import Foundation
import XCTest

@testable import PaceNoteCore

final class ClaudeStructuredOutputTests: XCTestCase {
    private let turnID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    func testDecodesStrictStructuredOutputAndIgnoresEnvelopeMetadata() throws {
        let data = try envelope(
            structuredOutput: draftObject(),
            extraEnvelope: ["session_id": "discard-me", "total_cost_usd": 99]
        )

        let draft = try ClaudeStructuredOutput.decode(data, as: DeepDraft.self)
        XCTAssertEqual(draft.turnID, turnID)
        XCTAssertEqual(draft.kind, .generalAnswer)
        XCTAssertEqual(draft.candidateSayNext, "We should clarify the requirements before choosing a design.")
    }

    func testRejectsFailureTurnCountPermissionAttemptsAndMissingOutput() throws {
        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(
                envelope(structuredOutput: draftObject(), subtype: "error_max_structured_output_retries"),
                as: DeepDraft.self
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeStructuredOutputError,
                .unsuccessfulResult("error_max_structured_output_retries")
            )
        }

        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(
                envelope(structuredOutput: draftObject(), numTurns: 2),
                as: DeepDraft.self
            )
        ) { XCTAssertEqual($0 as? ClaudeStructuredOutputError, .unexpectedTurnCount) }

        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(
                envelope(
                    structuredOutput: draftObject(),
                    extraEnvelope: ["permission_denials": [["tool": "Read"]]]
                ),
                as: DeepDraft.self
            )
        ) { XCTAssertEqual($0 as? ClaudeStructuredOutputError, .permissionAttempted) }

        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(
                envelope(structuredOutput: nil),
                as: DeepDraft.self
            )
        ) { XCTAssertEqual($0 as? ClaudeStructuredOutputError, .missingStructuredOutput) }
    }

    func testRejectsAdditionalStructuredKeysMalformedAndOversizedData() throws {
        var output = draftObject()
        output["unexpected"] = true
        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(
                envelope(structuredOutput: output),
                as: DeepDraft.self
            )
        ) { XCTAssertEqual($0 as? ClaudeStructuredOutputError, .invalidEnvelope) }

        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(Data("not-json".utf8), as: DeepDraft.self)
        ) { XCTAssertEqual($0 as? ClaudeStructuredOutputError, .invalidEnvelope) }

        XCTAssertThrowsError(
            try ClaudeStructuredOutput.decode(
                Data(repeating: 65, count: 1_025),
                as: DeepDraft.self,
                maximumBytes: 1_024
            )
        ) { XCTAssertEqual($0 as? ClaudeStructuredOutputError, .outputTooLarge) }
    }

    private func draftObject() -> [String: Any] {
        [
            "turnID": turnID.uuidString,
            "generation": 3,
            "groundingFingerprint": NSNull(),
            "kind": "general_answer",
            "candidateSayNext": "We should clarify the requirements before choosing a design.",
            "confidence": 0.8,
            "basis": [],
            "missingEvidence": [],
        ]
    }

    private func envelope(
        structuredOutput: [String: Any]?,
        subtype: String = "success",
        numTurns: Int = 1,
        extraEnvelope: [String: Any] = [:]
    ) throws -> Data {
        var value: [String: Any] = [
            "type": "result",
            "subtype": subtype,
            "is_error": subtype != "success",
            "num_turns": numTurns,
            "permission_denials": [],
        ]
        value["structured_output"] = structuredOutput ?? NSNull()
        for (key, nested) in extraEnvelope { value[key] = nested }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
