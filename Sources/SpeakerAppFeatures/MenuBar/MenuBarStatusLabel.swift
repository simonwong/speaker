import SpeakerCore
import SwiftUI

/// The menu bar extra's label.
///
/// It observes the two states its artwork depends on directly, so recording
/// and permission changes redraw the status item without the runtime
/// forwarding its children's change notifications.
package struct MenuBarStatusLabel: View {
    @ObservedObject var voiceInput: VoiceInputExperience
    @ObservedObject var permissions: PermissionModel

    package init(
        voiceInput: VoiceInputExperience,
        permissions: PermissionModel
    ) {
        self.voiceInput = voiceInput
        self.permissions = permissions
    }

    package var body: some View {
        SpeakerMenuBarLabel(
            state: MenuBarPresentation.iconState(
                isRecording: voiceInput.state.isRecording,
                permissions: permissions.snapshot
            )
        )
    }
}
