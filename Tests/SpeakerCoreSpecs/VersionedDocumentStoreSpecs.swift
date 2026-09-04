import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum VersionedDocumentStoreSpecs: CoreSpecDomain {
    private struct VersionedFixture: Codable, Equatable {
        let schemaVersion: Int
        let words: [String]
    }

    private struct LegacyFixture: Decodable {
        let schemaVersion: Int
        let word: String
    }

    private static let fixtureSchema = VersionedDocumentSchema<[String]>(
        currentVersion: 2,
        versionKey: .schemaVersion,
        decoders: [
            2: { data in
                try JSONDecoder().decode(VersionedFixture.self, from: data).words
            },
            1: { data in
                [try JSONDecoder().decode(LegacyFixture.self, from: data).word]
            },
        ]
    )

    private static func fixtureDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func siblingNames(of fileURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        ).sorted()
    }

    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("corrupt personal dictionary is preserved beside the file and loading continues empty", failures: &failures) {
            let directory = try fixtureDirectory("speaker-dictionary-preserve")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("personal-dictionary.json")
            try Data("not-json".utf8).write(to: fileURL)
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)

            let result = try await store.load()

            try expect(result.dictionary == .empty, "corrupt dictionary did not load as empty")
            guard let recovery = result.recovery else {
                throw SpecFailure(message: "corrupt dictionary produced no recovery notice")
            }
            guard case .malformed = recovery.reason else {
                throw SpecFailure(message: "unexpected corruption reason \(recovery.reason)")
            }
            try expect(
                recovery.backupURL.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL,
                "backup was not preserved in the dictionary directory"
            )
            try expect(
                recovery.backupURL.lastPathComponent.hasPrefix("personal-dictionary.corrupt-"),
                "backup name \(recovery.backupURL.lastPathComponent) lacks the corrupt- infix"
            )
            let backupBytes = try Data(contentsOf: recovery.backupURL)
            try expect(
                backupBytes == Data("not-json".utf8),
                "backup does not hold the original bytes"
            )
            try expect(
                !FileManager.default.fileExists(atPath: fileURL.path),
                "corrupt file still occupies the dictionary location"
            )

            let saved = try PersonalDictionary(entries: [.init(word: "Speaker")])
            try await store.save(saved)
            let reloaded = try await store.load()
            try expect(reloaded.dictionary == saved)
            try expect(reloaded.recovery == nil, "a clean reload still reported recovery")
            try expect(
                FileManager.default.fileExists(atPath: recovery.backupURL.path),
                "saving a new dictionary discarded the preserved backup"
            )
        }

        await runAsync("unsupported personal dictionary version is preserved instead of refused", failures: &failures) {
            let directory = try fixtureDirectory("speaker-dictionary-unsupported")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("personal-dictionary.json")
            try JSONSerialization.data(withJSONObject: ["version": 99, "entries": []])
                .write(to: fileURL)

            let result = try await VersionedJSONPersonalDictionaryStore(fileURL: fileURL).load()

            try expect(result.dictionary == .empty)
            try expect(result.recovery?.reason == .unsupportedVersion(99))
            try expect(
                result.recovery.map { FileManager.default.fileExists(atPath: $0.backupURL.path) } == true,
                "unsupported dictionary was not preserved"
            )
        }

        await runAsync("whitespace-only v2 dictionary words are treated as corruption and preserved", failures: &failures) {
            let directory = try fixtureDirectory("speaker-dictionary-whitespace")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("personal-dictionary.json")
            let document: [String: Any] = [
                "version": 2,
                "entries": [["id": UUID().uuidString, "word": "   "]],
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: fileURL)

            let result = try await VersionedJSONPersonalDictionaryStore(fileURL: fileURL).load()

            try expect(result.dictionary == .empty)
            guard case .malformed = result.recovery?.reason else {
                throw SpecFailure(message: "whitespace-only word was not reported as malformed")
            }
        }

        await runAsync("dictionary migration inspects a corrupt legacy file without moving it", failures: &failures) {
            let directory = try fixtureDirectory("speaker-dictionary-inspect")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("legacy.json")
            try Data("{".utf8).write(to: fileURL)
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)

            let decoded = try await store.decodeWithoutRecovery()

            try expect(decoded == nil, "corrupt legacy dictionary decoded to a value")
            let siblings = try siblingNames(of: fileURL)
            try expect(siblings == ["legacy.json"], "inspection moved or copied the file")
        }

        run("versioned document store dispatches by version table and preserves what it cannot decode", failures: &failures) {
            let directory = try fixtureDirectory("speaker-document-store")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("fixture.json")
            let store = VersionedOwnerOnlyDocumentStore(
                fileURL: fileURL,
                schema: fixtureSchema,
                maximumByteCount: 4_096,
                backupInfix: "recovery-"
            )

            guard case .absent = store.load() else {
                throw SpecFailure(message: "a missing document was not reported absent")
            }

            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "word": "legacy"])
                .write(to: fileURL)
            guard case let .loaded(document, version) = store.load() else {
                throw SpecFailure(message: "version 1 document was not migrated")
            }
            try expect(document == ["legacy"])
            try expect(version == 1)
            let storedLegacy = try JSONDecoder().decode(LegacyFixture.self, from: Data(contentsOf: fileURL))
            try expect(storedLegacy.word == "legacy", "loading rewrote the stored document")

            try store.write(JSONEncoder().encode(VersionedFixture(schemaVersion: 2, words: ["a", "b"])))
            guard case let .loaded(current, currentVersion) = store.load() else {
                throw SpecFailure(message: "current document was not loaded")
            }
            try expect(current == ["a", "b"] && currentVersion == 2)

            try JSONSerialization.data(withJSONObject: ["schemaVersion": 7])
                .write(to: fileURL)
            guard case .corrupted(.unsupportedVersion(7)) = store.decode() else {
                throw SpecFailure(message: "decode did not report the unsupported version")
            }
            let afterDecode = try siblingNames(of: fileURL)
            try expect(afterDecode == ["fixture.json"], "decode moved the file")
            guard case let .corruptedPreserved(backupURL, .unsupportedVersion(7)) = store.load() else {
                throw SpecFailure(message: "load did not preserve the unsupported document")
            }
            try expect(backupURL.lastPathComponent.hasPrefix("fixture.recovery-"))
            let afterPreserve = try siblingNames(of: fileURL)
            try expect(afterPreserve == [backupURL.lastPathComponent])

            try Data("{\"schemaVersion\": \"two\"}".utf8).write(to: fileURL)
            guard case .corruptedPreserved(_, .malformed) = store.load() else {
                throw SpecFailure(message: "a malformed version header was not preserved")
            }

            let oversized = Data(repeating: UInt8(ascii: " "), count: 4_097)
            do {
                try store.write(oversized)
                throw SpecFailure(message: "oversized document was written")
            } catch OwnerOnlyFilePersistenceError.fileTooLarge {}

            try store.removeBackups()
            let remaining = try siblingNames(of: fileURL)
            try expect(remaining.isEmpty, "removeBackups left preserved copies behind")
        }

        run("versioned document store leaves an unreadable file in place", failures: &failures) {
            let directory = try fixtureDirectory("speaker-document-unreadable")
            defer { try? FileManager.default.removeItem(at: directory) }
            let targetURL = directory.appendingPathComponent("outside.json")
            let fileURL = directory.appendingPathComponent("fixture.json")
            try JSONEncoder().encode(VersionedFixture(schemaVersion: 2, words: ["x"]))
                .write(to: targetURL)
            try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: targetURL)
            let store = VersionedOwnerOnlyDocumentStore(
                fileURL: fileURL,
                schema: fixtureSchema,
                maximumByteCount: 4_096,
                backupInfix: "recovery-"
            )

            // The owner-only boundary opens without following links, so the
            // link is refused before any bytes are read or moved aside.
            let linkOutcome = store.load()
            guard case .failed = linkOutcome else {
                throw SpecFailure(message: "a symbolic link was loaded or preserved: \(linkOutcome)")
            }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
            try expect(destination == targetURL.path, "the symbolic link was moved")

            let unprotectable = VersionedOwnerOnlyDocumentStore(
                fileURL: targetURL,
                schema: fixtureSchema,
                maximumByteCount: 4_096,
                backupInfix: "recovery-",
                fileProtection: LocalFileProtection { _ in
                    throw SpecFailure(message: "protection refused")
                }
            )
            guard case .failed(.protectionFailed) = unprotectable.load() else {
                throw SpecFailure(message: "a protection failure did not stop loading")
            }
            try expect(FileManager.default.fileExists(atPath: targetURL.path))
        }
    }
}
