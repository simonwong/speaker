import Foundation

/// Reads the JSON Session Record history that builds before SQLite wrote.
///
/// The legacy `history.json` is a migration source only (ADR-0006): startup
/// reads it once, imports its records into `SQLiteSessionHistory`, and removes
/// it. Nothing writes the document again, so the reader has no save, delete,
/// clear, or retention path. Reading still crosses the owner-only boundary,
/// and an undecodable document is moved aside as evidence rather than read.
public struct LegacyHistoryReader: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The document's records, newest first. A missing document has none.
        case records([VoiceInputHistoryRecord])
        /// The document could not be decoded and was preserved at `backupURL`.
        case corruptedPreserved(backupURL: URL)
        /// Owner-only protection failed; the document is untouched.
        case protectionFailed
        /// The document could not be read, or could not be preserved after it
        /// failed to decode; it is untouched.
        case unreadable
    }

    public static let schemaVersion = 1
    private static let maximumDocumentByteCount = 64 * 1_024 * 1_024

    private let document: VersionedOwnerOnlyDocumentStore<[VoiceInputHistoryRecord]>

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, fileProtection: .ownerOnly)
    }

    package init(fileURL: URL, fileProtection: LocalFileProtection) {
        document = VersionedOwnerOnlyDocumentStore(
            fileURL: fileURL,
            schema: Self.schema,
            maximumByteCount: Self.maximumDocumentByteCount,
            backupInfix: "corrupt-",
            fileProtection: fileProtection
        )
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = SpeakerDataDirectory.name
    ) -> URL {
        let baseDirectory =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser

        return
            baseDirectory
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    /// Loads the document once. Records pass the same retention rule the old
    /// store applied on load: everything retained, newest first, capped at
    /// the Session Record limit. Older `history.corrupt-…json` archives are
    /// pruned on the way; one that refuses to go says nothing about these
    /// records, and the user's next history clear removes it.
    public func read() -> Outcome {
        switch document.load().outcome {
        case .absent:
            .records([])
        case .loaded(let records, _):
            .records(
                SessionHistoryRecordPolicy.retained(
                    records,
                    policy: .forever,
                    maximumCount: SQLiteSessionHistory.defaultMaximumRecordCount,
                    now: Date()
                ))
        case .corruptedPreserved(let backupURL, _):
            .corruptedPreserved(backupURL: backupURL)
        case .failed(.protectionFailed):
            .protectionFailed
        case .failed(.readFailed), .failed(.preservationFailed):
            .unreadable
        }
    }

    /// Removes the document after its records were imported. It goes through
    /// the owner-only boundary, so a path that is no longer a regular file
    /// owned by the user is refused instead of followed.
    public func removeDocument() throws {
        try OwnerOnlyFilePersistence.removeRegularFile(at: document.fileURL)
    }

    private static let schema = VersionedDocumentSchema<[VoiceInputHistoryRecord]>(
        currentVersion: schemaVersion,
        versionKey: .schemaVersion,
        decoders: [
            1: { data in
                try SessionRecordPayloadCodec.decoder
                    .decode(LegacyHistoryDocumentV1.self, from: data)
                    .records.map { try $0.domainRecord }
            }
        ]
    )
}

private struct LegacyHistoryDocumentV1: Decodable {
    let schemaVersion: Int
    let records: [SessionRecordPayloadV1]
}
