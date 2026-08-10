import Foundation
import XCTest

@testable import PaceNoteCore

final class CleanupJournalTests: XCTestCase {
    func testJournalRejectsPathsOutsidePrivateRoot() async throws {
        let fixture = try Fixture()
        let journal = try CleanupJournalStore(journalURL: fixture.journalURL, allowedRoot: fixture.root)
        let entry = CleanupJournalEntry(
            meetingID: UUID(),
            profileID: "personal",
            privateRoot: fixture.meetingRoot,
            snapshotRoots: [URL(fileURLWithPath: "/tmp/outside")]
        )

        do {
            try await journal.begin(entry)
            XCTFail("Expected path rejection")
        } catch let error as CleanupJournalError {
            XCTAssertEqual(error, .pathOutsidePrivateRoot)
        }
    }

    func testJanitorDeletesThreadsAndSnapshotThenClearsJournal() async throws {
        let fixture = try Fixture()
        let snapshot = fixture.meetingRoot.appending(path: "snapshot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let journal = try CleanupJournalStore(journalURL: fixture.journalURL, allowedRoot: fixture.root)
        let meetingID = UUID()
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                snapshotRoots: [snapshot],
                expectedThreadCwds: [snapshot],
                threadIDs: ["thread-recorded"]
            ))
        let client = CleanupClient()
        let janitor = CleanupJanitor(journal: journal)

        let report = await janitor.run(client: client)

        XCTAssertEqual(report.deletedSnapshotCount, 1)
        XCTAssertEqual(report.deletedThreadCount, 2)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        let remaining = try await journal.entries()
        XCTAssertTrue(remaining.isEmpty)
        let deleted = await client.deleted
        XCTAssertEqual(deleted, Set(["thread-recorded", "thread-by-cwd"]))

        let secondReport = await janitor.run(client: client)
        XCTAssertEqual(secondReport.deletedThreadCount, 0)
        XCTAssertEqual(secondReport.deletedSnapshotCount, 0)
        XCTAssertTrue(secondReport.failures.isEmpty)
    }

    func testRemoveThreadIsScopedAndIdempotent() async throws {
        let fixture = try Fixture()
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let meetingID = UUID()
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                threadIDs: ["thread-one", "thread-two"]
            )
        )

        try await journal.removeThread("thread-one", meetingID: meetingID)
        try await journal.removeThread("thread-one", meetingID: meetingID)

        let entries = try await journal.entries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.threadIDs, ["thread-two"])
    }

    func testMergePreservesPreexistingSnapshotRecoveryRoots() async throws {
        let fixture = try Fixture()
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let meetingID = UUID()
        let groundingRoot = fixture.meetingRoot.appendingPathComponent("Grounding")
        let codexHome = fixture.meetingRoot.appendingPathComponent("codex-home")
        let quickRoot = fixture.meetingRoot.appendingPathComponent("quick-context")
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                snapshotRoots: [groundingRoot]
            )
        )

        try await journal.merge(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                snapshotRoots: [codexHome, quickRoot],
                expectedThreadCwds: [quickRoot]
            )
        )

        let entries = try await journal.entries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(
            Set(entry.snapshotRoots),
            Set([groundingRoot, codexHome, quickRoot].map(\.standardizedFileURL))
        )
        XCTAssertEqual(entry.expectedThreadCwds, [quickRoot.standardizedFileURL])
    }

    func testExpectedThreadCwdRequiresCodexCleanupBeforeAnyThreadIsRecorded() {
        let meetingRoot = URL(fileURLWithPath: "/private/meeting", isDirectory: true)
        let entry = CleanupJournalEntry(
            meetingID: UUID(),
            profileID: "personal",
            privateRoot: meetingRoot,
            expectedThreadCwds: [meetingRoot.appendingPathComponent("quick-context")]
        )

        XCTAssertTrue(entry.threadIDs.isEmpty)
        XCTAssertTrue(entry.requiresCodexCleanup)
    }

    func testJanitorReportsJournalRemovalWriteFailure() async throws {
        let fixture = try Fixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.root.path
            )
        }
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let meetingID = UUID()
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                expectedThreadCwds: [fixture.meetingRoot]
            )
        )
        let client = JournalWriteBlockingCleanupClient(directory: fixture.root)

        let report = await CleanupJanitor(journal: journal).run(client: client)

        XCTAssertTrue(
            report.failures.contains { $0.resource == "cleanup-journal" },
            "A failed final journal write must keep startup cleanup unhealthy."
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.root.path
        )
        let remainingMeetingIDs = try await journal.entries().map(\.meetingID)
        XCTAssertEqual(remainingMeetingIDs, [meetingID])
    }

    func testJanitorPreservesDisposableStateWhenThreadDiscoveryFails() async throws {
        let fixture = try Fixture()
        let codexHome = fixture.meetingRoot.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let meetingID = UUID()
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                snapshotRoots: [codexHome],
                expectedThreadCwds: [fixture.meetingRoot]
            )
        )

        let report = await CleanupJanitor(journal: journal).run(
            client: FailingThreadDiscoveryClient()
        )

        XCTAssertTrue(report.failures.contains { $0.resource == "thread-cwd" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome.path))
        let remainingMeetingIDs = try await journal.entries().map(\.meetingID)
        XCTAssertEqual(remainingMeetingIDs, [meetingID])
    }

    func testJanitorReconcilesAnAlreadyAbsentRecordedThread() async throws {
        let fixture = try Fixture()
        let snapshot = fixture.meetingRoot.appendingPathComponent(
            "snapshot",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let meetingID = UUID()
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                snapshotRoots: [snapshot],
                expectedThreadCwds: [fixture.meetingRoot],
                threadIDs: ["ephemeral-thread"]
            )
        )
        let client = MissingThreadCleanupClient()

        let report = await CleanupJanitor(journal: journal).run(client: client)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.deletedThreadCount, 0)
        XCTAssertEqual(report.deletedSnapshotCount, 1)
        let remainingEntries = try await journal.entries()
        let deleteAttempts = await client.deleteAttempts
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertEqual(deleteAttempts, 1)
    }

    func testJanitorKeepsRecoveryBlockedWhenRejectedThreadIsStillPresent() async throws {
        let fixture = try Fixture()
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let meetingID = UUID()
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: fixture.meetingRoot,
                expectedThreadCwds: [fixture.meetingRoot],
                threadIDs: ["persisted-thread"]
            )
        )

        let report = await CleanupJanitor(journal: journal).run(
            client: PresentRejectedThreadCleanupClient()
        )

        XCTAssertTrue(report.failures.contains { $0.resource == "thread" })
        let remainingMeetingIDs = try await journal.entries().map(\.meetingID)
        XCTAssertEqual(remainingMeetingIDs, [meetingID])
    }

    func testPrivacyAuditReportsHashNotSensitiveNeedle() throws {
        let fixture = try Fixture()
        let file = fixture.root.appending(path: "state.log")
        let secret = Data("private meeting sentence".utf8)
        try Data("prefix private meeting sentence suffix".utf8).write(to: file)

        let findings = try PrivacyAuditor().scan(root: fixture.root, sensitiveNeedles: [secret])

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].relativePath, "state.log")
        XCTAssertFalse(findings[0].needleHash.contains("meeting"))
    }

    func testPrivacyAuditIncludesHiddenFilesAndPackageDescendants() throws {
        let fixture = try Fixture()
        let hiddenRoot = fixture.root.appendingPathComponent(".state", isDirectory: true)
        let packageRoot = fixture.root.appendingPathComponent(
            "Diagnostics.app/Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let secret = Data("private meeting sentence".utf8)
        try secret.write(to: hiddenRoot.appendingPathComponent("session.log"))
        try secret.write(to: packageRoot.appendingPathComponent("diagnostic.log"))

        let findings = try PrivacyAuditor().scan(
            root: fixture.root,
            sensitiveNeedles: [secret]
        )

        XCTAssertEqual(
            Set(findings.map(\.relativePath)),
            Set([".state/session.log", "Diagnostics.app/Contents/diagnostic.log"])
        )
    }

    func testPrivacyAuditStreamsFilesLargerThanTwentyMegabytes() throws {
        let fixture = try Fixture()
        let file = fixture.root.appendingPathComponent("large-state.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let secret = Data("large private meeting canary".utf8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 20_500_000)
        try handle.write(contentsOf: secret)
        try handle.close()

        let findings = try PrivacyAuditor().scan(
            root: fixture.root,
            sensitiveNeedles: [secret]
        )

        XCTAssertEqual(findings.map(\.relativePath), ["large-state.sqlite"])
    }

    func testStableProfileSanitizerDeletesOnlyObservedTransientState() throws {
        let fixture = try Fixture()
        let profile = fixture.root.appendingPathComponent("profile", isDirectory: true)
        let sandboxMigration = profile.appendingPathComponent(
            ".sandbox_migration",
            isDirectory: false
        )
        let cache = profile.appendingPathComponent("cache", isDirectory: true)
        let plugins = profile.appendingPathComponent("plugins", isDirectory: true)
        let sessions = profile.appendingPathComponent("sessions", isDirectory: true)
        let shellSnapshots = profile.appendingPathComponent("shell_snapshots", isDirectory: true)
        let skills = profile.appendingPathComponent("skills", isDirectory: true)
        let threadWriterLocks = profile.appendingPathComponent(
            "thread-writer-locks",
            isDirectory: true
        )
        let temporary = profile.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        for directory in [
            cache, plugins, sessions, shellSnapshots, skills, threadWriterLocks, temporary,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("v1".utf8).write(to: sandboxMigration)
        try Data("skill_extra_roots = [\"/private/meeting\"]".utf8).write(
            to: profile.appendingPathComponent("config.toml")
        )
        try Data("installation".utf8).write(to: profile.appendingPathComponent("installation_id"))
        try Data("models".utf8).write(to: profile.appendingPathComponent("models_cache.json"))
        try Data("sqlite".utf8).write(to: profile.appendingPathComponent("state_5.sqlite"))

        let report = try CodexStableProfileSanitizer().cleanTransientState(
            profileRoot: profile
        )

        XCTAssertEqual(report.deletedEntryCount, 10)
        for directory in [
            cache, plugins, sessions, shellSnapshots, skills, threadWriterLocks,
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandboxMigration.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: profile.appendingPathComponent("config.toml").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: profile.appendingPathComponent("config.toml"),
                encoding: .utf8
            ),
            CodexIsolatedRuntimeBuilder.configurationText(
                permissionProfileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: profile.appendingPathComponent("models_cache.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: profile.appendingPathComponent("state_5.sqlite").path
            )
        )
    }

    func testStableProfileSanitizerFailsClosedBeforeDeletingUnknownOrCredentialState() throws {
        let fixture = try Fixture()
        let profile = fixture.root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let state = profile.appendingPathComponent("state_5.sqlite")
        let unknownState = profile.appendingPathComponent("unrecognized-state", isDirectory: true)
        try Data("sqlite".utf8).write(to: state)
        try FileManager.default.createDirectory(at: unknownState, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try CodexStableProfileSanitizer().cleanTransientState(profileRoot: profile)
        ) { error in
            XCTAssertEqual(
                error as? CodexStableProfileCleanupError,
                .unexpectedEntry("unrecognized-state")
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))

        try FileManager.default.removeItem(at: unknownState)
        let auth = profile.appendingPathComponent("auth.json")
        try Data("credential-canary".utf8).write(to: auth)
        XCTAssertThrowsError(
            try CodexStableProfileSanitizer().cleanTransientState(profileRoot: profile)
        ) { error in
            XCTAssertEqual(
                error as? CodexStableProfileCleanupError,
                .credentialMaterialPresent("auth.json")
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
    }

    func testStableProfileSanitizerDeletesTransientSymlinksButRejectsPersistentHardlinks() throws {
        let fixture = try Fixture()
        let profile = fixture.root.appendingPathComponent("profile", isDirectory: true)
        let skills = profile.appendingPathComponent("skills", isDirectory: true)
        let external = fixture.root.appendingPathComponent("external.txt")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("external".utf8).write(to: external)
        let linkedSkill = skills.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(
            at: linkedSkill,
            withDestinationURL: external
        )

        let report = try CodexStableProfileSanitizer().cleanTransientState(profileRoot: profile)

        XCTAssertEqual(report.deletedEntryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skills.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))

        let installation = profile.appendingPathComponent("installation_id")
        try FileManager.default.linkItem(at: external, to: installation)
        XCTAssertThrowsError(
            try CodexStableProfileSanitizer().cleanTransientState(profileRoot: profile)
        ) { error in
            XCTAssertEqual(
                error as? CodexStableProfileCleanupError,
                .unsafeEntry("installation_id")
            )
        }
    }

    func testPrivacyAuditRejectsSymlinksAndHardlinksEvenWithoutNeedles() throws {
        let fixture = try Fixture()
        let external = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("audit-external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("external".utf8).write(to: external)
        let symlink = fixture.root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)

        XCTAssertThrowsError(
            try PrivacyAuditor().scan(root: fixture.root, sensitiveNeedles: [])
        ) { error in
            XCTAssertEqual(
                error as? PrivacyAuditError,
                .unsafeEntry("linked.txt")
            )
        }

        try FileManager.default.removeItem(at: symlink)
        let original = fixture.root.appendingPathComponent("original.txt")
        let hardlink = fixture.root.appendingPathComponent("hardlink.txt")
        try Data("linked inode".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardlink)
        XCTAssertThrowsError(
            try PrivacyAuditor().scan(root: fixture.root, sensitiveNeedles: [])
        ) { error in
            guard let auditError = error as? PrivacyAuditError else {
                return XCTFail("Expected unsafe hardlink rejection.")
            }
            guard case .unsafeEntry(let path) = auditError else { return }
            XCTAssertTrue(["hardlink.txt", "original.txt"].contains(path))
        }
    }

    func testDefaultCleanerAuditsMeetingAndStableProfileRoots() async throws {
        let fixture = try Fixture()
        let profile = fixture.root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let secret = Data("private stable profile canary".utf8)
        try secret.write(to: profile.appendingPathComponent("config.toml"))
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let cleaner = DefaultMeetingSessionResourceCleaner(
            privateRoot: fixture.meetingRoot,
            journal: journal,
            applicationRoot: fixture.root,
            stableCodexProfileRoot: profile
        )

        let findingCount = try await cleaner.residualFindingCount(
            sensitiveNeedles: [secret]
        )

        XCTAssertEqual(findingCount, 1)
    }

    func testCleanerRestoresCanonicalConfigWhilePreservingCodexRecoveryState() async throws {
        let fixture = try Fixture()
        let profile = fixture.root.appendingPathComponent("profile", isDirectory: true)
        let sessions = profile.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("skill_extra_roots = [\"/private/meeting\"]".utf8).write(
            to: profile.appendingPathComponent("config.toml")
        )
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let cleaner = DefaultMeetingSessionResourceCleaner(
            privateRoot: fixture.meetingRoot,
            journal: journal,
            applicationRoot: fixture.root,
            stableCodexProfileRoot: profile
        )

        let report = await cleaner.deleteResources(preserveCodexRecoveryState: true)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.path))
        XCTAssertEqual(
            try String(
                contentsOf: profile.appendingPathComponent("config.toml"),
                encoding: .utf8
            ),
            CodexIsolatedRuntimeBuilder.configurationText(
                permissionProfileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID
            )
        )
    }

    func testDecodedJournalEntriesAreRevalidatedBeforeCleanup() async throws {
        let fixture = try Fixture()
        let meetingID = UUID()
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root
        )
        let tampered = CleanupJournalEntry(
            meetingID: meetingID,
            profileID: "personal",
            privateRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
            snapshotRoots: [URL(fileURLWithPath: "/tmp/chirpcue-outside")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([tampered]).write(to: fixture.journalURL)

        do {
            _ = try await journal.entries()
            XCTFail("Expected tampered journal rejection.")
        } catch let error as CleanupJournalError {
            XCTAssertEqual(error, .pathOutsidePrivateRoot)
        }
    }

    func testProductionJournalRequiresExactMeetingIDRoot() async throws {
        let fixture = try Fixture()
        let meetingID = UUID()
        let journal = try CleanupJournalStore(
            journalURL: fixture.journalURL,
            allowedRoot: fixture.root,
            requireDirectMeetingRoot: true
        )

        do {
            try await journal.begin(
                CleanupJournalEntry(
                    meetingID: meetingID,
                    profileID: "personal",
                    privateRoot: fixture.meetingRoot
                )
            )
            XCTFail("Expected exact meeting-root rejection.")
        } catch let error as CleanupJournalError {
            XCTAssertEqual(error, .pathOutsidePrivateRoot)
        }

        let exactRoot = fixture.root.appendingPathComponent(
            meetingID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exactRoot, withIntermediateDirectories: false)
        try await journal.begin(
            CleanupJournalEntry(
                meetingID: meetingID,
                profileID: "personal",
                privateRoot: exactRoot
            )
        )
        let persistedMeetingIDs = try await journal.entries().map(\.meetingID)
        XCTAssertEqual(persistedMeetingIDs, [meetingID])
    }

    func testPrivacyAuditFailsClosedOnEntryAndByteBudgets() throws {
        let fixture = try Fixture()
        try Data("12345678".utf8).write(to: fixture.root.appendingPathComponent("one.txt"))
        try Data("abcdefgh".utf8).write(to: fixture.root.appendingPathComponent("two.txt"))

        XCTAssertThrowsError(
            try PrivacyAuditor(
                limits: .init(maximumEntryCount: 1)
            ).scan(root: fixture.root, sensitiveNeedles: [])
        ) { error in
            XCTAssertEqual(
                error as? PrivacyAuditError,
                .resourceLimitExceeded(.entryCount)
            )
        }

        XCTAssertThrowsError(
            try PrivacyAuditor(
                limits: .init(maximumFileBytes: 4)
            ).scan(root: fixture.root, sensitiveNeedles: [])
        ) { error in
            XCTAssertEqual(
                error as? PrivacyAuditError,
                .resourceLimitExceeded(.fileBytes)
            )
        }
    }
}

private actor CleanupClient: ThreadCleanupClient {
    private(set) var deleted: Set<String> = []

    func deleteThread(id: String) async throws {
        deleted.insert(id)
    }

    func threadIDs(cwd: URL) async throws -> [String] {
        ["thread-by-cwd"]
    }
}

private actor JournalWriteBlockingCleanupClient: ThreadCleanupClient {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func deleteThread(id: String) async throws {}

    func threadIDs(cwd: URL) async throws -> [String] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        return []
    }
}

private struct FailingThreadDiscoveryClient: ThreadCleanupClient {
    func deleteThread(id: String) async throws {}

    func threadIDs(cwd: URL) async throws -> [String] {
        throw CleanupJournalError.meetingNotFound
    }
}

private actor MissingThreadCleanupClient: ThreadCleanupClient {
    private(set) var deleteAttempts = 0

    func deleteThread(id: String) async throws {
        deleteAttempts += 1
        throw CodexClientError.requestFailed(method: "thread/delete", code: -32_600)
    }

    func threadIDs(cwd: URL) async throws -> [String] { [] }
}

private struct PresentRejectedThreadCleanupClient: ThreadCleanupClient {
    func deleteThread(id: String) async throws {
        throw CodexClientError.requestFailed(method: "thread/delete", code: -32_600)
    }

    func threadIDs(cwd: URL) async throws -> [String] { ["persisted-thread"] }
}

private final class Fixture {
    let root: URL
    let meetingRoot: URL
    let journalURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PaceNoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        meetingRoot = root.appending(path: "meeting", directoryHint: .isDirectory)
        journalURL = root.appending(path: "cleanup.json")
        try FileManager.default.createDirectory(at: meetingRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
