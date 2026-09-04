import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum OwnerOnlyPersistenceSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("owner-only settings never follow a symbolic-link file", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-symlink-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let targetURL = directory.appendingPathComponent("outside.json")
            let fileURL = directory.appendingPathComponent("settings.json")
            try await VersionedLocalAppSettingsStore(fileURL: targetURL).save(
                SpeakerAppSettings(launchAtLogin: true)
            )
            try FileManager.default.createSymbolicLink(
                at: fileURL,
                withDestinationURL: targetURL
            )

            let result = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()

            try expect(result.settings == .default)
            guard case .recoveryFailed = result else {
                throw SpecFailure(message: "symlinked settings were loaded or recovered")
            }
            let target = await VersionedLocalAppSettingsStore(fileURL: targetURL).load()
            try expect(target.settings.launchAtLogin)
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: fileURL.path
            )
            try expect(destination == targetURL.path)
        }

        await runAsync("owner-only dictionary and credentials never follow symbolic-link files", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-sensitive-symlink-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let dictionaryTarget = directory.appendingPathComponent("dictionary-target.json")
            let dictionaryLink = directory.appendingPathComponent("dictionary.json")
            let expectedDictionary = try PersonalDictionary(entries: [
                .init(word: "private-term"),
            ])
            try await VersionedJSONPersonalDictionaryStore(fileURL: dictionaryTarget)
                .save(expectedDictionary)
            try FileManager.default.createSymbolicLink(
                at: dictionaryLink,
                withDestinationURL: dictionaryTarget
            )
            do {
                _ = try await VersionedJSONPersonalDictionaryStore(fileURL: dictionaryLink)
                    .load()
                throw SpecFailure(message: "symlinked dictionary was loaded")
            } catch let error as PersonalDictionaryStoreError {
                try expect(error == .privacyProtectionFailed)
            }

            let credentialTarget = directory.appendingPathComponent("credential-target.json")
            let credentialLink = directory.appendingPathComponent("credentials.json")
            let targetStore = LocalFileProviderCredentialStore(fileURL: credentialTarget)
            try await targetStore.save(apiKey: "private-key", for: .doubao)
            try FileManager.default.createSymbolicLink(
                at: credentialLink,
                withDestinationURL: credentialTarget
            )
            do {
                _ = try await LocalFileProviderCredentialStore(fileURL: credentialLink)
                    .apiKey(for: .doubao)
                throw SpecFailure(message: "symlinked credentials were loaded")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .storageUnavailable)
            }
        }

        await runAsync("owner-only persistence never writes through a symbolic-link directory", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-directory-symlink-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let outsideDirectory = root.appendingPathComponent(
                "outside",
                isDirectory: true
            )
            let linkedDirectory = root.appendingPathComponent(
                "Speaker",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outsideDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory,
                withDestinationURL: outsideDirectory
            )
            let fileURL = linkedDirectory.appendingPathComponent("settings.json")

            do {
                try await VersionedLocalAppSettingsStore(fileURL: fileURL).save(
                    SpeakerAppSettings(launchAtLogin: true)
                )
                throw SpecFailure(message: "settings were written through a symlink directory")
            } catch is AppSettingsStoreError {
                // Expected: the public store maps the fail-closed path error.
            }
            try expect(
                !FileManager.default.fileExists(
                    atPath: outsideDirectory
                        .appendingPathComponent("settings.json")
                        .path
                )
            )

            let outsideCredential = outsideDirectory.appendingPathComponent(
                "credentials.json"
            )
            try Data("external-credential".utf8).write(to: outsideCredential)
            do {
                _ = try OwnerOnlyFilePersistence.removeRegularFile(
                    at: linkedDirectory.appendingPathComponent("credentials.json")
                )
                throw SpecFailure(message: "credential was removed through a symlink directory")
            } catch let failure as SpecFailure {
                throw failure
            } catch {
                // Expected: removal uses the same no-follow directory boundary.
            }
            let retainedCredential = try Data(contentsOf: outsideCredential)
            try expect(
                retainedCredential == Data("external-credential".utf8),
                "external credential was changed"
            )
        }

        await runAsync("settings reject non-regular and oversized files without moving evidence", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-file-boundary-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let directoryURL = directory.appendingPathComponent(
                "settings-as-directory.json",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            let nonRegular = await VersionedLocalAppSettingsStore(
                fileURL: directoryURL
            ).load()
            guard case .recoveryFailed = nonRegular else {
                throw SpecFailure(message: "non-regular settings were treated as recoverable JSON")
            }
            var isDirectory: ObjCBool = false
            try expect(
                FileManager.default.fileExists(
                    atPath: directoryURL.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue,
                "non-regular settings evidence was moved"
            )

            let oversizedURL = directory.appendingPathComponent("oversized-settings.json")
            try Data(repeating: 0x41, count: 1_048_577).write(to: oversizedURL)
            let oversized = await VersionedLocalAppSettingsStore(
                fileURL: oversizedURL
            ).load()
            guard case .recoveryFailed = oversized else {
                throw SpecFailure(message: "oversized settings were treated as recoverable JSON")
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: oversizedURL.path
            )
            try expect(
                (attributes[.size] as? NSNumber)?.intValue == 1_048_577,
                "oversized settings evidence was moved or rewritten"
            )

            let store = VersionedLocalAppSettingsStore(fileURL: oversizedURL)
            do {
                _ = try await store.updateLaunchAtLogin(true)
                throw SpecFailure(message: "an update overwrote unreadable settings")
            } catch let error as AppSettingsStoreError {
                guard case .writeFailed = error else {
                    throw SpecFailure(message: "unexpected settings update error")
                }
            }
            let retainedAttributes = try FileManager.default.attributesOfItem(
                atPath: oversizedURL.path
            )
            try expect(
                (retainedAttributes[.size] as? NSNumber)?.intValue == 1_048_577,
                "failed settings update did not preserve oversized evidence"
            )
        }

        run("recovery archives retain only recent bounded no-follow evidence", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-recovery-budget-spec-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let now = Date()
            for index in 0..<5 {
                let file = root.appendingPathComponent(
                    "settings.recovery-\(index).json"
                )
                try OwnerOnlyFilePersistence.write(Data([UInt8(index)]), to: file)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-Double(index * 60))],
                    ofItemAtPath: file.path
                )
            }
            let external = root.appendingPathComponent("external-sentinel")
            try Data("external".utf8).write(to: external)
            let linked = root.appendingPathComponent("settings.recovery-linked.json")
            try FileManager.default.createSymbolicLink(
                at: linked,
                withDestinationURL: external
            )

            let filePruning = RecoveryArchivePruner.pruneRegularFiles(
                in: root,
                prefix: "settings.recovery-",
                suffix: ".json",
                now: now
            )
            try expect(filePruning.isComplete, "pruning reported a failure")
            try expect(filePruning.removedCount == 2)
            try expect(filePruning.retainedCount == 3)

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try expect(names.contains("settings.recovery-0.json"))
            try expect(names.contains("settings.recovery-1.json"))
            try expect(names.contains("settings.recovery-2.json"))
            try expect(!names.contains("settings.recovery-3.json"))
            try expect(!names.contains("settings.recovery-4.json"))
            try expect(names.contains("settings.recovery-linked.json"))
            let sentinel = try Data(contentsOf: external)
            try expect(sentinel == Data("external".utf8))

            let old = root.appendingPathComponent("history.corrupt-old.json")
            try OwnerOnlyFilePersistence.write(Data("old".utf8), to: old)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(
                    -RecoveryArchivePruner.maximumAge - 60
                )],
                ofItemAtPath: old.path
            )
            let current = root.appendingPathComponent("history.corrupt-current.json")
            try OwnerOnlyFilePersistence.write(Data("current".utf8), to: current)
            _ = RecoveryArchivePruner.pruneRegularFiles(
                in: root,
                prefix: "history.corrupt-",
                suffix: ".json",
                now: now
            )
            try expect(!FileManager.default.fileExists(atPath: old.path))
            try expect(FileManager.default.fileExists(atPath: current.path))

            for index in 0..<5 {
                let archive = root.appendingPathComponent(
                    "history.corrupt-\(index)",
                    isDirectory: true
                )
                let database = archive.appendingPathComponent("history.sqlite3")
                try OwnerOnlyFilePersistence.write(Data([UInt8(index)]), to: database)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-Double(index * 60))],
                    ofItemAtPath: archive.path
                )
            }
            let directoryPruning = RecoveryArchivePruner.pruneFlatDirectories(
                in: root,
                prefix: "history.corrupt-",
                now: now
            )
            try expect(directoryPruning.isComplete)
            try expect(directoryPruning.removedCount == 2)
            let directoryNames = try FileManager.default.contentsOfDirectory(
                atPath: root.path
            )
            try expect(directoryNames.contains("history.corrupt-0"))
            try expect(directoryNames.contains("history.corrupt-1"))
            try expect(directoryNames.contains("history.corrupt-2"))
            try expect(!directoryNames.contains("history.corrupt-3"))
            try expect(!directoryNames.contains("history.corrupt-4"))
        }

        run("recovery archive pruning reports the archives it could not remove", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-recovery-prune-failure-spec-\(UUID().uuidString)",
                    isDirectory: true
                )
            var lockedPaths: [String] = []
            defer {
                for path in lockedPaths {
                    try? FileManager.default.setAttributes(
                        [.immutable: false],
                        ofItemAtPath: path
                    )
                }
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let now = Date()
            for index in 0..<5 {
                let file = root.appendingPathComponent("settings.recovery-\(index).json")
                try OwnerOnlyFilePersistence.write(Data([UInt8(index)]), to: file)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-Double(index * 60))],
                    ofItemAtPath: file.path
                )
            }
            // The two oldest archives are the ones over budget. Locking them
            // is the realistic way a prune half-succeeds: they stay on disk,
            // and the caller has to be told rather than left to assume the
            // directory shrank.
            for index in 3..<5 {
                let path = root
                    .appendingPathComponent("settings.recovery-\(index).json")
                    .path
                try FileManager.default.setAttributes(
                    [.immutable: true],
                    ofItemAtPath: path
                )
                lockedPaths.append(path)
            }

            let summary = RecoveryArchivePruner.pruneRegularFiles(
                in: root,
                prefix: "settings.recovery-",
                suffix: ".json",
                now: now
            )

            try expect(!summary.isComplete, "an unremovable archive was reported as pruned")
            try expect(summary.removedCount == 0)
            try expect(summary.failures.count == 2)
            try expect(
                summary.failures.allSatisfy { $0.hasPrefix("settings.recovery-") },
                "a prune failure did not name its archive"
            )
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try expect(names.count == 5, "an archive was removed from a read-only directory")
        }
    }
}
