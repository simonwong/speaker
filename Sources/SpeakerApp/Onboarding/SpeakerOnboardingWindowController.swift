import AppKit
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

@MainActor
final class SpeakerOnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let permissions: PermissionModel
    private let doubao: DoubaoSettingsModel
    private let requestPermission: (PermissionKind) async -> Void
    private let refreshPermissions: () -> Void
    private let announce: AccessibilityAnnounce
    private let completion: () -> Void

    init(
        permissions: PermissionModel,
        doubao: DoubaoSettingsModel,
        requestPermission: @escaping (PermissionKind) async -> Void,
        refreshPermissions: @escaping () -> Void,
        announce: @escaping AccessibilityAnnounce,
        completion: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.doubao = doubao
        self.requestPermission = requestPermission
        self.refreshPermissions = refreshPermissions
        self.announce = announce
        self.completion = completion
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = SpeakerOnboardingView(
            permissions: permissions,
            doubao: doubao,
            requestPermission: requestPermission,
            refreshPermissions: refreshPermissions,
            announce: announce,
            completion: completion
        )
        let visibleFrame =
            NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 640, height: 680)
        let window = OnboardingWindowFactory.make(
            visibleFrame: visibleFrame,
            contentView: NSHostingView(rootView: content)
        )
        window.center()
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window?.contentView = nil
        window = nil
    }

    #if DEBUG
        func resizeDebug(to size: CGSize) {
            let debugMinimum = CGSize(width: 360, height: 360)
            window?.minSize = debugMinimum
            window?.contentMinSize = debugMinimum
            window?.setContentSize(size)
            window?.center()
        }

        func captureDebugSnapshot(to url: URL) throws {
            guard let contentView = window?.contentView else {
                throw OnboardingSnapshotError.windowUnavailable
            }
            contentView.layoutSubtreeIfNeeded()
            let bounds = contentView.bounds
            guard
                let representation = contentView.bitmapImageRepForCachingDisplay(
                    in: bounds
                )
            else {
                throw OnboardingSnapshotError.bitmapUnavailable
            }
            contentView.cacheDisplay(in: bounds, to: representation)
            guard
                let data = representation.representation(
                    using: .png,
                    properties: [:]
                )
            else {
                throw OnboardingSnapshotError.pngEncodingFailed
            }
            try data.write(to: url, options: .atomic)
        }
    #endif
}

#if DEBUG
    private enum OnboardingSnapshotError: Error {
        case windowUnavailable
        case bitmapUnavailable
        case pngEncodingFailed
    }
#endif
