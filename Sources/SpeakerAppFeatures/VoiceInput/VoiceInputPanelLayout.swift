import CoreGraphics

/// The single source for Voice Input HUD classification and geometry.
///
/// The strip inside the HUD reads `contentSize` and the panel presenter reads
/// `size`, so the SwiftUI surface and the window hosting it can never disagree
/// about the footprint. Only the inset between them lives here as a constant.
package enum VoiceInputPanelLayout: Equatable, Sendable {
    case processing
    case recording
    case pendingCopy
    case problem

    /// Transparent room the panel keeps around the strip so the drop shadow
    /// and the reveal animation are never clipped by the window edge.
    package static let contentInset: CGFloat = 5

    package init?(_ presentation: VoiceInputOverlayPresentation) {
        switch presentation {
        case .hidden:
            return nil
        case .processing:
            self = .processing
        case .recording:
            self = .recording
        case .pendingCopy:
            self = .pendingCopy
        case .problem:
            self = .problem
        }
    }

    /// The strip's own footprint. Recording and processing share one pill so
    /// the surface keeps a single identity from press to result.
    package var contentSize: CGSize {
        switch self {
        case .processing, .recording:
            CGSize(width: 118, height: 34)
        case .pendingCopy:
            CGSize(width: 384, height: 44)
        case .problem:
            CGSize(width: 320, height: 44)
        }
    }

    /// The panel footprint: the strip plus its inset on every edge.
    package var size: CGSize {
        CGSize(
            width: contentSize.width + 2 * Self.contentInset,
            height: contentSize.height + 2 * Self.contentInset
        )
    }
}
