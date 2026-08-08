import Foundation
import XCTest

final class MeetingDismissControlTests: XCTestCase {
    func testDismissControlHasWindowMenuAndKeyboardAccessibilitySurfaces() throws {
        let meetingWindow = try source("Sources/PaceNoteApp/UI/MeetingWindow.swift")
        let menuBar = try source("Sources/PaceNoteApp/UI/MenuBarContent.swift")
        let appCommands = try source("Sources/PaceNoteApp/PaceNoteApp.swift")

        XCTAssertTrue(meetingWindow.contains("meeting.dismiss-suggestion"))
        XCTAssertTrue(meetingWindow.contains("Dismiss Current Suggestion"))
        XCTAssertTrue(
            meetingWindow.contains(
                "Stops this answer and clears its cards. Meeting capture and transcript continue."
            )
        )
        XCTAssertTrue(menuBar.contains("menu-bar.dismiss-suggestion"))
        XCTAssertTrue(appCommands.contains("Button(\"Dismiss Suggestion\")"))
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
