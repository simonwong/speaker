import SwiftUI

/// The single mapping from a Doubao connection state to what the user sees.
///
/// The settings page and the onboarding window both badge the same state, so
/// they read the same text, SF Symbol and tone from here instead of keeping a
/// private switch each. Working and in-progress states stay neutral grey;
/// colour is kept for a failure.
package struct DoubaoStatusPresentation: Equatable, Sendable {
    package let text: String
    package let symbolName: String
    package let tone: SpeakerTone

    package init(status: DoubaoConnectionStatus) {
        switch status {
        case .loading:
            text = SpeakerCopy.ProviderStatus.loading
            symbolName = "clock.circle.fill"
            tone = .neutral
        case .unconfigured:
            text = SpeakerCopy.ProviderStatus.unconfigured
            symbolName = "key.circle.fill"
            tone = .neutral
        case .configured:
            text = SpeakerCopy.ProviderStatus.configured
            symbolName = "checkmark.circle.fill"
            tone = .ok
        case .checking:
            text = SpeakerCopy.ProviderStatus.checking
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
            tone = .neutral
        case .success:
            text = SpeakerCopy.ProviderStatus.success
            symbolName = "checkmark.circle.fill"
            tone = .ok
        case .failure:
            text = SpeakerCopy.ProviderStatus.failure
            symbolName = "xmark.circle.fill"
            tone = .error
        }
    }
}
