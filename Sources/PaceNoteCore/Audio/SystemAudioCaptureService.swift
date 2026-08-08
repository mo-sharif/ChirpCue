import CoreAudio
import Darwin
import Foundation

public struct AudioProcessTarget: Codable, Equatable, Hashable, Sendable {
    public let processID: Int32?
    public let bundleID: String?
    public let processStartToken: String?
    public let audioObjectID: AudioObjectID?

    public init(
        processID: Int32? = nil,
        bundleID: String? = nil,
        processStartToken: String? = nil,
        audioObjectID: AudioObjectID? = nil
    ) {
        precondition(processID != nil || bundleID != nil || audioObjectID != nil)
        self.processID = processID
        self.bundleID = bundleID
        self.processStartToken = processStartToken
        self.audioObjectID = audioObjectID
    }
}

public enum SystemAudioSelection: Equatable, Sendable {
    case selected([AudioProcessTarget])
    case global(excluding: [AudioProcessTarget])
}

enum SystemAudioTeardownStep: CaseIterable, Sendable {
    case stopAggregate
    case destroyIOProc
    case destroyAggregate
    case destroyTap
}

struct SystemAudioTeardownOperations: @unchecked Sendable {
    let stopAggregate: @Sendable (AudioObjectID, AudioDeviceIOProcID?) throws -> Void
    let destroyIOProc: @Sendable (AudioObjectID, AudioDeviceIOProcID) throws -> Void
    let destroyAggregate: @Sendable (AudioObjectID) throws -> Void
    let destroyTap: @Sendable (AudioObjectID) throws -> Void

    static let live = Self(
        stopAggregate: { aggregateID, ioProcID in
            try verify(AudioDeviceStop(aggregateID, ioProcID))
        },
        destroyIOProc: { aggregateID, ioProcID in
            try verify(AudioDeviceDestroyIOProcID(aggregateID, ioProcID))
        },
        destroyAggregate: { aggregateID in
            try verify(AudioHardwareDestroyAggregateDevice(aggregateID))
        },
        destroyTap: { tapID in
            try verify(AudioHardwareDestroyProcessTap(tapID))
        }
    )

    private static func verify(_ status: OSStatus) throws {
        guard status == noErr else {
            throw AudioCaptureError.systemFailure(code: status)
        }
    }
}

struct SystemAudioTeardownState: @unchecked Sendable {
    private(set) var aggregateID: AudioObjectID?
    private(set) var ioProcID: AudioDeviceIOProcID?
    private(set) var tapID: AudioObjectID?
    private(set) var aggregateIsRunning: Bool

    init(
        aggregateID: AudioObjectID? = nil,
        ioProcID: AudioDeviceIOProcID? = nil,
        tapID: AudioObjectID,
        aggregateIsRunning: Bool = false
    ) {
        precondition(aggregateID != nil || ioProcID == nil)
        precondition(aggregateID != nil || !aggregateIsRunning)
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.tapID = tapID
        self.aggregateIsRunning = aggregateIsRunning
    }

    var isComplete: Bool {
        aggregateID == nil && ioProcID == nil && tapID == nil && !aggregateIsRunning
    }

    mutating func registerAggregate(_ aggregateID: AudioObjectID) {
        precondition(self.aggregateID == nil)
        self.aggregateID = aggregateID
    }

    mutating func registerIOProc(_ ioProcID: AudioDeviceIOProcID) {
        precondition(aggregateID != nil)
        precondition(self.ioProcID == nil)
        self.ioProcID = ioProcID
    }

    mutating func markAggregateRunning() {
        precondition(aggregateID != nil)
        aggregateIsRunning = true
    }

    mutating func teardown(using operations: SystemAudioTeardownOperations) throws {
        if aggregateIsRunning {
            guard let aggregateID else { preconditionFailure("Running aggregate has no handle") }
            try operations.stopAggregate(aggregateID, ioProcID)
            aggregateIsRunning = false
        }

        if let ioProcID {
            guard let aggregateID else { preconditionFailure("IOProc has no aggregate handle") }
            try operations.destroyIOProc(aggregateID, ioProcID)
            self.ioProcID = nil
        }

        if let aggregateID {
            try operations.destroyAggregate(aggregateID)
            self.aggregateID = nil
        }

        if let tapID {
            try operations.destroyTap(tapID)
            self.tapID = nil
        }
    }
}

public actor SystemAudioCaptureService: AudioCapturing {
    public nonisolated let lane: AudioLane = .output

    private let selection: SystemAudioSelection
    private let configuration: AudioCaptureConfiguration
    private let history: BoundedAudioBuffer
    private let system = AudioHardwareSystem.shared
    private let teardownOperations: SystemAudioTeardownOperations

    private var eventBuffer: DiscardingAsyncStreamBuffer<AudioCaptureEvent>?
    private var teardownState: SystemAudioTeardownState?
    private var ring: RealtimeAudioRing?
    private var descriptor: AudioRouteDescriptor?
    private var drainTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var stopTask: Task<Void, Error>?
    private var missingCallbackReported = false
    private var unavailableRouteCheckCount = 0
    private var startedAt: HostTimestamp?

    public init(
        selection: SystemAudioSelection,
        configuration: AudioCaptureConfiguration = .init()
    ) {
        self.selection = selection
        self.configuration = configuration
        self.history = BoundedAudioBuffer(limits: configuration.historyLimits)
        self.teardownOperations = .live
    }

    init(
        selection: SystemAudioSelection,
        configuration: AudioCaptureConfiguration = .init(),
        teardownOperations: SystemAudioTeardownOperations,
        teardownState: SystemAudioTeardownState? = nil,
        ring: RealtimeAudioRing? = nil,
        history: BoundedAudioBuffer? = nil,
        drainTask: Task<Void, Never>? = nil,
        watchdogTask: Task<Void, Never>? = nil
    ) {
        self.selection = selection
        self.configuration = configuration
        self.history = history ?? BoundedAudioBuffer(limits: configuration.historyLimits)
        self.teardownOperations = teardownOperations
        self.teardownState = teardownState
        self.ring = ring
        self.drainTask = drainTask
        self.watchdogTask = watchdogTask
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
        guard teardownState == nil, stopTask == nil, ring == nil else {
            throw AudioCaptureError.alreadyRunning(.output)
        }

        let resolved = try resolveSelection()
        let tapDescription: CATapDescription
        let routeScope: AudioRouteScope

        switch selection {
        case .selected(let targets):
            guard !targets.isEmpty,
                !resolved.processes.isEmpty
            else {
                throw AudioCaptureError.sourceUnavailable
            }
            tapDescription = CATapDescription(
                stereoMixdownOfProcesses: resolved.processes.map(\.id)
            )
            tapDescription.bundleIDs = []
            tapDescription.isProcessRestoreEnabled = false
            routeScope = .selectedProcesses

        case .global:
            tapDescription = CATapDescription(
                stereoGlobalTapButExcludeProcesses: resolved.processes.map(\.id)
            )
            tapDescription.bundleIDs = resolved.bundleIDs
            tapDescription.isProcessRestoreEnabled = true
            routeScope = .globalOutput
        }

        tapDescription.name = "ChirpCue meeting output"
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
            teardownState = SystemAudioTeardownState(tapID: newTap.id)
            let streamDescription = try newTap.format
            let formatDescription = AudioFormatDescription(streamDescription)
            guard formatDescription.isUsablePCM else {
                throw AudioCaptureError.invalidFormat(.output)
            }

            let newRing = RealtimeAudioRing(lane: .output, format: formatDescription)
            ring = newRing
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ChirpCue Capture",
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
            teardownState?.registerAggregate(newAggregate.id)

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
                throw AudioCaptureError.systemFailure(code: createStatus)
            }
            if let newIOProc {
                teardownState?.registerIOProc(newIOProc)
            }

            try newAggregate.start(IOProcID: newIOProc)
            teardownState?.markAggregateRunning()

            let newDescriptor = AudioRouteDescriptor(
                lane: .output,
                scope: routeScope,
                format: formatDescription,
                selectedSourceCount: resolved.sourceCount
            )
            descriptor = newDescriptor
            startedAt = .now
            missingCallbackReported = false
            unavailableRouteCheckCount = 0
            beginDrain(for: newRing)
            beginWatchdog(for: newRing)
            yield(.started(newDescriptor))
        } catch {
            try await rollbackFailedSetup(after: error)
        }
    }

    public func stop() async throws {
        if let stopTask {
            return try await stopTask.value
        }

        let task = Task { try await self.performStop() }
        stopTask = task
        try await task.value
    }

    private func performStop() async throws {
        defer { stopTask = nil }
        let workers = sealCaptureProducerAndCancelWorkers()

        do {
            try teardownPendingResources()
        } catch {
            await joinWorkersAndScrubSensitiveState(workers)
            throw error
        }

        await joinWorkersAndScrubSensitiveState(workers)
        releaseCaptureStateAfterVerifiedTeardown()
        eventBuffer?.finish(delivering: .stopped(.output))
        eventBuffer = nil
    }

    func rollbackFailedSetup(after setupError: any Error) async throws -> Never {
        let workers = sealCaptureProducerAndCancelWorkers()

        do {
            try teardownPendingResources()
        } catch {
            await joinWorkersAndScrubSensitiveState(workers)
            throw error
        }

        await joinWorkersAndScrubSensitiveState(workers)
        releaseCaptureStateAfterVerifiedTeardown()
        throw setupError
    }

    private struct CaptureWorkers {
        let drain: Task<Void, Never>?
        let watchdog: Task<Void, Never>?
    }

    /// Closes the callback handoff before the first suspension. The Core Audio
    /// callback may still run until hardware teardown completes, but every later
    /// write is rejected and the bounded in-flight copy has already left.
    private func sealCaptureProducerAndCancelWorkers() -> CaptureWorkers {
        ring?.sealAndClear()
        eventBuffer?.discardQueued()

        let drainTask = self.drainTask
        let watchdogTask = self.watchdogTask
        drainTask?.cancel()
        watchdogTask?.cancel()
        self.drainTask = nil
        self.watchdogTask = nil
        return CaptureWorkers(drain: drainTask, watchdog: watchdogTask)
    }

    private func joinWorkersAndScrubSensitiveState(_ workers: CaptureWorkers) async {
        // Clear once before joining and again after it. A drain that was already
        // suspended in `history.append` cannot repopulate the retained buffer.
        await history.clear()
        eventBuffer?.discardQueued()
        await workers.drain?.value
        await workers.watchdog?.value
        await history.clear()
        eventBuffer?.discardQueued()
    }

    private func releaseCaptureStateAfterVerifiedTeardown() {
        precondition(teardownState == nil)
        ring = nil
        descriptor = nil
        startedAt = nil
        missingCallbackReported = false
        unavailableRouteCheckCount = 0
    }

    private func teardownPendingResources() throws {
        guard var pending = teardownState else { return }
        do {
            try pending.teardown(using: teardownOperations)
        } catch {
            teardownState = pending
            throw error
        }
        teardownState = pending.isComplete ? nil : pending
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
        let available = try system.processes
        switch selection {
        case .selected(let selected):
            guard !selected.isEmpty else { throw AudioCaptureError.sourceUnavailable }
            var matches: [AudioHardwareProcess] = []
            matches.reserveCapacity(selected.count)
            var matchedObjectIDs: Set<AudioObjectID> = []
            for target in selected {
                var match: AudioHardwareProcess?
                for process in available {
                    do {
                        let processID = try process.pid
                        if Self.selectedTargetMatches(
                            target,
                            processID: processID,
                            bundleID: try process.bundleID,
                            processStartToken: SystemProcessStartToken.value(for: processID),
                            audioObjectID: process.id
                        ) {
                            match = process
                            break
                        }
                    } catch {
                        // Core Audio's process list can change while its properties are read.
                        continue
                    }
                }
                if let match, matchedObjectIDs.insert(match.id).inserted {
                    matches.append(match)
                }
            }
            guard !matches.isEmpty else { throw AudioCaptureError.sourceUnavailable }
            return ResolvedSelection(
                processes: matches,
                bundleIDs: [],
                sourceCount: matches.count
            )
        case .global(let excluded):
            let safeExclusions = Self.globalOutputExclusions(
                requested: excluded,
                ownProcessID: getpid(),
                ownBundleID: Bundle.main.bundleIdentifier
            )
            let processIDs = Set(safeExclusions.compactMap(\.processID))
            let requestedBundleIDs = Set(safeExclusions.compactMap(\.bundleID))
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
    }

    static func globalOutputExclusions(
        requested: [AudioProcessTarget],
        ownProcessID: Int32,
        ownBundleID: String?
    ) -> [AudioProcessTarget] {
        var exclusions = requested
        exclusions.append(AudioProcessTarget(processID: ownProcessID))
        if let ownBundleID, !ownBundleID.isEmpty {
            exclusions.append(AudioProcessTarget(bundleID: ownBundleID))
        }
        return exclusions
    }

    static func selectedTargetMatches(
        _ target: AudioProcessTarget,
        processID: Int32,
        bundleID: String?,
        processStartToken: String?,
        audioObjectID: AudioObjectID
    ) -> Bool {
        guard let expectedProcessID = target.processID,
            let expectedStartToken = target.processStartToken,
            !expectedStartToken.isEmpty,
            let expectedAudioObjectID = target.audioObjectID
        else {
            return false
        }
        return expectedProcessID == processID
            && expectedStartToken == processStartToken
            && expectedAudioObjectID == audioObjectID
            && target.bundleID == bundleID
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
            guard !Task.isCancelled else {
                chunk.scrubAudioData()
                return
            }
            let result = await history.append(chunk)
            guard !Task.isCancelled else {
                chunk.scrubAudioData()
                return
            }
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
        guard !Task.isCancelled else { return }
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
        let selectionIsAvailable = overdue && (try? resolveSelection()) != nil
        if !overdue || selectionIsAvailable {
            unavailableRouteCheckCount = 0
        } else {
            unavailableRouteCheckCount = min(unavailableRouteCheckCount + 1, 3)
        }
        if Self.shouldReportMissingCallback(
            callbackOverdue: overdue,
            selectionIsAvailable: selectionIsAvailable,
            consecutiveUnavailableChecks: unavailableRouteCheckCount
        ), !missingCallbackReported {
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

    static func shouldReportMissingCallback(
        callbackOverdue: Bool,
        selectionIsAvailable: Bool,
        consecutiveUnavailableChecks: Int
    ) -> Bool {
        callbackOverdue && !selectionIsAvailable && consecutiveUnavailableChecks >= 3
    }

    @discardableResult
    private func yield(
        _ event: AudioCaptureEvent
    ) -> DiscardingAsyncStreamBuffer<AudioCaptureEvent>.YieldResult {
        eventBuffer?.yield(event) ?? .terminated
    }
}
