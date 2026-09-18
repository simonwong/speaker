import AppKit
import SpeakerAppFeatures
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport
import SwiftUI

enum PendingCopyRecoveryUISpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync(
            "pending copy HUD reports failure and retries the complete result", failures: &failures
        ) {
            let text = String(repeating: "这是需要手动复制的文字。", count: 20)
            let clipboard = ClipboardFake(succeeds: false)
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: text),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: clipboard,
                history: SessionHistoryFake())
            let experience = VoiceInputExperience(sessions: sessions, announce: { _ in })
            experience.start()
            let presenter = VoiceInputPanelPresenter(reduceMotion: { true }) { presentation in
                VoiceInputHUD(
                    presentation: presentation, performAction: experience.perform,
                    routeEffect: { _ in })
            }
            defer { presenter.stop() }
            do {
                await sessions.send(.pressed)
                await sessions.send(.released)
                let pending = await eventually(before: .seconds(2)) {
                    experience.state.menu.copyRetainedTextAction != nil
                }
                try expect(pending, "the result never became available to copy")
                presenter.present(experience.state.overlay)
                try await Task.sleep(for: .milliseconds(80))
                try expect(presenter.pressAccessibilityButton(label: "复制"))
                let failed = await eventually(before: .seconds(2)) {
                    experience.state.diagnosticCode == "pendingCopy.clipboardFailed"
                }
                try expect(failed)
                presenter.present(experience.state.overlay)
                try await Task.sleep(for: .milliseconds(80))
                if let path = ProcessInfo.processInfo.environment["SPEAKER_HUD_CAPTURE_DIR"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    guard
                        let window = NSApp.windows.first(where: {
                            $0.isVisible && $0.frame.size == presenter.evidence.windowSize
                        })
                    else { throw SpecFailure(message: "pending-copy window is unavailable") }
                    try await Task.sleep(for: .milliseconds(300))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = [
                        "-x", "-l", String(window.windowNumber),
                        directory.appendingPathComponent("copy-failed.png").path,
                    ]
                    try capture.run()
                    capture.waitUntilExit()
                    try expect(capture.terminationStatus == 0)
                }
                try expect(
                    presenter.accessibilityButtonEvidence.contains { $0.label == "重试复制" },
                    "copy failure left the HUD without a retry control")
                try expect(presenter.evidence.windowSize == CGSize(width: 370, height: 44))
                try expect(!presenter.evidence.isKeyWindow)
                await clipboard.setSucceeds(true)
                try expect(presenter.pressAccessibilityButton(label: "重试复制"))
                let copied = await eventually(before: .seconds(2)) {
                    experience.state.overlay == .hidden
                }
                try expect(copied, "retry did not finish the pending result")
                let copies = await clipboard.copiedTexts
                try expect(copies == [text, text], "retry lost or truncated the retained text")
                await experience.shutdown()
            } catch {
                await experience.shutdown()
                throw error
            }
        }
    }
}
