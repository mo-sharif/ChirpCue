import AVFoundation
import CoreMedia
import XCTest

@testable import PaceNoteCore

final class AudioClockTransformTests: XCTestCase {
    func testThirtyMinuteProductionSpeechTimelineMapsPlusMinusOneHundredPPMWithoutAccumulation()
        throws
    {
        let durationSeconds = 30 * 60
        let nominalSampleRate = 48_000.0
        let framesPerObservation: UInt32 = 48_000
        let analyzerSampleRate = 16_000.0
        let analyzerFramesPerObservation: AVAudioFrameCount = 16_000
        let microphoneRate = nominalSampleRate * (1 + 100.0 / 1_000_000)
        let outputRate = nominalSampleRate * (1 - 100.0 / 1_000_000)
        let microphoneLatency = 0.035
        let outputLatency = 0.010
        let jitterPattern = [-0.0015, 0.0005, 0.001, -0.0005, 0.0015, -0.001]
        var microphoneTimeline = SpeechAudioClockTimeline()
        var outputTimeline = SpeechAudioClockTimeline()
        var rawSkews: [TimeInterval] = []
        var mappedSkews: [TimeInterval] = []
        var maximumForwardCorrection = 0.0

        for second in 0...durationSeconds {
            let framePosition = Double(second) * nominalSampleRate
            let jitter = jitterPattern[second % jitterPattern.count]
            let microphoneHost = framePosition / microphoneRate + microphoneLatency + jitter
            let outputHost = framePosition / outputRate + outputLatency - jitter

            let microphoneSchedule = try microphoneTimeline.schedule(
                hostTime: hostTimestamp(seconds: microphoneHost),
                sourceFrameCount: framesPerObservation,
                sourceSampleRate: nominalSampleRate,
                analyzerFrameCount: analyzerFramesPerObservation,
                analyzerSampleRate: analyzerSampleRate
            )
            let outputSchedule = try outputTimeline.schedule(
                hostTime: hostTimestamp(seconds: outputHost),
                sourceFrameCount: framesPerObservation,
                sourceSampleRate: nominalSampleRate,
                analyzerFrameCount: analyzerFramesPerObservation,
                analyzerSampleRate: analyzerSampleRate
            )
            maximumForwardCorrection = max(
                maximumForwardCorrection,
                max(
                    microphoneSchedule.forwardCorrection,
                    outputSchedule.forwardCorrection
                )
            )

            guard second >= 10 else { continue }
            let truthSeconds = Double(second)
            let microphoneMarkerFrame = truthSeconds * microphoneRate
            let outputMarkerFrame = truthSeconds * outputRate
            let microphoneRange = CMTimeRange(
                start: CMTime(
                    seconds: microphoneMarkerFrame / nominalSampleRate,
                    preferredTimescale: 1_000_000_000
                ),
                duration: CMTime(seconds: 0.25, preferredTimescale: 1_000_000_000)
            )
            let outputRange = CMTimeRange(
                start: CMTime(
                    seconds: outputMarkerFrame / nominalSampleRate,
                    preferredTimescale: 1_000_000_000
                ),
                duration: CMTime(seconds: 0.25, preferredTimescale: 1_000_000_000)
            )
            let mappedMicrophone = try microphoneTimeline.mapResultRangeToHostTime(
                microphoneRange
            )
            let mappedOutput = try outputTimeline.mapResultRangeToHostTime(outputRange)
            mappedSkews.append(abs(mappedMicrophone.start.seconds - mappedOutput.start.seconds))

            let rawMicrophone = microphoneLatency + microphoneMarkerFrame / nominalSampleRate
            let rawOutput = outputLatency + outputMarkerFrame / nominalSampleRate
            rawSkews.append(abs(rawMicrophone - rawOutput))
        }

        XCTAssertLessThanOrEqual(maximumForwardCorrection, 0.000_001)
        XCTAssertGreaterThan(try XCTUnwrap(percentile95(rawSkews)), 0.080)
        XCTAssertLessThanOrEqual(try XCTUnwrap(percentile95(mappedSkews)), 0.080)
    }

    func testClockDiscontinuityResetsTheSlidingTransform() {
        var transform = AudioClockTransform()

        XCTAssertAccepted(
            transform.observe(
                hostTime: hostTimestamp(seconds: 10),
                frameCount: 48_000,
                sampleRate: 48_000
            )
        )
        XCTAssertAccepted(
            transform.observe(
                hostTime: hostTimestamp(seconds: 11),
                frameCount: 48_000,
                sampleRate: 48_000
            )
        )
        XCTAssertEqual(
            transform.observe(
                hostTime: hostTimestamp(seconds: 10.5),
                frameCount: 48_000,
                sampleRate: 48_000
            ),
            .discontinuity
        )

        XCTAssertAccepted(
            transform.observe(
                hostTime: hostTimestamp(seconds: 11.5),
                frameCount: 48_000,
                sampleRate: 48_000
            )
        )
    }

    func testAnalyzerTimelineCorrectsOnlyBoundedConversionOverlap() throws {
        var timeline = AnalyzerInputTimeline(
            configuration: .init(maximumForwardCorrection: 0.005)
        )
        let first = try timeline.schedule(
            rawStartTime: .zero,
            frameCount: 160,
            sampleRate: 16_000
        )
        let second = try timeline.schedule(
            rawStartTime: CMTime(seconds: 0.009, preferredTimescale: 1_000_000_000),
            frameCount: 160,
            sampleRate: 16_000
        )

        XCTAssertEqual(first.startTime.seconds, 0, accuracy: 0.000_001)
        XCTAssertEqual(first.endTime.seconds, 0.010, accuracy: 0.000_001)
        XCTAssertEqual(second.startTime.seconds, 0.010, accuracy: 0.000_001)
        XCTAssertEqual(second.forwardCorrection, 0.001, accuracy: 0.000_001)

        XCTAssertThrowsError(
            try timeline.schedule(
                rawStartTime: .zero,
                frameCount: 160,
                sampleRate: 16_000
            )
        ) { error in
            XCTAssertEqual(error as? AnalyzerInputTimelineError, .excessiveCorrection)
        }
    }

    func testAttributionFailsClosedWithoutBothHostRanges() {
        let resolver = TranscriptAttributionResolver()
        let output = transcript(lane: .output, range: nil)
        let microphone = transcript(lane: .microphone, range: nil)

        XCTAssertEqual(
            resolver.resolveMicrophone(
                microphone,
                receivedAt: 10.01,
                against: output,
                receivedAt: 10
            ),
            .attribute(source: .unknown, speakerUncertain: true)
        )
    }

    func testAttributionUsesVerifiedHostRangesInsteadOfReceiptOrder() {
        let resolver = TranscriptAttributionResolver()
        let start = hostTimestamp(seconds: 50)
        let range = HostTimeRange(start: start, end: start.advanced(by: 1))
        let output = transcript(lane: .output, range: range)
        let microphone = transcript(lane: .microphone, range: range)

        XCTAssertEqual(
            resolver.resolveMicrophone(
                microphone,
                receivedAt: 20,
                against: output,
                receivedAt: 10
            ),
            .suppressEcho
        )
    }

    private func hostTimestamp(seconds: TimeInterval) -> HostTimestamp {
        HostTimestamp(ticks: AVAudioTime.hostTime(forSeconds: seconds))
    }

    private func percentile95(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int(ceil(Double(sorted.count) * 0.95))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    private func transcript(
        lane: AudioLane,
        range: HostTimeRange?
    ) -> ProgressiveTranscriptResult {
        ProgressiveTranscriptResult(
            lane: lane,
            text: "The same loopback phrase",
            hostTimeRange: range,
            stability: .final,
            confidence: 0.95
        )
    }

    private func XCTAssertAccepted(
        _ observation: AudioClockObservation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .accepted = observation else {
            return XCTFail("Expected an accepted clock observation", file: file, line: line)
        }
    }
}
