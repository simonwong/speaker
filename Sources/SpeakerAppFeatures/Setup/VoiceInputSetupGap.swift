import SpeakerCore

/// What still stops the next Voice Input Session before the user presses
/// the shortcut: a missing runtime permission, or a selected Speech
/// Recognition Provider with no saved Key.
///
/// The menu bar icon, the menu's first row, and the Overview banner all read
/// this one value, so an unconfigured Speaker never looks ready on any of
/// them. A Key that is saved but never checked is not a gap; the session
/// itself reports a rejected Key.
package enum VoiceInputSetupGap: Equatable, Sendable {
    case permissions
    case speechRecognitionKey(SpeechRecognitionProviderID)

    /// Permissions come first because recording cannot start without them.
    /// A Key whose presence has not been read yet is not reported, so a
    /// configured Speaker does not flash a warning while it launches.
    package static func resolve(
        permissions: PermissionSnapshot,
        recognitionProvider: SpeechRecognitionProviderID,
        hasRecognitionKey: Bool?
    ) -> Self? {
        if !permissions.allGranted { return .permissions }
        if hasRecognitionKey == false { return .speechRecognitionKey(recognitionProvider) }
        return nil
    }

    /// Doubao's Key belongs to `DoubaoSettingsModel`; the other providers'
    /// Keys belong to `SpeechRecognitionSettingsModel`. Each reports `nil`
    /// until it has read its credential.
    @MainActor
    package static func current(
        permissions: PermissionSnapshot,
        doubao: DoubaoSettingsModel,
        recognition: SpeechRecognitionSettingsModel
    ) -> Self? {
        let provider = recognition.selectedProvider
        let hasKey: Bool?
        if !recognition.hasLoaded {
            hasKey = nil
        } else if provider == .doubao {
            hasKey = doubao.status == .loading ? nil : doubao.hasConfiguredKey
        } else {
            hasKey = recognition.hasStoredKey
        }
        return resolve(
            permissions: permissions,
            recognitionProvider: provider,
            hasRecognitionKey: hasKey
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

    package var message: String {
        switch self {
        case .permissions:
            "Speaker 还没有麦克风或辅助功能权限，暂时不能录音。"
        case .speechRecognitionKey(let provider):
            "还没有保存\(provider.displayName)的 API Key，暂时不能识别。"
        }
    }

    package var actionTitle: String {
        switch self {
        case .permissions: "去允许"
        case .speechRecognitionKey: "去设置"
        }
    }
}
