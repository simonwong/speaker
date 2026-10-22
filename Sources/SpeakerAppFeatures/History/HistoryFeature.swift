import Combine
import Foundation
import SpeakerCore
import SwiftUI

package enum HistoryOperation: Equatable {
    case copying(VoiceInputSessionID)
    case deleting(VoiceInputSessionID)
    case clearing
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
    private let announce: (String) -> Void
    private let now: () -> Date
    private let clock: any VoiceInputClock
    private var refreshID = UUID()
    private var feedbackTask: Task<Void, Never>?

    /// How long a copy, delete, or clear result stays on the History page.
    package static let feedbackDuration: Duration = .seconds(4)

    package init(
        store: any LocalSessionHistoryStoring,
        clipboard: any ClipboardWriting,
        announce: @escaping (String) -> Void,
        now: @escaping () -> Date = { Date() },
        clock: any VoiceInputClock = ContinuousVoiceInputClock()
    ) {
        self.store = store
        self.clipboard = clipboard
        self.announce = announce
        self.now = now
        self.clock = clock
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
        let id = UUID()
        refreshID = id
        let date = now()
        let snapshot = await store.allRecords()
        guard refreshID == id else { return }
        let status = await store.persistenceStatus()
        guard refreshID == id else { return }
        referenceDate = date
        records = HistoryPresentation.filteredRecords(snapshot, query: query)
        totalRecordCount = status.recordCount
        notice = status.notice.map(SpeakerCopy.History.pageNotice)
    }

    /// Which of a record's texts to copy.
    package enum CopiedText: Sendable {
        /// The text Speaker delivered or kept.
        case result
        /// The recognition result before refinement.
        case recognition
    }

    @discardableResult
    package func copy(
        _ record: VoiceInputHistoryRecord,
        _ part: CopiedText = .result
    ) async -> Bool {
        let text =
            switch part {
            case .result: HistoryPresentation.retainedText(for: record)
            case .recognition: HistoryPresentation.recognitionText(for: record)
            }
        guard activeOperation == nil, let text else { return false }
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
        let clock = clock
        feedbackTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled,
                self?.feedback?.id == feedback.id
            else { return }
            self?.feedback = nil
        }
    }

}

package struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    private let focusesSearch: Bool
    private let searchFocused: () -> Void

    package init(
        model: HistoryModel,
        focusesSearch: Bool = false,
        searchFocused: @escaping () -> Void = {}
    ) {
        self.model = model
        self.focusesSearch = focusesSearch
        self.searchFocused = searchFocused
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
                copyRecognition: { record in
                    Task { _ = await model.copy(record, .recognition) }
                },
                delete: { id in
                    Task { _ = await model.delete(id) }
                }
            ),
            focusesSearch: focusesSearch,
            searchFocused: searchFocused
        )
        .task { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .speakerHistoryDidChange)
        ) { _ in
            Task { await model.refresh() }
        }
    }
}
