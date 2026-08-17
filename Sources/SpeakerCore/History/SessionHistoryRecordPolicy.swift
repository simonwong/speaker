import Foundation

/// Shared semantic policy for every history representation. The legacy JSON
/// importer and production SQLite store must search, sort and retain exactly
/// the same fields or migrations can silently change user-visible behavior.
package enum SessionHistoryRecordPolicy {
    package static func retainedText(
        _ record: VoiceInputHistoryRecord
    ) -> String? {
        [record.finalText, record.transcription]
            .compactMap { $0 }
            .first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    package static func hasRetainedContent(
        _ record: VoiceInputHistoryRecord
    ) -> Bool {
        retainedText(record) != nil
    }

    package static func shouldRetain(
        _ record: VoiceInputHistoryRecord
    ) -> Bool {
        if hasRetainedContent(record) {
            return true
        }
        if case .failed(_, .recordingLimitReached) = record.outcome {
            return true
        }
        return false
    }

    /// Search covers the retained body plus content-free delivery evidence.
    /// Raw target identity and superseded transcription stay excluded.
    package static func searchableValues(
        _ record: VoiceInputHistoryRecord
    ) -> [String] {
        [
            retainedText(record),
            record.deliveryDiagnosticCode,
        ].compactMap { $0 }
    }

    package static func sort(
        _ records: [VoiceInputHistoryRecord]
    ) -> [VoiceInputHistoryRecord] {
        records.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.sessionID.rawValue.uuidString
                    > $1.sessionID.rawValue.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
    }

    package static func retained(
        _ records: [VoiceInputHistoryRecord],
        policy: HistoryRetentionPolicy,
        maximumCount: Int,
        now: Date
    ) -> [VoiceInputHistoryRecord] {
        let cutoff = policy.maximumAgeDays.flatMap {
            Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -$0,
                to: now
            )
        }
        let retainedRecords = records.filter(shouldRetain)
        let ageFiltered = cutoff.map { cutoff in
            retainedRecords.filter { $0.startedAt >= cutoff }
        } ?? retainedRecords
        return Array(sort(ageFiltered).prefix(max(1, maximumCount)))
    }
}
