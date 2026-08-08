import Foundation

public enum GeneralGuidancePolicy {
    static let approvedQualifiers = [
        "In general, ",
        "Broadly, ",
    ]

    static let approvedFrames = [
        "I would ",
        "We should ",
        "A practical approach is to ",
        "One option is to ",
    ]

    /// These clauses are intentionally closed. Repository-free model output is untrusted and
    /// cannot safely contribute arbitrary prose after an advisory-sounding prefix.
    static let approvedActionClauses = [
        "ask for the missing constraint before choosing a design",
        "assess the main tradeoffs before choosing a design",
        "bound retries with explicit limits",
        "clarify the requirements before choosing a design",
        "compare queueing against synchronous processing before selecting a design",
        "compare the main tradeoffs before choosing a design",
        "confirm privacy and security requirements before choosing a design",
        "confirm the consistency requirement before choosing a storage pattern",
        "define the success criteria before choosing a design",
        "document rollback criteria before implementation",
        "document the key assumptions before implementation",
        "frame eventual consistency as a tradeoff between immediate agreement and availability",
        "identify the main failure modes before choosing a design",
        "isolate callers from retries and downstream outages with a queued boundary",
        "isolate downstream work from the caller with a queued boundary",
        "measure actual latency before choosing a design",
        "measure failure rates before selecting a recovery strategy",
        "measure throughput and latency before selecting a design",
        "prefer bounded attempts over unlimited attempts",
        "prioritize the simplest reversible option",
        "prototype the riskiest assumption first",
        "separate request acceptance from background processing",
        "separate the immediate decision from implementation details",
        "start with a small prototype before committing",
        "test failure handling before choosing a design",
        "test recovery behavior before choosing a design",
        "use a queue to decouple request acceptance from background processing",
        "validate the key assumptions before committing",
        "validate the latency target before selecting a design",
        "verify the relevant constraints before committing",
    ]

    static let modelInstructions: String = {
        let frames =
            approvedFrames
            .map { "- `\($0.trimmingCharacters(in: .whitespaces))`" }
            .joined(separator: "\n")
        let actions =
            approvedActionClauses
            .map { "- `\($0)`" }
            .joined(separator: "\n")
        return """
            Use exactly one sentence from this closed advisory grammar. Choose one frame exactly:
            \(frames)

            Then copy one approved action clause exactly:
            \(actions)

            You may prefix the complete frame and action with exactly `In general, ` or `Broadly, `, and you may add one final period. Do not add, remove, reorder, or paraphrase words. Do not use any other name, product, pronoun, capability, state, connector, clause, possessive, contraction, or punctuation. If no approved sentence safely answers the question, return clarification or abstention instead of general_answer.
            """
    }()

    public static func accepts(_ candidate: String) -> Bool {
        guard candidate.split(whereSeparator: { $0.isWhitespace }).count <= 33,
            let sentence = canonicalSentence(candidate)
        else {
            return false
        }

        var remainder = sentence
        if let qualifier = approvedQualifiers.first(where: {
            remainder.lowercased().hasPrefix($0.lowercased())
        }) {
            remainder.removeFirst(qualifier.count)
        }

        guard
            let frame = approvedFrames.first(where: {
                remainder.lowercased().hasPrefix($0.lowercased())
            })
        else {
            return false
        }
        remainder.removeFirst(frame.count)

        return approvedActionClauses.contains { remainder.caseInsensitiveCompare($0) == .orderedSame }
    }

    private static func canonicalSentence(_ candidate: String) -> String? {
        var sentence = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty,
            sentence.utf8.count <= 320,
            !candidate.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }),
            sentence.unicodeScalars.allSatisfy(isAllowedSentenceScalar)
        else {
            return nil
        }

        if sentence.hasSuffix(".") {
            sentence.removeLast()
            sentence = sentence.trimmingCharacters(in: .whitespaces)
        }
        guard !sentence.isEmpty, !sentence.contains(".") else { return nil }
        return sentence
    }

    private static func isAllowedSentenceScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
            || value == 32
            || value == 44
            || value == 46
    }
}
