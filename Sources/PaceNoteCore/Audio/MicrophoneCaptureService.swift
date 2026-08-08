import AVFoundation
import Foundation

public actor MicrophoneCaptureService: AudioCapturing {
    public nonisolated let lane: AudioLane = .microphone

    private enum Lifecycle: Equatable {
        case idle
        case starting(UUID)
        case running
        case stopping(UUID)
    }

    private let permissionProvider: any MicrophonePermissionProviding
    private let configuration: AudioCaptureConfiguration
    private let history: BoundedAudioBuffer
    private let teardownSuspension: (@Sendable () async -> Void)?

    private var lifecycle: Lifecycle = .idle
    private var eventBuffer: DiscardingAsyncStreamBuffer<AudioCaptureEvent>?
    private var engine: AVAudioEngine?
    private var ring: RealtimeAudioRing?
    private var descriptor: AudioRouteDescriptor?
    private var drainTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var routeObserver: (any NSObjectProtocol)?
    private var missingCallbackReported = false
    private var startedAt: HostTimestamp?
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        permissionProvider: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        configuration: AudioCaptureConfiguration = .init()
    ) {
        self.permissionProvider = permissionProvider
        self.configuration = configuration
        self.history = BoundedAudioBuffer(limits: configuration.historyLimits)
        self.teardownSuspension = nil
    }

    init(
        permissionProvider: any MicrophonePermissionProviding,
        configuration: AudioCaptureConfiguration = .init(),
        teardownSuspension: @escaping @Sendable () async -> Void
    ) {
        self.permissionProvider = permissionProvider
        self.configuration = configuration
        self.history = BoundedAudioBuffer(limits: configuration.historyLimits)
        self.teardownSuspension = teardownSuspension
    }

    public func events() async -> AsyncStream<AudioCaptureEvent> {
        await waitForTeardownCompletion()
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
        await waitForTeardownCompletion()
        guard lifecycle == .idle, engine == nil else {
            throw AudioCaptureError.alreadyRunning(.microphone)
        }

        let attempt = UUID()
        lifecycle = .starting(attempt)

        do {
            let permissionStatus = await permissionProvider.status()
            guard lifecycle == .starting(attempt) else {
                throw AudioCaptureError.sourceUnavailable
            }
            switch permissionStatus {
            case .notDetermined:
                throw AudioCaptureError.permissionRequired
            case .denied:
                throw AudioCaptureError.permissionDenied
            case .granted:
                break
            }

            let newEngine = AVAudioEngine()
            let input = newEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let formatDescription = AudioFormatDescription(format)
            guard formatDescription.isUsablePCM else {
                throw AudioCaptureError.invalidFormat(.microphone)
            }

            let newRing = RealtimeAudioRing(lane: .microphone, format: formatDescription)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
                guard let hostTime = HostTimestamp(audioTime: time) else {
                    newRing.noteInvalidTimestamp()
                    return
                }
                _ = newRing.write(
                    buffer.audioBufferList,
                    frameCount: buffer.frameLength,
                    hostTime: hostTime
                )
            }

            do {
                newEngine.prepare()
                try newEngine.start()
            } catch {
                input.removeTap(onBus: 0)
                newRing.sealAndClear()
                throw error
            }

            let newDescriptor = AudioRouteDescriptor(
                lane: .microphone,
                scope: .defaultMicrophone,
                format: formatDescription
            )
            engine = newEngine
            ring = newRing
            descriptor = newDescriptor
            startedAt = .now
            missingCallbackReported = false
            lifecycle = .running

            installRouteObserver(for: newEngine)
            beginDrain(for: newRing)
            beginWatchdog(for: newRing)
            yield(.started(newDescriptor))
        } catch {
            if lifecycle == .starting(attempt) {
                lifecycle = .idle
            }
            throw error
        }
    }

    public func stop() async {
        await stop(emitStoppedEvent: true)
    }

    public func bufferedAudio() async -> [CapturedAudioChunk] {
        await history.snapshot()
    }

    public func clearBufferedAudio() async {
        await history.clear()
    }

    private func stop(emitStoppedEvent: Bool) async {
        if case .stopping = lifecycle {
            await waitForTeardownCompletion()
            return
        }

        let teardown = UUID()
        lifecycle = .stopping(teardown)

        let stoppedDrainTask = drainTask
        let stoppedWatchdogTask = watchdogTask
        stoppedDrainTask?.cancel()
        stoppedWatchdogTask?.cancel()
        self.drainTask = nil
        self.watchdogTask = nil

        let stoppedRouteObserver = routeObserver
        routeObserver = nil
        if let stoppedRouteObserver {
            NotificationCenter.default.removeObserver(stoppedRouteObserver)
        }

        let stoppedEngine = engine
        engine = nil
        if let stoppedEngine {
            stoppedEngine.inputNode.removeTap(onBus: 0)
            stoppedEngine.stop()
        }

        let stoppedRing = ring
        ring = nil
        stoppedRing?.sealAndClear()
        descriptor = nil
        startedAt = nil
        missingCallbackReported = false

        let stoppedEventBuffer = eventBuffer
        eventBuffer = nil
        stoppedEventBuffer?.discardQueued()

        await stoppedDrainTask?.value
        await stoppedWatchdogTask?.value
        if let teardownSuspension { await teardownSuspension() }
        await history.clear()
        let terminalEvent: AudioCaptureEvent? = emitStoppedEvent ? .stopped(.microphone) : nil
        stoppedEventBuffer?.finish(delivering: terminalEvent)

        guard lifecycle == .stopping(teardown) else { return }
        lifecycle = .idle
        let waiters = teardownWaiters
        teardownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func waitForTeardownCompletion() async {
        guard case .stopping = lifecycle else { return }
        await withCheckedContinuation { continuation in
            if case .stopping = lifecycle {
                teardownWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func installRouteObserver(for engine: AVAudioEngine) {
        routeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleRouteChange() }
        }
    }

    private func handleRouteChange() async {
        guard let previous = descriptor else { return }
        yield(.routeChanged(previous: previous, current: nil))
        yield(
            .gap(
                AudioGap(
                    lane: .microphone,
                    reason: .routeChanged,
                    detectedAt: .now
                )
            )
        )
        await stop(emitStoppedEvent: true)
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
                            lane: .microphone,
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
                                lane: .microphone,
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
                        lane: .microphone,
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
                        lane: .microphone,
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
                        lane: .microphone,
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
                        lane: .microphone,
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
