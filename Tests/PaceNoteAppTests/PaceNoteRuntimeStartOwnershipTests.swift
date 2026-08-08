import Foundation
import PaceNoteCore
import XCTest

@testable import PaceNoteApp

final class PaceNoteRuntimeStartOwnershipTests: XCTestCase {
    func testConcurrentStartIsRejectedWhileFirstAttemptOwnsReservation() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let barrier = RuntimeStartSuspensionBarrier()
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account"),
            startSuspensionBarrier: { await barrier.suspendIgnoringCancellation() }
        )
        let request = staleOutputSourceRequest()

        let firstStart = Task { try await runtime.startMeeting(request) }
        await barrier.waitUntilSuspended()

        let blockedEnvironment = await runtime.checkEnvironment()
        XCTAssertEqual(
            blockedEnvironment.codex,
            .limited(
                "Stop or finish the current meeting before rechecking provider accounts."
            )
        )
        let blockedSignIn = await runtime.beginCodexSignIn()
        XCTAssertEqual(
            blockedSignIn,
            .unavailable(
                "Stop or finish the current meeting before changing the Codex account."
            )
        )
        do {
            try await runtime.forgetCodexProfile()
            XCTFail("Forget must not overlap a reserved meeting start.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "Stop or finish the current meeting before forgetting the Codex profile."
            )
        }
        do {
            _ = try await runtime.confirmClaudeAccountChange()
            XCTFail("Claude account rebind must not overlap a reserved meeting start.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "Stop or finish the current meeting before confirming a different Claude account."
            )
        }

        do {
            try await runtime.startMeeting(request)
            XCTFail("A second start must not enter while the first attempt owns the runtime.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(error.errorDescription, "A meeting start is already in progress.")
        }

        await barrier.release()
        do {
            try await firstStart.value
            XCTFail("The fixture request should still fail after the ownership check.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "The selected meeting application is no longer available. Reload the app list."
            )
        }

        XCTAssertTrue(try fixture.meetingRoots().isEmpty)
        let journalEntries = try await fixture.journalEntries()
        XCTAssertTrue(journalEntries.isEmpty)
        await runtime.shutdown()
    }

    func testEnvironmentRecheckReservesRuntimeBeforeStartCanEnter() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let barrier = RuntimeStartSuspensionBarrier()
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account"),
            providerOperationSuspensionBarrier: {
                await barrier.suspendIgnoringCancellation()
            }
        )

        let recheck = Task { await runtime.checkEnvironment() }
        await barrier.waitUntilSuspended()

        do {
            try await runtime.startMeeting(staleOutputSourceRequest())
            XCTFail("Start must not overlap an environment recheck.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "Finish the provider account operation before starting a meeting."
            )
        }

        recheck.cancel()
        await barrier.waitUntilCancellationObserved()
        await barrier.release()
        let canceledSnapshot = await recheck.value
        XCTAssertEqual(
            canceledSnapshot.codex,
            .limited("The provider account recheck was canceled.")
        )
        await runtime.shutdown()
    }

    func testCodexSignInReservesRuntimeAndRejectsDuplicateSignIn() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let barrier = RuntimeStartSuspensionBarrier()
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account"),
            providerOperationSuspensionBarrier: {
                await barrier.suspendIgnoringCancellation()
            }
        )

        let firstSignIn = Task { await runtime.beginCodexSignIn() }
        await barrier.waitUntilSuspended()

        let duplicateState = await runtime.beginCodexSignIn()
        XCTAssertEqual(
            duplicateState,
            .unavailable("Another provider account operation is already in progress.")
        )
        do {
            try await runtime.startMeeting(staleOutputSourceRequest())
            XCTFail("Start must not overlap Codex sign-in.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "Finish the provider account operation before starting a meeting."
            )
        }

        firstSignIn.cancel()
        await barrier.waitUntilCancellationObserved()
        await barrier.release()
        let canceledState = await firstSignIn.value
        XCTAssertEqual(canceledState, .signedOut)
        await runtime.shutdown()
    }

    func testShutdownCancelsAndAwaitsOwnedProviderOperation() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let barrier = RuntimeStartSuspensionBarrier()
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account"),
            providerOperationSuspensionBarrier: {
                await barrier.suspendIgnoringCancellation()
            }
        )

        let recheck = Task { await runtime.checkEnvironment() }
        await barrier.waitUntilSuspended()
        let shutdown = Task { await runtime.shutdown() }
        await barrier.waitUntilCancellationObserved()
        let closingState = await runtime.shutdownStateForTesting()
        XCTAssertFalse(closingState.isClosed)

        await barrier.release()
        let shutdownCompleted = await shutdown.value
        _ = await recheck.value
        let closedState = await runtime.shutdownStateForTesting()
        XCTAssertTrue(shutdownCompleted)
        XCTAssertTrue(closedState.isClosed)
    }

    func testRuntimeHoldsExclusiveDedicatedProfileLease() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        var runtime: PaceNoteRuntime? = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account")
        )

        XCTAssertThrowsError(
            try PaceNoteRuntime(
                applicationSupportRoot: fixture.supportRoot,
                preverifiedSubscription: (planType: "pro", identityHash: "fixture-account")
            )
        ) { error in
            XCTAssertEqual(
                (error as? PaceNoteActionError)?.errorDescription,
                "The dedicated ChirpCue Codex profile is already in use. Quit ChirpCue and any live probe before trying again."
            )
        }

        await runtime?.shutdown()
        runtime = nil
    }

    func testFailedStartRetainsOwnershipWhenAudioTeardownIsUnresolved() {
        let report = MeetingSessionStopReport(
            deletedThreadCount: 0,
            deletedSnapshotCount: 0,
            deletedTemporaryRootCount: 0,
            residualFindingCount: 0,
            journalEntryRemoved: false,
            failures: [.audioCaptureTeardown]
        )
        let outputRequest = MeetingStartRequest(
            consentConfirmed: true,
            microphoneEnabled: true,
            outputEnabled: true,
            outputScope: .allSystemAudio,
            outputSourceID: nil,
            sealedSnapshotID: nil,
            selectedDomainSkillName: nil
        )

        XCTAssertEqual(
            PaceNoteRuntime.failedStartTeardownLane(
                report: report,
                originalError: MeetingSessionFailure.captureTeardownFailed(.microphone),
                request: outputRequest
            ),
            .microphone
        )
        XCTAssertEqual(
            PaceNoteRuntime.failedStartTeardownLane(
                report: report,
                originalError: MeetingSessionFailure.responseUnavailable,
                request: outputRequest
            ),
            .output
        )

        let microphoneReport = MeetingSessionStopReport(
            deletedThreadCount: 0,
            deletedSnapshotCount: 0,
            deletedTemporaryRootCount: 0,
            residualFindingCount: 0,
            journalEntryRemoved: false,
            failures: [.audioCaptureTeardown],
            audioTeardownFailureLane: .microphone
        )
        XCTAssertEqual(
            PaceNoteRuntime.failedStartTeardownLane(
                report: microphoneReport,
                originalError: MeetingSessionFailure.responseUnavailable,
                request: outputRequest
            ),
            .microphone
        )

        let cleanReport = MeetingSessionStopReport(
            deletedThreadCount: 0,
            deletedSnapshotCount: 0,
            deletedTemporaryRootCount: 0,
            residualFindingCount: 0,
            journalEntryRemoved: true,
            failures: []
        )
        XCTAssertNil(
            PaceNoteRuntime.failedStartTeardownLane(
                report: cleanReport,
                originalError: MeetingSessionFailure.captureTeardownFailed(.output),
                request: outputRequest
            )
        )
    }

    func testRuntimeRejectsMeetingWithNoCaptureLaneBeforeAllocatingMeetingState() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account")
        )

        do {
            try await runtime.startMeeting(
                MeetingStartRequest(
                    consentConfirmed: true,
                    microphoneEnabled: false,
                    outputEnabled: false,
                    outputScope: .allSystemAudio,
                    outputSourceID: nil,
                    sealedSnapshotID: nil,
                    selectedDomainSkillName: nil
                )
            )
            XCTFail("Expected capture-free meeting start to be rejected.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "Enable the microphone or meeting output before starting a meeting."
            )
        }

        XCTAssertTrue(try fixture.meetingRoots().isEmpty)
        let journalEntries = try await fixture.journalEntries()
        XCTAssertTrue(journalEntries.isEmpty)
        await runtime.shutdown()
    }

    func testStaleOutputSourceCleansUnstartedContextAcrossSameProcessRetries() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account")
        )

        for _ in 0..<2 {
            let message = await staleSourceFailureMessage(from: runtime)
            XCTAssertEqual(
                message,
                "The selected meeting application is no longer available. Reload the app list."
            )
            let journalEntries = try await fixture.journalEntries()
            XCTAssertTrue(try fixture.meetingRoots().isEmpty)
            XCTAssertTrue(journalEntries.isEmpty)
        }

        await runtime.shutdown()
    }

    func testFailedUnstartedCleanupBlocksRetryAndShutdownRetriesOwnedContext() async throws {
        let fixture = try RuntimeOwnershipFixture()
        defer { fixture.remove() }
        let removalCounter = LockedCounter()
        let fileManager = FailingMeetingRootRemovalFileManager(
            meetingsRoot: fixture.meetingsRoot,
            removalCounter: removalCounter
        )
        let runtime = try PaceNoteRuntime(
            fileManager: fileManager,
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account")
        )

        let firstMessage = await staleSourceFailureMessage(from: runtime)
        XCTAssertEqual(
            firstMessage,
            "The private repository snapshot cleanup could not be verified. It remains blocked for recovery."
        )
        let entriesAfterFailure = try await fixture.journalEntries()
        XCTAssertEqual(removalCounter.value, 1)
        XCTAssertEqual(try fixture.meetingRoots().count, 1)
        XCTAssertEqual(entriesAfterFailure.count, 1)

        let blockedMessage = await staleSourceFailureMessage(from: runtime)
        XCTAssertEqual(
            blockedMessage,
            "Private meeting cleanup is incomplete. Quit and reopen ChirpCue before starting another meeting."
        )
        let entriesWhileBlocked = try await fixture.journalEntries()
        XCTAssertEqual(removalCounter.value, 1)
        XCTAssertEqual(try fixture.meetingRoots().count, 1)
        XCTAssertEqual(entriesWhileBlocked.count, 1)

        await runtime.shutdown()

        let entriesAfterShutdown = try await fixture.journalEntries()
        XCTAssertEqual(removalCounter.value, 2)
        XCTAssertEqual(try fixture.meetingRoots().count, 1)
        XCTAssertEqual(entriesAfterShutdown.count, 1)
    }

    private func staleSourceFailureMessage(from runtime: PaceNoteRuntime) async -> String {
        do {
            try await runtime.startMeeting(
                MeetingStartRequest(
                    consentConfirmed: true,
                    microphoneEnabled: false,
                    outputEnabled: true,
                    outputScope: .meetingApplication,
                    outputSourceID: "pid:missing",
                    sealedSnapshotID: nil,
                    selectedDomainSkillName: nil
                )
            )
            XCTFail("Expected the stale output source to reject meeting start.")
            return ""
        } catch let error as PaceNoteActionError {
            return error.errorDescription ?? ""
        } catch {
            XCTFail("Unexpected error: \(error)")
            return ""
        }
    }
}

private func staleOutputSourceRequest() -> MeetingStartRequest {
    MeetingStartRequest(
        consentConfirmed: true,
        microphoneEnabled: false,
        outputEnabled: true,
        outputScope: .meetingApplication,
        outputSourceID: "pid:missing",
        sealedSnapshotID: nil,
        selectedDomainSkillName: nil
    )
}

actor RuntimeStartSuspensionBarrier {
    private var suspended = false
    private var cancellationObserved = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendIgnoringCancellation() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func recordCancellation() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class RuntimeOwnershipFixture {
    let root: URL
    let supportRoot: URL
    let applicationRoot: URL
    let meetingsRoot: URL
    private let journalURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-start-ownership-\(UUID().uuidString)",
            isDirectory: true
        )
        supportRoot = root.appendingPathComponent("Application Support", isDirectory: true)
        applicationRoot = supportRoot.appendingPathComponent("PaceNote", isDirectory: true)
        meetingsRoot = applicationRoot.appendingPathComponent("Meetings", isDirectory: true)
        journalURL =
            applicationRoot
            .appendingPathComponent("State", isDirectory: true)
            .appendingPathComponent("cleanup-journal.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: supportRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func meetingRoots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: meetingsRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: nil
        )
    }

    func journalEntries() async throws -> [CleanupJournalEntry] {
        let journal = try CleanupJournalStore(
            journalURL: journalURL,
            allowedRoot: applicationRoot
        )
        return try await journal.entries()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FailingMeetingRootRemovalFileManager: FileManager, @unchecked Sendable {
    private let meetingsRootPath: String
    private let removalCounter: LockedCounter

    init(meetingsRoot: URL, removalCounter: LockedCounter) {
        meetingsRootPath = meetingsRoot.standardizedFileURL.path + "/"
        self.removalCounter = removalCounter
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL.path.hasPrefix(meetingsRootPath) {
            removalCounter.increment()
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
