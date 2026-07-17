import ApplicationServices
import AppKit
import AVFoundation
import Foundation

package enum SystemPermissionRequestPlan: Equatable, Sendable {
    case none
    case requestMicrophone
    case openSystemSettings(anchor: String)
}

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
        let snapshot = currentSnapshot()
        switch Self.requestPlan(for: permission, state: snapshot[permission]) {
        case .none:
            break
        case .requestMicrophone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case let .openSystemSettings(anchor):
            openPrivacySettings(anchor: anchor)
        }

        return currentSnapshot()
    }

    package static func requestPlan(
        for permission: PermissionKind,
        state: PermissionState
    ) -> SystemPermissionRequestPlan {
        switch (permission, state) {
        case (_, .granted), (_, .restricted):
            .none
        case (.accessibility, .denied), (.accessibility, .notDetermined):
            .openSystemSettings(anchor: "Privacy_Accessibility")
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
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
