import Foundation

public struct GroundingManifestEntry: Codable, Hashable, Sendable {
    public let relativePath: String
    public let byteCount: UInt64
    public let sha256: String

    public init(relativePath: String, byteCount: UInt64, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct GroundingManifest: Codable, Equatable, Sendable {
    public let entries: [GroundingManifestEntry]
    public let fingerprint: String

    public init(entries: [GroundingManifestEntry]) {
        let ordered = entries.sorted { lhs, rhs in
            lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
        self.entries = ordered
        self.fingerprint = GroundingDigest.manifest(ordered)
    }

    public subscript(relativePath: String) -> GroundingManifestEntry? {
        entries.first { $0.relativePath == relativePath }
    }
}

public struct SoftSuspiciousFinding: Codable, Hashable, Sendable {
    public let relativePath: String
    public let contentHash: String
    public let ruleIDs: [String]

    public init(relativePath: String, contentHash: String, ruleIDs: [String]) {
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.ruleIDs = ruleIDs.sorted()
    }
}

public struct SoftSuspiciousApproval: Codable, Hashable, Sendable {
    public let relativePath: String
    public let contentHash: String
    public let ruleIDs: [String]

    public init(relativePath: String, contentHash: String, ruleIDs: [String]) {
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.ruleIDs = ruleIDs.sorted()
    }

    public init(approving finding: SoftSuspiciousFinding) {
        self.init(
            relativePath: finding.relativePath,
            contentHash: finding.contentHash,
            ruleIDs: finding.ruleIDs
        )
    }
}

public enum HardExclusionReason: String, Codable, Sendable {
    case repositoryMetadata
    case dependencyCache
    case buildOutput
    case oversizedFile
    case environmentFile
    case privateKey
    case credentialStore
    case tokenFile
    case secretContent
    case dump
}

public struct HardExcludedPath: Codable, Hashable, Sendable {
    public let relativePath: String
    public let reason: HardExclusionReason

    public init(relativePath: String, reason: HardExclusionReason) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

public enum GroundingInstructionKind: String, Codable, Sendable {
    case standard
    case override
}

public struct GroundingInstructionSource: Codable, Hashable, Sendable {
    public let relativePath: String
    public let scopeRelativePath: String
    public let fileHash: String
    public let kind: GroundingInstructionKind

    public init(
        relativePath: String,
        scopeRelativePath: String,
        fileHash: String,
        kind: GroundingInstructionKind
    ) {
        self.relativePath = relativePath
        self.scopeRelativePath = scopeRelativePath
        self.fileHash = fileHash
        self.kind = kind
    }
}

public struct GroundingInspection: Codable, Equatable, Sendable {
    public let branch: String
    public let head: String
    public let worktreeFingerprint: String
    public let manifest: GroundingManifest
    public let groundingFingerprint: String
    public let hardExclusions: [HardExcludedPath]
    public let softFindings: [SoftSuspiciousFinding]
    public let acceptedApprovals: [SoftSuspiciousApproval]
    public let instructionSources: [GroundingInstructionSource]

    public init(
        branch: String,
        head: String,
        worktreeFingerprint: String,
        manifest: GroundingManifest,
        groundingFingerprint: String,
        hardExclusions: [HardExcludedPath],
        softFindings: [SoftSuspiciousFinding],
        acceptedApprovals: [SoftSuspiciousApproval],
        instructionSources: [GroundingInstructionSource]
    ) {
        self.branch = branch
        self.head = head
        self.worktreeFingerprint = worktreeFingerprint
        self.manifest = manifest
        self.groundingFingerprint = groundingFingerprint
        self.hardExclusions = hardExclusions
        self.softFindings = softFindings
        self.acceptedApprovals = acceptedApprovals
        self.instructionSources = instructionSources
    }

    public func effectiveInstructionSources(for relativePath: String) -> [GroundingInstructionSource] {
        let directory = GroundingPath.parent(of: relativePath)
        let applicable = instructionSources.filter { instruction in
            instruction.scopeRelativePath.isEmpty
                || directory == instruction.scopeRelativePath
                || directory.hasPrefix(instruction.scopeRelativePath + "/")
        }

        return Dictionary(grouping: applicable, by: \.scopeRelativePath)
            .values
            .compactMap { sourcesAtScope in
                sourcesAtScope.first(where: { $0.kind == .override })
                    ?? sourcesAtScope.first(where: { $0.kind == .standard })
            }
            .sorted { lhs, rhs in
                let lhsDepth = GroundingPath.depth(lhs.scopeRelativePath)
                let rhsDepth = GroundingPath.depth(rhs.scopeRelativePath)
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return lhs.relativePath < rhs.relativePath
            }
    }
}

public struct GroundingSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let repoAlias: String
    public let sourceRoot: URL
    public let snapshotRoot: URL
    public let createdAt: Date
    public let inspection: GroundingInspection

    public init(
        id: UUID,
        repoAlias: String,
        sourceRoot: URL,
        snapshotRoot: URL,
        createdAt: Date,
        inspection: GroundingInspection
    ) {
        self.id = id
        self.repoAlias = repoAlias
        self.sourceRoot = sourceRoot
        self.snapshotRoot = snapshotRoot
        self.createdAt = createdAt
        self.inspection = inspection
    }

    public var manifest: GroundingManifest { inspection.manifest }
    public var groundingFingerprint: String { inspection.groundingFingerprint }

    public func effectiveInstructionSources(for relativePath: String) -> [GroundingInstructionSource] {
        inspection.effectiveInstructionSources(for: relativePath)
    }
}

public enum GroundingSnapshotStage: Equatable, Sendable {
    case sourceManifestSealed
    case willCopyFile(String)
    case snapshotCopied
    case willRecheckSource
}

public protocol GroundingSnapshotObserver: Sendable {
    func didReach(
        _ stage: GroundingSnapshotStage,
        attempt: Int,
        sourceRoot: URL,
        snapshotRoot: URL?
    ) async throws
}

public struct NoopGroundingSnapshotObserver: GroundingSnapshotObserver {
    public init() {}

    public func didReach(
        _ stage: GroundingSnapshotStage,
        attempt: Int,
        sourceRoot: URL,
        snapshotRoot: URL?
    ) async throws {}
}

public struct GroundingResourceLimits: Equatable, Sendable {
    public let maximumFileBytes: UInt64
    public let maximumFileCount: Int
    public let maximumAcceptedBytes: UInt64
    public let maximumScannedBytes: UInt64
    public let maximumTraversalEntries: Int
    public let maximumGitOutputBytes: Int
    public let gitCommandTimeout: TimeInterval
    public let maximumGroundingDuration: TimeInterval

    public init(
        maximumFileBytes: UInt64 = 8 * 1_024 * 1_024,
        maximumFileCount: Int = 5_000,
        maximumAcceptedBytes: UInt64 = 32 * 1_024 * 1_024,
        maximumScannedBytes: UInt64 = 192 * 1_024 * 1_024,
        maximumTraversalEntries: Int = 50_000,
        maximumGitOutputBytes: Int = 8 * 1_024 * 1_024,
        gitCommandTimeout: TimeInterval = 10,
        maximumGroundingDuration: TimeInterval = 30
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumFileCount = max(0, maximumFileCount)
        self.maximumAcceptedBytes = maximumAcceptedBytes
        self.maximumScannedBytes = maximumScannedBytes
        self.maximumTraversalEntries = max(0, maximumTraversalEntries)
        self.maximumGitOutputBytes = max(0, maximumGitOutputBytes)
        self.gitCommandTimeout =
            gitCommandTimeout.isFinite
            ? max(0.1, gitCommandTimeout)
            : 10
        self.maximumGroundingDuration =
            maximumGroundingDuration.isFinite
            ? max(0, maximumGroundingDuration)
            : 30
    }
}

public struct GroundingConfiguration: Sendable {
    public let snapshotParentDirectory: URL?
    public let maximumSnapshotRetries: Int
    public let resourceLimits: GroundingResourceLimits

    public init(
        snapshotParentDirectory: URL? = nil,
        maximumSnapshotRetries: Int = 2,
        resourceLimits: GroundingResourceLimits = .init()
    ) {
        self.snapshotParentDirectory = snapshotParentDirectory
        self.maximumSnapshotRetries = max(0, maximumSnapshotRetries)
        self.resourceLimits = resourceLimits
    }
}

public enum GroundingResourceLimit: String, Codable, Sendable {
    case fileBytes
    case fileCount
    case aggregateAcceptedBytes
    case aggregateScannedBytes
    case traversalEntries
    case gitOutputBytes
    case gitCommandTimeout
    case groundingDeadline
}

final class GroundingResourceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: GroundingResourceLimits
    private let deadlineUptime: TimeInterval
    private var scannedBytes: UInt64 = 0
    private var traversalEntries = 0

    init(limits: GroundingResourceLimits) {
        self.limits = limits
        self.deadlineUptime =
            ProcessInfo.processInfo.systemUptime + limits.maximumGroundingDuration
    }

    func checkDeadline() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkDeadlineWhileLocked()
    }

    func chargeScannedBytes(_ byteCount: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkDeadlineWhileLocked()
        let (next, overflow) = scannedBytes.addingReportingOverflow(byteCount)
        guard !overflow, next <= limits.maximumScannedBytes else {
            throw GroundingError.resourceLimitExceeded(.aggregateScannedBytes)
        }
        scannedBytes = next
    }

    func chargeTraversalEntry() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkDeadlineWhileLocked()
        guard traversalEntries < limits.maximumTraversalEntries else {
            throw GroundingError.resourceLimitExceeded(.traversalEntries)
        }
        traversalEntries += 1
    }

    private func checkDeadlineWhileLocked() throws {
        guard ProcessInfo.processInfo.systemUptime < deadlineUptime else {
            throw GroundingError.resourceLimitExceeded(.groundingDeadline)
        }
    }
}

public enum UnsafeFileKind: String, Codable, Sendable {
    case symbolicLink
    case hardLink
    case directory
    case socket
    case device
    case fifo
    case nonRegular
}

public enum GroundingError: Error, Equatable, Sendable {
    case notGitRepository
    case gitCommandFailed(String)
    case invalidRepositoryRoot
    case invalidRelativePath(String)
    case resourceLimitExceeded(GroundingResourceLimit)
    case unsafeFile(relativePath: String, kind: UnsafeFileKind)
    case unreadableFile(String)
    case sourceChangedDuringSnapshot
    case snapshotBusy
    case cannotCreatePrivateSnapshot
    case snapshotNotOwned
}

extension GroundingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notGitRepository:
            "The selected folder is not a Git repository."
        case .gitCommandFailed(let operation):
            "Git could not complete the \(operation) operation."
        case .invalidRepositoryRoot:
            "The selected repository root is invalid."
        case .invalidRelativePath(let path):
            "The repository returned an unsafe relative path: \(path)"
        case .resourceLimitExceeded(let limit):
            "The repository exceeded the configured \(limit.rawValue) grounding limit."
        case .unsafeFile(let path, let kind):
            "The repository contains an unsupported \(kind.rawValue) entry: \(path)"
        case .unreadableFile(let path):
            "The repository entry could not be read safely: \(path)"
        case .sourceChangedDuringSnapshot:
            "The repository changed while its snapshot was being created."
        case .snapshotBusy:
            "The repository remained unstable across all snapshot attempts."
        case .cannotCreatePrivateSnapshot:
            "A private snapshot directory could not be created."
        case .snapshotNotOwned:
            "The snapshot is not owned by this grounding manager."
        }
    }
}

enum GroundingPath {
    static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    static func depth(_ relativePath: String) -> Int {
        guard !relativePath.isEmpty else { return 0 }
        return relativePath.split(separator: "/").count
    }
}
