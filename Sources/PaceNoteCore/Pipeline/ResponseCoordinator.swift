import Foundation

public protocol ResponseGenerating: Sendable {
    func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput
    func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft
    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation
}

public enum ResponseCoordinatorEvent: Equatable, Sendable {
    case cue(CueEnvelope)
    case deep(BoundDeep)
    case quickUnavailable(String)
    case deepUnavailable(String)
    case discardedStale(TurnIdentity)
}

public struct ResponseCoordinatorConfiguration: Sendable {
    public let quickDeadline: Duration
    public let resultTTL: Duration
    public let bridgeText: String

    public init(
        quickDeadline: Duration = .seconds(2),
        resultTTL: Duration = .seconds(20),
        bridgeText: String = "Let me think through that carefully for a second."
    ) {
        self.quickDeadline = quickDeadline
        self.resultTTL = resultTTL
        self.bridgeText = bridgeText
    }
}

public actor ResponseCoordinator {
    private let generator: any ResponseGenerating
    private let configuration: ResponseCoordinatorConfiguration
    private var activeIdentity: TurnIdentity?
    private var activeTask: Task<Void, Never>?

    public init(
        generator: any ResponseGenerating,
        configuration: ResponseCoordinatorConfiguration = .init()
    ) {
        self.generator = generator
        self.configuration = configuration
    }

    deinit {
        activeTask?.cancel()
    }

    public func suggestions(for turn: ConversationTurn) -> AsyncStream<ResponseCoordinatorEvent> {
        activeTask?.cancel()
        activeIdentity = turn.identity

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.run(turn: turn, continuation: continuation)
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func invalidate() {
        activeTask?.cancel()
        activeTask = nil
        activeIdentity = nil
    }

    private func run(
        turn: ConversationTurn,
        continuation: AsyncStream<ResponseCoordinatorEvent>.Continuation
    ) async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let resultDeadline = startedAt.advanced(by: configuration.resultTTL)
        let generator = generator
        let deepOperation = Self.startOperation(deadline: resultDeadline) {
            try await generator.generateDeep(for: turn)
        }

        defer {
            deepOperation.task.cancel()
            continuation.finish()
        }

        // Meeting text is untrusted and no lexical topic classifier can reliably prove that a
        // model-written Quick response is non-factual. Always display a local, immutable bridge
        // immediately and continue to Deep. This is both faster and fail-closed: model output can
        // neither become the first spoken cue nor suppress the grounded answer.
        let cue = bridge(for: turn.identity, reason: "deterministic_safety_bridge")

        guard isCurrent(turn.identity), !Task.isCancelled else {
            continuation.yield(.discardedStale(turn.identity))
            return
        }
        continuation.yield(.cue(cue))

        let deepResult = await outcome(from: deepOperation.gate, deadline: resultDeadline)
        guard isCurrent(turn.identity), !Task.isCancelled else {
            continuation.yield(.discardedStale(turn.identity))
            return
        }

        switch deepResult {
        case .failure(let error):
            continuation.yield(.deepUnavailable(error))
        case .timedOut:
            deepOperation.task.cancel()
            continuation.yield(.discardedStale(turn.identity))
        case .cancelled:
            continuation.yield(.deepUnavailable("Cancelled"))
        case .success(let draft):
            guard clock.now <= resultDeadline else {
                continuation.yield(.discardedStale(turn.identity))
                return
            }
            guard Self.valid(draft, for: turn) else {
                continuation.yield(.deepUnavailable("Deep returned an invalid or mismatched envelope."))
                return
            }

            guard
                let reconciliation = await reconcile(
                    cue: cue,
                    draft: draft,
                    deadline: resultDeadline,
                    continuation: continuation,
                    identity: turn.identity
                )
            else {
                return
            }

            guard isCurrent(turn.identity), !Task.isCancelled,
                clock.now <= resultDeadline
            else {
                continuation.yield(.discardedStale(turn.identity))
                return
            }

            do {
                let bound = BoundDeep(
                    turnID: turn.identity.turnID,
                    generation: turn.identity.generation,
                    cueID: cue.id,
                    cueHash: cue.textHash,
                    deepDraftHash: try BoundDeep.draftHash(draft),
                    groundingFingerprint: draft.groundingFingerprint,
                    kind: draft.kind,
                    relationship: reconciliation.relationship,
                    transition: Self.limitWords(reconciliation.transition, maximum: 7),
                    sayNext: Self.safeSayNext(for: draft),
                    basis: draft.basis
                )
                guard Self.wordCount(bound.composedText) <= 40 else {
                    continuation.yield(.deepUnavailable("Bound Deep exceeded the speakable word limit."))
                    return
                }
                continuation.yield(.deep(bound))
            } catch {
                continuation.yield(.deepUnavailable(Self.safeError(error)))
            }
        }
    }

    private func outcome<Value: Sendable>(
        from gate: DeadlineGate<Value>,
        deadline: ContinuousClock.Instant
    ) async -> DeadlineOutcome<Value> {
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(until: deadline)
                await gate.resolve(.timedOut)
            } catch is CancellationError {
                return
            } catch {
                await gate.resolve(.timedOut)
            }
        }
        defer { timeoutTask.cancel() }

        return await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            Task { await gate.resolve(.cancelled) }
        }
    }

    private func reconcile(
        cue: CueEnvelope,
        draft: DeepDraft,
        deadline: ContinuousClock.Instant,
        continuation: AsyncStream<ResponseCoordinatorEvent>.Continuation,
        identity: TurnIdentity
    ) async -> Reconciliation? {
        if cue.isDeterministicBridge {
            switch draft.kind {
            case .answer:
                return Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
            case .generalAnswer:
                return Reconciliation(relationship: .continueAnswer, transition: "Broadly speaking,")
            case .clarification:
                return Reconciliation(relationship: .clarify, transition: "The detail I need is:")
            case .abstention:
                return Reconciliation(relationship: .abstain, transition: "I cannot verify that yet.")
            }
        }

        guard ContinuousClock().now <= deadline else {
            continuation.yield(.discardedStale(identity))
            return nil
        }

        let generator = generator
        let operation = Self.startOperation(deadline: deadline) {
            try await generator.reconcile(cue: cue, draft: draft)
        }
        defer { operation.task.cancel() }

        switch await outcome(from: operation.gate, deadline: deadline) {
        case .success(let reconciliation):
            return reconciliation
        case .failure(let error):
            continuation.yield(.deepUnavailable(error))
        case .timedOut:
            continuation.yield(.discardedStale(identity))
        case .cancelled:
            if !Task.isCancelled {
                continuation.yield(.deepUnavailable("Cancelled"))
            }
        }
        return nil
    }

    private nonisolated static func startOperation<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> Value
    ) -> PendingOperation<Value> {
        let gate = DeadlineGate<Value>()
        let task = Task {
            do {
                let value = try await operation()
                guard ContinuousClock().now <= deadline else {
                    await gate.resolve(.timedOut)
                    return
                }
                await gate.resolve(.success(value))
            } catch is CancellationError {
                await gate.resolve(.cancelled)
            } catch {
                guard ContinuousClock().now <= deadline else {
                    await gate.resolve(.timedOut)
                    return
                }
                await gate.resolve(.failure(safeError(error)))
            }
        }
        return PendingOperation(gate: gate, task: task)
    }

    private func bridge(for identity: TurnIdentity, reason: String) -> CueEnvelope {
        CueEnvelope(
            turnID: identity.turnID,
            generation: identity.generation,
            text: configuration.bridgeText,
            reason: reason,
            isDeterministicBridge: true
        )
    }

    private func isCurrent(_ identity: TurnIdentity) -> Bool {
        activeIdentity == identity
    }

    private static func valid(_ draft: DeepDraft, for turn: ConversationTurn) -> Bool {
        guard draft.turnID == turn.identity.turnID,
            draft.generation == turn.identity.generation,
            !draft.candidateSayNext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            wordCount(draft.candidateSayNext) <= 33,
            (0...1).contains(draft.confidence),
            draft.groundingFingerprint == turn.groundingFingerprint
        else {
            return false
        }

        let isGrounded = turn.repoAlias != nil || turn.groundingFingerprint != nil
        guard (turn.repoAlias != nil) == (turn.groundingFingerprint != nil) else { return false }
        if isGrounded {
            guard draft.kind != .generalAnswer else { return false }
            if draft.kind == .answer { return !draft.basis.isEmpty }
            return draft.basis.isEmpty
        }
        guard draft.kind != .answer, draft.basis.isEmpty else { return false }
        if draft.kind == .generalAnswer {
            return GeneralGuidancePolicy.accepts(draft.candidateSayNext)
        }
        return true
    }

    private static func limitWords(_ text: String, maximum: Int) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).prefix(maximum).joined(separator: " ")
    }

    private static func safeSayNext(for draft: DeepDraft) -> String {
        switch draft.kind {
        case .answer:
            limitWords(draft.candidateSayNext, maximum: 33)
        case .generalAnswer:
            limitWords(draft.candidateSayNext, maximum: 33)
        case .clarification:
            draft.groundingFingerprint == nil
                ? "Could you clarify which system or constraint you mean?"
                : "I need one more detail before I can verify that."
        case .abstention:
            draft.groundingFingerprint == nil
                ? "I do not have enough context to answer that safely."
                : "I cannot verify that from the available repository evidence."
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func safeError(_ error: any Error) -> String {
        if error is CancellationError { return "Cancelled" }
        return String(describing: error).prefix(160).description
    }
}

private enum DeadlineOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
    case timedOut
    case cancelled
}

private struct PendingOperation<Value: Sendable>: Sendable {
    let gate: DeadlineGate<Value>
    let task: Task<Void, Never>
}

private actor DeadlineGate<Value: Sendable> {
    private var outcome: DeadlineOutcome<Value>?
    private var continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>?

    func resolve(_ outcome: DeadlineOutcome<Value>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func value() async -> DeadlineOutcome<Value> {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
