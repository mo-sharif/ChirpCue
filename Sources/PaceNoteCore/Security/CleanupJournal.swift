import Darwin
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
    private static let maximumJournalBytes = 1_048_576
    private static let maximumEntries = 128
    private static let maximumValuesPerEntry = 256

    private let journalURL: URL
    private let allowedRoot: URL
    private let requireDirectMeetingRoot: Bool
    private let fileManager: FileManager

    public init(
        journalURL: URL,
        allowedRoot: URL,
        requireDirectMeetingRoot: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        self.journalURL = journalURL.standardizedFileURL
        self.allowedRoot = allowedRoot.standardizedFileURL
        self.requireDirectMeetingRoot = requireDirectMeetingRoot
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: self.journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func entries() throws -> [CleanupJournalEntry] {
        guard fileManager.fileExists(atPath: journalURL.path) else { return [] }
        let data = try Self.readValidatedJournal(at: journalURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([CleanupJournalEntry].self, from: data)
        guard decoded.count <= Self.maximumEntries else {
            throw CleanupJournalError.resourceLimitExceeded
        }
        guard Set(decoded.map(\.meetingID)).count == decoded.count else {
            throw CleanupJournalError.duplicateMeeting
        }
        for entry in decoded { try validate(entry) }
        return decoded
    }

    public func validateForCleanup(_ entry: CleanupJournalEntry) throws {
        try validate(entry)
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

    public func recordThreads(_ threadIDs: [String], meetingID: UUID) throws {
        guard threadIDs.allSatisfy(Self.isOpaqueIdentifier) else {
            throw CleanupJournalError.invalidThreadIdentifier
        }
        try mutate(meetingID: meetingID) { entry in
            for threadID in threadIDs where !entry.threadIDs.contains(threadID) {
                entry.threadIDs.append(threadID)
            }
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
        if requireDirectMeetingRoot {
            let expected = allowedRoot.appendingPathComponent(
                entry.meetingID.uuidString.lowercased(),
                isDirectory: true
            ).standardizedFileURL
            guard entry.privateRoot.standardizedFileURL == expected else {
                throw CleanupJournalError.pathOutsidePrivateRoot
            }
        }
        guard entry.snapshotRoots.count <= Self.maximumValuesPerEntry,
            entry.expectedThreadCwds.count <= Self.maximumValuesPerEntry,
            entry.threadIDs.count <= Self.maximumValuesPerEntry
        else {
            throw CleanupJournalError.resourceLimitExceeded
        }
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
        guard entries.count <= Self.maximumEntries else {
            throw CleanupJournalError.resourceLimitExceeded
        }
        for entry in entries { try validate(entry) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        guard data.count <= Self.maximumJournalBytes else {
            throw CleanupJournalError.resourceLimitExceeded
        }
        try data.write(to: journalURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private static func readValidatedJournal(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CleanupJournalError.invalidJournalFile }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1,
            status.st_uid == getuid(),
            status.st_size >= 0,
            status.st_size <= maximumJournalBytes
        else {
            throw CleanupJournalError.invalidJournalFile
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CleanupJournalError.invalidJournalFile
            }
            guard data.count + count <= maximumJournalBytes else {
                throw CleanupJournalError.resourceLimitExceeded
            }
            data.append(buffer, count: count)
        }
        return data
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
    case invalidJournalFile
    case duplicateMeeting
    case resourceLimitExceeded
}
