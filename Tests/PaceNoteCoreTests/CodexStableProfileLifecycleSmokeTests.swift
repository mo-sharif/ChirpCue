import Foundation
import XCTest

@testable import PaceNoteCore

/// Opt-in, zero-generation proof for PaceNote's real ChatGPT-authenticated profile.
///
/// This smoke performs discovery plus a base/fork lifecycle, but never starts a model turn.
/// The default suite only records a skip. Run it only after completing PaceNote's dedicated
/// ChatGPT sign-in.
final class CodexStableProfileLifecycleSmokeTests: XCTestCase {
    private static let optInEnvironmentKey =
        "PACENOTE_RUN_CODEX_STABLE_PROFILE_LIFECYCLE_SMOKE"

    func testMeetingGeneratorPrepareRetriesHungThreadStartsThenSanitizes() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 after signing in through ChirpCue to run the dedicated-profile preparation smoke."
            )
        }

        let fixture = try StableProfileLifecycleFixture()
        let profileLease = try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        defer { withExtendedLifetime(profileLease) {} }

        let generator = CodexMeetingResponseGenerator(
            configuration: MeetingResponseConfiguration(
                meetingID: fixture.meetingID,
                meetingPrivateRoot: fixture.ownedTemporaryRoot,
                codexProfileRoot: fixture.profileRoot,
                executableURL: fixture.codexExecutableURL,
                clientVersion: "0.3.4",
                groundingSnapshot: nil,
                deepComplexity: .hardTechnical
            ),
            journal: fixture.journal
        )

        do {
            _ = try await generator.prepare()
        } catch {
            _ = await generator.shutdown()
            try? fixture.removeOwnedTemporaryRoot()
            throw error
        }
        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
        try fixture.removeOwnedTemporaryRoot()
    }

    func testDedicatedProfileZeroGenerationLifecycleThenSanitize() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 after signing in through ChirpCue to run the dedicated-profile zero-generation lifecycle smoke."
            )
        }

        let fixture = try StableProfileLifecycleFixture()
        let profileLease: CodexProfileLease
        do {
            profileLease = try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        } catch {
            try? fixture.removeOwnedTemporaryRoot()
            throw error
        }
        defer { withExtendedLifetime(profileLease) {} }

        do {
            try await fixture.beginRecoveryJournal()
        } catch {
            try? fixture.removeOwnedTemporaryRoot()
            throw error
        }

        let sanitizer = CodexStableProfileSanitizer()
        var client: CodexAppServerClient?
        var ownedThreadIDs: [String] = []
        var primaryError: (any Error)?

        do {
            _ = try sanitizer.cleanTransientState(profileRoot: fixture.profileRoot)
            try fixture.assertPersistentAllowlistedFootprint()

            let isolated = try CodexIsolatedRuntimeBuilder.prepare(
                profileRoot: fixture.profileRoot,
                temporaryRoot: fixture.codexTemporaryRoot,
                codexExecutableURL: fixture.codexExecutableURL
            )
            XCTAssertEqual(
                isolated.permissionProfileID,
                CodexIsolatedRuntimeBuilder.defaultPermissionProfileID
            )

            let connected = try await Self.withTimeout(.seconds(30)) {
                try await CodexAppServerClient.connect(
                    configuration: .init(
                        executableURL: fixture.codexExecutableURL,
                        expectedCodexHome: isolated.profileRoot,
                        requestTimeout: .seconds(15),
                        clientVersion: "0.1.0",
                        permissionProfileID: isolated.permissionProfileID,
                        processArguments: isolated.processArguments,
                        processEnvironment: isolated.processEnvironment
                    )
                )
            }
            client = connected

            let account = try await Self.withTimeout(.seconds(20)) {
                try await connected.account(refreshToken: false)
            }
            XCTAssertEqual(account.account?.type, "chatgpt")

            let models = try await Self.withTimeout(.seconds(20)) {
                try await connected.listModels(includeHidden: false)
            }.filter { $0.hidden != true }
            XCTAssertFalse(models.isEmpty)
            let model = try XCTUnwrap(models.first?.model)
            XCTAssertFalse(model.isEmpty)

            let profiles = try await Self.withTimeout(.seconds(20)) {
                try await connected.listPermissionProfiles(cwd: fixture.workspaceRoot.path)
            }
            XCTAssertTrue(
                profiles.contains {
                    $0.id == isolated.permissionProfileID && $0.allowed
                }
            )

            _ = try await Self.withTimeout(.seconds(20)) {
                try await connected.rateLimits()
            }

            try await Self.withTimeout(.seconds(20)) {
                try await connected.setSkillExtraRoots([fixture.packagedSkillRoot.path])
            }
            let skills = try await Self.withTimeout(.seconds(20)) {
                try await connected.listSkills(
                    cwds: [fixture.workspaceRoot.path],
                    forceReload: true
                )
            }
            let expectedSkillURL = fixture.packagedSkillRoot
                .appendingPathComponent("SKILL.md", isDirectory: false)
                .standardizedFileURL
            let packagedMatches = skills.data.flatMap(\.skills).filter {
                $0.name == PackagedMeetingCoachSkill.name
                    && URL(fileURLWithPath: $0.path).standardizedFileURL == expectedSkillURL
            }
            XCTAssertEqual(packagedMatches.count, 1)

            let base = try await Self.withTimeout(.seconds(30)) {
                try await connected.createPersistentBase(
                    cwd: fixture.workspaceRoot.path,
                    runtimeWorkspaceRoots: [
                        fixture.workspaceRoot.path,
                        fixture.packagedSkillRoot.path,
                    ],
                    model: model,
                    baseInstructions: "ChirpCue zero-generation lifecycle smoke. Do not start a turn."
                )
            }
            ownedThreadIDs.append(base.id)
            try await fixture.journal.recordThread(base.id, meetingID: fixture.meetingID)
            XCTAssertEqual(base.permissionProfileID, isolated.permissionProfileID)
            XCTAssertEqual(base.cwd, fixture.workspaceRoot.path)

            let fork = try await Self.withTimeout(.seconds(30)) {
                try await connected.forkEphemeral(from: base, model: model)
            }
            ownedThreadIDs.append(fork.id)
            try await fixture.journal.recordThread(fork.id, meetingID: fixture.meetingID)
            XCTAssertNotEqual(fork.id, base.id)
            XCTAssertEqual(fork.baseThreadID, base.id)
            XCTAssertEqual(fork.permissionProfileID, isolated.permissionProfileID)
            XCTAssertEqual(fork.cwd, fixture.workspaceRoot.path)
        } catch {
            primaryError = error
        }

        let cleanupFailures = await Self.cleanupAndVerify(
            fixture: fixture,
            connectedClient: client,
            ownedThreadIDs: ownedThreadIDs,
            sanitizer: sanitizer
        )
        for failure in cleanupFailures {
            XCTFail("Stable-profile cleanup failed during \(failure.rawValue).")
        }
        if let primaryError { throw primaryError }
        guard cleanupFailures.isEmpty else {
            throw StableProfileLifecycleSmokeError.cleanupFailed
        }
    }

    private static func cleanupAndVerify(
        fixture: StableProfileLifecycleFixture,
        connectedClient: CodexAppServerClient?,
        ownedThreadIDs: [String],
        sanitizer: CodexStableProfileSanitizer
    ) async -> [StableProfileLifecycleCleanupFailure] {
        var failures: [StableProfileLifecycleCleanupFailure] = []
        let shouldSweepThreads = connectedClient != nil || !ownedThreadIDs.isEmpty
        if let connectedClient { await connectedClient.shutdown() }

        var threadsVerified = !shouldSweepThreads
        if shouldSweepThreads {
            var cleanupClient: CodexAppServerClient?
            do {
                let connected = try await withTimeout(.seconds(30)) {
                    try await fixture.connect()
                }
                cleanupClient = connected
                var listedThreadIDs: [String] = []
                do {
                    listedThreadIDs = try await withTimeout(.seconds(20)) {
                        try await connected.listThreadIDs(cwd: fixture.workspaceRoot.path)
                    }
                } catch {
                    failures.append(.threadListing)
                }

                let cleanupThreadIDs = unique(
                    Array(ownedThreadIDs.reversed()) + listedThreadIDs
                )
                var rejectedDeletionIDs: [String] = []
                for threadID in cleanupThreadIDs {
                    do {
                        try await withTimeout(.seconds(20)) {
                            try await connected.deleteThread(id: threadID)
                        }
                        try await fixture.journal.removeThread(
                            threadID,
                            meetingID: fixture.meetingID
                        )
                    } catch {
                        rejectedDeletionIDs.append(threadID)
                    }
                }

                do {
                    let residual = try await withTimeout(.seconds(20)) {
                        try await connected.listThreadIDs(cwd: fixture.workspaceRoot.path)
                    }
                    let residualIDs = Set(residual)
                    for threadID in rejectedDeletionIDs {
                        guard !residualIDs.contains(threadID) else {
                            failures.append(.threadDeletion)
                            continue
                        }
                        do {
                            try await fixture.journal.removeThread(
                                threadID,
                                meetingID: fixture.meetingID
                            )
                        } catch {
                            failures.append(.threadDeletion)
                        }
                    }
                    threadsVerified = residual.isEmpty
                    if !threadsVerified { failures.append(.residualThreads) }
                } catch {
                    if !rejectedDeletionIDs.isEmpty {
                        failures.append(.threadDeletion)
                    }
                    failures.append(.residualThreadVerification)
                }
            } catch {
                failures.append(.cleanupConnection)
            }
            if let cleanupClient { await cleanupClient.shutdown() }
        }

        var profileVerified = false
        if threadsVerified {
            do {
                _ = try sanitizer.cleanTransientState(profileRoot: fixture.profileRoot)
                try fixture.assertPersistentAllowlistedFootprint()
                profileVerified = true
            } catch {
                failures.append(.profileSanitization)
            }
        } else {
            failures.append(.profileSanitizationSkipped)
        }

        if threadsVerified, profileVerified {
            var temporaryRootRemoved = false
            do {
                try fixture.removeOwnedTemporaryRoot()
                temporaryRootRemoved = true
            } catch {
                failures.append(.temporaryRootDeletion)
            }
            if temporaryRootRemoved {
                do {
                    try await fixture.journal.remove(meetingID: fixture.meetingID)
                    try fixture.removeJournalFile()
                } catch {
                    failures.append(.journalRemoval)
                }
            }
        }
        return failures
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw StableProfileLifecycleSmokeError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw StableProfileLifecycleSmokeError.timedOut
            }
            return first
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private enum StableProfileLifecycleSmokeError: Error {
    case missingApplicationSupportDirectory
    case invalidOwnedTemporaryRoot
    case unexpectedPersistentEntry(String)
    case pendingCleanupExists
    case cleanupFailed
    case timedOut
}

private enum StableProfileLifecycleCleanupFailure: String, Sendable {
    case cleanupConnection = "cleanup connection"
    case threadListing = "thread listing"
    case threadDeletion = "thread deletion"
    case residualThreads = "residual thread check"
    case residualThreadVerification = "residual thread verification"
    case profileSanitization = "profile sanitization"
    case profileSanitizationSkipped = "profile sanitization precondition"
    case temporaryRootDeletion = "temporary-root deletion"
    case journalRemoval = "recovery-journal removal"
}

private struct StableProfileLifecycleFixture {
    let meetingID: UUID
    let applicationRoot: URL
    let profileRoot: URL
    let ownedTemporaryRoot: URL
    let journalURL: URL
    let codexTemporaryRoot: URL
    let workspaceRoot: URL
    let packagedSkillRoot: URL
    let codexExecutableURL: URL
    let journal: CleanupJournalStore

    init(fileManager: FileManager = .default) throws {
        guard
            let supportRoot = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw StableProfileLifecycleSmokeError.missingApplicationSupportDirectory
        }

        meetingID = UUID()
        applicationRoot =
            supportRoot
            .appendingPathComponent("PaceNote", isDirectory: true)
            .standardizedFileURL
        profileRoot =
            applicationRoot
            .appendingPathComponent("Profiles/personal", isDirectory: true)
            .standardizedFileURL
        ownedTemporaryRoot =
            applicationRoot
            .appendingPathComponent("Meetings/SmokeTests", isDirectory: true)
            .appendingPathComponent(
                "stable-profile-lifecycle-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        journalURL = fileManager.temporaryDirectory.appendingPathComponent(
            "chirpcue-stable-profile-journal-\(UUID().uuidString).json",
            isDirectory: false
        )
        codexTemporaryRoot =
            ownedTemporaryRoot
            .appendingPathComponent("codex-tmp", isDirectory: true)
        workspaceRoot =
            ownedTemporaryRoot
            .appendingPathComponent("workspace", isDirectory: true)
        codexExecutableURL = Self.locateCodexExecutable(fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: workspaceRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: codexTemporaryRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            packagedSkillRoot = try PackagedMeetingSkillStager.prepare(
                in: ownedTemporaryRoot,
                fileManager: fileManager
            )
            journal = try CleanupJournalStore(
                journalURL: journalURL,
                allowedRoot: ownedTemporaryRoot
            )
        } catch {
            try? fileManager.removeItem(at: ownedTemporaryRoot)
            throw error
        }
    }

    func beginRecoveryJournal() async throws {
        guard try await journal.entries().isEmpty else {
            throw StableProfileLifecycleSmokeError.pendingCleanupExists
        }
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: ownedTemporaryRoot,
                expectedThreadCwds: [workspaceRoot]
            )
        )
    }

    func connect() async throws -> CodexAppServerClient {
        let isolated = try CodexIsolatedRuntimeBuilder.prepare(
            profileRoot: profileRoot,
            temporaryRoot: codexTemporaryRoot,
            codexExecutableURL: codexExecutableURL
        )
        return try await CodexAppServerClient.connect(
            configuration: .init(
                executableURL: codexExecutableURL,
                expectedCodexHome: isolated.profileRoot,
                requestTimeout: .seconds(15),
                clientVersion: "0.1.0",
                permissionProfileID: isolated.permissionProfileID,
                processArguments: isolated.processArguments,
                processEnvironment: isolated.processEnvironment
            )
        )
    }

    func assertPersistentAllowlistedFootprint(
        fileManager: FileManager = .default
    ) throws {
        let allowed = Set(["config.toml", "installation_id"])
        let credentialEntries = [".credentials.json", "auth.json", "credentials.json"]
        for name in credentialEntries {
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: profileRoot.appendingPathComponent(name, isDirectory: false).path
                )
            )
        }

        let entries = try fileManager.contentsOfDirectory(
            at: profileRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard allowed.contains(name) else {
                throw StableProfileLifecycleSmokeError.unexpectedPersistentEntry(name)
            }
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertNotEqual(values.isSymbolicLink, true)
            XCTAssertNotEqual(values.isDirectory, true)
        }

        let configurationURL =
            profileRoot
            .appendingPathComponent("config.toml", isDirectory: false)
        XCTAssertTrue(fileManager.fileExists(atPath: configurationURL.path))
        let configuration = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertEqual(
            configuration,
            CodexIsolatedRuntimeBuilder.configurationText(
                permissionProfileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID
            )
        )
        let attributes = try fileManager.attributesOfItem(atPath: configurationURL.path)
        let mode = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        XCTAssertEqual(mode, 0o600)
        let profileAttributes = try fileManager.attributesOfItem(atPath: profileRoot.path)
        let profileMode =
            ((profileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        XCTAssertEqual(profileMode, 0o700)
    }

    func removeOwnedTemporaryRoot(fileManager: FileManager = .default) throws {
        try LiveSmokeStorageCleanup.removeOwnedRoot(
            ownedTemporaryRoot,
            applicationRoot: applicationRoot,
            fileManager: fileManager
        )
    }

    func removeJournalFile(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
    }

    private static func locateCodexExecutable(fileManager: FileManager) -> URL {
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
            ?? candidates[0]
    }
}
