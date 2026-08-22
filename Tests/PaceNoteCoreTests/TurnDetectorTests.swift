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

    func testCommonSpokenQuestionWithoutPunctuationTriggersAutomatically() {
        let questions = [
            "Where’s your plan for securing database access",
            "Talk me through the retry strategy",
            "Describe how you would isolate the service",
            "Have you handled a production incident",
            "Should we isolate this at the network boundary",
            "Outline the tradeoffs of the migration",
        ]

        for (index, question) in questions.enumerated() {
            var detector = TurnDetector()
            detector.observe(
                TranscriptSegment(
                    source: .them,
                    text: question,
                    startedAt: Double(index),
                    endedAt: Double(index + 1),
                    isFinal: true,
                    confidence: 0.9
                )
            )
            let expected = question.replacingOccurrences(of: "’", with: "'")
            XCTAssertEqual(detector.candidate(at: Double(index + 1))?.text, expected)
        }
    }

    func testShortDirectPromptTriggersAutomatically() {
        let prompts = ["Why us?", "Any concerns", "Thoughts?"]

        for prompt in prompts {
            var detector = TurnDetector()
            detector.observe(
                TranscriptSegment(
                    source: .them,
                    text: prompt,
                    startedAt: 1,
                    endedAt: 2,
                    isFinal: true,
                    confidence: 0.9
                )
            )

            XCTAssertEqual(detector.candidate(at: 2)?.text, prompt)
        }
    }

    func testFinalRevisionOfEmittedSegmentDoesNotTriggerSecondTurn() {
        var detector = TurnDetector(configuration: .init(minimumSilence: 0.45))
        let segmentID = UUID()
        detector.observe(
            TranscriptSegment(
                id: segmentID,
                source: .them,
                text: "How should we isolate database access",
                startedAt: 1,
                endedAt: 2,
                isFinal: false,
                confidence: 0.9
            )
        )

        XCTAssertNotNil(detector.candidate(at: 2.5))

        detector.observe(
            TranscriptSegment(
                id: segmentID,
                source: .them,
                text: "How should we isolate database access?",
                startedAt: 1,
                endedAt: 2.6,
                isFinal: true,
                confidence: 0.95
            )
        )

        XCTAssertNil(detector.candidate(at: 2.6))
    }

    func testMateriallyExpandedFinalRevisionOfEmittedSegmentTriggersCorrectedTurn() {
        var detector = TurnDetector(configuration: .init(minimumSilence: 0.45))
        let segmentID = UUID()
        detector.observe(
            TranscriptSegment(
                id: segmentID,
                source: .them,
                text: "How should we secure database access",
                startedAt: 1,
                endedAt: 2,
                isFinal: false,
                confidence: 0.9
            )
        )

        XCTAssertEqual(
            detector.candidate(at: 2.5)?.text,
            "How should we secure database access"
        )

        detector.observe(
            TranscriptSegment(
                id: segmentID,
                source: .them,
                text: "How should we secure database access through our MCP?",
                startedAt: 1,
                endedAt: 3,
                isFinal: true,
                confidence: 0.95
            )
        )

        XCTAssertEqual(
            detector.candidate(at: 3)?.text,
            "How should we secure database access through our MCP?"
        )
        XCTAssertNil(detector.candidate(at: 3.1))
    }
}
