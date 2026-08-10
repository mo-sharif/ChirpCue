import Foundation

public actor GroundingManager {
    private let configuration: GroundingConfiguration
    private let observer: any GroundingSnapshotObserver
    private let fileSecurity = GroundingFileSecurity()
    private let git: GitRepositoryReader
    private var ownedSnapshots: [UUID: URL] = [:]

    public init(
        configuration: GroundingConfiguration = .init(),
        observer: any GroundingSnapshotObserver = NoopGroundingSnapshotObserver()
    ) {
        self.configuration = configuration
        self.observer = observer
        self.git = GitRepositoryReader(limits: configuration.resourceLimits)
    }

    public func inspectRepository(
        at selectedRoot: URL,
        approvals: Set<SoftSuspiciousApproval> = []
    ) throws -> GroundingInspection {
        let budget = GroundingResourceBudget(limits: configuration.resourceLimits)
        let sourceRoot = try resolvedRepositoryRoot(selectedRoot, budget: budget)
        return try GroundingSourceBuilder().build(
            root: sourceRoot,
            approvals: approvals,
            git: git,
            fileSecurity: fileSecurity,
            limits: configuration.resourceLimits,
            budget: budget
        )
    }

    public func createSnapshot(
        repoAlias: String,
        sourceRoot selectedRoot: URL,
        approvals: Set<SoftSuspiciousApproval> = []
    ) async throws -> GroundingSnapshot {
        let budget = GroundingResourceBudget(limits: configuration.resourceLimits)
        let sourceRoot = try resolvedRepositoryRoot(selectedRoot, budget: budget)
        let parent =
            configuration.snapshotParentDirectory
            ?? FileManager.default.temporaryDirectory
            .appending(path: "PaceNote", directoryHint: .isDirectory)
            .appending(path: "Grounding", directoryHint: .isDirectory)
        try fileSecurity.createPrivateDirectory(parent)

        for attempt in 0...configuration.maximumSnapshotRetries {
            try budget.checkDeadline()
            var attemptRoot: URL?
            do {
                let sourceA = try GroundingSourceBuilder().build(
                    root: sourceRoot,
                    approvals: approvals,
                    git: git,
                    fileSecurity: fileSecurity,
                    limits: configuration.resourceLimits,
                    budget: budget
                )
                try await observer.didReach(
                    .sourceManifestSealed,
                    attempt: attempt,
                    sourceRoot: sourceRoot,
                    snapshotRoot: nil
                )
                try budget.checkDeadline()

                let snapshotID = UUID()
                let snapshotRoot = parent.appending(
                    path: snapshotID.uuidString.lowercased(),
                    directoryHint: .isDirectory
                )
                attemptRoot = snapshotRoot
                try fileSecurity.createPrivateDirectory(snapshotRoot)
                try await copy(
                    source: sourceRoot,
                    destination: snapshotRoot,
                    manifest: sourceA.manifest,
                    attempt: attempt,
                    budget: budget
                )

                try await observer.didReach(
                    .snapshotCopied,
                    attempt: attempt,
                    sourceRoot: sourceRoot,
                    snapshotRoot: snapshotRoot
                )
                try budget.checkDeadline()
                let snapshotManifest = try manifestForPrivateSnapshot(snapshotRoot, budget: budget)
                guard snapshotManifest == sourceA.manifest else {
                    throw GroundingError.sourceChangedDuringSnapshot
                }

                try await observer.didReach(
                    .willRecheckSource,
                    attempt: attempt,
                    sourceRoot: sourceRoot,
                    snapshotRoot: snapshotRoot
                )
                try budget.checkDeadline()
                let sourceB = try GroundingSourceBuilder().build(
                    root: sourceRoot,
                    approvals: approvals,
                    git: git,
                    fileSecurity: fileSecurity,
                    limits: configuration.resourceLimits,
                    budget: budget
                )
                guard sourceA == sourceB else {
                    throw GroundingError.sourceChangedDuringSnapshot
                }

                let snapshot = GroundingSnapshot(
                    id: snapshotID,
                    repoAlias: repoAlias,
                    sourceRoot: sourceRoot,
                    snapshotRoot: snapshotRoot,
                    createdAt: Date(),
                    inspection: sourceA
                )
                ownedSnapshots[snapshotID] = snapshotRoot
                return snapshot
            } catch GroundingError.sourceChangedDuringSnapshot {
                try removeAttemptSnapshot(attemptRoot)
                continue
            } catch let error as GroundingFileSecurity.ReadError {
                try removeAttemptSnapshot(attemptRoot)
                switch error {
                case .missing, .changed:
                    continue
                case .unsafe(let kind):
                    throw GroundingError.unsafeFile(relativePath: "<changed-entry>", kind: kind)
                case .exceedsByteLimit:
                    throw GroundingError.resourceLimitExceeded(.fileBytes)
                case .io:
                    throw GroundingError.cannotCreatePrivateSnapshot
                }
            } catch {
                try removeAttemptSnapshot(attemptRoot)
                throw error
            }
        }
        throw GroundingError.snapshotBusy
    }

    public func deleteSnapshot(_ snapshot: GroundingSnapshot) throws {
        guard let ownedRoot = ownedSnapshots[snapshot.id],
            ownedRoot.standardizedFileURL == snapshot.snapshotRoot.standardizedFileURL
        else {
            throw GroundingError.snapshotNotOwned
        }
        if FileManager.default.fileExists(atPath: ownedRoot.path) {
            try FileManager.default.removeItem(at: ownedRoot)
        }
        ownedSnapshots.removeValue(forKey: snapshot.id)
    }

    private func resolvedRepositoryRoot(
        _ selectedRoot: URL,
        budget: GroundingResourceBudget
    ) throws -> URL {
        try budget.checkDeadline()
        let candidate = try fileSecurity.canonicalRepositoryRoot(selectedRoot)
        let repositoryRoot = try git.repositoryRoot(startingAt: candidate, budget: budget)
        try budget.checkDeadline()
        let canonicalGitRoot = try fileSecurity.canonicalRepositoryRoot(repositoryRoot)
        guard canonicalGitRoot == candidate else {
            throw GroundingError.invalidRepositoryRoot
        }
        return canonicalGitRoot
    }

    private func removeAttemptSnapshot(_ root: URL?) throws {
        guard let root, FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            throw GroundingError.cannotCreatePrivateSnapshot
        }
    }

    private func copy(
        source: URL,
        destination: URL,
        manifest: GroundingManifest,
        attempt: Int,
        budget: GroundingResourceBudget
    ) async throws {
        try validate(manifest: manifest)
        var copiedBytes: UInt64 = 0
        for entry in manifest.entries {
            try budget.checkDeadline()
            try await observer.didReach(
                .willCopyFile(entry.relativePath),
                attempt: attempt,
                sourceRoot: source,
                snapshotRoot: destination
            )
            try budget.checkDeadline()
            let bytes: GroundingFileSecurity.SecureBytes
            do {
                bytes = try fileSecurity.secureRead(
                    root: source,
                    relativePath: entry.relativePath,
                    maximumByteCount: configuration.resourceLimits.maximumFileBytes,
                    budget: budget
                )
            } catch GroundingFileSecurity.ReadError.missing {
                throw GroundingError.sourceChangedDuringSnapshot
            } catch GroundingFileSecurity.ReadError.changed {
                throw GroundingError.sourceChangedDuringSnapshot
            } catch GroundingFileSecurity.ReadError.unsafe(let kind) {
                throw GroundingError.unsafeFile(relativePath: entry.relativePath, kind: kind)
            } catch GroundingFileSecurity.ReadError.exceedsByteLimit {
                throw GroundingError.resourceLimitExceeded(.fileBytes)
            } catch let error as GroundingError {
                throw error
            } catch {
                throw GroundingError.unreadableFile(entry.relativePath)
            }
            guard bytes.hash == entry.sha256, bytes.byteCount == entry.byteCount else {
                throw GroundingError.sourceChangedDuringSnapshot
            }
            copiedBytes = try addingAcceptedBytes(copiedBytes, bytes.byteCount)
            try fileSecurity.writePrivate(bytes.data, root: destination, relativePath: entry.relativePath)
        }
    }

    private func manifestForPrivateSnapshot(
        _ root: URL,
        budget: GroundingResourceBudget
    ) throws -> GroundingManifest {
        let paths = try fileSecurity.enumerateRegularFiles(
            root: root,
            maximumFileCount: configuration.resourceLimits.maximumFileCount,
            budget: budget
        )
        var acceptedBytes: UInt64 = 0
        var entries: [GroundingManifestEntry] = []
        entries.reserveCapacity(paths.count)
        for path in paths {
            try budget.checkDeadline()
            let bytes: GroundingFileSecurity.SecureBytes
            do {
                bytes = try fileSecurity.secureRead(
                    root: root,
                    relativePath: path,
                    maximumByteCount: configuration.resourceLimits.maximumFileBytes,
                    budget: budget
                )
            } catch GroundingFileSecurity.ReadError.exceedsByteLimit {
                throw GroundingError.resourceLimitExceeded(.fileBytes)
            }
            acceptedBytes = try addingAcceptedBytes(acceptedBytes, bytes.byteCount)
            entries.append(
                GroundingManifestEntry(
                    relativePath: path,
                    byteCount: bytes.byteCount,
                    sha256: bytes.hash
                ))
        }
        return GroundingManifest(entries: entries)
    }

    private func validate(manifest: GroundingManifest) throws {
        guard manifest.entries.count <= configuration.resourceLimits.maximumFileCount else {
            throw GroundingError.resourceLimitExceeded(.fileCount)
        }
        var acceptedBytes: UInt64 = 0
        for entry in manifest.entries {
            guard entry.byteCount <= configuration.resourceLimits.maximumFileBytes else {
                throw GroundingError.resourceLimitExceeded(.fileBytes)
            }
            acceptedBytes = try addingAcceptedBytes(acceptedBytes, entry.byteCount)
        }
    }

    private func addingAcceptedBytes(_ current: UInt64, _ added: UInt64) throws -> UInt64 {
        let (result, overflow) = current.addingReportingOverflow(added)
        guard !overflow, result <= configuration.resourceLimits.maximumAcceptedBytes else {
            throw GroundingError.resourceLimitExceeded(.aggregateAcceptedBytes)
        }
        return result
    }
}

struct GroundingSourceBuilder: Sendable {
    private let classifier = HardPathClassifier()
    private let scanner = GroundingSecretScanner()

    func build(
        root: URL,
        approvals: Set<SoftSuspiciousApproval>,
        git: GitRepositoryReader,
        fileSecurity: GroundingFileSecurity,
        limits: GroundingResourceLimits,
        budget: GroundingResourceBudget
    ) throws -> GroundingInspection {
        try budget.checkDeadline()
        try validateNoUnsafeEntries(
            root: root,
            git: git,
            fileSecurity: fileSecurity,
            limits: limits,
            budget: budget
        )
        let candidates = try git.candidatePaths(root: root, budget: budget)
        var entries: [GroundingManifestEntry] = []
        var hardExclusions: [HardExcludedPath] = []
        var softFindings: [SoftSuspiciousFinding] = []
        var acceptedApprovals: [SoftSuspiciousApproval] = []
        var acceptedBytes: UInt64 = 0

        for relativePath in candidates {
            try budget.checkDeadline()
            try fileSecurity.validate(relativePath: relativePath)
            do {
                try fileSecurity.validateRegularFile(root: root, relativePath: relativePath)
            } catch GroundingFileSecurity.ReadError.missing {
                continue
            } catch GroundingFileSecurity.ReadError.changed {
                throw GroundingError.sourceChangedDuringSnapshot
            } catch GroundingFileSecurity.ReadError.unsafe(let kind) {
                throw GroundingError.unsafeFile(relativePath: relativePath, kind: kind)
            } catch {
                throw GroundingError.unreadableFile(relativePath)
            }

            if let reason = classifier.reason(for: relativePath) {
                hardExclusions.append(HardExcludedPath(relativePath: relativePath, reason: reason))
                continue
            }

            let bytes: GroundingFileSecurity.SecureBytes
            do {
                bytes = try fileSecurity.secureRead(
                    root: root,
                    relativePath: relativePath,
                    maximumByteCount: limits.maximumFileBytes,
                    budget: budget
                )
            } catch GroundingFileSecurity.ReadError.missing,
                GroundingFileSecurity.ReadError.changed
            {
                throw GroundingError.sourceChangedDuringSnapshot
            } catch GroundingFileSecurity.ReadError.unsafe(let kind) {
                throw GroundingError.unsafeFile(relativePath: relativePath, kind: kind)
            } catch GroundingFileSecurity.ReadError.exceedsByteLimit {
                throw GroundingError.resourceLimitExceeded(.fileBytes)
            } catch let error as GroundingError {
                throw error
            } catch {
                throw GroundingError.unreadableFile(relativePath)
            }

            let secretFindings = scanner.findings(in: bytes.data)
            try budget.checkDeadline()
            if !secretFindings.hardRuleIDs.isEmpty {
                hardExclusions.append(
                    HardExcludedPath(relativePath: relativePath, reason: .secretContent)
                )
                continue
            }
            if !secretFindings.softRuleIDs.isEmpty {
                let finding = SoftSuspiciousFinding(
                    relativePath: relativePath,
                    contentHash: bytes.hash,
                    ruleIDs: secretFindings.softRuleIDs
                )
                softFindings.append(finding)
                let expectedApproval = SoftSuspiciousApproval(approving: finding)
                guard approvals.contains(expectedApproval) else { continue }
                acceptedApprovals.append(expectedApproval)
            }

            let (nextAcceptedBytes, overflow) = acceptedBytes.addingReportingOverflow(bytes.byteCount)
            guard !overflow, nextAcceptedBytes <= limits.maximumAcceptedBytes else {
                throw GroundingError.resourceLimitExceeded(.aggregateAcceptedBytes)
            }
            acceptedBytes = nextAcceptedBytes
            entries.append(
                GroundingManifestEntry(
                    relativePath: relativePath,
                    byteCount: bytes.byteCount,
                    sha256: bytes.hash
                ))
        }

        let manifest = GroundingManifest(entries: entries)
        let metadata = try git.metadata(root: root, budget: budget)
        try budget.checkDeadline()
        let groundingFingerprint = GroundingDigest.grounding(
            manifestFingerprint: manifest.fingerprint,
            branch: metadata.branch,
            head: metadata.head,
            worktreeFingerprint: metadata.worktreeFingerprint
        )
        let instructionSources = instructionSources(in: manifest)

        return GroundingInspection(
            branch: metadata.branch,
            head: metadata.head,
            worktreeFingerprint: metadata.worktreeFingerprint,
            manifest: manifest,
            groundingFingerprint: groundingFingerprint,
            hardExclusions: hardExclusions.sorted { $0.relativePath < $1.relativePath },
            softFindings: softFindings.sorted { $0.relativePath < $1.relativePath },
            acceptedApprovals: acceptedApprovals.sorted { $0.relativePath < $1.relativePath },
            instructionSources: instructionSources
        )
    }

    private func validateNoUnsafeEntries(
        root: URL,
        git: GitRepositoryReader,
        fileSecurity: GroundingFileSecurity,
        limits: GroundingResourceLimits,
        budget: GroundingResourceBudget
    ) throws {
        let ignoredPaths = try git.ignoredPaths(root: root, budget: budget)
        var enumerationFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else {
            throw GroundingError.sourceChangedDuringSnapshot
        }
        var visitedFileCount = 0
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        while let child = enumerator.nextObject() as? URL {
            try budget.chargeTraversalEntry()
            guard child.path.hasPrefix(rootPrefix) else {
                throw GroundingError.invalidRelativePath(child.lastPathComponent)
            }
            let relativePath = String(child.path.dropFirst(rootPrefix.count))
            try fileSecurity.validate(relativePath: relativePath)
            if relativePath == ".git" || relativePath.hasPrefix(".git/") {
                enumerator.skipDescendants()
                continue
            }
            if isIgnored(relativePath, ignoredPaths: ignoredPaths) {
                enumerator.skipDescendants()
                continue
            }

            let kind: UnsafeFileKind?
            do {
                kind = try fileSecurity.entryKind(at: child)
            } catch GroundingFileSecurity.ReadError.changed {
                throw GroundingError.sourceChangedDuringSnapshot
            } catch {
                throw GroundingError.unreadableFile(relativePath)
            }

            switch kind {
            case .directory:
                if classifier.reason(for: relativePath + "/placeholder") != nil {
                    enumerator.skipDescendants()
                }
            case .some(let unsafeKind):
                throw GroundingError.unsafeFile(relativePath: relativePath, kind: unsafeKind)
            case nil:
                guard visitedFileCount < limits.maximumFileCount else {
                    throw GroundingError.resourceLimitExceeded(.fileCount)
                }
                visitedFileCount += 1
            }
        }
        guard !enumerationFailed else {
            throw GroundingError.sourceChangedDuringSnapshot
        }
    }

    private func isIgnored(_ relativePath: String, ignoredPaths: Set<String>) -> Bool {
        ignoredPaths.contains { ignoredPath in
            relativePath == ignoredPath || relativePath.hasPrefix(ignoredPath + "/")
        }
    }

    private func instructionSources(in manifest: GroundingManifest) -> [GroundingInstructionSource] {
        manifest.entries.compactMap { entry in
            let filename = URL(fileURLWithPath: entry.relativePath).lastPathComponent
            let kind: GroundingInstructionKind
            switch filename {
            case "AGENTS.md": kind = .standard
            case "AGENTS.override.md": kind = .override
            default: return nil
            }
            return GroundingInstructionSource(
                relativePath: entry.relativePath,
                scopeRelativePath: GroundingPath.parent(of: entry.relativePath),
                fileHash: entry.sha256,
                kind: kind
            )
        }.sorted { $0.relativePath < $1.relativePath }
    }
}
