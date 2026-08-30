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

    func testTwoDeepAnswersCanRunOnIndependentEphemeralThreads() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let firstTurn = fixture.turn(generation: 1)
        let secondTurn = fixture.turn(generation: 2)
        let gate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [
                try Self.json(fixture.deepDraft(for: firstTurn)),
                try Self.json(fixture.deepDraft(for: secondTurn)),
            ],
            startTurnGate: gate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let first = Task { try await generator.generateDeep(for: firstTurn) }
        await gate.waitUntilSuspended()
        let second = Task { try await generator.generateDeep(for: secondTurn) }

        let bothStarted = await Self.eventually {
            await client.turnStartCount() == 2
        }
        XCTAssertTrue(bothStarted)
        await gate.release()

        let firstDraft = try await first.value
        let secondDraft = try await second.value
        XCTAssertEqual(firstDraft.turnID, firstTurn.identity.turnID)
        XCTAssertEqual(secondDraft.turnID, secondTurn.identity.turnID)
        _ = await generator.shutdown()
    }

    func testPreparationCanSkipUnusedSubscriptionQuickBase() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(realtime: true)
        let generator = fixture.generator(
            client: client,
            subscriptionQuickEnabled: false
        )

        let runtime = try await generator.prepare()
        let entries = try await fixture.journal.entries()

        XCTAssertFalse(runtime.usesRealtimeQuick)
        XCTAssertEqual(entries.first?.threadIDs, ["base-1"])
        await XCTAssertThrowsMeetingError(.notPrepared) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }

        let report = await generator.shutdown()
        XCTAssertEqual(report.deletedThreadCount, 1)
        XCTAssertEqual(report.failures, [])
    }

    func testDirectPreparationPublishesRuntimeBeforeQuickTemplateWarmupCompletes() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let gate = SuspendedCallGate()
        let runtimeReady = expectation(description: "runtime published before Quick warm-up")
        let client = FakeMeetingCodexClient(
            realtime: false,
            directEphemeralResponses: true,
            baseCreationGate: gate
        )
        let generator = fixture.generator(client: client)

        let preparation = Task {
            let runtime = try await generator.prepare()
            runtimeReady.fulfill()
            return runtime
        }

        await gate.waitUntilSuspended()
        await fulfillment(
            of: [runtimeReady],
            timeout: 1,
            enforceOrder: true
        )

        await gate.release()
        _ = try await preparation.value

        // Quick completion starts the serialized Deep warm-up. Release that explicit gate too so
        // shutdown can prove every background preparation operation was joined.
        await gate.waitUntilSuspended()
        await gate.release()
        let report = await generator.shutdown()
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testStableSubscriptionQuickCanDisableExperimentalRealtimeTransport() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let recorder = CodexConfigurationRecorder()
        let client = FakeMeetingCodexClient(realtime: true)
        let generator = fixture.generator(
            client: client,
            configurationRecorder: recorder,
            realtimeQuickEnabled: false
        )

        let runtime = try await generator.prepare()
        let capturedConfiguration = await recorder.configuration()
        let recordedConfiguration = try XCTUnwrap(capturedConfiguration)

        XCTAssertFalse(runtime.usesRealtimeQuick)
        XCTAssertFalse(recordedConfiguration.enableRealtimeQuick)
        _ = await generator.shutdown()
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
            sayNow: "I’d give the general shape now, then verify the implementation.",
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
        try await generator.awaitQuickCleanup(for: turn.identity)
        let realtimeStopCount = await client.realtimeStopCount()
        let quickTurnCount = await client.quickTurnCount()
        XCTAssertTrue(runtime.usesRealtimeQuick)
        XCTAssertEqual(generated, output)
        XCTAssertEqual(realtimeStopCount, 1)
        XCTAssertEqual(quickTurnCount, 0)
        _ = await generator.shutdown()
    }

    func testRealtimeBackendFailureRetriesQuickOnStableTurnPath() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 3)
        let output = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: 3,
            sayNow: "I’d clarify the constraint, then give the safest reversible default.",
            needsDeep: true,
            confidence: 0.68,
            reason: "realtime fallback"
        )
        let client = FakeMeetingCodexClient(
            realtime: true,
            turnOutputs: [try Self.json(output)],
            realtimeStreamErrors: [
                .requestFailed(method: "thread/realtime", code: -32_000)
            ]
        )
        let generator = fixture.generator(client: client)

        _ = try await generator.prepare()
        let generated = try await generator.generateQuick(for: turn)
        try await generator.awaitQuickCleanup(for: turn.identity)
        let disableCount = await client.realtimeDisableCount()
        let stopCount = await client.realtimeStopCount()
        let turnStartCount = await client.turnStartCount()

        XCTAssertEqual(generated, output)
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(turnStartCount, 1)
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

    func testDeepCreatedThreadFailureNeverPublishesQuickOnlyRuntimeOrClosesCleanupClient()
        async throws
    {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(
            realtime: false,
            createdBaseFailureNumber: 2
        )
        let generator = fixture.generator(client: client)

        await XCTAssertThrowsMeetingError(.protocolUnsupported) {
            _ = try await generator.prepare()
        }
        let basesAfterFailure = await client.baseCount()
        let shutdownsAfterFailure = await client.shutdownCallCount()
        let deletedAfterFailure = await client.deletedThreadIDs()
        XCTAssertEqual(basesAfterFailure, 2)
        XCTAssertEqual(shutdownsAfterFailure, 0)
        XCTAssertEqual(deletedAfterFailure, ["base-2"])

        await XCTAssertThrowsMeetingError(.protocolUnsupported) {
            _ = try await generator.prepare()
        }
        let basesAfterRetry = await client.baseCount()
        XCTAssertEqual(basesAfterRetry, 2)

        let report = await generator.shutdown()
        let finalShutdowns = await client.shutdownCallCount()
        let finalDeleted = await client.deletedThreadIDs()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(finalShutdowns, 1)
        XCTAssertEqual(Set(finalDeleted), Set(["base-1", "base-2"]))
    }

    func testForkCreatedThreadInvariantFailureBlocksLaterInferenceWithoutClosingCleanupClient()
        async throws
    {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(
            realtime: false,
            createdForkFailureNumber: 1
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.protocolUnsupported) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        let shutdownsAfterFailure = await client.shutdownCallCount()
        let forksAfterFailure = await client.forkCount()
        let deletedAfterFailure = await client.deletedThreadIDs()
        XCTAssertEqual(shutdownsAfterFailure, 0)
        XCTAssertEqual(forksAfterFailure, 1)
        XCTAssertEqual(deletedAfterFailure, ["fork-1"])

        await XCTAssertThrowsMeetingError(.protocolUnsupported) {
            _ = try await generator.generateDeep(for: fixture.turn(generation: 2))
        }
        let forksAfterRetry = await client.forkCount()
        XCTAssertEqual(forksAfterRetry, 1)

        let report = await generator.shutdown()
        let finalShutdowns = await client.shutdownCallCount()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(finalShutdowns, 1)
    }

    func testEphemeralDeleteFailureIsReconciledOnlyAfterExactCwdAbsence() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 4)
        let output = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: "I’d give the general shape now, then verify the implementation.",
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
        try await generator.awaitQuickCleanup(for: turn.identity)
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

    func testCancelActiveWorkJoinsLateQuickStartBeforeDeletingFork() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let startGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                try Self.json(
                    QuickModelOutput(
                        turnID: turn.identity.turnID,
                        generation: turn.identity.generation,
                        sayNow: "I would separate the decision from the implementation detail.",
                        needsDeep: true,
                        confidence: 0.8,
                        reason: "technical"
                    )
                )
            ],
            startQuickGate: startGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await startGate.waitUntilSuspended()
        let completion = CompletionProbe()
        let cancellation = Task {
            await generator.cancelActiveWork()
            await completion.markCompleted()
        }

        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        let deletedBeforeRelease = await client.deletedThreadIDs()
        XCTAssertFalse(completedBeforeRelease)
        XCTAssertTrue(deletedBeforeRelease.isEmpty)

        await startGate.release()
        await cancellation.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
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

    func testRealtimeQuickAdditionalKeysFallBackToStrictOrdinaryTurn() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let fallback = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: 1,
            sayNow: "I’d clarify the constraint, then give the safest reversible default.",
            needsDeep: true,
            confidence: 0.7,
            reason: "strict fallback"
        )
        let client = FakeMeetingCodexClient(
            realtime: true,
            quickOutputs: [
                """
                {"turnID":"\(turn.identity.turnID.uuidString)","generation":1,"sayNow":"Let me verify that.","needsDeep":true,"confidence":0.5,"reason":"technical","extra":"unsafe"}
                """
            ],
            turnOutputs: [try Self.json(fallback)]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generated = try await generator.generateQuick(for: turn)
        try await generator.awaitQuickCleanup(for: turn.identity)
        let deleted = await client.deletedThreadIDs()
        let disableCount = await client.realtimeDisableCount()
        let ordinaryTurnCount = await client.turnStartCount()

        XCTAssertEqual(generated, fallback)
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(ordinaryTurnCount, 1)
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

    func testCancelActiveWorkCancelsPendingQuickStartWithoutTransportTimeout() async throws {
        let fixture = try ResponseGeneratorFixture(quickPerMinute: 1)
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let replacementTurn = fixture.turn(generation: 2)
        let startGate = CancellationAwareCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                try Self.json(
                    QuickModelOutput(
                        turnID: replacementTurn.identity.turnID,
                        generation: replacementTurn.identity.generation,
                        sayNow: "I would separate the decision from the implementation detail.",
                        needsDeep: true,
                        confidence: 0.8,
                        reason: "technical"
                    )
                )
            ],
            cancellationAwareStartQuickGate: startGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await startGate.waitUntilSuspended()
        let completion = CompletionProbe()
        let cancellation = Task {
            await generator.cancelActiveWork()
            await completion.markCompleted()
        }

        for _ in 0..<100 {
            if await completion.isCompleted() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let completedPromptly = await completion.isCompleted()
        if !completedPromptly {
            await startGate.release()
        }

        await cancellation.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }
        XCTAssertTrue(completedPromptly)
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
        let replacement = try await generator.generateQuick(for: replacementTurn)
        XCTAssertEqual(replacement.turnID, replacementTurn.identity.turnID)
        _ = await generator.shutdown()
    }

    func testValidatedQuickReturnsWhileTranscriptForkCleanupIsStillPending() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            deleteThreadGate: deleteGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let completion = CompletionProbe()
        let generation = Task {
            let output = try await generator.generateQuick(for: turn)
            await completion.markCompleted()
            return output
        }
        await deleteGate.waitUntilSuspended()
        for _ in 0..<100 {
            if await completion.isCompleted() { break }
            await Task.yield()
        }

        let generationCompleted = await completion.isCompleted()
        XCTAssertTrue(generationCompleted)
        let output = try await generation.value
        XCTAssertEqual(output, Self.quickOutput(for: turn))
        let deletedBeforeCleanup = await client.deletedThreadIDs()
        XCTAssertTrue(deletedBeforeCleanup.isEmpty)

        let cleanupCompletion = CompletionProbe()
        let cleanup = Task {
            try await generator.awaitQuickCleanup(for: turn.identity)
            await cleanupCompletion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let cleanupCompletedEarly = await cleanupCompletion.isCompleted()
        XCTAssertFalse(cleanupCompletedEarly)

        await deleteGate.release()
        try await cleanup.value
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
        _ = await generator.shutdown()
    }

    func testShutdownJoinsPendingQuickCleanupBeforeDeletingBases() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            deleteThreadGate: deleteGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        _ = try await generator.generateQuick(for: turn)
        await deleteGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let shutdown = Task {
            let report = await generator.shutdown()
            await completion.markCompleted()
            return report
        }
        for _ in 0..<100 { await Task.yield() }
        let shutdownCompletedEarly = await completion.isCompleted()
        XCTAssertFalse(shutdownCompletedEarly)

        await deleteGate.release()
        let report = await shutdown.value
        let shutdownCompleted = await completion.isCompleted()
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(report.failures, [])
        let deleted = await client.deletedThreadIDs()
        XCTAssertEqual(Set(deleted), Set(["fork-1", "base-1", "base-2"]))
    }

    func testCancelActiveWorkJoinsPendingQuickCleanupBeforeReopening() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let replacementTurn = fixture.turn(generation: 2)
        let deleteGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                try Self.json(Self.quickOutput(for: turn)),
                try Self.json(Self.quickOutput(for: replacementTurn)),
            ],
            deleteThreadGate: deleteGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        _ = try await generator.generateQuick(for: turn)
        await deleteGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let cancellation = Task {
            await generator.cancelActiveWork()
            await completion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let cancellationCompletedEarly = await completion.isCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await deleteGate.release()
        await cancellation.value
        let cancellationCompleted = await completion.isCompleted()
        XCTAssertTrue(cancellationCompleted)

        let replacement = try await generator.generateQuick(for: replacementTurn)
        XCTAssertEqual(replacement, Self.quickOutput(for: replacementTurn))
        try await generator.awaitQuickCleanup(for: replacementTurn.identity)
        _ = await generator.shutdown()
    }

    func testRepeatedQuickForSameTurnIdentityTracksEveryPendingCleanup() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                try Self.json(Self.quickOutput(for: turn)),
                try Self.json(Self.quickOutput(for: turn)),
            ],
            deleteThreadGate: deleteGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        _ = try await generator.generateQuick(for: turn)
        await deleteGate.waitUntilSuspended()
        _ = try await generator.generateQuick(for: turn)

        let completion = CompletionProbe()
        let cleanup = Task {
            try await generator.awaitQuickCleanup(for: turn.identity)
            await completion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let cleanupCompletedEarly = await completion.isCompleted()
        XCTAssertFalse(cleanupCompletedEarly)

        await deleteGate.release()
        try await cleanup.value
        let deleted = await client.deletedThreadIDs()
        XCTAssertEqual(Set(deleted), Set(["fork-1", "fork-2"]))
        _ = await generator.shutdown()
    }

    func testCancellationBoundaryJoinsAConcurrentDeleteBeforeReopening() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let startQuickGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            hangQuick: true,
            startQuickGate: startQuickGate,
            deleteThreadGate: deleteGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await startQuickGate.waitUntilSuspended()
        generation.cancel()
        await startQuickGate.release()
        await deleteGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let cancellation = Task {
            await generator.cancelActiveWork()
            await completion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await deleteGate.release()
        await cancellation.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }
        let completedAfterRelease = await completion.isCompleted()
        XCTAssertTrue(completedAfterRelease)
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
        _ = await generator.shutdown()
    }

    func testAwaitQuickCleanupJoinsCancelledQuickAndReportsDeleteFailure() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let startQuickGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            hangQuick: true,
            startQuickGate: startQuickGate,
            deleteThreadGate: deleteGate,
            deletionFailuresRemaining: 1
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await startQuickGate.waitUntilSuspended()
        generation.cancel()
        await startQuickGate.release()
        await deleteGate.waitUntilSuspended()

        let completion = CompletionProbe()
        let cleanup = Task {
            let failure: MeetingResponseError?
            do {
                try await generator.awaitQuickCleanup(for: turn.identity)
                failure = nil
            } catch {
                failure = error as? MeetingResponseError
            }
            await completion.markCompleted()
            return failure
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await deleteGate.release()
        let cleanupFailure = await cleanup.value
        XCTAssertEqual(cleanupFailure, .cleanupFailed)
        await XCTAssertThrowsCancellation { _ = try await generation.value }
        _ = await generator.shutdown()
    }

    func testTransientInterruptFailureTriggersOneBoundaryRecovery() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let firstTurn = fixture.turn(generation: 1)
        let recoveredTurn = fixture.turn(generation: 2)
        let startQuickGate = SuspendedCallGate()
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            interruptErrors: [.requestTimedOut(method: "turn/interrupt")],
            hangQuick: true,
            startQuickGate: startQuickGate
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: recoveredTurn))],
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: Set(["base-1", "base-2"])
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: firstTurn) }
        await startQuickGate.waitUntilSuspended()
        let cancellation = Task { await generator.cancelActiveWork() }
        await startQuickGate.release()
        await cancellation.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }
        let output = try await generator.generateQuick(for: recoveredTurn)
        try await generator.awaitQuickCleanup(for: recoveredTurn.identity)

        XCTAssertEqual(output, Self.quickOutput(for: recoveredTurn))
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(factoryCalls, 2)
        _ = await generator.shutdown()
    }

    func testNontransientInterruptFailureBlocksWithoutReconnect() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let startQuickGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            interruptErrors: [.requestFailed(method: "turn/interrupt", code: -32_600)],
            hangQuick: true,
            startQuickGate: startQuickGate
        )
        let clientFactory = SequencedCodexClientFactory(clients: [client])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateQuick(for: turn) }
        await startQuickGate.waitUntilSuspended()
        let cancellation = Task { await generator.cancelActiveWork() }
        await startQuickGate.release()
        await cancellation.value
        await XCTAssertThrowsCancellation { _ = try await generation.value }
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(factoryCalls, 1)
        _ = await generator.shutdown()
    }

    func testQuickCleanupFailureIsVisibleAndBlocksFurtherInference() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            deletionFailuresRemaining: 1
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        _ = try await generator.generateQuick(for: turn)
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            try await generator.awaitQuickCleanup(for: turn.identity)
        }
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        let forkCount = await client.forkCount()
        XCTAssertEqual(forkCount, 1)
        _ = await generator.shutdown()
    }

    func testRejectedQuickJournalFailureBlocksFurtherInference() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: ["not-json"],
            deleteThreadGate: deleteGate
        )
        let clientFactory = SequencedCodexClientFactory(clients: [client])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        let rejected = Task { try await generator.generateQuick(for: turn) }
        await deleteGate.waitUntilSuspended()
        try fixture.replaceJournalWithDirectory()
        await deleteGate.release()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await rejected.value
        }
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        await generator.cancelActiveWork()
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(factoryCalls, 1, "A local journal failure must not synthesize a reconnect.")
        _ = await generator.shutdown()
    }

    func testDeepJournalFailureBlocksFurtherInference() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let deleteGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(fixture.deepDraft(for: turn))],
            deleteThreadGate: deleteGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generation = Task { try await generator.generateDeep(for: turn) }
        await deleteGate.waitUntilSuspended()
        try fixture.replaceJournalWithDirectory()
        await deleteGate.release()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generation.value
        }
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        _ = await generator.shutdown()
    }

    func testForkRegistrationAndCompensatingDeleteFailureBlocksEveryInferencePath() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let draft = fixture.deepDraft(for: turn)
        let cue = CueEnvelope(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            text: "I would verify cleanup before continuing.",
            reason: "cleanup",
            isDeterministicBridge: false
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            deletionFailuresRemaining: 1
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        try fixture.replaceJournalWithDirectory()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: turn)
        }
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateDeep(for: turn)
        }
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.reconcile(cue: cue, draft: draft)
        }

        let forks = await client.forkCount()
        XCTAssertEqual(forks, 1)
        _ = await generator.shutdown()
    }

    func testTransportFailureRecoversAtOneCoalescedCancellationBoundary() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let failedTurn = fixture.turn(generation: 1)
        let recoveredTurn = fixture.turn(generation: 2)
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed],
            deletionFailuresRemaining: 1
        )
        let oldThreadIDs = Set(["base-1", "base-2", "fork-1", "unreported-old"])
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: recoveredTurn))],
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: oldThreadIDs
        )
        let replacementGate = SuspendedCallGate()
        let clientFactory = SequencedCodexClientFactory(
            clients: [oldClient, replacement],
            replacementGate: replacementGate
        )
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: failedTurn)
        }

        let firstCancellation = Task { await generator.cancelActiveWork() }
        await replacementGate.waitUntilSuspended()
        let secondCancellation = Task { await generator.cancelActiveWork() }
        await replacementGate.release()
        await firstCancellation.value
        await secondCancellation.value

        let output = try await generator.generateQuick(for: recoveredTurn)
        try await generator.awaitQuickCleanup(for: recoveredTurn.identity)
        let factoryCalls = await clientFactory.callCount()
        let oldShutdowns = await oldClient.shutdownCallCount()
        let replacementBases = await replacement.baseCount()
        let deletedByReplacement = await replacement.deletedThreadIDs()
        let entries = try await fixture.journal.entries()
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(output, Self.quickOutput(for: recoveredTurn))
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(oldShutdowns, 1)
        XCTAssertEqual(replacementBases, 2)
        XCTAssertTrue(oldThreadIDs.isSubset(of: Set(deletedByReplacement)))
        XCTAssertEqual(
            Set(entry.threadIDs),
            Set(["replacement-base-1", "replacement-base-2"])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshot.snapshotRoot.path))

        let report = await generator.shutdown()
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testShutdownWaitsForSuspendedReconnectAndPreventsPostReturnWork() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let oldShutdownGate = SuspendedCallGate()
        let oldThreadIDs = Set(["base-1", "base-2", "fork-1"])
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed],
            shutdownGate: oldShutdownGate,
            rejectRequestsAfterShutdown: true,
            deletionFailuresRemaining: 1
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: oldThreadIDs
        )
        let replacementGate = SuspendedCallGate()
        let clientFactory = SequencedCodexClientFactory(
            clients: [oldClient, replacement],
            replacementGate: replacementGate
        )
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }

        let cancellation = Task { await generator.cancelActiveWork() }
        await oldShutdownGate.waitUntilSuspended()
        let completion = CompletionProbe()
        let shutdown = Task {
            let report = await generator.shutdown()
            await completion.markCompleted()
            return report
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await oldShutdownGate.release()
        await replacementGate.waitUntilSuspended()
        await replacementGate.release()
        let report = await shutdown.value
        await cancellation.value
        let oldShutdowns = await oldClient.shutdownCallCount()
        let replacementShutdowns = await replacement.shutdownCallCount()
        let replacementBases = await replacement.baseCount()
        let replacementDeleted = await replacement.deletedThreadIDs()
        let entries = try await fixture.journal.entries()
        XCTAssertGreaterThanOrEqual(oldShutdowns, 1)
        XCTAssertEqual(replacementShutdowns, 1)
        XCTAssertEqual(replacementBases, 0)
        XCTAssertEqual(Set(replacementDeleted), oldThreadIDs)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(entries.first?.threadIDs, [])

        await XCTAssertThrowsMeetingError(.notPrepared) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(factoryCalls, 2)
    }

    func testTransportRecoveryCleanupFailurePreservesJournalAndBlocks() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let failedTurn = fixture.turn(generation: 1)
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.requestTimedOut(method: "turn/start")],
            deletionFailuresRemaining: 1
        )
        let oldThreadIDs = Set(["base-1", "base-2", "fork-1", "unreported-old"])
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: oldThreadIDs,
            deletionFailuresRemaining: 32
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: failedTurn)
        }
        await generator.cancelActiveWork()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        await generator.cancelActiveWork()
        let factoryCalls = await clientFactory.callCount()
        let replacementBases = await replacement.baseCount()
        let replacementShutdowns = await replacement.shutdownCallCount()
        let entries = try await fixture.journal.entries()
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(replacementBases, 0)
        XCTAssertEqual(replacementShutdowns, 1)
        XCTAssertTrue(oldThreadIDs.isSubset(of: Set(entry.threadIDs)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshot.snapshotRoot.path))
    }

    func testRecoverySweepsThreadsAndRebuildsWhileRemoteCapacityIsExhausted() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed],
            deletionFailuresRemaining: 1
        )
        let oldThreadIDs = Set(["base-1", "base-2", "fork-1", "unreported-old"])
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            remoteRateLimited: true,
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: oldThreadIDs
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()
        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }

        await generator.cancelActiveWork()

        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        let deleted = await replacement.deletedThreadIDs()
        let replacementBases = await replacement.baseCount()
        let replacementForks = await replacement.forkCount()
        XCTAssertTrue(oldThreadIDs.isSubset(of: Set(deleted)))
        XCTAssertEqual(replacementBases, 2)
        XCTAssertEqual(replacementForks, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshot.snapshotRoot.path))

        _ = await generator.shutdown()
        let replacementShutdowns = await replacement.shutdownCallCount()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(replacementShutdowns, 1)
        XCTAssertEqual(entries.first?.threadIDs, [])
    }

    func testExhaustedRemoteCapacityAllowsPrepareButSuppressesModelLaunch() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(realtime: false, remoteRateLimited: true)
        let generator = fixture.generator(client: client)

        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await generator.generateDeep(for: fixture.turn(generation: 1))
        }
        let forkCount = await client.forkCount()
        let quickTurnCount = await client.quickTurnCount()
        XCTAssertEqual(forkCount, 0)
        XCTAssertEqual(quickTurnCount, 0)
        _ = await generator.shutdown()
    }

    func testConcurrentQuickAndDeepShareOneExhaustedCapacityRecheck() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let rateLimitGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            remoteCapacitySequence: [false, false],
            rateLimitGate: rateLimitGate,
            rateLimitGateCall: 2
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let quick = Task { try await generator.generateQuick(for: turn) }
        let deep = Task { try await generator.generateDeep(for: turn) }
        await rateLimitGate.waitUntilSuspended()

        let readsWhileSuspended = await client.rateLimitReadCount()
        let forksWhileSuspended = await client.forkCount()
        let quickStartsWhileSuspended = await client.quickTurnCount()
        let deepStartsWhileSuspended = await client.turnStartCount()
        XCTAssertEqual(readsWhileSuspended, 2)
        XCTAssertEqual(forksWhileSuspended, 0)
        XCTAssertEqual(quickStartsWhileSuspended, 0)
        XCTAssertEqual(deepStartsWhileSuspended, 0)

        await rateLimitGate.release()
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await quick.value
        }
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await deep.value
        }
        let finalReads = await client.rateLimitReadCount()
        XCTAssertEqual(finalReads, 2)
        _ = await generator.shutdown()
    }

    func testConcurrentQuickAndDeepResumeAfterOnePositiveCapacityRecheck() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let rateLimitGate = SuspendedCallGate()
        let quickOutput = Self.quickOutput(for: turn)
        let deepOutput = fixture.deepDraft(for: turn)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(quickOutput)],
            turnOutputs: [try Self.json(deepOutput)],
            remoteCapacitySequence: [false, true],
            rateLimitGate: rateLimitGate,
            rateLimitGateCall: 2
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let quick = Task { try await generator.generateQuick(for: turn) }
        let deep = Task { try await generator.generateDeep(for: turn) }
        await rateLimitGate.waitUntilSuspended()
        let readsWhileSuspended = await client.rateLimitReadCount()
        let forksWhileSuspended = await client.forkCount()
        XCTAssertEqual(readsWhileSuspended, 2)
        XCTAssertEqual(forksWhileSuspended, 0)

        await rateLimitGate.release()
        async let generatedQuick = quick.value
        async let generatedDeep = deep.value
        let (quickResult, deepResult) = try await (generatedQuick, generatedDeep)
        try await generator.awaitQuickCleanup(for: turn.identity)

        XCTAssertEqual(quickResult, quickOutput)
        XCTAssertEqual(deepResult, deepOutput)
        let finalReads = await client.rateLimitReadCount()
        let finalForks = await client.forkCount()
        let finalQuickStarts = await client.quickTurnCount()
        let finalDeepStarts = await client.turnStartCount()
        XCTAssertEqual(finalReads, 2)
        XCTAssertEqual(finalForks, 2)
        XCTAssertEqual(finalQuickStarts, 1)
        XCTAssertEqual(finalDeepStarts, 1)
        _ = await generator.shutdown()
    }

    func testForcedTerminalCapacityReadBlocksConcurrentAdmission() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let rateLimitGate = SuspendedCallGate()
        let joinProbe = CapacityJoinProbe()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            turnOutputs: [try Self.json(fixture.deepDraft(for: turn))],
            turnTerminalStatuses: ["failed"],
            remoteCapacitySequence: [true, false],
            rateLimitGate: rateLimitGate,
            rateLimitGateCall: 2
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        await generator.setCapacityCheckTestHooks(
            joined: { revision in await joinProbe.record(revision) }
        )

        let deep = Task { try await generator.generateDeep(for: turn) }
        await rateLimitGate.waitUntilSuspended()
        let quick = Task { try await generator.generateQuick(for: turn) }
        await joinProbe.waitUntilObserved(revision: 1, count: 2)

        let readsWhileSuspended = await client.rateLimitReadCount()
        let forksWhileSuspended = await client.forkCount()
        let quickStartsWhileSuspended = await client.quickTurnCount()
        XCTAssertEqual(readsWhileSuspended, 2)
        XCTAssertEqual(forksWhileSuspended, 1)
        XCTAssertEqual(quickStartsWhileSuspended, 0)

        await rateLimitGate.release()
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await deep.value
        }
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await quick.value
        }
        let finalReads = await client.rateLimitReadCount()
        let finalForks = await client.forkCount()
        XCTAssertEqual(finalReads, 2)
        XCTAssertEqual(finalForks, 1)
        _ = await generator.shutdown()
    }

    func testOlderAdmittedSuccessCannotOverwriteNewerExhaustedObservation() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let firstTurn = fixture.turn(generation: 1)
        let secondTurn = fixture.turn(generation: 2)
        let quickGate = SuspendedCallGate()
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: firstTurn))],
            turnOutputs: [try Self.json(fixture.deepDraft(for: firstTurn))],
            turnTerminalStatuses: ["failed"],
            remoteCapacitySequence: [true, false, false],
            startQuickGate: quickGate
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let admittedQuick = Task { try await generator.generateQuick(for: firstTurn) }
        await quickGate.waitUntilSuspended()
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await generator.generateDeep(for: firstTurn)
        }

        await quickGate.release()
        let quickResult = try await admittedQuick.value
        XCTAssertEqual(quickResult, Self.quickOutput(for: firstTurn))
        try await generator.awaitQuickCleanup(for: firstTurn.identity)

        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await generator.generateDeep(for: secondTurn)
        }
        let finalReads = await client.rateLimitReadCount()
        let finalForks = await client.forkCount()
        let finalQuickStarts = await client.quickTurnCount()
        let finalDeepStarts = await client.turnStartCount()
        XCTAssertEqual(finalReads, 3)
        XCTAssertEqual(finalForks, 2)
        XCTAssertEqual(finalQuickStarts, 1)
        XCTAssertEqual(finalDeepStarts, 1)
        _ = await generator.shutdown()
    }

    func testLateSharedCapacityWaiterCannotOverwriteNewerExhaustion() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let capacityReadGate = SuspendedCallGate()
        let delayedResumeGate = SuspendedCallGate()
        let probe = CapacityCheckInterleavingProbe(delayedResumeGate: delayedResumeGate)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            turnOutputs: [try Self.json(fixture.deepDraft(for: turn))],
            quickTerminalStatuses: ["failed"],
            turnTerminalStatuses: ["failed"],
            rateLimitErrors: [
                .requestFailed(method: "account/rateLimits/read", code: -32_600)
            ],
            remoteRateLimited: true,
            remoteCapacitySequence: [true, false],
            rateLimitGate: capacityReadGate,
            rateLimitGateCall: 2
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        await generator.setCapacityCheckTestHooks(
            joined: { revision in await probe.recordJoin(revision) },
            resumed: { revision in await probe.recordResume(revision) },
            applied: { revision in await probe.recordApply(revision) }
        )

        let quick = Task { try await generator.generateQuick(for: turn) }
        let deep = Task { try await generator.generateDeep(for: turn) }
        await capacityReadGate.waitUntilSuspended()
        for _ in 0..<1_000 {
            if await probe.joinCount(for: 1) == 2 { break }
            await Task.yield()
        }
        let joinedCount = await probe.joinCount(for: 1)
        XCTAssertEqual(joinedCount, 2)

        await capacityReadGate.release()
        await delayedResumeGate.waitUntilSuspended()
        await probe.waitUntilApplied(revision: 2)
        let newerApplyCount = await probe.applyCount(for: 2)
        XCTAssertEqual(newerApplyCount, 1)
        await delayedResumeGate.release()

        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await quick.value
        }
        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await deep.value
        }
        let finalReads = await client.rateLimitReadCount()
        let finalForks = await client.forkCount()
        let finalQuickStarts = await client.quickTurnCount()
        let finalDeepStarts = await client.turnStartCount()
        XCTAssertEqual(finalReads, 3)
        XCTAssertEqual(finalForks, 1)
        XCTAssertEqual(finalQuickStarts + finalDeepStarts, 1)
        _ = await generator.shutdown()
    }

    func testLateCapacityWaiterJoinsNewestPendingCheckInsteadOfUsingOlderAvailableResult()
        async throws
    {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let capacityReadGate = SuspendedCallGate()
        let delayedResumeGate = SuspendedCallGate()
        let revisionThreeJoinGate = SuspendedCallGate()
        let probe = CapacityCheckInterleavingProbe(delayedResumeGate: delayedResumeGate)
        let joinSuspender = FirstMatchingRevisionSuspender(
            revision: 3,
            gate: revisionThreeJoinGate
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                try Self.json(Self.quickOutput(for: turn)),
                try Self.json(Self.quickOutput(for: turn)),
            ],
            quickTerminalStatuses: ["failed", "failed"],
            rateLimitErrors: [
                .requestFailed(method: "account/rateLimits/read", code: -32_600)
            ],
            remoteRateLimited: true,
            remoteCapacitySequence: [true, true, false],
            rateLimitGate: capacityReadGate,
            rateLimitGateCall: 2
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()
        await generator.setCapacityCheckTestHooks(
            joined: { revision in
                await probe.recordJoin(revision)
                await joinSuspender.handle(revision)
            },
            resumed: { revision in await probe.recordResume(revision) },
            applied: { revision in await probe.recordApply(revision) }
        )

        let completionPair = AsyncStream<(Int, MeetingResponseError?)>.makeStream()
        let first = Task { () -> MeetingResponseError? in
            let capturedFailure: MeetingResponseError?
            do {
                _ = try await generator.generateQuick(for: turn)
                capturedFailure = nil
            } catch let failure as MeetingResponseError {
                capturedFailure = failure
            } catch {
                capturedFailure = MeetingResponseError.runtimeUnavailable
            }
            completionPair.continuation.yield((1, capturedFailure))
            return capturedFailure
        }
        let second = Task { () -> MeetingResponseError? in
            let capturedFailure: MeetingResponseError?
            do {
                _ = try await generator.generateQuick(for: turn)
                capturedFailure = nil
            } catch let failure as MeetingResponseError {
                capturedFailure = failure
            } catch {
                capturedFailure = MeetingResponseError.runtimeUnavailable
            }
            completionPair.continuation.yield((2, capturedFailure))
            return capturedFailure
        }

        await capacityReadGate.waitUntilSuspended()
        for _ in 0..<1_000 {
            if await probe.joinCount(for: 1) == 2 { break }
            await Task.yield()
        }
        let joinedCount = await probe.joinCount(for: 1)
        XCTAssertEqual(joinedCount, 2)
        await capacityReadGate.release()
        await delayedResumeGate.waitUntilSuspended()

        var completionIterator = completionPair.stream.makeAsyncIterator()
        let firstCompletion = await completionIterator.next()
        XCTAssertEqual(firstCompletion?.1, .invalidOutput)

        let third = Task { () -> MeetingResponseError? in
            do {
                _ = try await generator.generateQuick(for: turn)
                return nil
            } catch let failure as MeetingResponseError {
                return failure
            } catch {
                return .runtimeUnavailable
            }
        }
        await revisionThreeJoinGate.waitUntilSuspended()
        await delayedResumeGate.release()
        await probe.waitUntilApplied(revision: 3)

        let forksWhileNewestCheckIsPending = await client.forkCount()
        XCTAssertEqual(forksWhileNewestCheckIsPending, 2)
        await revisionThreeJoinGate.release()

        let firstError = await first.value
        let secondError = await second.value
        let thirdError = await third.value
        let sharedErrors = [firstError, secondError]
        XCTAssertEqual(
            sharedErrors.filter { $0 == MeetingResponseError.invalidOutput }.count,
            1
        )
        XCTAssertEqual(
            sharedErrors.filter { $0 == MeetingResponseError.providerCapacityUnavailable }.count,
            1
        )
        XCTAssertEqual(thirdError, .providerCapacityUnavailable)
        let finalReads = await client.rateLimitReadCount()
        let finalForks = await client.forkCount()
        let finalQuickStarts = await client.quickTurnCount()
        XCTAssertEqual(finalReads, 4)
        XCTAssertEqual(finalForks, 2)
        XCTAssertEqual(finalQuickStarts, 2)
        _ = await generator.shutdown()
    }

    func testFailedCapacityReadRechecksBeforeAnyLaterFork() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let failedTurn = fixture.turn(generation: 1)
        let recoveredTurn = fixture.turn(generation: 2)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: recoveredTurn))],
            rateLimitErrors: [
                .requestFailed(method: "account/rateLimits/read", code: -32_600),
                .requestFailed(method: "account/rateLimits/read", code: -32_600),
            ],
            remoteCapacitySequence: [true]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.runtimeUnavailable) {
            _ = try await generator.generateQuick(for: failedTurn)
        }
        let failedForks = await client.forkCount()
        XCTAssertEqual(failedForks, 0)

        let recovered = try await generator.generateQuick(for: recoveredTurn)
        XCTAssertEqual(recovered, Self.quickOutput(for: recoveredTurn))
        try await generator.awaitQuickCleanup(for: recoveredTurn.identity)
        let finalReads = await client.rateLimitReadCount()
        let finalForks = await client.forkCount()
        XCTAssertEqual(finalReads, 3)
        XCTAssertEqual(finalForks, 1)
        _ = await generator.shutdown()
    }

    func testTransportFailureWithConfirmedCleanupPreservesRuntimeError() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.runtimeUnavailable) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        let deleted = await client.deletedThreadIDs()
        XCTAssertTrue(deleted.contains("fork-1"))
        _ = await generator.shutdown()
    }

    func testFailedTerminalTurnWithExhaustedCapacityUsesProviderLimit() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            quickTerminalStatuses: ["failed"],
            remoteCapacitySequence: [true, false]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.providerCapacityUnavailable) {
            _ = try await generator.generateQuick(for: turn)
        }
        let forkCount = await client.forkCount()
        XCTAssertEqual(forkCount, 1)
        _ = await generator.shutdown()
    }

    func testFailedTerminalTurnWithAvailableCapacityRemainsInvalidOutput() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: turn))],
            quickTerminalStatuses: ["failed"],
            remoteCapacitySequence: [true, true]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.invalidOutput) {
            _ = try await generator.generateQuick(for: turn)
        }
        _ = await generator.shutdown()
    }

    func testNonrecoverableClientErrorsNeverReconnect() async throws {
        let errors: [CodexClientError] = [
            .requestFailed(method: "turn/start", code: -32_600),
            .malformedMessage,
            .invalidResponse(method: "turn/start"),
            .notInitialized,
            .permissionProfileMismatch,
            .serverRequestRejected(
                method: "item/tool/call",
                threadID: nil,
                turnID: nil,
                itemID: nil
            ),
        ]

        for (index, error) in errors.enumerated() {
            let fixture = try ResponseGeneratorFixture()
            defer { fixture.cleanup() }
            let failedTurn = fixture.turn(generation: UInt64(index * 2 + 1))
            let nextTurn = fixture.turn(generation: UInt64(index * 2 + 2))
            let client = FakeMeetingCodexClient(
                realtime: false,
                quickOutputs: [try Self.json(Self.quickOutput(for: nextTurn))],
                quickErrors: [error]
            )
            let clientFactory = SequencedCodexClientFactory(clients: [client])
            let generator = fixture.generator(clientFactory: { configuration in
                try await clientFactory.connect(configuration)
            })
            _ = try await generator.prepare()

            do {
                _ = try await generator.generateQuick(for: failedTurn)
                XCTFail("Expected the configured client error.")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
            await generator.cancelActiveWork()

            let output = try await generator.generateQuick(for: nextTurn)
            try await generator.awaitQuickCleanup(for: nextTurn.identity)
            let factoryCalls = await clientFactory.callCount()
            XCTAssertEqual(output, Self.quickOutput(for: nextTurn))
            XCTAssertEqual(factoryCalls, 1, "Unexpected reconnect for \(error)")
            _ = await generator.shutdown()
        }
    }

    func testInvalidStructuredOutputNeverReconnects() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let failedTurn = fixture.turn(generation: 1)
        let nextTurn = fixture.turn(generation: 2)
        let client = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [
                "not-json",
                try Self.json(Self.quickOutput(for: nextTurn)),
            ]
        )
        let clientFactory = SequencedCodexClientFactory(clients: [client])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.invalidOutput) {
            _ = try await generator.generateQuick(for: failedTurn)
        }
        await generator.cancelActiveWork()

        let output = try await generator.generateQuick(for: nextTurn)
        try await generator.awaitQuickCleanup(for: nextTurn.identity)
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(output, Self.quickOutput(for: nextTurn))
        XCTAssertEqual(factoryCalls, 1)
        _ = await generator.shutdown()
    }

    func testCancellationBoundaryRecoversTransportFailureFromPendingQuickCleanup() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let firstTurn = fixture.turn(generation: 1)
        let recoveredTurn = fixture.turn(generation: 2)
        let deleteGate = SuspendedCallGate()
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: firstTurn))],
            deleteThreadGate: deleteGate,
            deletionFailuresRemaining: 1
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            quickOutputs: [try Self.json(Self.quickOutput(for: recoveredTurn))],
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: Set(["base-1", "base-2", "fork-1", "unreported-old"])
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()
        _ = try await generator.generateQuick(for: firstTurn)
        await deleteGate.waitUntilSuspended()

        let cancellation = Task { await generator.cancelActiveWork() }
        await deleteGate.release()
        await cancellation.value

        let output = try await generator.generateQuick(for: recoveredTurn)
        try await generator.awaitQuickCleanup(for: recoveredTurn.identity)
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(output, Self.quickOutput(for: recoveredTurn))
        XCTAssertEqual(factoryCalls, 2)
        let report = await generator.shutdown()
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testRecoveryPreflightFailurePreservesExactSafeErrorWithoutRetry() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportUnavailable],
            deletionFailuresRemaining: 1
        )
        let replacement = FakeMeetingCodexClient(realtime: false, signedIn: false)
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        await generator.cancelActiveWork()

        await XCTAssertThrowsMeetingError(.credentialStoreUnavailable) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        await generator.cancelActiveWork()
        let factoryCalls = await clientFactory.callCount()
        let replacementShutdowns = await replacement.shutdownCallCount()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(replacementShutdowns, 1)
    }

    func testRecoveryDeepBaseFailureNeverPublishesQuickOnlyRuntime() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed],
            deletionFailuresRemaining: 1
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            invalidBaseNumber: 2,
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: Set(["base-1", "base-2", "fork-1"])
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        await generator.cancelActiveWork()

        await XCTAssertThrowsMeetingError(.protocolUnsupported) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 2))
        }
        let factoryCalls = await clientFactory.callCount()
        let replacementBases = await replacement.baseCount()
        let replacementShutdowns = await replacement.shutdownCallCount()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(replacementBases, 2)
        XCTAssertGreaterThanOrEqual(replacementShutdowns, 1)
        XCTAssertEqual(entries.first?.threadIDs, [])
        let report = await generator.shutdown()
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testShutdownFailsClosedWhenFailedRecoveryCannotCleanOwnedReplacementBase() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed],
            deletionFailuresRemaining: 1
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            invalidBaseNumber: 2,
            threadIDPrefix: "replacement-",
            discoverableThreadIDs: Set(["base-1", "base-2", "fork-1"]),
            listThreadFailureCalls: [3]
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        await generator.cancelActiveWork()

        let report = await generator.shutdown()
        let entries = try await fixture.journal.entries()
        XCTAssertTrue(report.failures.contains(.deleteThread))
        XCTAssertEqual(entries.first?.threadIDs, ["replacement-base-1"])
    }

    func testShutdownFailsClosedWhenRecoveryCannotAcquireCleanupClient() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let oldClient = FakeMeetingCodexClient(
            realtime: false,
            quickErrors: [.transportClosed]
        )
        let clientFactory = SequencedCodexClientFactory(clients: [oldClient])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        _ = try await generator.prepare()

        await XCTAssertThrowsMeetingError(.runtimeUnavailable) {
            _ = try await generator.generateQuick(for: fixture.turn(generation: 1))
        }
        await generator.cancelActiveWork()

        let report = await generator.shutdown()
        let entries = try await fixture.journal.entries()
        let factoryCalls = await clientFactory.callCount()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertTrue(report.failures.contains(.deleteThread))
        XCTAssertEqual(Set(entries.first?.threadIDs ?? []), Set(["base-1", "base-2"]))
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

    func testGroundedDeepAllowsExplicitlyUngroundedGeneralAnswer() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.turn(generation: 1)
        let general = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext:
                "I’ve worked with React across production web applications. Lately, I’ve focused on TypeScript products and reusable frontend architecture.",
            confidence: 0.8,
            basis: []
        )
        let client = FakeMeetingCodexClient(
            realtime: false,
            turnOutputs: [try Self.json(general)]
        )
        let generator = fixture.generator(client: client)
        _ = try await generator.prepare()

        let generated = try await generator.generateDeep(for: turn)

        XCTAssertEqual(generated, general)
        XCTAssertNil(generated.groundingFingerprint)
        XCTAssertTrue(generated.basis.isEmpty)
        _ = await generator.shutdown()
    }

    func testUsageGovernorRejectsSecondQuickWithinWindow() async throws {
        let fixture = try ResponseGeneratorFixture(quickPerMinute: 1)
        defer { fixture.cleanup() }
        let first = fixture.turn(generation: 1)
        let output = QuickModelOutput(
            turnID: first.identity.turnID,
            generation: 1,
            sayNow: "I’d verify the exact path before making a specific claim.",
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

    func testInitialPrepareTransportFailureRetiresClientAndRetriesOnceCleanly() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            accountErrors: [.transportClosed],
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "replacement-",
            threadStore: threadStore
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })

        let runtime = try await generator.prepare()

        let factoryCalls = await clientFactory.callCount()
        let failedShutdowns = await failedClient.shutdownCallCount()
        let failedBases = await failedClient.baseCount()
        let replacementBases = await replacement.baseCount()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(runtime.planType, "pro")
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedShutdowns, 1)
        XCTAssertEqual(failedBases, 0)
        XCTAssertEqual(replacementBases, 2)
        XCTAssertEqual(
            Set(entries.first?.threadIDs ?? []),
            Set(["replacement-base-1", "replacement-base-2"])
        )

        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
    }

    func testDeferredDeepWarmupReplacesTimedOutClientAndStillGenerates() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn(generation: 1)
        let replacementGate = SuspendedCallGate()
        let joinProbe = DeferredPreparationJoinProbe()
        let expected = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext:
                "I’d separate exclusivity from capacity: use a mutex for one owner, and a semaphore when a bounded number of workers may proceed.",
            confidence: 0.84,
            basis: []
        )
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            directEphemeralResponses: true,
            lostBaseResponseNumber: 1,
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            directEphemeralResponses: true,
            turnOutputs: [try Self.json(expected)],
            threadIDPrefix: "replacement-",
            threadStore: threadStore
        )
        let factory = SequencedCodexClientFactory(
            clients: [failedClient, replacement],
            replacementGate: replacementGate
        )
        let generator = fixture.generator(
            clientFactory: { configuration in
                try await factory.connect(configuration)
            },
            includeGrounding: false,
            subscriptionQuickEnabled: false
        )
        await generator.setDeferredPreparationJoinTestHooks(deep: {
            await joinProbe.record()
        })

        _ = try await generator.prepare()
        await replacementGate.waitUntilSuspended()
        let generation = Task {
            try await generator.generateDeep(for: turn)
        }
        await joinProbe.waitUntilObserved()
        await replacementGate.release()
        let generated = try await generation.value

        XCTAssertEqual(generated, expected)
        let factoryCalls = await factory.callCount()
        let failedShutdowns = await failedClient.shutdownCallCount()
        let replacementDeleted = await replacement.deletedThreadIDs()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedShutdowns, 1)
        XCTAssertTrue(replacementDeleted.contains("failed-base-1"))
        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
    }

    func testDeferredQuickWarmupJoinsClientReplacementAndStillGenerates() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn(generation: 1)
        let replacementGate = SuspendedCallGate()
        let joinProbe = DeferredPreparationJoinProbe()
        let expected = QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow:
                "I’d start with the React timeline, then use one recent application to show the architecture and impact.",
            needsDeep: true,
            confidence: 0.7,
            reason: "subscription_sol_low_fast"
        )
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            directEphemeralResponses: true,
            lostBaseResponseNumber: 1,
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            directEphemeralResponses: true,
            quickOutputs: [try Self.json(["sayNow": expected.sayNow])],
            threadIDPrefix: "replacement-",
            threadStore: threadStore
        )
        let factory = SequencedCodexClientFactory(
            clients: [failedClient, replacement],
            replacementGate: replacementGate
        )
        let generator = fixture.generator(
            clientFactory: { configuration in
                try await factory.connect(configuration)
            },
            includeGrounding: false,
            subscriptionQuickEnabled: true
        )
        await generator.setDeferredPreparationJoinTestHooks(quick: {
            await joinProbe.record()
        })

        _ = try await generator.prepare()
        await replacementGate.waitUntilSuspended()
        let generation = Task {
            try await generator.generateQuick(for: turn)
        }
        await joinProbe.waitUntilObserved()
        await replacementGate.release()
        let generated = try await generation.value
        try await generator.awaitQuickCleanup(for: turn.identity)

        XCTAssertEqual(generated, expected)
        let factoryCalls = await factory.callCount()
        let failedShutdowns = await failedClient.shutdownCallCount()
        let replacementDeleted = await replacement.deletedThreadIDs()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedShutdowns, 1)
        XCTAssertTrue(replacementDeleted.contains("failed-base-1"))
        let cleanup = await generator.shutdown()
        let remainingThreads = await threadStore.threadIDs()
        XCTAssertTrue(cleanup.failures.isEmpty)
        XCTAssertTrue(remainingThreads.isEmpty)
    }

    func testInitialPrepareTransportFailureDeletesJournaledBaseBeforeRetry() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            createdBaseFailureNumber: 1,
            createdThreadFailureCause: .client(.transportClosed),
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "replacement-",
            threadStore: threadStore
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })

        _ = try await generator.prepare()

        let factoryCalls = await clientFactory.callCount()
        let replacementDeleted = await replacement.deletedThreadIDs()
        let failedShutdowns = await failedClient.shutdownCallCount()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(replacementDeleted, ["failed-base-1"])
        XCTAssertEqual(failedShutdowns, 1)
        XCTAssertEqual(
            Set(entries.first?.threadIDs ?? []),
            Set(["replacement-base-1", "replacement-base-2"])
        )

        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
    }

    func testInitialPrepareTransportFailureDoesNotRetryWhenReplacementCleanupIsUnconfirmed()
        async throws
    {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            createdBaseFailureNumber: 1,
            createdThreadFailureCause: .client(.transportClosed),
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "replacement-",
            threadStore: threadStore,
            deletionFailuresRemaining: 1
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })

        await XCTAssertThrowsMeetingError(.cleanupFailed) {
            _ = try await generator.prepare()
        }

        let factoryCalls = await clientFactory.callCount()
        let failedShutdowns = await failedClient.shutdownCallCount()
        let replacementShutdowns = await replacement.shutdownCallCount()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedShutdowns, 1)
        XCTAssertEqual(replacementShutdowns, 1)
        XCTAssertEqual(entries.first?.threadIDs, ["failed-base-1"])

        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.contains(.deleteThread))
    }

    func testInitialPrepareLostThreadStartResponseDiscoversOrphanBeforeRetry() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseNumber: 1,
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let replacement = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "replacement-",
            threadStore: threadStore
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, replacement])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })

        _ = try await generator.prepare()

        let factoryCalls = await clientFactory.callCount()
        let failedCallbacks = await failedClient.baseCreationCallbackCount()
        let failedDeleted = await failedClient.deletedThreadIDs()
        let replacementDeleted = await replacement.deletedThreadIDs()
        let remainingRemoteThreads = await threadStore.threadIDs()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedCallbacks, 0)
        XCTAssertTrue(failedDeleted.isEmpty)
        XCTAssertEqual(replacementDeleted, ["failed-base-1"])
        XCTAssertEqual(
            Set(remainingRemoteThreads),
            Set(["replacement-base-1", "replacement-base-2"])
        )
        XCTAssertEqual(
            Set(entries.first?.threadIDs ?? []),
            Set(["replacement-base-1", "replacement-base-2"])
        )

        let cleanup = await generator.shutdown()
        let threadsAfterShutdown = await threadStore.threadIDs()
        XCTAssertTrue(cleanup.failures.isEmpty)
        XCTAssertTrue(threadsAfterShutdown.isEmpty)
    }

    func testDeepInvalidThreadStartResponseCleansUnknownThreadWithoutRetry() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseNumber: 2,
            lostBaseResponseError: .invalidResponse(method: "thread/start"),
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let cleanupOnly = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "cleanup-",
            threadStore: threadStore
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, cleanupOnly])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })

        await XCTAssertThrowsMeetingError(.runtimeUnavailable) {
            _ = try await generator.prepare()
        }

        let factoryCalls = await clientFactory.callCount()
        let failedCallbacks = await failedClient.baseCreationCallbackCount()
        let cleanupBases = await cleanupOnly.baseCount()
        let cleanupDeleted = await cleanupOnly.deletedThreadIDs()
        let remainingThreads = await threadStore.threadIDs()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedCallbacks, 1)
        XCTAssertEqual(cleanupBases, 0)
        XCTAssertEqual(Set(cleanupDeleted), Set(["failed-base-1", "failed-base-2"]))
        XCTAssertTrue(remainingThreads.isEmpty)
        XCTAssertTrue(entries.first?.threadIDs.isEmpty == true)

        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
    }

    func testShutdownCancellationWaitsForLostThreadStartDiscoveryWithoutRetry() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let lostResponseGate = CancellationAwareCallGate()
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseGate: lostResponseGate,
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let cleanupOnly = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "cleanup-",
            threadStore: threadStore
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, cleanupOnly])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        let preparation = Task {
            do {
                _ = try await generator.prepare()
                return false
            } catch is CancellationError {
                return await threadStore.threadIDs().isEmpty
            } catch {
                return false
            }
        }
        await lostResponseGate.waitUntilSuspended()

        let shutdown = Task { await generator.shutdown() }
        let report = await shutdown.value
        let cleanupFinishedBeforeCancellation = await preparation.value
        let factoryCalls = await clientFactory.callCount()
        let failedCallbacks = await failedClient.baseCreationCallbackCount()
        let cleanupBases = await cleanupOnly.baseCount()
        let cleanupDeleted = await cleanupOnly.deletedThreadIDs()
        let remainingThreads = await threadStore.threadIDs()
        let entries = try await fixture.journal.entries()
        XCTAssertTrue(cleanupFinishedBeforeCancellation)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(failedCallbacks, 0)
        XCTAssertEqual(cleanupBases, 0)
        XCTAssertEqual(cleanupDeleted, ["failed-base-1"])
        XCTAssertTrue(remainingThreads.isEmpty)
        XCTAssertTrue(entries.first?.threadIDs.isEmpty == true)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testShutdownCancellationFailsClosedWhenLostThreadCleanupCannotBeConfirmed()
        async throws
    {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let lostResponseGate = CancellationAwareCallGate()
        let threadStore = FakePersistentThreadStore()
        let failedClient = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseGate: lostResponseGate,
            threadIDPrefix: "failed-",
            threadStore: threadStore
        )
        let cleanupOnly = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "cleanup-",
            threadStore: threadStore,
            deletionFailuresRemaining: 1
        )
        let clientFactory = SequencedCodexClientFactory(clients: [failedClient, cleanupOnly])
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })
        let preparation = Task { () -> MeetingResponseError? in
            do {
                _ = try await generator.prepare()
                return nil
            } catch let error as MeetingResponseError {
                return error
            } catch {
                return nil
            }
        }
        await lostResponseGate.waitUntilSuspended()

        let report = await generator.shutdown()
        let preparationError = await preparation.value
        let factoryCalls = await clientFactory.callCount()
        let cleanupBases = await cleanupOnly.baseCount()
        let cleanupShutdowns = await cleanupOnly.shutdownCallCount()
        let remainingThreads = await threadStore.threadIDs()
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(preparationError, .cleanupFailed)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(cleanupBases, 0)
        XCTAssertEqual(cleanupShutdowns, 1)
        XCTAssertEqual(remainingThreads, ["failed-base-1"])
        XCTAssertEqual(entries.first?.threadIDs, ["failed-base-1"])
        XCTAssertTrue(report.failures.contains(.deleteThread))
    }

    func testInitialPrepareRetriesInferenceTwiceWhileCleaningFinalLostResponse() async throws {
        let fixture = try ResponseGeneratorFixture()
        defer { fixture.cleanup() }
        let threadStore = FakePersistentThreadStore()
        let first = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseNumber: 1,
            threadIDPrefix: "first-",
            threadStore: threadStore
        )
        let retry = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseNumber: 1,
            threadIDPrefix: "retry-",
            threadStore: threadStore
        )
        let third = FakeMeetingCodexClient(
            realtime: false,
            lostBaseResponseNumber: 1,
            threadIDPrefix: "third-",
            threadStore: threadStore
        )
        let finalCleanup = FakeMeetingCodexClient(
            realtime: false,
            threadIDPrefix: "cleanup-",
            threadStore: threadStore
        )
        let clientFactory = SequencedCodexClientFactory(
            clients: [first, retry, third, finalCleanup]
        )
        let generator = fixture.generator(clientFactory: { configuration in
            try await clientFactory.connect(configuration)
        })

        await XCTAssertThrowsMeetingError(.runtimeUnavailable) {
            _ = try await generator.prepare()
        }

        let factoryCalls = await clientFactory.callCount()
        let firstBases = await first.baseCount()
        let retryBases = await retry.baseCount()
        let thirdBases = await third.baseCount()
        let retryDeleted = await retry.deletedThreadIDs()
        let thirdDeleted = await third.deletedThreadIDs()
        let cleanupDeleted = await finalCleanup.deletedThreadIDs()
        let remainingThreads = await threadStore.threadIDs()
        XCTAssertEqual(factoryCalls, 4)
        XCTAssertEqual(firstBases, 1)
        XCTAssertEqual(retryBases, 1)
        XCTAssertEqual(thirdBases, 1)
        XCTAssertEqual(retryDeleted, ["first-base-1"])
        XCTAssertEqual(thirdDeleted, ["retry-base-1"])
        XCTAssertEqual(cleanupDeleted, ["third-base-1"])
        XCTAssertTrue(remainingThreads.isEmpty)
        let entries = try await fixture.journal.entries()
        XCTAssertTrue(entries.first?.threadIDs.isEmpty == true)

        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
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
        XCTAssertTrue(config.contains("persistence = \"save-all\""))
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

    private static func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static func quickOutput(for turn: ConversationTurn) -> QuickModelOutput {
        QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: "I would separate the decision from the implementation detail.",
            needsDeep: true,
            confidence: 0.8,
            reason: "technical_question"
        )
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
        includeGrounding: Bool = true,
        subscriptionQuickEnabled: Bool = true,
        realtimeQuickEnabled: Bool = true
    ) -> CodexMeetingResponseGenerator {
        generator(
            clientFactory: { configuration in
                await configurationRecorder?.record(configuration)
                return client
            },
            verifier: verifier,
            includeGrounding: includeGrounding,
            subscriptionQuickEnabled: subscriptionQuickEnabled,
            realtimeQuickEnabled: realtimeQuickEnabled
        )
    }

    func generator(
        clientFactory: @escaping CodexMeetingClientFactory,
        verifier: any MeetingEvidenceVerifying = FakeMeetingEvidenceVerifier(),
        includeGrounding: Bool = true,
        subscriptionQuickEnabled: Bool = true,
        realtimeQuickEnabled: Bool = true
    ) -> CodexMeetingResponseGenerator {
        CodexMeetingResponseGenerator(
            configuration: .init(
                meetingID: UUID(),
                meetingPrivateRoot: meetingRoot,
                codexProfileRoot: profileRoot,
                clientVersion: "0.1.0",
                expectedAccountIdentityHash: expectedAccountIdentityHash,
                groundingSnapshot: includeGrounding ? snapshot : nil,
                subscriptionQuickEnabled: subscriptionQuickEnabled,
                realtimeQuickEnabled: realtimeQuickEnabled,
                quickPerMinute: quickPerMinute
            ),
            journal: journal,
            evidenceVerifier: verifier,
            clientFactory: clientFactory
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

    func replaceJournalWithDirectory() throws {
        let journalURL = root.appendingPathComponent("journal/cleanup.json")
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createDirectory(
            at: journalURL,
            withIntermediateDirectories: false
        )
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

private actor SequencedCodexClientFactory {
    private var clients: [FakeMeetingCodexClient]
    private let replacementGate: SuspendedCallGate?
    private var calls = 0

    init(
        clients: [FakeMeetingCodexClient],
        replacementGate: SuspendedCallGate? = nil
    ) {
        self.clients = clients
        self.replacementGate = replacementGate
    }

    func connect(_ configuration: CodexAppServerConfiguration) async throws
        -> any CodexMeetingClient
    {
        calls += 1
        if calls == 2, let replacementGate {
            await replacementGate.suspend()
        }
        guard !clients.isEmpty else { throw CodexClientError.transportUnavailable }
        return clients.removeFirst()
    }

    func callCount() -> Int { calls }
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

private actor CancellationAwareCallGate {
    private var consumed = false
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationContinuation: CheckedContinuation<Void, Error>?

    func suspend() async throws {
        guard !consumed else { return }
        consumed = true
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    operationContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
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
        operationContinuation?.resume()
        operationContinuation = nil
    }

    private func cancel() {
        suspended = false
        operationContinuation?.resume(throwing: CancellationError())
        operationContinuation = nil
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

private actor DeferredPreparationJoinProbe {
    private var observed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        observed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilObserved() async {
        guard !observed else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor CapacityJoinProbe {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var observations: [UInt64: Int] = [:]
    private var waiters: [UInt64: [Waiter]] = [:]

    func record(_ revision: UInt64) {
        observations[revision, default: 0] += 1
        let observed = observations[revision, default: 0]
        let pending = waiters.removeValue(forKey: revision) ?? []
        var remaining: [Waiter] = []
        for waiter in pending {
            if observed >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        if !remaining.isEmpty {
            waiters[revision] = remaining
        }
    }

    func waitUntilObserved(revision: UInt64, count: Int) async {
        guard observations[revision, default: 0] < count else { return }
        await withCheckedContinuation { continuation in
            waiters[revision, default: []].append(
                Waiter(count: count, continuation: continuation)
            )
        }
    }
}

private actor CapacityCheckInterleavingProbe {
    private let delayedResumeGate: SuspendedCallGate
    private var joins: [UInt64: Int] = [:]
    private var resumes: [UInt64: Int] = [:]
    private var applies: [UInt64: Int] = [:]
    private var applyWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    init(delayedResumeGate: SuspendedCallGate) {
        self.delayedResumeGate = delayedResumeGate
    }

    func recordJoin(_ revision: UInt64) {
        joins[revision, default: 0] += 1
    }

    func recordResume(_ revision: UInt64) async {
        resumes[revision, default: 0] += 1
        if revision == 1, resumes[revision] == 2 {
            await delayedResumeGate.suspend()
        }
    }

    func recordApply(_ revision: UInt64) {
        applies[revision, default: 0] += 1
        let waiters = applyWaiters.removeValue(forKey: revision) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func joinCount(for revision: UInt64) -> Int {
        joins[revision, default: 0]
    }

    func applyCount(for revision: UInt64) -> Int {
        applies[revision, default: 0]
    }

    func waitUntilApplied(revision: UInt64) async {
        guard applies[revision, default: 0] == 0 else { return }
        await withCheckedContinuation { continuation in
            applyWaiters[revision, default: []].append(continuation)
        }
    }
}

private actor FirstMatchingRevisionSuspender {
    private let revision: UInt64
    private let gate: SuspendedCallGate
    private var matchCount = 0

    init(revision: UInt64, gate: SuspendedCallGate) {
        self.revision = revision
        self.gate = gate
    }

    func handle(_ observedRevision: UInt64) async {
        guard observedRevision == revision else { return }
        matchCount += 1
        if matchCount == 1 {
            await gate.suspend()
        }
    }
}

private actor FakePersistentThreadStore {
    private var cwdsByThreadID: [String: String] = [:]

    func insert(_ threadID: String, cwd: String) {
        cwdsByThreadID[threadID] = cwd
    }

    func remove(_ threadID: String) {
        cwdsByThreadID.removeValue(forKey: threadID)
    }

    func threadIDs(cwd: String? = nil) -> [String] {
        cwdsByThreadID.compactMap { threadID, storedCwd in
            cwd == nil || cwd == storedCwd ? threadID : nil
        }
        .sorted()
    }
}

private actor FakeMeetingCodexClient: CodexMeetingClient {
    nonisolated let runtimeCapabilities: CodexRuntimeCapabilities
    nonisolated let usesDirectEphemeralResponses: Bool

    struct SkillWrite: Equatable {
        let name: String
        let enabled: Bool
    }

    private var quickOutputs: [String]
    private var turnOutputs: [String]
    private var quickTerminalStatuses: [String]
    private var turnTerminalStatuses: [String]
    private var quickErrors: [CodexClientError]
    private var realtimeStreamErrors: [CodexClientError]
    private var accountErrors: [CodexClientError]
    private var rateLimitErrors: [CodexClientError]
    private var interruptErrors: [CodexClientError]
    private var extraSkillRoot: String?
    private var ambientSkillEnabled: Bool
    private let hangQuick: Bool
    private let signedIn: Bool
    private let remoteRateLimited: Bool
    private var remoteCapacitySequence: [Bool]
    private let invalidBaseCwd: Bool
    private let invalidBaseNumber: Int?
    private let lostBaseResponseNumber: Int?
    private let lostBaseResponseError: CodexClientError
    private let lostBaseResponseGate: CancellationAwareCallGate?
    private let createdBaseFailureNumber: Int?
    private let createdForkFailureNumber: Int?
    private let createdThreadFailureCause: CodexCreatedThreadFailureCause
    private let threadIDPrefix: String
    private let threadStore: FakePersistentThreadStore?
    private var discoverableThreadIDs: Set<String>?
    private var listThreadFailureCalls: Set<Int>
    private let baseCreationGate: SuspendedCallGate?
    private let forkCreationGate: SuspendedCallGate?
    private let startQuickGate: SuspendedCallGate?
    private let cancellationAwareStartQuickGate: CancellationAwareCallGate?
    private let startTurnGate: SuspendedCallGate?
    private let rateLimitGate: SuspendedCallGate?
    private let rateLimitGateCall: Int?
    private let shutdownGate: SuspendedCallGate?
    private let rejectRequestsAfterShutdown: Bool
    private var deleteThreadGate: SuspendedCallGate?
    private let confirmsAbsentAfterDeleteFailure: Bool
    private var deletionFailuresRemaining: Int
    private var nextBase = 1
    private var nextFork = 1
    private var baseCreationCallbacks = 0
    private var deleted: [String] = []
    private var interrupted: [String] = []
    private var writes: [SkillWrite] = []
    private var quickTurns = 0
    private var turnStarts = 0
    private var rateLimitReads = 0
    private var realtimeStops = 0
    private var realtimeDisables = 0
    private var loginStarts = 0
    private var accountReads = 0
    private var deleteAttempts = 0
    private var listThreadReads = 0
    private var shutdownCalls = 0
    private var isShutdown = false
    private var hangingContinuations: [String: AsyncThrowingStream<CodexTurnEvent, any Error>.Continuation] = [:]

    init(
        realtime: Bool,
        directEphemeralResponses: Bool = false,
        quickOutputs: [String] = [],
        turnOutputs: [String] = [],
        quickTerminalStatuses: [String] = [],
        turnTerminalStatuses: [String] = [],
        quickErrors: [CodexClientError] = [],
        realtimeStreamErrors: [CodexClientError] = [],
        accountErrors: [CodexClientError] = [],
        rateLimitErrors: [CodexClientError] = [],
        interruptErrors: [CodexClientError] = [],
        ambientSkillEnabled: Bool = false,
        hangQuick: Bool = false,
        signedIn: Bool = true,
        remoteRateLimited: Bool = false,
        remoteCapacitySequence: [Bool] = [],
        invalidBaseCwd: Bool = false,
        invalidBaseNumber: Int? = nil,
        lostBaseResponseNumber: Int? = nil,
        lostBaseResponseError: CodexClientError = .requestTimedOut(method: "thread/start"),
        lostBaseResponseGate: CancellationAwareCallGate? = nil,
        createdBaseFailureNumber: Int? = nil,
        createdForkFailureNumber: Int? = nil,
        createdThreadFailureCause: CodexCreatedThreadFailureCause = .client(
            .threadInvariantFailed
        ),
        threadIDPrefix: String = "",
        threadStore: FakePersistentThreadStore? = nil,
        discoverableThreadIDs: Set<String>? = nil,
        listThreadFailureCalls: Set<Int> = [],
        baseCreationGate: SuspendedCallGate? = nil,
        forkCreationGate: SuspendedCallGate? = nil,
        startQuickGate: SuspendedCallGate? = nil,
        cancellationAwareStartQuickGate: CancellationAwareCallGate? = nil,
        startTurnGate: SuspendedCallGate? = nil,
        rateLimitGate: SuspendedCallGate? = nil,
        rateLimitGateCall: Int? = nil,
        shutdownGate: SuspendedCallGate? = nil,
        rejectRequestsAfterShutdown: Bool = false,
        deleteThreadGate: SuspendedCallGate? = nil,
        deletionFailuresRemaining: Int = 0,
        confirmsAbsentAfterDeleteFailure: Bool = false
    ) {
        runtimeCapabilities = .init(realtimeTextV3: realtime)
        usesDirectEphemeralResponses = directEphemeralResponses
        self.quickOutputs = quickOutputs
        self.turnOutputs = turnOutputs
        self.quickTerminalStatuses = quickTerminalStatuses
        self.turnTerminalStatuses = turnTerminalStatuses
        self.quickErrors = quickErrors
        self.realtimeStreamErrors = realtimeStreamErrors
        self.accountErrors = accountErrors
        self.rateLimitErrors = rateLimitErrors
        self.interruptErrors = interruptErrors
        self.ambientSkillEnabled = ambientSkillEnabled
        self.hangQuick = hangQuick
        self.signedIn = signedIn
        self.remoteRateLimited = remoteRateLimited
        self.remoteCapacitySequence = remoteCapacitySequence
        self.invalidBaseCwd = invalidBaseCwd
        self.invalidBaseNumber = invalidBaseNumber
        self.lostBaseResponseNumber = lostBaseResponseNumber
        self.lostBaseResponseError = lostBaseResponseError
        self.lostBaseResponseGate = lostBaseResponseGate
        self.createdBaseFailureNumber = createdBaseFailureNumber
        self.createdForkFailureNumber = createdForkFailureNumber
        self.createdThreadFailureCause = createdThreadFailureCause
        self.threadIDPrefix = threadIDPrefix
        self.threadStore = threadStore
        self.discoverableThreadIDs = discoverableThreadIDs
        self.listThreadFailureCalls = listThreadFailureCalls
        self.baseCreationGate = baseCreationGate
        self.forkCreationGate = forkCreationGate
        self.startQuickGate = startQuickGate
        self.cancellationAwareStartQuickGate = cancellationAwareStartQuickGate
        self.startTurnGate = startTurnGate
        self.rateLimitGate = rateLimitGate
        self.rateLimitGateCall = rateLimitGateCall
        self.shutdownGate = shutdownGate
        self.rejectRequestsAfterShutdown = rejectRequestsAfterShutdown
        self.deleteThreadGate = deleteThreadGate
        self.deletionFailuresRemaining = deletionFailuresRemaining
        self.confirmsAbsentAfterDeleteFailure = confirmsAbsentAfterDeleteFailure
    }

    func account(refreshToken: Bool) async throws -> CodexAccountReadResult {
        accountReads += 1
        if !accountErrors.isEmpty {
            throw accountErrors.removeFirst()
        }
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
        rateLimitReads += 1
        if let rateLimitGateCall, rateLimitReads == rateLimitGateCall, let rateLimitGate {
            await rateLimitGate.suspend()
        }
        if !rateLimitErrors.isEmpty {
            throw rateLimitErrors.removeFirst()
        }
        let hasCapacity =
            remoteCapacitySequence.isEmpty
            ? !remoteRateLimited
            : remoteCapacitySequence.removeFirst()
        let fixture =
            !hasCapacity
            ? CodexFixtures.rateLimitsResult.replacingOccurrences(
                of: #""usedPercent":12"#,
                with: #""usedPercent":100"#
            ) : CodexFixtures.rateLimitsResult
        return try CodexFixtures.value(fixture).decode(CodexRateLimitsResult.self)
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
        let baseNumber = nextBase
        let id = "\(threadIDPrefix)base-\(baseNumber)"
        nextBase += 1
        if let baseCreationGate {
            await baseCreationGate.suspend()
        }
        let sources =
            cwd.contains("quick-context")
            ? []
            : [URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md").path]
        if let threadStore {
            await threadStore.insert(id, cwd: cwd)
        }
        return CodexBaseThread(
            id: id,
            model: model,
            permissionProfileID: "pacenote-readonly",
            cwd: invalidBaseCwd || invalidBaseNumber == baseNumber ? cwd + "/unexpected" : cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            instructionSources: sources
        )
    }

    func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread {
        let base = try await createPersistentBase(
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            model: model,
            baseInstructions: baseInstructions
        )
        if let lostBaseResponseGate {
            try await lostBaseResponseGate.suspend()
        }
        if lostBaseResponseNumber == nextBase - 1 {
            throw lostBaseResponseError
        }
        try await onCreated(base.id)
        baseCreationCallbacks += 1
        if createdBaseFailureNumber == nextBase - 1 {
            throw CodexCreatedThreadFailure(
                threadID: base.id,
                cause: createdThreadFailureCause
            )
        }
        return base
    }

    func prepareResponseTemplate(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        expectedInstructionSources: [String],
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread {
        _ = expectedInstructionSources
        return try await createPersistentBase(
            cwd: cwd,
            runtimeWorkspaceRoots: usesDirectEphemeralResponses ? [cwd] : runtimeWorkspaceRoots,
            model: model,
            baseInstructions: baseInstructions,
            onCreated: onCreated
        )
    }

    func forkEphemeral(from base: CodexBaseThread, model: String?) async throws
        -> CodexEphemeralThread
    {
        let id = "\(threadIDPrefix)fork-\(nextFork)"
        nextFork += 1
        if let forkCreationGate {
            await forkCreationGate.suspend()
        }
        if let threadStore {
            await threadStore.insert(id, cwd: base.cwd)
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

    func forkEphemeral(
        from base: CodexBaseThread,
        model: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexEphemeralThread {
        let fork = try await forkEphemeral(from: base, model: model)
        try await onCreated(fork.id)
        if createdForkFailureNumber == nextFork - 1 {
            throw CodexCreatedThreadFailure(
                threadID: fork.id,
                cause: createdThreadFailureCause
            )
        }
        return fork
    }

    func deleteThread(id: String) async throws {
        if rejectRequestsAfterShutdown, isShutdown {
            throw CodexClientError.notInitialized
        }
        deleteAttempts += 1
        if let deleteThreadGate {
            self.deleteThreadGate = nil
            await deleteThreadGate.suspend()
        }
        if deletionFailuresRemaining > 0 {
            deletionFailuresRemaining -= 1
            throw CodexClientError.transportUnavailable
        }
        deleted.append(id)
        if let threadStore {
            await threadStore.remove(id)
        }
        discoverableThreadIDs?.remove(id)
        hangingContinuations.removeValue(forKey: id)?.finish(throwing: CancellationError())
    }

    func listThreadIDs(cwd: String) async throws -> [String] {
        if rejectRequestsAfterShutdown, isShutdown {
            throw CodexClientError.notInitialized
        }
        listThreadReads += 1
        if listThreadFailureCalls.remove(listThreadReads) != nil {
            throw CodexClientError.transportUnavailable
        }
        if let threadStore { return await threadStore.threadIDs(cwd: cwd) }
        if let discoverableThreadIDs { return discoverableThreadIDs.sorted() }
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
            let pair = AsyncThrowingStream<CodexRealtimeEvent, any Error>.makeStream()
            if !realtimeStreamErrors.isEmpty {
                pair.continuation.finish(throwing: realtimeStreamErrors.removeFirst())
                return .realtime(.init(threadID: threadID, events: pair.stream))
            }
            let output = quickOutputs.removeFirst()
            pair.continuation.yield(.transcriptDone(role: "assistant", text: output))
            return .realtime(.init(threadID: threadID, events: pair.stream))
        }
        quickTurns += 1
        if !quickErrors.isEmpty { throw quickErrors.removeFirst() }
        if let startQuickGate {
            await startQuickGate.suspend()
        }
        if let cancellationAwareStartQuickGate {
            try await cancellationAwareStartQuickGate.suspend()
        }
        if hangQuick {
            let pair = AsyncThrowingStream<CodexTurnEvent, any Error>.makeStream()
            hangingContinuations[threadID] = pair.continuation
            return .turn(.init(threadID: threadID, turnID: "turn-quick", events: pair.stream))
        }
        let status =
            quickTerminalStatuses.isEmpty
            ? "completed"
            : quickTerminalStatuses.removeFirst()
        return .turn(
            Self.completedTurn(
                threadID: threadID,
                output: quickOutputs.removeFirst(),
                status: status
            )
        )
    }

    func startTurn(
        threadID: String,
        text: String,
        model: String?,
        effort: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexTurnSession {
        turnStarts += 1
        let status =
            turnTerminalStatuses.isEmpty
            ? "completed"
            : turnTerminalStatuses.removeFirst()
        let session = Self.completedTurn(
            threadID: threadID,
            output: turnOutputs.removeFirst(),
            status: status
        )
        if let startTurnGate {
            await startTurnGate.suspend()
        }
        return session
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        interrupted.append(threadID)
        if !interruptErrors.isEmpty {
            throw interruptErrors.removeFirst()
        }
        hangingContinuations.removeValue(forKey: threadID)?.finish(throwing: CancellationError())
    }

    func disableRealtimeQuick() async { realtimeDisables += 1 }
    func stopRealtimeText(threadID: String) async throws { realtimeStops += 1 }
    func shutdown() async {
        if let shutdownGate {
            await shutdownGate.suspend()
        }
        isShutdown = true
        shutdownCalls += 1
    }

    func skillWrites() -> [SkillWrite] { writes }
    func deletedThreadIDs() -> [String] { deleted }
    func interruptedThreadIDs() -> [String] { interrupted }
    func quickTurnCount() -> Int { quickTurns }
    func turnStartCount() -> Int { turnStarts }
    func rateLimitReadCount() -> Int { rateLimitReads }
    func realtimeStopCount() -> Int { realtimeStops }
    func realtimeDisableCount() -> Int { realtimeDisables }
    func loginStartCount() -> Int { loginStarts }
    func accountReadCount() -> Int { accountReads }
    func baseCount() -> Int { nextBase - 1 }
    func forkCount() -> Int { nextFork - 1 }
    func deleteAttemptCount() -> Int { deleteAttempts }
    func shutdownCallCount() -> Int { shutdownCalls }
    func baseCreationCallbackCount() -> Int { baseCreationCallbacks }

    private static func completedTurn(
        threadID: String,
        output: String,
        status: String = "completed"
    ) -> CodexTurnSession {
        let pair = AsyncThrowingStream<CodexTurnEvent, any Error>.makeStream()
        pair.continuation.yield(
            .itemCompleted([
                "type": "agentMessage",
                "text": .string(output),
                "phase": "final_answer",
            ]))
        pair.continuation.yield(.completed(status: status))
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
