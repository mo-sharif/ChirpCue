import Foundation

/// Decouples immediate coaching from subscription-provider startup and generation latency.
/// Quick responses stay local; the selected subscription provider prepares and reasons in parallel.
public actor LowLatencyMeetingResponseGenerator: MeetingResponseGenerating {
    private enum QuickPathDecision: Sendable {
        case localSatisfied
        case providerNeeded
        case unavailable
    }

    private enum Lifecycle: Sendable {
        case open
        case closing
        case closed
    }

    private let provider: any MeetingResponseGenerating
    private let quickGenerator: any LocalQuickGenerating
    private let planType: String?
    private let pendingDeepRoute: CodexModelRoute
    private let providerRetryDelay: Duration
    private let providerQuickHeadStart: Duration
    private let quickPathDecisionWindow: Duration

    private var lifecycle = Lifecycle.open
    private var quickRoute = FoundationModelQuickGenerator.deterministicRoute
    private var providerRuntime: MeetingResponseRuntime?
    private var providerFailure: MeetingResponseError?
    private var providerPreparationTask: Task<Void, Never>?
    private var preparationWaiters: [UUID: AsyncThrowingStream<MeetingResponseRuntime, Error>.Continuation] = [:]
    private var activeProviderCalls = 0
    private var providerQuickIdentities: Set<TurnIdentity> = []
    private var quickPathDecisions: [TurnIdentity: QuickPathDecision] = [:]
    private var shutdownTask: Task<MeetingResponseCleanupReport, Never>?
    private var lastShutdownReport: MeetingResponseCleanupReport?

    public init(
        provider: any MeetingResponseGenerating,
        quickGenerator: any LocalQuickGenerating,
        planType: String?,
        providerName: String,
        providerRetryDelay: Duration = .seconds(1),
        providerQuickHeadStart: Duration = .seconds(1),
        quickPathDecisionWindow: Duration = .milliseconds(25)
    ) {
        self.provider = provider
        self.quickGenerator = quickGenerator
        self.planType = planType
        self.pendingDeepRoute = CodexModelRoute(
            model: "\(providerName)-subscription",
            effort: "high"
        )
        self.providerRetryDelay = providerRetryDelay
        self.providerQuickHeadStart = providerQuickHeadStart
        self.quickPathDecisionWindow = quickPathDecisionWindow
    }

    deinit {
        providerPreparationTask?.cancel()
    }

    public func prepare() async throws -> MeetingResponseRuntime {
        try requireOpen()
        quickRoute = await quickGenerator.prepare()
        startProviderPreparationIfNeeded()
        return MeetingResponseRuntime(
            planType: planType,
            quickRoute: quickRoute,
            deepRoute: providerRuntime?.deepRoute ?? pendingDeepRoute,
            usesRealtimeQuick: false
        )
    }

    public func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        try requireOpen()
        let local: QuickModelOutput
        do {
            local = try await quickGenerator.generateQuick(for: turn)
        } catch {
            quickPathDecisions[turn.identity] = .unavailable
            throw error
        }
        quickPathDecisions[turn.identity] =
            local.reason == "deterministic_safety_bridge" ? .providerNeeded : .localSatisfied
        guard local.reason == "deterministic_safety_bridge" else { return local }

        do {
            let runtime = try await waitForProviderRuntime()
            try Task.checkCancellation()
            guard Self.supportsGeneratedQuick(runtime) else { return local }

            activeProviderCalls += 1
            do {
                let generated = try await provider.generateQuick(for: turn)
                activeProviderCalls -= 1
                providerQuickIdentities.insert(turn.identity)
                return generated
            } catch {
                activeProviderCalls -= 1
                if error is CancellationError { throw CancellationError() }
                return local
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return local
        }
    }

    public func awaitQuickCleanup(for identity: TurnIdentity) async throws {
        defer { quickPathDecisions.removeValue(forKey: identity) }
        await quickGenerator.awaitCleanup(for: identity)
        guard providerQuickIdentities.remove(identity) != nil else { return }
        try await provider.awaitQuickCleanup(for: identity)
    }

    public func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        try requireOpen()
        let runtime = try await waitForProviderRuntime()
        if Self.supportsGeneratedQuick(runtime) {
            let quickDecision = await quickPathDecision(for: turn.identity)
            if quickDecision == .providerNeeded {
                try await Task.sleep(for: providerQuickHeadStart)
            }
        }
        quickPathDecisions.removeValue(forKey: turn.identity)
        try Task.checkCancellation()
        activeProviderCalls += 1
        do {
            let draft = try await provider.generateDeep(for: turn)
            activeProviderCalls -= 1
            return draft
        } catch {
            activeProviderCalls -= 1
            throw error
        }
    }

    public func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        try requireOpen()
        _ = try await waitForProviderRuntime()
        try Task.checkCancellation()
        activeProviderCalls += 1
        do {
            let result = try await provider.reconcile(cue: cue, draft: draft)
            activeProviderCalls -= 1
            return result
        } catch {
            activeProviderCalls -= 1
            throw error
        }
    }

    public func cancelActiveWork() async {
        await quickGenerator.cancelActiveWork()
        if activeProviderCalls > 0 {
            await provider.cancelActiveWork()
        }
    }

    public func shutdown() async -> MeetingResponseCleanupReport {
        if let shutdownTask { return await shutdownTask.value }
        if let lastShutdownReport { return lastShutdownReport }
        lifecycle = .closing
        finishWaiters(throwing: CancellationError())
        providerPreparationTask?.cancel()
        await quickGenerator.cancelActiveWork()

        let provider = provider
        let task = Task { await provider.shutdown() }
        shutdownTask = task
        let report = await task.value
        providerPreparationTask = nil
        providerRuntime = nil
        providerFailure = nil
        providerQuickIdentities.removeAll()
        quickPathDecisions.removeAll()
        lifecycle = .closed
        shutdownTask = nil
        lastShutdownReport = report
        return report
    }

    private func startProviderPreparationIfNeeded() {
        guard lifecycle == .open,
            providerRuntime == nil,
            providerPreparationTask == nil
        else { return }

        providerFailure = nil
        let provider = provider
        let retryDelay = providerRetryDelay
        providerPreparationTask = Task {
            let outcome: Result<MeetingResponseRuntime, MeetingResponseError>
            while true {
                do {
                    outcome = .success(try await provider.prepare())
                    break
                } catch is CancellationError {
                    outcome = .failure(.runtimeUnavailable)
                    break
                } catch let error as MeetingResponseError where error == .runtimeUnavailable {
                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        outcome = .failure(.runtimeUnavailable)
                        break
                    }
                } catch let error as MeetingResponseError {
                    outcome = .failure(error)
                    break
                } catch {
                    outcome = .failure(.runtimeUnavailable)
                    break
                }
            }
            completeProviderPreparation(outcome)
        }
    }

    private func completeProviderPreparation(
        _ outcome: Result<MeetingResponseRuntime, MeetingResponseError>
    ) {
        providerPreparationTask = nil
        guard lifecycle == .open else {
            finishWaiters(throwing: CancellationError())
            return
        }
        switch outcome {
        case .success(let runtime):
            providerRuntime = runtime
            providerFailure = nil
            let waiters = preparationWaiters.values
            preparationWaiters.removeAll()
            for waiter in waiters {
                waiter.yield(runtime)
                waiter.finish()
            }
        case .failure(let error):
            providerRuntime = nil
            providerFailure = error
            finishWaiters(throwing: error)
        }
    }

    private func waitForProviderRuntime() async throws -> MeetingResponseRuntime {
        if let providerRuntime { return providerRuntime }
        if let providerFailure {
            self.providerFailure = nil
            throw providerFailure
        }
        startProviderPreparationIfNeeded()

        let waiterID = UUID()
        let stream = AsyncThrowingStream<MeetingResponseRuntime, Error> { continuation in
            preparationWaiters[waiterID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeWaiter(waiterID) }
            }
        }
        for try await runtime in stream {
            return runtime
        }
        throw CancellationError()
    }

    private func removeWaiter(_ id: UUID) {
        preparationWaiters.removeValue(forKey: id)
    }

    private func finishWaiters(throwing error: any Error) {
        let waiters = preparationWaiters.values
        preparationWaiters.removeAll()
        for waiter in waiters {
            waiter.finish(throwing: error)
        }
    }

    private func requireOpen() throws {
        guard lifecycle == .open else { throw MeetingResponseError.runtimeUnavailable }
    }

    private func quickPathDecision(for identity: TurnIdentity) async -> QuickPathDecision? {
        if let decision = quickPathDecisions[identity] { return decision }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: quickPathDecisionWindow)
        while clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return .unavailable
            }
            if let decision = quickPathDecisions[identity] { return decision }
        }
        return quickPathDecisions[identity]
    }

    private static func supportsGeneratedQuick(_ runtime: MeetingResponseRuntime) -> Bool {
        switch runtime.quickRoute.model {
        case "local-deterministic-bridge", "instant-local-fallback", "apple-on-device":
            false
        default:
            true
        }
    }
}
