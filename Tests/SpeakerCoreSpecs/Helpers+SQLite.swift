import Foundation
import SQLite3
import SpeakerCore
import SpeakerSpecSupport

func injectLegacyProviderMessages(into fileURL: URL) throws {
    var database: OpaquePointer?
    guard
        sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database
    else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history for injection")
    }
    defer { sqlite3_close(database) }
    let sql = """
        UPDATE history_records
        SET payload = CAST(json_set(
            CAST(payload AS TEXT),
            '$.providerMessage',
            'future-api-key-secret',
            '$.refinementFailureMessage',
            'private-refinement-context'
        ) AS BLOB)
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw SpecFailure(message: "could not inject legacy provider messages")
    }
}

func injectMalformedProviderMessageRow(
    into fileURL: URL,
    secret: String
) throws {
    var database: OpaquePointer?
    guard
        sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database
    else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history for malformed injection")
    }
    defer { sqlite3_close(database) }
    let payload = try JSONSerialization.data(
        withJSONObject: ["providerMessage": secret],
        options: [.sortedKeys]
    )
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            database,
            """
            INSERT INTO history_records(session_id, started_at, payload, payload_schema)
            VALUES('00000000-0000-0000-0000-000000000002', 1, ?, 1)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
    else {
        throw SpecFailure(message: "could not prepare malformed history injection")
    }
    defer { sqlite3_finalize(statement) }
    let bindStatus = payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
            statement,
            1,
            bytes.baseAddress,
            Int32(bytes.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }
    guard bindStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
        throw SpecFailure(message: "could not inject malformed history row")
    }
}

func injectProviderMessage(
    _ secret: String,
    into fileURL: URL
) throws {
    var database: OpaquePointer?
    guard
        sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database
    else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history for provider injection")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            database,
            """
            UPDATE history_records
            SET payload = CAST(json_set(
                CAST(payload AS TEXT),
                '$.providerMessage',
                ?
            ) AS BLOB)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
    else {
        throw SpecFailure(message: "could not prepare provider message injection")
    }
    defer { sqlite3_finalize(statement) }
    guard
        sqlite3_bind_text(
            statement,
            1,
            secret,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        ) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE
    else {
        throw SpecFailure(message: "could not inject provider message")
    }
}

func sqliteFilesContain(_ marker: Data, at fileURL: URL) -> Bool {
    for suffix in ["", "-wal", "-journal"] {
        let candidate = URL(fileURLWithPath: fileURL.path + suffix)
        guard let data = try? Data(contentsOf: candidate) else { continue }
        if data.range(of: marker) != nil {
            return true
        }
    }
    return false
}

func readHistoryPayload(from fileURL: URL) throws -> String {
    var database: OpaquePointer?
    guard
        sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database
    else {
        if let database { sqlite3_close(database) }
        throw SpecFailure(message: "could not open SQLite history payload")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            database,
            "SELECT payload FROM history_records LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
    else {
        throw SpecFailure(message: "could not prepare history payload read")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
        let bytes = sqlite3_column_blob(statement, 0)
    else {
        throw SpecFailure(message: "history payload was missing")
    }
    let count = Int(sqlite3_column_bytes(statement, 0))
    return String(decoding: Data(bytes: bytes, count: count), as: UTF8.self)
}
