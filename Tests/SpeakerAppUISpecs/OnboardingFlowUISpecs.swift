import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport
import SwiftUI

enum OnboardingFlowUISpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "onboarding advances explicitly through permissions key verification and keyboard tutorial",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "onboarding-flow-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = OnboardingDoubaoService()
            let model = DoubaoSettingsModel(
                service: service,
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json"))
            )
            await model.refresh()
            let access = PermissionAccessFake(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined))
            let permissions = PermissionModel(access: access)
            var completions = 0
            let hosting = NSHostingView(
                rootView: SpeakerOnboardingView(
                    permissions: permissions,
                    doubao: model,
                    requestPermission: { await permissions.request($0) },
                    refreshPermissions: { permissions.refresh() },
                    announce: { _ in },
                    shortcutName: { "⌃⇧Space" },
                    completion: { completions += 1 }
                ))
            let window = OnboardingWindowFactory.make(
                visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 900),
                contentView: hosting
            )
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            let shown = await eventually(before: .seconds(2)) {
                pump(hosting)
                return button("下一步", in: hosting) != nil
            }
            try expect(shown, "Next absent from AX tree")
            try expect(button("下一步", in: hosting)?.isAccessibilityEnabled() == false)
            try expect(button("下一步", in: hosting)?.accessibilityPerformPress() == false)
            try expect(access.requestedPermissions.isEmpty)
            try capture(hosting, name: "onboarding-1-permissions")
            try captureSmall(hosting, window: window, name: "onboarding-1-permissions-small")
            access.snapshot = .init(accessibility: .granted, microphone: .granted)
            permissions.refresh()
            let allowed = await eventually(before: .seconds(1)) {
                pump(hosting)
                return button("下一步", in: hosting)?.isAccessibilityEnabled() == true
            }
            try expect(allowed)
            try expect(button("下一步", in: hosting)?.accessibilityPerformPress() == true)
            let keyShown = await eventually(before: .seconds(1)) {
                pump(hosting)
                return !secureFields(in: hosting).isEmpty
            }
            try expect(keyShown)
            try expect(button("下一步", in: hosting)?.isAccessibilityEnabled() == false)
            try capture(hosting, name: "onboarding-2-api-key")
            try captureSmall(hosting, window: window, name: "onboarding-2-api-key-small")
            model.apiKeyDraft = "synthetic-onboarding-key"
            await model.save()
            pump(hosting)
            try expect(button("下一步", in: hosting)?.isAccessibilityEnabled() == false)
            let checksBeforeAction = await service.checkCount
            try expect(
                checksBeforeAction == 0,
                "onboarding checked the provider without an explicit action")
            model.checkConnection()
            let verified = await eventually(before: .seconds(1)) {
                pump(hosting)
                return button("下一步", in: hosting)?.isAccessibilityEnabled() == true
            }
            try expect(verified)
            try expect(
                button("开始使用 Speaker", in: hosting) == nil,
                "verification advanced the step automatically")
            try expect(button("下一步", in: hosting)?.accessibilityPerformPress() == true)
            let tutorialShown = await eventually(before: .seconds(1)) {
                pump(hosting)
                return button("开始使用 Speaker", in: hosting) != nil
            }
            try expect(tutorialShown)
            try capture(hosting, name: "onboarding-3-shortcut")
            window.contentMinSize = CGSize(width: 360, height: 360)
            window.minSize = CGSize(width: 360, height: 360)
            window.setContentSize(CGSize(width: 400, height: 480))
            pump(hosting)
            try capture(hosting, name: "onboarding-3-shortcut-small")
            try expect(button("开始使用 Speaker", in: hosting)?.isAccessibilityEnabled() == true)
            try expect(button("上一步", in: hosting)?.accessibilityPerformPress() == true)
            let returned = await eventually(before: .seconds(1)) {
                pump(hosting)
                return !secureFields(in: hosting).isEmpty
            }
            try expect(returned)
            await model.delete()
            pump(hosting)
            try expect(button("下一步", in: hosting)?.isAccessibilityEnabled() == false)
            try expect(completions == 0)
            try expect(button("稍后配置", in: hosting)?.accessibilityPerformPress() == true)
            try expect(completions == 1)
            await model.shutdown()
        }
        await reviewGuide(failures: &failures)
    }

    @MainActor
    private static func reviewGuide(failures: inout [String]) async {
        await runAsync(
            "onboarding review reaches the keyboard tutorial without another provider check",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "onboarding-review-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = OnboardingDoubaoService()
            let model = DoubaoSettingsModel(
                service: service,
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")))
            model.apiKeyDraft = "synthetic-existing-key"
            await model.save()
            let permissions = PermissionModel(
                access: PermissionAccessFake(
                    snapshot: .init(accessibility: .denied, microphone: .denied)))
            var completed = false
            let hosting = NSHostingView(
                rootView: SpeakerOnboardingView(
                    permissions: permissions, doubao: model, requestPermission: { _ in },
                    refreshPermissions: {}, announce: { _ in }, mode: .review,
                    completion: { completed = true }))
            let window = OnboardingWindowFactory.make(
                visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 900), contentView: hosting)
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.close()
            }
            let ready = await eventually(before: .seconds(1)) {
                pump(hosting)
                return button("下一步", in: hosting)?.isAccessibilityEnabled() == true
            }
            try expect(ready)
            try expect(button("下一步", in: hosting)?.accessibilityPerformPress() == true)
            let keyStep = await eventually(before: .seconds(1)) {
                pump(hosting)
                return !secureFields(in: hosting).isEmpty
            }
            try expect(keyStep)
            try expect(button("下一步", in: hosting)?.accessibilityPerformPress() == true)
            let tutorial = await eventually(before: .seconds(1)) {
                pump(hosting)
                return button("完成", in: hosting)?.isAccessibilityEnabled() == true
            }
            try expect(tutorial)
            let checkCount = await service.checkCount
            try expect(checkCount == 0)
            try expect(model.status == .configured)
            try expect(!permissions.snapshot.allGranted)
            try expect(button("完成", in: hosting)?.accessibilityPerformPress() == true)
            try expect(completed)
            await model.shutdown()
        }
    }

    @MainActor
    private static func pump(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private static func button(_ title: String, in view: NSView) -> (any NSAccessibilityProtocol)? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: AnyObject) -> (any NSAccessibilityProtocol)? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let element = object as? any NSAccessibilityProtocol {
                if element.accessibilityRole() == .button, element.accessibilityLabel() == title {
                    return element
                }
                for child in element.accessibilityChildren() ?? [] {
                    if let match = find(child as AnyObject) { return match }
                }
            }
            if let view = object as? NSView {
                for child in view.subviews {
                    if let match = find(child) { return match }
                }
            }
            return nil
        }
        return find(view)
    }

    @MainActor
    private static func secureFields(in view: NSView) -> [NSSecureTextField] {
        (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { secureFields(in: $0) }
    }

    @MainActor
    private static func captureSmall(_ view: NSView, window: NSWindow, name: String) throws {
        guard ProcessInfo.processInfo.environment["SPEAKER_ONBOARDING_UI_ARTIFACTS"] != nil else {
            return
        }
        let size = window.contentView?.frame.size ?? CGSize(width: 640, height: 620)
        window.contentMinSize = CGSize(width: 360, height: 360)
        window.minSize = CGSize(width: 360, height: 360)
        window.setContentSize(CGSize(width: 400, height: 480))
        pump(view)
        try capture(view, name: name)
        window.setContentSize(size)
        pump(view)
    }

    @MainActor
    private static func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SPEAKER_ONBOARDING_UI_ARTIFACTS"]
        else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let window = view.window else {
            throw SpecFailure(message: "onboarding window unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x", "-l", String(window.windowNumber),
            directory.appendingPathComponent(name + ".png").path,
        ]
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "onboarding window capture failed")
    }
}

private actor OnboardingDoubaoService: DoubaoSettingsServicing {
    private var hasKey = false
    private(set) var checkCount = 0
    func setResource(_ resource: DoubaoStreamingResource) {}
    func hasAPIKey() -> Bool { hasKey }
    func saveAPIKey(_ apiKey: String) { hasKey = !apiKey.isEmpty }
    func deleteAPIKey() { hasKey = false }
    func checkConnection() -> String? {
        checkCount += 1
        return "onboarding-ui-request"
    }
}
