import SwiftUI

/// The Overview's top row after an update: names the new version and opens
/// its release notes. Either action marks the version as seen.
struct WhatsNewBanner: View {
    let version: String
    let open: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(SpeakerVisualIdentity.controlTint)
                .accessibilityHidden(true)
            Text("Speaker 已更新到 \(version)。")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("看看更新了什么", action: open)
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .fixedSize()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("不再显示")
            .accessibilityLabel("关闭更新提示")
        }
        .font(SpeakerTypography.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            SpeakerVisualIdentity.controlTint.opacity(contrast == .increased ? 0.16 : 0.07),
            in: shape
        )
        .overlay {
            if contrast == .increased {
                shape.stroke(SpeakerVisualIdentity.controlTint.opacity(0.7), lineWidth: 1)
            }
        }
    }
}
