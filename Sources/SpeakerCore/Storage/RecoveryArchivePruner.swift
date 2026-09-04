import Darwin
import Foundation

/// What one pruning pass did, including the archives it could not remove.
///
/// Pruning is best effort — a stuck archive must never stop a document from
/// loading — but "best effort" is not "unobservable": the caller is told which
/// archives survived and why, so a directory that keeps filling up can be
/// reported instead of silently growing.
package struct RecoveryArchivePruneSummary: Equatable, Sendable {
    package let retainedCount: Int
    package let removedCount: Int
    /// One privacy-safe reason per archive the pass meant to remove and could
    /// not. Each entry names the archive file, which is Speaker-generated and
    /// carries no user content.
    package let failures: [String]

    package init(
        retainedCount: Int = 0,
        removedCount: Int = 0,
        failures: [String] = []
    ) {
        self.retainedCount = retainedCount
        self.removedCount = removedCount
        self.failures = failures
    }

    /// Every archive the pass meant to remove is gone.
    package var isComplete: Bool { failures.isEmpty }
}

/// Bounds privacy-sensitive corruption evidence without deleting the newest
/// usable recovery artifact. Candidate discovery uses `lstat`; deletion goes
/// back through the descriptor-relative no-follow persistence boundary.
package enum RecoveryArchivePruner {
    package static let maximumArchiveCount = 3
    package static let maximumTotalByteCount = 128 * 1_024 * 1_024
    package static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private enum Kind {
        case regularFile
        case flatDirectory
    }

    private struct Candidate {
        let url: URL
        let byteCount: Int
        let modificationDate: Date
        let kind: Kind
    }

    package static func pruneRegularFiles(
        in directory: URL,
        prefix: String,
        suffix: String,
        preserving preservedURL: URL? = nil,
        now: Date = Date()
    ) -> RecoveryArchivePruneSummary {
        prune(
            in: directory,
            prefix: prefix,
            suffix: suffix,
            kind: .regularFile,
            preserving: preservedURL,
            now: now
        )
    }

    package static func pruneFlatDirectories(
        in directory: URL,
        prefix: String,
        preserving preservedURL: URL? = nil,
        now: Date = Date()
    ) -> RecoveryArchivePruneSummary {
        prune(
            in: directory,
            prefix: prefix,
            suffix: "",
            kind: .flatDirectory,
            preserving: preservedURL,
            now: now
        )
    }

    private static func prune(
        in directory: URL,
        prefix: String,
        suffix: String,
        kind: Kind,
        preserving preservedURL: URL?,
        now: Date
    ) -> RecoveryArchivePruneSummary {
        guard !prefix.isEmpty, metadata(at: directory)?.kind == S_IFDIR else {
            return RecoveryArchivePruneSummary()
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return RecoveryArchivePruneSummary(
                failures: [failure(named: directory, error: error)]
            )
        }

        let preservedPath = preservedURL?.standardizedFileURL.path
        let candidates = entries.compactMap { url -> Candidate? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix),
                  suffix.isEmpty || name.hasSuffix(suffix)
            else { return nil }
            return candidate(at: url, kind: kind)
        }.sorted {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        var retainedCount = 0
        var removedCount = 0
        var retainedBytes = 0
        var failures: [String] = []
        for candidate in candidates {
            let isPreserved = candidate.url.standardizedFileURL.path == preservedPath
            let isNewestUsable = retainedCount == 0
            let age = max(0, now.timeIntervalSince(candidate.modificationDate))
            let fitsBytes = candidate.byteCount <= maximumTotalByteCount - min(
                retainedBytes,
                maximumTotalByteCount
            )
            let fitsBudget = retainedCount < maximumArchiveCount
                && fitsBytes
                && age <= maximumAge
            if isPreserved || isNewestUsable || fitsBudget {
                retainedCount += 1
                retainedBytes = min(
                    maximumTotalByteCount,
                    retainedBytes + candidate.byteCount
                )
                continue
            }
            if let failure = remove(candidate) {
                failures.append(failure)
                retainedCount += 1
            } else {
                removedCount += 1
            }
        }
        return RecoveryArchivePruneSummary(
            retainedCount: retainedCount,
            removedCount: removedCount,
            failures: failures
        )
    }

    private static func candidate(at url: URL, kind: Kind) -> Candidate? {
        guard let rootMetadata = metadata(at: url) else { return nil }
        switch kind {
        case .regularFile:
            guard rootMetadata.kind == S_IFREG else { return nil }
            return Candidate(
                url: url,
                byteCount: rootMetadata.byteCount,
                modificationDate: rootMetadata.modificationDate,
                kind: kind
            )
        case .flatDirectory:
            guard rootMetadata.kind == S_IFDIR,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: url,
                      includingPropertiesForKeys: nil
                  )
            else { return nil }
            var total = 0
            for child in children {
                guard let childMetadata = metadata(at: child),
                      childMetadata.kind == S_IFREG
                else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(
                    childMetadata.byteCount
                )
                total = overflow ? Int.max : sum
            }
            return Candidate(
                url: url,
                byteCount: total,
                modificationDate: rootMetadata.modificationDate,
                kind: kind
            )
        }
    }

    private static func metadata(
        at url: URL
    ) -> (kind: mode_t, byteCount: Int, modificationDate: Date)? {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              status.st_size <= off_t(Int.max)
        else { return nil }
        return (
            status.st_mode & S_IFMT,
            Int(status.st_size),
            Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
        )
    }

    /// Removes one archive, returning a privacy-safe reason when it survived.
    /// A flat directory stops at its first unremovable child so a partially
    /// deleted archive is never left looking complete.
    private static func remove(_ candidate: Candidate) -> String? {
        do {
            switch candidate.kind {
            case .regularFile:
                _ = try OwnerOnlyFilePersistence.removeRegularFile(at: candidate.url)
            case .flatDirectory:
                let children = try FileManager.default.contentsOfDirectory(
                    at: candidate.url,
                    includingPropertiesForKeys: nil
                )
                for child in children {
                    _ = try OwnerOnlyFilePersistence.removeRegularFile(at: child)
                }
                _ = try OwnerOnlyFilePersistence.removeEmptyDirectory(at: candidate.url)
            }
            return nil
        } catch {
            return failure(named: candidate.url, error: error)
        }
    }

    /// Names the Speaker-generated archive and appends the one privacy-safe
    /// reason Speaker is allowed to record for a local failure.
    private static func failure(named url: URL, error: Error) -> String {
        "\(url.lastPathComponent): \(PrivacySafeText.reason(for: error))"
    }
}
