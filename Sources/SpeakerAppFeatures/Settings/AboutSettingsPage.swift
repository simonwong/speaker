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

            if let message = softwareUpdate.state.unavailableMessage {
                SpeakerNotice(text: message)
                    .padding(.top, SpeakerSurfaceMetrics.cardSpacing)
            }

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

    /// The identity block names the product and owns its version and update
    /// check; the project card owns every outside link, so no fact appears
    /// twice on this page.
    private var identity: some View {
        HStack(spacing: 16) {
            SpeakerIdentityTile(size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Speaker")
                    .font(SpeakerTypography.title)
                Text("按住快捷键说话，文字送达松开时所在的输入框。")
                    .font(SpeakerTypography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(versionText)
                    .font(SpeakerTypography.detail.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("当前版本 \(versionText)")
            }

            Spacer(minLength: 12)

            Button("检查更新…") {
                softwareUpdate.checkForUpdates()
            }
            .buttonStyle(SpeakerButtonStyle())
            .disabled(!softwareUpdate.state.canCheckForUpdates)
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        SpeakerRow("官网", detail: "speaker.moonunder.app") {
            Button("打开官网") {
                routeEffects.openURL(ExternalLinks.speakerWebsite)
            }
        }
        SpeakerRowDivider()
        SpeakerRow("源代码", detail: "MIT 许可证") {
            Button {
                routeEffects.openURL(ExternalLinks.speakerRepository)
            } label: {
                Label {
                    Text("在 GitHub 查看")
                } icon: {
                    GitHubMark()
                        .fill(Color.primary)
                        .frame(width: 14, height: 14)
                }
            }
            .accessibilityLabel("在 GitHub 查看 Speaker")
        }
        SpeakerRowDivider()
        SpeakerRow("反馈问题") {
            Button("提交反馈") {
                routeEffects.openURL(ExternalLinks.speakerIssues)
            }
        }
    }

    @ViewBuilder
    private var authorRows: some View {
        SpeakerRow("Simon Wong", detail: "simonw.dev") {
            Button("打开网站") {
                routeEffects.openURL(ExternalLinks.authorWebsite)
            }
            .accessibilityLabel("打开 Simon Wong 的网站")
        }
        SpeakerRowDivider()
        SpeakerRow("MoonUnder Studio", detail: "moonunder.app") {
            Button("打开网站") {
                routeEffects.openURL(ExternalLinks.studioWebsite)
            }
            .accessibilityLabel("打开 MoonUnder Studio 的网站")
        }
    }

    @ViewBuilder
    private var privacyBoundaryRows: some View {
        SpeakerRow(
            "音频",
            detail: "只在内存中转换并发送给所选语音识别服务，不写入磁盘或历史。"
        )
        SpeakerRowDivider()
        SpeakerRow(
            "识别文字",
            detail: "保留在本机；只有启用文字整理模式时才会发送给所选文字整理服务。"
        )
        SpeakerRowDivider()
        SpeakerRow(
            "历史、设置与词库",
            detail: "只保存在这台 Mac 的当前用户目录，不包含音频或 API Key。"
        )
        SpeakerRowDivider()

        HStack {
            Spacer()
            if let privacyPolicyURL = ExternalLinks.privacyPolicy {
                Button("查看完整隐私说明") {
                    routeEffects.openURL(privacyPolicyURL)
                }
            }
            Button("打开本地数据文件夹") {
                routeEffects.openURL(speakerApplicationSupportDirectory)
            }
        }
    }

    /// Startup and recovery warnings land here, next to the redacted
    /// diagnostics copy that failure guidance elsewhere points to.
    @ViewBuilder
    private var diagnosticsRows: some View {
        ForEach(diagnostics.warnings, id: \.self) { warning in
            SpeakerNotice(tone: .warning, text: warning)
        }
        if !diagnostics.warnings.isEmpty {
            HStack {
                Spacer()
                Button("清除提示") {
                    diagnostics.dismissWarnings()
                }
            }
            SpeakerRowDivider()
        }

        SpeakerRow(
            "诊断信息",
            detail: "包含版本、权限和服务状态，不包含文字、音频或 API Key。"
        ) {
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
