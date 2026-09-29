import AppKit

/// The single source for Voice Input HUD classification and geometry.
///
/// The strip inside the HUD reads `contentSize` and the panel presenter reads
/// `size`, so the SwiftUI surface and the window hosting it can never disagree
/// about the footprint. Only the inset between them lives here as a constant.
package enum VoiceInputPanelLayout: Equatable, Sendable {
    case processing
    case recording
    /// Text strips fit their content: the width is measured from the text
    /// they show, between a floor that keeps them a pill and a ceiling past
    /// which the text truncates.
    case pendingCopy(width: CGFloat)
    case problem(width: CGFloat)

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
        case .pendingCopy(let title, let text, _, _, _, let copyFailed):
            self = .pendingCopy(
                width: Self.pendingCopyWidth(
                    text: text,
                    failureTitle: copyFailed ? title : nil
                )
            )
        case .problem(_, let title, _, _, _):
            self = .problem(width: Self.problemWidth(title: title))
        }
    }

    /// The strip's own footprint. Recording and processing share one pill so
    /// the surface keeps a single identity from press to result; every state
    /// shares the pill's height, so the HUD only ever changes width.
    package var contentSize: CGSize {
        switch self {
        case .processing, .recording:
            CGSize(width: 104, height: Self.stripHeight)
        case .pendingCopy(let width), .problem(let width):
            CGSize(width: width, height: Self.stripHeight)
        }
    }

    /// Icon, title and close control, with the strip's own padding.
    package static func problemWidth(title: String) -> CGFloat {
        let chrome: CGFloat = 14 + 18 + 9 + 9 + 26 + 4
        return fitted(
            textWidth(title, style: .callout) + chrome,
            minimum: 140,
            maximum: 320
        )
    }

    /// The text sits between the dismiss and copy controls; the width keeps
    /// room for both so revealing dismiss on hover never truncates it.
    package static func pendingCopyWidth(text: String, failureTitle: String?) -> CGFloat {
        let chrome: CGFloat = 38 + 38
        let failure = failureTitle.map { textWidth($0, style: .caption1) + 8 } ?? 0
        return fitted(
            textWidth(text, style: .callout) + failure + chrome,
            minimum: 160,
            maximum: 360
        )
    }

    private static func textWidth(_ text: String, style: NSFont.TextStyle) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: style)
        return NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private static func fitted(_ width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, width.rounded(.up)))
    }

    private static let stripHeight: CGFloat = 34

    /// The panel footprint: the strip plus its inset on every edge.
    package var size: CGSize {
        CGSize(
            width: contentSize.width + 2 * Self.contentInset,
            height: contentSize.height + 2 * Self.contentInset
        )
    }
}
