import AppKit
import PaceNoteCore
import SwiftUI

@MainActor
struct MeetingWindow: View {
    @Bindable var model: MeetingViewModel
    @FocusState private var isManualQuestionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            MeetingHeader(model: model)
            if let actionError = model.actionError {
                ActionErrorBanner(message: actionError) {
                    model.dismissActionError()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !model.brownouts.isEmpty {
                BrownoutBanner(reasons: model.brownouts, provider: model.selectedProvider)
            }
            Divider()
            HSplitView {
                TranscriptPane(segments: model.transcript)
                    .frame(minWidth: 390)
                SuggestionsPane(
                    quick: model.quickSuggestion,
                    deep: model.deepSuggestion
                )
                .frame(minWidth: 320, idealWidth: 370)
            }
            Divider()
            ManualQuestionBar(
                text: $model.manualQuestion,
                isEnabled: model.canCoach,
                isCurrentTurnEnabled: model.canCoachCurrentTurn,
                isBusy: model.isPerformingMeetingAction,
                isFocused: $isManualQuestionFocused,
                coachQuestion: {
                    Task { await model.coachManualQuestion() }
                },
                coachCurrentTurn: {
                    Task { await model.coachCurrentTurn() }
                }
            )
        }
        .background { AppBrandBackdrop() }
        .background(WindowSharingProtection())
        .sheet(item: $model.presentedSheet) { destination in
            switch destination {
            case .firstRun:
                FirstRunConsentView(model: model)
            case .meetingSetup:
                MeetingSetupView(model: model)
            case .repositoryReview:
                RepositoryReviewView(model: model)
            case .privacyDetails:
                PrivacyDetailsView(model: model)
            }
        }
        .task {
            await model.bootstrap()
        }
        .animation(.easeInOut(duration: 0.2), value: model.actionError)
    }
}

private struct MeetingHeader: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isCaptureActive ? .red : model.phase.statusColor)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.phase.statusTitle)
                            .font(.headline)
                        Text(model.statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(AppBrand.displayName) status: \(model.phase.statusTitle). "
                        + (model.isCaptureActive ? "Capture active. " : "Capture inactive. ")
                        + model.statusDetail
                )

                Spacer(minLength: 12)
                MeetingActionControls(model: model)
            }

            HStack(spacing: 8) {
                CaptureStatusChip(
                    title: "Mic",
                    systemImage: model.microphoneEnabled ? "mic.fill" : "mic.slash",
                    state: model.microphoneEnabled ? model.microphonePermission : .unavailable("Off for this meeting")
                )
                CaptureStatusChip(
                    title: "Output",
                    systemImage: model.outputEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                    state: model.outputEnabled ? model.systemAudioPermission : .unavailable("Off for this meeting")
                )
                ProviderStatusChip(
                    provider: model.selectedProvider,
                    state: model.selectedProviderState
                )
                if let repositoryName = model.repositoryName {
                    StatusChip(
                        title: repositoryName,
                        detail: model.repositoryState.isReady ? "Sealed snapshot" : "Not ready",
                        systemImage: model.repositoryState.isReady
                            ? "checkmark.shield.fill" : "folder.badge.questionmark",
                        tint: model.repositoryState.isReady ? .green : .orange
                    )
                } else {
                    StatusChip(
                        title: "No repository",
                        detail: "General coaching",
                        systemImage: "folder.badge.minus",
                        tint: .secondary
                    )
                }
                Spacer()
                if model.isBootstrapping || model.isPerformingMeetingAction {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("\(AppBrand.displayName) is working")
                }
            }
        }
        .padding(14)
        .background(.bar)
    }
}

private struct MeetingActionControls: View {
    @Bindable var model: MeetingViewModel

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.coachCurrentTurn() }
                } label: {
                    Label("Coach Now", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .disabled(!model.canCoachCurrentTurn)
                .help("Generate a response for the current turn (Command-Shift-Return)")
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .accessibilityLabel("Coach Now")
                .accessibilityIdentifier("meeting.coach-now")
                .paceNoteAssistiveControl(
                    label: "Coach Now",
                    identifier: "meeting.coach-now",
                    isEnabled: model.canCoachCurrentTurn
                ) {
                    Task { await model.coachCurrentTurn() }
                }

                if model.phase == .paused {
                    Button {
                        Task { await model.resume() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isPerformingMeetingAction)
                    .accessibilityLabel("Resume")
                    .accessibilityIdentifier("meeting.resume")
                    .paceNoteAssistiveControl(
                        label: "Resume",
                        identifier: "meeting.resume",
                        isEnabled: !model.isPerformingMeetingAction
                    ) {
                        Task { await model.resume() }
                    }
                } else {
                    Button {
                        Task { await model.pause() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.isPerformingMeetingAction || !model.canPause)
                    .accessibilityLabel("Pause")
                    .accessibilityIdentifier("meeting.pause")
                    .paceNoteAssistiveControl(
                        label: "Pause",
                        identifier: "meeting.pause",
                        isEnabled: !model.isPerformingMeetingAction && model.canPause
                    ) {
                        Task { await model.pause() }
                    }
                }

                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.isPerformingMeetingAction || model.phase == .idle || model.phase == .ended)
                .help("Stop and clear this meeting (Command-Period)")
                .accessibilityLabel("Stop and Clear Meeting")
                .accessibilityIdentifier("meeting.stop")
                .paceNoteAssistiveControl(
                    label: "Stop and Clear Meeting",
                    identifier: "meeting.stop",
                    isEnabled: !model.isPerformingMeetingAction && model.phase != .idle
                        && model.phase != .ended
                ) {
                    Task { await model.stop() }
                }

                Button {
                    model.presentMeetingSetup()
                } label: {
                    Label(
                        model.phase == .ended ? "New Meeting" : "Set Up Meeting",
                        systemImage: "waveform.badge.plus"
                    )
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.canPresentSetup || model.isPerformingMeetingAction)
                .accessibilityLabel(model.phase == .ended ? "New Meeting" : "Set Up Meeting")
                .accessibilityIdentifier("meeting.setup")
                .paceNoteAssistiveControl(
                    label: model.phase == .ended ? "New Meeting" : "Set Up Meeting",
                    identifier: "meeting.setup",
                    isEnabled: model.canPresentSetup && !model.isPerformingMeetingAction
                ) {
                    model.presentMeetingSetup()
                }
            }
        }
    }
}

private struct CaptureStatusChip: View {
    let title: String
    let systemImage: String
    let state: CapturePermissionState

    var body: some View {
        StatusChip(
            title: title,
            detail: state.shortLabel,
            systemImage: systemImage,
            tint: state.tint
        )
    }
}

private struct ProviderStatusChip: View {
    let provider: MeetingInferenceProvider
    let state: InferenceConnectionState

    var body: some View {
        StatusChip(
            title: provider.shortTitle,
            detail: state.shortLabel,
            systemImage: state.isReady ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark",
            tint: state.tint
        )
    }
}

private struct StatusChip: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }
}

private struct ActionErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss Error")
                .accessibilityIdentifier("meeting.dismiss-error")
                .paceNoteAssistiveControl(
                    label: "Dismiss Error",
                    identifier: "meeting.dismiss-error",
                    action: dismiss
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.red.opacity(0.1))
        .accessibilityElement(children: .contain)
    }
}

private struct BrownoutBanner: View {
    let reasons: Set<BrownoutReason>
    let provider: MeetingInferenceProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Limited mode", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            ForEach(reasons.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reason.userTitle(for: provider))
                        .font(.caption.weight(.semibold))
                    Text(reason.recoveryGuidance(for: provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .accessibilityIdentifier("meeting.brownout")
    }
}

private struct TranscriptPane: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live transcript")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Cleared when you stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            if segments.isEmpty {
                ContentUnavailableView {
                    Label("No transcript yet", systemImage: "waveform")
                } description: {
                    Text("Start a consented meeting to see source-labelled microphone and output speech.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(segments) { segment in
                                TranscriptRow(segment: segment)
                                    .id(segment.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: segments.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        .accessibilityIdentifier("meeting.transcript")
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(segment.source.displayName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(segment.source.tint)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.text)
                    .textSelection(.enabled)
                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
                if !segment.isFinal {
                    Text("Transcribing…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(segment.source.accessibilityName): \(segment.text)\(segment.isFinal ? "" : ", still transcribing")"
        )
    }
}

private struct SuggestionsPane: View {
    let quick: SuggestionCard?
    let deep: SuggestionCard?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("What to say")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Label("You stay in control", systemImage: "person.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if quick == nil && deep == nil {
                    ContentUnavailableView {
                        Label("No suggestion yet", systemImage: "text.bubble")
                    } description: {
                        Text(
                            "A brief speaking cue appears first. A concise answer follows; repository-specific answers are evidence checked."
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 230)
                }

                if let quick {
                    SuggestionCardView(
                        title: quick.stage == .bridge ? "Say now" : "Quick answer",
                        subtitle: "Locked for this turn",
                        card: quick,
                        tint: .blue,
                        systemImage: "lock.fill",
                        symbolAccessibilityLabel: "Suggestion locked"
                    )
                    .accessibilitySortPriority(2)
                }
                if let deep {
                    let presentation = deepPresentation(for: deep)
                    SuggestionCardView(
                        title: "Then say",
                        subtitle: presentation.subtitle,
                        card: deep,
                        tint: presentation.tint,
                        systemImage: presentation.systemImage,
                        symbolAccessibilityLabel: presentation.accessibilityLabel
                    )
                    .accessibilitySortPriority(1)
                } else if quick != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking deeper context automatically…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
        }
        .background(.thinMaterial)
    }

    private func deepPresentation(for card: SuggestionCard) -> DeepSuggestionPresentation {
        switch card.deepKind {
        case .answer:
            DeepSuggestionPresentation(
                subtitle: "Repository evidence checked",
                tint: .green,
                systemImage: "checkmark.seal.fill",
                accessibilityLabel: "Repository evidence check passed"
            )
        case .generalAnswer:
            DeepSuggestionPresentation(
                subtitle: "General guidance • verify before speaking",
                tint: .orange,
                systemImage: "exclamationmark.bubble.fill",
                accessibilityLabel: "General guidance is not repository verified"
            )
        case .clarification:
            DeepSuggestionPresentation(
                subtitle: "Safe clarification",
                tint: .purple,
                systemImage: "questionmark.bubble.fill",
                accessibilityLabel: "Clarification suggestion"
            )
        case .abstention:
            DeepSuggestionPresentation(
                subtitle: "Could not verify safely",
                tint: .secondary,
                systemImage: "hand.raised.fill",
                accessibilityLabel: "\(AppBrand.displayName) abstained"
            )
        case nil:
            DeepSuggestionPresentation(
                subtitle: card.evidence.isEmpty ? "Safe response" : "Repository evidence checked",
                tint: card.evidence.isEmpty ? .secondary : .green,
                systemImage: card.evidence.isEmpty ? "shield.fill" : "checkmark.seal.fill",
                accessibilityLabel: card.evidence.isEmpty
                    ? "Safe response" : "Repository evidence check passed"
            )
        }
    }
}

private struct DeepSuggestionPresentation {
    let subtitle: String
    let tint: Color
    let systemImage: String
    let accessibilityLabel: String
}

private struct SuggestionCardView: View {
    let title: String
    let subtitle: String
    let card: SuggestionCard
    let tint: Color
    let systemImage: String
    let symbolAccessibilityLabel: String
    @State private var showsEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityLabel(symbolAccessibilityLabel)
            }
            Text(card.text)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !card.evidence.isEmpty {
                DisclosureGroup("Evidence", isExpanded: $showsEvidence) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(card.evidence, id: \.self) { evidence in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(evidence.relativePath):\(evidence.startLine)")
                                    .font(.caption.monospaced())
                                Text(evidence.claim)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel("Evidence")
                .accessibilityIdentifier("meeting.suggestion.evidence")
                .paceNoteAssistiveControl(
                    label: showsEvidence ? "Hide Evidence" : "Show Evidence",
                    identifier: "meeting.suggestion.evidence"
                ) {
                    showsEvidence.toggle()
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(subtitle). \(card.text)")
    }
}

private struct ManualQuestionBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let isCurrentTurnEnabled: Bool
    let isBusy: Bool
    let isFocused: FocusState<Bool>.Binding
    let coachQuestion: () -> Void
    let coachCurrentTurn: () -> Void

    private var hasQuestion: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Ask a private follow-up or paste the exact question", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused(isFocused)
                .disabled(!isEnabled || isBusy)
                .onSubmit {
                    if hasQuestion && isEnabled && !isBusy { coachQuestion() }
                }
                .accessibilityLabel("Manual coaching question")
                .accessibilityHint("This text is sent only when you activate Coach Question")
                .accessibilityIdentifier("meeting.manual-question")

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Coach Question", action: coachQuestion)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!isEnabled || isBusy || !hasQuestion)
                        .accessibilityLabel("Coach Question")
                        .accessibilityIdentifier("meeting.coach-question")
                        .paceNoteAssistiveControl(
                            label: "Coach Question",
                            identifier: "meeting.coach-question",
                            isEnabled: isEnabled && !isBusy && hasQuestion,
                            action: coachQuestion
                        )

                    Button("Coach Current Turn", action: coachCurrentTurn)
                        .buttonStyle(.glass)
                        .disabled(!isCurrentTurnEnabled || isBusy)
                        .help("Use the recent transcript without adding a manual question")
                        .accessibilityLabel("Coach Current Turn")
                        .accessibilityIdentifier("meeting.coach-current-turn")
                        .paceNoteAssistiveControl(
                            label: "Coach Current Turn",
                            identifier: "meeting.coach-current-turn",
                            isEnabled: isCurrentTurnEnabled && !isBusy,
                            action: coachCurrentTurn
                        )
                }
            }
        }
        .padding(12)
        .background(.bar)
    }
}

extension MeetingPhase {
    var statusTitle: String {
        switch self {
        case .idle: "Not listening"
        case .permissionRequired: "Setup required"
        case .ready: "Ready"
        case .listening: "Listening"
        case .candidateQuestion: "Question detected"
        case .thinking: "Thinking"
        case .suggesting: "Suggestion ready"
        case .paused: "Paused"
        case .ended: "Meeting ended"
        case .brownout: "Limited mode"
        }
    }

    var statusColor: Color {
        switch self {
        case .listening: .red
        case .thinking, .candidateQuestion: .orange
        case .suggesting, .ready: .green
        case .brownout, .permissionRequired: .yellow
        default: .secondary
        }
    }
}

extension CapturePermissionState {
    var shortLabel: String {
        switch self {
        case .notChecked: "Not checked"
        case .requesting: "Requesting"
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .unavailable: "Unavailable"
        }
    }

    var tint: Color {
        switch self {
        case .authorized: .green
        case .requesting: .blue
        case .denied, .unavailable: .orange
        case .notChecked: .secondary
        }
    }

    var detail: String? {
        switch self {
        case .unavailable(let detail): detail
        case .denied: "Open System Settings to allow access."
        case .notChecked: "Permission has not been checked."
        case .requesting: "Waiting for macOS."
        case .authorized: nil
        }
    }
}

extension InferenceConnectionState {
    var isSignedOut: Bool { self == .signedOut }

    var shortLabel: String {
        switch self {
        case .notChecked: "Not checked"
        case .checking: "Checking"
        case .signedOut: "Sign in"
        case .authenticationExpired: "Sign-in expired"
        case .ready(let account): account.planLabel
        case .limited: "Limited"
        case .unavailable: "Unavailable"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .checking: .blue
        case .signedOut, .authenticationExpired, .limited, .unavailable: .orange
        case .notChecked: .secondary
        }
    }

    func detail(for provider: MeetingInferenceProvider) -> String {
        switch self {
        case .notChecked: "\(provider.shortTitle) subscription access has not been checked."
        case .checking: "Checking the local \(provider.shortTitle) subscription session."
        case .signedOut:
            switch provider {
            case .codex: "No ChatGPT account is signed in through Codex."
            case .claude:
                "Claude is signed out. Run `claude auth login --claudeai` in Terminal, then Recheck."
            }
        case .authenticationExpired(let message):
            switch provider {
            case .codex: "ChatGPT sign-in expired. \(message)"
            case .claude: "Claude account needs confirmation. \(message)"
            }
        case .ready(let account):
            "\(account.accountLabel), \(account.planLabel), \(account.modelCount) available model\(account.modelCount == 1 ? "" : "s")"
        case .limited(let message), .unavailable(let message): message
        }
    }
}

extension TranscriptSource {
    var tint: Color {
        switch self {
        case .you, .microphone: .blue
        case .them, .output: .purple
        case .unknown: .orange
        }
    }

    var accessibilityName: String {
        switch self {
        case .you: "You"
        case .them: "Other participant"
        case .microphone: "Microphone"
        case .output: "Meeting output"
        case .unknown: "Unknown speaker"
        }
    }
}

extension BrownoutReason {
    func userTitle(for provider: MeetingInferenceProvider) -> String {
        switch self {
        case .systemAudioLost: "Meeting output disconnected"
        case .microphoneLost: "Microphone disconnected"
        case .microphoneDisabled: "Microphone is off"
        case .outputDisabled: "Meeting output is off"
        case .transcriptUncertain: "Transcript confidence is low"
        case .transcriberAssetMissing: "Speech model is unavailable"
        case .codexOffline: "AI provider is offline"
        case .authenticationExpired:
            provider == .codex ? "ChatGPT sign-in expired" : "Claude sign-in expired"
        case .accountMismatch:
            provider == .codex ? "ChatGPT account changed" : "Claude account changed"
        case .protocolUnsupported:
            "\(provider.shortTitle) version is unsupported"
        case .appServerCrashed: "\(provider.shortTitle) process stopped"
        case .quickLimited: "Quick coaching is rate-limited"
        case .deepLimited: "Deep coaching is rate-limited"
        case .repositoryChanged: "Repository changed"
        case .snapshotBlocked: "Repository snapshot blocked"
        case .snapshotBusy: "Repository is changing"
        case .permissionProfileMismatch: "Read-only policy mismatch"
        case .skillPolicyMismatch: "Skill policy mismatch"
        case .speakerUncertain: "Speaker source is uncertain"
        }
    }

    func recoveryGuidance(for provider: MeetingInferenceProvider) -> String {
        switch self {
        case .systemAudioLost: "Reopen setup and select the meeting app again."
        case .microphoneLost: "Reconnect the current Mac microphone or use manual coaching."
        case .microphoneDisabled: "Automatic turn detection is off. Use Coach Current Turn."
        case .outputDisabled: "Only microphone speech is available."
        case .transcriptUncertain: "Confirm the question before speaking a suggestion."
        case .transcriberAssetMissing: "Download the required Apple speech asset, then retry."
        case .codexOffline: "Suggestions are paused until the selected provider connection returns."
        case .authenticationExpired:
            provider == .codex
                ? "Sign in to ChatGPT again from meeting setup."
                : "Run `claude auth login --claudeai`, then Recheck."
        case .accountMismatch:
            "Stop the meeting and confirm the intended \(provider.shortTitle) account."
        case .protocolUnsupported:
            "Install the tested \(provider.shortTitle) version before continuing."
        case .appServerCrashed:
            "Reconnect \(provider.shortTitle) from setup. Existing cards stay visible."
        case .quickLimited: "A deterministic bridge may appear while capacity recovers."
        case .deepLimited: "Use the SAY NOW bridge; deeper coaching is temporarily paused."
        case .repositoryChanged: "The sealed snapshot is stale. Reselect the repository."
        case .snapshotBlocked: "Review excluded and suspicious files before grounding."
        case .snapshotBusy: "Wait for repository writes to settle, then seal it again."
        case .permissionProfileMismatch: "Deep answers are disabled until read-only policy is verified."
        case .skillPolicyMismatch: "Deep answers are disabled until the selected skill scope is verified."
        case .speakerUncertain: "Labels use MIC or OUTPUT until speaker attribution is trustworthy."
        }
    }
}

#if DEBUG
    #Preview("Listening") {
        MeetingWindow(model: .previewListening)
            .frame(width: 980, height: 720)
    }

    #Preview("Limited mode") {
        MeetingWindow(model: .previewBrownout)
            .frame(width: 980, height: 720)
    }
#endif
