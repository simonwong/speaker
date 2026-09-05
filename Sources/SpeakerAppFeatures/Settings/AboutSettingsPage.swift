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
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("在 GitHub 查看 Speaker")
            .help("在 GitHub 查看 Speaker")
        }
    }
}
