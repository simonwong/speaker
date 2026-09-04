import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum CredentialStoreSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("credential store rejects blank API keys", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-credentials-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("credentials.json")
            )
            do {
                try await store.save(apiKey: "  \n ", for: .doubao)
                throw SpecFailure(message: "blank API key was accepted")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .emptyAPIKey)
            }
        }

        await runAsync("credential store refuses oversized keys without replacing the saved key", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-credentials-size-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("credentials.json")
            )
            try await store.save(apiKey: "retained-key", for: .doubao)

            do {
                try await store.save(
                    apiKey: String(repeating: "a", count: 64 * 1_024 + 1),
                    for: .doubao
                )
                throw SpecFailure(message: "oversized API key was saved")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .apiKeyTooLarge)
            }
            let retainedKey = try await store.apiKey(for: .doubao)
            try expect(
                retainedKey == "retained-key",
                "oversized API key replaced the readable credential"
            )
        }

        await runAsync("credential store round trips and deletes isolated API key", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-credentials-spec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("credentials.json")
            let store = LocalFileProviderCredentialStore(fileURL: fileURL)

            try await store.save(apiKey: "  local-test-key  ", for: .doubao)
            let storedKey = try await store.apiKey(for: .doubao)
            try expect(storedKey == "local-test-key")
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            try expect(permissions == 0o600, "credential file is not owner-only")

            try await store.deleteAPIKey(for: .doubao)
            try await store.deleteAPIKey(for: .doubao)
            let deletedKey = try await store.apiKey(for: .doubao)
            try expect(deletedKey == nil)
            try expect(
                !FileManager.default.fileExists(atPath: fileURL.path),
                "empty plaintext credential container was left on disk"
            )
        }

        await runAsync("stable signed credential store migrates local keys then deletes plaintext", failures: &failures) {
            let keychain = ProviderCredentialStoreFake()
            let local = ProviderCredentialStoreFake(values: [.doubao: "legacy-key"])
            let store = MigratingProviderCredentialStore(
                primary: keychain,
                legacy: local
            )

            let migrated = try await store.apiKey(for: .doubao)
            let keychainValue = try await keychain.apiKey(for: .doubao)
            let localValue = try await local.apiKey(for: .doubao)
            try expect(migrated == "legacy-key")
            try expect(keychainValue == "legacy-key")
            try expect(localValue == nil)
        }

        await runAsync("credential migration verifies Keychain readback and does not block a valid primary on cleanup failure", failures: &failures) {
            let mismatchedPrimary = ProviderCredentialStoreFake(corruptsSavedValues: true)
            let retainedLegacy = ProviderCredentialStoreFake(values: [.doubao: "legacy-key"])
            let mismatchedStore = MigratingProviderCredentialStore(
                primary: mismatchedPrimary,
                legacy: retainedLegacy
            )
            do {
                _ = try await mismatchedStore.apiKey(for: .doubao)
                throw SpecFailure(message: "migration accepted a mismatched primary readback")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .storageUnavailable)
            }
            let retainedLegacyValue = try await retainedLegacy.apiKey(for: .doubao)
            try expect(retainedLegacyValue == "legacy-key")

            let validPrimary = ProviderCredentialStoreFake(values: [.doubao: "keychain-key"])
            let failingCleanup = ProviderCredentialStoreFake(
                values: [.doubao: "keychain-key"],
                deleteFails: true
            )
            let usableStore = MigratingProviderCredentialStore(
                primary: validPrimary,
                legacy: failingCleanup
            )
            let available = try await usableStore.apiKey(for: .doubao)
            let migrationNotice = await usableStore.migrationNotice()
            try expect(available == "keychain-key")
            try expect(migrationNotice != nil)
        }

        await runAsync("credential migration keeps a conflicting legacy key when primary already exists", failures: &failures) {
            let primary = ProviderCredentialStoreFake(
                values: [.doubao: "keychain-key"]
            )
            let legacy = ProviderCredentialStoreFake(
                values: [.doubao: "different-legacy-key"]
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            let available = try await store.apiKey(for: .doubao)
            let primaryValue = try await primary.apiKey(for: .doubao)
            let legacyValue = try await legacy.apiKey(for: .doubao)
            let notice = await store.migrationNotice()

            try expect(available == "keychain-key")
            try expect(primaryValue == "keychain-key")
            try expect(
                legacyValue == "different-legacy-key",
                "a conflicting legacy credential was deleted"
            )
            try expect(notice?.contains("doubao") == true)
        }

        await runAsync("credential deletion keeps the primary key when legacy cleanup fails", failures: &failures) {
            let primary = ProviderCredentialStoreFake(
                values: [.doubao: "keychain-key"]
            )
            let legacy = ProviderCredentialStoreFake(
                values: [.doubao: "plaintext-key"],
                deleteFails: true
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            do {
                try await store.deleteAPIKey(for: .doubao)
                throw SpecFailure(
                    message: "delete succeeded while plaintext cleanup failed"
                )
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .storageUnavailable)
            }

            let primaryValue = try await primary.apiKey(for: .doubao)
            let availableValue = try await store.apiKey(for: .doubao)
            try expect(
                primaryValue == "keychain-key",
                "primary key was deleted before legacy cleanup committed"
            )
            try expect(
                availableValue == "keychain-key",
                "legacy key replaced the retained primary after failed deletion"
            )
        }

        await runAsync("credential migration preserves every legacy source when values conflict", failures: &failures) {
            let primary = ProviderCredentialStoreFake()
            let oldKeychain = ProviderCredentialStoreFake(
                values: [.doubao: "old-keychain-key"]
            )
            let plaintext = ProviderCredentialStoreFake(
                values: [.doubao: "plaintext-key"]
            )
            let legacy = LegacyProviderCredentialStoreChain(
                stores: [oldKeychain, plaintext]
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            do {
                _ = try await store.apiKey(for: .doubao)
                throw SpecFailure(message: "conflicting legacy credentials were migrated")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .conflictingStoredValues)
            }
            let primaryValue = try await primary.apiKey(for: .doubao)
            let oldKeychainValue = try await oldKeychain.apiKey(for: .doubao)
            let plaintextValue = try await plaintext.apiKey(for: .doubao)
            try expect(primaryValue == nil)
            try expect(oldKeychainValue == "old-keychain-key")
            try expect(plaintextValue == "plaintext-key")

            await store.migrateAllProviders()
            let notice = await store.migrationNotice()
            try expect(notice?.contains("doubao") == true)
        }

        await runAsync("credential migration never cleans readable legacy data when another source cannot be inspected", failures: &failures) {
            let primary = ProviderCredentialStoreFake()
            let unreadable = ProviderCredentialStoreFake(
                readError: .interactionUnavailable
            )
            let plaintext = ProviderCredentialStoreFake(
                values: [.deepSeek: "readable-key"]
            )
            let legacy = LegacyProviderCredentialStoreChain(
                stores: [unreadable, plaintext]
            )
            let store = MigratingProviderCredentialStore(
                primary: primary,
                legacy: legacy
            )

            do {
                _ = try await store.apiKey(for: .deepSeek)
                throw SpecFailure(message: "partially inspected legacy credentials were migrated")
            } catch let error as ProviderCredentialStoreError {
                try expect(error == .interactionUnavailable)
            }
            let primaryValue = try await primary.apiKey(for: .deepSeek)
            let plaintextValue = try await plaintext.apiKey(for: .deepSeek)
            try expect(primaryValue == nil)
            try expect(plaintextValue == "readable-key")
        }
    }
}
