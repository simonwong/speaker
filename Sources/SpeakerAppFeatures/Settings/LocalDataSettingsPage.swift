import SwiftUI

/// 设置页底部的本地数据分组：本地数据清除的唯一入口。卡片和标题保持中性，
/// 只有清除按钮的文字是红色，后果写在确认对话框里。
struct LocalDataSettingsPage: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @State private var confirmsDataErasure = false

    var body: some View {
        SpeakerCard {
            Text(
                "包括 API Key、会话历史、个人词库、设置、缓存和登录项；完成后 Speaker 退出。系统的麦克风与辅助功能授权不会被撤销。"
            )
            .font(SpeakerTypography.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if dataErasure.state == .erasing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在清除 Speaker 本地数据")
                }
                Button(
                    dataErasure.state == .erasing
                        ? "正在清除…"
                        : "清除本地数据并退出",
                    role: .destructive
                ) {
                    confirmsDataErasure = true
                }
                .disabled(dataErasure.state == .erasing)
            }
        }
        .alert(
            "清除 Speaker 保存的所有本地数据？",
            isPresented: $confirmsDataErasure
        ) {
            Button("取消", role: .cancel) {}
            Button("清除并退出", role: .destructive) {
                Task {
                    _ = await dataErasure.eraseAllAndExit()
                }
            }
        } message: {
            Text(
                "API Key、文字历史、个人词库、设置和登录项将被永久移除。Speaker 不会删除系统权限记录，也无法恢复这些本地数据。"
            )
        }
    }
}
