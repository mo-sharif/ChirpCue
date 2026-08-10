import AVFoundation
import CoreAudio
import XCTest

@testable import PaceNoteCore

final class SpeechAnalyzerProductionSmokeTests: XCTestCase {
    func testTwoConcurrentProductionTranscribersAcceptContiguousSyntheticAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PACENOTE_RUN_SPEECH_ANALYZER_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set PACENOTE_RUN_SPEECH_ANALYZER_SMOKE=1 and provide PACENOTE_SYNTHETIC_SPEECH_FIXTURE."
            )
        }
        let fixturePath = try XCTUnwrap(environment["PACENOTE_SYNTHETIC_SPEECH_FIXTURE"])
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixture = try Self.readFixture(fixtureURL)
        XCTAssertFalse(fixture.isEmpty)

        let assets = InstalledSpeechAssetProvider()
        let output = AppleSpeechTranscriptionService(lane: .output, assets: assets)
        let microphone = AppleSpeechTranscriptionService(lane: .microphone, assets: assets)
        let outputCapture = AsyncStream.makeStream(
            of: AudioCaptureEvent.self,
            bufferingPolicy: .unbounded
        )
        let microphoneCapture = AsyncStream.makeStream(
            of: AudioCaptureEvent.self,
            bufferingPolicy: .unbounded
        )
        let outputEvents = await output.events()
        let microphoneEvents = await microphone.events()

        do {
            async let outputStart: Void = output.start(
                audioEvents: outputCapture.stream,
                localeIdentifier: "en-US"
            )
            async let microphoneStart: Void = microphone.start(
                audioEvents: microphoneCapture.stream,
                localeIdentifier: "en-US"
            )
            _ = try await (outputStart, microphoneStart)

            let outputConsumer = SpeechOutcomeConsumer(stream: outputEvents)
            let microphoneConsumer = SpeechOutcomeConsumer(stream: microphoneEvents)
            let outputOutcome = Task { await outputConsumer.firstOutcome() }
            let microphoneOutcome = Task { await microphoneConsumer.firstOutcome() }
            let baseHostTime = HostTimestamp.now
            var elapsed: TimeInterval = 0

            for item in fixture {
                let hostTime = baseHostTime.advanced(by: elapsed)
                outputCapture.continuation.yield(
                    .audio(item.chunk(lane: .output, hostTime: hostTime))
                )
                microphoneCapture.continuation.yield(
                    .audio(item.chunk(lane: .microphone, hostTime: hostTime))
                )
                elapsed += item.duration
                try await Task.sleep(for: .milliseconds(20))
            }

            let outcomes = await (outputOutcome.value, microphoneOutcome.value)
            await output.stop()
            await microphone.stop()
            outputCapture.continuation.finish()
            microphoneCapture.continuation.finish()

            XCTAssertEqual(outcomes.0, .transcript)
            XCTAssertEqual(outcomes.1, .transcript)
        } catch {
            await output.stop()
            await microphone.stop()
            outputCapture.continuation.finish()
            microphoneCapture.continuation.finish()
            throw error
        }
    }

    private static func readFixture(_ url: URL) throws -> [SyntheticAudioItem] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCapacity: AVAudioFrameCount = 2_048
        var items: [SyntheticAudioItem] = []

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(Int64(frameCapacity), remaining))
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested)
            )
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { break }
            items.append(try SyntheticAudioItem(buffer: buffer))
        }
        return items
    }
}

private enum SmokeOutcome: Equatable, Sendable {
    case transcript
    case failure(SpeechTranscriptionFailure)
    case timeout
    case ended
}

private actor SpeechOutcomeConsumer {
    let stream: AsyncStream<SpeechTranscriptionEvent>

    init(stream: AsyncStream<SpeechTranscriptionEvent>) {
        self.stream = stream
    }

    func firstOutcome() async -> SmokeOutcome {
        await withTaskGroup(of: SmokeOutcome.self) { group in
            group.addTask { [stream] in
                for await event in stream {
                    switch event {
                    case .result:
                        return .transcript
                    case .failed(_, let reason):
                        return .failure(reason)
                    default:
                        continue
                    }
                }
                return .ended
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .timeout
            }
            let outcome = await group.next() ?? .ended
            group.cancelAll()
            return outcome
        }
    }
}

private struct InstalledSpeechAssetProvider: SpeechAssetPreparing {
    func availability(localeIdentifier _: String) async -> SpeechAssetAvailability {
        .installed
    }

    func prepare(localeIdentifier: String) async throws -> SpeechAssetPreparation {
        SpeechAssetPreparation(
            localeIdentifier: localeIdentifier,
            installedDuringPreparation: false,
            reserved: true
        )
    }
}

private struct SyntheticAudioItem: Sendable {
    let frameCount: UInt32
    let format: AudioFormatDescription
    let planes: [CapturedAudioPlane]

    init(buffer: AVAudioPCMBuffer) throws {
        frameCount = buffer.frameLength
        format = AudioFormatDescription(buffer.format)
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        planes = try buffers.map { source in
            guard let data = source.mData else {
                throw SpeechTranscriptionError.invalidAudioBuffer
            }
            return CapturedAudioPlane(
                channelCount: source.mNumberChannels,
                data: Data(bytes: data, count: Int(source.mDataByteSize))
            )
        }
    }

    var duration: TimeInterval {
        Double(frameCount) / format.sampleRate
    }

    func chunk(lane: AudioLane, hostTime: HostTimestamp) -> CapturedAudioChunk {
        CapturedAudioChunk(
            lane: lane,
            hostTime: hostTime,
            frameCount: frameCount,
            format: format,
            planes: planes
        )
    }
}
