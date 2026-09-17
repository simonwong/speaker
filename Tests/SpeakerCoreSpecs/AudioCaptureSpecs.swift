import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
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

        await runAsync(
            "microphone preview never streams audio and ends after eight seconds",
            failures: &failures
        ) {
            let device = MicrophoneDevice(uid: "test-device", name: "Test microphone", deviceID: 4)
            let source = MicrophoneDeviceSourceFake(
                snapshot: MicrophoneDeviceSnapshot(
                    devices: [device], systemDefaultDeviceID: 4, isAvailable: true
                ))
            let routing = MicrophoneRouting(devices: source)
            let probe = AudioCaptureHardwareFactoryFake()
            let clock = ManualVoiceInputClock()
            let capture = AVAudioCapture(
                microphones: routing, hardwareFactory: probe.factory, clock: clock)
            defer { routing.shutdown() }
            let stream = try await capture.startLevelTest()
            try expect(probe.instances.count == 1)
            try expect(
                !probe.instances[0].streamsAudio, "local preview opened a provider audio stream")
            try expect(routing.snapshot().actualDevice == device)
            let deadlineArmed = await eventually(before: .seconds(2)) {
                clock.sleepRequests.contains(.seconds(8))
                    && clock.sleepRequests.contains(.milliseconds(50))
            }
            try expect(deadlineArmed)
            let readings = Task { () -> [RecordingTelemetry] in
                var values: [RecordingTelemetry] = []
                for try await value in stream { values.append(value) }
                return values
            }
            clock.advance(by: .milliseconds(50))
            let meterArmed = await eventually(before: .seconds(2)) { clock.sleepRequestCount >= 3 }
            try expect(meterArmed)
            clock.advance(by: .milliseconds(7_950))
            let stopped = await eventually(before: .seconds(2)) { !routing.snapshot().isTesting }
            try expect(stopped, "local preview exceeded its eight-second deadline")
            let values = try await readings.value
            try expect(values.contains { $0.peakPower == -12 })
            try expect(probe.instances[0].stopCount == 1)
            try expect(routing.snapshot().actualDevice == nil)
        }

        await runAsync(
            "microphone voice capture survives late preview stop deadline and hardware callbacks",
            failures: &failures
        ) {
            let device = MicrophoneDevice(uid: "test-device", name: "Test microphone", deviceID: 4)
            let source = MicrophoneDeviceSourceFake(
                snapshot: MicrophoneDeviceSnapshot(
                    devices: [device], systemDefaultDeviceID: 4, isAvailable: true
                ))
            let routing = MicrophoneRouting(devices: source)
            let probe = AudioCaptureHardwareFactoryFake()
            let clock = ManualVoiceInputClock(honoursCancellation: false)
            let capture = AVAudioCapture(
                microphones: routing, hardwareFactory: probe.factory, clock: clock)
            defer { routing.shutdown() }
            _ = try await capture.startLevelTest()
            let deadlineArmed = await eventually(before: .seconds(2)) {
                clock.sleepRequests.contains(.seconds(8))
                    && clock.sleepRequests.contains(.milliseconds(50))
            }
            try expect(deadlineArmed)
            let preview = probe.instances[0]
            _ = await capture.audioChunks()
            let voicePlan = capture.prepareStart()
            try await voicePlan.start()
            let voice = probe.instances[1]
            try expect(preview.stopCount == 1)
            try expect(voice.streamsAudio && voice.isRunning)
            try expect(!routing.snapshot().isTesting)
            await capture.stopLevelTest()
            await preview.emitFailure(.conversionFailed)
            clock.advance(by: .seconds(8))
            let deadlineDrained = await eventually(before: .seconds(2)) {
                clock.pendingSleepCount <= 1
            }
            try expect(deadlineDrained)
            try expect(voice.isRunning && voice.stopCount == 0)
            do {
                _ = try await capture.startLevelTest()
                throw SpecFailure(message: "preview preempted voice capture")
            } catch let error as AudioCaptureError { try expect(error == .alreadyRecording) }
            await capture.cancel()
            clock.advance(by: .seconds(10))
            try expect(voice.stopCount == 1)
        }

        await runAsync(
            "microphone scoped plan cancellation and old callbacks preserve a newer recording",
            failures: &failures
        ) {
            let device = MicrophoneDevice(uid: "test-device", name: "Test microphone", deviceID: 4)
            let source = MicrophoneDeviceSourceFake(
                snapshot: MicrophoneDeviceSnapshot(
                    devices: [device], systemDefaultDeviceID: 4, isAvailable: true
                ))
            let routing = MicrophoneRouting(devices: source)
            let probe = AudioCaptureHardwareFactoryFake()
            let capture = AVAudioCapture(microphones: routing, hardwareFactory: probe.factory)
            defer { routing.shutdown() }
            let oldPlan = capture.prepareStart()
            try expect(probe.instances.isEmpty, "preparing a shortcut opened a microphone")
            _ = await capture.audioChunks()
            try await oldPlan.start()
            let old = probe.instances[0]
            await oldPlan.cancel()
            _ = await capture.audioChunks()
            await oldPlan.cancel()
            let newPlan = capture.prepareStart()
            try await newPlan.start()
            let current = probe.instances[1]
            await oldPlan.cancel()
            await old.emitConfigurationChange(inputFormatUnchanged: false)
            await old.emitFailure(.deviceConfigurationChanged)
            await old.emitFailure(.conversionFailed)
            try expect(current.isRunning && current.stopCount == 0)
            do {
                try await oldPlan.start()
                throw SpecFailure(message: "a cancelled start plan restarted recording")
            } catch is CancellationError {}
            try expect(current.isRunning)
            await newPlan.cancel()
            try expect(current.stopCount == 1)
        }

        await runAsync(
            "microphone device readback mismatch fails before publishing an actual input",
            failures: &failures
        ) {
            let device = MicrophoneDevice(uid: "test-device", name: "Test microphone", deviceID: 4)
            let source = MicrophoneDeviceSourceFake(
                snapshot: MicrophoneDeviceSnapshot(
                    devices: [device], systemDefaultDeviceID: 4, isAvailable: true
                ))
            let routing = MicrophoneRouting(devices: source)
            let probe = AudioCaptureHardwareFactoryFake(readbackOverride: 9)
            let capture = AVAudioCapture(microphones: routing, hardwareFactory: probe.factory)
            defer { routing.shutdown() }
            _ = await capture.audioChunks()
            do {
                try await capture.start()
                throw SpecFailure(message: "recording accepted a different actual device")
            } catch let error as AudioCaptureError {
                try expect(error == .microphoneSelectionFailed)
            }
            try expect(routing.snapshot().actualDevice == nil)
            try expect(probe.instances[0].stopCount == 1)
        }

        await runAsync(
            "microphone adapter interrupts lost devices and allows a fresh capture after reconnection",
            failures: &failures
        ) {
            let device = MicrophoneDevice(uid: "test-device", name: "Test microphone", deviceID: 4)
            let source = MicrophoneDeviceSourceFake(
                snapshot: MicrophoneDeviceSnapshot(
                    devices: [device], systemDefaultDeviceID: 4, isAvailable: true
                ))
            let routing = MicrophoneRouting(devices: source)
            let probe = AudioCaptureHardwareFactoryFake()
            let capture = AVAudioCapture(microphones: routing, hardwareFactory: probe.factory)
            defer { routing.shutdown() }
            _ = await capture.audioChunks()
            try await capture.start()
            let failures = await capture.observeFailures()
            let firstFailure = Task { () -> AudioCaptureError? in
                for await failure in failures { return failure }
                return nil
            }
            source.update(
                MicrophoneDeviceSnapshot(devices: [], systemDefaultDeviceID: nil, isAvailable: true)
            )
            let stopped = await eventually(before: .seconds(2)) { probe.instances[0].stopCount > 0 }
            try expect(stopped)
            let failure = await firstFailure.value
            try expect(failure == .deviceConfigurationChanged)
            await capture.cancel()
            let reconnected = MicrophoneDevice(uid: device.uid, name: device.name, deviceID: 8)
            source.update(
                MicrophoneDeviceSnapshot(
                    devices: [reconnected], systemDefaultDeviceID: 8, isAvailable: true))
            _ = await capture.audioChunks()
            try await capture.start()
            try expect(probe.instances[1].currentDeviceID == 8)
            await capture.cancel()
        }

        await runAsync(
            "microphone configuration notifications preserve healthy preview and voice capture",
            failures: &failures
        ) {
            for isPreview in [true, false] {
                let device = MicrophoneDevice(
                    uid: "test-device", name: "Test microphone", deviceID: 4)
                let source = MicrophoneDeviceSourceFake(
                    snapshot: .init(devices: [device], systemDefaultDeviceID: 4, isAvailable: true))
                let routing = MicrophoneRouting(devices: source)
                let probe = AudioCaptureHardwareFactoryFake()
                let capture = AVAudioCapture(microphones: routing, hardwareFactory: probe.factory)
                defer { routing.shutdown() }
                let previewStream: AsyncThrowingStream<RecordingTelemetry, any Error>?
                if isPreview {
                    previewStream = try await capture.startLevelTest()
                } else {
                    previewStream = nil
                    _ = await capture.audioChunks()
                    try await capture.start()
                }
                let hardware = probe.instances[0]
                await hardware.emitConfigurationChange()
                let remainedActive =
                    hardware.isRunning && hardware.stopCount == 0
                    && routing.snapshot().actualDevice == device
                await capture.cancel()
                withExtendedLifetime(previewStream) {}
                try expect(remainedActive, "a healthy configuration notification stopped capture")
            }
        }

        await runAsync(
            "microphone configuration notifications interrupt stopped changed or reformatted capture",
            failures: &failures
        ) {
            for isPreview in [true, false] {
                for change in 0..<3 {
                    let device = MicrophoneDevice(
                        uid: "test-device", name: "Test microphone", deviceID: 4)
                    let source = MicrophoneDeviceSourceFake(
                        snapshot: .init(
                            devices: [device], systemDefaultDeviceID: 4, isAvailable: true))
                    let routing = MicrophoneRouting(devices: source)
                    let probe = AudioCaptureHardwareFactoryFake()
                    let capture = AVAudioCapture(
                        microphones: routing, hardwareFactory: probe.factory)
                    defer { routing.shutdown() }
                    var preview: AsyncThrowingStream<RecordingTelemetry, any Error>.Iterator?
                    if isPreview {
                        preview = try await capture.startLevelTest().makeAsyncIterator()
                    } else {
                        _ = await capture.audioChunks()
                        try await capture.start()
                    }
                    let hardware = probe.instances[0]
                    await hardware.emitConfigurationChange(
                        running: change == 0 ? false : nil,
                        deviceID: change == 1 ? 9 : nil,
                        inputFormatUnchanged: change == 2 ? false : nil
                    )
                    let interrupted = hardware.stopCount == 1
                    if !interrupted { await capture.cancel() }
                    try expect(interrupted, "an invalid configuration continued capture")
                    do {
                        if isPreview {
                            _ = try await preview?.next()
                        } else {
                            _ = try await capture.stop()
                        }
                        throw SpecFailure(message: "an interrupted capture reported success")
                    } catch let error as AudioCaptureError {
                        try expect(error == .deviceConfigurationChanged)
                    }
                    await capture.cancel()
                    try expect(routing.snapshot().actualDevice == nil)
                }
            }
        }

        await runAsync(
            "microphone preview reports a runtime device failure instead of normal completion",
            failures: &failures
        ) {
            let device = MicrophoneDevice(uid: "test-device", name: "Test microphone", deviceID: 4)
            let source = MicrophoneDeviceSourceFake(
                snapshot: MicrophoneDeviceSnapshot(
                    devices: [device], systemDefaultDeviceID: 4, isAvailable: true
                ))
            let routing = MicrophoneRouting(devices: source)
            let probe = AudioCaptureHardwareFactoryFake()
            let capture = AVAudioCapture(microphones: routing, hardwareFactory: probe.factory)
            defer { routing.shutdown() }
            let stream = try await capture.startLevelTest()
            let terminal = Task { () -> AudioCaptureError? in
                do {
                    for try await _ in stream {}
                    return nil
                } catch { return error as? AudioCaptureError }
            }
            await probe.instances[0].emitFailure(.deviceConfigurationChanged)
            let failure = await terminal.value
            try expect(failure == .deviceConfigurationChanged)
            try expect(!routing.snapshot().isTesting && routing.snapshot().actualDevice == nil)
            try expect(probe.instances[0].stopCount == 1)
        }
    }
}
