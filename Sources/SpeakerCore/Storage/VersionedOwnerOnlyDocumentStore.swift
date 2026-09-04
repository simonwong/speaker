import Foundation

/// Why a stored document could not be decoded into the current schema.
public enum DocumentCorruption: Equatable, Sendable {
    case malformed(detail: String)
    case unsupportedVersion(Int)

    /// A content-free technical summary suitable for diagnostics.
    public var summary: String {
        switch self {
        case let .malformed(detail):
            detail
        case let .unsupportedVersion(version):
            "Unsupported schema version \(version)."
        }
    }
}

/// Why a document could not be loaded at all. The original file is untouched.
public enum DocumentLoadFailure: Equatable, Sendable {
    case protectionFailed(detail: String)
    case readFailed(detail: String)
    case preservationFailed(corruption: DocumentCorruption, detail: String)
}

/// The result of loading one versioned document.
public enum VersionedDocumentLoadOutcome<Document: Sendable>: Sendable {
    /// No file exists at the location; callers start from their defaults.
    case absent
    case loaded(Document, version: Int)
    /// The file could not be decoded and was moved aside to `backupURL`.
    /// The store location is free again and callers may start from defaults.
    case corruptedPreserved(backupURL: URL, corruption: DocumentCorruption)
    /// The file remains in place and must not be overwritten.
    case failed(DocumentLoadFailure)
}

/// The non-destructive counterpart of `VersionedDocumentLoadOutcome`: the
/// file is inspected but never moved.
public enum VersionedDocumentDecodeOutcome<Document: Sendable>: Sendable {
    case absent
    case decoded(Document, version: Int)
    case corrupted(DocumentCorruption)
    case failed(DocumentLoadFailure)
}

/// The JSON key that carries a document's schema version.
public enum DocumentVersionKey: String, Sendable {
    case schemaVersion
    case version
}

/// Which document versions a store understands and how each decodes into the
/// current domain value. Adding a version means adding one table row.
public struct VersionedDocumentSchema<Document: Sendable>: Sendable {
    public typealias Decode = @Sendable (Data) throws -> Document

    public let currentVersion: Int
    public let versionKey: DocumentVersionKey
    public let decoders: [Int: Decode]

    public init(
        currentVersion: Int,
        versionKey: DocumentVersionKey,
        decoders: [Int: Decode]
    ) {
        precondition(
            decoders[currentVersion] != nil,
            "the current document version must be decodable"
        )
        self.currentVersion = currentVersion
        self.versionKey = versionKey
        self.decoders = decoders
    }
}

/// One owner-only JSON document with a version header.
///
/// Loading protects the existing file, reads it through the bounded
/// no-follow persistence boundary, probes the version header, dispatches to
/// the schema's decoder for that version, and preserves an undecodable file
/// as a timestamped sibling before pruning older recovery archives. Writing
/// enforces the same byte bound. Each concrete store owns only its schema, its
/// migration table, and the domain-facing result type.
package struct VersionedOwnerOnlyDocumentStore<Document: Sendable>: Sendable {
    package let fileURL: URL
    package let schema: VersionedDocumentSchema<Document>
    package let maximumByteCount: Int
    /// The infix between the base file name and the timestamp of a preserved
    /// corrupt copy, for example `corrupt-` in `history.corrupt-<ms>-<uuid>.json`.
    package let backupInfix: String
    private let fileProtection: LocalFileProtection

    package init(
        fileURL: URL,
        schema: VersionedDocumentSchema<Document>,
        maximumByteCount: Int,
        backupInfix: String,
        fileProtection: LocalFileProtection = .ownerOnly
    ) {
        precondition(!backupInfix.isEmpty, "a backup infix is required")
        self.fileURL = fileURL
        self.schema = schema
        self.maximumByteCount = maximumByteCount
        self.backupInfix = backupInfix
        self.fileProtection = fileProtection
    }

    package var backupNamePrefix: String {
        "\(fileURL.deletingPathExtension().lastPathComponent).\(backupInfix)"
    }

    package var backupDirectoryURL: URL {
        fileURL.deletingLastPathComponent()
    }

    /// Loads the document, preserving a corrupt file as evidence so the
    /// location is usable again. Recovery archives are pruned first so a
    /// preserved copy never competes with unbounded older evidence.
    package func load() -> VersionedDocumentLoadOutcome<Document> {
        pruneBackups()
        switch decode() {
        case .absent:
            return .absent
        case let .decoded(document, version):
            return .loaded(document, version: version)
        case let .failed(failure):
            return .failed(failure)
        case let .corrupted(corruption):
            return preserveCorruptFile(corruption: corruption)
        }
    }

    /// Inspects the document without moving anything. Migrations that must
    /// leave a legacy source untouched on failure use this entry point.
    package func decode() -> VersionedDocumentDecodeOutcome<Document> {
        do {
            try fileProtection.protect(fileURL)
        } catch {
            return .failed(.protectionFailed(detail: Self.safeReason(for: error)))
        }
        let data: Data
        do {
            guard let storedData = try OwnerOnlyFilePersistence.read(
                from: fileURL,
                maximumByteCount: maximumByteCount
            ) else {
                return .absent
            }
            data = storedData
        } catch {
            return .failed(.readFailed(detail: Self.safeReason(for: error)))
        }

        let version: Int
        do {
            version = try Self.readVersion(from: data, key: schema.versionKey)
        } catch {
            return .corrupted(.malformed(detail: Self.safeReason(for: error)))
        }
        guard let decode = schema.decoders[version] else {
            return .corrupted(.unsupportedVersion(version))
        }
        do {
            return .decoded(try decode(data), version: version)
        } catch {
            return .corrupted(.malformed(detail: Self.safeReason(for: error)))
        }
    }

    /// Writes already-encoded document bytes through the owner-only boundary,
    /// refusing anything the store could not read back.
    package func write(_ data: Data) throws {
        guard data.count <= maximumByteCount else {
            throw OwnerOnlyFilePersistenceError.fileTooLarge(
                maximumByteCount: maximumByteCount
            )
        }
        try OwnerOnlyFilePersistence.write(data, to: fileURL)
    }

    package func pruneBackups(preserving preservedURL: URL? = nil) {
        RecoveryArchivePruner.pruneRegularFiles(
            in: backupDirectoryURL,
            prefix: backupNamePrefix,
            suffix: ".json",
            preserving: preservedURL
        )
    }

    /// Removes every preserved copy, for callers that erase the whole
    /// document on the user's behalf.
    package func removeBackups() throws {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates where
            candidate.lastPathComponent.hasPrefix(backupNamePrefix)
                && candidate.pathExtension == "json"
        {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    package static func safeReason(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    private func preserveCorruptFile(
        corruption: DocumentCorruption
    ) -> VersionedDocumentLoadOutcome<Document> {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = backupDirectoryURL.appendingPathComponent(
            "\(backupNamePrefix)\(timestamp)-\(UUID().uuidString).json",
            isDirectory: false
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
        } catch {
            return .failed(.preservationFailed(
                corruption: corruption,
                detail: Self.safeReason(for: error)
            ))
        }
        pruneBackups(preserving: backupURL)
        return .corruptedPreserved(backupURL: backupURL, corruption: corruption)
    }

    private struct VersionHeader: Decodable {
        let schemaVersion: Int?
        let version: Int?
    }

    private static func readVersion(
        from data: Data,
        key: DocumentVersionKey
    ) throws -> Int {
        let header = try JSONDecoder().decode(VersionHeader.self, from: data)
        let version = switch key {
        case .schemaVersion: header.schemaVersion
        case .version: header.version
        }
        guard let version else {
            throw DecodingError.keyNotFound(
                VersionCodingKey(stringValue: key.rawValue),
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Missing document version key \"\(key.rawValue)\"."
                )
            )
        }
        return version
    }

    private struct VersionCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
