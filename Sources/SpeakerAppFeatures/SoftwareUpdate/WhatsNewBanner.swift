import SwiftUI

/// The Overview's top row after an update: names the new version and opens
/// its release notes. Either action marks the version as seen. It is news,
/// not a state or a submit, so it stays neutral with a gold glyph and a plain
/// button.
struct WhatsNewBanner: View {
    let version: String
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        SpeakerNotice(
            text: "Speaker 已更新到 \(version)。",
            glyph: .highlight("sparkles"),
            action: .init("看看更新了什么", perform: open),
            onDismiss: .init(label: "关闭更新提示", help: "不再显示", perform: dismiss)
        )
    }
}
