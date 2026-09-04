import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI

@MainActor
private final class NonactivatingVoiceInputPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct VoiceInputPanelDismissal: Equatable, Sendable {
    let collapsesActivity: Bool
    let fadeDuration: TimeInterval
    let completionDelay: Duration
    fileprivate let revision: UInt
}

private struct VoiceInputPanelTransitionState: Sendable {
    private(set) var presentedLayout: VoiceInputPanelLayout?
    private var revision: UInt = 0

    mutating func present(_ layout: VoiceInputPanelLayout) {
        revision &+= 1
        presentedLayout = layout
    }

    mutating func dismiss(reduceMotion: Bool) -> VoiceInputPanelDismissal {
        revision &+= 1
        let collapsesActivity =
            switch presentedLayout {
            case .recording, .processing:
                !reduceMotion
            case .pendingCopy, .problem, nil:
                false
            }
        presentedLayout = nil
        return VoiceInputPanelDismissal(
            collapsesActivity: collapsesActivity,
            fadeDuration: collapsesActivity ? 0.2 : 0.12,
            completionDelay: collapsesActivity
                ? .milliseconds(220)
                : .milliseconds(140),
            revision: revision
        )
    }

    func canComplete(_ dismissal: VoiceInputPanelDismissal) -> Bool {
        presentedLayout == nil && dismissal.revision == revision
    }

    mutating func stop() {
        revision &+= 1
        presentedLayout = nil
    }
}

@MainActor
private enum VoiceInputPanelFactory {
    static func make(contentRect: NSRect) -> NSPanel {
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
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.animationBehavior = .none
        return panel
    }

    static func install(_ contentView: NSView, in panel: NSPanel) {
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.isOpaque = false
        panel.contentView = contentView
    }

    static func apply(_ layout: VoiceInputPanelLayout, to panel: NSPanel) {
        panel.setContentSize(layout.size)
        panel.contentView?.frame = NSRect(origin: .zero, size: layout.size)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }
}

private struct VoiceInputPanelDismissalEnvironmentKey: EnvironmentKey {
    static let defaultValue: VoiceInputPanelDismissal? = nil
}

extension EnvironmentValues {
    var voiceInputPanelDismissal: VoiceInputPanelDismissal? {
        get { self[VoiceInputPanelDismissalEnvironmentKey.self] }
        set { self[VoiceInputPanelDismissalEnvironmentKey.self] = newValue }
    }
}

@MainActor
private final class VoiceInputPanelAnimationState: ObservableObject {
    @Published var dismissal: VoiceInputPanelDismissal?
}

private struct VoiceInputPanelHost<Content: View>: View {
    let presentation: VoiceInputOverlayPresentation
    let content: (VoiceInputOverlayPresentation) -> Content
    @ObservedObject var animationState: VoiceInputPanelAnimationState

    var body: some View {
        content(presentation)
            .environment(
                \.voiceInputPanelDismissal,
                animationState.dismissal
            )
    }
}

#if DEBUG
    package struct VoiceInputPanelEvidence: Equatable, Sendable {
        package let isBorderless: Bool
        package let isNonactivating: Bool
        package let becomesKeyOnlyIfNeeded: Bool
        package let canBecomeKey: Bool
        package let canBecomeMain: Bool
        package let hidesOnDeactivate: Bool
        package let joinsAllSpaces: Bool
        package let appearsOverFullScreen: Bool
        package let hostingSurfaceIsLayerBacked: Bool
        package let hostingSurfaceIsOpaque: Bool?
        package let hostingSurfaceBackgroundAlpha: CGFloat?
        package let windowSize: CGSize
        package let contentSize: CGSize?
        package let isVisible: Bool
        package let isKeyWindow: Bool
        package let isCollapsingActivity: Bool
    }

    package struct VoiceInputPanelAccessibilityButtonEvidence: Equatable {
        package let label: String?
        package let frame: NSRect
    }

    package struct VoiceInputPanelVisualEffectEvidence: Equatable {
        package let material: NSVisualEffectView.Material
        package let blendingMode: NSVisualEffectView.BlendingMode
        package let state: NSVisualEffectView.State
    }
#endif

/// Presents every Voice Input HUD state through one AppKit lifecycle.
///
/// Callers provide SwiftUI content for the semantic presentation. Panel
/// configuration, geometry, placement, transitions, and delayed-dismissal
/// fencing remain behind this interface.
@MainActor
package final class VoiceInputPanelPresenter<Content: View> {
    private let panel: NSPanel
    private let hostingView: NSHostingView<VoiceInputPanelHost<Content>>
    private let content: (VoiceInputOverlayPresentation) -> Content
    private let animationState: VoiceInputPanelAnimationState
    private let reduceMotion: () -> Bool
    private let scheduleDismissal:
        @MainActor (
            Duration,
            @escaping @MainActor () -> Void
        ) -> Void
    private var placementCancellables: Set<AnyCancellable> = []
    private var transitionState = VoiceInputPanelTransitionState()

    package init(
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        scheduleDismissal:
            @escaping @MainActor (
                Duration,
                @escaping @MainActor () -> Void
            ) -> Void = { delay, completion in
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    completion()
                }
            },
        @ViewBuilder content:
            @escaping (VoiceInputOverlayPresentation) -> Content
    ) {
        self.content = content
        self.reduceMotion = reduceMotion
        self.scheduleDismissal = scheduleDismissal

        let animationState = VoiceInputPanelAnimationState()
        self.animationState = animationState
        hostingView = NSHostingView(
            rootView: Self.rootView(
                presentation: .hidden,
                content: content,
                animationState: animationState
            ))

        let initialSize = VoiceInputPanelLayout.processing.size
        panel = VoiceInputPanelFactory.make(
            contentRect: NSRect(origin: .zero, size: initialSize)
        )
        hostingView.autoresizingMask = [.width, .height]
        VoiceInputPanelFactory.install(hostingView, in: panel)

    }

    package func start() {
        guard placementCancellables.isEmpty else { return }
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

    package func stop() {
        placementCancellables.removeAll()
        transitionState.stop()
        animationState.dismissal = nil
        panel.orderOut(nil)
        panel.close()
    }

    #if DEBUG
        package var evidence: VoiceInputPanelEvidence {
            VoiceInputPanelEvidence(
                isBorderless: panel.styleMask.contains(.borderless),
                isNonactivating: panel.styleMask.contains(.nonactivatingPanel),
                becomesKeyOnlyIfNeeded: panel.becomesKeyOnlyIfNeeded,
                canBecomeKey: panel.canBecomeKey,
                canBecomeMain: panel.canBecomeMain,
                hidesOnDeactivate: panel.hidesOnDeactivate,
                joinsAllSpaces: panel.collectionBehavior.contains(.canJoinAllSpaces),
                appearsOverFullScreen: panel.collectionBehavior.contains(
                    .fullScreenAuxiliary
                ),
                hostingSurfaceIsLayerBacked: hostingView.wantsLayer,
                hostingSurfaceIsOpaque: hostingView.layer?.isOpaque,
                hostingSurfaceBackgroundAlpha:
                    hostingView.layer?.backgroundColor?.alpha,
                windowSize: panel.frame.size,
                contentSize: panel.contentView?.frame.size,
                isVisible: panel.isVisible,
                isKeyWindow: panel.isKeyWindow,
                isCollapsingActivity: animationState.dismissal != nil
            )
        }
    #endif

    package func present(_ presentation: VoiceInputOverlayPresentation) {
        guard let layout = VoiceInputPanelLayout(presentation) else {
            dismiss()
            return
        }

        let previousLayout = transitionState.presentedLayout
        transitionState.present(layout)
        let wasVisible = panel.isVisible
        let needsPlacement = previousLayout != layout || !wasVisible

        VoiceInputPanelFactory.apply(layout, to: panel)
        animationState.dismissal = nil
        hostingView.rootView = Self.rootView(
            presentation: presentation,
            content: content,
            animationState: animationState
        )
        if needsPlacement {
            repositionVisiblePanel()
        }

        let targetFrame = panel.frame
        if !wasVisible {
            panel.alphaValue = 0
            panel.setFrame(
                targetFrame.offsetBy(dx: 0, dy: -6),
                display: false
            )
        }
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = wasVisible ? 0.12 : 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                if !wasVisible {
                    panel.animator().setFrame(targetFrame, display: true)
                }
            }
        }
        panel.displayIfNeeded()
        #if DEBUG
            NSLog(
                "Speaker visual panel shown: layout=\(String(describing: layout)) "
                    + "window=\(panel.windowNumber) "
                    + "frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible)"
            )
        #endif
    }

    private func dismiss() {
        let dismissal = transitionState.dismiss(reduceMotion: reduceMotion())
        guard panel.isVisible else {
            animationState.dismissal = nil
            hostingView.rootView = Self.rootView(
                presentation: .hidden,
                content: content,
                animationState: animationState
            )
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        animationState.dismissal =
            dismissal.collapsesActivity
            ? dismissal
            : nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = dismissal.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        scheduleDismissal(dismissal.completionDelay) { [weak self] in
            guard let self,
                self.transitionState.canComplete(dismissal)
            else { return }
            self.panel.orderOut(nil)
            self.hostingView.rootView = Self.rootView(
                presentation: .hidden,
                content: self.content,
                animationState: self.animationState
            )
            self.animationState.dismissal = nil
            self.panel.alphaValue = 1
        }
    }

    private static func rootView(
        presentation: VoiceInputOverlayPresentation,
        content: @escaping (VoiceInputOverlayPresentation) -> Content,
        animationState: VoiceInputPanelAnimationState
    ) -> VoiceInputPanelHost<Content> {
        VoiceInputPanelHost(
            presentation: presentation,
            content: content,
            animationState: animationState
        )
    }

    private func repositionVisiblePanel() {
        guard let frame = Self.presentationScreen()?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + 24
            ))
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

        let applicationElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        _ = AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        var windowValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
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
        guard
            AXUIElementCopyAttributeValue(
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
        guard
            AXValueGetValue(
                unsafeDowncast(positionValue, to: AXValue.self),
                .cgPoint,
                &position
            ),
            AXValueGetValue(
                unsafeDowncast(sizeValue, to: AXValue.self),
                .cgSize,
                &size
            )
        else { return nil }

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
        guard
            let screenNumber = screen.deviceDescription[screenNumberKey]
                as? NSNumber
        else { return 0 }
        let displayBounds = CGDisplayBounds(
            CGDirectDisplayID(screenNumber.uint32Value)
        )
        let intersection = displayBounds.intersection(quartzWindowBounds)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    #if DEBUG
        package func captureDebugSnapshot(to url: URL) throws {
            let representation = try renderedBitmap()
            guard
                let data = representation.representation(
                    using: .png,
                    properties: [:]
                )
            else {
                throw VoiceInputHUDSnapshotError.pngEncodingFailed
            }
            try data.write(to: url, options: .atomic)
        }

        package func renderedBitmap() throws -> NSBitmapImageRep {
            hostingView.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            let bounds = hostingView.bounds
            guard
                let representation = hostingView.bitmapImageRepForCachingDisplay(
                    in: bounds
                )
            else {
                throw VoiceInputHUDSnapshotError.bitmapUnavailable
            }
            hostingView.cacheDisplay(in: bounds, to: representation)
            return representation
        }

        package var accessibilityButtonEvidence: [VoiceInputPanelAccessibilityButtonEvidence] {
            accessibilityButtons().map { button in
                VoiceInputPanelAccessibilityButtonEvidence(
                    label: button.accessibilityLabel(),
                    frame: button.accessibilityFrame()
                )
            }
        }

        package func pressAccessibilityButton(label: String) -> Bool {
            guard
                let button = accessibilityButtons().first(where: {
                    $0.accessibilityLabel() == label
                })
            else { return false }
            return button.accessibilityPerformPress()
        }

        package var visualEffectEvidence: [VoiceInputPanelVisualEffectEvidence] {
            visualEffectViews().map { effect in
                VoiceInputPanelVisualEffectEvidence(
                    material: effect.material,
                    blendingMode: effect.blendingMode,
                    state: effect.state
                )
            }
        }

        private func accessibilityButtons() -> [NSAccessibilityButton] {
            hostingView.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            var buttons: [NSAccessibilityButton] = []

            func visit(_ view: NSView) {
                let identifier = ObjectIdentifier(view)
                guard visited.insert(identifier).inserted else { return }
                if view.isAccessibilityElement(),
                    let button = view as? NSAccessibilityButton
                {
                    buttons.append(button)
                }
                view.subviews.forEach(visit)
            }

            visit(hostingView)
            return buttons
        }

        private func visualEffectViews() -> [NSVisualEffectView] {
            var effects: [NSVisualEffectView] = []

            func visit(_ view: NSView) {
                if let effect = view as? NSVisualEffectView {
                    effects.append(effect)
                }
                view.subviews.forEach(visit)
            }

            visit(hostingView)
            return effects
        }
    #endif
}

#if DEBUG
    private enum VoiceInputHUDSnapshotError: Error {
        case bitmapUnavailable
        case pngEncodingFailed
    }
#endif
