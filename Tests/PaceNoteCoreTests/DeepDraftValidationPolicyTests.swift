import XCTest

@testable import PaceNoteCore

final class DeepDraftValidationPolicyTests: XCTestCase {
    func testNaturalTwoSentencePersonalAnswerPassesForExactReportedQuestion() {
        let turn = makeTurn(grounded: false)
        let draft = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext:
                "I’ve worked with React for eight years across production web applications. Lately, I’ve focused on TypeScript AI products and frontend platforms.",
            confidence: 0.84,
            basis: []
        )

        XCTAssertTrue(DeepDraftValidationPolicy.accepts(draft, for: turn))
    }

    func testGroundedTurnAcceptsGeneralAnswerOnlyAsExplicitlyUngrounded() throws {
        let turn = makeTurn(grounded: true)
        let draft = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext:
                "I’ve worked with React for eight years. Lately, I’ve focused on TypeScript products and reusable frontend architecture.",
            confidence: 0.84,
            basis: []
        )

        let normalized = try XCTUnwrap(DeepDraftValidationPolicy.normalized(draft, for: turn))
        XCTAssertEqual(normalized.kind, .generalAnswer)
        XCTAssertNil(normalized.groundingFingerprint)
    }

    func testSafeAnswerWithoutEvidenceIsRelabeledInsteadOfRejected() throws {
        let turn = makeTurn(grounded: false)
        let mislabeled = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .answer,
            candidateSayNext: "I would start with the direct answer, then give one recent example.",
            confidence: 0.91,
            basis: []
        )

        let normalized = try XCTUnwrap(
            DeepDraftValidationPolicy.normalized(mislabeled, for: turn)
        )
        XCTAssertEqual(normalized.kind, .generalAnswer)
        XCTAssertEqual(normalized.confidence, 0.75)
    }

    func testEvidenceBearingAnswerIsNeverRelabeledAsGeneralGuidance() {
        let turn = makeTurn(grounded: true)
        let invalid = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: "wrong",
            kind: .answer,
            candidateSayNext: "I would claim this came from the repository.",
            confidence: 0.8,
            basis: [
                EvidenceReference(
                    repoAlias: "repo",
                    relativePath: "README.md",
                    startLine: 1,
                    endLine: 1,
                    fileHash: String(repeating: "a", count: 64),
                    claim: "I would claim this came from the repository."
                )
            ]
        )

        XCTAssertNil(DeepDraftValidationPolicy.normalized(invalid, for: turn))
    }

    private func makeTurn(grounded: Bool) -> ConversationTurn {
        ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: 1),
            question:
                "How many years have you had with React JS, and what kind of applications have you been working on lately?",
            recentTranscript: [],
            speakerBrief: "Eight years with React; lately building TypeScript AI products.",
            repoAlias: grounded ? "repo" : nil,
            groundingFingerprint: grounded ? "fingerprint" : nil
        )
    }
}
