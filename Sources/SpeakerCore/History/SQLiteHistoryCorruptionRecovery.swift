import Foundation
import SQLite3

extension SQLiteHistoryError {
    /// Whether the database file itself is unusable and can be moved aside.
    ///
    /// Only damage to the file qualifies. An unsupported schema is a newer
    /// Speaker's data and an open failure may be a permission or path problem;
    /// neither may be preserved and replaced behind the user's back.
    var isRecoverableCorruption: Bool {
        switch self {
        case .sqlite(let code, _):
            code == SQLITE_CORRUPT || code == SQLITE_NOTADB
        case .integrityCheckFailed:
            true
        case .openFailed, .encoding, .unsupportedSchema:
            false
        }
    }
}

/// Keeps a damaged history database as evidence instead of deleting it, and
/// bounds how much of that evidence accumulates.
///
/// A corrupt file is the user's only remaining copy of their history, so it is
/// moved into a timestamped owner-only directory next to the database before a
/// fresh one is created. A half-moved recovery set is restored rather than
/// left behind.
enum SQLiteHistoryCorruptionRecovery {
    struct PreservedDatabase {
        let backupURL: URL
        let pruning: RecoveryArchivePruneSummary
    }

    static func preserveCorruptedDatabase(at fileURL: URL) throws -> PreservedDatabase {
        let fileManager = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let backupDirectory = parent.appendingPathComponent(
            "history.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            var preservedAnyFile = false
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let source = URL(fileURLWithPath: fileURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = backupDirectory.appendingPathComponent(
                    fileURL.lastPathComponent + suffix,
                    isDirectory: false
                )
                try fileManager.moveItem(at: source, to: destination)
                try OwnerOnlyFilePersistence.protectExistingFile(at: destination)
                preservedAnyFile = true
            }
            guard preservedAnyFile else {
                throw SQLiteHistoryError.openFailed
            }
            return PreservedDatabase(
                backupURL: backupDirectory,
                pruning: pruneRecoveryArtifacts(
                    for: fileURL,
                    preserving: backupDirectory
                )
            )
        } catch {
            // Do not leave a half-moved recovery set. Restore anything that was
            // already moved before surfacing the failure. If even one restore
            // cannot complete, keep the recovery directory: deleting it here
            // could destroy the only remaining copy of a user's history.
            var restoredEveryCandidate = true
            if let candidates = try? fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: nil
            ) {
                for candidate in candidates {
                    let destination = parent.appendingPathComponent(candidate.lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        do {
                            try fileManager.moveItem(at: candidate, to: destination)
                        } catch {
                            restoredEveryCandidate = false
                        }
                    } else {
                        restoredEveryCandidate = false
                    }
                }
            } else {
                restoredEveryCandidate = false
            }
            if restoredEveryCandidate {
                try? fileManager.removeItem(at: backupDirectory)
            }
            throw error
        }
    }

    static func pruneRecoveryArtifacts(
        for fileURL: URL,
        preserving preservedURL: URL? = nil
    ) -> RecoveryArchivePruneSummary {
        RecoveryArchivePruner.pruneFlatDirectories(
            in: fileURL.deletingLastPathComponent(),
            prefix: "history.corrupt-",
            preserving: preservedURL
        )
    }

    /// Removes the legacy JSON history and every preserved recovery set once
    /// the user has cleared their history: nothing they asked to erase may
    /// survive in an archive.
    static func removeLegacyArtifacts(around fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            let name = candidate.lastPathComponent
            if name == "history.json"
                || name.hasPrefix("history.corrupt-")
                || name.hasPrefix("history.migrated-")
            {
                try FileManager.default.removeItem(at: candidate)
            }
        }
    }
}
