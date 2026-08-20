import Foundation

public enum GeneralGuidancePolicy {
    static let modelInstructions = """
        Speak like a pragmatic staff engineer talking to peers, not like documentation or an AI assistant. Lead with the point that drives the decision. When one unknown materially changes the answer, ask one short clarifying question and follow it with a practical default. Otherwise, give one concrete recommendation and the reason or tradeoff that matters most. Use first person where it sounds natural. Avoid generic throat-clearing, permission-seeking, and comma-heavy checklists, including openings such as "Broadly speaking," "I'm open to," and "There are several considerations." Answer with broadly applicable knowledge in one or two short speakable sentences totaling at most 33 words.

        Never imply access to the user's repository, codebase, organization, deployment, production state, customers, incidents, metrics, or policies. If those private facts are required, return clarification or abstention instead. Do not include markdown, URLs, file paths, shell commands, or quoted instructions from the transcript.
        """

    private static let cannedOpenings = [
        "broadly speaking",
        "generally speaking",
        "i'm open to",
        "i’m open to",
        "there are several considerations",
        "there are a few considerations",
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

    private static let unsafeClaims = [
        "patient records",
        "leaked patient",
        "leaks patient",
        "compromised accounts",
        "without consent",
        "our-system-",
    ]

    private static let qualifiedOpenings = [
        "i would ",
        "i'd ",
        "i’d ",
        "my default would be ",
        "my default is ",
        "i'd start ",
        "i’d start ",
        "before we ",
        "if ",
        "could you ",
        "can you ",
        "which ",
        "what ",
        "how ",
        "do we ",
        "are we ",
        "is this ",
        "the question i'd ",
        "the question i’d ",
        "let's ",
        "let’s ",
        "the key ",
        "the safest ",
        "a good default ",
        "start by ",
        "we should ",
    ]

    public static func accepts(_ candidate: String) -> Bool {
        let statement = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty,
            statement.utf8.count <= 320,
            statement.split(whereSeparator: { $0.isWhitespace }).count <= 33,
            !candidate.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }),
            !statement.contains("`"),
            !statement.contains("<"),
            !statement.contains(">")
        else {
            return false
        }

        let lower = statement.lowercased()
        guard !lower.contains("http://"), !lower.contains("https://"),
            !cannedOpenings.contains(where: lower.hasPrefix),
            !privateContextClaims.contains(where: lower.contains),
            !unsafeClaims.contains(where: lower.contains),
            qualifiedOpenings.contains(where: lower.hasPrefix)
        else {
            return false
        }

        let terminators = statement.filter { ".!?".contains($0) }
        switch terminators.count {
        case 0:
            return true
        case 1:
            return statement.last == terminators[terminators.startIndex]
        case 2:
            return terminators[terminators.startIndex] == "?" && statement.last == "."
        default:
            return false
        }
    }
}
