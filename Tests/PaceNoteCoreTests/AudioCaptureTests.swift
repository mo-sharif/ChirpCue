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
}

private actor FakeMicrophonePermissionProvider: MicrophonePermissionProviding {
    private let configuredStatus: AudioPermissionStatus
    private var requests = 0

    init(status: AudioPermissionStatus) {
        self.configuredStatus = status
    }

    func status() async -> AudioPermissionStatus {
        configuredStatus
    }

    func request() async -> AudioPermissionStatus {
        requests += 1
        return configuredStatus
    }

    func requestCount() -> Int {
        requests
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
