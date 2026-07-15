import Foundation

/// Serializes synchronous global-event callbacks into one ordered async
/// consumer so a quick release can never overtake its preceding press.
public final class VoiceInputTriggerDispatcher: @unchecked Sendable {
    private struct SequencedTrigger: Sendable {
        let trigger: GlobalVoiceTrigger
        let sequence: UInt64
    }

    private let sessions: VoiceInputSessions
    private let continuation: AsyncStream<SequencedTrigger>.Continuation
    private let consumer: Task<Void, Never>
    private let sequenceLock = NSLock()
    private var nextSequence: UInt64 = 0

    public init(sessions: VoiceInputSessions) {
        self.sessions = sessions
        let (stream, continuation) = AsyncStream<SequencedTrigger>.makeStream()
        self.continuation = continuation
        consumer = Task {
            for await event in stream {
                switch event.trigger {
                case .pressed:
                    await sessions.send(.pressed, triggerSequence: event.sequence)
                case .released:
                    await sessions.send(.released)
                case .cancel:
                    await sessions.cancel(triggeredAtSequence: event.sequence)
                case .monitorRecovered:
                    break
                }
            }
        }
    }

    public func send(_ trigger: GlobalVoiceTrigger) {
        let sequence = sequenceLock.withLock {
            nextSequence &+= 1
            return nextSequence
        }
        let event = SequencedTrigger(trigger: trigger, sequence: sequence)
        if trigger == .cancel {
            // A provider request can keep the ordered consumer inside `.released`.
            // Preempt it immediately. The sequence fence prevents a delayed
            // task from cancelling a session begun by a later press.
            Task { await sessions.cancel(triggeredAtSequence: sequence) }
        }
        continuation.yield(event)
    }

    public func finish() {
        continuation.finish()
    }

    public func shutdown() async {
        continuation.finish()
        consumer.cancel()
        await sessions.send(.cancel)
        await consumer.value
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }
}
