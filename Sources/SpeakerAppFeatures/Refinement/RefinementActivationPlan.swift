import SpeakerCore

package struct RefinementActivationPlan: Equatable, Sendable {
    package let activeMode: TextRefinementMode
    package let deferredMode: TextRefinementMode?

    package init(
        desiredMode: TextRefinementMode,
        hasStoredKey: Bool
    ) {
        if desiredMode.requiresRefinement, !hasStoredKey {
            activeMode = .defaultSmooth
            deferredMode = desiredMode
        } else {
            activeMode = desiredMode
            deferredMode = nil
        }
    }
}
