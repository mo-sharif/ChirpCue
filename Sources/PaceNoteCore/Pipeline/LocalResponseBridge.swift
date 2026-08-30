import Foundation

/// A bounded, question-aware opener that is available without waiting for a provider.
///
/// These responses intentionally stay generic: they help the user begin a consented
/// conversation without claiming private repository or organization facts.
public enum LocalResponseBridge {
    public static func requiresPersonalFacts(_ question: String) -> Bool {
        let normalized = normalize(question)
        return containsAny(
            normalized,
            [
                "how many years", "years of experience", "your experience", "have you had with",
                "have you worked with", "what have you been working on", "worked on lately",
                "working on lately", "what are you working on", "your background",
                "your most recent role", "tell me about yourself", "tell me about a time",
                "describe a time", "give me an example", "walk me through your",
                "walk me through a recent", "your greatest strength", "your strengths",
                "your weakness", "your weaknesses", "why should we hire you",
                "why are you interested", "why do you want", "what are you looking for",
                "what motivates you", "where do you see yourself", "why are you leaving",
                "why did you leave", "salary expectations",
            ]
        )
    }

    public static func response(for question: String) -> String {
        let normalized = normalize(question)

        if requiresPersonalFacts(question) {
            if containsAny(
                normalized,
                [
                    "tell me about a time", "describe a time", "give me an example",
                    "walk me through your", "walk me through a recent",
                ]
            ) {
                return
                    "I’ll anchor this in one concrete example, then make the decision, my role, and the outcome clear."
            }
            if containsAny(
                normalized,
                ["greatest strength", "your strengths", "your weakness", "your weaknesses"]
            ) {
                return
                    "I’ll give the honest headline first, then ground it in one recent example and what changed because of it."
            }
            if containsAny(
                normalized,
                [
                    "why should we hire you", "why are you interested", "why do you want",
                    "what are you looking for", "what motivates you", "where do you see yourself",
                    "why are you leaving", "why did you leave", "salary expectations",
                ]
            ) {
                return
                    "I’ll connect what I’m looking for next to this role, then make the fit concrete with one recent example."
            }
            return
                "I’ll start with the timeline, then walk through the most relevant recent application and the part I owned."
        }

        if containsAny(
            normalized,
            [
                "security", "secure", "permission", "access", "auth", "credential",
                "secret", "encrypt", "privacy", "compliance", "database", "mcp",
            ]
        ) {
            return
                "Which data and actions does this actually require? I’d default to least-privilege, read-only access with scoped credentials, query limits, and audit logs."
        }

        if containsAny(
            normalized,
            ["failure", "failing", "error", "bug", "broken", "incident", "outage", "debug", "retry"]
        ) {
            return
                "What changed immediately before the failure started? I’d trace where the signal first diverges, then test the smallest likely cause."
        }

        if containsAny(
            normalized,
            ["scale", "scaling", "latency", "performance", "throughput", "bottleneck", "load"]
        ) {
            return
                "Are we optimizing throughput, tail latency, or cost? I’d measure the actual bottleneck first, then isolate and scale that path."
        }

        if containsAny(
            normalized,
            ["tradeoff", "trade-off", "choose", "choice", "compare", "versus", " vs "]
        ) {
            return
                "Which constraint is hardest here? I’d keep the decision reversible and optimize for that constraint rather than balancing everything equally."
        }

        if containsAny(
            normalized,
            ["team", "lead", "manager", "conflict", "stakeholder", "priority", "prioritize", "ownership"]
        ) {
            return
                "What outcome is the team optimizing for? I’d make the decision criteria explicit, hear the strongest disagreement, and assign one clear owner."
        }

        if containsAny(
            normalized,
            ["tell me about a time", "example", "experience", "challenging", "mistake", "learned"]
        ) {
            return
                "I’ll anchor this in one concrete example, then make the decision, my role, and the outcome clear."
        }

        if containsAny(
            normalized,
            ["architecture", "design", "service", "api", "queue", "cache", "event", "asynchronous", "async"]
        ) {
            return
                "Which constraint matters most here? My default is a simple, reversible boundary with explicit failure handling."
        }

        if normalized.hasPrefix("what is ")
            || normalized.hasPrefix("what are ")
            || normalized.hasPrefix("explain ")
            || normalized.hasPrefix("how does ")
        {
            return
                "What level of detail would be most useful? I’d explain the core mechanism first, then the tradeoff it creates."
        }

        return
            "What outcome and constraint matter most here? I’d choose the simplest reversible approach and make the key tradeoff explicit."
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
