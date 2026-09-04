import AppKit
import SpeakerAppFeatures
import SwiftUI

/// AppKit adapter for `MainWindowVisibilityFeature`. A window closing does not
/// imply that its SwiftUI content view has detached, so closure is observed
/// explicitly instead of being inferred from `NSView.window` alone.
struct MainWindowVisibilityBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MainWindowVisibilityObserverView {
        let view = MainWindowVisibilityObserverView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window)
        }
        return view
    }

    func updateNSView(
        _ nsView: MainWindowVisibilityObserverView,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject {
        private lazy var feature = MainWindowVisibilityFeature {
            policy in
            let appKitPolicy: NSApplication.ActivationPolicy =
                switch policy {
                case .accessory: .accessory
                case .regular: .regular
                }
            guard NSApp.activationPolicy() != appKitPolicy else { return }
            NSApp.setActivationPolicy(appKitPolicy)
        }
        private weak var observedWindow: NSWindow?

        func observe(_ window: NSWindow?) {
            if observedWindow === window { return }
            stopObservingWindow()
            guard let window else {
                feature.mainWindowWillClose()
                return
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            feature.mainWindowDidOpen()
        }

        @objc private func windowWillClose(_ notification: Notification) {
            guard notification.object as? NSWindow === observedWindow else {
                return
            }
            feature.mainWindowWillClose()
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            guard notification.object as? NSWindow === observedWindow else {
                return
            }
            feature.mainWindowDidOpen()
        }

        private func stopObservingWindow() {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didBecomeKeyNotification,
                    object: observedWindow
                )
            }
            observedWindow = nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

final class MainWindowVisibilityObserverView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}
