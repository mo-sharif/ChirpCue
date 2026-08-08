import AppKit
import XCTest

@testable import PaceNoteApp

final class WindowFramePlacementTests: XCTestCase {
    @MainActor
    func testCoachingWindowIsShareProtectedAndAvailableAcrossSpaces() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.sharingType = .readOnly
        window.hidesOnDeactivate = true

        CoachingWindowBehavior.apply(to: window)

        XCTAssertEqual(window.sharingType, .none)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testClampsRestoredFrameFullyInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_050)
        let restoredFrame = NSRect(x: 1_216, y: -108, width: 980, height: 720)

        let result = WindowFramePlacement.clampedFrame(
            restoredFrame,
            visibleFrames: [visibleFrame]
        )

        XCTAssertEqual(result, NSRect(x: 940, y: 0, width: 980, height: 720))
        XCTAssertTrue(visibleFrame.contains(result))
    }

    func testLeavesFullyVisibleFrameUnchanged() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_050)
        let restoredFrame = NSRect(x: 300, y: 200, width: 980, height: 720)

        XCTAssertEqual(
            WindowFramePlacement.clampedFrame(restoredFrame, visibleFrames: [visibleFrame]),
            restoredFrame
        )
    }

    func testUsesDisplayWithLargestIntersection() {
        let primary = NSRect(x: 0, y: 0, width: 1_920, height: 1_050)
        let secondary = NSRect(x: 1_920, y: 0, width: 1_440, height: 900)
        let restoredFrame = NSRect(x: 2_800, y: -100, width: 980, height: 720)

        let result = WindowFramePlacement.clampedFrame(
            restoredFrame,
            visibleFrames: [primary, secondary]
        )

        XCTAssertEqual(result, NSRect(x: 2_380, y: 0, width: 980, height: 720))
        XCTAssertTrue(secondary.contains(result))
    }
}
