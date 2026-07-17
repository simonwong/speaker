package enum LoginItemServiceState: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

package enum LoginItemRegistrationState: Equatable, Sendable {
    case disabled
    case enabled
    case awaitingApproval
    case registrationMissing
    case unavailable
}

package struct LoginItemPresentation: Equatable, Sendable {
    package let registrationState: LoginItemRegistrationState
    package let isEnabled: Bool
    package let notice: String?
    package let showsSystemSettingsButton: Bool

    package init(
        desiredEnabled: Bool,
        serviceState: LoginItemServiceState
    ) {
        switch serviceState {
        case .enabled:
            registrationState = .enabled
            isEnabled = true
            notice = desiredEnabled
                ? nil
                : "登录项已在系统设置中启用；关闭开关即可停用。"
            showsSystemSettingsButton = false
        case .requiresApproval:
            registrationState = .awaitingApproval
            isEnabled = true
            notice = "已请求登录时启动，需要在系统设置的“登录项”中批准。"
            showsSystemSettingsButton = true
        case .notRegistered where desiredEnabled:
            registrationState = .registrationMissing
            isEnabled = false
            notice = "登录时启动已在系统中关闭；打开开关可以重新启用。"
            showsSystemSettingsButton = false
        case .notRegistered:
            registrationState = .disabled
            isEnabled = false
            notice = nil
            showsSystemSettingsButton = false
        case .notFound:
            registrationState = .unavailable
            isEnabled = false
            notice = "当前 Speaker 构建无法注册登录项。"
            showsSystemSettingsButton = false
        }
    }
}
