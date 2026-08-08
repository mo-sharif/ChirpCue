import Foundation

public enum MeetingSessionCleanupFailure: String, Codable, CaseIterable, Sendable {
    case responseCleanup
    case snapshotDeletion
    case temporaryRootDeletion
    case stableProfileCleanup
    case residualAudit
    case residualData
    case privateRootDeletion
    case journalRemoval
}

public struct MeetingResourceCleanupReport: Equatable, Sendable {
    public let deletedSnapshotCount: Int
    public let deletedTemporaryRootCount: Int
    public let failures: [MeetingSessionCleanupFailure]

    public init(
        deletedSnapshotCount: Int = 0,
        deletedTemporaryRootCount: Int = 0,
        failures: [MeetingSessionCleanupFailure] = []
    ) {
        self.deletedSnapshotCount = deletedSnapshotCount
        self.deletedTemporaryRootCount = deletedTemporaryRootCount
        self.failures = failures
    }
}

public struct MeetingSessionStopReport: Equatable, Sendable {
    public let deletedThreadCount: Int
    public let deletedSnapshotCount: Int
    public let deletedTemporaryRootCount: Int
    public let residualFindingCount: Int
    public let journalEntryRemoved: Bool
    public let failures: [MeetingSessionCleanupFailure]

    public init(
        deletedThreadCount: Int,
        deletedSnapshotCount: Int,
        deletedTemporaryRootCount: Int,
        residualFindingCount: Int,
        journalEntryRemoved: Bool,
        failures: [MeetingSessionCleanupFailure]
    ) {
        self.deletedThreadCount = deletedThreadCount
        self.deletedSnapshotCount = deletedSnapshotCount
        self.deletedTemporaryRootCount = deletedTemporaryRootCount
        self.residualFindingCount = residualFindingCount
        self.journalEntryRemoved = journalEntryRemoved
        self.failures = failures
    }

    public var cleanupSucceeded: Bool {
        failures.isEmpty && residualFindingCount == 0 && journalEntryRemoved
    }
}

public protocol MeetingSessionResourceCleaning: Sendable {
    func deleteResources(preserveCodexRecoveryState: Bool) async -> MeetingResourceCleanupReport
    func residualFindingCount(sensitiveNeedles: [Data]) async throws -> Int
    func deletePrivateRoot() async throws
    func removeJournalEntry(meetingID: UUID) async throws
}

public actor DefaultMeetingSessionResourceCleaner: MeetingSessionResourceCleaning {
    private let privateRoot: URL
    private let temporaryRoots: [URL]
    private let groundingManager: GroundingManager?
    private let groundingSnapshot: GroundingSnapshot?
    private let journal: CleanupJournalStore
    private let applicationRoot: URL
    private let stableCodexProfileRoot: URL?
    private let fileManager: FileManager

    public init(
        privateRoot: URL,
        temporaryRoots: [URL] = [],
        groundingManager: GroundingManager? = nil,
        groundingSnapshot: GroundingSnapshot? = nil,
        journal: CleanupJournalStore,
        applicationRoot: URL? = nil,
        stableCodexProfileRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.privateRoot = privateRoot.standardizedFileURL
        self.temporaryRoots = temporaryRoots.map(\.standardizedFileURL)
        self.groundingManager = groundingManager
        self.groundingSnapshot = groundingSnapshot
        self.journal = journal
        self.applicationRoot =
            (applicationRoot ?? privateRoot.deletingLastPathComponent())
            .standardizedFileURL
        self.stableCodexProfileRoot = stableCodexProfileRoot?.standardizedFileURL
        self.fileManager = fileManager
    }

    public func deleteResources(
        preserveCodexRecoveryState: Bool
    ) async -> MeetingResourceCleanupReport {
        var deletedSnapshots = 0
        var deletedTemporaryRoots = 0
        var failures: [MeetingSessionCleanupFailure] = []
        var deletedPaths: Set<String> = []

        if let groundingSnapshot {
            do {
                guard Self.isStrictlyContained(groundingSnapshot.snapshotRoot, inside: privateRoot),
                    let groundingManager
                else {
                    throw GroundingError.snapshotNotOwned
                }
                try await groundingManager.deleteSnapshot(groundingSnapshot)
                deletedSnapshots += 1
                deletedPaths.insert(groundingSnapshot.snapshotRoot.standardizedFileURL.path)
            } catch {
                failures.append(.snapshotDeletion)
            }
        }

        for root in temporaryRoots {
            let path = root.standardizedFileURL.path
            guard !deletedPaths.contains(path) else { continue }
            do {
                guard Self.isStrictlyContained(root, inside: privateRoot) else {
                    throw CleanupJournalError.pathOutsidePrivateRoot
                }
                if fileManager.fileExists(atPath: path) {
                    try fileManager.removeItem(at: root)
                    deletedTemporaryRoots += 1
                }
            } catch {
                failures.append(.temporaryRootDeletion)
            }
        }

        if let stableCodexProfileRoot {
            do {
                guard Self.isStrictlyContained(stableCodexProfileRoot, inside: applicationRoot)
                else {
                    throw CodexStableProfileCleanupError.invalidProfileRoot
                }
                let sanitizer = CodexStableProfileSanitizer(fileManager: fileManager)
                if preserveCodexRecoveryState {
                    try sanitizer.restoreCanonicalConfiguration(
                        profileRoot: stableCodexProfileRoot
                    )
                } else {
                    let report = try sanitizer.cleanTransientState(
                        profileRoot: stableCodexProfileRoot
                    )
                    deletedTemporaryRoots += report.deletedEntryCount
                }
            } catch {
                failures.append(.stableProfileCleanup)
            }
        }

        return MeetingResourceCleanupReport(
            deletedSnapshotCount: deletedSnapshots,
            deletedTemporaryRootCount: deletedTemporaryRoots,
            failures: failures
        )
    }

    public func residualFindingCount(sensitiveNeedles: [Data]) throws -> Int {
        var findingCount = 0
        for root in [privateRoot] + (stableCodexProfileRoot.map { [$0] } ?? []) {
            guard Self.isStrictlyContained(root, inside: applicationRoot) else {
                throw CleanupJournalError.pathOutsidePrivateRoot
            }
            guard fileManager.fileExists(atPath: root.path) else { continue }
            findingCount += try PrivacyAuditor(fileManager: fileManager)
                .scan(root: root, sensitiveNeedles: sensitiveNeedles)
                .count
        }
        return findingCount
    }

    public func deletePrivateRoot() throws {
        guard Self.isStrictlyContained(privateRoot, inside: applicationRoot) else {
            throw CleanupJournalError.pathOutsidePrivateRoot
        }
        if fileManager.fileExists(atPath: privateRoot.path) {
            try fileManager.removeItem(at: privateRoot)
        }
    }

    public func removeJournalEntry(meetingID: UUID) async throws {
        try await journal.remove(meetingID: meetingID)
    }

    private static func isStrictlyContained(_ child: URL, inside root: URL) -> Bool {
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return childPath.hasPrefix(rootPath + "/")
    }
}
