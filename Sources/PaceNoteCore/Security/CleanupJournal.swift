import Foundation

public struct CleanupJournalEntry: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let profileID: String
    public let privateRoot: URL
    public var snapshotRoots: [URL]
    public var expectedThreadCwds: [URL]
    public var threadIDs: [String]
    public let createdAt: Date

    public init(
        meetingID: UUID,
        profileID: String,
        privateRoot: URL,
        snapshotRoots: [URL] = [],
        expectedThreadCwds: [URL] = [],
        threadIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.meetingID = meetingID
        self.profileID = profileID
        self.privateRoot = privateRoot.standardizedFileURL
        self.snapshotRoots = snapshotRoots.map(\.standardizedFileURL)
        self.expectedThreadCwds = expectedThreadCwds.map(\.standardizedFileURL)
        self.threadIDs = threadIDs
        self.createdAt = createdAt
    }

    public var requiresCodexCleanup: Bool {
        !threadIDs.isEmpty || !expectedThreadCwds.isEmpty
    }
}

public actor CleanupJournalStore {
    private let journalURL: URL
    private let allowedRoot: URL
    private let fileManager: FileManager

    public init(journalURL: URL, allowedRoot: URL, fileManager: FileManager = .default) throws {
        self.journalURL = journalURL.standardizedFileURL
        self.allowedRoot = allowedRoot.standardizedFileURL
        self.fileManager = fileManager
        try Self.requireContained(self.journalURL, inside: self.allowedRoot)
        try fileManager.createDirectory(
            at: self.journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func entries() throws -> [CleanupJournalEntry] {
        guard fileManager.fileExists(atPath: journalURL.path) else { return [] }
        let data = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CleanupJournalEntry].self, from: data)
    }

    public func begin(_ entry: CleanupJournalEntry) throws {
        try validate(entry)
        var current = try entries()
        current.removeAll { $0.meetingID == entry.meetingID }
        current.append(entry)
        try write(current)
    }

    public func merge(_ entry: CleanupJournalEntry) throws {
        try validate(entry)
        var current = try entries()
        if let index = current.firstIndex(where: { $0.meetingID == entry.meetingID }) {
            guard current[index].profileID == entry.profileID,
                current[index].privateRoot == entry.privateRoot
            else {
                throw CleanupJournalError.meetingConflict
            }
            for root in entry.snapshotRoots where !current[index].snapshotRoots.contains(root) {
                current[index].snapshotRoots.append(root)
            }
            for cwd in entry.expectedThreadCwds
            where !current[index].expectedThreadCwds.contains(cwd) {
                current[index].expectedThreadCwds.append(cwd)
            }
            for threadID in entry.threadIDs where !current[index].threadIDs.contains(threadID) {
                current[index].threadIDs.append(threadID)
            }
            try validate(current[index])
        } else {
            current.append(entry)
        }
        try write(current)
    }

    public func recordSnapshot(_ snapshotRoot: URL, meetingID: UUID) throws {
        let standardized = snapshotRoot.standardizedFileURL
        try Self.requireContained(standardized, inside: allowedRoot)
        try mutate(meetingID: meetingID) { entry in
            if !entry.snapshotRoots.contains(standardized) { entry.snapshotRoots.append(standardized) }
        }
    }

    public func recordExpectedThreadCwd(_ cwd: URL, meetingID: UUID) throws {
        let standardized = cwd.standardizedFileURL
        try Self.requireContained(standardized, inside: allowedRoot)
        try mutate(meetingID: meetingID) { entry in
            if !entry.expectedThreadCwds.contains(standardized) { entry.expectedThreadCwds.append(standardized) }
        }
    }

    public func recordThread(_ threadID: String, meetingID: UUID) throws {
        guard Self.isOpaqueIdentifier(threadID) else { throw CleanupJournalError.invalidThreadIdentifier }
        try mutate(meetingID: meetingID) { entry in
            if !entry.threadIDs.contains(threadID) { entry.threadIDs.append(threadID) }
        }
    }

    public func removeThread(_ threadID: String, meetingID: UUID) throws {
        guard Self.isOpaqueIdentifier(threadID) else { throw CleanupJournalError.invalidThreadIdentifier }
        try mutate(meetingID: meetingID) { entry in
            entry.threadIDs.removeAll { $0 == threadID }
        }
    }

    public func remove(meetingID: UUID) throws {
        var current = try entries()
        current.removeAll { $0.meetingID == meetingID }
        try write(current)
    }

    public func removeAll() throws {
        try write([])
    }

    private func mutate(meetingID: UUID, body: (inout CleanupJournalEntry) -> Void) throws {
        var current = try entries()
        guard let index = current.firstIndex(where: { $0.meetingID == meetingID }) else {
            throw CleanupJournalError.meetingNotFound
        }
        body(&current[index])
        try validate(current[index])
        try write(current)
    }

    private func validate(_ entry: CleanupJournalEntry) throws {
        try Self.requireContained(entry.privateRoot, inside: allowedRoot)
        for url in entry.snapshotRoots + entry.expectedThreadCwds {
            try Self.requireContained(url, inside: entry.privateRoot)
        }
        guard entry.threadIDs.allSatisfy(Self.isOpaqueIdentifier) else {
            throw CleanupJournalError.invalidThreadIdentifier
        }
        guard entry.profileID.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
            throw CleanupJournalError.invalidProfileIdentifier
        }
    }

    private func write(_ entries: [CleanupJournalEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: journalURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private static func requireContained(_ child: URL, inside root: URL) throws {
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard childPath == rootPath || childPath.hasPrefix(rootPath + "/") else {
            throw CleanupJournalError.pathOutsidePrivateRoot
        }
    }

    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._:-]{1,160}$"#, options: .regularExpression) != nil
    }
}

public enum CleanupJournalError: Error, Equatable, Sendable {
    case meetingNotFound
    case meetingConflict
    case pathOutsidePrivateRoot
    case invalidThreadIdentifier
    case invalidProfileIdentifier
}
