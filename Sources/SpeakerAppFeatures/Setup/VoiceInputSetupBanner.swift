import SwiftUI

/// The Overview's top row while a `VoiceInputSetupGap` remains. It names what
/// is missing and opens the Settings group that fixes it.
struct VoiceInputSetupBanner: View {
    let gap: VoiceInputSetupGap
    let open: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(gap.message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(gap.actionTitle, action: open)
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .fixedSize()
                .accessibilityHidden(true)
                .overlay {
                    AccessibilityButtonBridge(label: gap.actionTitle, action: open)
                }
        }
        .font(SpeakerTypography.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(contrast == .increased ? 0.16 : 0.07), in: shape)
        .overlay {
            if contrast == .increased {
                shape.stroke(Color.orange.opacity(0.7), lineWidth: 1)
            }
        }
    }
}
