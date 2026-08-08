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
        let selectedProvider = MeetingViewModel.persistedInferenceProvider(in: defaults)
        let runtime: PaceNoteRuntime?
        let actions: MeetingActions
        do {
            let preparedRuntime = try PaceNoteRuntime()
            runtime = preparedRuntime
            actions = .live(runtime: preparedRuntime)
        } catch let error as PaceNoteActionError {
            runtime = nil
            actions = .unavailable(
                reason: error.errorDescription
                    ?? "\(AppBrand.displayName) could not initialize its private local service."
            )
        } catch {
            runtime = nil
            actions = .unavailable(
                reason: "\(AppBrand.displayName) could not initialize its private local service."
            )
        }
        self.runtime = runtime
        _model = State(
            initialValue: MeetingViewModel(
                actions: actions,
                hasCompletedFirstRun: defaults.bool(forKey: Self.firstRunKey),
                microphoneEnabled: microphoneEnabled,
                outputEnabled: outputEnabled,
                outputScope: outputScope,
                selectedProvider: selectedProvider,
                providerDefaults: defaults
            )
        )
    }

    var body: some Scene {
        WindowGroup(AppBrand.displayName, id: "meeting") {
            MeetingWindow(model: model)
                .frame(minWidth: 820, minHeight: 600)
                .tint(AppBrand.cyan)
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
            AppBrand.displayName,
            systemImage: model.isCaptureActive ? "record.circle.fill" : "quote.bubble"
        ) {
            MenuBarContent(model: model)
                .tint(AppBrand.cyan)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .tint(AppBrand.cyan)
        }
    }
}

@MainActor
final class PaceNoteApplicationDelegate: NSObject, NSApplicationDelegate {
    var runtime: PaceNoteRuntime?
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        return beginTermination(
            shutdown: { await runtime.shutdown() },
            reply: { sender.reply(toApplicationShouldTerminate: $0) }
        )
    }

    func beginTermination(
        shutdown: @escaping @MainActor () async -> Bool,
        reply: @escaping @MainActor (Bool) -> Void,
        onFailure: @escaping @MainActor () -> Void = PaceNoteApplicationDelegate
            .presentShutdownFailure
    ) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task {
            let shutdownCompleted = await shutdown()
            terminationInProgress = false
            reply(shutdownCompleted)
            if !shutdownCompleted {
                onFailure()
            }
        }
        return .terminateLater
    }

    private static func presentShutdownFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(AppBrand.displayName) is still verifying capture teardown"
        alert.informativeText =
            "Quit was canceled because \(AppBrand.displayName) could not verify that every audio route stopped. Use Retry Stop in \(AppBrand.displayName), then quit again."
        alert.addButton(withTitle: "Keep \(AppBrand.displayName) Open")
        alert.runModal()
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

            Button("Dismiss Suggestion") {
                Task { await model.dismissSuggestion() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.canDismissSuggestion)

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
            .disabled(!model.canStop)

            Divider()

            Button("Privacy Details") {
                model.presentPrivacyDetails()
            }
        }
    }
}
