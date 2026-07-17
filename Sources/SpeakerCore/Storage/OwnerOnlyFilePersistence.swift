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

enum OwnerOnlyFilePersistenceError: Error {
    case invalidFileURL
    case missingDirectory
    case nonRegularFile
    case unexpectedOwner
    case fileTooLarge(maximumByteCount: Int)
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
            guard let fileFD = try openExistingFile(
                in: directoryFD,
                name: name,
                pathForError: fileURL.path
            ) else {
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
            guard let fileFD = try openExistingFile(
                in: directoryFD,
                name: name,
                pathForError: fileURL.path
            ) else {
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
                guard let fileFD = try openExistingFile(
                    in: directoryFD,
                    name: name,
                    pathForError: fileURL.path
                ) else {
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
                guard let fileFD = try openExistingFile(
                    in: directoryFD,
                    name: name,
                    pathForError: fileURL.path
                ) else {
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
}

private extension OwnerOnlyFilePersistence {
    static func withDirectoryDescriptor<Result>(
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

    static func openExistingFile(
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
    static func validateRegularOwnerOnlyFile(
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

    static func validateExistingDestination(
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

    static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
