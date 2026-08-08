import Foundation
import XCTest

@testable import PaceNoteCore

final class MeetingSessionControllerTests: XCTestCase {
    func testConsentDenialDoesNotPrepareAssetsOrResponseRuntime() async throws {
        let harness = makeHarness(mode: .manualOnly)

        do {
            try await harness.controller.preflight(
                consent: MeetingConsent(participantDisclosureConfirmed: false)
            )
            XCTFail("Expected consent gate")
        } catch let failure as MeetingSessionFailure {
            XCTAssertEqual(failure, .consentRequired)
        }

        let state = await harness.controller.state()
        let prepareCount = await harness.response.prepareCount
        let assetPrepareCount = await harness.assets.prepareCount
        XCTAssertEqual(state.phase, .permissionRequired)
        XCTAssertFalse(state.isPrepared)
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(assetPrepareCount, 0)
        _ = await harness.controller.stop()
    }

    func testOutputDisabledModeNeverStartsOrStopsOutputServices() async throws {
        let harness = makeHarness(mode: .microphoneOnly, includeDisabledServices: true)
        try await prepareAndStart(harness)

        let state = await harness.controller.state()
        let microphoneStarts = await harness.microphoneCapture.startCount
        let outputStarts = await harness.outputCapture.startCount
        XCTAssertTrue(state.brownouts.contains { $0.reason == .outputDisabled })
        XCTAssertEqual(microphoneStarts, 1)
        XCTAssertEqual(outputStarts, 0)

        _ = await harness.controller.stop()
        let outputStops = await harness.outputCapture.stopCount
        XCTAssertEqual(outputStops, 0)
    }

    func testManualOnlyCoachWorksWithoutMicrophoneOutputOrSpeechAssets() async throws {
        let harness = makeHarness(mode: .manualOnly)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Explain the retry boundary")

        let reachedSuggestion = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .deep }
        }
        let state = await harness.controller.state()
        let turns = await harness.response.deepRequestedTurns
        let assetPrepareCount = await harness.assets.prepareCount
        XCTAssertTrue(reachedSuggestion)
        XCTAssertEqual(state.transcript.count, 1)
        XCTAssertEqual(state.transcript.first?.source, .them)
        XCTAssertEqual(turns.last?.question, "Explain the retry boundary")
        XCTAssertTrue(state.brownouts.contains { $0.reason == .microphoneDisabled })
        XCTAssertTrue(state.brownouts.contains { $0.reason == .outputDisabled })
        XCTAssertEqual(assetPrepareCount, 0)
        _ = await harness.controller.stop()
    }

    func testVolatileTranscriptIsReplacedByFinalRevisionWithSameID() async throws {
        let harness = makeHarness(mode: .systemOutputOnly)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(transcript(.output, "How does this retry", stability: .volatile))
        )
        let receivedVolatile = await eventually {
            let state = await harness.controller.state()
            return state.transcript.count == 1 && state.transcript[0].isFinal == false
        }
        let volatileID = await harness.controller.state().transcript.first?.id

        await harness.outputTranscriber.emit(
            .result(transcript(.output, "How does this retry?", stability: .final))
        )
        let receivedFinal = await eventually {
            let state = await harness.controller.state()
            return state.transcript.count == 1 && state.transcript[0].isFinal
        }
        let state = await harness.controller.state()
        XCTAssertTrue(receivedVolatile)
        XCTAssertTrue(receivedFinal)
        XCTAssertEqual(state.transcript.first?.id, volatileID)
        XCTAssertEqual(state.transcript.first?.text, "How does this retry?")
        XCTAssertEqual(state.transcript.first?.source, .them)
        _ = await harness.controller.stop()
    }

    func testCoachCurrentTurnForcesLatestOutputWithoutDuplicatingTranscript() async throws {
        let harness = makeHarness(mode: .systemOutputOnly)
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(transcript(.output, "The retry boundary is stable.", stability: .final))
        )
        let transcriptArrived = await eventually {
            await harness.controller.state().transcript.count == 1
        }
        XCTAssertTrue(transcriptArrived)

        try await harness.controller.coachCurrentTurn()
        let suggestionArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .deep }
        }

        let state = await harness.controller.state()
        XCTAssertTrue(suggestionArrived)
        XCTAssertEqual(state.transcript.count, 1)
        _ = await harness.controller.stop()
    }

    func testRouteGapCancelsInFlightResponseClearsCueAndRecovers() async throws {
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(transcript(.output, "The retry path has an isolation boundary.", stability: .final))
        )
        let transcriptArrived = await eventually {
            await harness.controller.state().transcript.count == 1
        }
        XCTAssertTrue(transcriptArrived)
        try await harness.controller.coachCurrentTurn()
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        let cancelCountBeforeGap = await response.cancelCount
        let gap = AudioGap(
            lane: .output,
            reason: .routeChanged,
            detectedAt: HostTimestamp(ticks: 100)
        )

        await harness.outputTranscriber.emit(.gap(gap))
        let reachedBrownout = await eventually {
            let state = await harness.controller.state()
            let cancelCount = await response.cancelCount
            return state.phase == .brownout
                && state.brownouts.contains { $0.reason == .systemAudioLost }
                && state.suggestions.isEmpty
                && cancelCount > cancelCountBeforeGap
        }

        await harness.outputTranscriber.emit(
            .started(lane: .output, localeIdentifier: "en-US")
        )
        let recovered = await eventually {
            let state = await harness.controller.state()
            return !state.brownouts.contains { $0.reason == .systemAudioLost }
                && state.phase == .listening
        }
        XCTAssertTrue(reachedBrownout)
        XCTAssertTrue(recovered)
        _ = await harness.controller.stop()
    }

    func testLostRouteAndTranscriberFailureInvalidateInFlightResponses() async throws {
        let route = testRouteDescriptor(lane: .output)
        let interruptions: [SpeechTranscriptionEvent] = [
            .routeChanged(previous: route, current: nil),
            .failed(lane: .output, reason: .analyzerFailed),
        ]

        for interruption in interruptions {
            let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
            let harness = makeHarness(mode: .systemOutputOnly, response: response)
            try await prepareAndStart(harness)
            await harness.outputTranscriber.emit(
                .result(transcript(.output, "The request moves through a queue.", stability: .final))
            )
            let transcriptArrived = await eventually {
                await harness.controller.state().transcript.count == 1
            }
            XCTAssertTrue(transcriptArrived)
            try await harness.controller.coachCurrentTurn()
            let cueArrived = await eventually {
                await harness.controller.state().suggestions.contains { $0.stage == .bridge }
            }
            XCTAssertTrue(cueArrived)
            let cancelCountBeforeInterruption = await response.cancelCount

            await harness.outputTranscriber.emit(interruption)

            let invalidated = await eventually {
                let state = await harness.controller.state()
                let cancelCount = await response.cancelCount
                return state.suggestions.isEmpty
                    && cancelCount > cancelCountBeforeInterruption
            }
            XCTAssertTrue(invalidated, "Expected \(interruption) to invalidate in-flight work")
            _ = await harness.controller.stop()
        }
    }

    func testSystemAudioPermissionDenialIsPreservedForRecoveryUI() async throws {
        let harness = makeHarness(
            mode: .systemOutputOnly,
            outputStartError: .permissionDenied
        )
        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )

        do {
            try await harness.controller.start()
            XCTFail("Expected system audio permission failure")
        } catch let failure as MeetingSessionFailure {
            XCTAssertEqual(failure, .systemAudioPermissionDenied)
        }

        let state = await harness.controller.state()
        XCTAssertTrue(state.brownouts.contains { $0.reason == .systemAudioLost })
        _ = await harness.controller.stop()
    }

    func testPauseStopsAudioCancelsGenerationAndResumeRestartsCapture() async throws {
        let harness = makeHarness(mode: .systemOutputOnly)
        try await prepareAndStart(harness)

        try await harness.controller.pause()
        let pausedState = await harness.controller.state()
        let stopsAfterPause = await harness.outputCapture.stopCount
        let cancelsAfterPause = await harness.response.cancelCount
        XCTAssertEqual(pausedState.phase, .paused)
        XCTAssertFalse(pausedState.isRunning)
        XCTAssertEqual(stopsAfterPause, 1)
        XCTAssertGreaterThanOrEqual(cancelsAfterPause, 1)

        try await harness.controller.resume()
        let resumedState = await harness.controller.state()
        let startsAfterResume = await harness.outputCapture.startCount
        XCTAssertTrue(resumedState.isRunning)
        XCTAssertEqual(resumedState.phase, .listening)
        XCTAssertEqual(startsAfterResume, 2)
        _ = await harness.controller.stop()
    }

    func testNewTypedCueCancelsStaleDeepAndOnlyLatestCardsRemain() async throws {
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)

        try await harness.controller.submitTypedQuestion("Why is the first path slow?")
        let firstCueArrived = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.identity.generation == 1 && $0.stage == .bridge }
        }
        try await harness.controller.submitTypedQuestion("Why is the second path isolated?")
        let secondDeepArrived = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.identity.generation == 2 && $0.stage == .deep }
        }

        let state = await harness.controller.state()
        let cancelCount = await response.cancelCount
        XCTAssertTrue(firstCueArrived)
        XCTAssertTrue(secondDeepArrived)
        XCTAssertFalse(state.suggestions.contains { $0.identity.generation == 1 })
        XCTAssertTrue(state.suggestions.allSatisfy { $0.identity.generation == 2 })
        XCTAssertGreaterThanOrEqual(cancelCount, 2)
        _ = await harness.controller.stop()
    }

    func testClarificationAndAbstentionDeepDraftsReachSpeakableCards() async throws {
        let clarificationResponse = FakeMeetingResponseGenerator(deepKind: .clarification)
        let clarificationHarness = makeHarness(
            mode: .manualOnly,
            response: clarificationResponse
        )
        try await prepareAndStart(clarificationHarness)
        try await clarificationHarness.controller.submitTypedQuestion("Which deployment do you mean?")
        let clarificationVisible = await eventually {
            let state = await clarificationHarness.controller.state()
            return state.suggestions.contains {
                $0.stage == .deep && $0.text.hasPrefix("The detail I need is:")
            }
        }
        XCTAssertTrue(clarificationVisible)
        _ = await clarificationHarness.controller.stop()

        let abstentionResponse = FakeMeetingResponseGenerator(deepKind: .abstention)
        let abstentionHarness = makeHarness(mode: .manualOnly, response: abstentionResponse)
        try await prepareAndStart(abstentionHarness)
        try await abstentionHarness.controller.submitTypedQuestion("What is the unverified value?")
        let abstentionVisible = await eventually {
            let state = await abstentionHarness.controller.state()
            return state.suggestions.contains {
                $0.stage == .deep && $0.text.hasPrefix("I cannot verify that yet.")
            }
        }
        XCTAssertTrue(abstentionVisible)
        _ = await abstentionHarness.controller.stop()
    }

    func testStopOrdersCleanupClearsEphemeralStateAndRemovesJournalOnSuccess() async throws {
        let response = FakeMeetingResponseGenerator(
            shutdownReport: MeetingResponseCleanupReport(deletedThreadCount: 3)
        )
        let cleaner = FakeMeetingResourceCleaner(
            deleteReport: MeetingResourceCleanupReport(
                deletedSnapshotCount: 1,
                deletedTemporaryRootCount: 2
            )
        )
        let harness = makeHarness(mode: .manualOnly, response: response, cleaner: cleaner)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Where is the retry state stored?")

        let report = await harness.controller.stop()
        let state = await harness.controller.state()
        let shutdownCount = await response.shutdownCount
        let journalRemovals = await cleaner.journalRemovalCount
        let cleanupOperations = await cleaner.operations()
        XCTAssertTrue(report.cleanupSucceeded)
        XCTAssertEqual(report.deletedThreadCount, 3)
        XCTAssertEqual(report.deletedSnapshotCount, 1)
        XCTAssertEqual(report.deletedTemporaryRootCount, 2)
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(journalRemovals, 1)
        XCTAssertEqual(
            cleanupOperations,
            [.deleteResources, .residualAudit, .deletePrivateRoot, .removeJournal]
        )
        XCTAssertEqual(state.phase, .ended)
        XCTAssertTrue(state.transcript.isEmpty)
        XCTAssertTrue(state.suggestions.isEmpty)
    }

    func testStopRetainsJournalWhenResidualAuditFindsTranscriptData() async throws {
        let cleaner = FakeMeetingResourceCleaner(residualFindingCount: 1)
        let harness = makeHarness(mode: .manualOnly, cleaner: cleaner)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Do not persist this question")

        let report = await harness.controller.stop()
        let journalRemovals = await cleaner.journalRemovalCount
        XCTAssertFalse(report.cleanupSucceeded)
        XCTAssertEqual(report.residualFindingCount, 1)
        XCTAssertTrue(report.failures.contains(.residualData))
        XCTAssertEqual(journalRemovals, 0)
    }

    func testStopRetainsJournalWhenPrivateRootDeletionFails() async throws {
        let cleaner = FakeMeetingResourceCleaner(privateRootDeletionFails: true)
        let harness = makeHarness(mode: .manualOnly, cleaner: cleaner)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Keep recovery until root deletion is verified")

        let report = await harness.controller.stop()
        let cleanupOperations = await cleaner.operations()
        let journalRemovals = await cleaner.journalRemovalCount

        XCTAssertFalse(report.cleanupSucceeded)
        XCTAssertTrue(report.failures.contains(.privateRootDeletion))
        XCTAssertEqual(journalRemovals, 0)
        XCTAssertEqual(
            cleanupOperations,
            [.deleteResources, .residualAudit, .deletePrivateRoot]
        )
    }

    func testAttributionResolverSuppressesExactAndNearDuplicateEcho() {
        let resolver = TranscriptAttributionResolver()
        let output = transcript(
            .output,
            "We should retry the request after the circuit breaker opens",
            confidence: 0.95
        )
        let exact = transcript(
            .microphone,
            "We should retry the request after the circuit breaker opens",
            confidence: 0.94
        )
        let near = transcript(
            .microphone,
            "We should retry the request when the circuit breaker opens",
            confidence: 0.91
        )

        XCTAssertEqual(
            resolver.resolveMicrophone(exact, receivedAt: 10.1, against: output, receivedAt: 10),
            .suppressEcho
        )
        XCTAssertEqual(
            resolver.resolveMicrophone(near, receivedAt: 10.2, against: output, receivedAt: 10),
            .suppressEcho
        )
    }

    func testControllerSuppressesEchoAndMarksAmbiguousOverlapUnknown() async throws {
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5)
        )
        try await prepareAndStart(harness)
        let outputText = "We should retry the request after the circuit breaker opens"
        await harness.outputTranscriber.emit(
            .result(transcript(.output, outputText, confidence: 0.95))
        )
        let outputVisibleBeforeEcho = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains { $0.source == .them && $0.text == outputText }
        }
        XCTAssertTrue(outputVisibleBeforeEcho)
        clock.set(10.1)
        await harness.microphoneTranscriber.emit(
            .result(transcript(.microphone, outputText, confidence: 0.94))
        )
        let echoSuppressed = await eventually {
            let state = await harness.controller.state()
            return state.transcript.count == 1 && state.transcript[0].source == .them
        }

        clock.set(10.2)
        await harness.microphoneTranscriber.emit(
            .result(transcript(.microphone, "I can explain our local write path", confidence: 0.92))
        )
        let ambiguityVisible = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains { $0.source == .unknown }
                && state.brownouts.contains { $0.reason == .speakerUncertain }
        }
        XCTAssertTrue(echoSuppressed)
        XCTAssertTrue(ambiguityVisible)
        _ = await harness.controller.stop()
    }

    func testClearlySeparateMicrophoneSpeechIsAttributedToYou() async throws {
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5)
        )
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(transcript(.output, "The remote speaker finished this thought", confidence: 0.94))
        )
        let outputVisibleBeforeLocalSpeech = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains { $0.source == .them }
        }
        XCTAssertTrue(outputVisibleBeforeLocalSpeech)
        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(transcript(.microphone, "My separate local response", confidence: 0.91))
        )

        let localSpeechVisible = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains {
                $0.source == .you && $0.text == "My separate local response"
            }
        }
        let state = await harness.controller.state()
        XCTAssertTrue(localSpeechVisible)
        XCTAssertFalse(state.brownouts.contains { $0.reason == .speakerUncertain })
        _ = await harness.controller.stop()
    }

    func testClearlyAttributedUserSpeechCancelsDeepAndPreservesDisplayedCue() async throws {
        let clock = LockedMeetingTime(10)
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            response: response,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5)
        )
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(transcript(.output, "The request moves through a queue.", confidence: 0.94))
        )
        let transcriptArrived = await eventually {
            await harness.controller.state().transcript.contains { $0.source == .them }
        }
        XCTAssertTrue(transcriptArrived)
        try await harness.controller.coachCurrentTurn()
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        let stateWithCue = await harness.controller.state()
        let cue = try XCTUnwrap(stateWithCue.suggestions.first { $0.stage == .bridge })
        let cancelCountBeforeSpeech = await response.cancelCount

        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(transcript(.microphone, "I can walk through that boundary", confidence: 0.93))
        )

        let localSpeechInvalidatedDeep = await eventually {
            let state = await harness.controller.state()
            let cancelCount = await response.cancelCount
            return state.transcript.contains {
                $0.source == .you && $0.text == "I can walk through that boundary"
            }
                && state.suggestions == [cue]
                && cancelCount > cancelCountBeforeSpeech
        }
        XCTAssertTrue(localSpeechInvalidatedDeep)
        _ = await harness.controller.stop()
    }

    private func prepareAndStart(_ harness: SessionHarness) async throws {
        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
    }

    private func makeHarness(
        mode: MeetingCaptureMode,
        includeDisabledServices: Bool = false,
        response: FakeMeetingResponseGenerator = FakeMeetingResponseGenerator(),
        cleaner: FakeMeetingResourceCleaner = FakeMeetingResourceCleaner(),
        time: any MeetingTimeProviding = LockedMeetingTime(10),
        microphoneAttributionDelay: Duration = .milliseconds(5),
        outputStartError: AudioCaptureError? = nil
    ) -> SessionHarness {
        let microphoneCapture = FakeSessionAudioCapture(lane: .microphone)
        let outputCapture = FakeSessionAudioCapture(
            lane: .output,
            startError: outputStartError
        )
        let microphoneTranscriber = FakeSessionTranscriber(lane: .microphone)
        let outputTranscriber = FakeSessionTranscriber(lane: .output)
        let assets = FakeSessionSpeechAssets()
        let permission = FakeSessionMicrophonePermission(status: .granted)

        let microphoneServices: MeetingAudioLaneServices? =
            mode.capturesMicrophone || includeDisabledServices
            ? MeetingAudioLaneServices(
                lane: .microphone,
                capture: microphoneCapture,
                transcriber: microphoneTranscriber
            )
            : nil
        let outputServices: MeetingAudioLaneServices? =
            mode.capturesSystemOutput || includeDisabledServices
            ? MeetingAudioLaneServices(
                lane: .output,
                capture: outputCapture,
                transcriber: outputTranscriber
            )
            : nil
        let controller = MeetingSessionController(
            configuration: MeetingSessionConfiguration(
                meetingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                captureMode: mode,
                turnBoundaryDelay: .milliseconds(5),
                microphoneAttributionDelay: microphoneAttributionDelay
            ),
            audioServices: MeetingAudioServices(
                microphone: microphoneServices,
                systemOutput: outputServices
            ),
            speechAssets: assets,
            microphonePermission: permission,
            responseGenerator: response,
            responseCoordinatorConfiguration: .init(
                quickDeadline: .milliseconds(50),
                resultTTL: .seconds(1)
            ),
            resourceCleaner: cleaner,
            time: time
        )
        return SessionHarness(
            controller: controller,
            response: response,
            cleaner: cleaner,
            assets: assets,
            microphoneCapture: microphoneCapture,
            outputCapture: outputCapture,
            microphoneTranscriber: microphoneTranscriber,
            outputTranscriber: outputTranscriber
        )
    }
}

private struct SessionHarness {
    let controller: MeetingSessionController
    let response: FakeMeetingResponseGenerator
    let cleaner: FakeMeetingResourceCleaner
    let assets: FakeSessionSpeechAssets
    let microphoneCapture: FakeSessionAudioCapture
    let outputCapture: FakeSessionAudioCapture
    let microphoneTranscriber: FakeSessionTranscriber
    let outputTranscriber: FakeSessionTranscriber
}

private actor FakeMeetingResponseGenerator: MeetingResponseGenerating {
    let runtime = MeetingResponseRuntime(
        planType: "pro",
        quickRoute: CodexModelRoute(model: "quick", effort: "low"),
        deepRoute: CodexModelRoute(model: "deep", effort: "medium"),
        usesRealtimeQuick: true
    )
    let shutdownReport: MeetingResponseCleanupReport
    let slowDeepGenerations: Set<UInt64>
    let deepKind: DeepDraftKind
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var shutdownCount = 0
    private(set) var requestedTurns: [ConversationTurn] = []
    private(set) var deepRequestedTurns: [ConversationTurn] = []

    init(
        slowDeepGenerations: Set<UInt64> = [],
        shutdownReport: MeetingResponseCleanupReport = .init(),
        deepKind: DeepDraftKind = .answer
    ) {
        self.slowDeepGenerations = slowDeepGenerations
        self.shutdownReport = shutdownReport
        self.deepKind = deepKind
    }

    func prepare() -> MeetingResponseRuntime {
        prepareCount += 1
        return runtime
    }

    func cancelActiveWork() {
        cancelCount += 1
    }

    func shutdown() -> MeetingResponseCleanupReport {
        shutdownCount += 1
        return shutdownReport
    }

    func generateQuick(for turn: ConversationTurn) async throws -> QuickModelOutput {
        requestedTurns.append(turn)
        await Task.yield()
        try Task.checkCancellation()
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: "I would separate the boundary before changing it.",
            needsDeep: true,
            confidence: 0.8,
            reason: "technical"
        )
    }

    func generateDeep(for turn: ConversationTurn) async throws -> DeepDraft {
        deepRequestedTurns.append(turn)
        if slowDeepGenerations.contains(turn.identity.generation) {
            try await Task.sleep(for: .seconds(30))
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
        return DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: turn.groundingFingerprint,
            kind: deepKind,
            candidateSayNext: deepText,
            confidence: 0.9,
            basis: []
        )
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) -> Reconciliation {
        switch draft.kind {
        case .answer:
            Reconciliation(relationship: .continueAnswer, transition: "More specifically,")
        case .clarification:
            Reconciliation(relationship: .clarify, transition: "The detail I need is:")
        case .abstention:
            Reconciliation(relationship: .abstain, transition: "I cannot verify that yet.")
        }
    }

    private var deepText: String {
        switch deepKind {
        case .answer:
            "The isolated queue prevents downstream retries from blocking the caller."
        case .clarification:
            "whether you mean staging or production"
        case .abstention:
            "I need the repository evidence before giving a precise value."
        }
    }
}

private actor FakeMeetingResourceCleaner: MeetingSessionResourceCleaning {
    enum Operation: Equatable {
        case deleteResources
        case residualAudit
        case deletePrivateRoot
        case removeJournal
    }

    let deleteReport: MeetingResourceCleanupReport
    let configuredResidualFindingCount: Int
    let privateRootDeletionFails: Bool
    private(set) var journalRemovalCount = 0
    private var recordedOperations: [Operation] = []

    init(
        deleteReport: MeetingResourceCleanupReport = .init(),
        residualFindingCount: Int = 0,
        privateRootDeletionFails: Bool = false
    ) {
        self.deleteReport = deleteReport
        self.configuredResidualFindingCount = residualFindingCount
        self.privateRootDeletionFails = privateRootDeletionFails
    }

    func deleteResources(preserveCodexRecoveryState: Bool) -> MeetingResourceCleanupReport {
        recordedOperations.append(.deleteResources)
        return deleteReport
    }

    func residualFindingCount(sensitiveNeedles: [Data]) -> Int {
        recordedOperations.append(.residualAudit)
        return configuredResidualFindingCount
    }

    func deletePrivateRoot() throws {
        recordedOperations.append(.deletePrivateRoot)
        if privateRootDeletionFails { throw FakeCleanupError.privateRootDeletion }
    }

    func removeJournalEntry(meetingID: UUID) {
        recordedOperations.append(.removeJournal)
        journalRemovalCount += 1
    }

    func operations() -> [Operation] { recordedOperations }
}

private enum FakeCleanupError: Error {
    case privateRootDeletion
}

private actor FakeSessionSpeechAssets: SpeechAssetPreparing {
    private(set) var prepareCount = 0

    func availability(localeIdentifier: String) -> SpeechAssetAvailability {
        .installed
    }

    func prepare(localeIdentifier: String) -> SpeechAssetPreparation {
        prepareCount += 1
        return SpeechAssetPreparation(
            localeIdentifier: localeIdentifier,
            installedDuringPreparation: false,
            reserved: true
        )
    }
}

private actor FakeSessionMicrophonePermission: MicrophonePermissionProviding {
    let configuredStatus: AudioPermissionStatus

    init(status: AudioPermissionStatus) {
        self.configuredStatus = status
    }

    func status() -> AudioPermissionStatus {
        configuredStatus
    }

    func request() -> AudioPermissionStatus {
        configuredStatus
    }
}

private actor FakeSessionAudioCapture: AudioCapturing {
    nonisolated let lane: AudioLane
    let startError: AudioCaptureError?
    private var continuation: AsyncStream<AudioCaptureEvent>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(lane: AudioLane, startError: AudioCaptureError? = nil) {
        self.lane = lane
        self.startError = startError
    }

    func events() -> AsyncStream<AudioCaptureEvent> {
        continuation?.finish()
        let pair = AsyncStream.makeStream(of: AudioCaptureEvent.self)
        continuation = pair.continuation
        return pair.stream
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() {
        stopCount += 1
        continuation?.yield(.stopped(lane))
        continuation?.finish()
        continuation = nil
    }
}

private actor FakeSessionTranscriber: AudioTranscribing {
    nonisolated let lane: AudioLane
    private var continuation: AsyncStream<SpeechTranscriptionEvent>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(lane: AudioLane) {
        self.lane = lane
    }

    func events() -> AsyncStream<SpeechTranscriptionEvent> {
        continuation?.finish()
        let pair = AsyncStream.makeStream(of: SpeechTranscriptionEvent.self)
        continuation = pair.continuation
        return pair.stream
    }

    func start(
        audioEvents: AsyncStream<AudioCaptureEvent>,
        localeIdentifier: String
    ) {
        startCount += 1
        continuation?.yield(.started(lane: lane, localeIdentifier: localeIdentifier))
    }

    func emit(_ event: SpeechTranscriptionEvent) {
        continuation?.yield(event)
    }

    func stop() {
        stopCount += 1
        continuation?.yield(.stopped(lane))
        continuation?.finish()
        continuation = nil
    }
}

private final class LockedMeetingTime: @unchecked Sendable, MeetingTimeProviding {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }

    func now() -> TimeInterval {
        lock.withLock { value }
    }

    func set(_ value: TimeInterval) {
        lock.withLock { self.value = value }
    }
}

private func transcript(
    _ lane: AudioLane,
    _ text: String,
    stability: TranscriptStability = .final,
    confidence: Double = 0.9
) -> ProgressiveTranscriptResult {
    ProgressiveTranscriptResult(
        lane: lane,
        text: text,
        hostTimeRange: nil,
        stability: stability,
        confidence: confidence
    )
}

private func testRouteDescriptor(lane: AudioLane) -> AudioRouteDescriptor {
    AudioRouteDescriptor(
        lane: lane,
        scope: lane == .microphone ? .defaultMicrophone : .selectedProcesses,
        format: AudioFormatDescription(
            sampleRate: 16_000,
            formatID: 1,
            formatFlags: 0,
            bytesPerPacket: 4,
            framesPerPacket: 1,
            bytesPerFrame: 4,
            channelsPerFrame: 1,
            bitsPerChannel: 32,
            isInterleaved: true
        )
    )
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
