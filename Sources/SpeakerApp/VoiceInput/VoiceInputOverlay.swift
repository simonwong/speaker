import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

@MainActor
final class VoiceInputPanelController {
    private let panel: NSPanel
    private let experience: VoiceInputExperience
    private let hostingView: NSHostingView<VoiceInputOverlay>
    private let performAction:
        (VoiceInputExperienceAction) -> VoiceInputExperienceEffect?
    private let routeEffect: (VoiceInputExperienceEffect) -> Void
    private var stateCancellable: AnyCancellable?
    private var placementCancellables: Set<AnyCancellable> = []
    private var presentedLayout: VoiceInputPanelLayout?

    init(
        experience: VoiceInputExperience,
        routeEffect: @escaping (VoiceInputExperienceEffect) -> Void
    ) {
        self.experience = experience
        let performAction: (VoiceInputExperienceAction) -> VoiceInputExperienceEffect? = {
            [weak experience] action in
            experience?.perform(action)
        }
        self.performAction = performAction
        self.routeEffect = routeEffect
        hostingView = NSHostingView(rootView: VoiceInputOverlay(
            presentation: .hidden,
            performAction: performAction,
            routeEffect: routeEffect
        ))
        let initialSize = VoiceInputPanelLayout.processing.size
        panel = VoiceInputPanelFactory.make(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialSize.width,
                height: initialSize.height
            )
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    private func rootView(
        for presentation: VoiceInputOverlayPresentation
    ) -> VoiceInputOverlay {
        VoiceInputOverlay(
            presentation: presentation,
            performAction: performAction,
            routeEffect: routeEffect
        )
    }

    func start() {
        guard stateCancellable == nil else { return }
        stateCancellable = experience.$state.sink { [weak self] state in
            self?.apply(state.overlay)
        }
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in self?.repositionVisiblePanel() }
        .store(in: &placementCancellables)
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .sink { [weak self] _ in self?.repositionVisiblePanel() }
        .store(in: &placementCancellables)
    }

    private func apply(_ overlay: VoiceInputOverlayPresentation) {
        switch overlay {
        case .hidden:
            hostingView.rootView = rootView(for: overlay)
            panel.orderOut(nil)
            panel.alphaValue = 1
            presentedLayout = nil
        case .recording, .processing, .pendingCopy, .problem:
            guard let layout = VoiceInputPanelLayout(overlay) else { return }
            // Resize the AppKit window before replacing the SwiftUI tree.
            // Otherwise a visible result card can render one frame of the next
            // compact activity state using its previous 320 pt footprint.
            VoiceInputPanelFactory.apply(layout, to: panel)
            hostingView.rootView = rootView(for: overlay)
            showPanel(for: overlay)
        }
    }

    private func showPanel(for overlay: VoiceInputOverlayPresentation) {
        guard let layout = VoiceInputPanelLayout(overlay) else { return }
        let wasVisible = panel.isVisible
        let needsPlacement = presentedLayout != layout || !wasVisible
        VoiceInputPanelFactory.apply(layout, to: panel)
        if needsPlacement {
            repositionVisiblePanel()
        }
        switch overlay {
        case .recording, .processing, .pendingCopy, .problem:
            if !wasVisible {
                panel.alphaValue = 0
            }
            panel.orderFrontRegardless()
        case .hidden:
            break
        }
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(
                    name: .easeOut
                )
                panel.animator().alphaValue = 1
            }
        }
        panel.displayIfNeeded()
        presentedLayout = layout
#if DEBUG
        NSLog(
            "Speaker visual panel shown: layout=\(String(describing: layout)) "
                + "window=\(panel.windowNumber) "
                + "frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible)"
        )
#endif

    }

    private func repositionVisiblePanel() {
        guard let frame = Self.presentationScreen()?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 24
        )
        panel.setFrameOrigin(origin)
    }

    private static func presentationScreen() -> NSScreen? {
        if let focusedWindowScreen = focusedWindowScreen() {
            return focusedWindowScreen
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
    }

    private static func focusedWindowScreen() -> NSScreen? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &sizeValue
            ) == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeDowncast(positionValue, to: AXValue.self),
            .cgPoint,
            &position
        ), AXValueGetValue(
            unsafeDowncast(sizeValue, to: AXValue.self),
            .cgSize,
            &size
        ) else { return nil }

        let windowBounds = CGRect(origin: position, size: size)
        return NSScreen.screens.max { lhs, rhs in
            intersectionArea(of: lhs, with: windowBounds)
                < intersectionArea(of: rhs, with: windowBounds)
        }.flatMap { screen in
            intersectionArea(of: screen, with: windowBounds) > 0 ? screen : nil
        }
    }

    private static func intersectionArea(
        of screen: NSScreen,
        with quartzWindowBounds: CGRect
    ) -> CGFloat {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return 0
        }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        let intersection = displayBounds.intersection(quartzWindowBounds)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

#if DEBUG
    func captureDebugSnapshot(to url: URL) throws {
        hostingView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let bounds = hostingView.bounds
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: bounds
        ) else {
            throw VoiceInputHUDSnapshotError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw VoiceInputHUDSnapshotError.pngEncodingFailed
        }
        try data.write(to: url, options: .atomic)
    }
#endif
}

#if DEBUG
private enum VoiceInputHUDSnapshotError: Error {
    case bitmapUnavailable
    case pngEncodingFailed
}
#endif

/// Thin App-owned wrapper for the system Settings side effect. The production
/// HUD itself lives in SpeakerAppFeatures and remains directly hostable by UI
/// specs through the same interface used here.
private struct VoiceInputOverlay: View {
    let presentation: VoiceInputOverlayPresentation
    let performAction:
        (VoiceInputExperienceAction) -> VoiceInputExperienceEffect?
    let routeEffect: (VoiceInputExperienceEffect) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VoiceInputHUD(
            presentation: presentation,
            performAction: performAction,
            routeEffect: { effect in
                routeEffect(effect)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}
