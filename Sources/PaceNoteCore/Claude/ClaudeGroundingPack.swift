import Foundation

public struct ClaudeGroundingExcerpt: Codable, Equatable, Sendable {
    public let repoAlias: String
    public let relativePath: String
    public let lineNumber: Int
    public let fileHash: String
    public let exactLine: String

    public init(
        repoAlias: String,
        relativePath: String,
        lineNumber: Int,
        fileHash: String,
        exactLine: String
    ) {
        self.repoAlias = repoAlias
        self.relativePath = relativePath
        self.lineNumber = lineNumber
        self.fileHash = fileHash
        self.exactLine = exactLine
    }
}

public struct ClaudeGroundingPack: Codable, Equatable, Sendable {
    public let repoAlias: String
    public let groundingFingerprint: String
    public let excerpts: [ClaudeGroundingExcerpt]

    public init(
        repoAlias: String,
        groundingFingerprint: String,
        excerpts: [ClaudeGroundingExcerpt]
    ) {
        self.repoAlias = repoAlias
        self.groundingFingerprint = groundingFingerprint
        self.excerpts = excerpts
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func contains(_ reference: EvidenceReference) -> Bool {
        excerpts.contains { excerpt in
            guard excerpt.repoAlias == reference.repoAlias,
                excerpt.relativePath == reference.relativePath,
                excerpt.lineNumber == reference.startLine,
                excerpt.lineNumber == reference.endLine,
                excerpt.fileHash == reference.fileHash
            else {
                return false
            }
            let line = excerpt.exactLine.trimmingCharacters(in: .whitespaces)
            let claim = reference.claim.trimmingCharacters(in: .whitespaces)
            if line == claim { return true }
            return Self.withoutLeadingMarker(line) == claim
        }
    }

    private static func withoutLeadingMarker(_ line: String) -> String {
        let markers = ["///", "//", "#", "*", "-", "+"]
        for marker in markers where line.hasPrefix(marker) {
            return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

public struct ClaudeGroundingPackLimits: Equatable, Sendable {
    public let maximumExcerptCount: Int
    public let maximumLineBytes: Int
    public let maximumPackBytes: Int
    public let maximumQueryTerms: Int

    public init(
        maximumExcerptCount: Int = 12,
        maximumLineBytes: Int = 512,
        maximumPackBytes: Int = 16 * 1_024,
        maximumQueryTerms: Int = 64
    ) {
        self.maximumExcerptCount = max(0, maximumExcerptCount)
        self.maximumLineBytes = max(0, maximumLineBytes)
        self.maximumPackBytes = max(0, maximumPackBytes)
        self.maximumQueryTerms = max(0, maximumQueryTerms)
    }
}

public enum ClaudeGroundingPackError: Error, Equatable, Sendable {
    case turnMismatch
    case staleSnapshot
    case unsafeSnapshot
    case packLimitExceeded
}

public protocol ClaudeGroundingPackBuilding: Sendable {
    func pack(
        for turn: ConversationTurn,
        snapshot: GroundingSnapshot
    ) async throws -> ClaudeGroundingPack
}

public struct ClaudeGroundingPackBuilder: ClaudeGroundingPackBuilding {
    private struct Candidate: Sendable {
        let score: Int
        let excerpt: ClaudeGroundingExcerpt
    }

    private let limits: ClaudeGroundingPackLimits
    private let groundingLimits: GroundingResourceLimits

    public init(
        limits: ClaudeGroundingPackLimits = .init(),
        groundingLimits: GroundingResourceLimits = .init()
    ) {
        self.limits = limits
        self.groundingLimits = groundingLimits
    }

    public func pack(
        for turn: ConversationTurn,
        snapshot: GroundingSnapshot
    ) async throws -> ClaudeGroundingPack {
        guard turn.repoAlias == snapshot.repoAlias,
            turn.groundingFingerprint == snapshot.groundingFingerprint
        else {
            throw ClaudeGroundingPackError.turnMismatch
        }
        guard snapshot.snapshotRoot.isFileURL,
            snapshot.snapshotRoot.path.hasPrefix("/"),
            snapshot.snapshotRoot.resolvingSymlinksInPath().standardizedFileURL
                == snapshot.snapshotRoot.standardizedFileURL
        else {
            throw ClaudeGroundingPackError.unsafeSnapshot
        }

        let queryTerms = Self.queryTerms(for: turn, maximum: limits.maximumQueryTerms)
        let fileSecurity = GroundingFileSecurity()
        let budget = GroundingResourceBudget(limits: groundingLimits)
        var candidates: [Candidate] = []

        for entry in snapshot.manifest.entries where !Self.isControlPath(entry.relativePath) {
            try Task.checkCancellation()
            try budget.checkDeadline()
            let bytes: GroundingFileSecurity.SecureBytes
            do {
                bytes = try fileSecurity.secureRead(
                    root: snapshot.snapshotRoot,
                    relativePath: entry.relativePath,
                    maximumByteCount: groundingLimits.maximumFileBytes,
                    budget: budget
                )
            } catch {
                throw ClaudeGroundingPackError.staleSnapshot
            }
            guard bytes.hash == entry.sha256, bytes.byteCount == entry.byteCount else {
                throw ClaudeGroundingPackError.staleSnapshot
            }
            guard !bytes.data.contains(0), let text = String(data: bytes.data, encoding: .utf8) else {
                continue
            }

            let pathTerms = Self.tokens(in: entry.relativePath)
            let pathOverlap = queryTerms.intersection(pathTerms).count
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, rawLine) in lines.enumerated() {
                try Task.checkCancellation()
                var line = String(rawLine)
                if line.hasSuffix("\r") { line.removeLast() }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                    line.utf8.count <= limits.maximumLineBytes,
                    !line.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
                            .contains($0)
                    })
                else {
                    continue
                }
                let overlap = queryTerms.intersection(Self.tokens(in: line)).count
                guard overlap > 0 || pathOverlap > 0 else { continue }
                let score = overlap * 1_000 + pathOverlap * 100 + min(trimmed.utf8.count, 99)
                candidates.append(
                    Candidate(
                        score: score,
                        excerpt: ClaudeGroundingExcerpt(
                            repoAlias: snapshot.repoAlias,
                            relativePath: entry.relativePath,
                            lineNumber: index + 1,
                            fileHash: entry.sha256,
                            exactLine: line
                        )
                    )
                )
                if candidates.count >= 4_096 {
                    candidates.sort(by: Self.precedes)
                    candidates.removeSubrange(2_048..<candidates.count)
                }
            }
        }

        candidates.sort(by: Self.precedes)

        var selected: [ClaudeGroundingExcerpt] = []
        for candidate in candidates {
            guard selected.count < limits.maximumExcerptCount else { break }
            let proposed = selected + [candidate.excerpt]
            let pack = ClaudeGroundingPack(
                repoAlias: snapshot.repoAlias,
                groundingFingerprint: snapshot.groundingFingerprint,
                excerpts: proposed
            )
            guard let encoded = try? pack.jsonData(), encoded.count <= limits.maximumPackBytes else {
                continue
            }
            selected = proposed
        }

        let result = ClaudeGroundingPack(
            repoAlias: snapshot.repoAlias,
            groundingFingerprint: snapshot.groundingFingerprint,
            excerpts: selected
        )
        guard (try result.jsonData()).count <= limits.maximumPackBytes else {
            throw ClaudeGroundingPackError.packLimitExceeded
        }
        return result
    }

    private static func queryTerms(
        for turn: ConversationTurn,
        maximum: Int
    ) -> Set<String> {
        let transcript = turn.recentTranscript.suffix(6).map(\.text).joined(separator: " ")
        return Set(tokens(in: turn.question + " " + transcript).prefix(maximum))
    }

    private static func tokens(in value: String) -> [String] {
        let lowered = value.lowercased()
        var result: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value == 95 {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.utf8.count >= 2, !stopWords.contains(current) { result.append(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.utf8.count >= 2, !stopWords.contains(current) { result.append(current) }
        return Array(Set(result)).sorted()
    }

    private static func isControlPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: lower).lastPathComponent
        let components = lower.split(separator: "/").map(String.init)
        return (name.hasPrefix("agents.") && name.hasSuffix(".md"))
            || (name.hasPrefix("claude.") && name.hasSuffix(".md"))
            || name == "skill.md"
            || name == ".mcp.json"
            || name == "copilot-instructions.md"
            || name == ".cursorrules"
            || name == "gemini.md"
            || components.contains("agents")
            || components.contains("hooks")
            || components.contains("plugins")
            || components.contains("skills")
            || components.contains(".skills")
            || components.contains(".plugins")
            || components.contains(".hooks")
            || components.contains(".claude-plugin")
            || lower.hasPrefix(".claude/")
            || lower.hasPrefix(".agents/")
            || lower.hasPrefix(".codex/")
            || lower.contains("/.claude/")
            || lower.contains("/.agents/")
            || lower.contains("/.codex/")
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.excerpt.relativePath != rhs.excerpt.relativePath {
            return lhs.excerpt.relativePath.utf8.lexicographicallyPrecedes(
                rhs.excerpt.relativePath.utf8
            )
        }
        return lhs.excerpt.lineNumber < rhs.excerpt.lineNumber
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "because", "before", "but",
        "can", "could", "does", "for", "from", "have", "how", "into", "its", "just",
        "more", "our", "should", "that", "the", "their", "then", "there", "these", "they",
        "this", "those", "through", "use", "using", "want", "what", "when", "where", "which",
        "will", "with", "would", "you", "your",
    ]
}
