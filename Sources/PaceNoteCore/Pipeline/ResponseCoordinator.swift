import Foundation

public protocol ResponseGenerating: Sendable {
    func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput
    func awaitQuickCleanup(for identity: TurnIdentity) async throws
    func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft
    func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation
}

public extension ResponseGenerating {
    func awaitQuickCleanup(for identity: TurnIdentity) async throws {}
}

public enum ResponseCoordinatorFailure: String, Equatable, Sendable {
    case rateLimited
    case providerCapacityUnavailable
    case cleanupUnavailable
    case busy
    case timedOut
    case providerUnavailable
    case responseRejected
    case groundingUnavailable
}

public enum ResponseCoordinatorEvent: Equatable, Sendable {
    case cue(CueEnvelope)
    case deep(BoundDeep)
    case quickUnavailable(ResponseCoordinatorFailure)
    case quickCleanupUnavailable(ResponseCoordinatorFailure)
    case deepUnavailable(ResponseCoordinatorFailure)
    case discardedStale(TurnIdentity)
}

public struct ResponseSensitiveOutputSnapshot: Sendable {
    public let values: [String]
    public let overflowed: Bool
}

public actor ResponseSensitiveOutputBuffer {
    private let capacity: Int
    private var values: [String] = []
    private var overflowed = false

    public init(capacity: Int = 2_048) {
        self.capacity = min(max(1, capacity), 4_096)
    }

    public func register(_ value: String) {
        guard !overflowed else { return }
        let bounded = String(decoding: value.utf8.prefix(320), as: UTF8.self)
        guard !bounded.isEmpty, !values.contains(bounded) else { return }
        guard values.count < capacity else {
            overflowed = true
            return
        }
        values.append(bounded)
    }

    public func takeSnapshotAndClear() -> ResponseSensitiveOutputSnapshot {
        let snapshot = ResponseSensitiveOutputSnapshot(values: values, overflowed: overflowed)
        values.removeAll(keepingCapacity: false)
        overflowed = false
        return snapshot
    }
}

public struct ResponseCoordinatorConfiguration: Sendable {
    public static let deterministicFallback =
        "I'd start by clarifying the goal and constraints, then walk through the tradeoffs before committing to an approach."

    public let quickDeadline: Duration
    public let resultTTL: Duration
    public let bridgeText: String

    public init(
        quickDeadline: Duration = .seconds(2),
        resultTTL: Duration = .seconds(20),
        bridgeText: String = ResponseCoordinatorConfiguration.deterministicFallback
    ) {
        self.quickDeadline = quickDeadline
        self.resultTTL = resultTTL
        self.bridgeText = bridgeText
    }

    public func bridgeText(for question: String) -> String {
        guard bridgeText == Self.deterministicFallback else { return bridgeText }
        return LocalResponseBridge.response(for: question)
    }

    public func initialCue(for turn: ConversationTurn) -> CueEnvelope {
        if bridgeText == Self.deterministicFallback,
            let answer = SpeakerBriefQuickAnswer.response(
                question: turn.question,
                brief: turn.speakerBrief
            )
        {
            return CueEnvelope(
                turnID: turn.identity.turnID,
                generation: turn.identity.generation,
                text: answer,
                reason: "speaker_brief_extract",
                isDeterministicBridge: false
            )
        }

        if bridgeText == Self.deterministicFallback,
            let answer = LocalResponseBridge.reviewedTechnicalResponse(for: turn.question)
        {
            return CueEnvelope(
                turnID: turn.identity.turnID,
                generation: turn.identity.generation,
                text: answer,
                reason: "reviewed_local_technical_answer",
                isDeterministicBridge: false
            )
        }

        return CueEnvelope(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            text: bridgeText(for: turn.question),
            reason: "instant_local_bridge",
            isDeterministicBridge: true
        )
    }
}

public actor ResponseCoordinator {
    private struct ActiveResponse: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let generator: any ResponseGenerating
    private let configuration: ResponseCoordinatorConfiguration
    private let sensitiveOutputBuffer: ResponseSensitiveOutputBuffer?
    private var activeResponses: [TurnIdentity: ActiveResponse] = [:]

    public init(
        generator: any ResponseGenerating,
        configuration: ResponseCoordinatorConfiguration = .init(),
        sensitiveOutputBuffer: ResponseSensitiveOutputBuffer? = nil
    ) {
        self.generator = generator
        self.configuration = configuration
        self.sensitiveOutputBuffer = sensitiveOutputBuffer
    }

    deinit {
        for response in activeResponses.values {
            response.task.cancel()
        }
    }

    public func suggestions(for turn: ConversationTurn) -> AsyncStream<ResponseCoordinatorEvent> {
        activeResponses[turn.identity]?.task.cancel()
        let token = UUID()

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.run(turn: turn, continuation: continuation)
                await self.finishResponse(identity: turn.identity, token: token)
            }
            activeResponses[turn.identity] = ActiveResponse(token: token, task: task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func invalidate(_ identity: TurnIdentity) async {
        guard let response = activeResponses.removeValue(forKey: identity) else { return }
        response.task.cancel()
        await response.task.value
    }

    public func invalidate() async {
        let responses = Array(activeResponses.values)
        activeResponses.removeAll(keepingCapacity: false)
        for response in responses {
            response.task.cancel()
        }
        for response in responses {
            await response.task.value
        }
    }

    private func run(
        turn: ConversationTurn,
        continuation: AsyncStream<ResponseCoordinatorEvent>.Continuation
    ) async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let resultDeadline = startedAt.advanced(by: configuration.resultTTL)
        let generator = generator
        let sensitiveOutputBuffer = sensitiveOutputBuffer
        let quickDeadline = min(
            startedAt.advanced(by: configuration.quickDeadline),
            resultDeadline
        )
        let quickOperation = Self.startOperation(
            deadline: quickDeadline,
            onValue: { output in
                await sensitiveOutputBuffer?.register(output.sayNow)
            },
            operation: { try await generator.generateQuick(for: turn) }
        )
        let deepOperation = Self.startOperation(
            deadline: resultDeadline,
            onValue: { draft in
                await sensitiveOutputBuffer?.register(draft.candidateSayNext)
            },
            operation: { try await generator.generateDeep(for: turn) }
        )

        defer { continuation.finish() }

        var cue = configuration.initialCue(for: turn)
        guard isActive(turn.identity), !Task.isCancelled else {
            quickOperation.task.cancel()
            deepOperation.task.cancel()
            await quickOperation.task.value
            await deepOperation.task.value
            continuation.yield(.discardedStale(turn.identity))
            return
        }
        continuation.yield(.cue(cue))

        var cleanupOperation: PendingOperation<QuickCleanupConfirmation>?
        await withTaskGroup(of: ResponseOperationOutcome.self) { group in
            group.addTask {
                .quick(
                    await Self.outcome(
                        from: quickOperation.gate,
                        deadline: quickDeadline
                    )
                )
            }
            group.addTask {
                .deep(
                    await Self.outcome(
                        from: deepOperation.gate,
                        deadline: resultDeadline
                    )
                )
            }

            var deepWasDisplayed = false
            for await outcome in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch outcome {
                case .quick(let result):
                    var quickFailure: ResponseCoordinatorFailure?
                    switch result {
                    case .success(let output) where output.reason == "deterministic_safety_bridge":
                        break
                    case .success(let output) where Self.valid(output, for: turn):
                        if !deepWasDisplayed {
                            let candidate = CueEnvelope(
                                turnID: turn.identity.turnID,
                                generation: turn.identity.generation,
                                text: Self.limitWords(output.sayNow, maximum: 24),
                                reason: output.reason,
                                isDeterministicBridge: false
                            )
                            if candidate.textHash != cue.textHash {
                                cue = candidate
                                continuation.yield(.cue(cue))
                            }
                        }
                    case .success:
                        quickFailure = .responseRejected
                    case .failure(let failure):
                        quickFailure = failure
                    case .timedOut:
                        quickOperation.task.cancel()
                        quickFailure = .timedOut
                    case .cancelled:
                        quickFailure = .providerUnavailable
                    }
                    if let quickFailure {
                        continuation.yield(.quickUnavailable(quickFailure))
                    }

                    let operation = Self.startOperation(
                        deadline: resultDeadline,
                        operation: {
                            try await generator.awaitQuickCleanup(for: turn.identity)
                            return QuickCleanupConfirmation()
                        }
                    )
                    cleanupOperation = operation
                    group.addTask {
                        .quickCleanup(
                            await Self.outcome(
                                from: operation.gate,
                                deadline: resultDeadline
                            )
                        )
                    }

                case .deep(let result):
                    deepWasDisplayed = emitDeepResult(
                        result,
                        turn: turn,
                        cue: cue,
                        deadline: resultDeadline,
                        continuation: continuation
                    )
                case .quickCleanup(let result):
                    emitQuickCleanupResult(result, continuation: continuation)
                }
            }
        }

        let cancellationMustDrain = Task.isCancelled
        quickOperation.task.cancel()
        deepOperation.task.cancel()
        cleanupOperation?.task.cancel()
        if cancellationMustDrain {
            await quickOperation.task.value
            await deepOperation.task.value
            await cleanupOperation?.task.value
        }
    }

    private func emitDeepResult(
        _ result: DeadlineOutcome<DeepDraft>,
        turn: ConversationTurn,
        cue: CueEnvelope,
        deadline: ContinuousClock.Instant,
        continuation: AsyncStream<ResponseCoordinatorEvent>.Continuation
    ) -> Bool {
        guard isActive(turn.identity), !Task.isCancelled else {
            continuation.yield(.discardedStale(turn.identity))
            return false
        }

        switch result {
        case .failure(let failure):
            continuation.yield(.deepUnavailable(failure))
            return false
        case .timedOut:
            continuation.yield(.deepUnavailable(.timedOut))
            return false
        case .cancelled:
            continuation.yield(.deepUnavailable(.providerUnavailable))
            return false
        case .success(let receivedDraft):
            guard ContinuousClock().now <= deadline else {
                continuation.yield(.discardedStale(turn.identity))
                return false
            }
            guard let draft = DeepDraftValidationPolicy.normalized(receivedDraft, for: turn) else {
                continuation.yield(.deepUnavailable(.responseRejected))
                return false
            }

            let reconciliation = Self.reconciliation(cue: cue, draft: draft)
            guard isActive(turn.identity), !Task.isCancelled,
                ContinuousClock().now <= deadline
            else {
                continuation.yield(.discardedStale(turn.identity))
                return false
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
                    continuation.yield(.deepUnavailable(.responseRejected))
                    return false
                }
                continuation.yield(.deep(bound))
                return true
            } catch {
                continuation.yield(.deepUnavailable(Self.classify(error)))
                return false
            }
        }
    }

    private func emitQuickCleanupResult(
        _ result: DeadlineOutcome<QuickCleanupConfirmation>,
        continuation: AsyncStream<ResponseCoordinatorEvent>.Continuation
    ) {
        switch result {
        case .success:
            break
        case .failure(let failure):
            continuation.yield(.quickCleanupUnavailable(failure))
        case .timedOut:
            continuation.yield(.quickCleanupUnavailable(.timedOut))
        case .cancelled:
            if !Task.isCancelled {
                continuation.yield(.quickCleanupUnavailable(.providerUnavailable))
            }
        }
    }

    private nonisolated static func outcome<Value: Sendable>(
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

    private static func reconciliation(cue: CueEnvelope, draft: DeepDraft) -> Reconciliation {
        switch draft.kind {
        case .answer:
            Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
        case .generalAnswer:
            Reconciliation(
                relationship: .continueAnswer,
                transition: cue.isDeterministicBridge ? "" : "More specifically,"
            )
        case .clarification:
            Reconciliation(relationship: .clarify, transition: "The detail I need is:")
        case .abstention:
            Reconciliation(relationship: .abstain, transition: "I cannot verify that yet.")
        }
    }

    private nonisolated static func startOperation<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        onValue: @escaping @Sendable (Value) async -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> Value
    ) -> PendingOperation<Value> {
        let gate = DeadlineGate<Value>()
        let task = Task {
            do {
                let value = try await operation()
                await onValue(value)
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
                await gate.resolve(.failure(classify(error)))
            }
        }
        return PendingOperation(gate: gate, task: task)
    }

    private func isActive(_ identity: TurnIdentity) -> Bool {
        activeResponses[identity] != nil
    }

    private func finishResponse(identity: TurnIdentity, token: UUID) {
        guard activeResponses[identity]?.token == token else { return }
        activeResponses.removeValue(forKey: identity)
    }

    private static func valid(_ output: QuickModelOutput, for turn: ConversationTurn) -> Bool {
        guard output.turnID == turn.identity.turnID,
            output.generation == turn.identity.generation,
            !output.sayNow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            wordCount(output.sayNow) <= 24,
            output.confidence.isFinite,
            (0...1).contains(output.confidence),
            !output.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            GeneralGuidancePolicy.accepts(output.sayNow)
        else {
            return false
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

    private static func classify(_ error: any Error) -> ResponseCoordinatorFailure {
        guard let responseError = error as? MeetingResponseError else {
            return .providerUnavailable
        }
        switch responseError {
        case .providerCapacityUnavailable:
            return .providerCapacityUnavailable
        case .quickRateLimited, .deepRateLimited:
            return .rateLimited
        case .deepAlreadyActive:
            return .busy
        case .invalidOutput:
            return .responseRejected
        case .groundingUnavailable, .groundingMismatch, .skillPolicyMismatch:
            return .groundingUnavailable
        case .cleanupFailed:
            return .cleanupUnavailable
        case .signInRequired, .credentialStoreUnavailable, .accountMismatch,
            .protocolUnsupported, .runtimeUnavailable, .notPrepared:
            return .providerUnavailable
        }
    }
}

private enum DeadlineOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(ResponseCoordinatorFailure)
    case timedOut
    case cancelled
}

private struct QuickCleanupConfirmation: Sendable {}

private enum ResponseOperationOutcome: Sendable {
    case quick(DeadlineOutcome<QuickModelOutput>)
    case deep(DeadlineOutcome<DeepDraft>)
    case quickCleanup(DeadlineOutcome<QuickCleanupConfirmation>)
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
