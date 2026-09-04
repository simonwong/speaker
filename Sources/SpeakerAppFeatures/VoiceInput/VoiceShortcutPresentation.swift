import SpeakerCore

extension VoiceShortcutNotice {
    package static let accessibilityRequiredMessage =
        "需要辅助功能权限；授权后，已选择的快捷键会自动生效。"
    package static let persistenceFailedMessage = "无法保存快捷键设置"
    package static let functionKeyActiveMessage = "Fn 快捷键已启用。"
    package static let functionKeyEventTapUnavailableMessage =
        "无法创建 Fn 键的系统事件监听。"
    package static let functionKeyRunLoopSourceUnavailableMessage =
        "Fn 键监听无法接入系统事件循环。"

    package var message: String {
        switch kind {
        case .accessibilityRequired:
            Self.accessibilityRequiredMessage
        case .functionKeyActivationFailed(let result):
            Self.functionKeyFailureMessage(result)
        case .fellBackToFunctionKey(let reason):
            "\(Self.fallbackReasonMessage(reason))，已继续使用 Fn。"
        case .fallbackUnavailable(let reason, let result):
            "\(Self.fallbackReasonMessage(reason))；\(Self.functionKeyFailureMessage(result))"
        case .persistenceFailed:
            Self.persistenceFailedMessage
        }
    }

    private static func fallbackReasonMessage(
        _ reason: FallbackReason
    ) -> String {
        switch reason {
        case .incompleteConfiguration:
            "自定义快捷键配置不完整"
        case .reservedForCancellation:
            "Esc 保留用于取消当前语音输入"
        case .editingConflict:
            "这个组合键可能与 macOS 或当前 App 的菜单命令冲突"
        case .unsafeShortcut:
            "请使用单独的左/右 ⌥、⌃、⇧，或安全的组合键"
        case .activationFailed(let result):
            customShortcutFailureMessage(result)
        }
    }

    private static func functionKeyFailureMessage(
        _ result: FunctionKeyMonitorStartResult
    ) -> String {
        switch result {
        case .active:
            functionKeyActiveMessage
        case .eventTapUnavailable:
            functionKeyEventTapUnavailableMessage
        case .runLoopSourceUnavailable:
            functionKeyRunLoopSourceUnavailableMessage
        }
    }

    private static func customShortcutFailureMessage(
        _ result: CustomShortcutRegistrationResult
    ) -> String {
        switch result {
        case .active:
            "自定义快捷键已启用"
        case .eventHandlerUnavailable:
            "无法安装自定义快捷键事件处理"
        case .hotKeyRegistrationUnavailable:
            "系统未接受这个自定义快捷键"
        case .shortcutEventTapUnavailable:
            "无法创建自定义快捷键的系统事件监听"
        case .shortcutRunLoopSourceUnavailable:
            "自定义快捷键监听无法接入系统事件循环"
        }
    }
}

extension VoiceShortcutPreference {
    /// Announced once a chosen shortcut becomes the live one.
    package var activationAnnouncement: String {
        "\(displayName) 快捷键已启用"
    }

    package var persistenceConfirmationMessage: String {
        "\(displayName) 快捷键设置已保存。"
    }
}
