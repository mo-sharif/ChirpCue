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
}

public struct PrivacyAuditor {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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

        var findings: [ResidualDataFinding] = []
        for case let fileURL as URL in enumerator {
            let standardizedFile = fileURL.standardizedFileURL
            guard standardizedFile.path.hasPrefix(resolvedRoot.path + "/") else {
                throw PrivacyAuditError.unsafeEntry(fileURL.lastPathComponent)
            }
            let relativePath = String(
                standardizedFile.path.dropFirst(resolvedRoot.path.count + 1)
            )
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
            for needle in try Self.matchedNeedles(in: fileURL, needles: needles) {
                findings.append(
                    ResidualDataFinding(
                        relativePath: relativePath,
                        needleHash: SHA256.hash(data: needle).prefix(8).map { String(format: "%02x", $0) }.joined()
                    ))
            }
        }
        return findings
    }

    private static func matchedNeedles(in fileURL: URL, needles: [Data]) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let overlapCount = max(0, (needles.map(\.count).max() ?? 1) - 1)
        var remaining = needles
        var overlap = Data()

        while !remaining.isEmpty,
            let chunk = try handle.read(upToCount: 1_048_576),
            !chunk.isEmpty
        {
            var searchable = overlap
            searchable.append(chunk)
            remaining.removeAll { searchable.range(of: $0) != nil }
            overlap = Data(searchable.suffix(min(overlapCount, searchable.count)))
        }
        let remainingSet = Set(remaining)
        return needles.filter { !remainingSet.contains($0) }
    }
}
