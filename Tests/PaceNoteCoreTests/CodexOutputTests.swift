import Foundation
import XCTest

@testable import PaceNoteCore

final class CodexOutputTests: XCTestCase {
    func testCollectsOnlyCompletedFinalAgentMessage() async throws {
        let pair = AsyncThrowingStream<CodexTurnEvent, any Error>.makeStream()
        let session = CodexTurnSession(threadID: "thread", turnID: "turn", events: pair.stream)
        let expected = QuickModelOutput(
            turnID: UUID(),
            generation: 1,
            sayNow: "I would separate those failure domains.",
            needsDeep: true,
            confidence: 0.7,
            reason: "technical"
        )
        let json = try JSONEncoder().encode(expected)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))

        pair.continuation.yield(.agentMessageDelta(itemID: "item", delta: "{"))
        pair.continuation.yield(
            .itemCompleted([
                "type": "agentMessage",
                "text": .string("commentary"),
                "phase": "commentary",
            ]))
        pair.continuation.yield(
            .itemCompleted([
                "type": "agentMessage",
                "text": .string(text),
                "phase": "final_answer",
            ]))
        pair.continuation.yield(.completed(status: "completed"))
        pair.continuation.finish()

        let actual = try await CodexStructuredOutput.collect(from: session, as: QuickModelOutput.self)
        XCTAssertEqual(actual, expected)
    }

    func testMalformedOrFencedJSONFailsClosed() throws {
        XCTAssertThrowsError(try CodexStructuredOutput.decode("```json\n{}\n```", as: QuickModelOutput.self))
        XCTAssertThrowsError(try CodexStructuredOutput.decode("{} trailing", as: QuickModelOutput.self))
    }

    func testStructuredOutputsRejectAdditionalKeysAtEveryNestedBoundary() throws {
        let turnID = UUID().uuidString
        XCTAssertThrowsError(
            try CodexStructuredOutput.decode(
                """
                {"turnID":"\(turnID)","generation":1,"sayNow":"Let me verify that.","needsDeep":true,"confidence":0.5,"reason":"technical","extra":"unsafe"}
                """,
                as: QuickModelOutput.self
            )
        )
        XCTAssertThrowsError(
            try CodexStructuredOutput.decode(
                """
                {"turnID":"\(turnID)","generation":1,"groundingFingerprint":"fingerprint","kind":"answer","candidateSayNext":"The queue separates delivery from the request.","confidence":0.9,"basis":[{"repoAlias":"fixture","relativePath":"Queue.swift","startLine":1,"endLine":2,"fileHash":"hash","claim":"The handler enqueues work.","extra":"unsafe"}],"missingEvidence":[]}
                """,
                as: DeepDraft.self
            )
        )
        XCTAssertThrowsError(
            try CodexStructuredOutput.decode(
                "{\"relationship\":\"continue\",\"transition\":\"The part I’d add is this.\",\"extra\":\"unsafe\"}",
                as: Reconciliation.self
            )
        )
    }

    func testGeneralDeepEncodingPreservesExplicitNullGroundingFingerprint() throws {
        let draft = DeepDraft(
            turnID: UUID(),
            generation: 1,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I would separate the decision from the implementation details.",
            confidence: 0.7,
            basis: []
        )

        let data = try JSONEncoder().encode(draft)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertTrue(object.keys.contains("groundingFingerprint"))
        XCTAssertTrue(object["groundingFingerprint"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(DeepDraft.self, from: data), draft)
    }

    func testRouterUsesOnlyVersionedAllowlistedModels() throws {
        let models = [
            model(id: "unknown-fast", efforts: ["low"], isDefault: true),
            model(id: "gpt-5.6-luna", efforts: ["low", "medium"]),
            model(id: "gpt-5.6-terra", efforts: ["low", "medium", "high"]),
            model(
                id: "gpt-5.6-sol",
                efforts: ["low", "medium", "high"],
                serviceTiers: ["priority"]
            ),
        ]
        let router = CodexModelRouter(models: models, policy: .codex_0_147)

        XCTAssertEqual(
            try router.route(for: .quick),
            .init(model: "gpt-5.6-sol", effort: "low", serviceTier: "priority")
        )
        XCTAssertEqual(
            try router.route(for: .narrowTechnical),
            .init(model: "gpt-5.6-sol", effort: "medium")
        )
        XCTAssertEqual(try router.route(for: .hardTechnical), .init(model: "gpt-5.6-sol", effort: "high"))
    }

    func testLiveCoachingPrefersInstantQuickWhenAdvertised() throws {
        let router = CodexModelRouter(
            models: [model(id: "gpt-5.6-sol", efforts: ["none", "low", "medium"])],
            policy: .liveCoaching
        )
        XCTAssertEqual(try router.route(for: .quick), .init(model: "gpt-5.6-sol", effort: "none"))
    }

    func testLiveCoachingPrefersSparkButSkipsHiddenSpark() throws {
        for hidden in [false, true] {
            let router = CodexModelRouter(
                models: [
                    model(id: "gpt-5.3-codex-spark", efforts: ["low", "medium", "high"], hidden: hidden),
                    model(id: "gpt-5.6-sol", efforts: ["none", "low", "medium"]),
                ],
                policy: .liveCoaching
            )
            XCTAssertEqual(
                try router.route(for: .quick),
                hidden
                    ? .init(model: "gpt-5.6-sol", effort: "none")
                    : .init(model: "gpt-5.3-codex-spark", effort: "low")
            )
        }
    }

    func testLiveCoachingKeepsQuickOnSolAndBothDeepRoutesOnAstraMedium() throws {
        let router = CodexModelRouter(
            models: [
                model(id: "gpt-6-astra", efforts: ["low", "medium", "high"], isDefault: true),
                model(id: "gpt-5.6-sol", efforts: ["low", "medium", "high"], serviceTiers: ["priority"]),
            ], policy: .liveCoaching)

        XCTAssertEqual(
            try router.route(for: .quick), .init(model: "gpt-5.6-sol", effort: "low", serviceTier: "priority"))
        XCTAssertEqual(try router.route(for: .narrowTechnical), .init(model: "gpt-6-astra", effort: "medium"))
        XCTAssertEqual(try router.route(for: .hardTechnical), .init(model: "gpt-6-astra", effort: "medium"))
    }

    func testUnavailableHiddenOrIneligibleAstraFallsBackToSol() throws {
        let unavailableCatalogs: [[CodexModel]] = [
            [],
            [model(id: "gpt-6-astra", efforts: ["medium"], hidden: true)],
            [model(id: "gpt-6-astra", efforts: ["high", "xhigh"])],
            [model(id: "gpt-6-astra", efforts: [])],
        ]
        for catalog in unavailableCatalogs {
            let router = CodexModelRouter(
                models: catalog + [model(id: "gpt-5.6-sol", efforts: ["low", "medium", "high"])],
                policy: .liveCoaching
            )
            XCTAssertEqual(try router.route(for: .narrowTechnical), .init(model: "gpt-5.6-sol", effort: "medium"))
            XCTAssertEqual(try router.route(for: .hardTechnical), .init(model: "gpt-5.6-sol", effort: "high"))
        }
    }

    func testLiveCoachingRetainsTerraFallbackAndRejectsUnknownModels() throws {
        let router = CodexModelRouter(
            models: [model(id: "gpt-5.6-terra", efforts: ["medium", "high"])],
            policy: .liveCoaching
        )
        XCTAssertEqual(try router.route(for: .narrowTechnical), .init(model: "gpt-5.6-terra", effort: "medium"))
        let unknownOnly = CodexModelRouter(
            models: [model(id: "unknown-model", efforts: ["medium"], isDefault: true)],
            policy: .liveCoaching
        )
        XCTAssertThrowsError(try unknownOnly.route(for: .narrowTechnical))
    }

    func testNewMeetingsDefaultToAstraCoachingPolicy() {
        let configuration = MeetingResponseConfiguration(
            meetingID: UUID(),
            meetingPrivateRoot: URL(fileURLWithPath: "/tmp/chirpcue-routing-test/meeting"),
            codexProfileRoot: URL(fileURLWithPath: "/tmp/chirpcue-routing-test/profile"),
            clientVersion: "test", groundingSnapshot: nil
        )
        XCTAssertEqual(configuration.routingPolicy, .liveCoaching)
    }

    private func model(
        id: String,
        efforts: [String],
        serviceTiers: [String] = [],
        isDefault: Bool = false,
        hidden: Bool = false
    ) -> CodexModel {
        CodexModel(
            id: id,
            model: id,
            displayName: id,
            hidden: hidden,
            supportedReasoningEfforts: efforts.map {
                CodexReasoningEffortOption(reasoningEffort: $0, description: "")
            },
            defaultReasoningEffort: efforts.first,
            inputModalities: ["text"],
            supportsPersonality: true,
            serviceTiers: serviceTiers.map {
                CodexModelServiceTier(id: $0, name: $0, description: "")
            },
            defaultServiceTier: nil,
            isDefault: isDefault
        )
    }
}
