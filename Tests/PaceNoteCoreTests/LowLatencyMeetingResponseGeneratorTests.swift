import Foundation
import XCTest

@testable import PaceNoteCore

final class LowLatencyMeetingResponseGeneratorTests: XCTestCase {
    func testCancellingBusyDeepStopsAdmissionRetries() async throws {
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate, deepFailures: Array(repeating: .deepAlreadyActive, count: 100)
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider, quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus", providerName: "codex", quickPathDecisionWindow: .zero,
            deepAdmissionPollInterval: .seconds(10)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()
        let turn = Self.turn(generation: 24)
        let pending = Task { try await generator.generateDeep(for: turn) }
        await provider.waitUntilDeepCalled()
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Cancelled admission must not generate an answer.")
        } catch is CancellationError {
            // Expected; neither the retry delay nor an earlier answer needs to finish.
        }
        let attempts = await provider.deepCallCount()
        XCTAssertEqual(attempts, 1)
        _ = await generator.shutdown()
    }

    func testBusyDeepWaitsForAdmissionWithoutBlockingQuick() async throws {
        let turn = Self.turn(generation: 20)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate, deepFailures: [.deepAlreadyActive, .deepAlreadyActive]
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider, quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus", providerName: "codex", providerQuickHeadStart: .zero,
            quickPathDecisionWindow: .zero, deepAdmissionWait: .seconds(1),
            deepAdmissionPollInterval: .milliseconds(10)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()
        async let deep = generator.generateDeep(for: turn)
        let quick = try await generator.generateQuick(for: turn)
        XCTAssertEqual(quick.reason, "provider_sol_low")
        let draft = try await deep
        XCTAssertEqual(draft.turnID, turn.identity.turnID)
        let attempts = await provider.deepCallCount()
        XCTAssertEqual(attempts, 3)
        try await generator.awaitQuickCleanup(for: turn.identity)
        _ = await generator.shutdown()
    }

    func testDeepAdmissionDoesNotRetrySubscriptionCapacityOrLocalRateLimits() async throws {
        for failure in [MeetingResponseError.providerCapacityUnavailable, .deepRateLimited, .invalidOutput] {
            let gate = ProviderPreparationGate()
            let provider = DeferredMeetingResponseGenerator(gate: gate, deepFailures: [failure])
            let generator = LowLatencyMeetingResponseGenerator(
                provider: provider, quickGenerator: DeterministicLocalQuickGenerator(),
                planType: "plus", providerName: "codex", quickPathDecisionWindow: .zero
            )
            _ = try await generator.prepare()
            await gate.waitUntilEntered()
            await gate.release()
            do {
                _ = try await generator.generateDeep(for: Self.turn(generation: 21))
                XCTFail("Expected the original failure.")
            } catch let actual as MeetingResponseError {
                XCTAssertEqual(actual, failure)
            }
            let attempts = await provider.deepCallCount()
            XCTAssertEqual(attempts, 1)
            _ = await generator.shutdown()
        }
    }

    func testBusyDeepWaitIsBounded() async throws {
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate, deepFailures: Array(repeating: .deepAlreadyActive, count: 100)
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider, quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus", providerName: "codex", quickPathDecisionWindow: .zero,
            deepAdmissionWait: .milliseconds(30), deepAdmissionPollInterval: .seconds(1)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()
        do {
            _ = try await generator.generateDeep(for: Self.turn(generation: 22))
            XCTFail("Busy admission must eventually finish.")
        } catch let error as MeetingResponseError {
            XCTAssertEqual(error, .deepAlreadyActive)
        }
        let attempts = await provider.deepCallCount()
        XCTAssertEqual(attempts, 1)
        _ = await generator.shutdown()
    }

    func testProviderQuickFailureIsNotDisguisedAsSuccessfulFallback() async throws {
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate, quickFailure: .providerCapacityUnavailable)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider, quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus", providerName: "codex"
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()
        do {
            _ = try await generator.generateQuick(for: Self.turn(generation: 23))
            XCTFail("Capacity failure must remain visible while the coordinator keeps its initial cue.")
        } catch let error as MeetingResponseError {
            XCTAssertEqual(error, .providerCapacityUnavailable)
        }
        _ = await generator.shutdown()
    }

    func testPrepareAndQuickDoNotWaitForSubscriptionProviderPreparation() async throws {
        let turn = Self.turn(generation: 1)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(gate: gate)
        let quick = StubLocalQuickGenerator(turn: turn)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: quick,
            planType: "plus",
            providerName: "codex",
            quickPathDecisionWindow: .seconds(2)
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
        let deepStartedAt = ContinuousClock().now
        _ = try await generator.generateDeep(for: turn)
        XCTAssertLessThan(
            deepStartedAt.duration(to: ContinuousClock().now),
            .milliseconds(200),
            "Quick cleanup must not erase the local-success decision before Deep consumes it."
        )
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

    func testProviderQuickCleanupFailureRecoversOnceAndAllowsNextTurn() async throws {
        let firstTurn = Self.turn(generation: 10)
        let secondTurn = Self.turn(generation: 11)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate,
            quickCleanupFailures: 1
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .milliseconds(0)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()

        let first = try await generator.generateQuick(for: firstTurn)
        XCTAssertEqual(first.reason, "provider_sol_low")
        try await generator.awaitQuickCleanup(for: firstTurn.identity)

        let second = try await generator.generateQuick(for: secondTurn)
        XCTAssertEqual(second.reason, "provider_sol_low")
        try await generator.awaitQuickCleanup(for: secondTurn.identity)

        let recoveries = await provider.recoveryCount()
        let preparations = await provider.prepareCallCount()
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(preparations, 2)
        _ = await generator.shutdown()
    }

    func testFailedCleanupRecoveryRemainsFailClosedWithoutRetryLoop() async throws {
        let turn = Self.turn(generation: 12)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate,
            quickCleanupFailures: 1,
            recoveryFailures: 1
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .milliseconds(0)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()
        _ = try await generator.generateQuick(for: turn)

        do {
            try await generator.awaitQuickCleanup(for: turn.identity)
            XCTFail("Expected cleanup recovery to remain fail closed.")
        } catch let error as MeetingResponseError {
            XCTAssertEqual(error, .cleanupFailed)
        }

        do {
            _ = try await generator.generateDeep(for: Self.turn(generation: 13))
            XCTFail("Expected later provider work to remain blocked.")
        } catch let error as MeetingResponseError {
            XCTAssertEqual(error, .cleanupFailed)
        }

        let recoveries = await provider.recoveryCount()
        XCTAssertEqual(recoveries, 1)
        _ = await generator.shutdown()
    }

    func testCleanupRecoveryRetriesDeepWorkCancelledByProviderReplacement() async throws {
        let turn = Self.turn(generation: 14)
        let gate = ProviderPreparationGate()
        let provider = DeferredMeetingResponseGenerator(
            gate: gate,
            quickCleanupFailures: 1,
            suspendFirstDeepUntilRecovery: true
        )
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: DeterministicLocalQuickGenerator(),
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .milliseconds(0)
        )
        _ = try await generator.prepare()
        await gate.waitUntilEntered()
        await gate.release()

        _ = try await generator.generateQuick(for: turn)
        let deepTask = Task { try await generator.generateDeep(for: turn) }
        await provider.waitUntilDeepSuspended()

        try await generator.awaitQuickCleanup(for: turn.identity)
        let deep = try await deepTask.value

        XCTAssertEqual(deep.generation, turn.identity.generation)
        let deepCalls = await provider.deepCallCount()
        let recoveries = await provider.recoveryCount()
        XCTAssertEqual(deepCalls, 2)
        XCTAssertEqual(recoveries, 1)
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

    func testHungLocalModelYieldsToProviderQuickAndOpensCircuitForLaterTurns() async throws {
        let firstTurn = Self.turn(generation: 8)
        let providerGate = ProviderPreparationGate()
        let localGate = ControlledQuickSuspension()
        let deadline = ManualQuickDeadline()
        let local = SuspendedLocalQuickGenerator(gate: localGate)
        let bounded = BoundedLocalQuickGenerator(
            base: local,
            waitForDeadline: {
                try await deadline.wait()
            }
        )
        let provider = DeferredMeetingResponseGenerator(gate: providerGate)
        let generator = LowLatencyMeetingResponseGenerator(
            provider: provider,
            quickGenerator: bounded,
            planType: "plus",
            providerName: "codex",
            providerQuickHeadStart: .milliseconds(10),
            quickPathDecisionWindow: .seconds(1)
        )
        _ = try await generator.prepare()
        await providerGate.waitUntilEntered()
        await providerGate.release()

        async let firstQuickTask = generator.generateQuick(for: firstTurn)
        async let firstDeepTask = generator.generateDeep(for: firstTurn)
        await localGate.waitUntilEntered()
        await deadline.waitUntilEntered()
        await deadline.fire()

        let (firstQuick, firstDeep) = try await (firstQuickTask, firstDeepTask)
        XCTAssertEqual(firstQuick.reason, "provider_sol_low")
        XCTAssertEqual(firstQuick.sayNow, DeferredMeetingResponseGenerator.quickResponse)
        XCTAssertEqual(firstDeep.generation, firstTurn.identity.generation)
        let firstCallOrder = await provider.callOrder()
        XCTAssertEqual(firstCallOrder, ["quick", "deep"])

        await localGate.release()
        try await generator.awaitQuickCleanup(for: firstTurn.identity)

        let secondTurn = Self.turn(generation: 9)
        let secondQuick = try await generator.generateQuick(for: secondTurn)
        XCTAssertEqual(secondQuick.reason, "provider_sol_low")
        let localCalls = await local.callCount()
        let providerCalls = await provider.quickCallCount()
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(providerCalls, 2)

        try await generator.awaitQuickCleanup(for: secondTurn.identity)
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

private actor SuspendedLocalQuickGenerator: LocalQuickGenerating {
    private let gate: ControlledQuickSuspension
    private var calls = 0

    init(gate: ControlledQuickSuspension) {
        self.gate = gate
    }

    func prepare() -> CodexModelRoute {
        CodexModelRoute(model: "test-suspended-local", effort: "fast")
    }

    func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        calls += 1
        await gate.suspend()
        try Task.checkCancellation()
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: "This local result should not win after its deadline.",
            needsDeep: true,
            confidence: 0.5,
            reason: "late_local_result"
        )
    }

    func cancelActiveWork() {}

    func callCount() -> Int { calls }
}

private actor ControlledQuickSuspension {
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

private actor ManualQuickDeadline {
    private var entered = false
    private var fired = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var fireWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        guard !fired else { return }
        await withCheckedContinuation { continuation in
            fireWaiters.append(continuation)
        }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func fire() {
        fired = true
        for waiter in fireWaiters { waiter.resume() }
        fireWaiters.removeAll()
    }
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
    private var quickCleanupFailures: Int
    private var deepFailures: [MeetingResponseError]
    private let quickFailure: MeetingResponseError?
    private var recoveryFailures: Int
    private let suspendFirstDeepUntilRecovery: Bool
    private var prepared = false
    private var preparationCalls = 0
    private var deepCalls = 0
    private var deepCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var quickCalls = 0
    private var cancellations = 0
    private var recoveries = 0
    private var calls: [String] = []
    private var deepSuspended = false
    private var deepSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var deepRecoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        gate: ProviderPreparationGate,
        preparationFailures: Int = 0,
        quickCleanupFailures: Int = 0,
        recoveryFailures: Int = 0,
        suspendFirstDeepUntilRecovery: Bool = false,
        deepFailures: [MeetingResponseError] = [],
        quickFailure: MeetingResponseError? = nil
    ) {
        self.gate = gate
        self.preparationFailures = preparationFailures
        self.quickCleanupFailures = quickCleanupFailures
        self.recoveryFailures = recoveryFailures
        self.suspendFirstDeepUntilRecovery = suspendFirstDeepUntilRecovery
        self.deepFailures = deepFailures
        self.quickFailure = quickFailure
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
        if let quickFailure { throw quickFailure }
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: Self.quickResponse,
            needsDeep: true,
            confidence: 0.78,
            reason: "provider_sol_low"
        )
    }

    func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        guard prepared else { throw MeetingResponseError.notPrepared }
        deepCalls += 1
        for waiter in deepCallWaiters { waiter.resume() }
        deepCallWaiters.removeAll()
        calls.append("deep")
        if !deepFailures.isEmpty { throw deepFailures.removeFirst() }
        if suspendFirstDeepUntilRecovery, deepCalls == 1 {
            deepSuspended = true
            for waiter in deepSuspensionWaiters { waiter.resume() }
            deepSuspensionWaiters.removeAll()
            await withCheckedContinuation { continuation in
                deepRecoveryWaiters.append(continuation)
            }
            throw CancellationError()
        }
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
        Reconciliation(relationship: .continueAnswer, transition: "The part I’d add is this.")
    }

    func awaitQuickCleanup(for _: TurnIdentity) throws {
        guard quickCleanupFailures > 0 else { return }
        quickCleanupFailures -= 1
        throw MeetingResponseError.cleanupFailed
    }

    func recoverAfterCleanupFailure() async throws -> MeetingResponseRuntime {
        recoveries += 1
        for waiter in deepRecoveryWaiters { waiter.resume() }
        deepRecoveryWaiters.removeAll()
        if recoveryFailures > 0 {
            recoveryFailures -= 1
            throw MeetingResponseError.cleanupFailed
        }
        return try await prepare()
    }

    func cancelActiveWork() {
        cancellations += 1
    }

    func shutdown() -> MeetingResponseCleanupReport {
        MeetingResponseCleanupReport()
    }

    func waitUntilDeepSuspended() async {
        guard !deepSuspended else { return }
        await withCheckedContinuation { continuation in
            deepSuspensionWaiters.append(continuation)
        }
    }

    func deepCallCount() -> Int { deepCalls }
    func waitUntilDeepCalled() async {
        guard deepCalls == 0 else { return }
        await withCheckedContinuation { deepCallWaiters.append($0) }
    }
    func quickCallCount() -> Int { quickCalls }
    func cancelCount() -> Int { cancellations }
    func recoveryCount() -> Int { recoveries }
    func prepareCallCount() -> Int { preparationCalls }
    func callOrder() -> [String] { calls }
}
