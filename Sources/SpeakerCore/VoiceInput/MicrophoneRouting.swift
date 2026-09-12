import Foundation

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

package final class MicrophoneCapturePlan: @unchecked Sendable {
    package let id = UUID()
    package let device: Result<MicrophoneDevice, AudioCaptureError>
    private let lock = NSLock()
    private var cancelled = false

    package init(device: Result<MicrophoneDevice, AudioCaptureError>) { self.device = device }
    package var isCancelled: Bool { lock.withLock { cancelled } }
    package func cancel() { lock.withLock { cancelled = true } }
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

public final class MicrophoneRouting: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let devices: any MicrophoneDeviceSource
    private var preference: MicrophonePreference = .systemDefault
    private var activeCapture: MicrophoneCaptureLease?
    private var captureStarted = false
    private var observers: [UUID: AsyncStream<MicrophoneRoutingSnapshot>.Continuation] = [:]
    private var observation: Task<Void, Never>?
    private var isShutDown = false

    public init(devices: any MicrophoneDeviceSource) {
        self.devices = devices
        let changes = devices.observeChanges()
        observation = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                self?.publish()
            }
        }
    }

    public func snapshot() -> MicrophoneRoutingSnapshot {
        lock.withLock { currentSnapshot() }
    }

    public func select(_ preference: MicrophonePreference) {
        lock.withLock {
            guard !isShutDown, self.preference != preference else { return }
            self.preference = preference
            publish()
        }
    }

    public func refresh() {
        guard lock.withLock({ !isShutDown }) else { return }
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
        lock.withLock {
            guard !isShutDown else {
                continuation.finish()
                return
            }
            observers[id] = continuation
            continuation.yield(currentSnapshot())
        }
        return stream
    }

    public func shutdown() {
        lock.withLock {
            guard !isShutDown else { return }
            isShutDown = true
            activeCapture = nil
            observation?.cancel()
            observation = nil
            let continuations = Array(observers.values)
            observers.removeAll()
            for continuation in continuations { continuation.finish() }
        }
        devices.shutdown()
    }

    package func prepareCapture() -> MicrophoneCapturePlan {
        lock.withLock {
            guard !isShutDown else {
                return MicrophoneCapturePlan(device: .failure(.microphoneUnavailable))
            }
            let snapshot = devices.snapshot()
            guard snapshot.isAvailable else {
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
    }

    package func acquire(
        _ plan: MicrophoneCapturePlan,
        purpose: MicrophoneCapturePurpose
    ) throws -> MicrophoneCaptureLease {
        devices.refresh()
        return try lock.withLock {
            guard !isShutDown else { throw AudioCaptureError.microphoneUnavailable }
            guard !plan.isCancelled else { throw CancellationError() }
            if let activeCapture,
                activeCapture.purpose == .voice || purpose == .levelTest
            {
                throw AudioCaptureError.alreadyRecording
            }
            let device = try plan.device.get()
            guard contains(device, in: devices.snapshot()) else {
                throw AudioCaptureError.microphoneUnavailable
            }
            let lease = MicrophoneCaptureLease(
                id: UUID(), planID: plan.id, device: device, purpose: purpose)
            activeCapture = lease
            captureStarted = false
            publish()
            return lease
        }
    }

    package func markStarted(_ lease: MicrophoneCaptureLease) {
        lock.withLock {
            guard isCurrent(lease) else { return }
            captureStarted = true
            publish()
        }
    }

    package func isCurrent(_ lease: MicrophoneCaptureLease) -> Bool {
        lock.withLock { !isShutDown && activeCapture?.id == lease.id }
    }

    package func deviceIsAvailable(_ lease: MicrophoneCaptureLease) -> Bool {
        lock.withLock { contains(lease.device, in: devices.snapshot()) }
    }

    package func refreshAndValidate(_ lease: MicrophoneCaptureLease) -> Bool {
        devices.refresh()
        return lock.withLock {
            isCurrent(lease) && contains(lease.device, in: devices.snapshot())
        }
    }

    package func release(_ lease: MicrophoneCaptureLease) {
        lock.withLock {
            guard activeCapture?.id == lease.id else { return }
            activeCapture = nil
            publish()
        }
    }

    private func currentSnapshot() -> MicrophoneRoutingSnapshot {
        MicrophoneRoutingSnapshot(
            preference: preference,
            devices: devices.snapshot(),
            actualDevice: captureStarted ? activeCapture?.device : nil,
            isTesting: activeCapture?.purpose == .levelTest
        )
    }

    private func contains(
        _ device: MicrophoneDevice,
        in snapshot: MicrophoneDeviceSnapshot
    ) -> Bool {
        snapshot.isAvailable
            && snapshot.devices.contains {
                $0.uid == device.uid && $0.deviceID == device.deviceID
            }
    }

    private func publish() {
        lock.withLock {
            guard !isShutDown else { return }
            let snapshot = currentSnapshot()
            for continuation in observers.values { continuation.yield(snapshot) }
        }
    }

    private func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }
}
