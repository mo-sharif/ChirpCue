import Foundation

public struct ClaudeMeetingResponseConfiguration: Sendable {
    public let meetingID: UUID
    public let meetingPrivateRoot: URL
    public let launcherURL: URL?
    public let realHomeDirectory: URL
    public let expectedAccountIdentityHash: String?
    public let speakingStyle: String
    public let groundingSnapshot: GroundingSnapshot?
    public let deepPerMinute: Int

    public init(
        meetingID: UUID,
        meetingPrivateRoot: URL,
        launcherURL: URL? = nil,
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedAccountIdentityHash: String? = nil,
        speakingStyle: String = "calm, direct, and conversational",
        groundingSnapshot: GroundingSnapshot?,
        deepPerMinute: Int = 2
    ) {
        self.meetingID = meetingID
        self.meetingPrivateRoot = meetingPrivateRoot.standardizedFileURL
        self.launcherURL = launcherURL?.standardizedFileURL
        self.realHomeDirectory = realHomeDirectory.standardizedFileURL
        self.expectedAccountIdentityHash = expectedAccountIdentityHash
        self.speakingStyle = speakingStyle
        self.groundingSnapshot = groundingSnapshot
        self.deepPerMinute = max(0, deepPerMinute)
    }

    public var runtimeRoot: URL {
        meetingPrivateRoot.appendingPathComponent("claude-runtime", isDirectory: true)
    }
}

public typealias ClaudeMeetingRuntimePreparer =
    @Sendable (
        ClaudeMeetingResponseConfiguration
    ) throws -> ClaudeIsolatedRuntime

public typealias ClaudeMeetingVersionVerifier =
    @Sendable (
        ClaudeIsolatedRuntime
    ) async throws -> Void

public typealias ClaudeMeetingExecutableRevalidator =
    @Sendable (
        ClaudeIsolatedRuntime
    ) throws -> Void

public typealias ClaudeMeetingManagedPolicyValidator = @Sendable () throws -> Void

public actor ClaudeMeetingResponseGenerator: MeetingResponseGenerating {
    private enum Lifecycle: Sendable {
        case open
        case closing
        case closed
    }

    private struct ActiveDeep: Sendable {
        let id: UUID
        let task: Task<DeepDraft, Error>
    }

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

        struct TranscriptLine: Encodable, Sendable {
            let source: String
            let text: String
        }

        let protocolVersion: String
        let expected: ExpectedEnvelope
        let speakingStyle: String
        let meetingQuestion: String
        let recentTranscript: [TranscriptLine]
        let sealedEvidence: ClaudeGroundingPack?
    }

    private let configuration: ClaudeMeetingResponseConfiguration
    private let runner: any ClaudeCommandRunning
    private let subscriptionChecker: (any ClaudeSubscriptionChecking)?
    private let evidenceVerifier: any MeetingEvidenceVerifying
    private let groundingPackBuilder: any ClaudeGroundingPackBuilding
    private let runtimePreparer: ClaudeMeetingRuntimePreparer
    private let versionVerifier: ClaudeMeetingVersionVerifier
    private let executableRevalidator: ClaudeMeetingExecutableRevalidator
    private let managedPolicyValidator: ClaudeMeetingManagedPolicyValidator

    private var lifecycle: Lifecycle = .open
    private var isolatedRuntime: ClaudeIsolatedRuntime?
    private var responseRuntime: MeetingResponseRuntime?
    private var activePreparation: ActivePreparation?
    private var preparationCleanupInProgress = false
    private var activeDeep: ActiveDeep?
    private var governor: UsageGovernor
    private var shutdownTask: Task<MeetingResponseCleanupReport, Never>?
    private var lastCleanupReport: MeetingResponseCleanupReport?

    public init(
        configuration: ClaudeMeetingResponseConfiguration,
        runner: any ClaudeCommandRunning = ClaudeProcessRunner(),
        subscriptionChecker: (any ClaudeSubscriptionChecking)? = nil,
        evidenceVerifier: any MeetingEvidenceVerifying = DefaultMeetingEvidenceVerifier(),
        groundingPackBuilder: any ClaudeGroundingPackBuilding = ClaudeGroundingPackBuilder(),
        runtimePreparer: @escaping ClaudeMeetingRuntimePreparer = { configuration in
            try ClaudeRuntimeBuilder.prepare(
                runtimeRoot: configuration.runtimeRoot,
                launcherURL: configuration.launcherURL,
                realHomeDirectory: configuration.realHomeDirectory
            )
        },
        versionVerifier: @escaping ClaudeMeetingVersionVerifier = { runtime in
            let version = try await ClaudeBinaryInspector.inspect(
                executableURL: runtime.executableURL,
                environment: runtime.processEnvironment
            )
            try ClaudeVersionPolicy.tested.validate(version)
        },
        executableRevalidator: @escaping ClaudeMeetingExecutableRevalidator = { runtime in
            try runtime.revalidateExecutable()
        },
        managedPolicyValidator: @escaping ClaudeMeetingManagedPolicyValidator =
            ClaudeManagedPolicyValidator.validate
    ) {
        self.configuration = configuration
        self.runner = runner
        self.subscriptionChecker = subscriptionChecker
        self.evidenceVerifier = evidenceVerifier
        self.groundingPackBuilder = groundingPackBuilder
        self.runtimePreparer = runtimePreparer
        self.versionVerifier = versionVerifier
        self.executableRevalidator = executableRevalidator
        self.managedPolicyValidator = managedPolicyValidator
        self.governor = UsageGovernor(quickPerMinute: 0, deepPerMinute: configuration.deepPerMinute)
    }

    public func prepare() async throws -> MeetingResponseRuntime {
        try requireOpen()
        if let responseRuntime { return responseRuntime }

        let preparation: ActivePreparation
        if let activePreparation {
            preparation = activePreparation
        } else {
            let id = UUID()
            let created = Task { try await self.performPrepare() }
            let operation = ActivePreparation(id: id, task: created)
            activePreparation = operation
            preparation = operation
        }

        do {
            let prepared = try await preparation.task.value
            if activePreparation?.id == preparation.id {
                activePreparation = nil
            }
            try requireOpen()
            return prepared
        } catch {
            if lifecycle == .open,
                activePreparation?.id == preparation.id,
                !preparationCleanupInProgress
            {
                preparationCleanupInProgress = true
                isolatedRuntime = nil
                responseRuntime = nil
                try? Self.removeRuntimeRoot(
                    configuration.runtimeRoot,
                    meetingPrivateRoot: configuration.meetingPrivateRoot
                )
                if activePreparation?.id == preparation.id {
                    activePreparation = nil
                }
                preparationCleanupInProgress = false
            }
            if error is CancellationError { throw CancellationError() }
            throw Self.map(error)
        }
    }

    public func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        try requirePrepared(for: turn)
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: "Let me think through that carefully for a second.",
            needsDeep: true,
            confidence: 1,
            reason: "deterministic_safety_bridge"
        )
    }

    public func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        try requirePrepared(for: turn)
        guard activeDeep == nil else { throw MeetingResponseError.deepAlreadyActive }
        switch governor.begin(.deep) {
        case .admitted:
            break
        case .deepRateLimited:
            throw MeetingResponseError.deepRateLimited
        case .deepAlreadyActive:
            throw MeetingResponseError.deepAlreadyActive
        case .quickRateLimited:
            throw MeetingResponseError.deepRateLimited
        }

        let id = UUID()
        let worker = Task { try await self.performDeep(for: turn) }
        activeDeep = ActiveDeep(id: id, task: worker)

        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
            Task { await self.runner.cancelActive() }
        }
        finishDeep(id: id)
        return try result.get()
    }

    public func reconcile(cue: CueEnvelope, draft: DeepDraft) async throws -> Reconciliation {
        try requireOpen()
        guard cue.turnID == draft.turnID,
            cue.generation == draft.generation,
            !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MeetingResponseError.invalidOutput
        }
        return switch draft.kind {
        case .answer:
            Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
        case .generalAnswer:
            Reconciliation(relationship: .continueAnswer, transition: "Broadly speaking,")
        case .clarification:
            Reconciliation(relationship: .clarify, transition: "The detail I need is:")
        case .abstention:
            Reconciliation(relationship: .abstain, transition: "I cannot verify that yet.")
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
        try requireOpen()
        try Self.validateConfiguration(configuration)
        try managedPolicyValidator()
        try Task.checkCancellation()

        let runtime = try runtimePreparer(configuration)
        isolatedRuntime = runtime
        try requireOpen()
        try Task.checkCancellation()

        // The immutable target is revalidated directly before every subprocess request.
        try managedPolicyValidator()
        try executableRevalidator(runtime)
        try await versionVerifier(runtime)
        try requireOpen()
        try Task.checkCancellation()

        let checker: any ClaudeSubscriptionChecking
        if let subscriptionChecker {
            checker = subscriptionChecker
        } else {
            checker = ClaudeCLIAuthStatusChecker(
                executableURL: runtime.executableURL,
                currentDirectoryURL: runtime.workingDirectory,
                environment: runtime.processEnvironment,
                runner: runner
            )
        }
        try managedPolicyValidator()
        try executableRevalidator(runtime)
        let account = try await checker.subscriptionStatus()
        try requireOpen()
        try Task.checkCancellation()

        if let expected = configuration.expectedAccountIdentityHash,
            expected != account.identityHash
        {
            throw MeetingResponseError.accountMismatch
        }

        let prepared = MeetingResponseRuntime(
            planType: account.planType,
            quickRoute: CodexModelRoute(model: "local-deterministic-bridge", effort: "none"),
            deepRoute: CodexModelRoute(model: "sonnet", effort: "high"),
            usesRealtimeQuick: false
        )
        responseRuntime = prepared
        lastCleanupReport = nil
        return prepared
    }

    private func performDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        defer { governor.endDeep() }
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
                else {
                    throw MeetingResponseError.groundingMismatch
                }
                try Task.checkCancellation()
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
                input.resetBytes(in: input.startIndex..<input.endIndex)
                input.removeAll(keepingCapacity: false)
            }
            try Task.checkCancellation()

            try managedPolicyValidator()
            try executableRevalidator(runtime)
            let result = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: runtime.executableURL,
                    currentDirectoryURL: runtime.workingDirectory,
                    arguments: runtime.processArguments,
                    environment: runtime.processEnvironment,
                    standardInput: input,
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(25),
                        maximumStandardInputBytes: 32 * 1_024,
                        maximumStandardOutputBytes: 256 * 1_024,
                        maximumStandardErrorBytes: 32 * 1_024,
                        terminationGracePeriod: .milliseconds(500)
                    )
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

            let draft = try ClaudeStructuredOutput.decode(output, as: DeepDraft.self)
            try Self.validate(draft, for: turn)
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
        _ configuration: ClaudeMeetingResponseConfiguration
    ) throws {
        let root = configuration.meetingPrivateRoot
        let runtimeRoot = configuration.runtimeRoot.standardizedFileURL
        guard root.isFileURL,
            root.path.hasPrefix("/"),
            !root.path.contains("\0"),
            runtimeRoot.deletingLastPathComponent().standardizedFileURL == root,
            runtimeRoot.lastPathComponent == "claude-runtime",
            boundedText(configuration.speakingStyle, maximumBytes: 256)
                == configuration.speakingStyle,
            !configuration.speakingStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MeetingResponseError.runtimeUnavailable
        }
        if let expected = configuration.expectedAccountIdentityHash {
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            guard expected.utf8.count == 64,
                expected.unicodeScalars.allSatisfy(hex.contains)
            else {
                throw MeetingResponseError.accountMismatch
            }
        }
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
        else {
            throw MeetingResponseError.invalidOutput
        }
        let transcript = turn.recentTranscript.suffix(6).map { segment in
            DeepInput.TranscriptLine(
                source: segment.source.rawValue,
                text: boundedText(segment.text.replacingOccurrences(of: "\0", with: ""), maximumBytes: 768)
            )
        }
        let input = DeepInput(
            protocolVersion: "pacenote.claude.deep.v1",
            expected: DeepInput.ExpectedEnvelope(
                turnID: turn.identity.turnID,
                generation: turn.identity.generation,
                groundingFingerprint: turn.groundingFingerprint,
                repoAlias: turn.repoAlias
            ),
            speakingStyle: boundedText(speakingStyle, maximumBytes: 256),
            meetingQuestion: question,
            recentTranscript: transcript,
            sealedEvidence: pack
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(input)
        guard data.count <= 32 * 1_024 else {
            throw MeetingResponseError.invalidOutput
        }
        return data
    }

    private static func validate(_ draft: DeepDraft, for turn: ConversationTurn) throws {
        guard draft.turnID == turn.identity.turnID,
            draft.generation == turn.identity.generation,
            draft.groundingFingerprint == turn.groundingFingerprint,
            !draft.candidateSayNext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !draft.candidateSayNext.contains("\0"),
            draft.candidateSayNext.utf8.count <= 320,
            wordCount(draft.candidateSayNext) <= 33,
            draft.confidence.isFinite,
            (0...1).contains(draft.confidence),
            draft.basis.count <= 6,
            draft.missingEvidence.count <= 4,
            draft.missingEvidence.allSatisfy({
                !$0.contains("\0") && $0.utf8.count <= 320
            }),
            (turn.repoAlias != nil) == (turn.groundingFingerprint != nil)
        else {
            throw MeetingResponseError.invalidOutput
        }

        if turn.groundingFingerprint == nil {
            guard draft.kind != .answer, draft.basis.isEmpty else {
                throw MeetingResponseError.invalidOutput
            }
            if draft.kind == .generalAnswer,
                !GeneralGuidancePolicy.accepts(draft.candidateSayNext)
            {
                throw MeetingResponseError.invalidOutput
            }
        } else {
            guard draft.kind != .generalAnswer else {
                throw MeetingResponseError.invalidOutput
            }
            if draft.kind == .answer {
                guard !draft.basis.isEmpty else { throw MeetingResponseError.invalidOutput }
            } else {
                guard draft.basis.isEmpty else { throw MeetingResponseError.invalidOutput }
            }
        }
    }

    private static func boundedText(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard count + scalarBytes <= maximumBytes else { break }
            result.append(scalar)
            count += scalarBytes
        }
        return String(result)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func removeRuntimeRoot(
        _ runtimeRoot: URL,
        meetingPrivateRoot: URL
    ) throws {
        let root = runtimeRoot.standardizedFileURL
        let parent = meetingPrivateRoot.standardizedFileURL
        guard root.isFileURL,
            root.lastPathComponent == "claude-runtime",
            root.deletingLastPathComponent().standardizedFileURL == parent
        else {
            throw MeetingResponseError.cleanupFailed
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    private static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? MeetingResponseError { return error }
        if error is ClaudeStructuredOutputError || error is DecodingError {
            return MeetingResponseError.invalidOutput
        }
        if error is ClaudeGroundingPackError || error is EvidenceVerificationError {
            return MeetingResponseError.groundingMismatch
        }
        if let error = error as? ClaudeSubscriptionError {
            return switch error {
            case .signedOut, .missingIdentity:
                MeetingResponseError.credentialStoreUnavailable
            case .unsupportedAuthentication, .unsupportedSubscription:
                MeetingResponseError.accountMismatch
            case .invalidStatus, .runtimeUnavailable:
                MeetingResponseError.runtimeUnavailable
            }
        }
        if error is ClaudeBinaryCompatibilityError {
            return MeetingResponseError.protocolUnsupported
        }
        if error is ClaudeIsolatedRuntimeError || error is ClaudeCommandError {
            return MeetingResponseError.runtimeUnavailable
        }
        return MeetingResponseError.runtimeUnavailable
    }
}
