import ApplicationServices
import AppKit
import AVFoundation
import Foundation

@MainActor
public final class SystemPermissionAccess: PermissionAccess {
    public init() {}

    public func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            microphone: microphoneState
        )
    }

    public func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        switch permission {
        case .accessibility:
            if AXIsProcessTrusted() {
                break
            }
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacySettings(anchor: "Privacy_Accessibility")
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                openPrivacySettings(anchor: "Privacy_Microphone")
            } else {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        }

        return currentSnapshot()
    }

    private var microphoneState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
