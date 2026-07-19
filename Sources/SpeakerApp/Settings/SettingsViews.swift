import AppKit
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

private typealias SettingsOverviewSection = SettingsPage

private struct SettingsOverviewSectionFramePreference: PreferenceKey {
    static let defaultValue: [SettingsOverviewSection: CGFloat] = [:]

    static func reduce(
        value: inout [SettingsOverviewSection: CGFloat],
        nextValue: () -> [SettingsOverviewSection: CGFloat]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SettingsOverviewChipSurface: ViewModifier {
    let isActive: Bool
    var tint: Color = .accentColor

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                isActive
                    ? .regular.tint(tint).interactive()
                    : .regular.interactive(),
                in: .capsule
            )
        } else {
            content.background(
                isActive
                    ? tint.opacity(0.14)
                    : Color.primary.opacity(0.04),
                in: Capsule()
            )
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

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

struct StatusBadge: View {
    let text: String
    let icon: String
    let color: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
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

struct SettingsNotice: View {
    let text: String
    var color: Color = .secondary
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
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

struct SettingsView: View {
    let workspace: SettingsWorkspace
    @ObservedObject private var dataErasure: SpeakerDataErasureCoordinator
    @StateObject private var shortcutRecorder = ShortcutRecorderModel()

    init(workspace: SettingsWorkspace) {
        self.workspace = workspace
        dataErasure = workspace.dataErasure
    }

    @ViewBuilder
    var body: some View {
        switch dataErasure.state.workspaceRoute {
        case .normal:
            SettingsOverviewView(
                workspace: workspace,
                shortcutRecorder: shortcutRecorder
            )
            .task {
                await workspace.refresh()
            }
            .onDisappear { shortcutRecorder.stop() }
        case .erasing:
            DataErasureInProgressView()
        case .aboutRecovery:
            AboutView(workspace: workspace)
        }
    }
}

struct DataErasureInProgressView: View {
    var body: some View {
        ContentUnavailableView(
            "本地数据清除中",
            systemImage: "externaldrive.badge.xmark",
            description: Text("Speaker 会在安全清除完成后自动退出。")
        )
    }
}

private struct SettingsOverviewView: View {
    let workspace: SettingsWorkspace
    @ObservedObject private var navigation: SettingsNavigationModel
    @ObservedObject private var permissions: PermissionModel
    @ObservedObject private var shortcut: VoiceShortcutFeature
    @ObservedObject private var doubao: DoubaoSettingsModel
    @ObservedObject private var refinement: RefinementSettingsModel
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    @State private var activeSection = SettingsOverviewSection.shortcut

    init(
        workspace: SettingsWorkspace,
        shortcutRecorder: ShortcutRecorderModel
    ) {
        self.workspace = workspace
        navigation = workspace.navigation
        permissions = workspace.permissions
        shortcut = workspace.shortcut
        doubao = workspace.doubao
        refinement = workspace.refinement
        self.shortcutRecorder = shortcutRecorder
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero

                    ForEach(visibleSections) { section in
                        sectionGroup(section) {
                            sectionContent(section, proxy: proxy)
                        }
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .coordinateSpace(name: "settingsOverviewScroll")
            .onPreferenceChange(
                SettingsOverviewSectionFramePreference.self
            ) { frames in
                let passed = visibleSections.filter {
                    (frames[$0] ?? .infinity) <= 70
                }
                activeSection = passed.last ?? visibleSections.first ?? .shortcut
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                pinnedBar(proxy: proxy)
            }
            .onChange(of: navigation.page) { _, page in
                navigate(to: page, proxy: proxy)
            }
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    navigate(
                        to: navigation.page,
                        proxy: proxy,
                        animated: false
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static let tabSections = SettingsOverviewSection.allCases

    private var visibleSections: [SettingsOverviewSection] {
        Self.tabSections
    }

    private var pendingSections: [SettingsOverviewSection] {
        var pending: [SettingsOverviewSection] = []
        if !doubao.hasConfiguredKey {
            pending.append(.apiKeys)
        }
        if refinement.choice != .defaultSmooth,
           !refinement.hasStoredKey {
            if !pending.contains(.apiKeys) {
                pending.append(.apiKeys)
            }
        }
        if !permissions.snapshot.allGranted {
            pending.append(.permissions)
        }
        return pending
    }

    private var usesGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    Color.accentColor.gradient,
                    in: RoundedRectangle(cornerRadius: 12)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("按下 \(shortcut.preference.displayName) 开始说话")
                    .font(.system(size: 25, weight: .bold))
                Text("松开或再按结束，整理后的文字自动送到当前输入位置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private func pinnedBar(proxy: ScrollViewProxy) -> some View {
        let bar = HStack(spacing: 6) {
            ForEach(visibleSections) { section in
                anchorChip(section, proxy: proxy)
            }
            Spacer()
            readinessChip(proxy: proxy)
        }

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { bar }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)
        } else {
            solidPinnedBar(bar)
        }
    }

    private func solidPinnedBar(_ bar: some View) -> some View {
        VStack(spacing: 0) {
            bar
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(.bar)
            Divider()
        }
    }

    private func anchorChip(
        _ section: SettingsOverviewSection,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            open(section, proxy: proxy)
        } label: {
            HStack(spacing: 5) {
                if let color = statusColor(for: section) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
                Text(section.title)
                    .font(.caption.weight(
                        activeSection == section ? .semibold : .regular
                    ))
            }
            .foregroundStyle(
                activeSection == section
                    ? (usesGlass ? Color.white : Color.accentColor)
                    : Color.secondary
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .modifier(SettingsOverviewChipSurface(
                isActive: activeSection == section
            ))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func readinessChip(proxy: ScrollViewProxy) -> some View {
        let isReady = pendingSections.isEmpty
        return Button {
            if let target = pendingSections.first {
                open(target, proxy: proxy)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isReady
                    ? "checkmark.circle.fill"
                    : "arrow.down.circle.fill")
                Text(isReady ? "已就绪" : "\(pendingSections.count) 项待配置")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(
                usesGlass ? Color.white : (isReady ? Color.green : Color.orange)
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .modifier(SettingsOverviewChipSurface(
                isActive: true,
                tint: isReady ? .green : .orange
            ))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isReady)
        .help(isReady ? "所有必需配置均已完成" : "点击跳到第一个待配置项")
    }

    private func sectionGroup<Content: View>(
        _ section: SettingsOverviewSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            content()
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SettingsOverviewSectionFramePreference.self,
                    value: [
                        section: geometry.frame(
                            in: .named("settingsOverviewScroll")
                        ).minY,
                    ]
                )
            }
        }
        .id(section)
    }

    @ViewBuilder
    private func sectionContent(
        _ section: SettingsOverviewSection,
        proxy: ScrollViewProxy
    ) -> some View {
        switch section {
        case .shortcut:
            ShortcutSettingsPage(
                shortcut: workspace.shortcut,
                shortcutRecorder: shortcutRecorder,
                openSpeechSettings: {
                    open(.permissions, proxy: proxy)
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
        case .refinement:
            RefinementSettingsPage(model: workspace.refinement)
        case .general:
            GeneralSettingsPage(
                loginItemSettings: workspace.loginItemSettings,
                history: workspace.history,
                softwareUpdate: workspace.softwareUpdate
            )
        }
    }

    private func open(
        _ section: SettingsOverviewSection,
        proxy: ScrollViewProxy
    ) {
        if navigation.page == section {
            navigate(to: section, proxy: proxy)
        } else {
            navigation.open(section)
        }
    }

    private func navigate(
        to section: SettingsOverviewSection,
        proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        guard visibleSections.contains(section) else { return }
        activeSection = section
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(section, anchor: .top)
            }
        } else {
            proxy.scrollTo(section, anchor: .top)
        }
    }

    private func statusColor(
        for section: SettingsOverviewSection
    ) -> Color? {
        switch section {
        case .shortcut, .refinement, .general:
            return nil
        case .apiKeys:
            if case .failure = doubao.status { return .red }
            if case .checking = doubao.status { return .blue }
            if refinement.connectionFailure != nil { return .red }
            if !doubao.hasConfiguredKey { return .orange }
            if refinement.choice != .defaultSmooth,
               !refinement.hasStoredKey {
                return .orange
            }
            return .green
        case .permissions:
            if permissions.snapshot.microphone == .restricted
                || permissions.snapshot.accessibility == .restricted {
                return .red
            }
            return permissions.snapshot.allGranted ? .green : .orange
        }
    }
}

private struct ShortcutSettingsPage: View {
    @ObservedObject var shortcut: VoiceShortcutFeature
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    let openSpeechSettings: () -> Void

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
                                    openSpeechSettings()
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
    let history: HistoryModel
    let softwareUpdate: SoftwareUpdateFeature

    var body: some View {
        SettingsCard(
            "通用",
            subtitle: "启动、历史保留与软件更新",
            icon: "switch.2"
        ) {
            LaunchAtLoginSettingsRow(model: loginItemSettings)
            HistorySavingSettingsRow(model: history)
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

private struct HistorySavingSettingsRow: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        Toggle(
            "保存历史",
            isOn: Binding(
                get: { model.retentionPolicy.savesNewRecords },
                set: { enabled in
                    Task {
                        await model.setRetentionPolicy(
                            enabled ? .forever : .disabled
                        )
                    }
                }
            )
        )
        .toggleStyle(.switch)
        .disabled(model.isUpdatingRetention)
    }
}

private struct AutomaticUpdateSettingsRow: View {
    @ObservedObject var model: SoftwareUpdateFeature

    @ViewBuilder
    var body: some View {
        if model.state.isAvailable {
            Divider()

            Toggle(
                "自动检查更新",
                isOn: Binding(
                    get: { model.state.automaticallyChecksForUpdates },
                    set: { model.setAutomaticallyChecksForUpdates($0) }
                )
            )
            .toggleStyle(.switch)
        }
    }
}

struct AboutView: View {
    let workspace: SettingsWorkspace

    var body: some View {
        ScrollView {
            AboutSettingsPage(
                dataErasure: workspace.dataErasure,
                softwareUpdate: workspace.softwareUpdate
            )
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await workspace.refresh() }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @ObservedObject var softwareUpdate: SoftwareUpdateFeature
    @State private var confirmsDataErasure = false

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return "版本 \(version)（\(build)）"
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
                            NSWorkspace.shared.open(privacyPolicyURL)
                        }
                    }
                    Button("打开本地数据文件夹") {
                        NSWorkspace.shared.open(Self.applicationSupportDirectory)
                    }
                    Spacer()
                }
            }

            SettingsCard(
                AboutSection.localData.title,
                subtitle: "完全清除这台 Mac 上由 Speaker 保存的数据",
                icon: AboutSection.localData.icon
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

                if case let .failed(failure) = dataErasure.state {
                    SettingsNotice(
                        text: Self.failureMessage(failure),
                        color: .red
                    )
                }
            }

            SettingsCard(
                AboutSection.version.title,
                subtitle: versionText,
                icon: AboutSection.version.icon
            ) {
                HStack {
                    Spacer()
                    if softwareUpdate.state.isAvailable {
                        Button("检查更新…") {
                            softwareUpdate.checkForUpdates()
                        }
                        .disabled(!softwareUpdate.state.canCheckForUpdates)
                    }
                    Link(
                        "github.com/simonwong/speaker",
                        destination: URL(
                            string: "https://github.com/simonwong/speaker"
                        )!
                    )
                }
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

    private static func failureMessage(
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

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Speaker", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static var privacyPolicyURL: URL? {
        Bundle.main.url(
            forResource: "PRIVACY",
            withExtension: "md"
        )
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

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("API Key")
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        SecureField(
                            model.hasConfiguredKey ? "输入新 Key 以替换当前凭据" : "输入豆包语音 API Key",
                            text: $model.apiKeyDraft
                        )
                        .textContentType(.password)

                        Button(model.hasConfiguredKey ? "替换 Key" : "保存 Key") {
                            Task { await model.save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.apiKeyDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }
                }

                GridRow {
                    Text("流式资源")
                        .font(.subheadline.weight(.medium))
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
                    .frame(maxWidth: 300, alignment: .leading)
                }
            }

            HStack(spacing: 10) {
                if case .checking = model.status {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("检查连接") {
                    model.checkConnection()
                }
                .disabled(!model.hasConfiguredKey || isChecking)

                Text("资源类型必须与控制台中已开通的套餐一致。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("删除 Key", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(!model.hasConfiguredKey)
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
        case .configured: "Key 已保存在本机"
        case .checking: "正在检查连接"
        case .success: "连接成功"
        case .failure: model.summary
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .success: .green
        case .failure: .red
        case .checking: .blue
        case .loading, .unconfigured, .configured: .secondary
        }
    }
}

private struct DeepSeekSettingsCard: View {
    @ObservedObject var model: RefinementSettingsModel
    @State private var confirmingDelete = false

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

            HStack(spacing: 8) {
                SecureField(
                    model.hasStoredKey
                        ? "输入新 Key 以替换当前凭据"
                        : "输入 DeepSeek API Key",
                    text: $model.apiKeyDraft
                )
                .textContentType(.password)

                Button(model.hasStoredKey ? "替换 Key" : "保存 Key") {
                    Task { await model.saveAPIKey() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.apiKeyDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        || model.isCheckingConnection
                )
            }

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
                .disabled(!model.hasStoredKey || model.isCheckingConnection)

                Spacer()

                Button("删除 Key", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(!model.hasStoredKey || model.isCheckingConnection)
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
    }

    private var statusText: String {
        if model.isConnectionVerified { return "已验证" }
        if model.connectionFailure != nil { return "连接失败" }
        if model.hasStoredKey { return "已保存，待验证" }
        return "未配置"
    }

    private var statusIcon: String {
        if model.isConnectionVerified { return "checkmark.circle.fill" }
        if model.connectionFailure != nil { return "xmark.circle.fill" }
        if model.hasStoredKey { return "exclamationmark.circle.fill" }
        return "key.slash"
    }

    private var statusColor: Color {
        if model.isConnectionVerified { return .green }
        if model.connectionFailure != nil { return .red }
        if model.hasStoredKey { return .orange }
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
    @State private var pendingDeleteID: UUID?

    var body: some View {
        SettingsCard(
            "个人词库",
            subtitle: "识别后会把完整且无歧义的别名替换成标准写法",
            icon: "text.book.closed"
        ) {
            HStack {
                StatusBadge(
                    text: "\(model.entries.filter(\.isEnabled).count) 个启用词条",
                    icon: "checkmark",
                    color: .green
                )
                Spacer()
                Text("修改后自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("标准写法")
                        .font(.caption.weight(.medium))
                    TextField("例如：DeepSeek", text: $model.draftCanonical)
                }
                GridRow {
                    Text("口语别名")
                        .font(.caption.weight(.medium))
                    HStack(spacing: 8) {
                        TextField("例如：deep seek，深度求索", text: $model.draftAliases)
                            .onSubmit { Task { await model.add() } }
                        Button("添加词条") {
                            Task { await model.add() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.draftCanonical
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }
                }
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
                        Text("添加产品名、人名或专业术语，提高最终文本一致性。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 8) {
                    ForEach($model.entries) { $entry in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $entry.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: entry.isEnabled) {
                                    model.scheduleSave()
                                }

                            TextField("标准写法", text: $entry.canonicalTerm)
                                .frame(minWidth: 130)
                                .onSubmit { Task { await model.saveEdits() } }
                                .onChange(of: entry.canonicalTerm) {
                                    model.scheduleSave()
                                }

                            TextField(
                                "别名（逗号分隔）",
                                text: Binding(
                                    get: { entry.aliases.joined(separator: "，") },
                                    set: { value in
                                        entry.aliases = value
                                            .split(whereSeparator: {
                                                $0 == "," || $0 == "，" || $0.isNewline
                                            })
                                            .map(String.init)
                                    }
                                )
                            )
                            .onSubmit { Task { await model.saveEdits() } }
                            .onChange(of: entry.aliases) {
                                model.scheduleSave()
                            }

                            Button {
                                pendingDeleteID = entry.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除词条")
                            .accessibilityLabel("删除词条 \(entry.canonicalTerm)")
                            .accessibilityHint("删除前会再次确认")
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }

            if let notice = model.notice {
                SettingsNotice(text: notice)
            }
        }
        .confirmationDialog(
            "删除这个词条？",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除词条", role: .destructive) {
                guard let id = pendingDeleteID else { return }
                pendingDeleteID = nil
                Task { await model.delete(id) }
            }
            Button("取消", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text("删除后仅影响新的语音输入，已有会话历史不会改变。")
        }
    }
}

struct DictionaryTabView: View {
    @ObservedObject var model: DictionarySettingsModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DictionarySettingsPage(model: model)
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
