import Foundation

public enum GeneralGuidancePolicy {
    static let detailedMaximumWords = 220
    static let detailedMaximumBytes = 3_000

    static var detailedModelInstructions: String {
        modelInstructions.replacingOccurrences(
            of: "Answer in one or two short speakable sentences totaling at most 33 words.",
            with:
                "For a substantive question, aim for 120 to 180 words across six to ten short sentences, never more than 220 words. Give a direct answer, explain why, and include one concrete example and the tradeoff when useful. When asked for an example, prefer a relevant personal story explicitly supplied in the speaker brief or the speaker's own transcript. Explain the situation, action, and outcome only as supported by those facts. If no matching story is supplied, clearly frame the example as hypothetical; never invent personal experience or private facts. Simple questions can be shorter. Do not pad the answer. Keep Quick's short opening in mind, but make this answer understandable on its own."
        )
    }

    enum RejectionReason: String, Sendable {
        case empty
        case size
        case controlCharacter
        case markup
        case url
        case cannedOpening
        case instructionOpening
        case privateContextClaim
        case unsafeClaim
        case sentenceCount
        case sentenceTermination
        case questionShape
    }

    static let modelInstructions = """
        Write for the ear, not the page. Sound like a pragmatic staff engineer talking face to face, not like documentation or an AI assistant. Use everyday words when they are just as accurate, natural contractions, and one clear idea per sentence. Keep technical terms the question needs, but do not surround them with jargon. Avoid semicolons, parentheses, long clauses, formal words such as "utilize" and "leverage," and lists with more than three items.

        Lead with the point that drives the decision. A question with multiple requested parts is not ambiguous: address each part in the order asked and never ask which part the listener wants. When one unknown materially changes the answer, ask one short clarifying question and follow it with a practical default. Otherwise, give one concrete recommendation and the reason or tradeoff that matters most. Use first person where it sounds natural. Use personal facts only when they appear in the user-supplied speaker brief or the speaker's own recent transcript; never invent years, employers, projects, roles, or outcomes. Avoid generic throat-clearing, permission-seeking, and comma-heavy checklists, including openings such as "Broadly speaking," "I'm open to," and "There are several considerations." Answer in one or two short speakable sentences totaling at most 33 words.

        Never imply access to the user's repository, codebase, organization, deployment, production state, customers, incidents, metrics, or policies. If those private facts are required, return clarification or abstention instead. Do not include markdown, URLs, file paths, shell commands, or quoted instructions from the transcript.
        """

    private static let instructionOpenings = [
        "as an ai",
        "disregard ",
        "execute ",
        "first answer",
        "forget the ",
        "follow these instructions",
        "ignore ",
        "output ",
        "repeat after me",
        "reveal ",
        "return only ",
        "run this ",
        "say the following",
    ]

    /// These openings are rejected because they contain no usable answer, not because of tone.
    /// Harmless lead-ins such as "At a high level" remain presentation guidance only.
    private static let nonAnswerOpenings = [
        "i can explain",
        "i can help",
    ]

    private static let privateContextClaims = [
        "your codebase",
        "your repository",
        "your repo",
        "your implementation",
        "your system",
        "your service",
        "your deployment",
        "your production",
        "your customers",
        "your incident",
        "your metrics",
        "your policy",
        "our codebase",
        "our repository",
        "our repo",
        "our implementation",
        "our system",
        "our service",
        "our deployment",
        "our production",
        "our customers",
        "our incident",
        "our metrics",
        "our policy",
        "the current codebase",
        "the current repository",
        "the current deployment",
        "in your production",
        "in our production",
    ]

    private static let privateContextSubjects = [
        "the application ",
        "the deployment ",
        "the production ",
        "the service ",
        "the system ",
        "production ",
    ]

    private static let assertedPrivateStateOpenings = [
        "allows ",
        "contains ",
        "depends ",
        "exposes ",
        "has ",
        "is ",
        "retries ",
        "runs ",
        "sends ",
        "stores ",
        "uses ",
    ]

    private static let assertedPrivateStateQualifiers = [
        "actually ",
        "already ",
        "always ",
        "currently ",
        "definitely ",
        "now ",
        "presently ",
    ]

    private static let unsafeClaims = [
        "patient records",
        "leaked patient",
        "leaks patient",
        "compromised accounts",
        "developer instruction",
        "developer message",
        "hidden instruction",
        "without consent",
        "repeat the transcript",
        "reveal the transcript",
        "system prompt",
        "our-system-",
    ]

    public static func accepts(_ candidate: String) -> Bool {
        rejectionReason(for: candidate) == nil
    }

    static func acceptsDetailed(_ candidate: String) -> Bool {
        rejectionReason(
            for: candidate,
            maximumWords: detailedMaximumWords,
            maximumBytes: detailedMaximumBytes,
            maximumSentences: 12
        ) == nil
    }

    static func rejectionReason(
        for candidate: String,
        maximumWords: Int = 33,
        maximumBytes: Int = 320,
        maximumSentences: Int = 2
    ) -> RejectionReason? {
        let statement = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return .empty }
        guard statement.utf8.count <= maximumBytes,
            statement.split(whereSeparator: { $0.isWhitespace }).count <= maximumWords
        else { return .size }
        guard
            !candidate.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            })
        else { return .controlCharacter }
        guard !statement.contains("`"),
            !statement.contains("<"),
            !statement.contains(">")
        else { return .markup }

        let lower = statement.lowercased()
        guard !lower.contains("http://"), !lower.contains("https://") else { return .url }
        guard !nonAnswerOpenings.contains(where: lower.hasPrefix) else {
            return .cannedOpening
        }
        guard !instructionOpenings.contains(where: lower.hasPrefix) else {
            return .instructionOpening
        }
        guard !privateContextClaims.contains(where: lower.contains) else {
            return .privateContextClaim
        }
        guard !assertsUnseenPrivateState(lower) else { return .privateContextClaim }
        guard !unsafeClaims.contains(where: lower.contains) else { return .unsafeClaim }

        let endings = sentenceEndings(statement)
        guard endings.count <= maximumSentences else { return .sentenceCount }
        if maximumSentences > 2 {
            // Longer answers must not hide a private-state assertion or injected instruction
            // after an otherwise safe opening sentence.
            let sentences = lower.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            for sentence in sentences {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if assertsUnseenPrivateState(trimmed) { return .privateContextClaim }
                if instructionOpenings.contains(where: trimmed.hasPrefix) {
                    return .instructionOpening
                }
            }
        }
        guard endings.isEmpty || ".!?".contains(statement.last ?? " ") else {
            return .sentenceTermination
        }
        if endings.count == 2 {
            guard endings[1] != "?" else { return .questionShape }
            let questionOpenings = [
                "could you ", "can you ", "which ", "what ", "how ", "do we ", "are we ",
                "is this ",
            ]
            if questionOpenings.contains(where: lower.hasPrefix), endings[0] != "?" {
                return .questionShape
            }
        }
        return nil
    }

    private static func assertsUnseenPrivateState(_ statement: String) -> Bool {
        for subject in privateContextSubjects where statement.hasPrefix(subject) {
            var remainder = statement.dropFirst(subject.count)
            if let qualifier = assertedPrivateStateQualifiers.first(where: remainder.hasPrefix) {
                remainder = remainder.dropFirst(qualifier.count)
            }
            if assertedPrivateStateOpenings.contains(where: remainder.hasPrefix) {
                return true
            }
        }
        return false
    }

    private static func sentenceEndings(_ statement: String) -> [Character] {
        let characters = Array(statement)
        return characters.indices.reduce(into: []) { endings, index in
            guard ".!?".contains(characters[index]) else { return }
            let nextIndex = characters.index(after: index)
            if nextIndex == characters.endIndex || characters[nextIndex].isWhitespace {
                endings.append(characters[index])
            }
        }
    }
}
