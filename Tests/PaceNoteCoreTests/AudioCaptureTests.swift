import AVFoundation
import CoreAudio
import XCTest

@testable import PaceNoteCore

final class AudioCaptureTests: XCTestCase {
    func testFakeCaptureEmitsExplicitLifecycleAndGapEvents() async throws {
        let capture = FakeAudioCapture(lane: .output)
        let stream = await capture.events()
        let descriptor = makeDescriptor(lane: .output)
        let gap = AudioGap(
            lane: .output,
            reason: .routeChanged,
            detectedAt: HostTimestamp(ticks: 123)
        )

        await capture.start(descriptor: descriptor)
        await capture.emit(.gap(gap))
        await capture.stop()

        var iterator = stream.makeAsyncIterator()
        let startedEvent = await iterator.next()
        let gapEvent = await iterator.next()
        let stoppedEvent = await iterator.next()
        let endEvent = await iterator.next()
        XCTAssertEqual(startedEvent, .started(descriptor))
        XCTAssertEqual(gapEvent, .gap(gap))
        XCTAssertEqual(stoppedEvent, .stopped(.output))
        XCTAssertNil(endEvent)
    }

    func testMicrophoneDeniedFailsBeforeConstructingCaptureEngine() async {
        let service = MicrophoneCaptureService(
            permissionProvider: FakeMicrophonePermissionProvider(status: .denied)
        )

        do {
            try await service.start()
            XCTFail("Expected permission denial")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testMicrophoneUndeterminedDoesNotImplicitlyRequestTCC() async {
        let permissions = FakeMicrophonePermissionProvider(status: .notDetermined)
        let service = MicrophoneCaptureService(permissionProvider: permissions)

        do {
            try await service.start()
            XCTFail("Expected permission requirement")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .permissionRequired)
        } catch {
            XCTFail("Unexpected error type")
        }
        let requestCount = await permissions.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testMicrophoneStopFinishesEventStreamAndAllowsReplacement() async {
        let service = MicrophoneCaptureService(
            permissionProvider: FakeMicrophonePermissionProvider(status: .denied)
        )
        let firstStream = await service.events()

        await service.stop()

        var firstIterator = firstStream.makeAsyncIterator()
        let firstTerminal = await firstIterator.next()
        let firstEnd = await firstIterator.next()
        XCTAssertEqual(firstTerminal, .stopped(.microphone))
        XCTAssertNil(firstEnd)

        let secondStream = await service.events()
        await service.stop()
        var secondIterator = secondStream.makeAsyncIterator()
        let secondTerminal = await secondIterator.next()
        let secondEnd = await secondIterator.next()
        XCTAssertEqual(secondTerminal, .stopped(.microphone))
        XCTAssertNil(secondEnd)
    }

    func testMicrophoneStopInvalidatesStartSuspendedOnPermissionStatus() async {
        let permissions = SuspendingMicrophonePermissionProvider(status: .denied)
        let service = MicrophoneCaptureService(permissionProvider: permissions)
        let stream = await service.events()

        let start = Task { () -> AudioCaptureError? in
            do {
                try await service.start()
                return nil
            } catch let error as AudioCaptureError {
                return error
            } catch {
                return .sourceUnavailable
            }
        }
        await permissions.waitUntilStatusRequested()

        await service.stop()
        await permissions.release()
        let startError = await start.value

        var iterator = stream.makeAsyncIterator()
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(startError, .sourceUnavailable)
        XCTAssertEqual(terminal, .stopped(.microphone))
        XCTAssertNil(end)
    }

    func testMicrophoneConcurrentStartIsRejectedBeforeSecondPermissionCheck() async {
        let permissions = SuspendingMicrophonePermissionProvider(status: .denied)
        let service = MicrophoneCaptureService(permissionProvider: permissions)

        let firstStart = Task { () -> AudioCaptureError? in
            do {
                try await service.start()
                return nil
            } catch let error as AudioCaptureError {
                return error
            } catch {
                return .sourceUnavailable
            }
        }
        await permissions.waitUntilStatusRequested()

        let secondError: AudioCaptureError?
        do {
            try await service.start()
            secondError = nil
        } catch let error as AudioCaptureError {
            secondError = error
        } catch {
            secondError = .sourceUnavailable
        }

        let statusRequestCount = await permissions.statusRequestCount
        await permissions.release()
        let firstError = await firstStart.value

        XCTAssertEqual(secondError, .alreadyRunning(.microphone))
        XCTAssertEqual(statusRequestCount, 1)
        XCTAssertEqual(firstError, .permissionDenied)
    }

    func testMicrophoneStopCannotFinishReplacementStreamOrScrubReplacementStart() async {
        let teardownBarrier = MicrophoneLifecycleBarrier()
        let permissions = FakeMicrophonePermissionProvider(status: .denied)
        let service = MicrophoneCaptureService(
            permissionProvider: permissions,
            teardownSuspension: { await teardownBarrier.suspendIfArmed() }
        )
        let firstStream = await service.events()
        await teardownBarrier.arm()

        let terminalDelivered = BooleanProbe()
        let firstTerminalTask = Task {
            var iterator = firstStream.makeAsyncIterator()
            let terminal = await iterator.next()
            await terminalDelivered.setTrue()
            let end = await iterator.next()
            return (terminal, end)
        }

        let stop = Task { await service.stop() }
        await teardownBarrier.waitUntilEntered()

        try? await Task.sleep(for: .milliseconds(50))
        let terminalWasDeliveredDuringTeardown = await terminalDelivered.value
        XCTAssertFalse(terminalWasDeliveredDuringTeardown)

        let eventsReturned = BooleanProbe()
        let replacementEvents = Task {
            let stream = await service.events()
            await eventsReturned.setTrue()
            return stream
        }
        let startReturned = BooleanProbe()
        let replacementStart = Task { () -> AudioCaptureError? in
            let result: AudioCaptureError?
            do {
                try await service.start()
                result = nil
            } catch let error as AudioCaptureError {
                result = error
            } catch {
                result = .sourceUnavailable
            }
            await startReturned.setTrue()
            return result
        }

        try? await Task.sleep(for: .milliseconds(50))
        let eventsWereBlocked = await eventsReturned.value
        let startWasBlocked = await startReturned.value
        let statusChecksWhileStopping = await permissions.statusCount
        XCTAssertFalse(eventsWereBlocked)
        XCTAssertFalse(startWasBlocked)
        XCTAssertEqual(statusChecksWhileStopping, 0)

        await teardownBarrier.release()
        await stop.value
        let replacementStream = await replacementEvents.value
        let replacementStartError = await replacementStart.value
        XCTAssertEqual(replacementStartError, .permissionDenied)

        await service.stop()
        var replacementIterator = replacementStream.makeAsyncIterator()
        let (firstTerminal, firstEnd) = await firstTerminalTask.value
        let replacementTerminal = await replacementIterator.next()
        let replacementEnd = await replacementIterator.next()
        XCTAssertEqual(firstTerminal, .stopped(.microphone))
        XCTAssertNil(firstEnd)
        XCTAssertEqual(replacementTerminal, .stopped(.microphone))
        XCTAssertNil(replacementEnd)
    }

    func testSystemAudioPermissionErrorMapsToVisiblePermissionDenial() {
        XCTAssertEqual(
            SystemAudioCaptureService.captureError(
                for: AudioHardwareError(kAudioDevicePermissionsError)
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            SystemAudioCaptureService.captureError(
                for: AudioHardwareError(kAudioHardwareNotReadyError)
            ),
            .systemFailure(code: kAudioHardwareNotReadyError)
        )
    }

    func testSystemAudioPermissionProbeDoesNotTouchTCCUntilExplicitRequest() async {
        let probe = SystemAudioPermissionProbe()
        let status = await probe.status()
        XCTAssertEqual(status, .notDetermined)
    }

    func testSystemAudioPermissionProbeRetriesFailedTapDestroyBeforeReportingGranted() async throws {
        let recorder = SystemAudioPermissionProbeRecorder()
        let probe = SystemAudioPermissionProbe(operations: recorder.operations)

        do {
            _ = try await probe.request()
            XCTFail("Expected the scripted tap destruction failure")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .systemFailure(code: recorder.failureStatus))
        }

        let failedStatus = await probe.status()
        XCTAssertEqual(failedStatus, .notDetermined)
        XCTAssertEqual(recorder.createdTapIDs, [8_001])
        XCTAssertEqual(recorder.destroyedTapIDs, [8_001])

        let retriedStatus = try await probe.request()

        XCTAssertEqual(retriedStatus, .granted)
        let finalStatus = await probe.status()
        XCTAssertEqual(finalStatus, .granted)
        XCTAssertEqual(recorder.createdTapIDs, [8_001])
        XCTAssertEqual(recorder.destroyedTapIDs, [8_001, 8_001])
    }

    func testSystemAudioStopFailureRetainsRunningAggregateForRetry() async throws {
        try await assertSystemAudioTeardownRetry(failing: .stopAggregate)
    }

    func testSystemAudioIOProcFailureDoesNotRepeatSuccessfulStopOnRetry() async throws {
        try await assertSystemAudioTeardownRetry(failing: .destroyIOProc)
    }

    func testSystemAudioAggregateFailureDoesNotRepeatDestroyedIOProcOnRetry() async throws {
        try await assertSystemAudioTeardownRetry(failing: .destroyAggregate)
    }

    func testSystemAudioTapFailureDoesNotRepeatDestroyedAggregateOnRetry() async throws {
        try await assertSystemAudioTeardownRetry(failing: .destroyTap)
    }

    func testSystemAudioStopSealsProducerAndTearsDownHardwareBeforeJoiningWorkers() async throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let pcmBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )
        pcmBuffer.frameLength = 1
        let ring = RealtimeAudioRing(lane: .output, format: AudioFormatDescription(format))
        XCTAssertTrue(
            ring.write(
                pcmBuffer.audioBufferList,
                frameCount: 1,
                hostTime: HostTimestamp(ticks: 1)
            )
        )

        let workerBarrier = MicrophoneLifecycleBarrier()
        await workerBarrier.arm()
        let cancellationInsensitiveWorker = Task {
            await workerBarrier.suspendIfArmed()
        }
        await workerBarrier.waitUntilEntered()
        let teardownRecorder = SystemAudioTeardownRecorder(failingOnceAt: nil)
        let expectedSteps: [SystemAudioTeardownStep] = [
            .stopAggregate, .destroyIOProc, .destroyAggregate, .destroyTap,
        ]
        let service = SystemAudioCaptureService(
            selection: .global(excluding: []),
            teardownOperations: teardownRecorder.operations,
            teardownState: SystemAudioTeardownState(
                aggregateID: 8_001,
                ioProcID: Self.fakeIOProcID,
                tapID: 8_002,
                aggregateIsRunning: true
            ),
            ring: ring,
            drainTask: cancellationInsensitiveWorker
        )

        let firstStop = Task { try await service.stop() }
        let secondStop = Task { try await service.stop() }
        var hardwareStopped = false
        for _ in 0..<100 {
            if teardownRecorder.steps == expectedSteps {
                hardwareStopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(hardwareStopped)
        XCTAssertFalse(
            ring.write(
                pcmBuffer.audioBufferList,
                frameCount: 1,
                hostTime: HostTimestamp(ticks: 2)
            )
        )

        await workerBarrier.release()
        try await firstStop.value
        try await secondStop.value
        XCTAssertEqual(teardownRecorder.steps, expectedSteps)
    }

    func testFailedSystemAudioSetupRetainsSealedRingUntilTeardownRetrySucceeds() async throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let pcmBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        pcmBuffer.frameLength = 4
        let samples = try XCTUnwrap(pcmBuffer.floatChannelData?[0])
        samples[0] = 0.25
        samples[1] = -0.5
        samples[2] = 0.75
        samples[3] = -1

        var ring: RealtimeAudioRing? = RealtimeAudioRing(
            lane: .output,
            format: AudioFormatDescription(format)
        )
        let retainedRing = WeakRingProbe(ring)
        XCTAssertTrue(
            ring?.write(
                pcmBuffer.audioBufferList,
                frameCount: pcmBuffer.frameLength,
                hostTime: HostTimestamp(ticks: 1)
            ) ?? false
        )

        let scrubRecorder = SetupHistoryScrubRecorder()
        let history = BoundedAudioBuffer(
            discardedChunkObserver: { scrubRecorder.record($0) }
        )
        let historyChunk = CapturedAudioChunk(
            lane: .output,
            hostTime: HostTimestamp(ticks: 2),
            frameCount: 4,
            format: AudioFormatDescription(format),
            planes: [
                CapturedAudioPlane(
                    channelCount: 1,
                    data: Data(repeating: 0xA5, count: 16)
                )
            ]
        )
        let appendResult = await history.append(historyChunk)
        XCTAssertEqual(appendResult, .stored)

        let teardownRecorder = SystemAudioTeardownRecorder(failingOnceAt: .destroyIOProc)
        let service = SystemAudioCaptureService(
            selection: .global(excluding: []),
            teardownOperations: teardownRecorder.operations,
            teardownState: SystemAudioTeardownState(
                aggregateID: 9_001,
                ioProcID: Self.fakeIOProcID,
                tapID: 9_002,
                aggregateIsRunning: true
            ),
            ring: ring,
            history: history
        )
        let stream = await service.events()

        do {
            try await service.rollbackFailedSetup(after: AudioCaptureError.sourceUnavailable)
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .systemFailure(code: teardownRecorder.failureStatus))
        }

        XCTAssertFalse(
            ring?.write(
                pcmBuffer.audioBufferList,
                frameCount: pcmBuffer.frameLength,
                hostTime: HostTimestamp(ticks: 3)
            ) ?? true
        )
        let bufferedAfterFailure = await service.bufferedAudio()
        XCTAssertTrue(bufferedAfterFailure.isEmpty)
        XCTAssertEqual(scrubRecorder.discardedCount, 1)
        XCTAssertEqual(scrubRecorder.nonzeroByteCount, 0)
        XCTAssertEqual(teardownRecorder.steps, [.stopAggregate, .destroyIOProc])

        ring = nil
        XCTAssertNotNil(retainedRing.value)
        do {
            try await service.start()
            XCTFail("A new start must not replace failed setup teardown ownership")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .alreadyRunning(.output))
        }

        try await service.stop()

        XCTAssertNil(retainedRing.value)
        XCTAssertEqual(
            teardownRecorder.steps,
            [.stopAggregate, .destroyIOProc, .destroyIOProc, .destroyAggregate, .destroyTap]
        )
        var iterator = stream.makeAsyncIterator()
        let stoppedEvent = await iterator.next()
        let endEvent = await iterator.next()
        XCTAssertEqual(stoppedEvent, .stopped(.output))
        XCTAssertNil(endEvent)
    }

    func testTranscriberRejectsMissingAssetBeforeUsingSpeechAnalyzer() async {
        let service = AppleSpeechTranscriptionService(
            lane: .output,
            assets: FakeSpeechAssetProvider(availability: .downloadRequired)
        )
        let audio = AsyncStream<AudioCaptureEvent> { $0.finish() }

        do {
            try await service.start(audioEvents: audio, localeIdentifier: "en-US")
            XCTFail("Expected missing asset")
        } catch let error as SpeechTranscriptionError {
            XCTAssertEqual(error, .assetUnavailable(.downloadRequired))
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testTranscriberStopFinishesResultStreamBeforeStart() async {
        let service = AppleSpeechTranscriptionService(
            lane: .output,
            assets: FakeSpeechAssetProvider(availability: .installed)
        )
        let stream = await service.events()

        await service.stop()

        var iterator = stream.makeAsyncIterator()
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .stopped(.output))
        XCTAssertNil(end)
    }

    func testScriptedTranscriberPreservesVolatileFinalAndGapOrdering() async {
        let transcriber = FakeAudioTranscriber(lane: .microphone)
        let stream = await transcriber.events()
        let volatile = ProgressiveTranscriptResult(
            lane: .microphone,
            text: "Let me check",
            hostTimeRange: nil,
            stability: .volatile,
            confidence: 0.7
        )
        let final = ProgressiveTranscriptResult(
            lane: .microphone,
            text: "Let me check that.",
            hostTimeRange: nil,
            stability: .final,
            confidence: 0.9
        )
        let gap = AudioGap(
            lane: .microphone,
            reason: .callbackMissing,
            detectedAt: HostTimestamp(ticks: 456)
        )

        await transcriber.startForTest(localeIdentifier: "en-US")
        await transcriber.emit(.result(volatile))
        await transcriber.emit(.result(final))
        await transcriber.emit(.gap(gap))
        await transcriber.stop()

        var iterator = stream.makeAsyncIterator()
        let startedEvent = await iterator.next()
        let volatileEvent = await iterator.next()
        let finalEvent = await iterator.next()
        let gapEvent = await iterator.next()
        let stoppedEvent = await iterator.next()
        let endEvent = await iterator.next()
        XCTAssertEqual(
            startedEvent,
            .started(lane: .microphone, localeIdentifier: "en-US")
        )
        XCTAssertEqual(volatileEvent, .result(volatile))
        XCTAssertEqual(finalEvent, .result(final))
        XCTAssertEqual(gapEvent, .gap(gap))
        XCTAssertEqual(stoppedEvent, .stopped(.microphone))
        XCTAssertNil(endEvent)
    }

    private func makeDescriptor(lane: AudioLane) -> AudioRouteDescriptor {
        AudioRouteDescriptor(
            lane: lane,
            scope: lane == .microphone ? .defaultMicrophone : .selectedProcesses,
            format: AudioFormatDescription(
                sampleRate: 16_000,
                formatID: kAudioFormatLinearPCM,
                formatFlags: kAudioFormatFlagIsFloat,
                bytesPerPacket: 4,
                framesPerPacket: 1,
                bytesPerFrame: 4,
                channelsPerFrame: 1,
                bitsPerChannel: 32,
                isInterleaved: true
            )
        )
    }

    private func assertSystemAudioTeardownRetry(
        failing step: SystemAudioTeardownStep
    ) async throws {
        let recorder = SystemAudioTeardownRecorder(failingOnceAt: step)
        let state = SystemAudioTeardownState(
            aggregateID: 7_001,
            ioProcID: Self.fakeIOProcID,
            tapID: 7_002,
            aggregateIsRunning: true
        )
        let service = SystemAudioCaptureService(
            selection: .global(excluding: []),
            teardownOperations: recorder.operations,
            teardownState: state
        )
        let stream = await service.events()
        let events = AudioCaptureEventRecorder()
        let streamTask = Task {
            for await event in stream { await events.append(event) }
            await events.finish()
        }

        do {
            try await service.stop()
            XCTFail("Expected the scripted \(step) failure")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .systemFailure(code: recorder.failureStatus))
        }

        await Task.yield()
        let failedEventState = await events.state()
        XCTAssertEqual(failedEventState.events, [])
        XCTAssertFalse(failedEventState.didFinish)

        do {
            try await service.start()
            XCTFail("A start must not replace teardown state retained for retry")
        } catch let error as AudioCaptureError {
            XCTAssertEqual(error, .alreadyRunning(.output))
        }

        let firstPass = recorder.steps
        let failureIndex = try XCTUnwrap(SystemAudioTeardownStep.allCases.firstIndex(of: step))
        XCTAssertEqual(firstPass, Array(SystemAudioTeardownStep.allCases[...failureIndex]))

        try await service.stop()
        await streamTask.value

        let completedEventState = await events.state()
        XCTAssertEqual(completedEventState.events, [.stopped(.output)])
        XCTAssertTrue(completedEventState.didFinish)
        XCTAssertEqual(
            recorder.steps,
            firstPass + Array(SystemAudioTeardownStep.allCases[failureIndex...])
        )

        try await service.stop()
        XCTAssertEqual(
            recorder.steps,
            firstPass + Array(SystemAudioTeardownStep.allCases[failureIndex...])
        )
    }

    private static let fakeIOProcID: AudioDeviceIOProcID = fakeSystemAudioIOProc
}

private func fakeSystemAudioIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    _ = (device, now, inputData, inputTime, outputData, outputTime, clientData)
    return noErr
}

private final class SystemAudioTeardownRecorder: @unchecked Sendable {
    let failureStatus: OSStatus = -7_007

    private let lock = NSLock()
    private let failingStep: SystemAudioTeardownStep?
    private var didFail = false
    private var recordedSteps: [SystemAudioTeardownStep] = []

    init(failingOnceAt step: SystemAudioTeardownStep?) {
        failingStep = step
    }

    var steps: [SystemAudioTeardownStep] {
        lock.withLock { recordedSteps }
    }

    var operations: SystemAudioTeardownOperations {
        SystemAudioTeardownOperations(
            stopAggregate: { [self] _, _ in try record(.stopAggregate) },
            destroyIOProc: { [self] _, _ in try record(.destroyIOProc) },
            destroyAggregate: { [self] _ in try record(.destroyAggregate) },
            destroyTap: { [self] _ in try record(.destroyTap) }
        )
    }

    private func record(_ step: SystemAudioTeardownStep) throws {
        let shouldFail = lock.withLock {
            recordedSteps.append(step)
            guard step == failingStep, !didFail else { return false }
            didFail = true
            return true
        }
        if shouldFail {
            throw AudioCaptureError.systemFailure(code: failureStatus)
        }
    }
}

private final class SystemAudioPermissionProbeRecorder: @unchecked Sendable {
    let failureStatus: OSStatus = -8_001

    private let lock = NSLock()
    private var didFailDestroy = false
    private var created: [AudioObjectID] = []
    private var destroyed: [AudioObjectID] = []

    var createdTapIDs: [AudioObjectID] {
        lock.withLock { created }
    }

    var destroyedTapIDs: [AudioObjectID] {
        lock.withLock { destroyed }
    }

    var operations: SystemAudioPermissionProbeOperations {
        SystemAudioPermissionProbeOperations(
            createTap: { [self] in
                lock.withLock {
                    let tapID: AudioObjectID = 8_001
                    created.append(tapID)
                    return tapID
                }
            },
            destroyTap: { [self] tapID in
                let shouldFail = lock.withLock {
                    destroyed.append(tapID)
                    guard !didFailDestroy else { return false }
                    didFailDestroy = true
                    return true
                }
                if shouldFail {
                    throw AudioCaptureError.systemFailure(code: failureStatus)
                }
            }
        )
    }
}

private final class SetupHistoryScrubRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var discarded = 0
    private var nonzeroBytes = 0

    var discardedCount: Int {
        lock.withLock { discarded }
    }

    var nonzeroByteCount: Int {
        lock.withLock { nonzeroBytes }
    }

    func record(_ chunk: CapturedAudioChunk) {
        lock.withLock {
            discarded += 1
            nonzeroBytes += chunk.planes.reduce(into: 0) { count, plane in
                count += plane.data.count(where: { $0 != 0 })
            }
        }
    }
}

private final class WeakRingProbe {
    weak var value: RealtimeAudioRing?

    init(_ value: RealtimeAudioRing?) {
        self.value = value
    }
}

private actor AudioCaptureEventRecorder {
    private var events: [AudioCaptureEvent] = []
    private(set) var didFinish = false

    func append(_ event: AudioCaptureEvent) {
        events.append(event)
    }

    func finish() {
        didFinish = true
    }

    func state() -> (events: [AudioCaptureEvent], didFinish: Bool) {
        (events, didFinish)
    }
}

private actor FakeMicrophonePermissionProvider: MicrophonePermissionProviding {
    private let configuredStatus: AudioPermissionStatus
    private(set) var statusCount = 0
    private var requests = 0

    init(status: AudioPermissionStatus) {
        self.configuredStatus = status
    }

    func status() async -> AudioPermissionStatus {
        statusCount += 1
        return configuredStatus
    }

    func request() async -> AudioPermissionStatus {
        requests += 1
        return configuredStatus
    }

    func requestCount() -> Int {
        requests
    }
}

private actor SuspendingMicrophonePermissionProvider: MicrophonePermissionProviding {
    private let configuredStatus: AudioPermissionStatus
    private var statusRequests = 0
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(status: AudioPermissionStatus) {
        self.configuredStatus = status
    }

    var statusRequestCount: Int { statusRequests }

    func status() async -> AudioPermissionStatus {
        statusRequests += 1
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                }
            }
        }
        return configuredStatus
    }

    func request() -> AudioPermissionStatus {
        configuredStatus
    }

    func waitUntilStatusRequested() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor MicrophoneLifecycleBarrier {
    private var armed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arm() {
        precondition(!armed && !entered)
        armed = true
        released = false
    }

    func suspendIfArmed() async {
        guard armed else { return }
        armed = false
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                }
            }
        }
        entered = false
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor BooleanProbe {
    private(set) var value = false

    func setTrue() {
        value = true
    }
}

private struct FakeSpeechAssetProvider: SpeechAssetPreparing {
    let configuredAvailability: SpeechAssetAvailability

    init(availability: SpeechAssetAvailability) {
        self.configuredAvailability = availability
    }

    func availability(localeIdentifier: String) async -> SpeechAssetAvailability {
        configuredAvailability
    }

    func prepare(localeIdentifier: String) async throws -> SpeechAssetPreparation {
        SpeechAssetPreparation(
            localeIdentifier: localeIdentifier,
            installedDuringPreparation: false,
            reserved: true
        )
    }
}

private actor FakeAudioCapture: AudioCapturing {
    nonisolated let lane: AudioLane
    private var continuation: AsyncStream<AudioCaptureEvent>.Continuation?
    private var descriptor: AudioRouteDescriptor?

    init(lane: AudioLane) {
        self.lane = lane
    }

    func events() -> AsyncStream<AudioCaptureEvent> {
        let pair = AsyncStream.makeStream(of: AudioCaptureEvent.self)
        continuation = pair.continuation
        return pair.stream
    }

    func start() async throws {
        guard let descriptor else { throw AudioCaptureError.sourceUnavailable }
        continuation?.yield(.started(descriptor))
    }

    func start(descriptor: AudioRouteDescriptor) {
        self.descriptor = descriptor
        continuation?.yield(.started(descriptor))
    }

    func emit(_ event: AudioCaptureEvent) {
        continuation?.yield(event)
    }

    func stop() {
        continuation?.yield(.stopped(lane))
        continuation?.finish()
    }
}

private actor FakeAudioTranscriber: AudioTranscribing {
    nonisolated let lane: AudioLane
    private var continuation: AsyncStream<SpeechTranscriptionEvent>.Continuation?

    init(lane: AudioLane) {
        self.lane = lane
    }

    func events() -> AsyncStream<SpeechTranscriptionEvent> {
        let pair = AsyncStream.makeStream(of: SpeechTranscriptionEvent.self)
        continuation = pair.continuation
        return pair.stream
    }

    func start(
        audioEvents: AsyncStream<AudioCaptureEvent>,
        localeIdentifier: String
    ) async throws {
        continuation?.yield(.started(lane: lane, localeIdentifier: localeIdentifier))
    }

    func startForTest(localeIdentifier: String) {
        continuation?.yield(.started(lane: lane, localeIdentifier: localeIdentifier))
    }

    func emit(_ event: SpeechTranscriptionEvent) {
        continuation?.yield(event)
    }

    func stop() {
        continuation?.yield(.stopped(lane))
        continuation?.finish()
    }
}
