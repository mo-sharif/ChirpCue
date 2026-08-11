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
                        AppBrandMark(size: 72)
                        Text("Welcome to \(AppBrand.displayName)")
                            .font(.largeTitle.weight(.semibold))
                        Text(AppBrand.tagline)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        FirstRunPrinciple(
                            systemImage: "record.circle",
                            title: "You start every capture",
                            detail:
                                "\(AppBrand.displayName) never listens in the background before you explicitly start a meeting. A visible red status remains on while capture is active."
                        )
                        FirstRunPrinciple(
                            systemImage: "person.2.badge.gearshape",
                            title: "You are responsible for consent",
                            detail:
                                "Use \(AppBrand.displayName) only when everyone has been appropriately informed and you have permission under the rules that apply to the meeting."
                        )
                        FirstRunPrinciple(
                            systemImage: "key.slash",
                            title: "Subscription access, no API key",
                            detail:
                                "Choose Codex through an app-owned ChatGPT profile, Claude through your signed-in Claude subscription, or Gemini through Google sign-in. \(AppBrand.displayName) never asks for a provider API key."
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
                                "\(AppBrand.displayName) never speaks, sends, pastes, or responds for you. You decide whether to say anything."
                        )
                    }

                    GroupBox("Before continuing") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(
                                "I understand \(AppBrand.displayName) captures only after I manually start a meeting.",
                                isOn: $model.firstRunAcknowledgement.manualStartOnly
                            )
                            .accessibilityLabel(
                                "I understand \(AppBrand.displayName) captures only after I manually start a meeting."
                            )
                            .accessibilityIdentifier("first-run.manual-start")
                            .paceNoteAssistiveControl(
                                label:
                                    "I understand \(AppBrand.displayName) captures only after I manually start a meeting.",
                                identifier: "first-run.manual-start",
                                role: .checkBox,
                                value: model.firstRunAcknowledgement.manualStartOnly
                            ) {
                                model.firstRunAcknowledgement.manualStartOnly.toggle()
                            }
                            Toggle(
                                "I will use \(AppBrand.displayName) only with appropriate participant permission.",
                                isOn: $model.firstRunAcknowledgement.consentResponsibility
                            )
                            .accessibilityLabel(
                                "I will use \(AppBrand.displayName) only with appropriate participant permission."
                            )
                            .accessibilityIdentifier("first-run.participant-permission")
                            .paceNoteAssistiveControl(
                                label:
                                    "I will use \(AppBrand.displayName) only with appropriate participant permission.",
                                identifier: "first-run.participant-permission",
                                role: .checkBox,
                                value: model.firstRunAcknowledgement.consentResponsibility
                            ) {
                                model.firstRunAcknowledgement.consentResponsibility.toggle()
                            }
                            Toggle(
                                PaceNoteDisclosureText.firstRunProviderProcessing,
                                isOn: $model.firstRunAcknowledgement.openAIProcessing
                            )
                            .accessibilityLabel(PaceNoteDisclosureText.firstRunProviderProcessing)
                            .accessibilityIdentifier("first-run.provider-processing")
                            .paceNoteAssistiveControl(
                                label: PaceNoteDisclosureText.firstRunProviderProcessing,
                                identifier: "first-run.provider-processing",
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
                .buttonStyle(.glassProminent)
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
                .buttonStyle(.glass)
                .disabled(!model.canManageProviderAccounts)
                .accessibilityLabel("Recheck Setup")
                .accessibilityIdentifier("meeting-setup.recheck")
                .paceNoteAssistiveControl(
                    label: "Recheck Setup",
                    identifier: "meeting-setup.recheck",
                    isEnabled: model.canManageProviderAccounts
                ) {
                    Task { await model.refreshEnvironment() }
                }
            }
            .padding(22)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CaptureSetupSection(model: model)
                    ProviderSetupSection(model: model)
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
                .disabled(model.isPerformingMeetingAction)
                .accessibilityLabel("Privacy Details")
                .accessibilityIdentifier("meeting-setup.privacy")
                .paceNoteAssistiveControl(
                    label: "Privacy Details",
                    identifier: "meeting-setup.privacy",
                    isEnabled: !model.isPerformingMeetingAction
                ) {
                    model.presentPrivacyDetails()
                }
                Spacer()
                Button("Cancel") {
                    model.cancelMeetingSetup()
                }
                .accessibilityLabel("Cancel Meeting Setup")
                .accessibilityIdentifier("meeting-setup.cancel")
                .paceNoteAssistiveControl(
                    label: "Cancel Meeting Setup",
                    identifier: "meeting-setup.cancel"
                ) {
                    model.cancelMeetingSetup()
                }
                Button("Start Meeting") {
                    Task { await model.startMeeting() }
                }
                .buttonStyle(.glassProminent)
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

                if model.microphoneEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "Uses the current macOS default input. \(AppBrand.displayName) does not enumerate an exact microphone device here."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Toggle(
                            PaceNoteDisclosureText.soleNearbySpeaker,
                            isOn: $model.meetingConsent.soleNearbySpeakerConfirmed
                        )
                        .accessibilityLabel(PaceNoteDisclosureText.soleNearbySpeaker)
                        .accessibilityIdentifier("meeting-setup.sole-nearby-speaker")
                        .paceNoteAssistiveControl(
                            label: PaceNoteDisclosureText.soleNearbySpeaker,
                            identifier: "meeting-setup.sole-nearby-speaker",
                            role: .checkBox,
                            value: model.meetingConsent.soleNearbySpeakerConfirmed
                        ) {
                            model.meetingConsent.soleNearbySpeakerConfirmed.toggle()
                        }
                        Text(
                            "Optional. Leave this off if anyone else may be nearby; microphone speech will be labeled MIC."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
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
                            ? "Meeting output will still be transcribed. With the microphone off, \(AppBrand.displayName) waits for you to press Coach Current Turn instead of suggesting automatically."
                            : "Capture is off. Enable the microphone or meeting output before starting.",
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

private struct ProviderSetupSection: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        GroupBox("Meeting inference provider") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider", selection: $model.selectedProvider) {
                    ForEach(MeetingInferenceProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Meeting Inference Provider")
                .accessibilityIdentifier("meeting-setup.inference-provider")
                .disabled(!model.canManageProviderAccounts)

                HStack(alignment: .top) {
                    Image(
                        systemName: model.selectedProviderState.isReady
                            ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(model.selectedProviderState.tint)
                    .font(.title2)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            model.selectedProviderState.setupTitle(
                                for: model.selectedProvider
                            )
                        )
                        .font(.headline)
                        Text(model.selectedProviderState.detail(for: model.selectedProvider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.selectedProvider == .codex && !model.codexState.isReady {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Sign in to Codex with ChatGPT") {
                                Task { await model.signInToCodex() }
                            }
                            .disabled(!model.canManageProviderAccounts)
                            .accessibilityLabel("Sign in to Codex with ChatGPT")
                            .accessibilityIdentifier("meeting-setup.codex-sign-in")
                            .paceNoteAssistiveControl(
                                label: "Sign in to Codex with ChatGPT",
                                identifier: "meeting-setup.codex-sign-in",
                                isEnabled: model.canManageProviderAccounts
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
                    if model.selectedProvider == .gemini && !model.geminiState.isReady {
                        Button("Sign in with Google") {
                            Task { await model.signInToGemini() }
                        }
                        .disabled(!model.canManageProviderAccounts)
                        .accessibilityLabel("Sign in to Gemini with Google")
                        .accessibilityIdentifier("meeting-setup.gemini-sign-in")
                        .paceNoteAssistiveControl(
                            label: "Sign in to Gemini with Google",
                            identifier: "meeting-setup.gemini-sign-in",
                            isEnabled: model.canManageProviderAccounts
                        ) {
                            Task { await model.signInToGemini() }
                        }
                    }
                }
                if model.selectedProvider == .codex {
                    Text(
                        "\(AppBrand.displayName) uses an app-owned isolated Codex profile and your ChatGPT subscription. No API key or separate API billing is used. Connected confirms account and model access; final protocol, permission-profile, and skill-policy checks run before capture can begin."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if model.selectedProvider == .claude {
                    Text(
                        "\(AppBrand.displayName) uses your signed-in Claude subscription through the local Claude CLI. No Anthropic API key or separate API billing is used."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if model.claudeState.isSignedOut {
                        Text("Sign in with `claude auth login --claudeai`, then Recheck.")
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(
                        "\(AppBrand.displayName) uses Google sign-in through the official Antigravity CLI. No Gemini API key or Google Cloud billing is used. Gemini receives only transcript slices and bounded host-selected lines from the sealed snapshot."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if model.geminiState.isSignedOut {
                        Text("Choose Sign in with Google, finish in Terminal, then Recheck.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
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
                        "Without a repository, \(AppBrand.displayName) can offer general guidance but cannot make codebase-specific claims."
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
                        if model.selectedProvider == .claude {
                            Label(
                                "Repository skills are Codex-only in Claude v1. Sealed-snapshot grounding remains available through bounded host-selected lines; instruction files and skills stay excluded.",
                                systemImage: "lock.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("meeting-setup.repository-skill-claude-note")
                        } else if !summary.domainSkills.isEmpty {
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
                    .disabled(model.repositoryState.isPending || model.isPerformingMeetingAction)
                    .accessibilityLabel(
                        model.repositoryName == nil ? "Choose Repository" : "Choose Another Repository"
                    )
                    .accessibilityIdentifier("meeting-setup.choose-repository")
                    .paceNoteAssistiveControl(
                        label:
                            model.repositoryName == nil
                            ? "Choose Repository" : "Choose Another Repository",
                        identifier: "meeting-setup.choose-repository",
                        isEnabled: !model.repositoryState.isPending
                            && !model.isPerformingMeetingAction,
                        action: chooseRepository
                    )
                    if case .review = model.repositoryState {
                        Button("Review Findings") {
                            model.presentedSheet = .repositoryReview
                        }
                        .disabled(model.isPerformingMeetingAction)
                        .accessibilityLabel("Review Repository Findings")
                        .accessibilityIdentifier("meeting-setup.review-findings")
                        .paceNoteAssistiveControl(
                            label: "Review Repository Findings",
                            identifier: "meeting-setup.review-findings",
                            isEnabled: !model.isPerformingMeetingAction
                        ) {
                            model.presentedSheet = .repositoryReview
                        }
                    }
                    if model.repositoryName != nil {
                        Button("Remove") {
                            Task { await model.removeRepository() }
                        }
                        .disabled(
                            model.repositoryState.isPending || model.isPerformingMeetingAction
                        )
                        .accessibilityLabel("Remove Repository")
                        .accessibilityIdentifier("meeting-setup.remove-repository")
                        .paceNoteAssistiveControl(
                            label: "Remove Repository",
                            identifier: "meeting-setup.remove-repository",
                            isEnabled: !model.repositoryState.isPending
                                && !model.isPerformingMeetingAction
                        ) {
                            Task { await model.removeRepository() }
                        }
                    }
                }

                Text(
                    "Codex can receive only the reviewed read-only snapshot. Claude v1 can receive only bounded host-selected lines from that snapshot and excludes instruction files and skills. Credentials, hard-excluded files, and the live working tree are never provided to either provider."
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
                    PaceNoteDisclosureText.meetingParticipantPermission,
                    isOn: $model.meetingConsent.participantPermission
                )
                .accessibilityLabel(PaceNoteDisclosureText.meetingParticipantPermission)
                .accessibilityIdentifier("meeting-setup.consent-participant")
                .paceNoteAssistiveControl(
                    label: PaceNoteDisclosureText.meetingParticipantPermission,
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
                    PaceNoteDisclosureText.meetingProcessing(for: model.selectedProvider),
                    isOn: $model.meetingConsent.openAIProcessingConfirmed
                )
                .accessibilityLabel(
                    PaceNoteDisclosureText.meetingProcessing(for: model.selectedProvider)
                )
                .accessibilityIdentifier("meeting-setup.consent-provider-processing")
                .paceNoteAssistiveControl(
                    label: PaceNoteDisclosureText.meetingProcessing(for: model.selectedProvider),
                    identifier: "meeting-setup.consent-provider-processing",
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

                    GroupBox("Grounding limits") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "\(Self.mebibytes(review.resourceLimits.maximumFileBytes)) MiB per file",
                                systemImage: "doc"
                            )
                            Label(
                                "\(review.resourceLimits.maximumFileCount.formatted()) reviewed files",
                                systemImage: "number"
                            )
                            Label(
                                "\(Self.mebibytes(review.resourceLimits.maximumAcceptedBytes)) MiB included content",
                                systemImage: "externaldrive"
                            )
                            Text(
                                "Files above the per-file limit are listed below and excluded from both providers instead of blocking the repository."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
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
                            Text(
                                "\(AppBrand.displayName) applies the effective path-scoped instruction chain for each cited file."
                            )
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
                .buttonStyle(.glassProminent)
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

    private static func mebibytes(_ bytes: UInt64) -> UInt64 {
        bytes / (1_024 * 1_024)
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
                            "Capture begins only after per-meeting setup and a deliberate Start Meeting action. \(AppBrand.displayName) does not support covert capture."
                    )
                    PrivacyDetailRow(
                        title: "Ephemeral meeting content",
                        detail:
                            "Audio is held in a short memory buffer and is not intentionally written to disk. Transcript and suggestions are cleared when you stop."
                    )
                    PrivacyDetailRow(
                        title: "\(model.selectedProvider.processorName) processing",
                        detail: PaceNoteDisclosureText.processingSummary(
                            for: model.selectedProvider
                        )
                    )
                    if model.selectedProvider == .codex {
                        PrivacyDetailRow(
                            title: "Isolated subscription sign-in",
                            detail:
                                "\(AppBrand.displayName) uses an app-owned isolated Codex profile authenticated with ChatGPT. It does not request, store, or bill an OpenAI API key."
                        )
                    } else {
                        PrivacyDetailRow(
                            title: "Claude subscription sign-in",
                            detail:
                                "\(AppBrand.displayName) uses the signed-in Claude subscription through the local Claude CLI. It does not request, store, or bill an Anthropic API key."
                        )
                    }
                    PrivacyDetailRow(
                        title: "Read-only repository grounding",
                        detail:
                            "Codex can receive only the reviewed private snapshot. Claude v1 can receive only bounded host-selected lines from that snapshot and excludes instruction files and skills. Hard exclusions cannot be overridden, suspicious paths require explicit review, and claims are displayed only after local evidence checks."
                    )
                    PrivacyDetailRow(
                        title: "You speak for yourself",
                        detail:
                            "\(AppBrand.displayName) never speaks, sends, pastes, or clicks for you. Suggestions remain visible prompts that you may use, change, or ignore."
                    )
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.closePrivacyDetails() }
                    .buttonStyle(.glassProminent)
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

private extension InferenceConnectionState {
    func setupTitle(for provider: MeetingInferenceProvider) -> String {
        switch self {
        case .ready: "\(provider.shortTitle) subscription preflight passed"
        case .authenticationExpired:
            "\(provider.shortTitle) account needs attention"
        case .signedOut: "Sign in to \(provider.shortTitle)"
        case .checking: "Checking \(provider.shortTitle) subscription"
        case .limited: "\(provider.shortTitle) preflight is limited"
        case .unavailable: "\(provider.shortTitle) is unavailable"
        case .notChecked: "\(provider.shortTitle) subscription not checked"
        }
    }
}
