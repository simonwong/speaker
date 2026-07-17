import Foundation

package struct SpeakerOwnedDataLocations {
    package let applicationSupport: URL
    package let legacyApplicationSupport: URL
    package let caches: [URL]
    package let savedApplicationState: [URL]

    package init(
        applicationSupport: URL,
        legacyApplicationSupport: URL,
        caches: [URL],
        savedApplicationState: [URL]
    ) {
        self.applicationSupport = applicationSupport
        self.legacyApplicationSupport = legacyApplicationSupport
        self.caches = caches
        self.savedApplicationState = savedApplicationState
    }

    package static func current(
        fileManager: FileManager = .default,
        bundleIdentifier: String
    ) -> SpeakerOwnedDataLocations {
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupportBase = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? home.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        let cachesBase = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? home.appendingPathComponent(
            "Library/Caches",
            isDirectory: true
        )
        let savedStateBase = home.appendingPathComponent(
            "Library/Saved Application State",
            isDirectory: true
        )
        return SpeakerOwnedDataLocations(
            applicationSupport: applicationSupportBase.appendingPathComponent(
                "Speaker",
                isDirectory: true
            ),
            legacyApplicationSupport: applicationSupportBase
                .appendingPathComponent(
                    "com.local.speaker",
                    isDirectory: true
                ),
            caches: [
                cachesBase.appendingPathComponent(
                    bundleIdentifier,
                    isDirectory: true
                ),
                cachesBase.appendingPathComponent(
                    "Speaker",
                    isDirectory: true
                ),
                cachesBase.appendingPathComponent(
                    "com.local.speaker",
                    isDirectory: true
                ),
            ],
            savedApplicationState: [
                savedStateBase.appendingPathComponent(
                    "\(bundleIdentifier).savedState",
                    isDirectory: true
                ),
                savedStateBase.appendingPathComponent(
                    "com.local.speaker.savedState",
                    isDirectory: true
                ),
            ]
        )
    }
}

package struct SpeakerOwnedLocalDataEraser {
    private let locations: SpeakerOwnedDataLocations
    private let allowedLibraryRoot: URL
    private let fileManager: FileManager

    package init(
        locations: SpeakerOwnedDataLocations,
        allowedLibraryRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.locations = locations
        self.allowedLibraryRoot = allowedLibraryRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    package func eraseApplicationSupport() throws {
        try erase(locations.applicationSupport)
    }

    package func eraseLegacyData() throws {
        try erase(locations.legacyApplicationSupport)
        for location in unique(locations.savedApplicationState) {
            try erase(location)
        }
    }

    package func eraseCaches() throws {
        for location in unique(locations.caches) {
            try erase(location)
        }
    }

    package func verify() throws {
        let ownedLocations = [
            locations.applicationSupport,
            locations.legacyApplicationSupport,
        ] + locations.caches + locations.savedApplicationState
        for location in unique(ownedLocations) {
            try validate(location)
            guard !fileManager.fileExists(atPath: location.path) else {
                throw SpeakerDataErasureReason.verificationMismatch
            }
        }
    }

    private func erase(_ location: URL) throws {
        try validate(location)
        let candidate = location.standardizedFileURL
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        do {
            try fileManager.removeItem(at: candidate)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch let error as CocoaError
            where error.code == .fileWriteNoPermission
                || error.code == .fileReadNoPermission {
            throw SpeakerDataErasureReason.accessDenied
        } catch {
            throw SpeakerDataErasureReason.io
        }
        guard !fileManager.fileExists(atPath: candidate.path) else {
            throw SpeakerDataErasureReason.verificationMismatch
        }
    }

    private func validate(_ location: URL) throws {
        let candidate = location.standardizedFileURL
        let parent = candidate
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedPrefix = allowedLibraryRoot.path + "/"
        guard candidate.path != parent.path,
              parent.path == allowedLibraryRoot.path
                || parent.path.hasPrefix(allowedPrefix)
        else {
            throw SpeakerDataErasureReason.unsafePath
        }
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}
