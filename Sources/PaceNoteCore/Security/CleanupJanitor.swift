import Foundation

public protocol ThreadCleanupClient: Sendable {
    /// Deletes the thread and succeeds when its rollout was already removed.
    /// Codex `thread/delete` defines missing rollout files as already deleted.
    func deleteThread(id: String) async throws
    func threadIDs(cwd: URL) async throws -> [String]
}

public struct CleanupFailure: Equatable, Sendable {
    public let resource: String
    public let reason: String

    public init(resource: String, reason: String) {
        self.resource = resource
        self.reason = reason
    }
}

public struct CleanupReport: Equatable, Sendable {
    public var deletedThreadCount = 0
    public var deletedSnapshotCount = 0
    public var failures: [CleanupFailure] = []

    public init() {}
}

public actor CleanupJanitor {
    private let journal: CleanupJournalStore
    private let fileManager: FileManager

    public init(journal: CleanupJournalStore, fileManager: FileManager = .default) {
        self.journal = journal
        self.fileManager = fileManager
    }

    public func run(
        client: any ThreadCleanupClient,
        meetingID: UUID? = nil,
        clearJournalOnSuccess: Bool = true
    ) async -> CleanupReport {
        var report = CleanupReport()
        let allEntries: [CleanupJournalEntry]
        do {
            allEntries = try await journal.entries()
        } catch {
            report.failures.append(.init(resource: "cleanup-journal", reason: Self.safe(error)))
            return report
        }
        let entries = allEntries.filter { meetingID == nil || $0.meetingID == meetingID }

        for entry in entries {
            let failuresBeforeEntry = report.failures.count
            do {
                try await journal.validateForCleanup(entry)
            } catch {
                report.failures.append(.init(resource: "cleanup-journal", reason: Self.safe(error)))
                continue
            }
            var threadIDs = Set(entry.threadIDs)
            for cwd in entry.expectedThreadCwds {
                do {
                    threadIDs.formUnion(try await client.threadIDs(cwd: cwd))
                } catch {
                    report.failures.append(.init(resource: "thread-cwd", reason: Self.safe(error)))
                }
            }

            for threadID in threadIDs {
                do {
                    try await client.deleteThread(id: threadID)
                    report.deletedThreadCount += 1
                    try await journal.removeThread(threadID, meetingID: entry.meetingID)
                } catch {
                    // Ephemeral forks can disappear when their originating app-server exits.
                    // Current Codex reports an error if a later cleanup client deletes that
                    // already-absent ID, so reconcile against every sealed meeting cwd before
                    // keeping the journal blocked.
                    let absenceConfirmed: Bool
                    do {
                        absenceConfirmed = try await Self.threadIsAbsent(
                            threadID,
                            expectedCwds: entry.expectedThreadCwds,
                            client: client
                        )
                    } catch {
                        absenceConfirmed = false
                    }
                    guard absenceConfirmed else {
                        report.failures.append(
                            .init(resource: "thread", reason: Self.safe(error))
                        )
                        continue
                    }
                    do {
                        try await journal.removeThread(threadID, meetingID: entry.meetingID)
                    } catch {
                        report.failures.append(
                            .init(resource: "cleanup-journal", reason: Self.safe(error))
                        )
                    }
                }
            }

            guard report.failures.count == failuresBeforeEntry else {
                continue
            }

            for snapshot in entry.snapshotRoots {
                do {
                    try await journal.validateForCleanup(entry)
                    guard Self.isContained(snapshot, inside: entry.privateRoot) else {
                        throw CleanupJournalError.pathOutsidePrivateRoot
                    }
                    if fileManager.fileExists(atPath: snapshot.path) {
                        try fileManager.removeItem(at: snapshot)
                        report.deletedSnapshotCount += 1
                    }
                } catch {
                    report.failures.append(.init(resource: "snapshot", reason: Self.safe(error)))
                }
            }

            if clearJournalOnSuccess, report.failures.count == failuresBeforeEntry {
                do {
                    try await journal.remove(meetingID: entry.meetingID)
                } catch {
                    report.failures.append(
                        .init(resource: "cleanup-journal", reason: Self.safe(error))
                    )
                }
            }
        }
        return report
    }

    /// Removes only Codex threads for one active meeting. The meeting journal and
    /// every disposable filesystem root remain available to the active session.
    public func runThreadOnly(
        client: any ThreadCleanupClient,
        meetingID: UUID
    ) async -> CleanupReport {
        var report = CleanupReport()
        let entry: CleanupJournalEntry
        do {
            let entries = try await journal.entries()
            guard let matchingEntry = entries.first(where: { $0.meetingID == meetingID }) else {
                throw CleanupJournalError.meetingNotFound
            }
            try await journal.validateForCleanup(matchingEntry)
            entry = matchingEntry
        } catch {
            report.failures.append(.init(resource: "cleanup-journal", reason: Self.safe(error)))
            return report
        }

        var threadIDs = Set(entry.threadIDs)
        do {
            for cwd in entry.expectedThreadCwds {
                threadIDs.formUnion(try await client.threadIDs(cwd: cwd))
            }
        } catch {
            report.failures.append(.init(resource: "thread-cwd", reason: Self.safe(error)))
            return report
        }

        do {
            try await journal.recordThreads(threadIDs.sorted(), meetingID: meetingID)
        } catch {
            report.failures.append(.init(resource: "cleanup-journal", reason: Self.safe(error)))
            return report
        }

        for threadID in threadIDs.sorted() {
            do {
                try await client.deleteThread(id: threadID)
                report.deletedThreadCount += 1
            } catch let deletionError {
                do {
                    guard
                        try await Self.threadIsAbsent(
                            threadID,
                            expectedCwds: entry.expectedThreadCwds,
                            client: client
                        )
                    else {
                        report.failures.append(
                            .init(resource: "thread", reason: Self.safe(deletionError))
                        )
                        continue
                    }
                } catch {
                    report.failures.append(.init(resource: "thread-cwd", reason: Self.safe(error)))
                    continue
                }
            }

            do {
                try await journal.removeThread(threadID, meetingID: meetingID)
            } catch {
                report.failures.append(.init(resource: "cleanup-journal", reason: Self.safe(error)))
            }
        }

        return report
    }

    private static func threadIsAbsent(
        _ threadID: String,
        expectedCwds: [URL],
        client: any ThreadCleanupClient
    ) async throws -> Bool {
        guard !expectedCwds.isEmpty else { return false }
        for cwd in expectedCwds where try await client.threadIDs(cwd: cwd).contains(threadID) {
            return false
        }
        return true
    }

    private static func isContained(_ child: URL, inside root: URL) -> Bool {
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return childPath.hasPrefix(rootPath + "/")
    }

    private static func safe(_ error: any Error) -> String {
        String(describing: error).prefix(120).description
    }
}
