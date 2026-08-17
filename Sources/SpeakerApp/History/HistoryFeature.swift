import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SwiftUI

enum HistoryOperation: Equatable {
    case copying(VoiceInputSessionID)
    case deleting(VoiceInputSessionID)
    case clearing
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [VoiceInputHistoryRecord] = []
    @Published private(set) var totalRecordCount = 0
    @Published var query = ""
    @Published private(set) var notice: String?
    @Published private(set) var feedback: HistoryDashboardFeedback?
    @Published private(set) var activeOperation: HistoryOperation?

    private let store: any LocalSessionHistoryStoring
    private let clipboard: any ClipboardWriting
    private let announce: (String) -> Void
    private var feedbackTask: Task<Void, Never>?

    init(
        store: any LocalSessionHistoryStoring,
        clipboard: any ClipboardWriting,
        announce: @escaping (String) -> Void
    ) {
        self.store = store
        self.clipboard = clipboard
        self.announce = announce
    }

    func refresh() async {
        records = HistoryPresentation.filteredRecords(
            await store.allRecords(),
            query: query
        )
        let status = await store.persistenceStatus()
        totalRecordCount = status.recordCount
        switch status.notice {
        case let .corruptedDataPreserved(_, reason): notice = "已保留损坏的历史文件：\(reason)"
        case let .corruptedRecordsSkipped(count): notice = "有 \(count) 条历史记录已损坏，已跳过；其他记录仍可使用。"
        case let .privacyMigrationFailed(reason): notice = "旧版历史隐私清理未完成：\(reason)"
        case let .writeFailed(reason): notice = "历史写入失败：\(reason)"
        case nil:
            notice = nil
        }
    }

    @discardableResult
    func copy(_ record: VoiceInputHistoryRecord) async -> Bool {
        guard activeOperation == nil,
              let text = HistoryPresentation.retainedText(for: record)
        else { return false }
        activeOperation = .copying(record.sessionID)
        defer { activeOperation = nil }
        guard await clipboard.copy(text) else {
            publishFeedback(
                .error,
                "无法写入剪贴板，请重试。"
            )
            return false
        }
        publishFeedback(.success, "文字已复制")
        return true
    }

    @discardableResult
    func delete(_ id: VoiceInputSessionID) async -> Bool {
        guard activeOperation == nil else { return false }
        activeOperation = .deleting(id)
        defer { activeOperation = nil }
        guard await store.delete(sessionID: id) else {
            publishFeedback(
                .error,
                "无法删除这条会话记录，请重试。"
            )
            await refresh()
            return false
        }
        await refresh()
        publishFeedback(.success, "会话记录已删除")
        return true
    }

    @discardableResult
    func clear() async -> Bool {
        guard activeOperation == nil else { return false }
        let deletedCount = totalRecordCount
        activeOperation = .clearing
        defer { activeOperation = nil }
        guard await store.clear() else {
            publishFeedback(
                .error,
                "无法清空会话历史，请检查本地存储后重试。"
            )
            await refresh()
            return false
        }
        await refresh()
        publishFeedback(
            .success,
            "已清空 \(deletedCount) 条会话记录"
        )
        return true
    }

    private func publishFeedback(
        _ kind: HistoryDashboardFeedback.Kind,
        _ message: String
    ) {
        let feedback = HistoryDashboardFeedback(
            id: UUID(),
            kind: kind,
            message: message
        )
        self.feedback = feedback
        announce(message)
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                  self?.feedback?.id == feedback.id
            else { return }
            self?.feedback = nil
        }
    }

}


struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    init(model: HistoryModel) {
        self.model = model
    }

    var body: some View {
        HistoryDashboard(
            state: HistoryDashboardState(
                records: model.records,
                totalRecordCount: model.totalRecordCount,
                notice: model.notice,
                feedback: model.feedback,
                isBusy: model.activeOperation != nil
            ),
            query: $model.query,
            actions: HistoryDashboardActions(
                refresh: { Task { await model.refresh() } },
                clear: { Task { _ = await model.clear() } },
                copy: { record in
                    Task { _ = await model.copy(record) }
                },
                delete: { id in
                    Task { _ = await model.delete(id) }
                }
            )
        )
        .task { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
        ) { _ in
            Task { await model.refresh() }
        }
    }
}
