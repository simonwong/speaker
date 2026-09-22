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
        case .apiKey: "API Key"
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
    package let doubaoStatus: DoubaoConnectionStatus
    package let hasStoredDoubaoKey: Bool
    package let isUpdatingDoubaoKey: Bool
    package let recognitionProvider: SpeechRecognitionProviderID
    package let hasStoredRecognitionKey: Bool
    package let isUpdatingRecognition: Bool

    package init(
        permissions: PermissionSnapshot,
        doubaoStatus: DoubaoConnectionStatus,
        hasStoredDoubaoKey: Bool,
        mode: OnboardingMode = .setup,
        isUpdatingDoubaoKey: Bool = false,
        recognitionProvider: SpeechRecognitionProviderID = .doubao,
        hasStoredRecognitionKey: Bool = false,
        isUpdatingRecognition: Bool = false
    ) {
        self.mode = mode
        self.permissions = permissions
        self.doubaoStatus = doubaoStatus
        self.hasStoredDoubaoKey = hasStoredDoubaoKey
        self.isUpdatingDoubaoKey = isUpdatingDoubaoKey
        self.recognitionProvider = recognitionProvider
        self.hasStoredRecognitionKey = hasStoredRecognitionKey
        self.isUpdatingRecognition = isUpdatingRecognition
    }

    package var isReady: Bool {
        guard permissions.allGranted, !isUpdatingRecognition else { return false }
        if recognitionProvider != .doubao { return hasStoredRecognitionKey }
        return hasStoredDoubaoKey && connectionSucceeded && !isUpdatingDoubaoKey
    }

    private var connectionSucceeded: Bool {
        if case .success = doubaoStatus { true } else { false }
    }

    package func canContinue(from step: OnboardingStep) -> Bool {
        if mode == .review { return true }
        return switch step {
        case .permissions: permissions.allGranted
        case .apiKey, .shortcut: isReady
        }
    }

    package func permissionInstructions(for permission: PermissionKind) -> String {
        switch (permission, permissions[permission]) {
        case (_, .granted):
            "Speaker 已确认权限开启。"
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
