import AppKit
import CryptoKit
import Foundation
import PaceNoteCore

struct RuntimeOutputSourceGroup: Sendable {
    let option: OutputSourceOption
    let sources: [SystemAudioSource]
}

actor PaceNoteRuntime {
    enum CodexLoginCompletion: Equatable, Sendable {
        case succeeded
        case failed
        case timedOut
    }

    private enum Lifecycle: Sendable {
        case open
        case closing
        case closed
    }

    private struct StartOperation: Sendable {
        let attemptID: UUID
        let task: Task<Void, any Error>
    }

    private struct ProviderOperation: Sendable {
        let id: UUID
        let cancel: @Sendable () -> Void
        let waitForCompletion: @Sendable () async -> Void
    }

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
        let identityHash: String?
    }

    private let fileManager: FileManager
    private let applicationRoot: URL
    private let meetingsRoot: URL
    private let codexProfileRoot: URL
    private let geminiProfileRoot: URL
    private let codexProfileLease: CodexProfileLease
    private let journal: CleanupJournalStore
    private let codexExecutableURL: URL
    private let microphonePermission = SystemMicrophonePermissionProvider()
    private let systemAudioPermission = SystemAudioPermissionProbe()
    private let sourceDiscovery = SystemAudioSourceDiscovery()
    private let preverifiedSubscription: VerifiedMeetingSubscription?
    private let startSuspensionBarrier: (@Sendable () async -> Void)?
    private let providerOperationSuspensionBarrier: (@Sendable () async -> Void)?

    private var outputSourcesByID: [String: [SystemAudioSource]] = [:]
    private var repositoryInspection: RepositoryInspectionContext?
    private var pendingMeeting: PendingMeetingContext?
    private var pendingMeetingCleanupBlocked = false
    private var activeMeeting: ActiveMeetingContext?
    private var eventContinuations: [UUID: AsyncStream<MeetingSessionEvent>.Continuation] = [:]
    private var startupCleanupAttempted = false
    private var startupCleanupHealthy = false
    private var lifecycle = Lifecycle.open
    private var startOperation: StartOperation?
    private var providerOperation: ProviderOperation?
    private var shutdownTask: Task<Bool, Never>?

    init(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil,
        preverifiedSubscription: (planType: String?, identityHash: String)? = nil,
        startSuspensionBarrier: (@Sendable () async -> Void)? = nil,
        providerOperationSuspensionBarrier: (@Sendable () async -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        self.startSuspensionBarrier = startSuspensionBarrier
        self.providerOperationSuspensionBarrier = providerOperationSuspensionBarrier
        self.preverifiedSubscription = preverifiedSubscription.map {
            VerifiedMeetingSubscription(planType: $0.planType, identityHash: $0.identityHash)
        }

        let supportRoot: URL
        if let applicationSupportRoot {
            supportRoot = applicationSupportRoot.standardizedFileURL
        } else if let defaultSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            supportRoot = defaultSupportRoot
        } else {
            throw PaceNoteActionError.safeMessage(
                "\(AppBrand.displayName) could not open its private application data directory."
            )
        }

        let applicationRoot =
            supportRoot
            .appendingPathComponent("PaceNote", isDirectory: true)
            .standardizedFileURL
        let meetingsRoot = applicationRoot.appendingPathComponent("Meetings", isDirectory: true)
        let profilesRoot = applicationRoot.appendingPathComponent("Profiles", isDirectory: true)
        let codexProfileRoot = profilesRoot.appendingPathComponent("personal", isDirectory: true)
        let geminiProfileRoot = profilesRoot.appendingPathComponent("gemini-personal", isDirectory: true)
        let stateRoot = applicationRoot.appendingPathComponent("State", isDirectory: true)

        for directory in [
            applicationRoot, meetingsRoot, profilesRoot, codexProfileRoot, geminiProfileRoot,
            stateRoot,
        ] {
            try Self.createPrivateDirectory(directory, fileManager: fileManager)
        }

        self.applicationRoot = applicationRoot
        self.meetingsRoot = meetingsRoot
        self.codexProfileRoot = codexProfileRoot
        self.geminiProfileRoot = geminiProfileRoot
        do {
            self.codexProfileLease = try CodexProfileLease.acquire(
                profileRoot: codexProfileRoot
            )
        } catch let error as CodexProfileLeaseError {
            throw PaceNoteActionError.safeMessage(
                error.errorDescription
                    ?? "\(AppBrand.displayName) could not acquire its dedicated Codex profile."
            )
        }
        self.journal = try CleanupJournalStore(
            journalURL: stateRoot.appendingPathComponent("cleanup-journal.json"),
            allowedRoot: meetingsRoot,
            requireDirectMeetingRoot: true
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
        if let reason = providerOperationBlockReason(
            action: "rechecking provider accounts"
        ) {
            return Self.blockedEnvironmentSnapshot(reason: reason)
        }

        let operationID = UUID()
        let task = Task { [self] in
            if let providerOperationSuspensionBarrier {
                await providerOperationSuspensionBarrier()
                guard !Task.isCancelled else {
                    return Self.blockedEnvironmentSnapshot(
                        reason: "The provider account recheck was canceled."
                    )
                }
            }
            return await performEnvironmentCheck()
        }
        providerOperation = ProviderOperation(
            id: operationID,
            cancel: { task.cancel() },
            waitForCompletion: { _ = await task.result }
        )
        let snapshot = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishProviderOperation(operationID)
        return snapshot
    }

    private func performEnvironmentCheck() async -> PaceNoteEnvironmentSnapshot {
        let cleanupIsHealthy = await ensureStartupCleanup()
        let microphone = await microphonePermission.status()
        let systemAudio = await systemAudioPermission.status()
        let sources = await reloadOutputSources()
        let codex: CodexConnectionState
        let claude: InferenceConnectionState
        let gemini: InferenceConnectionState
        if cleanupIsHealthy {
            codex = await subscriptionState()
            claude = await claudeSubscriptionState()
            gemini = await geminiSubscriptionState()
        } else {
            let reason =
                "\(AppBrand.displayName) could not finish cleanup from an earlier session. Capture remains blocked."
            codex = .limited(reason)
            claude = .limited(reason)
            gemini = .limited(reason)
        }
        return PaceNoteEnvironmentSnapshot(
            microphonePermission: Self.capturePermissionState(microphone),
            systemAudioPermission: Self.capturePermissionState(systemAudio),
            codex: codex,
            outputSources: sources,
            claude: claude,
            gemini: gemini
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
        if let reason = providerOperationBlockReason(
            action: "changing the Codex account"
        ) {
            return .unavailable(reason)
        }

        let operationID = UUID()
        let task = Task { [self] in
            if let providerOperationSuspensionBarrier {
                await providerOperationSuspensionBarrier()
                guard !Task.isCancelled else { return CodexConnectionState.signedOut }
            }
            return await performCodexSignIn()
        }
        providerOperation = ProviderOperation(
            id: operationID,
            cancel: { task.cancel() },
            waitForCompletion: { _ = await task.result }
        )
        let state = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishProviderOperation(operationID)
        return state
    }

    private func performCodexSignIn() async -> CodexConnectionState {
        guard await ensureStartupCleanup() else {
            return .limited(
                "\(AppBrand.displayName) must finish cleanup from an earlier session before signing in."
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

            // Subscribe before starting OAuth so even an immediate completion is buffered.
            let loginNotifications = await client.notifications()
            let login = try await client.startChatGPTLogin(useHostedLoginSuccessPage: true)
            guard let url = URL(string: login.authUrl),
                CodexChatGPTLoginURLPolicy.permits(url),
                await MainActor.run(body: { NSWorkspace.shared.open(url) })
            else {
                try? await client.cancelChatGPTLogin(loginID: login.loginId)
                await client.shutdown()
                return .unavailable(
                    "\(AppBrand.displayName) could not open the secure ChatGPT sign-in page."
                )
            }

            let completion: CodexLoginCompletion
            do {
                completion = try await Self.waitForCodexLoginCompletion(
                    notifications: loginNotifications,
                    loginID: login.loginId,
                    timeout: .seconds(120)
                )
            } catch {
                try? await client.cancelChatGPTLogin(loginID: login.loginId)
                throw error
            }

            guard completion == .succeeded else {
                if completion == .timedOut {
                    try? await client.cancelChatGPTLogin(loginID: login.loginId)
                }
                await client.shutdown()
                return .authenticationExpired(
                    completion == .timedOut
                        ? "Sign-in timed out. Use Sign in again when the browser flow is ready."
                        : "ChatGPT did not complete sign-in. Use Sign in again to retry."
                )
            }

            let accountResult = try await client.account(refreshToken: false)
            guard let account = accountResult.account else {
                await client.shutdown()
                return .authenticationExpired(
                    "ChatGPT completed sign-in, but the account was not available. Use Sign in again to retry."
                )
            }
            let state = await validatedSubscriptionState(account: account, client: client)
            await client.shutdown()
            return state
        } catch is CancellationError {
            await client.shutdown()
            return .signedOut
        } catch {
            await client.shutdown()
            return .unavailable(Self.safeMessage(for: error))
        }
    }

    static func waitForCodexLoginCompletion(
        notifications: AsyncStream<CodexServerNotification>,
        loginID: String,
        timeout: Duration
    ) async throws -> CodexLoginCompletion {
        try await withThrowingTaskGroup(of: CodexLoginCompletion.self) { group in
            group.addTask {
                for await notification in notifications {
                    try Task.checkCancellation()
                    guard notification.method == "account/login/completed",
                        let params = notification.params?.objectValue
                    else { continue }
                    if let completedLoginID = params["loginId"]?.stringValue,
                        completedLoginID != loginID
                    {
                        continue
                    }
                    guard let succeeded = params["success"]?.boolValue else { continue }
                    return succeeded ? .succeeded : .failed
                }
                try Task.checkCancellation()
                return .failed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            guard let completion = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return completion
        }
    }

    func beginGeminiSignIn() async -> InferenceConnectionState {
        if let reason = providerOperationBlockReason(action: "changing the Google account") {
            return .unavailable(reason)
        }
        let operationID = UUID()
        let task = Task { [self] in
            if let providerOperationSuspensionBarrier {
                await providerOperationSuspensionBarrier()
                guard !Task.isCancelled else { return InferenceConnectionState.signedOut }
            }
            return await performGeminiSignIn()
        }
        providerOperation = ProviderOperation(
            id: operationID,
            cancel: { task.cancel() },
            waitForCompletion: { _ = await task.result }
        )
        let state = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishProviderOperation(operationID)
        return state
    }

    private func performGeminiSignIn() async -> InferenceConnectionState {
        guard await ensureStartupCleanup() else {
            return .limited(
                "\(AppBrand.displayName) must finish cleanup from an earlier session before signing in."
            )
        }
        do {
            try resetGeminiSignInProfile()
            let signInRoot = applicationRoot.appendingPathComponent(
                "GoogleSignIn",
                isDirectory: true
            )
            try Self.createPrivateDirectory(signInRoot, fileManager: fileManager)
            let preparationRoot = signInRoot.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            defer {
                if Self.isStrictlyContained(preparationRoot, inside: signInRoot) {
                    try? fileManager.removeItem(at: preparationRoot)
                }
            }
            let runtime = try GeminiRuntimeBuilder.prepare(
                runtimeRoot: preparationRoot,
                profileRoot: geminiProfileRoot
            )
            let version = try await GeminiBinaryInspector.inspect(
                executableURL: runtime.executableURL,
                currentDirectoryURL: runtime.workingDirectory,
                environment: runtime.processEnvironment
            )
            try GeminiVersionPolicy.tested.validate(version)
            try runtime.revalidateExecutable()
            let scriptURL = signInRoot.appendingPathComponent(
                "chirpcue-google-sign-in.command",
                isDirectory: false
            )
            let quotedExecutable = Self.shellSingleQuote(runtime.executableURL.path)
            let quotedHome = Self.shellSingleQuote(geminiProfileRoot.path)
            let quotedTemporary = Self.shellSingleQuote(signInRoot.path)
            let quotedUser = Self.shellSingleQuote(NSUserName())
            let script = """
                #!/bin/sh
                cd \(quotedTemporary) || exit 1
                exec /usr/bin/env -i HOME=\(quotedHome) USER=\(quotedUser) LOGNAME=\(quotedUser) TMPDIR=\(quotedTemporary) PATH='/usr/bin:/bin:/usr/sbin:/sbin' AGY_CLI_DISABLE_AUTO_UPDATE=true \(quotedExecutable)
                """
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            guard await MainActor.run(body: { NSWorkspace.shared.open(scriptURL) }) else {
                return .unavailable(
                    "\(AppBrand.displayName) could not open the Google sign-in terminal."
                )
            }
            return .limited(
                "Complete Google sign-in in Terminal, close that session, then choose Recheck Accounts."
            )
        } catch {
            return .unavailable(Self.safeGeminiMessage(for: error))
        }
    }

    func forgetCodexProfile() async throws {
        if let reason = providerOperationBlockReason(
            action: "forgetting the Codex profile"
        ) {
            throw PaceNoteActionError.safeMessage(reason)
        }

        let operationID = UUID()
        let task = Task { [self] in
            if let providerOperationSuspensionBarrier {
                await providerOperationSuspensionBarrier()
                try Task.checkCancellation()
            }
            try await performForgetCodexProfile()
        }
        providerOperation = ProviderOperation(
            id: operationID,
            cancel: { task.cancel() },
            waitForCompletion: { _ = await task.result }
        )
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        finishProviderOperation(operationID)
        return try result.get()
    }

    private func performForgetCodexProfile() async throws {
        guard (try? await journal.entries().isEmpty) == true else {
            throw PaceNoteActionError.safeMessage(
                "\(AppBrand.displayName) must finish pending private-data cleanup before forgetting this profile."
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
                "\(AppBrand.displayName) could not safely erase and recreate the isolated Codex profile."
            )
        }
    }

    func confirmClaudeAccountChange() async throws -> InferenceConnectionState {
        if let reason = providerOperationBlockReason(
            action: "confirming a different Claude account"
        ) {
            throw PaceNoteActionError.safeMessage(reason)
        }

        let operationID = UUID()
        let task = Task { [self] in
            if let providerOperationSuspensionBarrier {
                await providerOperationSuspensionBarrier()
                try Task.checkCancellation()
            }
            return try await performConfirmClaudeAccountChange()
        }
        providerOperation = ProviderOperation(
            id: operationID,
            cancel: { task.cancel() },
            waitForCompletion: { _ = await task.result }
        )
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        finishProviderOperation(operationID)
        return try result.get()
    }

    private func performConfirmClaudeAccountChange() async throws -> InferenceConnectionState {
        guard (try? await journal.entries().isEmpty) == true else {
            throw PaceNoteActionError.safeMessage(
                "\(AppBrand.displayName) must finish pending private-data cleanup before changing accounts."
            )
        }
        let status: ClaudeSubscriptionStatus
        do {
            status = try await checkedClaudeSubscription()
        } catch {
            throw PaceNoteActionError.safeMessage(Self.safeClaudeMessage(for: error))
        }
        UserDefaults.standard.set(status.identityHash, forKey: Self.claudeAccountIdentityKey)
        return .ready(
            InferenceAccountSummary(
                accountLabel: status.redactedLabel,
                planLabel: Self.claudePlanLabel(status.planType),
                modelCount: 1
            )
        )
    }

    func reloadOutputSources() async -> [OutputSourceOption] {
        do {
            let sources = try await sourceDiscovery.sources()
            let groups = Self.groupedOutputSources(sources)
            outputSourcesByID = Dictionary(
                uniqueKeysWithValues: groups.map { ($0.option.id, $0.sources) }
            )
            return groups.map(\.option)
        } catch {
            outputSourcesByID = [:]
            return []
        }
    }

    static func groupedOutputSources(
        _ sources: [SystemAudioSource]
    ) -> [RuntimeOutputSourceGroup] {
        var sourcesByApplication: [String: [SystemAudioSource]] = [:]
        for source in sources {
            let applicationKey =
                source.owningApplicationBundleID
                ?? source.bundleID
                ?? source.id
            sourcesByApplication[applicationKey, default: []].append(source)
        }

        return sourcesByApplication.map { applicationKey, groupedSources in
            let owningName = groupedSources.compactMap(\.owningApplicationName).first {
                !$0.isEmpty
            }
            let mainProcessName = groupedSources.first {
                $0.bundleID == applicationKey
            }?.name
            let name = owningName ?? mainProcessName ?? groupedSources[0].name
            let detail =
                groupedSources.compactMap(\.owningApplicationBundleID).first
                ?? groupedSources.compactMap(\.bundleID).first
            return RuntimeOutputSourceGroup(
                option: OutputSourceOption(
                    id: stableID(prefix: "output-source", value: [applicationKey]),
                    name: name,
                    detail: detail
                ),
                sources: groupedSources.sorted { $0.id < $1.id }
            )
        }.sorted { left, right in
            let leftLikely = left.sources.contains(where: \.isLikelyMeetingSource)
            let rightLikely = right.sources.contains(where: \.isLikelyMeetingSource)
            if leftLikely != rightLikely { return leftLikely && !rightLikely }
            let nameOrder = left.option.name.localizedCaseInsensitiveCompare(right.option.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return left.option.id < right.option.id
        }
    }

    func inspectRepository(_ selectedURL: URL) async throws -> GroundingReviewSummary {
        guard activeMeeting == nil else {
            throw PaceNoteActionError.safeMessage("Stop the current meeting before changing repository access.")
        }
        let resourceLimits = GroundingResourceLimits()
        let manager = GroundingManager(
            configuration: GroundingConfiguration(resourceLimits: resourceLimits)
        )
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
                    detail: Self.hardExclusionDetail(
                        $0,
                        resourceLimits: resourceLimits
                    )
                )
            },
            softFindings: inspection.softFindings.map {
                GroundingReviewFinding(
                    id: Self.softFindingID($0),
                    relativePath: $0.relativePath,
                    detail: "Requires explicit approval: \($0.ruleIDs.joined(separator: ", "))."
                )
            },
            instructionFiles: inspection.instructionSources.map(\.relativePath),
            resourceLimits: resourceLimits
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
        guard lifecycle == .open else {
            throw PaceNoteActionError.safeMessage(
                "\(AppBrand.displayName) is shutting down. Reopen it before starting another meeting."
            )
        }
        guard providerOperation == nil else {
            throw PaceNoteActionError.safeMessage(
                "Finish the provider account operation before starting a meeting."
            )
        }
        guard startOperation == nil else {
            throw PaceNoteActionError.safeMessage("A meeting start is already in progress.")
        }
        guard activeMeeting == nil else {
            throw PaceNoteActionError.safeMessage("A meeting is already active.")
        }
        guard !pendingMeetingCleanupBlocked else {
            throw PaceNoteActionError.safeMessage(
                "Private meeting cleanup is incomplete. Quit and reopen \(AppBrand.displayName) before starting another meeting."
            )
        }
        guard request.consentConfirmed else {
            throw PaceNoteActionError.safeMessage(
                "Confirm participant permission, capture scope, and selected-provider processing before capture starts."
            )
        }
        guard request.microphoneEnabled || request.outputEnabled else {
            throw PaceNoteActionError.safeMessage(
                "Enable the microphone or meeting output before starting a meeting."
            )
        }

        let attemptID = UUID()
        let task = Task {
            try await self.performStartMeeting(request, attemptID: attemptID)
        }
        startOperation = StartOperation(attemptID: attemptID, task: task)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        if startOperation?.attemptID == attemptID {
            startOperation = nil
        }
        return try result.get()
    }

    private func performStartMeeting(
        _ request: MeetingStartRequest,
        attemptID: UUID
    ) async throws {
        try requireCurrentStart(attemptID)
        if let startSuspensionBarrier {
            await startSuspensionBarrier()
            try requireCurrentStart(attemptID)
        }

        let cleanupIsHealthy = await ensureStartupCleanup()
        try requireCurrentStart(attemptID)
        guard cleanupIsHealthy else {
            throw PaceNoteActionError.safeMessage(
                "\(AppBrand.displayName) must finish cleanup from an earlier session before capture can start."
            )
        }
        let verifiedSubscription = try await verifiedMeetingSubscription(
            provider: request.provider
        )
        try requireCurrentStart(attemptID)
        if request.outputEnabled, request.outputScope == .meetingApplication {
            _ = await reloadOutputSources()
            try requireCurrentStart(attemptID)
        }

        let context: PendingMeetingContext
        if let snapshotID = request.sealedSnapshotID {
            guard let pendingMeeting, pendingMeeting.snapshot?.id == snapshotID else {
                throw PaceNoteActionError.safeMessage("The reviewed repository snapshot is no longer available.")
            }
            context = pendingMeeting
        } else {
            if let pendingMeeting {
                try await discardPendingMeeting(pendingMeeting)
                try requireCurrentStart(attemptID)
            }
            let meetingID = UUID()
            let privateRoot = try createMeetingRoot(meetingID: meetingID)
            let newContext = PendingMeetingContext(
                meetingID: meetingID,
                privateRoot: privateRoot,
                groundingManager: nil,
                snapshot: nil
            )
            pendingMeeting = newContext
            do {
                try await journal.begin(
                    CleanupJournalEntry(
                        meetingID: meetingID,
                        profileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID,
                        privateRoot: privateRoot
                    )
                )
            } catch {
                do {
                    try await discardPendingMeeting(newContext)
                } catch let cleanupError {
                    pendingMeeting = newContext
                    pendingMeetingCleanupBlocked = true
                    startupCleanupHealthy = false
                    throw cleanupError
                }
                throw PaceNoteActionError.safeMessage(
                    "\(AppBrand.displayName) could not create its private cleanup journal."
                )
            }
            do {
                try requireCurrentStart(attemptID)
            } catch {
                do {
                    try await discardPendingMeeting(newContext)
                } catch let cleanupError {
                    pendingMeeting = newContext
                    pendingMeetingCleanupBlocked = true
                    startupCleanupHealthy = false
                    throw cleanupError
                }
                throw error
            }
            context = newContext
        }
        pendingMeeting = context

        let controller: MeetingSessionController
        let eventTask: Task<Void, Never>
        do {
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
            if request.provider != .codex, request.selectedDomainSkillName != nil {
                throw PaceNoteActionError.safeMessage(
                    "This provider is tool-restricted and cannot load repository skills. Clear the skill or choose Codex."
                )
            }
            if let selected = request.selectedDomainSkillName,
                !availableDomainSkillNames.contains(selected)
            {
                throw PaceNoteActionError.safeMessage(
                    "The selected repository skill is not present in the sealed snapshot."
                )
            }
            let providerResponseGenerator: any MeetingResponseGenerating
            let temporaryRoots: [URL]
            let stableProfileRoot: URL?
            switch request.provider {
            case .codex:
                providerResponseGenerator = CodexMeetingResponseGenerator(
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
                        deepComplexity: context.snapshot == nil ? .narrowTechnical : .hardTechnical,
                        subscriptionQuickEnabled: true,
                        realtimeQuickEnabled: false
                    ),
                    journal: journal
                )
                temporaryRoots = [
                    context.privateRoot.appendingPathComponent("Grounding", isDirectory: true),
                    context.privateRoot.appendingPathComponent("quick-context", isDirectory: true),
                    context.privateRoot.appendingPathComponent("codex-tmp", isDirectory: true),
                    context.privateRoot.appendingPathComponent("skill-context", isDirectory: true),
                ]
                stableProfileRoot = codexProfileRoot
            case .claude:
                providerResponseGenerator = ClaudeMeetingResponseGenerator(
                    configuration: ClaudeMeetingResponseConfiguration(
                        meetingID: context.meetingID,
                        meetingPrivateRoot: context.privateRoot,
                        expectedAccountIdentityHash: verifiedSubscription.identityHash,
                        speakingStyle: Self.speakingStyle,
                        groundingSnapshot: context.snapshot
                    )
                )
                temporaryRoots = [
                    context.privateRoot.appendingPathComponent("Grounding", isDirectory: true),
                    context.privateRoot.appendingPathComponent("claude-runtime", isDirectory: true),
                ]
                stableProfileRoot = nil
            case .gemini:
                providerResponseGenerator = GeminiMeetingResponseGenerator(
                    configuration: GeminiMeetingResponseConfiguration(
                        meetingID: context.meetingID,
                        meetingPrivateRoot: context.privateRoot,
                        speakingStyle: Self.speakingStyle,
                        groundingSnapshot: context.snapshot
                    )
                )
                temporaryRoots = [
                    context.privateRoot.appendingPathComponent("Grounding", isDirectory: true),
                    context.privateRoot.appendingPathComponent("gemini-runtime", isDirectory: true),
                ]
                stableProfileRoot = nil
            }
            let responseGenerator: any MeetingResponseGenerating =
                LowLatencyMeetingResponseGenerator(
                    provider: providerResponseGenerator,
                    quickGenerator: BoundedLocalQuickGenerator(
                        base: FoundationModelQuickGenerator(
                            speakingStyle: Self.speakingStyle
                        ),
                        timeout: .seconds(3)
                    ),
                    planType: verifiedSubscription.planType,
                    providerName: request.provider.rawValue,
                    quickPathDecisionWindow: .milliseconds(3_250)
                )
            let cleaner = DefaultMeetingSessionResourceCleaner(
                privateRoot: context.privateRoot,
                temporaryRoots: temporaryRoots,
                groundingManager: context.groundingManager,
                groundingSnapshot: context.snapshot,
                journal: journal,
                applicationRoot: applicationRoot,
                stableCodexProfileRoot: stableProfileRoot
            )
            controller = MeetingSessionController(
                configuration: MeetingSessionConfiguration(
                    meetingID: context.meetingID,
                    captureMode: captureMode,
                    grounding: groundingIdentity,
                    speakerBrief: Self.speakerBrief,
                    microphoneAttributionDelay: .milliseconds(800),
                    systemOutputScope: request.outputScope.sessionScope,
                    soleNearbySpeakerConfirmed: request.microphoneEnabled
                        && request.soleNearbySpeakerConfirmed
                ),
                audioServices: audioServices,
                speechAssets: speechAssets,
                microphonePermission: microphonePermission,
                responseGenerator: responseGenerator,
                responseCoordinatorConfiguration: ResponseCoordinatorConfiguration(
                    quickDeadline: .seconds(15),
                    resultTTL: .seconds(90),
                    bridgeText: ResponseCoordinatorConfiguration.deterministicFallback
                ),
                resourceCleaner: cleaner
            )
            let sessionEvents = await controller.events()
            try requireCurrentStart(attemptID)
            eventTask = Task { [weak self] in
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
            pendingMeeting = nil
        } catch {
            do {
                try await discardPendingMeeting(context)
            } catch let cleanupError {
                pendingMeeting = context
                pendingMeetingCleanupBlocked = true
                startupCleanupHealthy = false
                throw cleanupError
            }
            throw error
        }

        do {
            _ = try await controller.preflight(
                consent: PaceNoteCore.MeetingConsent(
                    participantDisclosureConfirmed: request.consentConfirmed
                )
            )
            try requireCurrentStart(attemptID)
            try await controller.start()
            try requireCurrentStart(attemptID)
        } catch {
            let report = await controller.stop()
            if let lane = Self.failedStartTeardownLane(
                report: report,
                originalError: error,
                request: request
            ) {
                startupCleanupHealthy = false
                throw MeetingSessionFailure.captureTeardownFailed(lane)
            }
            eventTask.cancel()
            await eventTask.value
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
            if let failure = error as? MeetingSessionFailure,
                case .captureTeardownFailed(let lane) = failure
            {
                throw MeetingSessionFailure.captureUnavailable(lane)
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

    func dismissSuggestion(_ identity: TurnIdentity) async {
        guard let activeMeeting else { return }
        await activeMeeting.controller.dismissSuggestion(identity: identity)
    }

    func stopMeeting() async throws {
        guard let activeMeeting else { return }
        let report = await activeMeeting.controller.stop()
        guard !report.failures.contains(.audioCaptureTeardown) else {
            throw PaceNoteActionError.audioTeardown(
                report.audioTeardownFailureLane ?? .output
            )
        }
        activeMeeting.eventTask.cancel()
        await activeMeeting.eventTask.value
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

    @discardableResult
    func shutdown() async -> Bool {
        if let shutdownTask {
            return await shutdownTask.value
        }
        guard lifecycle != .closed else { return true }

        lifecycle = .closing
        let task = Task { await self.performShutdown() }
        shutdownTask = task
        return await task.value
    }

    private func performShutdown() async -> Bool {
        defer { shutdownTask = nil }

        if let providerOperation {
            providerOperation.cancel()
            await providerOperation.waitForCompletion()
            if self.providerOperation?.id == providerOperation.id {
                self.providerOperation = nil
            }
        }
        if let startOperation {
            startOperation.task.cancel()
            _ = await startOperation.task.result
            if self.startOperation?.attemptID == startOperation.attemptID {
                self.startOperation = nil
            }
        }
        if activeMeeting != nil {
            do {
                try await stopMeeting()
            } catch {
                startupCleanupHealthy = false
            }
            guard activeMeeting == nil else { return false }
        }
        if let pendingMeeting {
            try? await discardPendingMeeting(pendingMeeting)
        }
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()

        // Environment preflight starts the isolated app-server even before a meeting,
        // which can create transcript-free transient databases. Remove them on a clean
        // idle shutdown instead of waiting for the next launch. A nonempty cleanup
        // journal must keep its recovery state intact for the startup janitor.
        do {
            let hasPendingCleanup = try await !journal.entries().isEmpty
            _ = try Self.sanitizeIdleProfileForShutdown(
                profileRoot: codexProfileRoot,
                fileManager: fileManager,
                hasActiveMeeting: activeMeeting != nil,
                hasPendingMeeting: pendingMeeting != nil,
                hasPendingCleanup: hasPendingCleanup
            )
        } catch {
            startupCleanupHealthy = false
        }
        lifecycle = .closed
        return true
    }

    #if DEBUG
        func installActiveMeetingForShutdownTesting(
            controller: MeetingSessionController,
            privateRoot: URL
        ) {
            precondition(activeMeeting == nil)
            activeMeeting = ActiveMeetingContext(
                meetingID: UUID(),
                privateRoot: privateRoot,
                controller: controller,
                eventTask: Task {}
            )
        }

        func shutdownStateForTesting() -> (hasActiveMeeting: Bool, isClosed: Bool) {
            (activeMeeting != nil, lifecycle == .closed)
        }
    #endif

    private func providerOperationBlockReason(action: String) -> String? {
        guard lifecycle == .open else {
            return "\(AppBrand.displayName) is shutting down. Reopen it before \(action)."
        }
        guard activeMeeting == nil, startOperation == nil else {
            return "Stop or finish the current meeting before \(action)."
        }
        guard providerOperation == nil else {
            return "Another provider account operation is already in progress."
        }
        return nil
    }

    private func finishProviderOperation(_ operationID: UUID) {
        if providerOperation?.id == operationID {
            providerOperation = nil
        }
    }

    private static func blockedEnvironmentSnapshot(
        reason: String
    ) -> PaceNoteEnvironmentSnapshot {
        PaceNoteEnvironmentSnapshot(
            microphonePermission: .notChecked,
            systemAudioPermission: .notChecked,
            codex: .limited(reason),
            outputSources: [],
            claude: .limited(reason),
            gemini: .limited(reason)
        )
    }

    private func requireCurrentStart(_ attemptID: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle == .open, startOperation?.attemptID == attemptID else {
            throw CancellationError()
        }
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
                    let sources = outputSourcesByID[sourceID],
                    !sources.isEmpty
                else {
                    throw PaceNoteActionError.safeMessage(
                        "The selected meeting application is no longer available. Reload the app list."
                    )
                }
                selection = .selected(sources.map(\.captureTarget))
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

    private func verifiedMeetingSubscription(
        provider: MeetingInferenceProvider
    ) async throws -> VerifiedMeetingSubscription {
        switch provider {
        case .codex:
            return try await verifiedCodexMeetingSubscription()
        case .claude:
            return try await verifiedClaudeMeetingSubscription()
        case .gemini:
            return try await verifiedGeminiMeetingSubscription()
        }
    }

    private func verifiedCodexMeetingSubscription() async throws -> VerifiedMeetingSubscription {
        if let preverifiedSubscription { return preverifiedSubscription }

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
                    "A different ChatGPT account is signed in. Forget the \(AppBrand.displayName) profile before switching accounts."
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

    private func verifiedClaudeMeetingSubscription() async throws -> VerifiedMeetingSubscription {
        let status: ClaudeSubscriptionStatus
        do {
            status = try await checkedClaudeSubscription()
        } catch {
            throw PaceNoteActionError.safeMessage(Self.safeClaudeMessage(for: error))
        }

        if let expected = UserDefaults.standard.string(forKey: Self.claudeAccountIdentityKey),
            expected != status.identityHash
        {
            throw PaceNoteActionError.safeMessage(
                "A different Claude account is signed in. Confirm the current Claude account in Settings before using it."
            )
        }
        UserDefaults.standard.set(status.identityHash, forKey: Self.claudeAccountIdentityKey)
        return VerifiedMeetingSubscription(
            planType: status.planType,
            identityHash: status.identityHash
        )
    }

    private func verifiedGeminiMeetingSubscription() async throws -> VerifiedMeetingSubscription {
        do {
            let status = try await checkedGeminiSubscription()
            try resetGeminiSignInProfile()
            return VerifiedMeetingSubscription(planType: status.planType, identityHash: nil)
        } catch {
            throw PaceNoteActionError.safeMessage(Self.safeGeminiMessage(for: error))
        }
    }

    private func claudeSubscriptionState() async -> InferenceConnectionState {
        do {
            let status = try await checkedClaudeSubscription()
            if let expected = UserDefaults.standard.string(forKey: Self.claudeAccountIdentityKey),
                expected != status.identityHash
            {
                return .authenticationExpired(
                    "A different Claude account is signed in. Use Current Claude Account only after checking the intended identity."
                )
            }
            UserDefaults.standard.set(status.identityHash, forKey: Self.claudeAccountIdentityKey)
            return .ready(
                InferenceAccountSummary(
                    accountLabel: status.redactedLabel,
                    planLabel: Self.claudePlanLabel(status.planType),
                    modelCount: 1
                )
            )
        } catch ClaudeSubscriptionError.signedOut {
            return .signedOut
        } catch {
            return .unavailable(Self.safeClaudeMessage(for: error))
        }
    }

    private func checkedClaudeSubscription() async throws -> ClaudeSubscriptionStatus {
        let preflightRoot =
            applicationRoot
            .appendingPathComponent("ClaudeAuthChecks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        defer {
            if Self.isStrictlyContained(preflightRoot, inside: applicationRoot) {
                try? fileManager.removeItem(at: preflightRoot)
            }
        }

        let runtime = try ClaudeRuntimeBuilder.prepare(runtimeRoot: preflightRoot)
        let trust = try ClaudeExecutableTrustSnapshot.capture(runtime.executableURL)
        let version = try await ClaudeBinaryInspector.inspect(
            executableURL: runtime.executableURL,
            environment: runtime.processEnvironment
        )
        try ClaudeVersionPolicy.tested.validate(version)
        try trust.revalidate()

        return try await ClaudeCLIAuthStatusChecker(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment
        ).subscriptionStatus()
    }

    private func geminiSubscriptionState() async -> InferenceConnectionState {
        do {
            let status = try await checkedGeminiSubscription()
            try resetGeminiSignInProfile()
            return .ready(
                InferenceAccountSummary(
                    accountLabel: status.redactedLabel,
                    planLabel: status.planType,
                    modelCount: status.modelIDs.count
                )
            )
        } catch GeminiSubscriptionError.signedOut {
            return .signedOut
        } catch {
            return .unavailable(Self.safeGeminiMessage(for: error))
        }
    }

    private func checkedGeminiSubscription() async throws -> GeminiSubscriptionStatus {
        let preflightRoot =
            applicationRoot
            .appendingPathComponent("GeminiAuthChecks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        defer {
            if Self.isStrictlyContained(preflightRoot, inside: applicationRoot) {
                try? fileManager.removeItem(at: preflightRoot)
            }
        }
        let runtime = try GeminiRuntimeBuilder.prepare(
            runtimeRoot: preflightRoot
        )
        let version = try await GeminiBinaryInspector.inspect(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment
        )
        try GeminiVersionPolicy.tested.validate(version)
        try runtime.revalidateExecutable()
        return try await GeminiCLIAuthStatusChecker(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment
        ).subscriptionStatus()
    }

    private func resetGeminiSignInProfile() throws {
        let root = geminiProfileRoot.standardizedFileURL
        guard root.lastPathComponent == "gemini-personal",
            root.deletingLastPathComponent().lastPathComponent == "Profiles",
            Self.isStrictlyContained(root, inside: applicationRoot)
        else {
            throw GeminiIsolatedRuntimeError.invalidRuntimeRoot
        }
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try Self.createPrivateDirectory(root, fileManager: fileManager)
    }

    private func validatedSubscriptionState(
        account: CodexAccount,
        client: CodexAppServerClient
    ) async -> CodexConnectionState {
        guard account.type == "chatgpt",
            let email = Self.normalizedEmail(account.email)
        else {
            return .unavailable(
                "\(AppBrand.displayName) requires a ChatGPT-authenticated Codex account."
            )
        }
        let identityHash = Self.identityHash(email)
        if let expected = UserDefaults.standard.string(forKey: Self.accountIdentityKey),
            expected != identityHash
        {
            return .authenticationExpired(
                "A different ChatGPT account is signed in. Forget the \(AppBrand.displayName) profile before switching accounts."
            )
        }
        UserDefaults.standard.set(identityHash, forKey: Self.accountIdentityKey)

        do {
            let models = try await client.listModels(includeHidden: false)
            let summary = CodexAccountSummary(
                accountLabel: Self.redactedEmail(email),
                planLabel: Self.planLabel(account.planType),
                modelCount: models.count
            )
            do {
                let rateLimits = try await client.rateLimits()
                guard rateLimits.hasAvailableCapacity else {
                    return .readyLimited(
                        summary,
                        "Codex model capacity is temporarily exhausted. Meetings, transcription, and the local bridge can still start; ChirpCue rechecks before the next model launch."
                    )
                }
            } catch {
                return .readyCapacityUnconfirmed(
                    summary,
                    "Codex allowance could not be read. Meetings, transcription, and the local bridge can still start; model access is checked again before use."
                )
            }
            return .ready(summary)
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
                expectedCodexHome: isolated.profileRoot,
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
                _ = try Self.recoverIdleCodexProfileForStartup(
                    applicationRoot: applicationRoot,
                    profileRoot: codexProfileRoot,
                    fileManager: fileManager
                )
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
        if report.failures.isEmpty {
            do {
                guard try await journal.entries().isEmpty else {
                    throw CleanupJournalError.meetingConflict
                }
                let remainingMeetingRoots = try fileManager.contentsOfDirectory(
                    at: meetingsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
                guard remainingMeetingRoots.isEmpty else {
                    throw CleanupJournalError.pathOutsidePrivateRoot
                }
                _ = try CodexStableProfileSanitizer(fileManager: fileManager)
                    .cleanTransientState(profileRoot: codexProfileRoot)
            } catch {
                report.failures.append(
                    CleanupFailure(
                        resource: "structural-audit",
                        reason: "Recovered meeting state was not proven absent."
                    )
                )
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
        if pendingMeeting?.meetingID == context.meetingID {
            pendingMeeting = nil
            pendingMeetingCleanupBlocked = false
        }
    }

    private func createMeetingRoot(meetingID: UUID) throws -> URL {
        let root = meetingsRoot.appendingPathComponent(
            meetingID.uuidString.lowercased(),
            isDirectory: true
        )
        guard Self.isStrictlyContained(root, inside: meetingsRoot) else {
            throw PaceNoteActionError.safeMessage(
                "\(AppBrand.displayName) rejected an unsafe meeting data path."
            )
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

    static func failedStartTeardownLane(
        report: MeetingSessionStopReport,
        originalError: any Error,
        request: MeetingStartRequest
    ) -> AudioLane? {
        guard report.failures.contains(.audioCaptureTeardown) else { return nil }
        if let lane = report.audioTeardownFailureLane { return lane }
        if let failure = originalError as? MeetingSessionFailure,
            case .captureTeardownFailed(let lane) = failure
        {
            return lane
        }
        return request.outputEnabled ? .output : .microphone
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
                throw PaceNoteActionError.safeMessage(
                    "\(AppBrand.displayName) rejected an unsafe private data directory."
                )
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

    private static func hardExclusionDetail(
        _ finding: HardExcludedPath,
        resourceLimits: GroundingResourceLimits
    ) -> String {
        if finding.reason == .oversizedFile {
            let maximumMiB = resourceLimits.maximumFileBytes / (1_024 * 1_024)
            return "Excluded because it exceeds the \(maximumMiB) MiB per-file grounding limit."
        }
        return "Always excluded: \(finding.reason.rawValue)."
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

    /// A newer official Codex build may add transcript-free cache/state files before
    /// ChirpCue has learned their names. With no journaled meeting to recover, rebuild
    /// the entire app-owned profile instead of leaving account sign-in permanently
    /// blocked. Keychain-backed ChatGPT authentication is outside this directory.
    @discardableResult
    static func recoverIdleCodexProfileForStartup(
        applicationRoot: URL,
        profileRoot: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let sanitizer = CodexStableProfileSanitizer(fileManager: fileManager)
        do {
            _ = try sanitizer.cleanTransientState(profileRoot: profileRoot)
            return false
        } catch {
            try CodexProfileForgetter(
                applicationRoot: applicationRoot,
                profileRoot: profileRoot,
                fileManager: fileManager
            ).resetLocalProfileForRecovery()
            _ = try sanitizer.cleanTransientState(profileRoot: profileRoot)
            return true
        }
    }

    @discardableResult
    static func sanitizeIdleProfileForShutdown(
        profileRoot: URL,
        fileManager: FileManager,
        hasActiveMeeting: Bool,
        hasPendingMeeting: Bool,
        hasPendingCleanup: Bool
    ) throws -> Bool {
        guard !hasActiveMeeting, !hasPendingMeeting, !hasPendingCleanup else { return false }
        _ = try CodexStableProfileSanitizer(fileManager: fileManager)
            .cleanTransientState(profileRoot: profileRoot)
        return true
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

    private static func claudePlanLabel(_ plan: String) -> String {
        guard !plan.isEmpty else { return "Claude subscription" }
        return "Claude \(plan.prefix(1).uppercased())\(plan.dropFirst())"
    }

    private static func safeClaudeMessage(for error: any Error) -> String {
        if let error = error as? ClaudeSubscriptionError, let message = error.errorDescription {
            return message
        }
        if let error = error as? ClaudeBinaryCompatibilityError,
            let message = error.errorDescription
        {
            return message
        }
        if let error = error as? ClaudeIsolatedRuntimeError,
            let message = error.errorDescription
        {
            return message
        }
        return "The local Claude subscription check could not complete safely."
    }

    private static func safeGeminiMessage(for error: any Error) -> String {
        if let error = error as? GeminiSubscriptionError, let message = error.errorDescription {
            return message
        }
        if let error = error as? GeminiBinaryCompatibilityError,
            let message = error.errorDescription
        {
            return message
        }
        if let error = error as? GeminiIsolatedRuntimeError,
            let message = error.errorDescription
        {
            return message
        }
        return "The local Google AI subscription check could not complete safely."
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        return "The local \(AppBrand.displayName) service could not complete this operation."
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
        case "Calm": "calm, reassuring, and conversational, like a pragmatic staff engineer"
        case "Technical": "precise, technical, and conversational, like a pragmatic staff engineer"
        default: "direct, concise, and conversational, like a pragmatic staff engineer"
        }
    }

    private static var speakerBrief: String? {
        SpeakerBriefPolicy.normalized(
            UserDefaults.standard.string(forKey: "paceNote.speakerBrief")
        )
    }

    private static let accountIdentityKey = "paceNote.codexAccountIdentityHash"
    private static let claudeAccountIdentityKey = "paceNote.claudeAccountIdentityHash"
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
            beginGeminiSignIn: { await runtime.beginGeminiSignIn() },
            forgetCodexProfile: {
                do {
                    try await runtime.forgetCodexProfile()
                } catch let error as PaceNoteActionError {
                    throw error
                } catch {
                    throw PaceNoteActionError.safeMessage(
                        "\(AppBrand.displayName) could not forget the isolated Codex profile."
                    )
                }
            },
            confirmClaudeAccountChange: {
                do {
                    return try await runtime.confirmClaudeAccountChange()
                } catch let error as PaceNoteActionError {
                    throw error
                } catch {
                    throw PaceNoteActionError.safeMessage(
                        "\(AppBrand.displayName) could not confirm the current Claude account."
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
                do {
                    try await runtime.startMeeting($0)
                } catch let error as PaceNoteActionError {
                    throw error
                } catch let error as MeetingSessionFailure {
                    if case .captureTeardownFailed(let lane) = error {
                        throw PaceNoteActionError.audioTeardown(lane)
                    }
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            },
            pauseMeeting: {
                do { try await runtime.pauseMeeting() } catch let error as MeetingSessionFailure {
                    if case .captureTeardownFailed(let lane) = error {
                        throw PaceNoteActionError.audioTeardown(lane)
                    }
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                } catch {
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                }
            },
            resumeMeeting: {
                do { try await runtime.resumeMeeting() } catch let error as MeetingSessionFailure {
                    if case .captureTeardownFailed(let lane) = error {
                        throw PaceNoteActionError.audioTeardown(lane)
                    }
                    throw PaceNoteActionError.safeMessage(PaceNoteRuntime.safeMessage(for: error))
                } catch {
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
            },
            dismissSuggestion: {
                await runtime.dismissSuggestion($0)
            }
        )
    }
}
