import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum AudioCaptureSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run("provider diagnostics remove controls and cap untrusted messages", failures: &failures)
        {
            let diagnostic = VoiceProviderDiagnostic(
                provider: "doubao\nspoofed",
                requestID: " request\t123 ",
                message: String(repeating: "x", count: 1_200) + "\u{0000}tail"
            )
            try expect(diagnostic.provider == "doubao spoofed")
            try expect(diagnostic.requestID == "request 123")
            try expect(diagnostic.message?.count == 1_000)
            try expect(!(diagnostic.message?.contains("\u{0000}") ?? true))
        }

        run("diagnostic refinement kind never includes a custom user label", failures: &failures) {
            let mode = TextRefinementMode.custom(
                name: "客户甲绝密项目",
                prompt: "把内容写成内部项目更新"
            )
            try expect(mode.diagnosticKind == "custom")
            try expect(!mode.diagnosticKind.contains("客户甲"))
        }

        run("audio capture environment contains no free-text fields", failures: &failures) {
            let secret = "private device and raw error detail"
            let failure = AudioCaptureVoiceProcessingFailure.classify(
                NSError(
                    domain: secret,
                    code: 77,
                    userInfo: [NSLocalizedDescriptionKey: secret]
                )
            )
            let snapshot = AudioCaptureEnvironmentSnapshot(
                voiceProcessingRequested: true,
                voiceProcessingActive: false,
                voiceProcessingEnableFailure: failure,
                automaticGainControlEnabled: false,
                preferredMicrophoneMode: .voiceIsolation,
                activeMicrophoneMode: .standard
            )

            func containsFreeText(_ value: Any) -> Bool {
                if value is String { return true }
                return Mirror(reflecting: value).children.contains {
                    containsFreeText($0.value)
                }
            }

            try expect(failure == .other)
            try expect(!containsFreeText(snapshot))
            try expect(!String(describing: snapshot).contains(secret))
        }

        run(
            "microphone denial is distinct from an unknown recording-device failure",
            failures: &failures
        ) {
            let denied = VoiceInputProblem(
                audioCaptureError: .microphonePermissionDenied
            )
            let deviceFailure = VoiceInputProblem(
                audioCaptureError: .couldNotStart
            )
            try expect(denied.failure == .microphonePermissionDenied)
            try expect(deviceFailure.failure == .recordingFailed)
        }

        run("audio quality rejects only definite local silence", failures: &failures) {
            try AudioCaptureQualityPolicy.validate(
                duration: .seconds(1),
                peakPower: -50
            )
            do {
                try AudioCaptureQualityPolicy.validate(
                    duration: .seconds(1),
                    peakPower: -160
                )
                throw SpecFailure(message: "digital silence was accepted")
            } catch let failure as AudioCaptureError {
                try expect(failure == .silent)
            }
            do {
                try AudioCaptureQualityPolicy.validate(
                    duration: .milliseconds(299),
                    peakPower: -10
                )
                throw SpecFailure(message: "sub-300 ms recording was accepted")
            } catch let failure as AudioCaptureError {
                try expect(failure == .tooShort)
            }
        }

        run(
            "provider networking does not persist cookies credentials or cache", failures: &failures
        ) {
            let configuration = ProviderURLSessionFactory.ephemeralConfiguration()
            try expect(configuration.urlCache == nil)
            try expect(configuration.httpCookieStorage == nil)
            try expect(configuration.urlCredentialStorage == nil)
            try expect(!configuration.httpShouldSetCookies)
            try expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }

        run("initial snapshot comes from permission access", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )

            let model = PermissionModel(access: access)

            try expect(
                model.snapshot
                    == .init(
                        accessibility: .denied,
                        microphone: .notDetermined
                    ))
            try expect(!model.snapshot.allGranted)
        }

        run("refresh publishes current permission snapshot", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)
            access.snapshot = .init(accessibility: .granted, microphone: .granted)

            model.refresh()

            try expect(
                model.snapshot
                    == .init(
                        accessibility: .granted,
                        microphone: .granted
                    ))
            try expect(model.snapshot.allGranted)
        }

        run("restricted microphone authorization remains distinct from denial", failures: &failures)
        {
            try expect(
                SystemPermissionAccess.microphoneState(for: .restricted)
                    == .restricted
            )
            try expect(
                SystemPermissionAccess.microphoneState(for: .denied)
                    == .denied
            )
            let snapshot = PermissionSnapshot(
                accessibility: .granted,
                microphone: .restricted
            )
            try expect(!snapshot.allGranted)
        }

        run("permission requests resolve to one unambiguous system action", failures: &failures) {
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .accessibility,
                    state: .denied
                ) == .openSystemSettings(anchor: "Privacy_Accessibility")
            )
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .microphone,
                    state: .notDetermined
                ) == .requestMicrophone
            )
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .microphone,
                    state: .denied
                ) == .openSystemSettings(anchor: "Privacy_Microphone")
            )
            try expect(
                SystemPermissionAccess.requestPlan(
                    for: .microphone,
                    state: .restricted
                ) == .none
            )
        }

        await runAsync("request updates snapshot with provider result", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            access.requestResults[.accessibility] = .init(
                accessibility: .granted,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.request(.accessibility)

            try expect(access.requestedPermissions == [.accessibility])
            try expect(
                model.snapshot
                    == .init(
                        accessibility: .granted,
                        microphone: .granted
                    ))
        }

        await runAsync("first launch requests an undetermined microphone once", failures: &failures)
        {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .notDetermined)
            )
            access.requestResults[.microphone] = .init(
                accessibility: .denied,
                microphone: .granted
            )
            let model = PermissionModel(access: access)

            await model.requestMicrophoneIfNeeded()
            await model.requestMicrophoneIfNeeded()

            try expect(access.requestedPermissions == [.microphone])
            try expect(model.snapshot.microphone == .granted)
        }

        await runAsync("first launch does not reprompt a denied microphone", failures: &failures) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .denied)
            )
            let model = PermissionModel(access: access)

            await model.requestMicrophoneIfNeeded()

            try expect(access.requestedPermissions.isEmpty)
        }

        await runAsync(
            "first launch requests missing accessibility for the active bundle", failures: &failures
        ) {
            let access = PermissionAccessStub(
                snapshot: .init(accessibility: .denied, microphone: .granted)
            )
            let model = PermissionModel(access: access)

            await model.requestAccessibilityIfNeeded()

            try expect(access.requestedPermissions == [.accessibility])
        }
    }
}
