import Foundation
import PaceNoteCore
import XCTest

@testable import PaceNoteApp

@MainActor
final class MeetingViewModelTests: XCTestCase {
    func testOnlyRootRepositorySkillsWithValidFrontmatterAreOffered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillDirectory =
            root
            .appendingPathComponent(".agents/skills/incident-response", isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = ".agents/skills/incident-response/SKILL.md"
        try Data(
            "---\nname: incident-response\ndescription: Safe incident context.\n---\nRead only.\n".utf8
        ).write(to: root.appendingPathComponent(relativePath))
        let manifest = GroundingManifest(
            entries: [
                GroundingManifestEntry(
                    relativePath: relativePath,
                    byteCount: 1,
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
        let inspection = GroundingInspection(
            branch: "main",
            head: String(repeating: "b", count: 40),
            worktreeFingerprint: "worktree",
            manifest: manifest,
            groundingFingerprint: "grounding",
            hardExclusions: [],
            softFindings: [],
            acceptedApprovals: [],
            instructionSources: []
        )
        let snapshot = GroundingSnapshot(
            id: UUID(),
            repoAlias: "fixture",
            sourceRoot: root,
            snapshotRoot: root,
            createdAt: Date(),
            inspection: inspection
        )

        XCTAssertEqual(
            try PaceNoteRuntime.domainSkills(in: snapshot),
            [DomainSkillOption(name: "incident-response")]
        )
    }

    func testRuntimeEventsReplacePartialTranscriptAndClearMeetingState() async throws {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events),
            hasCompletedFirstRun: true
        )
        await model.bootstrap()

        let segmentID = UUID()
        let partial = TranscriptSegment(
            id: segmentID,
            source: .them,
            text: "How does the service",
            startedAt: 1,
            endedAt: 2,
            isFinal: false
        )
        let final = TranscriptSegment(
            id: segmentID,
            source: .them,
            text: "How does the service isolate repository access?",
            startedAt: 1,
            endedAt: 3,
            isFinal: true
        )

        await events.emit(.stateChanged(Self.sessionState(phase: .listening)))
        await events.emit(.transcriptUpserted(partial))
        await events.emit(.transcriptUpserted(final))
        try await Self.eventually { model.transcript == [final] }
        XCTAssertTrue(model.isCaptureActive)

        await events.emit(.transcriptsCleared)
        try await Self.eventually { model.transcript.isEmpty }
    }

    func testManualOnlyMeetingIsAllowedWhenSubscriptionAndConsentAreReady() async {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events),
            hasCompletedFirstRun: true,
            microphoneEnabled: false,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        XCTAssertTrue(model.setupBlockers.isEmpty)
        XCTAssertTrue(model.canStart)
    }

    func testStartRequestCarriesCompletedPerMeetingConsent() async throws {
        let events = EventHarness()
        let recorder = StartRequestRecorder()
        var actions = Self.actions(events: events)
        actions.startMeeting = { request in
            await recorder.record(request)
        }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: false,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        await model.startMeeting()

        let recordedRequest = await recorder.request()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertTrue(request.consentConfirmed)
    }

    func testCurrentTurnCoachingRequiresSystemOutputButManualQuestionDoesNot() async {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events),
            hasCompletedFirstRun: true,
            microphoneEnabled: false,
            outputEnabled: false
        )
        await model.bootstrap()
        model.phase = .listening

        XCTAssertTrue(model.canCoach)
        XCTAssertFalse(model.canCoachCurrentTurn)

        model.outputEnabled = true
        XCTAssertTrue(model.canCoachCurrentTurn)
    }

    func testCaptureIndicatorStaysActiveAcrossResponsePhasesAndTracksPauseResumeStop() async {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events),
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        await model.startMeeting()
        XCTAssertTrue(model.isCaptureActive)

        model.receiveQuickSuggestion(
            SuggestionCard(
                identity: TurnIdentity(meetingID: UUID(), generation: 1),
                stage: .quick,
                text: "I can give you the short version first."
            )
        )
        XCTAssertEqual(model.phase, .suggesting)
        XCTAssertTrue(model.isCaptureActive)

        await model.pause()
        XCTAssertFalse(model.isCaptureActive)
        await model.resume()
        XCTAssertTrue(model.isCaptureActive)
        await model.stop()
        XCTAssertFalse(model.isCaptureActive)
    }

    func testClarificationDeepCardWithoutEvidenceRemainsVisible() {
        let model = MeetingViewModel(hasCompletedFirstRun: true)
        model.phase = .listening
        let identity = TurnIdentity(meetingID: UUID(), generation: 1)
        model.receiveQuickSuggestion(
            SuggestionCard(identity: identity, stage: .bridge, text: "Let me verify that.")
        )
        let clarification = SuggestionCard(
            identity: identity,
            stage: .deep,
            text: "Which deployment environment do you mean?",
            evidence: []
        )

        model.receiveVerifiedDeepSuggestion(clarification)

        XCTAssertEqual(model.deepSuggestion, clarification)
    }

    func testForgetProfileErasesFileBackedCredentialsBeforeLogout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-forget-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("Profiles/personal", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("credential-canary".utf8).write(
            to: profile.appendingPathComponent("auth.json")
        )

        try await CodexProfileForgetter(
            applicationRoot: root,
            profileRoot: profile
        ).forget {
            let entries = try FileManager.default.contentsOfDirectory(
                at: profile,
                includingPropertiesForKeys: nil
            )
            guard entries.isEmpty else { throw ForgetProfileTestError.profileWasNotEmpty }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: profile,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testForgetProfileErasesUnknownStateAndRecreatesProfileAfterLogoutFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-forget-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("Profiles/personal", isDirectory: true)
        let unknown = profile.appendingPathComponent("sessions/private.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: unknown.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("meeting-canary".utf8).write(to: unknown)

        do {
            try await CodexProfileForgetter(
                applicationRoot: root,
                profileRoot: profile
            ).forget {
                throw ForgetProfileTestError.logoutFailed
            }
            XCTFail("Expected logout verification failure.")
        } catch let error as CodexProfileForgetError {
            XCTAssertEqual(error, .credentialStoreLogoutFailed)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: profile,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testForgetProfileRejectsSymlinkedAncestorWithoutTouchingExternalTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-forget-\(UUID().uuidString)", isDirectory: true)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-external-\(UUID().uuidString)", isDirectory: true)
        let externalProfile = external.appendingPathComponent("personal", isDirectory: true)
        let marker = externalProfile.appendingPathComponent("keep.txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalProfile, withIntermediateDirectories: true)
        try Data("do-not-delete".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Profiles", isDirectory: true),
            withDestinationURL: external
        )

        do {
            try await CodexProfileForgetter(
                applicationRoot: root,
                profileRoot: root.appendingPathComponent("Profiles/personal", isDirectory: true)
            ).forget {}
            XCTFail("Expected ancestor symlink rejection.")
        } catch let error as CodexProfileForgetError {
            XCTAssertEqual(error, .invalidProfileRoot)
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("do-not-delete".utf8))
    }

    func testForgetProfileReplacementFailurePreservesExistingProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-forget-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("Profiles/personal", isDirectory: true)
        let marker = profile.appendingPathComponent("keep.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("still-signed-in".utf8).write(to: marker)

        do {
            try await CodexProfileForgetter(
                applicationRoot: root,
                profileRoot: profile,
                fileManager: FailingRemovalFileManager()
            ).forget {}
            XCTFail("Expected profile replacement failure.")
        } catch let error as CodexProfileForgetError {
            XCTAssertEqual(error, .profileReplacementFailed)
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("still-signed-in".utf8))
    }

    private static func actions(events: EventHarness) -> MeetingActions {
        MeetingActions(
            sessionEvents: { await events.stream() },
            checkEnvironment: {
                PaceNoteEnvironmentSnapshot(
                    microphonePermission: .authorized,
                    systemAudioPermission: .authorized,
                    codex: .ready(
                        CodexAccountSummary(
                            accountLabel: "m•••@example.com",
                            planLabel: "ChatGPT Pro",
                            modelCount: 2
                        )
                    ),
                    outputSources: []
                )
            },
            requestCapturePermission: { _ in .authorized },
            beginCodexSignIn: { .signedOut },
            forgetCodexProfile: {},
            reloadOutputSources: { [] },
            inspectRepository: { _ in throw PaceNoteActionError.serviceNotConnected },
            sealRepository: { _ in throw PaceNoteActionError.serviceNotConnected },
            discardRepositorySnapshot: { _ in },
            startMeeting: { _ in },
            pauseMeeting: {},
            resumeMeeting: {},
            stopMeeting: {},
            coachCurrentTurn: { _ in }
        )
    }

    private static func sessionState(phase: MeetingPhase) -> MeetingSessionState {
        MeetingSessionState(
            phase: phase,
            captureMode: .microphoneAndSystemOutput,
            consentConfirmed: true,
            isPrepared: true,
            isRunning: true,
            runtime: nil,
            transcript: [],
            suggestions: [],
            brownouts: []
        )
    }

    private static func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }
}

private actor EventHarness {
    private let pair = AsyncStream.makeStream(
        of: MeetingSessionEvent.self,
        bufferingPolicy: .unbounded
    )

    func stream() -> AsyncStream<MeetingSessionEvent> { pair.stream }

    func emit(_ event: MeetingSessionEvent) {
        pair.continuation.yield(event)
    }
}

private actor StartRequestRecorder {
    private var value: MeetingStartRequest?

    func record(_ request: MeetingStartRequest) {
        value = request
    }

    func request() -> MeetingStartRequest? { value }
}

private enum ForgetProfileTestError: Error {
    case profileWasNotEmpty
    case logoutFailed
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
