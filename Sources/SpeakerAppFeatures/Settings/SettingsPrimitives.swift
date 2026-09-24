import SwiftUI

struct SettingsCard<Content: View>: View {
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
        .buttonStyle(SettingsButtonStyle())
        .textFieldStyle(SettingsTextFieldStyle())
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}

extension View {
    /// A row's trailing menu: the row title names it, and every menu in a card
    /// shares one right-hand column.
    func settingsTrailingMenu() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: SpeakerSurfaceMetrics.trailingControlWidth, alignment: .trailing)
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
                .font(SpeakerTypography.footnote.weight(.semibold))
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
    private let icon: String?
    @Environment(\.colorSchemeContrast) private var contrast

    package init(text: String, color: Color = .secondary, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    /// The glyph follows the notice's severity unless a caller names one, so
    /// a red failure never wears an information icon.
    private var symbolName: String {
        if let icon { return icon }
        switch color {
        case .red: return "xmark.circle.fill"
        case .orange: return "exclamationmark.triangle.fill"
        case .green: return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
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
            Image(systemName: symbolName)
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

var speakerApplicationSupportDirectory: URL {
    FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first?.appendingPathComponent("Speaker", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser
}
