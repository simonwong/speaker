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
        case .processing:
            CGSize(width: 72, height: 40)
        case .recording:
            CGSize(width: 106, height: 42)
        case .pendingCopy:
            CGSize(width: 312, height: 68)
        case .problem:
            CGSize(width: 300, height: 72)
        }
    }
}
