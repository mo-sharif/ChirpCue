import PaceNoteCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var model: MeetingViewModel
    @State private var confirmingClaudeAccountChange = false
    @AppStorage("paceNote.defaultMicrophoneEnabled") private var defaultMicrophoneEnabled = true
    @AppStorage("paceNote.defaultOutputEnabled") private var defaultOutputEnabled = true
    @AppStorage("paceNote.defaultOutputScope") private var defaultOutputScope = OutputCaptureScope.meetingApplication
        .rawValue
    @AppStorage("paceNote.speakingStyle") private var speakingStyle = "Direct"
    @AppStorage("paceNote.speakerBrief") private var speakerBrief = ""

    var body: some View {
        TabView {
            Form {
                Section("New meetings") {
                    Toggle("Enable microphone by default", isOn: $defaultMicrophoneEnabled)
                        .accessibilityLabel("Enable Microphone by Default")
                        .accessibilityIdentifier("settings.default-microphone")
                        .paceNoteAssistiveControl(
                            label: "Enable Microphone by Default",
                            identifier: "settings.default-microphone",
                            role: .checkBox,
                            value: defaultMicrophoneEnabled
                        ) {
                            defaultMicrophoneEnabled.toggle()
                        }
                    Toggle("Enable meeting output by default", isOn: $defaultOutputEnabled)
                        .accessibilityLabel("Enable Meeting Output by Default")
                        .accessibilityIdentifier("settings.default-output")
                        .paceNoteAssistiveControl(
                            label: "Enable Meeting Output by Default",
                            identifier: "settings.default-output",
                            role: .checkBox,
                            value: defaultOutputEnabled
                        ) {
                            defaultOutputEnabled.toggle()
                        }
                    Picker("Default output scope", selection: $defaultOutputScope) {
                        ForEach(OutputCaptureScope.allCases) { scope in
                            Text(scope.title).tag(scope.rawValue)
                        }
                    }
                    .accessibilityLabel("Default Output Scope")
                    .accessibilityIdentifier("settings.output-scope")
                    Text(
                        "Every meeting still requires source review, permission checks, and explicit consent before capture starts."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Response") {
                    Picker("Speaking style", selection: $speakingStyle) {
                        Text("Direct").tag("Direct")
                        Text("Calm").tag("Calm")
                        Text("Technical").tag("Technical")
                    }
                    .accessibilityLabel("Speaking Style")
                    .accessibilityIdentifier("settings.speaking-style")
                    HStack {
                        Text("About you")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if !speakerBrief.isEmpty {
                            Button("Clear") { speakerBrief = "" }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Clear About You")
                                .accessibilityIdentifier("settings.speaker-brief-clear")
                        }
                    }
                    TextEditor(text: $speakerBrief)
                        .frame(minHeight: 92)
                        .accessibilityLabel("About You")
                        .accessibilityIdentifier("settings.speaker-brief")
                        .onChange(of: speakerBrief) { _, newValue in
                            if newValue.count > SpeakerBriefPolicy.maximumCharacters {
                                speakerBrief = String(
                                    newValue.prefix(SpeakerBriefPolicy.maximumCharacters)
                                )
                            }
                        }
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            "Add factual background for new meetings, such as years with React, recent applications, and your role. Stored locally on this Mac and sent only with meeting inference."
                        )
                        Spacer()
                        Text("\(speakerBrief.count)/\(SpeakerBriefPolicy.maximumCharacters)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Keyboard shortcuts") {
                    ShortcutRow(action: "Set up meeting", shortcut: "⌘⇧L")
                    ShortcutRow(action: "Retry latest answer", shortcut: "⌘⇧↩")
                    ShortcutRow(action: "Coach typed question", shortcut: "⌘↩")
                    ShortcutRow(action: "Pause capture", shortcut: "⌘⇧P")
                    ShortcutRow(action: "Stop and clear", shortcut: "⌘.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Section("Meeting inference provider") {
                    Picker("Provider", selection: $model.selectedProvider) {
                        ForEach(MeetingInferenceProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .accessibilityLabel("Meeting Inference Provider")
                    .accessibilityIdentifier("settings.inference-provider")
                    .disabled(!model.canManageProviderAccounts || !model.canPresentSetup)
                    Text(
                        "Changing providers revokes the current provider-processing consent. You must confirm it again before starting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Recheck Accounts") {
                        Task { await model.refreshEnvironment() }
                    }
                    .accessibilityLabel("Recheck Accounts")
                    .accessibilityIdentifier("settings.recheck-account")
                    .paceNoteAssistiveControl(
                        label: "Recheck Accounts",
                        identifier: "settings.recheck-account",
                        isEnabled: model.canManageProviderAccounts
                    ) {
                        Task { await model.refreshEnvironment() }
                    }
                    .disabled(!model.canManageProviderAccounts)
                }
                Section("Codex via ChatGPT") {
                    LabeledContent("Status", value: model.codexState.shortLabel)
                    Text(model.codexState.detail(for: .codex))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(AppBrand.displayName) uses an app-owned isolated Codex profile and your ChatGPT subscription. It does not use an API key."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        if !model.codexState.isReady {
                            Button("Sign in to Codex with ChatGPT") {
                                Task { await model.signInToCodex() }
                            }
                            .accessibilityLabel("Sign in to Codex with ChatGPT")
                            .accessibilityIdentifier("settings.codex-sign-in")
                            .paceNoteAssistiveControl(
                                label: "Sign in to Codex with ChatGPT",
                                identifier: "settings.codex-sign-in",
                                isEnabled: model.canManageProviderAccounts
                            ) {
                                Task { await model.signInToCodex() }
                            }
                        }
                        if model.canForgetCodexProfile {
                            Button("Sign Out and Forget Profile", role: .destructive) {
                                Task { await model.forgetCodexProfile() }
                            }
                            .accessibilityLabel("Sign Out and Forget Profile")
                            .accessibilityIdentifier("settings.codex-sign-out")
                            .paceNoteAssistiveControl(
                                label: "Sign Out and Forget Profile",
                                identifier: "settings.codex-sign-out",
                                isEnabled: model.canForgetCodexProfile
                            ) {
                                Task { await model.forgetCodexProfile() }
                            }
                        }
                    }
                    .disabled(!model.canManageProviderAccounts)
                }
                Section("Claude subscription") {
                    LabeledContent("Status", value: model.claudeState.shortLabel)
                    Text(model.claudeState.detail(for: .claude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(AppBrand.displayName) uses the signed-in Claude subscription through the local Claude CLI. It does not use an Anthropic API key."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if model.claudeState.isSignedOut {
                        Text("Sign in with `claude auth login --claudeai`, then Recheck.")
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if model.canConfirmClaudeAccountChange {
                        Button("Use Current Claude Account") {
                            confirmingClaudeAccountChange = true
                        }
                        .accessibilityLabel("Use Current Claude Account")
                        .accessibilityIdentifier("settings.claude-confirm-account")
                        .paceNoteAssistiveControl(
                            label: "Use Current Claude Account",
                            identifier: "settings.claude-confirm-account",
                            isEnabled: model.canManageProviderAccounts
                        ) {
                            confirmingClaudeAccountChange = true
                        }
                        .disabled(!model.canManageProviderAccounts)
                    }
                }
                Section("Gemini via Google AI") {
                    LabeledContent("Status", value: model.geminiState.shortLabel)
                    Text(model.geminiState.detail(for: .gemini))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(AppBrand.displayName) uses Google sign-in through the official Antigravity CLI. It does not use a Gemini API key or Google Cloud billing."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        if !model.geminiState.isReady {
                            Button("Sign in with Google") {
                                Task { await model.signInToGemini() }
                            }
                            .accessibilityLabel("Sign in to Gemini with Google")
                            .accessibilityIdentifier("settings.gemini-sign-in")
                            .paceNoteAssistiveControl(
                                label: "Sign in to Gemini with Google",
                                identifier: "settings.gemini-sign-in",
                                isEnabled: model.canManageProviderAccounts
                            ) {
                                Task { await model.signInToGemini() }
                            }
                            .disabled(!model.canManageProviderAccounts)
                        }
                        Link(
                            "Install Antigravity CLI",
                            destination: URL(string: "https://antigravity.google/docs/cli/install")!
                        )
                    }
                }
                Section("Capture permissions") {
                    LabeledContent("Microphone", value: model.microphonePermission.shortLabel)
                    LabeledContent("System audio", value: model.systemAudioPermission.shortLabel)
                    Text(
                        "\(AppBrand.displayName) never interprets a settings toggle as macOS permission. Permission status comes from the local capture preflight."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Connection", systemImage: "person.crop.circle.badge.checkmark") }

            Form {
                Section("Meeting data") {
                    PrivacySettingRow(
                        title: "Ephemeral by default",
                        detail: "Audio is not intentionally stored. Transcript and suggestions clear when you stop."
                    )
                    PrivacySettingRow(
                        title: "\(model.selectedProvider.processorName) processing",
                        detail: PaceNoteDisclosureText.processingSummary(
                            for: model.selectedProvider
                        )
                    )
                    PrivacySettingRow(
                        title: "Never speaks or sends for you",
                        detail: "\(AppBrand.displayName) never speaks, pastes, sends, or clicks for you."
                    )
                    PrivacySettingRow(
                        title: "Screen-share protected",
                        detail:
                            "The coaching window asks macOS not to include it in window capture. Always verify your sharing preview before a meeting."
                    )
                }
                Section("Repository grounding") {
                    PrivacySettingRow(
                        title: "Sealed and read-only",
                        detail:
                            "Codex receives only the reviewed private snapshot. Claude v1 receives only bounded host-selected lines from that snapshot and excludes instruction files and skills. Neither provider receives the live working tree or credentials, and every displayed repository claim must pass local evidence checks."
                    )
                }
                Section {
                    Button("Stop and Clear Current Meeting", role: .destructive) {
                        Task { await model.stop() }
                    }
                    .disabled(
                        model.phase == .idle || model.phase == .ended || model.isPerformingMeetingAction
                    )
                    .accessibilityLabel("Stop and Clear Current Meeting")
                    .accessibilityIdentifier("settings.stop-and-clear")
                    .paceNoteAssistiveControl(
                        label: "Stop and Clear Current Meeting",
                        identifier: "settings.stop-and-clear",
                        isEnabled: model.phase != .idle && model.phase != .ended
                            && !model.isPerformingMeetingAction
                    ) {
                        Task { await model.stop() }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .scenePadding()
        .frame(width: 600, height: 470)
        .onChange(of: defaultMicrophoneEnabled) { _, value in
            if model.canPresentSetup { model.microphoneEnabled = value }
        }
        .onChange(of: defaultOutputEnabled) { _, value in
            if model.canPresentSetup { model.outputEnabled = value }
        }
        .onChange(of: defaultOutputScope) { _, value in
            if model.canPresentSetup, let scope = OutputCaptureScope(rawValue: value) {
                model.outputScope = scope
            }
        }
        .confirmationDialog(
            "Use the current Claude account?",
            isPresented: $confirmingClaudeAccountChange,
            titleVisibility: .visible
        ) {
            Button("Confirm Current Claude Account") {
                Task { await model.confirmClaudeAccountChange() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "ChirpCue will bind future meetings to the currently signed-in Claude subscription. Provider-processing consent will be cleared and must be confirmed again."
            )
        }
    }
}

private struct ShortcutRow: View {
    let action: String
    let shortcut: String

    var body: some View {
        LabeledContent(action) {
            Text(shortcut)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PrivacySettingRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
    #Preview("Settings") {
        SettingsView(model: .previewSetup)
    }
#endif
