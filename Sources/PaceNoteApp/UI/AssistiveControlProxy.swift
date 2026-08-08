import AppKit
import SwiftUI

@MainActor
enum AssistiveControlRole {
    case button
    case checkBox

    fileprivate var accessibilityRole: NSAccessibility.Role {
        switch self {
        case .button: .button
        case .checkBox: .checkBox
        }
    }
}

@MainActor
private struct AssistiveControlProxy: NSViewRepresentable {
    let label: String
    let identifier: String
    let role: AssistiveControlRole
    let value: Bool?
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> AssistiveControlProxyView {
        AssistiveControlProxyView()
    }

    func updateNSView(_ nsView: AssistiveControlProxyView, context: Context) {
        nsView.configure(
            label: label,
            identifier: identifier,
            role: role,
            value: value,
            isEnabled: isEnabled,
            action: action
        )
    }
}

@MainActor
final class AssistiveControlProxyView: NSView {
    private var action: (() -> Void)?

    func configure(
        label: String,
        identifier: String,
        role: AssistiveControlRole,
        value: Bool?,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.action = action
        setAccessibilityElement(true)
        setAccessibilityRole(role.accessibilityRole)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        setAccessibilityEnabled(isEnabled)
        setAccessibilityValue(value.map { NSNumber(value: $0) })
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard isAccessibilityEnabled(), let action else { return false }
        action()
        return true
    }
}

extension View {
    /// Supplies a native named control because macOS 26 can omit SwiftUI button and toggle labels
    /// from the AppKit accessibility tree. The visual control stays responsible for pointer and
    /// keyboard input; this proxy preserves the same role, state, enabled value, and press action.
    @MainActor
    func paceNoteAssistiveControl(
        label: String,
        identifier: String,
        role: AssistiveControlRole = .button,
        value: Bool? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        accessibilityHidden(true)
            .overlay {
                AssistiveControlProxy(
                    label: label,
                    identifier: identifier,
                    role: role,
                    value: value,
                    isEnabled: isEnabled,
                    action: action
                )
            }
    }
}
