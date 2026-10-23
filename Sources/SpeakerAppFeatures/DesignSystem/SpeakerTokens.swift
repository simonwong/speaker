import QuartzCore
import SwiftUI

// Speaker's design tokens. Page code reads every font, distance, radius,
// control size, and status colour from here instead of writing a number or a
// `Color` literal; docs/design-system.md names the role of each value.

/// The only type ladder the windows use: six roles and the Overview's display
/// digits.
///
/// Every role is a relative text style, so the whole window follows the
/// accessibility text size instead of freezing at one point size. Only
/// `.monospacedDigit()` may follow a role; a weight never does.
package enum SpeakerTypography {
    /// An identity or step title: About's "Speaker", onboarding step titles.
    package static let title = Font.title2.weight(.semibold)
    /// Section headers, history day headers, small bold labels.
    package static let label = Font.callout.weight(.semibold)
    /// Row titles, chip text, keycaps (with `.fontDesign(.rounded)`).
    package static let emphasis = Font.body.weight(.medium)
    /// Content, field text, history text.
    package static let body = Font.body
    /// Every secondary line: row detail, notices, badges, counts, legends.
    package static let detail = Font.callout
    /// Request IDs and the history time column.
    package static let mono = Font.system(.callout, design: .monospaced).weight(.medium)

    /// Display digits for the Overview's figures only; not a text role.
    package enum Display {
        package static let metric = Font.system(.title2, design: .serif)
            .weight(.semibold).monospacedDigit()

        /// No text style is large enough for the headline figure, so the
        /// surface scales `heroBaseSize` through `@ScaledMetric` and passes
        /// the result to `hero(size:)`.
        package static let heroBaseSize: CGFloat = 64

        package static func hero(size: CGFloat) -> Font {
            Font.system(size: size, weight: .semibold, design: .serif)
                .monospacedDigit()
        }
    }
}

/// The spacing scale, on a 4 pt grid.
package enum SpeakerSpacing {
    /// Title to its detail line, between history rows, between tab segments.
    package static let hairline: CGFloat = 2
    /// Glyph to text, field label to field.
    package static let xs: CGFloat = 4
    /// Controls in one group, section header to card, between chips.
    package static let s: CGFloat = 8
    /// Icon tile to text, rows inside a card, notice side padding.
    package static let m: CGFloat = 12
    /// Card padding, between cards in one group.
    package static let l: CGFloat = 16
    /// Page top.
    package static let xl: CGFloat = 24
    /// Between settings groups, page bottom.
    package static let xxl: CGFloat = 32
}

/// Corner radii. Every 28 pt interactive control is a `Capsule()` instead,
/// and an icon button's hover background a `Circle()`.
package enum SpeakerRadius {
    /// Glass cards and onboarding cards.
    package static let card: CGFloat = 12
    /// Rectangles inside a card: notices, multi-line editors, mode cards,
    /// history and custom-mode rows, keycaps, icon tiles.
    package static let inner: CGFloat = 8
}

/// Control sizes. Every control in one row shares `height`.
package enum SpeakerControlMetrics {
    /// Buttons, menus, fields, search, keycap, chip, icon-button hit area,
    /// icon tile.
    package static let height: CGFloat = 28
    /// Only a button inside a 28 pt control, such as a chip's delete button.
    package static let compactHeight: CGFloat = 20
    /// `SpeakerRow`: a 28 pt control plus 4 pt above and below.
    package static let rowMinHeight: CGFloat = 36
    /// Widest a row's trailing menu may grow, so every picker in a card ends
    /// on the same column.
    package static let trailingWidth: CGFloat = 260
    /// The smallest keycap, so a one-letter key still reads as a key.
    package static let keycapMinWidth: CGFloat = 56
}

/// The page layout, composed from the scales above.
package enum SpeakerSurfaceMetrics {
    /// Shared content column for every tab, card edges included.
    package static let contentMaxWidth: CGFloat = 720
    package static let pageTopPadding = SpeakerSpacing.xl
    package static let pageBottomPadding = SpeakerSpacing.xxl
    /// Between settings groups.
    package static let sectionSpacing = SpeakerSpacing.xxl
    /// From a section header down to its card.
    package static let sectionHeaderSpacing = SpeakerSpacing.s
    /// Between cards in one group.
    package static let cardSpacing = SpeakerSpacing.l
    package static let cardPadding = SpeakerSpacing.l
    /// Between rows inside a card.
    package static let rowSpacing = SpeakerSpacing.m
}

/// What a status means. Views take a tone and read its colour and glyph here,
/// so no surface infers meaning by comparing colours.
package enum SpeakerTone: Equatable, Sendable {
    case neutral
    case ok
    case warning
    case error

    package var color: Color {
        switch self {
        case .neutral: .secondary
        case .ok: SpeakerVisualIdentity.settledGreen
        case .warning: .orange
        case .error: .red
        }
    }

    /// A `*.circle.fill` symbol; its glyph draws white on the tone's circle.
    package var symbol: String {
        switch self {
        case .neutral: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    /// Settled tones recede into secondary text; only a tone that asks for
    /// attention keeps full-strength text and colours an icon tile.
    package var isSettled: Bool {
        self == .neutral || self == .ok
    }
}

/// Neutral and tone fills.
package enum SpeakerFill {
    /// A neutral notice, a hover.
    package static let subtle = Color.primary.opacity(0.04)
    /// Keycap, chip, icon tile, the underlay of a glass button, a track.
    package static let control = Color.primary.opacity(0.06)
    /// Tab selection, an expanded row, an icon button's hover.
    package static let selected = Color.primary.opacity(0.10)

    /// A tone-coloured background, stronger under Increase Contrast.
    package static func tone(_ tone: SpeakerTone, increasedContrast: Bool) -> Color {
        tone.color.opacity(increasedContrast ? 0.16 : 0.07)
    }
}

/// Edges.
package enum SpeakerStroke {
    /// The hairline around a field, keycap, or chip.
    package static func hairline(increasedContrast: Bool) -> Color {
        Color.primary.opacity(increasedContrast ? 0.4 : 0.1)
    }

    /// A focused field or a keycap waiting for a new shortcut.
    package static let focus = SpeakerVisualIdentity.controlTint.opacity(0.7)
    package static let focusWidth: CGFloat = 1.5
}

/// The windows' motion rungs. Each eases out and stays well under 300 ms;
/// callers drop movement under Reduce Motion.
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
