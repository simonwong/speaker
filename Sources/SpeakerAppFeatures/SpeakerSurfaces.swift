import SwiftUI

/// The main window's shared design language: one metric scale, one type
/// ladder, and the containers every tab composes from. Product copy stays in
/// the calling surface; only neutral presentation lives here.
package enum SpeakerSurfaceMetrics {
    /// Shared content column for all five tabs, card edges included.
    package static let contentMaxWidth: CGFloat = 720
    package static let pageTopPadding: CGFloat = 24
    package static let pageBottomPadding: CGFloat = 32
    package static let sectionSpacing: CGFloat = 28
    package static let cardSpacing: CGFloat = 16
    package static let cardCornerRadius: CGFloat = 12
    package static let cardPadding: CGFloat = 16
    package static let cardHeaderSpacing: CGFloat = 14
    package static let rowSpacing: CGFloat = 12
    package static let controlCornerRadius: CGFloat = 8
    package static let chipCornerRadius: CGFloat = 8
    package static let iconTileSize: CGFloat = 28
    package static let iconTileCornerRadius: CGFloat = 7
}

/// The only type ladder the main window uses.
///
/// Every rung is a relative text style, so the whole window follows the
/// accessibility text size instead of freezing at one point size. The names
/// stay product-facing: `caption` is the small supporting line, which the
/// system ladder calls Callout, and `footnote` the smallest, which it calls
/// Subheadline.
package enum SpeakerTypography {
    package static let pageTitle = Font.title2.weight(.semibold)
    package static let cardTitle = Font.headline
    package static let sectionHeader = Font.callout.weight(.semibold)
    package static let body = Font.body
    package static let bodyEmphasis = Font.body.weight(.medium)
    package static let caption = Font.callout
    package static let footnote = Font.subheadline
    package static let mono = Font.system(
        .subheadline,
        design: .monospaced
    ).weight(.medium)
    package static let metricNumber = Font.system(
        .title2,
        design: .serif
    ).weight(.semibold).monospacedDigit()

    /// The overview's headline figure is display typography: no text style is
    /// large enough, so the surface scales `heroNumberBaseSize` through
    /// `@ScaledMetric` and passes the result here.
    package static let heroNumberBaseSize: CGFloat = 64

    package static func heroNumber(size: CGFloat) -> Font {
        Font.system(size: size, weight: .semibold, design: .serif)
            .monospacedDigit()
    }
}

/// The card paper: window background stays the ground, cards lift one step.
package struct SpeakerCardSurface: ViewModifier {
    private let tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    package init(tint: Color?) {
        self.tint = tint
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SpeakerSurfaceMetrics.cardCornerRadius,
            style: .continuous
        )
    }

    private var strokeColor: Color {
        if contrast == .increased {
            return (tint ?? Color.primary).opacity(0.32)
        }
        if let tint {
            return tint.opacity(0.35)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }

    package func body(content: Content) -> some View {
        content
            .padding(SpeakerSurfaceMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if colorScheme == .dark {
                            shape.fill(Color.primary.opacity(0.045))
                        }
                    }
                    .overlay {
                        if let tint {
                            shape.fill(tint.opacity(0.04))
                        }
                    }
            }
            .overlay {
                shape.strokeBorder(
                    strokeColor,
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            }
            .shadow(
                color: colorScheme == .dark
                    ? .clear
                    : .black.opacity(0.04),
                radius: 10,
                y: 3
            )
    }
}

extension View {
    package func speakerCard(tint: Color? = nil) -> some View {
        modifier(SpeakerCardSurface(tint: tint))
    }
}

/// The 28pt rounded square that fronts a card header or a row.
package struct SpeakerIconTile: View {
    private let symbol: String
    private let tint: Color?

    package init(symbol: String, tint: Color? = nil) {
        self.symbol = symbol
        self.tint = tint
    }

    package var body: some View {
        Image(systemName: symbol)
            // A glyph centred in a fixed 28pt tile: the size belongs to the
            // tile, not to the text ladder.
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint ?? Color.secondary)
            .frame(
                width: SpeakerSurfaceMetrics.iconTileSize,
                height: SpeakerSurfaceMetrics.iconTileSize
            )
            .background(
                (tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.12),
                in: RoundedRectangle(
                    cornerRadius: SpeakerSurfaceMetrics.iconTileCornerRadius,
                    style: .continuous
                )
            )
    }
}

package struct SpeakerCardHeader: View {
    private let title: String
    private let subtitle: String?
    private let icon: String
    private let tint: Color?

    package init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        tint: Color? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
    }

    package var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SpeakerIconTile(symbol: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SpeakerTypography.cardTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(SpeakerTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shared scrolling page: one centered content column on the window
/// ground, identical in every tab that uses it.
package struct SpeakerPage<Content: View>: View {
    @Environment(\.mainWindowLayout) private var mainWindowLayout
    private let content: Content

    package init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
            .padding(.top, SpeakerSurfaceMetrics.pageTopPadding)
            .padding(.bottom, SpeakerSurfaceMetrics.pageBottomPadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

package struct SpeakerSectionHeader: View {
    private let title: String
    private let tint: Color

    package init(_ title: String, tint: Color = .secondary) {
        self.title = title
        self.tint = tint
    }

    package var body: some View {
        Text(title)
            .font(SpeakerTypography.sectionHeader)
            .foregroundStyle(tint)
            .padding(.leading, 4)
    }
}

/// One line inside a card: optional icon tile, title, explanation, and a
/// trailing control.
package struct SpeakerRow<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let icon: String?
    private let iconTint: Color?
    private let trailing: Trailing

    package init(
        _ title: String,
        detail: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.iconTint = iconTint
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                SpeakerIconTile(symbol: icon, tint: iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SpeakerTypography.bodyEmphasis)
                if let detail {
                    Text(detail)
                        .font(SpeakerTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.vertical, 4)
    }
}

extension SpeakerRow where Trailing == EmptyView {
    package init(
        _ title: String,
        detail: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil
    ) {
        self.init(
            title,
            detail: detail,
            icon: icon,
            iconTint: iconTint
        ) {
            EmptyView()
        }
    }
}

/// A labelled read-only block of text: history detail and refinement prompts
/// share this shape.
package struct SpeakerTextBlock: View {
    private let title: String
    private let text: String
    private let isPlaceholder: Bool

    package init(title: String, text: String, isPlaceholder: Bool = false) {
        self.title = title
        self.text = text
        self.isPlaceholder = isPlaceholder
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SpeakerTypography.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(SpeakerTypography.body)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(
                        cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
                        style: .continuous
                    )
                )
        }
    }
}

package struct SpeakerEmptyState: View {
    private let title: String
    private let description: String
    private let systemImage: String

    package init(title: String, description: String, systemImage: String) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
    }

    package var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(SpeakerTypography.bodyEmphasis)
            Text(description)
                .font(SpeakerTypography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}
