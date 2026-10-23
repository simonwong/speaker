import SpeakerCore
import SwiftUI

package struct AboutView: View {
    let workspace: SettingsWorkspace

    package init(workspace: SettingsWorkspace) {
        self.workspace = workspace
    }

    package var body: some View {
        SpeakerPage {
            AboutSettingsPage(
                softwareUpdate: workspace.softwareUpdate,
                diagnostics: workspace.diagnostics,
                routeEffects: workspace.routeEffects,
                copyDiagnostics: workspace.copyDiagnostics
            )
        }
        .task { await workspace.refresh() }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var softwareUpdate: SoftwareUpdateFeature
    @ObservedObject var diagnostics: DiagnosticNoticeModel
    let routeEffects: SettingsRouteEffects
    let copyDiagnostics: () async -> Void

    private var versionText: String {
        SpeakerBuildIdentity.current.displayText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity

            VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.sectionSpacing) {
                section(.project) { projectRows }
                section(.author) { authorRows }
                section(.privacyBoundary) { privacyBoundaryRows }
                section(.diagnostics) { diagnosticsRows }
            }
            .padding(.top, SpeakerSurfaceMetrics.sectionSpacing)
        }
    }

    /// Each group is titled outside its card, like the Settings groups.
    private func section<Content: View>(
        _ section: AboutSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.sectionHeaderSpacing) {
            SpeakerSectionHeader(section.title)
            SpeakerCard(content: content)
        }
    }

    /// The app icon's size here: a brand mark, so a local constant.
    private static let identityTileSize: CGFloat = 64

    /// The identity block names the product and owns its version and update
    /// check; the project card owns every outside link, so no fact appears
    /// twice on this page. Why updates are unavailable is said once, in
    /// Settings, and repeated here only as the disabled button's tooltip.
    private var identity: some View {
        HStack(spacing: SpeakerSpacing.l) {
            SpeakerIdentityTile(size: Self.identityTileSize)

            VStack(alignment: .leading, spacing: SpeakerSpacing.xs) {
                Text("Speaker")
                    .font(SpeakerTypography.title)
                Text(versionText)
                    .font(SpeakerTypography.detail.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("当前版本 \(versionText)")
            }

            Spacer(minLength: SpeakerSpacing.m)

            Button("检查更新…") {
                softwareUpdate.checkForUpdates()
            }
            .buttonStyle(SpeakerButtonStyle())
            .disabled(!softwareUpdate.state.canCheckForUpdates)
            .help(softwareUpdate.state.unavailableMessage ?? "")
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        SpeakerRow("官网", detail: "speaker.moonunder.app") {
            Button("打开") {
                routeEffects.openURL(ExternalLinks.speakerWebsite)
            }
            .accessibilityLabel("打开 Speaker 官网")
        }
        SpeakerRowDivider()
        SpeakerRow("源代码", detail: "MIT 许可证") {
            Button {
                routeEffects.openURL(ExternalLinks.speakerRepository)
            } label: {
                Label {
                    Text("GitHub")
                } icon: {
                    GitHubMark()
                        .fill(Color.primary)
                        .frame(width: Self.gitHubMarkSize, height: Self.gitHubMarkSize)
                }
            }
            .accessibilityLabel("在 GitHub 查看 Speaker")
        }
        SpeakerRowDivider()
        SpeakerRow("反馈问题", detail: "GitHub Issues") {
            Button("打开") {
                routeEffects.openURL(ExternalLinks.speakerIssues)
            }
            .accessibilityLabel("在 GitHub 提交反馈")
        }
    }

    /// The GitHub mark sits beside a button title, at its cap height.
    private static let gitHubMarkSize: CGFloat = 14

    @ViewBuilder
    private var authorRows: some View {
        SpeakerRow("Simon Wong", detail: "simonw.dev") {
            Button("打开") {
                routeEffects.openURL(ExternalLinks.authorWebsite)
            }
            .accessibilityLabel("打开 Simon Wong 的网站")
        }
        SpeakerRowDivider()
        SpeakerRow("MoonUnder Studio", detail: "moonunder.app") {
            Button("打开") {
                routeEffects.openURL(ExternalLinks.studioWebsite)
            }
            .accessibilityLabel("打开 MoonUnder Studio 的网站")
        }
    }

    /// The privacy promises. Each action sits on the row it belongs to.
    @ViewBuilder
    private var privacyBoundaryRows: some View {
        SpeakerRow("音频", detail: "只在内存中转换并发送给所选语音识别服务，不写入磁盘或历史")
        SpeakerRowDivider()
        SpeakerRow("识别文字", detail: "保留在本机；只在启用文字整理时发送给所选文字整理服务")
        SpeakerRowDivider()
        SpeakerRow("历史、设置与词库", detail: "只保存在这台 Mac 的当前用户目录，不包含音频或 API Key") {
            Button("在 Finder 中显示") {
                routeEffects.openURL(speakerApplicationSupportDirectory)
            }
            .accessibilityLabel("在 Finder 中显示本地数据")
        }
        if let privacyPolicyURL = ExternalLinks.privacyPolicy {
            SpeakerRowDivider()
            SpeakerRow("完整隐私说明") {
                Button("打开") {
                    routeEffects.openURL(privacyPolicyURL)
                }
                .accessibilityLabel("打开完整隐私说明")
            }
        }
    }

    /// Startup and recovery warnings land here, next to the redacted
    /// diagnostics copy that failure guidance elsewhere points to.
    @ViewBuilder
    private var diagnosticsRows: some View {
        ForEach(diagnostics.warnings, id: \.self) { warning in
            SpeakerNotice(
                tone: .warning,
                text: warning,
                onDismiss: .init(label: "清除提示") { diagnostics.dismissWarnings() }
            )
        }
        if !diagnostics.warnings.isEmpty {
            SpeakerRowDivider()
        }

        SpeakerRow("诊断信息", detail: "不包含文字、音频或 API Key") {
            Button("复制诊断信息") {
                Task { await copyDiagnostics() }
            }
        }

        switch diagnostics.copyResult {
        case .copied:
            SpeakerNotice(tone: .ok, text: SpeakerCopy.Diagnostics.copied)
        case .failed:
            SpeakerNotice(tone: .warning, text: SpeakerCopy.Diagnostics.copyFailed)
        case nil:
            EmptyView()
        }
    }
}
