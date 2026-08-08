import CoreAudio
import Darwin
import Foundation

public struct AudioProcessTarget: Codable, Equatable, Hashable, Sendable {
    public let processID: Int32?
    public let bundleID: String?

    public init(processID: Int32? = nil, bundleID: String? = nil) {
        precondition(processID != nil || bundleID != nil)
        self.processID = processID
        self.bundleID = bundleID
    }
}

public enum SystemAudioSelection: Equatable, Sendable {
    case selected([AudioProcessTarget])
    case global(excluding: [AudioProcessTarget])
}

public actor SystemAudioCaptureService: AudioCapturing {
    public nonisolated let lane: AudioLane = .output

    private let selection: SystemAudioSelection
    private let configuration: AudioCaptureConfiguration
    private let history: BoundedAudioBuffer
    private let system = AudioHardwareSystem.shared

    private var eventBuffer: DiscardingAsyncStreamBuffer<AudioCaptureEvent>?
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var ring: RealtimeAudioRing?
    private var descriptor: AudioRouteDescriptor?
    private var drainTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var missingCallbackReported = false
    private var startedAt: HostTimestamp?

    public init(
        selection: SystemAudioSelection,
        configuration: AudioCaptureConfiguration = .init()
    ) {
        self.selection = selection
        self.configuration = configuration
        self.history = BoundedAudioBuffer(limits: configuration.historyLimits)
    }

    public func events() -> AsyncStream<AudioCaptureEvent> {
        eventBuffer?.finish()
        let buffer = DiscardingAsyncStreamBuffer<AudioCaptureEvent>(
            maximumCount: 64,
            prepare: { $0.ownedForSensitiveBuffer() },
            discard: { $0.scrubAudioData() }
        )
        eventBuffer = buffer
        return buffer.stream()
    }

    public func start() async throws {
        guard tap == nil else { throw AudioCaptureError.alreadyRunning(.output) }

        let resolved = try resolveSelection()
        let tapDescription: CATapDescription
        let routeScope: AudioRouteScope

        switch selection {
        case .selected(let targets):
            guard !resolved.processes.isEmpty || !resolved.bundleIDs.isEmpty else {
                throw AudioCaptureError.sourceUnavailable
            }
            tapDescription = CATapDescription(
                stereoMixdownOfProcesses: resolved.processes.map(\.id)
            )
            tapDescription.bundleIDs = resolved.bundleIDs
            tapDescription.isProcessRestoreEnabled = true
            routeScope = .selectedProcesses

            guard !targets.isEmpty else { throw AudioCaptureError.sourceUnavailable }

        case .global:
            tapDescription = CATapDescription(
                stereoGlobalTapButExcludeProcesses: resolved.processes.map(\.id)
            )
            tapDescription.bundleIDs = resolved.bundleIDs
            tapDescription.isProcessRestoreEnabled = true
            routeScope = .globalOutput
        }

        tapDescription.name = "PaceNote meeting output"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        let newTap: AudioHardwareTap
        do {
            guard let createdTap = try system.makeProcessTap(description: tapDescription) else {
                throw AudioCaptureError.sourceUnavailable
            }
            newTap = createdTap
        } catch let error as AudioHardwareError {
            throw Self.captureError(for: error)
        }

        do {
            let streamDescription = try newTap.format
            let formatDescription = AudioFormatDescription(streamDescription)
            guard formatDescription.isUsablePCM else {
                throw AudioCaptureError.invalidFormat(.output)
            }

            let newRing = RealtimeAudioRing(lane: .output, format: formatDescription)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "PaceNote Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: try newTap.uid,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            guard
                let newAggregate = try system.makeAggregateDevice(
                    description: aggregateDescription
                )
            else {
                throw AudioCaptureError.sourceUnavailable
            }

            var newIOProc: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(
                &newIOProc,
                newAggregate.id,
                nil
            ) { _, inputData, inputTime, _, _ in
                guard let hostTime = HostTimestamp(audioTimeStamp: inputTime.pointee) else {
                    newRing.noteInvalidTimestamp()
                    return
                }
                let frameCount = Self.frameCount(
                    in: inputData,
                    bytesPerFrame: streamDescription.mBytesPerFrame
                )
                _ = newRing.write(inputData, frameCount: frameCount, hostTime: hostTime)
            }
            guard createStatus == noErr else {
                try? system.destroyAggregateDevice(newAggregate)
                throw AudioCaptureError.systemFailure(code: createStatus)
            }

            do {
                try newAggregate.start(IOProcID: newIOProc)
            } catch {
                if let newIOProc {
                    _ = AudioDeviceDestroyIOProcID(newAggregate.id, newIOProc)
                }
                try? system.destroyAggregateDevice(newAggregate)
                throw error
            }

            let newDescriptor = AudioRouteDescriptor(
                lane: .output,
                scope: routeScope,
                format: formatDescription,
                selectedSourceCount: resolved.sourceCount
            )
            tap = newTap
            aggregate = newAggregate
            ioProcID = newIOProc
            ring = newRing
            descriptor = newDescriptor
            startedAt = .now
            missingCallbackReported = false
            beginDrain(for: newRing)
            beginWatchdog(for: newRing)
            yield(.started(newDescriptor))
        } catch {
            try? system.destroyProcessTap(newTap)
            throw error
        }
    }

    public func stop() async {
        let drainTask = self.drainTask
        let watchdogTask = self.watchdogTask
        drainTask?.cancel()
        watchdogTask?.cancel()
        self.drainTask = nil
        self.watchdogTask = nil

        if let aggregate {
            try? aggregate.stop(IOProcID: ioProcID)
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
            }
            try? system.destroyAggregateDevice(aggregate)
        }
        if let tap {
            try? system.destroyProcessTap(tap)
        }

        aggregate = nil
        tap = nil
        ioProcID = nil
        await drainTask?.value
        await watchdogTask?.value
        ring?.clear()
        ring = nil
        descriptor = nil
        startedAt = nil
        missingCallbackReported = false
        await history.clear()
        eventBuffer?.finish(delivering: .stopped(.output))
        eventBuffer = nil
    }

    public func bufferedAudio() async -> [CapturedAudioChunk] {
        await history.snapshot()
    }

    public func clearBufferedAudio() async {
        await history.clear()
    }

    private struct ResolvedSelection {
        let processes: [AudioHardwareProcess]
        let bundleIDs: [String]
        let sourceCount: Int
    }

    private func resolveSelection() throws -> ResolvedSelection {
        let targets: [AudioProcessTarget]
        switch selection {
        case .selected(let selected):
            targets = selected
        case .global(let excluded):
            var safeExclusions = excluded
            safeExclusions.append(AudioProcessTarget(processID: getpid()))
            if let ownBundleID = Bundle.main.bundleIdentifier {
                safeExclusions.append(AudioProcessTarget(bundleID: ownBundleID))
            }
            targets = safeExclusions
        }

        let available = try system.processes
        let processIDs = Set(targets.compactMap(\.processID))
        let requestedBundleIDs = Set(targets.compactMap(\.bundleID))
        let matches = try available.filter { process in
            if processIDs.contains(try process.pid) { return true }
            guard let bundleID = try process.bundleID else { return false }
            return requestedBundleIDs.contains(bundleID)
        }

        let resolvedBundleIDs = Set(
            try matches.compactMap { try $0.bundleID }
        ).union(requestedBundleIDs)
        return ResolvedSelection(
            processes: matches,
            bundleIDs: resolvedBundleIDs.sorted(),
            sourceCount: max(matches.count, requestedBundleIDs.count)
        )
    }

    private nonisolated static func frameCount(
        in bufferList: UnsafePointer<AudioBufferList>,
        bytesPerFrame: UInt32
    ) -> UInt32 {
        guard bytesPerFrame > 0 else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        return
            buffers
            .map { $0.mDataByteSize / bytesPerFrame }
            .min() ?? 0
    }

    nonisolated static func captureError(for error: AudioHardwareError) -> AudioCaptureError {
        if error.error == kAudioDevicePermissionsError { return .permissionDenied }
        return .systemFailure(code: error.error)
    }

    private func beginDrain(for ring: RealtimeAudioRing) {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.drain(ring)
                do {
                    try await Task.sleep(for: self.configuration.drainInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func drain(_ ring: RealtimeAudioRing) async {
        while var chunk = ring.read() {
            let result = await history.append(chunk)
            if result == .rejectedTooLarge {
                yield(
                    .gap(
                        AudioGap(
                            lane: .output,
                            reason: .oversizedBuffer,
                            detectedAt: chunk.hostTime,
                            droppedChunkCount: 1
                        )
                    )
                )
            } else {
                let result = yield(.audio(chunk))
                if result == .droppedOldest {
                    yield(
                        .gap(
                            AudioGap(
                                lane: .output,
                                reason: .bufferOverflow,
                                detectedAt: chunk.hostTime,
                                droppedChunkCount: 1
                            )
                        )
                    )
                }
            }
            chunk.scrubAudioData()
        }
        emitRingGaps(ring)
    }

    private func emitRingGaps(_ ring: RealtimeAudioRing) {
        let now = HostTimestamp.now
        let overflow = ring.takeOverflowCount()
        if overflow > 0 {
            yield(
                .gap(
                    AudioGap(
                        lane: .output,
                        reason: .bufferOverflow,
                        detectedAt: now,
                        droppedChunkCount: overflow
                    )
                )
            )
        }

        let oversized = ring.takeOversizedCount()
        if oversized > 0 {
            yield(
                .gap(
                    AudioGap(
                        lane: .output,
                        reason: .oversizedBuffer,
                        detectedAt: now,
                        droppedChunkCount: oversized
                    )
                )
            )
        }

        let invalidTimestamps = ring.takeInvalidTimestampCount()
        if invalidTimestamps > 0 {
            yield(
                .gap(
                    AudioGap(
                        lane: .output,
                        reason: .invalidTimestamp,
                        detectedAt: now,
                        droppedChunkCount: invalidTimestamps
                    )
                )
            )
        }
    }

    private func beginWatchdog(for ring: RealtimeAudioRing) {
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self else { return }
                await self.checkWatchdog(ring)
            }
        }
    }

    private func checkWatchdog(_ ring: RealtimeAudioRing) {
        guard let baseline = ring.lastCallbackHostTime() ?? startedAt else { return }
        let overdue = HostTimestamp.now.seconds - baseline.seconds > configuration.callbackTimeout
        if overdue, !missingCallbackReported {
            missingCallbackReported = true
            yield(
                .gap(
                    AudioGap(
                        lane: .output,
                        reason: .callbackMissing,
                        detectedAt: .now
                    )
                )
            )
        } else if !overdue {
            missingCallbackReported = false
        }
    }

    @discardableResult
    private func yield(
        _ event: AudioCaptureEvent
    ) -> DiscardingAsyncStreamBuffer<AudioCaptureEvent>.YieldResult {
        eventBuffer?.yield(event) ?? .terminated
    }
}
