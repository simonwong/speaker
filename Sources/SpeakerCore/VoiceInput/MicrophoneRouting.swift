import Foundation
import os

public enum MicrophonePreference: Equatable, Hashable, Codable, Sendable {
    case systemDefault
    case device(uid: String)
}

public struct MicrophoneDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let deviceID: UInt32
    public var id: String { uid }

    public init(uid: String, name: String, deviceID: UInt32) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
    }
}

public struct MicrophoneDeviceSnapshot: Equatable, Sendable {
    public let devices: [MicrophoneDevice]
    public let systemDefaultDeviceID: UInt32?
    public let isAvailable: Bool

    public init(
        devices: [MicrophoneDevice],
        systemDefaultDeviceID: UInt32?,
        isAvailable: Bool
    ) {
        self.devices = devices
        self.systemDefaultDeviceID = systemDefaultDeviceID
        self.isAvailable = isAvailable
    }
}

public protocol MicrophoneDeviceSource: Sendable {
    func snapshot() -> MicrophoneDeviceSnapshot
    func observeChanges() -> AsyncStream<MicrophoneDeviceSnapshot>
    func refresh()
    func shutdown()
}

public struct MicrophoneRoutingSnapshot: Equatable, Sendable {
    public let preference: MicrophonePreference
    public let devices: MicrophoneDeviceSnapshot
    public let actualDevice: MicrophoneDevice?
    public let isTesting: Bool
}

public protocol MicrophoneLevelTesting: Sendable {
    func startLevelTest() async throws -> AsyncThrowingStream<RecordingTelemetry, any Error>
    func stopLevelTest() async
}

package final class MicrophoneCapturePlan: Sendable {
    package let id = UUID()
    package let device: Result<MicrophoneDevice, AudioCaptureError>
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    package init(device: Result<MicrophoneDevice, AudioCaptureError>) { self.device = device }
    package var isCancelled: Bool { cancelled.withLock { $0 } }
    package func cancel() { cancelled.withLock { $0 = true } }
}

package enum MicrophoneCapturePurpose: Sendable {
    case voice
    case levelTest
}

package struct MicrophoneCaptureLease: Equatable, Sendable {
    package let id: UUID
    package let planID: UUID
    package let device: MicrophoneDevice
    package let purpose: MicrophoneCapturePurpose
}

/// Routing state lives in one lock. The device source is read inside it only
/// where a published snapshot must match the state it describes;
/// `MicrophoneDeviceSource.snapshot()` is a leaf read that never calls back
/// into routing. Stream termination and task cancellation, which run
/// handlers synchronously, always happen outside the lock.
public final class MicrophoneRouting: Sendable {
    private struct State: Sendable {
        var preference: MicrophonePreference = .systemDefault
        var activeCapture: MicrophoneCaptureLease?
        var captureStarted = false
        var observers: [UUID: AsyncStream<MicrophoneRoutingSnapshot>.Continuation] = [:]
        var observation: Task<Void, Never>?
        var isShutDown = false

        func isCurrent(_ lease: MicrophoneCaptureLease) -> Bool {
            !isShutDown && activeCapture?.id == lease.id
        }

        func snapshot(devices: MicrophoneDeviceSnapshot) -> MicrophoneRoutingSnapshot {
            MicrophoneRoutingSnapshot(
                preference: preference,
                devices: devices,
                actualDevice: captureStarted ? activeCapture?.device : nil,
                isTesting: activeCapture?.purpose == .levelTest
            )
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let devices: any MicrophoneDeviceSource

    public init(devices: any MicrophoneDeviceSource) {
        self.devices = devices
        let changes = devices.observeChanges()
        let observation = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                self?.publish()
            }
        }
        state.withLock { $0.observation = observation }
    }

    public func snapshot() -> MicrophoneRoutingSnapshot {
        let devices = devices.snapshot()
        return state.withLock { $0.snapshot(devices: devices) }
    }

    public func select(_ preference: MicrophonePreference) {
        state.withLock { state in
            guard !state.isShutDown, state.preference != preference else { return }
            state.preference = preference
            publish(&state)
        }
    }

    public func refresh() {
        guard state.withLock({ !$0.isShutDown }) else { return }
        devices.refresh()
        publish()
    }

    public func observe() -> AsyncStream<MicrophoneRoutingSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MicrophoneRoutingSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            self?.removeObserver(id)
        }
        let registered = state.withLock { [devices] state -> Bool in
            guard !state.isShutDown else { return false }
            state.observers[id] = continuation
            continuation.yield(state.snapshot(devices: devices.snapshot()))
            return true
        }
        if !registered {
            continuation.finish()
        }
        return stream
    }

    public func shutdown() {
        let stopped = state.withLock {
            state -> (Task<Void, Never>?, [AsyncStream<MicrophoneRoutingSnapshot>.Continuation])? in
            guard !state.isShutDown else { return nil }
            state.isShutDown = true
            state.activeCapture = nil
            let observation = state.observation
            state.observation = nil
            let continuations = Array(state.observers.values)
            state.observers.removeAll()
            return (observation, continuations)
        }
        if let (observation, continuations) = stopped {
            observation?.cancel()
            for continuation in continuations { continuation.finish() }
        }
        devices.shutdown()
    }

    package func prepareCapture() -> MicrophoneCapturePlan {
        let snapshot = devices.snapshot()
        let preference = state.withLock { state -> MicrophonePreference? in
            state.isShutDown ? nil : state.preference
        }
        guard let preference, snapshot.isAvailable else {
            return MicrophoneCapturePlan(device: .failure(.microphoneUnavailable))
        }
        let device: MicrophoneDevice?
        switch preference {
        case .systemDefault:
            device = snapshot.devices.first { $0.deviceID == snapshot.systemDefaultDeviceID }
        case .device(let uid):
            device = snapshot.devices.first { $0.uid == uid }
        }
        return MicrophoneCapturePlan(
            device: device.map { .success($0) } ?? .failure(.microphoneUnavailable)
        )
    }

    package func acquire(
        _ plan: MicrophoneCapturePlan,
        purpose: MicrophoneCapturePurpose
    ) throws -> MicrophoneCaptureLease {
        devices.refresh()
        let isCancelled = plan.isCancelled
        let snapshot = devices.snapshot()
        return try state.withLock { state in
            guard !state.isShutDown else { throw AudioCaptureError.microphoneUnavailable }
            guard !isCancelled else { throw CancellationError() }
            if let activeCapture = state.activeCapture,
                activeCapture.purpose == .voice || purpose == .levelTest
            {
                throw AudioCaptureError.alreadyRecording
            }
            let device = try plan.device.get()
            guard Self.contains(device, in: snapshot) else {
                throw AudioCaptureError.microphoneUnavailable
            }
            let lease = MicrophoneCaptureLease(
                id: UUID(), planID: plan.id, device: device, purpose: purpose)
            state.activeCapture = lease
            state.captureStarted = false
            publish(&state)
            return lease
        }
    }

    package func markStarted(_ lease: MicrophoneCaptureLease) {
        state.withLock { state in
            guard state.isCurrent(lease) else { return }
            state.captureStarted = true
            publish(&state)
        }
    }

    package func isCurrent(_ lease: MicrophoneCaptureLease) -> Bool {
        state.withLock { $0.isCurrent(lease) }
    }

    package func deviceIsAvailable(_ lease: MicrophoneCaptureLease) -> Bool {
        Self.contains(lease.device, in: devices.snapshot())
    }

    package func refreshAndValidate(_ lease: MicrophoneCaptureLease) -> Bool {
        devices.refresh()
        let snapshot = devices.snapshot()
        return isCurrent(lease) && Self.contains(lease.device, in: snapshot)
    }

    package func release(_ lease: MicrophoneCaptureLease) {
        state.withLock { state in
            guard state.activeCapture?.id == lease.id else { return }
            state.activeCapture = nil
            publish(&state)
        }
    }

    private static func contains(
        _ device: MicrophoneDevice,
        in snapshot: MicrophoneDeviceSnapshot
    ) -> Bool {
        snapshot.isAvailable
            && snapshot.devices.contains {
                $0.uid == device.uid && $0.deviceID == device.deviceID
            }
    }

    private func publish() {
        state.withLock { state in publish(&state) }
    }

    /// Yields inside the lock so observers see snapshots in state order.
    /// Yielding never runs observer code synchronously.
    private func publish(_ state: inout State) {
        guard !state.isShutDown else { return }
        let snapshot = state.snapshot(devices: devices.snapshot())
        for continuation in state.observers.values { continuation.yield(snapshot) }
    }

    private func removeObserver(_ id: UUID) {
        _ = state.withLock { $0.observers.removeValue(forKey: id) }
    }
}
