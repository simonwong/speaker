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
            text = SpeakerCopy.ProviderStatus.loading
            symbolName = "clock"
            tint = .secondary
        case .unconfigured:
            text = SpeakerCopy.ProviderStatus.unconfigured
            symbolName = "key.slash"
            tint = .secondary
        case .configured:
            text = SpeakerCopy.ProviderStatus.configured
            symbolName = "checkmark.shield"
            tint = .green
        case .checking:
            text = SpeakerCopy.ProviderStatus.checking
            symbolName = "arrow.triangle.2.circlepath"
            tint = .blue
        case .success:
            text = SpeakerCopy.ProviderStatus.success
            symbolName = "checkmark.circle.fill"
            tint = .green
        case .failure:
            text = SpeakerCopy.ProviderStatus.failure
            symbolName = "xmark.circle.fill"
            tint = .red
        }
    }
}
