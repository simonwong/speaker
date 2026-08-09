import AppKit
import Combine
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

/// Adapts Voice Input Experience state and App-owned Settings routing to the
/// deep HUD presentation module.
@MainActor
final class VoiceInputPanelController {
    private let experience: VoiceInputExperience
    private let presenter: VoiceInputPanelPresenter<VoiceInputOverlay>
    private var stateCancellable: AnyCancellable?

    init(
        experience: VoiceInputExperience,
        routeEffect: @escaping (VoiceInputExperienceEffect) -> Void
    ) {
        self.experience = experience
        let performAction: (VoiceInputExperienceAction) -> VoiceInputExperienceEffect? = {
            [weak experience] action in
            experience?.perform(action)
        }
        presenter = VoiceInputPanelPresenter { presentation in
            VoiceInputOverlay(
                presentation: presentation,
                performAction: performAction,
                routeEffect: routeEffect
            )
        }
    }

    func start() {
        guard stateCancellable == nil else { return }
        presenter.start()
        stateCancellable = experience.$state.sink { [weak presenter] state in
            presenter?.present(state.overlay)
        }
    }

    func stop() {
        stateCancellable = nil
        presenter.stop()
    }

#if DEBUG
    func captureDebugSnapshot(to url: URL) throws {
        try presenter.captureDebugSnapshot(to: url)
    }
#endif
}

/// App-owned adapter for the system Settings side effect. HUD rendering and
/// AppKit presentation stay in SpeakerAppFeatures; this view supplies the
/// Environment action that only the App scene owns.
private struct VoiceInputOverlay: View {
    let presentation: VoiceInputOverlayPresentation
    let performAction:
        (VoiceInputExperienceAction) -> VoiceInputExperienceEffect?
    let routeEffect: (VoiceInputExperienceEffect) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VoiceInputHUD(
            presentation: presentation,
            performAction: performAction,
            routeEffect: { effect in
                routeEffect(effect)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}
