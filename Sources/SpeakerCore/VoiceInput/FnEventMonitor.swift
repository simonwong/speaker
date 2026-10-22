@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation
import os

package enum GlobalVoiceTrigger: Equatable, Sendable {
    case pressed
    case released
    case cancel
    case monitorRecovered
}

/// Where the live shortcut monitors send their edges. Every closure is
/// called on `ShortcutEventTapThread`, not the main thread, while a key event
/// waits for the answer: each must be thread-safe, return without waiting for
/// another thread, and hop to the main actor for presentation work.
package struct VoiceTriggerTarget: Sendable {
    package let receive: @Sendable (GlobalVoiceTrigger) -> Void
    package let shouldConsumeEscape: @Sendable () -> Bool
    /// A shortcut press was refused because another process holds Secure
    /// Event Input. The press is still consumed; this only reports it, and it
    /// is called inside the event callback, so it must return quickly.
    package let secureInputBlockedPress: @Sendable () -> Void

    package init(
        receive: @escaping @Sendable (GlobalVoiceTrigger) -> Void,
        shouldConsumeEscape: @escaping @Sendable () -> Bool,
        secureInputBlockedPress: @escaping @Sendable () -> Void = {}
    ) {
        self.receive = receive
        self.shouldConsumeEscape = shouldConsumeEscape
        self.secureInputBlockedPress = secureInputBlockedPress
    }
}

/// The process that holds Secure Event Input, as the window server reports it.
package enum SecureEventInputHolder {
    package static func processID() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let value = session["kCGSSessionSecureInputPID"] as? NSNumber,
            value.int32Value > 0
        else { return nil }
        return value.int32Value
    }
}

/// Thread-safe policy shared by the event tap and the session presentation.
/// Escape is consumed only while Speaker owns an active voice interaction.
package final class EscapeCancellationGate: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: false)

    package init() {}

    package func setActive(_ active: Bool) {
        self.active.withLock { $0 = active }
    }

    package var shouldConsumeEscape: Bool {
        active.withLock { $0 }
    }
}

package enum EscapeKeyEvent: Sendable {
    case keyDown
    case keyUp
}

package enum EscapeKeyEventDecision: Equatable, Sendable {
    case passThrough
    case consume
    case consumeAndCancel
}

/// Once Speaker consumes an Escape key-down, it owns the complete physical
/// key sequence. Repeats and the matching key-up stay consumed even after the
/// session publishes its terminal state.
package struct EscapeKeyEventPolicy: Sendable {
    package private(set) var isConsumingSequence = false

    package init() {}

    package mutating func handle(
        _ event: EscapeKeyEvent,
        speakerIsActive: Bool
    ) -> EscapeKeyEventDecision {
        switch event {
        case .keyDown:
            if isConsumingSequence { return .consume }
            guard speakerIsActive else { return .passThrough }
            isConsumingSequence = true
            return .consumeAndCancel
        case .keyUp:
            guard isConsumingSequence else { return .passThrough }
            isConsumingSequence = false
            return .consume
        }
    }

    package mutating func reset() {
        isConsumingSequence = false
    }
}

package enum FunctionKeyMonitorStartResult: Equatable, Sendable {
    case active
    case eventTapUnavailable
    case runLoopSourceUnavailable
}

package enum ModifierFlagEventEdge: Equatable, Sendable {
    case pressed
    case released
}

package enum ModifierFlagEventDisposition: Equatable, Sendable {
    case passThrough
    case consume(ModifierFlagEventEdge)
}

/// Accepts modifier edges only when macOS identifies the physical Fn key as
/// their source. Navigation keys can carry `maskSecondaryFn` without Fn being
/// pressed, so the flag alone is not a sufficient trigger signal.
package struct FunctionKeyFlagEventPolicy: Sendable {
    private(set) var isDown = false

    package init() {}

    package mutating func handle(
        keyCode: Int64,
        flags: CGEventFlags
    ) -> ModifierFlagEventDisposition {
        guard keyCode == Int64(kVK_Function) else { return .passThrough }
        let functionFlagIsSet = flags.contains(.maskSecondaryFn)
        guard functionFlagIsSet != isDown else { return .passThrough }
        isDown = functionFlagIsSet
        return .consume(functionFlagIsSet ? .pressed : .released)
    }

    package mutating func reset() {
        isDown = false
    }
}

/// Observes the Fn key through `ShortcutEventTaps` on the shortcut event tap
/// thread. While idle only modifier-flag changes are intercepted.
@MainActor
package final class FnEventMonitor {
    private let target: VoiceTriggerTarget
    private var taps: ShortcutEventTaps?

    package init(
        target: VoiceTriggerTarget
    ) {
        self.target = target
    }

    package var isRunning: Bool { taps != nil }

    @discardableResult
    package func start() -> FunctionKeyMonitorStartResult {
        guard taps == nil else { return .active }
        let taps = ShortcutEventTaps(
            target: target,
            flagTrigger: .functionKey(FunctionKeyFlagEventPolicy())
        )
        switch taps.install() {
        case .none:
            self.taps = taps
            return .active
        case .eventTapUnavailable:
            return .eventTapUnavailable
        case .runLoopSourceUnavailable:
            return .runLoopSourceUnavailable
        }
    }

    package func stop() {
        taps?.uninstall()
        taps = nil
    }

    deinit {
        taps?.uninstallLater()
    }
}
