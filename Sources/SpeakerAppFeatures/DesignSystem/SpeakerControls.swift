import SwiftUI

/// Window buttons: native glass buttons on macOS 26, bordered buttons before
/// it and under Reduce Transparency.
///
/// Only a prominent button, the one action that submits what the user just
/// entered, takes the brand coral. Every other button carries no tint and
/// stays neutral: a glass button fills its whole body with any tint it
/// inherits, so a tint above these buttons would colour every secondary
/// action. A destructive button stays neutral with red text; the
/// confirmation dialog states its scope.
///
/// A regular-size button grows to the large capsule: at regular size the
/// glass is a small rounded rectangle that all but vanishes on the glass
/// card, and the large capsule matches the fields and menus beside it. A
/// caller that asks for a smaller size keeps it.
package struct SpeakerButtonStyle: PrimitiveButtonStyle {
    private let prominent: Bool
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle
    @Environment(\.controlSize) private var controlSize

    package init(prominent: Bool = false) {
        self.prominent = prominent
    }

    package func makeBody(configuration: Configuration) -> some View {
        styled(configuration)
            .buttonBorderShape(.capsule)
            .controlSize(controlSize == .regular ? .large : controlSize)
    }

    @ViewBuilder
    private func styled(_ configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            // Glass over the glass card, or a disabled button on the window
            // ground, can sample nearly the colour beneath it and vanish; a
            // faint capsule underneath keeps its edge.
            if prominent {
                Button(configuration).buttonStyle(.glassProminent)
                    .tint(SpeakerVisualIdentity.controlTint)
                    .background(SpeakerFill.control, in: Capsule())
            } else {
                Button(configuration).buttonStyle(.glass)
                    .modifier(DestructiveLabel(role: configuration.role))
                    .background(SpeakerFill.control, in: Capsule())
            }
        } else if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
                .tint(SpeakerVisualIdentity.controlTint)
        } else {
            Button(configuration).buttonStyle(.bordered)
                .modifier(DestructiveLabel(role: configuration.role))
        }
    }
}

/// A destructive neutral button keeps its glass or bezel and turns only its
/// label red.
private struct DestructiveLabel: ViewModifier {
    let role: ButtonRole?

    @ViewBuilder
    func body(content: Content) -> some View {
        if role == .destructive {
            content.foregroundStyle(SpeakerTone.error.color)
        } else {
            content
        }
    }
}

package struct SpeakerTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    package init() {}

    package func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, SpeakerSpacing.m)
            .frame(minHeight: SpeakerControlMetrics.height)
            .speakerField(focused: focused)
    }
}

/// A text field that grows to several lines. It keeps the single-line field's
/// height while empty, but wraps its lines in a rounded rectangle with
/// vertical padding, so a second line never touches a capsule's curve.
package struct SpeakerMultilineTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    package init() {}

    package func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, SpeakerSpacing.m)
            .padding(.vertical, SpeakerSpacing.s)
            .frame(minHeight: SpeakerControlMetrics.height)
            .speakerEditorField(focused: focused)
    }
}

extension View {
    /// A row's trailing menu: the row title names it, and every menu in a card
    /// shares one right-hand column. The large size draws the same capsule as
    /// the buttons and fields.
    package func speakerTrailingMenu() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.large)
            .frame(maxWidth: SpeakerControlMetrics.trailingWidth, alignment: .trailing)
    }

    /// A switch, the only toggle style the windows use, in the control coral.
    package func speakerSwitch() -> some View {
        toggleStyle(.switch)
            .tint(SpeakerVisualIdentity.controlTint)
    }

    /// A progress bar or level meter in the control coral.
    package func speakerProgress() -> some View {
        tint(SpeakerVisualIdentity.controlTint)
    }
}

/// An icon-only button: a centred glyph in a fixed hit area, a circle that
/// appears on hover, a press response, a tooltip, and an accessibility label.
package struct SpeakerIconButton: View {
    package enum Size: Sendable {
        /// 28 pt, beside other 28 pt controls.
        case regular
        /// 20 pt, only inside a 28 pt control, such as a chip.
        case compact
    }

    private let symbol: String
    private let label: String
    private let help: String?
    private let size: Size
    private let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(
        symbol: String,
        label: String,
        help: String? = nil,
        size: Size = .regular,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.help = help
        self.size = size
        self.action = action
    }

    private var side: CGFloat {
        size == .regular ? SpeakerControlMetrics.height : SpeakerControlMetrics.compactHeight
    }

    // A glyph centred in a fixed hit circle: the size belongs to the circle,
    // not to the text ladder.
    private var glyphFont: Font {
        size == .regular
            ? .system(size: 13, weight: .medium)
            : .system(size: 9, weight: .bold)
    }

    package var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(glyphFont)
                .foregroundStyle(.secondary)
                .frame(width: side, height: side)
                .background(Circle().fill(isHovered ? SpeakerFill.selected : .clear))
                .contentShape(Circle())
                .animation(reduceMotion ? nil : SpeakerMotion.feedback, value: isHovered)
        }
        .buttonStyle(SpeakerPressableButtonStyle(pressedScale: SpeakerMotion.compactPressedScale))
        .onHover { isHovered = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// A shortcut drawn as one key, the height of the buttons beside it. While
/// Speaker waits for a new shortcut, the keycap takes the focus ring and its
/// prompt recedes.
package struct SpeakerKeycap: View {
    private let name: String
    private let isRecording: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    package init(name: String, isRecording: Bool = false) {
        self.name = name
        self.isRecording = isRecording
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SpeakerRadius.inner, style: .continuous)
    }

    package var body: some View {
        Text(name)
            .font(SpeakerTypography.emphasis)
            .fontDesign(.rounded)
            .foregroundStyle(isRecording ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, SpeakerSpacing.m)
            .frame(
                minWidth: SpeakerControlMetrics.keycapMinWidth,
                minHeight: SpeakerControlMetrics.height
            )
            .background(SpeakerFill.control, in: shape)
            .overlay {
                if isRecording {
                    shape.strokeBorder(SpeakerStroke.focus, lineWidth: SpeakerStroke.focusWidth)
                } else {
                    shape.strokeBorder(
                        SpeakerStroke.hairline(increasedContrast: contrast == .increased),
                        lineWidth: 1
                    )
                }
            }
    }
}

/// A single-line capsule naming one item, with an optional delete button.
/// An omitted item gets an orange hairline and a leading warning glyph; a
/// quality hint is a trailing secondary glyph whose text goes to the
/// tooltip. The caller supplies the accessibility label that carries both.
package struct SpeakerChip: View {
    private let text: String
    private let isOmitted: Bool
    private let hintSymbol: String?
    private let help: String?
    private let deleteLabel: String?
    private let onDelete: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    package init(
        _ text: String,
        isOmitted: Bool = false,
        hintSymbol: String? = nil,
        help: String? = nil,
        deleteLabel: String? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.text = text
        self.isOmitted = isOmitted
        self.hintSymbol = hintSymbol
        self.help = help
        self.deleteLabel = deleteLabel
        self.onDelete = onDelete
    }

    private var strokeColor: Color {
        if isOmitted {
            return SpeakerTone.warning.color.opacity(contrast == .increased ? 0.8 : 0.35)
        }
        return SpeakerStroke.hairline(increasedContrast: contrast == .increased)
    }

    package var body: some View {
        HStack(spacing: SpeakerSpacing.xs) {
            if isOmitted {
                Image(systemName: SpeakerTone.warning.symbol)
                    .foregroundStyle(SpeakerTone.warning.color)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(SpeakerTypography.emphasis)
                .foregroundStyle(isOmitted ? .secondary : .primary)
                .lineLimit(1)
            if let hintSymbol {
                Image(systemName: hintSymbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if let onDelete {
                SpeakerIconButton(
                    symbol: "xmark",
                    label: deleteLabel ?? text,
                    size: .compact,
                    action: onDelete
                )
            }
        }
        .font(SpeakerTypography.detail)
        .padding(.leading, SpeakerSpacing.m)
        .padding(.trailing, onDelete == nil ? SpeakerSpacing.m : SpeakerSpacing.xs)
        .frame(height: SpeakerControlMetrics.height)
        .background(SpeakerFill.control, in: Capsule())
        .overlay { Capsule().strokeBorder(strokeColor, lineWidth: 1) }
        .help(help ?? "")
    }
}

/// An external URL: secondary text and a trailing arrow. In-app actions are
/// buttons, never links.
package struct SpeakerLink: View {
    private let title: String
    private let destination: URL

    package init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    package var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: "arrow.up.right")
                .labelStyle(TrailingIconLabelStyle())
        }
        // A surrounding capsule style would otherwise dress the link as a
        // button. Link buttons ignore `tint` and draw the system link blue,
        // so the colour is set here to stay neutral.
        .buttonStyle(.link)
        .foregroundStyle(.secondary)
        .font(SpeakerTypography.detail)
        .speakerPointingHandCursor()
    }
}

/// A link title followed by its glyph, like "豆包控制台 ↗".
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SpeakerSpacing.hairline) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
