import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum AppSettingsStoreSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("versioned app settings round trip shortcut refinement and login launch", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-spec-\(UUID().uuidString)", isDirectory: true)
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

        await runAsync("legacy settings without retention preserve existing history", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-legacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(#"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"defaultSmooth"},"launchAtLogin":false}}"#.utf8)
            try legacy.write(to: fileURL)

            let loaded = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            try expect(loaded.settings.historyRetention == .forever)
        }

        await runAsync("refinement prompt overrides persist incrementally and stay optional for legacy settings", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-prompts-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(#"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"conciseCleanup"},"launchAtLogin":false}}"#.utf8)
            try legacy.write(to: fileURL)

            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            let legacyLoaded = await store.load()
            try expect(legacyLoaded.settings.refinementPromptOverrides == RefinementPromptOverrides())
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

        await runAsync("disabling history remembers the enabled retention across restart", failures: &failures) {
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

        await runAsync("settings refuse to load when owner-only protection fails", failures: &failures) {
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
            guard case let .recoveryFailed(_, reason) = result else {
                throw SpecFailure(message: "settings protection failure was hidden")
            }
            try expect(reason.contains("文件权限"))
        }

        run("app settings persistence errors have a user-facing description", failures: &failures) {
            let error = AppSettingsStoreError.writeFailed(reason: "disk unavailable")
            try expect(error.localizedDescription == "无法保存 Speaker 设置：disk unavailable")
        }

        await runAsync("corrupt app settings recover to defaults without overwriting evidence", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-settings-corrupt-spec-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("settings.json")
            try Data("broken".utf8).write(to: fileURL)

            let result = await VersionedLocalAppSettingsStore(fileURL: fileURL).load()
            if case let .recovered(settings, recovery) = result {
                try expect(settings == .default)
                try expect(FileManager.default.fileExists(atPath: recovery.backupURL.path))
            } else {
                throw SpecFailure(message: "corrupt settings were not preserved and recovered")
            }
        }
    }
}
