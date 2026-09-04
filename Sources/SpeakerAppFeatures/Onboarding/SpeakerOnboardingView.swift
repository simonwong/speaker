import AppKit
import SpeakerCore
import SwiftUI

package struct SpeakerOnboardingView: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var doubao: DoubaoSettingsModel
    let completion: () -> Void
    let requestPermission: (PermissionKind) async -> Void
    let refreshPermissions: () -> Void
    let announce: AccessibilityAnnounce
    let buildInfo: SpeakerBuildInfoReader

    package init(
        permissions: PermissionModel,
        doubao: DoubaoSettingsModel,
        requestPermission: @escaping (PermissionKind) async -> Void,
        refreshPermissions: @escaping () -> Void,
        announce: @escaping AccessibilityAnnounce,
        buildInfo: SpeakerBuildInfoReader = .main,
        completion: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.doubao = doubao
        self.completion = completion
        self.requestPermission = requestPermission
        self.refreshPermissions = refreshPermissions
        self.announce = announce
        self.buildInfo = buildInfo
    }

    private var ready: Bool {
        presentation.isReady
    }

    private var isCheckingConnection: Bool {
        presentation.isCheckingConnection
    }

    private var presentation: OnboardingPresentation {
        OnboardingPresentation(
            permissions: permissions.snapshot,
            doubaoStatus: doubao.status,
            hasStoredDoubaoKey: doubao.hasStoredKey
        )
    }

    private var signingMode: SpeakerSigningMode {
        buildInfo.signingMode
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    onboardingIcon
                    onboardingTitle
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 0) {
                    OnboardingPermissionRow(
                        icon: "mic.fill",
                        title: "麦克风",
                        detail: "用于录音；Speaker 不保存音频。",
                        state: permissions.snapshot.microphone,
                        permissionAction: presentation.permissionAction(
                            for: .microphone
                        )
                    ) {
                        Task { await requestPermission(.microphone) }
                    }
                    Divider().padding(.leading, 48)
                    OnboardingPermissionRow(
                        icon: "accessibility",
                        title: "辅助功能",
                        detail: "用于全局快捷键与向已验证的输入框写入文字。",
                        state: permissions.snapshot.accessibility,
                        permissionAction: presentation.permissionAction(
                            for: .accessibility
                        )
                    ) {
                        Task { await requestPermission(.accessibility) }
                    }
                }
                .padding(.horizontal, 16)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14)
                )

                if let notice = signingMode.permissionIdentityNotice {
                    Label(notice, systemImage: "hammer.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            providerTitle
                            Spacer()
                            providerStatus
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            providerTitle
                            providerStatus
                        }
                    }
                    Text("Key 只保存在这台 Mac；语音会直接发送到你自己的豆包账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !doubao.hasConfiguredKey {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                apiKeyField
                                saveAPIKeyButton
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                apiKeyField
                                saveAPIKeyButton
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            resourcePicker
                            Spacer()
                            connectionCheckControls
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            resourcePicker
                            connectionCheckControls
                        }
                    }

                    connectionStatusNotice

                    Link(
                        "在火山引擎控制台获取 Key",
                        destination: ExternalLinks.doubaoConsoleAPIKeys
                    )
                    .font(.caption)
                }
                .padding(16)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14)
                )

            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    readinessMessage
                    Spacer()
                    skipButton
                    completionButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    readinessMessage
                    HStack(spacing: 10) {
                        skipButton
                        completionButton
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 360, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            refreshPermissions()
            await doubao.refresh()
        }
        .onChange(of: permissions.snapshot) { previous, current in
            announcePermissionChanges(from: previous, to: current)
        }
        .onChange(of: doubao.status) { _, status in
            switch status {
            case .checking:
                announce("正在检查豆包连接")
            case .success:
                announce("豆包连接成功")
            case .failure(let message):
                announce("豆包连接失败：\(message)")
            case .loading, .unconfigured, .configured:
                break
            }
        }
        .onChange(of: ready) { wasReady, isReady in
            guard !wasReady, isReady else { return }
            announce("所有设置已完成，可以开始使用 Speaker")
        }
    }

    private var onboardingIcon: some View {
        SpeakerIdentityTile(size: 58, accessibility: .named)
    }

    private var onboardingTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("用说话代替打字")
                .font(.title.bold())
            Text("长按 Fn 讲话、松开结束；也可以短按开始，再按一次结束。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerTitle: some View {
        Label("豆包语音 API Key", systemImage: "key.fill")
            .font(.headline)
    }

    private var providerStatus: some View {
        let status = DoubaoStatusPresentation(status: doubao.status)
        return StatusBadge(
            text: status.text,
            icon: status.symbolName,
            color: status.tint
        )
    }

    private var apiKeyField: some View {
        SecureField(
            "粘贴豆包语音 API Key",
            text: $doubao.apiKeyDraft
        )
        .accessibilityLabel("豆包语音 API Key")
    }

    private var saveAPIKeyButton: some View {
        Button("保存") {
            Task { await doubao.save() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            doubao.apiKeyDraft
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        .accessibilityLabel("保存豆包语音 API Key")
    }

    private var resourcePicker: some View {
        LabeledContent("流式资源") {
            Picker(
                "流式资源",
                selection: Binding(
                    get: { doubao.resource },
                    set: { resource in
                        Task { await doubao.selectResource(resource) }
                    }
                )
            ) {
                ForEach(DoubaoStreamingResource.allCases, id: \.rawValue) { resource in
                    Text(resource.displayName).tag(resource)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!presentation.canSelectResource)
        }
        .font(.caption.weight(.medium))
    }

    private var connectionCheckControls: some View {
        HStack(spacing: 8) {
            if isCheckingConnection {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在检查豆包连接")
            }
            Button("检查连接") {
                doubao.checkConnection()
            }
            .disabled(!presentation.canCheckConnection)
        }
    }

    private var readinessMessage: some View {
        Text(
            ready
                ? "权限与豆包连接均已确认，可以开始使用。"
                : "完成权限、保存 Key 并通过连接检查后即可开始；也可以先跳过，之后在设置中随时完成。"
        )
        .font(.caption)
        .foregroundStyle(ready ? .green : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var skipButton: some View {
        if !presentation.canComplete {
            Button("跳过，稍后配置", action: completion)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint(
                    "关闭首次设置，之后不再自动弹出。完成权限和豆包配置前语音输入不可用，可在菜单栏或设置中继续配置。"
                )
        }
    }

    private var completionButton: some View {
        Button("开始使用 Speaker", action: completion)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!presentation.canComplete)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
                ready
                    ? "关闭首次设置并开始使用 Speaker"
                    : "需要先完成权限和豆包连接检查"
            )
    }

    @ViewBuilder
    private var connectionStatusNotice: some View {
        switch doubao.status {
        case .loading:
            SettingsNotice(text: "正在读取本机配置…")
        case .unconfigured:
            SettingsNotice(text: "保存 Key 后，请选择已开通的资源并检查连接。")
        case .configured:
            SettingsNotice(text: "Key 已保存；连接尚未验证。")
        case .checking:
            SettingsNotice(text: "正在等待豆包返回明确的连接检查结果。")
        case .success:
            SettingsNotice(text: "连接成功，当前资源可以使用。", color: .green)
        case .failure:
            SettingsNotice(text: doubao.summary, color: .red)
        }
    }

    private func announcePermissionChanges(
        from previous: PermissionSnapshot,
        to current: PermissionSnapshot
    ) {
        if previous.microphone != current.microphone {
            announce(permissionAnnouncement("麦克风", state: current.microphone))
        }
        if previous.accessibility != current.accessibility {
            announce(permissionAnnouncement("辅助功能", state: current.accessibility))
        }
    }

    private func permissionAnnouncement(_ name: String, state: PermissionState) -> String {
        switch state {
        case .granted: "\(name)权限已允许"
        case .denied: "\(name)权限未允许"
        case .notDetermined: "\(name)权限尚未决定"
        case .restricted: "\(name)权限受系统或组织策略限制"
        }
    }
}

private struct OnboardingPermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let state: PermissionState
    let permissionAction: OnboardingPermissionAction?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: icon)
                    .foregroundStyle(state == .granted ? .green : .secondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                if state == .granted {
                    Label("已完成", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else if state == .restricted {
                    Label(
                        "受系统或组织策略限制",
                        systemImage: "lock.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                } else if permissionAction != nil {
                    permissionButton
                }
            }
        }
        .padding(.vertical, 13)
    }

    private var permissionButton: some View {
        Button(
            permissionAction == .request
                ? "继续"
                : "打开系统设置",
            action: action
        )
        .accessibilityLabel(
            permissionAction == .request
                ? "允许\(title)"
                : "打开\(title)设置"
        )
    }
}
