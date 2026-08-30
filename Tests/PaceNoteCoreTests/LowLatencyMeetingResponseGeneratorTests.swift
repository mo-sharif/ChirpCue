import Foundation
import XCTest

@testable import PaceNoteCore

final class LowLatencyMeetingResponseGeneratorTests: XCTestCase {
    func testPrepareAndQuickDoNotWaitForSubscriptionProviderPreparation() async throws {
        let turn = Self.turn(generation: 1)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let quick = StubLocalQuickGenerator(turn: turn)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: quick,
            planType: "plus",
            providerName: "codex"
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let runtime = try await generator.prepare()
        let generatedQuick = try await generator.generateQuick(for: turn)

        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(100))
        XCTAssertEqual(runtime.quickRoute, StubLocalQuickGenerator.route)
        XCTAssertEqual(runtime.deepRoute.model, "codex-subscription")
        XCTAssertFalse(runtime.usesRealtimeQuick)
        XCTAssertEqual(generatedQuick.sayNow, StubLocalQuickGenerator.response)
        try await generator.awaitQuickCleanup(for: turn.identity)
        let cleanedIdentities = await quick.cleanedIdentities()
        XCTAssertEqual(cleanedIdentities, [turn.identity])

        await gate.waitUntilEntered()
        await gate.release()
        _ = try await generator.generateDeep(for: turn)
        _ = await generator.shutdown()
    }

    func testDeterministicLocalBridgeUpgradesToProviderGeneratedQuick() async throws {
        let turn = Self.turn(generation: 2)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .milliseconds(0)
        )
        _ = try await generator.prepare()

        let quickTask = Task { try await generator.generateQuick(for: turn) }
        await gate.waitUntilEntered()
        await gate.release()
        let generated = try await quickTask.value

        XCTAssertEqual(generated.sayNow, DeferredMeetingResponseGenerator.quickResponse)
        XCTAssertEqual(generated.reason, "provider_sol_low")
        let quickCalls = await provider.quickCallCount()
        XCTAssertEqual(quickCalls, 1)
        try await generator.awaitQuickCleanup(for: turn.identity)
        _ = await generator.shutdown()
    }

    func testDeepWaitsForSharedPreparationThenUsesProvider() async throws {
        let turn = Self.turn(generation: 2)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: StubLocalQuickGenerator(turn: turn),
            planType: nil,
            providerName: "codex"
        )
        _ = try await generator.prepare()

        let deepTask = Task { try await generator.generateDeep(for: turn) }
        await gate.waitUntilEntered()
        let callsBeforeRelease = await provider.deepCallCount()
        XCTAssertEqual(callsBeforeRelease, 0)

        await gate.release()
        let draft = try await deepTask.value

        XCTAssertEqual(draft.turnID, turn.identity.turnID)
        let callsAfterRelease = await provider.deepCallCount()
        XCTAssertEqual(callsAfterRelease, 1)
        _ = await generator.shutdown()
    }

    func testLocalQuickSuccessRemovesSubscriptionQuickHeadStartFromDeep() async throws {
        let turn = Self.turn(generation: 6)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: StubLocalQuickGenerator(turn: turn),
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .seconds(1)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()
        _ = try await generator.generateQuick(for: turn)
        let clock = ContinuousClock()
        let startedAt = clock.now

        _ = try await generator.generateDeep(for: turn)

        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(200))
        let quickCalls = await provider.quickCallCount()
        XCTAssertEqual(quickCalls, 0)
        _ = await generator.shutdown()
    }

    func testProviderQuickStillClaimsQueueBeforeDeepWhenLocalBridgeNeedsUpgrade() async throws {
        let turn = Self.turn(generation: 7)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .milliseconds(10),
            quickPathDecisionWindow: .milliseconds(10)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()

        async let quick = generator.generateQuick(for: turn)
        async let deep = generator.generateDeep(for: turn)
        _ = try await (quick, deep)

        let callOrder = await provider.callOrder()
        XCTAssertEqual(callOrder, ["quick", "deep"])
        _ = await generator.shutdown()
    }

    func testCancellingDeepWaitDoesNotCancelSharedProviderPreparation() async throws {
        let turn = Self.turn(generation: 3)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: StubLocalQuickGenerator(turn: turn),
            planType: nil,
            providerName: "codex"
        )
        _ = try await generator.prepare()

        let cancelledTask = Task { try await generator.generateDeep(for: turn) }
        await gate.waitUntilEntered()
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected the cancelled waiter to stop promptly.")
        } catch is CancellationError {
            // Expected. Provider preparation remains alive for the next turn.
        }

        let cancellationCount = await provider.cancelCount()
        XCTAssertEqual(cancellationCount, 0)
        await gate.release()
        let next = Self.turn(generation: 4)
        let draft = try await generator.generateDeep(for: next)
        XCTAssertEqual(draft.generation, 4)
        _ = await generator.shutdown()
    }

    func testTransientProviderPreparationRetriesWithoutBlockingQuickLane() async throws {
        let turn = Self.turn(generation: 5)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate,
            preparationFailures: 1
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: StubLocalQuickGenerator(turn: turn),
            planType: "plus",
            providerName: "codex",
            providerRetryDelay: .milliseconds(1)
        )

        _ = try await generator.prepare()
        let quick = try await generator.generateQuick(for: turn)
        XCTAssertEqual(quick.sayNow, StubLocalQuickGenerator.response)

        await gate.waitUntilEntered()
        await gate.release()
        _ = try await generator.generateDeep(for: turn)
        let preparationCalls = await provider.prepareCallCount()
        XCTAssertEqual(preparationCalls, 2)
        _ = await generator.shutdown()
    }

    private static func turn(generation: UInt64) -> ConversationTurn {
        ConversationTurn(
            identity: TurnIdentity(meetingID: UUID(), generation: generation),
            question: "How would you keep database access secure through MCP?",
            recentTranscript: [
                TranscriptSegment(
                    source: .them,
                    text: "How would you keep database access secure through MCP?",
                    startedAt: 0,
                    endedAt: 1,
                    isFinal: true,
                    confidence: 0.98
                )
            ]
        )
    }
}

private actor StubLocalQuickGenerator: LocalQuickGenerating {
    static let route = CodexModelRoute(model: "test-on-device", effort: "fast")
    static let response = "I’d start with read-only, least-privilege access and make every query auditable."

    private let expectedTurn: ConversationTurn
    private var cleanupRequests: [TurnIdentity] = []

    init(turn: ConversationTurn) {
        expectedTurn = turn
    }

    func prepare() -> CodexModelRoute { Self.route }

    func generateQuick(for turn: ConversationTurn) throws -> QuickModelOutput {
        QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: Self.response,
            needsDeep: true,
            confidence: turn.question == expectedTurn.question ? 0.8 : 0.7,
            reason: "test_on_device"
        )
    }

    func awaitCleanup(for identity: TurnIdentity) {
        cleanupRequests.append(identity)
    }

    func cancelActiveWork() {}

    func cleanedIdentities() -> [TurnIdentity] { cleanupRequests }
}

private actor DeterministicLocalQuickGenerator: LocalQuickGenerating {
    func prepare() -> CodexModelRoute {
        FoundationModelQuickGenerator.deterministicRoute
    }

    func generateQuick(for turn: ConversationTurn) -> QuickModelOutput {
        QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: LocalResponseBridge.response(for: turn.question),
            needsDeep: true,
            confidence: 1,
            reason: "deterministic_safety_bridge"
        )
    }

    func cancelActiveWork() {}
}

private actor ProviderPreparationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor DeferredMeetingResponseGenerator: MeetingResponseGenerating {
    static let quickResponse =
        "I’d start with read-only access, scoped credentials, and an audit trail for every MCP query."

    private let gate: ProviderPreparationGate
    private var preparationFailures: Int
    private var prepared = false
    private var preparationCalls = 0
    private var deepCalls = 0
    private var quickCalls = 0
    private var cancellations = 0
    private var calls: [String] = []

    init(gate: ProviderPreparationGate, preparationFailures: Int = 0) {
        self.gate = gate
        self.preparationFailures = preparationFailures
    }

    func prepare() async throws -> MeetingResponseRuntime {
        preparationCalls += 1
        if preparationFailures > 0 {
            preparationFailures -= 1
            throw MeetingResponseError.runtimeUnavailable
        }
        await gate.suspend()
        try Task.checkCancellation()
        prepared = true
        return MeetingResponseRuntime(
            planType: "plus",
            quickRoute: CodexModelRoute(model: "provider-quick", effort: "low"),
            deepRoute: CodexModelRoute(model: "provider-deep", effort: "high"),
            usesRealtimeQuick: true
        )
    }

    func generateQuick(for turn: ConversationTurn) throws -> QuickModelOutput {
        guard prepared else { throw MeetingResponseError.notPrepared }
        quickCalls += 1
        calls.append("quick")
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: Self.quickResponse,
            needsDeep: true,
            confidence: 0.78,
            reason: "provider_sol_low"
        )
    }

    func generateDeep(for turn: ConversationTurn) throws -> DeepDraft {
        guard prepared else { throw MeetingResponseError.notPrepared }
        deepCalls += 1
        calls.append("deep")
        return DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I’d enforce least privilege first, then add bounded queries and end-to-end auditing.",
            confidence: 0.82,
            basis: []
        )
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) throws -> Reconciliation {
        Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
    }

    func cancelActiveWork() {
        cancellations += 1
    }

    func shutdown() -> MeetingResponseCleanupReport {
        MeetingResponseCleanupReport()
    }

    func deepCallCount() -> Int { deepCalls }
    func quickCallCount() -> Int { quickCalls }
    func cancelCount() -> Int { cancellations }
    func prepareCallCount() -> Int { preparationCalls }
    func callOrder() -> [String] { calls }
}
