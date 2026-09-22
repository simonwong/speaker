import AppKit
import SpeakerCore
import SwiftUI

package struct SpeakerOnboardingView: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var doubao: DoubaoSettingsModel
    @ObservedObject var recognition: SpeechRecognitionSettingsModel
    @State private var step: OnboardingStep = .permissions
    let completion: () -> Void
    let requestPermission: (PermissionKind) async -> Void
    let refreshPermissions: () -> Void
    let announce: AccessibilityAnnounce
    let buildInfo: SpeakerBuildInfoReader
    let shortcutName: () -> String
    let mode: OnboardingMode

    package init(
        permissions: PermissionModel,
        doubao: DoubaoSettingsModel,
        recognition: SpeechRecognitionSettingsModel,
        requestPermission: @escaping (PermissionKind) async -> Void,
        refreshPermissions: @escaping () -> Void,
        announce: @escaping AccessibilityAnnounce,
        buildInfo: SpeakerBuildInfoReader = .main,
        shortcutName: @escaping () -> String = { "Fn" },
        mode: OnboardingMode = .setup,
        completion: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.doubao = doubao
        self.recognition = recognition
        self.completion = completion
        self.requestPermission = requestPermission
        self.refreshPermissions = refreshPermissions
        self.announce = announce
        self.buildInfo = buildInfo
        self.shortcutName = shortcutName
        self.mode = mode
    }

    private var presentation: OnboardingPresentation {
        OnboardingPresentation(
            permissions: permissions.snapshot,
            doubaoStatus: doubao.status,
            hasStoredDoubaoKey: doubao.hasStoredKey,
            mode: mode,
            isUpdatingDoubaoKey: doubao.isUpdatingKey,
            recognitionProvider: recognition.selectedProvider,
            hasStoredRecognitionKey: recognition.hasStoredKey && recognition.hasValidProfile,
            isUpdatingRecognition: recognition.isMutating
        )
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                stepIndicator
                stepContent
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .buttonStyle(SettingsButtonStyle())
        .frame(minWidth: 360, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            refreshPermissions()
            await doubao.refresh()
            await recognition.refresh()
        }
        .onChange(of: permissions.snapshot) { previous, current in
            for permission in PermissionKind.allCases
            where previous[permission] != current[permission] {
                let name = permission == .microphone ? "麦克风" : "辅助功能"
                announce("\(name)：\(permissionStatus(current[permission]))")
            }
        }
        .onChange(of: doubao.status) { _, status in
            guard recognition.selectedProvider == .doubao else { return }
            switch status {
            case .checking: announce("正在检查豆包连接")
            case .success: announce("豆包连接成功，可以进入下一步")
            case .failure(let message): announce("豆包连接失败：\(message)")
            case .loading, .unconfigured, .configured: break
            }
        }
        .onChange(of: recognition.hasStoredKey) { _, stored in
            guard recognition.selectedProvider != .doubao else { return }
            announce(stored ? "语音识别 Key 已保存，首次录音时验证账号与模型" : "请保存当前语音识别服务的 Key")
        }
        .onChange(of: step) { _, current in
            announce("第 \(current.rawValue + 1) 步，共 3 步：\(current.title)")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            SpeakerIdentityTile(size: 48, accessibility: .named)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(.title2.bold())
                Text(stepDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepDescription: String {
        switch step {
        case .permissions: "先让 Speaker 听见你，并将文字输入其他应用。"
        case .apiKey: "选择语音识别服务，用自己的账号将语音转成文字。"
        case .shortcut: "记住键盘上的快捷键，就能在任何输入框中开始。"
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                HStack(spacing: 6) {
                    Text("\(item.rawValue + 1)")
                        .font(.caption.bold())
                        .frame(width: 24, height: 24)
                        .background(
                            item == step ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Circle()
                        )
                        .foregroundStyle(item == step ? Color.white : Color.secondary)
                    Text(item.shortTitle)
                        .font(.caption.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? .primary : .secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if item != .shortcut {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step.rawValue + 1) 步，共 3 步：\(step.title)")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .permissions:
            VStack(alignment: .leading, spacing: 16) {
                permissionCard(
                    .microphone, title: "麦克风", icon: "mic.fill", purpose: "用于听见你的声音。Speaker 不保存音频。")
                permissionCard(
                    .accessibility, title: "辅助功能", icon: "accessibility",
                    purpose: "用于响应键盘快捷键，并把文字输入你正在使用的应用。")
                Button("重新检查权限", action: refreshPermissions)
                    .font(.callout)
                if let notice = buildInfo.signingMode.permissionIdentityNotice {
                    SettingsNotice(text: notice, color: .orange)
                }
            }
        case .apiKey:
            VStack(alignment: .leading, spacing: 14) {
                SpeechRecognitionSettingsCard(model: recognition, doubao: doubao)
                Text("Key 只保存在这台 Mac。语音直接发送到所选服务，费用由服务商收取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("文字整理为可选项，之后可在设置中添加。默认模式直接使用识别结果；豆包保留原生语义顺滑。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .shortcut:
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("当前键盘快捷键")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(shortcutName())
                        .font(.title2.monospaced().bold())
                }
                tutorialRow(
                    icon: "hand.tap", title: "短按键盘快捷键", detail: "按一下 \(shortcutName()) 开始录音，再按一下结束。"
                )
                tutorialRow(
                    icon: "hand.point.up.left", title: "长按键盘快捷键",
                    detail: "按住 \(shortcutName()) 讲话，松开结束录音。")
                tutorialRow(icon: "escape", title: "按 Esc 取消", detail: "录音或处理中按 Esc，取消这次语音输入。")
                Text("打开任意应用的输入框，再使用键盘快捷键。录音结束时所在的输入框，就是文字的输入位置。快捷键可随时在设置中更改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func permissionCard(
        _ permission: PermissionKind,
        title: String,
        icon: String,
        purpose: String
    ) -> some View {
        let state = permissions.snapshot[permission]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Text(permissionStatus(state))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state == .granted ? Color.green : Color.secondary)
            }
            Text(purpose)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(presentation.permissionInstructions(for: permission))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = presentation.permissionAction(for: permission) {
                Button(action == .request ? "允许麦克风" : "打开\(title)设置") {
                    Task { await requestPermission(permission) }
                }
                .buttonStyle(SettingsButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tutorialRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if !presentation.canContinue(from: step) {
                Text(blockingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(mode == .review ? "关闭引导" : "稍后配置", action: completion)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
                    .overlay {
                        AccessibilityButtonBridge(
                            label: mode == .review ? "关闭引导" : "稍后配置", hint: "关闭首次设置，之后可在设置中完成配置。",
                            action: completion)
                    }
                Spacer(minLength: 4)
                if step != .permissions {
                    Button("上一步", action: previousStep)
                        .accessibilityHidden(true)
                        .overlay {
                            AccessibilityButtonBridge(label: "上一步", action: previousStep)
                        }
                }
                Button(
                    step == .shortcut ? (mode == .review ? "完成" : "开始使用 Speaker") : "下一步",
                    action: nextStep
                )
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(!presentation.canContinue(from: step))
                .keyboardShortcut(.defaultAction)
                .accessibilityHidden(true)
                .overlay {
                    AccessibilityButtonBridge(
                        label: step == .shortcut
                            ? (mode == .review ? "完成" : "开始使用 Speaker") : "下一步",
                        isEnabled: presentation.canContinue(from: step),
                        action: nextStep
                    )
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func previousStep() {
        step = step == .shortcut ? .apiKey : .permissions
    }

    private func nextStep() {
        guard presentation.canContinue(from: step) else { return }
        switch step {
        case .permissions: step = .apiKey
        case .apiKey: step = .shortcut
        case .shortcut: completion()
        }
    }

    private var blockingMessage: String {
        if !permissions.snapshot.allGranted {
            return step == .permissions
                ? "两项权限都开启后，点击「下一步」。也可以稍后在设置中完成。"
                : "权限尚未全部开启，请返回第一步检查。"
        }
        if recognition.selectedProvider != .doubao {
            return "保存所选语音识别服务的 Key 后继续；首次录音会发送音频并验证账号与模型。"
        }
        return "保存豆包 Key，选择已开通的资源，再点击「检查连接」。连接成功后继续。"
    }

    private func permissionStatus(_ state: PermissionState) -> String {
        switch state {
        case .granted: "已开启"
        case .denied: "未开启"
        case .notDetermined: "待允许"
        case .restricted: "受限制"
        }
    }
}
