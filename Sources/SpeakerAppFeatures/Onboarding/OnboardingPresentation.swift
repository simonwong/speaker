import SpeakerCore

package enum OnboardingPermissionAction: Equatable, Sendable {
    case request
    case openSystemSettings
}

package enum OnboardingMode: Equatable, Sendable {
    case setup
    case review
}

package enum OnboardingStep: Int, CaseIterable, Sendable {
    case permissions
    case apiKey
    case shortcut

    package var shortTitle: String {
        switch self {
        case .permissions: "权限"
        case .apiKey: "语音识别"
        case .shortcut: "快捷键"
        }
    }

    package var title: String {
        switch self {
        case .permissions: "允许必要权限"
        case .apiKey: "选择语音识别"
        case .shortcut: "学会快捷键"
        }
    }
}

package struct OnboardingPresentation: Equatable, Sendable {
    package let mode: OnboardingMode
    package let permissions: PermissionSnapshot
    package let recognitionReadiness: SpeechRecognitionReadiness
    package let isUpdatingRecognition: Bool

    package init(
        permissions: PermissionSnapshot,
        recognitionReadiness: SpeechRecognitionReadiness,
        mode: OnboardingMode = .setup,
        isUpdatingRecognition: Bool = false
    ) {
        self.mode = mode
        self.permissions = permissions
        self.recognitionReadiness = recognitionReadiness
        self.isUpdatingRecognition = isUpdatingRecognition
    }

    /// First-time setup accepts only full readiness: unlike the menu bar,
    /// it waits for Doubao's explicit connection check, and no Key, profile,
    /// or language-model change may be in progress.
    package var isReady: Bool {
        permissions.allGranted && !isUpdatingRecognition && recognitionReadiness == .ready
    }

    package func canContinue(from step: OnboardingStep) -> Bool {
        if mode == .review { return true }
        return switch step {
        case .permissions: permissions.allGranted
        case .apiKey, .shortcut: isReady
        }
    }

    /// The steps that grant a missing permission. A granted one has none: its
    /// badge already says so.
    package func permissionInstructions(for permission: PermissionKind) -> String? {
        switch (permission, permissions[permission]) {
        case (_, .granted):
            nil
        case (_, .restricted):
            "此权限受系统或组织限制，请联系这台 Mac 的管理员。"
        case (.microphone, .notDetermined):
            "点击「允许麦克风」，再在 macOS 弹窗中点击「允许」。"
        case (.microphone, .denied):
            "打开系统设置 → 隐私与安全性 → 麦克风，开启 Speaker。返回后会自动检查。"
        case (.accessibility, .notDetermined), (.accessibility, .denied):
            "打开系统设置 → 隐私与安全性 → 辅助功能，开启 Speaker。如列表没有 Speaker，点击 + 添加「应用程序」中的 Speaker。返回后会自动检查。"
        }
    }

    package func permissionAction(
        for permission: PermissionKind
    ) -> OnboardingPermissionAction? {
        switch permissions[permission] {
        case .notDetermined:
            permission == .microphone ? .request : .openSystemSettings
        case .denied: .openSystemSettings
        case .granted, .restricted: nil
        }
    }
}
