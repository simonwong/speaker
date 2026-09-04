import SwiftUI

/// The single mapping from a Doubao connection state to what the user sees.
///
/// The settings page and the onboarding window both badge the same state, so
/// they read the same text, SF Symbol and tint from here instead of keeping a
/// private switch each.
package struct DoubaoStatusPresentation: Equatable, Sendable {
    package let text: String
    package let symbolName: String
    package let tint: Color

    package init(status: DoubaoConnectionStatus) {
        switch status {
        case .loading:
            text = SpeakerCopy.DoubaoStatus.loading
            symbolName = "clock"
            tint = .secondary
        case .unconfigured:
            text = SpeakerCopy.DoubaoStatus.unconfigured
            symbolName = "key.slash"
            tint = .secondary
        case .configured:
            text = SpeakerCopy.DoubaoStatus.configured
            symbolName = "checkmark.shield"
            tint = .green
        case .checking:
            text = SpeakerCopy.DoubaoStatus.checking
            symbolName = "arrow.triangle.2.circlepath"
            tint = .blue
        case .success:
            text = SpeakerCopy.DoubaoStatus.success
            symbolName = "checkmark.circle.fill"
            tint = .green
        case let .failure(message):
            text = message
            symbolName = "exclamationmark.triangle.fill"
            tint = .red
        }
    }
}
