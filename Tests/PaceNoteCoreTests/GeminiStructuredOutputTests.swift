import Foundation
import XCTest

@testable import PaceNoteCore

final class GeminiStructuredOutputTests: XCTestCase {
    private let turnID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!

    func testDecodesObjectAndStringResponses() throws {
        let object = draftObject()
        let objectEnvelope: [String: Any] = [
            "status": "SUCCESS", "response": object, "num_turns": 1,
        ]
        let objectDraft = try GeminiStructuredOutput.decode(
            JSONSerialization.data(withJSONObject: objectEnvelope),
            as: DeepDraft.self
        )
        XCTAssertEqual(objectDraft.turnID, turnID)

        let nested = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let textEnvelope: [String: Any] = [
            "status": "SUCCESS", "response": String(decoding: nested, as: UTF8.self),
            "num_turns": 1,
        ]
        let textDraft = try GeminiStructuredOutput.decode(
            JSONSerialization.data(withJSONObject: textEnvelope),
            as: DeepDraft.self
        )
        XCTAssertEqual(textDraft.candidateSayNext, "I would clarify which data paths require access first.")
    }

    func testRejectsFailureMalformedAndUnexpectedTurnCount() throws {
        XCTAssertThrowsError(
            try GeminiStructuredOutput.decode(
                Data(#"{"status":"ERROR","error":"private details"}"#.utf8),
                as: DeepDraft.self
            )
        ) { XCTAssertEqual($0 as? GeminiStructuredOutputError, .unsuccessfulResult) }
        XCTAssertThrowsError(
            try GeminiStructuredOutput.decode(Data("not-json".utf8), as: DeepDraft.self)
        ) { XCTAssertEqual($0 as? GeminiStructuredOutputError, .invalidEnvelope) }
        let envelope: [String: Any] = [
            "status": "SUCCESS", "response": draftObject(), "num_turns": 5,
        ]
        XCTAssertThrowsError(
            try GeminiStructuredOutput.decode(
                JSONSerialization.data(withJSONObject: envelope),
                as: DeepDraft.self
            )
        ) { XCTAssertEqual($0 as? GeminiStructuredOutputError, .unexpectedTurnCount) }
    }

    private func draftObject() -> [String: Any] {
        [
            "turnID": turnID.uuidString,
            "generation": 1,
            "groundingFingerprint": NSNull(),
            "kind": "general_answer",
            "candidateSayNext": "I would clarify which data paths require access first.",
            "confidence": 0.8,
            "basis": [],
            "missingEvidence": [],
        ]
    }
}
