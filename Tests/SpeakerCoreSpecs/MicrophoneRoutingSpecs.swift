import Foundation
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

enum MicrophoneRoutingSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        let builtIn = MicrophoneDevice(uid: "built-in", name: "Microphone", deviceID: 1)
        let usb = MicrophoneDevice(uid: "usb", name: "Microphone", deviceID: 2)
        func snapshot(
            _ devices: [MicrophoneDevice] = [builtIn, usb], defaultID: UInt32? = 1,
            available: Bool = true
        ) -> MicrophoneDeviceSnapshot {
            MicrophoneDeviceSnapshot(
                devices: devices, systemDefaultDeviceID: defaultID, isAvailable: available
            )
        }

        run(
            "microphone plans freeze the system device before later default or preference changes",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: snapshot())
            let routing = MicrophoneRouting(devices: source)
            defer { routing.shutdown() }
            let plan = routing.prepareCapture()
            source.update(snapshot(defaultID: 2))
            routing.select(.device(uid: usb.uid))
            let capture = try routing.acquire(plan, purpose: .voice)
            routing.markStarted(capture)
            try expect(capture.device == builtIn)
            try expect(routing.snapshot().preference == .device(uid: usb.uid))
            try expect(routing.snapshot().actualDevice == builtIn)
            try expect(
                routing.deviceIsAvailable(capture),
                "changing the default invalidated a healthy frozen device")
            routing.release(capture)
            let next = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            try expect(next.device == usb)
        }

        run(
            "microphone fixed selection survives absence and resolves a new ID after reconnection",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: snapshot())
            let routing = MicrophoneRouting(devices: source)
            defer { routing.shutdown() }
            routing.select(.device(uid: usb.uid))
            let oldPlan = routing.prepareCapture()
            source.update(snapshot([builtIn]))
            try expectThrows(AudioCaptureError.self, "unverified microphone capture was accepted") {
                _ = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            }
            try expect(routing.snapshot().preference == .device(uid: usb.uid))
            try expect(routing.snapshot().actualDevice == nil)
            let reconnected = MicrophoneDevice(uid: usb.uid, name: usb.name, deviceID: 7)
            source.update(snapshot([builtIn, reconnected]))
            try expectThrows(AudioCaptureError.self, "unverified microphone capture was accepted") {
                _ = try routing.acquire(oldPlan, purpose: .voice)
            }
            let next = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            try expect(next.device == reconnected)
        }

        run(
            "microphone ID reuse and directory read failure never select an unverified route",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: snapshot())
            let routing = MicrophoneRouting(devices: source)
            defer { routing.shutdown() }
            routing.select(.device(uid: usb.uid))
            let plan = routing.prepareCapture()
            let other = MicrophoneDevice(uid: "different", name: usb.name, deviceID: usb.deviceID)
            source.update(snapshot([builtIn, other]))
            try expectThrows(AudioCaptureError.self, "unverified microphone capture was accepted") {
                _ = try routing.acquire(plan, purpose: .voice)
            }
            source.update(snapshot(available: false))
            try expectThrows(AudioCaptureError.self, "unverified microphone capture was accepted") {
                _ = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            }
            try expect(routing.snapshot().actualDevice == nil)
            routing.refresh()
            try expect(source.refreshCount > 0)
        }

        run(
            "microphone voice capture preempts the preview lease and rejects its late cleanup",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: snapshot())
            let routing = MicrophoneRouting(devices: source)
            defer { routing.shutdown() }
            let preview = try routing.acquire(routing.prepareCapture(), purpose: .levelTest)
            try expect(routing.snapshot().isTesting)
            let voice = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            try expect(!routing.isCurrent(preview))
            try expect(!routing.snapshot().isTesting)
            routing.release(preview)
            try expect(routing.isCurrent(voice), "a late preview cleanup released voice capture")
            try expectThrows(AudioCaptureError.self, "unverified microphone capture was accepted") {
                _ = try routing.acquire(routing.prepareCapture(), purpose: .levelTest)
            }
            routing.release(voice)
            try expect(routing.snapshot().actualDevice == nil)
        }

        run(
            "microphone generation rejects old callbacks after cancellation and restart",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: snapshot())
            let routing = MicrophoneRouting(devices: source)
            defer { routing.shutdown() }
            let old = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            routing.release(old)
            let current = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            try expect(!routing.isCurrent(old))
            routing.release(old)
            try expect(routing.isCurrent(current))
            source.update(snapshot([usb], defaultID: 2))
            try expect(!routing.deviceIsAvailable(current))
            source.update(snapshot())
            try expect(routing.deviceIsAvailable(current))
        }

        run(
            "microphone shutdown invalidates active capture and refuses new plans",
            failures: &failures
        ) {
            let source = MicrophoneDeviceSourceFake(snapshot: snapshot())
            let routing = MicrophoneRouting(devices: source)
            let capture = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            routing.shutdown()
            try expect(!routing.isCurrent(capture))
            try expectThrows(AudioCaptureError.self, "unverified microphone capture was accepted") {
                _ = try routing.acquire(routing.prepareCapture(), purpose: .voice)
            }
            routing.select(.device(uid: usb.uid))
            try expect(routing.snapshot().preference == .systemDefault)
        }
    }
}
