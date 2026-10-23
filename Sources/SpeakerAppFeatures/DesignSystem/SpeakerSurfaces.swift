import AppKit
import SwiftUI

// The containers every tab and the onboarding window compose from. Product
// copy stays in the calling surface; only neutral presentation lives here.

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

/// Text links show the pointing hand, as on the rest of the Mac; buttons,
/// switches, menus, and rows keep the arrow. A disabled link keeps the arrow.
package struct SpeakerPointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    package func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.modifier(LegacyPointingHandCursor(isActive: isEnabled))
        }
    }
}

/// macOS 14 has no `pointerStyle`, so the cursor stack is balanced by hand:
/// one push on entry, one pop on exit, disable, or disappearance.
private struct LegacyPointingHandCursor: ViewModifier {
    let isActive: Bool
    @State private var isHovered = false
    @State private var hasPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovered in
                isHovered = hovered
                sync(hovered: hovered, active: isActive)
            }
            .onChange(of: isActive) { _, active in
                sync(hovered: isHovered, active: active)
            }
            .onDisappear {
                isHovered = false
                sync(hovered: false, active: isActive)
            }
    }

    private func sync(hovered: Bool, active: Bool) {
        let wantsHand = hovered && active
        guard wantsHand != hasPushed else { return }
        if wantsHand {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
        hasPushed = wantsHand
    }
}

extension View {
    package func speakerPointingHandCursor() -> some View {
        modifier(SpeakerPointingHandCursor())
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
        if focused { return SpeakerStroke.focus }
        // A glass field inside a glass card loses its edge in dark mode, so
        // every style keeps a hairline.
        return SpeakerStroke.hairline(increasedContrast: contrast == .increased)
    }

    private var borderWidth: CGFloat {
        if focused { return SpeakerStroke.focusWidth }
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
                shape: RoundedRectangle(cornerRadius: SpeakerRadius.inner, style: .continuous)
            ))
    }
}

/// The card surface every tab and the onboarding window share: Liquid Glass
/// on macOS 26, the system material before it, and opaque paper under Reduce
/// Transparency.
package struct SpeakerCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

    package init() {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SpeakerRadius.card, style: .continuous)
    }

    private var strokeColor: Color {
        if contrast == .increased {
            return Color.primary.opacity(0.32)
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
            content.glassEffect(.regular, in: shape)
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
    }
}

extension View {
    package func speakerCard() -> some View {
        modifier(SpeakerCardSurface())
    }
}

/// A glass card holding settings the user changes. It carries no title or
/// icon: a `SpeakerSectionHeader` above it names the group. Rows inside are
/// separated by `SpeakerRowDivider`.
package struct SpeakerCard<Content: View>: View {
    private let content: Content

    package init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: SpeakerSurfaceMetrics.rowSpacing) {
            content
        }
        .speakerCard()
        .buttonStyle(SpeakerButtonStyle())
        .textFieldStyle(SpeakerTextFieldStyle())
    }
}

/// The line between two rows inside one card. Nothing outside a card draws
/// one.
package struct SpeakerRowDivider: View {
    package init() {}

    package var body: some View {
        Divider().opacity(0.6)
    }
}

/// The 28 pt rounded square that fronts a row standing for a system object
/// with a status, such as a permission. It stays neutral unless its tone
/// asks for attention; brand colours never fill it.
package struct SpeakerIconTile: View {
    private let symbol: String
    private let tone: SpeakerTone?

    package init(symbol: String, tone: SpeakerTone? = nil) {
        self.symbol = symbol
        self.tone = tone
    }

    private var attentionTone: SpeakerTone? {
        guard let tone, !tone.isSettled else { return nil }
        return tone
    }

    package var body: some View {
        Image(systemName: symbol)
            // A glyph centred in a fixed 28 pt tile: the size belongs to the
            // tile, not to the text ladder.
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(attentionTone?.color ?? Color.secondary)
            .frame(width: SpeakerControlMetrics.height, height: SpeakerControlMetrics.height)
            .background(
                attentionTone.map { $0.color.opacity(0.12) } ?? SpeakerFill.control,
                in: RoundedRectangle(cornerRadius: SpeakerRadius.inner, style: .continuous)
            )
            // Decoration: the title beside it already says what it stands for.
            .accessibilityHidden(true)
    }
}

/// The content column: centred, at most `contentMaxWidth` wide, inset from
/// the window edges. Every tab's scrolling content and History's toolbar and
/// status line use it, so their edges line up.
package struct SpeakerPageColumn: ViewModifier {
    @Environment(\.mainWindowLayout) private var mainWindowLayout

    package init() {}

    package func body(content: Content) -> some View {
        content
            .frame(maxWidth: SpeakerSurfaceMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, mainWindowLayout.pageHorizontalPadding)
    }
}

extension View {
    package func speakerPageColumn() -> some View {
        modifier(SpeakerPageColumn())
    }
}

/// The shared scrolling page: one centred content column on the window
/// ground, identical in every tab that uses it. It has no title: the tab bar
/// names the page.
package struct SpeakerPage<Content: View>: View {
    private let content: Content

    package init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .speakerPageColumn()
            .padding(.top, SpeakerSurfaceMetrics.pageTopPadding)
            .padding(.bottom, SpeakerSurfaceMetrics.pageBottomPadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The only group heading: outside its card, inset so it aligns with the
/// card's corner curve.
package struct SpeakerSectionHeader: View {
    private let title: String

    package init(_ title: String) {
        self.title = title
    }

    package var body: some View {
        Text(title)
            .font(SpeakerTypography.label)
            .foregroundStyle(.secondary)
            .padding(.leading, SpeakerSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One line inside a card: optional icon tile, title, a detail that states a
/// value or state, and trailing controls.
package struct SpeakerRow<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let icon: String?
    private let iconTone: SpeakerTone?
    private let trailing: Trailing

    package init(
        _ title: String,
        detail: String? = nil,
        icon: String? = nil,
        iconTone: SpeakerTone? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.iconTone = iconTone
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(alignment: .center, spacing: SpeakerSpacing.m) {
            if let icon {
                SpeakerIconTile(symbol: icon, tone: iconTone)
            }

            VStack(alignment: .leading, spacing: SpeakerSpacing.hairline) {
                Text(title)
                    .font(SpeakerTypography.emphasis)
                if let detail {
                    Text(detail)
                        .font(SpeakerTypography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: SpeakerSpacing.m)

            trailing
        }
        .padding(.vertical, SpeakerSpacing.xs)
        .frame(minHeight: SpeakerControlMetrics.rowMinHeight)
    }
}

extension SpeakerRow where Trailing == EmptyView {
    package init(
        _ title: String,
        detail: String? = nil,
        icon: String? = nil,
        iconTone: SpeakerTone? = nil
    ) {
        self.init(title, detail: detail, icon: icon, iconTone: iconTone) {
            EmptyView()
        }
    }
}

/// An empty state inside the window. `ContentUnavailableView` is kept for
/// states that take over the whole window.
package struct SpeakerEmptyState: View {
    private let title: String
    private let description: String?
    private let systemImage: String

    package init(title: String, description: String? = nil, systemImage: String) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
    }

    package var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .padding(.bottom, SpeakerSpacing.hairline)
                .accessibilityHidden(true)
            Text(title)
                .font(SpeakerTypography.emphasis)
            if let description {
                Text(description)
                    .font(SpeakerTypography.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}
