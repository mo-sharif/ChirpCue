import FoundationModels
import XCTest

@testable import PaceNoteCore

final class FoundationModelQuickGeneratorTests: XCTestCase {
    func testSystemModelBypassStillUsesReviewedLocalTechnicalAnswer() async throws {
        let turn = ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: 1),
            question: "How should MCP access a database securely?",
            recentTranscript: []
        )
        let generator = FoundationModelQuickGenerator(systemModelEnabled: false)

        let route = await generator.prepare()
        let output = try await generator.generateQuick(for: turn)

        XCTAssertEqual(route, FoundationModelQuickGenerator.deterministicRoute)
        XCTAssertEqual(output.reason, "reviewed_local_technical_answer")
        XCTAssertTrue(output.sayNow.contains("least-privilege"))
        XCTAssertEqual(output.turnID, turn.identity.turnID)
    }

    func testNormalizesAQualifiedSpeakableResponse() {
        let accepted = FoundationModelQuickGenerator.acceptedResponse(
            from: "  Say now: I’d start with read-only access, then make every query bounded and auditable.  "
        )

        XCTAssertEqual(
            accepted,
            "I’d start with read-only access, then make every query bounded and auditable."
        )
    }

    func testRejectsMarkdownAndPrivateContextClaims() {
        XCTAssertNil(
            FoundationModelQuickGenerator.acceptedResponse(
                from: "I’d inspect `secrets.json` in our repository first."
            )
        )
    }

    func testAcceptsAConciseImperativeTechnicalAnswer() {
        XCTAssertEqual(
            FoundationModelQuickGenerator.acceptedResponse(
                from: "Start with read-only credentials, scope access by dataset, and audit every MCP query."
            ),
            "Start with read-only credentials, scope access by dataset, and audit every MCP query."
        )
    }

    func testUnavailableSystemModelReturnsQuestionAwareFallback() async throws {
        let generator = FoundationModelQuickGenerator()
        let route = await generator.prepare()
        guard route == FoundationModelQuickGenerator.deterministicRoute else {
            throw XCTSkip("Apple's on-device model is available on this test host.")
        }
        let turn = ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: 1),
            question: "How should MCP access our database securely?",
            recentTranscript: []
        )

        let output = try await generator.generateQuick(for: turn)

        XCTAssertEqual(output.reason, "reviewed_local_technical_answer")
        XCTAssertTrue(output.sayNow.contains("least-privilege"))
        XCTAssertEqual(output.turnID, turn.identity.turnID)
    }

    func testPersonalExperienceQuestionWithoutBriefAlwaysUsesFactSafeBridge() async throws {
        let question =
            "How many years have you had with React JS, and what kind of applications have you been working on lately?"
        let turn = ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: 1),
            question: question,
            recentTranscript: []
        )
        let generator = FoundationModelQuickGenerator(systemModelEnabled: true)

        let output = try await generator.generateQuick(for: turn)

        XCTAssertEqual(output.reason, "deterministic_safety_bridge")
        XCTAssertEqual(output.sayNow, LocalResponseBridge.response(for: question))
        XCTAssertFalse(output.sayNow.lowercased().contains("which part"))
    }

    func testPersonalExperienceQuestionUsesRelevantBriefFactsWithoutModelDelay() async throws {
        let question =
            "How many years have you had with React JS, and what kind of applications have you been working on lately?"
        let turn = ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: 1),
            question: question,
            recentTranscript: [],
            speakerBrief: """
                I’ve worked with React for eight years across production web applications.
                Lately, I’ve focused on TypeScript AI products and reusable frontend architecture.
                """
        )
        let generator = FoundationModelQuickGenerator(systemModelEnabled: true)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let output = try await generator.generateQuick(for: turn)

        XCTAssertEqual(output.reason, "speaker_brief_extract")
        XCTAssertEqual(
            output.sayNow,
            "I’ve worked with React for eight years across production web applications. Lately, I’ve focused on TypeScript AI products and reusable frontend architecture."
        )
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(100))
    }

    func testBoundedSystemModelProducesOrFallsBackInsideProductDeadline() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_RUN_APPLE_QUICK_SMOKE"] == "1" else {
            throw XCTSkip("Set PACENOTE_RUN_APPLE_QUICK_SMOKE=1 for the on-device generation smoke.")
        }
        let generator = BoundedLocalQuickGenerator(
            base: FoundationModelQuickGenerator(),
            timeout: .seconds(3)
        )
        let route = await generator.prepare()
        guard route == FoundationModelQuickGenerator.onDeviceRoute else {
            throw XCTSkip("Apple's on-device model is unavailable on this test host.")
        }
        let turn = ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: 1),
            question: "How would you migrate a large frontend without stopping feature delivery?",
            recentTranscript: []
        )
        let clock = ContinuousClock()
        let startedAt = clock.now

        let output = try await generator.generateQuick(for: turn)
        let latency = startedAt.duration(to: clock.now)

        XCTAssertTrue(
            ["on_device_foundation_model", "deterministic_safety_bridge"].contains(output.reason)
        )
        XCTAssertLessThanOrEqual(latency, .seconds(4))
        XCTAssertLessThanOrEqual(output.sayNow.split(whereSeparator: { $0.isWhitespace }).count, 24)
        await generator.awaitCleanup(for: turn.identity)
    }

    func testAvailableSystemModelReportsRawFirstTextLatencyForDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_RUN_APPLE_QUICK_SMOKE"] == "1" else {
            throw XCTSkip("Set PACENOTE_RUN_APPLE_QUICK_SMOKE=1 for the on-device generation smoke.")
        }
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw XCTSkip("Apple's on-device model is unavailable on this test host.")
        }
        let session = LanguageModelSession(
            model: model,
            tools: [],
            instructions: "Return only one concise sentence a staff engineer can say aloud."
        )
        session.prewarm()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let stream = session.streamResponse(
            to: "How would you migrate a large frontend without stopping feature delivery?",
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0,
                maximumResponseTokens: 32
            )
        )
        var firstTextLatency: Duration?

        for try await partial in stream where !partial.content.isEmpty {
            firstTextLatency = startedAt.duration(to: clock.now)
            break
        }

        XCTAssertNotNil(firstTextLatency)
        if let firstTextLatency {
            let attachment = XCTAttachment(string: "raw_first_text_latency=\(firstTextLatency)")
            attachment.name = "Apple on-device raw first-text latency"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertLessThanOrEqual(firstTextLatency, .seconds(60))
        }
    }
}
