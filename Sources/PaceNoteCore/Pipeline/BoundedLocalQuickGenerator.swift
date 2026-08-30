import Foundation

/// Gives an optional local model a short chance to improve the instant cue without letting an
/// unresponsive on-device runtime consume the provider Quick window.
///
/// A timed-out attempt is canceled and retained until the normal identity-scoped cleanup path
/// joins it. The circuit stays open for the rest of the meeting so later questions can reach the
/// subscription Quick lane immediately.
public actor BoundedLocalQuickGenerator: LocalQuickGenerating {
    private struct ActiveAttempt: Sendable {
        let identity: TurnIdentity
        let task: Task<Void, Never>
    }

    private let base: any LocalQuickGenerating
    private let waitForDeadline: @Sendable () async throws -> Void
    private var activeAttempts: [UUID: ActiveAttempt] = [:]
    private var localModelDegraded = false

    public init(
        base: any LocalQuickGenerating,
        timeout: Duration = .seconds(3)
    ) {
        self.base = base
        let boundedTimeout = timeout > .zero ? timeout : .milliseconds(1)
        self.waitForDeadline = {
            try await ContinuousClock().sleep(for: boundedTimeout)
        }
    }

    init(
        base: any LocalQuickGenerating,
        waitForDeadline: @escaping @Sendable () async throws -> Void
    ) {
        self.base = base
        self.waitForDeadline = waitForDeadline
    }

    deinit {
        for attempt in activeAttempts.values {
            attempt.task.cancel()
        }
    }

    public func prepare() async -> CodexModelRoute {
        localModelDegraded = false
        return await base.prepare()
    }

    public func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        try Task.checkCancellation()
        guard !localModelDegraded else { return Self.fallback(for: turn) }

        let gate = BoundedLocalQuickOutcomeGate()
        let attemptID = UUID()
        let base = base
        let operationTask = Task { [weak self] in
            let outcome: BoundedLocalQuickOutcome
            do {
                outcome = .success(try await base.generateQuick(for: turn))
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed
            }
            await gate.resolve(outcome)
            await self?.finishAttempt(attemptID)
        }
        activeAttempts[attemptID] = ActiveAttempt(
            identity: turn.identity,
            task: operationTask
        )

        let waitForDeadline = waitForDeadline
        let timeoutTask = Task {
            do {
                try await waitForDeadline()
                await gate.resolve(.timedOut)
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }

        let outcome = await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            operationTask.cancel()
            Task { await gate.resolve(.cancelled) }
        }

        switch outcome {
        case .success(let output):
            return output
        case .timedOut:
            localModelDegraded = true
            operationTask.cancel()
            return Self.fallback(for: turn)
        case .failed:
            localModelDegraded = true
            return Self.fallback(for: turn)
        case .cancelled:
            try Task.checkCancellation()
            localModelDegraded = true
            return Self.fallback(for: turn)
        }
    }

    public func awaitCleanup(for identity: TurnIdentity) async {
        let attempts = activeAttempts.filter { $0.value.identity == identity }
        for attempt in attempts.values {
            attempt.task.cancel()
        }
        await base.awaitCleanup(for: identity)
        for (id, attempt) in attempts {
            await attempt.task.value
            activeAttempts.removeValue(forKey: id)
        }
    }

    public func cancelActiveWork() async {
        let attempts = activeAttempts
        for attempt in attempts.values {
            attempt.task.cancel()
        }
        await base.cancelActiveWork()
        for attempt in attempts.values {
            await attempt.task.value
        }
        activeAttempts.removeAll(keepingCapacity: false)
    }

    private func finishAttempt(_ id: UUID) {
        activeAttempts.removeValue(forKey: id)
    }

    private static func fallback(for turn: ConversationTurn) -> QuickModelOutput {
        QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: LocalResponseBridge.response(for: turn.question),
            needsDeep: true,
            confidence: 1,
            reason: "deterministic_safety_bridge"
        )
    }
}

private enum BoundedLocalQuickOutcome: Sendable {
    case success(QuickModelOutput)
    case failed
    case cancelled
    case timedOut
}

private actor BoundedLocalQuickOutcomeGate {
    private var outcome: BoundedLocalQuickOutcome?
    private var continuation: CheckedContinuation<BoundedLocalQuickOutcome, Never>?

    func resolve(_ outcome: BoundedLocalQuickOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func value() async -> BoundedLocalQuickOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
