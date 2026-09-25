import QuartzCore
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
    /// Single-line fields match the large capsule buttons and menus beside
    /// them.
    package static let fieldHeight: CGFloat = 28
    package static let chipCornerRadius: CGFloat = 8
    package static let iconTileSize: CGFloat = 28
    package static let iconTileCornerRadius: CGFloat = 7
    /// Widest a row's trailing menu may grow, so every picker in a card ends
    /// on the same column.
    package static let trailingControlWidth: CGFloat = 260
}

/// The main window's motion rungs. Each eases out and stays well under
/// 300 ms; callers drop movement under Reduce Motion.
package enum SpeakerMotion {
    /// The strong ease-out every UI rung shares: it answers in the first
    /// frames instead of easing into motion.
    package static func easeOut(duration: TimeInterval) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
    /// The same curve for AppKit window animations.
    package static func easeOutTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    }
    /// Hover, focus, and press feedback.
    package static let feedback = easeOut(duration: 0.12)
    /// A block appearing, leaving, or changing selection.
    package static let change = easeOut(duration: 0.2)
    /// How far a pressed plain control shrinks. Never towards zero.
    package static let pressedScale: CGFloat = 0.97
    /// Icon-only controls of 26 pt or less shrink a little further, so the
    /// press still reads on so few pixels.
    package static let compactPressedScale: CGFloat = 0.95
}

/// Plain-content buttons that answer a press: a slight shrink, or a dim
/// under Reduce Motion. Disabled buttons fade like the plain style.
package struct SpeakerPressableButtonStyle: ButtonStyle {
    private let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    package init(pressedScale: CGFloat = SpeakerMotion.pressedScale) {
        self.pressedScale = pressedScale
    }

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(opacity(pressed: configuration.isPressed))
            .animation(SpeakerMotion.feedback, value: configuration.isPressed)
    }

    private func opacity(pressed: Bool) -> Double {
        if !isEnabled { return 0.45 }
        return pressed && reduceMotion ? 0.7 : 1
    }
}

/// The surface every editable field sits on: the History search bar,
/// settings text fields, and prompt editors share one glass, one hairline, and
/// one focus ring. Without Liquid Glass it falls back to an inset well.
package struct SpeakerFieldSurface<FieldShape: InsettableShape>: ViewModifier {
    private let focused: Bool
    private let shape: FieldShape
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

    nonisolated package init(focused: Bool, shape: FieldShape) {
        self.focused = focused
        self.shape = shape
    }

    private var borderColor: Color {
        if focused { return .accentColor.opacity(0.7) }
        // A glass field inside a glass card loses its edge in dark mode, so
        // every style keeps a hairline.
        return Color.primary.opacity(contrast == .increased ? 0.4 : 0.1)
    }

    private var borderWidth: CGFloat {
        if focused { return 1.5 }
        return contrast == .increased ? 1 : 0.5
    }

    package func body(content: Content) -> some View {
        surface(content)
            .overlay {
                shape
                    .strokeBorder(borderColor, lineWidth: borderWidth)
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : SpeakerMotion.feedback, value: focused)
            }
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            // Glass over the glass card samples almost the same colour, so a
            // faint well underneath keeps the field legible as a field.
            content
                .background(Color.primary.opacity(0.05), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(Color.primary.opacity(0.05), in: shape)
        }
    }
}

extension View {
    /// A single-line field: a capsule, the same height and shape as the
    /// buttons and menus beside it. Nonisolated so `TextFieldStyle` bodies
    /// can apply it.
    nonisolated package func speakerField(focused: Bool) -> some View {
        modifier(SpeakerFieldSurface(focused: focused, shape: Capsule()))
    }

    /// A multi-line editor keeps a rounded rectangle; a capsule would clip
    /// its corners.
    nonisolated package func speakerEditorField(focused: Bool) -> some View {
        modifier(
            SpeakerFieldSurface(
                focused: focused,
                shape: RoundedRectangle(
                    cornerRadius: SpeakerSurfaceMetrics.controlCornerRadius,
                    style: .continuous
                )
            ))
    }
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

/// The card every tab and the onboarding window share: Liquid Glass on
/// macOS 26, the system material before it, and opaque paper under Reduce
/// Transparency. A tint colours the glass and the edge only lightly, so a
/// warning card reads as a hint rather than a slab.
package struct SpeakerCardSurface: ViewModifier {
    private let tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

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
        switch surfaceStyle {
        case .liquidGlass: return .clear
        case .systemMaterial: return Color.primary.opacity(0.12)
        case .opaque: return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
        }
    }

    package func body(content: Content) -> some View {
        surface(
            content
                .padding(SpeakerSurfaceMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
        .overlay {
            shape
                .strokeBorder(
                    strokeColor,
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(
            color: surfaceStyle == .opaque && colorScheme == .light
                ? .black.opacity(0.04)
                : .clear,
            radius: 10,
            y: 3
        )
    }

    @ViewBuilder
    private func surface(_ content: some View) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(.regular.tint(tint?.opacity(0.14)), in: shape)
        } else if surfaceStyle == .opaque {
            content.background { paper }
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }

    private var paper: some View {
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
            // Decoration: the title beside it already says what it stands for.
            .accessibilityHidden(true)
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
        // A lone title centres on its tile; a subtitle that may wrap keeps
        // the tile beside the first line.
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 10) {
            SpeakerIconTile(symbol: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SpeakerTypography.cardTitle)
                    .accessibilityAddTraits(.isHeader)
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
            .accessibilityAddTraits(.isHeader)
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
                .accessibilityHidden(true)
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
