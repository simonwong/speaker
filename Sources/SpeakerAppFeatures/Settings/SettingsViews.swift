import AppKit
import SpeakerCore
import SwiftUI

/// A thin wrapper over the shared card surface. A card may be headless when
/// its settings group title already names it.
private struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let icon: String?
    let tint: Color?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    init(@ViewBuilder content: () -> Content) {
        title = nil
        subtitle = nil
        icon = nil
        tint = nil
        self.content = content()
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: SpeakerSurfaceMetrics.cardHeaderSpacing
        ) {
            if let title, let icon {
                SpeakerCardHeader(
                    title: title,
                    subtitle: subtitle,
                    icon: icon,
                    tint: tint
                )
            }

            VStack(
                alignment: .leading,
                spacing: SpeakerSurfaceMetrics.rowSpacing
            ) {
                content
            }
        }
        .speakerCard(tint: tint)
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Divider().opacity(0.6)
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
            .font(SpeakerTypography.footnote.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                color.opacity(contrast == .increased ? 0.2 : 0.12),
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

    /// A neutral notice must not read as a coloured status, so `.secondary`
    /// drops to the plain grey surface.
    private var isNeutral: Bool { color == .secondary }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    package var body: some View {
        Label {
            Text(text)
                .foregroundStyle(contrast == .increased ? Color.primary : color)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(isNeutral ? Color.secondary : color)
        }
            .font(SpeakerTypography.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isNeutral && contrast != .increased
                    ? Color.primary.opacity(0.04)
                    : color.opacity(contrast == .increased ? 0.16 : 0.07),
                in: shape
            )
            .overlay {
                if contrast == .increased {
                    shape.stroke(color.opacity(0.7), lineWidth: 1)
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
        return SpeakerCopy.LocalDataErase.failureMessage(failure)
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
            SpeakerSectionHeader(
                group.title,
                tint: group == .localData ? .red : .secondary
            )
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
            VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
                DoubaoSettingsCard(model: workspace.doubao)
                DeepSeekSettingsCard(model: workspace.refinement)
            }
        case .refinement:
            RefinementSettingsPage(model: workspace.refinement)
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
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            SettingsCard {
                HStack(spacing: 14) {
                    Text(shortcut.preference.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minWidth: 72, minHeight: 40)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(
                                cornerRadius: SpeakerSurfaceMetrics
                                    .controlCornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: SpeakerSurfaceMetrics
                                    .controlCornerRadius,
                                style: .continuous
                            )
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }

                    StatusBadge(
                        text: shortcutStatusText,
                        icon: shortcutStatusIcon,
                        color: shortcutStatusColor
                    )

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
                            .font(SpeakerTypography.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(
                            cornerRadius: SpeakerSurfaceMetrics
                                .controlCornerRadius,
                            style: .continuous
                        )
                    )
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

                SettingsRowDivider()

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

    private var shortcutStatusIcon: String {
        switch shortcut.activation {
        case .active: "checkmark"
        case .waitingForAccessibility, .unavailable: "exclamationmark"
        case .stopped: "pause.fill"
        }
    }

    private var shortcutStatusColor: Color {
        switch shortcut.activation {
        case .active: .green
        case .waitingForAccessibility, .unavailable: .orange
        case .stopped: .red
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
        SettingsCard {
            LaunchAtLoginSettingsRow(model: loginItemSettings)
            SettingsRowDivider()
            HistoryRetentionSettingsRow(model: historyRetention)
            SettingsRowDivider()
            AutomaticUpdateSettingsRow(model: softwareUpdate)
        }
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var model: LoginItemSettingsModel

    var body: some View {
        SpeakerRow("登录时自动启动") {
            Toggle(
                "登录时自动启动",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { enabled in
                        Task { await model.setEnabled(enabled) }
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }

        if let notice = model.notice {
            SettingsNotice(text: notice, color: .orange)
        }
        if model.showsSystemSettingsButton {
            Button("打开登录项设置") {
                model.openSystemSettings()
            }
            .controlSize(.small)
        }
    }
}

/// 历史保留策略的唯一入口：设置-通用。历史页不再提供策略切换。
private struct HistoryRetentionSettingsRow: View {
    @ObservedObject var model: HistoryRetentionSettingsModel

    var body: some View {
        SpeakerRow("保存历史", detail: "历史只保存在本机") {
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
        SpeakerRow("自动检查更新") {
            Toggle(
                "自动检查更新",
                isOn: Binding(
                    get: { model.state.automaticallyChecksForUpdates },
                    set: { model.setAutomaticallyChecksForUpdates($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!model.state.isAvailable)
        }

        if let message = model.state.unavailableMessage {
            SettingsNotice(text: message, color: .secondary)
        }
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

    package init(workspace: SettingsWorkspace) {
        self.workspace = workspace
    }

    package var body: some View {
        SpeakerPage {
            AboutSettingsPage(
                softwareUpdate: workspace.softwareUpdate,
                routeEffects: workspace.routeEffects
            )
        }
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
        VStack(alignment: .leading, spacing: 0) {
            identity

            privacyBoundaryCard
                .padding(.top, 24)

            versionCard
                .padding(.top, SpeakerSurfaceMetrics.cardSpacing)
        }
    }

    /// The identity block names the product; the version card owns updates and
    /// the repository so neither fact appears twice on this page.
    private var identity: some View {
        HStack(spacing: 16) {
            SpeakerIdentityTile(size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Speaker")
                    .font(SpeakerTypography.pageTitle)
                Text("按住快捷键说话，文字送达松开时所在的输入框。")
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
    }

    private var privacyBoundaryCard: some View {
        SettingsCard(
            AboutSection.privacyBoundary.title,
            subtitle: "每一类数据去了哪里",
            icon: AboutSection.privacyBoundary.icon
        ) {
            SpeakerRow(
                "音频",
                detail: "只在内存中转换并发送给豆包，不写入磁盘或历史。",
                icon: "waveform"
            )
            SettingsRowDivider()
            SpeakerRow(
                "识别文字",
                detail: "保留在本机；只有启用需要 DeepSeek 的整理模式时才会发送给 DeepSeek。",
                icon: "text.alignleft"
            )
            SettingsRowDivider()
            SpeakerRow(
                "历史、设置与词库",
                detail: "只保存在这台 Mac 的当前用户目录，不包含音频或 API Key。",
                icon: "clock.arrow.circlepath"
            )
            SettingsRowDivider()

            HStack {
                if let privacyPolicyURL = ExternalLinks.privacyPolicy {
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
    }

    private var versionCard: some View {
        SettingsCard(
            AboutSection.version.title,
            subtitle: "更新与源码",
            icon: AboutSection.version.icon
        ) {
            SpeakerRow("当前版本") {
                HStack(spacing: 10) {
                    Text(versionText)
                        .font(SpeakerTypography.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button("检查更新…") {
                        softwareUpdate.checkForUpdates()
                    }
                    .disabled(!softwareUpdate.state.canCheckForUpdates)
                }
            }

            if let message = softwareUpdate.state.unavailableMessage {
                SettingsNotice(text: message, color: .secondary)
            }

            SettingsRowDivider()

            SpeakerRow("源码", detail: "github.com/simonwong/speaker") {
                Link(destination: ExternalLinks.speakerRepository) {
                    Label {
                        Text("在 GitHub 查看")
                            .font(SpeakerTypography.caption)
                    } icon: {
                        GitHubMark()
                            .fill(Color.primary)
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("在 GitHub 查看 Speaker")
                .help("在 GitHub 查看 Speaker")
            }
        }
    }
}

/// 设置页底部的红色危险区：本地数据清除的唯一入口。
private struct LocalDataSettingsCard: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @State private var confirmsDataErasure = false

    var body: some View {
        SettingsCard(
            "清除本地数据",
            subtitle: "移除这台 Mac 上由 Speaker 保存的全部数据",
            icon: "externaldrive.badge.xmark",
            tint: .red
        ) {
            Text(
                "包括 API Key、会话历史、个人词库、设置、缓存和登录项；完成后 Speaker 退出。系统的麦克风与辅助功能授权不会被撤销。"
            )
            .font(SpeakerTypography.caption)
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

private struct GestureHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SpeakerTypography.caption.weight(.semibold))
                Text(detail)
                    .font(SpeakerTypography.footnote)
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
    var buildInfo = SpeakerBuildInfoReader.main

    private var signingMode: SpeakerSigningMode {
        buildInfo.signingMode
    }

    var body: some View {
        SettingsCard {
            if let notice = signingMode.permissionIdentityNotice {
                SettingsNotice(text: notice, color: .orange)
                SettingsRowDivider()
            }

            PermissionSettingsRow(
                title: "麦克风",
                explanation: "音频只在内存中流式处理，不写入磁盘或历史。",
                kind: .microphone,
                state: permissions.snapshot.microphone,
                requestPermission: requestPermission
            )

            SettingsRowDivider()

            PermissionSettingsRow(
                title: "辅助功能",
                explanation: "监听全局快捷键，并把文字送达结束录音时的输入框。",
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
        SpeakerRow(
            title,
            detail: explanation,
            icon: icon,
            iconTint: color
        ) {
            HStack(spacing: 10) {
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
            "豆包语音",
            subtitle: "边说边转录，默认启用语义顺滑",
            icon: "waveform.badge.mic"
        ) {
            HStack {
                StatusBadge(
                    text: status.text,
                    icon: status.symbolName,
                    color: status.tint
                )
                .help(model.summary)
                Spacer()
                Link(
                    "打开豆包控制台",
                    destination: ExternalLinks.doubaoConsoleAPIKeys
                )
                .font(SpeakerTypography.caption)
            }

            SettingsRowDivider()

            if mode == .enterKey {
                keyInput(
                    placeholder: "输入豆包语音 API Key",
                    saveTitle: "保存 Key"
                )
            } else {
                SpeakerRow("流式资源", detail: "须与控制台已开通的套餐一致") {
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
                    .frame(maxWidth: 260, alignment: .trailing)
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

                    Spacer()

                    Button("删除 Key", role: .destructive) {
                        confirmingDelete = true
                    }
                }

                if mode == .replacingKey {
                    keyInput(
                        placeholder: "输入新 Key 替换当前凭据",
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

    private var status: DoubaoStatusPresentation {
        DoubaoStatusPresentation(status: model.status)
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
            "DeepSeek · 可选",
            subtitle: "只接收豆包转录文本与整理提示词，不接收音频",
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
                    destination: ExternalLinks.deepSeekAPIKeys
                )
                .font(SpeakerTypography.caption)
            }

            SettingsRowDivider()

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
                        placeholder: "输入新 Key 替换当前凭据",
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
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            SettingsCard(
                "整理模式",
                subtitle: "默认顺滑只用豆包；其他模式需要先验证 DeepSeek Key",
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
                            inspected: model.inspectedPromptMode
                                == choice.builtInMode,
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
                    "“\(promptEditor.title)”提示词",
                    subtitle: "提示词只保存在本机，修改后对新会话生效",
                    icon: "text.quote"
                ) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.promptDraft)
                            .font(SpeakerTypography.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)

                        if model.promptDraft.isEmpty {
                            Text("输入该模式的整理提示词……")
                                .font(SpeakerTypography.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 110)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(
                            cornerRadius: SpeakerSurfaceMetrics
                                .controlCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: SpeakerSurfaceMetrics
                                .controlCornerRadius,
                            style: .continuous
                        )
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }

                    HStack {
                        Text(
                            "\(model.promptDraft.count) / \(TextRefinementMode.maximumCustomPromptLength)"
                        )
                        .font(SpeakerTypography.footnote.monospacedDigit())
                        .foregroundStyle(
                            model.promptDraft.count
                                > TextRefinementMode.maximumCustomPromptLength
                                ? Color.red
                                : .secondary
                        )
                        Text(promptEditor.isOverridden ? "当前为自定义提示词" : "当前为内置提示词")
                            .font(SpeakerTypography.footnote)
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
                    "自定义模式",
                    subtitle: "说清楚希望保留、删除和重组的内容",
                    icon: "slider.horizontal.3"
                ) {
                    TextField("模式名称", text: $model.customName)

                    HStack {
                        Spacer()
                        Text(
                            "\(model.customName.count) / \(TextRefinementMode.maximumCustomNameLength)"
                        )
                        .font(SpeakerTypography.footnote.monospacedDigit())
                        .foregroundStyle(
                            model.customName.count > TextRefinementMode.maximumCustomNameLength
                                ? Color.red
                                : .secondary
                        )
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.customPrompt)
                            .font(SpeakerTypography.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)

                        if model.customPrompt.isEmpty {
                            Text("例如：整理成简洁的工作邮件，保留所有数字和专有名词……")
                                .font(SpeakerTypography.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 130)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(
                            cornerRadius: SpeakerSurfaceMetrics
                                .controlCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: SpeakerSurfaceMetrics
                                .controlCornerRadius,
                            style: .continuous
                        )
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }

                    HStack {
                        Text("\(model.customPrompt.count) / 4000")
                            .font(SpeakerTypography.footnote.monospacedDigit())
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
    let inspected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: choice.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(
                            selected || inspected ? Color.accentColor : .secondary
                        )
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : locked ? "lock.fill" : "circle")
                        .foregroundStyle(
                            selected ? Color.accentColor : Color.secondary.opacity(0.55)
                        )
                }
                Text(choice.title)
                    .font(SpeakerTypography.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text(choice.subtitle)
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                selected || inspected
                    ? Color.accentColor.opacity(0.10)
                    : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected || inspected
                            ? Color.accentColor.opacity(0.8)
                            : Color.primary.opacity(0.08),
                        lineWidth: selected || inspected ? 1.5 : 1
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
            subtitle: "人名、术语、产品名，让豆包更准确地认出它们",
            icon: "text.book.closed"
        ) {
            HStack(spacing: 8) {
                TextField(
                    "输入词条，回车添加",
                    text: $model.draftWord
                )
                .textFieldStyle(.roundedBorder)
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

            capacityRow

            if model.entries.isEmpty {
                SpeakerEmptyState(
                    title: "还没有词条",
                    description: "在上方输入一个词，回车即可添加。",
                    systemImage: "text.book.closed"
                )
            } else {
                let omittedEntryIDs = model.omittedEntryIDs
                DictionaryChipFlowLayout(spacing: 8) {
                    ForEach(model.entries) { entry in
                        DictionaryEntryChip(
                            word: entry.word,
                            isOmitted: omittedEntryIDs.contains(entry.id),
                            qualityHint: model.qualityHint(for: entry)
                        ) {
                            Task { await model.delete(entry.id) }
                        }
                    }
                }
            }

            Text("只有词条文本会随识别请求发送给豆包；启用需要 DeepSeek 的整理模式时，词条文本也会一并发送给 DeepSeek。")
                .font(SpeakerTypography.footnote)
                .foregroundStyle(.tertiary)

            if let notice = model.notice {
                SettingsNotice(text: notice)
            }
        }
    }

    private var hasOmittedEntries: Bool {
        !model.omittedEntryIDs.isEmpty
    }

    private var capacityRow: some View {
        HStack(spacing: 10) {
            Label {
                Text(model.sendingCountText)
            } icon: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
            }
            .font(SpeakerTypography.footnote.weight(.medium))
            .foregroundStyle(hasOmittedEntries ? Color.orange : Color.secondary)

            Spacer(minLength: 12)

            DictionaryCapacityBar(
                filledRatio: capacityRatio,
                isAtCapacity: capacityRatio >= 1 && hasOmittedEntries
            )
        }
        .frame(height: 20)
    }

    private var capacityRatio: Double {
        let maximum = DictionaryProviderCapacity.doubao.maximumHotwordCount
        guard maximum > 0 else { return 0 }
        return min(1, Double(model.sentEntryCount) / Double(maximum))
    }
}

/// A silent companion to `sendingCountText`; the numbers stay in that text.
private struct DictionaryCapacityBar: View {
    let filledRatio: Double
    let isAtCapacity: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        if isAtCapacity { return .orange }
        return colorScheme == .dark
            ? SpeakerVisualIdentity.warmAccent
            : SpeakerVisualIdentity.warmAccentDeep
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: geometry.size.width
                            * max(0, min(1, filledRatio))
                    )
            }
        }
        .frame(width: 120, height: 4)
        .accessibilityHidden(true)
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

    package init(model: DictionarySettingsModel) {
        self.model = model
    }

    package var body: some View {
        SpeakerPage {
            DictionarySettingsPage(model: model)
        }
    }
}
