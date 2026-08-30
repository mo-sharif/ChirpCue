import Foundation

/// A bounded, question-aware opener that is available without waiting for a provider.
///
/// Reviewed technical primers answer common concepts directly; broader prompts use generic
/// staff-level framing. Neither path claims private repository or organization facts.
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
                "accessibility", "accessible", "a11y", "screen reader", "keyboard navigation",
                "wcag", "aria",
            ]
        ) {
            return
                "I’d start with semantic HTML and keyboard support, then verify focus and screen-reader behavior across the critical user flows."
        }

        let hasExplicitSecurityTerm = containsAny(
            normalized,
            [
                "security", "secure", "permission", "permissions", "auth", "authentication",
                "authorization", "credential", "credentials", "secret", "secrets", "encrypt",
                "encrypted", "encryption", "privacy", "compliance", "access control", "oauth",
                "sso", "least privilege",
            ]
        )
        let hasSensitiveAccessPair =
            containsAny(normalized, ["access", "read access", "write access"])
            && containsAny(
                normalized,
                ["data", "database", "mcp", "credentials", "permission", "read only"]
            )
        if hasExplicitSecurityTerm || hasSensitiveAccessPair {
            return
                "Which data and actions does this actually require? I’d default to least-privilege, read-only access with scoped credentials, query limits, and audit logs."
        }

        if let directAnswer = directTechnicalAnswer(for: normalized) {
            return directAnswer
        }

        if containsAny(
            normalized,
            ["test", "tests", "testing", "testable", "unit test", "integration test", "end to end"]
        ) {
            return
                "I’d center tests on observable behavior, cover boundaries with integration tests, and keep a small end-to-end suite for critical paths."
        }

        let isFrontendPerformance =
            containsAny(
                normalized,
                ["core web vitals", "lcp", "inp", "cls"]
            )
            || (containsAny(normalized, ["frontend", "front end", "web", "browser", "react"])
                && containsAny(normalized, ["performance", "latency", "slow", "rendering"]))
        if isFrontendPerformance {
            return
                "I’d protect interaction and rendering budgets first, then measure LCP, INP, and CLS with real-user data before optimizing."
        }

        if containsAny(
            normalized,
            [
                "failure", "failures", "failing", "error", "errors", "bug", "bugs", "broken",
                "incident", "incidents", "outage", "outages", "debug", "debugging", "retry",
                "retries",
            ]
        ) {
            return
                "What changed immediately before the failure started? I’d trace where the signal first diverges, then test the smallest likely cause."
        }

        if containsAny(
            normalized,
            [
                "scale", "scales", "scaling", "scalable", "latency", "performance", "throughput",
                "bottleneck", "bottlenecks", "load", "loads",
            ]
        ) {
            return
                "Are we optimizing throughput, tail latency, or cost? I’d measure the actual bottleneck first, then isolate and scale that path."
        }

        if containsAny(
            normalized,
            [
                "tradeoff", "tradeoffs", "trade-off", "trade-offs", "choose", "choice", "choices", "compare", "versus",
                "vs",
            ]
        ) {
            return
                "Which constraint is hardest here? I’d keep the decision reversible and optimize for that constraint rather than balancing everything equally."
        }

        if containsAny(
            normalized,
            [
                "team", "teams", "lead", "leading", "leadership", "manager", "management",
                "conflict", "stakeholder", "stakeholders", "priority", "priorities", "prioritize",
                "ownership",
            ]
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
            [
                "architecture", "design", "service", "services", "api", "apis", "queue", "queues",
                "cache", "caches", "caching", "event", "events", "asynchronous", "async",
            ]
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
                "I’d explain the core mechanism first, then connect it to the tradeoff that matters in practice."
        }

        return
            "What outcome and constraint matter most here? I’d choose the simplest reversible approach and make the key tradeoff explicit."
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        let haystack = " \(value) "
        return needles.contains { needle in
            let phrase = normalize(needle)
            return !phrase.isEmpty && haystack.contains(" \(phrase) ")
        }
    }

    private static func directTechnicalAnswer(for normalized: String) -> String? {
        if containsAny(normalized, ["react reconciliation", "react reconcile", "virtual dom"]) {
            return
                "At a high level, React builds a new element tree, compares it with the previous one, and commits only the DOM updates that changed."
        }

        let asksAboutReactRendering =
            containsAny(normalized, ["react", "component"])
            && containsAny(
                normalized,
                ["re render", "re renders", "rerender", "rerenders", "render again"]
            )
        if asksAboutReactRendering {
            return
                "A React component re-renders when its state, consumed context, or parent-driven inputs change; memoization only skips work when identities stay stable."
        }

        if containsAny(normalized, ["state"]) && containsAny(normalized, ["prop", "props"]) {
            return
                "The difference is that props are parent inputs, while state is component-owned data that changes and drives rendering."
        }

        let asksAboutReactHooks =
            (containsAny(normalized, ["react"]) && containsAny(normalized, ["hook", "hooks"]))
            || containsAny(normalized, ["use state", "use effect", "usestate", "useeffect"])
        if asksAboutReactHooks {
            return
                "At a high level, React hooks let function components reuse stateful behavior, but their call order must stay stable across renders."
        }

        let asksAboutJavaScriptClosure =
            containsAny(normalized, ["closure", "closures"])
            && containsAny(normalized, ["javascript", "js", "function", "lexical"])
        if asksAboutJavaScriptClosure {
            return
                "A closure is a function bundled with the lexical variables it can still access from its creation scope."
        }

        if containsAny(normalized, ["event loop", "javascript event loop", "browser event loop"]) {
            return
                "At a high level, the event loop runs synchronous JavaScript first, then schedules queued work when the call stack becomes clear."
        }

        let asksAboutJavaScriptAsync =
            containsAny(normalized, ["async await"])
            || (containsAny(normalized, ["promise", "promises"])
                && containsAny(normalized, ["javascript", "js", "typescript", "async", "await"]))
        if asksAboutJavaScriptAsync {
            return
                "A promise represents a future result; async and await make its success and failure paths read like synchronous control flow."
        }

        let comparesRenderingLocation =
            containsAny(
                normalized,
                ["ssr", "server side rendering"]
            ) && containsAny(normalized, ["csr", "client side rendering"])
        if comparesRenderingLocation {
            return
                "The difference is that SSR sends ready HTML sooner, while CSR builds the page in the browser after JavaScript loads."
        }

        let asksAboutWebHydration =
            containsAny(
                normalized,
                ["hydration", "hydrate", "hydrating"]
            )
            && containsAny(
                normalized,
                ["react", "web", "html", "server rendered", "server side rendering", "client"]
            )
        if asksAboutWebHydration {
            return
                "At a high level, hydration attaches client-side behavior to server-rendered HTML so the existing page becomes interactive without rebuilding it."
        }

        if containsAny(normalized, ["typescript"]) {
            return
                "I’d use TypeScript to move interface mistakes into compile time, make contracts explicit, and keep large refactors safer."
        }

        if containsAny(normalized, ["eventual consistency", "eventually consistent"]) {
            return
                "At a high level, eventual consistency lets replicas diverge temporarily, provided they converge after updates stop."
        }

        if containsAny(normalized, ["idempotency", "idempotent"]) {
            return
                "An idempotent operation can be retried without changing the result beyond the first successful application."
        }

        let asksAboutDatabaseIndex =
            containsAny(normalized, ["database", "sql"])
            && containsAny(normalized, ["index", "indexes", "indices"])
        if asksAboutDatabaseIndex {
            return
                "A database index speeds reads through a separate lookup structure, trading extra storage and write cost for faster retrieval."
        }

        if containsAny(normalized, ["cache", "caches", "caching"]) {
            return
                "A cache lowers latency and source load by reusing data, but freshness and invalidation become part of the design."
        }

        if containsAny(normalized, ["model context protocol", "mcp"]) {
            return
                "At a high level, MCP standardizes how a host exposes approved tools and context to a model through a defined protocol."
        }

        return nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
