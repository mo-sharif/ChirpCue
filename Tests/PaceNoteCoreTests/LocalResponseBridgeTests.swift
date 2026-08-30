import XCTest

@testable import PaceNoteCore

final class LocalResponseBridgeTests: XCTestCase {
    func testSecurityQuestionGetsAnImmediateSpecificOpener() {
        let response = LocalResponseBridge.response(
            for: "How do we keep the database secure when our MCP accesses it?"
        )

        XCTAssertTrue(response.contains("least-privilege"))
        XCTAssertTrue(response.contains("read-only"))
        XCTAssertTrue(response.contains("audit logs"))
        XCTAssertTrue(GeneralGuidancePolicy.accepts(response))
        XCTAssertLessThanOrEqual(response.split(whereSeparator: \Character.isWhitespace).count, 24)
    }

    func testEveryBridgeCategoryStaysSpeakableAndPolicySafe() {
        let questions = [
            "Why is this service failing?",
            "How would this scale under load?",
            "How do you compare these tradeoffs?",
            "How would you resolve conflict on the team?",
            "Tell me about a time you made a mistake.",
            "How would you design an asynchronous API?",
            "What is eventual consistency?",
            "How should we approach this?",
        ]

        for question in questions {
            let response = LocalResponseBridge.response(for: question)
            XCTAssertTrue(GeneralGuidancePolicy.accepts(response), response)
            XCTAssertLessThanOrEqual(
                response.split(whereSeparator: \Character.isWhitespace).count,
                24,
                response
            )
        }
    }

    func testPersonalExperienceQuestionGetsAnOrderedNoninventedBridge() {
        let question =
            "My first question is, how many years have you had with React JS, and what kind of applications have you been working on lately?"

        let response = LocalResponseBridge.response(for: question)

        XCTAssertTrue(LocalResponseBridge.requiresPersonalFacts(question))
        XCTAssertEqual(
            response,
            "I’ll start with the timeline, then walk through the most relevant recent application and the part I owned."
        )
        XCTAssertFalse(response.lowercased().contains("which part"))
        XCTAssertTrue(GeneralGuidancePolicy.accepts(response))
        XCTAssertLessThanOrEqual(response.split(whereSeparator: \Character.isWhitespace).count, 24)
    }

    func testCustomConfiguredBridgeRemainsUnchanged() {
        let custom = "I’d clarify the riskiest constraint first."
        let configuration = ResponseCoordinatorConfiguration(bridgeText: custom)

        XCTAssertEqual(configuration.bridgeText(for: "How should this scale?"), custom)
    }

    func testCommonPersonalInterviewPromptsUseNaturalNoninventedOpeners() {
        let expected: [(String, String)] = [
            (
                "Tell me about a time you influenced without authority.",
                "I’ll anchor this in one concrete example, then make the decision, my role, and the outcome clear."
            ),
            (
                "What is your greatest strength?",
                "I’ll give the honest headline first, then ground it in one recent example and what changed because of it."
            ),
            (
                "Why are you interested in this role?",
                "I’ll connect what I’m looking for next to this role, then make the fit concrete with one recent example."
            ),
        ]

        for (question, opener) in expected {
            XCTAssertTrue(LocalResponseBridge.requiresPersonalFacts(question), question)
            XCTAssertEqual(LocalResponseBridge.response(for: question), opener)
            XCTAssertTrue(GeneralGuidancePolicy.accepts(opener), opener)
            XCTAssertFalse(opener.contains("?"), opener)
        }
    }

    func testCommonTechnicalInterviewQuestionsGetDirectImmediateAnswers() {
        let fixtures: [(question: String, expectedText: String)] = [
            (
                "Can you explain how React reconciliation and the virtual DOM work?",
                "commits only the DOM updates that changed"
            ),
            (
                "What causes a React component to re-render?",
                "state, consumed context, or parent-driven inputs"
            ),
            (
                "What’s the difference between state and props in React?",
                "props are parent inputs, while state is component-owned"
            ),
            (
                "Explain closures in JavaScript.",
                "lexical variables it can still access"
            ),
            (
                "How does the browser event loop work?",
                "runs synchronous JavaScript first"
            ),
            (
                "What problem do promises and async/await solve?",
                "represents a future result"
            ),
            (
                "Compare SSR and CSR.",
                "SSR sends ready HTML sooner"
            ),
            (
                "What is hydration in a server-rendered React app?",
                "attaches client-side behavior to server-rendered HTML"
            ),
            (
                "Why do you use TypeScript?",
                "move interface mistakes into compile time"
            ),
            (
                "What is eventual consistency?",
                "lets replicas diverge temporarily"
            ),
            (
                "Why does idempotency matter?",
                "can be retried without changing the result"
            ),
            (
                "What does a database index do?",
                "trading extra storage and write cost"
            ),
            (
                "How would you think about caching?",
                "freshness and invalidation become part of the design"
            ),
            (
                "How does MCP work?",
                "exposes approved tools and context to a model"
            ),
            (
                "How do you make a web app accessible?",
                "semantic HTML and keyboard support"
            ),
            (
                "How do you test a frontend application?",
                "center tests on observable behavior"
            ),
            (
                "How would you improve frontend performance and Core Web Vitals?",
                "measure LCP, INP, and CLS"
            ),
            (
                "Why do React list items need stable keys?",
                "stable identity"
            ),
            (
                "Compare controlled and uncontrolled inputs in React.",
                "lets the DOM own it"
            ),
            (
                "When should I use useMemo versus useCallback?",
                "avoided work outweighs their overhead"
            ),
            (
                "What tradeoff comes with React Context?",
                "re-render many consumers"
            ),
            (
                "What do React error boundaries catch?",
                "rendering failures below them"
            ),
            (
                "What does hoisting mean in JavaScript?",
                "let and const stay unusable"
            ),
            (
                "What is the difference between debouncing and throttling?",
                "waits for activity to stop"
            ),
            (
                "How does event delegation work?",
                "through event bubbling"
            ),
            (
                "What problem does CORS solve in browsers?",
                "which origins may read"
            ),
            (
                "Walk through the browser rendering pipeline.",
                "paints and composites pixels"
            ),
            (
                "How does code splitting improve a web application?",
                "adding explicit loading boundaries"
            ),
            (
                "What does tree shaking do?",
                "statically unused exports"
            ),
            (
                "How would you investigate a browser memory leak?",
                "heap snapshots reveal the retaining path"
            ),
            (
                "Explain the CAP theorem.",
                "favors consistency or availability"
            ),
            (
                "Compare an inner join with a left join in SQL.",
                "keeps every left-side row"
            ),
            (
                "What does ACID mean for database transactions?",
                "do not leave partial state"
            ),
            (
                "Compare optimistic locking and pessimistic locking.",
                "detects conflicts at write time"
            ),
            (
                "What does a load balancer do?",
                "spreads traffic across healthy instances"
            ),
            (
                "Why would you put work on a message queue?",
                "decouples producers from consumers"
            ),
            (
                "How would you design rate limiting?",
                "protects capacity and fairness"
            ),
            (
                "Compare REST and GraphQL.",
                "cache-friendly semantics"
            ),
            (
                "Compare offset pagination and cursor pagination.",
                "drifts under writes"
            ),
            (
                "When would you use WebSockets versus server-sent events?",
                "only the server streams updates"
            ),
            (
                "Compare microservices with a modular monolith.",
                "cost of distributed coordination"
            ),
            (
                "How does a CDN improve web performance?",
                "serves cacheable content near users"
            ),
            (
                "What makes a design system successful?",
                "tokens, accessibility rules, documentation, and governance"
            ),
            (
                "What are the tradeoffs of microfrontends?",
                "duplicated runtime cost"
            ),
            (
                "How should teams manage feature flags?",
                "a removal date"
            ),
            (
                "What is observability and why does it matter?",
                "logs, metrics, and traces"
            ),
            (
                "What should a strong CI/CD pipeline provide?",
                "makes rollback fast and observable"
            ),
            (
                "What is dependency injection?",
                "supplies collaborators from outside"
            ),
            (
                "What is the difference between authentication and authorization?",
                "decides what that identity may do"
            ),
            (
                "How does OAuth delegate access?",
                "without receiving the user’s password"
            ),
            (
                "How do encryption at rest and encryption in transit differ?",
                "TLS protects data in transit"
            ),
            (
                "How should an application store and rotate secrets?",
                "store them in a managed vault"
            ),
        ]
        let clock = ContinuousClock()
        let startedAt = clock.now

        for fixture in fixtures {
            let response = LocalResponseBridge.response(for: fixture.question)
            let reviewed = LocalResponseBridge.reviewedTechnicalResponse(for: fixture.question)

            XCTAssertTrue(response.contains(fixture.expectedText), "\(fixture.question): \(response)")
            XCTAssertEqual(reviewed, response, fixture.question)
            XCTAssertTrue(GeneralGuidancePolicy.accepts(response), response)
            XCTAssertLessThanOrEqual(
                response.split(whereSeparator: \Character.isWhitespace).count,
                24,
                response
            )
            XCTAssertFalse(response.contains("What level of detail"), response)
        }

        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(500))
    }

    func testWholeWordMatchingDoesNotConfuseRelatedTechnicalTerms() {
        let accessibility = LocalResponseBridge.response(
            for: "How does accessibility affect frontend design?"
        )
        let eventualConsistency = LocalResponseBridge.response(
            for: "What is eventual consistency?"
        )
        let databaseIndex = LocalResponseBridge.response(
            for: "What does a database index do?"
        )
        let mcpDataFlow = LocalResponseBridge.response(
            for: "How does MCP expose data to a model?"
        )

        XCTAssertTrue(accessibility.contains("semantic HTML"), accessibility)
        XCTAssertFalse(accessibility.contains("least-privilege"), accessibility)
        XCTAssertTrue(eventualConsistency.contains("replicas diverge temporarily"))
        XCTAssertFalse(eventualConsistency.contains("reversible boundary"))
        XCTAssertTrue(databaseIndex.contains("separate lookup structure"))
        XCTAssertFalse(databaseIndex.contains("read-only access"))
        XCTAssertTrue(mcpDataFlow.contains("defined protocol"))
        XCTAssertFalse(mcpDataFlow.contains("least-privilege"))
    }

    func testAmbiguousEverydayTermsDoNotTriggerTechnicalPrimers() {
        let deliveryPromise = LocalResponseBridge.response(
            for: "Can you promise this will be done by Friday?"
        )
        let patientHydration = LocalResponseBridge.response(
            for: "How should we improve hydration for patients?"
        )
        let launchHooks = LocalResponseBridge.response(
            for: "Which hooks do we need in the launch process?"
        )
        let leadershipSecret = LocalResponseBridge.response(
            for: "What is your secret to resolving conflict on a team?"
        )
        let roadmapPermission = LocalResponseBridge.response(
            for: "How do you get permission to change a team roadmap?"
        )
        let contextualMCPFollowUp =
            LocalResponseBridge.reviewedTechnicalResponse(for: "And how does MCP change that plan?")
        let specificTypeScriptQuestion =
            LocalResponseBridge.reviewedTechnicalResponse(
                for: "How do conditional types distribute over a union in TypeScript?"
            )

        XCTAssertFalse(deliveryPromise.contains("future result"), deliveryPromise)
        XCTAssertFalse(patientHydration.contains("client-side behavior"), patientHydration)
        XCTAssertFalse(launchHooks.contains("function components"), launchHooks)
        XCTAssertFalse(leadershipSecret.contains("least-privilege"), leadershipSecret)
        XCTAssertTrue(leadershipSecret.contains("team"), leadershipSecret)
        XCTAssertFalse(roadmapPermission.contains("least-privilege"), roadmapPermission)
        XCTAssertTrue(roadmapPermission.contains("team"), roadmapPermission)
        XCTAssertNil(contextualMCPFollowUp)
        XCTAssertNil(specificTypeScriptQuestion)
    }
}
