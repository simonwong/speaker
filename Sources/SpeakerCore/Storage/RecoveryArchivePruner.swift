import Darwin
import Foundation

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
    ) {
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
    ) {
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
    ) {
        guard !prefix.isEmpty,
              metadata(at: directory)?.kind == S_IFDIR,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return }

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
        var retainedBytes = 0
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
            remove(candidate)
        }
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

    private static func remove(_ candidate: Candidate) {
        switch candidate.kind {
        case .regularFile:
            _ = try? OwnerOnlyFilePersistence.removeRegularFile(at: candidate.url)
        case .flatDirectory:
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: candidate.url,
                includingPropertiesForKeys: nil
            ) else { return }
            for child in children {
                guard (try? OwnerOnlyFilePersistence.removeRegularFile(at: child)) != nil
                else { return }
            }
            _ = try? OwnerOnlyFilePersistence.removeEmptyDirectory(at: candidate.url)
        }
    }
}
