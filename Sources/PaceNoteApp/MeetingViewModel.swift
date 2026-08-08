import Foundation
import Observation
import PaceNoteCore

enum PaceNoteSheet: String, Equatable, Identifiable {
    case firstRun
    case meetingSetup
    case repositoryReview
    case privacyDetails

    var id: String { rawValue }
}

enum CapturePermissionKind: String, Sendable {
    case microphone
    case systemAudio
}

enum CapturePermissionState: Equatable, Sendable {
    case notChecked
    case requesting
    case authorized
    case denied
    case unavailable(String)

    var isAuthorized: Bool {
        self == .authorized
    }
}

enum CodexConnectionState: Equatable, Sendable {
    case notChecked
    case checking
    case signedOut
    case authenticationExpired(String)
    case ready(CodexAccountSummary)
    case limited(String)
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct CodexAccountSummary: Equatable, Sendable {
    let accountLabel: String
    let planLabel: String
    let modelCount: Int

    init(accountLabel: String, planLabel: String, modelCount: Int) {
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.modelCount = modelCount
    }
}

enum OutputCaptureScope: String, CaseIterable, Identifiable, Sendable {
    case meetingApplication
    case allSystemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetingApplication: "One meeting app"
        case .allSystemAudio: "All Mac output"
        }
    }

    var explanation: String {
        switch self {
        case .meetingApplication:
            "Only the selected meeting application's output is captured."
        case .allSystemAudio:
            "Every audible app can enter the transcript. Use only when app-specific capture is unavailable."
        }
    }

    var sessionScope: MeetingSystemOutputScope {
        switch self {
        case .meetingApplication: .meetingApplication
        case .allSystemAudio: .allSystemAudio
        }
    }
}

enum PaceNoteDisclosureText {
    static let firstRunOpenAIProcessing =
        "I understand transcript slices, selected repository excerpts, applicable AGENTS.md instructions, selected skill content, and tool output may leave this Mac and be processed by OpenAI through my signed-in ChatGPT account."
    static let meetingParticipantPermission =
        "I have informed all participants about live transcription and AI assistance, and I have permission to capture and process this meeting."
    static let meetingOpenAIProcessing =
        "I understand this meeting's transcript slices, any selected repository excerpts, applicable AGENTS.md instructions, selected skill content, and tool output may leave this Mac and be processed by OpenAI through my ChatGPT account."
    static let openAIProcessingSummary =
        "Transcript slices, selected repository excerpts, applicable AGENTS.md instructions, selected skill content, and tool output may leave this Mac for processing under the signed-in ChatGPT account's applicable OpenAI terms. PaceNote makes no zero-retention claim."
    static let soleNearbySpeaker =
        "I am the only person near this Mac's microphone. Label microphone speech as YOU."
}

struct OutputSourceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String?

    init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

struct PaceNoteEnvironmentSnapshot: Equatable, Sendable {
    let microphonePermission: CapturePermissionState
    let systemAudioPermission: CapturePermissionState
    let codex: CodexConnectionState
    let outputSources: [OutputSourceOption]

    init(
        microphonePermission: CapturePermissionState,
        systemAudioPermission: CapturePermissionState,
        codex: CodexConnectionState,
        outputSources: [OutputSourceOption]
    ) {
        self.microphonePermission = microphonePermission
        self.systemAudioPermission = systemAudioPermission
        self.codex = codex
        self.outputSources = outputSources
    }
}

struct GroundingReviewFinding: Identifiable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let detail: String

    init(id: String, relativePath: String, detail: String) {
        self.id = id
        self.relativePath = relativePath
        self.detail = detail
    }
}

struct GroundingReviewSummary: Equatable, Sendable {
    let repositoryAlias: String
    let branch: String
    let revision: String
    let includedFileCount: Int
    let hardExclusions: [GroundingReviewFinding]
    let softFindings: [GroundingReviewFinding]
    let instructionFiles: [String]

    init(
        repositoryAlias: String,
        branch: String,
        revision: String,
        includedFileCount: Int,
        hardExclusions: [GroundingReviewFinding],
        softFindings: [GroundingReviewFinding],
        instructionFiles: [String]
    ) {
        self.repositoryAlias = repositoryAlias
        self.branch = branch
        self.revision = revision
        self.includedFileCount = includedFileCount
        self.hardExclusions = hardExclusions
        self.softFindings = softFindings
        self.instructionFiles = instructionFiles
    }
}

struct SealedRepositorySummary: Equatable, Sendable {
    let snapshotID: UUID
    let repositoryAlias: String
    let branch: String
    let revision: String
    let includedFileCount: Int
    let instructionFileCount: Int
    let domainSkills: [DomainSkillOption]

    init(
        snapshotID: UUID,
        repositoryAlias: String,
        branch: String,
        revision: String,
        includedFileCount: Int,
        instructionFileCount: Int,
        domainSkills: [DomainSkillOption] = []
    ) {
        self.snapshotID = snapshotID
        self.repositoryAlias = repositoryAlias
        self.branch = branch
        self.revision = revision
        self.includedFileCount = includedFileCount
        self.instructionFileCount = instructionFileCount
        self.domainSkills = domainSkills
    }
}

struct DomainSkillOption: Identifiable, Hashable, Sendable {
    let name: String

    var id: String { name }
}

enum RepositorySetupState: Equatable, Sendable {
    case none
    case inspecting(String)
    case review(GroundingReviewSummary)
    case sealing(GroundingReviewSummary)
    case sealed(SealedRepositorySummary)
    case blocked(alias: String, message: String)

    var displayAlias: String? {
        switch self {
        case .none: nil
        case .inspecting(let alias): alias
        case .review(let summary), .sealing(let summary): summary.repositoryAlias
        case .sealed(let summary): summary.repositoryAlias
        case .blocked(let alias, _): alias
        }
    }

    var isReady: Bool {
        if case .sealed = self { return true }
        return false
    }

    var isPending: Bool {
        switch self {
        case .inspecting, .review, .sealing: true
        default: false
        }
    }
}

struct FirstRunAcknowledgement: Equatable, Sendable {
    var manualStartOnly = false
    var consentResponsibility = false
    var openAIProcessing = false

    var isComplete: Bool {
        manualStartOnly && consentResponsibility && openAIProcessing
    }
}

struct MeetingConsent: Equatable, Sendable {
    var participantPermission = false
    var captureScopeConfirmed = false
    var openAIProcessingConfirmed = false
    var soleNearbySpeakerConfirmed = false

    var isComplete: Bool {
        participantPermission && captureScopeConfirmed && openAIProcessingConfirmed
    }
}

struct MeetingStartRequest: Equatable, Sendable {
    let consentConfirmed: Bool
    let microphoneEnabled: Bool
    let outputEnabled: Bool
    let outputScope: OutputCaptureScope
    let outputSourceID: String?
    let sealedSnapshotID: UUID?
    let selectedDomainSkillName: String?
    let soleNearbySpeakerConfirmed: Bool

    init(
        consentConfirmed: Bool,
        microphoneEnabled: Bool,
        outputEnabled: Bool,
        outputScope: OutputCaptureScope,
        outputSourceID: String?,
        sealedSnapshotID: UUID?,
        selectedDomainSkillName: String?,
        soleNearbySpeakerConfirmed: Bool = false
    ) {
        self.consentConfirmed = consentConfirmed
        self.microphoneEnabled = microphoneEnabled
        self.outputEnabled = outputEnabled
        self.outputScope = outputScope
        self.outputSourceID = outputSourceID
        self.sealedSnapshotID = sealedSnapshotID
        self.selectedDomainSkillName = selectedDomainSkillName
        self.soleNearbySpeakerConfirmed = soleNearbySpeakerConfirmed
    }
}

struct RepositorySealRequest: Sendable {
    let repositoryURL: URL
    let approvedSoftFindingIDs: Set<String>

    init(repositoryURL: URL, approvedSoftFindingIDs: Set<String>) {
        self.repositoryURL = repositoryURL
        self.approvedSoftFindingIDs = approvedSoftFindingIDs
    }
}

enum PaceNoteActionError: LocalizedError, Sendable {
    case serviceNotConnected
    case audioTeardown(AudioLane)
    case safeMessage(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotConnected:
            "PaceNote's local service is not connected yet."
        case .audioTeardown(let lane):
            "The \(lane.rawValue) audio route could not be fully stopped. Retry Stop before starting or resuming."
        case .safeMessage(let message):
            message
        }
    }
}

struct MeetingActions: Sendable {
    var sessionEvents: @Sendable () async -> AsyncStream<MeetingSessionEvent>
    var checkEnvironment: @Sendable () async -> PaceNoteEnvironmentSnapshot
    var requestCapturePermission: @Sendable (CapturePermissionKind) async -> CapturePermissionState
    var beginCodexSignIn: @Sendable () async -> CodexConnectionState
    var forgetCodexProfile: @Sendable () async throws -> Void
    var reloadOutputSources: @Sendable () async -> [OutputSourceOption]
    var inspectRepository: @Sendable (URL) async throws -> GroundingReviewSummary
    var sealRepository: @Sendable (RepositorySealRequest) async throws -> SealedRepositorySummary
    var discardRepositorySnapshot: @Sendable (UUID) async throws -> Void
    var startMeeting: @Sendable (MeetingStartRequest) async throws -> Void
    var pauseMeeting: @Sendable () async throws -> Void
    var resumeMeeting: @Sendable () async throws -> Void
    var stopMeeting: @Sendable () async throws -> Void
    var coachCurrentTurn: @Sendable (String?) async throws -> Void

    static let unwired = unavailable(reason: "PaceNote's local service is not connected yet.")

    static func unavailable(reason: String) -> MeetingActions {
        MeetingActions(
            sessionEvents: { AsyncStream { $0.finish() } },
            checkEnvironment: {
                PaceNoteEnvironmentSnapshot(
                    microphonePermission: .unavailable(reason),
                    systemAudioPermission: .unavailable(reason),
                    codex: .unavailable(reason),
                    outputSources: []
                )
            },
            requestCapturePermission: { _ in .unavailable(reason) },
            beginCodexSignIn: { .unavailable(reason) },
            forgetCodexProfile: { throw PaceNoteActionError.safeMessage(reason) },
            reloadOutputSources: { [] },
            inspectRepository: { _ in throw PaceNoteActionError.safeMessage(reason) },
            sealRepository: { _ in throw PaceNoteActionError.safeMessage(reason) },
            discardRepositorySnapshot: { _ in throw PaceNoteActionError.safeMessage(reason) },
            startMeeting: { _ in throw PaceNoteActionError.safeMessage(reason) },
            pauseMeeting: { throw PaceNoteActionError.safeMessage(reason) },
            resumeMeeting: { throw PaceNoteActionError.safeMessage(reason) },
            stopMeeting: { throw PaceNoteActionError.safeMessage(reason) },
            coachCurrentTurn: { _ in throw PaceNoteActionError.safeMessage(reason) }
        )
    }
}

@MainActor
@Observable
final class MeetingViewModel {
    var phase: MeetingPhase = .idle
    private(set) var isCaptureActive = false
    private(set) var transcript: [TranscriptSegment] = []
    private(set) var quickSuggestion: SuggestionCard?
    private(set) var deepSuggestion: SuggestionCard?
    private(set) var brownouts: Set<BrownoutReason> = []
    var manualQuestion = ""
    var statusDetail = "Complete setup before listening."
    var microphoneEnabled = true {
        didSet {
            if oldValue != microphoneEnabled {
                meetingConsent.captureScopeConfirmed = false
                meetingConsent.soleNearbySpeakerConfirmed = false
            }
        }
    }
    var outputEnabled = true {
        didSet {
            if oldValue != outputEnabled { meetingConsent.captureScopeConfirmed = false }
        }
    }
    var outputScope: OutputCaptureScope = .meetingApplication {
        didSet {
            if oldValue != outputScope { meetingConsent.captureScopeConfirmed = false }
        }
    }
    var selectedOutputSourceID: String? {
        didSet {
            if oldValue != selectedOutputSourceID { meetingConsent.captureScopeConfirmed = false }
        }
    }
    private(set) var outputSources: [OutputSourceOption] = []
    private(set) var microphonePermission: CapturePermissionState = .notChecked
    private(set) var systemAudioPermission: CapturePermissionState = .notChecked
    private(set) var codexState: CodexConnectionState = .notChecked
    private(set) var repositoryState: RepositorySetupState = .none
    private(set) var isBootstrapping = false
    private(set) var isPerformingMeetingAction = false
    private(set) var hasIncompleteAudioTeardown = false
    private(set) var actionError: String?
    var presentedSheet: PaceNoteSheet?
    var firstRunAcknowledgement = FirstRunAcknowledgement()
    private(set) var hasCompletedFirstRun: Bool
    var meetingConsent = MeetingConsent() {
        didSet {
            if oldValue != meetingConsent {
                meetingStartConfigurationDidChange()
            }
        }
    }
    var approvedSoftFindingIDs: Set<String> = []
    var selectedDomainSkillName: String? {
        didSet {
            if oldValue != selectedDomainSkillName {
                meetingConsent.openAIProcessingConfirmed = false
            }
        }
    }

    private let actions: MeetingActions
    private var selectedRepositoryURL: URL?
    private var didBootstrap = false
    private var privacyReturnSheet: PaceNoteSheet?
    private var runtimeEventTask: Task<Void, Never>?
    private var isStopping = false
    private var ignoresSessionEvents = false
    private struct PendingMeetingStart {
        let id: UUID
        let request: MeetingStartRequest
        let task: Task<Void, any Error>
    }
    private var pendingMeetingStart: PendingMeetingStart?
    private var activeStartRequest: MeetingStartRequest?
    private var consentRevocationStopTask: Task<Void, Never>?

    init(
        actions: MeetingActions = .unwired,
        hasCompletedFirstRun: Bool = false,
        microphoneEnabled: Bool = true,
        outputEnabled: Bool = true,
        outputScope: OutputCaptureScope = .meetingApplication
    ) {
        self.actions = actions
        self.hasCompletedFirstRun = hasCompletedFirstRun
        self.microphoneEnabled = microphoneEnabled
        self.outputEnabled = outputEnabled
        self.outputScope = outputScope
        if !hasCompletedFirstRun {
            presentedSheet = .firstRun
        }
    }

    var repositoryName: String? { repositoryState.displayAlias }

    var selectedOutputSource: OutputSourceOption? {
        outputSources.first { $0.id == selectedOutputSourceID }
    }

    var canPresentSetup: Bool {
        !hasIncompleteAudioTeardown && !isPerformingMeetingAction
            && (phase == .idle || phase == .ready || phase == .ended
                || phase == .permissionRequired)
    }

    var canStart: Bool {
        !hasIncompleteAudioTeardown && !isMeetingActive && pendingMeetingStart == nil
            && setupBlockers.isEmpty && !isPerformingMeetingAction
    }

    var canCoach: Bool {
        !hasIncompleteAudioTeardown && codexState.isReady && !isPerformingMeetingAction
            && isMeetingActive && phase != .paused
    }

    var canCoachCurrentTurn: Bool {
        canCoach && outputEnabled
    }

    var canForgetCodexProfile: Bool {
        guard !hasIncompleteAudioTeardown, !isMeetingActive,
            !isPerformingMeetingAction, pendingMeetingStart == nil
        else { return false }
        switch codexState {
        case .notChecked, .checking, .signedOut:
            return false
        case .authenticationExpired, .ready, .limited, .unavailable:
            return true
        }
    }

    var canPause: Bool {
        guard !hasIncompleteAudioTeardown else { return false }
        return switch phase {
        case .listening, .candidateQuestion, .thinking, .suggesting, .brownout: true
        default: false
        }
    }

    var setupBlockers: [String] {
        var blockers: [String] = []
        if !microphoneEnabled && !outputEnabled {
            blockers.append("Enable the microphone or meeting output before starting.")
        }
        if microphoneEnabled && !microphonePermission.isAuthorized {
            blockers.append("Microphone permission is required while microphone capture is on.")
        }
        if outputEnabled && !systemAudioPermission.isAuthorized {
            blockers.append("System audio permission is required while output capture is on.")
        }
        if outputEnabled && outputScope == .meetingApplication && selectedOutputSourceID == nil {
            blockers.append("Choose the meeting application to capture.")
        }
        if !codexState.isReady {
            blockers.append("Sign in to ChatGPT through the local Codex app-server.")
        }
        if repositoryState.isPending {
            blockers.append("Finish or cancel the repository review.")
        }
        if case .blocked = repositoryState {
            blockers.append("Remove or reselect the blocked repository.")
        }
        if !meetingConsent.isComplete {
            blockers.append("Confirm all per-meeting consent statements.")
        }
        return blockers
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        isBootstrapping = true
        let events = await actions.sessionEvents()
        runtimeEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receiveSessionEvent(event)
            }
        }
        let snapshot = await actions.checkEnvironment()
        microphonePermission = snapshot.microphonePermission
        systemAudioPermission = snapshot.systemAudioPermission
        codexState = snapshot.codex
        outputSources = snapshot.outputSources
        selectFirstOutputSourceIfNeeded()
        isBootstrapping = false
        refreshReadyPhase()
    }

    func completeFirstRun() {
        guard firstRunAcknowledgement.isComplete else { return }
        hasCompletedFirstRun = true
        presentedSheet = nil
        statusDetail = "Ready to configure a consented meeting."
        refreshReadyPhase()
    }

    func presentMeetingSetup() {
        guard hasCompletedFirstRun, canPresentSetup else {
            if !hasCompletedFirstRun { presentedSheet = .firstRun }
            return
        }
        actionError = nil
        meetingConsent = MeetingConsent()
        presentedSheet = .meetingSetup
    }

    func cancelMeetingSetup() {
        let wasStarting = pendingMeetingStart != nil
        invalidatePendingMeetingStart()
        meetingConsent = MeetingConsent()
        privacyReturnSheet = nil
        presentedSheet = nil
        if !wasStarting {
            statusDetail = "Meeting setup was canceled. Nothing is being captured."
        }
    }

    func presentPrivacyDetails() {
        guard !isPerformingMeetingAction else { return }
        privacyReturnSheet = presentedSheet == .meetingSetup ? .meetingSetup : nil
        presentedSheet = .privacyDetails
    }

    func closePrivacyDetails() {
        presentedSheet = privacyReturnSheet
        privacyReturnSheet = nil
    }

    func requestPermission(_ kind: CapturePermissionKind) async {
        actionError = nil
        switch kind {
        case .microphone: microphonePermission = .requesting
        case .systemAudio: systemAudioPermission = .requesting
        }
        let result = await actions.requestCapturePermission(kind)
        switch kind {
        case .microphone: microphonePermission = result
        case .systemAudio: systemAudioPermission = result
        }
        refreshReadyPhase()
    }

    func refreshEnvironment() async {
        isBootstrapping = true
        actionError = nil
        let snapshot = await actions.checkEnvironment()
        microphonePermission = snapshot.microphonePermission
        systemAudioPermission = snapshot.systemAudioPermission
        codexState = snapshot.codex
        outputSources = snapshot.outputSources
        selectFirstOutputSourceIfNeeded()
        isBootstrapping = false
        refreshReadyPhase()
    }

    func signInToCodex() async {
        guard !isPerformingMeetingAction else { return }
        actionError = nil
        codexState = .checking
        codexState = await actions.beginCodexSignIn()
        refreshReadyPhase()
    }

    func forgetCodexProfile() async {
        guard canForgetCodexProfile else {
            actionError =
                "Finish or stop the current meeting action before forgetting the Codex profile."
            return
        }
        isPerformingMeetingAction = true
        actionError = nil
        do {
            try await actions.forgetCodexProfile()
            codexState = .signedOut
            statusDetail = "The isolated Codex profile was forgotten."
            refreshReadyPhase()
        } catch {
            actionError = safeMessage(for: error)
        }
        isPerformingMeetingAction = false
    }

    func reloadOutputSources() async {
        actionError = nil
        outputSources = await actions.reloadOutputSources()
        selectFirstOutputSourceIfNeeded()
        if outputSources.isEmpty {
            actionError =
                "No capturable meeting application is available. Open the meeting app or choose all Mac output."
        }
    }

    func selectRepository(_ url: URL) async {
        guard !isPerformingMeetingAction, pendingMeetingStart == nil else { return }
        let alias = url.lastPathComponent
        selectedRepositoryURL = url
        repositoryState = .inspecting(alias)
        approvedSoftFindingIDs.removeAll()
        actionError = nil
        do {
            let review = try await actions.inspectRepository(url)
            repositoryState = .review(review)
            presentedSheet = .repositoryReview
        } catch {
            selectedRepositoryURL = nil
            repositoryState = .blocked(alias: alias, message: safeMessage(for: error))
            actionError = safeMessage(for: error)
            presentedSheet = .meetingSetup
        }
    }

    func sealRepository() async {
        guard !isPerformingMeetingAction, pendingMeetingStart == nil else { return }
        guard let url = selectedRepositoryURL,
            case .review(let review) = repositoryState,
            Set(review.softFindings.map(\.id)).isSubset(of: approvedSoftFindingIDs)
        else { return }

        repositoryState = .sealing(review)
        actionError = nil
        do {
            let sealed = try await actions.sealRepository(
                RepositorySealRequest(
                    repositoryURL: url,
                    approvedSoftFindingIDs: approvedSoftFindingIDs
                )
            )
            repositoryState = .sealed(sealed)
            selectedDomainSkillName = nil
            meetingConsent.openAIProcessingConfirmed = false
            selectedRepositoryURL = nil
            approvedSoftFindingIDs.removeAll()
            presentedSheet = .meetingSetup
        } catch {
            repositoryState = .review(review)
            actionError = safeMessage(for: error)
        }
    }

    func cancelRepositoryReview() {
        guard !isPerformingMeetingAction, pendingMeetingStart == nil else { return }
        selectedRepositoryURL = nil
        repositoryState = .none
        selectedDomainSkillName = nil
        approvedSoftFindingIDs.removeAll()
        actionError = nil
        presentedSheet = .meetingSetup
    }

    func removeRepository() async {
        guard !isPerformingMeetingAction, pendingMeetingStart == nil else { return }
        let snapshotID: UUID?
        if case .sealed(let summary) = repositoryState {
            snapshotID = summary.snapshotID
        } else {
            snapshotID = nil
        }
        if let snapshotID {
            do {
                try await actions.discardRepositorySnapshot(snapshotID)
            } catch {
                actionError = safeMessage(for: error)
                return
            }
        }
        repositoryState = .none
        selectedDomainSkillName = nil
        meetingConsent.openAIProcessingConfirmed = false
        selectedRepositoryURL = nil
        approvedSoftFindingIDs.removeAll()
    }

    private func currentMeetingStartRequest() -> MeetingStartRequest {
        let sealedSnapshotID: UUID?
        if case .sealed(let summary) = repositoryState {
            sealedSnapshotID = summary.snapshotID
        } else {
            sealedSnapshotID = nil
        }
        return MeetingStartRequest(
            consentConfirmed: meetingConsent.isComplete,
            microphoneEnabled: microphoneEnabled,
            outputEnabled: outputEnabled,
            outputScope: outputScope,
            outputSourceID: outputScope == .meetingApplication ? selectedOutputSourceID : nil,
            sealedSnapshotID: sealedSnapshotID,
            selectedDomainSkillName: selectedDomainSkillName,
            soleNearbySpeakerConfirmed: microphoneEnabled
                && meetingConsent.soleNearbySpeakerConfirmed
        )
    }

    func startMeeting() async {
        guard canStart, pendingMeetingStart == nil else { return }
        isPerformingMeetingAction = true
        ignoresSessionEvents = true
        actionError = nil
        let request = currentMeetingStartRequest()
        let attemptID = UUID()
        let startTask = Task {
            try await actions.startMeeting(request)
        }
        pendingMeetingStart = PendingMeetingStart(
            id: attemptID,
            request: request,
            task: startTask
        )
        // Capture can become live while the runtime is still finishing Start. Keep the visible
        // capture indicator conservative until success or verified cleanup returns.
        isCaptureActive = request.microphoneEnabled || request.outputEnabled
        statusDetail = "Starting only the capture sources you approved."

        let result = await withTaskCancellationHandler {
            await startTask.result
        } onCancel: {
            startTask.cancel()
        }
        let mayCommit =
            !Task.isCancelled
            && pendingMeetingStart?.id == attemptID
            && pendingMeetingStart?.request == request
            && currentMeetingStartRequest() == request
            && setupBlockers.isEmpty
        if pendingMeetingStart?.id == attemptID {
            pendingMeetingStart = nil
        }

        guard mayCommit else {
            await finishRevokedMeetingStart(request: request, result: result)
            isPerformingMeetingAction = false
            return
        }

        do {
            try result.get()
            activeStartRequest = request
            ignoresSessionEvents = false
            isCaptureActive = request.microphoneEnabled || request.outputEnabled
            hasIncompleteAudioTeardown = false
            phase = .listening
            statusDetail = "Listening only to the capture sources you approved."
            presentedSheet = nil
        } catch {
            ignoresSessionEvents = true
            meetingConsent.captureScopeConfirmed = false
            if Self.isAudioTeardownFailure(error) {
                enterIncompleteAudioTeardown()
            } else {
                isCaptureActive = false
                phase = .permissionRequired
                statusDetail = "Meeting did not start. Review setup and try again."
            }
            actionError = safeMessage(for: error)
        }
        isPerformingMeetingAction = false
    }

    func pause() async {
        guard canPause else { return }
        isPerformingMeetingAction = true
        actionError = nil
        do {
            try await actions.pauseMeeting()
            isCaptureActive = false
            hasIncompleteAudioTeardown = false
            phase = .paused
            statusDetail = "Capture and coaching are paused."
        } catch {
            actionError = safeMessage(for: error)
            if Self.isAudioTeardownFailure(error) {
                enterIncompleteAudioTeardown()
            }
        }
        isPerformingMeetingAction = false
    }

    func resume() async {
        guard !hasIncompleteAudioTeardown, phase == .paused else { return }
        isPerformingMeetingAction = true
        actionError = nil
        // Resume can reactivate hardware before the runtime call returns. Keep the red
        // indicator conservative until the result proves capture never became active.
        isCaptureActive = microphoneEnabled || outputEnabled
        do {
            try await actions.resumeMeeting()
            isCaptureActive = microphoneEnabled || outputEnabled
            hasIncompleteAudioTeardown = false
            phase = .listening
            statusDetail = "Listening only to the capture sources you approved."
        } catch {
            actionError = safeMessage(for: error)
            if Self.isAudioTeardownFailure(error) {
                enterIncompleteAudioTeardown()
            } else {
                isCaptureActive = false
            }
        }
        isPerformingMeetingAction = false
    }

    func stop() async {
        guard phase != .idle && phase != .ended else { return }
        activeStartRequest = nil
        isPerformingMeetingAction = true
        isStopping = true
        ignoresSessionEvents = true
        actionError = nil

        // Clear meeting content before waiting for service cleanup. Stop is the privacy boundary.
        transcript.removeAll(keepingCapacity: false)
        quickSuggestion = nil
        deepSuggestion = nil
        manualQuestion = ""
        brownouts.removeAll()
        statusDetail = "Meeting content cleared from the interface."

        do {
            try await actions.stopMeeting()
            if case .sealed(let summary) = repositoryState {
                try await actions.discardRepositorySnapshot(summary.snapshotID)
            }
            isCaptureActive = false
            hasIncompleteAudioTeardown = false
            resetPerMeetingSetupState()
            phase = .ended
            statusDetail = "Meeting data and its private repository snapshot were cleared."
        } catch {
            actionError =
                "Local content was cleared, but background cleanup needs attention: \(safeMessage(for: error))"
            if Self.isAudioTeardownFailure(error) {
                enterIncompleteAudioTeardown()
            } else {
                isCaptureActive = false
                hasIncompleteAudioTeardown = false
                resetPerMeetingSetupState()
                phase = .ended
                statusDetail = "Meeting content was cleared; journaled cleanup will retry on launch."
            }
        }
        clearMeetingContent()
        isStopping = false
        isPerformingMeetingAction = false
    }

    func coachCurrentTurn() async {
        guard canCoachCurrentTurn else { return }
        await requestCoaching(question: nil)
    }

    func coachManualQuestion() async {
        let question = manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        await requestCoaching(question: question)
    }

    func dismissActionError() {
        actionError = nil
    }

    private static func isAudioTeardownFailure(_ error: any Error) -> Bool {
        if let failure = error as? MeetingSessionFailure,
            case .captureTeardownFailed = failure
        {
            return true
        }
        if let actionError = error as? PaceNoteActionError,
            case .audioTeardown = actionError
        {
            return true
        }
        return false
    }

    private func enterIncompleteAudioTeardown() {
        hasIncompleteAudioTeardown = true
        // Teardown failure means capture state is unknown. Keep the red indicator on until a
        // later Stop succeeds and proves every owned audio handle is gone.
        isCaptureActive = true
        phase = .brownout
        presentedSheet = nil
        statusDetail =
            "Capture may still be active because teardown is incomplete. Retry Stop before continuing."
    }

    private func invalidatePendingMeetingStart() {
        guard let pendingMeetingStart else { return }
        self.pendingMeetingStart = nil
        pendingMeetingStart.task.cancel()
        ignoresSessionEvents = true
        clearMeetingContent()
        statusDetail = "Canceling Start and verifying capture cleanup."
    }

    private func meetingStartConfigurationDidChange() {
        invalidatePendingMeetingStart()

        guard consentRevocationStopTask == nil,
            let activeStartRequest,
            activeStartRequest != currentMeetingStartRequest()
        else { return }

        self.activeStartRequest = nil
        ignoresSessionEvents = true
        statusDetail = "Consent or capture scope changed. Stopping capture now."
        consentRevocationStopTask = Task { [weak self] in
            guard let self else { return }
            await self.stop()
            self.consentRevocationStopTask = nil
        }
    }

    private func finishRevokedMeetingStart(
        request: MeetingStartRequest,
        result: Result<Void, any Error>
    ) async {
        ignoresSessionEvents = true
        clearMeetingContent()

        do {
            try await actions.stopMeeting()
        } catch {
            if Self.isAudioTeardownFailure(error) {
                actionError =
                    "Start was revoked, but capture teardown could not be verified: \(safeMessage(for: error))"
                enterIncompleteAudioTeardown()
                return
            }
            isCaptureActive = false
            hasIncompleteAudioTeardown = false
            actionError =
                "Capture stopped, but private meeting cleanup needs attention: \(safeMessage(for: error))"
            resetPerMeetingSetupState()
            refreshAfterRevokedStart(
                detail: "The revoked Start was stopped; journaled cleanup will retry on launch."
            )
            return
        }

        isCaptureActive = false
        hasIncompleteAudioTeardown = false
        if let snapshotID = request.sealedSnapshotID {
            do {
                try await actions.discardRepositorySnapshot(snapshotID)
            } catch {
                actionError =
                    "Capture stopped, but private snapshot cleanup needs attention: \(safeMessage(for: error))"
                resetPerMeetingSetupState()
                refreshAfterRevokedStart(
                    detail: "The revoked Start was stopped; snapshot cleanup will retry on launch."
                )
                return
            }
        }
        resetPerMeetingSetupState()
        let detail: String
        switch result {
        case .success:
            detail = "The revoked Start was stopped and its meeting data was cleared."
        case .failure:
            detail = "Start was canceled and its private meeting data was cleared."
        }
        refreshAfterRevokedStart(detail: detail)
    }

    private func refreshAfterRevokedStart(detail: String) {
        if codexState.isReady {
            phase = .ready
        } else {
            phase = .permissionRequired
        }
        statusDetail = detail
    }

    private func resetPerMeetingSetupState() {
        repositoryState = .none
        selectedRepositoryURL = nil
        approvedSoftFindingIDs.removeAll()
        selectedDomainSkillName = nil
        meetingConsent = MeetingConsent()
    }

    func repositorySelectionFailed() {
        actionError = "The repository folder could not be selected. No repository access was granted."
    }

    func receiveTranscript(_ incomingSegments: [TranscriptSegment]) {
        guard !isStopping, !hasIncompleteAudioTeardown, phase != .idle, phase != .ended else {
            return
        }
        for segment in incomingSegments {
            if let index = transcript.firstIndex(where: { $0.id == segment.id }) {
                transcript[index] = segment
            } else {
                transcript.append(segment)
            }
        }
        transcript.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if transcript.count > 300 {
            transcript.removeFirst(transcript.count - 300)
        }
    }

    func receiveQuickSuggestion(_ card: SuggestionCard) {
        guard !isStopping, !hasIncompleteAudioTeardown, phase != .idle, phase != .ended,
            phase != .paused, card.stage == .quick || card.stage == .bridge
        else {
            return
        }
        if let existing = quickSuggestion, existing.identity == card.identity {
            return
        }
        quickSuggestion = card
        deepSuggestion = nil
        phase = .suggesting
        statusDetail =
            card.stage == .bridge
            ? "A safe bridge is ready while PaceNote checks deeper context." : "A quick response is ready."
    }

    func receiveVerifiedDeepSuggestion(_ card: SuggestionCard) {
        guard !isStopping, !hasIncompleteAudioTeardown, phase != .idle, phase != .ended,
            phase != .paused,
            card.stage == .deep,
            let quickSuggestion,
            quickSuggestion.identity == card.identity,
            deepSuggestion == nil
        else { return }
        deepSuggestion = card
        phase = .suggesting
        statusDetail = Self.deepSuggestionStatus(for: card.deepKind)
    }

    func updateBrownouts(_ reasons: Set<BrownoutReason>) {
        brownouts = reasons
        if hasIncompleteAudioTeardown {
            phase = .brownout
            statusDetail =
                "Capture may still be active because teardown is incomplete. Retry Stop before continuing."
            return
        }
        if reasons.isEmpty {
            if phase == .brownout { phase = .listening }
        } else if phase != .paused && phase != .ended {
            phase = .brownout
            statusDetail = "PaceNote is in a limited mode. Review the visible recovery guidance."
        }
    }

    private func requestCoaching(question: String?) async {
        guard canCoach else { return }
        isPerformingMeetingAction = true
        actionError = nil
        do {
            try await actions.coachCurrentTurn(question)
            if question != nil { manualQuestion = "" }
            phase = .thinking
            statusDetail = "Preparing a response. Existing suggestion cards remain unchanged."
        } catch {
            actionError = safeMessage(for: error)
        }
        isPerformingMeetingAction = false
    }

    private func receiveSessionEvent(_ event: MeetingSessionEvent) {
        guard !isStopping, !ignoresSessionEvents else { return }
        switch event {
        case .stateChanged(let state):
            brownouts = Set(state.brownouts.map(\.reason))
            if hasIncompleteAudioTeardown {
                isCaptureActive = true
                phase = .brownout
                statusDetail =
                    "Capture may still be active because teardown is incomplete. Retry Stop before continuing."
            } else {
                isCaptureActive = state.isRunning && !state.captureMode.enabledLanes.isEmpty
                phase = state.phase
                updateStatusDetail(for: state.phase)
            }
        case .transcriptUpserted(let segment):
            receiveTranscript([segment])
        case .transcriptRemoved(let id):
            transcript.removeAll { $0.id == id }
        case .transcriptsCleared:
            transcript.removeAll(keepingCapacity: false)
        case .suggestionsCleared(let identity):
            if let identity {
                if quickSuggestion?.identity == identity { quickSuggestion = nil }
                if deepSuggestion?.identity == identity { deepSuggestion = nil }
            } else {
                quickSuggestion = nil
                deepSuggestion = nil
            }
        case .suggestionUpserted(let card):
            if card.stage == .deep {
                receiveVerifiedDeepSuggestion(card)
            } else {
                receiveQuickSuggestion(card)
            }
        case .brownoutActivated(let brownout):
            brownouts.insert(brownout.reason)
        case .brownoutCleared(let brownout):
            brownouts.remove(brownout.reason)
        case .failed(let failure):
            if failure == .systemAudioPermissionDenied {
                systemAudioPermission = .denied
            }
            actionError = failure.errorDescription ?? "The meeting session could not continue."
            if Self.isAudioTeardownFailure(failure) {
                enterIncompleteAudioTeardown()
            }
        }
    }

    private func clearMeetingContent() {
        transcript.removeAll(keepingCapacity: false)
        quickSuggestion = nil
        deepSuggestion = nil
        manualQuestion = ""
        brownouts.removeAll()
    }

    private func updateStatusDetail(for phase: MeetingPhase) {
        switch phase {
        case .idle:
            statusDetail = "Complete setup before listening."
        case .permissionRequired:
            statusDetail = "Complete capture and ChatGPT setup before listening."
        case .ready:
            statusDetail = "Ready to start the consented meeting."
        case .listening:
            statusDetail = "Listening only to the capture sources you approved."
        case .candidateQuestion:
            statusDetail = "A possible question was detected."
        case .thinking:
            statusDetail = "Preparing a response."
        case .suggesting:
            statusDetail =
                deepSuggestion.map { Self.deepSuggestionStatus(for: $0.deepKind) }
                ?? "A quick response is ready while deeper context is checked."
        case .paused:
            statusDetail = "Capture and coaching are paused."
        case .brownout:
            statusDetail = "PaceNote is in a limited mode. Review the visible recovery guidance."
        case .ended:
            statusDetail = "Meeting content was cleared."
        }
    }

    private func selectFirstOutputSourceIfNeeded() {
        guard outputScope == .meetingApplication else { return }
        if let selectedOutputSourceID,
            outputSources.contains(where: { $0.id == selectedOutputSourceID })
        {
            return
        }
        selectedOutputSourceID = outputSources.first?.id
    }

    private static func deepSuggestionStatus(for kind: DeepDraftKind?) -> String {
        switch kind {
        case .answer:
            "A repository evidence-checked response is ready."
        case .generalAnswer:
            "General guidance is ready. Verify it before speaking."
        case .clarification:
            "A safe clarification is ready."
        case .abstention:
            "PaceNote could not verify an answer safely."
        case nil:
            "A Deep response is ready. Review it before speaking."
        }
    }

    private var isMeetingActive: Bool {
        switch phase {
        case .listening, .candidateQuestion, .thinking, .suggesting, .paused, .brownout: true
        default: false
        }
    }

    private func refreshReadyPhase() {
        guard !hasIncompleteAudioTeardown else { return }
        guard phase == .idle || phase == .permissionRequired || phase == .ready else { return }
        if codexState.isReady {
            phase = .ready
            statusDetail = "Ready to configure a consented meeting."
        } else {
            phase = .permissionRequired
            statusDetail = "Complete capture and ChatGPT setup before listening."
        }
    }

    private func safeMessage(for error: any Error) -> String {
        if let actionError = error as? PaceNoteActionError,
            let message = actionError.errorDescription
        {
            return message
        }
        if let groundingError = error as? GroundingError,
            let message = groundingError.errorDescription
        {
            return message
        }
        if let sessionError = error as? MeetingSessionFailure,
            let message = sessionError.errorDescription
        {
            return message
        }
        return "The local operation could not be completed."
    }
}

#if DEBUG
    extension MeetingViewModel {
        static var previewListening: MeetingViewModel {
            let model = MeetingViewModel(hasCompletedFirstRun: true)
            model.didBootstrap = true
            model.phase = .suggesting
            model.statusDetail = "A repository-grounded response is ready."
            model.microphonePermission = .authorized
            model.systemAudioPermission = .authorized
            model.codexState = .ready(
                CodexAccountSummary(
                    accountLabel: "Preview account",
                    planLabel: "ChatGPT Pro",
                    modelCount: 6
                )
            )
            model.outputSources = [
                OutputSourceOption(id: "preview-meet", name: "Google Chrome", detail: "Google Meet")
            ]
            model.selectedOutputSourceID = "preview-meet"
            model.repositoryState = .sealed(
                SealedRepositorySummary(
                    snapshotID: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
                    repositoryAlias: "PaceNote",
                    branch: "main",
                    revision: "9d31b2a",
                    includedFileCount: 84,
                    instructionFileCount: 1,
                    domainSkills: [DomainSkillOption(name: "incident-response")]
                )
            )
            model.transcript = [
                TranscriptSegment(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
                    source: .them,
                    text: "How does the app prevent the model from reading credentials in the repository?",
                    startedAt: 1,
                    endedAt: 5,
                    isFinal: true,
                    confidence: 0.96
                ),
                TranscriptSegment(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
                    source: .you,
                    text: "There are two separate safeguards.",
                    startedAt: 6,
                    endedAt: 8,
                    isFinal: true,
                    confidence: 0.98
                ),
            ]
            let identity = TurnIdentity(
                meetingID: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
                turnID: UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID(),
                generation: 3
            )
            model.quickSuggestion = SuggestionCard(
                id: UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID(),
                identity: identity,
                stage: .bridge,
                text: "Let me think through that carefully for a second.",
                confidence: 1
            )
            model.deepSuggestion = SuggestionCard(
                id: UUID(uuidString: "77777777-7777-7777-7777-777777777777") ?? UUID(),
                identity: identity,
                stage: .deep,
                text:
                    "First, credential-like paths are excluded locally. Then Codex receives only a sealed read-only copy, never the live repository.",
                confidence: 0.93,
                evidence: [
                    EvidenceReference(
                        repoAlias: "PaceNote",
                        relativePath: "Sources/PaceNoteCore/Grounding/GroundingManager.swift",
                        startLine: 35,
                        endLine: 46,
                        fileHash: String(repeating: "a", count: 64),
                        claim: "The grounding manager creates a private snapshot before repository use."
                    )
                ],
                deepKind: .answer
            )
            return model
        }

        static var previewBrownout: MeetingViewModel {
            let model = previewListening
            model.updateBrownouts([.deepLimited, .speakerUncertain])
            return model
        }

        static var previewSetup: MeetingViewModel {
            let model = MeetingViewModel(hasCompletedFirstRun: true)
            model.didBootstrap = true
            model.phase = .ready
            model.statusDetail = "Ready to configure a consented meeting."
            model.microphonePermission = .authorized
            model.systemAudioPermission = .authorized
            model.codexState = .ready(
                CodexAccountSummary(
                    accountLabel: "Preview account",
                    planLabel: "ChatGPT Pro",
                    modelCount: 6
                )
            )
            model.outputSources = [
                OutputSourceOption(id: "preview-meet", name: "Google Chrome", detail: "Google Meet"),
                OutputSourceOption(id: "preview-zoom", name: "zoom.us"),
            ]
            model.selectedOutputSourceID = "preview-meet"
            model.presentedSheet = nil
            return model
        }

        static var previewRepositoryReview: MeetingViewModel {
            let model = previewSetup
            model.repositoryState = .review(
                GroundingReviewSummary(
                    repositoryAlias: "PaceNote",
                    branch: "main",
                    revision: "9d31b2a",
                    includedFileCount: 84,
                    hardExclusions: [
                        GroundingReviewFinding(
                            id: "hard-env",
                            relativePath: ".env.local",
                            detail: "Environment files are always excluded."
                        )
                    ],
                    softFindings: [
                        GroundingReviewFinding(
                            id: "soft-fixture",
                            relativePath: "Tests/Fixtures/sample-token.json",
                            detail: "Filename matched a credential-fixture rule."
                        )
                    ],
                    instructionFiles: ["AGENTS.md"]
                )
            )
            return model
        }
    }
#endif
