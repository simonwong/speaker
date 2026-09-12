import Foundation
import SpeakerCore

public final class MicrophoneDeviceSourceFake: MicrophoneDeviceSource, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var current: MicrophoneDeviceSnapshot
    private var observers: [UUID: AsyncStream<MicrophoneDeviceSnapshot>.Continuation] = [:]
    private var isShutDown = false
    private var refreshes = 0

    public init(snapshot: MicrophoneDeviceSnapshot) { current = snapshot }

    public var refreshCount: Int { lock.withLock { refreshes } }

    public func snapshot() -> MicrophoneDeviceSnapshot { lock.withLock { current } }

    public func update(_ snapshot: MicrophoneDeviceSnapshot) {
        lock.withLock {
            guard !isShutDown else { return }
            current = snapshot
            for continuation in observers.values { continuation.yield(snapshot) }
        }
    }

    public func observeChanges() -> AsyncStream<MicrophoneDeviceSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MicrophoneDeviceSnapshot>.makeStream(
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
            continuation.yield(current)
        }
        return stream
    }

    public func refresh() { lock.withLock { refreshes += 1 } }

    public func shutdown() {
        lock.withLock {
            isShutDown = true
            let continuations = Array(observers.values)
            observers.removeAll()
            for continuation in continuations { continuation.finish() }
        }
    }

    private func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }
}
