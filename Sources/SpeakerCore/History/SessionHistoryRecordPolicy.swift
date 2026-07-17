import Foundation

/// Shared semantic policy for every history representation. The legacy JSON
/// importer and production SQLite store must search, sort and retain exactly
/// the same fields or migrations can silently change user-visible behavior.
package enum SessionHistoryRecordPolicy {
    package static func searchableValues(
        _ record: VoiceInputHistoryRecord
    ) -> [String] {
        [
            record.transcription,
            record.finalText,
            record.applicationName,
            record.providerErrorCode,
            record.providerOperation,
            record.providerStatusCode,
            record.providerRequestID,
            record.transcriptionProvider,
            record.deliveryDiagnosticCode,
            record.deepSeekText,
            record.deepSeekRequestID,
            record.refinementModeName,
            record.refinementPrompt,
            record.refinementFailureCode,
            record.refinementFailureStatusCode,
            record.cancelledAtStage,
            record.dictionarySnapshotEntries
                .flatMap { [$0.canonicalTerm] + $0.aliases }
                .joined(separator: " "),
            record.dictionaryRequestContext?.hotwords.joined(separator: " "),
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
        let ageFiltered = cutoff.map { cutoff in
            records.filter { $0.startedAt >= cutoff }
        } ?? records
        return Array(sort(ageFiltered).prefix(max(1, maximumCount)))
    }
}
