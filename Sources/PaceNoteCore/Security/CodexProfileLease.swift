import Darwin
import Foundation

public enum CodexProfileLeaseError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfileRoot
    case invalidLockFile
    case alreadyInUse
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidProfileRoot, .invalidLockFile:
            "PrismCue rejected an unsafe Codex profile lock path."
        case .alreadyInUse:
            "The dedicated PrismCue Codex profile is already in use. Quit PrismCue and any live probe before trying again."
        case .unavailable:
            "PrismCue could not acquire exclusive access to its dedicated Codex profile."
        }
    }
}

/// Holds an advisory lock for the lifetime of one PrismCue profile owner.
///
/// The lock file is a stable sibling of the profile rather than a child of it, so profile
/// sanitization cannot remove the locked inode. The file intentionally remains on disk after
/// release; unlinking it would allow a second process to lock a different inode at the same path.
public final class CodexProfileLease: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    public static func acquire(profileRoot: URL) throws -> CodexProfileLease {
        let standardized = profileRoot.standardizedFileURL
        guard standardized.isFileURL,
            standardized.path.hasPrefix("/"),
            !standardized.path.contains("\0")
        else {
            throw CodexProfileLeaseError.invalidProfileRoot
        }

        let profileName = standardized.lastPathComponent
        guard !profileName.isEmpty,
            profileName != ".",
            profileName != "..",
            profileName.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            })
        else {
            throw CodexProfileLeaseError.invalidProfileRoot
        }

        let profilesRoot = standardized.deletingLastPathComponent().standardizedFileURL
        var parentStatus = stat()
        guard lstat(profilesRoot.path, &parentStatus) == 0,
            parentStatus.st_mode & S_IFMT == S_IFDIR,
            parentStatus.st_uid == geteuid(),
            profilesRoot.resolvingSymlinksInPath().standardizedFileURL == profilesRoot
        else {
            throw CodexProfileLeaseError.invalidProfileRoot
        }

        let lockURL = profilesRoot.appendingPathComponent(
            ".\(profileName).lock",
            isDirectory: false
        )
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw CodexProfileLeaseError.invalidLockFile
            }
            throw CodexProfileLeaseError.unavailable
        }

        var ownsDescriptor = true
        defer {
            if ownsDescriptor { _ = close(descriptor) }
        }

        var lockStatus = stat()
        guard fstat(descriptor, &lockStatus) == 0,
            lockStatus.st_mode & S_IFMT == S_IFREG,
            lockStatus.st_nlink == 1,
            lockStatus.st_uid == geteuid(),
            fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
        else {
            throw CodexProfileLeaseError.invalidLockFile
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw CodexProfileLeaseError.alreadyInUse
            }
            throw CodexProfileLeaseError.unavailable
        }

        ownsDescriptor = false
        return CodexProfileLease(descriptor: descriptor)
    }
}
