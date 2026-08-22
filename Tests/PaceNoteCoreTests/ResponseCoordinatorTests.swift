import Foundation
import XCTest

@testable import PaceNoteCore

final class ResponseCoordinatorTests: XCTestCase {
    func testFastAIAnswerAppearsBeforeDeepAndBindsReconciliation() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(10),
            deepDelay: .milliseconds(25),
            quickText: "I would decouple the caller from downstream latency, then make retries explicit.",
            turn: turn
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))
        let cue = try XCTUnwrap(events.compactMap(\.cue).first)
        let deep = try XCTUnwrap(events.compactMap(\.deep).first)

        XCTAssertFalse(cue.isDeterministicBridge)
        XCTAssertEqual(
            cue.text,
            "I would decouple the caller from downstream latency, then make retries explicit."
        )
        XCTAssertEqual(deep.cueID, cue.id)
        XCTAssertEqual(deep.cueHash, cue.textHash)
        XCTAssertEqual(deep.kind, .generalAnswer)
        XCTAssertTrue(deep.basis.isEmpty)
        XCTAssertEqual(deep.transition, "More specifically,")
        XCTAssertEqual(deep.sayNext, generator.deepText)
        XCTAssertLessThanOrEqual(deep.composedText.split(separator: " ").count, 40)
    }

    func testValidatedQuickAndDeepAreVisibleWhileQuickCleanupRemainsPending() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let cleanupGate = QuickCleanupGate()
        let coordinator = ResponseCoordinator(
            generator: QuickCleanupControlledGenerator(turn: turn, cleanupGate: cleanupGate),
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )

        let stream = await coordinator.suggestions(for: turn)
        var iterator = stream.makeAsyncIterator()
        let firstEvent = await iterator.next()
        let first = try XCTUnwrap(firstEvent)
        let cue = try XCTUnwrap(first.cue)
        XCTAssertFalse(cue.isDeterministicBridge)

        await cleanupGate.waitUntilSuspended()
        let secondEvent = await iterator.next()
        let second = try XCTUnwrap(secondEvent)
        XCTAssertNotNil(second.deep)

        await cleanupGate.release()
        while await iterator.next() != nil {}
    }

    func testQuickCleanupFailureIsVisibleWithoutSuppressingQuickOrDeep() async {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let coordinator = ResponseCoordinator(
            generator: QuickCleanupControlledGenerator(
                turn: turn,
                cleanupError: MeetingResponseError.cleanupFailed
            ),
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertEqual(events.compactMap(\.cue).count, 1)
        XCTAssertEqual(events.compactMap(\.deep).count, 1)
        XCTAssertEqual(events.compactMap(\.quickCleanupUnavailable), [.cleanupUnavailable])
    }

    func testBridgeDoesNotWaitForQuickModel() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(200),
            deepDelay: .milliseconds(20),
            quickText: "This must not become visible.",
            turn: turn
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(25), resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))
        let cue = try XCTUnwrap(events.compactMap(\.cue).first)
        let deep = try XCTUnwrap(events.compactMap(\.deep).first)

        XCTAssertTrue(cue.isDeterministicBridge)
        XCTAssertEqual(
            cue.text,
            "I'd start by clarifying the goal and constraints, then walk through the tradeoffs before committing to an approach."
        )
        XCTAssertLessThanOrEqual(cue.text.split(whereSeparator: { $0.isWhitespace }).count, 24)
        XCTAssertEqual(deep.cueHash, cue.textHash)
    }

    func testGroundedTechnicalQuickCannotDisplayFactualClaimOrSuppressDeep() async throws {
        let turn = makeTurn(generation: 1)
        let generator = ScriptedGenerator(
            quickDelay: .seconds(10),
            deepDelay: .milliseconds(15),
            quickText: "The production queue definitely retries every request three times.",
            turn: turn,
            quickNeedsDeep: false
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )
        let events = await Self.collect(coordinator.suggestions(for: turn))
        let cue = try XCTUnwrap(events.compactMap(\.cue).first)

        XCTAssertTrue(cue.isDeterministicBridge)
        XCTAssertFalse(cue.text.contains("retries every request"))
        XCTAssertEqual(events.compactMap(\.deep).count, 1)
    }

    func testUngroundedTechnicalQuickCannotBypassBridgeWithNeedsDeepFalse() async throws {
        let turn = makeTurn(
            generation: 1,
            grounded: false,
            technical: false,
            question: "Does it encrypt data at rest?"
        )
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(1),
            deepDelay: .milliseconds(15),
            quickText: "It stores every password in plaintext.",
            turn: turn,
            quickNeedsDeep: false
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))
        let cue = try XCTUnwrap(events.compactMap(\.cue).first)

        XCTAssertTrue(cue.isDeterministicBridge)
        XCTAssertFalse(cue.text.contains("password in plaintext"))
        XCTAssertEqual(events.compactMap(\.deep).count, 1)
    }

    func testNontechnicalTurnUsesFastAIAnswerAndDeep() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(5),
            deepDelay: .milliseconds(15),
            quickText: "I would frame the decision around reversibility and the cost of being wrong.",
            turn: turn,
            quickNeedsDeep: false
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )
        let clock = ContinuousClock()
        let startedAt = clock.now

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertFalse(try XCTUnwrap(events.compactMap(\.cue).first).isDeterministicBridge)
        XCTAssertEqual(events.compactMap(\.deep).count, 1)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(250))
    }

    func testUnverifiedNonanswerCandidateIsNeverDisplayed() async throws {
        let turn = makeTurn(generation: 1)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(1),
            deepDelay: .milliseconds(5),
            quickText: "This must not be used.",
            turn: turn,
            deepKind: .clarification,
            deepText: "Production definitely retries three times. Which deployment?"
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))
        let deep = try XCTUnwrap(events.compactMap(\.deep).first)

        XCTAssertEqual(deep.sayNext, "I need one more detail before I can verify that.")
        XCTAssertFalse(deep.composedText.contains("retries three times"))
    }

    func testGroundedTurnRejectsGeneralAnswerKind() async {
        let turn = makeTurn(generation: 1)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(1),
            deepDelay: .milliseconds(1),
            quickText: "Let me verify that.",
            turn: turn,
            deepKind: .generalAnswer
        )
        let coordinator = ResponseCoordinator(generator: generator)

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertTrue(events.compactMap(\.deep).isEmpty)
        XCTAssertEqual(events.compactMap(\.deepUnavailable).count, 1)
    }

    func testUngroundedTurnRejectsEvidenceAnswerKind() async {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(1),
            deepDelay: .milliseconds(1),
            quickText: "Let me think about that.",
            turn: turn,
            deepKind: .answer
        )
        let coordinator = ResponseCoordinator(generator: generator)

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertTrue(events.compactMap(\.deep).isEmpty)
        XCTAssertEqual(events.compactMap(\.deepUnavailable).count, 1)
    }

    func testUngroundedTurnRejectsUnsupportedOrganizationClaim() async {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(1),
            deepDelay: .milliseconds(1),
            quickText: "Let me think about that.",
            turn: turn,
            deepKind: .generalAnswer,
            deepText: "Our system uses Kafka for every asynchronous workflow."
        )
        let coordinator = ResponseCoordinator(generator: generator)

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertTrue(events.compactMap(\.deep).isEmpty)
        XCTAssertEqual(events.compactMap(\.deepUnavailable).count, 1)
    }

    func testNewerTurnCancelsAndInvalidatesOlderResult() async throws {
        let oldTurn = makeTurn(generation: 1)
        let newTurn = makeTurn(generation: 2)
        let generator = ScriptedGenerator(
            quickDelay: .milliseconds(5),
            deepDelay: .milliseconds(100),
            quickText: "I will check the exact tradeoff.",
            turn: oldTurn,
            alternateTurn: newTurn
        )
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(25), resultTTL: .seconds(1))
        )

        let oldStream = await coordinator.suggestions(for: oldTurn)
        var oldIterator = oldStream.makeAsyncIterator()
        var oldEvents: [ResponseCoordinatorEvent] = []
        if let firstOldEvent = await oldIterator.next() {
            oldEvents.append(firstOldEvent)
        }

        let newStream = await coordinator.suggestions(for: newTurn)
        while let event = await oldIterator.next() {
            oldEvents.append(event)
        }
        let newEvents = await Self.collect(newStream)

        XCTAssertTrue(oldEvents.compactMap(\.deep).isEmpty)
        XCTAssertEqual(newEvents.compactMap(\.deep).count, 1)
    }

    func testHangingQuickCannotDelayBridgeOrDeep() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = HangingGenerator(hangingStage: .quick)
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(35), resultTTL: .milliseconds(300))
        )

        let result = try await Self.collectWithin(
            coordinator.suggestions(for: turn),
            timeout: .milliseconds(250)
        )
        let cue = try XCTUnwrap(result.events.compactMap(\.cue).first)

        XCTAssertTrue(cue.isDeterministicBridge)
        XCTAssertLessThan(result.elapsed, .milliseconds(200))
        XCTAssertEqual(result.events.compactMap(\.deep).count, 1)
    }

    func testNeverFinishingDeepExpiresAtResultTTLWithoutJoiningCancelledTask() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = HangingGenerator(hangingStage: .deep)
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .milliseconds(45))
        )

        let result = try await Self.collectWithin(
            coordinator.suggestions(for: turn),
            timeout: .milliseconds(250)
        )

        XCTAssertEqual(result.events.compactMap(\.cue).count, 1)
        XCTAssertTrue(result.events.compactMap(\.deep).isEmpty)
        XCTAssertEqual(result.events.compactMap(\.deepUnavailable), [.timedOut])
        XCTAssertTrue(result.events.compactMap(\.discardedStale).isEmpty)
        XCTAssertGreaterThanOrEqual(result.elapsed, .milliseconds(30))
        XCTAssertLessThan(result.elapsed, .milliseconds(200))
    }

    func testLateDeepOutputIsAuditedEvenAfterTheVisibleStreamTimesOut() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let buffer = ResponseSensitiveOutputBuffer(capacity: 4)
        let coordinator = ResponseCoordinator(
            generator: CancellationResistantLateGenerator(),
            configuration: .init(resultTTL: .milliseconds(20)),
            sensitiveOutputBuffer: buffer
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))
        XCTAssertEqual(events.compactMap(\.deepUnavailable), [.timedOut])
        try await Task.sleep(for: .milliseconds(40))
        let snapshot = await buffer.takeSnapshotAndClear()

        XCTAssertEqual(
            snapshot.values,
            ["I would keep the late provider output in the cleanup audit."]
        )
        XCTAssertFalse(snapshot.overflowed)
    }

    func testProviderCompatibilityFailureIsNotReportedAsRateLimit() async {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let coordinator = ResponseCoordinator(
            generator: FailingDeepGenerator(error: .protocolUnsupported),
            configuration: .init(resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertEqual(events.compactMap(\.deepUnavailable), [.providerUnavailable])
    }

    func testProviderCapacityFailureRemainsDistinctFromLocalRateLimit() async {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let coordinator = ResponseCoordinator(
            generator: FailingDeepGenerator(error: .providerCapacityUnavailable),
            configuration: .init(resultTTL: .seconds(1))
        )

        let events = await Self.collect(coordinator.suggestions(for: turn))

        XCTAssertEqual(
            events.compactMap(\.quickUnavailable),
            [.providerCapacityUnavailable]
        )
        XCTAssertEqual(
            events.compactMap(\.deepUnavailable),
            [.providerCapacityUnavailable]
        )
    }

    func testDeterministicBridgeBypassesReconciliationModel() async throws {
        let turn = makeTurn(generation: 1, grounded: false, technical: false)
        let generator = HangingGenerator(hangingStage: .reconcile)
        let coordinator = ResponseCoordinator(
            generator: generator,
            configuration: .init(quickDeadline: .milliseconds(100), resultTTL: .milliseconds(45))
        )

        let result = try await Self.collectWithin(
            coordinator.suggestions(for: turn),
            timeout: .milliseconds(250)
        )

        XCTAssertEqual(result.events.compactMap(\.cue).count, 1)
        XCTAssertEqual(result.events.compactMap(\.deep).count, 1)
        XCTAssertTrue(result.events.compactMap(\.discardedStale).isEmpty)
        XCTAssertLessThan(result.elapsed, .milliseconds(200))
    }

    private func makeTurn(
        generation: UInt64,
        grounded: Bool = true,
        technical: Bool = true,
        question: String? = nil
    ) -> ConversationTurn {
        let identity = TurnIdentity(
            meetingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            turnID: generation == 1
                ? UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
                : UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            generation: generation
        )
        return ConversationTurn(
            identity: identity,
            question: question
                ?? (technical ? "Why is this asynchronous?" : "How would you frame that concern?"),
            recentTranscript: [],
            repoAlias: grounded ? "sample" : nil,
            groundingFingerprint: grounded ? "fingerprint-\(generation)" : nil
        )
    }

    private static func collect(_ stream: AsyncStream<ResponseCoordinatorEvent>) async -> [ResponseCoordinatorEvent] {
        var events: [ResponseCoordinatorEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private static func collectWithin(
        _ stream: AsyncStream<ResponseCoordinatorEvent>,
        timeout: Duration
    ) async throws -> TimedEvents {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        let result = EventResultBox()
        let collector = Task {
            await result.store(collect(stream))
        }
        defer { collector.cancel() }

        while clock.now < deadline {
            if let events = await result.load() {
                return TimedEvents(events: events, elapsed: startedAt.duration(to: clock.now))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CoordinatorTestError.collectionTimedOut
    }
}

private extension ResponseCoordinatorEvent {
    var cue: CueEnvelope? {
        if case .cue(let value) = self { value } else { nil }
    }

    var deep: BoundDeep? {
        if case .deep(let value) = self { value } else { nil }
    }

    var discardedStale: TurnIdentity? {
        if case .discardedStale(let value) = self { value } else { nil }
    }

    var deepUnavailable: ResponseCoordinatorFailure? {
        if case .deepUnavailable(let value) = self { value } else { nil }
    }

    var quickUnavailable: ResponseCoordinatorFailure? {
        if case .quickUnavailable(let value) = self { value } else { nil }
    }

    var quickCleanupUnavailable: ResponseCoordinatorFailure? {
        if case .quickCleanupUnavailable(let value) = self { value } else { nil }
    }
}

private struct TimedEvents: Sendable {
    let events: [ResponseCoordinatorEvent]
    let elapsed: Duration
}

private enum CoordinatorTestError: Error {
    case collectionTimedOut
}

private actor EventResultBox {
    private var events: [ResponseCoordinatorEvent]?

    func store(_ events: [ResponseCoordinatorEvent]) {
        self.events = events
    }

    func load() -> [ResponseCoordinatorEvent]? {
        events
    }
}

private struct ScriptedGenerator: ResponseGenerating {
    let quickDelay: Duration
    let deepDelay: Duration
    let quickText: String
    let turn: ConversationTurn
    let alternateTurn: ConversationTurn?
    let quickNeedsDeep: Bool
    let deepKind: DeepDraftKind
    let deepText: String

    init(
        quickDelay: Duration,
        deepDelay: Duration,
        quickText: String,
        turn: ConversationTurn,
        alternateTurn: ConversationTurn? = nil,
        quickNeedsDeep: Bool = true,
        deepKind: DeepDraftKind? = nil,
        deepText: String? = nil
    ) {
        self.quickDelay = quickDelay
        self.deepDelay = deepDelay
        self.quickText = quickText
        self.turn = turn
        self.alternateTurn = alternateTurn
        self.quickNeedsDeep = quickNeedsDeep
        self.deepKind =
            deepKind
            ?? (turn.groundingFingerprint == nil ? .generalAnswer : .answer)
        self.deepText =
            deepText
            ?? (turn.groundingFingerprint == nil
                ? "I would isolate callers from retries and downstream outages with a queued boundary."
                : "The queued boundary isolates callers from retries and downstream outages.")
    }

    func generateQuick(for requestedTurn: ConversationTurn) async throws -> QuickModelOutput {
        try await Task.sleep(for: quickDelay)
        return QuickModelOutput(
            turnID: requestedTurn.identity.turnID,
            generation: requestedTurn.identity.generation,
            sayNow: quickText,
            needsDeep: quickNeedsDeep,
            confidence: 0.72,
            reason: "technical_question"
        )
    }

    func generateDeep(for requestedTurn: ConversationTurn) async throws -> DeepDraft {
        try await Task.sleep(for: deepDelay)
        let reference = EvidenceReference(
            repoAlias: requestedTurn.repoAlias ?? "sample",
            relativePath: "Sources/Pipeline.swift",
            startLine: 10,
            endLine: 18,
            fileHash: "file-hash",
            claim: "The boundary queues downstream work."
        )
        let basis =
            deepKind == .answer
            ? [reference]
            : []
        return DeepDraft(
            turnID: requestedTurn.identity.turnID,
            generation: requestedTurn.identity.generation,
            groundingFingerprint: requestedTurn.groundingFingerprint,
            kind: deepKind,
            candidateSayNext: deepText,
            confidence: 0.91,
            basis: basis
        )
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
    }
}

private struct HangingGenerator: ResponseGenerating {
    enum Stage: Sendable {
        case quick
        case deep
        case reconcile
    }

    let hangingStage: Stage

    func generateQuick(for requestedTurn: ConversationTurn) async throws -> QuickModelOutput {
        if hangingStage == .quick {
            return await suspendForever()
        }
        return QuickModelOutput(
            turnID: requestedTurn.identity.turnID,
            generation: requestedTurn.identity.generation,
            sayNow: "I can explain the boundary.",
            needsDeep: true,
            confidence: 0.8,
            reason: "technical_question"
        )
    }

    func generateDeep(for requestedTurn: ConversationTurn) async throws -> DeepDraft {
        if hangingStage == .deep {
            return await suspendForever()
        }
        return DeepDraft(
            turnID: requestedTurn.identity.turnID,
            generation: requestedTurn.identity.generation,
            groundingFingerprint: requestedTurn.groundingFingerprint,
            kind: requestedTurn.groundingFingerprint == nil ? .generalAnswer : .answer,
            candidateSayNext: requestedTurn.groundingFingerprint == nil
                ? "I would isolate downstream work from the caller with a queued boundary."
                : "The queued boundary isolates downstream work from the caller.",
            confidence: 0.9,
            basis: requestedTurn.groundingFingerprint == nil
                ? []
                : [
                    EvidenceReference(
                        repoAlias: requestedTurn.repoAlias ?? "sample",
                        relativePath: "Sources/Pipeline.swift",
                        startLine: 10,
                        endLine: 18,
                        fileHash: "file-hash",
                        claim: "The boundary queues downstream work."
                    )
                ]
        )
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        if hangingStage == .reconcile {
            return await suspendForever()
        }
        return Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
    }

    private func suspendForever<Value: Sendable>() async -> Value {
        await withUnsafeContinuation { (_: UnsafeContinuation<Value, Never>) in }
    }
}

private struct FailingDeepGenerator: ResponseGenerating {
    let error: MeetingResponseError

    func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        throw error
    }

    func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        throw error
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        throw error
    }
}

private struct CancellationResistantLateGenerator: ResponseGenerating {
    func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        throw MeetingResponseError.runtimeUnavailable
    }

    func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        try? await Task.sleep(for: .milliseconds(80))
        return DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I would keep the late provider output in the cleanup audit.",
            confidence: 0.9,
            basis: []
        )
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        Reconciliation(relationship: .continueAnswer, transition: "")
    }
}

private struct QuickCleanupControlledGenerator: ResponseGenerating {
    let turn: ConversationTurn
    let cleanupGate: QuickCleanupGate?
    let cleanupError: (any Error & Sendable)?

    init(
        turn: ConversationTurn,
        cleanupGate: QuickCleanupGate? = nil,
        cleanupError: (any Error & Sendable)? = nil
    ) {
        self.turn = turn
        self.cleanupGate = cleanupGate
        self.cleanupError = cleanupError
    }

    func generateQuick(for requestedTurn: ConversationTurn) async throws -> QuickModelOutput {
        QuickModelOutput(
            turnID: requestedTurn.identity.turnID,
            generation: requestedTurn.identity.generation,
            sayNow: "I would separate the immediate decision from the implementation details.",
            needsDeep: true,
            confidence: 0.8,
            reason: "technical_question"
        )
    }

    func awaitQuickCleanup(for identity: TurnIdentity) async throws {
        if let cleanupGate { await cleanupGate.suspend() }
        if let cleanupError { throw cleanupError }
    }

    func generateDeep(for requestedTurn: ConversationTurn) async throws -> DeepDraft {
        DeepDraft(
            turnID: requestedTurn.identity.turnID,
            generation: requestedTurn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I would isolate the caller with a queued boundary and explicit failure handling.",
            confidence: 0.9,
            basis: []
        )
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
    }
}

private actor QuickCleanupGate {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
