import AppKit
import SwiftUI

/// An invisible accessibility button laid over a visually identical SwiftUI
/// control.
///
/// AppKit can discover and press this view even when SwiftUI lazily omits its
/// virtual accessibility children while VoiceOver is not running. Mouse
/// hit-testing deliberately falls through to the original SwiftUI button, so
/// hover, click, and keyboard-shortcut behaviour stay with that control. Every
/// surface that needs the bridge — the HUD strips and the Personal Dictionary
/// Entry chip — uses this one definition.
struct AccessibilityButtonBridge: NSViewRepresentable {
    let label: String
    let hint: String?
    let value: String?
    let isEnabled: Bool
    let action: () -> Void

    init(
        label: String,
        hint: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.hint = hint
        self.value = value
        self.isEnabled = isEnabled
        self.action = action
    }

    func makeNSView(context: Context) -> AccessibilityButtonBridgeView {
        AccessibilityButtonBridgeView(
            label: label,
            hint: hint,
            value: value,
            isEnabled: isEnabled(in: context),
            action: action
        )
    }

    func updateNSView(
        _ view: AccessibilityButtonBridgeView,
        context: Context
    ) {
        view.update(
            label: label,
            hint: hint,
            value: value,
            isEnabled: isEnabled(in: context),
            action: action
        )
    }

    /// A `.disabled` ancestor disables the visible control, so the bridge
    /// must not stay pressable for VoiceOver.
    private func isEnabled(in context: Context) -> Bool {
        isEnabled && context.environment.isEnabled
    }
}

@MainActor
final class AccessibilityButtonBridgeView:
    NSView,
    @preconcurrency NSAccessibilityButton
{
    private var accessibilityAction: () -> Void

    init(
        label: String,
        hint: String?,
        value: String? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        accessibilityAction = action
        super.init(frame: .zero)
        update(label: label, hint: hint, value: value, isEnabled: isEnabled, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        label: String,
        hint: String?,
        value: String? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        accessibilityAction = action
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(hint)
        setAccessibilityValue(value)
        setAccessibilityEnabled(isEnabled)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard isAccessibilityEnabled() else { return false }
        accessibilityAction()
        return true
    }
}
