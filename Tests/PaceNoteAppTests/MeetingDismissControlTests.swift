import Foundation
import XCTest

final class MeetingDismissControlTests: XCTestCase {
    func testDismissControlHasWindowMenuAndKeyboardAccessibilitySurfaces() throws {
        let meetingWindow = try source("Sources/PaceNoteApp/UI/MeetingWindow.swift")
        let menuBar = try source("Sources/PaceNoteApp/UI/MenuBarContent.swift")
        let appCommands = try source("Sources/PaceNoteApp/PaceNoteApp.swift")

        XCTAssertTrue(meetingWindow.contains("meeting.dismiss-suggestion"))
        XCTAssertTrue(meetingWindow.contains("Dismiss question"))
        XCTAssertTrue(
            meetingWindow.contains(
                "Clears only this answer thread. Meeting capture and transcript continue."
            )
        )
        XCTAssertTrue(menuBar.contains("menu-bar.dismiss-suggestion"))
        XCTAssertTrue(appCommands.contains("Button(\"Dismiss Latest Answer\")"))
        XCTAssertTrue(
            appCommands.contains(
                ".keyboardShortcut(\"d\", modifiers: [.command, .shift])"
            )
        )
    }

    func testStopControlsRemainBoundToTheDismissIndependentAvailabilityGate() throws {
        let meetingWindow = try source("Sources/PaceNoteApp/UI/MeetingWindow.swift")
        let menuBar = try source("Sources/PaceNoteApp/UI/MenuBarContent.swift")
        let appCommands = try source("Sources/PaceNoteApp/PaceNoteApp.swift")

        XCTAssertTrue(meetingWindow.contains(".disabled(!model.canStop)"))
        XCTAssertTrue(menuBar.contains(".disabled(!model.canStop)"))
        XCTAssertTrue(appCommands.contains(".disabled(!model.canStop)"))
    }

    func testTerminalDeepFailureReplacesSpinnerWithRetryControl() throws {
        let meetingWindow = try source("Sources/PaceNoteApp/UI/MeetingWindow.swift")

        XCTAssertTrue(meetingWindow.contains("meeting.retry-deep"))
        XCTAssertTrue(meetingWindow.contains("Retry Next Part"))
        XCTAssertTrue(
            meetingWindow.contains(
                "The first answer stays available; the next part didn’t arrive."
            )
        )
    }

    func testPrompterLabelsGuideTheSpokenHandoff() throws {
        let meetingWindow = try source("Sources/PaceNoteApp/UI/MeetingWindow.swift")

        XCTAssertTrue(meetingWindow.contains("title: \"Start here\""))
        XCTAssertTrue(meetingWindow.contains("title: \"Then add this\""))
        XCTAssertTrue(meetingWindow.contains("Say this first • the next part is coming"))
        XCTAssertTrue(meetingWindow.contains(".lineSpacing(5)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
