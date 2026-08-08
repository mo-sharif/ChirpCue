import AppKit
import SwiftUI

enum AppBrand {
    static let displayName = "PrismCue"
    static let tagline = "A clear, consent-first speaking coach for meetings on your Mac."

    static let cyan = Color(red: 0.13, green: 0.73, blue: 0.96)
    static let violet = Color(red: 0.48, green: 0.36, blue: 0.96)
}

@MainActor
struct AppBrandMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AppBrandBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        AppBrand.cyan.opacity(0.10),
                        .clear,
                        AppBrand.violet.opacity(0.08),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
