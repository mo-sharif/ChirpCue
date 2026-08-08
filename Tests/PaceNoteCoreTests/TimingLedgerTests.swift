import Foundation
import XCTest

@testable import PaceNoteCore

final class TimingLedgerTests: XCTestCase {
    func testEarlyBridgeSpeechMarginAndVerifiedDeepTargetsUseMonotonicDurations() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 41, at: 100)
        ledger.recordBridgeReady(generation: 41, at: 100.5)
        ledger.recordConfirmedLocalSpeech(generation: 41, at: 102)
        ledger.recordVerifiedDeepReady(generation: 41, at: 109)

        let snapshot = ledger.snapshot()
        let sample = snapshot.samples.first
        XCTAssertEqual(snapshot.retainedTurnCount, 1)
        XCTAssertEqual(sample?.sequence, 1)
        XCTAssertEqual(sample?.turnStableToBridgeReadySeconds, 0.5)
        XCTAssertEqual(sample?.confirmedLocalSpeechObserved, true)
        XCTAssertEqual(sample?.bridgeToConfirmedLocalSpeechMarginSeconds, 1.5)
        XCTAssertEqual(sample?.turnStableToVerifiedDeepReadySeconds, 9)
        XCTAssertEqual(sample?.deepOutcome, .ready)
        XCTAssertNil(sample?.invalidationOutcome)
        XCTAssertEqual(snapshot.targets.bridgeReadyDeadlineSeconds, 1.25)
        XCTAssertEqual(snapshot.targets.bridgeReadyDeadlineStatus, .met)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechTargetRate, 0.85)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechStatus, .met)
        XCTAssertEqual(snapshot.targets.verifiedDeepP50TargetSeconds, 10)
        XCTAssertEqual(snapshot.targets.verifiedDeepP95TargetSeconds, 25)
        XCTAssertEqual(snapshot.targets.verifiedDeepObservedP50Seconds, 9)
        XCTAssertEqual(snapshot.targets.verifiedDeepObservedP95Seconds, 9)
        XCTAssertEqual(snapshot.targets.verifiedDeepP50Status, .met)
        XCTAssertEqual(snapshot.targets.verifiedDeepP95Status, .met)
    }

    func testHeldDeepIsNotMeasuredUntilItBecomesControllerReady() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 1, at: 10)
        ledger.recordBridgeReady(generation: 1, at: 10.2)
        ledger.recordConfirmedLocalSpeech(generation: 1, at: 11)

        let held = ledger.snapshot()
        XCTAssertNil(held.samples.first?.turnStableToVerifiedDeepReadySeconds)
        XCTAssertEqual(held.samples.first?.deepOutcome, .pending)
        XCTAssertEqual(held.targets.verifiedDeepP50Status, .notEvaluated)
        XCTAssertEqual(held.targets.verifiedDeepP95Status, .notEvaluated)

        ledger.recordVerifiedDeepReady(generation: 1, at: 13)

        let displayed = ledger.snapshot()
        XCTAssertEqual(displayed.samples.first?.turnStableToVerifiedDeepReadySeconds, 3)
        XCTAssertEqual(displayed.samples.first?.deepOutcome, .ready)
    }

    func testConfirmedSpeechWithoutAVisibleBridgeCountsAsAMissedTarget() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 1, at: 10)
        ledger.recordConfirmedLocalSpeech(generation: 1, at: 10.4)
        ledger.invalidate(generation: 1, outcome: .localSpeech, at: 10.4)

        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot.targets.bridgeReadyMissingSampleCount, 1)
        XCTAssertEqual(snapshot.targets.bridgeReadyDeadlineStatus, .missed)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechSampleCount, 1)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechObservedRate, 0)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechStatus, .missed)
    }

    func testLateAttributionPreservesSpeechThatStartedBeforeTheBridge() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 1, at: 10)
        ledger.recordBridgeReady(generation: 1, at: 10.5)
        ledger.recordConfirmedLocalSpeech(generation: 1, at: 10.4)

        let snapshot = ledger.snapshot()
        XCTAssertEqual(
            snapshot.samples.first?.bridgeToConfirmedLocalSpeechMarginSeconds ?? 0,
            -0.1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechObservedRate, 0)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechStatus, .missed)
    }

    func testConfirmedSpeechWithoutVerifiedHostTimingStillCountsAsAMissedTarget() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 1, at: 10)
        ledger.recordBridgeReady(generation: 1, at: 10.2)
        ledger.recordConfirmedLocalSpeech(generation: 1, at: nil)

        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot.samples.first?.confirmedLocalSpeechObserved, true)
        XCTAssertNil(snapshot.samples.first?.bridgeToConfirmedLocalSpeechMarginSeconds)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechSampleCount, 1)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechObservedRate, 0)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechStatus, .missed)
    }

    func testStaleAndInvalidationOutcomesRemainContentFree() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 7, at: 20)
        ledger.recordBridgeReady(generation: 7, at: 20.1)
        ledger.invalidate(generation: 7, outcome: .newerTurn, at: 21)
        ledger.recordStaleDiscard(generation: 7, at: 21.1)
        ledger.recordUserDismissed(generation: 7, at: 21.2)

        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot.staleDiscardedCount, 1)
        XCTAssertEqual(snapshot.invalidatedTurnCount, 1)
        XCTAssertEqual(snapshot.userDismissedCount, 1)
        XCTAssertEqual(snapshot.samples.first?.deepOutcome, .staleDiscarded)
        XCTAssertEqual(snapshot.samples.first?.invalidationOutcome, .newerTurn)
        XCTAssertEqual(snapshot.samples.first?.userDismissed, true)
        assertHasNoContentBearingValues(snapshot)
    }

    func testLedgerBoundsEntriesAndClampsNegativeDurations() {
        var ledger = TimingLedger(capacity: 2)
        ledger.beginTurn(generation: 1, at: 10)
        ledger.recordBridgeReady(generation: 1, at: 11)
        ledger.beginTurn(generation: 2, at: 9)
        ledger.recordBridgeReady(generation: 2, at: 8)
        ledger.beginTurn(generation: 3, at: 12)
        ledger.recordBridgeReady(generation: 3, at: 13.3)

        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot.samples.map(\.sequence), [2, 3])
        XCTAssertEqual(snapshot.droppedTurnCount, 1)
        XCTAssertEqual(snapshot.samples[0].turnStableToBridgeReadySeconds, 0)
        XCTAssertEqual(
            snapshot.samples[1].turnStableToBridgeReadySeconds ?? 0,
            1.3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.targets.bridgeReadyDeadlineStatus, .notEvaluated)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechStatus, .notEvaluated)
        XCTAssertEqual(snapshot.targets.verifiedDeepP50Status, .notEvaluated)
        XCTAssertEqual(snapshot.targets.verifiedDeepP95Status, .notEvaluated)
    }

    func testClearScrubsSamplesAndDoesNotClaimTargetsPassedWithoutData() {
        var ledger = TimingLedger(capacity: 8)
        ledger.beginTurn(generation: 1, at: 1)
        ledger.recordBridgeReady(generation: 1, at: 1.2)
        ledger.clear()

        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot, .empty)
        XCTAssertNil(snapshot.targets.bridgeReadyWorstSeconds)
        XCTAssertNil(snapshot.targets.verifiedDeepObservedP50Seconds)
        XCTAssertNil(snapshot.targets.verifiedDeepObservedP95Seconds)
        XCTAssertEqual(snapshot.targets.bridgeReadyDeadlineStatus, .notEvaluated)
        XCTAssertEqual(snapshot.targets.bridgeBeforeLocalSpeechStatus, .notEvaluated)
        XCTAssertEqual(snapshot.targets.verifiedDeepP50Status, .notEvaluated)
        XCTAssertEqual(snapshot.targets.verifiedDeepP95Status, .notEvaluated)
    }

    private func assertHasNoContentBearingValues(
        _ value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(value is String, file: file, line: line)
        XCTAssertFalse(value is UUID, file: file, line: line)
        XCTAssertFalse(value is Data, file: file, line: line)
        for child in Mirror(reflecting: value).children {
            assertHasNoContentBearingValues(child.value, file: file, line: line)
        }
    }
}
