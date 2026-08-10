import CryptoKit
import Foundation
import XCTest

@testable import PaceNoteCore

final class CodexMeetingResponseGeneratorTests: XCTestCase {
    func testOrdinaryQuickFallbackDeepVerificationSkillPolicyAndCleanup() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let quick = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: 1,
            sayNow: "I would separate queue isolation from restart recovery.",
            needsDeep: true,
            confidence: 0.72,
            reason: "implementation detail"
        )
        let deep = fixture.deepDraft(for: turn)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(quick)],
            turnOutputs: [try Self.json(deep)],
            ambientSkillEnabled: true
        )
        let verifier = FakeMeetingEvidenceVerifier()
        let generator = fixture.generator(client: client, verifier: verifier)

        let runtime = try await generator.prepare()
        XCTAssertFalse(runtime.usesRealtimeQuick)
        let generatedQuick = try await generator.generateQuick(for: turn)
        let generatedDeep = try await generator.generateDeep(for: turn)
        XCTAssertEqual(generatedQuick, quick)
        XCTAssertEqual(generatedDeep, deep)

        let activeJournalEntries = try await fixture.journal.entries()
        let activeJournalEntry = try XCTUnwrap(activeJournalEntries.first)
        XCTAssertEqual(Set(activeJournalEntry.threadIDs), Set(["base-1", "base-2"]))

        let disabled = await client.skillWrites()
        XCTAssertTrue(disabled.contains(where: { $0.name == "ambient-skill" && !$0.enabled }))
        let verificationCount = await verifier.verificationCount()
        XCTAssertEqual(verificationCount, 1)
        let verifiedCandidates = await verifier.verifiedCandidates()
        XCTAssertEqual(verifiedCandidates, [deep.candidateSayNext])

        let report = await generator.shutdown()
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.deletedThreadCount, 2)
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(entries.count, 1, "Session cleanup owns final journal removal.")
        XCTAssertTrue(entries[0].threadIDs.isEmpty)
        let allDeleted = await client.deletedThreadIDs()
        XCTAssertEqual(Set(allDeleted), Set(["base-1", "base-2", "fork-1", "fork-2"]))
    }

    func testGroundedCandidateMismatchFallsBackToOneVerifiedBasisClaim() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let draft = fixture.deepDraft(for: turn)
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(draft)]
        )
        let verifier = FakeMeetingEvidenceVerifier(candidateMismatchOnFirstCall: true)
        let generator = fixture.generator(client: client, verifier: verifier)

        _ = try await generator.prepare()
        let generated = try await generator.generateDeep(for: turn)

        XCTAssertEqual(generated.candidateSayNext, draft.basis[0].claim)
        XCTAssertEqual(generated.basis, [draft.basis[0]])
        let verifiedCandidates = await verifier.verifiedCandidates()
        XCTAssertEqual(
            verifiedCandidates,
            [draft.candidateSayNext, draft.basis[0].claim, draft.basis[0].claim]
        )
        let interrupted = await client.interruptedThreadIDs()
        XCTAssertTrue(interrupted.isEmpty)
        _ = await generator.shutdown()
    }

    func testRealtimeQuickUsesStrictJSONAndNeverStartsOrdinaryQuickTurn() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 3)
        let output = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: 3,
            sayNow: "I can give the shape now, then verify the implementation.",
            needsDeep: true,
            confidence: 0.61,
            reason: "needs repository evidence"
        )
        let client = FakeMeetingCodexClient(
            realtime: true,
            quickOutputs: [try Self.json(output)]
        )
        let generator = fixture.generator(client: client)

        let runtime = try await generator.prepare()
        let generated = try await generator.generateQuick(for: turn)
        let realtimeStopCount = await client.realtimeStopCount()
        let quickTurnCount = await client.quickTurnCount()
        XCTAssertTrue(runtime.usesRealtimeQuick)
        XCTAssertEqual(generated, output)
        XCTAssertEqual(realtimeStopCount, 1)
        XCTAssertEqual(quickTurnCount, 0)
        _ = await generator.shutdown()
    }

    func testMalformedBaseIsJournaledBeforeValidationAndDeletionRetriesOnShutdown() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(
            realtime: false,
            invalidBaseCwd: true,
            deletionFailuresRemaining: 1
        )
        let generator = fixture.generator(client: client)

        await XCTAssertThrowsMeetingError(.protocolUnsupported) {
            _ = try await generator.prepare()
        }

        let entriesBeforeShutdown = try await fixture.journal.entries()
        let attemptsBeforeShutdown = await client.deleteAttemptCount()
        XCTAssertEqual(entriesBeforeShutdown.first?.threadIDs, ["base-1"])
        XCTAssertEqual(attemptsBeforeShutdown, 1)

        let report = await generator.shutdown()
        let attemptsAfterShutdown = await client.deleteAttemptCount()
        let deletedThreadIDs = await client.deletedThreadIDs()
        let entriesAfterShutdown = try await fixture.journal.entries()

        XCTAssertEqual(attemptsAfterShutdown, 2)
        XCTAssertEqual(deletedThreadIDs, ["base-1"])
        XCTAssertEqual(entriesAfterShutdown.first?.threadIDs, [])
        XCTAssertTrue(report.failures.contains(.deleteThread))
    }

    func testEphemeralDeleteFailureIsReconciledOnlyAfterExactCwdAbsence() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 4)
        let output = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: "I can give the shape now, then verify the implementation.",
            needsDeep: true,
            confidence: 0.61,
            reason: "needs repository evidence"
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(output)],
            deletionFailuresRemaining: 1,
            confirmsAbsentAfterDeleteFailure: true
        )
        let generator = fixture.generator(client: client)

        _ = try await generator.prepare()
        let generated = try await generator.generateQuick(for: turn)
        let deleteAttempts = await client.deleteAttemptCount()
        XCTAssertEqual(generated, output)
        XCTAssertEqual(deleteAttempts, 1)

        let report = await generator.shutdown()
        XCTAssertFalse(report.failures.contains(.deleteThread))
    }

    func testShutdownWaitsForLateBaseThenJournalsAndDeletesIt() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let baseGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            baseCreationGate: baseGate
        )
        let generator = fixture.generator(client: client)

        let preparation = Task { try await generator.prepare() }
        await baseGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let shutdown = Task {
            let report = await generator.shutdown()
            await completion.markCompleted()
            return report
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await baseGate.release()
        let report = await shutdown.value
        await XCTAssertThrowsCancellation { _ = try await preparation.value }

        let deleted = await client.deletedThreadIDs()
        let entries = try await fixture.journal.entries()
        let shutdownCount = await client.shutdownCallCount()
        XCTAssertEqual(deleted, ["base-1"])
        XCTAssertEqual(entries.first?.threadIDs, [])
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(shutdownCount, 1)
        await XCTAssertThrowsMeetingError(.notPrepared) {
            _ = try await generator.prepare()
        }
    }

    func testShutdownWaitsForLateForkThenJournalsAndDeletesIt() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let forkGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                try Self.json(
                    QuickModelOutput(
                        turnID: turn.identity.turnID,
                        generation: 1,
                        sayNow: "Let me verify the exact path.",
                        needsDeep: true,
                        confidence: 0.5,
                        reason: "technical"
                    )
                )
            ],
            forkCreationGate: forkGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await forkGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let shutdown = Task {
            let report = await generator.shutdown()
            await completion.markCompleted()
            return report
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await forkGate.release()
        let report = await shutdown.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }

        let deleted = await client.deletedThreadIDs()
        let quickTurnCount = await client.quickTurnCount()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(Set(deleted), Set(["base-1", "base-2", "fork-1"]))
        XCTAssertEqual(quickTurnCount, 0)
        XCTAssertEqual(entries.first?.threadIDs, [])
        XCTAssertEqual(report.deletedThreadCount, 2)
        XCTAssertEqual(report.failures, [])
    }

    func testCancelActiveWorkWaitsForLateForkThenReopensPreparedGenerator() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let forkGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            forkCreationGate: forkGate
        )
        let generator = fixture.generator(client: client)
        let preparedRuntime = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await forkGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let cancellation = Task {
            await generator.cancelActiveWork()
            await completion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await forkGate.release()
        await cancellation.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }

        let runtimeAfterCancellation = try await generator.prepare()
        let deleted = await client.deletedThreadIDs()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(runtimeAfterCancellation, preparedRuntime)
        XCTAssertTrue(deleted.contains("fork-1"))
        XCTAssertEqual(Set(entries.first?.threadIDs ?? []), Set(["base-1", "base-2"]))
        _ = await generator.shutdown()
    }

    func testCoalescedShutdownWaitsForLateDeepTurnHandleBeforeReportingClean() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let startTurnGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(fixture.deepDraft(for: turn))],
            startTurnGate: startTurnGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateDeep(for: turn) }
        await startTurnGate.waitUntilSuspended()

        let firstCompletion = CompletionProbe()
        let secondCompletion = CompletionProbe()
        let firstShutdown = Task {
            let report = await generator.shutdown()
            await firstCompletion.markCompleted()
            return report
        }
        let secondShutdown = Task {
            let report = await generator.shutdown()
            await secondCompletion.markCompleted()
            return report
        }
        for _ in 0..<100 { await Task.yield() }
        let firstCompletedBeforeRelease = await firstCompletion.isCompleted()
        let secondCompletedBeforeRelease = await secondCompletion.isCompleted()
        XCTAssertFalse(firstCompletedBeforeRelease)
        XCTAssertFalse(secondCompletedBeforeRelease)

        await startTurnGate.release()
        let firstReport = await firstShutdown.value
        let secondReport = await secondShutdown.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }

        let interrupted = await client.interruptedThreadIDs()
        let deleted = await client.deletedThreadIDs()
        let entries = try await fixture.journal.entries()
        let shutdownCount = await client.shutdownCallCount()
        XCTAssertEqual(interrupted, ["fork-1"])
        XCTAssertEqual(Set(deleted), Set(["base-1", "base-2", "fork-1"]))
        XCTAssertEqual(entries.first?.threadIDs, [])
        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(firstReport.deletedThreadCount, 2)
        XCTAssertEqual(firstReport.failures, [])
        XCTAssertEqual(shutdownCount, 1)
    }

    func testRealtimeQuickRejectsAdditionalJSONKeys() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let client = FakeMeetingCodexClient(
            realtime: true,
            quickOutputs: [
                """
                {"turnID":"\(turn.identity.turnID.uuidString)","generation":1,"sayNow":"Let me verify that.","needsDeep":true,"confidence":0.5,"reason":"technical","extra":"unsafe"}
                """
            ]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.invalidOutput) {
            _ = try await generator.generateQuick(for: turn)
        }
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
        _ = await generator.shutdown()
    }

    func testCancellationInterruptsAndDeletesTranscriptFork() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let startQuickGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            hangQuick: true,
            startQuickGate: startQuickGate
        )
        let generator = fixture.generator(client: client)
        let turn = fixture.turn(generation: 1)
        _ = try await generator.prepare()

        let task = Task { try await generator.generateQuick(for: turn) }
        await startQuickGate.waitUntilSuspended()
        let startedQuickCount = await client.quickTurnCount()
        XCTAssertEqual(startedQuickCount, 1)
        task.cancel()
        await startQuickGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let interrupted = await client.interruptedThreadIDs()
        let deleted = await client.deletedThreadIDs()
        XCTAssertEqual(interrupted, ["fork-1"])
        XCTAssertTrue(deleted.contains("fork-1"))
        _ = await generator.shutdown()
    }

    func testDeepEvidenceRejectionFailsClosedAndDeletesFork() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(fixture.deepDraft(for: turn))]
        )
        let verifier = FakeMeetingEvidenceVerifier(reject: true)
        let generator = fixture.generator(client: client, verifier: verifier)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.groundingMismatch) {
            _ = try await generator.generateDeep(for: turn)
        }
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
        _ = await generator.shutdown()
    }

    func testRepositoryFreeDeepReturnsClearlyGeneralAnswerWithoutEvidenceVerification() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn(generation: 1)
        let draft = fixture.generalDraft(for: turn)
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(draft)],
            ambientSkillEnabled: true
        )
        let verifier = FakeMeetingEvidenceVerifier()
        let generator = fixture.generator(
            client: client,
            verifier: verifier,
            includeGrounding: false
        )

        _ = try await generator.prepare()
        let generated = try await generator.generateDeep(for: turn)

        XCTAssertEqual(generated, draft)
        XCTAssertEqual(generated.kind, .generalAnswer)
        XCTAssertNil(generated.groundingFingerprint)
        XCTAssertTrue(generated.basis.isEmpty)
        let verificationCount = await verifier.verificationCount()
        let skillWrites = await client.skillWrites()
        XCTAssertEqual(verificationCount, 0)
        XCTAssertTrue(
            skillWrites.contains(where: {
                $0.name == "ambient-skill" && !$0.enabled
            })
        )
        _ = await generator.shutdown()
    }

    func testRepositoryFreeDeepRejectsEvidenceAnswerKind() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn(generation: 1)
        let invalid = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .answer,
            candidateSayNext: "The service definitely retries every request.",
            confidence: 0.9,
            basis: []
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(invalid)]
        )
        let generator = fixture.generator(client: client, includeGrounding: false)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.invalidOutput) {
            _ = try await generator.generateDeep(for: turn)
        }
        _ = await generator.shutdown()
    }

    func testRepositoryFreeDeepRejectsUnsupportedOrganizationClaim() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn(generation: 1)
        let invalid = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "Our system uses Kafka for every asynchronous workflow.",
            confidence: 0.9,
            basis: []
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(invalid)]
        )
        let generator = fixture.generator(client: client, includeGrounding: false)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.invalidOutput) {
            _ = try await generator.generateDeep(for: turn)
        }
        _ = await generator.shutdown()
    }

    func testRepositoryFreeDeepRejectsClosedGrammarBypassCorpus() async throws {
        let rejected = [
            "I would validate latency as acme leaks patient records.",
            "I would add monitoring after acme leaked patient records.",
            "I would validate latency or acme leaks patient records.",
            "I would compare latency between queues and acme leaks patient records.",
            "We should assess acme leaked patient records.",
            "I would treat acme compromised accounts as resolved.",
            "We should document our-system-leaks-patient-records.",
            "We can use patient records without consent.",
        ]

        for candidate in rejected {
            let fixture = try ResponseGeneratorFixture()
            defer { fixture.cleanup() }
            let turn = fixture.generalTurn(generation: 1)
            let invalid = DeepDraft(
                turnID: turn.identity.turnID,
                generation: turn.identity.generation,
                groundingFingerprint: nil,
                kind: .generalAnswer,
                candidateSayNext: candidate,
                confidence: 0.9,
                basis: []
            )
            let client = FakeMeetingCodexClient(
                realtime: false,
                turnOutputs: [try Self.json(invalid)]
            )
            let generator = fixture.generator(client: client, includeGrounding: false)
            _ = try await generator.prepare()

            await XCTAssertThrowsMeetingError(.invalidOutput) {
                _ = try await generator.generateDeep(for: turn)
            }
            let deleted = await client.deletedThreadIDs()
            XCTAssertTrue(deleted.contains("fork-1"), candidate)
            _ = await generator.shutdown()
        }
    }

    func testGroundedDeepRejectsGeneralAnswerKind() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let invalid = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: turn.groundingFingerprint,
            kind: .generalAnswer,
            candidateSayNext: "Broadly, I would separate the immediate path from retries.",
            confidence: 0.8,
            basis: []
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(invalid)]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.invalidOutput) {
            _ = try await generator.generateDeep(for: turn)
        }
        _ = await generator.shutdown()
    }

    func testUsageGovernorRejectsSecondQuickWithinWindow() async throws {
        let fixture = try ResponseGeneratorFixture(quickPerMinute: 1)
        defer { fixture.cleanup() }
        let first = fixture.turn(generation: 1)
        let output = QuickModelOutput(
            turnID: first.identity.turnID,
            generation: 1,
            sayNow: "Let me verify the exact path.",
            needsDeep: true,
            confidence: 0.5,
            reason: "technical"
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(output)]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        _ = try await generator.generateQuick(for: first)

        await XCTAssertThrowsMeetingError(.quickRateLimited) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        let forkCount = await client.forkCount()
        XCTAssertEqual(forkCount, 1)
        _ = await generator.shutdown()
    }

    func testAccountBindingMismatchFailsBeforeAnyThreadCreation() async throws {
        let fixture = try ResponseGeneratorFixture(expectedAccountIdentityHash: String(repeating: "0", count: 64))
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(realtime: false)
        let generator = fixture.generator(client: client)

        await XCTAssertThrowsMeetingError(.accountMismatch) {
            _ = try await generator.prepare()
        }
        let baseCount = await client.baseCount()
        let accountReadCount = await client.accountReadCount()
        let loginCount = await client.loginStartCount()
        XCTAssertEqual(baseCount, 0)
        XCTAssertEqual(accountReadCount, 1)
        XCTAssertEqual(loginCount, 0)
        _ = await generator.shutdown()
    }

    func testMatchingAccountBindingIsVerifiedBeforeThreadCreation() async throws {
        let normalizedEmail = "person@example.invalid"
        let identityHash = SHA256.hash(
            data: Data("chatgpt-email:\(normalizedEmail)".utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
        let fixture = try ResponseGeneratorFixture(expectedAccountIdentityHash: identityHash)
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(realtime: false)
        let generator = fixture.generator(client: client)

        let runtime = try await generator.prepare()
        let accountReadCount = await client.accountReadCount()
        let baseCount = await client.baseCount()
        let loginCount = await client.loginStartCount()

        XCTAssertEqual(runtime.planType, "pro")
        XCTAssertEqual(accountReadCount, 1)
        XCTAssertEqual(baseCount, 2)
        XCTAssertEqual(loginCount, 0)
        _ = await generator.shutdown()
    }

    func testMissingStableProfileCredentialsFailWithoutStartingLogin() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(realtime: false, signedIn: false)
        let generator = fixture.generator(client: client)

        do {
            _ = try await generator.prepare()
            XCTFail("Expected OS credential-store failure.")
        } catch let error as MeetingResponseError {
            XCTAssertEqual(error, .credentialStoreUnavailable)
        }
        let baseCount = await client.baseCount()
        let accountReadCount = await client.accountReadCount()
        let loginCount = await client.loginStartCount()
        XCTAssertEqual(baseCount, 0)
        XCTAssertEqual(accountReadCount, 1)
        XCTAssertEqual(loginCount, 0)

        let signInJournalEntries = try await fixture.journal.entries()
        let entry = try XCTUnwrap(signInJournalEntries.first)
        let quickRoot = fixture.meetingRoot.appendingPathComponent(
            "quick-context",
            isDirectory: true
        )
        let skillRoot = fixture.meetingRoot.appendingPathComponent(
            "skill-context",
            isDirectory: true
        )
        let temporaryRoot = fixture.meetingRoot.appendingPathComponent(
            "codex-tmp",
            isDirectory: true
        )
        XCTAssertTrue(entry.snapshotRoots.contains(quickRoot.standardizedFileURL))
        XCTAssertTrue(entry.snapshotRoots.contains(skillRoot.standardizedFileURL))
        XCTAssertTrue(entry.snapshotRoots.contains(temporaryRoot.standardizedFileURL))
        XCTAssertTrue(entry.expectedThreadCwds.contains(quickRoot.standardizedFileURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quickRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.profileRoot.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.profileRoot.appendingPathComponent("auth.json").path
            )
        )
        _ = await generator.shutdown()
    }

    func testGenerationFailsClosedBeforeLaunchWhenProfileContainsCredentialFile() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.profileRoot,
            withIntermediateDirectories: true
        )
        try Data("must-not-copy".utf8).write(
            to: fixture.profileRoot.appendingPathComponent("auth.json")
        )
        let recorder = CodexConfigurationRecorder()
        let client = FakeMeetingCodexClient(realtime: false)
        let generator = fixture.generator(client: client, configurationRecorder: recorder)

        do {
            _ = try await generator.prepare()
            XCTFail("Expected file-backed credential rejection.")
        } catch let error as MeetingResponseError {
            XCTAssertEqual(error, .runtimeUnavailable)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.meetingRoot.appendingPathComponent("auth.json").path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.profileRoot.appendingPathComponent("auth.json")),
            Data("must-not-copy".utf8)
        )
        let recordedConfiguration = await recorder.configuration()
        XCTAssertNil(recordedConfiguration)
        let accountReadCount = await client.accountReadCount()
        XCTAssertEqual(accountReadCount, 0)
        let entries = try await fixture.journal.entries()
        XCTAssertFalse(try XCTUnwrap(entries.first).snapshotRoots.contains(fixture.profileRoot))
        _ = await generator.shutdown()
    }

    func testIsolatedRuntimeWritesPrivateLockedConfigAndScrubsSecrets() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-isolation-test-\(UUID().uuidString)", isDirectory: true)
        let root = testRoot.appendingPathComponent("profile", isDirectory: true)
        let trustedHome = testRoot.appendingPathComponent("user-home", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let runtime = try CodexIsolatedRuntimeBuilder.prepare(
            profileRoot: root,
            userHomeDirectory: trustedHome,
            inheritedEnvironment: [
                "HOME": "/untrusted/inherited/home",
                "TMPDIR": "/tmp/example/",
                "LANG": "en_US.UTF-8",
                "GH_TOKEN": "secret",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "HTTPS_PROXY": "http://proxy.invalid",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
            ]
        )

        let rootMode = try Self.mode(runtime.profileRoot)
        let configMode = try Self.mode(runtime.configurationURL)
        XCTAssertEqual(rootMode, 0o700)
        XCTAssertEqual(configMode, 0o600)
        XCTAssertEqual(runtime.processEnvironment["CODEX_HOME"], root.path)
        XCTAssertEqual(runtime.processEnvironment["HOME"], trustedHome.path)
        XCTAssertNotEqual(
            runtime.processEnvironment["HOME"],
            runtime.processEnvironment["CODEX_HOME"]
        )
        XCTAssertEqual(
            runtime.processEnvironment["TMPDIR"],
            root.appendingPathComponent("tmp", isDirectory: true).path
        )
        XCTAssertNil(runtime.processEnvironment["GH_TOKEN"])
        XCTAssertNil(runtime.processEnvironment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(runtime.processEnvironment["HTTPS_PROXY"])
        XCTAssertNil(runtime.processEnvironment["SSH_AUTH_SOCK"])
        XCTAssertTrue(
            runtime.processEnvironment["PATH"]?.hasPrefix(
                "/Applications/ChatGPT.app/Contents/Resources:"
            ) == true)

        let config = try String(contentsOf: runtime.configurationURL, encoding: .utf8)
        XCTAssertTrue(config.contains("cli_auth_credentials_store = \"keyring\""))
        XCTAssertTrue(config.contains("persistence = \"none\""))
        XCTAssertTrue(config.contains("plugins = false"))
        XCTAssertTrue(config.contains("remote_plugin = false"))
        XCTAssertTrue(config.contains("default_permissions = \"pacenote-readonly\""))
        XCTAssertTrue(config.contains("\":root\" = \"deny\""))
        XCTAssertTrue(config.contains("\".\" = \"read\""))
        XCTAssertTrue(config.contains("enabled = false"))
        XCTAssertTrue(runtime.processArguments.contains("--strict-config"))
    }

    func testIsolatedRuntimeRejectsFileBackedCredentialsBeforeWritingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pacenote-credential-rejection-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let credentialURL = root.appendingPathComponent("auth.json")
        try Data("credential-canary".utf8).write(to: credentialURL)

        XCTAssertThrowsError(
            try CodexIsolatedRuntimeBuilder.prepare(profileRoot: root)
        ) { error in
            XCTAssertEqual(
                error as? CodexIsolatedRuntimeError,
                .credentialMaterialPresent("auth.json")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("config.toml").path
            )
        )
        XCTAssertEqual(try Data(contentsOf: credentialURL), Data("credential-canary".utf8))
    }

    func testGeneratedIsolationConfigStartsPinnedStrictAppServerWithoutGeneration() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_RUN_CODEX_ISOLATION_SMOKE"] == "1" else {
            throw XCTSkip("Set PACENOTE_RUN_CODEX_ISOLATION_SMOKE=1 for the zero-generation strict-config probe.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-isolation-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try CodexIsolatedRuntimeBuilder.prepare(profileRoot: root)
        let client = try await CodexAppServerClient.connect(
            configuration: .init(
                expectedCodexHome: isolated.profileRoot,
                clientVersion: "0.1.0",
                permissionProfileID: isolated.permissionProfileID,
                processArguments: isolated.processArguments,
                processEnvironment: isolated.processEnvironment
            )
        )
        let account = try await client.account(refreshToken: false)
        XCTAssertEqual(account.account?.type, "chatgpt")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("auth.json").path
            )
        )
        let profiles = try await client.listPermissionProfiles(cwd: root.path)
        XCTAssertTrue(
            profiles.contains {
                $0.id == isolated.permissionProfileID && $0.allowed
            })
        let meetingRoot = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingRoot, withIntermediateDirectories: true)
        let skillRoot = try PackagedMeetingSkillStager.prepare(in: meetingRoot)
        try await client.setSkillExtraRoots([skillRoot.path])
        let skills = try await client.listSkills(cwds: [root.path], forceReload: true)
        XCTAssertTrue(
            skills.data.flatMap(\.skills).contains {
                $0.name == PackagedMeetingCoachSkill.name
                    && URL(fileURLWithPath: $0.path).standardizedFileURL
                        == skillRoot.appendingPathComponent("SKILL.md").standardizedFileURL
            })
        await client.shutdown()
    }

    func testStablePaceNoteProfileZeroGenerationFootprint() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_INSPECT_STABLE_PROFILE"] == "1" else {
            throw XCTSkip("Set PACENOTE_INSPECT_STABLE_PROFILE=1 for the stable-profile footprint probe.")
        }
        let fileManager = FileManager.default
        let supportRoot = try XCTUnwrap(
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let profileRoot =
            supportRoot
            .appendingPathComponent("PaceNote/Profiles/personal", isDirectory: true)
            .standardizedFileURL
        let profileLease = try CodexProfileLease.acquire(profileRoot: profileRoot)
        defer { withExtendedLifetime(profileLease) {} }
        let applicationRoot = profileRoot.deletingLastPathComponent().deletingLastPathComponent()
        let cleanupJournal = try CleanupJournalStore(
            journalURL:
                applicationRoot
                .appendingPathComponent("State/cleanup-journal.json", isDirectory: false),
            allowedRoot: applicationRoot
        )
        guard try await cleanupJournal.entries().isEmpty else {
            throw StableProfileInspectionError.pendingCleanupExists
        }
        let isolated = try CodexIsolatedRuntimeBuilder.prepare(profileRoot: profileRoot)
        let client = try await CodexAppServerClient.connect(
            configuration: .init(
                expectedCodexHome: isolated.profileRoot,
                clientVersion: "0.1.0",
                permissionProfileID: isolated.permissionProfileID,
                processArguments: isolated.processArguments,
                processEnvironment: isolated.processEnvironment
            )
        )
        do {
            _ = try await client.account(refreshToken: false)
            _ = try? await client.listModels(includeHidden: false)
            _ = try await client.listPermissionProfiles(cwd: profileRoot.path)
            _ = try? await client.listSkills(cwds: [profileRoot.path], forceReload: true)
            _ = try? await client.rateLimits()
            await client.shutdown()
        } catch {
            await client.shutdown()
            _ = try? CodexStableProfileSanitizer().cleanTransientState(
                profileRoot: profileRoot
            )
            throw error
        }
        _ = try CodexStableProfileSanitizer().cleanTransientState(
            profileRoot: profileRoot
        )
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    func testIsolatedRuntimeRejectsUsingTheCodexProfileAsUserHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pacenote-keychain-home-rejection-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try CodexIsolatedRuntimeBuilder.prepare(
                profileRoot: root,
                userHomeDirectory: root
            )
        ) { error in
            XCTAssertEqual(error as? CodexIsolatedRuntimeError, .invalidUserHome)
        }
    }
}

private enum StableProfileInspectionError: Error {
    case pendingCleanupExists
}

private struct ResponseGeneratorFixture {
    let root: URL
    let meetingRoot: URL
    let profileRoot: URL
    let sourceRoot: URL
    let snapshot: GroundingSnapshot
    let journal: CleanupJournalStore
    let quickPerMinute: Int
    let expectedAccountIdentityHash: String?

    init(quickPerMinute: Int = 8, expectedAccountIdentityHash: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-response-test-\(UUID().uuidString)", isDirectory: true)
        meetingRoot = root.appendingPathComponent("meeting", isDirectory: true)
        profileRoot = root.appendingPathComponent("profile", isDirectory: true)
        sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let snapshotRoot = meetingRoot.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        try Data("Use exact queue evidence.\n".utf8).write(
            to: snapshotRoot.appendingPathComponent("AGENTS.md")
        )
        try Data("let queue = \"isolates slow work\"\n".utf8).write(
            to: snapshotRoot.appendingPathComponent("Queue.swift")
        )
        try Data("Use exact queue evidence.\n".utf8).write(
            to: sourceRoot.appendingPathComponent("AGENTS.md")
        )
        try Data("let queue = \"isolates slow work\"\n".utf8).write(
            to: sourceRoot.appendingPathComponent("Queue.swift")
        )

        let agentHash = try Self.hash(snapshotRoot.appendingPathComponent("AGENTS.md"))
        let queueHash = try Self.hash(snapshotRoot.appendingPathComponent("Queue.swift"))
        let manifest = GroundingManifest(entries: [
            .init(relativePath: "AGENTS.md", byteCount: 26, sha256: agentHash),
            .init(relativePath: "Queue.swift", byteCount: 33, sha256: queueHash),
        ])
        let inspection = GroundingInspection(
            branch: "main",
            head: "test",
            worktreeFingerprint: "worktree",
            manifest: manifest,
            groundingFingerprint: "grounding-test",
            hardExclusions: [],
            softFindings: [],
            acceptedApprovals: [],
            instructionSources: [
                .init(
                    relativePath: "AGENTS.md",
                    scopeRelativePath: "",
                    fileHash: agentHash,
                    kind: .standard
                )
            ]
        )
        snapshot = GroundingSnapshot(
            id: UUID(),
            repoAlias: "demo",
            sourceRoot: sourceRoot,
            snapshotRoot: snapshotRoot,
            createdAt: Date(),
            inspection: inspection
        )
        journal = try CleanupJournalStore(
            journalURL: root.appendingPathComponent("journal/cleanup.json"),
            allowedRoot: root
        )
        self.quickPerMinute = quickPerMinute
        self.expectedAccountIdentityHash = expectedAccountIdentityHash
    }

    func generator(
        client: FakeMeetingCodexClient,
        verifier: any MeetingEvidenceVerifying = FakeMeetingEvidenceVerifier(),
        configurationRecorder: CodexConfigurationRecorder? = nil,
        includeGrounding: Bool = true
    ) -> CodexMeetingResponseGenerator {
        CodexMeetingResponseGenerator(
            configuration: .init(
                meetingID: UUID(),
                meetingPrivateRoot: meetingRoot,
                codexProfileRoot: profileRoot,
                clientVersion: "0.1.0",
                expectedAccountIdentityHash: expectedAccountIdentityHash,
                groundingSnapshot: includeGrounding ? snapshot : nil,
                quickPerMinute: quickPerMinute
            ),
            journal: journal,
            evidenceVerifier: verifier,
            clientFactory: { configuration in
                await configurationRecorder?.record(configuration)
                return client
            }
        )
    }

    func turn(generation: UInt64) -> ConversationTurn {
        ConversationTurn(
            identity: .init(meetingID: UUID(), generation: generation),
            question: "Why do we use the queue?",
            recentTranscript: [
                .init(
                    source: .them,
                    text: "Why do we use the queue?",
                    startedAt: 0,
                    endedAt: 1,
                    isFinal: true,
                    confidence: 0.98
                )
            ],
            repoAlias: snapshot.repoAlias,
            groundingFingerprint: snapshot.groundingFingerprint
        )
    }

    func generalTurn(generation: UInt64) -> ConversationTurn {
        ConversationTurn(
            identity: .init(meetingID: UUID(), generation: generation),
            question: "How should I explain the tradeoff?",
            recentTranscript: [
                .init(
                    source: .them,
                    text: "How should I explain the tradeoff?",
                    startedAt: 0,
                    endedAt: 1,
                    isFinal: true,
                    confidence: 0.98
                )
            ]
        )
    }

    func deepDraft(for turn: ConversationTurn) -> DeepDraft {
        DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: snapshot.groundingFingerprint,
            kind: .answer,
            candidateSayNext: "The queue isolates slow work from the request path.",
            confidence: 0.9,
            basis: [
                .init(
                    repoAlias: snapshot.repoAlias,
                    relativePath: "Queue.swift",
                    startLine: 1,
                    endLine: 1,
                    fileHash: snapshot.manifest["Queue.swift"]!.sha256,
                    claim: "The queue isolates slow work."
                )
            ]
        )
    }

    func generalDraft(for turn: ConversationTurn) -> DeepDraft {
        DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I would separate the immediate decision from implementation details.",
            confidence: 0.72,
            basis: []
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private actor CodexConfigurationRecorder {
    private var value: CodexAppServerConfiguration?

    func record(_ configuration: CodexAppServerConfiguration) {
        value = configuration
    }

    func configuration() -> CodexAppServerConfiguration? {
        value
    }
}

private actor FakeMeetingEvidenceVerifier: MeetingEvidenceVerifying {
    private let reject: Bool
    private let candidateMismatchOnFirstCall: Bool
    private var count = 0
    private var candidates: [String] = []

    init(reject: Bool = false, candidateMismatchOnFirstCall: Bool = false) {
        self.reject = reject
        self.candidateMismatchOnFirstCall = candidateMismatchOnFirstCall
    }

    func isFresh(_ snapshot: GroundingSnapshot) async -> Bool { true }

    func verifyAnswer(
        candidateSayNext: String,
        _ references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot
    ) async throws {
        count += 1
        candidates.append(candidateSayNext)
        if candidateMismatchOnFirstCall, count == 1 {
            throw EvidenceVerificationError.candidateNotSupported
        }
        if reject {
            throw EvidenceVerificationError.claimNotSupported(
                references.first?.relativePath ?? "evidence"
            )
        }
    }

    func verificationCount() -> Int { count }
    func verifiedCandidates() -> [String] { candidates }
}

private actor SuspendedCallGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        suspended = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor CompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor FakeMeetingCodexClient: CodexMeetingClient {
    nonisolated let runtimeCapabilities: CodexRuntimeCapabilities

    struct SkillWrite: Equatable {
        let name: String
        let enabled: Bool
    }

    private var quickOutputs: [String]
    private var turnOutputs: [String]
    private var extraSkillRoot: String?
    private var ambientSkillEnabled: Bool
    private let hangQuick: Bool
    private let signedIn: Bool
    private let invalidBaseCwd: Bool
    private let baseCreationGate: SuspendedCallGate?
    private let forkCreationGate: SuspendedCallGate?
    private let startQuickGate: SuspendedCallGate?
    private let startTurnGate: SuspendedCallGate?
    private let confirmsAbsentAfterDeleteFailure: Bool
    private var deletionFailuresRemaining: Int
    private var nextBase = 1
    private var nextFork = 1
    private var deleted: [String] = []
    private var interrupted: [String] = []
    private var writes: [SkillWrite] = []
    private var quickTurns = 0
    private var realtimeStops = 0
    private var loginStarts = 0
    private var accountReads = 0
    private var deleteAttempts = 0
    private var shutdownCalls = 0
    private var hangingContinuations: [String: AsyncThrowingStream<CodexTurnEvent, any Error>.Continuation] = [:]

    init(
        realtime: Bool,
        quickOutputs: [String] = [],
        turnOutputs: [String] = [],
        ambientSkillEnabled: Bool = false,
        hangQuick: Bool = false,
        signedIn: Bool = true,
        invalidBaseCwd: Bool = false,
        baseCreationGate: SuspendedCallGate? = nil,
        forkCreationGate: SuspendedCallGate? = nil,
        startQuickGate: SuspendedCallGate? = nil,
        startTurnGate: SuspendedCallGate? = nil,
        deletionFailuresRemaining: Int = 0,
        confirmsAbsentAfterDeleteFailure: Bool = false
    ) {
        runtimeCapabilities = .init(realtimeTextV3: realtime)
        self.quickOutputs = quickOutputs
        self.turnOutputs = turnOutputs
        self.ambientSkillEnabled = ambientSkillEnabled
        self.hangQuick = hangQuick
        self.signedIn = signedIn
        self.invalidBaseCwd = invalidBaseCwd
        self.baseCreationGate = baseCreationGate
        self.forkCreationGate = forkCreationGate
        self.startQuickGate = startQuickGate
        self.startTurnGate = startTurnGate
        self.deletionFailuresRemaining = deletionFailuresRemaining
        self.confirmsAbsentAfterDeleteFailure = confirmsAbsentAfterDeleteFailure
    }

    func account(refreshToken: Bool) async throws -> CodexAccountReadResult {
        accountReads += 1
        return CodexAccountReadResult(
            account: signedIn
                ? CodexAccount(type: "chatgpt", email: "person@example.invalid", planType: "pro")
                : nil,
            requiresOpenaiAuth: true
        )
    }

    func startChatGPTLogin(useHostedLoginSuccessPage: Bool) async throws -> CodexChatGPTLogin {
        loginStarts += 1
        return CodexChatGPTLogin(
            type: "chatgpt",
            loginId: "login",
            authUrl: "https://example.invalid/login"
        )
    }

    func logout() async throws {}

    func verifyCapabilities(cwd: String) async throws -> CodexCapabilitySnapshot {
        CodexCapabilitySnapshot(
            models: [
                Self.model("gpt-5.6-luna", efforts: ["low"]),
                Self.model("gpt-5.6-terra", efforts: ["medium"]),
            ],
            permissionProfiles: [
                CodexPermissionProfile(id: "pacenote-readonly", description: nil, allowed: true)
            ],
            skills: []
        )
    }

    func rateLimits() async throws -> CodexRateLimitsResult {
        try CodexFixtures.value(CodexFixtures.rateLimitsResult).decode(CodexRateLimitsResult.self)
    }

    func listSkills(cwds: [String], forceReload: Bool) async throws -> CodexSkillsResult {
        let cwd = cwds[0]
        var skills: [CodexSkill] = []
        if let extraSkillRoot {
            skills.append(
                CodexSkill(
                    name: PackagedMeetingCoachSkill.name,
                    description: "Meeting coach",
                    path: URL(fileURLWithPath: extraSkillRoot).appendingPathComponent("SKILL.md").path,
                    scope: "extra",
                    enabled: true,
                    interface: nil,
                    dependencies: nil
                )
            )
        }
        skills.append(
            CodexSkill(
                name: "ambient-skill",
                description: "Ambient",
                path: URL(fileURLWithPath: cwd).appendingPathComponent("ambient/SKILL.md").path,
                scope: "repo",
                enabled: ambientSkillEnabled,
                interface: nil,
                dependencies: nil
            )
        )
        return CodexSkillsResult(
            data: [CodexSkillsListEntry(cwd: cwd, skills: skills, errors: [])]
        )
    }

    func setSkillExtraRoots(_ roots: [String]) async throws {
        extraSkillRoot = roots.first
    }

    func setSkillEnabled(
        name: String,
        path: String,
        enabled: Bool
    ) async throws -> CodexSkillsConfigWriteResult {
        writes.append(.init(name: name, enabled: enabled))
        if name == "ambient-skill" { ambientSkillEnabled = enabled }
        return CodexSkillsConfigWriteResult(effectiveEnabled: enabled)
    }

    func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?
    ) async throws -> CodexBaseThread {
        let id = "base-\(nextBase)"
        nextBase += 1
        if let baseCreationGate {
            await baseCreationGate.suspend()
        }
        let sources =
            cwd.contains("quick-context")
            ? []
            : [URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md").path]
        return CodexBaseThread(
            id: id,
            model: model,
            permissionProfileID: "pacenote-readonly",
            cwd: invalidBaseCwd ? cwd + "/unexpected" : cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            instructionSources: sources
        )
    }

    func forkEphemeral(from base: CodexBaseThread, model: String?) async throws
        -> CodexEphemeralThread
    {
        let id = "fork-\(nextFork)"
        nextFork += 1
        if let forkCreationGate {
            await forkCreationGate.suspend()
        }
        return CodexEphemeralThread(
            id: id,
            baseThreadID: base.id,
            model: model ?? base.model,
            permissionProfileID: "pacenote-readonly",
            cwd: base.cwd,
            runtimeWorkspaceRoots: base.runtimeWorkspaceRoots,
            instructionSources: base.instructionSources
        )
    }

    func deleteThread(id: String) async throws {
        deleteAttempts += 1
        if deletionFailuresRemaining > 0 {
            deletionFailuresRemaining -= 1
            throw CodexClientError.transportUnavailable
        }
        deleted.append(id)
        hangingContinuations.removeValue(forKey: id)?.finish(throwing: CancellationError())
    }

    func listThreadIDs(cwd: String) async throws -> [String] {
        guard confirmsAbsentAfterDeleteFailure else {
            throw CodexClientError.transportUnavailable
        }
        return []
    }

    func startQuick(
        threadID: String,
        text: String,
        realtimePrompt: String,
        model: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexQuickSession {
        if runtimeCapabilities.realtimeTextV3 {
            let output = quickOutputs.removeFirst()
            let pair = AsyncThrowingStream<CodexRealtimeEvent, any Error>.makeStream()
            pair.continuation.yield(.transcriptDone(role: "assistant", text: output))
            return .realtime(.init(threadID: threadID, events: pair.stream))
        }
        quickTurns += 1
        if let startQuickGate {
            await startQuickGate.suspend()
        }
        if hangQuick {
            let pair = AsyncThrowingStream<CodexTurnEvent, any Error>.makeStream()
            hangingContinuations[threadID] = pair.continuation
            return .turn(.init(threadID: threadID, turnID: "turn-quick", events: pair.stream))
        }
        return .turn(Self.completedTurn(threadID: threadID, output: quickOutputs.removeFirst()))
    }

    func startTurn(
        threadID: String,
        text: String,
        model: String?,
        effort: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexTurnSession {
        let session = Self.completedTurn(threadID: threadID, output: turnOutputs.removeFirst())
        if let startTurnGate {
            await startTurnGate.suspend()
        }
        return session
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        interrupted.append(threadID)
        hangingContinuations.removeValue(forKey: threadID)?.finish(throwing: CancellationError())
    }

    func stopRealtimeText(threadID: String) async throws { realtimeStops += 1 }
    func shutdown() async { shutdownCalls += 1 }

    func skillWrites() -> [SkillWrite] { writes }
    func deletedThreadIDs() -> [String] { deleted }
    func interruptedThreadIDs() -> [String] { interrupted }
    func quickTurnCount() -> Int { quickTurns }
    func realtimeStopCount() -> Int { realtimeStops }
    func loginStartCount() -> Int { loginStarts }
    func accountReadCount() -> Int { accountReads }
    func baseCount() -> Int { nextBase - 1 }
    func forkCount() -> Int { nextFork - 1 }
    func deleteAttemptCount() -> Int { deleteAttempts }
    func shutdownCallCount() -> Int { shutdownCalls }

    private static func completedTurn(threadID: String, output: String) -> CodexTurnSession {
        let pair = AsyncThrowingStream<CodexTurnEvent, any Error>.makeStream()
        pair.continuation.yield(
            .itemCompleted([
                "type": "agentMessage",
                "text": .string(output),
                "phase": "final_answer",
            ]))
        pair.continuation.yield(.completed(status: "completed"))
        pair.continuation.finish()
        return CodexTurnSession(threadID: threadID, turnID: UUID().uuidString, events: pair.stream)
    }

    private static func model(_ name: String, efforts: [String]) -> CodexModel {
        CodexModel(
            id: name,
            model: name,
            displayName: name,
            hidden: false,
            supportedReasoningEfforts: efforts.map {
                .init(reasoningEffort: $0, description: $0)
            },
            defaultReasoningEffort: efforts.first,
            inputModalities: ["text"],
            supportsPersonality: false,
            serviceTiers: nil,
            defaultServiceTier: nil,
            isDefault: false
        )
    }
}

private func XCTAssertThrowsMeetingError<T>(
    _ expected: MeetingResponseError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as MeetingResponseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected MeetingResponseError, received \(error).", file: file, line: line)
    }
}

private func XCTAssertThrowsCancellation<T>(
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected cancellation.", file: file, line: line)
    } catch is CancellationError {
    } catch {
        XCTFail("Expected CancellationError, received \(error).", file: file, line: line)
    }
}
