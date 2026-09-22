import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport
import SwiftUI

enum APIKeySettingsUISpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "recognition provider model region and independent key controls work at narrow width",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "asr-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let credentials = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("keys.json"))
            try await credentials.save(apiKey: "text-refinement-only", for: .openAI)
            let settings = VersionedLocalAppSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json"))
            let model = SpeechRecognitionSettingsModel(
                credentials: credentials, configuration: VoiceInputConfigurationController(),
                settingsStore: settings)
            let doubao = DoubaoSettingsModel(
                service: CredentialedDoubaoTranscriber(credentials: credentials),
                settingsStore: settings)
            await model.load()
            let hosting = NSHostingView(
                rootView: SpeechRecognitionSettingsCard(model: model, doubao: doubao).padding(12)
                    .frame(width: 400))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            let rendered = await eventually(before: .seconds(2)) {
                pumpUI()
                return !popupButtons(in: hosting).isEmpty
            }
            try expect(rendered, "recognition provider picker did not render")
            try select("OpenAI 语音识别", in: hosting)
            let switched = await eventually(before: .seconds(2)) {
                pumpUI()
                return model.selectedProvider == .openAI
                    && !model.isMutating
                    && popupButtons(in: hosting).contains {
                        $0.itemTitles.contains("gpt-4o-transcribe")
                    }
            }
            try expect(
                switched && !model.hasStoredKey,
                "OpenAI provider switch failed or borrowed refinement credential")
            try select("gpt-4o-transcribe", in: hosting)
            let selected = await eventually(before: .seconds(2)) {
                model.selectedProfile.model == "gpt-4o-transcribe" && !model.isMutating
            }
            try expect(selected, "complete recording model selection failed")
            model.apiKeyDraft = "speech-recognition-only"
            let saveVisible = await eventually(before: .seconds(2)) {
                pumpUI()
                return buttons(named: "保存 Key", in: hosting).contains {
                    $0.isAccessibilityEnabled()
                }
            }
            try expect(saveVisible, "recognition key save action not enabled")
            try expect(
                buttons(named: "保存 Key", in: hosting).first?.accessibilityPerformPress() == true)
            let saved = await eventually(before: .seconds(2)) {
                model.hasStoredKey && model.apiKeyDraft.isEmpty
            }
            try expect(saved, "recognition key save did not finish")
            try expect(
                secureFields(in: hosting).allSatisfy {
                    !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
                }, "recognition credential editor clipped at narrow width")
            try expect(hosting.frame.width <= 400)
            try expect(
                buttons(named: "检查连接", in: hosting).isEmpty, "ASR implied a free validation request"
            )
            let textKey = try await credentials.apiKey(for: .openAI)
            let audioKey = try await credentials.apiKey(for: .openAITranscription)
            try expect(textKey == "text-refinement-only" && audioKey == "speech-recognition-only")
            try select("流式识别（边录边传）", in: hosting)
            let streaming = await eventually(before: .seconds(2)) {
                pumpUI()
                return model.selectedProfile.method == .streaming
                    && !model.isMutating
                    && popupButtons(in: hosting).contains {
                        $0.itemTitles.contains("gpt-live-transcribe")
                    }
            }
            try expect(
                streaming && model.hasStoredKey,
                "OpenAI streaming controls or saved credential missing")
            try expect(
                !popupButtons(in: hosting).contains {
                    $0.itemTitles.contains("gpt-4o-transcribe")
                })
            try select("整段识别（录完上传）", in: hosting)
            let completeRecording = await eventually(before: .seconds(2)) {
                pumpUI()
                return model.selectedProfile.method == .completeRecording
                    && !model.isMutating
                    && popupButtons(in: hosting).contains {
                        $0.itemTitles.contains("gpt-transcribe")
                    }
            }
            try expect(
                completeRecording && model.hasStoredKey,
                "OpenAI complete recording controls or saved credential missing")
            try select("阿里千问语音识别", in: hosting)
            let qwen = await eventually(before: .seconds(2)) {
                pumpUI()
                return !model.isMutating
                    && popupButtons(in: hosting).contains { $0.itemTitles.contains("新加坡") }
            }
            try expect(qwen, "Qwen region picker did not render")
            try select("新加坡", in: hosting)
            let region = await eventually(before: .seconds(2)) {
                pumpUI()
                return model.selectedProfile.region == .singapore && !model.isMutating
                    && popupButtons(in: hosting).contains {
                        $0.titleOfSelectedItem == "新加坡" && $0.isEnabled
                    }
                    && popupButtons(in: hosting).contains {
                        $0.itemTitles.contains("流式识别（边录边传）") && $0.isEnabled
                    }
            }
            try expect(
                region && !model.hasStoredKey,
                "Qwen region switch failed or borrowed Beijing credential")
            try select("流式识别（边录边传）", in: hosting)
            let qwenStreaming = await eventually(before: .seconds(2)) {
                pumpUI()
                return model.selectedProfile.method == .streaming
                    && !model.isMutating
                    && popupButtons(in: hosting).contains {
                        $0.itemTitles.contains("qwen3-asr-flash-realtime")
                    }
            }
            try expect(
                qwenStreaming && model.selectedProfile.region == .singapore,
                "Qwen streaming controls or retained region missing")

            await model.shutdown()
            await doubao.shutdown()
        }

        await runAsync(
            "saved provider keys remain editable and replace without deletion", failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "speaker-key-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let credentials = LocalFileProviderCredentialStore(
                fileURL: directory.appendingPathComponent("keys.json"))
            let settings = VersionedLocalAppSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json"))
            let doubao = DoubaoSettingsModel(
                service: CredentialedDoubaoTranscriber(credentials: credentials),
                settingsStore: settings)
            let refinement = RefinementSettingsModel(
                service: CredentialedTextRefiner(credentials: credentials),
                configuration: VoiceInputConfigurationController(), settingsStore: settings)
            doubao.apiKeyDraft = "synthetic-doubao-old"
            await doubao.save()
            refinement.apiKeyDraft = "synthetic-deepseek-old"
            await refinement.saveAPIKey()
            let hosting = NSHostingView(
                rootView: APIKeySettingsPage(
                    doubao: doubao, refinement: refinement,
                    recognition: SpeechRecognitionSettingsModel(
                        credentials: credentials,
                        configuration: VoiceInputConfigurationController(), settingsStore: settings)
                ))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 850), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            let visible = await eventually(before: .seconds(2)) {
                pumpUI()
                hosting.layoutSubtreeIfNeeded()
                return secureFields(in: hosting).filter {
                    $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
                }.count == 2
            }
            try expect(visible, "saved keys hid their replacement fields")
            doubao.apiKeyDraft = "synthetic-doubao-new"
            refinement.apiKeyDraft = "synthetic-deepseek-new"
            let saveButtonsVisible = await eventually(before: .seconds(2)) {
                pumpUI()
                return buttons(named: "保存更换", in: hosting).filter { $0.isAccessibilityEnabled() }
                    .count == 2
            }
            try expect(
                saveButtonsVisible, "replacement actions were missing beside the secure inputs")
            for button in buttons(named: "保存更换", in: hosting) {
                try expect(
                    button.accessibilityPerformPress(), "replacement action could not be activated")
            }
            let saved = await eventually(before: .seconds(2)) {
                let doubaoKey = try? await credentials.apiKey(for: .doubao)
                let deepseekKey = try? await credentials.apiKey(for: .deepSeek)
                return doubaoKey == "synthetic-doubao-new"
                    && deepseekKey == "synthetic-deepseek-new"
            }
            try expect(saved, "replacement actions did not replace both stored keys")
            let doubaoKey = try await credentials.apiKey(for: .doubao)
            let deepseekKey = try await credentials.apiKey(for: .deepSeek)
            try expect(doubaoKey == "synthetic-doubao-new")
            try expect(deepseekKey == "synthetic-deepseek-new")
            try expect(
                doubao.apiKeyDraft.isEmpty && refinement.apiKeyDraft.isEmpty,
                "save did not clear drafts")
            let deletionActions = buttons(named: "删除 Key", in: hosting)
            try expect(
                deletionActions.count == 2,
                "expected two delete actions, got \(deletionActions.count)")
            try expect(
                deletionActions[0].accessibilityPerformPress(),
                "delete source action refused AX press")
            let cancelVisible = await eventually(before: .seconds(2)) {
                pumpUI()
                return dialogButtons(named: "取消", excluding: hosting).count == 1
            }
            try expect(cancelVisible, "delete confirmation did not expose its cancel action")
            try expect(
                press(dialogButtons(named: "取消", excluding: hosting)[0]),
                "native cancel refused press")
            let cancelFinished = await eventually(before: .seconds(2)) {
                pumpUI()
                return dialogButtons(named: "取消", excluding: hosting).isEmpty
            }
            try expect(cancelFinished, "cancelled confirmation stayed visible")
            let retainedAfterCancel = try await credentials.apiKey(for: .doubao)
            try expect(
                retainedAfterCancel == "synthetic-doubao-new", "cancelling deletion removed the key"
            )
            for _ in 0..<2 {
                guard let deletion = buttons(named: "删除 Key", in: hosting).first else {
                    throw SpecFailure(message: "stored key lost its delete action")
                }
                try expect(
                    deletion.accessibilityPerformPress(),
                    "confirmed delete source action refused AX press")
                let confirmationVisible = await eventually(before: .seconds(2)) {
                    pumpUI()
                    return dialogButtons(named: "删除 Key", excluding: hosting).count == 1
                }
                try expect(
                    confirmationVisible, "delete confirmation did not expose its destructive action"
                )
                try expect(
                    press(dialogButtons(named: "删除 Key", excluding: hosting)[0]),
                    "native delete refused press")
                let originalCount = buttons(named: "删除 Key", in: hosting).count
                let deleted = await eventually(before: .seconds(2)) {
                    pumpUI()
                    return buttons(named: "删除 Key", in: hosting).count < originalCount
                }
                try expect(deleted, "confirmed deletion did not clear the stored key")
            }
            let deletedDoubao = try await credentials.apiKey(for: .doubao)
            let deletedDeepseek = try await credentials.apiKey(for: .deepSeek)
            try expect(deletedDoubao == nil && deletedDeepseek == nil)
            await doubao.shutdown()
            await refinement.shutdown()
        }
    }

    @MainActor
    private static func popupButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popupButtons(in: $0) }
    }

    @MainActor
    private static func select(_ title: String, in view: NSView) throws {
        guard let control = popupButtons(in: view).first(where: { $0.itemTitles.contains(title) }),
            let index = control.itemTitles.firstIndex(of: title)
        else { throw SpecFailure(message: "picker option missing: \(title)") }
        control.menu?.performActionForItem(at: index)
    }

    @MainActor
    private static func press(_ button: any NSAccessibilityProtocol) -> Bool {
        if let button = button as? NSButton {
            guard button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        if let cell = button as? NSButtonCell, let control = cell.controlView as? NSButton {
            guard control.isEnabled else { return false }
            control.performClick(nil)
            return true
        }
        return button.accessibilityPerformPress()
    }

    @MainActor
    private static func dialogButtons(named title: String, excluding root: NSView)
        -> [any NSAccessibilityProtocol]
    {
        let existing = Set(
            buttons(named: title, in: root).map { ObjectIdentifier($0 as AnyObject) })
        return NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
            .flatMap { buttons(named: title, in: $0) }
            .filter { !existing.contains(ObjectIdentifier($0 as AnyObject)) }
    }

    @MainActor
    private static func buttons(named title: String, in root: NSView)
        -> [any NSAccessibilityProtocol]
    {
        var visited = Set<ObjectIdentifier>()
        var matches: [any NSAccessibilityProtocol] = []
        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let element = object as? any NSAccessibilityProtocol {
                if element.accessibilityRole() == .button,
                    element.accessibilityLabel() == title || element.accessibilityTitle() == title
                {
                    matches.append(element)
                }
                for child in element.accessibilityChildren() ?? [] { visit(child as AnyObject) }
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root)
        return matches
    }

    @MainActor
    private static func secureFields(in view: NSView) -> [NSSecureTextField] {
        (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { secureFields(in: $0) }
    }
    @MainActor
    private static func pumpUI() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

}
