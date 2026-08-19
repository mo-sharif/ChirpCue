import Foundation

public struct CodexStableProfileCleanupReport: Equatable, Sendable {
    public let deletedEntryCount: Int

    public init(deletedEntryCount: Int = 0) {
        self.deletedEntryCount = deletedEntryCount
    }
}

public enum CodexStableProfileCleanupError: Error, Equatable, Sendable {
    case invalidProfileRoot
    case unsafeEntry(String)
    case credentialMaterialPresent(String)
    case unexpectedEntry(String)
    case deletionFailed(String)
    case configurationRewriteFailed
}

public struct CodexStableProfileSanitizer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func cleanTransientState(
        profileRoot: URL
    ) throws -> CodexStableProfileCleanupReport {
        let root = try validatedProfileRoot(profileRoot)
        try restoreCanonicalConfiguration(profileRoot: root)

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var removable: [URL] = []

        for entry in entries {
            let name = entry.lastPathComponent
            let values = try entry.resourceValues(forKeys: keys)
            guard entry.deletingLastPathComponent().standardizedFileURL == root,
                values.isSymbolicLink != true
            else {
                throw CodexStableProfileCleanupError.unsafeEntry(name)
            }

            if Self.credentialEntryNames.contains(name) {
                throw CodexStableProfileCleanupError.credentialMaterialPresent(name)
            }
            if Self.transientDirectoryNames.contains(name) {
                guard values.isDirectory == true else {
                    throw CodexStableProfileCleanupError.unsafeEntry(name)
                }
                removable.append(entry)
                continue
            }
            if Self.transientFileNames.contains(name) {
                guard values.isRegularFile == true,
                    try hasSingleLink(entry)
                else {
                    throw CodexStableProfileCleanupError.unsafeEntry(name)
                }
                removable.append(entry)
                continue
            }
            if Self.persistentDirectoryNames.contains(name) {
                guard values.isDirectory == true else {
                    throw CodexStableProfileCleanupError.unsafeEntry(name)
                }
                try validateOwnedTree(entry, profileRoot: root)
                continue
            }
            if Self.persistentFileNames.contains(name) {
                guard values.isRegularFile == true,
                    try hasSingleLink(entry)
                else {
                    throw CodexStableProfileCleanupError.unsafeEntry(name)
                }
                continue
            }
            throw CodexStableProfileCleanupError.unexpectedEntry(name)
        }

        for entry in removable {
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                throw CodexStableProfileCleanupError.deletionFailed(entry.lastPathComponent)
            }
        }
        return CodexStableProfileCleanupReport(deletedEntryCount: removable.count)
    }

    public func restoreCanonicalConfiguration(profileRoot: URL) throws {
        let root = try validatedProfileRoot(profileRoot)
        for name in Self.credentialEntryNames
        where fileManager.fileExists(
            atPath: root.appendingPathComponent(name, isDirectory: false).path
        ) {
            throw CodexStableProfileCleanupError.credentialMaterialPresent(name)
        }

        let configurationURL = root.appendingPathComponent("config.toml", isDirectory: false)
        if fileManager.fileExists(atPath: configurationURL.path) {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: configurationURL.path)
            } catch {
                throw CodexStableProfileCleanupError.configurationRewriteFailed
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                configurationURL.resolvingSymlinksInPath().standardizedFileURL
                    == configurationURL.standardizedFileURL
            else {
                throw CodexStableProfileCleanupError.unsafeEntry("config.toml")
            }
        }

        do {
            let configuration = CodexIsolatedRuntimeBuilder.configurationText(
                permissionProfileID: CodexIsolatedRuntimeBuilder.defaultPermissionProfileID
            )
            try Data(configuration.utf8).write(to: configurationURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
        } catch let error as CodexStableProfileCleanupError {
            throw error
        } catch {
            throw CodexStableProfileCleanupError.configurationRewriteFailed
        }
    }

    private func validatedProfileRoot(_ profileRoot: URL) throws -> URL {
        let root = profileRoot.standardizedFileURL
        guard root.isFileURL,
            root.path.hasPrefix("/"),
            !root.path.contains("\0")
        else {
            throw CodexStableProfileCleanupError.invalidProfileRoot
        }

        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
            rootIsDirectory.boolValue,
            root.resolvingSymlinksInPath().standardizedFileURL == root
        else {
            throw CodexStableProfileCleanupError.invalidProfileRoot
        }
        return root
    }

    private func validateOwnedTree(_ treeRoot: URL, profileRoot: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: treeRoot,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        else {
            throw CodexStableProfileCleanupError.unsafeEntry(treeRoot.lastPathComponent)
        }

        for case let entry as URL in enumerator {
            let path = entry.standardizedFileURL.path
            let relativePath = String(path.dropFirst(profileRoot.path.count + 1))
            guard path.hasPrefix(profileRoot.path + "/") else {
                throw CodexStableProfileCleanupError.unsafeEntry(relativePath)
            }
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw CodexStableProfileCleanupError.unsafeEntry(relativePath)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true,
                try hasSingleLink(entry)
            else {
                throw CodexStableProfileCleanupError.unsafeEntry(relativePath)
            }
        }
    }

    private func hasSingleLink(_ file: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        return (attributes[.referenceCount] as? NSNumber)?.intValue == 1
    }

    // Evidence: these are the only top-level transient entries produced by the pinned
    // app-server after account/read, model, rate-limit, permission, and skill preflight
    // calls with zero generations.
    private static let transientDirectoryNames: Set<String> = [
        ".tmp", "cache", "plugins", "sessions", "shell_snapshots", "skills",
        "thread-writer-locks", "tmp",
    ]
    private static let transientFileNames: Set<String> = [
        ".sandbox_migration",
        "goals_1.sqlite", "goals_1.sqlite-shm", "goals_1.sqlite-wal",
        "logs_2.sqlite", "logs_2.sqlite-shm", "logs_2.sqlite-wal",
        "memories_1.sqlite", "memories_1.sqlite-shm", "memories_1.sqlite-wal",
        "models_cache.json",
        "queue_1.sqlite", "queue_1.sqlite-shm", "queue_1.sqlite-wal",
        "state_5.sqlite", "state_5.sqlite-shm", "state_5.sqlite-wal",
    ]
    private static let persistentDirectoryNames: Set<String> = []
    private static let persistentFileNames: Set<String> = ["config.toml", "installation_id"]
    private static let credentialEntryNames: Set<String> = [
        ".credentials.json", "auth.json", "credentials.json",
    ]
}
