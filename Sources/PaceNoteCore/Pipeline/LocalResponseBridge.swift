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
                    "I’ll use one real example. I’ll cover the decision, my role, and the result."
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
                "Are we trying to improve throughput, tail latency, or cost? I’d find the real bottleneck first and scale only that path."
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
                "I’ll use one real example. I’ll cover the decision, my role, and the result."
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
                "React builds a new element tree and compares it with the last one. Then it updates only the DOM parts that changed."
        }

        let asksAboutReactRendering =
            containsAny(normalized, ["react", "component"])
            && containsAny(
                normalized,
                ["re render", "re renders", "rerender", "rerenders", "render again"]
            )
        if asksAboutReactRendering {
            return
                "A React component re-renders when state, context, or parent inputs change. Memoization can skip work when those values stay stable."
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
                "A controlled input keeps its value in React state. An uncontrolled input lets the DOM own it and reads the value through a ref."
        }

        if containsAny(normalized, ["usememo", "usecallback", "use memo", "use callback"]) {
            return
                "useMemo caches a value, while useCallback caches a function. I use either only when the saved work is worth the extra complexity."
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
                "The event loop runs synchronous JavaScript first. When the call stack clears, it starts the next queued work."
        }

        let asksAboutJavaScriptAsync =
            containsAny(normalized, ["async await"])
            || (containsAny(normalized, ["promise", "promises"])
                && containsAny(normalized, ["javascript", "js", "typescript", "async", "await"]))
        if asksAboutJavaScriptAsync {
            return
                "A promise holds a future result. Async and await make its success and failure paths read like normal step-by-step code."
        }

        if containsAny(normalized, ["hoisting", "hoisted"]) {
            return
                "JavaScript hoists declarations during scope setup, but let and const stay unusable until initialization while var starts as undefined."
        }

        if containsAny(normalized, ["debounce", "debouncing"])
            && containsAny(normalized, ["throttle", "throttling"])
        {
            return
                "Debouncing waits for activity to stop. Throttling limits how often work runs while activity continues."
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
                "Hydration attaches client behavior to server-rendered HTML. That makes the existing page interactive without rebuilding it."
        }

        if containsAny(normalized, ["cors", "cross origin resource sharing"]) {
            return
                "CORS is a browser-enforced policy where the server explicitly allows which origins may read a cross-origin response."
        }

        if containsAny(normalized, ["critical rendering path", "browser rendering pipeline"]) {
            return
                "The browser reads HTML and CSS, builds the page layout, then paints it. Compositing puts the final layers on screen."
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
                "Browser memory leaks often come from listeners, timers, or caches that stay alive. Heap snapshots show what is still holding them."
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
                "Eventual consistency lets replicas differ for a while. They should agree again after updates stop."
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
                "An inner join returns only matching rows. A left join keeps every left-side row and uses null when the right side is missing."
        }

        if containsAny(normalized, ["acid", "database transaction", "database transactions"]) {
            return
                "A transaction makes a group of changes succeed or fail together. ACID also protects consistency, isolation, and durability."
        }

        if containsAny(normalized, ["optimistic locking", "pessimistic locking"]) {
            return
                "Optimistic locking checks for conflicts when you write. Pessimistic locking blocks other access earlier when conflicts are common or costly."
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
                "A queue separates producers from consumers and absorbs traffic spikes. I’d define delivery, retries, and poison-message handling up front."
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
                "REST gives you resource-based endpoints and simple caching. GraphQL lets clients choose fields, but adds schema and query-cost work."
        }

        if containsAny(normalized, ["cursor pagination", "offset pagination"]) {
            return
                "Offset pagination is simple but can drift during writes. Cursor pagination stays stable when it uses an unchanging sort key."
        }

        let comparesStreamingTransports =
            containsAny(normalized, ["websocket", "websockets", "web socket", "web sockets"])
            && containsAny(normalized, ["server sent events", "sse"])
        if comparesStreamingTransports {
            return
                "WebSockets send data both ways. Server-sent events are simpler when only the server needs to stream updates."
        }

        let comparesServiceBoundaries =
            containsAny(normalized, ["microservice", "microservices"])
            && containsAny(normalized, ["monolith", "modular monolith"])
        if comparesServiceBoundaries {
            return
                "A modular monolith keeps deployment simple. Microservices add independent scaling and ownership, but make coordination harder."
        }

        if containsAny(normalized, ["cdn", "content delivery network"]) {
            return
                "A CDN serves cacheable content near users, reducing origin load and latency while making cache policy and invalidation critical."
        }

        if containsAny(normalized, ["design system", "component library"]) {
            return
                "A design system combines reusable components with shared design rules. It helps teams ship accessible, consistent behavior."
        }

        if containsAny(normalized, ["microfrontend", "microfrontends", "micro frontend", "micro frontends"]) {
            return
                "Microfrontends trade independent delivery and ownership for duplicated runtime cost, integration contracts, and harder cross-application consistency."
        }

        if containsAny(normalized, ["feature flag", "feature flags", "feature toggle", "feature toggles"]) {
            return
                "Feature flags separate deployment from release. Each flag still needs an owner, a safe default, and a removal date."
        }

        if containsAny(normalized, ["observability", "distributed tracing"]) {
            return
                "Observability connects logs, metrics, and traces around user-visible signals so you can locate failures instead of guessing from symptoms."
        }

        if containsAny(normalized, ["continuous integration", "continuous delivery", "ci cd", "cicd"]) {
            return
                "A strong CI/CD path keeps builds repeatable and gates risky changes. It should also make rollout and rollback fast."
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
                "MCP gives hosts a standard way to share approved tools and context with a model. The host still controls what is available."
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
                "Which data and actions does this need? I’d start with read-only, least-privilege access and full audit logs."
        }

        let comparesAuthenticationAndAuthorization =
            containsAny(normalized, ["authentication", "authn"])
            && containsAny(normalized, ["authorization", "authz"])
        if comparesAuthenticationAndAuthorization {
            return
                "Authentication checks who a caller is. Authorization decides what that identity can do at each protected boundary."
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
                "TLS protects data while it moves. Storage encryption protects saved data, with keys kept separate and access tightly limited."
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
                "I’d keep secrets out of code and store them in a managed vault. Then I’d limit access, rotate them, and audit every read."
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
                "I’d start with the threat model. Then I’d add least privilege, strong authentication, and audit logs."
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
                "I’d set clear speed budgets first. Then I’d use real-user LCP, INP, and CLS data to find the slow path."
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
