import CryptoKit
import Foundation

public struct ResidualDataFinding: Equatable, Sendable {
    public let relativePath: String
    public let needleHash: String

    public init(relativePath: String, needleHash: String) {
        self.relativePath = relativePath
        self.needleHash = needleHash
    }
}

public enum PrivacyAuditError: Error, Equatable, Sendable {
    case unsafeEntry(String)
    case resourceLimitExceeded(PrivacyAuditResourceLimit)
}

public enum PrivacyAuditResourceLimit: String, Equatable, Sendable {
    case entryCount
    case depth
    case fileBytes
    case aggregateBytes
    case findingCount
    case deadline
}

public struct PrivacyAuditLimits: Equatable, Sendable {
    public let maximumEntryCount: Int
    public let maximumDepth: Int
    public let maximumFileBytes: UInt64
    public let maximumAggregateBytes: UInt64
    public let maximumFindingCount: Int
    public let maximumDuration: TimeInterval

    public init(
        maximumEntryCount: Int = 5_000,
        maximumDepth: Int = 64,
        maximumFileBytes: UInt64 = 32 * 1_024 * 1_024,
        maximumAggregateBytes: UInt64 = 128 * 1_024 * 1_024,
        maximumFindingCount: Int = 4_096,
        maximumDuration: TimeInterval = 10
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumDepth = max(1, maximumDepth)
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumAggregateBytes = max(1, maximumAggregateBytes)
        self.maximumFindingCount = max(1, maximumFindingCount)
        self.maximumDuration = max(0.001, maximumDuration)
    }
}

public struct PrivacyAuditor {
    private let fileManager: FileManager
    private let limits: PrivacyAuditLimits
    private let now: @Sendable () -> TimeInterval

    public init(
        fileManager: FileManager = .default,
        limits: PrivacyAuditLimits = .init(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.now = now
    }

    public func scan(root: URL, sensitiveNeedles: [Data]) throws -> [ResidualDataFinding] {
        guard root.isFileURL else { return [] }
        let standardizedRoot = root.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard standardizedRoot == resolvedRoot else {
            throw PrivacyAuditError.unsafeEntry(".")
        }
        let needles = sensitiveNeedles.filter { $0.count >= 8 }
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: resolvedRoot,
                includingPropertiesForKeys: keys,
                options: []
            )
        else { return [] }

        let deadline = now() + limits.maximumDuration
        var findings: [ResidualDataFinding] = []
        var entryCount = 0
        var aggregateBytes: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard now() <= deadline else {
                throw PrivacyAuditError.resourceLimitExceeded(.deadline)
            }
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw PrivacyAuditError.resourceLimitExceeded(.entryCount)
            }
            let standardizedFile = fileURL.standardizedFileURL
            guard standardizedFile.path.hasPrefix(resolvedRoot.path + "/") else {
                throw PrivacyAuditError.unsafeEntry(fileURL.lastPathComponent)
            }
            let relativePath = String(
                standardizedFile.path.dropFirst(resolvedRoot.path.count + 1)
            )
            guard relativePath.split(separator: "/").count <= limits.maximumDepth else {
                throw PrivacyAuditError.resourceLimitExceeded(.depth)
            }
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw PrivacyAuditError.unsafeEntry(relativePath)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw PrivacyAuditError.unsafeEntry(relativePath)
            }
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw PrivacyAuditError.unsafeEntry(relativePath)
            }
            let fileBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileBytes <= limits.maximumFileBytes else {
                throw PrivacyAuditError.resourceLimitExceeded(.fileBytes)
            }
            let (nextAggregate, overflow) = aggregateBytes.addingReportingOverflow(fileBytes)
            guard !overflow, nextAggregate <= limits.maximumAggregateBytes else {
                throw PrivacyAuditError.resourceLimitExceeded(.aggregateBytes)
            }
            aggregateBytes = nextAggregate
            for needle in try Self.matchedNeedles(
                in: fileURL,
                needles: needles,
                deadline: deadline,
                now: now
            ) {
                guard findings.count < limits.maximumFindingCount else {
                    throw PrivacyAuditError.resourceLimitExceeded(.findingCount)
                }
                findings.append(
                    ResidualDataFinding(
                        relativePath: relativePath,
                        needleHash: SHA256.hash(data: needle).prefix(8).map { String(format: "%02x", $0) }.joined()
                    ))
            }
        }
        return findings
    }

    private static func matchedNeedles(
        in fileURL: URL,
        needles: [Data],
        deadline: TimeInterval,
        now: @Sendable () -> TimeInterval
    ) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let overlapCount = max(0, (needles.map(\.count).max() ?? 1) - 1)
        var remaining = needles
        var overlap = Data()

        while !remaining.isEmpty,
            let chunk = try handle.read(upToCount: 1_048_576),
            !chunk.isEmpty
        {
            guard now() <= deadline else {
                throw PrivacyAuditError.resourceLimitExceeded(.deadline)
            }
            var searchable = overlap
            searchable.append(chunk)
            remaining.removeAll { searchable.range(of: $0) != nil }
            overlap = Data(searchable.suffix(min(overlapCount, searchable.count)))
        }
        let remainingSet = Set(remaining)
        return needles.filter { !remainingSet.contains($0) }
    }
}
