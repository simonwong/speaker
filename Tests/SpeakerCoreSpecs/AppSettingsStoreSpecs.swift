import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum AppSettingsStoreSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "microphone settings default to the system and persist only a fixed UID in owner-only storage",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-microphone-settings-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            let defaults = await store.load()
            try expect(defaults.settings.microphone == .systemDefault)

            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let legacy = Data(
                #"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"defaultSmooth"},"launchAtLogin":true}}"#
                    .utf8
            )
            try legacy.write(to: fileURL)
            let legacyLoaded = await store.load()
            try expect(legacyLoaded.settings.microphone == .systemDefault)
            try expect(legacyLoaded.settings.refinementProviders.selectedProfile == .legacyDeepSeek)
            try expect(legacyLoaded.settings.speechRecognitionProviders.selectedProfile == .doubao)
            try expect(legacyLoaded.settings.launchAtLogin)
            try await store.updateMicrophone(.device(uid: "synthetic-stable-device"))
            async let shortcut = store.updateShortcut(
                .custom(keyCode: 49, modifiers: 2_048, displayName: "⌥ Space")
            )
            async let refinement = store.updateRefinement(.fullRewrite)
            _ = try await (shortcut, refinement)
            let restored = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            try expect(restored.microphone == .device(uid: "synthetic-stable-device"))
            try expect(restored.refinement == .fullRewrite)
            try expect(restored.launchAtLogin)
            let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let data = try Data(contentsOf: fileURL)
            let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try expect(document?["schemaVersion"] as? Int == 1)
            let text = String(decoding: data, as: UTF8.self)
            try expect(!text.contains("deviceID") && !text.contains("systemDefaultDeviceID"))

            try await store.updateMicrophone(.systemDefault)
            let reset = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            try expect(reset.microphone == .systemDefault)
            try expect(
                reset.shortcut == restored.shortcut && reset.refinement == restored.refinement)
        }

        await runAsync(
            "speech recognition methods migrate legacy profiles and reject incompatible models",
            failures: &failures
        ) {
            for provider in SpeechRecognitionProviderID.allCases {
                let original = SpeechRecognitionProfile(provider: provider)
                let encoded = try JSONEncoder().encode(original)
                var document = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                document.removeValue(forKey: "method")
                let legacy = try JSONDecoder().decode(
                    SpeechRecognitionProfile.self,
                    from: JSONSerialization.data(withJSONObject: document))
                try expect(legacy == original)
                try expect(legacy.method == (provider == .doubao ? .streaming : .completeRecording))
                for method in SpeechRecognitionProviderCatalog.methods(for: provider) {
                    let profile = try SpeechRecognitionProfile(provider: provider, method: method)
                        .validated()
                    let restored = try JSONDecoder().decode(
                        SpeechRecognitionProfile.self, from: JSONEncoder().encode(profile))
                    try expect(restored == profile)
                    try expect(profile.credentialProviderID == original.credentialProviderID)
                }
                document["method"] = "future-recognition-method"
                let unsupported = try JSONDecoder().decode(
                    SpeechRecognitionProfile.self,
                    from: JSONSerialization.data(withJSONObject: document))
                try expect(unsupported.method == .unsupported)
                try expect(unsupported.provider == provider && unsupported.model == original.model)
                do {
                    _ = try unsupported.validated()
                    throw SpecFailure(message: "unknown recognition method silently accepted")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.kind == .invalidConfiguration)
                }
            }
            for profile in [
                SpeechRecognitionProfile(provider: .doubao, method: .completeRecording),
                SpeechRecognitionProfile(
                    provider: .openAI, model: "gpt-transcribe", method: .streaming),
                SpeechRecognitionProfile(
                    provider: .qwen, model: "qwen3-asr-flash-realtime", method: .completeRecording),
            ] {
                do {
                    _ = try profile.validated()
                    throw SpecFailure(message: "incompatible recognition method accepted")
                } catch let failure as SpeechRecognitionFailure {
                    try expect(failure.kind == .invalidConfiguration)
                }
            }
        }

        await runAsync(
            "speech recognition settings retain provider models and region across restarts",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-asr-settings-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            var providers = SpeechRecognitionProviderSettings()
            let openAI = SpeechRecognitionProfile(provider: .openAI, model: "gpt-4o-transcribe")
            let qwen = SpeechRecognitionProfile(
                provider: .qwen, region: .singapore, method: .streaming)
            try providers.select(openAI)
            try await store.updateSpeechRecognitionProviders(providers)
            try providers.select(qwen)
            try await store.updateSpeechRecognitionProviders(providers)
            let restored = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            try expect(restored.speechRecognitionProviders.selectedProfile == qwen)
            try expect(restored.speechRecognitionProviders.profile(for: .openAI) == openAI)
            try expect(restored.refinementProviders == RefinementProviderSettings())
        }

        await runAsync(
            "microphone settings refuse an unsafe existing file without overwriting its contents",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-microphone-settings-protection-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            try await VersionedLocalAppSettingsStore(fileURL: fileURL).save(
                SpeakerAppSettings(microphone: .device(uid: "synthetic-original-device"))
            )
            let original = try Data(contentsOf: fileURL)
            let store = VersionedLocalAppSettingsStore(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in throw FileProtectionFailure() }
            )
            do {
                try await store.updateMicrophone(.systemDefault)
                throw SpecFailure(message: "unsafe settings accepted a microphone update")
            } catch AppSettingsStoreError.sourceUnreadable(.protectionFailed) {
                let preserved = try Data(contentsOf: fileURL)
                try expect(preserved == original)
            }
        }

        await runAsync(
            "versioned app settings round trip shortcut refinement and login launch",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            let settings = SpeakerAppSettings(
                shortcut: .custom(keyCode: 49, modifiers: 2_048, displayName: "⌥ Space"),
                refinement: .custom(name: "短句", prompt: "只清理重复"),
                launchAtLogin: true,
                doubaoResourceID: DoubaoStreamingResource.model1Concurrent.rawValue,
                historyRetention: .thirtyDays
            )

            try await store.save(settings)
            let loaded = await store.load()
            try expect(loaded.settings == settings)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "settings file is not owner-only"
            )

            async let shortcutUpdate = store.updateShortcut(.functionKey)
            async let refinementUpdate = store.updateRefinement(.fullRewrite)
            async let loginUpdate = store.updateLaunchAtLogin(false)
            async let resourceUpdate = store.updateDoubaoResource(.model2Duration)
            async let retentionUpdate = store.updateHistoryRetention(.oneYear)
            _ = try await (
                shortcutUpdate,
                refinementUpdate,
                loginUpdate,
                resourceUpdate,
                retentionUpdate
            )
            let atomicallyUpdated = await store.load().settings
            try expect(atomicallyUpdated.shortcut == .functionKey)
            try expect(atomicallyUpdated.refinement == .fullRewrite)
            try expect(atomicallyUpdated.launchAtLogin == false)
            try expect(
                atomicallyUpdated.doubaoResourceID
                    == DoubaoStreamingResource.model2Duration.rawValue
            )
            try expect(atomicallyUpdated.historyRetention == .oneYear)

            let savedCustom = RefinementPreference(
                mode: .custom(name: "邮件", prompt: "整理成简洁邮件")
            )
            try await store.updateSavedCustomRefinement(savedCustom)
            try await store.updateRefinement(.defaultSmooth)
            let afterBuiltInSwitch = await store.load().settings
            try expect(afterBuiltInSwitch.refinement == .defaultSmooth)
            try expect(afterBuiltInSwitch.savedCustomRefinement == savedCustom)
        }

        await runAsync(
            "legacy settings without retention preserve existing history", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-legacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(
                #"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"defaultSmooth"},"launchAtLogin":false}}"#
                    .utf8)
            try legacy.write(to: fileURL)

            let loaded = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            try expect(loaded.settings.historyRetention == .forever)
        }

        await runAsync(
            "refinement prompt overrides persist incrementally and stay optional for legacy settings",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-prompts-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(
                #"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"conciseCleanup"},"launchAtLogin":false}}"#
                    .utf8)
            try legacy.write(to: fileURL)

            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            let legacyLoaded = await store.load()
            try expect(
                legacyLoaded.settings.refinementPromptOverrides == RefinementPromptOverrides())
            try expect(
                legacyLoaded.settings.refinement.textRefinementMode
                    .applyingPromptOverrides(legacyLoaded.settings.refinementPromptOverrides)
                    == .conciseCleanup()
            )

            try await store.updateRefinementPromptOverride("只保留要点", for: .conciseCleanup())
            try await store.updateRefinementPromptOverride("重组但别发挥", for: .fullRewrite())
            let overridden = await store.load().settings
            try expect(overridden.refinementPromptOverrides.conciseCleanup == "只保留要点")
            try expect(overridden.refinementPromptOverrides.fullRewrite == "重组但别发挥")
            try expect(overridden.refinement == .conciseCleanup)
            try expect(
                overridden.refinement.textRefinementMode
                    .applyingPromptOverrides(overridden.refinementPromptOverrides)
                    == .conciseCleanup(promptOverride: "只保留要点")
            )

            // Selecting another mode never clears the saved overrides.
            try await store.updateRefinement(.fullRewrite)
            let reselected = await store.load().settings
            try expect(reselected.refinementPromptOverrides == overridden.refinementPromptOverrides)

            // Restoring the default clears only that mode's override.
            try await store.updateRefinementPromptOverride(nil, for: .conciseCleanup())
            let restored = await store.load().settings
            try expect(restored.refinementPromptOverrides.conciseCleanup == nil)
            try expect(restored.refinementPromptOverrides.fullRewrite == "重组但别发挥")
        }

        await runAsync(
            "disabling history remembers the enabled retention across restart", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-history-toggle-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let writer = VersionedLocalAppSettingsStore(fileURL: fileURL)
            try await writer.save(
                SpeakerAppSettings(historyRetention: .thirtyDays)
            )
            try await writer.updateHistoryRetention(.disabled)

            let reloaded = await VersionedLocalAppSettingsStore(
                fileURL: fileURL
            ).load().settings
            try expect(reloaded.historyRetention == .disabled)
            try expect(
                reloaded.historyRetentionWhenEnabled == .thirtyDays
            )

            try await writer.updateHistoryRetention(
                reloaded.historyRetentionWhenEnabled
            )
            let enabled = await writer.load().settings
            try expect(enabled.historyRetention == .thirtyDays)
        }

        await runAsync(
            "settings refuse to load when owner-only protection fails", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-protection-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let writer = VersionedLocalAppSettingsStore(fileURL: fileURL)
            try await writer.save(
                SpeakerAppSettings(launchAtLogin: true)
            )
            let protected = VersionedLocalAppSettingsStore(
                fileURL: fileURL,
                fileProtection: LocalFileProtection { _ in
                    throw FileProtectionFailure()
                }
            )

            let result = await protected.load()

            try expect(result.settings == .default)
            guard case .recoveryFailed(_, let failure) = result else {
                throw SpecFailure(message: "settings protection failure was hidden")
            }
            try expect(failure == .protectionFailed)
        }

        run("app settings persistence errors stay structured for presentation", failures: &failures)
        {
            let error = AppSettingsStoreError.writeFailed(reason: "disk unavailable")
            guard case .writeFailed(let reason) = error else {
                throw SpecFailure(message: "write failure lost its reason")
            }
            try expect(reason == "disk unavailable")
            try expect(
                !(error is any LocalizedError), "SpeakerCore must not own user-facing sentences")
        }

        await runAsync(
            "corrupt app settings recover to defaults without overwriting evidence",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-settings-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            try Data("broken".utf8).write(to: fileURL)

            let result = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            if case .recovered(let settings, let recovery) = result {
                try expect(settings == .default)
                try expect(FileManager.default.fileExists(atPath: recovery.backupURL.path))
            } else {
                throw SpecFailure(message: "corrupt settings were not preserved and recovered")
            }
        }
    }
}
