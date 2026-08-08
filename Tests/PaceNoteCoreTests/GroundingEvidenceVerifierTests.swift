import Foundation
import XCTest

@testable import PaceNoteCore

final class GroundingEvidenceVerifierTests: XCTestCase {
    func testValidEvidenceReturnsOnlyTheVerifiedLineRange() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let verifier = EvidenceVerifier()

        let verified = try await verifier.verify(
            [reference],
            groundingFingerprint: context.snapshot.groundingFingerprint,
            instructionSources: context.snapshot.effectiveInstructionSources(for: reference.relativePath),
            against: context.snapshot
        )

        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified[0].excerpt, "    func enqueue(_ job: Job) {\n        queue.append(job)\n    }")
        let isFresh = await verifier.isFresh(context.snapshot)
        XCTAssertTrue(isFresh)
    }

    func testEvidenceRejectsTraversalAliasHashLineInstructionAndUnsupportedClaim() async throws {
        let cases: [EvidenceFailureCase] = [.traversal, .alias, .hash, .line, .instructions, .claim]
        for failureCase in cases {
            let context = try await EvidenceFixture.make()
            defer { context.remove() }
            let verifier = EvidenceVerifier()
            let valid = try context.reference(
                path: "Sources/Worker.swift",
                startLine: 2,
                endLine: 4,
                claim: "queue.append(job)"
            )
            let reference: EvidenceReference
            var instructions = context.snapshot.effectiveInstructionSources(for: valid.relativePath)
            switch failureCase {
            case .traversal:
                reference = EvidenceReference(
                    repoAlias: "fixture",
                    relativePath: "../outside.txt",
                    startLine: 1,
                    endLine: 1,
                    fileHash: valid.fileHash,
                    claim: valid.claim
                )
            case .alias:
                reference = EvidenceReference(
                    repoAlias: "other",
                    relativePath: valid.relativePath,
                    startLine: valid.startLine,
                    endLine: valid.endLine,
                    fileHash: valid.fileHash,
                    claim: valid.claim
                )
            case .hash:
                reference = EvidenceReference(
                    repoAlias: valid.repoAlias,
                    relativePath: valid.relativePath,
                    startLine: valid.startLine,
                    endLine: valid.endLine,
                    fileHash: String(repeating: "f", count: 64),
                    claim: valid.claim
                )
            case .line:
                reference = EvidenceReference(
                    repoAlias: valid.repoAlias,
                    relativePath: valid.relativePath,
                    startLine: 2,
                    endLine: 99,
                    fileHash: valid.fileHash,
                    claim: valid.claim
                )
            case .instructions:
                reference = valid
                instructions = []
            case .claim:
                reference = EvidenceReference(
                    repoAlias: valid.repoAlias,
                    relativePath: valid.relativePath,
                    startLine: valid.startLine,
                    endLine: valid.endLine,
                    fileHash: valid.fileHash,
                    claim: "database encryption rotates certificates"
                )
            }

            do {
                _ = try await verifier.verify(
                    [reference],
                    groundingFingerprint: context.snapshot.groundingFingerprint,
                    instructionSources: instructions,
                    against: context.snapshot
                )
                XCTFail("\(failureCase) must fail verification")
            } catch let error as EvidenceVerificationError {
                XCTAssertTrue(failureCase.matches(error), "Unexpected error for \(failureCase): \(error)")
            }
        }
    }

    func testCitedSourceMutationInvalidatesEvidence() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        try context.write("Sources/Worker.swift", "struct Worker { let changed = true }\n")
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.sourceChanged) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(for: reference.relativePath),
                against: context.snapshot
            )
        }
        let isFresh = await verifier.isFresh(context.snapshot)
        XCTAssertFalse(isFresh)
    }

    func testUncitedSourceMutationStillInvalidatesRepositoryFingerprint() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        try context.write("README.md", "changed project notes\n")
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.sourceChanged) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(for: reference.relativePath),
                against: context.snapshot
            )
        }
    }

    func testSnapshotMutationInvalidatesEvidenceEvenWhenSourceIsUnchanged() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let snapshotFile = context.snapshot.snapshotRoot.appending(path: "Sources/Worker.swift")
        try Data("tampered snapshot\n".utf8).write(to: snapshotFile)
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.snapshotChanged) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(for: reference.relativePath),
                against: context.snapshot
            )
        }
    }

    func testGroundingFingerprintMismatchFailsBeforeEvidenceDisplay() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.groundingFingerprintMismatch) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: "wrong-fingerprint",
                instructionSources: context.snapshot.effectiveInstructionSources(for: reference.relativePath),
                against: context.snapshot
            )
        }
    }

    func testEvidenceVerificationOverallDeadlineFailsClosed() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let verifier = EvidenceVerifier(limits: .init(maximumGroundingDuration: 0))

        do {
            _ = try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(
                    for: reference.relativePath
                ),
                against: context.snapshot
            )
            XCTFail("An expired overall grounding deadline must fail verification")
        } catch let GroundingError.resourceLimitExceeded(limit) {
            XCTAssertEqual(limit, .groundingDeadline)
        }
    }

    func testEvidenceVerificationScannedByteBudgetFailsClosed() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let verifier = EvidenceVerifier(limits: .init(maximumScannedBytes: 1))

        await XCTAssertThrowsEvidence(.snapshotChanged) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(
                    for: reference.relativePath
                ),
                against: context.snapshot
            )
        }
    }

    func testOneGenericSharedTermDoesNotSupportAClaim() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "The queue rotates database encryption certificates nightly"
        )
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.claimNotSupported(reference.relativePath)) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(
                    for: reference.relativePath
                ),
                against: context.snapshot
            )
        }
    }

    func testUnrelatedCandidateCannotRideOnVerifiedEvidence() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let verifier = EvidenceVerifier()

        do {
            _ = try await verifier.verifyAnswer(
                candidateSayNext: "The database rotates encryption certificates every night.",
                references: [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                against: context.snapshot
            )
            XCTFail("An unrelated spoken candidate must not pass evidence verification.")
        } catch let error as EvidenceVerificationError {
            XCTAssertEqual(error, .candidateNotSupported)
        }
    }

    func testCandidateMateriallyBoundToVerifiedEvidencePasses() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 2,
            endLine: 4,
            claim: "queue.append(job)"
        )
        let verifier = EvidenceVerifier()

        let verified = try await verifier.verifyAnswer(
            candidateSayNext: "queue.append(job)",
            references: [reference],
            groundingFingerprint: context.snapshot.groundingFingerprint,
            against: context.snapshot
        )

        XCTAssertEqual(verified.map(\.reference), [reference])
    }

    func testBasisClaimCannotAppendUnsupportedClause() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let supported = "The worker queue appends each job and isolates callers from retry latency."
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 6,
            endLine: 6,
            claim: supported + " It also deletes credentials."
        )
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.claimNotSupported(reference.relativePath)) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(
                    for: reference.relativePath
                ),
                against: context.snapshot
            )
        }
    }

    func testCandidateCannotAppendUnsupportedClauseToVerifiedClaim() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let supported = "The worker queue appends each job and isolates callers from retry latency."
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 6,
            endLine: 6,
            claim: supported
        )
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.candidateNotSupported) {
            try await verifier.verifyAnswer(
                candidateSayNext: supported + " It also deletes credentials.",
                references: [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                against: context.snapshot
            )
        }
    }

    func testCandidateCannotInventRelationshipAcrossVerifiedClaims() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let workerClaim = "The worker queue appends each job and isolates callers from retry latency."
        let references = try [
            context.reference(
                path: "Sources/Worker.swift",
                startLine: 6,
                endLine: 6,
                claim: workerClaim
            ),
            context.reference(
                path: "Sources/Worker.swift",
                startLine: 2,
                endLine: 4,
                claim: "queue.append(job)"
            ),
        ]
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.candidateNotSupported) {
            try await verifier.verifyAnswer(
                candidateSayNext: workerClaim + " Therefore enqueue prevents blocking.",
                references: references,
                groundingFingerprint: context.snapshot.groundingFingerprint,
                against: context.snapshot
            )
        }
    }

    func testClaimCannotDropNegationFromCitedLine() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 7,
            endLine: 7,
            claim: "Authentication is required for local requests."
        )
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.claimNotSupported(reference.relativePath)) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(
                    for: reference.relativePath
                ),
                against: context.snapshot
            )
        }
    }

    func testClaimCannotChangeMeaningByDroppingPunctuation() async throws {
        let context = try await EvidenceFixture.make()
        addTeardownBlock { context.remove() }
        let reference = try context.reference(
            path: "Sources/Worker.swift",
            startLine: 8,
            endLine: 8,
            claim: "No authentication is required for production requests."
        )
        let verifier = EvidenceVerifier()

        await XCTAssertThrowsEvidence(.claimNotSupported(reference.relativePath)) {
            try await verifier.verify(
                [reference],
                groundingFingerprint: context.snapshot.groundingFingerprint,
                instructionSources: context.snapshot.effectiveInstructionSources(
                    for: reference.relativePath
                ),
                against: context.snapshot
            )
        }
    }
}

private enum EvidenceFailureCase: String, Sendable {
    case traversal
    case alias
    case hash
    case line
    case instructions
    case claim

    func matches(_ error: EvidenceVerificationError) -> Bool {
        switch (self, error) {
        case (.traversal, .invalidPath),
            (.alias, .repositoryAliasMismatch),
            (.hash, .referenceHashMismatch),
            (.line, .invalidLineRange),
            (.instructions, .instructionSourcesMismatch),
            (.claim, .claimNotSupported):
            true
        default: false
        }
    }
}

private struct EvidenceFixture: @unchecked Sendable {
    let parent: URL
    let root: URL
    let snapshot: GroundingSnapshot

    static func make() async throws -> EvidenceFixture {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "PaceNoteEvidenceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "repo", directoryHint: .isDirectory)
        let snapshots = parent.appending(path: "snapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(root: root, ["init", "--quiet"])
        try write(root: root, "AGENTS.md", "Verify every repository claim.\n")
        try write(
            root: root,
            "Sources/Worker.swift",
            "struct Worker {\n    func enqueue(_ job: Job) {\n        queue.append(job)\n    }\n}\n// The worker queue appends each job and isolates callers from retry latency.\n// Authentication is not required for local requests.\n// No, authentication is required for production requests.\n"
        )
        try write(root: root, "README.md", "Worker queue architecture\n")
        try runGit(root: root, ["add", "."])
        let manager = GroundingManager(
            configuration: .init(snapshotParentDirectory: snapshots, maximumSnapshotRetries: 2)
        )
        let snapshot = try await manager.createSnapshot(repoAlias: "fixture", sourceRoot: root)
        return EvidenceFixture(parent: parent, root: root, snapshot: snapshot)
    }

    func reference(path: String, startLine: Int, endLine: Int, claim: String) throws -> EvidenceReference {
        let entry = try XCTUnwrap(snapshot.manifest[path])
        return EvidenceReference(
            repoAlias: snapshot.repoAlias,
            relativePath: path,
            startLine: startLine,
            endLine: endLine,
            fileHash: entry.sha256,
            claim: claim
        )
    }

    func write(_ relativePath: String, _ contents: String) throws {
        try Self.write(root: root, relativePath, contents)
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }

    private static func write(root: URL, _ relativePath: String, _ contents: String) throws {
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: destination)
    }

    private static func runGit(root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EvidenceFixture", code: Int(process.terminationStatus))
        }
    }
}

private func XCTAssertThrowsEvidence<T: Sendable>(
    _ expected: EvidenceVerificationError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as EvidenceVerificationError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
