import Foundation

/// Shared shape and trust-boundary validation for every subscription provider.
enum DeepDraftValidationPolicy {
    static func accepts(_ draft: DeepDraft, for turn: ConversationTurn) -> Bool {
        guard hasValidShape(draft, for: turn) else { return false }

        switch draft.kind {
        case .answer:
            guard let expectedFingerprint = turn.groundingFingerprint else { return false }
            return draft.groundingFingerprint == expectedFingerprint && !draft.basis.isEmpty
        case .generalAnswer:
            return draft.groundingFingerprint == nil
                && draft.basis.isEmpty
                && GeneralGuidancePolicy.accepts(draft.candidateSayNext)
        case .clarification, .abstention:
            return draft.groundingFingerprint == turn.groundingFingerprint && draft.basis.isEmpty
        }
    }

    /// Repairs only trust-neutral metadata mistakes. It never converts a claim with evidence into
    /// general guidance, and the candidate must independently pass the ungrounded policy.
    static func normalized(_ draft: DeepDraft, for turn: ConversationTurn) -> DeepDraft? {
        if accepts(draft, for: turn) { return draft }
        guard hasValidShape(draft, for: turn),
            draft.basis.isEmpty,
            draft.kind == .answer || draft.kind == .generalAnswer,
            GeneralGuidancePolicy.accepts(draft.candidateSayNext)
        else {
            return nil
        }
        return DeepDraft(
            turnID: draft.turnID,
            generation: draft.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: draft.candidateSayNext,
            confidence: min(draft.confidence, 0.75),
            basis: [],
            missingEvidence: draft.missingEvidence
        )
    }

    private static func hasValidShape(_ draft: DeepDraft, for turn: ConversationTurn) -> Bool {
        draft.turnID == turn.identity.turnID
            && draft.generation == turn.identity.generation
            && !draft.candidateSayNext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.candidateSayNext.contains("\0")
            && draft.candidateSayNext.utf8.count <= 320
            && wordCount(draft.candidateSayNext) <= 33
            && draft.confidence.isFinite
            && (0...1).contains(draft.confidence)
            && draft.basis.count <= 6
            && draft.missingEvidence.count <= 4
            && draft.missingEvidence.allSatisfy({
                !$0.contains("\0") && $0.utf8.count <= 320
            })
            && (turn.repoAlias != nil) == (turn.groundingFingerprint != nil)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
