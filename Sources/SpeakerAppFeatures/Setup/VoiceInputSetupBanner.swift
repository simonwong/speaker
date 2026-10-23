import SwiftUI

/// The Overview's top row while a `VoiceInputSetupGap` remains. It names what
/// is missing and opens the Settings group that fixes it. Finishing setup is
/// the one thing the Overview asks for, so its action is the only prominent
/// notice action.
struct VoiceInputSetupBanner: View {
    let gap: VoiceInputSetupGap
    let open: () -> Void

    var body: some View {
        SpeakerNotice(
            tone: .warning,
            text: gap.message,
            glyph: .symbol("exclamationmark.triangle.fill"),
            action: .init(gap.actionTitle, prominent: true, perform: open)
        )
    }
}
