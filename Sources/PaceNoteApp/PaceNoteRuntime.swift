import AppKit
import CryptoKit
import Foundation
import PaceNoteCore

actor PaceNoteRuntime {
    private struct RepositoryInspectionContext: Sendable {
        let selectedURL: URL
        let inspection: GroundingInspection
        let softFindingsByID: [String: SoftSuspiciousFinding]
    }

    private struct PendingMeetingContext: Sendable {
        let meetingID: UUID
        let privateRoot: URL
        let groundingManager: GroundingManager?
        let snapshot: GroundingSnapshot?
    }

    private struct ActiveMeetingContext: Sendable {
        let meetingID: UUID
        let privateRoot: URL
        let controller: MeetingSessionController
        let eventTask: Task<Void, Never>
    }

    private struct VerifiedMeetingSubscription: Sendable {
        let planType: String?
        let identityHash: String
    }

    private let fileManager: FileManager
    private let applicationRoot: URL
    private let meetingsRoot: URL
    private let codexProfileRoot: URL
    private let journal: CleanupJournalStore
    private let codexExecutableURL: URL
    private let microphonePermission = SystemMicrophonePermissionProvider()
    private let systemAudioPermission = SystemAudioPermissionProbe()
    private let sourceDiscovery = SystemAudioSourceDiscovery()

    private var outputSourcesByID: [String: SystemAudioSource] = [:]
    private var repositoryInspection: RepositoryInspectionContext?
    private var pendingMeeting: PendingMeetingContext?
    private var activeMeeting: ActiveMeetingContext?
    private var eventContinuations: [UUID: AsyncStream<MeetingSessionEvent>.Continuation] = [:]
    private var startupCleanupAttempted = false
    private var startupCleanupHealthy = false

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        guard
            let supportRoot = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw PaceNoteActionError.safeMessage("PaceNote could not open its private application data directory.")
        }

        let applicationRoot =
            supportRoot
            .appendingPathComponent("PaceNote", isDirectory: true)
            .standardizedFileURL
        let meetingsRoot = applicationRoot.appendingPathComponent("Meetings", isDirectory: true)
        let profilesRoot = applicationRoot.appendingPathComponent("Profiles", isDirectory: true)
        let codexProfileRoot = profilesRoot.appendingPathComponent("personal", isDirectory: true)
        let stateRoot = applicationRoot.appendingPathComponent("State", isDirectory: true)

        for directory in [applicationRoot, meetingsRoot, profilesRoot, codexProfileRoot, stateRoot] {
            try Self.createPrivateDirectory(directory, fileManager: fileManager)
        }

        self.applicationRoot = applicationRoot
        self.meetingsRoot = meetingsRoot
        self.codexProfileRoot = codexProfileRoot
        self.journal = try CleanupJournalStore(
            journalURL: stateRoot.appendingPathComponent("cleanup-journal.json"),
            allowedRoot: applicationRoot
        )
        self.codexExecutableURL = Self.locateCodexExecutable(fileManager: fileManager)
    }

    func events() -> AsyncStream<MeetingSessionEvent> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: MeetingSessionEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    func checkEnvironment() async -> PaceNoteEnvironmentSnapshot {
        let cleanupIsHealthy = await ensureStartupCleanup()
        let microphone = await microphonePermission.status()
        let systemAudio = await systemAudioPermission.status()
        let sources = await reloadOutputSources()
        let codex: CodexConnectionState
        if cleanupIsHealthy {
            codex = await subscriptionState()
        } else {
            codex = .limited(
                "PaceNote could not finish cleanup from an earlier session. Capture remains blocked."
            )
        }
        return PaceNoteEnvironmentSnapshot(
            microphonePermission: Self.capturePermissionState(microphone),
            systemAudioPermission: Self.capturePermissionState(systemAudio),
            codex: codex,
            outputSources: sources
        )
    }

    func requestCapturePermission(_ kind: CapturePermissionKind) async -> CapturePermissionState {
        switch kind {
        case .microphone:
            return Self.capturePermissionState(await microphonePermission.request())
        case .systemAudio:
            do {
                return Self.capturePermissionState(try await systemAudioPermission.request())
            } catch {
                return .unavailable("macOS could not complete the system audio permission check.")
            }
        }
    }

    func beginCodexSignIn() async -> CodexConnectionState {
        guard await ensureStartupCleanup() else {
            return .limited(
                "PaceNote must finish cleanup from an earlier session before signing in."
            )
        }
        let client: CodexAppServerClient
        do {
            client = try await connectCodexClient()
        } catch {
            return .unavailable(Self.safeMessage(for: error))
        }

        do {
            let existing = try await client.account(refreshToken: true)
            if let account = existing.account {
                let state = await validatedSubscriptionState(account: account, client: client)
                await client.shutdown()
                return state
            }

            let login = try await client.startChatGPTLogin(useHostedLoginSuccessPage: true)
            guard let url = URL(string: login.authUrl),
                CodexChatGPTLoginURLPolicy.permits(url),
                await MainActor.run(body: { NSWorkspace.shared.open(url) })
            else {
                await client.shutdown()
                return .unavailable("PaceNote could not open the secure ChatGPT sign-in page.")
            }

            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(1))
                let accountResult = try await client.account(refreshToken: true)
                if let account = accountResult.account {
                    let state = await validatedSubscriptionState(account: account, client: client)
                    await client.shutdown()
                    return state
                }
            }
            await client.shutdown()
            return .authenticationExpired(
                "Sign-in was not completed. Use Sign in again when the browser flow is ready."
            )
        } catch is CancellationError {
            await client.shutdown()
            return .signedOut
        } catch {
            await client.shutdown()
            return .unavailable(Self.safeMessage(for: error))
        }
    }

    func forgetCodexProfile() async throws {
        guard activeMeeting == nil else {
            throw PaceNoteActionError.safeMessage("Stop the current meeting before forgetting the Codex profile.")
        }
        guard (try? await journal.entries().isEmpty) == true else {
            throw PaceNoteActionError.safeMessage(
                "PaceNote must finish pending private-data cleanup before forgetting this profile."
            )
        }

        do {
            try await CodexProfileForgetter(
                applicationRoot: applicationRoot,
                profileRoot: codexProfileRoot,
                fileManager: fileManager
            ).forget {
                let client = try await self.connectCodexClient()
                do {
                    try await client.logout()
                    await client.shutdown()
                } catch {
                    await client.shutdown()
                    throw error
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.accountIdentityKey)
            startupCleanupAttempted = false
            startupCleanupHealthy = false
        } catch CodexProfileForgetError.credentialStoreLogoutFailed {
            UserDefaults.standard.removeObject(forKey: Self.accountIdentityKey)
            startupCleanupAttempted = false
            startupCleanupHealthy = false
            throw PaceNoteActionError.safeMessage(
                "The local profile was erased, but OS credential-store sign-out could not be verified. Try Forget profile again."
            )
        } catch {
            throw PaceNoteActionError.safeMessage(
                "PaceNote could not safely erase and recreate the isolated Codex profile."
            )
        }
    }

    func reloadOutputSources() async -> [OutputSourceOption] {
        do {
            let sources = try await sourceDiscovery.sources()
            outputSourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
            return sources.map {
                OutputSourceOption(
                    id: $0.id,
                    name: $0.name,
                    detail: $0.bundleID
                )
            }
        } catch {
            outputSourcesByID = [:]
            return []
        }
    }

    func inspectRepository(_ selectedURL: URL) async throws -> GroundingReviewSummary {
        guard activeMeeting == nil else {
            throw PaceNoteActionError.safeMessage("Stop the current meeting before changing repository access.")
        }
        let manager = GroundingManager()
        let inspection = try await manager.inspectRepository(at: selectedURL)
        let softByID = Dictionary(
            uniqueKeysWithValues: inspection.softFindings.map {
                (Self.softFindingID($0), $0)
            })
        repositoryInspection = RepositoryInspectionContext(
            selectedURL: selectedURL.standardizedFileURL,
            inspection: inspection,
            softFindingsByID: softByID
        )

        return GroundingReviewSummary(
            repositoryAlias: selectedURL.lastPathComponent,
            branch: inspection.branch,
            revision: String(inspection.head.prefix(12)),
            includedFileCount: inspection.manifest.entries.count,
            hardExclusions: inspection.hardExclusions.map {
                GroundingReviewFinding(
                    id: Self.hardFindingID($0),
                    relativePath: $0.relativePath,
                    detail: "Always excluded: \($0.reason.rawValue)."
                )
            },
            softFindings: inspection.softFindings.map {
                GroundingReviewFinding(
                    id: Self.softFindingID($0),
                    relativePath: $0.relativePath,
                    detail: "Requires explicit approval: \($0.ruleIDs.joined(separator: ", "))."
                )
            },
            instructionFiles: inspection.instructionSources.map(\.relativePath)
        )
    }

    func sealRepository(_ request: RepositorySealRequest) async throws -> SealedRepositorySummary {
        guard activeMeeting == nil, let inspected = repositoryInspection else {
            throw PaceNoteActionError.safeMessage("Inspect the repository again before sealing it.")
        }
        guard request.repositoryURL.standardizedFileURL == inspected.selectedURL else {
            throw PaceNoteActionError.safeMessage("The selected repository changed before review completed.")
        }
        let requiredApprovals = Set(inspected.softFindingsByID.keys)
        guard request.approvedSoftFindingIDs == requiredApprovals else {
            throw PaceNoteActionError.safeMessage(
                "Review every suspicious file before it can enter the sealed snapshot."
            )
        }

        if let pendingMeeting {
            try await discardPendingMeeting(pendingMeeting)
        }

        let meetingID = UUID()
        let privateRoot = try createMeetingRoot(meetingID: meetingID)
        let groundingRoot = privateRoot.appendingPathComponent("Grounding", isDirectory: true)
        let manager = GroundingManager(
            configuration: GroundingConfiguration(snapshotParentDirectory: groundingRoot)
        )
        let approvals = Set(inspected.softFindingsByID.values.map(SoftSuspiciousApproval.init(approving:)))

        do {
            try await journal.begin(
                CleanupJournalEntry(
                    meetingID: meetingID,
                    profileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID,
                    privateRoot: privateRoot,
                    snapshotRoots: [groundingRoot]
                )
            )
            let snapshot = try await manager.createSnapshot(
                repoAlias: request.repositoryURL.lastPathComponent,
                sourceRoot: request.repositoryURL,
                approvals: approvals
            )
            try await journal.recordSnapshot(snapshot.snapshotRoot, meetingID: meetingID)
            let domainSkills = try Self.domainSkills(in: snapshot)
            pendingMeeting = PendingMeetingContext(
                meetingID: meetingID,
                privateRoot: privateRoot,
                groundingManager: manager,
                snapshot: snapshot
            )
            repositoryInspection = nil
            return SealedRepositorySummary(
                snapshotID: snapshot.id,
                repositoryAlias: snapshot.repoAlias,
                branch: snapshot.inspection.branch,
                revision: String(snapshot.inspection.head.prefix(12)),
                includedFileCount: snapshot.manifest.entries.count,
                instructionFileCount: snapshot.inspection.instructionSources.count,
                domainSkills: domainSkills
            )
        } catch {
            do {
                if fileManager.fileExists(atPath: privateRoot.path) {
                    try fileManager.removeItem(at: privateRoot)
                }
                try await journal.remove(meetingID: meetingID)
            } catch {
                // Keep the journal entry when removal cannot be verified. Startup recovery owns it.
            }
            throw error
        }
    }

    func discardRepositorySnapshot(_ snapshotID: UUID) async throws {
        guard let pendingMeeting, pendingMeeting.snapshot?.id == snapshotID else { return }
        try await discardPendingMeeting(pendingMeeting)
        repositoryInspection = nil
    }

    func startMeeting(_ request: MeetingStartRequest) async throws {
        guard activeMeeting == nil else {
            throw PaceNoteActionError.safeMessage("A meeting is already active.")
        }
        guard request.consentConfirmed else {
            throw PaceNoteActionError.safeMessage(
                "Confirm participant permission, capture scope, and OpenAI processing before capture starts."
            )
        }
        guard await ensureStartupCleanup() else {
            throw PaceNoteActionError.safeMessage(
                "PaceNote must finish cleanup from an earlier session before capture can start."
            )
        }
        let verifiedSubscription = try await verifiedMeetingSubscription()

        let context: PendingMeetingContext
        if let snapshotID = request.sealedSnapshotID {
            guard let pendingMeeting, pendingMeeting.snapshot?.id == snapshotID else {
                throw PaceNoteActionError.safeMessage("The reviewed repository snapshot is no longer available.")
            }
            context = pendingMeeting
        } else {
            if let pendingMeeting { try await discardPendingMeeting(pendingMeeting) }
            let meetingID = UUID()
            let privateRoot = try createMeetingRoot(meetingID: meetingID)
            do {
                try await journal.begin(
                    CleanupJournalEntry(
                        meetingID: meetingID,
                        profileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID,
                        privateRoot: privateRoot
                    )
                )
            } catch {
                try? fileManager.removeItem(at: privateRoot)
                throw PaceNoteActionError.safeMessage(
                    "PaceNote could not create its private cleanup journal."
                )
            }
            context = PendingMeetingContext(
                meetingID: meetingID,
                privateRoot: privateRoot,
                groundingManager: nil,
                snapshot: nil
            )
        }
        pendingMeeting = nil

        let captureMode = Self.captureMode(for: request)
        let speechAssets = AppleSpeechAssetManager()
        let audioServices = try makeAudioServices(
            request: request,
            captureMode: captureMode,
            speechAssets: speechAssets
        )
        let groundingIdentity = context.snapshot.map {
            MeetingGroundingIdentity(
                repoAlias: $0.repoAlias,
                fingerprint: $0.groundingFingerprint
            )
        }
        let availableDomainSkillNames = Set(try Self.domainSkills(in: context.snapshot).map(\.name))
        if let selected = request.selectedDomainSkillName,
            !availableDomainSkillNames.contains(selected)
        {
            throw PaceNoteActionError.safeMessage(
                "The selected repository skill is not present in the sealed snapshot."
            )
        }
        let responseGenerator = CodexMeetingResponseGenerator(
            configuration: MeetingResponseConfiguration(
                meetingID: context.meetingID,
                meetingPrivateRoot: context.privateRoot,
                codexProfileRoot: codexProfileRoot,
                executableURL: codexExecutableURL,
                clientVersion: Self.applicationVersion,
                subscriptionPlanType: verifiedSubscription.planType,
                expectedAccountIdentityHash: verifiedSubscription.identityHash,
                speakingStyle: Self.speakingStyle,
                groundingSnapshot: context.snapshot,
                selectedDomainSkillName: request.selectedDomainSkillName,
                deepComplexity: .hardTechnical
            ),
            journal: journal
        )
        let cleaner = DefaultMeetingSessionResourceCleaner(
            privateRoot: context.privateRoot,
            temporaryRoots: [
                context.privateRoot.appendingPathComponent("Grounding", isDirectory: true),
                context.privateRoot.appendingPathComponent("quick-context", isDirectory: true),
                context.privateRoot.appendingPathComponent("codex-tmp", isDirectory: true),
                context.privateRoot.appendingPathComponent("skill-context", isDirectory: true),
            ],
            groundingManager: context.groundingManager,
            groundingSnapshot: context.snapshot,
            journal: journal,
            applicationRoot: applicationRoot,
            stableCodexProfileRoot: codexProfileRoot
        )
        let controller = MeetingSessionController(
            configuration: MeetingSessionConfiguration(
                meetingID: context.meetingID,
                captureMode: captureMode,
                grounding: groundingIdentity,
                microphoneAttributionDelay: .milliseconds(800)
            ),
            audioServices: audioServices,
            speechAssets: speechAssets,
            microphonePermission: microphonePermission,
            responseGenerator: responseGenerator,
            responseCoordinatorConfiguration: ResponseCoordinatorConfiguration(
                quickDeadline: .milliseconds(1_250),
                resultTTL: .seconds(30),
                bridgeText: "Let me dig into the exact implementation for a second."
            ),
            resourceCleaner: cleaner
        )
        let sessionEvents = await controller.events()
        let eventTask = Task { [weak self] in
            for await event in sessionEvents {
                guard !Task.isCancelled else { return }
                await self?.emit(event)
            }
        }
        activeMeeting = ActiveMeetingContext(
            meetingID: context.meetingID,
            privateRoot: context.privateRoot,
            controller: controller,
            eventTask: eventTask
        )

        do {
            _ = try await controller.preflight(
                consent: PaceNoteCore.MeetingConsent(
                    participantDisclosureConfirmed: request.consentConfirmed
                )
            )
            try await controller.start()
        } catch {
            let report = await controller.stop()
            eventTask.cancel()
            activeMeeting = nil
            if report.cleanupSucceeded {
                do {
                    if fileManager.fileExists(atPath: context.privateRoot.path) {
                        try fileManager.removeItem(at: context.privateRoot)
                    }
                } catch {
                    startupCleanupHealthy = false
                }
            } else {
                startupCleanupHealthy = false
            }
            throw error
        }
    }

    func pauseMeeting() async throws {
        guard let activeMeeting else { throw MeetingSessionFailure.invalidLifecycle }
        try await activeMeeting.controller.pause()
    }

    func resumeMeeting() async throws {
        guard let activeMeeting else { throw MeetingSessionFailure.invalidLifecycle }
        try await activeMeeting.controller.resume()
    }

    func coachCurrentTurn(_ question: String?) async throws {
        guard let activeMeeting else { throw MeetingSessionFailure.invalidLifecycle }
        if let question {
            try await activeMeeting.controller.submitTypedQuestion(question)
        } else {
            try await activeMeeting.controller.coachCurrentTurn()
        }
    }

    func stopMeeting() async throws {
        guard let activeMeeting else { return }
        let report = await activeMeeting.controller.stop()
        activeMeeting.eventTask.cancel()
        self.activeMeeting = nil
        guard report.cleanupSucceeded else {
            startupCleanupHealthy = false
            throw PaceNoteActionError.safeMessage(
                "Some private meeting resources could not be verified as deleted. They remain journaled for cleanup on the next launch."
            )
        }
        do {
            if fileManager.fileExists(atPath: activeMeeting.privateRoot.path) {
                try fileManager.removeItem(at: activeMeeting.privateRoot)
            }
        } catch {
            startupCleanupHealthy = false
            throw PaceNoteActionError.safeMessage(
                "The meeting was cleared, but its empty private directory could not be removed."
            )
        }
    }

    func shutdown() async {
        if activeMeeting != nil {
            try? await stopMeeting()
        }
        if let pendingMeeting {
            try? await discardPendingMeeting(pendingMeeting)
        }
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    private func makeAudioServices(
        request: MeetingStartRequest,
        captureMode: MeetingCaptureMode,
        speechAssets: AppleSpeechAssetManager
    ) throws -> MeetingAudioServices {
        let microphone: MeetingAudioLaneServices?
        if captureMode.capturesMicrophone {
            microphone = MeetingAudioLaneServices(
                lane: .microphone,
                capture: MicrophoneCaptureService(permissionProvider: microphonePermission),
                transcriber: AppleSpeechTranscriptionService(
                    lane: .microphone,
                    assets: speechAssets
                )
            )
        } else {
            microphone = nil
        }

        let output: MeetingAudioLaneServices?
        if captureMode.capturesSystemOutput {
            let selection: SystemAudioSelection
            switch request.outputScope {
            case .meetingApplication:
                guard let sourceID = request.outputSourceID,
                    let source = outputSourcesByID[sourceID]
                else {
                    throw PaceNoteActionError.safeMessage(
                        "The selected meeting application is no longer available. Reload the app list."
                    )
                }
                selection = .selected([source.captureTarget])
            case .allSystemAudio:
                selection = .global(excluding: [])
            }
            output = MeetingAudioLaneServices(
                lane: .output,
                capture: SystemAudioCaptureService(selection: selection),
                transcriber: AppleSpeechTranscriptionService(lane: .output, assets: speechAssets)
            )
        } else {
            output = nil
        }
        return MeetingAudioServices(microphone: microphone, systemOutput: output)
    }

    private func subscriptionState() async -> CodexConnectionState {
        let client: CodexAppServerClient
        do {
            client = try await connectCodexClient()
        } catch {
            return .unavailable(Self.safeMessage(for: error))
        }
        do {
            let result = try await client.account(refreshToken: false)
            guard let account = result.account else {
                await client.shutdown()
                return .signedOut
            }
            let state = await validatedSubscriptionState(account: account, client: client)
            await client.shutdown()
            return state
        } catch {
            await client.shutdown()
            return .unavailable(Self.safeMessage(for: error))
        }
    }

    private func verifiedMeetingSubscription() async throws -> VerifiedMeetingSubscription {
        let client: CodexAppServerClient
        do {
            client = try await connectCodexClient()
        } catch {
            throw PaceNoteActionError.safeMessage(Self.safeMessage(for: error))
        }

        do {
            let result = try await client.account(refreshToken: false)
            guard let account = result.account,
                account.type == "chatgpt",
                let email = Self.normalizedEmail(account.email)
            else {
                await client.shutdown()
                throw PaceNoteActionError.safeMessage(
                    "Sign in to ChatGPT before starting a meeting."
                )
            }
            let identityHash = Self.identityHash(email)
            if let expected = UserDefaults.standard.string(forKey: Self.accountIdentityKey),
                expected != identityHash
            {
                await client.shutdown()
                throw PaceNoteActionError.safeMessage(
                    "A different ChatGPT account is signed in. Forget the PaceNote profile before switching accounts."
                )
            }
            UserDefaults.standard.set(identityHash, forKey: Self.accountIdentityKey)
            await client.shutdown()
            return VerifiedMeetingSubscription(
                planType: account.planType,
                identityHash: identityHash
            )
        } catch let error as PaceNoteActionError {
            throw error
        } catch {
            await client.shutdown()
            throw PaceNoteActionError.safeMessage(Self.safeMessage(for: error))
        }
    }

    private func validatedSubscriptionState(
        account: CodexAccount,
        client: CodexAppServerClient
    ) async -> CodexConnectionState {
        guard account.type == "chatgpt",
            let email = Self.normalizedEmail(account.email)
        else {
            return .unavailable("PaceNote requires a ChatGPT-authenticated Codex account.")
        }
        let identityHash = Self.identityHash(email)
        if let expected = UserDefaults.standard.string(forKey: Self.accountIdentityKey),
            expected != identityHash
        {
            return .authenticationExpired(
                "A different ChatGPT account is signed in. Forget the PaceNote profile before switching accounts."
            )
        }
        UserDefaults.standard.set(identityHash, forKey: Self.accountIdentityKey)

        do {
            let models = try await client.listModels(includeHidden: false)
            return .ready(
                CodexAccountSummary(
                    accountLabel: Self.redactedEmail(email),
                    planLabel: Self.planLabel(account.planType),
                    modelCount: models.count
                )
            )
        } catch {
            return .limited("The ChatGPT account is connected, but Codex model access is unavailable.")
        }
    }

    private func connectCodexClient() async throws -> CodexAppServerClient {
        guard fileManager.isExecutableFile(atPath: codexExecutableURL.path) else {
            throw CodexClientError.binaryUnavailable
        }
        let isolated = try CodexIsolatedRuntimeBuilder.prepare(
            profileRoot: codexProfileRoot,
            codexExecutableURL: codexExecutableURL,
            fileManager: fileManager
        )
        return try await CodexAppServerClient.connect(
            configuration: CodexAppServerConfiguration(
                executableURL: codexExecutableURL,
                clientVersion: Self.applicationVersion,
                permissionProfileID: isolated.permissionProfileID,
                processArguments: isolated.processArguments,
                processEnvironment: isolated.processEnvironment
            )
        )
    }

    private func ensureStartupCleanup() async -> Bool {
        if startupCleanupAttempted, startupCleanupHealthy { return true }
        startupCleanupAttempted = true

        let entries: [CleanupJournalEntry]
        do {
            entries = try await journal.entries()
        } catch {
            startupCleanupHealthy = false
            return false
        }
        guard !entries.isEmpty else {
            do {
                _ = try CodexStableProfileSanitizer(fileManager: fileManager)
                    .cleanTransientState(profileRoot: codexProfileRoot)
                startupCleanupHealthy = true
                return true
            } catch {
                startupCleanupHealthy = false
                return false
            }
        }

        let janitor = CleanupJanitor(journal: journal)
        var report = CleanupReport()
        for entry in entries {
            let entryReport: CleanupReport
            if entry.requiresCodexCleanup {
                let connected: CodexAppServerClient
                do {
                    connected = try await connectCodexClient()
                } catch {
                    report.failures.append(
                        CleanupFailure(
                            resource: "codex-runtime",
                            reason: Self.safeMessage(for: error)
                        )
                    )
                    continue
                }
                entryReport = await janitor.run(
                    client: AppServerJanitorClient(client: connected),
                    meetingID: entry.meetingID,
                    clearJournalOnSuccess: false
                )
                await connected.shutdown()
            } else {
                entryReport = await janitor.run(
                    client: SnapshotOnlyJanitorClient(),
                    meetingID: entry.meetingID,
                    clearJournalOnSuccess: false
                )
            }
            report.deletedThreadCount += entryReport.deletedThreadCount
            report.deletedSnapshotCount += entryReport.deletedSnapshotCount
            report.failures.append(contentsOf: entryReport.failures)
        }

        if report.failures.isEmpty {
            do {
                _ = try CodexStableProfileSanitizer(fileManager: fileManager)
                    .cleanTransientState(profileRoot: codexProfileRoot)
            } catch {
                report.failures.append(
                    CleanupFailure(
                        resource: "codex-profile",
                        reason: "Stable Codex transient-state cleanup was not verified."
                    )
                )
            }
        }

        if report.failures.isEmpty {
            for entry in entries {
                do {
                    guard Self.isStrictlyContained(entry.privateRoot, inside: meetingsRoot) else {
                        throw CleanupJournalError.pathOutsidePrivateRoot
                    }
                    if fileManager.fileExists(atPath: entry.privateRoot.path) {
                        try fileManager.removeItem(at: entry.privateRoot)
                    }
                    try await journal.remove(meetingID: entry.meetingID)
                } catch {
                    report.failures.append(
                        CleanupFailure(
                            resource: "meeting-root",
                            reason: "Meeting root deletion was not verified before journal removal."
                        )
                    )
                }
            }
        }
        startupCleanupHealthy = report.failures.isEmpty
        return startupCleanupHealthy
    }

    private func discardPendingMeeting(_ context: PendingMeetingContext) async throws {
        if let snapshot = context.snapshot, let manager = context.groundingManager {
            if fileManager.fileExists(atPath: snapshot.snapshotRoot.path) {
                do {
                    try await manager.deleteSnapshot(snapshot)
                } catch {
                    throw PaceNoteActionError.safeMessage(
                        "The private repository snapshot could not be deleted. It remains journaled for recovery."
                    )
                }
            }
        }
        do {
            if fileManager.fileExists(atPath: context.privateRoot.path) {
                try fileManager.removeItem(at: context.privateRoot)
            }
            try await journal.remove(meetingID: context.meetingID)
        } catch {
            throw PaceNoteActionError.safeMessage(
                "The private repository snapshot cleanup could not be verified. It remains blocked for recovery."
            )
        }
        if pendingMeeting?.meetingID == context.meetingID { pendingMeeting = nil }
    }

    private func createMeetingRoot(meetingID: UUID) throws -> URL {
        let root = meetingsRoot.appendingPathComponent(
            meetingID.uuidString.lowercased(),
            isDirectory: true
        )
        guard Self.isStrictlyContained(root, inside: meetingsRoot) else {
            throw PaceNoteActionError.safeMessage("PaceNote rejected an unsafe meeting data path.")
        }
        try Self.createPrivateDirectory(root, fileManager: fileManager)
        return root
    }

    private func emit(_ event: MeetingSessionEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private static func captureMode(for request: MeetingStartRequest) -> MeetingCaptureMode {
        switch (request.microphoneEnabled, request.outputEnabled) {
        case (false, false): .manualOnly
        case (true, false): .microphoneOnly
        case (false, true): .systemOutputOnly
        case (true, true): .microphoneAndSystemOutput
        }
    }

    private static func capturePermissionState(_ status: AudioPermissionStatus) -> CapturePermissionState {
        switch status {
        case .notDetermined: .notChecked
        case .denied: .denied
        case .granted: .authorized
        }
    }

    private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
            else {
                throw PaceNoteActionError.safeMessage("PaceNote rejected an unsafe private data directory.")
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func locateCodexExecutable(fileManager: FileManager) -> URL {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return
            candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
            ?? URL(fileURLWithPath: candidates[0])
    }

    private static func softFindingID(_ finding: SoftSuspiciousFinding) -> String {
        stableID(
            prefix: "soft",
            value: [finding.relativePath, finding.contentHash] + finding.ruleIDs
        )
    }

    private static func hardFindingID(_ finding: HardExcludedPath) -> String {
        stableID(prefix: "hard", value: [finding.relativePath, finding.reason.rawValue])
    }

    static func domainSkills(in snapshot: GroundingSnapshot?) throws -> [DomainSkillOption] {
        guard let snapshot else { return [] }
        var names: Set<String> = []
        for entry in snapshot.manifest.entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard components.count == 4,
                components[0] == ".agents",
                components[1] == "skills",
                components[3] == "SKILL.md"
            else {
                continue
            }
            let skillURL = snapshot.snapshotRoot.appendingPathComponent(entry.relativePath)
            let data = try Data(contentsOf: skillURL, options: .mappedIfSafe)
            guard data.count <= 262_144,
                let text = String(data: data, encoding: .utf8),
                let name = skillFrontmatterName(text),
                name.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
            else {
                continue
            }
            names.insert(name)
        }
        return names.sorted().map(DomainSkillOption.init(name:))
    }

    static func skillFrontmatterName(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }
        for line in lines.dropFirst() {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized == "---" { return nil }
            guard normalized.hasPrefix("name:") else { continue }
            let raw = normalized.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func stableID(prefix: String, value: [String]) -> String {
        let digest = SHA256.hash(data: Data(value.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), normalized.utf8.count <= 320 else { return nil }
        return normalized
    }

    private static func identityHash(_ email: String) -> String {
        SHA256.hash(data: Data("chatgpt-email:\(email)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func redactedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else { return "ChatGPT account" }
        return "\(first)•••@\(parts[1])"
    }

    private static func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "ChatGPT subscription" }
        return "ChatGPT \(plan.prefix(1).uppercased())\(plan.dropFirst())"
    }

    fileprivate static func safeMessage(for error: any Error) -> String {
        if let error = error as? CodexClientError, let message = error.errorDescription {
            return message
        }
        if let error = error as? MeetingSessionFailure, let message = error.errorDescription {
            return message
        }
        if let error = error as? GroundingError, let message = error.errorDescription {
            return message
        }
        return "The local PaceNote service could not complete this operation."
    }

    private static func isStrictlyContained(_ child: URL, inside root: URL) -> Bool {
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return childPath.hasPrefix(rootPath + "/")
    }

    private static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static var speakingStyle: String {
        switch UserDefaults.standard.string(forKey: "paceNote.speakingStyle") {
        case "Calm": "calm, reassuring, and conversational"
        case "Technical": "precise, technical, and conversational"
        default: "direct, concise, and conversational"
        }
    }

    private static let accountIdentityKey = "paceNote.codexAccountIdentityHash"
}

private struct SnapshotOnlyJanitorClient: ThreadCleanupClient {
    func deleteThread(id: String) async throws {
        throw CodexClientError.transportUnavailable
    }

    func threadIDs(cwd: URL) async throws -> [String] { [] }
}

private actor AppServerJanitorClient: ThreadCleanupClient {
    let client: CodexAppServerClient

    init(client: CodexAppServerClient) {
        self.client = client
    }

    func deleteThread(id: String) async throws {
        try await client.deleteThread(id: id)
    }

    func threadIDs(cwd: URL) async throws -> [String] {
        try await client.listThreadIDs(cwd: cwd.path)
    }
}

extension MeetingActions {
    static func live(runtime: PaceNoteRuntime) -> MeetingActions {
        MeetingActions(
            sessionEvents: { await runtime.events() },
            checkEnvironment: { await runtime.checkEnvironment() },
            requestCapturePermission: { await runtime.requestCapturePermission($0) },
            beginCodexSignIn: { await runtime.beginCodexSignIn() },
            forgetCodexProfile: {
                do {
                    try await runtime.forgetCodexProfile()
                } catch let error as PaceNoteActionError {
                    throw error
                } catch {
                    throw PaceNoteActionError.safeMessage(
                        "PaceNote could not forget the isolated Codex profile."
                    )
                }
            },
            reloadOutputSources: { await runtime.reloadOutputSources() },
            inspectRepository: {
                do { return try await runtime.inspectRepository($0) } catch let error as PaceNoteActionError {
                    throw error
                } catch let error as GroundingError { throw error } catch {
                    throw PaceNoteActionError.safeMessage("The repository could not be inspected safely.")
                }
            },
            sealRepository: {
                do { return try await runtime.sealRepository($0) } catch let error as PaceNoteActionError {
                    throw error
                } catch let error as GroundingError { throw error } catch {
                    throw PaceNoteActionError.safeMessage("The repository snapshot could not be sealed safely.")
                }
            },
            discardRepositorySnapshot: {
                do { try await runtime.discardRepositorySnapshot($0) } catch let error as PaceNoteActionError {
                    throw error
                } catch {
                    throw PaceNoteActionError.safeMessage(
                        "The private repository snapshot could not be deleted."
                    )
                }
            },
            startMeeting: {
                do { try await runtime.startMeeting($0) } catch let error as PaceNoteActionError { throw error } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            },
            pauseMeeting: {
                do { try await runtime.pauseMeeting() } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            },
            resumeMeeting: {
                do { try await runtime.resumeMeeting() } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            },
            stopMeeting: {
                do { try await runtime.stopMeeting() } catch let error as PaceNoteActionError { throw error } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            },
            coachCurrentTurn: {
                do { try await runtime.coachCurrentTurn($0) } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            }
        )
    }
}
