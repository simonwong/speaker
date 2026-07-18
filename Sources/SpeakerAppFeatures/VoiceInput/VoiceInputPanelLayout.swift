import CoreGraphics

package enum VoiceInputPanelLayout: Equatable, Sendable {
    case processing
    case recording
    case pendingCopy
    case problem

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

    package var size: CGSize {
        switch self {
        // Recording and processing share one footprint on purpose: the two
        // phases are the same pill, and any size difference would make the
        // panel jump mid-session.
        case .processing, .recording:
            CGSize(width: 128, height: 44)
        case .pendingCopy:
            CGSize(width: 394, height: 54)
        case .problem:
            CGSize(width: 330, height: 54)
        }
    }
}
