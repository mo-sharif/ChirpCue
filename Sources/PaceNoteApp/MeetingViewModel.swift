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

    var isComplete: Bool {
        participantPermission && captureScopeConfirmed && openAIProcessingConfirmed
    }
}

struct MeetingStartRequest: Sendable {
    let consentConfirmed: Bool
    let microphoneEnabled: Bool
    let outputEnabled: Bool
    let outputScope: OutputCaptureScope
    let outputSourceID: String?
    let sealedSnapshotID: UUID?
    let selectedDomainSkillName: String?

    init(
        consentConfirmed: Bool,
        microphoneEnabled: Bool,
        outputEnabled: Bool,
        outputScope: OutputCaptureScope,
        outputSourceID: String?,
        sealedSnapshotID: UUID?,
        selectedDomainSkillName: String?
    ) {
        self.consentConfirmed = consentConfirmed
        self.microphoneEnabled = microphoneEnabled
        self.outputEnabled = outputEnabled
        self.outputScope = outputScope
        self.outputSourceID = outputSourceID
        self.sealedSnapshotID = sealedSnapshotID
        self.selectedDomainSkillName = selectedDomainSkillName
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
    case safeMessage(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotConnected:
            "PaceNote's local service is not connected yet."
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

    static let unwired = MeetingActions(
        sessionEvents: { AsyncStream { $0.finish() } },
        checkEnvironment: {
            PaceNoteEnvironmentSnapshot(
                microphonePermission: .unavailable("Local capture service is not connected."),
                systemAudioPermission: .unavailable("Local capture service is not connected."),
                codex: .unavailable("Codex app-server is not connected."),
                outputSources: []
            )
        },
        requestCapturePermission: { _ in
            .unavailable("Local capture service is not connected.")
        },
        beginCodexSignIn: {
            .unavailable("Codex app-server is not connected.")
        },
        forgetCodexProfile: { throw PaceNoteActionError.serviceNotConnected },
        reloadOutputSources: { [] },
        inspectRepository: { _ in throw PaceNoteActionError.serviceNotConnected },
        sealRepository: { _ in throw PaceNoteActionError.serviceNotConnected },
        discardRepositorySnapshot: { _ in throw PaceNoteActionError.serviceNotConnected },
        startMeeting: { _ in throw PaceNoteActionError.serviceNotConnected },
        pauseMeeting: { throw PaceNoteActionError.serviceNotConnected },
        resumeMeeting: { throw PaceNoteActionError.serviceNotConnected },
        stopMeeting: { throw PaceNoteActionError.serviceNotConnected },
        coachCurrentTurn: { _ in throw PaceNoteActionError.serviceNotConnected }
    )
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
            if oldValue != microphoneEnabled { meetingConsent.captureScopeConfirmed = false }
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
    private(set) var actionError: String?
    var presentedSheet: PaceNoteSheet?
    var firstRunAcknowledgement = FirstRunAcknowledgement()
    private(set) var hasCompletedFirstRun: Bool
    var meetingConsent = MeetingConsent()
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
        phase == .idle || phase == .ready || phase == .ended || phase == .permissionRequired
    }

    var canStart: Bool {
        setupBlockers.isEmpty && !isPerformingMeetingAction
    }

    var canCoach: Bool {
        codexState.isReady && !isPerformingMeetingAction && isMeetingActive
    }

    var canCoachCurrentTurn: Bool {
        canCoach && outputEnabled
    }

    var canForgetCodexProfile: Bool {
        guard !isMeetingActive else { return false }
        switch codexState {
        case .notChecked, .checking, .signedOut:
            return false
        case .authenticationExpired, .ready, .limited, .unavailable:
            return true
        }
    }

    var canPause: Bool {
        switch phase {
        case .listening, .candidateQuestion, .thinking, .suggesting, .brownout: true
        default: false
        }
    }

    var setupBlockers: [String] {
        var blockers: [String] = []
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

    func presentPrivacyDetails() {
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
        actionError = nil
        codexState = .checking
        codexState = await actions.beginCodexSignIn()
        refreshReadyPhase()
    }

    func forgetCodexProfile() async {
        guard !isMeetingActive else {
            actionError = "Stop the current meeting before forgetting the Codex profile."
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
        selectedRepositoryURL = nil
        repositoryState = .none
        selectedDomainSkillName = nil
        approvedSoftFindingIDs.removeAll()
        actionError = nil
        presentedSheet = .meetingSetup
    }

    func removeRepository() async {
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

    func startMeeting() async {
        guard canStart else { return }
        isPerformingMeetingAction = true
        actionError = nil
        let sealedSnapshotID: UUID?
        if case .sealed(let summary) = repositoryState {
            sealedSnapshotID = summary.snapshotID
        } else {
            sealedSnapshotID = nil
        }
        do {
            try await actions.startMeeting(
                MeetingStartRequest(
                    consentConfirmed: meetingConsent.isComplete,
                    microphoneEnabled: microphoneEnabled,
                    outputEnabled: outputEnabled,
                    outputScope: outputScope,
                    outputSourceID: outputScope == .meetingApplication ? selectedOutputSourceID : nil,
                    sealedSnapshotID: sealedSnapshotID,
                    selectedDomainSkillName: selectedDomainSkillName
                )
            )
            isCaptureActive = microphoneEnabled || outputEnabled
            phase = .listening
            statusDetail = "Listening only to the capture sources you approved."
            presentedSheet = nil
        } catch {
            phase = .permissionRequired
            actionError = safeMessage(for: error)
            statusDetail = "Meeting did not start. Review setup and try again."
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
            phase = .paused
            statusDetail = "Capture and coaching are paused."
        } catch {
            actionError = safeMessage(for: error)
        }
        isPerformingMeetingAction = false
    }

    func resume() async {
        guard phase == .paused else { return }
        isPerformingMeetingAction = true
        actionError = nil
        do {
            try await actions.resumeMeeting()
            isCaptureActive = microphoneEnabled || outputEnabled
            phase = .listening
            statusDetail = "Listening only to the capture sources you approved."
        } catch {
            actionError = safeMessage(for: error)
        }
        isPerformingMeetingAction = false
    }

    func stop() async {
        guard phase != .idle && phase != .ended else { return }
        isPerformingMeetingAction = true
        actionError = nil

        // Clear meeting content before waiting for service cleanup. Stop is the privacy boundary.
        transcript.removeAll(keepingCapacity: false)
        quickSuggestion = nil
        deepSuggestion = nil
        manualQuestion = ""
        brownouts.removeAll()
        isCaptureActive = false
        phase = .ended
        statusDetail = "Meeting content cleared from the interface."

        do {
            try await actions.stopMeeting()
            if case .sealed(let summary) = repositoryState {
                try await actions.discardRepositorySnapshot(summary.snapshotID)
            }
            repositoryState = .none
            meetingConsent = MeetingConsent()
            statusDetail = "Meeting data and its private repository snapshot were cleared."
        } catch {
            actionError =
                "Local content was cleared, but background cleanup needs attention: \(safeMessage(for: error))"
        }
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

    func repositorySelectionFailed() {
        actionError = "The repository folder could not be selected. No repository access was granted."
    }

    func receiveTranscript(_ incomingSegments: [TranscriptSegment]) {
        guard phase != .idle && phase != .ended else { return }
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
        guard card.stage == .quick || card.stage == .bridge else { return }
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
        guard card.stage == .deep,
            let quickSuggestion,
            quickSuggestion.identity == card.identity,
            deepSuggestion == nil
        else { return }
        deepSuggestion = card
        phase = .suggesting
        statusDetail = "A repository-grounded response is ready."
    }

    func updateBrownouts(_ reasons: Set<BrownoutReason>) {
        brownouts = reasons
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
        switch event {
        case .stateChanged(let state):
            isCaptureActive = state.isRunning && !state.captureMode.enabledLanes.isEmpty
            phase = state.phase
            brownouts = Set(state.brownouts.map(\.reason))
            updateStatusDetail(for: state.phase)
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
        }
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
                deepSuggestion == nil
                ? "A quick response is ready while deeper context is checked."
                : "A repository-grounded response is ready."
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

    private var isMeetingActive: Bool {
        switch phase {
        case .listening, .candidateQuestion, .thinking, .suggesting, .paused, .brownout: true
        default: false
        }
    }

    private func refreshReadyPhase() {
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
                text: "There are two separate safeguards. Let me walk through the boundary.",
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
                ]
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
