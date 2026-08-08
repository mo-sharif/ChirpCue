import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var model: MeetingViewModel
    @AppStorage("paceNote.defaultMicrophoneEnabled") private var defaultMicrophoneEnabled = true
    @AppStorage("paceNote.defaultOutputEnabled") private var defaultOutputEnabled = true
    @AppStorage("paceNote.defaultOutputScope") private var defaultOutputScope = OutputCaptureScope.meetingApplication
        .rawValue
    @AppStorage("paceNote.speakingStyle") private var speakingStyle = "Direct"

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
                }
                Section("Keyboard shortcuts") {
                    ShortcutRow(action: "Set up meeting", shortcut: "⌘⇧L")
                    ShortcutRow(action: "Coach current turn", shortcut: "⌘⇧↩")
                    ShortcutRow(action: "Coach typed question", shortcut: "⌘↩")
                    ShortcutRow(action: "Pause capture", shortcut: "⌘⇧P")
                    ShortcutRow(action: "Stop and clear", shortcut: "⌘.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Section("ChatGPT-authenticated Codex") {
                    LabeledContent("Status", value: model.codexState.shortLabel)
                    Text(model.codexState.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "PaceNote uses an app-owned isolated Codex profile and your ChatGPT subscription. It does not use an API key."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Recheck Account") {
                            Task { await model.refreshEnvironment() }
                        }
                        .accessibilityLabel("Recheck Account")
                        .accessibilityIdentifier("settings.recheck-account")
                        .paceNoteAssistiveControl(
                            label: "Recheck Account",
                            identifier: "settings.recheck-account",
                            isEnabled: !model.isBootstrapping && !model.isPerformingMeetingAction
                        ) {
                            Task { await model.refreshEnvironment() }
                        }
                        if !model.codexState.isReady {
                            Button("Sign in to Codex with ChatGPT") {
                                Task { await model.signInToCodex() }
                            }
                            .accessibilityLabel("Sign in to Codex with ChatGPT")
                            .accessibilityIdentifier("settings.codex-sign-in")
                            .paceNoteAssistiveControl(
                                label: "Sign in to Codex with ChatGPT",
                                identifier: "settings.codex-sign-in",
                                isEnabled: !model.isBootstrapping && !model.isPerformingMeetingAction
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
                                isEnabled: !model.isBootstrapping && !model.isPerformingMeetingAction
                            ) {
                                Task { await model.forgetCodexProfile() }
                            }
                        }
                    }
                    .disabled(model.isBootstrapping || model.isPerformingMeetingAction)
                }
                Section("Capture permissions") {
                    LabeledContent("Microphone", value: model.microphonePermission.shortLabel)
                    LabeledContent("System audio", value: model.systemAudioPermission.shortLabel)
                    Text(
                        "PaceNote never interprets a settings toggle as macOS permission. Permission status comes from the local capture preflight."
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
                        title: "OpenAI processing",
                        detail: PaceNoteDisclosureText.openAIProcessingSummary
                    )
                    PrivacySettingRow(
                        title: "No automatic response",
                        detail: "PaceNote never speaks, pastes, sends, or clicks for you."
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
                            "Codex receives only the reviewed private snapshot, never the live working tree or credentials. Every displayed repository claim must pass local evidence checks."
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
