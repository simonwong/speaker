import Foundation

/// Holds the latest `VoiceInputPresentation` and fans it out to observers.
/// Every observer receives the current value on subscription and only the
/// newest value afterwards, so a slow consumer never sees a stale overlay.
struct VoiceInputPresentationPublisher {
    private(set) var current = VoiceInputPresentation(revision: 0, activity: .idle)
    private var observers: [UUID: AsyncStream<VoiceInputPresentation>.Continuation] = [:]

    mutating func subscribe(
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> AsyncStream<VoiceInputPresentation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VoiceInputPresentation>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        continuation.yield(current)
        continuation.onTermination = { _ in onTermination(id) }
        return stream
    }

    mutating func publish(
        _ activity: VoiceInputActivity,
        telemetry: RecordingTelemetry? = nil,
        notice: VoiceInputNotice? = nil
    ) {
        current = VoiceInputPresentation(
            revision: current.revision &+ 1,
            activity: activity,
            recordingTelemetry: telemetry,
            notice: notice
        )
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    mutating func remove(_ id: UUID) {
        observers[id] = nil
    }
}

/// Fans out the dispatcher sequence of a session that reached a terminal
/// state, so gesture consumers can reset without another physical key edge.
struct TriggerTerminationPublisher {
    private var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    mutating func subscribe(
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> AsyncStream<UInt64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        continuation.onTermination = { _ in onTermination(id) }
        return stream
    }

    func yield(_ sequence: UInt64) {
        for continuation in observers.values {
            continuation.yield(sequence)
        }
    }

    mutating func remove(_ id: UUID) {
        observers[id] = nil
    }
}
