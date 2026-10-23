import SpeakerCore

/// What still stops the next Voice Input Session before the user presses
/// the shortcut: a missing runtime permission, or a selected Speech
/// Recognition Provider whose readiness is `.needsSetup` — no saved Key, an
/// on-device language model that is not installed, or a profile Speaker
/// cannot run.
///
/// The menu bar icon, the menu's first row, and the Overview banner all read
/// this one value, so an unconfigured Speaker never looks ready on any of
/// them. A Key that is saved but never checked is not a gap; the session
/// itself reports a rejected Key.
package enum VoiceInputSetupGap: Equatable, Sendable {
    case permissions
    case speechRecognitionKey(SpeechRecognitionProviderID)

    /// Permissions come first because recording cannot start without them.
    /// An unread Key or language model is not reported, so a configured
    /// Speaker does not flash a warning while it launches.
    package static func resolve(
        permissions: PermissionSnapshot,
        recognitionProvider: SpeechRecognitionProviderID,
        recognitionReadiness: SpeechRecognitionReadiness
    ) -> Self? {
        if !permissions.allGranted { return .permissions }
        if recognitionReadiness == .needsSetup { return .speechRecognitionKey(recognitionProvider) }
        return nil
    }

    @MainActor
    package static func current(
        permissions: PermissionSnapshot,
        recognition: SpeechRecognitionSettingsModel
    ) -> Self? {
        resolve(
            permissions: permissions,
            recognitionProvider: recognition.selectedProvider,
            recognitionReadiness: recognition.readiness
        )
    }

    package var settingsGroup: SettingsGroup {
        switch self {
        case .permissions: .permissions
        case .speechRecognitionKey: .speechRecognition
        }
    }

    package var menuTitle: String {
        switch self {
        case .permissions: "完成权限设置…"
        case .speechRecognitionKey: "设置语音识别…"
        }
    }
}
