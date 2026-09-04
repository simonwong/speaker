import Combine
import Foundation
import SpeakerCore
import SwiftUI

package enum HistoryOperation: Equatable {
    case copying(VoiceInputSessionID)
    case deleting(VoiceInputSessionID)
    case clearing
    case addingDictionaryEntry
}

/// The History tab's state: the visible Session Records, the moment they were
/// read, and the one operation allowed to run at a time.
@MainActor
package final class HistoryModel: ObservableObject {
    @Published package private(set) var records: [VoiceInputHistoryRecord] = []
    @Published package private(set) var totalRecordCount = 0
    @Published package var query = ""
    @Published package private(set) var notice: String?
    @Published package private(set) var feedback: HistoryDashboardFeedback?
    @Published package private(set) var activeOperation: HistoryOperation?
    /// The moment the last refresh read the store. Day grouping is pinned to
    /// it, so a specification can fix the 今天/昨天 boundary.
    @Published package private(set) var referenceDate: Date

    private let store: any LocalSessionHistoryStoring
    private let clipboard: any ClipboardWriting
    private let dictionary: DictionarySettingsModel
    private let announce: (String) -> Void
    private let now: () -> Date
    private var feedbackTask: Task<Void, Never>?

    package init(
        store: any LocalSessionHistoryStoring,
        clipboard: any ClipboardWriting,
        dictionary: DictionarySettingsModel,
        announce: @escaping (String) -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.clipboard = clipboard
        self.dictionary = dictionary
        self.announce = announce
        self.now = now
        referenceDate = now()
    }

    package var dashboardState: HistoryDashboardState {
        HistoryDashboardState(
            records: records,
            totalRecordCount: totalRecordCount,
            notice: notice,
            feedback: feedback,
            isBusy: activeOperation != nil,
            referenceDate: referenceDate
        )
    }

    package func refresh() async {
        referenceDate = now()
        records = HistoryPresentation.filteredRecords(
            await store.allRecords(),
            query: query
        )
        let status = await store.persistenceStatus()
        totalRecordCount = status.recordCount
        notice = status.notice.map(SpeakerCopy.History.pageNotice)
    }

    @discardableResult
    package func copy(_ record: VoiceInputHistoryRecord) async -> Bool {
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
        publishFeedback(.success, SpeakerCopy.Clipboard.textCopied)
        return true
    }

    @discardableResult
    package func delete(_ id: VoiceInputSessionID) async -> Bool {
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
    package func clear() async -> Bool {
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

    @discardableResult
    package func addDictionaryEntry(_ word: String) async -> Bool {
        guard activeOperation == nil else { return false }
        activeOperation = .addingDictionaryEntry
        defer { activeOperation = nil }
        let feedback = await HistoryDictionaryEntryAddition.perform(
            word: word,
            using: dictionary
        )
        publishFeedback(feedback)
        return feedback.kind == .success
    }

    private func publishFeedback(
        _ kind: HistoryDashboardFeedback.Kind,
        _ message: String
    ) {
        publishFeedback(
            HistoryDashboardFeedback(
                id: UUID(),
                kind: kind,
                message: message
            )
        )
    }

    private func publishFeedback(_ feedback: HistoryDashboardFeedback) {
        self.feedback = feedback
        announce(feedback.message)
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

package struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    package init(model: HistoryModel) {
        self.model = model
    }

    package var body: some View {
        HistoryDashboard(
            state: model.dashboardState,
            query: $model.query,
            actions: HistoryDashboardActions(
                refresh: { Task { await model.refresh() } },
                clear: { Task { _ = await model.clear() } },
                copy: { record in
                    Task { _ = await model.copy(record) }
                },
                delete: { id in
                    Task { _ = await model.delete(id) }
                },
                addDictionaryEntry: { word in
                    Task { _ = await model.addDictionaryEntry(word) }
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
