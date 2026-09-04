import AppKit
import ApplicationServices
import Foundation
import SpeakerAppFeatures
import SpeakerCore

@MainActor
enum DeliverySmokeRunner {
    static func request(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> DeliverySmokeLaunchRequest? {
        let signingMode = SpeakerBuildInfoReader.main.signingMode
        let request = DeliverySmokeLaunchRequest(
            arguments: arguments,
            signingMode: signingMode
        )
        return request
    }

    static func run(_ request: DeliverySmokeLaunchRequest) async {
        guard AXIsProcessTrusted() else {
            try? writeOwnerOnly(
                [
                    "result=FAIL",
                    "stage=capture",
                    "reason=accessibilityPermissionMissing",
                    "accessibilityTrusted=false",
                    "frontmostPID=\((NSWorkspace.shared.frontmostApplication?.processIdentifier).map(String.init) ?? "none")",
                    "targetPID=\(request.processID.map(String.init) ?? "frontmost")",
                    "",
                ].joined(separator: "\n"),
                to: request.reportURL
            )
            NSApp.terminate(nil)
            return
        }
        // Construct the production target tracker before activating the smoke
        // target. This exercises the long-lived app-switch lifecycle used by
        // the installed menu-bar app instead of a freshly seeded tracker.
        let targets = AccessibilityInputTargets()
        guard await waitForTriggerIfNeeded(request) else {
            NSApp.terminate(nil)
            return
        }

        let initialFrontmostProcessID = NSWorkspace.shared
            .frontmostApplication?.processIdentifier
        guard
            let targetProcessID = request.processID
                ?? initialFrontmostProcessID,
            targetProcessID > 0
        else {
            try? writeOwnerOnly(
                [
                    "result=FAIL",
                    "stage=activation",
                    "reason=targetUnavailable",
                    "",
                ].joined(separator: "\n"),
                to: request.reportURL
            )
            NSApp.terminate(nil)
            return
        }

        guard
            let targetApplication = NSRunningApplication(
                processIdentifier: targetProcessID
            )
        else {
            try? writeOwnerOnly(
                [
                    "result=FAIL",
                    "stage=activation",
                    "reason=targetUnavailable",
                    "targetPID=\(targetProcessID)",
                    "",
                ].joined(separator: "\n"),
                to: request.reportURL
            )
            NSApp.terminate(nil)
            return
        }

        if !request.captureOnly {
            var targetIsFrontmost =
                NSWorkspace.shared.frontmostApplication?
                .processIdentifier == targetProcessID
            if !targetIsFrontmost {
                for _ in 0..<40 {
                    _ = targetApplication.activate(
                        options: [.activateAllWindows]
                    )
                    if NSWorkspace.shared.frontmostApplication?
                        .processIdentifier == targetProcessID
                    {
                        targetIsFrontmost = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard targetIsFrontmost else {
                try? writeOwnerOnly(
                    [
                        "result=FAIL",
                        "stage=activation",
                        "reason=targetNotFrontmost",
                        "accessibilityTrusted=\(AXIsProcessTrusted())",
                        "frontmostPID=\((NSWorkspace.shared.frontmostApplication?.processIdentifier).map(String.init) ?? "none")",
                        "targetPID=\(targetProcessID)",
                        "",
                    ].joined(separator: "\n"),
                    to: request.reportURL
                )
                NSApp.terminate(nil)
                return
            }
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == targetProcessID
        else {
            try? writeOwnerOnly(
                [
                    "result=FAIL",
                    "stage=activation",
                    "reason=targetLostFocusBeforeCapture",
                    "targetPID=\(targetProcessID)",
                    "",
                ].joined(separator: "\n"),
                to: request.reportURL
            )
            NSApp.terminate(nil)
            return
        }

        let isAccessibilityTrusted = true
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        if request.exercisesVoiceSession {
            let result = await runVoiceSession(
                targets: targets,
                targetProcessID: targetProcessID,
                frontmostProcessID: frontmostProcessID
            )
            do {
                try writeOwnerOnly(result + "\n", to: request.reportURL)
            } catch {
                NSLog("Speaker delivery smoke report write failed")
            }
            NSApp.terminate(nil)
            return
        }
        let captureHint = targets.releaseCaptureHint()
        let capture: InputTargetCaptureResult
        if let captureHint,
            captureHint.processID == targetProcessID
        {
            capture = await targets.capture(matching: captureHint)
        } else {
            capture = .unavailable(.invalidatedTarget)
        }
        let result: String
        switch capture {
        case .unavailable(let reason):
            var lines = [
                "result=FAIL",
                "stage=capture",
                "reason=\(reason)",
                "accessibilityTrusted=\(isAccessibilityTrusted)",
                "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                "targetPID=\(targetProcessID)",
            ]
            if let diagnostic = targets.releaseCaptureDiagnostic {
                lines.append("diagnostic=\(diagnostic)")
            }
            result = lines.joined(separator: "\n")
        case .writable(let target) where request.captureOnly:
            result = [
                "result=PASS",
                "stage=capture",
                "accessibilityTrusted=\(isAccessibilityTrusted)",
                "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                "targetPID=\(targetProcessID)",
                "targetApplication=\(sanitize(target.applicationName))",
            ].joined(separator: "\n")
        case .writable(let target):
            let outcome = await targets.deliver(
                "Speaker smoke",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            switch outcome {
            case .delivered:
                result = [
                    "result=PASS",
                    "stage=delivery",
                    "deliveryReceipt=confirmedTargetValue",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(targetProcessID)",
                    "targetApplication=\(sanitize(target.applicationName))",
                ].joined(separator: "\n")
            case .pasteCommandPosted(let diagnostic):
                result = [
                    "result=PASS",
                    "stage=delivery",
                    "deliveryReceipt=pasteCommandPosted",
                    "diagnostic=\(diagnostic.code)",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(targetProcessID)",
                    "targetApplication=\(sanitize(target.applicationName))",
                ].joined(separator: "\n")
            case .pendingCopy(let reason):
                result = [
                    "result=FAIL",
                    "stage=delivery",
                    "reason=\(reason)",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(targetProcessID)",
                    "targetApplication=\(sanitize(target.applicationName))",
                ].joined(separator: "\n")
            case .pendingCopyDiagnosed(let reason, let diagnostic):
                result = [
                    "result=FAIL",
                    "stage=delivery",
                    "reason=\(reason)",
                    "diagnostic=\(diagnostic.code)",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(targetProcessID)",
                    "targetApplication=\(sanitize(target.applicationName))",
                ].joined(separator: "\n")
            }
        }

        do {
            try writeOwnerOnly(
                result + "\n",
                to: request.reportURL
            )
        } catch {
            NSLog("Speaker delivery smoke report write failed")
        }
        NSApp.terminate(nil)
    }

    private static func runVoiceSession(
        targets: AccessibilityInputTargets,
        targetProcessID: pid_t,
        frontmostProcessID: pid_t?
    ) async -> String {
        let sessions = VoiceInputSessions(
            audioCapture: DeliverySmokeAudioCapture(),
            targetCapture: targets,
            textProcessor: DeliverySmokeTextProcessor(text: "Speaker smoke"),
            delivery: targets,
            clipboard: SystemClipboardWriter(),
            history: MemorySessionHistory()
        )
        let presentations = await sessions.observe()
        let dispatcher = VoiceInputTriggerDispatcher(
            sessions: sessions,
            releaseCaptureHint: { targets.releaseCaptureHint() }
        )
        let terminalTask = Task {
            await firstTerminalActivity(in: presentations)
        }
        let pressedAt = DispatchTime.now().uptimeNanoseconds
        dispatcher.send(.pressed, at: pressedAt)
        dispatcher.send(
            .released,
            at: pressedAt
                + VoiceShortcutGestureStateMachine.defaultLongPressNanoseconds
                + 1
        )
        let terminal = await terminalTask.value
        await dispatcher.shutdown()

        let base = [
            "accessibilityTrusted=true",
            "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
            "targetPID=\(targetProcessID)",
        ]
        switch terminal {
        case .delivered(_, let applicationName, let text)
        where text == "Speaker smoke":
            return
                ([
                    "result=PASS",
                    "stage=voiceSession",
                    "targetApplication=\(sanitize(applicationName))",
                ] + base).joined(separator: "\n")
        case .pendingCopy(_, _, let reason):
            var lines = [
                "result=FAIL",
                "stage=voiceSession",
                "reason=\(reason)",
            ]
            if let diagnostic = targets.releaseCaptureDiagnostic {
                lines.append("diagnostic=\(diagnostic)")
            }
            return (lines + base).joined(separator: "\n")
        case .failed(_, let failure):
            return
                ([
                    "result=FAIL",
                    "stage=voiceSession",
                    "reason=\(failure)",
                ] + base).joined(separator: "\n")
        case .cancelled:
            return
                ([
                    "result=FAIL",
                    "stage=voiceSession",
                    "reason=cancelled",
                ] + base).joined(separator: "\n")
        case .delivered:
            return
                ([
                    "result=FAIL",
                    "stage=voiceSession",
                    "reason=unexpectedDeliveredText",
                ] + base).joined(separator: "\n")
        case .none:
            return
                ([
                    "result=FAIL",
                    "stage=voiceSession",
                    "reason=terminalTimeout",
                ] + base).joined(separator: "\n")
        case .idle, .preparing, .recording, .processing:
            return
                ([
                    "result=FAIL",
                    "stage=voiceSession",
                    "reason=nonterminalResult",
                ] + base).joined(separator: "\n")
        }
    }

    private static func firstTerminalActivity(
        in presentations: AsyncStream<VoiceInputPresentation>
    ) async -> VoiceInputActivity? {
        await withTaskGroup(of: VoiceInputActivity?.self) { group in
            group.addTask {
                for await presentation in presentations {
                    if presentation.activity.isTerminal {
                        return presentation.activity
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func waitForTriggerIfNeeded(
        _ request: DeliverySmokeLaunchRequest
    ) async -> Bool {
        guard let triggerURL = request.triggerURL else { return true }
        let armedURL = triggerURL.deletingLastPathComponent()
            .appendingPathComponent("armed.txt")
        do {
            try writeOwnerOnly("armed\n", to: armedURL)
        } catch {
            try? writeOwnerOnly(
                "result=FAIL\nstage=arming\nreason=armedWriteFailed\n",
                to: request.reportURL
            )
            return false
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while !FileManager.default.fileExists(atPath: triggerURL.path),
            clock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard FileManager.default.fileExists(atPath: triggerURL.path) else {
            try? writeOwnerOnly(
                "result=FAIL\nstage=arming\nreason=triggerTimeout\n",
                to: request.reportURL
            )
            return false
        }
        return true
    }

    private static func writeOwnerOnly(
        _ content: String,
        to url: URL
    ) throws {
        try OwnerOnlyFilePersistence.write(Data(content.utf8), to: url)
    }

    private static func sanitize(_ value: String) -> String {
        String(
            value.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }
        ).prefix(80).description
    }
}

private struct DeliverySmokeAudioCapture: AudioCapturing {
    func start() async throws {}

    func stop() async throws -> CapturedAudio {
        CapturedAudio(
            data: Data(),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {}
}

private struct DeliverySmokeTextProcessor: VoiceTextProcessing {
    let text: String

    func captureSnapshot() async -> VoiceTextProcessingSnapshot { .empty }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        VoiceTextProcessingResult(
            doubaoText: text,
            normalizedText: text,
            deepSeekText: nil,
            finalText: text,
            doubaoRequestID: "delivery-smoke",
            deepSeekRequestID: nil,
            refinementStatus: .notRequested,
            refinementFailure: nil
        )
    }
}
