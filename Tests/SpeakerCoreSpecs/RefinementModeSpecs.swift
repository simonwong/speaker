import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

/// The Custom Mode list and the Refinement Mode order. The mode is always the
/// user's own choice, fixed when the recording shortcut is pressed; nothing
/// here reads the frontmost App.
enum RefinementModeSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "a settings file with one saved Custom Mode migrates it to the first list entry",
            failures: &failures
        ) {
            let directory = try temporaryDirectory("legacy")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(
                #"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"custom","name":"邮件","prompt":"整理成邮件"},"savedCustomRefinement":{"kind":"custom","name":"邮件","prompt":"整理成邮件"},"launchAtLogin":false}}"#
                    .utf8)
            try legacy.write(to: fileURL)

            let first = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            let second = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            try expect(first.customRefinementModes.map(\.name) == ["邮件"])
            try expect(first.customRefinementModes.map(\.prompt) == ["整理成邮件"])
            let migrated = try require(first.customRefinementModes.first)
            try expect(
                first.refinementSelection == .custom(migrated.id),
                "the selected Custom Mode did not attach to the migrated entry")
            try expect(
                first == second, "two loads of one unmigrated file named different modes")
        }

        await runAsync(
            "a selected Custom Mode that differs from the saved one joins the list after it",
            failures: &failures
        ) {
            let directory = try temporaryDirectory("legacy-two")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let legacy = Data(
                #"{"schemaVersion":1,"settings":{"shortcut":{"kind":"functionKey"},"refinement":{"kind":"custom","name":"短句","prompt":"只清理重复"},"savedCustomRefinement":{"kind":"custom","name":"邮件","prompt":"整理成邮件"},"launchAtLogin":false}}"#
                    .utf8)
            try legacy.write(to: fileURL)

            let settings = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            try expect(settings.customRefinementModes.map(\.name) == ["邮件", "短句"])
            try expect(
                settings.refinementSelection == .custom(settings.customRefinementModes[1].id))
        }

        await runAsync(
            "the Custom Mode list stays readable by builds that predate it",
            failures: &failures
        ) {
            let directory = try temporaryDirectory("compat")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("settings.json")
            let store = VersionedLocalAppSettingsStore(fileURL: fileURL)
            let mail = try await store.saveCustomRefinementMode(
                CustomRefinementMode(name: "邮件", prompt: "整理成邮件")
            )
            .customRefinementModes[0]
            let notes = CustomRefinementMode(name: "笔记", prompt: "整理成要点")
            try await store.saveCustomRefinementMode(notes)
            try await store.updateRefinement(.custom(notes))

            // An older build reads `refinement` and `savedCustomRefinement` with
            // the `kind`/`name`/`prompt` keys and ignores keys it does not know.
            let document =
                try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as! [String: Any]
            try expect(document["schemaVersion"] as? Int == 1)
            let stored = document["settings"] as! [String: Any]
            let refinement = stored["refinement"] as! [String: Any]
            try expect(refinement["kind"] as? String == "custom")
            try expect(refinement["name"] as? String == "笔记")
            try expect(refinement["prompt"] as? String == "整理成要点")
            let saved = stored["savedCustomRefinement"] as! [String: Any]
            try expect(saved["name"] as? String == "笔记", "the mirror is not the selected mode")

            try await store.updateRefinement(.defaultSmooth)
            let builtIn =
                try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as! [String: Any]
            let mirror =
                (builtIn["settings"] as! [String: Any])["savedCustomRefinement"]
                as! [String: Any]
            try expect(
                mirror["name"] as? String == mail.name,
                "with a built-in mode selected the mirror is not the first Custom Mode")

            let restored = await VersionedLocalAppSettingsStore(fileURL: fileURL).load().settings
            try expect(restored.customRefinementModes.map(\.name) == ["邮件", "笔记"])
        }

        run(
            "the Custom Mode list saves, renames, reorders, and stops at its limit",
            failures: &failures
        ) {
            var settings = SpeakerAppSettings()
            let first = try settings.saveCustomRefinementMode(
                CustomRefinementMode(name: " 邮件 ", prompt: " 整理成邮件 "))
            try expect(first.name == "邮件" && first.prompt == "整理成邮件")
            settings.selectRefinement(.custom(first))
            var renamed = first
            renamed.name = "工作邮件"
            try settings.saveCustomRefinementMode(renamed)
            try expect(settings.customRefinementModes.map(\.name) == ["工作邮件"])
            try expect(
                settings.refinement.textRefinementMode
                    == .custom(name: "工作邮件", prompt: "整理成邮件"),
                "renaming the selected mode left the old name selected")

            for index in 2...CustomRefinementMode.maximumCount {
                try settings.saveCustomRefinementMode(
                    CustomRefinementMode(name: "模式\(index)", prompt: "提示\(index)"))
            }
            try expect(settings.customRefinementModes.count == CustomRefinementMode.maximumCount)
            do {
                try settings.saveCustomRefinementMode(
                    CustomRefinementMode(name: "多余", prompt: "提示"))
                throw SpecFailure(message: "an eleventh Custom Mode was accepted")
            } catch TextRefinementModeValidationError.tooManyCustomModes {}

            let last = settings.customRefinementModes[CustomRefinementMode.maximumCount - 1]
            settings.moveCustomRefinementMode(id: last.id, to: 0)
            try expect(settings.customRefinementModes.first == last)
            settings.moveCustomRefinementMode(id: last.id, to: 99)
            try expect(settings.customRefinementModes.last == last)
            try expect(settings.refinementSelection == .custom(first.id))
        }

        run(
            "deleting the selected Custom Mode falls back to Default Smoothing", failures: &failures
        ) {
            var settings = SpeakerAppSettings()
            let mail = try settings.saveCustomRefinementMode(
                CustomRefinementMode(name: "邮件", prompt: "整理成邮件"))
            let notes = try settings.saveCustomRefinementMode(
                CustomRefinementMode(name: "笔记", prompt: "整理成要点"))
            settings.selectRefinement(.custom(notes))

            settings.deleteCustomRefinementMode(id: mail.id)
            try expect(settings.refinementSelection == .custom(notes.id))
            settings.deleteCustomRefinementMode(id: notes.id)
            try expect(settings.refinement == .defaultSmooth)
            try expect(settings.customRefinementModes.isEmpty)
        }

        run(
            "the mode order is built-in modes then Custom Modes in list order",
            failures: &failures
        ) {
            let mail = CustomRefinementMode(name: "邮件", prompt: "整理成邮件")
            let notes = CustomRefinementMode(name: "笔记", prompt: "整理成要点")
            try expect(
                RefinementModeSelection.order(customModes: [mail, notes]) == [
                    .defaultSmooth, .conciseCleanup, .fullRewrite, .custom(mail.id),
                    .custom(notes.id),
                ])
        }

        await runAsync(
            "a mode chosen while a session records applies only to the next session",
            failures: &failures
        ) {
            let mail = CustomRefinementMode(name: "邮件", prompt: "整理成邮件")
            let notes = CustomRefinementMode(name: "笔记", prompt: "整理成要点")
            let configuration = VoiceInputConfigurationController(
                refinementMode: mail.textRefinementMode,
                refinementProvider: .defaultProfile(for: .deepSeek)
            )
            let refiner = DeepSeekRefinerFake(result: .success(.init(text: "整理后")))
            let processor = DefaultVoiceTextProcessor(
                configuration: configuration,
                transcriber: ContextualTranscriberFake(text: "原文"),
                refinement: OptionalTextRefinementPipeline(refiner: refiner)
            )
            let delivery = TextDeliveryFake(result: .delivered)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(.init(id: UUID(), applicationName: "TextEdit"))
                ),
                textProcessor: processor,
                delivery: delivery,
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )

            await sessions.dispatchPress()
            // The menu selects another mode mid-session.
            let nextMode = try require(
                RefinementModeSelection.custom(notes.id).refinementMode(
                    customModes: [mail, notes], promptOverrides: RefinementPromptOverrides()))
            try await configuration.selectRefinementMode(nextMode)
            await sessions.dispatchRelease()
            let delivered1 = await eventually(before: .seconds(5)) {
                await delivery.deliveredTexts.count == 1
            }
            try expect(delivered1, "the first session did not deliver")

            await sessions.dispatchPress()
            await sessions.dispatchRelease()
            let delivered2 = await eventually(before: .seconds(5)) {
                await delivery.deliveredTexts.count == 2
            }
            try expect(delivered2, "the next session did not deliver")
            await sessions.shutdown()

            let modes = await refiner.modes
            try expect(
                modes == [mail.textRefinementMode, notes.textRefinementMode],
                "the switch reached the session that was already recording")
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SpecFailure(message: "expected a value") }
        return value
    }

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-refinement-modes-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
