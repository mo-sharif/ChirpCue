import Darwin
import Foundation
import XCTest

@testable import PaceNoteCore

final class GroundingSnapshotTests: XCTestCase {
    func testProductionGroundingLimitsSupportLargeRepositoriesWithoutRemovingBounds() {
        let limits = GroundingResourceLimits()
        XCTAssertEqual(limits.maximumFileBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumFileCount, 5_000)
        XCTAssertEqual(limits.maximumAcceptedBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(limits.maximumScannedBytes, 192 * 1_024 * 1_024)
    }

    func testSnapshotIncludesTrackedAndNonignoredUntrackedFilesOnly() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("tracked.txt", "tracked\n")
        try fixture.git(["add", "tracked.txt"])
        try fixture.write("untracked.txt", "untracked\n")
        try fixture.write("ignored.txt", "ignored\n")
        try fixture.write(".gitignore", "ignored.txt\n")

        let manager = GroundingManager(configuration: fixture.configuration)
        let snapshot = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
        let paths = Set(snapshot.manifest.entries.map(\.relativePath))

        XCTAssertTrue(paths.contains("tracked.txt"))
        XCTAssertTrue(paths.contains("untracked.txt"))
        XCTAssertTrue(paths.contains(".gitignore"))
        XCTAssertFalse(paths.contains("ignored.txt"))
        XCTAssertEqual(snapshot.manifest, try fixture.manifest(at: snapshot.snapshotRoot))
        XCTAssertEqual(try fixture.permissions(snapshot.snapshotRoot), 0o700)
        XCTAssertEqual(try fixture.permissions(snapshot.snapshotRoot.appending(path: "tracked.txt")), 0o600)

        try await manager.deleteSnapshot(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.snapshotRoot.path))
    }

    func testHardDeniedFilesCannotBeApprovedAndSoftFindingRequiresExactHashBoundApproval() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("Sources/App.swift", "let title = \"ChirpCue\"\n")
        try fixture.write("Config.swift", "let api_key = \"fixture_secret_123456789\"\n")
        try fixture.write(".env.production", "API_KEY=must_never_leave\n")
        try fixture.git(["add", "."])

        let manager = GroundingManager(configuration: fixture.configuration)
        let unapproved = try await manager.inspectRepository(at: fixture.root)
        let finding = try XCTUnwrap(unapproved.softFindings.first { $0.relativePath == "Config.swift" })
        XCTAssertNil(unapproved.manifest["Config.swift"])
        XCTAssertNil(unapproved.manifest[".env.production"])
        XCTAssertEqual(
            unapproved.hardExclusions.first { $0.relativePath == ".env.production" }?.reason,
            .environmentFile
        )

        let wrongHash = SoftSuspiciousApproval(
            relativePath: finding.relativePath,
            contentHash: String(repeating: "0", count: 64),
            ruleIDs: finding.ruleIDs
        )
        let wrongApproval = try await manager.inspectRepository(at: fixture.root, approvals: [wrongHash])
        XCTAssertNil(wrongApproval.manifest["Config.swift"])

        let exactApproval = SoftSuspiciousApproval(approving: finding)
        let hardDenyAttempt = SoftSuspiciousApproval(
            relativePath: ".env.production",
            contentHash: finding.contentHash,
            ruleIDs: finding.ruleIDs
        )
        let snapshot = try await manager.createSnapshot(
            repoAlias: "fixture",
            sourceRoot: fixture.root,
            approvals: [exactApproval, hardDenyAttempt]
        )
        XCTAssertNotNil(snapshot.manifest["Config.swift"])
        XCTAssertNil(snapshot.manifest[".env.production"])
        XCTAssertEqual(snapshot.inspection.acceptedApprovals, [exactApproval])

        try fixture.write("Config.swift", "let api_key = \"changed_fixture_secret_987654321\"\n")
        let afterEdit = try await manager.inspectRepository(at: fixture.root, approvals: [exactApproval])
        XCTAssertNil(afterEdit.manifest["Config.swift"])
        XCTAssertNotEqual(afterEdit.softFindings.first?.contentHash, finding.contentHash)
    }

    func testDefiniteSecretContentIsHardExcludedWithoutApprovalEscape() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        let payloads = [
            "Secrets/private.txt": "-----BEGIN PRIVATE KEY-----\nsynthetic-only\n-----END PRIVATE KEY-----\n",
            "Secrets/aws.txt": "AKIA0000000000000000\n",
            "Secrets/github.txt": "ghp_AAAAAAAAAAAAAAAAAAAAAAAA\n",
            "Secrets/github-fine-bare.txt":
                "github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n",
            "Secrets/github-fine-embedded.txt":
                "token=\"github_pat_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\"\n",
            "Secrets/slack.txt": "xox" + "b-111111111111-222222222222-abcdefghijklmnopqrstuvwx\n",
            "Secrets/stripe.txt": "sk_test_AAAAAAAAAAAAAAAAAAAAAAAA\n",
            "Secrets/openai.txt": "sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA\n",
            "Secrets/google.txt": "AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n",
            "Secrets/bearer.txt": "Authorization: Bearer AAAAAAAAAAAAAAAAAAAAAAAA\n",
            "Secrets/slack-webhook.txt":
                "https://hooks.slack.com/" + "services/T00000000/B00000000/abcdefghijklmnopqrstuvwx\n",
            "Secrets/discord-webhook.txt":
                "https://discord.com/api/webhooks/1234567890/abcdefghijklmnopqrstuvwx\n",
        ]
        var approvals = Set<SoftSuspiciousApproval>()
        let scanner = GroundingSecretScanner()
        for (path, contents) in payloads {
            try fixture.write(path, contents)
            let data = Data(contents.utf8)
            let findings = scanner.findings(in: data)
            XCTAssertFalse(findings.hardRuleIDs.isEmpty, "Expected a hard rule for \(path)")
            approvals.insert(
                SoftSuspiciousApproval(
                    relativePath: path,
                    contentHash: GroundingDigest.sha256(data),
                    ruleIDs: findings.hardRuleIDs
                ))
        }

        let inspection = try await GroundingManager(configuration: fixture.configuration)
            .inspectRepository(at: fixture.root, approvals: approvals)

        XCTAssertEqual(
            Set(inspection.hardExclusions.filter { $0.reason == .secretContent }.map(\.relativePath)),
            Set(payloads.keys)
        )
        XCTAssertTrue(payloads.keys.allSatisfy { inspection.manifest[$0] == nil })
        XCTAssertTrue(inspection.acceptedApprovals.isEmpty)
    }

    func testConnectionURIUserinfoIsHardDeniedAndAssignmentsAreFlagged() {
        let scanner = GroundingSecretScanner()
        let schemes = [
            "postgresql", "mysql", "mariadb", "mongodb+srv", "redis", "rediss",
            "amqp", "amqps", "kafka", "nats", "https",
        ]
        for scheme in schemes {
            let value = scheme + "://fixture-user:" + "SyntheticPassword123@db.invalid/data"
            XCTAssertEqual(
                scanner.findings(in: Data(value.utf8)).hardRuleIDs,
                ["uri-userinfo-credential"],
                scheme
            )
        }

        for name in ["DATABASE_URL", "REDIS_URL", "BROKER_URL", "DSN", "CONNECTION_STRING"] {
            let value = name + "=fixture_connection_value_12345"
            XCTAssertEqual(
                scanner.findings(in: Data(value.utf8)).softRuleIDs,
                ["credential-assignment"],
                name
            )
        }
    }

    func testSelectedSubdirectoryCannotRedirectGroundingToGitTopLevel() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("Sources/App.swift", "struct App {}\n")
        let selectedSubdirectory = fixture.root.appendingPathComponent(
            "Sources",
            isDirectory: true
        )

        do {
            _ = try await GroundingManager(configuration: fixture.configuration)
                .inspectRepository(at: selectedSubdirectory)
            XCTFail("Expected exact selected-root binding.")
        } catch let error as GroundingError {
            XCTAssertEqual(error, .invalidRepositoryRoot)
        }
    }

    func testSnapshotWriterRejectsIntermediateDestinationSymlink() throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        let snapshotRoot = fixture.parent.appendingPathComponent("owned-snapshot", isDirectory: true)
        let externalRoot = fixture.parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: snapshotRoot.appendingPathComponent("Nested"),
            withDestinationURL: externalRoot
        )

        XCTAssertThrowsError(
            try GroundingFileSecurity().writePrivate(
                Data("sealed source".utf8),
                root: snapshotRoot,
                relativePath: "Nested/Source.swift"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalRoot.appendingPathComponent("Source.swift").path
            )
        )
    }

    func testCommonAuthAndOAuthCredentialStorePathsAreHardExcluded() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        let paths = [
            "Config/auth.json",
            ".config/gh/hosts.yml",
            ".config/gcloud/application_default_credentials.json",
            ".docker/config.json",
            "oauth/client_secret.json",
        ]
        for path in paths {
            try fixture.write(path, "{}\n")
        }

        let inspection = try await GroundingManager(configuration: fixture.configuration)
            .inspectRepository(at: fixture.root)

        XCTAssertEqual(
            Set(inspection.hardExclusions.filter { $0.reason == .credentialStore }.map(\.relativePath)),
            Set(paths)
        )
        XCTAssertTrue(paths.allSatisfy { inspection.manifest[$0] == nil })
    }

    func testOversizedFilesAreVisiblyExcludedWhileCountAndAggregateLimitsFailClosed() async throws {
        let perFileFixture = try GitFixture()
        addTeardownBlock { try perFileFixture.remove() }
        try perFileFixture.write("large.txt", String(repeating: "x", count: 33))
        let perFileManager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: perFileFixture.snapshots,
                resourceLimits: .init(maximumFileBytes: 32)
            ))
        let perFileInspection = try await perFileManager.inspectRepository(
            at: perFileFixture.root
        )
        XCTAssertTrue(perFileInspection.manifest.entries.isEmpty)
        XCTAssertEqual(
            perFileInspection.hardExclusions,
            [HardExcludedPath(relativePath: "large.txt", reason: .oversizedFile)]
        )

        let countFixture = try GitFixture()
        addTeardownBlock { try countFixture.remove() }
        try countFixture.write("A.txt", "a")
        try countFixture.write("B.txt", "b")
        let countManager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: countFixture.snapshots,
                resourceLimits: .init(maximumFileCount: 1)
            ))
        await XCTAssertThrowsGroundingLimit(.fileCount) {
            try await countManager.inspectRepository(at: countFixture.root)
        }

        let aggregateFixture = try GitFixture()
        addTeardownBlock { try aggregateFixture.remove() }
        try aggregateFixture.write("A.txt", "12345678")
        try aggregateFixture.write("B.txt", "12345678")
        let aggregateManager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: aggregateFixture.snapshots,
                resourceLimits: .init(maximumAcceptedBytes: 12)
            ))
        await XCTAssertThrowsGroundingLimit(.aggregateAcceptedBytes) {
            try await aggregateManager.inspectRepository(at: aggregateFixture.root)
        }
    }

    func testExcludedSecretStillConsumesScannedByteBudget() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write(
            "secret-content.txt",
            "github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
        )
        let manager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: fixture.snapshots,
                resourceLimits: .init(maximumScannedBytes: 1)
            ))

        await XCTAssertThrowsGroundingLimit(.aggregateScannedBytes) {
            try await manager.inspectRepository(at: fixture.root)
        }
    }

    func testScannedByteBudgetIsSharedAcrossSnapshotPhases() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("A.txt", "12345678")
        let manager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: fixture.snapshots,
                maximumSnapshotRetries: 0,
                resourceLimits: .init(maximumScannedBytes: 20)
            ))

        await XCTAssertThrowsGroundingLimit(.aggregateScannedBytes) {
            try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
        }
    }

    func testTraversalEntryAndOverallDeadlineLimitsFailClosed() async throws {
        let traversalFixture = try GitFixture()
        addTeardownBlock { try traversalFixture.remove() }
        try traversalFixture.write("Sources/A.swift", "struct A {}\n")
        let traversalManager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: traversalFixture.snapshots,
                resourceLimits: .init(maximumTraversalEntries: 1)
            ))
        await XCTAssertThrowsGroundingLimit(.traversalEntries) {
            try await traversalManager.inspectRepository(at: traversalFixture.root)
        }

        let deadlineFixture = try GitFixture()
        addTeardownBlock { try deadlineFixture.remove() }
        try deadlineFixture.write("A.txt", "deadline\n")
        let deadlineManager = GroundingManager(
            configuration: .init(
                snapshotParentDirectory: deadlineFixture.snapshots,
                resourceLimits: .init(maximumGroundingDuration: 0)
            ))
        await XCTAssertThrowsGroundingLimit(.groundingDeadline) {
            try await deadlineManager.inspectRepository(at: deadlineFixture.root)
        }
    }

    func testResourceLimitsRemainEnforcedDuringCopyVerificationAndRebuild() async throws {
        for mutation in ResourceLimitMutation.allCases {
            let fixture = try GitFixture()
            addTeardownBlock { try fixture.remove() }
            try fixture.write("A.txt", "small")
            let observer = ResourceLimitMutationObserver(root: fixture.root, mutation: mutation)
            let limits: GroundingResourceLimits =
                mutation == .beforeRebuild
                ? .init(maximumFileBytes: 32, maximumFileCount: 1)
                : .init(maximumFileBytes: 32, maximumFileCount: 10)
            let manager = GroundingManager(
                configuration: .init(
                    snapshotParentDirectory: fixture.snapshots,
                    maximumSnapshotRetries: 0,
                    resourceLimits: limits
                ),
                observer: observer
            )

            await XCTAssertThrowsGroundingLimit(mutation.expectedLimit) {
                try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
            }
        }
    }

    func testGitOutputAndTimeoutLimitsTerminateBoundedly() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "PaceNoteGitLimitTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let flood = try makeExecutable(
            at: parent.appending(path: "flood"),
            contents: "#!/bin/sh\nwhile :; do printf '01234567890123456789012345678901'; done\n"
        )
        let floodReader = GitRepositoryReader(
            limits: .init(maximumGitOutputBytes: 1_024, gitCommandTimeout: 2),
            executableURL: flood
        )
        let floodStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try floodReader.repositoryRoot(startingAt: parent)) { error in
            XCTAssertEqual(error as? GroundingError, .resourceLimitExceeded(.gitOutputBytes))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - floodStartedAt, 1)

        let sleeper = try makeExecutable(
            at: parent.appending(path: "sleeper"),
            contents: "#!/bin/sh\nexec /bin/sleep 5\n"
        )
        let timeoutReader = GitRepositoryReader(
            limits: .init(maximumGitOutputBytes: 1_024, gitCommandTimeout: 0.1),
            executableURL: sleeper
        )
        let timeoutStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try timeoutReader.repositoryRoot(startingAt: parent)) { error in
            XCTAssertEqual(error as? GroundingError, .resourceLimitExceeded(.gitCommandTimeout))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - timeoutStartedAt, 1)

        let inheritedPipe = try makeExecutable(
            at: parent.appending(path: "inherited-pipe"),
            contents: "#!/bin/sh\n/bin/sleep 5 &\nexit 0\n"
        )
        let inheritedPipeReader = GitRepositoryReader(
            limits: .init(maximumGitOutputBytes: 1_024, gitCommandTimeout: 0.5),
            executableURL: inheritedPipe
        )
        let inheritedPipeStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try inheritedPipeReader.repositoryRoot(startingAt: parent)) { error in
            let groundingError = error as? GroundingError
            XCTAssertTrue(
                groundingError == .notGitRepository
                    || groundingError == .resourceLimitExceeded(.gitCommandTimeout)
            )
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - inheritedPipeStartedAt, 1.5)
    }

    func testExtremePublicFileLimitDoesNotOverflowSizeConversion() throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("small.txt", "bounded")

        let bytes = try GroundingFileSecurity().secureRead(
            root: fixture.root,
            relativePath: "small.txt",
            maximumByteCount: UInt64.max
        )

        XCTAssertEqual(bytes.data, Data("bounded".utf8))
    }

    func testNestedAgentInstructionsUseOverrideAtTheSameScope() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("AGENTS.md", "root instructions\n")
        try fixture.write("Sources/AGENTS.md", "standard source instructions\n")
        try fixture.write("Sources/AGENTS.override.md", "override source instructions\n")
        try fixture.write("Sources/Worker.swift", "struct Worker {}\n")

        let manager = GroundingManager(configuration: fixture.configuration)
        let snapshot = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
        let chain = snapshot.effectiveInstructionSources(for: "Sources/Worker.swift")

        XCTAssertEqual(chain.map(\.relativePath), ["AGENTS.md", "Sources/AGENTS.override.md"])
        XCTAssertEqual(chain.map(\.kind), [.standard, .override])
    }

    func testStableSymbolicLinkIsRejectedWithoutReadingItsTarget() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        let outside = fixture.parent.appending(path: "outside-secret.txt")
        try Data("outside secret\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "linked.txt"),
            withDestinationURL: outside
        )
        try fixture.git(["add", "linked.txt"])

        let manager = GroundingManager(configuration: fixture.configuration)
        do {
            _ = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
            XCTFail("A tracked symlink must block grounding")
        } catch GroundingError.unsafeFile(let path, let kind) {
            XCTAssertEqual(path, "linked.txt")
            XCTAssertEqual(kind, .symbolicLink)
        }
    }

    func testHardLinkIsRejected() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("original.txt", "shared inode\n")
        let original = fixture.root.appending(path: "original.txt").path
        let alias = fixture.root.appending(path: "alias.txt").path
        XCTAssertEqual(Darwin.link(original, alias), 0)
        try fixture.git(["add", "original.txt", "alias.txt"])

        let manager = GroundingManager(configuration: fixture.configuration)
        do {
            _ = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
            XCTFail("A hard link must block grounding")
        } catch GroundingError.unsafeFile(_, let kind) {
            XCTAssertEqual(kind, .hardLink)
        }
    }

    func testFIFOIsRejectedWithoutBlockingOnRead() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        let fifo = fixture.root.appending(path: "input.pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)

        let manager = GroundingManager(configuration: fixture.configuration)
        do {
            _ = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
            XCTFail("A FIFO must block grounding")
        } catch GroundingError.unsafeFile(let path, let kind) {
            XCTAssertEqual(path, "input.pipe")
            XCTAssertEqual(kind, .fifo)
        }
    }

    func testUnixSocketIsRejected() async throws {
        let fixture = try GitFixture(useShortPath: true)
        addTeardownBlock { try fixture.remove() }
        let socketURL = fixture.root.appending(path: "agent.socket")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw XCTSkip("The temporary socket path exceeds sockaddr_un.sun_path")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        XCTAssertEqual(bindResult, 0)

        let manager = GroundingManager(configuration: fixture.configuration)
        do {
            _ = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
            XCTFail("A Unix socket must block grounding")
        } catch GroundingError.unsafeFile(let path, let kind) {
            XCTAssertEqual(path, "agent.socket")
            XCTAssertEqual(kind, .socket)
        }
    }

    func testEditAddRenameAndDeleteDuringCopyNeverProduceAnAcceptedMixedSnapshot() async throws {
        for mutation in SnapshotMutation.allCases {
            let fixture = try GitFixture()
            addTeardownBlock { try fixture.remove() }
            try fixture.write("Sources/A.swift", "let value = 1\n")
            try fixture.write("Sources/B.swift", "let other = 2\n")
            try fixture.git(["add", "."])
            let observer = MutatingSnapshotObserver(root: fixture.root, mutation: mutation, repeatEveryAttempt: true)
            let manager = GroundingManager(
                configuration: .init(
                    snapshotParentDirectory: fixture.snapshots,
                    maximumSnapshotRetries: 0
                ),
                observer: observer
            )

            do {
                _ = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
                XCTFail("\(mutation) must invalidate A=S=B")
            } catch GroundingError.snapshotBusy {
                let mutationCount = await observer.mutationCount
                XCTAssertEqual(mutationCount, 1)
            }
        }
    }

    func testBoundedRetriesReturnSnapshotBusyWhenSourceChangesEveryAttempt() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("Sources/A.swift", "let value = 1\n")
        let observer = MutatingSnapshotObserver(root: fixture.root, mutation: .edit, repeatEveryAttempt: true)
        let manager = GroundingManager(
            configuration: .init(snapshotParentDirectory: fixture.snapshots, maximumSnapshotRetries: 2),
            observer: observer
        )

        do {
            _ = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
            XCTFail("A continuously changing source must not be accepted")
        } catch GroundingError.snapshotBusy {
            let mutationCount = await observer.mutationCount
            XCTAssertEqual(mutationCount, 3)
        }
    }

    func testRetryAcceptsOnlyTheLaterStableSourceState() async throws {
        let fixture = try GitFixture()
        addTeardownBlock { try fixture.remove() }
        try fixture.write("Sources/A.swift", "let value = 1\n")
        let observer = MutatingSnapshotObserver(root: fixture.root, mutation: .edit, repeatEveryAttempt: false)
        let manager = GroundingManager(
            configuration: .init(snapshotParentDirectory: fixture.snapshots, maximumSnapshotRetries: 2),
            observer: observer
        )

        let snapshot = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: fixture.root)
        let mutationCount = await observer.mutationCount
        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(snapshot.manifest, try fixture.manifest(at: snapshot.snapshotRoot))
        XCTAssertEqual(
            snapshot.manifest["Sources/A.swift"]?.sha256,
            try fixture.manifest(at: fixture.root, paths: ["Sources/A.swift"])["Sources/A.swift"]?.sha256
        )
    }
}

private enum SnapshotMutation: String, CaseIterable, Sendable {
    case edit
    case add
    case rename
    case delete
}

private enum ResourceLimitMutation: CaseIterable, Sendable {
    case duringCopy
    case duringVerification
    case beforeRebuild

    var expectedLimit: GroundingResourceLimit {
        switch self {
        case .duringCopy, .duringVerification: .fileBytes
        case .beforeRebuild: .fileCount
        }
    }
}

private actor ResourceLimitMutationObserver: GroundingSnapshotObserver {
    private let root: URL
    private let mutation: ResourceLimitMutation
    private var didMutate = false

    init(root: URL, mutation: ResourceLimitMutation) {
        self.root = root
        self.mutation = mutation
    }

    func didReach(
        _ stage: GroundingSnapshotStage,
        attempt: Int,
        sourceRoot: URL,
        snapshotRoot: URL?
    ) async throws {
        guard !didMutate else { return }
        switch (mutation, stage) {
        case (.duringCopy, .willCopyFile("A.txt")):
            try Data(repeating: 0x41, count: 64).write(to: root.appending(path: "A.txt"))
        case (.duringVerification, .snapshotCopied):
            let snapshotRoot = try XCTUnwrap(snapshotRoot)
            try Data(repeating: 0x41, count: 64).write(to: snapshotRoot.appending(path: "A.txt"))
        case (.beforeRebuild, .willRecheckSource):
            try Data("added".utf8).write(to: root.appending(path: "B.txt"))
        default:
            return
        }
        didMutate = true
    }
}

private actor MutatingSnapshotObserver: GroundingSnapshotObserver {
    private let root: URL
    private let mutation: SnapshotMutation
    private let repeatEveryAttempt: Bool
    private(set) var mutationCount = 0

    init(root: URL, mutation: SnapshotMutation, repeatEveryAttempt: Bool) {
        self.root = root
        self.mutation = mutation
        self.repeatEveryAttempt = repeatEveryAttempt
    }

    func didReach(
        _ stage: GroundingSnapshotStage,
        attempt: Int,
        sourceRoot: URL,
        snapshotRoot: URL?
    ) async throws {
        guard case .snapshotCopied = stage,
            repeatEveryAttempt || mutationCount == 0
        else { return }
        mutationCount += 1
        let fileManager = FileManager.default
        switch mutation {
        case .edit:
            let target = root.appending(path: "Sources/A.swift")
            try Data("let value = \(mutationCount + 1)\n".utf8).write(to: target)
        case .add:
            let target = root.appending(path: "Sources/Added\(mutationCount).swift")
            try Data("let added = \(mutationCount)\n".utf8).write(to: target)
        case .rename:
            let source = root.appending(path: "Sources/A.swift")
            let destination = root.appending(path: "Sources/Renamed.swift")
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        case .delete:
            let target = root.appending(path: "Sources/A.swift")
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }
}

private final class GitFixture: @unchecked Sendable {
    let parent: URL
    let root: URL
    let snapshots: URL

    init(useShortPath: Bool = false) throws {
        let directoryName =
            useShortPath
            ? "pn-\(UUID().uuidString.prefix(8))"
            : "PaceNoteGroundingTests-\(UUID().uuidString)"
        let base =
            useShortPath
            ? URL(fileURLWithPath: "/tmp", isDirectory: true)
            : FileManager.default.temporaryDirectory
        parent = base.appending(path: directoryName, directoryHint: .isDirectory)
        root = parent.appending(path: "repo", directoryHint: .isDirectory)
        snapshots = parent.appending(path: "snapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet"])
    }

    var configuration: GroundingConfiguration {
        .init(snapshotParentDirectory: snapshots, maximumSnapshotRetries: 2)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: destination)
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitFixture", code: Int(process.terminationStatus))
        }
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func manifest(at root: URL, paths: [String]? = nil) throws -> GroundingManifest {
        let security = GroundingFileSecurity()
        let selectedPaths = try paths ?? security.enumerateRegularFiles(root: root)
        return GroundingManifest(
            entries: try selectedPaths.map { relativePath in
                let bytes = try security.secureRead(root: root, relativePath: relativePath)
                return GroundingManifestEntry(
                    relativePath: relativePath,
                    byteCount: bytes.byteCount,
                    sha256: bytes.hash
                )
            })
    }

    func remove() throws {
        try FileManager.default.removeItem(at: parent)
    }
}

private func makeExecutable(at url: URL, contents: String) throws -> URL {
    try Data(contents.utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return url
}

private func XCTAssertThrowsGroundingLimit<T: Sendable>(
    _ expected: GroundingResourceLimit,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let GroundingError.resourceLimitExceeded(actual) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
