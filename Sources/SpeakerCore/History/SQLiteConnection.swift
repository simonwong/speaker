import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

/// Every way the local history database can refuse an operation.
///
/// The associated message is whatever SQLite reported, never user text and
/// never a path, so a reason can be shown or copied without leaking history.
enum SQLiteHistoryError: Error {
    case openFailed
    case sqlite(code: Int32, message: String)
    case encoding
    case integrityCheckFailed(String)
    case unsupportedSchema(Int32)
}

extension SQLiteHistoryError: PrivacySafeDescribing {
    var privacySafeDescription: String {
        switch self {
        case .sqlite(_, let message):
            message
        case .openFailed:
            "Unable to open the local history database."
        case .encoding:
            "A local history record could not be decoded."
        case .integrityCheckFailed(let message):
            "The local history database failed its integrity check: \(message)"
        case .unsupportedSchema(let version):
            "The local history database uses unsupported schema version \(version)."
        }
    }
}

/// One open handle on the local history database.
///
/// This is the only place SQLite's C API is called: opening under the
/// owner-only persistence boundary, the durability and privacy pragmas,
/// statement preparation, transactions, WAL truncation, and file protection.
/// Callers work with `SQLiteStatement` values and `SQLiteHistoryError`, so no
/// caller has to know a status code or an `OpaquePointer`.
final class SQLiteConnection: @unchecked Sendable {
    private let fileURL: URL
    private var handle: OpaquePointer?

    /// Whether the handle is still usable. A failed `close()` leaves it open,
    /// because a busy database has not been detached from its files.
    var isOpen: Bool { handle != nil }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.handle = nil
        try OwnerOnlyFilePersistence.protectExistingFile(at: fileURL)
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &connection, flags, nil) == SQLITE_OK,
            let connection
        else {
            if let connection { sqlite3_close(connection) }
            throw SQLiteHistoryError.openFailed
        }
        handle = connection
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA busy_timeout=3000")
        } catch {
            closeIgnoringFailure()
            throw error
        }
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// Detaches the handle from its files. A busy close is a hard failure: the
    /// caller asked for a verifiable detach, not a best-effort one.
    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: status,
                message: Self.errorMessage(handle)
            )
        }
        self.handle = nil
    }

    /// Abandons a handle whose setup could not finish. Nothing has been
    /// promised to a caller yet, so a close failure has nowhere to be reported.
    func closeIgnoringFailure() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        let handle = try requireHandle()
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw lastError()
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        let handle = try requireHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw lastError()
        }
        return SQLiteStatement(statement: statement, connection: self)
    }

    /// Rows changed by the most recent statement on this handle.
    var changeCount: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    func beginImmediateTransaction() throws {
        try execute("BEGIN IMMEDIATE")
    }

    func commitTransaction() throws {
        try execute("COMMIT")
    }

    /// A rollback runs while another failure is already being propagated, so it
    /// can only replace the reason the caller is about to report.
    func rollbackTransaction() {
        try? execute("ROLLBACK")
    }

    func integerValue(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        guard try statement.step() else { throw lastError() }
        return statement.int32(at: 0)
    }

    func textValue(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        guard try statement.step() else { throw lastError() }
        return statement.text(at: 0)
    }

    func table(_ tableName: String, containsColumn columnName: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(tableName))")
        defer { statement.finalize() }
        while try statement.step() {
            if statement.text(at: 1) == columnName { return true }
        }
        return false
    }

    /// Truncates the write-ahead log and proves the sidecar is empty afterwards.
    ///
    /// A checkpoint that reports success while another reader keeps the log
    /// alive would leave deleted history readable on disk, so the file size is
    /// the verdict, not the return code.
    func truncateCheckpoint() throws {
        let handle = try requireHandle()
        var logFrameCount: Int32 = -1
        var checkpointedFrameCount: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(
            handle,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrameCount,
            &checkpointedFrameCount
        )
        guard result == SQLITE_OK else {
            throw SQLiteHistoryError.sqlite(
                code: result,
                message: Self.errorMessage(handle)
            )
        }
        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: walURL.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value != 0
        {
            throw SQLiteHistoryError.sqlite(
                code: SQLITE_BUSY,
                message: "The local history write-ahead log is still in use."
            )
        }
    }

    func protectDatabaseFiles() throws {
        try Self.protectDatabaseFiles(at: fileURL)
    }

    static func protectDatabaseFiles(at fileURL: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try OwnerOnlyFilePersistence.protectExistingFile(
                at: URL(fileURLWithPath: fileURL.path + suffix)
            )
        }
    }

    /// The failure SQLite is currently reporting on this handle.
    func lastError() -> SQLiteHistoryError {
        guard let handle else { return .openFailed }
        return .sqlite(
            code: sqlite3_extended_errcode(handle),
            message: Self.errorMessage(handle)
        )
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteHistoryError.openFailed }
        return handle
    }

    private static func errorMessage(_ connection: OpaquePointer) -> String {
        sqlite3_errmsg(connection).map(String.init(cString:)) ?? "unknown sqlite error"
    }
}

/// One prepared statement, finalized by its owner.
///
/// Binding and column reading are the only ways a caller touches SQLite
/// values; every failure arrives as the connection's current error.
final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: SQLiteConnection
    private var isFinalized = false

    fileprivate init(statement: OpaquePointer, connection: SQLiteConnection) {
        self.statement = statement
        self.connection = connection
    }

    deinit {
        finalize()
    }

    func finalize() {
        guard !isFinalized else { return }
        isFinalized = true
        sqlite3_finalize(statement)
    }

    func bind(_ value: String, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK
        else {
            throw connection.lastError()
        }
    }

    func bind(_ value: Data, at index: Int32) throws {
        let status = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                sqliteTransient
            )
        }
        guard status == SQLITE_OK else {
            throw connection.lastError()
        }
    }

    func bind(_ value: Double, at index: Int32) {
        sqlite3_bind_double(statement, index, value)
    }

    func bind(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(statement, index, value)
    }

    func bind(_ value: Int32, at index: Int32) {
        sqlite3_bind_int(statement, index, value)
    }

    /// Advances the statement. `true` means a row is available; `false` means
    /// the statement finished. Anything else is the connection's error.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw connection.lastError()
        }
    }

    /// Runs a statement that must not produce rows.
    func stepDone() throws {
        guard try step() == false else { throw connection.lastError() }
    }

    func int32(at index: Int32) -> Int32 {
        sqlite3_column_int(statement, index)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func text(at index: Int32) -> String? {
        sqlite3_column_text(statement, index).map(String.init(cString:))
    }

    func blob(at index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
