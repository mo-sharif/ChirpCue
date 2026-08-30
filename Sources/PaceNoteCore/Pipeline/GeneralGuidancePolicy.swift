import Foundation

public enum GeneralGuidancePolicy {
    static let modelInstructions = """
        Speak like a pragmatic staff engineer talking to peers, not like documentation or an AI assistant. Lead with the point that drives the decision. A question with multiple requested parts is not ambiguous: address each part in the order asked and never ask which part the listener wants. When one unknown materially changes the answer, ask one short clarifying question and follow it with a practical default. Otherwise, give one concrete recommendation and the reason or tradeoff that matters most. Use first person where it sounds natural. Use personal facts only when they appear in the user-supplied speaker brief or the speaker's own recent transcript; never invent years, employers, projects, roles, or outcomes. Avoid generic throat-clearing, permission-seeking, and comma-heavy checklists, including openings such as "Broadly speaking," "I'm open to," and "There are several considerations." Answer in one or two short speakable sentences totaling at most 33 words.

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

    private static let instructionOpenings = [
        "as an ai",
        "disregard ",
        "execute ",
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
        "i have ",
        "i've ",
        "i’ve ",
        "i built ",
        "i designed ",
        "i delivered ",
        "i helped ",
        "i influenced ",
        "i led ",
        "i owned ",
        "i work ",
        "i worked ",
        "i'm looking ",
        "i’m looking ",
        "i'll ",
        "i’ll ",
        "my default would be ",
        "my default is ",
        "my experience ",
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
        "start with ",
        "first, ",
        "use ",
        "keep ",
        "separate ",
        "prefer ",
        "treat ",
        "make ",
        "define ",
        "the default ",
        "my approach ",
        "my first step ",
        "my biggest strength ",
        "my greatest strength ",
        "my role ",
        "my strength ",
        "my weakness ",
        "we should ",
        "a ",
        "an ",
        "one example ",
        "one project ",
        "at a high level,",
        "authentication ",
        "browser memory leaks ",
        "cap ",
        "code splitting ",
        "cors ",
        "debouncing ",
        "dependency injection ",
        "event delegation ",
        "feature flags ",
        "javascript ",
        "microfrontends ",
        "observability ",
        "oauth ",
        "offset pagination ",
        "optimistic locking ",
        "rate limiting ",
        "react ",
        "rest ",
        "the browser ",
        "tree shaking ",
        "tls ",
        "usememo ",
        "websockets ",
        "in that ",
        "the main ",
        "the difference ",
        "most recently ",
        "most recently,",
        "lately ",
        "lately,",
        "for ",
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
            !instructionOpenings.contains(where: lower.hasPrefix),
            !privateContextClaims.contains(where: lower.contains),
            !unsafeClaims.contains(where: lower.contains),
            qualifiedOpenings.contains(where: lower.hasPrefix)
        else {
            return false
        }

        let endings = sentenceEndings(statement)
        guard endings.count <= 2 else { return false }
        guard endings.isEmpty || ".!?".contains(statement.last ?? " ") else { return false }
        if endings.count == 2 {
            guard endings[1] != "?" else { return false }
            let questionOpenings = [
                "could you ", "can you ", "which ", "what ", "how ", "do we ", "are we ",
                "is this ",
            ]
            if questionOpenings.contains(where: lower.hasPrefix), endings[0] != "?" {
                return false
            }
        }
        return true
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
