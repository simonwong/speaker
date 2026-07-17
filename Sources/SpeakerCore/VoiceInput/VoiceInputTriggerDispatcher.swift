import Foundation

/// Serializes synchronous global-event callbacks into one ordered async
/// consumer so a quick release can never overtake its preceding press.
package final class VoiceInputTriggerDispatcher: @unchecked Sendable {
    private struct SequencedTrigger: Sendable {
        let trigger: GlobalVoiceTrigger
        let sequence: UInt64
        let source: GlobalVoiceTrigger
        let uptimeNanoseconds: UInt64
        let ownerSequence: UInt64?
        var captureHint: InputTargetCaptureHint?
    }

    private let sessions: VoiceInputSessions
    private let continuation: AsyncStream<SequencedTrigger>.Continuation
    private let consumer: Task<Void, Never>
    private let gestureController: GestureController
    private let releaseCaptureHint:
        @Sendable () -> InputTargetCaptureHint?

    package init(
        sessions: VoiceInputSessions,
        releaseCaptureHint:
            @escaping @Sendable () -> InputTargetCaptureHint? = { nil }
    ) {
        self.sessions = sessions
        self.releaseCaptureHint = releaseCaptureHint
        let (stream, continuation) = AsyncStream<SequencedTrigger>.makeStream()
        self.continuation = continuation
        let gestureController = GestureController()
        self.gestureController = gestureController
        consumer = Task {
            let terminations = await sessions.observeTriggerTerminations()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await sequence in terminations {
                        guard !Task.isCancelled else { return }
                        gestureController.sessionTerminated(sequence: sequence)
                    }
                }
                group.addTask {
                    for await event in stream {
                        guard !Task.isCancelled else { return }
                        switch event.trigger {
                        case .pressed:
                            await sessions.send(.pressed, triggerSequence: event.sequence)
                        case .released:
                            if event.source == .pressed,
                               let ownerSequence = event.ownerSequence,
                               !(await sessions.isActive(triggerSequence: ownerSequence)),
                               gestureController.recoverStalePress(
                                   sequence: event.sequence,
                                   at: event.uptimeNanoseconds
                               ) {
                                await sessions.send(
                                    .pressed,
                                    triggerSequence: event.sequence
                                )
                            } else {
                                await sessions.releaseFromDispatcher(
                                    captureHint: event.captureHint
                                )
                            }
                        case .cancel:
                            await sessions.cancel(triggeredAtSequence: event.sequence)
                        case .monitorRecovered:
                            break
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    package func send(_ trigger: GlobalVoiceTrigger) {
        send(trigger, at: DispatchTime.now().uptimeNanoseconds)
    }

    package func send(_ trigger: GlobalVoiceTrigger, at uptimeNanoseconds: UInt64) {
        var events = gestureController.handle(trigger, at: uptimeNanoseconds)
        for index in events.indices where events[index].trigger == .released {
            events[index].captureHint = releaseCaptureHint()
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

    package func finish() {
        continuation.finish()
    }

    package func shutdown() async {
        continuation.finish()
        consumer.cancel()
        await sessions.shutdown()
        await consumer.value
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }

    private final class GestureController: @unchecked Sendable {
        private let lock = NSLock()
        private var nextSequence: UInt64 = 0
        private var ownerSequence: UInt64?
        private var physicalKeyIsDown = false
        private var gesture = VoiceShortcutGestureStateMachine()

        func handle(
            _ trigger: GlobalVoiceTrigger,
            at uptimeNanoseconds: UInt64
        ) -> [SequencedTrigger] {
            lock.withLock {
                nextSequence &+= 1
                let sequence = nextSequence
                let existingOwnerSequence = ownerSequence
                switch trigger {
                case .pressed:
                    physicalKeyIsDown = true
                case .released, .cancel, .monitorRecovered:
                    physicalKeyIsDown = false
                }
                let semanticTriggers = gesture.handle(trigger, at: uptimeNanoseconds)
                if trigger == .pressed, semanticTriggers.contains(.pressed) {
                    ownerSequence = sequence
                } else if trigger == .cancel {
                    ownerSequence = nil
                }
                return semanticTriggers.map {
                    SequencedTrigger(
                        trigger: $0,
                        sequence: sequence,
                        source: trigger,
                        uptimeNanoseconds: uptimeNanoseconds,
                        ownerSequence: existingOwnerSequence,
                        captureHint: nil
                    )
                }
            }
        }

        func recoverStalePress(sequence: UInt64, at uptimeNanoseconds: UInt64) -> Bool {
            lock.withLock {
                gesture = VoiceShortcutGestureStateMachine()
                guard gesture.handle(.pressed, at: uptimeNanoseconds) == [.pressed] else {
                    return false
                }
                if !physicalKeyIsDown {
                    _ = gesture.handle(.released, at: uptimeNanoseconds)
                }
                ownerSequence = sequence
                return true
            }
        }

        func sessionTerminated(sequence: UInt64) {
            lock.withLock {
                guard ownerSequence == sequence else { return }
                gesture = VoiceShortcutGestureStateMachine()
                ownerSequence = nil
            }
        }
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
