import SwiftUI

/// 设置页底部的红色危险区：本地数据清除的唯一入口。
struct LocalDataSettingsPage: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @State private var confirmsDataErasure = false

    var body: some View {
        SettingsCard(
            "清除本地数据",
            subtitle: "移除这台 Mac 上由 Speaker 保存的全部数据",
            icon: "externaldrive.badge.xmark",
            tint: .red
        ) {
            Text(
                "包括 API Key、会话历史、个人词库、设置、缓存和登录项；完成后 Speaker 退出。系统的麦克风与辅助功能授权不会被撤销。"
            )
            .font(SpeakerTypography.caption)
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
