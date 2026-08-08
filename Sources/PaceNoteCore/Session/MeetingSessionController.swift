import Foundation

public actor MeetingSessionController {
    private struct TranscriptObservation: Sendable {
        let result: ProgressiveTranscriptResult
        let receivedAt: TimeInterval
    }

    private struct PendingMicrophoneObservation: Sendable {
        let id: UUID
        let observation: TranscriptObservation
    }

    private enum Lifecycle: Equatable {
        case idle
        case preparing(UUID)
        case prepared
        case running
        case paused
        case stopping
        case ended
    }

    private let configuration: MeetingSessionConfiguration
    private let audioServices: MeetingAudioServices
    private let speechAssets: any SpeechAssetPreparing
    private let microphonePermission: any MicrophonePermissionProviding
    private let responseGenerator: any MeetingResponseGenerating
    private let responseCoordinator: ResponseCoordinator
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
    private var currentIdentity: TurnIdentity?
    private var microphonePartialID: UUID?
    private var outputPartialID: UUID?
    private var microphoneEventTask: Task<Void, Never>?
    private var outputEventTask: Task<Void, Never>?
    private var microphoneAttributionTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var pendingMicrophoneObservation: PendingMicrophoneObservation?
    private var latestOutputObservation: TranscriptObservation?
    private var continuation: AsyncStream<MeetingSessionEvent>.Continuation?
    private var lastStopReport: MeetingSessionStopReport?

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
        attributionResolver: TranscriptAttributionResolver = .init()
    ) {
        self.configuration = configuration
        self.audioServices = audioServices
        self.speechAssets = speechAssets
        self.microphonePermission = microphonePermission
        self.responseGenerator = responseGenerator
        self.responseCoordinator = ResponseCoordinator(
            generator: responseGenerator,
            configuration: responseCoordinatorConfiguration
        )
        self.resourceCleaner = resourceCleaner
        self.time = time
        self.attributionResolver = attributionResolver
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
        microphoneEventTask?.cancel()
        outputEventTask?.cancel()
        microphoneAttributionTask?.cancel()
        boundaryTask?.cancel()
        generationTask?.cancel()
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

    public func state() -> MeetingSessionState {
        makeState()
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

        do {
            try validateAudioServices()
            try await prepareMicrophonePermission(attempt: attempt)
            try await prepareSpeechAssets(attempt: attempt)
            try requirePreparing(attempt)

            let preparedRuntime: MeetingResponseRuntime
            do {
                preparedRuntime = try await responseGenerator.prepare()
            } catch let error as MeetingResponseError {
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
                    try requirePreparing(attempt)
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
        do {
            try await startEnabledAudioServices()
            lifecycle = .running
            updateOperationalPhase()
            emitState()
        } catch let failure as MeetingSessionFailure {
            await stopAudioServices()
            lifecycle = .prepared
            updateOperationalPhase()
            emitFailure(failure)
            throw failure
        } catch {
            await stopAudioServices()
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
        lifecycle = .paused
        phase = .paused
        microphoneAttributionTask?.cancel()
        microphoneAttributionTask = nil
        pendingMicrophoneObservation = nil
        latestOutputObservation = nil
        microphonePartialID = nil
        outputPartialID = nil
        boundaryTask?.cancel()
        boundaryTask = nil
        microphoneAttributionTask?.cancel()
        microphoneAttributionTask = nil
        pendingMicrophoneObservation = nil
        latestOutputObservation = nil
        await stopAudioServices()
        await cancelCurrentGeneration(clearSuggestions: true)
        emitState()
    }

    public func resume() async throws {
        guard lifecycle == .paused else {
            throw MeetingSessionFailure.invalidLifecycle
        }
        do {
            try await startEnabledAudioServices()
            lifecycle = .running
            updateOperationalPhase()
            emitState()
        } catch let failure as MeetingSessionFailure {
            await stopAudioServices()
            lifecycle = .paused
            phase = .paused
            emitFailure(failure)
            throw failure
        } catch {
            await stopAudioServices()
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
        guard let candidate = turnDetector.candidate(at: time.now(), force: true) else {
            throw MeetingSessionFailure.noCandidateQuestion
        }
        await beginTurn(question: candidate.text, stableAt: candidate.stableAt)
    }

    @discardableResult
    public func stop() async -> MeetingSessionStopReport {
        if let lastStopReport { return lastStopReport }
        guard lifecycle != .stopping else {
            return MeetingSessionStopReport(
                deletedThreadCount: 0,
                deletedSnapshotCount: 0,
                deletedTemporaryRootCount: 0,
                residualFindingCount: 0,
                journalEntryRemoved: false,
                failures: [.responseCleanup]
            )
        }

        lifecycle = .stopping
        let sensitiveNeedles = cleanupNeedles()

        boundaryTask?.cancel()
        boundaryTask = nil
        await stopAudioServices()
        await cancelCurrentGeneration(clearSuggestions: true)

        let responseReport = await responseGenerator.shutdown()
        let resourceReport = await resourceCleaner.deleteResources(
            preserveCodexRecoveryState: !responseReport.failures.isEmpty
        )

        timeline.clear()
        microphonePartialID = nil
        outputPartialID = nil
        turnDetector.invalidate()
        suggestions.removeAll(keepingCapacity: false)
        currentIdentity = nil
        runtime = nil
        emit(.transcriptsCleared)

        var failures = resourceReport.failures
        if !responseReport.failures.isEmpty {
            failures.append(.responseCleanup)
        }

        let residualFindingCount: Int
        do {
            residualFindingCount = try await resourceCleaner.residualFindingCount(
                sensitiveNeedles: sensitiveNeedles
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
            failures: Self.deduplicated(failures)
        )
        lastStopReport = report
        lifecycle = .ended
        phase = .ended
        emitState()
        continuation?.finish()
        continuation = nil
        return report
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
            activateBrownout(.init(reason: .transcriberAssetMissing))
            throw failure
        } catch {
            activateBrownout(.init(reason: .transcriberAssetMissing))
            throw MeetingSessionFailure.transcriptionAssetUnavailable
        }
    }

    private func startEnabledAudioServices() async throws {
        if configuration.captureMode.capturesMicrophone {
            guard let microphone = audioServices.microphone else {
                throw MeetingSessionFailure.missingAudioServices(.microphone)
            }
            do {
                try await startLane(microphone)
                deactivateBrownout(reason: .microphoneLost, lane: .microphone)
            } catch let error as AudioCaptureError where error == .permissionDenied {
                activateBrownout(.init(reason: .microphoneLost, lane: .microphone))
                throw MeetingSessionFailure.microphonePermissionDenied
            } catch {
                activateBrownout(.init(reason: .microphoneLost, lane: .microphone))
                throw MeetingSessionFailure.captureUnavailable(.microphone)
            }
        }

        if configuration.captureMode.capturesSystemOutput {
            guard let output = audioServices.systemOutput else {
                throw MeetingSessionFailure.missingAudioServices(.output)
            }
            do {
                try await startLane(output)
                deactivateBrownout(reason: .systemAudioLost, lane: .output)
            } catch let error as AudioCaptureError where error == .permissionDenied {
                activateBrownout(.init(reason: .systemAudioLost, lane: .output))
                throw MeetingSessionFailure.systemAudioPermissionDenied
            } catch {
                activateBrownout(.init(reason: .systemAudioLost, lane: .output))
                throw MeetingSessionFailure.captureUnavailable(.output)
            }
        }
    }

    private func startLane(_ services: MeetingAudioLaneServices) async throws {
        let audioEvents = await services.capture.events()
        let transcriptionEvents = await services.transcriber.events()
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
            try await services.capture.start()
        } catch {
            task.cancel()
            setEventTask(nil, lane: services.lane)
            await services.transcriber.stop()
            await services.capture.stop()
            throw error
        }
    }

    private func stopAudioServices() async {
        microphoneEventTask?.cancel()
        outputEventTask?.cancel()
        microphoneEventTask = nil
        outputEventTask = nil

        if configuration.captureMode.capturesMicrophone,
            let microphone = audioServices.microphone
        {
            await microphone.transcriber.stop()
            await microphone.capture.stop()
        }
        if configuration.captureMode.capturesSystemOutput,
            let output = audioServices.systemOutput
        {
            await output.transcriber.stop()
            await output.capture.stop()
        }
    }

    private func handleTranscription(_ event: SpeechTranscriptionEvent) async {
        guard lifecycle == .running else { return }
        switch event {
        case .started(let lane, _):
            deactivateBrownout(reason: Self.lostReason(for: lane), lane: lane)
            updateOperationalPhase()
            emitState()

        case .result(let result):
            if result.lane == .microphone {
                await handleMicrophoneResult(result)
            } else {
                await handleOutputResult(result)
            }

        case .gap(let gap):
            await cancelCurrentGeneration(clearSuggestions: true)
            activateBrownout(.init(reason: Self.lostReason(for: gap.lane), lane: gap.lane))
            phase = .brownout
            emitState()

        case .routeChanged(let previous, let current):
            await cancelCurrentGeneration(clearSuggestions: true)
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
            await cancelCurrentGeneration(clearSuggestions: true)
            if reason == .assetUnavailable {
                activateBrownout(.init(reason: .transcriberAssetMissing, lane: lane))
            } else {
                activateBrownout(.init(reason: Self.lostReason(for: lane), lane: lane))
                activateBrownout(.init(reason: .transcriptUncertain, lane: lane))
            }
            phase = .brownout
            emitState()

        case .stopped(let lane):
            await cancelCurrentGeneration(clearSuggestions: true)
            activateBrownout(.init(reason: Self.lostReason(for: lane), lane: lane))
            phase = .brownout
            emitState()
        }
    }

    private func handleMicrophoneResult(_ result: ProgressiveTranscriptResult) async {
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
        }

        latestOutputObservation = observation
        let segment = ingest(result, source: .them)
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
            await self?.flushMicrophone(id: pending.id)
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
            .attribute(source: .you, speakerUncertain: false),
            observation: pending.observation
        )
    }

    private func applyMicrophone(
        _ decision: TranscriptAttributionDecision,
        observation: TranscriptObservation
    ) async {
        switch decision {
        case .suppressEcho:
            suppressCurrentMicrophonePartial()
            deactivateBrownout(reason: .speakerUncertain, lane: .microphone)
            emitState()

        case .attribute(let source, let speakerUncertain):
            if speakerUncertain {
                activateBrownout(.init(reason: .speakerUncertain, lane: .microphone))
            } else {
                deactivateBrownout(reason: .speakerUncertain, lane: .microphone)
            }
            if source == .you, !speakerUncertain {
                await cancelGenerationForLocalSpeech()
            }
            _ = ingest(observation.result, source: source)
        }
    }

    @discardableResult
    private func ingest(
        _ result: ProgressiveTranscriptResult,
        source: TranscriptSource
    ) -> TranscriptSegment {
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
        generation &+= 1
        let identity = TurnIdentity(
            meetingID: configuration.meetingID,
            generation: generation
        )
        let previousIdentity = currentIdentity
        currentIdentity = identity
        generationTask?.cancel()
        generationTask = nil
        suggestions.removeAll(keepingCapacity: true)
        emit(.suggestionsCleared(previousIdentity))
        phase = .candidateQuestion
        emitState()

        await responseCoordinator.invalidate()
        await responseGenerator.cancelActiveWork()
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
                await self?.handleResponse(event, identity: identity)
            }
            await self?.generationFinished(identity: identity)
        }
    }

    private func handleResponse(_ event: ResponseCoordinatorEvent, identity: TurnIdentity) {
        guard lifecycle == .running, currentIdentity == identity else { return }
        switch event {
        case .cue(let cue):
            guard cue.turnID == identity.turnID, cue.generation == identity.generation else { return }
            let stage: SuggestionStage = cue.isDeterministicBridge ? .bridge : .quick
            let card = SuggestionCard(identity: identity, stage: stage, text: cue.text)
            suggestions.removeAll { $0.identity == identity && $0.stage != .deep }
            suggestions.insert(card, at: 0)
            phase = .suggesting
            emit(.suggestionUpserted(card))
            emitState()

        case .deep(let deep):
            guard deep.turnID == identity.turnID, deep.generation == identity.generation else { return }
            let card = SuggestionCard(
                identity: identity,
                stage: .deep,
                text: deep.composedText,
                evidence: deep.basis
            )
            suggestions.removeAll { $0.identity == identity && $0.stage == .deep }
            suggestions.append(card)
            phase = .suggesting
            emit(.suggestionUpserted(card))
            emitState()

        case .quickUnavailable:
            activateBrownout(.init(reason: .quickLimited))
            updateOperationalPhase()
            emitState()

        case .deepUnavailable:
            activateBrownout(.init(reason: .deepLimited))
            updateOperationalPhase()
            emitState()

        case .discardedStale:
            break
        }
    }

    private func generationFinished(identity: TurnIdentity) {
        guard lifecycle == .running, currentIdentity == identity else { return }
        generationTask = nil
        updateOperationalPhase()
        emitState()
    }

    private func cancelGenerationForLocalSpeech() async {
        guard generationTask != nil || (currentIdentity != nil && suggestions.isEmpty) else {
            return
        }
        await cancelCurrentGeneration(clearSuggestions: false)
        updateOperationalPhase()
    }

    private func cancelCurrentGeneration(clearSuggestions: Bool) async {
        boundaryTask?.cancel()
        boundaryTask = nil
        generationTask?.cancel()
        generationTask = nil
        let previousIdentity = currentIdentity
        currentIdentity = nil
        await responseCoordinator.invalidate()
        await responseGenerator.cancelActiveWork()
        if clearSuggestions {
            suggestions.removeAll(keepingCapacity: false)
            emit(.suggestionsCleared(previousIdentity))
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

    private func updateOperationalPhase() {
        switch lifecycle {
        case .idle:
            phase = consentConfirmed ? .idle : .permissionRequired
        case .preparing:
            phase = .idle
        case .prepared:
            phase = hasBlockingBrownout ? .brownout : .ready
        case .running:
            if hasBlockingBrownout {
                phase = .brownout
            } else {
                phase = suggestions.isEmpty ? .listening : .suggesting
            }
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
                .speakerUncertain:
                false
            default:
                true
            }
        }
    }

    private func cleanupNeedles() -> [Data] {
        let transcriptNeedles = timeline.segments.map(\.text)
        let suggestionNeedles = suggestions.map(\.text)
        return Array(
            Set(
                (transcriptNeedles + suggestionNeedles)
                    .map(Self.normalized)
                    .filter { $0.utf8.count >= 8 }
                    .map { Data($0.utf8) }
            )
        )
    }

    private func makeState() -> MeetingSessionState {
        MeetingSessionState(
            phase: phase,
            captureMode: configuration.captureMode,
            consentConfirmed: consentConfirmed,
            isPrepared: lifecycle == .prepared || lifecycle == .running || lifecycle == .paused,
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
