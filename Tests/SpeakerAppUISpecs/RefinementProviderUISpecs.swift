import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport
import SwiftUI

enum RefinementProviderUISpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "refinement provider model and custom endpoint controls work at narrow width",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "speaker-provider-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = RefinementSettingsModel(
                service: CredentialedTextRefiner(
                    credentials: LocalFileProviderCredentialStore(
                        fileURL: directory.appendingPathComponent("credentials.json"))),
                configuration: VoiceInputConfigurationController(),
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")))
            await model.load()
            let hosting = NSHostingView(
                rootView: RefinementProviderSettingsCard(model: model).padding(12).frame(width: 400)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 650), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            let rendered = await eventually(before: .seconds(2)) {
                pump(hosting)
                return controls(NSPopUpButton.self, in: hosting).count == 2
            }
            try expect(rendered, "provider and model selectors were not rendered")
            try capture(window, name: "deepseek-narrow")
            guard
                let provider = controls(NSPopUpButton.self, in: hosting).first(where: {
                    $0.itemTitles.contains("OpenAI")
                }),
                let openAIIndex = provider.itemTitles.firstIndex(of: "OpenAI")
            else { throw SpecFailure(message: "built-in provider selector missing") }
            try expect(provider.itemTitles == ["DeepSeek", "OpenAI", "Kimi", "GLM", "自定义"])
            provider.menu?.performActionForItem(at: openAIIndex)
            let switched = await eventually(before: .seconds(2)) {
                pump(hosting)
                return model.selectedProvider == .openAI
                    && controls(NSPopUpButton.self, in: hosting).contains {
                        $0.itemTitles.contains("gpt-5.6-terra")
                    }
            }
            try expect(switched, "provider action did not update model options")
            try expect(model.selectedProfile.modelID == "gpt-5.6-luna")
            try expect(
                controls(NSPopUpButton.self, in: hosting).contains {
                    $0.itemTitles.contains("gpt-5.6-luna（推荐）")
                })
            guard
                let models = controls(NSPopUpButton.self, in: hosting).first(where: {
                    $0.itemTitles.contains("gpt-5.6-terra")
                }),
                let modelIndex = models.itemTitles.firstIndex(of: "gpt-5.6-terra")
            else { throw SpecFailure(message: "OpenAI models missing") }
            models.menu?.performActionForItem(at: modelIndex)
            let saved = await eventually(before: .seconds(2)) {
                model.selectedProfile.modelID == "gpt-5.6-terra"
            }
            try expect(saved, "model picker action was not persisted")
            try capture(window, name: "openai-narrow")
            guard let customIndex = provider.itemTitles.firstIndex(of: "自定义") else {
                throw SpecFailure(message: "custom provider missing")
            }
            provider.menu?.performActionForItem(at: customIndex)
            let custom = await eventually(before: .seconds(2)) {
                pump(hosting)
                return model.selectedProvider == .custom && editableFields(in: hosting).count == 3
            }
            let fieldsSeen = fieldSummary(in: hosting)
            try expect(
                custom,
                "custom provider did not expose URL, model ID and secure Key fields: provider \(model.selectedProvider), popup \(provider.titleOfSelectedItem ?? "-") in window \(provider.window != nil), fields [\(fieldsSeen)]"
            )
            let fields = editableFields(in: hosting)
            try expect(
                fields.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty },
                "custom fields were clipped")
            try expect(hosting.frame.width <= 400, "provider card exceeded narrow width")
            try expect(
                accessibilityLabels(in: hosting).contains("API Base URL"),
                "Base URL accessibility label missing: \(accessibilityLabels(in: hosting))")
            try expect(
                accessibilityLabels(in: hosting).contains("模型 ID"),
                "model ID accessibility label missing")
            guard let urlField = fields.first(where: { $0.accessibilityLabel() == "API Base URL" }),
                let modelField = fields.first(where: { $0.accessibilityLabel() == "模型 ID" })
            else { throw SpecFailure(message: "custom native inputs missing") }
            try edit(urlField, value: "https://example.invalid/v1")
            try edit(modelField, value: "custom-test-model")
            window.endEditing(for: nil)
            try expect(
                model.baseURLDraft == "https://example.invalid/v1"
                    && model.modelIDDraft == "custom-test-model",
                "native input actions did not update profile drafts")
            let saveVisible = await eventually(before: .seconds(2)) {
                pump(hosting)
                return controls(NSView.self, in: hosting).contains {
                    $0.accessibilityLabel() == "保存模型配置" && $0.isAccessibilityEnabled()
                }
            }
            try expect(saveVisible, "custom configuration save action missing")
            guard
                let save = controls(NSView.self, in: hosting).first(where: {
                    $0.accessibilityLabel() == "保存模型配置" && $0.isAccessibilityEnabled()
                })
            else { throw SpecFailure(message: "custom save disappeared") }
            try expect(
                save.accessibilityPerformPress(), "custom save accessibility action refused press")
            let configured = await eventually(before: .seconds(2)) {
                model.hasValidProfile && model.selectedProfile.modelID == "custom-test-model"
            }
            try expect(configured, "native custom save did not persist configuration")
            try expect(!model.isCheckingConnection && !model.isConnectionVerified)
            pump(hosting)
            try capture(window, name: "custom-narrow")
            try await verifyControlAppearances(model)
            await model.shutdown()
        }
    }

    @MainActor
    private static func verifyControlAppearances(_ model: RefinementSettingsModel) async throws {
        for (name, scheme, style, appearance) in [
            (
                "glass-light", ColorScheme.light, AdaptiveGlassSurfaceStyle.liquidGlass,
                NSAppearance.Name.aqua
            ),
            ("glass-dark", .dark, .liquidGlass, .darkAqua),
            ("glass-contrast", .light, .liquidGlass, .accessibilityHighContrastAqua),
            ("material-fallback", .light, .systemMaterial, .aqua),
            ("opaque-fallback", .dark, .opaque, .accessibilityHighContrastDarkAqua),
        ] {
            model.apiKeyDraft = ""
            let hosting = NSHostingView(
                rootView: RefinementProviderSettingsCard(model: model)
                    .padding(12).frame(width: 400)
                    .environment(\.colorScheme, scheme)
                    .environment(\.adaptiveGlassSurfaceStyleOverride, style))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 750),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.appearance = NSAppearance(named: appearance)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }
            let rendered = await eventually(before: .seconds(2)) {
                pump(hosting)
                return editableFields(in: hosting).count == 3
            }
            try expect(rendered, "\(name) lost editable fields")
            guard let key = controls(NSSecureTextField.self, in: hosting).first else {
                throw SpecFailure(message: "\(name) lost secure input")
            }
            try expect(window.makeFirstResponder(key), "\(name) refused input focus")
            guard let editor = key.currentEditor() as? NSTextView else {
                throw SpecFailure(message: "\(name) has no native text editor")
            }
            editor.insertText(
                "synthetic-glass-key", replacementRange: NSRange(location: 0, length: 0))
            let edited = await eventually(before: .seconds(2)) {
                pump(hosting)
                return model.apiKeyDraft == "synthetic-glass-key"
            }
            try expect(edited, "\(name) did not update the Key draft through native editing")
            try expect(!key.visibleRect.isEmpty, "\(name) clipped its secure input")
            let saveEnabled = await eventually(before: .seconds(2)) {
                pump(hosting)
                return controls(NSView.self, in: hosting).contains {
                    $0.accessibilityLabel() == "保存 Key" && $0.isAccessibilityEnabled()
                }
            }
            try expect(saveEnabled, "\(name) left the save action disabled after editing")
            if ProcessInfo.processInfo.environment["SPEAKER_REFINEMENT_PROVIDER_UI_ARTIFACTS"]
                != nil
            {
                activateForCapture()
            }
            try capture(window, name: name)
            window.endEditing(for: nil)
        }
        model.apiKeyDraft = ""
    }

    @MainActor
    private static func activateForCapture() {
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    private static func edit(_ field: NSTextField, value: String) throws {
        field.stringValue = value
        guard let action = field.action else {
            throw SpecFailure(message: "native field has no commit action")
        }
        try expect(
            NSApp.sendAction(action, to: field.target, from: field),
            "native field commit action failed")
    }

    @MainActor
    private static func accessibilityLabels(in root: NSView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let element = object as? any NSAccessibilityProtocol {
                if let label = element.accessibilityLabel() { labels.append(label) }
                for child in element.accessibilityChildren() ?? [] { visit(child as AnyObject) }
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root)
        return labels
    }

    @MainActor
    private static func capture(_ window: NSWindow, name: String) throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "SPEAKER_REFINEMENT_PROVIDER_UI_ARTIFACTS"]
        else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x", "-l", String(window.windowNumber),
            directory.appendingPathComponent(name + ".png").path,
        ]
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0)
    }

    @MainActor
    private static func controls<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        let own = (root as? T).map { [$0] } ?? []
        return own + root.subviews.flatMap { controls(type, in: $0) }
    }

    @MainActor
    private static func editableFields(in root: NSView) -> [NSTextField] {
        controls(NSTextField.self, in: root).filter(\.isEditable)
    }

    /// Every editable field with its label and visibility, so a failure on a
    /// CI runner shows what the card rendered.
    @MainActor
    private static func fieldSummary(in root: NSView) -> String {
        editableFields(in: root).map { field in
            let label = field.accessibilityLabel() ?? field.placeholderString ?? "-"
            return "\(type(of: field)) \(label) hidden=\(field.isHiddenOrHasHiddenAncestor)"
        }.joined(separator: "; ")
    }

    @MainActor
    private static func pump(_ root: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        root.layoutSubtreeIfNeeded()
    }
}
