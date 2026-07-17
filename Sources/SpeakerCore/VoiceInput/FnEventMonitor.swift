@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation

package enum GlobalVoiceTrigger: Equatable, Sendable {
    case pressed
    case released
    case cancel
    case monitorRecovered
}

package struct VoiceTriggerTarget: Sendable {
    package let receive: @Sendable (GlobalVoiceTrigger) -> Void
    package let shouldConsumeEscape: @Sendable () -> Bool

    package init(
        receive: @escaping @Sendable (GlobalVoiceTrigger) -> Void,
        shouldConsumeEscape: @escaping @Sendable () -> Bool
    ) {
        self.receive = receive
        self.shouldConsumeEscape = shouldConsumeEscape
    }
}

/// Thread-safe policy shared by the event tap and the session presentation.
/// Escape is consumed only while Speaker owns an active voice interaction.
package final class EscapeCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    package init() {}

    package func setActive(_ active: Bool) {
        lock.withLock { self.active = active }
    }

    package var shouldConsumeEscape: Bool {
        lock.withLock { active }
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
    private var isConsumingSequence = false

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

@MainActor
package final class FnEventMonitor {
    private let target: VoiceTriggerTarget
    private var box: FnEventTapBox?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    package init(
        target: VoiceTriggerTarget
    ) {
        self.target = target
    }

    package var isRunning: Bool { tap != nil }

    @discardableResult
    package func start() -> FunctionKeyMonitorStartResult {
        guard tap == nil else { return .active }

        let box = FnEventTapBox(target: target)
        let mask = eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)
            | eventMask(for: .keyUp)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnEventTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            return .eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .runLoopSourceUnavailable
        }

        box.tap = tap
        self.box = box
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .active
    }

    package func stop() {
        guard let tap else { return }
        box?.stop()
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        source = nil
        self.tap = nil
        box = nil
    }

    deinit {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << type.rawValue
    }
}

private final class FnEventTapBox: @unchecked Sendable {
    let target: VoiceTriggerTarget
    var tap: CFMachPort?
    var fnIsDown = false
    var didEmitPress = false
    var secureInputTimer: DispatchSourceTimer?
    var escapePolicy = EscapeKeyEventPolicy()

    init(target: VoiceTriggerTarget) {
        self.target = target
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            fnIsDown = false
            didEmitPress = false
            escapePolicy.reset()
            stopSecureInputMonitoring()
            target.receive(.cancel)
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                target.receive(.monitorRecovered)
            }
            return false
        case .flagsChanged:
            let isDown = event.flags.contains(.maskSecondaryFn)
            guard isDown != fnIsDown else { return false }
            fnIsDown = isDown
            if isDown {
                guard !IsSecureEventInputEnabled() else {
                    fnIsDown = false
                    return false
                }
                didEmitPress = true
                target.receive(.pressed)
                startSecureInputMonitoring()
            } else {
                stopSecureInputMonitoring()
                if didEmitPress {
                    didEmitPress = false
                    target.receive(.released)
                }
            }
            return false
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
            let keyEvent: EscapeKeyEvent = type == .keyDown ? .keyDown : .keyUp
            switch escapePolicy.handle(
                keyEvent,
                speakerIsActive: target.shouldConsumeEscape()
            ) {
            case .passThrough:
                return false
            case .consume:
                return true
            case .consumeAndCancel:
                didEmitPress = false
                stopSecureInputMonitoring()
                target.receive(.cancel)
                return true
            }
        default:
            return false
        }
    }

    private func startSecureInputMonitoring() {
        stopSecureInputMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.fnIsDown, self.didEmitPress else { return }
            guard IsSecureEventInputEnabled() else { return }
            self.didEmitPress = false
            self.stopSecureInputMonitoring()
            self.target.receive(.cancel)
        }
        secureInputTimer = timer
        timer.resume()
    }

    private func stopSecureInputMonitoring() {
        secureInputTimer?.cancel()
        secureInputTimer = nil
    }

    func stop() {
        let hadActivePress = didEmitPress
        fnIsDown = false
        didEmitPress = false
        escapePolicy.reset()
        stopSecureInputMonitoring()
        if hadActivePress {
            target.receive(.cancel)
        }
    }

    deinit {
        secureInputTimer?.cancel()
    }
}

private let fnEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let box = Unmanaged<FnEventTapBox>.fromOpaque(userInfo).takeUnretainedValue()
    return box.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}
