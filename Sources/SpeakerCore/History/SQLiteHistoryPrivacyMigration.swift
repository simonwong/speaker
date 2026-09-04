import Foundation

/// Removes response text from history rows written by older builds.
///
/// Provider messages are not a stable diagnostic contract and may echo
/// credentials or user context, so only structured provider metadata is kept.
/// Removing the field from a payload is not enough: the old bytes stay in the
/// database file and its write-ahead log until the pass vacuums and checkpoints
/// them away, and the pass is only reported as done once a re-read of every row
/// finds nothing left to scrub.
enum SQLiteHistoryPrivacyMigration {
    /// What one completed pass had to drop.
    struct Outcome {
        /// Rows whose payload could not be read back as a Session Record and
        /// were deleted rather than left holding unreadable text.
        let corruptedRecordCount: Int
    }

    private static let currentVersion: Int32 = 1
    private static let metadataKey = "provider_message_scrub"

    /// Scrubs, sanitizes, and verifies in one pass.
    ///
    /// `checkpoint` is the store's own WAL convergence, so a checkpoint made
    /// here also settles whatever destructive work the store had pending.
    static func scrubUntrustedProviderMessages(
        on connection: SQLiteConnection,
        checkpoint: () throws -> Void
    ) throws -> Outcome {
        let plan = try scrubPlan(on: connection)
        let completedVersion = try scrubVersion(on: connection)
        let requiresPhysicalSanitization = plan.hasChanges
            || completedVersion < currentVersion

        if plan.hasChanges {
            try connection.beginImmediateTransaction()
            do {
                for rewrite in plan.rewrites {
                    try rewritePayload(
                        rewrite.payload,
                        sessionID: rewrite.sessionID,
                        on: connection
                    )
                }
                for sessionID in plan.deletions {
                    try deleteRow(sessionID: sessionID, on: connection)
                }
                try connection.commitTransaction()
            } catch {
                connection.rollbackTransaction()
                throw error
            }
        }

        if requiresPhysicalSanitization {
            try checkpoint()
            try connection.execute("VACUUM")
            try checkpoint()
            try markCompleted(on: connection)
            try checkpoint()
        }

        try verify(on: connection)
        return Outcome(corruptedRecordCount: plan.corruptedDeletionCount)
    }

    private struct Plan {
        struct Rewrite {
            let sessionID: String
            let payload: Data
        }

        var rewrites: [Rewrite] = []
        var deletions: [String] = []
        var corruptedDeletionCount = 0

        var hasChanges: Bool {
            !rewrites.isEmpty || !deletions.isEmpty
        }
    }

    private static func scrubPlan(on connection: SQLiteConnection) throws -> Plan {
        let statement = try connection.prepare(
            """
            SELECT session_id, payload, payload_schema
            FROM history_records
            """
        )
        defer { statement.finalize() }

        var plan = Plan()
        while try statement.step() {
            guard let sessionID = statement.text(at: 0) else {
                throw SQLiteHistoryError.encoding
            }
            guard statement.int32(at: 2) == SQLiteHistorySchema.version,
                  let payload = statement.blob(at: 1)
            else {
                plan.deletions.append(sessionID)
                plan.corruptedDeletionCount += 1
                continue
            }

            guard var object = try? JSONSerialization.jsonObject(
                with: payload
            ) as? [String: Any] else {
                plan.deletions.append(sessionID)
                plan.corruptedDeletionCount += 1
                continue
            }

            let containedUntrustedText =
                object.keys.contains("providerMessage")
                || object.keys.contains("refinementFailureMessage")
            object.removeValue(forKey: "providerMessage")
            object.removeValue(forKey: "refinementFailureMessage")

            guard let sanitizedPayload = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ), let stored = try? SQLiteHistorySchema.payloadDecoder.decode(
                HistoryRecordV1.self,
                from: sanitizedPayload
            ), let record = try? stored.domainRecord else {
                plan.deletions.append(sessionID)
                plan.corruptedDeletionCount += 1
                continue
            }

            guard SessionHistoryRecordPolicy.shouldRetain(record) else {
                plan.deletions.append(sessionID)
                continue
            }

            if containedUntrustedText {
                plan.rewrites.append(.init(
                    sessionID: sessionID,
                    payload: sanitizedPayload
                ))
            }
        }
        return plan
    }

    /// A pass that still finds work to do has not sanitized anything.
    private static func verify(on connection: SQLiteConnection) throws {
        let verification = try scrubPlan(on: connection)
        guard !verification.hasChanges else {
            throw SQLiteHistoryError.encoding
        }
    }

    private static func rewritePayload(
        _ payload: Data,
        sessionID: String,
        on connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            "UPDATE history_records SET payload = ? WHERE session_id = ?"
        )
        defer { statement.finalize() }
        try statement.bind(payload, at: 1)
        try statement.bind(sessionID, at: 2)
        try statement.stepDone()
    }

    private static func deleteRow(
        sessionID: String,
        on connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            "DELETE FROM history_records WHERE session_id = ?"
        )
        defer { statement.finalize() }
        try statement.bind(sessionID, at: 1)
        try statement.stepDone()
    }

    private static func scrubVersion(on connection: SQLiteConnection) throws -> Int32 {
        let statement = try connection.prepare(
            "SELECT value FROM history_metadata WHERE key = ?"
        )
        defer { statement.finalize() }
        try statement.bind(metadataKey, at: 1)
        guard try statement.step() else { return 0 }
        return statement.int32(at: 0)
    }

    private static func markCompleted(on connection: SQLiteConnection) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO history_metadata(key, value)
            VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """
        )
        defer { statement.finalize() }
        try statement.bind(metadataKey, at: 1)
        statement.bind(currentVersion, at: 2)
        try statement.stepDone()
    }
}
