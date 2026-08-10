import AppKit
import SwiftUI

struct WindowSharingProtection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWindow(for: view)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            CoachingWindowBehavior.apply(to: window)
            let clampedFrame = WindowFramePlacement.clampedFrame(
                window.frame,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            )
            if !window.frame.equalTo(clampedFrame) {
                window.setFrame(clampedFrame, display: true)
            }
        }
    }
}

enum CoachingWindowBehavior {
    @MainActor
    static func apply(to window: NSWindow) {
        #if DEBUG
            window.sharingType = ScreenshotShowcase.current == nil ? .none : .readOnly
        #else
            window.sharingType = .none
        #endif
        window.hidesOnDeactivate = false
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}

enum WindowFramePlacement {
    static func clampedFrame(_ frame: NSRect, visibleFrames: [NSRect]) -> NSRect {
        guard let firstFrame = visibleFrames.first else { return frame }
        let targetFrame =
            visibleFrames.max { lhs, rhs in
                intersectionArea(frame, lhs) < intersectionArea(frame, rhs)
            } ?? firstFrame

        var result = frame
        result.size.width = min(max(1, result.width), targetFrame.width)
        result.size.height = min(max(1, result.height), targetFrame.height)
        result.origin.x = min(
            max(result.minX, targetFrame.minX),
            targetFrame.maxX - result.width
        )
        result.origin.y = min(
            max(result.minY, targetFrame.minY),
            targetFrame.maxY - result.height
        )
        return result
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
