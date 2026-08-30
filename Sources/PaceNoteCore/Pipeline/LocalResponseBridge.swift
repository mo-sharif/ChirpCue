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

        if let reviewed = reviewedTechnicalResponse(forNormalizedQuestion: normalized) {
            return reviewed
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

    /// A reviewed, self-contained technical sentence that is safe to use as the completed Quick
    /// answer without spending time or subscription capacity on another model turn.
    public static func reviewedTechnicalResponse(for question: String) -> String? {
        reviewedTechnicalResponse(forNormalizedQuestion: normalize(question))
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

        let asksAboutReactKeys =
            containsAny(normalized, ["react", "jsx"])
            && containsAny(normalized, ["key", "keys", "list key", "list keys"])
        if asksAboutReactKeys {
            return
                "React keys give sibling elements stable identity, so reconciliation preserves the right state and updates the intended item."
        }

        if containsAny(normalized, ["controlled component", "controlled components"])
            || (containsAny(normalized, ["controlled", "uncontrolled"])
                && containsAny(normalized, ["react", "input", "component", "components"]))
        {
            return
                "A controlled input keeps its value in React state; an uncontrolled input lets the DOM own it and reads through a ref."
        }

        if containsAny(normalized, ["usememo", "usecallback", "use memo", "use callback"]) {
            return
                "useMemo caches a computed value and useCallback caches a function identity; both help only when avoided work outweighs their overhead."
        }

        let asksAboutReactContext =
            containsAny(normalized, ["react context", "context api"])
            || (containsAny(normalized, ["context"])
                && containsAny(normalized, ["react", "prop drilling", "provider"]))
        if asksAboutReactContext {
            return
                "React context shares values down a tree without prop drilling, but broad provider changes can re-render many consumers."
        }

        if containsAny(normalized, ["error boundary", "error boundaries"]) {
            return
                "React error boundaries catch rendering failures below them and show fallback UI, but they do not catch every asynchronous error."
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

        if containsAny(normalized, ["hoisting", "hoisted"]) {
            return
                "JavaScript hoists declarations during scope setup, but let and const stay unusable until initialization while var starts as undefined."
        }

        if containsAny(normalized, ["debounce", "debouncing"])
            && containsAny(normalized, ["throttle", "throttling"])
        {
            return
                "Debouncing waits for activity to stop; throttling limits execution frequency while activity continues."
        }

        if containsAny(normalized, ["event delegation"]) {
            return
                "Event delegation handles child interactions from an ancestor through event bubbling, reducing listeners and supporting dynamically added elements."
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

        if containsAny(normalized, ["cors", "cross origin resource sharing"]) {
            return
                "CORS is a browser-enforced policy where the server explicitly allows which origins may read a cross-origin response."
        }

        if containsAny(normalized, ["critical rendering path", "browser rendering pipeline"]) {
            return
                "The browser parses HTML and CSS, builds render structures, lays out geometry, then paints and composites pixels."
        }

        if containsAny(normalized, ["code splitting", "lazy loading", "lazy load"]) {
            return
                "Code splitting loads JavaScript only when a route or interaction needs it, improving startup while adding explicit loading boundaries."
        }

        if containsAny(normalized, ["tree shaking", "treeshaking"]) {
            return
                "Tree shaking removes statically unused exports during bundling, so package side-effect declarations must be accurate."
        }

        let asksAboutBrowserMemoryLeak =
            containsAny(normalized, ["memory leak", "memory leaks"])
            && containsAny(normalized, ["browser", "frontend", "front end", "javascript", "react"])
        if asksAboutBrowserMemoryLeak {
            return
                "Browser memory leaks usually come from retained listeners, timers, closures, or caches; heap snapshots reveal the retaining path."
        }

        if containsAny(normalized, ["what is typescript", "explain typescript"]) {
            return
                "TypeScript adds static type checking to JavaScript, catching contract mistakes before runtime while still compiling to ordinary JavaScript."
        }

        let asksWhyTypeScript =
            containsAny(normalized, ["typescript"])
            && containsAny(
                normalized,
                ["advantage", "advantages", "benefit", "benefits", "help", "use", "using", "value", "why"]
            )
        if asksWhyTypeScript {
            return
                "I’d use TypeScript to move interface mistakes into compile time, make contracts explicit, and keep large refactors safer."
        }

        if containsAny(normalized, ["eventual consistency", "eventually consistent"]) {
            return
                "At a high level, eventual consistency lets replicas diverge temporarily, provided they converge after updates stop."
        }

        if containsAny(normalized, ["cap theorem", "consistency availability partition tolerance"]) {
            return
                "CAP says a partitioned distributed system must choose whether a request favors consistency or availability until connectivity recovers."
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

        let asksAboutSQLJoins =
            containsAny(normalized, ["sql", "database", "table", "tables"])
            && containsAny(normalized, ["inner join", "left join", "joins"])
        if asksAboutSQLJoins {
            return
                "An inner join returns matching rows; a left join keeps every left-side row and fills missing right-side values with null."
        }

        if containsAny(normalized, ["acid", "database transaction", "database transactions"]) {
            return
                "A transaction groups changes atomically; ACID adds consistency, isolation, and durability so concurrent failures do not leave partial state."
        }

        if containsAny(normalized, ["optimistic locking", "pessimistic locking"]) {
            return
                "Optimistic locking detects conflicts at write time; pessimistic locking blocks competing access earlier when conflicts are frequent or expensive."
        }

        if containsAny(normalized, ["cache", "caches", "caching"]) {
            return
                "A cache lowers latency and source load by reusing data, but freshness and invalidation become part of the design."
        }

        if containsAny(normalized, ["load balancer", "load balancing"]) {
            return
                "A load balancer spreads traffic across healthy instances, improving capacity and availability while removing failed targets."
        }

        if containsAny(normalized, ["message queue", "job queue", "work queue"]) {
            return
                "A queue decouples producers from consumers and absorbs bursts, but delivery, ordering, retries, and poison messages need explicit handling."
        }

        if containsAny(normalized, ["rate limiting", "rate limiter", "rate limit algorithm"]) {
            return
                "Rate limiting protects capacity and fairness by bounding requests per identity, with clear retry behavior and distributed counters where needed."
        }

        let comparesRESTAndGraphQL =
            containsAny(normalized, ["rest", "rest api", "restful"])
            && containsAny(normalized, ["graphql", "graph ql"])
        if comparesRESTAndGraphQL {
            return
                "REST exposes resource-shaped endpoints and cache-friendly semantics; GraphQL lets clients select fields but adds schema and query-cost complexity."
        }

        if containsAny(normalized, ["cursor pagination", "offset pagination"]) {
            return
                "Offset pagination is simple but drifts under writes; cursor pagination stays stable and efficient when ordered by an immutable key."
        }

        let comparesStreamingTransports =
            containsAny(normalized, ["websocket", "websockets", "web socket", "web sockets"])
            && containsAny(normalized, ["server sent events", "sse"])
        if comparesStreamingTransports {
            return
                "WebSockets are bidirectional; server-sent events are one-way over HTTP and simpler when only the server streams updates."
        }

        let comparesServiceBoundaries =
            containsAny(normalized, ["microservice", "microservices"])
            && containsAny(normalized, ["monolith", "modular monolith"])
        if comparesServiceBoundaries {
            return
                "A modular monolith keeps deployment simple; microservices buy independent scaling and ownership at the cost of distributed coordination."
        }

        if containsAny(normalized, ["cdn", "content delivery network"]) {
            return
                "A CDN serves cacheable content near users, reducing origin load and latency while making cache policy and invalidation critical."
        }

        if containsAny(normalized, ["design system", "component library"]) {
            return
                "A design system pairs reusable components with tokens, accessibility rules, documentation, and governance so teams ship consistent behavior."
        }

        if containsAny(normalized, ["microfrontend", "microfrontends", "micro frontend", "micro frontends"]) {
            return
                "Microfrontends trade independent delivery and ownership for duplicated runtime cost, integration contracts, and harder cross-application consistency."
        }

        if containsAny(normalized, ["feature flag", "feature flags", "feature toggle", "feature toggles"]) {
            return
                "Feature flags decouple deployment from release, but they need ownership, telemetry, safe defaults, and a removal date."
        }

        if containsAny(normalized, ["observability", "distributed tracing"]) {
            return
                "Observability connects logs, metrics, and traces around user-visible signals so you can locate failures instead of guessing from symptoms."
        }

        if containsAny(normalized, ["continuous integration", "continuous delivery", "ci cd", "cicd"]) {
            return
                "A strong CI/CD path keeps builds reproducible, gates risky changes, deploys incrementally, and makes rollback fast and observable."
        }

        if containsAny(normalized, ["dependency injection", "inject dependencies"]) {
            return
                "Dependency injection supplies collaborators from outside a component, making boundaries explicit and substitutions easier to test."
        }

        if containsAny(
            normalized,
            [
                "model context protocol", "explain mcp", "how does mcp expose", "how does mcp work",
                "what does mcp do", "what does mcp standardize", "what is mcp", "what s mcp",
                "why use mcp",
            ]
        ) {
            return
                "At a high level, MCP standardizes how a host exposes approved tools and context to a model through a defined protocol."
        }

        return nil
    }

    private static func reviewedTechnicalResponse(
        forNormalizedQuestion normalized: String
    ) -> String? {
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

        let hasSensitiveAccessPair =
            containsAny(normalized, ["access", "read access", "write access"])
            && containsAny(
                normalized,
                ["data", "database", "mcp", "credentials", "permission", "read only"]
            )
        let hasSecuredDataSystem =
            containsAny(normalized, ["data", "database", "mcp"])
            && containsAny(
                normalized,
                ["security", "secure", "permission", "permissions", "credential", "credentials"]
            )
        if hasSensitiveAccessPair || hasSecuredDataSystem {
            return
                "Which data and actions does this actually require? I’d default to least-privilege, read-only access with scoped credentials, query limits, and audit logs."
        }

        let comparesAuthenticationAndAuthorization =
            containsAny(normalized, ["authentication", "authn"])
            && containsAny(normalized, ["authorization", "authz"])
        if comparesAuthenticationAndAuthorization {
            return
                "Authentication verifies who a caller is; authorization decides what that identity may do at each protected resource boundary."
        }

        if containsAny(normalized, ["oauth", "oauth 2", "oauth2"]) {
            return
                "OAuth delegates limited access through scoped tokens, so a client can act without receiving the user’s password."
        }

        let asksAboutEncryption = containsAny(
            normalized,
            [
                "encrypt", "encrypted", "encryption", "data at rest", "data in transit",
            ]
        )
        if asksAboutEncryption {
            return
                "TLS protects data in transit; storage encryption protects data at rest, with keys separated, rotated, and access-controlled."
        }

        let asksAboutSecretManagement =
            containsAny(normalized, ["secret", "secrets"])
            && containsAny(
                normalized,
                [
                    "api", "application", "code", "config", "credential", "credentials",
                    "environment", "key", "keys", "repository", "rotate", "rotation", "service",
                    "store", "storage", "system", "token", "tokens", "vault",
                ]
            )
        if asksAboutSecretManagement {
            return
                "I’d keep secrets out of code, store them in a managed vault, scope access, rotate them, and audit every retrieval."
        }

        if containsAny(
            normalized,
            [
                "security", "secure", "auth", "authentication", "authorization", "credential",
                "credentials", "privacy", "compliance", "access control", "sso",
                "least privilege",
            ]
        ) {
            return
                "I’d start with the threat model, then layer least privilege, strong authentication, encryption, safe defaults, and auditable controls."
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
