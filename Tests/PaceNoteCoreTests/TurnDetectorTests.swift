import Foundation
import XCTest

@testable import PaceNoteCore

final class TurnDetectorTests: XCTestCase {
    func testOutputQuestionTriggersAfterStablePause() {
        var detector = TurnDetector(configuration: .init(minimumSilence: 0.45))
        let segment = TranscriptSegment(
            source: .output,
            text: "Why is the event pipeline asynchronous",
            startedAt: 10,
            endedAt: 12,
            isFinal: false,
            confidence: 0.9
        )
        detector.observe(segment)

        XCTAssertNil(detector.candidate(at: 12.2))
        XCTAssertEqual(detector.candidate(at: 12.5)?.text, segment.text)
        XCTAssertNil(detector.candidate(at: 13))
    }

    func testMicrophoneSpeechNeverBecomesRemoteQuestion() {
        var detector = TurnDetector()
        detector.observe(
            TranscriptSegment(
                source: .microphone,
                text: "Why did we do this?",
                startedAt: 1,
                endedAt: 2,
                isFinal: true,
                confidence: 1
            ))

        XCTAssertNil(detector.candidate(at: 3))
    }

    func testLowConfidenceQuestionIsSuppressed() {
        var detector = TurnDetector()
        detector.observe(
            TranscriptSegment(
                source: .them,
                text: "Could you explain the retry policy?",
                startedAt: 1,
                endedAt: 2,
                isFinal: true,
                confidence: 0.2
            ))

        XCTAssertNil(detector.candidate(at: 3))
    }

    func testForceAcceptsStableStatement() {
        var detector = TurnDetector()
        detector.observe(
            TranscriptSegment(
                source: .output,
                text: "Tell us about the operational tradeoff",
                startedAt: 1,
                endedAt: 2,
                isFinal: true,
                confidence: 0.9
            ))

        XCTAssertNotNil(detector.candidate(at: 2, force: true))
    }
}
