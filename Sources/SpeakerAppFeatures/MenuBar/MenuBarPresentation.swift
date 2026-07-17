import SpeakerCore

package enum MenuBarPresentation {
    package static func systemImage(
        isRecording: Bool,
        permissions: PermissionSnapshot
    ) -> String {
        if isRecording {
            return "waveform.circle.fill"
        }
        return permissions.allGranted
            ? "waveform"
            : "waveform.badge.exclamationmark"
    }
}
