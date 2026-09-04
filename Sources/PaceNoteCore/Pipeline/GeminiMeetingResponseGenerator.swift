import Foundation

public struct GeminiMeetingResponseConfiguration: Sendable {
    public let meetingID: UUID
    public let meetingPrivateRoot: URL
    public let realHomeDirectory: URL
    public let speakingStyle: String
    public let groundingSnapshot: GroundingSnapshot?
    public let deepPerMinute: Int

    public init(
        meetingID: UUID,
        meetingPrivateRoot: URL,
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        speakingStyle: String = "calm, direct, and conversational",
        groundingSnapshot: GroundingSnapshot?,
        deepPerMinute: Int = 2
    ) {
        self.meetingID = meetingID
        self.meetingPrivateRoot = meetingPrivateRoot.standardizedFileURL
        self.realHomeDirectory = realHomeDirectory.standardizedFileURL
        self.speakingStyle = speakingStyle
        self.groundingSnapshot = groundingSnapshot
        self.deepPerMinute = max(0, deepPerMinute)
    }

    public var runtimeRoot: URL {
        meetingPrivateRoot.appendingPathComponent("gemini-runtime", isDirectory: true)
    }
}

public typealias GeminiMeetingRuntimePreparer =
    @Sendable (GeminiMeetingResponseConfiguration) throws -> GeminiIsolatedRuntime
public typealias GeminiMeetingVersionVerifier =
    @Sendable (GeminiIsolatedRuntime) async throws -> Void
public typealias GeminiMeetingExecutableRevalidator =
    @Sendable (GeminiIsolatedRuntime) throws -> Void

public actor GeminiMeetingResponseGenerator: MeetingResponseGenerating {
    private enum Lifecycle: Sendable { case open, closing, closed }
    private struct ActiveDeep: Sendable { let id: UUID; let task: Task<DeepDraft, Error> }
    private struct ActivePreparation: Sendable {
        let id: UUID
        let task: Task<MeetingResponseRuntime, Error>
    }

    private struct DeepInput: Encodable, Sendable {
        struct ExpectedEnvelope: Encodable, Sendable {
            let turnID: UUID
            let generation: UInt64
            let groundingFingerprint: String?
            let repoAlias: String?
        }
        struct TranscriptLine: Encodable, Sendable { let source: String; let text: String }

        let protocolVersion: String
        let expected: ExpectedEnvelope
        let speakingStyle: String
        let speakerBrief: String?
        let meetingQuestion: String
        let recentTranscript: [TranscriptLine]
        let generalGuidancePolicy: String
        let sealedEvidence: ClaudeGroundingPack?
    }

    private let configuration: GeminiMeetingResponseConfiguration
    private let runner: any ClaudeCommandRunning
    private let subscriptionChecker: (any GeminiSubscriptionChecking)?
    private let evidenceVerifier: any MeetingEvidenceVerifying
    private let groundingPackBuilder: any ClaudeGroundingPackBuilding
    private let runtimePreparer: GeminiMeetingRuntimePreparer
    private let versionVerifier: GeminiMeetingVersionVerifier
    private let executableRevalidator: GeminiMeetingExecutableRevalidator

    private var lifecycle: Lifecycle = .open
    private var isolatedRuntime: GeminiIsolatedRuntime?
    private var responseRuntime: MeetingResponseRuntime?
    private var preparedSubscription: GeminiSubscriptionStatus?
    private var activePreparation: ActivePreparation?
    private var preparationCleanupInProgress = false
    #if DEBUG
        private var preparationFailureResumedTestHook: (@Sendable (UUID) async -> Void)?
    #endif
    private var activeDeep: ActiveDeep?
    private var governor: UsageGovernor
    private var shutdownTask: Task<MeetingResponseCleanupReport, Never>?
    private var lastCleanupReport: MeetingResponseCleanupReport?

    public init(
        configuration: GeminiMeetingResponseConfiguration,
        runner: any ClaudeCommandRunning = ClaudeProcessRunner(),
        subscriptionChecker: (any GeminiSubscriptionChecking)? = nil,
        evidenceVerifier: any MeetingEvidenceVerifying = DefaultMeetingEvidenceVerifier(),
        groundingPackBuilder: any ClaudeGroundingPackBuilding = ClaudeGroundingPackBuilder(),
        runtimePreparer: @escaping GeminiMeetingRuntimePreparer = { configuration in
            try GeminiRuntimeBuilder.prepare(
                runtimeRoot: configuration.runtimeRoot,
                realHomeDirectory: configuration.realHomeDirectory
            )
        },
        versionVerifier: @escaping GeminiMeetingVersionVerifier = { runtime in
            let version = try await GeminiBinaryInspector.inspect(
                executableURL: runtime.executableURL,
                currentDirectoryURL: runtime.workingDirectory,
                environment: runtime.processEnvironment
            )
            try GeminiVersionPolicy.tested.validate(version)
        },
        executableRevalidator: @escaping GeminiMeetingExecutableRevalidator = { runtime in
            try runtime.revalidateExecutable()
        }
    ) {
        self.configuration = configuration
        self.runner = runner
        self.subscriptionChecker = subscriptionChecker
        self.evidenceVerifier = evidenceVerifier
        self.groundingPackBuilder = groundingPackBuilder
        self.runtimePreparer = runtimePreparer
        self.versionVerifier = versionVerifier
        self.executableRevalidator = executableRevalidator
        self.governor = UsageGovernor(quickPerMinute: 0, deepPerMinute: configuration.deepPerMinute)
    }

    #if DEBUG
        func setPreparationFailureResumedTestHook(
            _ hook: (@Sendable (UUID) async -> Void)?
        ) {
            preparationFailureResumedTestHook = hook
        }
    #endif

    public func prepare() async throws -> MeetingResponseRuntime {
        try requireOpen()
        if let responseRuntime { return responseRuntime }
        let operation: ActivePreparation
        if let activePreparation {
            operation = activePreparation
        } else {
            let id = UUID()
            let task = Task { try await self.performPrepare() }
            operation = ActivePreparation(id: id, task: task)
            activePreparation = operation
        }
        do {
            let prepared = try await operation.task.value
            if activePreparation?.id == operation.id { activePreparation = nil }
            try requireOpen()
            return prepared
        } catch {
            if lifecycle == .open,
                activePreparation?.id == operation.id,
                !preparationCleanupInProgress
            {
                preparationCleanupInProgress = true
                isolatedRuntime = nil
                responseRuntime = nil
                preparedSubscription = nil
                try? Self.removeRuntimeRoot(
                    configuration.runtimeRoot,
                    meetingPrivateRoot: configuration.meetingPrivateRoot
                )
                if activePreparation?.id == operation.id {
                    activePreparation = nil
                }
                preparationCleanupInProgress = false
            }
            #if DEBUG
                if let preparationFailureResumedTestHook {
                    await preparationFailureResumedTestHook(operation.id)
                }
            #endif
            if error is CancellationError { throw CancellationError() }
            throw Self.map(error)
        }
    }

    public func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        try requirePrepared(for: turn)
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: ResponseCoordinatorConfiguration.deterministicFallback,
            needsDeep: true,
            confidence: 1,
            reason: "deterministic_safety_bridge"
        )
    }

    public func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        try requirePrepared(for: turn)
        guard activeDeep == nil else { throw MeetingResponseError.deepAlreadyActive }
        let reservation: GovernorReservation
        switch governor.reserve(.deep) {
        case .reserved(let admitted):
            reservation = admitted
        case .deepAlreadyActive:
            throw MeetingResponseError.deepAlreadyActive
        case .quickRateLimited, .deepRateLimited:
            throw MeetingResponseError.deepRateLimited
        }
        let id = UUID()
        let worker = Task { try await self.performDeep(for: turn, reservation: reservation) }
        activeDeep = ActiveDeep(id: id, task: worker)
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
            Task { await self.runner.cancelActive() }
        }
        finishDeep(id: id)
        switch result {
        case .success:
            governor.finish(reservation)
        case .failure(let error):
            governor.finish(reservation, refundCommitted: error is CancellationError)
        }
        return try result.get()
    }

    public func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        try requireOpen()
        guard cue.turnID == draft.turnID, cue.generation == draft.generation else {
            throw MeetingResponseError.invalidOutput
        }
        return switch draft.kind {
        case .answer:
            Reconciliation(relationship: .continueAnswer, transition: "Here’s the concrete detail.")
        case .generalAnswer:
            Reconciliation(
                relationship: .continueAnswer,
                transition: cue.isDeterministicBridge
                    ? "Here’s the direct answer."
                    : "The part I’d add is this."
            )
        case .clarification:
            Reconciliation(relationship: .clarify, transition: "One thing I’d ask first.")
        case .abstention:
            Reconciliation(relationship: .abstain, transition: "I’d be careful here.")
        }
    }

    public func cancelActiveWork() async {
        guard lifecycle == .open, let activeDeep else { return }
        activeDeep.task.cancel()
        await runner.cancelActive()
        _ = await activeDeep.task.result
        finishDeep(id: activeDeep.id)
    }

    public func shutdown() async -> MeetingResponseCleanupReport {
        if let shutdownTask { return await shutdownTask.value }
        if let lastCleanupReport, lifecycle == .closed { return lastCleanupReport }
        lifecycle = .closing
        activePreparation?.task.cancel()
        let worker = Task { await self.performShutdown() }
        shutdownTask = worker
        return await worker.value
    }

    private func performPrepare() async throws -> MeetingResponseRuntime {
        try Self.validateConfiguration(configuration)
        try Task.checkCancellation()
        let runtime = try runtimePreparer(configuration)
        isolatedRuntime = runtime
        try executableRevalidator(runtime)
        try await versionVerifier(runtime)
        try Task.checkCancellation()
        let account = try await makeSubscriptionChecker(runtime: runtime).subscriptionStatus()
        let prepared = MeetingResponseRuntime(
            planType: account.planType,
            quickRoute: CodexModelRoute(model: "local-deterministic-bridge", effort: "none"),
            deepRoute: CodexModelRoute(model: "gemini-pro", effort: "high"),
            usesRealtimeQuick: false
        )
        preparedSubscription = account
        responseRuntime = prepared
        lastCleanupReport = nil
        return prepared
    }

    private func performDeep(
        for turn: ConversationTurn,
        reservation: GovernorReservation
    ) async throws -> DeepDraft {
        do {
            try Task.checkCancellation()
            guard let runtime = isolatedRuntime, responseRuntime != nil else {
                throw MeetingResponseError.notPrepared
            }
            let pack: ClaudeGroundingPack?
            if let snapshot = configuration.groundingSnapshot {
                guard turn.repoAlias == snapshot.repoAlias,
                    turn.groundingFingerprint == snapshot.groundingFingerprint,
                    await evidenceVerifier.isFresh(snapshot)
                else { throw MeetingResponseError.groundingMismatch }
                pack = try await groundingPackBuilder.pack(for: turn, snapshot: snapshot)
            } else {
                guard turn.repoAlias == nil, turn.groundingFingerprint == nil else {
                    throw MeetingResponseError.groundingMismatch
                }
                pack = nil
            }

            var input = try Self.makeInput(
                turn: turn,
                speakingStyle: configuration.speakingStyle,
                pack: pack
            )
            defer {
                try? GeminiRuntimeBuilder.clearInput(runtime: runtime)
                input.resetBytes(in: input.startIndex..<input.endIndex)
                input.removeAll(keepingCapacity: false)
            }
            try Task.checkCancellation()
            let current = try await makeSubscriptionChecker(runtime: runtime).subscriptionStatus()
            guard current == preparedSubscription else { throw MeetingResponseError.accountMismatch }
            try executableRevalidator(runtime)
            try GeminiRuntimeBuilder.writeInput(input, runtime: runtime)
            try Task.checkCancellation()
            governor.commit(reservation)
            let result = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: runtime.executableURL,
                    currentDirectoryURL: runtime.workingDirectory,
                    arguments: runtime.processArguments,
                    environment: runtime.processEnvironment,
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(25),
                        maximumStandardInputBytes: 0,
                        maximumStandardOutputBytes: 256 * 1_024,
                        maximumStandardErrorBytes: 32 * 1_024,
                        terminationGracePeriod: .milliseconds(500)
                    ),
                    postLaunchValidator: { processID, executableURL in
                        try SpawnedProcessAttestation.validateGemini(
                            processID: processID,
                            executableURL: executableURL
                        )
                    }
                )
            )
            try Task.checkCancellation()
            var output = result.standardOutput
            var errors = result.standardError
            defer {
                output.resetBytes(in: output.startIndex..<output.endIndex)
                output.removeAll(keepingCapacity: false)
                errors.resetBytes(in: errors.startIndex..<errors.endIndex)
                errors.removeAll(keepingCapacity: false)
            }
            guard result.terminationStatus == 0 else {
                throw MeetingResponseError.runtimeUnavailable
            }
            let receivedDraft = try GeminiStructuredOutput.decode(output, as: DeepDraft.self)
            let draft = try Self.validatedDraft(receivedDraft, for: turn)
            if let snapshot = configuration.groundingSnapshot, let pack {
                guard draft.basis.allSatisfy(pack.contains) else {
                    throw MeetingResponseError.groundingMismatch
                }
                if draft.kind == .answer {
                    guard draft.basis.count == 1 else {
                        throw MeetingResponseError.groundingMismatch
                    }
                    try await evidenceVerifier.verifyAnswer(
                        candidateSayNext: draft.candidateSayNext,
                        draft.basis,
                        groundingFingerprint: snapshot.groundingFingerprint,
                        against: snapshot
                    )
                }
            }
            return draft
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    private func performShutdown() async -> MeetingResponseCleanupReport {
        if let activePreparation {
            activePreparation.task.cancel()
            await runner.cancelActive()
            _ = await activePreparation.task.result
            self.activePreparation = nil
            preparationCleanupInProgress = false
        }
        if let activeDeep {
            activeDeep.task.cancel()
            await runner.cancelActive()
            _ = await activeDeep.task.result
            finishDeep(id: activeDeep.id)
        } else {
            await runner.cancelActive()
        }
        isolatedRuntime = nil
        responseRuntime = nil
        preparedSubscription = nil
        var failures: [MeetingResponseCleanupFailure] = []
        do {
            try Self.removeRuntimeRoot(
                configuration.runtimeRoot,
                meetingPrivateRoot: configuration.meetingPrivateRoot
            )
        } catch {
            failures.append(.shutdownRuntime)
        }
        lifecycle = .closed
        let report = MeetingResponseCleanupReport(failures: failures)
        lastCleanupReport = report
        shutdownTask = nil
        return report
    }

    private func makeSubscriptionChecker(
        runtime: GeminiIsolatedRuntime
    ) -> any GeminiSubscriptionChecking {
        if let subscriptionChecker { return subscriptionChecker }
        return GeminiCLIAuthStatusChecker(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment,
            runner: runner
        )
    }

    private func finishDeep(id: UUID) {
        guard activeDeep?.id == id else { return }
        activeDeep = nil
    }

    private func requireOpen() throws {
        guard lifecycle == .open else { throw MeetingResponseError.notPrepared }
    }

    private func requirePrepared(for turn: ConversationTurn) throws {
        try requireOpen()
        guard responseRuntime != nil, isolatedRuntime != nil else {
            throw MeetingResponseError.notPrepared
        }
        guard turn.identity.meetingID == configuration.meetingID else {
            throw MeetingResponseError.invalidOutput
        }
    }

    private static func validateConfiguration(
        _ configuration: GeminiMeetingResponseConfiguration
    ) throws {
        let root = configuration.meetingPrivateRoot
        let runtimeRoot = configuration.runtimeRoot.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"),
            runtimeRoot.deletingLastPathComponent().standardizedFileURL == root,
            runtimeRoot.lastPathComponent == "gemini-runtime",
            boundedText(configuration.speakingStyle, maximumBytes: 256)
                == configuration.speakingStyle,
            !configuration.speakingStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MeetingResponseError.runtimeUnavailable }
        if let snapshot = configuration.groundingSnapshot {
            let snapshotRoot = snapshot.snapshotRoot.resolvingSymlinksInPath().standardizedFileURL
            let privateRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard snapshotRoot.path.hasPrefix(privateRoot.path + "/") else {
                throw MeetingResponseError.groundingMismatch
            }
        }
    }

    private static func makeInput(
        turn: ConversationTurn,
        speakingStyle: String,
        pack: ClaudeGroundingPack?
    ) throws -> Data {
        let question = boundedText(turn.question, maximumBytes: 4 * 1_024)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !turn.question.contains("\0")
        else { throw MeetingResponseError.invalidOutput }
        let transcript = turn.deepConversation.suffix(pack == nil ? 16 : 6).map {
            DeepInput.TranscriptLine(
                source: $0.source.rawValue,
                text: boundedText(
                    $0.text.replacingOccurrences(of: "\0", with: ""),
                    maximumBytes: 512
                )
            )
        }
        let value = DeepInput(
            protocolVersion: "chirpcue.gemini.deep.v1",
            expected: .init(
                turnID: turn.identity.turnID,
                generation: turn.identity.generation,
                groundingFingerprint: turn.groundingFingerprint,
                repoAlias: turn.repoAlias
            ),
            speakingStyle: boundedText(speakingStyle, maximumBytes: 256),
            speakerBrief: turn.speakerBrief.map {
                boundedText($0, maximumBytes: pack == nil ? 8_192 : 4_096)
            },
            meetingQuestion: question,
            recentTranscript: transcript,
            generalGuidancePolicy: GeneralGuidancePolicy.detailedModelInstructions,
            sealedEvidence: pack
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 32 * 1_024 else { throw MeetingResponseError.invalidOutput }
        return data
    }

    private static func validatedDraft(
        _ draft: DeepDraft,
        for turn: ConversationTurn
    ) throws -> DeepDraft {
        guard let normalized = DeepDraftValidationPolicy.normalized(draft, for: turn) else {
            throw MeetingResponseError.invalidOutput
        }
        return normalized
    }

    private static func boundedText(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars {
            let bytes = String(scalar).utf8.count
            guard count + bytes <= maximumBytes else { break }
            result.append(scalar)
            count += bytes
        }
        return String(result)
    }

    private static func removeRuntimeRoot(_ runtimeRoot: URL, meetingPrivateRoot: URL) throws {
        let root = runtimeRoot.standardizedFileURL
        let parent = meetingPrivateRoot.standardizedFileURL
        guard root.lastPathComponent == "gemini-runtime",
            root.deletingLastPathComponent().standardizedFileURL == parent
        else { throw MeetingResponseError.cleanupFailed }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    private static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? MeetingResponseError { return error }
        if error is GeminiStructuredOutputError || error is DecodingError {
            return MeetingResponseError.invalidOutput
        }
        if error is ClaudeGroundingPackError || error is EvidenceVerificationError {
            return MeetingResponseError.groundingMismatch
        }
        if let error = error as? GeminiSubscriptionError {
            return switch error {
            case .signedOut: MeetingResponseError.credentialStoreUnavailable
            case .noSupportedModels: MeetingResponseError.accountMismatch
            case .invalidStatus, .runtimeUnavailable: MeetingResponseError.runtimeUnavailable
            }
        }
        if error is GeminiBinaryCompatibilityError {
            return MeetingResponseError.protocolUnsupported
        }
        if error is GeminiIsolatedRuntimeError || error is ClaudeCommandError {
            return MeetingResponseError.runtimeUnavailable
        }
        return MeetingResponseError.runtimeUnavailable
    }
}
