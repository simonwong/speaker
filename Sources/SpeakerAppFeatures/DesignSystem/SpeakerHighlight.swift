import SwiftUI

/// How a block inside a card marks itself as picked: a refinement mode card
/// or a Custom Mode row. Coral says the block is in use; gold says it is open
/// in the editor but not yet in use. A block with neither keeps
/// `SpeakerFill.subtle` and the hairline.
package enum SpeakerHighlight: Equatable, Sendable {
    /// In use: the selection coral.
    case selected
    /// Open in the editor, not yet in use: the secondary brand gold.
    case editing

    /// The fill under a block without Liquid Glass.
    package var fill: Color {
        switch self {
        case .selected: SpeakerVisualIdentity.controlTint.opacity(0.10)
        case .editing: SpeakerVisualIdentity.warmGold.opacity(0.10)
        }
    }

    /// The tint a Liquid Glass block takes; glass thins a tint, so it is a
    /// step stronger than `fill`.
    package var glassTint: Color {
        switch self {
        case .selected: SpeakerVisualIdentity.controlTint.opacity(0.16)
        case .editing: SpeakerVisualIdentity.warmGold.opacity(0.14)
        }
    }

    /// The ring around the block, drawn `SpeakerStroke.focusWidth` wide.
    package var stroke: Color {
        switch self {
        case .selected: SpeakerVisualIdentity.controlTint.opacity(0.8)
        case .editing: SpeakerVisualIdentity.warmGoldDeep.opacity(0.7)
        }
    }

    /// The block's leading glyph and state glyph.
    package var accent: Color {
        switch self {
        case .selected: SpeakerVisualIdentity.controlTint
        case .editing: SpeakerVisualIdentity.warmGoldDeep
        }
    }
}
