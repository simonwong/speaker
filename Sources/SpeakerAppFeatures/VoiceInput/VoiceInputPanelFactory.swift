@preconcurrency import AppKit

@MainActor
private final class NonactivatingVoiceInputPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

package enum VoiceInputPanelFactory {
    @MainActor
    package static func make(contentRect: NSRect) -> NSPanel {
        let panel = NonactivatingVoiceInputPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The SwiftUI HUD draws a shape-aware shadow. A window shadow here
        // would add a second, rectangular halo around the transparent panel.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.animationBehavior = .none
        return panel
    }

    /// Applies the complete content geometry for a presentation transition.
    ///
    /// Keeping this operation beside panel construction prevents AppKit from
    /// retaining a previous result card's width when the HUD returns to the
    /// compact recording or processing state.
    @MainActor
    package static func apply(
        _ layout: VoiceInputPanelLayout,
        to panel: NSPanel
    ) {
        panel.setContentSize(layout.size)
        panel.contentView?.frame = NSRect(origin: .zero, size: layout.size)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }
}
