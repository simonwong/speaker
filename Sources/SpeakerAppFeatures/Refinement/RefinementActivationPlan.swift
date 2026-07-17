import SpeakerCore

package struct RefinementActivationPlan: Equatable, Sendable {
    package let activeMode: TextRefinementMode
    package let deferredMode: TextRefinementMode?

    package init(
        desiredMode: TextRefinementMode,
        hasStoredKey: Bool
    ) {
        if desiredMode.requiresDeepSeek, !hasStoredKey {
            activeMode = .defaultSmooth
            deferredMode = desiredMode
        } else {
            activeMode = desiredMode
            deferredMode = nil
        }
    }
}
