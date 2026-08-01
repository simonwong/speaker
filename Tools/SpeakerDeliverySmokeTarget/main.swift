import AppKit
import Foundation

private struct SmokeTargetConfiguration {
    let readyURL: URL
    let receiptURL: URL
    let expectedText: String
    let waitsForExternalActivation: Bool

    init?(arguments: [String]) {
        guard let readyPath = Self.value(
            after: "--speaker-smoke-ready",
            in: arguments
        ), let receiptPath = Self.value(
            after: "--speaker-smoke-receipt",
            in: arguments
        ), let expectedText = Self.value(
            after: "--speaker-smoke-expected",
            in: arguments
        ), !expectedText.isEmpty
        else { return nil }
        readyURL = URL(fileURLWithPath: readyPath)
        receiptURL = URL(fileURLWithPath: receiptPath)
        self.expectedText = expectedText
        waitsForExternalActivation = arguments.contains(
            "--speaker-smoke-wait-for-activation"
        )
    }

    private static func value(
        after option: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
private final class SmokeTargetDelegate: NSObject,
    NSApplicationDelegate, NSTextViewDelegate {
    private let configuration: SmokeTargetConfiguration
    private var window: NSWindow?
    private var textView: NSTextView?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(configuration: SmokeTargetConfiguration) {
        self.configuration = configuration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180)
        )
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.string = ""

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 180)
        )
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speaker Delivery Smoke Target"
        window.contentView = scrollView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        self.window = window
        self.textView = textView

        if configuration.waitsForExternalActivation {
            try? Self.write(
                [
                    "result=READY",
                    "processID=\(getpid())",
                ],
                to: configuration.readyURL
            )
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            beginReadinessCheck()
        }
        beginTimeout()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    func textDidChange(_ notification: Notification) {
        guard textView?.string == configuration.expectedText else { return }
        finish(
            result: [
                "result=PASS",
                "stage=observedText",
                "observedLength=\(configuration.expectedText.count)",
            ]
        )
    }

    private func beginReadinessCheck() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<100 {
                if NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == getpid(),
                   window?.firstResponder === textView
                {
                    try? Self.write(
                        [
                            "result=READY",
                            "processID=\(getpid())",
                        ],
                        to: configuration.readyURL
                    )
                    return
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(textView)
                try? await Task.sleep(for: .milliseconds(50))
            }
            finish(
                result: [
                    "result=FAIL",
                    "stage=activation",
                    "reason=targetNotFrontmost",
                ]
            )
        }
    }

    private func beginTimeout() {
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let timeout: Duration = self.configuration.waitsForExternalActivation
                ? .seconds(10)
                : .seconds(3)
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.finish(
                result: [
                    "result=FAIL",
                    "stage=observedText",
                    "reason=expectedTextNotObserved",
                    "observedLength=\(self.textView?.string.count ?? 0)",
                ]
            )
        }
    }

    private func finish(result: [String]) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        try? Self.write(result, to: configuration.receiptURL)
        NSApplication.shared.terminate(nil)
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

@main
private enum SpeakerDeliverySmokeTargetMain {
    @MainActor
    static func main() {
        guard let configuration = SmokeTargetConfiguration(
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            FileHandle.standardError.write(
                Data("Invalid smoke-target arguments\n".utf8)
            )
            exit(64)
        }
        let application = NSApplication.shared
        let delegate = SmokeTargetDelegate(configuration: configuration)
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
