import SwiftUI

/// 设置页底部的本地数据分组：本地数据清除的唯一入口。卡片和标题保持中性，
/// 只有清除按钮的文字是红色，范围和后果写在确认对话框里。
struct LocalDataSettingsPage: View {
    @ObservedObject var dataErasure: SpeakerDataErasureCoordinator
    @State private var confirmsDataErasure = false

    private var isErasing: Bool { dataErasure.state == .erasing }

    var body: some View {
        SpeakerCard {
            SpeakerRow("清除本地数据") {
                HStack(spacing: SpeakerSpacing.s) {
                    if isErasing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在清除 Speaker 本地数据")
                    }
                    Button(isErasing ? "正在清除…" : "清除并退出…", role: .destructive) {
                        confirmsDataErasure = true
                    }
                    .disabled(isErasing)
                }
            }
        }
        .localDataEraseConfirmation(
            LocalDataEraseConfirmation.title,
            isPresented: $confirmsDataErasure
        ) {
            Task { _ = await dataErasure.eraseAllAndExit() }
        }
    }
}

/// The copy every local-data erase confirmation shares, so Settings and the
/// recovery screen state the same scope.
enum LocalDataEraseConfirmation {
    static let title = "清除 Speaker 保存的所有本地数据？"
    static let retryTitle = "重试清除 Speaker 保存的所有本地数据？"
    static let confirm = "清除并退出"
    static let message =
        "API Key、历史、个人词库、设置、缓存和登录项将被永久删除，随后 Speaker 退出。系统的麦克风与辅助功能授权不受影响。删除后无法恢复。"
}

extension View {
    /// The confirmation in front of a local-data erase.
    func localDataEraseConfirmation(
        _ title: String,
        isPresented: Binding<Bool>,
        erase: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(LocalDataEraseConfirmation.confirm, role: .destructive, action: erase)
            Button("取消", role: .cancel) {}
        } message: {
            Text(LocalDataEraseConfirmation.message)
        }
    }
}
