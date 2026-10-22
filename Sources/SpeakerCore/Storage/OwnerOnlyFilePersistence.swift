import Darwin
import Foundation

package struct LocalFileProtection: Sendable {
    private let operation: @Sendable (URL) throws -> Void

    package init(
        _ operation: @escaping @Sendable (URL) throws -> Void
    ) {
        self.operation = operation
    }

    package static let ownerOnly = LocalFileProtection {
        try OwnerOnlyFilePersistence.protectExistingFile(at: $0)
    }

    package func protect(_ fileURL: URL) throws {
        try operation(fileURL)
    }
}

package enum OwnerOnlyFilePersistenceError: Error {
    case invalidFileURL
    case missingDirectory
    case nonRegularFile
    case unexpectedOwner
    case fileTooLarge(maximumByteCount: Int)
    /// A directory was replaced between inspecting and opening it.
    case changedDuringRemoval
}

/// Centralizes the privacy and crash-safety contract for Speaker's local data.
///
/// File descriptors, rather than a second path lookup, are the security
/// boundary. The containing directory and destination file are opened with
/// `O_NOFOLLOW`, file type/owner are checked with `fstat`, reads are bounded,
/// and writes use an owner-only sibling followed by an atomic `renameat`.
package enum OwnerOnlyFilePersistence {
    package static func protectExistingFile(at fileURL: URL) throws {
        try withDirectoryDescriptor(for: fileURL, createIfMissing: true) { directoryFD, name in
            guard
                let fileFD = try openExistingFile(
                    in: directoryFD,
                    name: name,
                    pathForError: fileURL.path
                )
            else {
                return
            }
            defer { Darwin.close(fileFD) }
            try validateRegularOwnerOnlyFile(
                fileFD,
                pathForError: fileURL.path
            )
        }
    }

    package static func read(
        from fileURL: URL,
        maximumByteCount: Int
    ) throws -> Data? {
        guard maximumByteCount >= 0 else {
            throw OwnerOnlyFilePersistenceError.fileTooLarge(
                maximumByteCount: maximumByteCount
            )
        }
        return try withDirectoryDescriptor(
            for: fileURL,
            createIfMissing: true
        ) { directoryFD, name in
            guard
                let fileFD = try openExistingFile(
                    in: directoryFD,
                    name: name,
                    pathForError: fileURL.path
                )
            else {
                return nil
            }
            defer { Darwin.close(fileFD) }

            let initialStatus = try validateRegularOwnerOnlyFile(
                fileFD,
                pathForError: fileURL.path
            )
            guard initialStatus.st_size >= 0,
                initialStatus.st_size <= off_t(maximumByteCount)
            else {
                throw OwnerOnlyFilePersistenceError.fileTooLarge(
                    maximumByteCount: maximumByteCount
                )
            }

            var data = Data()
            data.reserveCapacity(Int(initialStatus.st_size))
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(fileFD, bytes.baseAddress, bytes.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: fileURL.path)
                }
                if count == 0 { break }
                guard data.count <= maximumByteCount - count else {
                    throw OwnerOnlyFilePersistenceError.fileTooLarge(
                        maximumByteCount: maximumByteCount
                    )
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
    }

    package static func write(_ data: Data, to fileURL: URL) throws {
        try withDirectoryDescriptor(for: fileURL, createIfMissing: true) { directoryFD, name in
            try validateExistingDestination(
                in: directoryFD,
                name: name,
                pathForError: fileURL.path
            )

            let temporaryName = ".\(name).\(UUID().uuidString).tmp"
            let temporaryFD = temporaryName.withCString { pointer in
                Darwin.openat(
                    directoryFD,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard temporaryFD >= 0 else {
                throw posixError(path: fileURL.path)
            }

            var shouldRemoveTemporaryFile = true
            defer {
                Darwin.close(temporaryFD)
                if shouldRemoveTemporaryFile {
                    temporaryName.withCString { pointer in
                        _ = Darwin.unlinkat(directoryFD, pointer, 0)
                    }
                }
            }

            guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
                throw posixError(path: fileURL.path)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        temporaryFD,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw posixError(path: fileURL.path)
                    }
                    guard count > 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    offset += count
                }
            }
            guard Darwin.fsync(temporaryFD) == 0 else {
                throw posixError(path: fileURL.path)
            }

            let renameResult = temporaryName.withCString { temporaryPointer in
                name.withCString { destinationPointer in
                    Darwin.renameat(
                        directoryFD,
                        temporaryPointer,
                        directoryFD,
                        destinationPointer
                    )
                }
            }
            guard renameResult == 0 else {
                throw posixError(path: fileURL.path)
            }
            shouldRemoveTemporaryFile = false
            guard Darwin.fsync(directoryFD) == 0 else {
                throw posixError(path: fileURL.path)
            }
        }
    }

    package static func regularFileExists(at fileURL: URL) throws -> Bool {
        do {
            return try withDirectoryDescriptor(
                for: fileURL,
                createIfMissing: false
            ) { directoryFD, name in
                guard
                    let fileFD = try openExistingFile(
                        in: directoryFD,
                        name: name,
                        pathForError: fileURL.path
                    )
                else {
                    return false
                }
                defer { Darwin.close(fileFD) }
                try validateRegularOwnerOnlyFile(
                    fileFD,
                    pathForError: fileURL.path
                )
                return true
            }
        } catch OwnerOnlyFilePersistenceError.missingDirectory {
            return false
        }
    }

    @discardableResult
    package static func removeRegularFile(at fileURL: URL) throws -> Bool {
        do {
            return try withDirectoryDescriptor(
                for: fileURL,
                createIfMissing: false
            ) { directoryFD, name in
                guard
                    let fileFD = try openExistingFile(
                        in: directoryFD,
                        name: name,
                        pathForError: fileURL.path
                    )
                else {
                    return false
                }
                defer { Darwin.close(fileFD) }
                try validateRegularOwnerOnlyFile(
                    fileFD,
                    pathForError: fileURL.path
                )
                let result = name.withCString { pointer in
                    Darwin.unlinkat(directoryFD, pointer, 0)
                }
                if result != 0, errno != ENOENT {
                    throw posixError(path: fileURL.path)
                }
                guard Darwin.fsync(directoryFD) == 0 else {
                    throw posixError(path: fileURL.path)
                }
                return result == 0
            }
        } catch OwnerOnlyFilePersistenceError.missingDirectory {
            return false
        }
    }

    /// Moves one regular owner-only file to a name that does not exist yet.
    ///
    /// Both containing directories are opened without following links and the
    /// source is validated through its descriptor. `renameatx_np` with
    /// `RENAME_EXCL` then moves the directory entry itself: it never follows a
    /// link at either name and refuses to replace an existing destination.
    package static func renameRegularFile(
        at sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try withDirectoryDescriptor(
            for: sourceURL,
            createIfMissing: false
        ) { sourceDirectoryFD, sourceName in
            try withDirectoryDescriptor(
                for: destinationURL,
                createIfMissing: false
            ) { destinationDirectoryFD, destinationName in
                guard
                    let fileFD = try openExistingFile(
                        in: sourceDirectoryFD,
                        name: sourceName,
                        pathForError: sourceURL.path
                    )
                else {
                    throw CocoaError(
                        .fileNoSuchFile,
                        userInfo: [NSFilePathErrorKey: sourceURL.path]
                    )
                }
                defer { Darwin.close(fileFD) }
                try validateRegularOwnerOnlyFile(
                    fileFD,
                    pathForError: sourceURL.path
                )
                let result = sourceName.withCString { sourcePointer in
                    destinationName.withCString { destinationPointer in
                        Darwin.renameatx_np(
                            sourceDirectoryFD,
                            sourcePointer,
                            destinationDirectoryFD,
                            destinationPointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard result == 0 else {
                    throw posixError(path: sourceURL.path)
                }
                guard Darwin.fsync(destinationDirectoryFD) == 0,
                    Darwin.fsync(sourceDirectoryFD) == 0
                else {
                    throw posixError(path: destinationURL.path)
                }
            }
        }
    }

    @discardableResult
    package static func removeEmptyDirectory(at directoryURL: URL) throws -> Bool {
        let probeURL = directoryURL.appendingPathComponent(".speaker-directory-probe")
        do {
            return try withDirectoryDescriptor(
                for: probeURL,
                createIfMissing: false
            ) { directoryFD, _ in
                var status = stat()
                guard Darwin.fstat(directoryFD, &status) == 0 else {
                    throw posixError(path: directoryURL.path)
                }
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw OwnerOnlyFilePersistenceError.nonRegularFile
                }
                guard status.st_uid == geteuid() else {
                    throw OwnerOnlyFilePersistenceError.unexpectedOwner
                }

                let parentURL = directoryURL.deletingLastPathComponent()
                let parentFD = Darwin.open(
                    parentURL.path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard parentFD >= 0 else {
                    throw posixError(path: parentURL.path)
                }
                defer { Darwin.close(parentFD) }
                let result = directoryURL.lastPathComponent.withCString { pointer in
                    Darwin.unlinkat(parentFD, pointer, AT_REMOVEDIR)
                }
                if result != 0, errno == ENOTEMPTY || errno == EEXIST {
                    return false
                }
                if result != 0, errno == ENOENT {
                    return false
                }
                guard result == 0 else {
                    throw posixError(path: directoryURL.path)
                }
                guard Darwin.fsync(parentFD) == 0 else {
                    throw posixError(path: parentURL.path)
                }
                return true
            }
        } catch OwnerOnlyFilePersistenceError.missingDirectory {
            return false
        }
    }

    /// Removes a directory and everything inside it without following a
    /// symbolic link at any level.
    ///
    /// Each entry is inspected with `fstatat(AT_SYMLINK_NOFOLLOW)` relative to
    /// its already-open parent. A symbolic link, like any other
    /// non-directory, is unlinked itself and its destination is never
    /// touched; a subdirectory is opened with `O_DIRECTORY | O_NOFOLLOW` and
    /// must still be the inode that was inspected before its contents are
    /// removed. Every entry must belong to the current user. The first entry
    /// that cannot be removed stops the walk and is reported; entries removed
    /// before it stay removed. Returns `false` when nothing exists at
    /// `directoryURL`.
    @discardableResult
    package static func removeDirectoryTree(at directoryURL: URL) throws -> Bool {
        do {
            return try withDirectoryDescriptor(
                for: directoryURL,
                createIfMissing: false
            ) { parentFD, name in
                guard
                    let status = try entryStatus(
                        named: name,
                        in: parentFD,
                        pathForError: directoryURL.path
                    )
                else {
                    return false
                }
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw OwnerOnlyFilePersistenceError.nonRegularFile
                }
                try removeEntry(
                    named: name,
                    in: parentFD,
                    pathForError: directoryURL.path
                )
                guard Darwin.fsync(parentFD) == 0 else {
                    throw posixError(path: directoryURL.deletingLastPathComponent().path)
                }
                return true
            }
        } catch OwnerOnlyFilePersistenceError.missingDirectory {
            return false
        }
    }
}

extension OwnerOnlyFilePersistence {
    /// The entry's own metadata, never its link destination's, or `nil` when
    /// it does not exist. An entry owned by someone else is refused.
    fileprivate static func entryStatus(
        named name: String,
        in parentFD: Int32,
        pathForError: String
    ) throws -> stat? {
        var status = stat()
        let result = name.withCString { pointer in
            Darwin.fstatat(parentFD, pointer, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0 else {
            throw posixError(path: pathForError)
        }
        guard status.st_uid == geteuid() else {
            throw OwnerOnlyFilePersistenceError.unexpectedOwner
        }
        return status
    }

    fileprivate static func removeEntry(
        named name: String,
        in parentFD: Int32,
        pathForError: String
    ) throws {
        guard
            let status = try entryStatus(
                named: name,
                in: parentFD,
                pathForError: pathForError
            )
        else {
            return
        }
        var flags: Int32 = 0
        if (status.st_mode & S_IFMT) == S_IFDIR {
            let directoryFD = name.withCString { pointer in
                Darwin.openat(
                    parentFD,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard directoryFD >= 0 else {
                throw posixError(path: pathForError)
            }
            defer { Darwin.close(directoryFD) }
            var opened = stat()
            guard Darwin.fstat(directoryFD, &opened) == 0 else {
                throw posixError(path: pathForError)
            }
            guard opened.st_dev == status.st_dev, opened.st_ino == status.st_ino else {
                throw OwnerOnlyFilePersistenceError.changedDuringRemoval
            }
            for child in try entryNames(in: directoryFD, pathForError: pathForError) {
                try removeEntry(
                    named: child,
                    in: directoryFD,
                    pathForError: pathForError + "/" + child
                )
            }
            flags = AT_REMOVEDIR
        }
        let result = name.withCString { pointer in
            Darwin.unlinkat(parentFD, pointer, flags)
        }
        if result != 0, errno != ENOENT {
            throw posixError(path: pathForError)
        }
    }

    /// Lists a directory through its descriptor, so the listing describes the
    /// directory already opened rather than whatever its path names now.
    fileprivate static func entryNames(
        in directoryFD: Int32,
        pathForError: String
    ) throws -> [String] {
        let listingFD = Darwin.dup(directoryFD)
        guard listingFD >= 0 else {
            throw posixError(path: pathForError)
        }
        guard let directory = Darwin.fdopendir(listingFD) else {
            Darwin.close(listingFD)
            throw posixError(path: pathForError)
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while true {
            // `readdir` reports both the end and an error as `nil`; only an
            // error sets `errno`.
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw posixError(path: pathForError)
                }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    fileprivate static func withDirectoryDescriptor<Result>(
        for fileURL: URL,
        createIfMissing: Bool,
        operation: (Int32, String) throws -> Result
    ) throws -> Result {
        guard fileURL.isFileURL else {
            throw OwnerOnlyFilePersistenceError.invalidFileURL
        }
        let name = fileURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw OwnerOnlyFilePersistenceError.invalidFileURL
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let directoryFD = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryFD < 0, errno == ENOENT, !createIfMissing {
            throw OwnerOnlyFilePersistenceError.missingDirectory
        }
        guard directoryFD >= 0 else {
            throw posixError(path: directoryURL.path)
        }
        defer { Darwin.close(directoryFD) }

        var status = stat()
        guard Darwin.fstat(directoryFD, &status) == 0 else {
            throw posixError(path: directoryURL.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw OwnerOnlyFilePersistenceError.nonRegularFile
        }
        guard status.st_uid == geteuid() else {
            throw OwnerOnlyFilePersistenceError.unexpectedOwner
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            throw posixError(path: directoryURL.path)
        }
        return try operation(directoryFD, name)
    }

    fileprivate static func openExistingFile(
        in directoryFD: Int32,
        name: String,
        pathForError: String
    ) throws -> Int32? {
        let fileFD = name.withCString { pointer in
            Darwin.openat(
                directoryFD,
                pointer,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if fileFD < 0, errno == ENOENT { return nil }
        guard fileFD >= 0 else {
            throw posixError(path: pathForError)
        }
        return fileFD
    }

    @discardableResult
    fileprivate static func validateRegularOwnerOnlyFile(
        _ fileFD: Int32,
        pathForError: String
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else {
            throw posixError(path: pathForError)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw OwnerOnlyFilePersistenceError.nonRegularFile
        }
        guard status.st_uid == geteuid() else {
            throw OwnerOnlyFilePersistenceError.unexpectedOwner
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw posixError(path: pathForError)
        }
        return status
    }

    fileprivate static func validateExistingDestination(
        in directoryFD: Int32,
        name: String,
        pathForError: String
    ) throws {
        var status = stat()
        let result = name.withCString { pointer in
            Darwin.fstatat(directoryFD, pointer, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result < 0, errno == ENOENT { return }
        guard result == 0 else {
            throw posixError(path: pathForError)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw OwnerOnlyFilePersistenceError.nonRegularFile
        }
        guard status.st_uid == geteuid() else {
            throw OwnerOnlyFilePersistenceError.unexpectedOwner
        }
    }

    fileprivate static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
