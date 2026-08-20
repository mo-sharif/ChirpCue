import Foundation

public actor MeetingSessionController {
    struct DelayedAttributionRetentionSnapshot: Equatable, Sendable {
        let hasAttributionTask: Bool
        let hasPendingMicrophoneObservation: Bool
        let hasLatestOutputObservation: Bool
    }

    struct BridgeSpeechRetentionSnapshot: Equatable, Sendable {
        let hasActiveHold: Bool
        let hasQueuedDeep: Bool
    }

    private struct AudioServiceTeardownFailure: Error, Sendable {
        let lanes: [AudioLane]
    }

    private struct TranscriptObservation: Sendable {
        let result: ProgressiveTranscriptResult
        let receivedAt: TimeInterval
    }

    private struct PendingMicrophoneObservation: Sendable {
        let id: UUID
        let observation: TranscriptObservation
    }

    private struct BridgeSpeechHold: Sendable {
        let identity: TurnIdentity
        let bridgeText: String
    }

    private struct QueuedDeepResponse: Sendable {
        let identity: TurnIdentity
        let response: BoundDeep
    }

    private struct ResponseCancellationOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct CleanupNeedleSnapshot: Sendable {
        var needles: [Data]
        let overflowed: Bool

        mutating func clear() {
            Self.zero(&needles)
        }

        private static func zero(_ needles: inout [Data]) {
            for index in needles.indices {
                needles[index].resetBytes(
                    in: needles[index].startIndex..<needles[index].endIndex
                )
                needles[index].removeAll(keepingCapacity: false)
            }
            needles.removeAll(keepingCapacity: false)
        }
    }

    private struct CleanupNeedleLedger: Sendable {
        static let defaultCapacity = 2_048
        static let maximumCapacity = 4_096
        private static let maximumNeedleBytes = 128
        private static let minimumNeedleBytes = 8

        private let capacity: Int
        private var needles: [Data] = []
        private(set) var overflowed = false

        init(capacity: Int = defaultCapacity) {
            self.capacity = min(max(1, capacity), Self.maximumCapacity)
            needles.reserveCapacity(min(self.capacity, 64))
        }

        mutating func register(_ text: String) {
            guard !overflowed else { return }
            let normalized = MeetingSessionController.normalized(text)
            let fragment = Data(normalized.utf8.prefix(Self.maximumNeedleBytes))
            guard fragment.count >= Self.minimumNeedleBytes,
                !needles.contains(fragment)
            else {
                return
            }
            guard needles.count < capacity else {
                overflowed = true
                return
            }
            needles.append(fragment)
        }

        mutating func takeSnapshotAndClear() -> CleanupNeedleSnapshot {
            let snapshot = CleanupNeedleSnapshot(
                needles: needles.map { needle in
                    var copy = Data(capacity: needle.count)
                    copy.append(needle)
                    return copy
                },
                overflowed: overflowed
            )
            clear()
            return snapshot
        }

        mutating func clear() {
            for index in needles.indices {
                needles[index].resetBytes(
                    in: needles[index].startIndex..<needles[index].endIndex
                )
                needles[index].removeAll(keepingCapacity: false)
            }
            needles.removeAll(keepingCapacity: false)
            overflowed = false
        }

        mutating func markOverflowed() {
            overflowed = true
        }
    }

    private enum Lifecycle: Equatable {
        case idle
        case preparing(UUID)
        case prepared
        case starting(UUID)
        case running
        case pausing(UUID)
        case paused
        case resuming(UUID)
        case stopping
        case ended
    }

    private let configuration: MeetingSessionConfiguration
    private let audioServices: MeetingAudioServices
    private let speechAssets: any SpeechAssetPreparing
    private let microphonePermission: any MicrophonePermissionProviding
    private let responseGenerator: any MeetingResponseGenerating
    private let responseCoordinator: ResponseCoordinator
    private let sensitiveOutputBuffer: ResponseSensitiveOutputBuffer
    private let resourceCleaner: any MeetingSessionResourceCleaning
    private let time: any MeetingTimeProviding
    private let attributionResolver: TranscriptAttributionResolver

    private var lifecycle: Lifecycle = .idle
    private var phase: MeetingPhase = .permissionRequired
    private var consentConfirmed = false
    private var runtime: MeetingSessionRuntimeStatus?
    private var timeline: TranscriptTimeline
    private var turnDetector: TurnDetector
    private var suggestions: [SuggestionCard] = []
    private var brownouts: [MeetingBrownout]
    private var generation: UInt64 = 0
    private var timingLedger = TimingLedger()
    private var cleanupNeedleLedger: CleanupNeedleLedger
    private var currentIdentity: TurnIdentity?
    private var currentQuestion: String?
    private var microphonePartialID: UUID?
    private var outputPartialID: UUID?
    private var microphoneEventTask: Task<Void, Never>?
    private var outputEventTask: Task<Void, Never>?
    private var microphoneAttributionTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var responseCancellationOperation: ResponseCancellationOperation?
    private var pendingMicrophoneObservation: PendingMicrophoneObservation?
    private var latestOutputObservation: TranscriptObservation?
    private var bridgeSpeechHold: BridgeSpeechHold?
    private var queuedDeepResponse: QueuedDeepResponse?
    private var continuation: AsyncStream<MeetingSessionEvent>.Continuation?
    private var preparationAttempt: UUID?
    private var preparationTask: Task<MeetingSessionState, Error>?
    private var audioTransitionAttempt: UUID?
    private var audioTransitionTask: Task<Void, Error>?
    private var stopTask: Task<MeetingSessionStopReport, Never>?
    private var lastStopReport: MeetingSessionStopReport?
    #if DEBUG
        private var responseEventTestHook: (@Sendable (ResponseCoordinatorEvent) async -> Void)?
    #endif

    public init(
        configuration: MeetingSessionConfiguration,
        audioServices: MeetingAudioServices = .init(),
        speechAssets: any SpeechAssetPreparing = AppleSpeechAssetManager(),
        microphonePermission: any MicrophonePermissionProviding =
            SystemMicrophonePermissionProvider(),
        responseGenerator: any MeetingResponseGenerating,
        responseCoordinatorConfiguration: ResponseCoordinatorConfiguration = .init(),
        resourceCleaner: any MeetingSessionResourceCleaning,
        time: any MeetingTimeProviding = HostMeetingTimeProvider(),
        attributionResolver: TranscriptAttributionResolver = .init(),
        cleanupNeedleCapacity: Int = 2_048
    ) {
        self.configuration = configuration
        self.audioServices = audioServices
        self.speechAssets = speechAssets
        self.microphonePermission = microphonePermission
        self.responseGenerator = responseGenerator
        let sensitiveOutputBuffer = ResponseSensitiveOutputBuffer(
            capacity: cleanupNeedleCapacity
        )
        self.sensitiveOutputBuffer = sensitiveOutputBuffer
        self.responseCoordinator = ResponseCoordinator(
            generator: responseGenerator,
            configuration: responseCoordinatorConfiguration,
            sensitiveOutputBuffer: sensitiveOutputBuffer
        )
        self.resourceCleaner = resourceCleaner
        self.time = time
        self.attributionResolver = attributionResolver
        self.cleanupNeedleLedger = CleanupNeedleLedger(capacity: cleanupNeedleCapacity)
        self.timeline = TranscriptTimeline(retention: configuration.transcriptRetention)
        self.turnDetector = TurnDetector(
            configuration: TurnDetectorConfiguration(
                minimumSilence: Self.seconds(configuration.turnBoundaryDelay)
            )
        )

        var initialBrownouts: [MeetingBrownout] = []
        if !configuration.captureMode.capturesMicrophone {
            initialBrownouts.append(.init(reason: .microphoneDisabled, lane: .microphone))
        }
        if !configuration.captureMode.capturesSystemOutput {
            initialBrownouts.append(.init(reason: .outputDisabled, lane: .output))
        }
        self.brownouts = initialBrownouts
    }

    deinit {
        preparationTask?.cancel()
        audioTransitionTask?.cancel()
        stopTask?.cancel()
        microphoneEventTask?.cancel()
        outputEventTask?.cancel()
        microphoneAttributionTask?.cancel()
        boundaryTask?.cancel()
        generationTask?.cancel()
        responseCancellationOperation?.task.cancel()
        cleanupNeedleLedger.clear()
        continuation?.finish()
    }

    public func events() -> AsyncStream<MeetingSessionEvent> {
        continuation?.finish()
        let pair = AsyncStream.makeStream(
            of: MeetingSessionEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        continuation = pair.continuation
        pair.continuation.yield(.stateChanged(makeState()))
        return pair.stream
    }

    #if DEBUG
        func setResponseEventTestHook(
            _ hook: (@Sendable (ResponseCoordinatorEvent) async -> Void)?
        ) {
            responseEventTestHook = hook
        }
    #endif

    public func state() -> MeetingSessionState {
        makeState()
    }

    public func timingSnapshot() -> MeetingTimingSnapshot {
        timingLedger.snapshot()
    }

    func delayedAttributionRetentionSnapshot() -> DelayedAttributionRetentionSnapshot {
        DelayedAttributionRetentionSnapshot(
            hasAttributionTask: microphoneAttributionTask != nil,
            hasPendingMicrophoneObservation: pendingMicrophoneObservation != nil,
            hasLatestOutputObservation: latestOutputObservation != nil
        )
    }

    func bridgeSpeechRetentionSnapshot() -> BridgeSpeechRetentionSnapshot {
        BridgeSpeechRetentionSnapshot(
            hasActiveHold: bridgeSpeechHold != nil,
            hasQueuedDeep: queuedDeepResponse != nil
        )
    }

    @discardableResult
    public func requestMicrophonePermission() async throws -> AudioPermissionStatus {
        guard consentConfirmed,
            configuration.captureMode.capturesMicrophone,
            lifecycle == .idle
        else {
            throw MeetingSessionFailure.invalidLifecycle
        }

        let status = await microphonePermission.request()
        guard lifecycle == .idle else {
            throw MeetingSessionFailure.invalidLifecycle
        }
        if status == .denied {
            activateBrownout(.init(reason: .microphoneLost, lane: .microphone))
            phase = .permissionRequired
            emitState()
        }
        return status
    }

    @discardableResult
    public func preflight(consent: MeetingConsent) async throws -> MeetingSessionState {
        guard lifecycle == .idle else {
            throw MeetingSessionFailure.invalidLifecycle
        }
        consentConfirmed = consent.participantDisclosureConfirmed
        guard consentConfirmed else {
            phase = .permissionRequired
            let failure = MeetingSessionFailure.consentRequired
            emitFailure(failure)
            throw failure
        }

        let attempt = UUID()
        lifecycle = .preparing(attempt)
        phase = .idle
        emitState()

        preparationAttempt = attempt
        let task = Task { try await self.performPreflight(attempt: attempt) }
        preparationTask = task

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performPreflight(attempt: UUID) async throws -> MeetingSessionState {
        defer { finishPreparation(attempt: attempt) }

        do {
            try validateAudioServices()
            try await prepareMicrophonePermission(attempt: attempt)
            try await prepareSpeechAssets(attempt: attempt)
            try requirePreparing(attempt)

            let preparedRuntime: MeetingResponseRuntime
            do {
                preparedRuntime = try await responseGenerator.prepare()
            } catch let error as MeetingResponseError {
                try requirePreparing(attempt)
                let failure = Self.sessionFailure(for: error)
                activateBrownout(Self.brownout(for: error))
                if case .signInRequired = error {
                    try requirePreparing(attempt)
                    lifecycle = .idle
                    phase = .permissionRequired
                    emitFailure(failure)
                    throw failure
                }
                if case .credentialStoreUnavailable = error {
                    lifecycle = .idle
                    phase = .permissionRequired
                    emitFailure(failure)
                    throw failure
                }
                _ = await responseGenerator.shutdown()
                try requirePreparing(attempt)
                lifecycle = .idle
                updateOperationalPhase()
                emitFailure(failure)
                throw failure
            } catch {
                try requirePreparing(attempt)
                _ = await responseGenerator.shutdown()
                try requirePreparing(attempt)
                activateBrownout(.init(reason: .codexOffline))
                lifecycle = .idle
                updateOperationalPhase()
                let failure = MeetingSessionFailure.responseUnavailable
                emitFailure(failure)
                throw failure
            }

            try requirePreparing(attempt)
            runtime = MeetingSessionRuntimeStatus(
                planType: preparedRuntime.planType,
                quickRoute: preparedRuntime.quickRoute,
                deepRoute: preparedRuntime.deepRoute,
                usesRealtimeQuick: preparedRuntime.usesRealtimeQuick
            )
            deactivateBrownout(reason: .codexOffline)
            deactivateBrownout(reason: .authenticationExpired)
            deactivateBrownout(reason: .accountMismatch)
            deactivateBrownout(reason: .protocolUnsupported)
            lifecycle = .prepared
            phase = .ready
            emitState()
            return makeState()
        } catch let failure as MeetingSessionFailure {
            if case .preparing(let currentAttempt) = lifecycle, currentAttempt == attempt {
                lifecycle = .idle
                updateOperationalPhase()
                emitFailure(failure)
            }
            throw failure
        } catch {
            if case .preparing(let currentAttempt) = lifecycle, currentAttempt == attempt {
                lifecycle = .idle
                updateOperationalPhase()
            }
            let failure = MeetingSessionFailure.responseUnavailable
            emitFailure(failure)
            throw failure
        }
    }

    public func start() async throws {
        guard lifecycle == .prepared else {
            throw MeetingSessionFailure.invalidLifecycle
        }

        let attempt = UUID()
        lifecycle = .starting(attempt)
        audioTransitionAttempt = attempt
        let task = Task { try await self.performStart(attempt: attempt) }
        audioTransitionTask = task

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStart(attempt: UUID) async throws {
        defer { finishAudioTransition(attempt: attempt) }
        do {
            try await startEnabledAudioServices(attempt: attempt)
            try requireAudioTransition(attempt)
            lifecycle = .running
            updateOperationalPhase()
            emitState()
        } catch let failure as MeetingSessionFailure {
            guard ownsAudioTransition(attempt) else {
                throw MeetingSessionFailure.invalidLifecycle
            }
            if let teardownFailure = await audioTeardownFailure() {
                try requireAudioTransition(attempt)
                throw transitionToIncompleteAudioTeardown(teardownFailure)
            }
            try requireAudioTransition(attempt)
            lifecycle = .prepared
            updateOperationalPhase()
            emitFailure(failure)
            throw failure
        } catch {
            guard ownsAudioTransition(attempt) else {
                throw MeetingSessionFailure.invalidLifecycle
            }
            if let teardownFailure = await audioTeardownFailure() {
                try requireAudioTransition(attempt)
                throw transitionToIncompleteAudioTeardown(teardownFailure)
            }
            try requireAudioTransition(attempt)
            lifecycle = .prepared
            activateBrownout(.init(reason: .transcriptUncertain))
            updateOperationalPhase()
            let failure = MeetingSessionFailure.responseUnavailable
            emitFailure(failure)
            throw failure
        }
    }

    public func pause() async throws {
        guard lifecycle == .running else {
            throw MeetingSessionFailure.invalidLifecycle
        }

        let attempt = UUID()
        lifecycle = .pausing(attempt)
        audioTransitionAttempt = attempt
        let task = Task { try await self.performPause(attempt: attempt) }
        audioTransitionTask = task

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performPause(attempt: UUID) async throws {
        defer { finishAudioTransition(attempt: attempt) }
        clearDelayedAttributionState()
        microphonePartialID = nil
        outputPartialID = nil
        boundaryTask?.cancel()
        boundaryTask = nil
        let teardownFailure = await audioTeardownFailure()
        try requireAudioTransition(attempt)
        await cancelCurrentGeneration(
            clearSuggestions: true,
            invalidation: .sessionPaused
        )
        try requireAudioTransition(attempt)
        if let teardownFailure {
            throw transitionToIncompleteAudioTeardown(teardownFailure)
        }
        lifecycle = .paused
        phase = .paused
        emitState()
    }

    public func resume() async throws {
        guard lifecycle == .paused else {
            throw MeetingSessionFailure.invalidLifecycle
        }

        let attempt = UUID()
        lifecycle = .resuming(attempt)
        audioTransitionAttempt = attempt
        let task = Task { try await self.performResume(attempt: attempt) }
        audioTransitionTask = task

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performResume(attempt: UUID) async throws {
        defer { finishAudioTransition(attempt: attempt) }
        do {
            try await startEnabledAudioServices(attempt: attempt)
            try requireAudioTransition(attempt)
            lifecycle = .running
            updateOperationalPhase()
            emitState()
        } catch let failure as MeetingSessionFailure {
            guard ownsAudioTransition(attempt) else {
                throw MeetingSessionFailure.invalidLifecycle
            }
            if let teardownFailure = await audioTeardownFailure() {
                try requireAudioTransition(attempt)
                throw transitionToIncompleteAudioTeardown(teardownFailure)
            }
            try requireAudioTransition(attempt)
            lifecycle = .paused
            phase = .paused
            emitFailure(failure)
            throw failure
        } catch {
            guard ownsAudioTransition(attempt) else {
                throw MeetingSessionFailure.invalidLifecycle
            }
            if let teardownFailure = await audioTeardownFailure() {
                try requireAudioTransition(attempt)
                throw transitionToIncompleteAudioTeardown(teardownFailure)
            }
            try requireAudioTransition(attempt)
            lifecycle = .paused
            phase = .paused
            let failure = MeetingSessionFailure.responseUnavailable
            emitFailure(failure)
            throw failure
        }
    }

    public func submitTypedQuestion(_ question: String) async throws {
        guard lifecycle == .running else {
            throw MeetingSessionFailure.invalidLifecycle
        }
        let normalized = Self.normalized(question)
        guard !normalized.isEmpty else {
            throw MeetingSessionFailure.emptyManualQuestion
        }
        cleanupNeedleLedger.register(normalized)

        let now = time.now()
        let segment = TranscriptSegment(
            source: .them,
            text: normalized,
            startedAt: now,
            endedAt: now,
            isFinal: true
        )
        timeline.upsert(segment)
        emit(.transcriptUpserted(segment))
        emitState()
        await beginTurn(question: normalized, stableAt: now)
    }

    public func coachCurrentTurn() async throws {
        guard lifecycle == .running else {
            throw MeetingSessionFailure.invalidLifecycle
        }
        if let currentQuestion, currentIdentity != nil {
            await beginTurn(question: currentQuestion, stableAt: time.now())
            return
        }
        guard let candidate = turnDetector.candidate(at: time.now(), force: true) else {
            throw MeetingSessionFailure.noCandidateQuestion
        }
        await beginTurn(question: candidate.text, stableAt: candidate.stableAt)
    }

    public func dismissSuggestion(identity expectedIdentity: TurnIdentity) async {
        guard lifecycle == .running,
            suggestions.contains(where: { $0.identity == expectedIdentity })
        else {
            return
        }

        let dismissedAt = time.now()
        timingLedger.recordUserDismissed(
            generation: expectedIdentity.generation,
            at: dismissedAt
        )

        let ownsActiveGeneration = currentIdentity == expectedIdentity
        var dismissedGenerationTask: Task<Void, Never>?
        if ownsActiveGeneration {
            timingLedger.invalidate(
                generation: expectedIdentity.generation,
                outcome: .userDismissed,
                at: dismissedAt
            )
            dismissedGenerationTask = generationTask
            dismissedGenerationTask?.cancel()
            generationTask = nil
            currentIdentity = nil
            currentQuestion = nil
        }
        if bridgeSpeechHold?.identity == expectedIdentity {
            bridgeSpeechHold = nil
        }
        if queuedDeepResponse?.identity == expectedIdentity {
            queuedDeepResponse = nil
        }
        suggestions.removeAll { $0.identity == expectedIdentity }
        emit(.suggestionsCleared(expectedIdentity))
        updateOperationalPhase()
        emitState()

        guard ownsActiveGeneration else { return }
        await cancelResponseWork(joining: dismissedGenerationTask)
    }

    @discardableResult
    public func stop() async -> MeetingSessionStopReport {
        if let stopTask { return await stopTask.value }
        if let lastStopReport,
            !lastStopReport.failures.contains(.audioCaptureTeardown)
        {
            return lastStopReport
        }

        registerRetainedCleanupContent()
        clearDelayedAttributionState()
        let preparationTask = self.preparationTask
        let audioTransitionTask = self.audioTransitionTask
        lifecycle = .stopping
        boundaryTask?.cancel()
        boundaryTask = nil
        clearVisibleMeetingContentForStop()
        preparationTask?.cancel()
        audioTransitionTask?.cancel()
        let task: Task<MeetingSessionStopReport, Never>
        if let lastStopReport {
            task = Task {
                if let preparationTask { _ = await preparationTask.result }
                if let audioTransitionTask { _ = await audioTransitionTask.result }
                return await self.retryAudioTeardown(from: lastStopReport)
            }
        } else {
            task = Task {
                if let preparationTask { _ = await preparationTask.result }
                if let audioTransitionTask { _ = await audioTransitionTask.result }
                return await self.performStop()
            }
        }
        stopTask = task
        return await task.value
    }

    private func performStop() async -> MeetingSessionStopReport {
        let audioTeardownFailureLane = await stopAudioServicesWithOneRetry()
        await cancelCurrentGeneration(
            clearSuggestions: false,
            invalidation: .sessionStopped
        )
        registerRetainedCleanupContent()
        let responseReport = await responseGenerator.shutdown()
        let providerOutputSnapshot = await sensitiveOutputBuffer.takeSnapshotAndClear()
        for value in providerOutputSnapshot.values {
            cleanupNeedleLedger.register(value)
        }
        if providerOutputSnapshot.overflowed {
            cleanupNeedleLedger.markOverflowed()
        }
        var cleanupNeedleSnapshot = cleanupNeedleLedger.takeSnapshotAndClear()
        defer { cleanupNeedleSnapshot.clear() }
        let timingSnapshot = timingLedger.snapshot()
        timingLedger.clear()

        let resourceReport = await resourceCleaner.deleteResources(
            preserveCodexRecoveryState: !responseReport.failures.isEmpty
        )

        currentIdentity = nil
        currentQuestion = nil
        runtime = nil

        var failures = resourceReport.failures
        if audioTeardownFailureLane != nil {
            failures.append(.audioCaptureTeardown)
        }
        if !responseReport.failures.isEmpty {
            failures.append(.responseCleanup)
        }
        if cleanupNeedleSnapshot.overflowed {
            failures.append(.residualAudit)
        }

        let residualFindingCount: Int
        do {
            residualFindingCount = try await resourceCleaner.residualFindingCount(
                sensitiveNeedles: cleanupNeedleSnapshot.needles
            )
            if residualFindingCount > 0 {
                failures.append(.residualData)
            }
        } catch {
            residualFindingCount = 0
            failures.append(.residualAudit)
        }

        var journalEntryRemoved = false
        if failures.isEmpty {
            do {
                try await resourceCleaner.deletePrivateRoot()
            } catch {
                failures.append(.privateRootDeletion)
            }
        }
        if failures.isEmpty {
            do {
                try await resourceCleaner.removeJournalEntry(meetingID: configuration.meetingID)
                journalEntryRemoved = true
            } catch {
                failures.append(.journalRemoval)
            }
        }

        let report = MeetingSessionStopReport(
            deletedThreadCount: responseReport.deletedThreadCount,
            deletedSnapshotCount: resourceReport.deletedSnapshotCount,
            deletedTemporaryRootCount: resourceReport.deletedTemporaryRootCount,
            residualFindingCount: residualFindingCount,
            journalEntryRemoved: journalEntryRemoved,
            failures: Self.deduplicated(failures),
            audioTeardownFailureLane: audioTeardownFailureLane,
            timing: timingSnapshot
        )
        recordStop(report)
        return report
    }

    private func retryAudioTeardown(
        from previous: MeetingSessionStopReport
    ) async -> MeetingSessionStopReport {
        var failures = previous.failures.filter { $0 != .audioCaptureTeardown }
        let audioTeardownFailureLane = await stopAudioServicesWithOneRetry()
        if audioTeardownFailureLane != nil {
            failures.append(.audioCaptureTeardown)
        }

        var journalEntryRemoved = previous.journalEntryRemoved
        if failures.isEmpty, !journalEntryRemoved {
            do {
                try await resourceCleaner.deletePrivateRoot()
            } catch {
                failures.append(.privateRootDeletion)
            }
        }
        if failures.isEmpty, !journalEntryRemoved {
            do {
                try await resourceCleaner.removeJournalEntry(meetingID: configuration.meetingID)
                journalEntryRemoved = true
            } catch {
                failures.append(.journalRemoval)
            }
        }

        let report = MeetingSessionStopReport(
            deletedThreadCount: previous.deletedThreadCount,
            deletedSnapshotCount: previous.deletedSnapshotCount,
            deletedTemporaryRootCount: previous.deletedTemporaryRootCount,
            residualFindingCount: previous.residualFindingCount,
            journalEntryRemoved: journalEntryRemoved,
            failures: Self.deduplicated(failures),
            audioTeardownFailureLane: audioTeardownFailureLane,
            timing: previous.timing
        )
        recordStop(report)
        return report
    }

    private func recordStop(_ report: MeetingSessionStopReport) {
        lastStopReport = report
        stopTask = nil
        if report.failures.contains(.audioCaptureTeardown) {
            lifecycle = .stopping
            phase = .brownout
            let lane =
                report.audioTeardownFailureLane
                ?? configuration.captureMode.enabledLanes.first
                ?? .output
            activateBrownout(.init(reason: Self.lostReason(for: lane), lane: lane))
            emitFailure(.captureTeardownFailed(lane))
            return
        }

        lifecycle = .ended
        phase = .ended
        emitState()
        continuation?.finish()
        continuation = nil
    }

    private func validateAudioServices() throws {
        for lane in configuration.captureMode.enabledLanes {
            guard let services = services(for: lane) else {
                throw MeetingSessionFailure.missingAudioServices(lane)
            }
            guard services.lane == lane,
                services.capture.lane == lane,
                services.transcriber.lane == lane
            else {
                throw MeetingSessionFailure.invalidAudioServices(lane)
            }
        }
    }

    private func prepareMicrophonePermission(attempt: UUID) async throws {
        guard configuration.captureMode.capturesMicrophone else { return }
        let status = await microphonePermission.status()
        try requirePreparing(attempt)
        switch status {
        case .granted:
            deactivateBrownout(reason: .microphoneLost, lane: .microphone)
        case .notDetermined:
            phase = .permissionRequired
            throw MeetingSessionFailure.microphonePermissionRequired
        case .denied:
            activateBrownout(.init(reason: .microphoneLost, lane: .microphone))
            phase = .permissionRequired
            throw MeetingSessionFailure.microphonePermissionDenied
        }
    }

    private func prepareSpeechAssets(attempt: UUID) async throws {
        guard !configuration.captureMode.enabledLanes.isEmpty else { return }
        let initialAvailability = await speechAssets.availability(
            localeIdentifier: configuration.localeIdentifier
        )
        try requirePreparing(attempt)
        guard initialAvailability != .unsupported else {
            activateBrownout(.init(reason: .transcriberAssetMissing))
            throw MeetingSessionFailure.transcriptionAssetUnavailable
        }

        do {
            let preparation = try await speechAssets.prepare(
                localeIdentifier: configuration.localeIdentifier
            )
            try requirePreparing(attempt)
            let finalAvailability = await speechAssets.availability(
                localeIdentifier: preparation.localeIdentifier
            )
            try requirePreparing(attempt)
            guard finalAvailability == .installed, preparation.reserved else {
                throw MeetingSessionFailure.transcriptionAssetUnavailable
            }
            deactivateBrownout(reason: .transcriberAssetMissing)
        } catch let failure as MeetingSessionFailure {
            try requirePreparing(attempt)
            activateBrownout(.init(reason: .transcriberAssetMissing))
            throw failure
        } catch {
            try requirePreparing(attempt)
            activateBrownout(.init(reason: .transcriberAssetMissing))
            throw MeetingSessionFailure.transcriptionAssetUnavailable
        }
    }

    private func startEnabledAudioServices(attempt: UUID) async throws {
        try requireAudioTransition(attempt)
        // Creating the private Core Audio aggregate can notify AVAudioEngine instances about a
        // hardware configuration change. Bring up output first so that notification cannot tear
        // down a microphone engine that ChirpCue just started.
        if configuration.captureMode.capturesSystemOutput {
            guard let output = audioServices.systemOutput else {
                throw MeetingSessionFailure.missingAudioServices(.output)
            }
            do {
                try await startLane(output, attempt: attempt)
                try requireAudioTransition(attempt)
                deactivateBrownout(reason: .systemAudioLost, lane: .output)
            } catch let failure as MeetingSessionFailure {
                throw failure
            } catch let error as AudioCaptureError where error == .permissionDenied {
                try requireAudioTransition(attempt)
                activateBrownout(.init(reason: .systemAudioLost, lane: .output))
                throw MeetingSessionFailure.systemAudioPermissionDenied
            } catch {
                try requireAudioTransition(attempt)
                activateBrownout(.init(reason: .systemAudioLost, lane: .output))
                throw MeetingSessionFailure.captureUnavailable(.output)
            }
        }

        try requireAudioTransition(attempt)
        if configuration.captureMode.capturesMicrophone {
            guard let microphone = audioServices.microphone else {
                throw MeetingSessionFailure.missingAudioServices(.microphone)
            }
            do {
                try await startLane(microphone, attempt: attempt)
                try requireAudioTransition(attempt)
                deactivateBrownout(reason: .microphoneLost, lane: .microphone)
            } catch let failure as MeetingSessionFailure {
                throw failure
            } catch let error as AudioCaptureError where error == .permissionDenied {
                try requireAudioTransition(attempt)
                activateBrownout(.init(reason: .microphoneLost, lane: .microphone))
                throw MeetingSessionFailure.microphonePermissionDenied
            } catch {
                try requireAudioTransition(attempt)
                activateBrownout(.init(reason: .microphoneLost, lane: .microphone))
                throw MeetingSessionFailure.captureUnavailable(.microphone)
            }
        }
    }

    private func startLane(
        _ services: MeetingAudioLaneServices,
        attempt: UUID
    ) async throws {
        let audioEvents = await services.capture.events()
        try requireAudioTransition(attempt)
        let transcriptionEvents = await services.transcriber.events()
        try requireAudioTransition(attempt)
        let task = Task { [weak self] in
            for await event in transcriptionEvents {
                guard !Task.isCancelled else { return }
                await self?.handleTranscription(event)
            }
        }
        setEventTask(task, lane: services.lane)

        do {
            try await services.transcriber.start(
                audioEvents: audioEvents,
                localeIdentifier: configuration.localeIdentifier
            )
            try requireAudioTransition(attempt)
            try await services.capture.start()
            try requireAudioTransition(attempt)
        } catch {
            task.cancel()
            setEventTask(nil, lane: services.lane)
            await services.transcriber.stop()
            throw error
        }
    }

    private func stopAudioServices() async throws {
        let stoppedMicrophoneEventTask = microphoneEventTask
        let stoppedOutputEventTask = outputEventTask
        stoppedMicrophoneEventTask?.cancel()
        stoppedOutputEventTask?.cancel()
        microphoneEventTask = nil
        outputEventTask = nil

        var failedLanes: [AudioLane] = []
        if configuration.captureMode.capturesMicrophone,
            let microphone = audioServices.microphone
        {
            await microphone.transcriber.stop()
            do {
                try await microphone.capture.stop()
            } catch {
                failedLanes.append(.microphone)
            }
        }
        if configuration.captureMode.capturesSystemOutput,
            let output = audioServices.systemOutput
        {
            await output.transcriber.stop()
            do {
                try await output.capture.stop()
            } catch {
                failedLanes.append(.output)
            }
        }

        await stoppedMicrophoneEventTask?.value
        await stoppedOutputEventTask?.value
        clearDelayedAttributionState()

        if !failedLanes.isEmpty {
            throw AudioServiceTeardownFailure(lanes: failedLanes)
        }
    }

    private func audioTeardownFailure() async -> AudioServiceTeardownFailure? {
        do {
            try await stopAudioServices()
            return nil
        } catch let failure as AudioServiceTeardownFailure {
            return failure
        } catch {
            return AudioServiceTeardownFailure(lanes: configuration.captureMode.enabledLanes)
        }
    }

    private func stopAudioServicesWithOneRetry() async -> AudioLane? {
        var lastFailure: AudioServiceTeardownFailure?
        for _ in 0..<2 {
            guard let failure = await audioTeardownFailure() else { return nil }
            lastFailure = failure
        }
        return lastFailure?.lanes.first ?? configuration.captureMode.enabledLanes.first
    }

    private func transitionToIncompleteAudioTeardown(
        _ teardownFailure: AudioServiceTeardownFailure
    ) -> MeetingSessionFailure {
        let lane = teardownFailure.lanes.first ?? .output
        lifecycle = .stopping
        phase = .brownout
        activateBrownout(.init(reason: Self.lostReason(for: lane), lane: lane))
        let failure = MeetingSessionFailure.captureTeardownFailed(lane)
        emitFailure(failure)
        return failure
    }

    private func handleTranscription(_ event: SpeechTranscriptionEvent) async {
        guard lifecycle == .running else { return }
        switch event {
        case .started(let lane, _):
            deactivateBrownout(reason: Self.lostReason(for: lane), lane: lane)
            deactivateBrownout(reason: .transcriptionUnavailable, lane: lane)
            updateOperationalPhase()
            emitState()

        case .result(let result):
            if result.lane == .microphone {
                await handleMicrophoneResult(result)
            } else {
                await handleOutputResult(result)
            }

        case .gap(let gap):
            await cancelCurrentGeneration(
                clearSuggestions: true,
                invalidation: .captureInterrupted
            )
            activateBrownout(.init(reason: Self.lostReason(for: gap.lane), lane: gap.lane))
            phase = .brownout
            emitState()

        case .routeChanged(let previous, let current):
            await cancelCurrentGeneration(
                clearSuggestions: true,
                invalidation: .captureInterrupted
            )
            if current == nil {
                activateBrownout(
                    .init(reason: Self.lostReason(for: previous.lane), lane: previous.lane)
                )
            } else {
                deactivateBrownout(
                    reason: Self.lostReason(for: previous.lane),
                    lane: previous.lane
                )
            }
            updateOperationalPhase()
            emitState()

        case .failed(let lane, let reason):
            await cancelCurrentGeneration(
                clearSuggestions: true,
                invalidation: .captureInterrupted
            )
            if reason == .assetUnavailable {
                activateBrownout(.init(reason: .transcriberAssetMissing, lane: lane))
            } else {
                activateBrownout(.init(reason: .transcriptionUnavailable, lane: lane))
            }
            phase = .brownout
            emitState()

        case .stopped(let lane):
            await cancelCurrentGeneration(
                clearSuggestions: true,
                invalidation: .captureInterrupted
            )
            activateBrownout(.init(reason: Self.lostReason(for: lane), lane: lane))
            phase = .brownout
            emitState()
        }
    }

    private func handleMicrophoneResult(_ result: ProgressiveTranscriptResult) async {
        cleanupNeedleLedger.register(result.text)
        let observation = TranscriptObservation(result: result, receivedAt: time.now())
        if let latestOutputObservation {
            let decision = attributionResolver.resolveMicrophone(
                result,
                receivedAt: observation.receivedAt,
                against: latestOutputObservation.result,
                receivedAt: latestOutputObservation.receivedAt
            )
            if case .attribute(source: .you, speakerUncertain: false) = decision {
                enqueueMicrophone(observation)
            } else {
                await applyMicrophone(decision, observation: observation)
            }
        } else {
            enqueueMicrophone(observation)
        }
    }

    private func handleOutputResult(_ result: ProgressiveTranscriptResult) async {
        cleanupNeedleLedger.register(result.text)
        let observation = TranscriptObservation(result: result, receivedAt: time.now())
        if let pending = pendingMicrophoneObservation {
            microphoneAttributionTask?.cancel()
            microphoneAttributionTask = nil
            pendingMicrophoneObservation = nil
            let decision = attributionResolver.resolveMicrophone(
                pending.observation.result,
                receivedAt: pending.observation.receivedAt,
                against: result,
                receivedAt: observation.receivedAt
            )
            await applyMicrophone(decision, observation: pending.observation)
            guard lifecycle == .running else { return }
        }

        guard lifecycle == .running else { return }
        latestOutputObservation = observation
        let outputSource: TranscriptSource =
            configuration.systemOutputScope == .meetingApplication ? .them : .output
        let segment = ingest(result, source: outputSource)
        turnDetector.observe(segment)
        boundaryTask?.cancel()
        if segment.isFinal {
            await detectTurnBoundary(force: false)
        } else {
            scheduleTurnBoundary()
        }
    }

    private func enqueueMicrophone(_ observation: TranscriptObservation) {
        let pending = PendingMicrophoneObservation(id: UUID(), observation: observation)
        let pendingID = pending.id
        pendingMicrophoneObservation = pending
        microphoneAttributionTask?.cancel()
        let delay = configuration.microphoneAttributionDelay
        microphoneAttributionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushMicrophone(id: pendingID)
        }
    }

    private func flushMicrophone(id: UUID) async {
        guard lifecycle == .running,
            let pending = pendingMicrophoneObservation,
            pending.id == id
        else {
            return
        }
        pendingMicrophoneObservation = nil
        microphoneAttributionTask = nil
        await applyMicrophone(
            .attribute(source: confirmedMicrophoneSource, speakerUncertain: false),
            observation: pending.observation
        )
    }

    private func applyMicrophone(
        _ decision: TranscriptAttributionDecision,
        observation: TranscriptObservation
    ) async {
        guard lifecycle == .running else { return }
        switch decision {
        case .suppressEcho:
            suppressCurrentMicrophonePartial()
            deactivateBrownout(reason: .speakerUncertain, lane: .microphone)
            emitState()

        case .attribute(let source, let speakerUncertain):
            let attributedSource =
                source == .you && !speakerUncertain ? confirmedMicrophoneSource : source
            if speakerUncertain {
                activateBrownout(.init(reason: .speakerUncertain, lane: .microphone))
            } else {
                deactivateBrownout(reason: .speakerUncertain, lane: .microphone)
            }
            if attributedSource == .you, !speakerUncertain {
                if let currentIdentity {
                    timingLedger.recordConfirmedLocalSpeech(
                        generation: currentIdentity.generation,
                        at: observation.result.hostTimeRange?.start.seconds
                    )
                }
                if observation.result.stability == .volatile {
                    holdDeepForLikelyBridgeSpeech(observation.result.text)
                } else if completesDisplayedBridge(observation.result.text) {
                    _ = ingest(observation.result, source: attributedSource)
                    releaseQueuedDeepAfterBridge()
                    return
                } else {
                    await cancelGenerationForLocalSpeech()
                    guard lifecycle == .running else { return }
                }
            }
            _ = ingest(observation.result, source: attributedSource)
        }
    }

    private var confirmedMicrophoneSource: TranscriptSource {
        configuration.soleNearbySpeakerConfirmed ? .you : .microphone
    }

    @discardableResult
    private func ingest(
        _ result: ProgressiveTranscriptResult,
        source: TranscriptSource
    ) -> TranscriptSegment {
        cleanupNeedleLedger.register(result.text)
        let segment = makeSegment(result, source: source)
        timeline.upsert(segment)
        emit(.transcriptUpserted(segment))
        emitState()
        return segment
    }

    private func suppressCurrentMicrophonePartial() {
        guard let microphonePartialID else { return }
        timeline = TranscriptTimeline(
            retention: configuration.transcriptRetention,
            segments: timeline.segments.filter { $0.id != microphonePartialID }
        )
        self.microphonePartialID = nil
        emit(.transcriptRemoved(microphonePartialID))
    }

    private func makeSegment(
        _ result: ProgressiveTranscriptResult,
        source: TranscriptSource
    ) -> TranscriptSegment {
        let existingID = partialID(for: result.lane)
        let id = existingID ?? UUID()
        let existing = timeline.segments.first { $0.id == id }
        let now = time.now()
        let range = result.hostTimeRange
        let startedAt = existing?.startedAt ?? range?.start.seconds ?? now
        let endedAt = max(startedAt, range?.end.seconds ?? now)

        if result.stability == .final {
            setPartialID(nil, lane: result.lane)
        } else {
            setPartialID(id, lane: result.lane)
        }

        return TranscriptSegment(
            id: id,
            source: source,
            text: Self.normalized(result.text),
            startedAt: startedAt,
            endedAt: endedAt,
            isFinal: result.stability == .final,
            confidence: result.confidence
        )
    }

    private func scheduleTurnBoundary() {
        let delay = configuration.turnBoundaryDelay
        boundaryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.detectTurnBoundary(force: false)
        }
    }

    private func detectTurnBoundary(force: Bool) async {
        guard lifecycle == .running,
            let candidate = turnDetector.candidate(at: time.now(), force: force)
        else {
            return
        }
        await beginTurn(question: candidate.text, stableAt: candidate.stableAt)
    }

    private func beginTurn(question: String, stableAt: TimeInterval) async {
        guard lifecycle == .running else { return }
        clearTransientResponseBrownouts()
        currentQuestion = question
        generation &+= 1
        let identity = TurnIdentity(
            meetingID: configuration.meetingID,
            generation: generation
        )
        let previousIdentity = currentIdentity
        if let previousIdentity {
            timingLedger.invalidate(
                generation: previousIdentity.generation,
                outcome: .newerTurn,
                at: stableAt
            )
        }
        timingLedger.beginTurn(generation: identity.generation, at: stableAt)
        clearBridgeSpeechState()
        currentIdentity = identity
        let previousGenerationTask = generationTask
        previousGenerationTask?.cancel()
        generationTask = nil
        suggestions.removeAll(keepingCapacity: true)
        emit(.suggestionsCleared(previousIdentity))
        phase = .candidateQuestion
        emitState()

        await cancelResponseWork(joining: previousGenerationTask)
        guard lifecycle == .running, currentIdentity == identity else { return }

        let turn = ConversationTurn(
            identity: identity,
            question: question,
            recentTranscript: timeline.recent(
                endingAt: stableAt,
                seconds: configuration.transcriptContextSeconds
            ),
            repoAlias: configuration.grounding?.repoAlias,
            groundingFingerprint: configuration.grounding?.fingerprint
        )
        phase = .thinking
        emitState()
        let responseEvents = await responseCoordinator.suggestions(for: turn)
        guard lifecycle == .running, currentIdentity == identity else {
            await responseCoordinator.invalidate()
            return
        }

        generationTask = Task { [weak self] in
            for await event in responseEvents {
                guard !Task.isCancelled else { return }
                #if DEBUG
                    await self?.waitBeforeHandlingResponseForTesting(event)
                #endif
                await self?.handleResponse(event, identity: identity)
            }
            await self?.generationFinished(identity: identity)
        }
    }

    #if DEBUG
        private func waitBeforeHandlingResponseForTesting(
            _ event: ResponseCoordinatorEvent
        ) async {
            if let responseEventTestHook {
                await responseEventTestHook(event)
            }
        }
    #endif

    private func handleResponse(_ event: ResponseCoordinatorEvent, identity: TurnIdentity) {
        switch event {
        case .cue(let cue):
            cleanupNeedleLedger.register(cue.text)
        case .deep(let deep):
            registerCleanupContent(deep)
        case .quickUnavailable, .deepUnavailable, .discardedStale:
            break
        }
        guard lifecycle == .running, currentIdentity == identity else {
            timingLedger.recordStaleDiscard(
                generation: identity.generation,
                at: time.now()
            )
            return
        }
        switch event {
        case .cue(let cue):
            guard cue.turnID == identity.turnID, cue.generation == identity.generation else {
                timingLedger.recordStaleDiscard(
                    generation: identity.generation,
                    at: time.now()
                )
                return
            }
            let stage: SuggestionStage = cue.isDeterministicBridge ? .bridge : .quick
            let card = SuggestionCard(identity: identity, stage: stage, text: cue.text)
            suggestions.removeAll { $0.identity == identity && $0.stage != .deep }
            suggestions.insert(card, at: 0)
            timingLedger.recordBridgeReady(
                generation: identity.generation,
                at: time.now()
            )
            phase = .suggesting
            emit(.suggestionUpserted(card))
            emitState()

        case .deep(let deep):
            guard deep.turnID == identity.turnID, deep.generation == identity.generation else {
                timingLedger.recordStaleDiscard(
                    generation: identity.generation,
                    at: time.now()
                )
                return
            }
            clearTransientResponseBrownouts()
            if bridgeSpeechHold?.identity == identity {
                queuedDeepResponse = QueuedDeepResponse(identity: identity, response: deep)
            } else {
                displayDeep(deep, identity: identity)
            }

        case .quickUnavailable:
            activateBrownout(.init(reason: .quickLimited))
            updateOperationalPhase()
            emitState()

        case .deepUnavailable(let failure):
            timingLedger.recordDeepUnavailable(
                generation: identity.generation,
                at: time.now()
            )
            let reason: BrownoutReason =
                switch failure {
                case .rateLimited: .deepLimited
                case .busy: .deepBusy
                case .timedOut: .deepTimedOut
                case .providerUnavailable: .deepUnavailable
                case .responseRejected, .groundingUnavailable: .deepRejected
                }
            activateBrownout(.init(reason: reason))
            updateOperationalPhase()
            emitState()

        case .discardedStale:
            timingLedger.recordStaleDiscard(
                generation: identity.generation,
                at: time.now()
            )
        }
    }

    private func holdDeepForLikelyBridgeSpeech(_ text: String) {
        guard bridgeSpeechHold == nil,
            let reference = displayedBridgeReference(),
            Self.isLikelyBridgeSpeech(text, bridgeText: reference.bridgeText)
        else {
            return
        }
        bridgeSpeechHold = reference
    }

    private func completesDisplayedBridge(_ text: String) -> Bool {
        guard let reference = displayedBridgeReference() else { return false }
        return Self.isCompletedBridgeSpeech(text, bridgeText: reference.bridgeText)
    }

    private func displayedBridgeReference() -> BridgeSpeechHold? {
        guard let identity = currentIdentity else { return nil }
        if let bridgeSpeechHold, bridgeSpeechHold.identity == identity {
            return bridgeSpeechHold
        }
        guard
            let card = suggestions.first(where: {
                $0.identity == identity && ($0.stage == .quick || $0.stage == .bridge)
            })
        else {
            return nil
        }
        return BridgeSpeechHold(identity: identity, bridgeText: card.text)
    }

    private func releaseQueuedDeepAfterBridge() {
        let completedIdentity = bridgeSpeechHold?.identity ?? currentIdentity
        bridgeSpeechHold = nil
        guard let queuedDeepResponse else { return }
        self.queuedDeepResponse = nil
        guard lifecycle == .running,
            currentIdentity == completedIdentity,
            queuedDeepResponse.identity == completedIdentity
        else {
            return
        }
        displayDeep(queuedDeepResponse.response, identity: queuedDeepResponse.identity)
    }

    private func displayDeep(_ deep: BoundDeep, identity: TurnIdentity) {
        registerCleanupContent(deep)
        guard lifecycle == .running, currentIdentity == identity else {
            timingLedger.recordStaleDiscard(
                generation: identity.generation,
                at: time.now()
            )
            return
        }
        let card = SuggestionCard(
            identity: identity,
            stage: .deep,
            text: deep.composedText,
            evidence: deep.basis,
            deepKind: deep.kind
        )
        suggestions.removeAll { $0.identity == identity && $0.stage == .deep }
        suggestions.append(card)
        timingLedger.recordVerifiedDeepReady(
            generation: identity.generation,
            at: time.now()
        )
        phase = .suggesting
        emit(.suggestionUpserted(card))
        emitState()
    }

    private func clearBridgeSpeechState() {
        bridgeSpeechHold = nil
        queuedDeepResponse = nil
    }

    private func generationFinished(identity: TurnIdentity) {
        guard lifecycle == .running, currentIdentity == identity else { return }
        generationTask = nil
        updateOperationalPhase()
        emitState()
    }

    private func cancelGenerationForLocalSpeech() async {
        guard
            generationTask != nil
                || (currentIdentity != nil && suggestions.isEmpty)
                || bridgeSpeechHold != nil
                || queuedDeepResponse != nil
        else {
            return
        }
        await cancelCurrentGeneration(
            clearSuggestions: false,
            invalidation: .localSpeech
        )
        updateOperationalPhase()
    }

    private func cancelCurrentGeneration(
        clearSuggestions: Bool,
        invalidation: MeetingTimingInvalidationOutcome
    ) async {
        boundaryTask?.cancel()
        boundaryTask = nil
        let cancelledGenerationTask = generationTask
        cancelledGenerationTask?.cancel()
        generationTask = nil
        clearBridgeSpeechState()
        let previousIdentity = currentIdentity
        if let previousIdentity {
            timingLedger.invalidate(
                generation: previousIdentity.generation,
                outcome: invalidation,
                at: time.now()
            )
        }
        currentIdentity = nil
        currentQuestion = nil
        await cancelResponseWork(joining: cancelledGenerationTask)
        if clearSuggestions {
            suggestions.removeAll(keepingCapacity: false)
            emit(.suggestionsCleared(previousIdentity))
        }
    }

    private func cancelResponseWork(joining generationConsumer: Task<Void, Never>?) async {
        if let operation = responseCancellationOperation {
            if let generationConsumer {
                let operationID = UUID()
                let task = Task {
                    await operation.task.value
                    await generationConsumer.value
                }
                responseCancellationOperation = ResponseCancellationOperation(
                    id: operationID,
                    task: task
                )
                await task.value
                if responseCancellationOperation?.id == operationID {
                    responseCancellationOperation = nil
                }
                return
            }
            await operation.task.value
            if responseCancellationOperation?.id == operation.id {
                responseCancellationOperation = nil
            }
            return
        }

        let operationID = UUID()
        let responseCoordinator = self.responseCoordinator
        let responseGenerator = self.responseGenerator
        let task = Task {
            await responseCoordinator.invalidate()
            await responseGenerator.cancelActiveWork()
            await generationConsumer?.value
        }
        responseCancellationOperation = ResponseCancellationOperation(
            id: operationID,
            task: task
        )
        await task.value
        if responseCancellationOperation?.id == operationID {
            responseCancellationOperation = nil
        }
    }

    private func services(for lane: AudioLane) -> MeetingAudioLaneServices? {
        switch lane {
        case .microphone: audioServices.microphone
        case .output: audioServices.systemOutput
        }
    }

    private func setEventTask(_ task: Task<Void, Never>?, lane: AudioLane) {
        switch lane {
        case .microphone: microphoneEventTask = task
        case .output: outputEventTask = task
        }
    }

    private func partialID(for lane: AudioLane) -> UUID? {
        switch lane {
        case .microphone: microphonePartialID
        case .output: outputPartialID
        }
    }

    private func setPartialID(_ id: UUID?, lane: AudioLane) {
        switch lane {
        case .microphone: microphonePartialID = id
        case .output: outputPartialID = id
        }
    }

    private func requirePreparing(_ attempt: UUID) throws {
        guard lifecycle == .preparing(attempt) else {
            throw MeetingSessionFailure.invalidLifecycle
        }
    }

    private func finishPreparation(attempt: UUID) {
        guard preparationAttempt == attempt else { return }
        preparationAttempt = nil
        preparationTask = nil
    }

    private func requireAudioTransition(_ attempt: UUID) throws {
        guard ownsAudioTransition(attempt) else {
            throw MeetingSessionFailure.invalidLifecycle
        }
    }

    private func ownsAudioTransition(_ attempt: UUID) -> Bool {
        guard audioTransitionAttempt == attempt else { return false }
        switch lifecycle {
        case .starting(let current), .pausing(let current), .resuming(let current):
            return current == attempt
        default:
            return false
        }
    }

    private func finishAudioTransition(attempt: UUID) {
        guard audioTransitionAttempt == attempt else { return }
        audioTransitionAttempt = nil
        audioTransitionTask = nil
    }

    private func activateBrownout(_ brownout: MeetingBrownout) {
        guard !brownouts.contains(where: { $0.id == brownout.id }) else { return }
        brownouts.append(brownout)
        brownouts.sort { $0.id < $1.id }
        emit(.brownoutActivated(brownout))
    }

    private func deactivateBrownout(reason: BrownoutReason, lane: AudioLane? = nil) {
        let matches = brownouts.filter { brownout in
            brownout.reason == reason && (lane == nil || brownout.lane == lane)
        }
        guard !matches.isEmpty else { return }
        brownouts.removeAll { brownout in
            brownout.reason == reason && (lane == nil || brownout.lane == lane)
        }
        for brownout in matches {
            emit(.brownoutCleared(brownout))
        }
    }

    private func clearTransientResponseBrownouts() {
        for reason in [
            BrownoutReason.quickLimited,
            .deepLimited,
            .deepBusy,
            .deepTimedOut,
            .deepUnavailable,
            .deepRejected,
        ] {
            deactivateBrownout(reason: reason)
        }
    }

    private func updateOperationalPhase() {
        switch lifecycle {
        case .idle:
            phase = consentConfirmed ? .idle : .permissionRequired
        case .preparing:
            phase = .idle
        case .prepared:
            phase = hasBlockingBrownout ? .brownout : .ready
        case .starting:
            phase = hasBlockingBrownout ? .brownout : .ready
        case .running:
            if hasBlockingBrownout {
                phase = .brownout
            } else {
                phase = suggestions.isEmpty ? .listening : .suggesting
            }
        case .pausing, .resuming:
            phase = .paused
        case .paused:
            phase = .paused
        case .stopping, .ended:
            phase = .ended
        }
    }

    private var hasBlockingBrownout: Bool {
        brownouts.contains { brownout in
            switch brownout.reason {
            case .microphoneDisabled, .outputDisabled, .quickLimited, .deepLimited,
                .deepBusy, .deepTimedOut, .deepUnavailable, .deepRejected, .speakerUncertain:
                false
            default:
                true
            }
        }
    }

    private var isPreparedLifecycle: Bool {
        switch lifecycle {
        case .prepared, .starting, .running, .pausing, .paused, .resuming:
            true
        case .idle, .preparing, .stopping, .ended:
            false
        }
    }

    private func registerCleanupContent(_ deep: BoundDeep) {
        cleanupNeedleLedger.register(deep.composedText)
        for reference in deep.basis {
            cleanupNeedleLedger.register(reference.claim)
        }
    }

    private func registerRetainedCleanupContent() {
        for segment in timeline.segments {
            cleanupNeedleLedger.register(segment.text)
        }
        for suggestion in suggestions {
            cleanupNeedleLedger.register(suggestion.text)
            for reference in suggestion.evidence {
                cleanupNeedleLedger.register(reference.claim)
            }
        }
        if let pendingMicrophoneObservation {
            cleanupNeedleLedger.register(pendingMicrophoneObservation.observation.result.text)
        }
        if let latestOutputObservation {
            cleanupNeedleLedger.register(latestOutputObservation.result.text)
        }
        if let bridgeSpeechHold {
            cleanupNeedleLedger.register(bridgeSpeechHold.bridgeText)
        }
        if let queuedDeepResponse {
            registerCleanupContent(queuedDeepResponse.response)
        }
    }

    private func clearVisibleMeetingContentForStop() {
        timeline.clear()
        microphonePartialID = nil
        outputPartialID = nil
        turnDetector.invalidate()
        suggestions.removeAll(keepingCapacity: false)
        emit(.transcriptsCleared)
        emit(.suggestionsCleared(currentIdentity))
    }

    private func clearDelayedAttributionState() {
        microphoneAttributionTask?.cancel()
        microphoneAttributionTask = nil
        pendingMicrophoneObservation = nil
        latestOutputObservation = nil
        clearBridgeSpeechState()
    }

    private func makeState() -> MeetingSessionState {
        MeetingSessionState(
            phase: phase,
            captureMode: configuration.captureMode,
            consentConfirmed: consentConfirmed,
            isPrepared: isPreparedLifecycle,
            isRunning: lifecycle == .running,
            runtime: runtime,
            transcript: timeline.segments,
            suggestions: suggestions,
            brownouts: brownouts
        )
    }

    private func emitState() {
        emit(.stateChanged(makeState()))
    }

    private func emitFailure(_ failure: MeetingSessionFailure) {
        emit(.failed(failure))
        emitState()
    }

    private func emit(_ event: MeetingSessionEvent) {
        _ = continuation?.yield(event)
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isLikelyBridgeSpeech(
        _ text: String,
        bridgeText: String
    ) -> Bool {
        guard let candidate = boundedSpeechTokens(text),
            let bridge = boundedSpeechTokens(bridgeText),
            candidate.count >= 2,
            candidate.count <= bridge.count
        else {
            return false
        }
        return isOrderedSubsequence(candidate, of: bridge)
    }

    private static func isCompletedBridgeSpeech(
        _ text: String,
        bridgeText: String
    ) -> Bool {
        guard let candidate = boundedSpeechTokens(text),
            let bridge = boundedSpeechTokens(bridgeText)
        else {
            return false
        }
        if candidate == bridge { return true }
        guard bridge.count > 1 else { return false }

        let maximumOmissions = min(3, max(1, bridge.count / 3))
        let minimumCandidateCount = max(2, bridge.count - maximumOmissions)
        guard candidate.count >= minimumCandidateCount,
            candidate.count < bridge.count
        else {
            return false
        }
        return isOrderedSubsequence(candidate, of: bridge)
    }

    private static func boundedSpeechTokens(_ text: String) -> [String]? {
        let maximumTextBytes = 256
        let maximumTokenCount = 32
        guard text.utf8.count <= maximumTextBytes else { return nil }
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= maximumTokenCount else { return nil }
        return tokens
    }

    private static func isOrderedSubsequence(
        _ candidate: [String],
        of reference: [String]
    ) -> Bool {
        var referenceIndex = reference.startIndex
        for token in candidate {
            while referenceIndex < reference.endIndex,
                reference[referenceIndex] != token
            {
                reference.formIndex(after: &referenceIndex)
            }
            guard referenceIndex < reference.endIndex else { return false }
            reference.formIndex(after: &referenceIndex)
        }
        return true
    }

    private static func lostReason(for lane: AudioLane) -> BrownoutReason {
        lane == .microphone ? .microphoneLost : .systemAudioLost
    }

    private static func sessionFailure(for error: MeetingResponseError) -> MeetingSessionFailure {
        switch error {
        case .signInRequired, .credentialStoreUnavailable:
            .responseSignInRequired
        case .accountMismatch:
            .responseAccountMismatch
        case .protocolUnsupported:
            .responseProtocolUnsupported
        case .quickRateLimited, .deepRateLimited:
            .responseRateLimited
        default:
            .responseUnavailable
        }
    }

    private static func brownout(for error: MeetingResponseError) -> MeetingBrownout {
        switch error {
        case .signInRequired, .credentialStoreUnavailable:
            .init(reason: .authenticationExpired)
        case .accountMismatch:
            .init(reason: .accountMismatch)
        case .protocolUnsupported:
            .init(reason: .protocolUnsupported)
        case .quickRateLimited:
            .init(reason: .quickLimited)
        case .deepRateLimited:
            .init(reason: .deepLimited)
        case .skillPolicyMismatch:
            .init(reason: .skillPolicyMismatch)
        case .groundingUnavailable, .groundingMismatch:
            .init(reason: .snapshotBlocked)
        default:
            .init(reason: .codexOffline)
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func deduplicated(
        _ failures: [MeetingSessionCleanupFailure]
    ) -> [MeetingSessionCleanupFailure] {
        MeetingSessionCleanupFailure.allCases.filter(failures.contains)
    }
}
