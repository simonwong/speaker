import AppKit
import SpeakerCore
import SwiftUI

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    Color.primary.opacity(contrast == .increased ? 0.32 : 0.07),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
        }
        .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
    }
}

package struct StatusBadge: View {
    let text: String
    let icon: String
    let color: Color
    @Environment(\.colorSchemeContrast) private var contrast

    package init(text: String, icon: String, color: Color) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    package var body: some View {
        Label {
            Text(text)
                .foregroundStyle(contrast == .increased ? Color.primary : color)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                color.opacity(contrast == .increased ? 0.2 : 0.11),
                in: Capsule()
            )
            .overlay {
                if contrast == .increased {
                    Capsule().stroke(color.opacity(0.75), lineWidth: 1)
                }
            }
            .lineLimit(1)
    }
}

package struct SettingsNotice: View {
    let text: String
    var color: Color = .secondary
    @Environment(\.colorSchemeContrast) private var contrast

    package init(text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    package var body: some View {
        Label {
            Text(text)
                .foregroundStyle(contrast == .increased ? Color.primary : color)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(color)
        }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                color.opacity(contrast == .increased ? 0.16 : 0.07),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.7), lineWidth: 1)
                }
            }
            .textSelection(.enabled)
    }
}

package struct SettingsView: View {
    let workspace: SettingsWorkspace
    @StateObject private var shortcutRecorder = ShortcutRecorderModel()
    @ObservedObject private var dataErasure: SpeakerDataErasureCoordinator

    package init(workspace: SettingsWorkspace) {
        self.workspace = workspace
        dataErasure = workspace.dataErasure
    }

    package var body: some View {
        Group {
            switch dataErasure.state.workspaceRoute {
            case .normal:
                SettingsOverviewView(
                    workspace: workspace,
                    shortcutRecorder: shortcutRecorder
                )
            case .erasing:
                DataErasureInProgressView()
            case .aboutRecovery:
                DataErasureRecoveryView(
                    dataErasure: dataErasure,
                    routeEffects: workspace.routeEffects
                )
            }
        }
        .task {
            await workspace.refresh()
        }
        .onDisappear { shortcutRecorder.stop() }
    }
}

package struct DataErasureInProgressView: View {
    package init() {}

    package var body: some View {
        ContentUnavailableView(
            "本地数据清除中",
            systemImage: "externaldrive.badge.xmark",
            description: Text("Speaker 会在安全清除完成后自动退出。")
        )
    }
}

/// Full-window recovery surface shown when a local-data erasure did not
/// complete. This is its own destination, not the About page.
package struct DataErasureRecoveryView: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    let routeEffects: SettingsRouteEffects
    @State private var confirmsRetry = false

    package init(
        dataErasure: SpeakerDataErasureCoordinator,
        routeEffects: SettingsRouteEffects
    ) {
        self.dataErasure = dataErasure
        self.routeEffects = routeEffects
    }

    package var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "本地数据尚未全部清除",
                systemImage: "externaldrive.badge.xmark",
                description: Text(failureText)
            )

            HStack(spacing: 12) {
                Button("打开本地数据文件夹") {
                    routeEffects.openURL(speakerApplicationSupportDirectory)
                }
                Button("重试清除并退出", role: .destructive) {
                    confirmsRetry = true
                }
                .disabled(dataErasure.state == .erasing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "重试清除 Speaker 保存的所有本地数据？",
            isPresented: $confirmsRetry
        ) {
            Button("取消", role: .cancel) {}
            Button("清除并退出", role: .destructive) {
                Task {
                    _ = await dataErasure.eraseAllAndExit()
                }
            }
        } message: {
            Text(
                "API Key、文字历史、个人词库、设置和登录项将被永久移除。Speaker 不会删除系统权限记录，也无法恢复这些本地数据。"
            )
        }
    }

    private var failureText: String {
        guard case let .failed(failure) = dataErasure.state else {
            return "Speaker 正在完成剩余的清除步骤。"
        }
        return Self.failureMessage(failure)
    }

    static func failureMessage(
        _ failure: SpeakerDataErasureFailure
    ) -> String {
        guard let issue = failure.issues.first else {
            return "本地数据未能全部清除，请重试。"
        }
        return switch issue.reason {
        case .accessDenied:
            "macOS 拒绝删除部分数据，请检查文件权限后重试。"
        case .interactionUnavailable:
            "无法访问凭据存储，请解锁 Mac 后重试。"
        case .busy:
            "本地历史仍在使用中，未删除数据库。请重试。"
        case .unsafePath:
            "待删除路径未通过安全校验，Speaker 已停止清除。"
        case .verificationMismatch:
            "清除结果未通过验证，Speaker 没有报告成功；请重试。"
        case .io:
            "部分本地数据无法删除，请关闭可能占用文件的程序后重试。"
        }
    }
}

private var speakerApplicationSupportDirectory: URL {
    FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first?.appendingPathComponent("Speaker", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser
}

private struct SettingsOverviewView: View {
    let workspace: SettingsWorkspace
    @ObservedObject private var navigation: SettingsNavigationModel
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel

    init(
        workspace: SettingsWorkspace,
        shortcutRecorder: ShortcutRecorderModel
    ) {
        self.workspace = workspace
        navigation = workspace.navigation
        self.shortcutRecorder = shortcutRecorder
    }

    var body: some View {
        SettingsOverviewScrollView(navigation: navigation) { group in
            sectionGroup(group) {
                sectionContent(group)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionGroup<Content: View>(
        _ group: SettingsGroup,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(
                    group == .localData ? Color.red : Color.secondary
                )
                .padding(.leading, 6)
            content()
        }
    }

    @ViewBuilder
    private func sectionContent(_ group: SettingsGroup) -> some View {
        switch group {
        case .shortcut:
            ShortcutSettingsPage(
                shortcut: workspace.shortcut,
                shortcutRecorder: shortcutRecorder,
                openPermissionSettings: {
                    navigation.open(.permissions)
                }
            )
        case .permissions:
            PermissionSettingsPage(
                permissions: workspace.permissions,
                requestPermission: workspace.requestPermission
            )
        case .apiKeys:
            VStack(spacing: 16) {
                DoubaoSettingsCard(model: workspace.doubao)
                DeepSeekSettingsCard(model: workspace.refinement)
            }
            Text("音频只发给豆包；文字仅在启用对应整理模式时发给 DeepSeek。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        case .refinement:
            RefinementSettingsPage(model: workspace.refinement)
            Text("提示词仅在选择需要 DeepSeek 的整理模式时生效；默认顺滑没有提示词。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        case .general:
            GeneralSettingsPage(
                loginItemSettings: workspace.loginItemSettings,
                historyRetention: workspace.historyRetention,
                softwareUpdate: workspace.softwareUpdate
            )
        case .localData:
            LocalDataSettingsCard(dataErasure: workspace.dataErasure)
        }
    }
}

private struct ShortcutSettingsPage: View {
    @ObservedObject var shortcut: VoiceShortcutFeature
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    let openPermissionSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "语音输入快捷键",
                subtitle: "长按时松开结束；短按时再次按下结束",
                icon: "keyboard"
            ) {
                HStack(spacing: 16) {
                    Text(shortcut.preference.displayName)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 16)
                        .frame(minWidth: 78, minHeight: 44)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(.separator.opacity(0.55), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("快捷键状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shortcutStatusText)
                            .font(.subheadline.weight(.medium))
                    }

                    Spacer()

                    Button("使用 Fn") {
                        shortcutRecorder.stop()
                        shortcut.select(.functionKey)
                    }
                    .disabled(shortcut.activation.activePreference == .functionKey)

                    Button(shortcutRecorder.isRecording ? "取消" : "录制新快捷键") {
                        if shortcutRecorder.isRecording {
                            shortcutRecorder.stop()
                        } else {
                            shortcutRecorder.start { hotKey in
                                shortcut.select(.init(customHotKey: hotKey))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if shortcutRecorder.isRecording, let notice = shortcutRecorder.notice {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(notice)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if let notice = shortcut.notice {
                    SettingsNotice(text: notice.message, color: noticeColor(notice.level))
                    if let recovery = notice.recovery {
                        HStack {
                            Spacer()
                            Button(recovery == .openAccessibilitySettings ? "查看权限设置" : "重试") {
                                switch recovery {
                                case .retryActivation:
                                    shortcut.retryActivation()
                                case .retryPersistence:
                                    shortcut.retryPersistence()
                                case .openAccessibilitySettings:
                                    openPermissionSettings()
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    GestureHint(
                        icon: "hand.tap",
                        title: "短按",
                        detail: "按一下开始，再按一下结束"
                    )
                    GestureHint(
                        icon: "hand.point.up.left",
                        title: "长按",
                        detail: "按住录音，松开结束"
                    )
                    GestureHint(
                        icon: "escape",
                        title: "取消",
                        detail: "录音期间按 Esc"
                    )
                }
            }

        }
    }

    private var shortcutStatusText: String {
        switch shortcut.activation {
        case let .active(preference):
            preference == .functionKey ? "默认 Fn 已启用" : "自定义组合键已启用"
        case .waitingForAccessibility:
            "已选择，等待辅助功能权限"
        case .unavailable:
            "已选择，但监听尚未启用"
        case .stopped:
            "监听已停止"
        }
    }

    private func noticeColor(_ level: VoiceShortcutNotice.Level) -> Color {
        switch level {
        case .information: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct GeneralSettingsPage: View {
    let loginItemSettings: LoginItemSettingsModel
    let historyRetention: HistoryRetentionSettingsModel
    let softwareUpdate: SoftwareUpdateFeature

    var body: some View {
        SettingsCard(
            "通用",
            subtitle: "启动、历史保存与软件更新",
            icon: "switch.2"
        ) {
            LaunchAtLoginSettingsRow(model: loginItemSettings)
            HistoryRetentionSettingsRow(model: historyRetention)
            AutomaticUpdateSettingsRow(model: softwareUpdate)
        }
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var model: LoginItemSettingsModel

    var body: some View {
        Toggle(
            "登录 Mac 时自动启动 Speaker",
            isOn: Binding(
                get: { model.isEnabled },
                set: { enabled in
                    Task { await model.setEnabled(enabled) }
                }
            )
        )
        .toggleStyle(.switch)

        if let notice = model.notice {
            SettingsNotice(text: notice, color: .orange)
        }
        if model.showsSystemSettingsButton {
            Button("打开登录项设置") {
                model.openSystemSettings()
            }
            .controlSize(.small)
        }

        Divider()
    }
}

/// 历史保留策略的唯一入口：设置-通用。历史页不再提供策略切换。
private struct HistoryRetentionSettingsRow: View {
    @ObservedObject var model: HistoryRetentionSettingsModel

    var body: some View {
        HStack {
            Text("保存历史")
            Spacer()
            Picker(
                "保存历史",
                selection: Binding(
                    get: { model.retentionPolicy },
                    set: { policy in
                        Task { await model.setRetentionPolicy(policy) }
                    }
                )
            ) {
                ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .trailing)
            .disabled(model.isUpdating)
        }

        if let notice = model.notice {
            SettingsNotice(text: notice, color: .orange)
        }
    }
}

private struct AutomaticUpdateSettingsRow: View {
    @ObservedObject var model: SoftwareUpdateFeature

    var body: some View {
        Divider()

        Toggle(
            "自动检查更新",
            isOn: Binding(
                get: { model.state.automaticallyChecksForUpdates },
                set: { model.setAutomaticallyChecksForUpdates($0) }
            )
        )
        .toggleStyle(.switch)
        .disabled(!model.state.isAvailable)
    }
}

private struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 41.4395, y: 69.3848))
        path.addCurve(
            to: CGPoint(x: 19.9062, y: 46.9902),
            control1: CGPoint(x: 28.8066, y: 67.8535),
            control2: CGPoint(x: 19.9062, y: 58.7617)
        )
        path.addCurve(
            to: CGPoint(x: 24.5, y: 33.5918),
            control1: CGPoint(x: 19.9062, y: 42.2051),
            control2: CGPoint(x: 21.6289, y: 37.0371)
        )
        path.addCurve(
            to: CGPoint(x: 24.8828, y: 20.959),
            control1: CGPoint(x: 23.2559, y: 30.4336),
            control2: CGPoint(x: 23.4473, y: 23.7344)
        )
        path.addCurve(
            to: CGPoint(x: 36.9414, y: 25.2656),
            control1: CGPoint(x: 28.7109, y: 20.4805),
            control2: CGPoint(x: 33.8789, y: 22.4902)
        )
        path.addCurve(
            to: CGPoint(x: 49.0957, y: 23.543),
            control1: CGPoint(x: 40.5781, y: 24.1172),
            control2: CGPoint(x: 44.4062, y: 23.543)
        )
        path.addCurve(
            to: CGPoint(x: 61.0586, y: 25.1699),
            control1: CGPoint(x: 53.7852, y: 23.543),
            control2: CGPoint(x: 57.6133, y: 24.1172)
        )
        path.addCurve(
            to: CGPoint(x: 73.1172, y: 20.959),
            control1: CGPoint(x: 64.0254, y: 22.4902),
            control2: CGPoint(x: 69.2891, y: 20.4805)
        )
        path.addCurve(
            to: CGPoint(x: 73.4043, y: 33.4961),
            control1: CGPoint(x: 74.457, y: 23.543),
            control2: CGPoint(x: 74.6484, y: 30.2422)
        )
        path.addCurve(
            to: CGPoint(x: 78.0937, y: 46.9902),
            control1: CGPoint(x: 76.4668, y: 37.1328),
            control2: CGPoint(x: 78.0937, y: 42.0137)
        )
        path.addCurve(
            to: CGPoint(x: 56.3691, y: 69.2891),
            control1: CGPoint(x: 78.0937, y: 58.7617),
            control2: CGPoint(x: 69.1934, y: 67.6621)
        )
        path.addCurve(
            to: CGPoint(x: 61.8242, y: 81.252),
            control1: CGPoint(x: 59.623, y: 71.3945),
            control2: CGPoint(x: 61.8242, y: 75.9883)
        )
        path.addLine(to: CGPoint(x: 61.8242, y: 91.2051))
        path.addCurve(
            to: CGPoint(x: 67.0879, y: 94.5547),
            control1: CGPoint(x: 61.8242, y: 94.0762),
            control2: CGPoint(x: 64.2168, y: 95.7031)
        )
        path.addCurve(
            to: CGPoint(x: 98, y: 49.1914),
            control1: CGPoint(x: 84.4102, y: 87.9512),
            control2: CGPoint(x: 98, y: 70.6289)
        )
        path.addCurve(
            to: CGPoint(x: 48.9043, y: 0),
            control1: CGPoint(x: 98, y: 22.1074),
            control2: CGPoint(x: 75.9883, y: 0)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: 49.1914),
            control1: CGPoint(x: 21.8203, y: 0),
            control2: CGPoint(x: 0, y: 22.1074)
        )
        path.addCurve(
            to: CGPoint(x: 31.6777, y: 94.6504),
            control1: CGPoint(x: 0, y: 70.4375),
            control2: CGPoint(x: 13.4941, y: 88.0469)
        )
        path.addCurve(
            to: CGPoint(x: 36.75, y: 91.3008),
            control1: CGPoint(x: 34.2617, y: 95.6074),
            control2: CGPoint(x: 36.75, y: 93.8848)
        )
        path.addLine(to: CGPoint(x: 36.75, y: 83.6445))
        path.addCurve(
            to: CGPoint(x: 32.1562, y: 84.6016),
            control1: CGPoint(x: 35.4102, y: 84.2188),
            control2: CGPoint(x: 33.6875, y: 84.6016)
        )
        path.addCurve(
            to: CGPoint(x: 19.4277, y: 74.7441),
            control1: CGPoint(x: 25.8398, y: 84.6016),
            control2: CGPoint(x: 22.1074, y: 81.1563)
        )
        path.addCurve(
            to: CGPoint(x: 15.0254, y: 70.3418),
            control1: CGPoint(x: 18.375, y: 72.1602),
            control2: CGPoint(x: 17.2266, y: 70.6289)
        )
        path.addCurve(
            to: CGPoint(x: 13.4941, y: 69.1934),
            control1: CGPoint(x: 13.877, y: 70.2461),
            control2: CGPoint(x: 13.4941, y: 69.7676)
        )
        path.addCurve(
            to: CGPoint(x: 17.3223, y: 67.1836),
            control1: CGPoint(x: 13.4941, y: 68.0449),
            control2: CGPoint(x: 15.4082, y: 67.1836)
        )
        path.addCurve(
            to: CGPoint(x: 24.9785, y: 72.4473),
            control1: CGPoint(x: 20.0977, y: 67.1836),
            control2: CGPoint(x: 22.4902, y: 68.9063)
        )
        path.addCurve(
            to: CGPoint(x: 31.2949, y: 76.4668),
            control1: CGPoint(x: 26.8926, y: 75.2227),
            control2: CGPoint(x: 28.9023, y: 76.4668)
        )
        path.addCurve(
            to: CGPoint(x: 37.4199, y: 73.4043),
            control1: CGPoint(x: 33.6875, y: 76.4668),
            control2: CGPoint(x: 35.2187, y: 75.6055)
        )
        path.addCurve(
            to: CGPoint(x: 41.4395, y: 69.3848),
            control1: CGPoint(x: 39.0469, y: 71.7773),
            control2: CGPoint(x: 40.291, y: 70.3418)
        )
        path.closeSubpath()

        let scale = min(rect.width / 98, rect.height / 96)
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: rect.midX - 49 * scale,
            ty: rect.midY - 48 * scale
        )
        return path.applying(transform)
    }
}

package struct AboutView: View {
    let workspace: SettingsWorkspace
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    package init(workspace: SettingsWorkspace) {
        self.workspace = workspace
    }

    package var body: some View {
        ScrollView {
            AboutSettingsPage(
                softwareUpdate: workspace.softwareUpdate,
                routeEffects: workspace.routeEffects
            )
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(
                .horizontal,
                mainWindowLayout.pageHorizontalPadding
            )
            .padding(.vertical, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await workspace.refresh() }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var softwareUpdate: SoftwareUpdateFeature
    let routeEffects: SettingsRouteEffects

    private var versionText: String {
        SpeakerBuildIdentity.current.displayText
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                AboutSection.privacyBoundary.title,
                subtitle: "你应该清楚每一类数据会去哪里",
                icon: AboutSection.privacyBoundary.icon
            ) {
                PrivacyBoundaryRow(
                    icon: "waveform",
                    title: "音频",
                    detail: "录音只在内存中转换并发送到豆包，不保存到磁盘或历史。"
                )
                Divider()
                PrivacyBoundaryRow(
                    icon: "text.alignleft",
                    title: "识别文字",
                    detail: "豆包返回的识别文字保留在本机；仅当你启用需要 DeepSeek 的整理模式时，文字才会发送给 DeepSeek。"
                )
                Divider()
                PrivacyBoundaryRow(
                    icon: "clock.arrow.circlepath",
                    title: "历史、设置与词库",
                    detail: "只保存在这台 Mac 的当前用户目录；会话历史不包含音频或 API Key。"
                )
                Divider()

                HStack {
                    if let privacyPolicyURL = Self.privacyPolicyURL {
                        Button("查看完整隐私说明") {
                            routeEffects.openURL(privacyPolicyURL)
                        }
                    }
                    Button("打开本地数据文件夹") {
                        routeEffects.openURL(speakerApplicationSupportDirectory)
                    }
                    Spacer()
                }
            }

            SettingsCard(
                AboutSection.version.title,
                subtitle: versionText,
                icon: AboutSection.version.icon
            ) {
                HStack {
                    SpeakerIdentityTile(size: 30)
                    Text("Speaker")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("检查更新…") {
                        softwareUpdate.checkForUpdates()
                    }
                    .disabled(!softwareUpdate.state.canCheckForUpdates)
                    Link(
                        destination: URL(
                            string: "https://github.com/simonwong/speaker"
                        )!
                    ) {
                        GitHubMark()
                            .fill(Color.primary)
                            .frame(width: 20, height: 20)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("在 GitHub 查看 Speaker")
                    .help("在 GitHub 查看 Speaker")
                }
            }
        }
    }

    private static var privacyPolicyURL: URL? {
        Bundle.main.url(
            forResource: "PRIVACY",
            withExtension: "md"
        )
    }
}

/// 设置页底部的红色危险区：本地数据清除的唯一入口。
private struct LocalDataSettingsCard: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @State private var confirmsDataErasure = false

    var body: some View {
        SettingsCard(
            SettingsGroup.localData.title,
            subtitle: "完全清除这台 Mac 上由 Speaker 保存的数据",
            icon: "externaldrive.badge.xmark",
            tint: .red
        ) {
            Text(
                "清除 API Key、会话历史、个人词库、设置、缓存和登录项，然后退出 Speaker。系统中的麦克风与辅助功能授权不会被自动撤销。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if dataErasure.state == .erasing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在清除 Speaker 本地数据")
                }
                Button(
                    dataErasure.state == .erasing
                    ? "正在清除…"
                    : "清除本地数据并退出",
                    role: .destructive
                ) {
                    confirmsDataErasure = true
                }
                .disabled(dataErasure.state == .erasing)
            }
        }
        .alert(
            "清除 Speaker 保存的所有本地数据？",
            isPresented: $confirmsDataErasure
        ) {
            Button("取消", role: .cancel) {}
            Button("清除并退出", role: .destructive) {
                Task {
                    _ = await dataErasure.eraseAllAndExit()
                }
            }
        } message: {
            Text(
                "API Key、文字历史、个人词库、设置和登录项将被永久移除。Speaker 不会删除系统权限记录，也无法恢复这些本地数据。"
            )
        }
    }
}

private struct PrivacyBoundaryRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GestureHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionSettingsPage: View {
    @ObservedObject var permissions: PermissionModel
    let requestPermission: (PermissionKind) async -> Void

    private var signingMode: SpeakerSigningMode {
        SpeakerSigningMode(
            infoValue: Bundle.main.object(
                forInfoDictionaryKey: "SpeakerSigningMode"
            ) as? String
        )
    }

    var body: some View {
        SettingsCard(
            "系统权限",
            subtitle: "只请求完成语音输入所必需的权限",
            icon: "checkmark.shield"
        ) {
            if let notice = signingMode.permissionIdentityNotice {
                SettingsNotice(text: notice, color: .orange)
                Divider()
            }

            PermissionSettingsRow(
                title: "麦克风",
                explanation: "音频只在内存中流式处理，不会写入磁盘或历史。",
                kind: .microphone,
                state: permissions.snapshot.microphone,
                requestPermission: requestPermission
            )

            Divider()

            PermissionSettingsRow(
                title: "辅助功能",
                explanation: "监听全局快捷键，并把文本安全送达到结束录音时的输入框。",
                kind: .accessibility,
                state: permissions.snapshot.accessibility,
                requestPermission: requestPermission
            )
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let explanation: String
    let kind: PermissionKind
    let state: PermissionState
    let requestPermission: (PermissionKind) async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            StatusBadge(
                text: statusTitle,
                icon: statusIcon,
                color: color
            )

            if state != .granted, state != .restricted {
                Button(buttonTitle) {
                    Task { await requestPermission(kind) }
                }
            }
        }
    }

    private var icon: String {
        switch kind {
        case .accessibility: "accessibility"
        case .microphone: "mic.fill"
        }
    }

    private var color: Color {
        switch state {
        case .granted:
            .green
        case .restricted:
            .red
        case .denied, .notDetermined:
            .orange
        }
    }

    private var statusTitle: String {
        switch state {
        case .granted:
            "已授权"
        case .restricted:
            "受系统限制"
        case .denied, .notDetermined:
            "待完成"
        }
    }

    private var statusIcon: String {
        switch state {
        case .granted:
            "checkmark"
        case .restricted:
            "lock.fill"
        case .denied, .notDetermined:
            "exclamationmark"
        }
    }

    private var buttonTitle: String {
        state == .notDetermined ? "请求授权" : "打开设置"
    }
}

private struct DoubaoSettingsCard: View {
    @ObservedObject var model: DoubaoSettingsModel
    @State private var confirmingDelete = false
    @State private var isReplacingKey = false

    private var mode: APIKeyCardMode {
        APIKeyCardPresentation.mode(
            hasStoredKey: model.hasConfiguredKey,
            isReplacingKey: isReplacingKey
        )
    }

    var body: some View {
        SettingsCard(
            "豆包流式语音",
            subtitle: "录音过程中实时转录，默认启用语义顺滑",
            icon: "waveform.badge.mic"
        ) {
            HStack {
                StatusBadge(
                    text: statusText,
                    icon: statusIcon,
                    color: statusColor
                )
                .help(model.summary)
                Spacer()
                Link(
                    "打开豆包控制台",
                    destination: URL(
                        string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default"
                    )!
                )
                .font(.caption)
            }

            Divider()

            if mode == .enterKey {
                keyInput(
                    placeholder: "输入豆包语音 API Key",
                    saveTitle: "保存 Key"
                )
            } else {
                HStack {
                    Text("流式资源")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker(
                        "流式资源",
                        selection: Binding(
                            get: { model.resource },
                            set: { resource in Task { await model.selectResource(resource) } }
                        )
                    ) {
                        ForEach(DoubaoStreamingResource.allCases, id: \.rawValue) { resource in
                            Text(resource.displayName).tag(resource)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    if case .checking = model.status {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button("检查连接") {
                        model.checkConnection()
                    }
                    .disabled(isChecking)

                    Button(isReplacingKey ? "收起" : "更换 Key") {
                        isReplacingKey.toggle()
                    }
                    .disabled(isChecking)

                    Text("资源类型必须与控制台中已开通的套餐一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("删除 Key", role: .destructive) {
                        confirmingDelete = true
                    }
                }

                if mode == .replacingKey {
                    keyInput(
                        placeholder: "输入新 Key 以替换当前凭据",
                        saveTitle: "保存"
                    )
                }
            }
        }
        .confirmationDialog(
            "删除豆包 API Key？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                Task { await model.delete() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将无法进行新的语音转录，历史记录不会受影响。")
        }
        .onChange(of: model.hasConfiguredKey) { _, hasKey in
            if !hasKey { isReplacingKey = false }
        }
    }

    private func keyInput(
        placeholder: String,
        saveTitle: String
    ) -> some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $model.apiKeyDraft)
                .textContentType(.password)

            Button(saveTitle) {
                Task {
                    await model.save()
                    isReplacingKey = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.apiKeyDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
    }

    private var isChecking: Bool {
        if case .checking = model.status { true } else { false }
    }

    private var statusIcon: String {
        switch model.status {
        case .loading: "clock"
        case .unconfigured: "key.slash"
        case .configured: "checkmark.shield"
        case .checking: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch model.status {
        case .loading: "正在读取本机配置"
        case .unconfigured: "未配置"
        case .configured: "已配置"
        case .checking: "正在检查连接"
        case .success: "连接成功"
        case .failure: model.summary
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .success, .configured: .green
        case .failure: .red
        case .checking: .blue
        case .loading, .unconfigured: .secondary
        }
    }
}

private struct DeepSeekSettingsCard: View {
    @ObservedObject var model: RefinementSettingsModel
    @State private var confirmingDelete = false
    @State private var isReplacingKey = false

    private var mode: APIKeyCardMode {
        APIKeyCardPresentation.mode(
            hasStoredKey: model.hasStoredKey,
            isReplacingKey: isReplacingKey
        )
    }

    var body: some View {
        SettingsCard(
            "DeepSeek（可选）",
            subtitle: "仅发送豆包转录文本和整理规则，不发送音频",
            icon: "sparkles"
        ) {
            HStack {
                StatusBadge(
                    text: statusText,
                    icon: statusIcon,
                    color: statusColor
                )
                Spacer()
                Link(
                    "打开 DeepSeek 平台",
                    destination: URL(
                        string: "https://platform.deepseek.com/api_keys"
                    )!
                )
                .font(.caption)
            }

            Divider()

            if mode == .enterKey {
                keyInput(
                    placeholder: "输入 DeepSeek API Key",
                    saveTitle: "保存 Key"
                )
            } else {
                HStack {
                    Button {
                        model.checkConnection()
                    } label: {
                        if model.isCheckingConnection {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("检查中…")
                            }
                        } else {
                            Text("检查连接")
                        }
                    }
                    .disabled(model.isCheckingConnection)

                    Button(isReplacingKey ? "收起" : "更换 Key") {
                        isReplacingKey.toggle()
                    }
                    .disabled(model.isCheckingConnection)

                    Spacer()

                    Button("删除 Key", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(model.isCheckingConnection)
                }

                if mode == .replacingKey {
                    keyInput(
                        placeholder: "输入新 Key 以替换当前凭据",
                        saveTitle: "保存"
                    )
                }
            }

            if let credentialNotice = model.credentialNotice {
                SettingsNotice(text: credentialNotice, color: .red)
            }
            if let connectionFailure = model.connectionFailure {
                SettingsNotice(text: connectionFailure, color: .red)
            }
        }
        .confirmationDialog(
            "删除 DeepSeek API Key？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                Task { await model.deleteAPIKey() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后会自动切回默认顺滑，豆包转录仍可正常使用。")
        }
        .onChange(of: model.hasStoredKey) { _, hasKey in
            if !hasKey { isReplacingKey = false }
        }
    }

    private func keyInput(
        placeholder: String,
        saveTitle: String
    ) -> some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $model.apiKeyDraft)
                .textContentType(.password)

            Button(saveTitle) {
                Task {
                    await model.saveAPIKey()
                    isReplacingKey = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.apiKeyDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                    || model.isCheckingConnection
            )
        }
    }

    private var statusText: String {
        if model.isConnectionVerified { return "已验证" }
        if model.connectionFailure != nil { return "连接失败" }
        if model.hasStoredKey { return "已配置" }
        return "未配置"
    }

    private var statusIcon: String {
        if model.isConnectionVerified { return "checkmark.circle.fill" }
        if model.connectionFailure != nil { return "xmark.circle.fill" }
        if model.hasStoredKey { return "checkmark.shield" }
        return "key.slash"
    }

    private var statusColor: Color {
        if model.isConnectionVerified { return .green }
        if model.connectionFailure != nil { return .red }
        if model.hasStoredKey { return .green }
        return .secondary
    }
}

private struct RefinementSettingsPage: View {
    @ObservedObject var model: RefinementSettingsModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "整理模式",
                subtitle: "默认顺滑不调用 DeepSeek；其他模式需要先验证 Key",
                icon: "text.alignleft"
            ) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(RefinementChoice.allCases) { choice in
                        RefinementModeButton(
                            choice: choice,
                            selected: model.choice == choice,
                            locked: choice != .defaultSmooth && !model.hasStoredKey
                        ) {
                            Task { await model.select(choice) }
                        }
                    }
                }

                if let notice = model.notice {
                    SettingsNotice(
                        text: notice,
                        color: model.isConnectionVerified ? .green : .secondary
                    )
                }
            }

            if let promptEditor = model.promptEditorState, !model.isEditingCustomMode {
                SettingsCard(
                    "“\(model.mode.displayName)”提示词",
                    subtitle: "提示词只保存在本机，修改后对新会话生效",
                    icon: "text.quote"
                ) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.promptDraft)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)

                        if model.promptDraft.isEmpty {
                            Text("输入该模式的整理提示词……")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 110)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.separator.opacity(0.7), lineWidth: 1)
                    }

                    HStack {
                        Text(
                            "\(model.promptDraft.count) / \(TextRefinementMode.maximumCustomPromptLength)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            model.promptDraft.count
                                > TextRefinementMode.maximumCustomPromptLength
                                ? Color.red
                                : .secondary
                        )
                        Text(promptEditor.isOverridden ? "当前为自定义提示词" : "当前为内置提示词")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            Task { await model.restoreDefaultPrompt() }
                        }
                        .disabled(
                            !promptEditor.canRestoreDefault(draft: model.promptDraft)
                        )
                        Button("保存") {
                            Task { await model.savePromptOverride() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!promptEditor.canSave(draft: model.promptDraft))
                    }
                }
            }

            if model.isEditingCustomMode || model.choice == .custom {
                SettingsCard(
                    "自定义整理规则",
                    subtitle: "清楚描述希望保留、删除和重组的内容",
                    icon: "slider.horizontal.3"
                ) {
                    TextField("规则名称", text: $model.customName)

                    HStack {
                        Spacer()
                        Text(
                            "\(model.customName.count) / \(TextRefinementMode.maximumCustomNameLength)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            model.customName.count > TextRefinementMode.maximumCustomNameLength
                                ? Color.red
                                : .secondary
                        )
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.customPrompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)

                        if model.customPrompt.isEmpty {
                            Text("例如：整理成简洁的工作邮件，保留所有数字和专有名词……")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 130)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.separator.opacity(0.7), lineWidth: 1)
                    }

                    HStack {
                        Text("\(model.customPrompt.count) / 4000")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(
                                model.customPrompt.count > 4_000 ? Color.red : .secondary
                            )
                        Spacer()
                        Button("保存并启用") {
                            Task { await model.saveCustomMode() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !model.hasStoredKey
                                || model.customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.customName.count
                                    > TextRefinementMode.maximumCustomNameLength
                                || model.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.customPrompt.count
                                    > TextRefinementMode.maximumCustomPromptLength
                        )
                    }
                }
            }
        }
    }

}

private struct RefinementModeButton: View {
    let choice: RefinementChoice
    let selected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: choice.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : locked ? "lock.fill" : "circle")
                        .foregroundStyle(
                            selected ? Color.accentColor : Color.secondary.opacity(0.55)
                        )
                }
                Text(choice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(choice.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DictionarySettingsPage: View {
    @ObservedObject var model: DictionarySettingsModel

    var body: some View {
        SettingsCard(
            "个人词库",
            subtitle: "添加人名、术语和产品名，提高豆包识别准确率",
            icon: "text.book.closed"
        ) {
            HStack(spacing: 8) {
                TextField(
                    "添加词条：人名、术语、产品名…回车添加",
                    text: $model.draftWord
                )
                .onSubmit { Task { await model.add() } }

                Button("添加") {
                    Task { await model.add() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.draftWord
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }

            Divider()

            if model.entries.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有词条")
                            .font(.subheadline.weight(.medium))
                        Text("添加产品名、人名或专业术语，识别更准。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
            } else {
                DictionaryChipFlowLayout(spacing: 8) {
                    ForEach(model.entries) { entry in
                        DictionaryEntryChip(word: entry.word) {
                            Task { await model.delete(entry.id) }
                        }
                    }
                }
            }

            Text("词条会随每次识别请求发送给豆包（仅词条文本），直接提升这些词的识别准确率。悬停词条可删除。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let notice = model.notice {
                SettingsNotice(text: notice)
            }
        }
    }
}

private struct DictionaryChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > availableWidth {
                totalHeight += rowHeight + spacing
                contentWidth = max(contentWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }

        contentWidth = max(contentWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX,
               point.x + size.width > bounds.maxX
            {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: point,
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

package struct DictionaryTabView: View {
    @ObservedObject var model: DictionarySettingsModel
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    package init(model: DictionarySettingsModel) {
        self.model = model
    }

    package var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DictionarySettingsPage(model: model)
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(
                .horizontal,
                mainWindowLayout.pageHorizontalPadding
            )
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
