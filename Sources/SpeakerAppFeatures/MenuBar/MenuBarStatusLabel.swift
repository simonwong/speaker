import SpeakerCore
import SwiftUI

/// The menu bar extra's label.
///
/// It observes the states its artwork depends on directly, so recording,
/// permission, and recognition Key changes redraw the status item without the
/// runtime forwarding its children's change notifications.
package struct MenuBarStatusLabel: View {
    @ObservedObject var voiceInput: VoiceInputExperience
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var doubao: DoubaoSettingsModel
    @ObservedObject var recognition: SpeechRecognitionSettingsModel

    package init(
        voiceInput: VoiceInputExperience,
        permissions: PermissionModel,
        doubao: DoubaoSettingsModel,
        recognition: SpeechRecognitionSettingsModel
    ) {
        self.voiceInput = voiceInput
        self.permissions = permissions
        self.doubao = doubao
        self.recognition = recognition
    }

    package var body: some View {
        SpeakerMenuBarLabel(
            state: MenuBarPresentation.iconState(
                isRecording: voiceInput.state.isRecording,
                setupGap: VoiceInputSetupGap.current(
                    permissions: permissions.snapshot,
                    doubao: doubao,
                    recognition: recognition
                )
            )
        )
    }
}
