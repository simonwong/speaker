import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum PersonalDictionarySpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run("personal dictionary reports empty and duplicate words", failures: &failures) {
            let emptyID = UUID()
            let duplicateOne = UUID()
            let duplicateTwo = UUID()
            let issues = PersonalDictionaryValidator.validate([
                .init(id: emptyID, word: " "),
                .init(id: duplicateOne, word: "Speaker"),
                .init(id: duplicateTwo, word: "speaker"),
            ])

            try expect(issues.contains(.emptyWord(entryID: emptyID)))
            try expect(
                issues.contains { issue in
                    if case .duplicateWord = issue { true } else { false }
                })
        }

        run("dictionary Entry quality policy preserves documented boundaries", failures: &failures)
        {
            try expect(DictionaryEntryQualityPolicy.hint(for: "123456789") == .none)
            try expect(DictionaryEntryQualityPolicy.hint(for: "1234567890") == .tooLong)
            try expect(DictionaryEntryQualityPolicy.hint(for: "字") == .singleCharacter)
            try expect(DictionaryEntryQualityPolicy.hint(for: " 123456789 ") == .none)
            try expect(DictionaryEntryQualityPolicy.hint(for: "\n1234567890\t") == .tooLong)
            try expect(DictionaryEntryQualityPolicy.hint(for: " 字\n") == .singleCharacter)
        }

        run(
            "dictionary Entry candidates preserve supported runs and deduplicate case-insensitively",
            failures: &failures
        ) {
            let candidates = DictionaryEntryCandidateExtractor.candidates(
                in: "Use a Swift-lang v2.0, I O'Reilly; SPEAKER speaker 123 42 中文"
            )

            try expect(
                candidates == ["Use", "Swift-lang", "v2.0", "O'Reilly", "SPEAKER"]
            )
        }

        run("dictionary Entry candidates stop at the fixed limit", failures: &failures) {
            let text = (0...(DictionaryEntryCandidateExtractor.maximumCandidateCount + 2))
                .map { "Term\($0)" }
                .joined(separator: " ")
            let candidates = DictionaryEntryCandidateExtractor.candidates(in: text)

            try expect(
                candidates.count
                    == DictionaryEntryCandidateExtractor.maximumCandidateCount
            )
            try expect(candidates.first == "Term0")
            try expect(
                candidates.last
                    == "Term\(DictionaryEntryCandidateExtractor.maximumCandidateCount - 1)"
            )
        }

        await runAsync(
            "versioned personal dictionary store migrates v1 canonical terms", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-dictionary-v1-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let retainedID = UUID()
            let discardedStateID = UUID()
            let legacyDocument: [String: Any] = [
                "version": 1,
                "entries": [
                    [
                        "id": retainedID.uuidString,
                        "canonicalTerm": "Speaker",
                        "aliases": ["说话者"],
                        "isEnabled": true,
                    ],
                    [
                        "id": discardedStateID.uuidString,
                        "canonicalTerm": "DeepSeek",
                        "aliases": ["deep seek"],
                        "isEnabled": false,
                    ],
                ],
            ]
            let legacyData = try JSONSerialization.data(withJSONObject: legacyDocument)
            try legacyData.write(to: fileURL)
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)

            let dictionary = try await store.load().dictionary
            let migratedData = try Data(contentsOf: fileURL)
            let migratedDocument =
                try JSONSerialization.jsonObject(with: migratedData)
                as? [String: Any]
            let migratedEntries = migratedDocument?["entries"] as? [[String: Any]]

            try expect(dictionary.entries.map(\.word) == ["Speaker", "DeepSeek"])
            try expect(migratedDocument?["version"] as? Int == 2)
            try expect(
                migratedEntries?.allSatisfy { entry in
                    entry["word"] != nil
                        && entry["canonicalTerm"] == nil
                        && entry["aliases"] == nil
                        && entry["isEnabled"] == nil
                } == true)
        }

        run("dictionary snapshot preserves entry order before provider guard", failures: &failures)
        {
            let alpha = DictionaryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                word: "Alpha"
            )
            let beta = DictionaryEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                word: "Beta"
            )
            let long = DictionaryEntry(word: "VeryLongTerm")
            let dictionary = try PersonalDictionary(entries: [beta, alpha, long])
            let snapshot = dictionary.snapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                createdAt: Date(timeIntervalSince1970: 10)
            )
            let context = DictionaryRequestContextBuilder.makeContext(
                from: snapshot,
                capacity: .init(maximumHotwordCount: 1)
            )

            try expect(DictionaryProviderCapacity.doubao.maximumHotwordCount == 100)
            try expect(snapshot.entries.map(\.word) == ["Beta", "Alpha", "VeryLongTerm"])
            try expect(context.hotwords == ["Beta"])
            try expect(context.includedEntryIDs == [beta.id])
            try expect(context.omissions.count == 2)
            try expect(context.omissions.allSatisfy { $0.reason == .providerCountLimit })
        }

        await runAsync(
            "versioned personal dictionary store round trips locally", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            let dictionary = try PersonalDictionary(entries: [
                .init(word: "豆包"),
                .init(word: "DeepSeek"),
            ])

            try await store.save(dictionary)
            let loaded = try await store.load().dictionary
            try expect(loaded == dictionary)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "dictionary file is not owner-only"
            )
        }

        await runAsync(
            "versioned personal dictionary rejects whitespace-only v2 words", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-blank-v2-spec-\(UUID().uuidString)"
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let document: [String: Any] = [
                "version": 2,
                "entries": [
                    [
                        "id": UUID().uuidString,
                        "word": "   ",
                    ]
                ],
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: fileURL)
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)

            let result = try await store.load()
            try expect(result.dictionary == .empty, "whitespace-only v2 word was loaded")
            guard let recovery = result.recovery else {
                throw SpecFailure(message: "whitespace-only v2 word was not treated as corruption")
            }
            try expect(
                FileManager.default.fileExists(atPath: recovery.backupURL.path),
                "corrupt dictionary was not preserved beside the file"
            )
        }

        await runAsync(
            "personal dictionary refuses an unreadable oversized save and retains the old file",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-dictionary-size-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            let retained = try PersonalDictionary(entries: [
                .init(word: "retained-term")
            ])
            try await store.save(retained)
            let oversized = try PersonalDictionary(entries: [
                .init(word: String(repeating: "字", count: 3 * 1_024 * 1_024))
            ])

            do {
                try await store.save(oversized)
                throw SpecFailure(message: "oversized dictionary was saved")
            } catch let error as PersonalDictionaryStoreError {
                try expect(error == .writeFailed)
            }
            let reloaded = try await store.load().dictionary
            try expect(
                reloaded == retained,
                "oversized dictionary replaced the readable file"
            )
        }

        await runAsync(
            "personal dictionary refuses to load when owner-only protection fails",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-protection-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("dictionary.json")
            let writer = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            try await writer.save(
                PersonalDictionary(entries: [
                    .init(word: "private term")
                ])
            )
            let protected = VersionedJSONPersonalDictionaryStore(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )

            do {
                _ = try await protected.load()
                throw SpecFailure(message: "unprotected dictionary was loaded")
            } catch let failure as PersonalDictionaryStoreError {
                try expect(failure == .privacyProtectionFailed)
            }
        }

        await runAsync(
            "personal dictionary migration verifies the stable copy before removing legacy data",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-migration-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacyURL =
                directory
                .appendingPathComponent("legacy/dictionary.json")
            let primaryURL =
                directory
                .appendingPathComponent("Speaker/personal-dictionary.json")
            let dictionary = try PersonalDictionary(entries: [
                .init(word: "豆包")
            ])
            try await VersionedJSONPersonalDictionaryStore(fileURL: legacyURL)
                .save(dictionary)

            let outcome =
                await VersionedJSONPersonalDictionaryStore
                .migrateLegacyFileIfNeeded(
                    from: legacyURL,
                    to: primaryURL
                )
            let migrated = try await VersionedJSONPersonalDictionaryStore(
                fileURL: primaryURL
            ).load().dictionary

            try expect(outcome == .migrated)
            try expect(migrated == dictionary)
            try expect(
                !FileManager.default.fileExists(atPath: legacyURL.path),
                "verified legacy dictionary was not removed"
            )
        }

        await runAsync(
            "personal dictionary migration never overwrites an existing stable dictionary",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-existing-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacyURL = directory.appendingPathComponent("legacy.json")
            let primaryURL = directory.appendingPathComponent("primary.json")
            let legacyDictionary = try PersonalDictionary(entries: [
                .init(word: "旧词条")
            ])
            let primaryDictionary = try PersonalDictionary(entries: [
                .init(word: "新词条")
            ])
            try await VersionedJSONPersonalDictionaryStore(fileURL: legacyURL)
                .save(legacyDictionary)
            try await VersionedJSONPersonalDictionaryStore(fileURL: primaryURL)
                .save(primaryDictionary)

            let outcome =
                await VersionedJSONPersonalDictionaryStore
                .migrateLegacyFileIfNeeded(
                    from: legacyURL,
                    to: primaryURL
                )
            let retained = try await VersionedJSONPersonalDictionaryStore(
                fileURL: primaryURL
            ).load().dictionary

            try expect(outcome == .primaryAlreadyExists)
            try expect(retained == primaryDictionary)
            try expect(
                FileManager.default.fileExists(atPath: legacyURL.path),
                "legacy data was removed without being selected for migration"
            )
        }

        await runAsync(
            "corrupted legacy dictionary is preserved when migration fails", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-corrupt-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let legacyURL = directory.appendingPathComponent("legacy.json")
            let primaryURL = directory.appendingPathComponent("primary.json")
            try Data("not-json".utf8).write(to: legacyURL)

            let outcome =
                await VersionedJSONPersonalDictionaryStore
                .migrateLegacyFileIfNeeded(
                    from: legacyURL,
                    to: primaryURL
                )

            try expect(outcome == .failed)
            try expect(
                FileManager.default.fileExists(atPath: legacyURL.path),
                "corrupted legacy dictionary was deleted"
            )
            try expect(
                !FileManager.default.fileExists(atPath: primaryURL.path),
                "failed migration left a primary dictionary"
            )
        }
    }
}
