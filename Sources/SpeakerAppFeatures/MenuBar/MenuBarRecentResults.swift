import Combine
import Foundation
import SpeakerCore

/// The menu bar's 「最近结果」 submenu: the newest Session Records that kept
/// text, read from the same store as History. Retention, deletion, and
/// secure-target redaction therefore apply here without a second copy.
@MainActor
package final class MenuBarRecentResultsModel: ObservableObject {
    package struct Item: Equatable, Identifiable, Sendable {
        package let id: VoiceInputSessionID
        package let title: String
    }

    package static let limit = 5
    /// Menu items are one line; longer text is cut with an ellipsis.
    package static let titleLength = 28

    @Published package private(set) var items: [Item] = []

    private let store: any LocalSessionHistoryStoring
    private let clipboard: any ClipboardWriting
    private let announce: (String) -> Void
    private let calendar: Calendar
    private let now: () -> Date
    private var refreshID = UUID()
    private var historyChanges: AnyCancellable?

    package init(
        store: any LocalSessionHistoryStoring,
        clipboard: any ClipboardWriting,
        announce: @escaping (String) -> Void,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.clipboard = clipboard
        self.announce = announce
        self.calendar = calendar
        self.now = now
        // The history store posts from its own executor; hop to the main
        // queue before touching this main-actor model.
        historyChanges = NotificationCenter.default
            .publisher(for: .speakerHistoryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    package func refresh() async {
        let id = UUID()
        refreshID = id
        let records = await store.recentRecordsWithText(limit: Self.limit)
        guard refreshID == id else { return }
        let today = calendar.startOfDay(for: now())
        items = records.compactMap { record in
            guard let text = HistoryPresentation.retainedText(for: record) else { return nil }
            return Item(
                id: record.sessionID,
                title: title(text: text, startedAt: record.startedAt, today: today)
            )
        }
    }

    /// Copies the record's complete text. The record is read again so a
    /// result deleted since the menu was built is never copied.
    @discardableResult
    package func copy(_ id: VoiceInputSessionID) async -> Bool {
        guard let record = await store.record(sessionID: id),
            let text = HistoryPresentation.retainedText(for: record)
        else {
            await refresh()
            return false
        }
        guard await clipboard.copy(text) else {
            announce("无法写入剪贴板，请重试。")
            return false
        }
        announce(SpeakerCopy.Clipboard.textCopied)
        return true
    }

    /// Today's results lead with their time, older ones with their date.
    private func title(text: String, startedAt: Date, today: Date) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let preview =
            line.count > Self.titleLength
            ? String(line.prefix(Self.titleLength)) + "…"
            : line
        let when: String
        if calendar.startOfDay(for: startedAt) == today {
            when = startedAt.formatted(
                Date.VerbatimFormatStyle(
                    format:
                        "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                    locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: calendar.timeZone,
                    calendar: calendar
                )
            )
        } else {
            let components = calendar.dateComponents([.month, .day], from: startedAt)
            when = "\(components.month ?? 0)月\(components.day ?? 0)日"
        }
        return "\(when)  \(preview)"
    }
}
