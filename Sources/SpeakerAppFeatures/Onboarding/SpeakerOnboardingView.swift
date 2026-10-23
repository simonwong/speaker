import AppKit
import SpeakerCore
import SwiftUI

package struct SpeakerOnboardingView: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var recognition: SpeechRecognitionSettingsModel
    @State private var step: OnboardingStep = .permissions
    @State private var movesForward = true
    /// Practice text typed by a first dictation; it lives only in this view.
    @State private var practiceText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let completion: () -> Void
    let requestPermission: (PermissionKind) async -> Void
    let refreshPermissions: () -> Void
    let announce: AccessibilityAnnounce
    let shortcutName: () -> String
    let mode: OnboardingMode
    /// Offers the automatic-update choice on the last step of first-time setup.
    let softwareUpdate: SoftwareUpdateFeature?

    package init(
        permissions: PermissionModel,
        recognition: SpeechRecognitionSettingsModel,
        requestPermission: @escaping (PermissionKind) async -> Void,
        refreshPermissions: @escaping () -> Void,
        announce: @escaping AccessibilityAnnounce,
        shortcutName: @escaping () -> String = { "Fn" },
        mode: OnboardingMode = .setup,
        softwareUpdate: SoftwareUpdateFeature? = nil,
        completion: @escaping () -> Void
    ) {
        self.softwareUpdate = softwareUpdate
        self.permissions = permissions
        self.recognition = recognition
        self.completion = completion
        self.requestPermission = requestPermission
        self.refreshPermissions = refreshPermissions
        self.announce = announce
        self.shortcutName = shortcutName
        self.mode = mode
    }

    private var presentation: OnboardingPresentation {
        OnboardingPresentation(
            permissions: permissions.snapshot,
            recognitionReadiness: recognition.readiness,
            mode: mode,
            isUpdatingRecognition: recognition.isMutating
        )
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeakerSpacing.xl) {
                header
                stepIndicator
                stepContent
            }
            .padding(.horizontal, SpeakerSpacing.xl)
            .padding(.top, SpeakerSurfaceMetrics.pageTopPadding)
            .padding(.bottom, SpeakerSpacing.l)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .buttonStyle(SpeakerButtonStyle())
        .frame(minWidth: 360, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            refreshPermissions()
            await recognition.refresh()
        }
        .onChange(of: permissions.snapshot) { previous, current in
            for permission in PermissionKind.allCases
            where previous[permission] != current[permission] {
                let name = permission == .microphone ? "麦克风" : "辅助功能"
                announce("\(name)：\(PermissionStatusPresentation(state: current[permission]).text)")
            }
        }
        .onChange(of: recognition.doubaoStatus) { _, status in
            guard recognition.selectedProvider == .doubao else { return }
            switch status {
            case .checking: announce("正在检查豆包连接")
            case .success: announce("豆包连接成功，可以进入下一步")
            case .failure(let message): announce("豆包连接失败：\(message)")
            case .loading, .unconfigured, .configured: break
            }
        }
        .onChange(of: recognition.hasStoredKey) { _, stored in
            guard recognition.selectedProvider != .doubao,
                !recognition.selectedProvider.isOnDevice
            else { return }
            announce(stored ? "语音识别 Key 已保存，首次录音时验证账号与模型" : "请保存当前语音识别服务的 Key")
        }
        .onChange(of: recognition.onDeviceModelStatus) { _, status in
            guard recognition.selectedProvider.isOnDevice, status == .installed else { return }
            announce("语言模型已就绪，可以进入下一步")
        }
        .onChange(of: step) { _, current in
            announce("第 \(current.rawValue + 1) 步，共 3 步：\(current.title)")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SpeakerSpacing.m) {
            SpeakerIdentityTile(size: 48, accessibility: .named)
            VStack(alignment: .leading, spacing: SpeakerSpacing.xs) {
                Text(step.title)
                    .font(SpeakerTypography.title)
                if let stepDescription {
                    Text(stepDescription)
                        .font(SpeakerTypography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Only the provider step needs a line under its title: the rows of the
    /// other steps already say what each item is for.
    private var stepDescription: String? {
        switch step {
        case .apiKey: "云端服务使用你自己的 Key。"
        case .permissions, .shortcut: nil
        }
    }

    /// Completed steps trade their number for a checkmark, the current step
    /// takes the coral, and later steps keep their number.
    private var stepIndicator: some View {
        HStack(spacing: SpeakerSpacing.s) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                HStack(spacing: SpeakerSpacing.s) {
                    stepMarker(item)
                    Text(item.shortTitle)
                        .font(item == step ? SpeakerTypography.label : SpeakerTypography.detail)
                        .foregroundStyle(item == step ? .primary : .secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if item != .shortcut {
                    Rectangle()
                        .fill(SpeakerStroke.hairline(increasedContrast: false))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step.rawValue + 1) 步，共 3 步：\(step.title)")
    }

    private func stepMarker(_ item: OnboardingStep) -> some View {
        let isCurrent = item == step
        let isCompleted = item.rawValue < step.rawValue
        return Group {
            if isCompleted {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
            } else {
                Text("\(item.rawValue + 1)")
                    .monospacedDigit()
            }
        }
        .font(SpeakerTypography.label)
        .foregroundStyle(isCurrent ? Color.white : Color.secondary)
        .frame(width: Self.stepMarkerSide, height: Self.stepMarkerSide)
        .background(
            isCurrent ? SpeakerVisualIdentity.controlTint : SpeakerFill.selected,
            in: Circle()
        )
    }

    private static let stepMarkerSide: CGFloat = 24

    /// One step at a time: the next step slides in from the side it lies on
    /// while the last one only fades. Reduce Motion keeps only the fade.
    private var stepContent: some View {
        ZStack(alignment: .topLeading) {
            content(for: step)
                .id(step)
                .transition(stepTransition)
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: movesForward ? 16 : -16)),
            removal: .opacity
        )
    }

    @ViewBuilder
    private func content(for step: OnboardingStep) -> some View {
        switch step {
        case .permissions:
            VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.cardSpacing) {
                SpeakerCard {
                    permissionRow(
                        .microphone, title: "麦克风", icon: "mic.fill",
                        purpose: "录制语音，Speaker 不保存音频")
                    SpeakerRowDivider()
                    permissionRow(
                        .accessibility, title: "辅助功能", icon: "accessibility",
                        purpose: "响应快捷键并输入文字")
                }
                if !permissions.snapshot.allGranted {
                    Button("重新检查权限", action: refreshPermissions)
                }
            }
        case .apiKey:
            VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.sectionHeaderSpacing) {
                SpeakerSectionHeader("语音识别")
                SpeechRecognitionSettingsCard(model: recognition)
                    .environment(\.collapsesStoredProviderKeys, false)
            }
        case .shortcut:
            VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.cardSpacing) {
                SpeakerCard {
                    SpeakerRow("当前键盘快捷键") {
                        SpeakerKeycap(name: shortcutName())
                    }
                    if shortcutName() == VoiceShortcutPreference.functionKey.displayName {
                        FunctionKeyConflictHint()
                    }
                    SpeakerRowDivider()
                    // The title names the physical key, so the detail never
                    // repeats it.
                    SpeakerRow("短按 \(shortcutName())", detail: "开始录音，再按一下结束")
                    SpeakerRowDivider()
                    SpeakerRow("按住 \(shortcutName())", detail: "说话，松开结束")
                    SpeakerRowDivider()
                    SpeakerRow("按 Esc", detail: "录音或处理中取消本次输入")
                }
                SpeakerCard {
                    practiceField
                }
                if mode == .setup, let softwareUpdate {
                    OnboardingAutomaticUpdateChoice(model: softwareUpdate)
                }
            }
        }
    }

    /// The same row Settings shows for a permission, followed by the steps
    /// that grant it while it is still missing. The steps line up with the
    /// row's title, past the icon tile.
    private func permissionRow(
        _ permission: PermissionKind,
        title: String,
        icon: String,
        purpose: String
    ) -> some View {
        let state = permissions.snapshot[permission]
        let status = PermissionStatusPresentation(state: state)
        let instructions = presentation.permissionInstructions(for: permission)
        let action = presentation.permissionAction(for: permission)
        return VStack(alignment: .leading, spacing: SpeakerSpacing.s) {
            SpeakerRow(title, detail: purpose, icon: icon, iconTone: status.tileTone) {
                StatusBadge(
                    text: status.text,
                    icon: status.symbolName,
                    tone: status.tone
                )
            }
            if instructions != nil || action != nil {
                VStack(alignment: .leading, spacing: SpeakerSpacing.s) {
                    if let instructions {
                        Text(instructions)
                            .font(SpeakerTypography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action {
                        Button(action == .request ? "允许麦克风" : "打开\(title)设置") {
                            Task { await requestPermission(permission) }
                        }
                    }
                }
                .padding(.leading, SpeakerControlMetrics.height + SpeakerSpacing.m)
            }
        }
    }

    /// A real Input Target inside onboarding, so the first dictation shows
    /// text arriving without leaving setup. Nothing typed here is kept.
    private var practiceField: some View {
        VStack(alignment: .leading, spacing: SpeakerSpacing.s) {
            Text("试一试")
                .font(SpeakerTypography.emphasis)
            TextField(
                "点这里，再用 \(shortcutName()) 说一句话",
                text: $practiceText,
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(SpeakerMultilineTextFieldStyle())
            .accessibilityLabel("练习输入框")
            Text("文字会输入到结束录音时所在的输入框。")
                .font(SpeakerTypography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SpeakerSpacing.m) {
            Divider()
            if !presentation.canContinue(from: step) {
                SpeakerNotice(text: blockingMessage)
            }
            HStack(spacing: SpeakerSpacing.s) {
                Button(mode == .review ? "关闭引导" : "稍后配置", action: completion)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
                    .overlay {
                        AccessibilityButtonBridge(
                            label: mode == .review ? "关闭引导" : "稍后配置", hint: "关闭首次设置，之后可在设置中完成配置。",
                            action: completion)
                    }
                Spacer(minLength: SpeakerSpacing.xs)
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
                .buttonStyle(SpeakerButtonStyle(prominent: true))
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
        .padding(.horizontal, SpeakerSpacing.xl)
        .padding(.bottom, SpeakerSpacing.l)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func previousStep() {
        go(to: step == .shortcut ? .apiKey : .permissions)
    }

    private func nextStep() {
        guard presentation.canContinue(from: step) else { return }
        switch step {
        case .permissions: go(to: .apiKey)
        case .apiKey: go(to: .shortcut)
        case .shortcut:
            // Finishing first-time setup confirms the automatic-update choice;
            // 稍后配置 and review mode record nothing.
            if mode == .setup { softwareUpdate?.finishSetup() }
            completion()
        }
    }

    private func go(to destination: OnboardingStep) {
        movesForward = destination.rawValue > step.rawValue
        withAnimation(SpeakerMotion.change) {
            step = destination
        }
    }

    private var blockingMessage: String {
        if !permissions.snapshot.allGranted {
            return step == .permissions
                ? "开启两项权限后继续。"
                : "权限尚未全部开启，请返回第一步。"
        }
        if recognition.selectedProvider.isOnDevice {
            return "下载 Apple 语音识别的语言模型后继续。"
        }
        if recognition.selectedProvider != .doubao {
            return "保存所选语音识别服务的 Key 后继续。"
        }
        return "保存豆包 Key、选择已开通的资源，再点「检查连接」。"
    }
}

/// The automatic-update switch on the last step of first-time setup. It starts
/// on; 「开始使用 Speaker」 records it, and Settings changes it later.
private struct OnboardingAutomaticUpdateChoice: View {
    @ObservedObject var model: SoftwareUpdateFeature

    var body: some View {
        if model.offersSetupAutomaticChecksChoice {
            SpeakerRow("自动检查更新", detail: "每天检查一次，有新版本时提醒你安装") {
                Toggle("自动检查更新", isOn: $model.setupAutomaticChecksChoice)
                    .speakerSwitch()
                    .labelsHidden()
            }
            .speakerCard()
        }
    }
}
