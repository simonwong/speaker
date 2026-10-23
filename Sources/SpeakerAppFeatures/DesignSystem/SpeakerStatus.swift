import SwiftUI

/// A state beside its row: a filled-circle glyph in the tone's colour and
/// plain text. Settled tones (neutral grey, healthy green) use secondary
/// text, so a card of them stays quiet; only a tone that asks for attention
/// keeps full-strength text.
///
/// `icon` names a `*.circle.fill` symbol and defaults to the tone's; its
/// glyph draws white on the coloured circle.
package struct StatusBadge: View {
    private let text: String
    private let icon: String?
    private let tone: SpeakerTone
    @Environment(\.colorSchemeContrast) private var contrast

    package init(text: String, icon: String? = nil, tone: SpeakerTone) {
        self.text = text
        self.icon = icon
        self.tone = tone
    }

    package var body: some View {
        Label {
            Text(text)
                .foregroundStyle(
                    tone.isSettled && contrast != .increased ? Color.secondary : Color.primary
                )
        } icon: {
            Image(systemName: icon ?? tone.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tone.color)
        }
        .font(SpeakerTypography.detail)
        .lineLimit(1)
    }
}

/// The one inline message: a tone, a sentence, and optionally one action and
/// a dismiss button, on a rounded fill inside or beside a card.
package struct SpeakerNotice: View {
    /// The glyph before the text.
    package enum Glyph: Equatable, Sendable {
        /// The tone's own symbol, so a red failure never wears an
        /// information icon.
        case tone
        /// Another symbol in the tone's colour.
        case symbol(String)
        /// A symbol in the secondary brand gold, for news rather than state.
        case highlight(String)
    }

    /// The notice's single action. Only the setup banner's next step is
    /// prominent.
    package struct Action {
        let title: String
        let prominent: Bool
        let hint: String?
        let perform: () -> Void

        package init(
            _ title: String,
            prominent: Bool = false,
            hint: String? = nil,
            perform: @escaping () -> Void
        ) {
            self.title = title
            self.prominent = prominent
            self.hint = hint
            self.perform = perform
        }
    }

    /// The trailing close button.
    package struct Dismiss {
        let label: String
        let help: String?
        let perform: () -> Void

        package init(label: String, help: String? = nil, perform: @escaping () -> Void) {
            self.label = label
            self.help = help
            self.perform = perform
        }
    }

    private let tone: SpeakerTone
    private let text: String
    private let glyph: Glyph
    private let action: Action?
    private let dismiss: Dismiss?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    package init(
        tone: SpeakerTone = .neutral,
        text: String,
        glyph: Glyph = .tone,
        action: Action? = nil,
        onDismiss: Dismiss? = nil
    ) {
        self.tone = tone
        self.text = text
        self.glyph = glyph
        self.action = action
        dismiss = onDismiss
    }

    private var increasedContrast: Bool { contrast == .increased }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SpeakerRadius.inner, style: .continuous)
    }

    private var symbolName: String {
        switch glyph {
        case .tone: tone.symbol
        case .symbol(let name), .highlight(let name): name
        }
    }

    private var glyphColor: Color {
        if case .highlight = glyph {
            return colorScheme == .dark
                ? SpeakerVisualIdentity.warmGold : SpeakerVisualIdentity.warmGoldDeep
        }
        return tone.color
    }

    /// Settled tones read as secondary text; a warning or error keeps its
    /// colour unless Increase Contrast asks for full-strength text.
    private var textColor: Color {
        if increasedContrast { return .primary }
        return tone.isSettled ? .secondary : tone.color
    }

    /// A neutral notice must not read as a coloured status, so it drops to
    /// the plain grey fill.
    private var fill: Color {
        tone == .neutral && !increasedContrast
            ? SpeakerFill.subtle
            : SpeakerFill.tone(tone, increasedContrast: increasedContrast)
    }

    package var body: some View {
        HStack(spacing: SpeakerSpacing.s) {
            Label {
                Text(text)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(glyphColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(SpeakerButtonStyle(prominent: action.prominent))
                    .fixedSize()
                    // Glass buttons can drop out of AppKit's accessibility
                    // tree; the bridge keeps the action reachable.
                    .accessibilityHidden(true)
                    .overlay {
                        AccessibilityButtonBridge(
                            label: action.title,
                            hint: action.hint,
                            action: action.perform
                        )
                    }
            }

            if let dismiss {
                SpeakerIconButton(
                    symbol: "xmark",
                    label: dismiss.label,
                    help: dismiss.help,
                    size: .compact,
                    action: dismiss.perform
                )
            }
        }
        .font(SpeakerTypography.detail)
        .padding(.horizontal, SpeakerSpacing.m)
        .padding(.vertical, SpeakerSpacing.s)
        .background(fill, in: shape)
        .overlay {
            if increasedContrast {
                shape.stroke(tone.color.opacity(0.7), lineWidth: 1)
            }
        }
    }
}
