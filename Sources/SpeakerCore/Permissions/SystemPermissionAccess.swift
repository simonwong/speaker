import AVFoundation
import AppKit
import ApplicationServices
import Foundation

package enum SystemPermissionRequestPlan: Equatable, Sendable {
    case none
    case requestMicrophone
    /// Asks macOS to list Speaker under Accessibility, then opens that pane.
    case registerAccessibilityThenOpenSystemSettings(anchor: String)
    case openSystemSettings(anchor: String)
}

@MainActor
public final class SystemPermissionAccess: PermissionAccess {
    /// `AXIsProcessTrusted()` never adds the app to the Accessibility list;
    /// only the prompting check does, and it shows a system alert each time.
    /// Prompt once per launch so the list has Speaker without repeat alerts.
    private var hasRegisteredAccessibility = false

    public init() {}

    public func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            microphone: microphoneState
        )
    }

    public func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        let snapshot = currentSnapshot()
        switch Self.requestPlan(
            for: permission,
            state: snapshot[permission],
            hasRegisteredAccessibility: hasRegisteredAccessibility
        ) {
        case .none:
            break
        case .requestMicrophone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .registerAccessibilityThenOpenSystemSettings(let anchor):
            hasRegisteredAccessibility = true
            // The literal value of `kAXTrustedCheckOptionPrompt`, which Swift 6
            // rejects as a mutable global.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacySettings(anchor: anchor)
        case .openSystemSettings(let anchor):
            openPrivacySettings(anchor: anchor)
        }

        return currentSnapshot()
    }

    package static func requestPlan(
        for permission: PermissionKind,
        state: PermissionState,
        hasRegisteredAccessibility: Bool = false
    ) -> SystemPermissionRequestPlan {
        switch (permission, state) {
        case (_, .granted), (_, .restricted):
            .none
        case (.accessibility, .denied), (.accessibility, .notDetermined):
            hasRegisteredAccessibility
                ? .openSystemSettings(anchor: "Privacy_Accessibility")
                : .registerAccessibilityThenOpenSystemSettings(
                    anchor: "Privacy_Accessibility"
                )
        case (.microphone, .notDetermined):
            .requestMicrophone
        case (.microphone, .denied):
            .openSystemSettings(anchor: "Privacy_Microphone")
        }
    }

    private var microphoneState: PermissionState {
        Self.microphoneState(
            for: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    package static func microphoneState(
        for status: AVAuthorizationStatus
    ) -> PermissionState {
        switch status {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}
