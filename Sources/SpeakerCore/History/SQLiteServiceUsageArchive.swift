import Foundation

/// Per-service usage counts of deleted Session Records, so the overview's
/// estimated cost never shrinks when history is deleted, cleared, or evicted.
///
/// Two tables hold counts keyed by provider and model identifiers: recording
/// time per Speech Recognition Provider model, and successful requests with
/// sent and received character counts per Refinement Provider model. Neither
/// holds text, session identifiers, or timestamps. A Custom Refinement
/// Provider's model is stored as an empty identifier. Full data erasure
/// removes the database file with them.
///
/// The tables are an additive migration of schema version 1: `create` runs at
/// every open with `IF NOT EXISTS`, so a database written before they existed
/// gains them empty, and `user_version` stays 1 because an older build that
/// opens the file reads every row it knows and ignores the new tables.
enum SQLiteServiceUsageArchive {
    static func create(on connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS recognition_usage_archive (
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                sessions INTEGER NOT NULL,
                milliseconds INTEGER NOT NULL,
                PRIMARY KEY(provider, model)
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS refinement_usage_archive (
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                requests INTEGER NOT NULL,
                input_characters INTEGER NOT NULL,
                output_characters INTEGER NOT NULL,
                PRIMARY KEY(provider, model)
            )
            """
        )
    }

    /// Adds the usage of rows about to be deleted. Callers run it inside the
    /// transaction that deletes the same rows.
    static func fold(
        _ services: VoiceInputServiceUsageAccumulator,
        on connection: SQLiteConnection
    ) throws {
        for (key, totals) in services.recognition {
            let upsert = try connection.prepare(
                """
                INSERT INTO recognition_usage_archive(provider, model, sessions, milliseconds)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(provider, model) DO UPDATE SET
                    sessions = sessions + excluded.sessions,
                    milliseconds = milliseconds + excluded.milliseconds
                """
            )
            defer { upsert.finalize() }
            try upsert.bind(key.provider, at: 1)
            try upsert.bind(key.modelID, at: 2)
            upsert.bind(Int64(totals.sessions), at: 3)
            upsert.bind(Int64(totals.milliseconds), at: 4)
            try upsert.stepDone()
        }
        for (key, totals) in services.refinement {
            let upsert = try connection.prepare(
                """
                INSERT INTO refinement_usage_archive(
                    provider, model, requests, input_characters, output_characters
                )
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(provider, model) DO UPDATE SET
                    requests = requests + excluded.requests,
                    input_characters = input_characters + excluded.input_characters,
                    output_characters = output_characters + excluded.output_characters
                """
            )
            defer { upsert.finalize() }
            try upsert.bind(key.provider.rawValue, at: 1)
            try upsert.bind(key.modelID, at: 2)
            upsert.bind(Int64(totals.requests), at: 3)
            upsert.bind(Int64(totals.inputCharacters), at: 4)
            upsert.bind(Int64(totals.outputCharacters), at: 5)
            try upsert.stepDone()
        }
    }

    /// Adds every archived count. A row naming a Refinement Provider this
    /// build does not know is skipped rather than guessed.
    static func read(
        into services: inout VoiceInputServiceUsageAccumulator,
        on connection: SQLiteConnection
    ) throws {
        let recognition = try connection.prepare(
            "SELECT provider, model, sessions, milliseconds FROM recognition_usage_archive"
        )
        defer { recognition.finalize() }
        while try recognition.step() {
            guard let provider = recognition.text(at: 0) else { continue }
            services.addArchivedRecognition(
                .init(provider: provider, modelID: recognition.text(at: 1) ?? ""),
                sessions: Int(recognition.int64(at: 2)),
                milliseconds: Int(recognition.int64(at: 3))
            )
        }
        let refinement = try connection.prepare(
            """
            SELECT provider, model, requests, input_characters, output_characters
            FROM refinement_usage_archive
            """
        )
        defer { refinement.finalize() }
        while try refinement.step() {
            guard
                let rawProvider = refinement.text(at: 0),
                let provider = RefinementProviderID(rawValue: rawProvider)
            else { continue }
            services.addArchivedRefinement(
                .init(provider: provider, modelID: refinement.text(at: 1) ?? ""),
                requests: Int(refinement.int64(at: 2)),
                inputCharacters: Int(refinement.int64(at: 3)),
                outputCharacters: Int(refinement.int64(at: 4))
            )
        }
    }
}
