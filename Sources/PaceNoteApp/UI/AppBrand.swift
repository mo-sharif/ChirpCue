import AppKit
import SwiftUI

enum AppBrand {
    static let displayName = "ChirpCue"
    static let tagline = "Your quiet conversation sidekick for the moments you need the right words."

    static let cyan = Color(red: 0.16, green: 0.86, blue: 0.94)
    static let chartreuse = Color(red: 0.49, green: 0.96, blue: 0.30)
    static let gold = Color(red: 1.00, green: 0.78, blue: 0.20)
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
                        AppBrand.chartreuse.opacity(0.10),
                        .clear,
                        AppBrand.cyan.opacity(0.08),
                        AppBrand.gold.opacity(0.04),
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
