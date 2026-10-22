import Foundation

extension Notification.Name {
    public static let speakerHistoryDidChange = Notification.Name(
        "com.local.speaker.history-did-change"
    )
}

public protocol LocalSessionHistoryStoring: SessionHistoryRecording {
    func allRecords() async -> [VoiceInputHistoryRecord]
    func record(sessionID: VoiceInputSessionID) async -> VoiceInputHistoryRecord?
    @discardableResult func delete(sessionID: VoiceInputSessionID) async -> Bool
    @discardableResult func clear() async -> Bool
    func persistenceStatus() async -> LocalHistoryPersistenceStatus
    func clearPersistenceNotice() async
    func currentRetentionPolicy() async -> HistoryRetentionPolicy
    @discardableResult func applyRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        now: Date
    ) async -> Bool
    func usageStatistics() async -> VoiceInputUsageSummary
    func recentRecordsWithText(limit: Int) async -> [VoiceInputHistoryRecord]
}

extension LocalSessionHistoryStoring {
    public func latestRecord() async -> VoiceInputHistoryRecord? {
        await allRecords().first
    }

    /// Aggregates every stored session into all-time totals and per-day buckets.
    ///
    /// The default implementation folds `allRecords()`; stores backed by a
    /// database should override it to stream rows instead of loading the whole
    /// table into memory.
    public func usageStatistics() async -> VoiceInputUsageSummary {
        VoiceInputUsageStatistics.summarize(await allRecords())
    }

    /// The newest records that still hold retained text, newest first.
    ///
    /// The default implementation filters `allRecords()`; a database-backed
    /// store should stop reading once it has `limit` records.
    public func recentRecordsWithText(limit: Int) async -> [VoiceInputHistoryRecord] {
        Array(
            await allRecords()
                .filter(SessionHistoryRecordPolicy.hasRetainedContent)
                .prefix(max(0, limit))
        )
    }
}

public struct LocalHistoryPersistenceStatus: Equatable, Sendable {
    public let recordCount: Int
    public let notice: LocalHistoryPersistenceNotice?

    public init(recordCount: Int, notice: LocalHistoryPersistenceNotice?) {
        self.recordCount = recordCount
        self.notice = notice
    }
}

/// Why the local history store could not finish its privacy migration.
public enum LocalHistoryFailureReason: Equatable, Sendable {
    case databaseUnavailable
    /// A privacy-safe technical detail already free of user or provider text.
    case detail(String)
}

public enum LocalHistoryPersistenceNotice: Equatable, Sendable {
    case corruptedDataPreserved(backupURL: URL, reason: String)
    case corruptedRecordsSkipped(count: Int)
    case privacyMigrationFailed(reason: LocalHistoryFailureReason)
    case writeFailed(reason: String)
    /// Preserved corruption evidence could not be pruned back inside its
    /// budget, so the store's directory keeps growing until it is cleared.
    case recoveryArchivePruneFailed(reason: String)
}
