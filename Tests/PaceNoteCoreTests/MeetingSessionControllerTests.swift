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

    func testFinalOutputQuestionAutomaticallyStartsQuickAndDeepWithoutMicrophone() async throws {
        let harness = makeHarness(mode: .systemOutputOnly)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(transcript(.output, "How should we isolate database access?", stability: .final))
        )

        let automaticAnswerArrived = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .quick }
                && state.suggestions.contains { $0.stage == .deep }
        }
        let quickTurns = await harness.response.requestedTurns
        let deepTurns = await harness.response.deepRequestedTurns

        XCTAssertTrue(automaticAnswerArrived)
        XCTAssertEqual(quickTurns.map(\.question), ["How should we isolate database access?"])
        XCTAssertEqual(deepTurns.map(\.question), ["How should we isolate database access?"])
        _ = await harness.controller.stop()
    }

    func testSpeakerBriefIsBoundIntoEveryAutomaticResponseTurn() async throws {
        let brief = "Eight years with React; lately building TypeScript AI products."
        let harness = makeHarness(mode: .systemOutputOnly, speakerBrief: brief)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "My first question for you is, what, how many years have you had with React JS, and what kind of applications have you been working on lately?",
                    stability: .final
                )
            )
        )

        let responseStarted = await eventually {
            let quickCount = await harness.response.requestedTurns.count
            let deepCount = await harness.response.deepRequestedTurns.count
            return quickCount == 1 && deepCount == 1
        }
        let quickTurn = await harness.response.requestedTurns.first
        let deepTurn = await harness.response.deepRequestedTurns.first

        XCTAssertTrue(responseStarted)
        XCTAssertEqual(quickTurn?.speakerBrief, brief)
        XCTAssertEqual(deepTurn?.speakerBrief, brief)
        _ = await harness.controller.stop()
    }

    func testQuickFailuresUseAccurateTransientBrownouts() async throws {
        let cases: [(MeetingResponseError, BrownoutReason)] = [
            (.quickRateLimited, .quickLimited),
            (.providerCapacityUnavailable, .providerLimited),
            (.runtimeUnavailable, .quickUnavailable),
            (.invalidOutput, .quickRejected),
        ]

        for (failure, expectedBrownout) in cases {
            let response = FakeMeetingResponseGenerator(
                slowDeepGenerations: [1],
                quickFailuresRemaining: 1,
                quickFailure: failure
            )
            let harness = makeHarness(mode: .systemOutputOnly, response: response)
            try await prepareAndStart(harness)

            await harness.outputTranscriber.emit(
                .result(
                    transcript(
                        .output,
                        "How should we isolate database access?",
                        stability: .final
                    )
                )
            )

            let failureVisible = await eventually {
                let state = await harness.controller.state()
                return state.suggestions.contains { $0.stage == .bridge }
                    && state.brownouts.contains { $0.reason == expectedBrownout }
            }
            XCTAssertTrue(failureVisible, "Expected \(expectedBrownout) for \(failure)")
            _ = await harness.controller.stop()
        }
    }

    func testQuickTimeoutUsesAccurateTransientBrownout() async throws {
        let response = FakeMeetingResponseGenerator(
            slowQuickGenerations: [1],
            slowDeepGenerations: [1]
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final
                )
            )
        )

        let timeoutVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .bridge }
                && state.brownouts.contains { $0.reason == .quickTimedOut }
        }
        XCTAssertTrue(timeoutVisible)
        _ = await harness.controller.stop()
    }

    func testAutomaticQuestionAfterQuickFailureKeepsFirstThreadAndRecovers() async throws {
        let response = FakeMeetingResponseGenerator(
            slowDeepGenerations: [1],
            quickFailuresRemaining: 1,
            quickFailure: .quickRateLimited
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)
        let firstQuestion = "How should we isolate database access?"

        await harness.outputTranscriber.emit(
            .result(transcript(.output, firstQuestion, stability: .final))
        )
        let firstFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .bridge }
                && state.brownouts.contains { $0.reason == .quickLimited }
        }
        XCTAssertTrue(firstFailureVisible)
        let failedState = await harness.controller.state()
        let failedCard = try XCTUnwrap(failedState.suggestions.first)

        let secondQuestion = "What should we monitor after deployment?"
        await harness.outputTranscriber.emit(
            .result(transcript(.output, secondQuestion, stability: .final))
        )

        let recovered = await eventually {
            let state = await harness.controller.state()
            let recoveredCards = state.suggestions.filter {
                $0.identity != failedCard.identity
            }
            return state.suggestions.contains { $0.identity == failedCard.identity }
                && recoveredCards.contains { $0.stage == .quick }
                && recoveredCards.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason == .quickLimited }
        }
        let quickTurns = await response.requestedTurns
        let deepTurns = await response.deepRequestedTurns
        XCTAssertTrue(recovered)
        XCTAssertEqual(quickTurns.map(\.question), [firstQuestion, secondQuestion])
        XCTAssertEqual(deepTurns.map(\.question), [firstQuestion, secondQuestion])
        _ = await harness.controller.stop()
    }

    func testProviderCapacityWarningPersistsUntilALaterGenerationModelSucceeds() async throws {
        let response = FakeMeetingResponseGenerator(
            slowQuickGenerations: [2],
            slowDeepGenerations: [2],
            quickFailuresRemaining: 1,
            quickFailure: .providerCapacityUnavailable,
            deepFailuresRemaining: 1,
            deepFailure: .providerCapacityUnavailable
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final
                )
            )
        )
        let firstFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .bridge }
                && state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(firstFailureVisible)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "What should we monitor after deployment?",
                    stability: .final
                )
            )
        )
        let secondBridgeKeptWarning = await eventually {
            let state = await harness.controller.state()
            let quickTurns = await response.requestedTurns
            return quickTurns.count == 2
                && state.suggestions.contains { $0.stage == .bridge }
                && state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(secondBridgeKeptWarning)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How would you roll this out safely?",
                    stability: .final
                )
            )
        )
        let recovered = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .quick }
                && state.suggestions.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(recovered)
        _ = await harness.controller.stop()
    }

    func testSameGenerationDeepSuccessDoesNotHideNewerProviderCapacityFailure() async throws {
        let deepBarrier = AudioOperationBarrier()
        let response = FakeMeetingResponseGenerator(
            deepBarrier: deepBarrier,
            quickFailuresRemaining: 1,
            quickFailure: .providerCapacityUnavailable
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)
        await deepBarrier.arm()

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final
                )
            )
        )
        await deepBarrier.waitUntilEntered()
        let quickFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .bridge }
                && state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(quickFailureVisible)

        await deepBarrier.release()
        let sameGenerationDeepVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .deep }
                && state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(sameGenerationDeepVisible)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "What should we monitor after deployment?",
                    stability: .final
                )
            )
        )
        let laterGenerationRecovered = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .quick }
                && state.suggestions.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(laterGenerationRecovered)
        _ = await harness.controller.stop()
    }

    func testAutomaticQuestionAfterDeepFailureKeepsFirstThreadAndRecovers() async throws {
        let response = FakeMeetingResponseGenerator(
            deepFailuresRemaining: 1,
            deepFailure: .deepRateLimited
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)
        let firstQuestion = "How should we isolate database access?"

        await harness.outputTranscriber.emit(
            .result(transcript(.output, firstQuestion, stability: .final))
        )
        let firstFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .quick }
                && state.suggestions.allSatisfy { $0.stage != .deep }
                && state.brownouts.contains { $0.reason == .deepLimited }
        }
        XCTAssertTrue(firstFailureVisible)
        let failedState = await harness.controller.state()
        let failedCard = try XCTUnwrap(failedState.suggestions.first)

        let secondQuestion = "What should we monitor after deployment?"
        await harness.outputTranscriber.emit(
            .result(transcript(.output, secondQuestion, stability: .final))
        )

        let recovered = await eventually {
            let state = await harness.controller.state()
            let recoveredCards = state.suggestions.filter {
                $0.identity != failedCard.identity
            }
            return state.suggestions.contains { $0.identity == failedCard.identity }
                && recoveredCards.contains { $0.stage == .bridge || $0.stage == .quick }
                && recoveredCards.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason.isDeepResponseFailure }
        }
        let quickTurns = await response.requestedTurns
        let deepTurns = await response.deepRequestedTurns
        XCTAssertTrue(recovered)
        XCTAssertEqual(quickTurns.map(\.question), [firstQuestion, secondQuestion])
        XCTAssertEqual(deepTurns.map(\.question), [firstQuestion, secondQuestion])
        _ = await harness.controller.stop()
    }

    func testSuccessfulNextQuestionClearsRecoveredCleanupBrownout() async throws {
        let response = FakeMeetingResponseGenerator(
            slowDeepGenerations: [1],
            quickCleanupFailuresRemaining: 1
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final
                )
            )
        )
        let cleanupFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.brownouts.contains { $0.reason == .codexOffline }
        }
        XCTAssertTrue(cleanupFailureVisible)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "What should we monitor after deployment?",
                    stability: .final
                )
            )
        )
        let recovered = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .quick }
                && !state.brownouts.contains { $0.reason == .codexOffline }
        }
        XCTAssertTrue(recovered)
        _ = await harness.controller.stop()
    }

    func testSameTurnDeepSuccessDoesNotHideCleanupBrownout() async throws {
        let deepBarrier = AudioOperationBarrier()
        await deepBarrier.arm()
        let response = FakeMeetingResponseGenerator(
            deepBarrier: deepBarrier,
            quickCleanupFailuresRemaining: 1
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final
                )
            )
        )
        await deepBarrier.waitUntilEntered()
        let cleanupFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.brownouts.contains { $0.reason == .codexOffline }
        }
        XCTAssertTrue(cleanupFailureVisible)

        await deepBarrier.release()
        let deepArrived = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .deep }
        }
        let state = await harness.controller.state()
        XCTAssertTrue(deepArrived)
        XCTAssertTrue(state.brownouts.contains { $0.reason == .codexOffline })
        _ = await harness.controller.stop()
    }

    func testBridgeAloneDoesNotHideCleanupBrownout() async throws {
        let response = FakeMeetingResponseGenerator(
            slowQuickGenerations: [2],
            slowDeepGenerations: [1, 2],
            quickCleanupFailuresRemaining: 1
        )
        let harness = makeHarness(mode: .systemOutputOnly, response: response)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final
                )
            )
        )
        let cleanupFailureVisible = await eventually {
            let state = await harness.controller.state()
            return state.brownouts.contains { $0.reason == .codexOffline }
        }
        XCTAssertTrue(cleanupFailureVisible)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "What should we monitor after deployment?",
                    stability: .final
                )
            )
        )
        let bridgeVisible = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.stage == .bridge }
        }
        let state = await harness.controller.state()
        XCTAssertTrue(bridgeVisible)
        XCTAssertTrue(state.brownouts.contains { $0.reason == .codexOffline })
        _ = await harness.controller.stop()
    }

    func testFinalRevisionOfAutomaticQuestionDoesNotStartDuplicateResponse() async throws {
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(mode: .systemOutputOnly, time: clock)
        try await prepareAndStart(harness)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access",
                    stability: .volatile,
                    hostTimeRange: hostTimeRange(start: 8)
                )
            )
        )
        let firstResponseStarted = await eventually {
            await harness.response.requestedTurns.count == 1
        }
        XCTAssertTrue(firstResponseStarted)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How should we isolate database access?",
                    stability: .final,
                    hostTimeRange: hostTimeRange(start: 8, duration: 2)
                )
            )
        )
        let finalRevisionVisible = await eventually {
            let state = await harness.controller.state()
            return state.transcript.count == 1
                && state.transcript.first?.isFinal == true
                && state.transcript.first?.text == "How should we isolate database access?"
        }
        try await Task.sleep(for: .milliseconds(30))
        let requestedTurns = await harness.response.requestedTurns

        XCTAssertTrue(finalRevisionVisible)
        XCTAssertEqual(requestedTurns.count, 1)
        _ = await harness.controller.stop()
    }

    func testExpandedFinalRevisionStartsFollowUpWithoutReplacingOriginalAnswer() async throws {
        let clock = LockedMeetingTime(10)
        let harness = makeHarness(mode: .systemOutputOnly, time: clock)
        try await prepareAndStart(harness)
        let partialQuestion = "How should we secure database access"
        let finalQuestion = "How should we secure database access through our MCP?"

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    partialQuestion,
                    stability: .volatile,
                    hostTimeRange: hostTimeRange(start: 8)
                )
            )
        )
        let firstResponseStarted = await eventually {
            await harness.response.requestedTurns.map(\.question) == [partialQuestion]
        }
        XCTAssertTrue(firstResponseStarted)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    finalQuestion,
                    stability: .final,
                    hostTimeRange: hostTimeRange(start: 8, duration: 2)
                )
            )
        )

        let correctedResponseStarted = await eventually {
            await harness.response.requestedTurns.map(\.question)
                == [partialQuestion, finalQuestion]
        }
        let state = await harness.controller.state()
        let cancelCount = await harness.response.cancelCount
        XCTAssertTrue(correctedResponseStarted)
        XCTAssertEqual(state.transcript.count, 1)
        XCTAssertEqual(state.transcript.first?.text, finalQuestion)
        XCTAssertEqual(state.transcript.first?.isFinal, true)
        XCTAssertTrue(state.suggestions.contains { $0.identity.generation == 1 })
        XCTAssertTrue(state.suggestions.contains { $0.identity.generation == 2 })
        XCTAssertEqual(cancelCount, 0)
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
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
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
                await harness.controller.state().suggestions.contains { $0.stage == .quick }
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

    func testProviderCapacityLimitDoesNotPreventMeetingCapture() async throws {
        let response = FakeMeetingResponseGenerator(prepareFailure: .providerCapacityUnavailable)
        let harness = makeHarness(mode: .manualOnly, response: response)
        let suggestionLifecycle = SuggestionThreadLifecycleProbe()
        let events = await harness.controller.events()
        let eventTask = Task {
            for await event in events {
                await suggestionLifecycle.record(event)
            }
        }
        defer { eventTask.cancel() }

        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()

        let limitVisible = await eventually {
            let state = await harness.controller.state()
            return state.isRunning
                && state.brownouts.contains { $0.reason == .providerLimited }
        }
        XCTAssertTrue(limitVisible)
        try await harness.controller.submitTypedQuestion("What should I say while we wait?")
        let state = await harness.controller.state()
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(state.suggestions.contains { $0.stage == .bridge })
        XCTAssertTrue(state.brownouts.contains { $0.reason == .providerLimited })
        let failureWasScopedToTheThread = await eventually {
            await suggestionLifecycle.hasCompletedProviderFailure(generation: 1)
        }
        XCTAssertTrue(failureWasScopedToTheThread)
        _ = await harness.controller.stop()
    }

    func testStopInvalidatesAndAwaitsSuspendedResponsePreparation() async throws {
        let preparationBarrier = AudioOperationBarrier()
        let response = FakeMeetingResponseGenerator(prepareBarrier: preparationBarrier)
        let harness = makeHarness(mode: .manualOnly, response: response)
        await preparationBarrier.arm()

        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
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
        let stopReport = await stop.value
        let state = await harness.controller.state()
        let shutdownCount = await response.shutdownCount

        XCTAssertTrue(stopReport.cleanupSucceeded)
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(state.phase, .ended)
        XCTAssertFalse(state.isPrepared)
    }

    func testCaptureAndTranscriptStartWhileResponseRuntimeIsStillPreparing() async throws {
        let preparationBarrier = AudioOperationBarrier()
        await preparationBarrier.arm()
        let response = FakeMeetingResponseGenerator(prepareBarrier: preparationBarrier)
        let harness = makeHarness(mode: .systemOutputOnly, response: response)

        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
        await preparationBarrier.waitUntilEntered()

        let startingState = await harness.controller.state()
        let outputStarts = await harness.outputCapture.startCount
        XCTAssertTrue(startingState.isRunning)
        XCTAssertNil(startingState.runtime)
        XCTAssertEqual(outputStarts, 1)
        XCTAssertTrue(startingState.brownouts.contains { $0.reason == .providerPreparing })

        await harness.outputTranscriber.emit(
            .result(transcript(.output, "How do we secure the database?", stability: .final))
        )
        let transcriptAndBridgeVisible = await eventually {
            let state = await harness.controller.state()
            return state.transcript.contains { $0.text == "How do we secure the database?" }
                && state.suggestions.contains { $0.stage == .bridge }
        }
        XCTAssertTrue(transcriptAndBridgeVisible)

        await preparationBarrier.release()
        let recovered = await eventually {
            let state = await harness.controller.state()
            return state.runtime != nil
                && state.suggestions.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason == .providerPreparing }
        }
        XCTAssertTrue(recovered)
        _ = await harness.controller.stop()
    }

    func testSpeakerBriefAnswerAppearsWhileResponseRuntimeIsStillPreparing() async throws {
        let answer =
            "I have eight years of experience with React. Lately, I have been building TypeScript AI products and reusable frontend platforms."
        let preparationBarrier = AudioOperationBarrier()
        await preparationBarrier.arm()
        let response = FakeMeetingResponseGenerator(
            prepareBarrier: preparationBarrier,
            quickText: answer
        )
        let harness = makeHarness(
            mode: .systemOutputOnly,
            response: response,
            speakerBrief: answer
        )

        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
        await preparationBarrier.waitUntilEntered()

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "How many years have you used React, and what have you built lately?",
                    stability: .final
                )
            )
        )
        let immediateAnswerVisible = await eventually {
            let state = await harness.controller.state()
            return state.runtime == nil
                && state.suggestions.contains { $0.stage == .quick && $0.text == answer }
                && !state.suggestions.contains { $0.stage == .bridge }
        }
        let quickRequestsBeforeRuntime = await response.requestedTurns.count

        XCTAssertTrue(immediateAnswerVisible)
        XCTAssertEqual(quickRequestsBeforeRuntime, 0)

        await preparationBarrier.release()
        let recovered = await eventually {
            let state = await harness.controller.state()
            let matchingQuick = state.suggestions.filter {
                $0.stage == .quick && $0.text == answer
            }
            return state.runtime != nil
                && matchingQuick.count == 1
                && state.suggestions.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason == .providerPreparing }
        }

        XCTAssertTrue(recovered)
        _ = await harness.controller.stop()
    }

    func testQuestionsDetectedDuringProviderWarmupResumeAsIndependentThreads() async throws {
        let preparationBarrier = AudioOperationBarrier()
        await preparationBarrier.arm()
        let response = FakeMeetingResponseGenerator(prepareBarrier: preparationBarrier)
        let harness = makeHarness(mode: .systemOutputOnly, response: response)

        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
        await preparationBarrier.waitUntilEntered()

        await harness.outputTranscriber.emit(
            .result(transcript(.output, "How do we secure the database?", stability: .final))
        )
        await harness.outputTranscriber.emit(
            .result(transcript(.output, "And how does MCP change that plan?", stability: .final))
        )
        let bothBridgesVisible = await eventually {
            let bridges = await harness.controller.state().suggestions.filter { $0.stage == .bridge }
            return Set(bridges.map { $0.identity.generation }) == [1, 2]
        }
        XCTAssertTrue(bothBridgesVisible)

        await preparationBarrier.release()
        let bothDeepAnswersVisible = await eventually {
            let deep = await harness.controller.state().suggestions.filter { $0.stage == .deep }
            return Set(deep.map { $0.identity.generation }) == [1, 2]
        }
        let requestedQuestions = await response.deepRequestedTurns.map(\.question)

        XCTAssertTrue(bothDeepAnswersVisible)
        XCTAssertEqual(
            Set(requestedQuestions),
            ["How do we secure the database?", "And how does MCP change that plan?"]
        )
        _ = await harness.controller.stop()
    }

    func testRuntimePreparationRetriesAndRecoversWithoutRestartingMeeting() async throws {
        let response = FakeMeetingResponseGenerator(
            prepareFailure: .runtimeUnavailable,
            prepareFailuresRemaining: 1
        )
        let harness = makeHarness(mode: .manualOnly, response: response)

        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
        try await harness.controller.submitTypedQuestion("Explain the retry boundary")

        let recovered = await eventually {
            let state = await harness.controller.state()
            let prepareCount = await response.prepareCount
            return prepareCount >= 2
                && state.isRunning
                && state.runtime != nil
                && state.suggestions.contains { $0.stage == .deep }
                && !state.brownouts.contains { $0.reason == .providerPreparing }
        }
        XCTAssertTrue(recovered)
        _ = await harness.controller.stop()
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

    func testNewTypedCueKeepsEarlierAnswerAndRunsFollowUpInParallel() async throws {
        let clock = LockedMeetingTime(10)
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .manualOnly, response: response, time: clock)
        try await prepareAndStart(harness)

        try await harness.controller.submitTypedQuestion("Why is the first path slow?")
        let firstCueArrived = await eventually {
            let state = await harness.controller.state()
            return state.suggestions.contains { $0.identity.generation == 1 && $0.stage == .quick }
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
        XCTAssertTrue(state.suggestions.contains { $0.identity.generation == 1 })
        XCTAssertTrue(state.suggestions.contains { $0.identity.generation == 2 })
        XCTAssertEqual(cancelCount, 0)
        let timing = await harness.controller.timingSnapshot()
        XCTAssertEqual(timing.samples.count, 2)
        XCTAssertEqual(timing.samples[0].turnStableToBridgeReadySeconds, 0)
        XCTAssertNil(timing.samples[0].invalidationOutcome)
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
            await harness.controller.state().suggestions.contains { $0.stage != .deep }
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

    func testDismissCancelsOnlySelectedDeepAndClearsItsSuggestionCards() async throws {
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
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(cueArrived)
        await deepBarrier.waitUntilEntered()

        let beforeDismiss = await harness.controller.state()
        let identity = try XCTUnwrap(beforeDismiss.suggestions.first?.identity)
        let transcriptBeforeDismiss = beforeDismiss.transcript
        let cancelCountBeforeDismiss = await response.cancelCount
        let dismissCompletion = AsyncCompletionProbe()
        let dismissTask = Task {
            await harness.controller.dismissSuggestion(identity: identity)
            await dismissCompletion.markCompleted()
        }
        let clearedWhileCancellationDrains = await eventually {
            await harness.controller.state().suggestions.isEmpty
        }
        let cancelCountWhileCancellationDrains = await response.cancelCount
        let dismissFinishedEarly = await dismissCompletion.isCompleted()
        XCTAssertTrue(clearedWhileCancellationDrains)
        XCTAssertFalse(dismissFinishedEarly)
        XCTAssertEqual(cancelCountWhileCancellationDrains, cancelCountBeforeDismiss)

        await deepBarrier.release()
        await dismissTask.value

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
        XCTAssertEqual(cancelCountAfterDismiss, cancelCountBeforeDismiss)
        XCTAssertEqual(timing.userDismissedCount, 1)
        XCTAssertEqual(timing.samples.first?.invalidationOutcome, .userDismissed)

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

    func testDismissingOneThreadDoesNotCancelOrDelayParallelFollowUp() async throws {
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is the first path isolated?")
        let cueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(cueArrived)
        let firstState = await harness.controller.state()
        let firstIdentity = try XCTUnwrap(firstState.suggestions.first?.identity)

        try await harness.controller.submitTypedQuestion("Why is the second path bounded?")
        let newerDeepArrived = await eventually {
            await harness.controller.state().suggestions.contains {
                $0.identity.generation == 2 && $0.stage == .deep
            }
        }
        XCTAssertTrue(newerDeepArrived)
        let cancelCountBeforeDismiss = await response.cancelCount

        await harness.controller.dismissSuggestion(identity: firstIdentity)

        let stateAfterDismiss = await harness.controller.state()
        let requestedGenerations = await response.deepRequestedTurns.map(\.identity.generation)
        XCTAssertFalse(stateAfterDismiss.suggestions.contains { $0.identity == firstIdentity })
        XCTAssertTrue(
            stateAfterDismiss.suggestions.contains {
                $0.identity.generation == 2 && $0.stage == .deep
            }
        )
        XCTAssertEqual(Set(requestedGenerations), [1, 2])
        let cancelCountAfterDismiss = await response.cancelCount
        XCTAssertEqual(cancelCountAfterDismiss, cancelCountBeforeDismiss)
        _ = await harness.controller.stop()
    }

    func testPauseJoinsAnInFlightIdentityScopedDismissal() async throws {
        let responseEventBarrier = AudioOperationBarrier()
        await responseEventBarrier.arm()
        let response = FakeMeetingResponseGenerator()
        let harness = makeHarness(mode: .manualOnly, response: response)
        await harness.controller.setResponseEventTestHook { event in
            if case .deep = event {
                await responseEventBarrier.suspendIfArmed()
            }
        }
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is this queue bounded?")
        let cueArrived = await eventually {
            let state = await harness.controller.state()
            return !state.suggestions.isEmpty
        }
        XCTAssertTrue(cueArrived)
        let stateWithCue = await harness.controller.state()
        let identity = try XCTUnwrap(stateWithCue.suggestions.first?.identity)
        let transcriptBeforeDismiss = stateWithCue.transcript
        await responseEventBarrier.waitUntilEntered()

        let dismissTask = Task {
            await harness.controller.dismissSuggestion(identity: identity)
        }
        let suggestionCleared = await eventually {
            await harness.controller.state().suggestions.isEmpty
        }
        XCTAssertTrue(suggestionCleared)
        let pauseCompletion = AsyncCompletionProbe()
        let pauseTask = Task {
            try await harness.controller.pause()
            await pauseCompletion.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(20))
        let pauseFinishedBeforeDismissalDrain = await pauseCompletion.isCompleted()
        XCTAssertFalse(pauseFinishedBeforeDismissalDrain)

        await responseEventBarrier.release()

        await dismissTask.value
        try await pauseTask.value
        let pausedState = await harness.controller.state()
        XCTAssertEqual(pausedState.phase, .paused)
        XCTAssertFalse(pausedState.isRunning)
        XCTAssertEqual(pausedState.transcript, transcriptBeforeDismiss)
        XCTAssertTrue(pausedState.suggestions.isEmpty)
        _ = await harness.controller.stop()
    }

    func testStopJoinsAnInFlightIdentityScopedDismissal() async throws {
        let responseEventBarrier = AudioOperationBarrier()
        await responseEventBarrier.arm()
        let response = FakeMeetingResponseGenerator()
        let harness = makeHarness(mode: .manualOnly, response: response)
        await harness.controller.setResponseEventTestHook { event in
            if case .deep = event {
                await responseEventBarrier.suspendIfArmed()
            }
        }
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is this queue bounded?")
        let cueArrived = await eventually {
            let state = await harness.controller.state()
            return !state.suggestions.isEmpty
        }
        XCTAssertTrue(cueArrived)
        await responseEventBarrier.waitUntilEntered()
        let stateWithCue = await harness.controller.state()
        let identity = try XCTUnwrap(stateWithCue.suggestions.first?.identity)

        let stopCompletion = AsyncCompletionProbe()
        let dismissTask = Task {
            await harness.controller.dismissSuggestion(identity: identity)
        }
        let suggestionCleared = await eventually {
            await harness.controller.state().suggestions.isEmpty
        }
        XCTAssertTrue(suggestionCleared)
        let stopTask = Task {
            let report = await harness.controller.stop()
            await stopCompletion.markCompleted()
            return report
        }
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

    func testDismissingEarlierIdentityClearsOnlyThatThread() async throws {
        let response = FakeMeetingResponseGenerator(slowDeepGenerations: [1])
        let harness = makeHarness(mode: .manualOnly, response: response)
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("Why is the first path slow?")
        let firstCueArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(firstCueArrived)
        let firstState = await harness.controller.state()
        let earlierIdentity = try XCTUnwrap(firstState.suggestions.first?.identity)

        try await harness.controller.submitTypedQuestion("Why is the second path isolated?")
        let newerDeepArrived = await eventually {
            await harness.controller.state().suggestions.contains {
                $0.identity.generation == 2 && $0.stage == .deep
            }
        }
        XCTAssertTrue(newerDeepArrived)
        let beforeEarlierDismiss = await harness.controller.state()
        let cancelCount = await response.cancelCount

        await harness.controller.dismissSuggestion(identity: earlierIdentity)

        let stateAfterEarlierDismiss = await harness.controller.state()
        let cancelCountAfterEarlierDismiss = await response.cancelCount
        let timingAfterEarlierDismiss = await harness.controller.timingSnapshot()
        let newerSuggestionsBeforeDismiss = beforeEarlierDismiss.suggestions.filter {
            $0.identity != earlierIdentity
        }
        XCTAssertEqual(stateAfterEarlierDismiss.suggestions, newerSuggestionsBeforeDismiss)
        XCTAssertEqual(cancelCountAfterEarlierDismiss, cancelCount)
        XCTAssertEqual(timingAfterEarlierDismiss.userDismissedCount, 1)
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
            return state.suggestions.contains { $0.stage == .quick }
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
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
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
            "I would separate the boundary before changing it.",
            "I would separate boundary before changing it.",
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
                await harness.controller.state().suggestions.contains { $0.stage == .quick }
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
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(cueArrived)
        await deepBarrier.waitUntilEntered()
        let cancelCountBeforeSpeech = await response.cancelCount

        clock.set(12)
        let volatileBridge = "I would separate the boundary"
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
        XCTAssertTrue(stateWhileSpeaking.suggestions.contains { $0.stage == .quick })
        XCTAssertFalse(stateWhileSpeaking.suggestions.contains { $0.stage == .deep })
        XCTAssertEqual(heldTiming.samples.first?.bridgeToConfirmedLocalSpeechMarginSeconds, 2)
        XCTAssertNil(heldTiming.samples.first?.turnStableToVerifiedDeepReadySeconds)
        XCTAssertEqual(heldTiming.samples.first?.deepOutcome, .pending)

        let finalBridge = "I would separate the boundary before changing it."
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

    func testPartialFinalQuickSpeechKeepsDeepGenerationRunning() async throws {
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
        try await harness.controller.submitTypedQuestion("How should we isolate the queue?")

        let quickArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(quickArrived)
        await deepBarrier.waitUntilEntered()
        let cancelCountBeforeSpeech = await response.cancelCount

        clock.set(12)
        let partialQuick = "I would separate the boundary"
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    partialQuick,
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let partialBecameFinal = await eventually {
            await harness.controller.state().transcript.contains {
                $0.source == .you && $0.text == partialQuick && $0.isFinal
            }
        }
        XCTAssertTrue(partialBecameFinal)
        let cancelCountAfterSpeech = await response.cancelCount
        XCTAssertEqual(cancelCountAfterSpeech, cancelCountBeforeSpeech)

        await deepBarrier.release()
        let deepArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .deep }
        }
        XCTAssertTrue(deepArrived)
        let cancelCountAfterDeep = await response.cancelCount
        XCTAssertEqual(cancelCountAfterDeep, cancelCountBeforeSpeech)
        _ = await harness.controller.stop()
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
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
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
                    "I would separate the boundary",
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
                hasQueuedQuick: false,
                hasQueuedDeep: false
            )
        )
        let stateAfterDismiss = await harness.controller.state()
        XCTAssertTrue(stateAfterDismiss.suggestions.isEmpty)

        let finalBridge =
            "I'd start by clarifying the goal and constraints, then walk through the tradeoffs before committing to an approach."
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

    func testClearlyAttributedUserSpeechHoldsDeepUntilFinalTranscript() async throws {
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
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(cueArrived)
        let stateWithCue = await harness.controller.state()
        let cue = try XCTUnwrap(stateWithCue.suggestions.first { $0.stage == .quick })
        await deepBarrier.waitUntilEntered()
        let cancelCountBeforeSpeech = await response.cancelCount

        clock.set(12)
        let substantiveResponse =
            "I would separate the boundary before changing it because the queue is isolated"
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
        let holdAfterVolatile = await harness.controller.bridgeSpeechRetentionSnapshot()
        XCTAssertTrue(volatileSpeechVisible)
        XCTAssertEqual(cancelCountAfterVolatile, cancelCountBeforeSpeech)
        XCTAssertEqual(stateAfterVolatile.suggestions, [cue])
        XCTAssertTrue(holdAfterVolatile.hasActiveHold)

        await deepBarrier.release()
        let deepQueued = await eventually {
            await harness.controller.bridgeSpeechRetentionSnapshot().hasQueuedDeep
        }
        let stateWithQueuedDeep = await harness.controller.state()
        XCTAssertTrue(deepQueued)
        XCTAssertFalse(stateWithQueuedDeep.suggestions.contains { $0.stage == .deep })

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

        let finalSpeechReleasedDeep = await eventually {
            let state = await harness.controller.state()
            let cancelCount = await response.cancelCount
            return state.transcript.contains {
                $0.source == .you && $0.text == substantiveResponse && $0.isFinal
            }
                && state.suggestions.contains { $0.stage == .deep }
                && cancelCount == cancelCountBeforeSpeech
        }
        let finalRetention = await harness.controller.bridgeSpeechRetentionSnapshot()
        XCTAssertTrue(finalSpeechReleasedDeep)
        XCTAssertFalse(finalRetention.hasActiveHold)
        XCTAssertFalse(finalRetention.hasQueuedDeep)
        _ = await harness.controller.stop()
    }

    func testQuickAndDeepUpgradesWaitUntilFinalLocalSpeechBeforeReplacingCue() async throws {
        let clock = LockedMeetingTime(10)
        let quickBarrier = AudioOperationBarrier()
        let deepBarrier = AudioOperationBarrier()
        await quickBarrier.arm()
        await deepBarrier.arm()
        let response = FakeMeetingResponseGenerator(
            quickBarrier: quickBarrier,
            deepBarrier: deepBarrier
        )
        let harness = makeHarness(
            mode: .microphoneAndSystemOutput,
            response: response,
            time: clock,
            microphoneAttributionDelay: .milliseconds(5),
            soleNearbySpeakerConfirmed: true,
            responseQuickDeadline: .seconds(1)
        )
        try await prepareAndStart(harness)
        try await harness.controller.submitTypedQuestion("How does the browser event loop work?")

        let bridgeArrived = await eventually {
            await harness.controller.state().suggestions.contains {
                $0.stage == .bridge && $0.text.contains("runs synchronous JavaScript first")
            }
        }
        XCTAssertTrue(bridgeArrived)
        let stateWithBridge = await harness.controller.state()
        let originalCue = try XCTUnwrap(stateWithBridge.suggestions.first { $0.stage == .bridge })
        await quickBarrier.waitUntilEntered()
        await deepBarrier.waitUntilEntered()

        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    originalCue.text,
                    stability: .volatile,
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let holdActivated = await eventually {
            await harness.controller.bridgeSpeechRetentionSnapshot().hasActiveHold
        }
        XCTAssertTrue(holdActivated)

        await quickBarrier.release()
        let quickQueued = await eventually {
            await harness.controller.bridgeSpeechRetentionSnapshot().hasQueuedQuick
        }
        let stateWhileSpeaking = await harness.controller.state()

        XCTAssertTrue(quickQueued)
        XCTAssertTrue(stateWhileSpeaking.suggestions.contains(originalCue))
        XCTAssertFalse(stateWhileSpeaking.suggestions.contains { $0.stage == .quick })

        await deepBarrier.release()
        let bothUpgradesQueued = await eventually {
            let retention = await harness.controller.bridgeSpeechRetentionSnapshot()
            return retention.hasQueuedQuick && retention.hasQueuedDeep
        }
        XCTAssertTrue(bothUpgradesQueued)

        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    originalCue.text,
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let upgradesReleased = await eventually {
            let state = await harness.controller.state()
            let retention = await harness.controller.bridgeSpeechRetentionSnapshot()
            return state.suggestions.contains { $0.stage == .quick }
                && state.suggestions.contains { $0.stage == .deep }
                && !retention.hasActiveHold
                && !retention.hasQueuedQuick
                && !retention.hasQueuedDeep
        }

        XCTAssertTrue(upgradesReleased)
        _ = await harness.controller.stop()
    }

    func testHeldDeepReleasesWhenFinalMicrophoneAttributionChanges() async throws {
        let localSpeech = "I would separate the boundary before changing it"
        let cases: [(overlappingOutput: String, suppressesEcho: Bool)] = [
            (localSpeech, true),
            ("The remote speaker is still finishing a different thought", false),
        ]

        for testCase in cases {
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
                        "The remote speaker finished the previous thought",
                        confidence: 0.94,
                        hostTimeRange: hostTimeRange(start: 10)
                    )
                )
            )
            let initialOutputVisible = await eventually {
                await harness.controller.state().transcript.contains {
                    $0.source == .them && $0.text == "The remote speaker finished the previous thought"
                }
            }
            XCTAssertTrue(initialOutputVisible)

            try await harness.controller.submitTypedQuestion("How should we isolate the queue?")
            let quickArrived = await eventually {
                await harness.controller.state().suggestions.contains { $0.stage == .quick }
            }
            XCTAssertTrue(quickArrived)
            await deepBarrier.waitUntilEntered()

            clock.set(12)
            await harness.microphoneTranscriber.emit(
                .result(
                    transcript(
                        .microphone,
                        localSpeech,
                        stability: .volatile,
                        confidence: 0.94,
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

            await harness.outputTranscriber.emit(
                .result(
                    transcript(
                        .output,
                        testCase.overlappingOutput,
                        confidence: 0.95,
                        hostTimeRange: hostTimeRange(start: 12)
                    )
                )
            )
            let overlappingOutputVisible = await eventually {
                await harness.controller.state().transcript.contains {
                    $0.source == .them && $0.text == testCase.overlappingOutput
                }
            }
            XCTAssertTrue(overlappingOutputVisible)

            await harness.microphoneTranscriber.emit(
                .result(
                    transcript(
                        .microphone,
                        localSpeech,
                        confidence: 0.94,
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
            let finalState = await harness.controller.state()
            XCTAssertTrue(deepReleased)
            if testCase.suppressesEcho {
                XCTAssertFalse(finalState.transcript.contains { $0.source == .you })
            } else {
                XCTAssertTrue(
                    finalState.transcript.contains {
                        $0.source == .unknown && $0.text == localSpeech
                    }
                )
            }
            _ = await harness.controller.stop()
        }
    }

    func testHeldDeepReleasesAfterVolatileEchoSuppressionThenDifferentFinalAttribution()
        async throws
    {
        let localSpeech = "I would separate the boundary before changing it"
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
                    "The remote speaker finished the previous thought",
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 10)
                )
            )
        )
        let initialOutputVisible = await eventually {
            await harness.controller.state().transcript.contains {
                $0.source == .them && $0.text == "The remote speaker finished the previous thought"
            }
        }
        XCTAssertTrue(initialOutputVisible)

        try await harness.controller.submitTypedQuestion("How should we isolate the queue?")
        let quickArrived = await eventually {
            await harness.controller.state().suggestions.contains { $0.stage == .quick }
        }
        XCTAssertTrue(quickArrived)
        await deepBarrier.waitUntilEntered()

        clock.set(12)
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    localSpeech,
                    stability: .volatile,
                    confidence: 0.94,
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

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    localSpeech,
                    confidence: 0.95,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    localSpeech,
                    stability: .volatile,
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )

        let volatileEchoSuppressed = await eventually {
            let state = await harness.controller.state()
            let retention = await harness.controller.bridgeSpeechRetentionSnapshot()
            return !state.transcript.contains {
                $0.source == .you && $0.text == localSpeech
            }
                && retention.hasActiveHold
                && retention.hasQueuedDeep
                && !state.suggestions.contains { $0.stage == .deep }
        }
        XCTAssertTrue(volatileEchoSuppressed)

        await harness.outputTranscriber.emit(
            .result(
                transcript(
                    .output,
                    "The remote speaker is finishing a different thought",
                    confidence: 0.95,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )
        let changedOutputVisible = await eventually {
            await harness.controller.state().transcript.contains {
                $0.source == .them
                    && $0.text == "The remote speaker is finishing a different thought"
            }
        }
        XCTAssertTrue(changedOutputVisible)

        await harness.microphoneTranscriber.emit(
            .result(
                transcript(
                    .microphone,
                    localSpeech,
                    confidence: 0.94,
                    hostTimeRange: hostTimeRange(start: 12)
                )
            )
        )

        let deepReleased = await eventually {
            let state = await harness.controller.state()
            let retention = await harness.controller.bridgeSpeechRetentionSnapshot()
            return state.transcript.contains {
                $0.source == .unknown && $0.text == localSpeech && $0.isFinal
            }
                && state.suggestions.contains { $0.stage == .deep }
                && !retention.hasActiveHold
                && !retention.hasQueuedDeep
        }
        XCTAssertTrue(deepReleased)
        _ = await harness.controller.stop()
    }

    private func prepareAndStart(_ harness: SessionHarness) async throws {
        _ = try await harness.controller.preflight(
            consent: MeetingConsent(participantDisclosureConfirmed: true)
        )
        try await harness.controller.start()
        let runtimeReady = await eventually {
            await harness.controller.state().runtime != nil
        }
        XCTAssertTrue(runtimeReady, "Expected the fake response runtime to prepare")
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
        speakerBrief: String? = nil,
        responseQuickDeadline: Duration = .milliseconds(50),
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
                speakerBrief: speakerBrief,
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
                quickDeadline: responseQuickDeadline,
                resultTTL: .seconds(1)
            ),
            resourceCleaner: cleaner,
            time: time,
            cleanupNeedleCapacity: cleanupNeedleCapacity,
            responsePreparationRetryDelay: .milliseconds(5)
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
    let slowQuickGenerations: Set<UInt64>
    let slowDeepGenerations: Set<UInt64>
    let deepKind: DeepDraftKind
    let quickText: String
    let prepareBarrier: AudioOperationBarrier?
    let quickBarrier: AudioOperationBarrier?
    let deepBarrier: AudioOperationBarrier?
    let cancelBarrier: AudioOperationBarrier?
    let prepareFailure: MeetingResponseError?
    private var prepareFailuresRemaining: Int?
    private var quickFailuresRemaining: Int
    private let quickFailure: MeetingResponseError
    private var deepFailuresRemaining: Int
    private let deepFailure: MeetingResponseError
    private var quickCleanupFailuresRemaining: Int
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var shutdownCount = 0
    private(set) var requestedTurns: [ConversationTurn] = []
    private(set) var deepRequestedTurns: [ConversationTurn] = []

    init(
        slowQuickGenerations: Set<UInt64> = [],
        slowDeepGenerations: Set<UInt64> = [],
        shutdownReport: MeetingResponseCleanupReport = .init(),
        deepKind: DeepDraftKind = .generalAnswer,
        prepareBarrier: AudioOperationBarrier? = nil,
        quickText: String = "I would separate the boundary before changing it.",
        quickBarrier: AudioOperationBarrier? = nil,
        deepBarrier: AudioOperationBarrier? = nil,
        cancelBarrier: AudioOperationBarrier? = nil,
        prepareFailure: MeetingResponseError? = nil,
        prepareFailuresRemaining: Int? = nil,
        quickFailuresRemaining: Int = 0,
        quickFailure: MeetingResponseError = .runtimeUnavailable,
        quickCleanupFailuresRemaining: Int = 0,
        deepFailuresRemaining: Int = 0,
        deepFailure: MeetingResponseError = .runtimeUnavailable
    ) {
        self.slowQuickGenerations = slowQuickGenerations
        self.slowDeepGenerations = slowDeepGenerations
        self.shutdownReport = shutdownReport
        self.deepKind = deepKind
        self.prepareBarrier = prepareBarrier
        self.quickText = quickText
        self.quickBarrier = quickBarrier
        self.deepBarrier = deepBarrier
        self.cancelBarrier = cancelBarrier
        self.prepareFailure = prepareFailure
        self.prepareFailuresRemaining = prepareFailuresRemaining.map { max(0, $0) }
        self.quickFailuresRemaining = max(0, quickFailuresRemaining)
        self.quickFailure = quickFailure
        self.quickCleanupFailuresRemaining = max(0, quickCleanupFailuresRemaining)
        self.deepFailuresRemaining = max(0, deepFailuresRemaining)
        self.deepFailure = deepFailure
    }

    func prepare() async throws -> MeetingResponseRuntime {
        prepareCount += 1
        if let prepareBarrier { await prepareBarrier.suspendIfArmed() }
        if let prepareFailure {
            if let remaining = prepareFailuresRemaining {
                if remaining > 0 {
                    prepareFailuresRemaining = remaining - 1
                    throw prepareFailure
                }
            } else {
                throw prepareFailure
            }
        }
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
        if quickFailuresRemaining > 0 {
            quickFailuresRemaining -= 1
            throw quickFailure
        }
        if let quickBarrier { await quickBarrier.suspendIfArmed() }
        if slowQuickGenerations.contains(turn.identity.generation) {
            try await Task.sleep(for: .seconds(30))
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
        return QuickModelOutput(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            sayNow: quickText,
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

    func awaitQuickCleanup(for _: TurnIdentity) async throws {
        guard quickCleanupFailuresRemaining > 0 else { return }
        quickCleanupFailuresRemaining -= 1
        throw MeetingResponseError.cleanupFailed
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

private actor SuggestionThreadLifecycleProbe {
    private var quickFailures: [UInt64: BrownoutReason] = [:]
    private var deepFailures: [UInt64: BrownoutReason] = [:]
    private var completedGenerations: Set<UInt64> = []

    func record(_ event: MeetingSessionEvent) {
        switch event {
        case .suggestionStageFailed(let identity, let stage, let reason):
            switch stage {
            case .bridge, .quick:
                quickFailures[identity.generation] = reason
            case .deep:
                deepFailures[identity.generation] = reason
            }
        case .suggestionThreadCompleted(let identity):
            completedGenerations.insert(identity.generation)
        default:
            break
        }
    }

    func hasCompletedProviderFailure(generation: UInt64) -> Bool {
        quickFailures[generation] == .providerLimited
            && deepFailures[generation] == .providerLimited
            && completedGenerations.contains(generation)
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
    timeout: Duration = .seconds(2),
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
