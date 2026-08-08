import AppKit
import PaceNoteCore
import SwiftUI

@main
struct PaceNoteApp: App {
    private static let firstRunKey = "paceNote.didCompleteFirstRun"

    @AppStorage(Self.firstRunKey) private var didCompleteFirstRun = false
    @NSApplicationDelegateAdaptor(PaceNoteApplicationDelegate.self) private var appDelegate
    @State private var model: MeetingViewModel
    private let runtime: PaceNoteRuntime?

    init() {
        let defaults = UserDefaults.standard
        let microphoneEnabled = defaults.object(forKey: "paceNote.defaultMicrophoneEnabled") as? Bool ?? true
        let outputEnabled = defaults.object(forKey: "paceNote.defaultOutputEnabled") as? Bool ?? true
        let outputScope =
            OutputCaptureScope(
                rawValue: defaults.string(forKey: "paceNote.defaultOutputScope") ?? ""
            ) ?? .meetingApplication
        let runtime = try? PaceNoteRuntime()
        self.runtime = runtime
        _model = State(
            initialValue: MeetingViewModel(
                actions: runtime.map(MeetingActions.live(runtime:)) ?? .unwired,
                hasCompletedFirstRun: defaults.bool(forKey: Self.firstRunKey),
                microphoneEnabled: microphoneEnabled,
                outputEnabled: outputEnabled,
                outputScope: outputScope
            )
        )
    }

    var body: some Scene {
        WindowGroup("PaceNote", id: "meeting") {
            MeetingWindow(model: model)
                .frame(minWidth: 820, minHeight: 600)
                .task {
                    appDelegate.runtime = runtime
                }
                .onChange(of: model.hasCompletedFirstRun) { _, completed in
                    didCompleteFirstRun = completed
                }
        }
        .defaultSize(width: 980, height: 720)
        .defaultPosition(.center)
        .windowLevel(.floating)
        .commands {
            PaceNoteCommands(model: model)
        }

        MenuBarExtra(
            "PaceNote",
            systemImage: model.isCaptureActive ? "record.circle.fill" : "waveform.circle"
        ) {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class PaceNoteApplicationDelegate: NSObject, NSApplicationDelegate {
    var runtime: PaceNoteRuntime?
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct PaceNoteCommands: Commands {
    let model: MeetingViewModel

    var body: some Commands {
        CommandMenu("Meeting") {
            Button("Set Up Meeting") {
                model.presentMeetingSetup()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!model.canPresentSetup || model.isPerformingMeetingAction)

            Divider()

            Button("Coach Current Turn") {
                Task { await model.coachCurrentTurn() }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!model.canCoachCurrentTurn)

            if model.phase == .paused {
                Button("Resume Capture") {
                    Task { await model.resume() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isPerformingMeetingAction)
            } else {
                Button("Pause Capture") {
                    Task { await model.pause() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.isPerformingMeetingAction || !model.canPause)
            }

            Button("Stop and Clear Meeting") {
                Task { await model.stop() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model.isPerformingMeetingAction || model.phase == .idle || model.phase == .ended)

            Divider()

            Button("Privacy Details") {
                model.presentPrivacyDetails()
            }
        }
    }
}
