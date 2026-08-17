import Combine
import Foundation
import SpeakerCore

/// Owns the single user-facing history-retention setting without coupling the
/// Settings feature to the AppKit-backed history window coordinator.
@MainActor
package final class HistoryRetentionSettingsModel: ObservableObject {
    @Published package private(set) var retentionPolicy: HistoryRetentionPolicy = .forever
    @Published package private(set) var isUpdating = false
    @Published package private(set) var notice: String?

    private let store: any LocalSessionHistoryStoring
    private let settingsStore: VersionedLocalAppSettingsStore

    package init(
        store: any LocalSessionHistoryStoring,
        settingsStore: VersionedLocalAppSettingsStore
    ) {
        self.store = store
        self.settingsStore = settingsStore
    }

    package func refresh() async {
        retentionPolicy = await store.currentRetentionPolicy()
    }

    package func setRetentionPolicy(
        _ policy: HistoryRetentionPolicy
    ) async {
        guard policy != retentionPolicy, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await settingsStore.updateHistoryRetention(policy)
            retentionPolicy = policy
            guard await store.applyRetentionPolicy(policy, now: Date()) else {
                notice = "保留设置已保存，但旧记录尚未完成清理；Speaker 会在后续写入或下次启动时重试。"
                return
            }
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }
}
