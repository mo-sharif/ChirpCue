import AVFoundation
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

    func testCombinedCaptureStartsOutputBeforeMicrophone() async throws {
        let startRecorder = AudioLaneStartRecorder()
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            startRecorder: startRecorder
        )

        try await prepareAndStart(harness)

        let lanes = await startRecorder.lanes
        XCTAssertEqual(lanes, [.output, .microphone])
        _ = await harness.controller.stop()
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
        XCTAssertEqual(state.suggestions.first(where: { $0.stage == .deep })?.deepKind, .generalAnswer)
        XCTAssertTrue(state.suggestions.first(where: { $0.stage == .deep })?.evidence.isEmpty == true)
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

    func testGlobalSystemOutputUsesOutputLabelInsteadOfThem() async throws {
        let harness = makeHarness(
            mode: .systemOutputOnly,
            systemOutputScope: .allSystemAudio
        )
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(transcript(.output, "How does this retry?", stability: .final))
        )

        let globalOutputVisible = await eventually {
            let state = await harness.controller.state()
            return state.transcript.first?.source == .output
        }
        XCTAssertTrue(globalOutputVisible)
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
        try await Task.sleep(for: .milliseconds(30))
        let turnsBeforeManualCoach = await harness.response.deepRequestedTurns
        let stateBeforeManualCoach = await harness.controller.state()
        XCTAssertTrue(turnsBeforeManualCoach.isEmpty)
        XCTAssertTrue(stateBeforeManualCoach.suggestions.isEmpty)

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
                let expectedBrownout: BrownoutReason =
                    if case .failed = interruption {
                        .transcriptionUnavailable
                    } else {
                        .systemAudioLost
                    }
                return state.suggestions.isEmpty
                    && state.brownouts.contains { $0.reason == expectedBrownout }
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

    func testProviderRateLimitIsPreservedForRecoveryUI() async throws {
        let response = FakeMeetingResponseGenerator(prepareFailure: .quickRateLimited)
        let harness = makeHarness(mode: .manualOnly, response: response)

        do {
            _ = try await harness.controller.preflight(
                consent: MeetingConsent(participantDisclosureConfirmed: true)
            )
            XCTFail("Expected provider rate limit")
        } catch let failure as MeetingSessionFailure {
            XCTAssertEqual(failure, .responseRateLimited)
            XCTAssertEqual(
                failure.errorDescription,
                "The selected provider is temporarily rate limited. Wait for its allowance to reset, then choose Recheck and start again."
            )
        }

        let state = await harness.controller.state()
        XCTAssertTrue(state.brownouts.contains { $0.reason == .quickLimited })
        _ = await harness.controller.stop()
    }

    func testStopInvalidatesAndAwaitsSuspendedPreflight() async throws {
        let preparationBarrier = AudioOperationBarrier()
        let response = FakeMeetingResponseGenerator(prepareBarrier: preparationBarrier)
        let harness = makeHarness(mode: .manualOnly, response: response)
        await preparationBarrier.arm()

        let preflight = Task { () -> MeetingSessionFailure? in
            do {
                _ = try await harness.controller.preflight(
                    consent: MeetingConsent(participantDisclosureConfirmed: true)
                )
                return nil
            } catch let failure as MeetingSessionFailure {
                return failure
            } catch {
                return .responseUnavailable
            }
        }
        await preparationBarrier.waitUntilEntered()

        let stopProbe = StopReportProbe()
        let stop = Task {
            let report = await harness.controller.stop()
            await stopProbe.store(report)
            return report
        }
        let stopReturnedEarly = await eventually(timeout: .milliseconds(100)) {
            await stopProbe.hasReport
        }
        XCTAssertFalse(stopReturnedEarly)

        await preparationBarrier.release()
        let preflightFailure = await preflight.value
        let stopReport = await stop.value
        let state = await harness.controller.state()
        let shutdownCount = await response.shutdownCount

        XCTAssertEqual(preflightFailure, .invalidLifecycle)
        XCTAssertTrue(stopReport.cleanupSucceeded)
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(state.phase, .ended)
        XCTAssertFalse(state.isPrepared)
    }

    func testStopInvalidatesAndAwaitsSuspendedStart() async throws {
        let startBarrier = AudioOperationBarrier()
        let harness = makeHarness(mode: .systemOutputOnly, outputStartBarrier: startBarrier)
        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        await startBarrier.arm()

        let start = Task { () -> MeetingSessionFailure? in
            do {
                try await harness.controller.start()
                return nil
            } catch let failure as MeetingSessionFailure {
                return failure
            } catch {
                return .responseUnavailable
            }
        }
        await startBarrier.waitUntilEntered()

        let stopProbe = StopReportProbe()
        let stop = Task {
            let report = await harness.controller.stop()
            await stopProbe.store(report)
            return report
        }
        let stopReturnedEarly = await eventually(timeout: .milliseconds(100)) {
            await stopProbe.hasReport
        }
        XCTAssertFalse(stopReturnedEarly)

        await startBarrier.release()
        let startFailure = await start.value
        let stopReport = await stop.value
        let state = await harness.controller.state()
        let startCount = await harness.outputCapture.startCount
        let stopCount = await harness.outputCapture.stopCount

        XCTAssertEqual(startFailure, .invalidLifecycle)
        XCTAssertTrue(stopReport.cleanupSucceeded)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(state.phase, .ended)
        XCTAssertFalse(state.isRunning)
    }

    func testStopInvalidatesAndAwaitsSuspendedResume() async throws {
        let startBarrier = AudioOperationBarrier()
        let harness = makeHarness(mode: .systemOutputOnly, outputStartBarrier: startBarrier)
        try await prepareAndStart(harness)
        try await harness.controller.pause()
        await startBarrier.arm()

        let resume = Task { () -> MeetingSessionFailure? in
            do {
                try await harness.controller.resume()
                return nil
            } catch let failure as MeetingSessionFailure {
                return failure
            } catch {
                return .responseUnavailable
            }
        }
        await startBarrier.waitUntilEntered()

        let stopProbe = StopReportProbe()
        let stop = Task {
            let report = await harness.controller.stop()
            await stopProbe.store(report)
            return report
        }
        let stopReturnedEarly = await eventually(timeout: .milliseconds(100)) {
            await stopProbe.hasReport
        }
        XCTAssertFalse(stopReturnedEarly)

        await startBarrier.release()
        let resumeFailure = await resume.value
        let stopReport = await stop.value
        let state = await harness.controller.state()
        let startCount = await harness.outputCapture.startCount
        let stopCount = await harness.outputCapture.stopCount

        XCTAssertEqual(resumeFailure, .invalidLifecycle)
        XCTAssertTrue(stopReport.cleanupSucceeded)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(stopCount, 2)
        XCTAssertEqual(state.phase, .ended)
        XCTAssertFalse(state.isRunning)
    }

    func testStopInvalidatesAndAwaitsSuspendedPause() async throws {
        let stopBarrier = AudioOperationBarrier()
        let harness = makeHarness(mode: .systemOutputOnly, outputStopBarrier: stopBarrier)
        try await prepareAndStart(harness)
        await stopBarrier.arm()

        let pause = Task { () -> MeetingSessionFailure? in
            do {
                try await harness.controller.pause()
                return nil
            } catch let failure as MeetingSessionFailure {
                return failure
            } catch {
                return .responseUnavailable
            }
        }
        await stopBarrier.waitUntilEntered()

        let stopProbe = StopReportProbe()
        let stop = Task {
            let report = await harness.controller.stop()
            await stopProbe.store(report)
            return report
        }
        let stopReturnedEarly = await eventually(timeout: .milliseconds(100)) {
            await stopProbe.hasReport
        }
        XCTAssertFalse(stopReturnedEarly)

        await stopBarrier.release()
        let pauseFailure = await pause.value
        let stopReport = await stop.value
        let state = await harness.controller.state()
        let stopCount = await harness.outputCapture.stopCount

        XCTAssertEqual(pauseFailure, .invalidLifecycle)
        XCTAssertTrue(stopReport.cleanupSucceeded)
        XCTAssertEqual(stopCount, 2)
        XCTAssertEqual(state.phase, .ended)
        XCTAssertFalse(state.isRunning)
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
        let clock = LockedMeetingTime(10)
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .manualOnly, response: response, time: clock)
        try await prepareAndStart(harness)

        try await harness.controller.submitTypedQuestion("Why is the first path slow?")
        let firstCueArrived = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.identity.generation == 1 && $0.stage == .bridge }
        }
        clock.set(11)
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
        let timing = await harness.controller.timingSnapshot()
        XCTAssertEqual(timing.samples.count, 2)
        XCTAssertEqual(timing.samples[0].turnStableToBridgeReadySeconds, 0)
        XCTAssertEqual(timing.samples[0].invalidationOutcome, .newerTurn)
        XCTAssertEqual(timing.samples[1].deepOutcome, .ready)
        _ = await harness.controller.stop()
    }

    func testConfirmedSpeechTimingUsesVerifiedHostOnsetInsteadOfDelayedReceipt() async throws {
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(
            mode: .microphoneOnly,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5),
            soleNearbySpeakerConfirmed: true
        )
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("How does the bounded queue work?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)

        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    "I started answering before the cue arrived",
                    confidence: 0.95,
                    hostTimeRange: hostTimeRange(start: 9.75)
                )
            )
        )
        let speechAttributed = await eventually {
            await harness.controller.state().transcript.contains {
                $0.source == .you && $0.text == "I started answering before the cue arrived"
            }
        }
        let timing = await harness.controller.timingSnapshot()

        XCTAssertTrue(speechAttributed)
        XCTAssertEqual(
            timing.samples.first?.bridgeToConfirmedLocalSpeechMarginSeconds ?? 0,
            -0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(timing.targets.bridgeBeforeLocalSpeechStatus, .missed)
        _ = await harness.controller.stop()
    }

    func testDismissCancelsDeepAndClearsOnlyCurrentSuggestionCards() async throws {
        let clock = LockedMeetingTime(10)
        let deepBarrier = AudioOperationBarrier()
        await deepBarrier.arm()
        let response = FakeMeetingResponseGenerator(deepBarrier: deepBarrier)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            response: response,
            time: clock,
            soleNearbySpeakerConfirmed: true
        )
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("How does the request queue work?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        await deepBarrier.waitUntilEntered()

        let beforeDismiss = await harness.controller.state()
        let identity = try XCTUnwrap(beforeDismiss.suggestions.first?.identity)
        let transcriptBeforeDismiss = beforeDismiss.transcript
        let cancelCountBeforeDismiss = await response.cancelCount
        await harness.controller.dismissSuggestion(identity: identity)

        let dismissed = await harness.controller.state()
        let timing = await harness.controller.timingSnapshot()
        let microphoneStopCount = await harness.microphoneCapture.stopCount
        let outputStopCount = await harness.outputCapture.stopCount
        let cancelCountAfterDismiss = await response.cancelCount
        XCTAssertTrue(dismissed.isRunning)
        XCTAssertEqual(dismissed.phase, .listening)
        XCTAssertEqual(dismissed.transcript, transcriptBeforeDismiss)
        XCTAssertTrue(dismissed.suggestions.isEmpty)
        XCTAssertEqual(microphoneStopCount, 0)
        XCTAssertEqual(outputStopCount, 0)
        XCTAssertGreaterThan(cancelCountAfterDismiss, cancelCountBeforeDismiss)
        XCTAssertEqual(timing.userDismissedCount, 1)
        XCTAssertEqual(timing.samples.first?.invalidationOutcome, .userDismissed)

        await deepBarrier.release()
        try? await Task.sleep(for: .milliseconds(20))
        let stateAfterLateDeep = await harness.controller.state()
        XCTAssertTrue(stateAfterLateDeep.suggestions.isEmpty)
        _ = await harness.controller.stop()
    }

    func testDismissedDeepSuggestionRemainsInStopResidualAudit() async throws {
        let cleaner = FakeMeetingResourceCleaner()
        let harness = makeHarness(mode: .manualOnly, cleaner: cleaner)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is the queue isolated?")
        let deepArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .deep }
        }
        XCTAssertTrue(deepArrived)

        let stateWithDeep = await harness.controller.state()
        let dismissedDeep = try XCTUnwrap(
            stateWithDeep.suggestions.first { $0.stage == .deep }
        )
        await harness.controller.dismissSuggestion(identity: dismissedDeep.identity)
        let dismissedState = await harness.controller.state()
        XCTAssertTrue(dismissedState.suggestions.isEmpty)

        let report = await harness.controller.stop()
        let auditedNeedles = await cleaner.sensitiveNeedles()
        let expectedFragment = Data(dismissedDeep.text.utf8.prefix(128))
        XCTAssertTrue(report.cleanupSucceeded)
        XCTAssertTrue(auditedNeedles.contains(expectedFragment))
    }

    func testDismissCancellationFinishesBeforeANewerTurnStartsGeneration() async throws {
        let cancellationBarrier = AudioOperationBarrier()
        let response = FakeMeetingResponseGenerator(cancelBarrier: cancellationBarrier)
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is the first path isolated?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        let firstState = await harness.controller.state()
        let firstIdentity = try XCTUnwrap(firstState.suggestions.first?.identity)

        await cancellationBarrier.arm()
        let dismissTask = Task {
            await harness.controller.dismissSuggestion(identity: firstIdentity)
        }
        await cancellationBarrier.waitUntilEntered()
        let nextTurnTask = Task {
            try await harness.controller.submitTypedQuestion("Why is the second path bounded?")
        }
        try await Task.sleep(for: .milliseconds(20))
        let deepRequestCountWhileCancelling = await response.deepRequestedTurns.count
        XCTAssertEqual(deepRequestCountWhileCancelling, 1)

        await cancellationBarrier.release()
        await dismissTask.value
        try await nextTurnTask.value
        let newerDeepArrived = await eventually {
            await harness.controller.state().suggestions.contains {
                $0.identity.generation == 2 && $0.stage == .deep
            }
        }
        XCTAssertTrue(newerDeepArrived)
        _ = await harness.controller.stop()
    }

    func testPauseJoinsAnInFlightDismissCancellation() async throws {
        let cancellationBarrier = AudioOperationBarrier()
        let response = FakeMeetingResponseGenerator(cancelBarrier: cancellationBarrier)
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is this queue bounded?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        let stateWithCue = await harness.controller.state()
        let identity = try XCTUnwrap(stateWithCue.suggestions.first?.identity)
        let transcriptBeforeDismiss = stateWithCue.transcript

        await cancellationBarrier.arm()
        let dismissTask = Task {
            await harness.controller.dismissSuggestion(identity: identity)
        }
        await cancellationBarrier.waitUntilEntered()
        let pauseTask = Task { try await harness.controller.pause() }
        await cancellationBarrier.release()

        await dismissTask.value
        try await pauseTask.value
        let pausedState = await harness.controller.state()
        XCTAssertEqual(pausedState.phase, .paused)
        XCTAssertFalse(pausedState.isRunning)
        XCTAssertEqual(pausedState.transcript, transcriptBeforeDismiss)
        XCTAssertTrue(pausedState.suggestions.isEmpty)
        _ = await harness.controller.stop()
    }

    func testStopSupersedesAnInFlightDismissCancellation() async throws {
        let cancellationBarrier = AudioOperationBarrier()
        let responseEventBarrier = AudioOperationBarrier()
        await responseEventBarrier.arm()
        let response = FakeMeetingResponseGenerator(cancelBarrier: cancellationBarrier)
        let harness = makeHarness(mode: .manualOnly, response: response)
        await harness.controller.setResponseEventTestHook { event in
            if case .deep = event {
                await responseEventBarrier.suspendIfArmed()
            }
        }
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is this queue bounded?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        await responseEventBarrier.waitUntilEntered()
        let stateWithCue = await harness.controller.state()
        let identity = try XCTUnwrap(stateWithCue.suggestions.first?.identity)

        await cancellationBarrier.arm()
        let stopCompletion = AsyncCompletionProbe()
        let dismissTask = Task {
            await harness.controller.dismissSuggestion(identity: identity)
        }
        await cancellationBarrier.waitUntilEntered()
        let stopTask = Task {
            let report = await harness.controller.stop()
            await stopCompletion.markCompleted()
            return report
        }
        await cancellationBarrier.release()
        try await Task.sleep(for: .milliseconds(20))

        let stopFinishedBeforeGenerationDrain = await stopCompletion.isCompleted()
        XCTAssertFalse(stopFinishedBeforeGenerationDrain)

        await responseEventBarrier.release()

        await dismissTask.value
        let report = await stopTask.value
        let auditedNeedles = await harness.cleaner.sensitiveNeedles()
        let expectedLateDeepFragment = Data(
            "I would separate the immediate decision from implementation details."
                .utf8.prefix(128)
        )
        let stoppedState = await harness.controller.state()
        XCTAssertTrue(report.cleanupSucceeded)
        XCTAssertTrue(auditedNeedles.contains(expectedLateDeepFragment))
        XCTAssertEqual(stoppedState.phase, .ended)
        XCTAssertFalse(stoppedState.isRunning)
        XCTAssertTrue(stoppedState.transcript.isEmpty)
        XCTAssertTrue(stoppedState.suggestions.isEmpty)
    }

    func testStaleDismissIdentityCannotClearOrCancelANewerTurn() async throws {
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is the first path slow?")
        let firstCueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(firstCueArrived)
        let firstState = await harness.controller.state()
        let staleIdentity = try XCTUnwrap(firstState.suggestions.first?.identity)

        try await harness.controller.submitTypedQuestion("Why is the second path isolated?")
        let newerDeepArrived = await eventually {
            await harness.controller.state().suggestions.contains {
                $0.identity.generation == 2 && $0.stage == .deep
            }
        }
        XCTAssertTrue(newerDeepArrived)
        let beforeStaleDismiss = await harness.controller.state()
        let cancelCount = await response.cancelCount

        await harness.controller.dismissSuggestion(identity: staleIdentity)

        let stateAfterStaleDismiss = await harness.controller.state()
        let cancelCountAfterStaleDismiss = await response.cancelCount
        let timingAfterStaleDismiss = await harness.controller.timingSnapshot()
        XCTAssertEqual(stateAfterStaleDismiss.suggestions, beforeStaleDismiss.suggestions)
        XCTAssertEqual(cancelCountAfterStaleDismiss, cancelCount)
        XCTAssertEqual(timingAfterStaleDismiss.userDismissedCount, 0)
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

    func testDeepFailureBecomesTerminalAndCoachCurrentTurnRetriesSameQuestion() async throws {
        let response = FakeMeetingResponseGenerator(
            deepFailuresRemaining: 1,
            deepFailure: .protocolUnsupported
        )
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)
        let question = "How should I explain mutexes and semaphores?"
        try await harness.controller.submitTypedQuestion(question)

        let failureVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .bridge }
                && state.suggestions.allSatisfy { $0.stage != .deep }
                && state.brownouts.contains { $0.reason == .deepUnavailable }
        }
        XCTAssertTrue(failureVisible)

        try await harness.controller.coachCurrentTurn()
        let retryResolved = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason.isDeepResponseFailure }
        }
        let requestedTurns = await response.deepRequestedTurns
        XCTAssertTrue(retryResolved)
        XCTAssertEqual(requestedTurns.map(\.question), [question, question])
        _ = await harness.controller.stop()
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

    func testStopAuditsAndClearsDelayedAttributionText() async throws {
        let cleanupBarrier = CleanupBarrier()
        let cleaner = FakeMeetingResourceCleaner(deleteBarrier: cleanupBarrier)
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            cleaner: cleaner,
            time: clock,
            microphoneAttributionDelay: .seconds(5)
        )
        try await prepareAndStart(harness)
        let outputText = "Sensitive output words retained during attribution"
        let pendingText = "Sensitive microphone words waiting for speaker attribution"
        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    outputText,
                    confidence: 0.96,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
        )
        let outputRetained = await eventually {
            await harness.controller.delayedAttributionRetentionSnapshot()
                .hasLatestOutputObservation
        }
        XCTAssertTrue(outputRetained)
        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    pendingText,
                    confidence: 0.91,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let populated = await eventually {
            let snapshot = await harness.controller.delayedAttributionRetentionSnapshot()
            return snapshot.hasAttributionTask
                && snapshot.hasPendingMicrophoneObservation
                && snapshot.hasLatestOutputObservation
        }
        XCTAssertTrue(populated)

        let stopTask = Task { await harness.controller.stop() }
        await cleanupBarrier.waitUntilEntered()

        let cleared = await harness.controller.delayedAttributionRetentionSnapshot()
        XCTAssertEqual(
            cleared,
            MeetingSessionController.DelayedAttributionRetentionSnapshot(
                hasAttributionTask: false,
                hasPendingMicrophoneObservation: false,
                hasLatestOutputObservation: false
            )
        )
        await cleanupBarrier.release()

        let report = await stopTask.value
        let retainedNeedles = await cleaner.sensitiveNeedles()
        let auditedNeedles = retainedNeedles.compactMap {
            String(data: $0, encoding: .utf8)
        }
        let state = await harness.controller.state()

        XCTAssertTrue(report.cleanupSucceeded)
        XCTAssertTrue(auditedNeedles.contains(pendingText))
        XCTAssertTrue(auditedNeedles.contains(outputText))
        XCTAssertTrue(state.transcript.isEmpty)
        XCTAssertTrue(state.suggestions.isEmpty)
    }

    func testCleanupNeedleOverflowFailsClosedAndStillRunsBoundedResidualAudit() async throws {
        let cleaner = FakeMeetingResourceCleaner()
        let harness = makeHarness(
            mode: .manualOnly,
            cleaner: cleaner,
            cleanupNeedleCapacity: 1
        )
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is the first path isolated?")
        try await harness.controller.submitTypedQuestion("Why is the second path bounded?")

        let report = await harness.controller.stop()
        let cleanupOperations = await cleaner.operations()
        let auditedNeedles = await cleaner.sensitiveNeedles()
        let journalRemovals = await cleaner.journalRemovalCount

        XCTAssertFalse(report.cleanupSucceeded)
        XCTAssertTrue(report.failures.contains(.residualAudit))
        XCTAssertEqual(auditedNeedles.count, 1)
        XCTAssertEqual(cleanupOperations, [.deleteResources, .residualAudit])
        XCTAssertEqual(journalRemovals, 0)
    }

    func testDeepArrivingDuringAudioTeardownIsIncludedInStopResidualAudit() async throws {
        let deepBarrier = AudioOperationBarrier()
        let outputStopBarrier = AudioOperationBarrier()
        await deepBarrier.arm()
        await outputStopBarrier.arm()
        let response = FakeMeetingResponseGenerator(deepBarrier: deepBarrier)
        let cleaner = FakeMeetingResourceCleaner()
        let harness = makeHarness(
            mode: .systemOutputOnly,
            response: response,
            cleaner: cleaner,
            outputStopBarrier: outputStopBarrier
        )
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is this queue bounded?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        await deepBarrier.waitUntilEntered()

        let stopTask = Task { await harness.controller.stop() }
        await outputStopBarrier.waitUntilEntered()
        let stateDuringStop = await harness.controller.state()
        XCTAssertTrue(stateDuringStop.transcript.isEmpty)
        XCTAssertTrue(stateDuringStop.suggestions.isEmpty)

        await deepBarrier.release()
        let staleDeepWasHandled = await eventually {
            await harness.controller.timingSnapshot().staleDiscardedCount == 1
        }
        XCTAssertTrue(staleDeepWasHandled)
        await outputStopBarrier.release()

        let report = await stopTask.value
        let auditedNeedles = await cleaner.sensitiveNeedles()
        let lateDeepText =
            "I would separate the immediate decision from implementation details."
        let expectedFragment = Data(lateDeepText.utf8.prefix(128))
        XCTAssertTrue(report.cleanupSucceeded)
        XCTAssertTrue(auditedNeedles.contains(expectedFragment))
    }

    func testConcurrentStopCallersAwaitOneCleanupAndReceiveTheSameReport() async throws {
        let cleanupBarrier = CleanupBarrier()
        let response = FakeMeetingResponseGenerator(
            shutdownReport: MeetingResponseCleanupReport(deletedThreadCount: 4)
        )
        let cleaner = FakeMeetingResourceCleaner(
            deleteReport: MeetingResourceCleanupReport(
                deletedSnapshotCount: 2,
                deletedTemporaryRootCount: 3
            ),
            deleteBarrier: cleanupBarrier
        )
        let harness = makeHarness(mode: .manualOnly, response: response, cleaner: cleaner)
        try await prepareAndStart(harness)

        let firstStop = Task { await harness.controller.stop() }
        await cleanupBarrier.waitUntilEntered()

        let secondResult = StopReportProbe()
        let secondStop = Task {
            let report = await harness.controller.stop()
            await secondResult.store(report)
            return report
        }
        let secondReturnedBeforeCleanupFinished = await eventually(timeout: .milliseconds(200)) {
            await secondResult.hasReport
        }
        XCTAssertFalse(secondReturnedBeforeCleanupFinished)

        await cleanupBarrier.release()
        let firstReport = await firstStop.value
        let secondReport = await secondStop.value
        let cachedReport = await harness.controller.stop()

        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(secondReport, cachedReport)
        XCTAssertTrue(firstReport.cleanupSucceeded)
        XCTAssertEqual(firstReport.deletedThreadCount, 4)
        XCTAssertEqual(firstReport.deletedSnapshotCount, 2)
        XCTAssertEqual(firstReport.deletedTemporaryRootCount, 3)
        let shutdownCount = await response.shutdownCount
        let journalRemovalCount = await cleaner.journalRemovalCount
        let cleanupOperations = await cleaner.operations()
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(journalRemovalCount, 1)
        XCTAssertEqual(
            cleanupOperations,
            [.deleteResources, .residualAudit, .deletePrivateRoot, .removeJournal]
        )
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

    func testStopRetriesTransientAudioTeardownAndReportsSuccess() async throws {
        let harness = makeHarness(mode: .systemOutputOnly, outputStopFailureCount: 1)
        try await prepareAndStart(harness)

        let report = await harness.controller.stop()
        let state = await harness.controller.state()
        let stopCount = await harness.outputCapture.stopCount
        let journalRemovals = await harness.cleaner.journalRemovalCount

        XCTAssertTrue(report.cleanupSucceeded)
        XCTAssertFalse(report.failures.contains(.audioCaptureTeardown))
        XCTAssertEqual(stopCount, 2)
        XCTAssertEqual(journalRemovals, 1)
        XCTAssertEqual(state.phase, .ended)
    }

    func testStopRetainsControllerForExplicitRetryAfterBoundedAudioFailure() async throws {
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            outputStopFailureCount: 2
        )
        try await prepareAndStart(harness)

        let failedReport = await harness.controller.stop()
        let failedState = await harness.controller.state()
        let firstOutputStopCount = await harness.outputCapture.stopCount
        let firstMicrophoneStopCount = await harness.microphoneCapture.stopCount
        let firstJournalRemovals = await harness.cleaner.journalRemovalCount

        XCTAssertFalse(failedReport.cleanupSucceeded)
        XCTAssertTrue(failedReport.failures.contains(.audioCaptureTeardown))
        XCTAssertEqual(failedReport.audioTeardownFailureLane, .output)
        XCTAssertEqual(firstOutputStopCount, 2)
        XCTAssertEqual(firstMicrophoneStopCount, 2)
        XCTAssertEqual(firstJournalRemovals, 0)
        XCTAssertEqual(failedState.phase, .brownout)

        let retryReport = await harness.controller.stop()
        let retryState = await harness.controller.state()
        let finalOutputStopCount = await harness.outputCapture.stopCount
        let cleanupOperations = await harness.cleaner.operations()

        XCTAssertTrue(retryReport.cleanupSucceeded)
        XCTAssertNil(retryReport.audioTeardownFailureLane)
        XCTAssertEqual(finalOutputStopCount, 3)
        XCTAssertEqual(retryState.phase, .ended)
        XCTAssertEqual(
            cleanupOperations,
            [.deleteResources, .residualAudit, .deletePrivateRoot, .removeJournal]
        )
    }

    func testStopAudioTeardownFailureEmitsTypedFailureBeforeBrownoutState() async throws {
        let harness = makeHarness(
            mode: .systemOutputOnly,
            outputStopFailureCount: 2
        )
        let events = await harness.controller.events()
        let observedFailureAndState:
            Task<
                (MeetingSessionFailure?, MeetingSessionState?), Never
            > = Task {
                var failure: MeetingSessionFailure?
                for await event in events {
                    switch event {
                    case .failed(let incoming):
                        failure = incoming
                    case .stateChanged(let state) where failure != nil:
                        return (failure, state)
                    default:
                        continue
                    }
                }
                return (failure, nil)
            }
        try await prepareAndStart(harness)

        let report = await harness.controller.stop()
        let (failure, state) = await observedFailureAndState.value

        XCTAssertTrue(report.failures.contains(.audioCaptureTeardown))
        XCTAssertEqual(failure, .captureTeardownFailed(.output))
        XCTAssertEqual(state?.phase, .brownout)
        XCTAssertFalse(state?.isRunning ?? true)
    }

    func testStopReportPreservesMicrophoneTeardownLaneAcrossExplicitRetry() async throws {
        let harness = makeHarness(
            mode: .microphoneOnly,
            microphoneStopFailureCount: 4
        )
        try await prepareAndStart(harness)

        let firstReport = await harness.controller.stop()
        let secondReport = await harness.controller.stop()
        let failedStopCount = await harness.microphoneCapture.stopCount

        XCTAssertTrue(firstReport.failures.contains(.audioCaptureTeardown))
        XCTAssertEqual(firstReport.audioTeardownFailureLane, .microphone)
        XCTAssertTrue(secondReport.failures.contains(.audioCaptureTeardown))
        XCTAssertEqual(secondReport.audioTeardownFailureLane, .microphone)
        XCTAssertEqual(failedStopCount, 4)

        let recoveredReport = await harness.controller.stop()
        let recoveredStopCount = await harness.microphoneCapture.stopCount

        XCTAssertTrue(recoveredReport.cleanupSucceeded)
        XCTAssertNil(recoveredReport.audioTeardownFailureLane)
        XCTAssertEqual(recoveredStopCount, 5)
    }

    func testPauseFailureDoesNotClaimPausedOrPermitResume() async throws {
        let harness = makeHarness(mode: .systemOutputOnly, outputStopFailureCount: 1)
        try await prepareAndStart(harness)

        do {
            try await harness.controller.pause()
            XCTFail("Expected pause teardown failure")
        } catch let error as MeetingSessionFailure {
            XCTAssertEqual(error, .captureTeardownFailed(.output))
        }

        let state = await harness.controller.state()
        XCTAssertEqual(state.phase, .brownout)
        do {
            try await harness.controller.resume()
            XCTFail("Incomplete teardown must block resume")
        } catch let error as MeetingSessionFailure {
            XCTAssertEqual(error, .invalidLifecycle)
        }

        let report = await harness.controller.stop()
        XCTAssertTrue(report.cleanupSucceeded)
        let stopCount = await harness.outputCapture.stopCount
        XCTAssertEqual(stopCount, 2)
    }

    func testAttributionResolverSuppressesExactAndNearDuplicateEcho() {
        let resolver = TranscriptAttributionResolver()
        let start = HostTimestamp(ticks: 1)
        let range = HostTimeRange(start: start, end: start.advanced(by: 1))
        let output = transcript(
            .output,
            "We should retry the request after the circuit breaker opens",
            confidence: 0.95,
            hostTimeRange: range
        )
        let exact = transcript(
            .microphone,
            "We should retry the request after the circuit breaker opens",
            confidence: 0.94,
            hostTimeRange: range
        )
        let near = transcript(
            .microphone,
            "We should retry the request when the circuit breaker opens",
            confidence: 0.91,
            hostTimeRange: range
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
            .result(
                transcript(
                    .output,
                    outputText,
                    confidence: 0.95,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
        )
        let outputVisibleBeforeEcho = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains { $0.source == .them && $0.text == outputText }
        }
        XCTAssertTrue(outputVisibleBeforeEcho)
        clock.set(10.1)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    outputText,
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 10.1)
                )
            )
        )
        let echoSuppressed = await eventually {
            let state = await harness.controller.state()
            return state.transcript.count == 1 && state.transcript[0].source == .them
        }

        clock.set(10.2)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    "I can explain our local write path",
                    confidence: 0.92,
                    hostTimeRange: hostTimeRange(start: 10.2)
                )
            )
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
            microphoneAttributionDelay: .milliseconds(5),
            soleNearbySpeakerConfirmed: true
        )
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "The remote speaker finished this thought",
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
        )
        let outputVisibleBeforeLocalSpeech = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains { $0.source == .them }
        }
        XCTAssertTrue(outputVisibleBeforeLocalSpeech)
        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    "My separate local response",
                    confidence: 0.91,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
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

    func testMicrophoneSpeechUsesMicLabelWithoutSoleSpeakerConfirmation() async throws {
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5)
        )
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "The remote speaker finished this thought",
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
        )
        let outputVisible = await eventually {
            await harness.controller.state().transcript.contains { $0.source == .them }
        }
        XCTAssertTrue(outputVisible)

        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    "A nearby person can be speaking",
                    confidence: 0.91,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )

        let microphoneVisible = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains {
                $0.source == .microphone && $0.text == "A nearby person can be speaking"
            }
        }
        XCTAssertTrue(microphoneVisible)
        _ = await harness.controller.stop()
    }

    func testExactAndNearBridgeSpeechContinueDeepGeneration() async throws {
        let bridgeTranscripts = [
            "Let me think through that carefully for a second.",
            "Let me think through that for a second.",
        ]

        for bridgeTranscript in bridgeTranscripts {
            let clock = LockedMeetingTime(10)
            let deepBarrier = AudioOperationBarrier()
            await deepBarrier.arm()
            let response = FakeMeetingResponseGenerator(deepBarrier: deepBarrier)
            let harness = makeHarness(
                mode: .microphoneAndSystemOutput,
                response: response,
                time: clock,
                microphoneAttributionDelay: .milliseconds(5),
                soleNearbySpeakerConfirmed: true
            )
            try await prepareAndStart(harness)
            await harness.outputTranscriber.emit(
                .result(
                    transcript(
                        .output,
                        "The request moves through a queue.",
                        confidence: 0.94,
                        hostTimeRange: hostTimeRange(start: 10)
                    )
                )
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
            await deepBarrier.waitUntilEntered()
            let cancelCountBeforeSpeech = await response.cancelCount

            clock.set(12)
            await harness.microphoneTranscriber.emit(
                .result(
                    transcript(
                        .microphone,
                        bridgeTranscript,
                        confidence: 0.93,
                        hostTimeRange: hostTimeRange(start: 12)
                    )
                )
            )
            let bridgeBecameFinal = await eventually {
                await harness.controller.state().transcript.contains {
                    $0.source == .you && $0.text == bridgeTranscript && $0.isFinal
                }
            }
            XCTAssertTrue(bridgeBecameFinal, bridgeTranscript)

            await deepBarrier.release()
            let deepArrived = await eventually {
                await harness.controller.state().suggestions.contains { $0.stage == .deep }
            }
            let cancelCountAfterDeep = await response.cancelCount
            XCTAssertTrue(deepArrived, bridgeTranscript)
            XCTAssertEqual(cancelCountAfterDeep, cancelCountBeforeSpeech, bridgeTranscript)
            _ = await harness.controller.stop()
        }
    }

    func testDeepArrivingDuringBridgeSpeechIsHeldUntilFinalTranscript() async throws {
        let clock = LockedMeetingTime(10)
        let deepBarrier = AudioOperationBarrier()
        await deepBarrier.arm()
        let response = FakeMeetingResponseGenerator(deepBarrier: deepBarrier)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            response: response,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5),
            soleNearbySpeakerConfirmed: true
        )
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "The request moves through a queue.",
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
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
        await deepBarrier.waitUntilEntered()
        let cancelCountBeforeSpeech = await response.cancelCount

        clock.set(12)
        let volatileBridge = "Let me think through that carefully"
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    volatileBridge,
                    stability: .volatile,
                    confidence: 0.93,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let holdActivated = await eventually {
            let state = await harness.controller.state()
            let retention = await harness.controller.bridgeSpeechRetentionSnapshot()
            return retention.hasActiveHold
                && state.transcript.contains {
                    $0.source == .you && $0.text == volatileBridge && !$0.isFinal
                }
        }
        XCTAssertTrue(holdActivated)

        await deepBarrier.release()
        let deepWasQueued = await eventually {
            await harness.controller.bridgeSpeechRetentionSnapshot().hasQueuedDeep
        }
        let stateWhileSpeaking = await harness.controller.state()
        let heldTiming = await harness.controller.timingSnapshot()
        XCTAssertTrue(deepWasQueued)
        XCTAssertTrue(stateWhileSpeaking.suggestions.contains { $0.stage == .bridge })
        XCTAssertFalse(stateWhileSpeaking.suggestions.contains { $0.stage == .deep })
        XCTAssertEqual(heldTiming.samples.first?.bridgeToConfirmedLocalSpeechMarginSeconds, 2)
        XCTAssertNil(heldTiming.samples.first?.turnStableToVerifiedDeepReadySeconds)
        XCTAssertEqual(heldTiming.samples.first?.deepOutcome, .pending)

        let finalBridge = "Let me think through that carefully for a second."
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    finalBridge,
                    confidence: 0.95,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let deepReleased = await eventually {
            let state = await harness.controller.state()
            let retention = await harness.controller.bridgeSpeechRetentionSnapshot()
            return state.suggestions.contains { $0.stage == .deep }
                && !retention.hasActiveHold
                && !retention.hasQueuedDeep
        }
        let cancelCountAfterDeep = await response.cancelCount
        let displayedTiming = await harness.controller.timingSnapshot()
        XCTAssertTrue(deepReleased)
        XCTAssertEqual(cancelCountAfterDeep, cancelCountBeforeSpeech)
        XCTAssertEqual(
            displayedTiming.samples.first?.turnStableToVerifiedDeepReadySeconds,
            2
        )
        XCTAssertEqual(displayedTiming.samples.first?.deepOutcome, .ready)

        let report = await harness.controller.stop()
        let clearedTiming = await harness.controller.timingSnapshot()
        XCTAssertEqual(report.timing.samples.first?.deepOutcome, .ready)
        XCTAssertEqual(report.timing.samples.first?.invalidationOutcome, .sessionStopped)
        XCTAssertEqual(clearedTiming, .empty)
    }

    func testDismissDropsDeepQueuedWhileTheBridgeIsBeingSpoken() async throws {
        let clock = LockedMeetingTime(10)
        let deepBarrier = AudioOperationBarrier()
        await deepBarrier.arm()
        let response = FakeMeetingResponseGenerator(deepBarrier: deepBarrier)
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            response: response,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5),
            soleNearbySpeakerConfirmed: true
        )
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("How does the request queue work?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(cueArrived)
        await deepBarrier.waitUntilEntered()
        let cueState = await harness.controller.state()
        let identity = try XCTUnwrap(cueState.suggestions.first?.identity)

        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    "Let me think through that carefully",
                    stability: .volatile,
                    confidence: 0.93,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let holdActivated = await eventually {
            await harness.controller.bridgeSpeechRetentionSnapshot().hasActiveHold
        }
        XCTAssertTrue(holdActivated)
        await deepBarrier.release()
        let deepQueued = await eventually {
            await harness.controller.bridgeSpeechRetentionSnapshot().hasQueuedDeep
        }
        XCTAssertTrue(deepQueued)

        await harness.controller.dismissSuggestion(identity: identity)
        let retentionAfterDismiss = await harness.controller.bridgeSpeechRetentionSnapshot()
        XCTAssertEqual(
            retentionAfterDismiss,
            MeetingSessionController.BridgeSpeechRetentionSnapshot(
                hasActiveHold: false,
                hasQueuedDeep: false
            )
        )
        let stateAfterDismiss = await harness.controller.state()
        XCTAssertTrue(stateAfterDismiss.suggestions.isEmpty)

        let finalBridge = "Let me think through that carefully for a second."
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    finalBridge,
                    confidence: 0.95,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let finalTranscriptVisible = await eventually {
            await harness.controller.state().transcript.contains {
                $0.source == .you && $0.text == finalBridge && $0.isFinal
            }
        }
        XCTAssertTrue(finalTranscriptVisible)
        try? await Task.sleep(for: .milliseconds(20))
        let finalState = await harness.controller.state()
        let timing = await harness.controller.timingSnapshot()
        XCTAssertTrue(finalState.isRunning)
        XCTAssertTrue(finalState.suggestions.isEmpty)
        XCTAssertEqual(timing.userDismissedCount, 1)
        XCTAssertEqual(timing.samples.first?.invalidationOutcome, .userDismissed)
        _ = await harness.controller.stop()
    }

    func testClearlyAttributedUserSpeechCancelsDeepAndPreservesDisplayedCue() async throws {
        let clock = LockedMeetingTime(10)
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            response: response,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5),
            soleNearbySpeakerConfirmed: true
        )
        try await prepareAndStart(harness)
        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "The request moves through a queue.",
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
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
        let substantiveResponse =
            "Let me think through that carefully for a second because the queue is isolated"
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    substantiveResponse,
                    stability: .volatile,
                    confidence: 0.93,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let volatileSpeechVisible = await eventually {
            await harness.controller.state().transcript.contains {
                $0.source == .you && $0.text == substantiveResponse && !$0.isFinal
            }
        }
        let cancelCountAfterVolatile = await response.cancelCount
        let stateAfterVolatile = await harness.controller.state()
        XCTAssertTrue(volatileSpeechVisible)
        XCTAssertEqual(cancelCountAfterVolatile, cancelCountBeforeSpeech)
        XCTAssertEqual(stateAfterVolatile.suggestions, [cue])

        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    substantiveResponse,
                    confidence: 0.93,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )

        let localSpeechInvalidatedDeep = await eventually {
            let state = await harness.controller.state()
            let cancelCount = await response.cancelCount
            return state.transcript.contains {
                $0.source == .you && $0.text == substantiveResponse && $0.isFinal
            }
                && state.suggestions == [cue]
                && cancelCount > cancelCountBeforeSpeech
        }
        XCTAssertTrue(localSpeechInvalidatedDeep)
        await harness.controller.dismissSuggestion(identity: cue.identity)
        let stateAfterDismiss = await harness.controller.state()
        let timingAfterDismiss = await harness.controller.timingSnapshot()
        XCTAssertTrue(stateAfterDismiss.suggestions.isEmpty)
        XCTAssertEqual(timingAfterDismiss.userDismissedCount, 1)
        XCTAssertEqual(timingAfterDismiss.samples.first?.invalidationOutcome, .localSpeech)
        XCTAssertEqual(timingAfterDismiss.samples.first?.userDismissed, true)
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
        systemOutputScope: MeetingSystemOutputScope = .meetingApplication,
        soleNearbySpeakerConfirmed: Bool = false,
        outputStartError: AudioCaptureError? = nil,
        outputStartBarrier: AudioOperationBarrier? = nil,
        outputStopBarrier: AudioOperationBarrier? = nil,
        microphoneStopFailureCount: Int = 0,
        outputStopFailureCount: Int = 0,
        cleanupNeedleCapacity: Int = 2_048,
        startRecorder: AudioLaneStartRecorder? = nil
    ) -> SessionHarness {
        let microphoneCapture = FakeSessionAudioCapture(
            lane: .microphone,
            stopFailureCount: microphoneStopFailureCount,
            startRecorder: startRecorder
        )
        let outputCapture = FakeSessionAudioCapture(
            lane: .output,
            startError: outputStartError,
            startBarrier: outputStartBarrier,
            stopBarrier: outputStopBarrier,
            stopFailureCount: outputStopFailureCount,
            startRecorder: startRecorder
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
                microphoneAttributionDelay: microphoneAttributionDelay,
                systemOutputScope: systemOutputScope,
                soleNearbySpeakerConfirmed: soleNearbySpeakerConfirmed
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
            time: time,
            cleanupNeedleCapacity: cleanupNeedleCapacity
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
    let prepareBarrier: AudioOperationBarrier?
    let deepBarrier: AudioOperationBarrier?
    let cancelBarrier: AudioOperationBarrier?
    let prepareFailure: MeetingResponseError?
    private var deepFailuresRemaining: Int
    private let deepFailure: MeetingResponseError
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var shutdownCount = 0
    private(set) var requestedTurns: [ConversationTurn] = []
    private(set) var deepRequestedTurns: [ConversationTurn] = []

    init(
        slowDeepGenerations: Set<UInt64> = [],
        shutdownReport: MeetingResponseCleanupReport = .init(),
        deepKind: DeepDraftKind = .generalAnswer,
        prepareBarrier: AudioOperationBarrier? = nil,
        deepBarrier: AudioOperationBarrier? = nil,
        cancelBarrier: AudioOperationBarrier? = nil,
        prepareFailure: MeetingResponseError? = nil,
        deepFailuresRemaining: Int = 0,
        deepFailure: MeetingResponseError = .runtimeUnavailable
    ) {
        self.slowDeepGenerations = slowDeepGenerations
        self.shutdownReport = shutdownReport
        self.deepKind = deepKind
        self.prepareBarrier = prepareBarrier
        self.deepBarrier = deepBarrier
        self.cancelBarrier = cancelBarrier
        self.prepareFailure = prepareFailure
        self.deepFailuresRemaining = max(0, deepFailuresRemaining)
        self.deepFailure = deepFailure
    }

    func prepare() async throws -> MeetingResponseRuntime {
        prepareCount += 1
        if let prepareBarrier { await prepareBarrier.suspendIfArmed() }
        if let prepareFailure { throw prepareFailure }
        return runtime
    }

    func cancelActiveWork() async {
        cancelCount += 1
        if let cancelBarrier { await cancelBarrier.suspendIfArmed() }
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
        if deepFailuresRemaining > 0 {
            deepFailuresRemaining -= 1
            throw deepFailure
        }
        if let deepBarrier { await deepBarrier.suspendIfArmed() }
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
        case .generalAnswer:
            Reconciliation(relationship: .continueAnswer, transition: "")
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
        case .generalAnswer:
            "I would separate the immediate decision from implementation details."
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
    let deleteBarrier: CleanupBarrier?
    private(set) var journalRemovalCount = 0
    private var recordedOperations: [Operation] = []
    private var recordedSensitiveNeedles: [Data] = []

    init(
        deleteReport: MeetingResourceCleanupReport = .init(),
        residualFindingCount: Int = 0,
        privateRootDeletionFails: Bool = false,
        deleteBarrier: CleanupBarrier? = nil
    ) {
        self.deleteReport = deleteReport
        self.configuredResidualFindingCount = residualFindingCount
        self.privateRootDeletionFails = privateRootDeletionFails
        self.deleteBarrier = deleteBarrier
    }

    func deleteResources(
        preserveCodexRecoveryState: Bool
    ) async -> MeetingResourceCleanupReport {
        recordedOperations.append(.deleteResources)
        if let deleteBarrier { await deleteBarrier.enterAndWaitForRelease() }
        return deleteReport
    }

    func residualFindingCount(sensitiveNeedles: [Data]) -> Int {
        recordedOperations.append(.residualAudit)
        recordedSensitiveNeedles = sensitiveNeedles
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
    func sensitiveNeedles() -> [Data] { recordedSensitiveNeedles }
}

private actor CleanupBarrier {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWaitForRelease() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor AudioOperationBarrier {
    private var armed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arm() {
        precondition(!armed && !entered)
        armed = true
        released = false
    }

    func suspendIfArmed() async {
        guard armed else { return }
        armed = false
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        guard !released else {
            entered = false
            return
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
        entered = false
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor AsyncCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor StopReportProbe {
    private var report: MeetingSessionStopReport?

    var hasReport: Bool { report != nil }

    func store(_ report: MeetingSessionStopReport) {
        self.report = report
    }
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

private actor AudioLaneStartRecorder {
    private(set) var lanes: [AudioLane] = []

    func record(_ lane: AudioLane) {
        lanes.append(lane)
    }
}

private actor FakeSessionAudioCapture: AudioCapturing {
    nonisolated let lane: AudioLane
    let startError: AudioCaptureError?
    let startBarrier: AudioOperationBarrier?
    let stopBarrier: AudioOperationBarrier?
    let startRecorder: AudioLaneStartRecorder?
    private var continuation: AsyncStream<AudioCaptureEvent>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var stopFailuresRemaining: Int

    init(
        lane: AudioLane,
        startError: AudioCaptureError? = nil,
        startBarrier: AudioOperationBarrier? = nil,
        stopBarrier: AudioOperationBarrier? = nil,
        stopFailureCount: Int = 0,
        startRecorder: AudioLaneStartRecorder? = nil
    ) {
        precondition(stopFailureCount >= 0)
        self.lane = lane
        self.startError = startError
        self.startBarrier = startBarrier
        self.stopBarrier = stopBarrier
        self.startRecorder = startRecorder
        self.stopFailuresRemaining = stopFailureCount
    }

    func events() -> AsyncStream<AudioCaptureEvent> {
        continuation?.finish()
        let pair = AsyncStream.makeStream(of: AudioCaptureEvent.self)
        continuation = pair.continuation
        return pair.stream
    }

    func start() async throws {
        startCount += 1
        await startRecorder?.record(lane)
        if let startBarrier { await startBarrier.suspendIfArmed() }
        if let startError { throw startError }
    }

    func stop() async throws {
        stopCount += 1
        if let stopBarrier { await stopBarrier.suspendIfArmed() }
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw AudioCaptureError.systemFailure(code: -7_007)
        }
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
    confidence: Double = 0.9,
    hostTimeRange: HostTimeRange? = nil
) -> ProgressiveTranscriptResult {
    ProgressiveTranscriptResult(
        lane: lane,
        text: text,
        hostTimeRange: hostTimeRange,
        stability: stability,
        confidence: confidence
    )
}

private func hostTimeRange(
    start: TimeInterval,
    duration: TimeInterval = 0.5
) -> HostTimeRange {
    let startTimestamp = HostTimestamp(ticks: AVAudioTime.hostTime(forSeconds: start))
    return HostTimeRange(
        start: startTimestamp,
        end: startTimestamp.advanced(by: duration)
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
