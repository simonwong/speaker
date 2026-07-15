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
    private var gesture = VoiceShortcutGestureStateMachine()

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
        send(trigger, at: DispatchTime.now().uptimeNanoseconds)
    }

    package func send(_ trigger: GlobalVoiceTrigger, at uptimeNanoseconds: UInt64) {
        let events = sequenceLock.withLock {
            nextSequence &+= 1
            let sequence = nextSequence
            return gesture.handle(trigger, at: uptimeNanoseconds).map {
                SequencedTrigger(trigger: $0, sequence: sequence)
            }
        }
        for event in events {
            if event.trigger == .cancel {
                // A provider request can keep the ordered consumer inside `.released`.
                // Preempt it immediately. The sequence fence prevents a delayed
                // task from cancelling a session begun by a later press.
                Task { await sessions.cancel(triggeredAtSequence: event.sequence) }
            }
            continuation.yield(event)
        }
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

package struct VoiceShortcutGestureStateMachine: Sendable {
    private enum State: Sendable {
        case idle
        case held(startedAt: UInt64)
        case latched
        case stoppingAwaitingRelease
    }

    package static let defaultLongPressNanoseconds: UInt64 = 300_000_000

    private let longPressNanoseconds: UInt64
    private var state: State = .idle

    package init(
        longPressNanoseconds: UInt64 = Self.defaultLongPressNanoseconds
    ) {
        self.longPressNanoseconds = longPressNanoseconds
    }

    package mutating func handle(
        _ trigger: GlobalVoiceTrigger,
        at uptimeNanoseconds: UInt64
    ) -> [GlobalVoiceTrigger] {
        switch trigger {
        case .pressed:
            switch state {
            case .idle:
                state = .held(startedAt: uptimeNanoseconds)
                return [.pressed]
            case .latched:
                state = .stoppingAwaitingRelease
                return [.released]
            case .held, .stoppingAwaitingRelease:
                return []
            }
        case .released:
            switch state {
            case let .held(startedAt):
                let elapsed = uptimeNanoseconds >= startedAt
                    ? uptimeNanoseconds - startedAt
                    : 0
                if elapsed >= longPressNanoseconds {
                    state = .idle
                    return [.released]
                }
                state = .latched
                return []
            case .stoppingAwaitingRelease:
                state = .idle
                return []
            case .idle, .latched:
                return []
            }
        case .cancel:
            state = .idle
            return [.cancel]
        case .monitorRecovered:
            return [.monitorRecovered]
        }
    }
}
