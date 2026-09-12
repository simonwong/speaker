import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

private actor MicrophonePreferenceWriter {
    private(set) var values: [MicrophonePreference] = []
    var rejectsWrites: Bool
    private let delaysFirstWrite: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(rejectsWrites: Bool = false, delaysFirstWrite: Bool = false) {
        self.rejectsWrites = rejectsWrites
        self.delaysFirstWrite = delaysFirstWrite
    }

    func write(_ value: MicrophonePreference) async throws {
        values.append(value)
        if delaysFirstWrite, values.count == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        if rejectsWrites { throw AppSettingsStoreError.writeFailed(reason: "io") }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func acceptWrites() { rejectsWrites = false }
}

enum MicrophoneSelectionSpecs {
    private static let builtIn = MicrophoneDevice(uid: "built-in-uid", name: "内置麦克风", deviceID: 1)
    private static let usb = MicrophoneDevice(uid: "usb-private-uid", name: "USB 麦克风", deviceID: 2)

    @MainActor
    static func run(failures: inout [String]) async {
        SpeakerSpecSupport.run(
            "microphone choices disambiguate identical names with stable private-identity-free labels",
            failures: &failures
        ) {
            let first = MicrophoneDevice(uid: "private-a", name: "USB 麦克风", deviceID: 8)
            let second = MicrophoneDevice(uid: "private-b", name: "USB 麦克风", deviceID: 9)
            let source = MicrophoneDeviceSourceFake(
                snapshot: .init(
                    devices: [second, first], systemDefaultDeviceID: 8, isAvailable: true))
            let routing = MicrophoneRouting(devices: source)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { _ in })
            let initial = Dictionary(
                uniqueKeysWithValues: model.state.choices.map { ($0.preference, $0.title) })
            try expect(initial[.device(uid: first.uid)] == "USB 麦克风（1）")
            try expect(initial[.device(uid: second.uid)] == "USB 麦克风（2）")
            try expect(initial[.systemDefault] == "跟随系统（USB 麦克风（1））")
            source.update(
                .init(devices: [first, second], systemDefaultDeviceID: 8, isAvailable: true))
            model.refresh()
            try expect(
                Dictionary(
                    uniqueKeysWithValues: model.state.choices.map { ($0.preference, $0.title) })
                    == initial)
            try expect(!model.state.choices.contains { $0.title.contains("private-") })
            model.beginShutdown()
        }

        await runAsync(
            "microphone selection follows a changed system default without rewriting preference",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1))
            let routing = MicrophoneRouting(devices: source)
            let writer = MicrophonePreferenceWriter()
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { try await writer.write($0) }
            )
            model.start()
            try expect(model.state.preference == .systemDefault)
            try expect(model.state.selectionTitle == "跟随系统（内置麦克风）")
            source.update(devices(defaultID: 2))
            let refreshed = await eventually(before: .seconds(1)) {
                model.state.selectionTitle == "跟随系统（USB 麦克风）"
            }
            try expect(refreshed)
            try expect(model.state.preference == .systemDefault)
            let writes = await writer.values
            try expect(writes.isEmpty)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone selection retains a disconnected fixed device without exposing its UID",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1))
            let routing = MicrophoneRouting(devices: source)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { _ in }
            )
            model.start()
            model.select(.device(uid: usb.uid))
            source.update(.init(devices: [builtIn], systemDefaultDeviceID: 1, isAvailable: true))
            let disconnected = await eventually(before: .seconds(1)) {
                model.state.resolvedDevice == nil
            }
            try expect(disconnected)
            try expect(model.state.preference == .device(uid: usb.uid))
            try expect(model.state.choices.contains { $0.preference == .device(uid: usb.uid) })
            try expect(model.state.selectionTitle == "所选麦克风（已断开）")
            try expect(!model.state.choices.contains { $0.title.contains(usb.uid) })
            try expect(model.state.deviceNotice != nil)
            try expect(!model.state.canStartTest)
            source.update(devices(defaultID: 1))
            let reconnected = await eventually(before: .seconds(1)) {
                model.state.selectionTitle == usb.name
            }
            try expect(reconnected)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone selection made before startup restore wins and stays shared with routing",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { _ in }
            )
            model.start()
            model.select(.device(uid: usb.uid))
            model.restore(.systemDefault)
            await Task.yield()
            try expect(model.state.preference == .device(uid: usb.uid))
            try expect(routing.snapshot().preference == model.state.preference)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone selection during recording preserves actual capture and applies to the next capture",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { _ in }
            )
            model.start()
            let lease = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            routing.markStarted(lease)
            model.select(.device(uid: usb.uid))
            try expect(model.state.routing.actualDevice == builtIn)
            try expect(model.state.resolvedDevice == usb)
            try expect(model.state.captureDescription.contains(builtIn.name))
            try expect(model.state.captureDescription.contains("下次"))
            try expect(!model.state.canStartTest)
            routing.release(lease)
            let next = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            routing.markStarted(next)
            try expect(next.device == usb)
            routing.release(next)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone selection persists rapid choices in order and shutdown waits for the latest write",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let writer = MicrophonePreferenceWriter(delaysFirstWrite: true)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { try await writer.write($0) }
            )
            model.select(.device(uid: usb.uid))
            let began = await eventually(before: .seconds(1)) { await writer.values.count == 1 }
            try expect(began)
            model.select(.systemDefault)
            model.beginShutdown()
            model.select(.device(uid: builtIn.uid))
            var flushed = false
            let flush = Task { @MainActor in
                await model.flushPersistence()
                flushed = true
            }
            await Task.yield()
            try expect(!flushed)
            await writer.resume()
            await flush.value
            let writes = await writer.values
            try expect(writes == [.device(uid: usb.uid), .systemDefault])
            try expect(model.state.preference == .systemDefault)
        }

        await runAsync(
            "microphone selection reports a failed save and retries the latest preference",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let writer = MicrophonePreferenceWriter(rejectsWrites: true)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { try await writer.write($0) }
            )
            model.select(.device(uid: usb.uid))
            await model.flushPersistence()
            try expect(model.state.persistenceFailed)
            try expect(routing.snapshot().preference == .device(uid: usb.uid))
            await writer.acceptWrites()
            model.retryPersistence()
            await model.flushPersistence()
            try expect(!model.state.persistenceFailed)
            let writes = await writer.values
            try expect(writes == [.device(uid: usb.uid), .device(uid: usb.uid)])
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone directory failure is distinct from an empty directory and can be refreshed",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(
                snapshot: .init(
                    devices: [builtIn, usb], systemDefaultDeviceID: 1, isAvailable: false))
            let routing = MicrophoneRouting(devices: source)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: MicrophoneLevelTesterFake(),
                persistPreference: { _ in }
            )
            model.restore(.device(uid: usb.uid))
            try expect(model.state.deviceNotice?.contains("无法读取") == true)
            try expect(model.state.selectionTitle == "所选麦克风（列表不可用）")
            try expect(
                model.state.choices.filter { $0.preference == .device(uid: usb.uid) }.count == 1)
            model.select(.systemDefault)
            source.update(.init(devices: [], systemDefaultDeviceID: nil, isAvailable: true))
            model.refresh()
            try expect(model.state.deviceNotice?.contains("没有可用") == true)
            source.update(devices(defaultID: 1))
            model.refresh()
            try expect(model.state.deviceNotice == nil)
            try expect(model.state.canStartTest)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone local test opens only on request and finishes when the source ends",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let tester = MicrophoneLevelTesterFake(routing: routing)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: tester, persistPreference: { _ in })
            model.start()
            model.startLevelTest()
            await Task.yield()
            let initialStartCount = await tester.startCount
            try expect(initialStartCount == 0)
            model.restore(.systemDefault)
            model.startLevelTest()
            let testing = await eventually(before: .seconds(1)) {
                model.state.testStatus == .testing
            }
            try expect(testing)
            await tester.emit(.init(elapsedMilliseconds: 100, peakPower: -12))
            let metered = await eventually(before: .seconds(1)) { model.state.testLevel > 0.7 }
            try expect(metered)
            await tester.finish()
            let ended = await eventually(before: .seconds(1)) { model.state.testStatus == .idle }
            try expect(ended)
            try expect(model.state.testLevel == 0)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone local test reports an explicit capture failure after meters started",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let tester = MicrophoneLevelTesterFake(routing: routing)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: tester, persistPreference: { _ in })
            model.restore(.systemDefault)
            model.startLevelTest()
            let began = await eventually(before: .seconds(1)) { model.state.testStatus == .testing }
            try expect(began)
            await tester.finish(error: .conversionFailed)
            let reported = await eventually(before: .seconds(1)) {
                model.state.testError != nil && model.state.testStatus == .idle
            }
            try expect(reported)
            try expect(model.state.testError?.contains("未能完成") == true)
            try expect(model.state.testLevel == 0)
            model.beginShutdown()
            await model.flushPersistence()
        }

        await runAsync(
            "microphone local test stop waits for a delayed start before shutdown completes",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let tester = MicrophoneLevelTesterFake(delaysStart: true)
            let model = MicrophoneSelectionFeature(
                microphones: routing, levelTester: tester, persistPreference: { _ in })
            model.restore(.systemDefault)
            model.startLevelTest()
            let began = await eventually(before: .seconds(1)) { await tester.startCount == 1 }
            try expect(began)
            model.beginShutdown()
            var flushed = false
            let flush = Task { @MainActor in
                await model.flushPersistence()
                flushed = true
            }
            await Task.yield()
            try expect(!flushed)
            await tester.resumeStart()
            await flush.value
            let stopCount = await tester.stopCount
            let remainsActive = await tester.isActive
            try expect(stopCount == 1)
            try expect(!remainsActive)
            model.startLevelTest()
            let finalStartCount = await tester.startCount
            try expect(finalStartCount == 1)
        }

        await runAsync(
            "microphone local test failure remains actionable without raw provider or device details",
            failures: &failures
        ) {
            let routing = MicrophoneRouting(
                devices: MicrophoneDeviceSourceFake(snapshot: devices(defaultID: 1)))
            let model = MicrophoneSelectionFeature(
                microphones: routing,
                levelTester: MicrophoneLevelTesterFake(failure: .microphonePermissionDenied),
                persistPreference: { _ in }
            )
            model.restore(.systemDefault)
            model.startLevelTest()
            let failed = await eventually(before: .seconds(1)) { model.state.testError != nil }
            try expect(failed)
            try expect(model.state.testStatus == .idle)
            try expect(model.state.testError?.contains("权限") == true)
            try expect(!model.state.testError!.contains(builtIn.uid))
            model.beginShutdown()
            await model.flushPersistence()
        }
    }

    private static func devices(defaultID: UInt32) -> MicrophoneDeviceSnapshot {
        .init(devices: [builtIn, usb], systemDefaultDeviceID: defaultID, isAvailable: true)
    }
}
