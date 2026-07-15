import ApplicationServices
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
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
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
}
