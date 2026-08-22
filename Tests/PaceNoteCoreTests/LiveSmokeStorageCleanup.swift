import Darwin
import Foundation

enum LiveSmokeStorageCleanupError: Error, Equatable {
    case invalidOwnedRoot
    case unsafeOwnedRoot
    case ownedRootDeletionFailed
    case emptyParentDeletionFailed(Int32)
}

/// Removes one opt-in smoke fixture and then atomically removes its shared parent only when empty.
///
/// `FileManager.removeItem` is deliberately never used for the shared parent. Another opt-in smoke
/// may create a sibling between inspection and deletion, so POSIX `rmdir` provides the required
/// atomic "empty only" behavior.
enum LiveSmokeStorageCleanup {
    static func removeOwnedRoot(
        _ ownedRoot: URL,
        applicationRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let applicationRoot = applicationRoot.standardizedFileURL
        let smokeTestsRoot =
            applicationRoot
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent("SmokeTests", isDirectory: true)
            .standardizedFileURL
        let ownedRoot = ownedRoot.standardizedFileURL

        guard applicationRoot.isFileURL,
            applicationRoot.path.hasPrefix("/"),
            !applicationRoot.path.contains("\0"),
            ownedRoot.isFileURL,
            ownedRoot.path.hasPrefix(smokeTestsRoot.path + "/"),
            ownedRoot.deletingLastPathComponent().standardizedFileURL == smokeTestsRoot,
            !ownedRoot.lastPathComponent.isEmpty
        else {
            throw LiveSmokeStorageCleanupError.invalidOwnedRoot
        }

        if fileManager.fileExists(atPath: ownedRoot.path) {
            let values = try ownedRoot.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LiveSmokeStorageCleanupError.unsafeOwnedRoot
            }
            do {
                try fileManager.removeItem(at: ownedRoot)
            } catch {
                throw LiveSmokeStorageCleanupError.ownedRootDeletionFailed
            }
        }
        guard !fileManager.fileExists(atPath: ownedRoot.path) else {
            throw LiveSmokeStorageCleanupError.ownedRootDeletionFailed
        }

        errno = 0
        guard rmdir(smokeTestsRoot.path) != 0 else { return }
        let code = errno
        guard code != ENOENT, code != ENOTEMPTY, code != EEXIST else { return }
        throw LiveSmokeStorageCleanupError.emptyParentDeletionFailed(code)
    }
}
