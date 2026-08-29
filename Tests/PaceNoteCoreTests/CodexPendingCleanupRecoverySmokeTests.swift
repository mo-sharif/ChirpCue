import Foundation
import XCTest

@testable import PaceNoteCore

final class CodexPendingCleanupRecoverySmokeTests: XCTestCase {
    func testRecoverExactJournaledMeetingStateWithoutGeneration() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_RECOVER_PENDING_CLEANUP"] == "1" else {
            throw XCTSkip(
                "Set PACENOTE_RECOVER_PENDING_CLEANUP=1 to recover exact journaled ChirpCue meeting state without model generation."
            )
        }

        let fileManager = FileManager.default
        let supportRoot = try XCTUnwrap(
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let applicationRoot = supportRoot.appendingPathComponent("PaceNote", isDirectory: true)
        let meetingsRoot = applicationRoot.appendingPathComponent("Meetings", isDirectory: true)
        let profileRoot = applicationRoot.appendingPathComponent(
            "Profiles/personal",
            isDirectory: true
        )
        let journal = try CleanupJournalStore(
            journalURL: applicationRoot.appendingPathComponent(
                "State/cleanup-journal.json",
                isDirectory: false
            ),
            allowedRoot: meetingsRoot
        )
        let entries = try await journal.entries()

        let profileLease = try CodexProfileLease.acquire(profileRoot: profileRoot)
        defer { withExtendedLifetime(profileLease) {} }
        guard !entries.isEmpty else {
            _ = try CodexStableProfileSanitizer().cleanTransientState(profileRoot: profileRoot)
            return
        }
        let temporaryRoot = applicationRoot.appendingPathComponent(
            "State/recovery-codex-tmp",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let isolated = try CodexIsolatedRuntimeBuilder.prepare(
            profileRoot: profileRoot,
            temporaryRoot: temporaryRoot,
            codexExecutableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
            )
        )
        let client = try await CodexAppServerClient.connect(
            configuration: .init(
                executableURL: URL(
                    fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
                ),
                expectedCodexHome: isolated.profileRoot,
                requestTimeout: .seconds(20),
                clientVersion: "cleanup-recovery",
                permissionProfileID: isolated.permissionProfileID,
                processArguments: isolated.processArguments,
                processEnvironment: isolated.processEnvironment
            )
        )
        let account = try await client.account(refreshToken: false)
        guard account.account?.type == "chatgpt" else {
            await client.shutdown()
            throw PendingCleanupRecoveryError.nonChatGPTAccount
        }

        let report = await CleanupJanitor(journal: journal).run(
            client: PendingCleanupClient(client: client),
            clearJournalOnSuccess: false
        )
        await client.shutdown()
        guard report.failures.isEmpty else {
            XCTFail(
                "Pending cleanup failed at: \(report.failures.map(\.resource).joined(separator: ", "))."
            )
            throw PendingCleanupRecoveryError.cleanupFailed
        }

        for entry in entries {
            if fileManager.fileExists(atPath: entry.privateRoot.path) {
                try fileManager.removeItem(at: entry.privateRoot)
            }
            try await journal.remove(meetingID: entry.meetingID)
        }
        _ = try CodexStableProfileSanitizer().cleanTransientState(profileRoot: profileRoot)
        let remainingEntries = try await journal.entries()
        XCTAssertTrue(remainingEntries.isEmpty)
    }
}

private struct PendingCleanupClient: ThreadCleanupClient {
    let client: CodexAppServerClient

    func deleteThread(id: String) async throws {
        try await client.deleteThread(id: id)
    }

    func threadIDs(cwd: URL) async throws -> [String] {
        try await client.listThreadIDs(cwd: cwd.path)
    }
}

private enum PendingCleanupRecoveryError: Error {
    case nonChatGPTAccount
    case cleanupFailed
}
