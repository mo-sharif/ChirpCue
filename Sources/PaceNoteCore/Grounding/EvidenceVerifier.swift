import Foundation

public struct VerifiedEvidence: Equatable, Sendable {
    public let reference: EvidenceReference
    public let excerpt: String
    public let instructionSources: [GroundingInstructionSource]

    public init(
        reference: EvidenceReference,
        excerpt: String,
        instructionSources: [GroundingInstructionSource]
    ) {
        self.reference = reference
        self.excerpt = excerpt
        self.instructionSources = instructionSources
    }
}

public enum EvidenceVerificationError: Error, Equatable, Sendable {
    case groundingFingerprintMismatch
    case repositoryAliasMismatch(String)
    case invalidPath(String)
    case pathNotIncluded(String)
    case referenceHashMismatch(String)
    case snapshotChanged
    case sourceChanged
    case invalidLineRange(String)
    case nonUTF8Evidence(String)
    case instructionSourcesMismatch(String)
    case claimNotSupported(String)
    case candidateNotSupported
}

extension EvidenceVerificationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .groundingFingerprintMismatch:
            "The answer was produced from a different grounding snapshot."
        case .repositoryAliasMismatch(let path):
            "The evidence repository alias does not match for \(path)."
        case .invalidPath(let path):
            "The evidence path is invalid: \(path)"
        case .pathNotIncluded(let path):
            "The evidence path is absent from the sealed snapshot: \(path)"
        case .referenceHashMismatch(let path):
            "The evidence hash does not match the sealed manifest: \(path)"
        case .snapshotChanged:
            "The sealed snapshot changed after it was accepted."
        case .sourceChanged:
            "The source repository changed after grounding."
        case .invalidLineRange(let path):
            "The evidence line range is invalid: \(path)"
        case .nonUTF8Evidence(let path):
            "The cited evidence is not UTF-8 text: \(path)"
        case .instructionSourcesMismatch(let path):
            "The Deep thread used a different instruction scope for \(path)."
        case .claimNotSupported(let path):
            "The claim does not exactly match a complete cited source line: \(path)"
        case .candidateNotSupported:
            "The suggested response does not exactly match a locally verified evidence claim."
        }
    }
}

public actor EvidenceVerifier {
    private let fileSecurity = GroundingFileSecurity()
    private let limits: GroundingResourceLimits
    private let git: GitRepositoryReader

    public init(limits: GroundingResourceLimits = .init()) {
        self.limits = limits
        self.git = GitRepositoryReader(limits: limits)
    }

    public func verify(
        _ references: [EvidenceReference],
        groundingFingerprint: String,
        instructionSources: [GroundingInstructionSource],
        against snapshot: GroundingSnapshot
    ) throws -> [VerifiedEvidence] {
        let budget = GroundingResourceBudget(limits: limits)
        return try verifyReferences(
            references,
            groundingFingerprint: groundingFingerprint,
            instructionSourcesFor: { _ in instructionSources },
            against: snapshot,
            budget: budget
        )
    }

    private func verifyReferences(
        _ references: [EvidenceReference],
        groundingFingerprint: String,
        instructionSourcesFor: (EvidenceReference) -> [GroundingInstructionSource],
        against snapshot: GroundingSnapshot,
        budget: GroundingResourceBudget
    ) throws -> [VerifiedEvidence] {
        try budget.checkDeadline()
        guard groundingFingerprint == snapshot.groundingFingerprint else {
            throw EvidenceVerificationError.groundingFingerprintMismatch
        }

        for reference in references {
            do {
                try fileSecurity.validate(relativePath: reference.relativePath)
            } catch {
                throw EvidenceVerificationError.invalidPath(reference.relativePath)
            }
            guard reference.repoAlias == snapshot.repoAlias else {
                throw EvidenceVerificationError.repositoryAliasMismatch(reference.relativePath)
            }
            guard let manifestEntry = snapshot.manifest[reference.relativePath] else {
                throw EvidenceVerificationError.pathNotIncluded(reference.relativePath)
            }
            guard reference.fileHash == manifestEntry.sha256 else {
                throw EvidenceVerificationError.referenceHashMismatch(reference.relativePath)
            }
        }

        let currentSnapshotManifest: GroundingManifest
        do {
            currentSnapshotManifest = try manifest(root: snapshot.snapshotRoot, budget: budget)
        } catch {
            throw EvidenceVerificationError.snapshotChanged
        }
        guard currentSnapshotManifest == snapshot.manifest else {
            throw EvidenceVerificationError.snapshotChanged
        }

        var sourceBytesByPath: [String: GroundingFileSecurity.SecureBytes] = [:]
        for reference in references {
            try budget.checkDeadline()
            let sourceBytes: GroundingFileSecurity.SecureBytes
            do {
                sourceBytes = try fileSecurity.secureRead(
                    root: snapshot.sourceRoot,
                    relativePath: reference.relativePath,
                    maximumByteCount: limits.maximumFileBytes,
                    budget: budget
                )
            } catch {
                throw EvidenceVerificationError.sourceChanged
            }
            guard sourceBytes.hash == reference.fileHash else {
                throw EvidenceVerificationError.sourceChanged
            }
            sourceBytesByPath[reference.relativePath] = sourceBytes
        }

        let currentInspection: GroundingInspection
        do {
            currentInspection = try GroundingSourceBuilder().build(
                root: snapshot.sourceRoot,
                approvals: Set(snapshot.inspection.acceptedApprovals),
                git: git,
                fileSecurity: fileSecurity,
                limits: limits,
                budget: budget
            )
        } catch {
            throw EvidenceVerificationError.sourceChanged
        }
        guard currentInspection == snapshot.inspection else {
            throw EvidenceVerificationError.sourceChanged
        }

        return try references.map { reference in
            try budget.checkDeadline()
            let effectiveInstructions = snapshot.effectiveInstructionSources(for: reference.relativePath)
            guard effectiveInstructions == instructionSourcesFor(reference) else {
                throw EvidenceVerificationError.instructionSourcesMismatch(reference.relativePath)
            }

            let snapshotBytes: GroundingFileSecurity.SecureBytes
            do {
                snapshotBytes = try fileSecurity.secureRead(
                    root: snapshot.snapshotRoot,
                    relativePath: reference.relativePath,
                    maximumByteCount: limits.maximumFileBytes,
                    budget: budget
                )
            } catch {
                throw EvidenceVerificationError.snapshotChanged
            }
            guard snapshotBytes.hash == reference.fileHash,
                sourceBytesByPath[reference.relativePath]?.hash == snapshotBytes.hash
            else {
                throw EvidenceVerificationError.snapshotChanged
            }

            let excerpt = try extractLines(
                from: snapshotBytes.data,
                startLine: reference.startLine,
                endLine: reference.endLine,
                relativePath: reference.relativePath
            )
            guard plausiblySupports(claim: reference.claim, excerpt: excerpt) else {
                throw EvidenceVerificationError.claimNotSupported(reference.relativePath)
            }
            return VerifiedEvidence(
                reference: reference,
                excerpt: excerpt,
                instructionSources: effectiveInstructions
            )
        }
    }

    /// Verifies both the model-supplied basis and the exact statement displayed to the user.
    /// The candidate must match one fully supported basis claim after every reference has been
    /// re-read from the sealed snapshot and matched to the unchanged source repository.
    public func verifyAnswer(
        candidateSayNext: String,
        references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot
    ) throws -> [VerifiedEvidence] {
        let budget = GroundingResourceBudget(limits: limits)
        let verified = try verifyReferences(
            references,
            groundingFingerprint: groundingFingerprint,
            instructionSourcesFor: {
                snapshot.effectiveInstructionSources(for: $0.relativePath)
            },
            against: snapshot,
            budget: budget
        )

        guard exactlyMatchesVerifiedClaim(candidate: candidateSayNext, evidence: verified) else {
            throw EvidenceVerificationError.candidateNotSupported
        }
        return verified
    }

    /// Converts a model-supplied citation into one exact, locally re-read source line. The model's
    /// claim text is ignored; only its bounded path, hash, and line range are used as a locator.
    public func verifiedExtractiveFallback(
        references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot,
        maximumWords: Int
    ) throws -> EvidenceReference? {
        guard references.count <= 6, (1...33).contains(maximumWords) else { return nil }

        for reference in references {
            do {
                try fileSecurity.validate(relativePath: reference.relativePath)
            } catch {
                throw EvidenceVerificationError.invalidPath(reference.relativePath)
            }
            guard let manifestEntry = snapshot.manifest[reference.relativePath] else {
                throw EvidenceVerificationError.pathNotIncluded(reference.relativePath)
            }
            guard reference.fileHash == manifestEntry.sha256 else {
                throw EvidenceVerificationError.referenceHashMismatch(reference.relativePath)
            }
            guard reference.startLine >= 1,
                reference.endLine >= reference.startLine,
                reference.endLine - reference.startLine < 8
            else {
                throw EvidenceVerificationError.invalidLineRange(reference.relativePath)
            }

            let budget = GroundingResourceBudget(limits: limits)
            let bytes: GroundingFileSecurity.SecureBytes
            do {
                bytes = try fileSecurity.secureRead(
                    root: snapshot.snapshotRoot,
                    relativePath: reference.relativePath,
                    maximumByteCount: limits.maximumFileBytes,
                    budget: budget
                )
            } catch {
                throw EvidenceVerificationError.snapshotChanged
            }
            guard bytes.hash == reference.fileHash else {
                throw EvidenceVerificationError.snapshotChanged
            }

            for lineNumber in reference.startLine...reference.endLine {
                let line = try extractLines(
                    from: bytes.data,
                    startLine: lineNumber,
                    endLine: lineNumber,
                    relativePath: reference.relativePath
                )
                for claim in exactSourceClaims(from: line) {
                    guard claim.split(whereSeparator: { $0.isWhitespace }).count <= maximumWords,
                        informativeTerms(in: claim).count >= 2
                    else {
                        continue
                    }
                    let corrected = EvidenceReference(
                        repoAlias: snapshot.repoAlias,
                        relativePath: reference.relativePath,
                        startLine: lineNumber,
                        endLine: lineNumber,
                        fileHash: reference.fileHash,
                        claim: claim
                    )
                    do {
                        _ = try verifyAnswer(
                            candidateSayNext: claim,
                            references: [corrected],
                            groundingFingerprint: groundingFingerprint,
                            against: snapshot
                        )
                        return corrected
                    } catch let error as EvidenceVerificationError {
                        switch error {
                        case .claimNotSupported, .candidateNotSupported:
                            continue
                        default:
                            throw error
                        }
                    }
                }
            }
        }
        return nil
    }

    public func isFresh(_ snapshot: GroundingSnapshot) -> Bool {
        let budget = GroundingResourceBudget(limits: limits)
        do {
            let snapshotManifest = try manifest(root: snapshot.snapshotRoot, budget: budget)
            guard snapshotManifest == snapshot.manifest else { return false }
            let source = try GroundingSourceBuilder().build(
                root: snapshot.sourceRoot,
                approvals: Set(snapshot.inspection.acceptedApprovals),
                git: git,
                fileSecurity: fileSecurity,
                limits: limits,
                budget: budget
            )
            return source == snapshot.inspection
        } catch {
            return false
        }
    }

    private func manifest(
        root: URL,
        budget: GroundingResourceBudget
    ) throws -> GroundingManifest {
        let paths = try fileSecurity.enumerateRegularFiles(
            root: root,
            maximumFileCount: limits.maximumFileCount,
            budget: budget
        )
        var acceptedBytes: UInt64 = 0
        var entries: [GroundingManifestEntry] = []
        entries.reserveCapacity(paths.count)
        for relativePath in paths {
            try budget.checkDeadline()
            let bytes = try fileSecurity.secureRead(
                root: root,
                relativePath: relativePath,
                maximumByteCount: limits.maximumFileBytes,
                budget: budget
            )
            let (newAcceptedBytes, overflow) = acceptedBytes.addingReportingOverflow(
                bytes.byteCount
            )
            guard !overflow, newAcceptedBytes <= limits.maximumAcceptedBytes else {
                throw GroundingError.resourceLimitExceeded(.aggregateAcceptedBytes)
            }
            acceptedBytes = newAcceptedBytes
            entries.append(
                GroundingManifestEntry(
                    relativePath: relativePath,
                    byteCount: bytes.byteCount,
                    sha256: bytes.hash
                ))
        }
        return GroundingManifest(entries: entries)
    }

    private func extractLines(
        from data: Data,
        startLine: Int,
        endLine: Int,
        relativePath: String
    ) throws -> String {
        guard startLine >= 1, endLine >= startLine else {
            throw EvidenceVerificationError.invalidLineRange(relativePath)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EvidenceVerificationError.nonUTF8Evidence(relativePath)
        }
        guard !text.isEmpty else {
            throw EvidenceVerificationError.invalidLineRange(relativePath)
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard endLine <= lines.count else {
            throw EvidenceVerificationError.invalidLineRange(relativePath)
        }
        return lines[(startLine - 1)...(endLine - 1)].joined(separator: "\n")
    }

    private func plausiblySupports(claim: String, excerpt: String) -> Bool {
        let claimTerms = informativeTerms(in: claim)
        guard claimTerms.count >= 2 else { return false }
        let normalizedClaim = normalizedStatement(claim)
        guard !normalizedClaim.isEmpty else { return false }
        return excerpt.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            evidenceLineCandidates(String(line)).contains(normalizedClaim)
        }
    }

    private func exactlyMatchesVerifiedClaim(
        candidate: String,
        evidence: [VerifiedEvidence]
    ) -> Bool {
        let normalizedCandidate = normalizedStatement(candidate)
        guard !normalizedCandidate.isEmpty else { return false }
        return evidence.contains {
            normalizedStatement($0.reference.claim) == normalizedCandidate
        }
    }

    private func informativeTerms(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "also", "an", "and", "are", "as", "at", "be", "because", "by", "can", "could",
            "for", "from", "has", "have", "here", "in", "into", "is", "it", "its", "just",
            "more", "of", "on", "or", "our", "really", "so", "specifically", "that", "the",
            "their", "them", "they", "this", "to", "was", "we", "were", "will", "with", "would",
            "you", "your",
        ]
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" ? Character(String(scalar)) : " "
        }
        return Set(
            String(scalars).lowercased().split(whereSeparator: { $0.isWhitespace })
                .map { canonicalTerm(String($0)) }
                .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private func normalizedStatement(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func evidenceLineCandidates(_ line: String) -> Set<String> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates: Set<String> = [normalizedStatement(trimmed)]
        let prefixes = ["///", "//", "/*", "*", "#", "-"]
        for prefix in prefixes {
            let decoratedPrefix = prefix + " "
            guard trimmed.hasPrefix(decoratedPrefix) else { continue }
            var undecorated = String(trimmed.dropFirst(decoratedPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            if prefix == "/*", undecorated.hasSuffix("*/") {
                undecorated = String(undecorated.dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
            }
            if !undecorated.isEmpty {
                candidates.insert(normalizedStatement(undecorated))
            }
            break
        }
        return candidates
    }

    private func exactSourceClaims(from line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var claims: [String] = []
        for prefix in ["///", "//", "/*", "*", "#", "-"] {
            let decoratedPrefix = prefix + " "
            guard trimmed.hasPrefix(decoratedPrefix) else { continue }
            var undecorated = String(trimmed.dropFirst(decoratedPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            if prefix == "/*", undecorated.hasSuffix("*/") {
                undecorated = String(undecorated.dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
            }
            if !undecorated.isEmpty { claims.append(undecorated) }
            break
        }
        claims.append(trimmed)
        var seen: Set<String> = []
        return claims.filter { seen.insert($0).inserted }
    }

    private func canonicalTerm(_ term: String) -> String {
        guard term.count > 4 else { return term }
        if term.hasSuffix("ies") {
            return String(term.dropLast(3)) + "y"
        }
        if term.hasSuffix("s") && !term.hasSuffix("ss") {
            return String(term.dropLast())
        }
        return term
    }
}
