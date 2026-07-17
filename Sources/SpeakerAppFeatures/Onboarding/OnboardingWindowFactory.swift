import AppKit

@MainActor
package enum OnboardingWindowFactory {
    package static func make(
        visibleFrame: CGRect,
        contentView: NSView
    ) -> NSWindow {
        let layout = OnboardingWindowLayout(
            visibleFrame: visibleFrame
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: layout.initialSize
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "开始使用 Speaker"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = layout.effectiveMinimumSize
        window.contentMinSize = layout.effectiveMinimumSize
        window.contentView = contentView
        return window
    }
}
