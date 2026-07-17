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
        DeliverySmokeLaunchRequest(
            arguments: arguments,
            signingMode: SpeakerSigningMode(
                infoValue: Bundle.main.object(
                    forInfoDictionaryKey: "SpeakerSigningMode"
                ) as? String
            )
        )
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
                    "targetPID=\(request.processID)",
                    "",
                ].joined(separator: "\n"),
                to: request.reportURL
            )
            NSApp.terminate(nil)
            return
        }

        guard let targetApplication = NSRunningApplication(
            processIdentifier: request.processID
        ) else {
            try? writeOwnerOnly(
                [
                    "result=FAIL",
                    "stage=activation",
                    "reason=targetUnavailable",
                    "targetPID=\(request.processID)",
                    "",
                ].joined(separator: "\n"),
                to: request.reportURL
            )
            NSApp.terminate(nil)
            return
        }

        var targetIsFrontmost = false
        for _ in 0..<40 {
            _ = targetApplication.activate(options: [.activateAllWindows])
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == request.processID
            {
                targetIsFrontmost = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard targetIsFrontmost else {
            try? writeOwnerOnly(
                [
                    "result=FAIL",
                    "stage=activation",
                    "reason=targetNotFrontmost",
                    "accessibilityTrusted=\(AXIsProcessTrusted())",
                    "frontmostPID=\((NSWorkspace.shared.frontmostApplication?.processIdentifier).map(String.init) ?? "none")",
                    "targetPID=\(request.processID)",
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
        let targets = AccessibilityInputTargets()
        let result: String
        switch await targets.capture(expectedProcessID: request.processID) {
        case let .unavailable(reason):
            result = [
                "result=FAIL",
                "stage=capture",
                "reason=\(reason)",
                "accessibilityTrusted=\(isAccessibilityTrusted)",
                "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                "targetPID=\(request.processID)",
            ].joined(separator: "\n")
        case let .writable(target):
            let outcome = await targets.deliver(
                "Speaker smoke",
                to: target,
                commitGate: DeliveryCommitGate()
            )
            switch outcome {
            case .delivered:
                result = [
                    "result=PASS",
                    "stage=receipt",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(request.processID)",
                    "targetApplication=\(sanitize(target.applicationName))",
                ].joined(separator: "\n")
            case let .pendingCopy(reason):
                result = [
                    "result=FAIL",
                    "stage=delivery",
                    "reason=\(reason)",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(request.processID)",
                    "targetApplication=\(sanitize(target.applicationName))",
                ].joined(separator: "\n")
            case let .pendingCopyDiagnosed(reason, diagnostic):
                result = [
                    "result=FAIL",
                    "stage=delivery",
                    "reason=\(reason)",
                    "diagnostic=\(diagnostic.code)",
                    "accessibilityTrusted=\(isAccessibilityTrusted)",
                    "frontmostPID=\(frontmostProcessID.map(String.init) ?? "none")",
                    "targetPID=\(request.processID)",
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
