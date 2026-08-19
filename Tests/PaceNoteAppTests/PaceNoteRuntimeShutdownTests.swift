import AppKit
import Foundation
import PaceNoteCore
import XCTest

@testable import PaceNoteApp

final class PaceNoteRuntimeShutdownTests: XCTestCase {
    func testShutdownRefusesToCloseUntilActiveAudioTeardownSucceeds() async throws {
        let fixture = try RuntimeShutdownFixture()
        defer { fixture.remove() }
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account")
        )
        let capture = RetryingShutdownAudioCapture(stopFailureCount: 2)
        let privateRoot = fixture.supportRoot.appendingPathComponent(
            "active-shutdown-meeting",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: privateRoot,
            withIntermediateDirectories: true
        )
        await runtime.installActiveMeetingForShutdownTesting(
            controller: makeShutdownController(capture: capture),
            privateRoot: privateRoot
        )

        let firstShutdownCompleted = await runtime.shutdown()
        let blockedState = await runtime.shutdownStateForTesting()
        let blockedStopCount = await capture.stopCount()

        XCTAssertFalse(firstShutdownCompleted)
        XCTAssertTrue(blockedState.hasActiveMeeting)
        XCTAssertFalse(blockedState.isClosed)
        XCTAssertEqual(blockedStopCount, 2)

        let retryCompleted = await runtime.shutdown()
        let closedState = await runtime.shutdownStateForTesting()
        let completedStopCount = await capture.stopCount()

        XCTAssertTrue(retryCompleted)
        XCTAssertFalse(closedState.hasActiveMeeting)
        XCTAssertTrue(closedState.isClosed)
        XCTAssertEqual(completedStopCount, 3)
    }

    @MainActor
    func testTerminationReplyDeniesFailedShutdownAndAllowsSuccessfulRetry() async {
        let delegate = PaceNoteApplicationDelegate()

        let denied = await terminationReply(from: delegate, shutdownCompleted: false)
        XCTAssertFalse(denied)

        let approved = await terminationReply(from: delegate, shutdownCompleted: true)
        XCTAssertTrue(approved)
    }

    func testShutdownCancelsAndAwaitsCancellationInsensitiveStart() async throws {
        let fixture = try RuntimeShutdownFixture()
        defer { fixture.remove() }
        let barrier = RuntimeStartSuspensionBarrier()
        let completion = RuntimeShutdownCompletionProbe()
        let runtime = try PaceNoteRuntime(
            applicationSupportRoot: fixture.supportRoot,
            preverifiedSubscription: (planType: "pro", identityHash: "fixture-account"),
            startSuspensionBarrier: { await barrier.suspendIgnoringCancellation() }
        )
        let request = MeetingStartRequest(
            consentConfirmed: true,
            microphoneEnabled: false,
            outputEnabled: true,
            outputScope: .meetingApplication,
            outputSourceID: "pid:missing",
            sealedSnapshotID: nil,
            selectedDomainSkillName: nil
        )

        let start = Task { try await runtime.startMeeting(request) }
        await barrier.waitUntilSuspended()
        let shutdown = Task {
            await runtime.shutdown()
            await completion.markCompleted()
        }

        await barrier.waitUntilCancellationObserved()
        let completedWhileStartWasSuspended = await completion.isCompleted()
        XCTAssertFalse(completedWhileStartWasSuspended)

        await barrier.release()
        await shutdown.value
        do {
            try await start.value
            XCTFail("Shutdown must cancel the reserved start attempt.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error).")
        }

        XCTAssertTrue(try fixture.meetingRoots().isEmpty)
        let journalEntries = try await fixture.journalEntries()
        XCTAssertTrue(journalEntries.isEmpty)

        do {
            try await runtime.startMeeting(request)
            XCTFail("A closed runtime must reject a later meeting start.")
        } catch let error as PaceNoteActionError {
            XCTAssertEqual(
                error.errorDescription,
                "ChirpCue is shutting down. Reopen it before starting another meeting."
            )
        }
    }

    func testIdleShutdownSanitizesTranscriptFreePreflightState() throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }

        XCTAssertTrue(
            try PaceNoteRuntime.sanitizeIdleProfileForShutdown(
                profileRoot: fixture.profile,
                fileManager: .default,
                hasActiveMeeting: false,
                hasPendingMeeting: false,
                hasPendingCleanup: false
            )
        )

        XCTAssertEqual(
            try fixture.entryNames(),
            ["config.toml", "installation_id"]
        )
    }

    func testStartupRebuildsIdleProfileWhenNewCodexStateIsNotYetAllowlisted() throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        try Data("future-transient-state".utf8).write(
            to: fixture.profile.appendingPathComponent("future_state.sqlite")
        )

        XCTAssertTrue(
            try PaceNoteRuntime.recoverIdleCodexProfileForStartup(
                applicationRoot: fixture.applicationRoot,
                profileRoot: fixture.profile,
                fileManager: .default
            )
        )
        XCTAssertEqual(try fixture.entryNames(), ["config.toml"])
    }

    func testStartupRecoveryFailsClosedWhenIdleProfileCannotBeRebuilt() throws {
        let fixture = try ProfileFixture()
        defer { fixture.remove() }
        try Data("future-transient-state".utf8).write(
            to: fixture.profile.appendingPathComponent("future_state.sqlite")
        )
        let fileManager = FailingProfileReplacementFileManager(profileRoot: fixture.profile)

        XCTAssertThrowsError(
            try PaceNoteRuntime.recoverIdleCodexProfileForStartup(
                applicationRoot: fixture.applicationRoot,
                profileRoot: fixture.profile,
                fileManager: fileManager
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.profile.appendingPathComponent("future_state.sqlite").path
            )
        )
    }

    func testShutdownPreservesProfileWhileAnyRecoveryOwnerRemains() throws {
        for blocker in RecoveryBlocker.allCases {
            let fixture = try ProfileFixture()
            defer { fixture.remove() }

            XCTAssertFalse(
                try PaceNoteRuntime.sanitizeIdleProfileForShutdown(
                    profileRoot: fixture.profile,
                    fileManager: .default,
                    hasActiveMeeting: blocker == .activeMeeting,
                    hasPendingMeeting: blocker == .pendingMeeting,
                    hasPendingCleanup: blocker == .cleanupJournal
                ),
                "Expected \(blocker) to preserve recovery state."
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.profile.appendingPathComponent("state_5.sqlite").path
                )
            )
        }
    }
}

@MainActor
private func terminationReply(
    from delegate: PaceNoteApplicationDelegate,
    shutdownCompleted: Bool
) async -> Bool {
    await withCheckedContinuation { continuation in
        let initialReply = delegate.beginTermination(
            shutdown: { shutdownCompleted },
            reply: { continuation.resume(returning: $0) },
            onFailure: {}
        )
        XCTAssertEqual(initialReply, .terminateLater)
    }
}

private func makeShutdownController(
    capture: RetryingShutdownAudioCapture
) -> MeetingSessionController {
    MeetingSessionController(
        configuration: MeetingSessionConfiguration(captureMode: .systemOutputOnly),
        audioServices: MeetingAudioServices(
            systemOutput: MeetingAudioLaneServices(
                lane: .output,
                capture: capture,
                transcriber: ShutdownTestTranscriber()
            )
        ),
        responseGenerator: ShutdownTestResponseGenerator(),
        resourceCleaner: ShutdownTestResourceCleaner()
    )
}

private actor RetryingShutdownAudioCapture: AudioCapturing {
    nonisolated let lane = AudioLane.output
    private var remainingStopFailures: Int
    private var recordedStopCount = 0

    init(stopFailureCount: Int) {
        remainingStopFailures = stopFailureCount
    }

    func events() -> AsyncStream<AudioCaptureEvent> {
        AsyncStream { $0.finish() }
    }

    func start() {}

    func stop() throws {
        recordedStopCount += 1
        guard remainingStopFailures > 0 else { return }
        remainingStopFailures -= 1
        throw AudioCaptureError.systemFailure(code: -7_007)
    }

    func stopCount() -> Int {
        recordedStopCount
    }
}

private actor ShutdownTestTranscriber: AudioTranscribing {
    nonisolated let lane = AudioLane.output

    func events() -> AsyncStream<SpeechTranscriptionEvent> {
        AsyncStream { $0.finish() }
    }

    func start(
        audioEvents: AsyncStream<AudioCaptureEvent>,
        localeIdentifier: String
    ) {}

    func stop() {}
}

private actor ShutdownTestResponseGenerator: MeetingResponseGenerating {
    func prepare() -> MeetingResponseRuntime {
        MeetingResponseRuntime(
            planType: "pro",
            quickRoute: CodexModelRoute(model: "quick", effort: "low"),
            deepRoute: CodexModelRoute(model: "deep", effort: "medium"),
            usesRealtimeQuick: true
        )
    }

    func cancelActiveWork() {}

    func shutdown() -> MeetingResponseCleanupReport {
        MeetingResponseCleanupReport()
    }

    func generateQuick(for turn: ConversationTurn) throws -> QuickModelOutput {
        throw MeetingResponseError.runtimeUnavailable
    }

    func generateDeep(for turn: ConversationTurn) throws -> DeepDraft {
        throw MeetingResponseError.runtimeUnavailable
    }

    func reconcile(cue: CueEnvelope, draft: DeepDraft) throws -> Reconciliation {
        throw MeetingResponseError.runtimeUnavailable
    }
}

private actor ShutdownTestResourceCleaner: MeetingSessionResourceCleaning {
    func deleteResources(
        preserveCodexRecoveryState: Bool
    ) -> MeetingResourceCleanupReport {
        MeetingResourceCleanupReport()
    }

    func residualFindingCount(sensitiveNeedles: [Data]) -> Int {
        0
    }

    func deletePrivateRoot() {}

    func removeJournalEntry(meetingID: UUID) {}
}

private actor RuntimeShutdownCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class RuntimeShutdownFixture {
    let root: URL
    let supportRoot: URL
    private let applicationRoot: URL
    private let meetingsRoot: URL
    private let journalURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-runtime-shutdown-\(UUID().uuidString)",
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

private enum RecoveryBlocker: CaseIterable {
    case activeMeeting
    case pendingMeeting
    case cleanupJournal
}

private final class ProfileFixture {
    let root: URL
    let applicationRoot: URL
    let profile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-idle-shutdown-\(UUID().uuidString)",
            isDirectory: true
        )
        applicationRoot = root.appendingPathComponent("PaceNote", isDirectory: true)
        profile = applicationRoot.appendingPathComponent("Profiles/personal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profile,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("fixture-installation".utf8).write(
            to: profile.appendingPathComponent("installation_id")
        )
        try Data("transient-fixture".utf8).write(
            to: profile.appendingPathComponent("state_5.sqlite")
        )
        let temporary = profile.appendingPathComponent(".tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try Data("transient-fixture".utf8).write(
            to: temporary.appendingPathComponent("preflight.log")
        )
    }

    func entryNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FailingProfileReplacementFileManager: FileManager, @unchecked Sendable {
    private let profilePath: String

    init(profileRoot: URL) {
        profilePath = profileRoot.standardizedFileURL.path
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL.path == profilePath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
