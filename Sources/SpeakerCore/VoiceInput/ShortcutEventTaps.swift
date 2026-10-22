@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation

/// The one thread that runs Speaker's global keyboard event taps.
///
/// A session event tap holds every matching key event on the Mac until its
/// callback returns, and macOS disables a tap that answers too late. A tap
/// on the main run loop would wait behind any main-thread work, so the taps
/// run on this dedicated user-interactive thread with its own run loop.
/// Tap state, the Secure Event Input poll, and enabling, disabling, or
/// re-enabling a tap all happen on this thread; other threads hand work to
/// it with `perform` or `performAndWait`.
///
/// `@unchecked` because `CFRunLoop` is not annotated `Sendable`. The run loop
/// is immutable after `init`, and `CFRunLoopPerformBlock` and
/// `CFRunLoopWakeUp` accept it from any thread.
package final class ShortcutEventTapThread: @unchecked Sendable {
    package static let shared = ShortcutEventTapThread()

    package let runLoop: CFRunLoop

    private init() {
        let handoff = RunLoopHandoff()
        let thread = Thread {
            handoff.publish(CFRunLoopGetCurrent())
            // With no tap installed the run loop has no source; this port
            // keeps it from returning.
            RunLoop.current.add(Port(), forMode: .default)
            while true {
                CFRunLoopRun()
            }
        }
        thread.name = "Speaker shortcut event taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        runLoop = handoff.wait()
    }

    package var isCurrent: Bool {
        CFRunLoopGetCurrent() === runLoop
    }

    package func perform(_ work: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `work` on the tap thread and waits for it. Tap callbacks never
    /// wait for another thread, so the wait is bounded by `work` itself.
    package func performAndWait<T>(_ work: @Sendable () -> T) -> T {
        if isCurrent { return work() }
        return withoutActuallyEscaping(work) { work in
            let slot = ResultSlot<T>()
            let done = DispatchSemaphore(value: 0)
            perform {
                slot.value = work()
                done.signal()
            }
            done.wait()
            return slot.value!
        }
    }

    /// `@unchecked` because it publishes a `CFRunLoop`; `condition` guards it
    /// and lets the creating thread block until the tap thread publishes.
    private final class RunLoopHandoff: @unchecked Sendable {
        private let condition = NSCondition()
        private var runLoop: CFRunLoop?

        func publish(_ runLoop: CFRunLoop) {
            condition.withLock {
                self.runLoop = runLoop
                condition.signal()
            }
        }

        func wait() -> CFRunLoop {
            condition.withLock {
                while runLoop == nil { condition.wait() }
                return runLoop!
            }
        }
    }

    /// `@unchecked` because `T` need not be `Sendable`. The tap thread writes
    /// the value before signalling, and the waiting thread reads it only after
    /// the semaphore wait returns.
    private final class ResultSlot<T>: @unchecked Sendable {
        var value: T?
    }
}

/// The synchronous decisions behind Speaker's shortcut event taps, kept free
/// of live taps so specifications can drive every edge.
///
/// While idle, Speaker observes only its shortcut: the modifier-flag tap for
/// Fn or a single modifier, or the Carbon hot key for a key chord. Escape
/// matters only while Speaker owns a voice interaction, so the keyDown/keyUp
/// tap stays disabled until a shortcut press arms it. The press arms it on
/// the tap thread before the press is dispatched, so Escape is observed from
/// the moment a session can exist. The first key event after Speaker stops
/// consuming Escape, and after any consumed Escape sequence ends, disarms it.
package struct ShortcutEventTapState: Sendable {
    package enum FlagTrigger: Sendable {
        case none
        case functionKey(FunctionKeyFlagEventPolicy)
        case modifierOnly(ModifierOnlyFlagEventPolicy)
    }

    package enum Tap: Equatable, Sendable {
        case modifierFlags
        case keys
    }

    package enum Effect: Equatable, Sendable {
        case send(GlobalVoiceTrigger)
        case reportSecureInputBlockedPress
        case startSecureInputPolling
        case stopSecureInputPolling
        case reenableModifierFlagTap
    }

    package struct Decision: Equatable, Sendable {
        package var consumesEvent: Bool
        package var effects: [Effect]

        package init(consumesEvent: Bool, effects: [Effect]) {
            self.consumesEvent = consumesEvent
            self.effects = effects
        }

        static let passThrough = Decision(consumesEvent: false, effects: [])
    }

    private var flagTrigger: FlagTrigger
    private var isDown = false
    private var didEmitPress = false
    private var escapePolicy = EscapeKeyEventPolicy()
    /// Whether the keyDown/keyUp tap must currently see events.
    package private(set) var observesKeyEvents = false

    package init(flagTrigger: FlagTrigger) {
        self.flagTrigger = flagTrigger
    }

    package var observesModifierFlags: Bool {
        if case .none = flagTrigger { false } else { true }
    }

    package mutating func shortcutPressed(secureInputEnabled: Bool) -> [Effect] {
        guard !secureInputEnabled else { return [.reportSecureInputBlockedPress] }
        isDown = true
        didEmitPress = true
        observesKeyEvents = true
        return [.send(.pressed), .startSecureInputPolling]
    }

    package mutating func shortcutReleased() -> [Effect] {
        isDown = false
        guard didEmitPress else { return [.stopSecureInputPolling] }
        didEmitPress = false
        return [.stopSecureInputPolling, .send(.released)]
    }

    package mutating func modifierFlagsChanged(
        keyCode: Int64,
        flags: CGEventFlags,
        secureInputEnabled: () -> Bool
    ) -> Decision {
        let disposition: ModifierFlagEventDisposition
        switch flagTrigger {
        case .none:
            return .passThrough
        case .functionKey(var policy):
            disposition = policy.handle(keyCode: keyCode, flags: flags)
            flagTrigger = .functionKey(policy)
        case .modifierOnly(var policy):
            disposition = policy.handle(keyCode: keyCode, flags: flags)
            flagTrigger = .modifierOnly(policy)
        }
        guard case .consume(let edge) = disposition else { return .passThrough }
        switch edge {
        case .pressed:
            return Decision(
                consumesEvent: true,
                effects: shortcutPressed(secureInputEnabled: secureInputEnabled())
            )
        case .released:
            return Decision(consumesEvent: true, effects: shortcutReleased())
        }
    }

    package mutating func keyEvent(
        keyCode: Int64,
        isKeyDown: Bool,
        speakerIsActive: () -> Bool
    ) -> Decision {
        let isActive = speakerIsActive()
        var decision = Decision.passThrough
        if keyCode == Int64(kVK_Escape) {
            switch escapePolicy.handle(
                isKeyDown ? .keyDown : .keyUp,
                speakerIsActive: isActive
            ) {
            case .passThrough:
                break
            case .consume:
                decision.consumesEvent = true
            case .consumeAndCancel:
                didEmitPress = false
                decision = Decision(
                    consumesEvent: true,
                    effects: [.stopSecureInputPolling, .send(.cancel)]
                )
            }
        }
        if !isActive, !escapePolicy.isConsumingSequence {
            observesKeyEvents = false
        }
        return decision
    }

    package mutating func secureInputPollFired(secureInputEnabled: () -> Bool) -> [Effect] {
        guard isDown, didEmitPress, secureInputEnabled() else { return [] }
        didEmitPress = false
        return [.stopSecureInputPolling, .send(.cancel)]
    }

    /// macOS disabled a tap. A tap that should have been running may have
    /// missed the shortcut release or Escape, so the press is cancelled and
    /// the tap restored. The key tap Speaker disarmed itself is not a loss.
    package mutating func tapDisabled(_ tap: Tap) -> [Effect] {
        if tap == .keys, !observesKeyEvents { return [] }
        reset()
        return [
            .stopSecureInputPolling,
            .send(.cancel),
            .reenableModifierFlagTap,
            .send(.monitorRecovered),
        ]
    }

    package mutating func stop() -> [Effect] {
        let hadActivePress = didEmitPress
        reset()
        return hadActivePress
            ? [.stopSecureInputPolling, .send(.cancel)]
            : [.stopSecureInputPolling]
    }

    private mutating func reset() {
        switch flagTrigger {
        case .none:
            break
        case .functionKey(var policy):
            policy.reset()
            flagTrigger = .functionKey(policy)
        case .modifierOnly(var policy):
            policy.reset()
            flagTrigger = .modifierOnly(policy)
        }
        isDown = false
        didEmitPress = false
        escapePolicy.reset()
        observesKeyEvents = false
    }
}

/// Live event taps for one shortcut monitor. Every stored property is
/// confined to the tap thread, which is what makes the `@unchecked` sound;
/// the Core Graphics tap objects it holds are not `Sendable`.
package final class ShortcutEventTaps: @unchecked Sendable {
    package enum InstallFailure: Error, Equatable, Sendable {
        case eventTapUnavailable
        case runLoopSourceUnavailable
    }

    private struct InstalledTap {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    private let thread: ShortcutEventTapThread
    private let target: VoiceTriggerTarget
    private var state: ShortcutEventTapState
    private var modifierFlagTap: InstalledTap?
    private var keyTap: InstalledTap?
    private var keyTapIsEnabled = false
    private var secureInputPoll: CFRunLoopTimer?
    private var isInstalled = false

    package init(
        target: VoiceTriggerTarget,
        flagTrigger: ShortcutEventTapState.FlagTrigger,
        thread: ShortcutEventTapThread = .shared
    ) {
        self.target = target
        self.thread = thread
        state = ShortcutEventTapState(flagTrigger: flagTrigger)
    }

    package func install() -> InstallFailure? {
        thread.performAndWait { self.installOnTapThread() }
    }

    package func uninstall() {
        thread.performAndWait { self.uninstallOnTapThread() }
    }

    /// For `deinit` paths that must not wait.
    package func uninstallLater() {
        thread.perform { self.uninstallOnTapThread() }
    }

    /// Carbon delivers chord hot keys on the main thread; the edge joins the
    /// tap thread so it shares one ordered state with Escape.
    package func shortcutPressed() {
        thread.perform {
            guard self.isInstalled else { return }
            self.apply(
                self.state.shortcutPressed(
                    secureInputEnabled: IsSecureEventInputEnabled()
                )
            )
        }
    }

    package func shortcutReleased() {
        thread.perform {
            guard self.isInstalled else { return }
            self.apply(self.state.shortcutReleased())
        }
    }

    private func installOnTapThread() -> InstallFailure? {
        guard !isInstalled else { return nil }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard
            let keyPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.mask(.keyDown, .keyUp),
                callback: shortcutKeyTapCallback,
                userInfo: userInfo
            )
        else { return .eventTapUnavailable }
        // A new tap starts enabled; Escape waits for a shortcut press.
        CGEvent.tapEnable(tap: keyPort, enable: false)
        guard let keySource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyPort, 0)
        else {
            CFMachPortInvalidate(keyPort)
            return .runLoopSourceUnavailable
        }

        var flagTap: InstalledTap?
        if state.observesModifierFlags {
            guard
                let flagPort = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: Self.mask(.flagsChanged),
                    callback: shortcutModifierFlagTapCallback,
                    userInfo: userInfo
                )
            else {
                CFMachPortInvalidate(keyPort)
                return .eventTapUnavailable
            }
            guard
                let flagSource = CFMachPortCreateRunLoopSource(
                    kCFAllocatorDefault,
                    flagPort,
                    0
                )
            else {
                CFMachPortInvalidate(flagPort)
                CFMachPortInvalidate(keyPort)
                return .runLoopSourceUnavailable
            }
            flagTap = InstalledTap(port: flagPort, source: flagSource)
        }

        keyTap = InstalledTap(port: keyPort, source: keySource)
        keyTapIsEnabled = false
        modifierFlagTap = flagTap
        isInstalled = true
        CFRunLoopAddSource(thread.runLoop, keySource, .commonModes)
        if let flagTap {
            CFRunLoopAddSource(thread.runLoop, flagTap.source, .commonModes)
            CGEvent.tapEnable(tap: flagTap.port, enable: true)
        }
        return nil
    }

    private func uninstallOnTapThread() {
        guard isInstalled else { return }
        apply(state.stop())
        isInstalled = false
        for tap in [modifierFlagTap, keyTap].compactMap(\.self) {
            CFRunLoopRemoveSource(thread.runLoop, tap.source, .commonModes)
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFMachPortInvalidate(tap.port)
        }
        modifierFlagTap = nil
        keyTap = nil
        keyTapIsEnabled = false
    }

    fileprivate func handle(
        _ type: CGEventType,
        _ event: CGEvent,
        from tap: ShortcutEventTapState.Tap
    ) -> Bool {
        guard isInstalled else { return false }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if tap == .keys { keyTapIsEnabled = false }
            apply(state.tapDisabled(tap))
            return false
        case .flagsChanged:
            let decision = state.modifierFlagsChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags,
                secureInputEnabled: { IsSecureEventInputEnabled() }
            )
            apply(decision.effects)
            return decision.consumesEvent
        case .keyDown, .keyUp:
            let decision = state.keyEvent(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                isKeyDown: type == .keyDown,
                speakerIsActive: target.shouldConsumeEscape
            )
            apply(decision.effects)
            return decision.consumesEvent
        default:
            return false
        }
    }

    private func apply(_ effects: [ShortcutEventTapState.Effect]) {
        // Arm the key tap before the press leaves this thread.
        if let keyTap, state.observesKeyEvents != keyTapIsEnabled {
            keyTapIsEnabled = state.observesKeyEvents
            CGEvent.tapEnable(tap: keyTap.port, enable: keyTapIsEnabled)
        }
        for effect in effects {
            switch effect {
            case .send(let trigger):
                target.receive(trigger)
            case .reportSecureInputBlockedPress:
                target.secureInputBlockedPress()
            case .startSecureInputPolling:
                startSecureInputPolling()
            case .stopSecureInputPolling:
                stopSecureInputPolling()
            case .reenableModifierFlagTap:
                if let modifierFlagTap {
                    CGEvent.tapEnable(tap: modifierFlagTap.port, enable: true)
                }
            }
        }
    }

    private func startSecureInputPolling() {
        stopSecureInputPolling()
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 0.1,
            0.1,
            0,
            0
        ) { [weak self] _ in
            guard let self, self.isInstalled else { return }
            self.apply(
                self.state.secureInputPollFired(
                    secureInputEnabled: { IsSecureEventInputEnabled() }
                )
            )
        }
        secureInputPoll = timer
        CFRunLoopAddTimer(thread.runLoop, timer, .commonModes)
    }

    private func stopSecureInputPolling() {
        if let secureInputPoll {
            CFRunLoopTimerInvalidate(secureInputPoll)
        }
        secureInputPoll = nil
    }

    private static func mask(_ types: CGEventType...) -> CGEventMask {
        types.reduce(0) { $0 | CGEventMask(1) << $1.rawValue }
    }
}

private let shortcutModifierFlagTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let taps = Unmanaged<ShortcutEventTaps>.fromOpaque(userInfo).takeUnretainedValue()
    return taps.handle(type, event, from: .modifierFlags)
        ? nil
        : Unmanaged.passUnretained(event)
}

private let shortcutKeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let taps = Unmanaged<ShortcutEventTaps>.fromOpaque(userInfo).takeUnretainedValue()
    return taps.handle(type, event, from: .keys)
        ? nil
        : Unmanaged.passUnretained(event)
}
