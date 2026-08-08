import Foundation
import PaceNoteCore
import XCTest

@testable import PaceNoteApp

@MainActor
final class MeetingViewModelTests: XCTestCase {
    func testUnavailableRuntimeSurfacesItsSafeStartupReason() async {
        let reason = "The dedicated ChirpCue Codex profile is already in use."
        let model = MeetingViewModel(
            actions: .unavailable(reason: reason),
            hasCompletedFirstRun: true
        )

        await model.bootstrap()

        XCTAssertEqual(model.codexState, .unavailable(reason))
        XCTAssertEqual(model.microphonePermission, .unavailable(reason))
        XCTAssertEqual(model.systemAudioPermission, .unavailable(reason))
        XCTAssertFalse(model.canStart)
    }

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

    func testMeetingCannotStartWithBothCaptureLanesDisabled() async {
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

        XCTAssertTrue(
            model.setupBlockers.contains("Enable the microphone or meeting output before starting.")
        )
        XCTAssertFalse(model.canStart)
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
            microphoneEnabled: true,
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
        XCTAssertFalse(request.soleNearbySpeakerConfirmed)
    }

    func testStartRequestCarriesOptionalSoleNearbySpeakerConfirmation() async throws {
        let events = EventHarness()
        let recorder = StartRequestRecorder()
        var actions = Self.actions(events: events)
        actions.startMeeting = { request in
            await recorder.record(request)
        }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        model.meetingConsent.soleNearbySpeakerConfirmed = true

        await model.startMeeting()

        let recordedRequest = await recorder.request()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertTrue(request.soleNearbySpeakerConfirmed)
    }

    func testWithdrawingConsentCancelsPendingStartAndStopsLateSuccess() async throws {
        let events = EventHarness()
        let startBarrier = CancellationInsensitiveStartBarrier()
        var actions = Self.actions(events: events)
        actions.startMeeting = { request in try await startBarrier.start(request) }
        actions.stopMeeting = { await startBarrier.stop() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        let startTask = Task { @MainActor in await model.startMeeting() }
        await startBarrier.waitUntilEntered()
        XCTAssertTrue(model.isCaptureActive)

        model.meetingConsent.participantPermission = false
        await startBarrier.waitUntilCancellationObserved()
        XCTAssertTrue(model.isPerformingMeetingAction)
        XCTAssertTrue(model.isCaptureActive)

        let lateSegment = TranscriptSegment(
            source: .them,
            text: "Late transcript from a revoked Start",
            startedAt: 1,
            endedAt: 2,
            isFinal: true
        )
        await events.emit(.stateChanged(Self.sessionState(phase: .listening)))
        await events.emit(.transcriptUpserted(lateSegment))
        await Task.yield()
        XCTAssertTrue(model.transcript.isEmpty)

        await startBarrier.release()
        await startTask.value

        let stopCount = await startBarrier.stopCount()
        let fakeCaptureActive = await startBarrier.isActive()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(fakeCaptureActive)
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertFalse(model.isPerformingMeetingAction)
        XCTAssertNotEqual(model.phase, .listening)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertEqual(model.meetingConsent, MeetingConsent())
    }

    func testChangingOutputScopeCancelsPendingStartAndStopsStaleRequest() async {
        let events = EventHarness()
        let startBarrier = CancellationInsensitiveStartBarrier()
        let source = OutputSourceOption(id: "process:42:1", name: "Google Chrome")
        var actions = Self.actions(events: events, outputSources: [source])
        actions.startMeeting = { request in try await startBarrier.start(request) }
        actions.stopMeeting = { await startBarrier.stop() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: false,
            outputEnabled: true,
            outputScope: .meetingApplication
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        let startTask = Task { @MainActor in await model.startMeeting() }
        await startBarrier.waitUntilEntered()

        model.outputScope = .allSystemAudio
        await startBarrier.waitUntilCancellationObserved()
        await startBarrier.release()
        await startTask.value

        let stopCount = await startBarrier.stopCount()
        let fakeCaptureActive = await startBarrier.isActive()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(fakeCaptureActive)
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertFalse(model.isPerformingMeetingAction)
        XCTAssertNotEqual(model.phase, .listening)
        XCTAssertEqual(model.meetingConsent, MeetingConsent())
    }

    func testCancelMeetingSetupDismissesAndRejectsLateStartEvents() async {
        let events = EventHarness()
        let startBarrier = CancellationInsensitiveStartBarrier()
        var actions = Self.actions(events: events)
        actions.startMeeting = { request in try await startBarrier.start(request) }
        actions.stopMeeting = { await startBarrier.stop() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.presentedSheet = .meetingSetup
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        let startTask = Task { @MainActor in await model.startMeeting() }
        await startBarrier.waitUntilEntered()

        model.cancelMeetingSetup()
        await startBarrier.waitUntilCancellationObserved()
        XCTAssertNil(model.presentedSheet)
        XCTAssertEqual(model.meetingConsent, MeetingConsent())
        XCTAssertTrue(model.isCaptureActive)

        await events.emit(.stateChanged(Self.sessionState(phase: .listening)))
        await events.emit(
            .transcriptUpserted(
                TranscriptSegment(
                    source: .them,
                    text: "Late private content after Cancel",
                    startedAt: 2,
                    endedAt: 3,
                    isFinal: true
                )
            )
        )
        await Task.yield()
        XCTAssertTrue(model.transcript.isEmpty)

        await startBarrier.release()
        await startTask.value

        let stopCount = await startBarrier.stopCount()
        let fakeCaptureActive = await startBarrier.isActive()
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(fakeCaptureActive)
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertFalse(model.isPerformingMeetingAction)
        XCTAssertNil(model.presentedSheet)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertNotEqual(model.phase, .listening)
    }

    func testRevokedFailedStartStopsAndDiscardsExactSealedSnapshot() async {
        let events = EventHarness()
        let snapshotID = UUID()
        let startBarrier = CancellationInsensitiveStartBarrier(failsAfterRelease: true)
        let discardedSnapshots = SnapshotDiscardRecorder()
        var actions = Self.actions(events: events)
        actions.inspectRepository = { _ in
            GroundingReviewSummary(
                repositoryAlias: "fixture",
                branch: "main",
                revision: "abc123",
                includedFileCount: 2,
                hardExclusions: [],
                softFindings: [],
                instructionFiles: []
            )
        }
        actions.sealRepository = { _ in
            SealedRepositorySummary(
                snapshotID: snapshotID,
                repositoryAlias: "fixture",
                branch: "main",
                revision: "abc123",
                includedFileCount: 2,
                instructionFileCount: 0
            )
        }
        actions.startMeeting = { request in try await startBarrier.start(request) }
        actions.stopMeeting = { await startBarrier.stop() }
        actions.discardRepositorySnapshot = { id in await discardedSnapshots.record(id) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        await model.selectRepository(URL(fileURLWithPath: "/tmp/fixture", isDirectory: true))
        await model.sealRepository()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        let startTask = Task { @MainActor in await model.startMeeting() }
        await startBarrier.waitUntilEntered()
        model.cancelMeetingSetup()
        await startBarrier.waitUntilCancellationObserved()
        await startBarrier.release()
        await startTask.value

        let stopCount = await startBarrier.stopCount()
        let discardedIDs = await discardedSnapshots.ids()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(discardedIDs, [snapshotID])
        XCTAssertEqual(model.repositoryState, .none)
        XCTAssertEqual(model.meetingConsent, MeetingConsent())
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertFalse(model.hasIncompleteAudioTeardown)
        XCTAssertNil(model.actionError)
    }

    func testWithdrawingConsentAfterStartAutomaticallyStopsCapture() async throws {
        let events = EventHarness()
        let stopAction = RetryingStopAction(failureCount: 0)
        var actions = Self.actions(events: events)
        actions.stopMeeting = { try await stopAction.stop() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        await model.startMeeting()
        XCTAssertEqual(model.phase, .listening)

        model.meetingConsent.participantPermission = false

        for _ in 0..<100 {
            if await stopAction.count() == 1, model.phase == .ended { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stopCount = await stopAction.count()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(model.phase, .ended)
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertEqual(model.meetingConsent, MeetingConsent())
    }

    func testSoleNearbySpeakerConfirmationDefaultsOffAndResetsWithMicrophoneChanges() {
        let model = MeetingViewModel(hasCompletedFirstRun: true, microphoneEnabled: true)
        XCTAssertFalse(model.meetingConsent.soleNearbySpeakerConfirmed)

        model.meetingConsent.soleNearbySpeakerConfirmed = true
        model.meetingConsent.captureScopeConfirmed = true
        model.microphoneEnabled = false
        XCTAssertFalse(model.meetingConsent.soleNearbySpeakerConfirmed)
        XCTAssertFalse(model.meetingConsent.captureScopeConfirmed)

        model.meetingConsent.soleNearbySpeakerConfirmed = true
        model.microphoneEnabled = true
        XCTAssertFalse(model.meetingConsent.soleNearbySpeakerConfirmed)
    }

    func testOutputCaptureScopeMapsToCoreTranscriptAttributionScope() {
        XCTAssertEqual(OutputCaptureScope.meetingApplication.sessionScope, .meetingApplication)
        XCTAssertEqual(OutputCaptureScope.allSystemAudio.sessionScope, .allSystemAudio)
    }

    func testConsentDisclosuresMatchEachProvidersOutboundDataBoundary() {
        let participant = PaceNoteDisclosureText.meetingParticipantPermission.lowercased()
        XCTAssertTrue(participant.contains("informed all participants"))
        XCTAssertTrue(participant.contains("permission"))

        let firstRun = PaceNoteDisclosureText.firstRunProviderProcessing.lowercased()
        XCTAssertTrue(firstRun.contains("openai"))
        XCTAssertTrue(firstRun.contains("anthropic"))
        XCTAssertTrue(firstRun.contains("claude v1"))
        XCTAssertTrue(firstRun.contains("excludes agents.md"))

        for disclosure in [
            PaceNoteDisclosureText.meetingProcessing(for: .codex),
            PaceNoteDisclosureText.processingSummary(for: .codex),
        ] {
            let normalized = disclosure.lowercased()
            XCTAssertTrue(normalized.contains("agents.md instructions"))
            XCTAssertTrue(normalized.contains("selected skill content"))
            XCTAssertTrue(normalized.contains("tool output"))
            XCTAssertTrue(normalized.contains("repository excerpts"))
            XCTAssertTrue(normalized.contains("transcript slices"))
            XCTAssertTrue(normalized.contains("no zero-retention claim"))
        }

        for disclosure in [
            PaceNoteDisclosureText.meetingProcessing(for: .claude),
            PaceNoteDisclosureText.processingSummary(for: .claude),
        ] {
            let normalized = disclosure.lowercased()
            XCTAssertTrue(normalized.contains("anthropic"))
            XCTAssertTrue(normalized.contains("transcript slices"))
            XCTAssertTrue(normalized.contains("bounded host-selected lines"))
            XCTAssertTrue(normalized.contains("excludes agents.md"))
            XCTAssertTrue(normalized.contains("claude.md"))
            XCTAssertTrue(normalized.contains(".claude content"))
            XCTAssertTrue(normalized.contains("skill content"))
            XCTAssertTrue(normalized.contains("tools"))
            XCTAssertTrue(normalized.contains("tool output"))
            XCTAssertTrue(normalized.contains("no zero-retention claim"))
        }
    }

    func testProviderDefaultsPersistAndLegacyRequestDefaultsToCodex() {
        let suiteName = "MeetingViewModelTests.provider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MeetingViewModel.persistedInferenceProvider(in: defaults), .codex)
        let model = MeetingViewModel(
            hasCompletedFirstRun: true,
            providerDefaults: defaults
        )
        model.selectedProvider = .claude

        XCTAssertEqual(MeetingViewModel.persistedInferenceProvider(in: defaults), .claude)
        XCTAssertEqual(
            PaceNoteEnvironmentSnapshot(
                microphonePermission: .authorized,
                systemAudioPermission: .authorized,
                codex: .signedOut,
                outputSources: []
            ).claude,
            .notChecked
        )
        XCTAssertEqual(
            MeetingStartRequest(
                consentConfirmed: true,
                microphoneEnabled: true,
                outputEnabled: false,
                outputScope: .meetingApplication,
                outputSourceID: nil,
                sealedSnapshotID: nil,
                selectedDomainSkillName: nil
            ).provider,
            .codex
        )
    }

    func testSelectedProviderControlsReadinessAndClaudeSignInBlocker() async {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events, claudeState: .signedOut),
            hasCompletedFirstRun: true,
            selectedProvider: .claude
        )
        await model.bootstrap()
        model.phase = .listening

        XCTAssertFalse(model.canCoach)
        XCTAssertTrue(
            model.setupBlockers.contains(
                "Sign in with `claude auth login --claudeai`, then Recheck."
            )
        )

        model.selectedProvider = .codex
        XCTAssertTrue(model.canCoach)
    }

    func testExplicitClaudeAccountConfirmationRebindsTheCurrentSubscription() async {
        let events = EventHarness()
        let confirmed = InferenceAccountSummary(
            accountLabel: "c…@example.invalid",
            planLabel: "Claude Max",
            modelCount: 1
        )
        var actions = Self.actions(
            events: events,
            claudeState: .authenticationExpired("A different Claude account is signed in.")
        )
        actions.confirmClaudeAccountChange = { .ready(confirmed) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            selectedProvider: .claude
        )
        await model.bootstrap()
        model.meetingConsent.openAIProcessingConfirmed = true

        XCTAssertTrue(model.canConfirmClaudeAccountChange)
        await model.confirmClaudeAccountChange()

        XCTAssertEqual(model.claudeState, .ready(confirmed))
        XCTAssertFalse(model.canConfirmClaudeAccountChange)
        XCTAssertFalse(model.meetingConsent.openAIProcessingConfirmed)
        XCTAssertEqual(
            model.statusDetail,
            "The current Claude subscription account is now confirmed."
        )
    }

    func testProviderBrownoutsUseTheSelectedProviderNameAndRecoveryPath() {
        XCTAssertEqual(
            BrownoutReason.accountMismatch.userTitle(for: .claude),
            "Claude account changed"
        )
        XCTAssertEqual(
            BrownoutReason.authenticationExpired.recoveryGuidance(for: .claude),
            "Run `claude auth login --claudeai`, then Recheck."
        )
        XCTAssertEqual(
            BrownoutReason.protocolUnsupported.userTitle(for: .codex),
            "Codex version is unsupported"
        )
        XCTAssertEqual(
            BrownoutReason.deepLimited.userTitle(for: .codex),
            "ChirpCue's local Deep limit was reached"
        )
        XCTAssertEqual(
            BrownoutReason.deepLimited.recoveryGuidance(for: .codex),
            "Wait up to one minute, then use Retry Answer. This local pause does not mean your Codex subscription is exhausted."
        )
    }

    func testProviderAccountActionsAreBlockedDuringAnActiveMeeting() async {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events),
            hasCompletedFirstRun: true
        )
        await model.bootstrap()
        model.phase = .listening

        XCTAssertFalse(model.canManageProviderAccounts)
        await model.signInToCodex()

        XCTAssertEqual(
            model.actionError,
            "Stop the current meeting before changing the Codex account."
        )
    }

    func testRecheckDisablesStartUntilTheEnvironmentOperationFinishes() async {
        let events = EventHarness()
        let account = InferenceAccountSummary(
            accountLabel: "m•••@example.com",
            planLabel: "ChatGPT Pro",
            modelCount: 2
        )
        let snapshot = PaceNoteEnvironmentSnapshot(
            microphonePermission: .authorized,
            systemAudioPermission: .authorized,
            codex: .ready(account),
            outputSources: []
        )
        let recheckBarrier = AsyncValueBarrier(
            value: snapshot,
            suspendOnCall: 2
        )
        let starts = StartRequestRecorder()
        var actions = Self.actions(events: events)
        actions.checkEnvironment = { await recheckBarrier.call() }
        actions.startMeeting = { request in await starts.record(request) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        XCTAssertTrue(model.canStart)

        let recheck = Task { @MainActor in await model.refreshEnvironment() }
        await recheckBarrier.waitUntilEntered()

        XCTAssertTrue(model.isBootstrapping)
        XCTAssertFalse(model.canManageProviderAccounts)
        XCTAssertFalse(model.canStart)
        await model.startMeeting()
        let requestDuringRecheck = await starts.request()
        XCTAssertNil(requestDuringRecheck)

        await recheckBarrier.release()
        await recheck.value
        XCTAssertFalse(model.isBootstrapping)
        XCTAssertTrue(model.canStart)
    }

    func testSignInDisablesStartAndCoalescesDuplicateSignInAction() async {
        let events = EventHarness()
        let account = InferenceAccountSummary(
            accountLabel: "m•••@example.com",
            planLabel: "ChatGPT Pro",
            modelCount: 2
        )
        let signInBarrier = AsyncValueBarrier<CodexConnectionState>(
            value: .ready(account),
            suspendOnCall: 1
        )
        let starts = StartRequestRecorder()
        var actions = Self.actions(events: events)
        actions.beginCodexSignIn = { await signInBarrier.call() }
        actions.startMeeting = { request in await starts.record(request) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        XCTAssertTrue(model.canStart)

        let firstSignIn = Task { @MainActor in await model.signInToCodex() }
        await signInBarrier.waitUntilEntered()

        XCTAssertTrue(model.isBootstrapping)
        XCTAssertFalse(model.canStart)
        await model.signInToCodex()
        await model.startMeeting()
        let signInCalls = await signInBarrier.callCount()
        let requestDuringSignIn = await starts.request()
        XCTAssertEqual(signInCalls, 1)
        XCTAssertNil(requestDuringSignIn)

        await signInBarrier.release()
        await firstSignIn.value
        XCTAssertFalse(model.isBootstrapping)
        XCTAssertEqual(model.codexState, .ready(account))
        XCTAssertTrue(model.canStart)
    }

    func testClaudeStartRequestUsesClaudeWhenSubscriptionIsReady() async throws {
        let events = EventHarness()
        let recorder = StartRequestRecorder()
        let claudeAccount = InferenceAccountSummary(
            accountLabel: "Claude account",
            planLabel: "Claude Max",
            modelCount: 1
        )
        var actions = Self.actions(events: events, claudeState: .ready(claudeAccount))
        actions.startMeeting = { request in await recorder.record(request) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false,
            selectedProvider: .claude
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true

        await model.startMeeting()

        let recordedRequest = await recorder.request()
        XCTAssertEqual(try XCTUnwrap(recordedRequest).provider, .claude)
    }

    func testSwitchingToClaudeRevokesProcessingConsentAndClearsOnlyTheSkill() async {
        let events = EventHarness()
        var actions = Self.actions(events: events)
        actions.inspectRepository = { _ in
            GroundingReviewSummary(
                repositoryAlias: "fixture",
                branch: "main",
                revision: "abc123",
                includedFileCount: 3,
                hardExclusions: [],
                softFindings: [],
                instructionFiles: []
            )
        }
        actions.sealRepository = { _ in
            SealedRepositorySummary(
                snapshotID: UUID(),
                repositoryAlias: "fixture",
                branch: "main",
                revision: "abc123",
                includedFileCount: 3,
                instructionFileCount: 0,
                domainSkills: [DomainSkillOption(name: "incident-response")]
            )
        }
        let model = MeetingViewModel(actions: actions, hasCompletedFirstRun: true)
        await model.bootstrap()
        await model.selectRepository(URL(fileURLWithPath: "/tmp/fixture", isDirectory: true))
        await model.sealRepository()
        model.selectedDomainSkillName = "incident-response"
        model.meetingConsent.openAIProcessingConfirmed = true

        model.selectedProvider = .claude

        XCTAssertFalse(model.meetingConsent.openAIProcessingConfirmed)
        XCTAssertNil(model.selectedDomainSkillName)
        XCTAssertEqual(model.repositoryName, "fixture")
        XCTAssertTrue(model.repositoryState.isReady)
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

    func testDismissForwardsDisplayedIdentityAndClearsOnlySuggestionCards() async throws {
        let events = EventHarness()
        let recorder = SuggestionDismissRecorder()
        let listeningState = Self.sessionState(phase: .listening)
        var actions = Self.actions(events: events)
        actions.dismissSuggestion = { identity in
            await recorder.record(identity)
            await events.emit(.suggestionsCleared(identity))
            await events.emit(.stateChanged(listeningState))
        }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        await model.startMeeting()

        let transcript = TranscriptSegment(
            source: .them,
            text: "How does the queue stay bounded?",
            startedAt: 1,
            endedAt: 2,
            isFinal: true
        )
        let identity = TurnIdentity(meetingID: UUID(), generation: 7)
        model.receiveTranscript([transcript])
        model.receiveQuickSuggestion(
            SuggestionCard(identity: identity, stage: .bridge, text: "Let me verify that.")
        )
        model.manualQuestion = "Keep this draft"

        await model.dismissSuggestion()
        try await Self.eventually {
            model.quickSuggestion == nil && model.deepSuggestion == nil
                && model.phase == .listening
        }

        let recordedIdentity = await recorder.identity()
        XCTAssertEqual(recordedIdentity, identity)
        XCTAssertEqual(model.transcript, [transcript])
        XCTAssertEqual(model.manualQuestion, "Keep this draft")
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertFalse(model.isDismissingSuggestion)
        XCTAssertFalse(model.canDismissSuggestion)
    }

    func testDismissBlocksCoachAndPauseButKeepsStopAvailable() async {
        let events = EventHarness()
        let dismissBarrier = AsyncStopBarrier()
        var actions = Self.actions(events: events)
        actions.dismissSuggestion = { _ in await dismissBarrier.wait() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        await model.startMeeting()
        model.receiveQuickSuggestion(
            SuggestionCard(
                identity: TurnIdentity(meetingID: UUID(), generation: 1),
                stage: .bridge,
                text: "Let me verify that."
            )
        )

        let dismissTask = Task { @MainActor in await model.dismissSuggestion() }
        await dismissBarrier.waitUntilEntered()
        XCTAssertTrue(model.isDismissingSuggestion)
        XCTAssertFalse(model.canDismissSuggestion)
        XCTAssertFalse(model.canCoach)
        XCTAssertFalse(model.canPause)
        XCTAssertTrue(model.canStop)

        await model.stop()
        XCTAssertEqual(model.phase, .ended)
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertTrue(model.isDismissingSuggestion)

        await dismissBarrier.release()
        await dismissTask.value
        XCTAssertFalse(model.isDismissingSuggestion)
        XCTAssertFalse(model.canStop)
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
        XCTAssertFalse(model.canCoach)
        await model.resume()
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertTrue(model.canCoach)
        await model.stop()
        XCTAssertFalse(model.isCaptureActive)
    }

    func testResumeShowsCaptureIndicatorBeforeRuntimeReturns() async {
        let events = EventHarness()
        let resumeBarrier = AsyncStopBarrier()
        var actions = Self.actions(events: events)
        actions.resumeMeeting = { await resumeBarrier.wait() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.phase = .paused

        let resumeTask = Task { @MainActor in await model.resume() }
        await resumeBarrier.waitUntilEntered()

        XCTAssertTrue(model.isCaptureActive)
        await resumeBarrier.release()
        await resumeTask.value
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertEqual(model.phase, .listening)
    }

    func testTypedResumeTeardownFailureKeepsCaptureIndicatorOn() async {
        let events = EventHarness()
        var actions = Self.actions(events: events)
        actions.resumeMeeting = { throw PaceNoteActionError.audioTeardown(.microphone) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.phase = .paused

        await model.resume()

        XCTAssertEqual(model.phase, .brownout)
        XCTAssertTrue(model.hasIncompleteAudioTeardown)
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertTrue(model.statusDetail.contains("may still be active"))
    }

    func testRuntimeStateCannotClearIndicatorAfterTeardownFailure() async throws {
        let events = EventHarness()
        let model = MeetingViewModel(
            actions: Self.actions(events: events),
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.phase = .paused

        await events.emit(.failed(.captureTeardownFailed(.microphone)))
        await events.emit(
            .stateChanged(
                MeetingSessionState(
                    phase: .brownout,
                    captureMode: .microphoneOnly,
                    consentConfirmed: true,
                    isPrepared: false,
                    isRunning: false,
                    runtime: nil,
                    transcript: [],
                    suggestions: [],
                    brownouts: [MeetingBrownout(reason: .outputDisabled, lane: .output)]
                )
            )
        )
        try await Self.eventually {
            model.hasIncompleteAudioTeardown && model.brownouts.contains(.outputDisabled)
        }

        XCTAssertEqual(model.phase, .brownout)
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertTrue(model.statusDetail.contains("may still be active"))
    }

    func testSuccessfulStopRejectsLateBufferedEventsAndClearsAgainAfterAwait() async throws {
        let events = EventHarness()
        let stopBarrier = AsyncStopBarrier()
        var actions = Self.actions(events: events)
        actions.stopMeeting = { await stopBarrier.wait() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        await model.startMeeting()

        let stopTask = Task { @MainActor in await model.stop() }
        await stopBarrier.waitUntilEntered()
        XCTAssertTrue(model.isCaptureActive)
        let lateSegment = TranscriptSegment(
            source: .them,
            text: "Late private transcript",
            startedAt: 3,
            endedAt: 4,
            isFinal: true
        )
        let identity = TurnIdentity(meetingID: UUID(), generation: 9)
        await events.emit(.stateChanged(Self.sessionState(phase: .suggesting)))
        await events.emit(.transcriptUpserted(lateSegment))
        await events.emit(
            .suggestionUpserted(
                SuggestionCard(identity: identity, stage: .bridge, text: "Late private suggestion")
            )
        )
        await Task.yield()
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertNil(model.quickSuggestion)

        await stopBarrier.release()
        await stopTask.value
        await events.emit(.transcriptUpserted(lateSegment))
        await events.emit(
            .suggestionUpserted(
                SuggestionCard(identity: identity, stage: .bridge, text: "Replayed suggestion")
            )
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(model.phase, .ended)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertNil(model.quickSuggestion)
        XCTAssertNil(model.deepSuggestion)
        XCTAssertFalse(model.isCaptureActive)
    }

    func testStopFailureKeepsRetryableBrownoutAfterClearingSensitiveContent() async {
        let events = EventHarness()
        let stopAction = RetryingStopAction(failureCount: 1)
        var actions = Self.actions(events: events)
        actions.stopMeeting = { try await stopAction.stop() }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        await model.startMeeting()
        XCTAssertFalse(model.canStart)
        XCTAssertTrue(model.canCoach)
        XCTAssertTrue(model.canPause)
        model.receiveTranscript([
            TranscriptSegment(
                source: .them,
                text: "Sensitive meeting content",
                startedAt: 1,
                endedAt: 2,
                isFinal: true
            )
        ])
        model.receiveQuickSuggestion(
            SuggestionCard(
                identity: TurnIdentity(meetingID: UUID(), generation: 1),
                stage: .quick,
                text: "Sensitive response"
            )
        )

        await model.stop()

        XCTAssertEqual(model.phase, .brownout)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertNil(model.quickSuggestion)
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(model.hasIncompleteAudioTeardown)
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.canCoach)
        XCTAssertFalse(model.canPause)
        model.receiveTranscript([
            TranscriptSegment(
                source: .them,
                text: "Late queued transcript",
                startedAt: 3,
                endedAt: 4,
                isFinal: true
            )
        ])
        model.receiveQuickSuggestion(
            SuggestionCard(
                identity: TurnIdentity(meetingID: UUID(), generation: 2),
                stage: .quick,
                text: "Late queued response"
            )
        )
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertNil(model.quickSuggestion)
        XCTAssertEqual(model.phase, .brownout)
        let firstCallCount = await stopAction.count()
        XCTAssertEqual(firstCallCount, 1)

        await model.stop()

        XCTAssertEqual(model.phase, .ended)
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.hasIncompleteAudioTeardown)
        XCTAssertFalse(model.isCaptureActive)
        XCTAssertTrue(model.canPresentSetup)
        let finalCallCount = await stopAction.count()
        XCTAssertEqual(finalCallCount, 2)
    }

    func testTypedAudioTeardownActionDoesNotClaimStartSucceededOrResetToSetup() async {
        let events = EventHarness()
        var actions = Self.actions(events: events)
        actions.startMeeting = { _ in throw PaceNoteActionError.audioTeardown(.output) }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: true,
            outputEnabled: false
        )
        await model.bootstrap()
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        model.presentedSheet = .meetingSetup

        await model.startMeeting()

        XCTAssertEqual(model.phase, .brownout)
        XCTAssertTrue(model.isCaptureActive)
        XCTAssertTrue(model.hasIncompleteAudioTeardown)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.canCoach)
        XCTAssertFalse(model.canPause)
        XCTAssertNil(model.presentedSheet)
        XCTAssertTrue(model.statusDetail.contains("Retry Stop"))
    }

    func testNonAudioStopCleanupFailureReleasesPerMeetingConsentAndRepositoryState() async {
        let events = EventHarness()
        let snapshotID = UUID()
        var actions = Self.actions(events: events)
        actions.inspectRepository = { _ in
            GroundingReviewSummary(
                repositoryAlias: "fixture",
                branch: "main",
                revision: "abc123",
                includedFileCount: 3,
                hardExclusions: [],
                softFindings: [],
                instructionFiles: []
            )
        }
        actions.sealRepository = { _ in
            SealedRepositorySummary(
                snapshotID: snapshotID,
                repositoryAlias: "fixture",
                branch: "main",
                revision: "abc123",
                includedFileCount: 3,
                instructionFileCount: 0,
                domainSkills: [DomainSkillOption(name: "incident-response")]
            )
        }
        actions.discardRepositorySnapshot = { _ in
            throw PaceNoteActionError.safeMessage("Snapshot cleanup was journaled.")
        }
        let model = MeetingViewModel(
            actions: actions,
            hasCompletedFirstRun: true,
            microphoneEnabled: false,
            outputEnabled: false
        )
        await model.bootstrap()
        await model.selectRepository(URL(fileURLWithPath: "/tmp/fixture", isDirectory: true))
        await model.sealRepository()
        model.selectedDomainSkillName = "incident-response"
        model.meetingConsent.participantPermission = true
        model.meetingConsent.captureScopeConfirmed = true
        model.meetingConsent.openAIProcessingConfirmed = true
        model.phase = .listening

        await model.stop()

        XCTAssertEqual(model.phase, .ended)
        XCTAssertEqual(model.repositoryState, .none)
        XCTAssertNil(model.repositoryName)
        XCTAssertNil(model.selectedDomainSkillName)
        XCTAssertEqual(model.meetingConsent, MeetingConsent())
        XCTAssertTrue(model.approvedSoftFindingIDs.isEmpty)
        XCTAssertFalse(model.hasIncompleteAudioTeardown)
        XCTAssertNotNil(model.actionError)
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

    func testGeneralDeepCardIsNeverDescribedAsRepositoryGrounded() {
        let model = MeetingViewModel(hasCompletedFirstRun: true)
        model.phase = .listening
        let identity = TurnIdentity(meetingID: UUID(), generation: 1)
        model.receiveQuickSuggestion(
            SuggestionCard(identity: identity, stage: .bridge, text: "Let me think about that.")
        )
        let general = SuggestionCard(
            identity: identity,
            stage: .deep,
            text: "I’d use a queue here because it separates acceptance from downstream processing.",
            deepKind: .generalAnswer
        )

        model.receiveVerifiedDeepSuggestion(general)

        XCTAssertEqual(model.deepSuggestion, general)
        XCTAssertEqual(model.statusDetail, "General guidance is ready. Verify it before speaking.")
        XCTAssertFalse(model.statusDetail.lowercased().contains("repository"))
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

    private static func actions(
        events: EventHarness,
        outputSources: [OutputSourceOption] = [],
        codexState: InferenceConnectionState = .ready(
            InferenceAccountSummary(
                accountLabel: "m•••@example.com",
                planLabel: "ChatGPT Pro",
                modelCount: 2
            )
        ),
        claudeState: InferenceConnectionState = .notChecked
    ) -> MeetingActions {
        MeetingActions(
            sessionEvents: { await events.stream() },
            checkEnvironment: {
                PaceNoteEnvironmentSnapshot(
                    microphonePermission: .authorized,
                    systemAudioPermission: .authorized,
                    codex: codexState,
                    outputSources: outputSources,
                    claude: claudeState
                )
            },
            requestCapturePermission: { _ in .authorized },
            beginCodexSignIn: { .signedOut },
            forgetCodexProfile: {},
            confirmClaudeAccountChange: { .signedOut },
            reloadOutputSources: { [] },
            inspectRepository: { _ in throw PaceNoteActionError.serviceNotConnected },
            sealRepository: { _ in throw PaceNoteActionError.serviceNotConnected },
            discardRepositorySnapshot: { _ in },
            startMeeting: { _ in },
            pauseMeeting: {},
            resumeMeeting: {},
            stopMeeting: {},
            coachCurrentTurn: { _ in },
            dismissSuggestion: { _ in }
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

private actor AsyncValueBarrier<Value: Sendable> {
    private let value: Value
    private let suspendedCallNumber: Int
    private var calls = 0
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(value: Value, suspendOnCall: Int) {
        self.value = value
        suspendedCallNumber = suspendOnCall
    }

    func call() async -> Value {
        calls += 1
        guard calls == suspendedCallNumber else { return value }
        entered = true
        let waiters = enteredContinuations
        enteredContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return value }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        return value
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseContinuations
        releaseContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func callCount() -> Int { calls }
}

private actor RetryingStopAction {
    private var failuresRemaining: Int
    private(set) var callCount = 0

    init(failureCount: Int) {
        failuresRemaining = failureCount
    }

    func stop() throws {
        callCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PaceNoteActionError.audioTeardown(.output)
        }
    }

    func count() -> Int { callCount }
}

private actor AsyncStopBarrier {
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CancellationInsensitiveStartBarrier {
    private let failsAfterRelease: Bool
    private var entered = false
    private var cancellationObserved = false
    private var released = false
    private var active = false
    private var stopCallCount = 0
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(failsAfterRelease: Bool = false) {
        self.failsAfterRelease = failsAfterRelease
    }

    func start(_ request: MeetingStartRequest) async throws {
        precondition(request.consentConfirmed)
        entered = true
        let waiters = enteredContinuations
        enteredContinuations.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { continuation in
                    if released {
                        continuation.resume()
                    } else {
                        releaseContinuation = continuation
                    }
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        if failsAfterRelease { throw CancellationError() }
        active = true
    }

    func stop() {
        stopCallCount += 1
        active = false
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func isActive() -> Bool { active }
    func stopCount() -> Int { stopCallCount }

    private func recordCancellation() {
        cancellationObserved = true
        let waiters = cancellationContinuations
        cancellationContinuations.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private actor SnapshotDiscardRecorder {
    private var values: [UUID] = []

    func record(_ id: UUID) {
        values.append(id)
    }

    func ids() -> [UUID] { values }
}

private actor SuggestionDismissRecorder {
    private var value: TurnIdentity?

    func record(_ identity: TurnIdentity) {
        value = identity
    }

    func identity() -> TurnIdentity? { value }
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
