import Foundation

package struct VoiceInputPanelDismissal: Equatable, Sendable {
    package let collapsesActivity: Bool
    package let fadeDuration: TimeInterval
    package let completionDelay: Duration
    fileprivate let revision: UInt
}

/// Owns HUD dismissal policy and fences delayed AppKit completion work.
///
/// The App layer applies the returned plan to the live panel. Tests cross the
/// same interface without waiting for wall-clock animation time.
package struct VoiceInputPanelTransitionState: Sendable {
    package private(set) var presentedLayout: VoiceInputPanelLayout?
    private var revision: UInt = 0

    package init() {}

    package mutating func present(_ layout: VoiceInputPanelLayout) {
        revision &+= 1
        presentedLayout = layout
    }

    package mutating func dismiss(
        reduceMotion: Bool
    ) -> VoiceInputPanelDismissal {
        revision &+= 1
        let collapsesActivity = switch presentedLayout {
        case .recording, .processing:
            !reduceMotion
        case .pendingCopy, .problem, nil:
            false
        }
        presentedLayout = nil
        return VoiceInputPanelDismissal(
            collapsesActivity: collapsesActivity,
            fadeDuration: collapsesActivity ? 0.2 : 0.12,
            completionDelay: collapsesActivity
                ? .milliseconds(220)
                : .milliseconds(140),
            revision: revision
        )
    }

    package func canComplete(
        _ dismissal: VoiceInputPanelDismissal
    ) -> Bool {
        presentedLayout == nil && dismissal.revision == revision
    }
}
