import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {
    @Bindable var model: MeetingViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
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
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(AppBrand.displayName) status: \(model.phase.statusTitle). "
                    + (model.isCaptureActive ? "Capture active. " : "Capture inactive. ")
                    + model.statusDetail
            )

            VStack(alignment: .leading, spacing: 5) {
                Label(
                    model.microphoneEnabled ? model.microphonePermission.shortLabel : "Off",
                    systemImage: model.microphoneEnabled ? "mic.fill" : "mic.slash"
                )
                Label(
                    model.outputEnabled ? model.systemAudioPermission.shortLabel : "Off",
                    systemImage: model.outputEnabled ? "speaker.wave.2.fill" : "speaker.slash"
                )
                Label(
                    "\(model.selectedProvider.shortTitle): \(model.selectedProviderState.shortLabel)",
                    systemImage: "person.crop.circle"
                )
                Label(
                    model.repositoryName ?? "No repository",
                    systemImage: model.repositoryState.isReady ? "checkmark.shield.fill" : "folder"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !model.brownouts.isEmpty {
                Label(
                    "Limited mode: \(model.brownouts.count) issue\(model.brownouts.count == 1 ? "" : "s")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }

            Divider()

            Button("Open \(AppBrand.displayName)") {
                openMeetingWindow()
            }
            .keyboardShortcut("o")
            .accessibilityLabel("Open \(AppBrand.displayName)")
            .accessibilityIdentifier("menu-bar.open")
            .paceNoteAssistiveControl(
                label: "Open \(AppBrand.displayName)",
                identifier: "menu-bar.open",
                action: openMeetingWindow
            )

            Button("Coach Current Turn") {
                Task { await model.coachCurrentTurn() }
            }
            .disabled(!model.canCoachCurrentTurn)
            .accessibilityLabel("Coach Current Turn")
            .accessibilityIdentifier("menu-bar.coach-current-turn")
            .paceNoteAssistiveControl(
                label: "Coach Current Turn",
                identifier: "menu-bar.coach-current-turn",
                isEnabled: model.canCoachCurrentTurn
            ) {
                Task { await model.coachCurrentTurn() }
            }

            Button("Dismiss Suggestion") {
                Task { await model.dismissSuggestion() }
            }
            .disabled(!model.canDismissSuggestion)
            .accessibilityLabel("Dismiss Current Suggestion")
            .accessibilityHint(
                "Stops this answer and clears its cards. Meeting capture and transcript continue."
            )
            .accessibilityIdentifier("menu-bar.dismiss-suggestion")
            .paceNoteAssistiveControl(
                label: "Dismiss Current Suggestion",
                identifier: "menu-bar.dismiss-suggestion",
                isEnabled: model.canDismissSuggestion
            ) {
                Task { await model.dismissSuggestion() }
            }

            if model.phase == .paused {
                Button("Resume Capture") {
                    Task { await model.resume() }
                }
                .disabled(model.isPerformingMeetingAction)
                .accessibilityLabel("Resume Capture")
                .accessibilityIdentifier("menu-bar.resume")
                .paceNoteAssistiveControl(
                    label: "Resume Capture",
                    identifier: "menu-bar.resume",
                    isEnabled: !model.isPerformingMeetingAction
                ) {
                    Task { await model.resume() }
                }
            } else if model.canPause {
                Button("Pause Capture") {
                    Task { await model.pause() }
                }
                .disabled(model.isPerformingMeetingAction)
                .accessibilityLabel("Pause Capture")
                .accessibilityIdentifier("menu-bar.pause")
                .paceNoteAssistiveControl(
                    label: "Pause Capture",
                    identifier: "menu-bar.pause",
                    isEnabled: !model.isPerformingMeetingAction
                ) {
                    Task { await model.pause() }
                }
            } else {
                Button("Set Up Meeting") {
                    openMeetingWindow()
                    model.presentMeetingSetup()
                }
                .disabled(!model.canPresentSetup)
                .accessibilityLabel("Set Up Meeting")
                .accessibilityIdentifier("menu-bar.setup")
                .paceNoteAssistiveControl(
                    label: "Set Up Meeting",
                    identifier: "menu-bar.setup",
                    isEnabled: model.canPresentSetup
                ) {
                    openMeetingWindow()
                    model.presentMeetingSetup()
                }
            }

            Button("Stop and Clear", role: .destructive) {
                Task { await model.stop() }
            }
            .disabled(!model.canStop)
            .accessibilityLabel("Stop and Clear")
            .accessibilityIdentifier("menu-bar.stop-and-clear")
            .paceNoteAssistiveControl(
                label: "Stop and Clear",
                identifier: "menu-bar.stop-and-clear",
                isEnabled: model.canStop
            ) {
                Task { await model.stop() }
            }

            SettingsLink()
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("menu-bar.settings")
                .paceNoteAssistiveControl(
                    label: "Settings",
                    identifier: "menu-bar.settings"
                ) {
                    openSettings()
                }

            Divider()
            Button("Quit \(AppBrand.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .accessibilityLabel("Quit \(AppBrand.displayName)")
            .accessibilityIdentifier("menu-bar.quit")
            .paceNoteAssistiveControl(
                label: "Quit \(AppBrand.displayName)",
                identifier: "menu-bar.quit"
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func openMeetingWindow() {
        openWindow(id: "meeting")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

#if DEBUG
    #Preview("Menu bar") {
        MenuBarContent(model: .previewListening)
    }
#endif
