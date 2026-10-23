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
                SettingsNotice(text: message, color: .secondary)
                    .padding(.top, SpeakerSurfaceMetrics.cardSpacing)
            }

            projectCard
                .padding(.top, SpeakerSurfaceMetrics.sectionSpacing)

            authorCard
                .padding(.top, SpeakerSurfaceMetrics.cardSpacing)

            privacyBoundaryCard
                .padding(.top, SpeakerSurfaceMetrics.cardSpacing)

            diagnosticsCard
                .padding(.top, SpeakerSurfaceMetrics.cardSpacing)
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
                    .font(SpeakerTypography.pageTitle)
                Text("按住快捷键说话，文字送达松开时所在的输入框。")
                    .font(SpeakerTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(versionText)
                    .font(SpeakerTypography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("当前版本 \(versionText)")
            }

            Spacer(minLength: 12)

            Button("检查更新…") {
                softwareUpdate.checkForUpdates()
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(!softwareUpdate.state.canCheckForUpdates)
        }
    }

    private var projectCard: some View {
        SettingsCard(
            AboutSection.project.title,
            icon: AboutSection.project.icon
        ) {
            SpeakerRow("官网", detail: "speaker.moonunder.app", icon: "globe") {
                Button("打开官网") {
                    routeEffects.openURL(ExternalLinks.speakerWebsite)
                }
            }
            SettingsRowDivider()
            SpeakerRow(
                "源代码",
                detail: "MIT 许可证",
                icon: "chevron.left.forwardslash.chevron.right"
            ) {
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
            SettingsRowDivider()
            SpeakerRow("反馈问题", icon: "exclamationmark.bubble") {
                Button("提交反馈") {
                    routeEffects.openURL(ExternalLinks.speakerIssues)
                }
            }
        }
    }

    private var authorCard: some View {
        SettingsCard(
            AboutSection.author.title,
            icon: AboutSection.author.icon
        ) {
            SpeakerRow("Simon Wong", detail: "simonwong.cn", icon: "person.fill") {
                Button("打开网站") {
                    routeEffects.openURL(ExternalLinks.authorWebsite)
                }
                .accessibilityLabel("打开 Simon Wong 的网站")
            }
            SettingsRowDivider()
            SpeakerRow("MoonUnder Studio", detail: "moonunder.app", icon: "building.2") {
                Button("打开网站") {
                    routeEffects.openURL(ExternalLinks.studioWebsite)
                }
                .accessibilityLabel("打开 MoonUnder Studio 的网站")
            }
        }
    }

    private var privacyBoundaryCard: some View {
        SettingsCard(
            AboutSection.privacyBoundary.title,
            icon: AboutSection.privacyBoundary.icon
        ) {
            SpeakerRow(
                "音频",
                detail: "只在内存中转换并发送给所选语音识别服务，不写入磁盘或历史。",
                icon: "waveform"
            )
            SettingsRowDivider()
            SpeakerRow(
                "识别文字",
                detail: "保留在本机；只有启用文字整理模式时才会发送给所选文字整理服务。",
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
    }

    /// Startup and recovery warnings land here, next to the redacted
    /// diagnostics copy that failure guidance elsewhere points to.
    private var diagnosticsCard: some View {
        SettingsCard(
            AboutSection.diagnostics.title,
            icon: AboutSection.diagnostics.icon
        ) {
            ForEach(diagnostics.warnings, id: \.self) { warning in
                SettingsNotice(text: warning, color: .orange)
            }
            if !diagnostics.warnings.isEmpty {
                HStack {
                    Spacer()
                    Button("清除提示") {
                        diagnostics.dismissWarnings()
                    }
                }
                SettingsRowDivider()
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
                SettingsNotice(text: SpeakerCopy.Diagnostics.copied, color: .green)
            case .failed:
                SettingsNotice(text: SpeakerCopy.Diagnostics.copyFailed, color: .orange)
            case nil:
                EmptyView()
            }
        }
    }
}
