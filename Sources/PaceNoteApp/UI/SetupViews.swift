import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FirstRunConsentView: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "waveform.and.person.filled")
                            .font(.system(size: 38))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Welcome to PaceNote")
                            .font(.largeTitle.weight(.semibold))
                        Text("A private, consent-first speaking coach for meetings on your Mac.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        FirstRunPrinciple(
                            systemImage: "record.circle",
                            title: "You start every capture",
                            detail:
                                "PaceNote never listens in the background before you explicitly start a meeting. A visible red status remains on while capture is active."
                        )
                        FirstRunPrinciple(
                            systemImage: "person.2.badge.gearshape",
                            title: "You are responsible for consent",
                            detail:
                                "Use PaceNote only when everyone has been appropriately informed and you have permission under the rules that apply to the meeting."
                        )
                        FirstRunPrinciple(
                            systemImage: "key.slash",
                            title: "ChatGPT subscription, no API key",
                            detail:
                                "PaceNote signs in to Codex with ChatGPT through an app-owned isolated Codex profile. It never asks for an OpenAI API key."
                        )
                        FirstRunPrinciple(
                            systemImage: "lock.shield",
                            title: "Ephemeral meeting data",
                            detail:
                                "Audio is not intentionally written to disk. Transcript and meeting suggestions are cleared when you stop. Repository grounding uses a private, read-only sealed snapshot."
                        )
                        FirstRunPrinciple(
                            systemImage: "person.wave.2",
                            title: "Suggestions stay suggestions",
                            detail:
                                "PaceNote never speaks, sends, pastes, or responds for you. You decide whether to say anything."
                        )
                    }

                    GroupBox("Before continuing") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(
                                "I understand PaceNote captures only after I manually start a meeting.",
                                isOn: $model.firstRunAcknowledgement.manualStartOnly
                            )
                            .accessibilityLabel(
                                "I understand PaceNote captures only after I manually start a meeting."
                            )
                            .accessibilityIdentifier("first-run.manual-start")
                            .paceNoteAssistiveControl(
                                label:
                                    "I understand PaceNote captures only after I manually start a meeting.",
                                identifier: "first-run.manual-start",
                                role: .checkBox,
                                value: model.firstRunAcknowledgement.manualStartOnly
                            ) {
                                model.firstRunAcknowledgement.manualStartOnly.toggle()
                            }
                            Toggle(
                                "I will use PaceNote only with appropriate participant permission.",
                                isOn: $model.firstRunAcknowledgement.consentResponsibility
                            )
                            .accessibilityLabel(
                                "I will use PaceNote only with appropriate participant permission."
                            )
                            .accessibilityIdentifier("first-run.participant-permission")
                            .paceNoteAssistiveControl(
                                label:
                                    "I will use PaceNote only with appropriate participant permission.",
                                identifier: "first-run.participant-permission",
                                role: .checkBox,
                                value: model.firstRunAcknowledgement.consentResponsibility
                            ) {
                                model.firstRunAcknowledgement.consentResponsibility.toggle()
                            }
                            Toggle(
                                "I understand transcript text and selected repository excerpts are processed by OpenAI through my signed-in ChatGPT account.",
                                isOn: $model.firstRunAcknowledgement.openAIProcessing
                            )
                            .accessibilityLabel(
                                "I understand transcript text and selected repository excerpts are processed by OpenAI through my signed-in ChatGPT account."
                            )
                            .accessibilityIdentifier("first-run.openai-processing")
                            .paceNoteAssistiveControl(
                                label:
                                    "I understand transcript text and selected repository excerpts are processed by OpenAI through my signed-in ChatGPT account.",
                                identifier: "first-run.openai-processing",
                                role: .checkBox,
                                value: model.firstRunAcknowledgement.openAIProcessing
                            ) {
                                model.firstRunAcknowledgement.openAIProcessing.toggle()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(4)
                    }
                }
                .padding(28)
            }

            Divider()
            HStack {
                Button("Not Now") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Not Now")
                .accessibilityIdentifier("first-run.not-now")
                .paceNoteAssistiveControl(
                    label: "Not Now",
                    identifier: "first-run.not-now"
                ) {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("Continue") {
                    model.completeFirstRun()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.firstRunAcknowledgement.isComplete)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Continue")
                .accessibilityHint("Completes the privacy introduction without requesting capture permission")
                .accessibilityIdentifier("first-run.continue")
                .paceNoteAssistiveControl(
                    label: "Continue",
                    identifier: "first-run.continue",
                    isEnabled: model.firstRunAcknowledgement.isComplete
                ) {
                    model.completeFirstRun()
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(width: 660, height: 720)
        .interactiveDismissDisabled()
    }
}

private struct FirstRunPrinciple: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct MeetingSetupView: View {
    @Bindable var model: MeetingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingRepository = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up this meeting")
                        .font(.title2.weight(.semibold))
                    Text("Nothing is captured until setup succeeds and you select Start Meeting.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshEnvironment() }
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBootstrapping || model.isPerformingMeetingAction)
                .accessibilityLabel("Recheck Setup")
                .accessibilityIdentifier("meeting-setup.recheck")
                .paceNoteAssistiveControl(
                    label: "Recheck Setup",
                    identifier: "meeting-setup.recheck",
                    isEnabled: !model.isBootstrapping && !model.isPerformingMeetingAction
                ) {
                    Task { await model.refreshEnvironment() }
                }
            }
            .padding(22)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CaptureSetupSection(model: model)
                    CodexSetupSection(model: model)
                    RepositorySetupSection(
                        model: model,
                        chooseRepository: { isChoosingRepository = true }
                    )
                    MeetingConsentSection(model: model)

                    if !model.setupBlockers.isEmpty {
                        GroupBox("Required before starting") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(model.setupBlockers, id: \.self) { blocker in
                                    Label(blocker, systemImage: "circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                        .accessibilityIdentifier("meeting-setup.blockers")
                    }

                    if let actionError = model.actionError {
                        Label(actionError, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Button("Privacy Details") {
                    model.presentPrivacyDetails()
                }
                .accessibilityLabel("Privacy Details")
                .accessibilityIdentifier("meeting-setup.privacy")
                .paceNoteAssistiveControl(
                    label: "Privacy Details",
                    identifier: "meeting-setup.privacy"
                ) {
                    model.presentPrivacyDetails()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityLabel("Cancel Meeting Setup")
                .accessibilityIdentifier("meeting-setup.cancel")
                .paceNoteAssistiveControl(
                    label: "Cancel Meeting Setup",
                    identifier: "meeting-setup.cancel"
                ) {
                    dismiss()
                }
                Button("Start Meeting") {
                    Task { await model.startMeeting() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start Meeting")
                .accessibilityIdentifier("meeting-setup.start")
                .paceNoteAssistiveControl(
                    label: "Start Meeting",
                    identifier: "meeting-setup.start",
                    isEnabled: model.canStart
                ) {
                    Task { await model.startMeeting() }
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(width: 720)
        .frame(minHeight: 720)
        .fileImporter(
            isPresented: $isChoosingRepository,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.selectRepository(url) }
            case .failure:
                model.repositorySelectionFailed()
            }
        }
        .interactiveDismissDisabled(model.isPerformingMeetingAction || model.repositoryState.isPending)
    }
}

private struct CaptureSetupSection: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        GroupBox("Capture") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Toggle("Microphone", isOn: $model.microphoneEnabled)
                        .toggleStyle(.switch)
                        .frame(width: 150, alignment: .leading)
                        .accessibilityLabel("Microphone")
                        .accessibilityIdentifier("meeting-setup.microphone")
                        .paceNoteAssistiveControl(
                            label: "Microphone",
                            identifier: "meeting-setup.microphone",
                            role: .checkBox,
                            value: model.microphoneEnabled
                        ) {
                            model.microphoneEnabled.toggle()
                        }
                    PermissionSetupStatus(
                        state: model.microphonePermission,
                        requestTitle: "Request Microphone Access",
                        accessibilityIdentifier: "meeting-setup.request-microphone"
                    ) {
                        Task { await model.requestPermission(.microphone) }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Toggle("Meeting output", isOn: $model.outputEnabled)
                        .toggleStyle(.switch)
                        .frame(width: 150, alignment: .leading)
                        .accessibilityLabel("Meeting Output")
                        .accessibilityIdentifier("meeting-setup.output")
                        .paceNoteAssistiveControl(
                            label: "Meeting Output",
                            identifier: "meeting-setup.output",
                            role: .checkBox,
                            value: model.outputEnabled
                        ) {
                            model.outputEnabled.toggle()
                        }
                    PermissionSetupStatus(
                        state: model.systemAudioPermission,
                        requestTitle: "Request System Audio Access",
                        accessibilityIdentifier: "meeting-setup.request-system-audio"
                    ) {
                        Task { await model.requestPermission(.systemAudio) }
                    }
                }

                if model.outputEnabled {
                    Divider()
                    Picker("Output scope", selection: $model.outputScope) {
                        ForEach(OutputCaptureScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Output Scope")
                    .accessibilityIdentifier("meeting-setup.output-scope")
                    Text(model.outputScope.explanation)
                        .font(.caption)
                        .foregroundStyle(model.outputScope == .allSystemAudio ? .orange : .secondary)

                    if model.outputScope == .meetingApplication {
                        HStack {
                            Picker("Meeting app", selection: $model.selectedOutputSourceID) {
                                Text("Choose an app").tag(String?.none)
                                ForEach(model.outputSources) { source in
                                    Text(source.name).tag(Optional(source.id))
                                }
                            }
                            .accessibilityLabel("Meeting App")
                            .accessibilityIdentifier("meeting-setup.output-app")
                            Button {
                                Task { await model.reloadOutputSources() }
                            } label: {
                                Label("Reload Apps", systemImage: "arrow.clockwise")
                            }
                            .accessibilityLabel("Reload Meeting Apps")
                            .accessibilityIdentifier("meeting-setup.reload-output-sources")
                            .paceNoteAssistiveControl(
                                label: "Reload Meeting Apps",
                                identifier: "meeting-setup.reload-output-sources"
                            ) {
                                Task { await model.reloadOutputSources() }
                            }
                        }
                    }
                }

                if !model.microphoneEnabled {
                    Label(
                        model.outputEnabled
                            ? "Meeting output still supports automatic question detection. Microphone capture is only needed to label your side of the conversation."
                            : "Capture is off. PaceNote will coach only questions you type manually.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(6)
        }
    }
}

private struct PermissionSetupStatus: View {
    let state: CapturePermissionState
    let requestTitle: String
    let accessibilityIdentifier: String
    let request: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(state.shortLabel, systemImage: state.isAuthorized ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(state.tint)
                if !state.isAuthorized {
                    Button(requestTitle, action: request)
                        .disabled(state == .requesting)
                        .accessibilityLabel(requestTitle)
                        .accessibilityIdentifier(accessibilityIdentifier)
                        .paceNoteAssistiveControl(
                            label: requestTitle,
                            identifier: accessibilityIdentifier,
                            isEnabled: state != .requesting,
                            action: request
                        )
                }
                if state == .requesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct CodexSetupSection: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        GroupBox("ChatGPT and Codex") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(
                        systemName: model.codexState.isReady
                            ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(model.codexState.tint)
                    .font(.title2)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.codexState.setupTitle)
                            .font(.headline)
                        Text(model.codexState.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.codexState.isReady {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Sign in to Codex with ChatGPT") {
                                Task { await model.signInToCodex() }
                            }
                            .disabled(model.codexState == .checking)
                            .accessibilityLabel("Sign in to Codex with ChatGPT")
                            .accessibilityIdentifier("meeting-setup.codex-sign-in")
                            .paceNoteAssistiveControl(
                                label: "Sign in to Codex with ChatGPT",
                                identifier: "meeting-setup.codex-sign-in",
                                isEnabled: model.codexState != .checking
                            ) {
                                Task { await model.signInToCodex() }
                            }
                            if model.canForgetCodexProfile {
                                Button("Forget Isolated Profile", role: .destructive) {
                                    Task { await model.forgetCodexProfile() }
                                }
                                .accessibilityLabel("Forget Isolated Codex Profile")
                                .accessibilityIdentifier("meeting-setup.codex-forget")
                                .paceNoteAssistiveControl(
                                    label: "Forget Isolated Codex Profile",
                                    identifier: "meeting-setup.codex-forget"
                                ) {
                                    Task { await model.forgetCodexProfile() }
                                }
                            }
                        }
                    }
                }
                Text(
                    "PaceNote uses an app-owned isolated Codex profile and your ChatGPT subscription. No API key or separate API billing is used. Connected confirms account and model access; final protocol, permission-profile, and skill-policy checks run before capture can begin."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}

private struct RepositorySetupSection: View {
    @Bindable var model: MeetingViewModel
    let chooseRepository: () -> Void

    var body: some View {
        GroupBox("Repository grounding (optional)") {
            VStack(alignment: .leading, spacing: 11) {
                switch model.repositoryState {
                case .none:
                    Text(
                        "Without a repository, PaceNote can offer general guidance but cannot make codebase-specific claims."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .inspecting(let alias):
                    Label("Inspecting \(alias) for a safe snapshot…", systemImage: "magnifyingglass")
                    ProgressView()
                case .review(let review):
                    Label("\(review.repositoryAlias) needs findings review", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                case .sealing(let review):
                    Label("Sealing a private snapshot of \(review.repositoryAlias)…", systemImage: "lock.shield")
                    ProgressView()
                case .sealed(let summary):
                    VStack(alignment: .leading, spacing: 3) {
                        Label("\(summary.repositoryAlias) is sealed", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("\(summary.branch) at \(summary.revision), \(summary.includedFileCount) included files")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if !summary.domainSkills.isEmpty {
                            Picker("Optional repository skill", selection: $model.selectedDomainSkillName) {
                                Text("Meeting coach only").tag(String?.none)
                                ForEach(summary.domainSkills) { skill in
                                    Text(skill.name).tag(Optional(skill.name))
                                }
                            }
                            .accessibilityLabel("Optional Repository Skill")
                            .accessibilityIdentifier("meeting-setup.repository-skill")
                            Text(
                                "At most one reviewed repository skill is explicitly loaded. Skills requiring network or write tools are rejected at preflight."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                case .blocked(let alias, let message):
                    VStack(alignment: .leading, spacing: 3) {
                        Label("\(alias) was not attached", systemImage: "xmark.shield.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button(model.repositoryName == nil ? "Choose Repository…" : "Choose Another…") {
                        chooseRepository()
                    }
                    .disabled(model.repositoryState.isPending)
                    .accessibilityLabel(
                        model.repositoryName == nil ? "Choose Repository" : "Choose Another Repository"
                    )
                    .accessibilityIdentifier("meeting-setup.choose-repository")
                    .paceNoteAssistiveControl(
                        label:
                            model.repositoryName == nil
                            ? "Choose Repository" : "Choose Another Repository",
                        identifier: "meeting-setup.choose-repository",
                        isEnabled: !model.repositoryState.isPending,
                        action: chooseRepository
                    )
                    if case .review = model.repositoryState {
                        Button("Review Findings") {
                            model.presentedSheet = .repositoryReview
                        }
                        .accessibilityLabel("Review Repository Findings")
                        .accessibilityIdentifier("meeting-setup.review-findings")
                        .paceNoteAssistiveControl(
                            label: "Review Repository Findings",
                            identifier: "meeting-setup.review-findings"
                        ) {
                            model.presentedSheet = .repositoryReview
                        }
                    }
                    if model.repositoryName != nil {
                        Button("Remove") {
                            Task { await model.removeRepository() }
                        }
                        .disabled(model.repositoryState.isPending)
                        .accessibilityLabel("Remove Repository")
                        .accessibilityIdentifier("meeting-setup.remove-repository")
                        .paceNoteAssistiveControl(
                            label: "Remove Repository",
                            identifier: "meeting-setup.remove-repository",
                            isEnabled: !model.repositoryState.isPending
                        ) {
                            Task { await model.removeRepository() }
                        }
                    }
                }

                Text(
                    "The model receives only a read-only sealed snapshot. Credentials, hard-excluded files, and the live working tree are never provided to Codex."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}

private struct MeetingConsentSection: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        GroupBox("Consent for this meeting") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle(
                    "I have permission to use live transcription and AI assistance in this meeting.",
                    isOn: $model.meetingConsent.participantPermission
                )
                .accessibilityLabel(
                    "I have permission to use live transcription and AI assistance in this meeting."
                )
                .accessibilityIdentifier("meeting-setup.consent-participant")
                .paceNoteAssistiveControl(
                    label:
                        "I have permission to use live transcription and AI assistance in this meeting.",
                    identifier: "meeting-setup.consent-participant",
                    role: .checkBox,
                    value: model.meetingConsent.participantPermission
                ) {
                    model.meetingConsent.participantPermission.toggle()
                }
                Toggle(
                    "I reviewed the enabled microphone, output source, and capture scope above.",
                    isOn: $model.meetingConsent.captureScopeConfirmed
                )
                .accessibilityLabel(
                    "I reviewed the enabled microphone, output source, and capture scope above."
                )
                .accessibilityIdentifier("meeting-setup.consent-capture-scope")
                .paceNoteAssistiveControl(
                    label:
                        "I reviewed the enabled microphone, output source, and capture scope above.",
                    identifier: "meeting-setup.consent-capture-scope",
                    role: .checkBox,
                    value: model.meetingConsent.captureScopeConfirmed
                ) {
                    model.meetingConsent.captureScopeConfirmed.toggle()
                }
                Toggle(
                    "I understand this meeting's transcript and any selected repository excerpts are processed by OpenAI through my ChatGPT account.",
                    isOn: $model.meetingConsent.openAIProcessingConfirmed
                )
                .accessibilityLabel(
                    "I understand this meeting's transcript and any selected repository excerpts are processed by OpenAI through my ChatGPT account."
                )
                .accessibilityIdentifier("meeting-setup.consent-openai-processing")
                .paceNoteAssistiveControl(
                    label:
                        "I understand this meeting's transcript and any selected repository excerpts are processed by OpenAI through my ChatGPT account.",
                    identifier: "meeting-setup.consent-openai-processing",
                    role: .checkBox,
                    value: model.meetingConsent.openAIProcessingConfirmed
                ) {
                    model.meetingConsent.openAIProcessingConfirmed.toggle()
                }
            }
            .toggleStyle(.checkbox)
            .padding(6)
        }
    }
}

@MainActor
struct RepositoryReviewView: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        Group {
            switch model.repositoryState {
            case .review(let review), .sealing(let review):
                RepositoryReviewContent(model: model, review: review)
            default:
                ContentUnavailableView(
                    "No review is available",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Return to meeting setup and select a repository.")
                )
                .frame(width: 620, height: 420)
            }
        }
        .interactiveDismissDisabled(model.repositoryState.isPending)
    }
}

private struct RepositoryReviewContent: View {
    @Bindable var model: MeetingViewModel
    let review: GroundingReviewSummary

    private var allSoftFindingsApproved: Bool {
        Set(review.softFindings.map(\.id)).isSubset(of: model.approvedSoftFindingIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review repository snapshot")
                    .font(.title2.weight(.semibold))
                Text("\(review.repositoryAlias) · \(review.branch) · \(review.revision)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text("Review paths only. File contents are not shown in this interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Included") {
                        Label("\(review.includedFileCount) regular, permitted files", systemImage: "doc.on.doc")
                            .padding(5)
                    }

                    GroupBox("Hard exclusions") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("These paths are always excluded and cannot be approved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if review.hardExclusions.isEmpty {
                                Label("No hard exclusions found", systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            } else {
                                ForEach(review.hardExclusions) { finding in
                                    FindingRow(finding: finding, tint: .red)
                                }
                            }
                        }
                        .padding(5)
                    }

                    GroupBox("Suspicious files requiring explicit approval") {
                        VStack(alignment: .leading, spacing: 11) {
                            if review.softFindings.isEmpty {
                                Label("No suspicious files require approval", systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            } else {
                                ForEach(review.softFindings) { finding in
                                    Toggle(
                                        isOn: Binding(
                                            get: { model.approvedSoftFindingIDs.contains(finding.id) },
                                            set: { isApproved in
                                                if isApproved {
                                                    model.approvedSoftFindingIDs.insert(finding.id)
                                                } else {
                                                    model.approvedSoftFindingIDs.remove(finding.id)
                                                }
                                            }
                                        )
                                    ) {
                                        FindingRow(finding: finding, tint: .orange)
                                    }
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel(
                                        "Approve suspicious file \(finding.relativePath). \(finding.detail)"
                                    )
                                    .accessibilityIdentifier("repository-review.approve-\(finding.id)")
                                    .paceNoteAssistiveControl(
                                        label:
                                            "Approve suspicious file \(finding.relativePath). \(finding.detail)",
                                        identifier: "repository-review.approve-\(finding.id)",
                                        role: .checkBox,
                                        value: model.approvedSoftFindingIDs.contains(finding.id)
                                    ) {
                                        if model.approvedSoftFindingIDs.contains(finding.id) {
                                            model.approvedSoftFindingIDs.remove(finding.id)
                                        } else {
                                            model.approvedSoftFindingIDs.insert(finding.id)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(5)
                    }

                    GroupBox("Instruction scope") {
                        VStack(alignment: .leading, spacing: 7) {
                            if review.instructionFiles.isEmpty {
                                Text("No AGENTS.md instruction files were found.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(review.instructionFiles, id: \.self) { path in
                                    Label(path, systemImage: "doc.badge.gearshape")
                                        .font(.caption.monospaced())
                                }
                            }
                            Text("PaceNote applies the effective path-scoped instruction chain for each cited file.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(5)
                    }

                    if let actionError = model.actionError {
                        Label(actionError, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Button("Cancel Repository") {
                    model.cancelRepositoryReview()
                }
                .disabled(model.repositoryState.isPending && !isReviewState)
                .accessibilityLabel("Cancel Repository")
                .accessibilityIdentifier("repository-review.cancel")
                .paceNoteAssistiveControl(
                    label: "Cancel Repository",
                    identifier: "repository-review.cancel",
                    isEnabled: !(model.repositoryState.isPending && !isReviewState)
                ) {
                    model.cancelRepositoryReview()
                }
                Spacer()
                if !allSoftFindingsApproved {
                    Text("Approve every suspicious file or cancel the repository.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Seal Approved Snapshot") {
                    Task { await model.sealRepository() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allSoftFindingsApproved || !isReviewState)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Seal Approved Snapshot")
                .accessibilityIdentifier("repository-review.seal")
                .paceNoteAssistiveControl(
                    label: "Seal Approved Snapshot",
                    identifier: "repository-review.seal",
                    isEnabled: allSoftFindingsApproved && isReviewState
                ) {
                    Task { await model.sealRepository() }
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(width: 680)
        .frame(minHeight: 680)
    }

    private var isReviewState: Bool {
        if case .review = model.repositoryState { return true }
        return false
    }
}

private struct FindingRow: View {
    let finding: GroundingReviewFinding
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(finding.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(tint)
            Text(finding.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PrivacyDetailsView: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Privacy and control", systemImage: "hand.raised.fill")
                        .font(.title2.weight(.semibold))
                    PrivacyDetailRow(
                        title: "Manual, visible capture",
                        detail:
                            "Capture begins only after per-meeting setup and a deliberate Start Meeting action. PaceNote does not support covert capture."
                    )
                    PrivacyDetailRow(
                        title: "Ephemeral meeting content",
                        detail:
                            "Audio is held in a short memory buffer and is not intentionally written to disk. Transcript and suggestions are cleared when you stop."
                    )
                    PrivacyDetailRow(
                        title: "OpenAI processing",
                        detail:
                            "Transcript text and selected repository excerpts leave this Mac for processing under the signed-in ChatGPT account's applicable OpenAI terms. PaceNote makes no zero-retention claim."
                    )
                    PrivacyDetailRow(
                        title: "Isolated subscription sign-in",
                        detail:
                            "PaceNote uses an app-owned isolated Codex profile authenticated with ChatGPT. It does not request, store, or bill an OpenAI API key."
                    )
                    PrivacyDetailRow(
                        title: "Read-only repository grounding",
                        detail:
                            "Only a reviewed, private sealed snapshot is available to Codex. Hard exclusions cannot be overridden, suspicious paths require explicit review, and claims are displayed only after local evidence checks."
                    )
                    PrivacyDetailRow(
                        title: "You speak for yourself",
                        detail:
                            "PaceNote never speaks, sends, pastes, or clicks for you. Suggestions remain visible prompts that you may use, change, or ignore."
                    )
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.closePrivacyDetails() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("privacy-details.done")
                    .paceNoteAssistiveControl(
                        label: "Done",
                        identifier: "privacy-details.done"
                    ) {
                        model.closePrivacyDetails()
                    }
            }
            .padding(16)
        }
        .frame(width: 620, height: 580)
    }
}

private struct PrivacyDetailRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
    #Preview("First run") {
        FirstRunConsentView(model: MeetingViewModel(hasCompletedFirstRun: false))
    }

    #Preview("Meeting setup") {
        MeetingSetupView(model: .previewSetup)
    }

    #Preview("Repository review") {
        RepositoryReviewView(model: .previewRepositoryReview)
    }

    #Preview("Privacy") {
        PrivacyDetailsView(model: .previewSetup)
    }
#endif

private extension CodexConnectionState {
    var setupTitle: String {
        switch self {
        case .ready: "Account preflight passed"
        case .authenticationExpired: "ChatGPT sign-in expired"
        case .signedOut: "Sign in with ChatGPT"
        case .checking: "Checking Codex account"
        case .limited: "Codex preflight is limited"
        case .unavailable: "Codex is unavailable"
        case .notChecked: "Codex account not checked"
        }
    }
}
