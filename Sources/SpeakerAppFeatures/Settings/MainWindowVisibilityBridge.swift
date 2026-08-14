import AppKit
import SwiftUI

/// Keeps the app's activation policy in sync with the main window's visibility:
/// while the window exists the app appears in the Dock and Command-Tab
/// (`.regular`); once it closes the app returns to a menu-bar-only accessory.
package struct MainWindowVisibilityBridge: NSViewRepresentable {
    package init() {}

    package static func activationPolicy(
        mainWindowVisible: Bool
    ) -> NSApplication.ActivationPolicy {
        mainWindowVisible ? .regular : .accessory
    }

    package func makeNSView(context: Context) -> NSView {
        MainWindowVisibilityObserverView()
    }

    package func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowVisibilityObserverView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPolicy(mainWindowVisible: window != nil)
    }

    private func applyPolicy(mainWindowVisible: Bool) {
        let policy = MainWindowVisibilityBridge.activationPolicy(
            mainWindowVisible: mainWindowVisible
        )
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}
