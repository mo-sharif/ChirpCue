import AppKit
import XCTest

@testable import PaceNoteApp

@MainActor
final class AssistiveControlProxyTests: XCTestCase {
    func testNamedCheckBoxExposesStateAndPressAction() {
        var pressCount = 0
        let view = AssistiveControlProxyView()

        view.configure(
            label: "Participant permission",
            identifier: "consent.participant",
            role: .checkBox,
            value: false,
            isEnabled: true
        ) {
            pressCount += 1
        }

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .checkBox)
        XCTAssertEqual(view.accessibilityLabel(), "Participant permission")
        XCTAssertEqual(view.accessibilityIdentifier(), "consent.participant")
        XCTAssertEqual((view.accessibilityValue() as? NSNumber)?.boolValue, false)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(pressCount, 1)
    }

    func testDisabledProxyRejectsPress() {
        var didPress = false
        let view = AssistiveControlProxyView()

        view.configure(
            label: "Continue",
            identifier: "first-run.continue",
            role: .button,
            value: nil,
            isEnabled: false
        ) {
            didPress = true
        }

        XCTAssertFalse(view.isAccessibilityEnabled())
        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertFalse(didPress)
    }
}
