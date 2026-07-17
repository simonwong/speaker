@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation

public struct CustomHotKey: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let displayName: String

    public init(keyCode: UInt32, modifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
    }

    public static let optionSpace = CustomHotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        displayName: "⌥ Space"
    )

    public var isReservedForCancellation: Bool {
        keyCode == UInt32(kVK_Escape)
    }

    public var conflictsWithCommonEditingShortcut: Bool {
        let relevantModifiers = modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let commandMenuModifiers = relevantModifiers & UInt32(cmdKey | optionKey | controlKey)
        guard commandMenuModifiers == UInt32(cmdKey) else { return false }
        return [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
            kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
            kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
            kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
            kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
            kVK_ANSI_Z,
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
            kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_RightBracket,
            kVK_ANSI_LeftBracket, kVK_ANSI_Quote, kVK_ANSI_Semicolon,
            kVK_ANSI_Backslash, kVK_ANSI_Comma, kVK_ANSI_Slash,
            kVK_ANSI_Period, kVK_ANSI_Grave, kVK_Space,
        ].contains(Int(keyCode))
    }

    /// Global hot keys must not overlap ordinary typing. Shift only changes
    /// typed characters, while a single Command/Option/Control modifier still
    /// collides with menus, dead keys, terminal control input or input-source
    /// shortcuts. Option-Space remains an explicit, familiar escape hatch;
    /// every other custom trigger needs two intent modifiers. Shift may be
    /// added, but never counts toward that minimum.
    public var isSafeForGlobalVoiceInput: Bool {
        let relevantModifiers = modifiers
            & UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard relevantModifiers != 0, !isReservedForCancellation else {
            return false
        }
        if keyCode == UInt32(kVK_Space),
           relevantModifiers == UInt32(optionKey)
        {
            return true
        }
        let intentModifiers = relevantModifiers
            & UInt32(cmdKey | optionKey | controlKey)
        return intentModifiers.nonzeroBitCount >= 2
    }
}

package enum CustomShortcutRegistrationResult: Equatable, Sendable {
    case active
    case eventHandlerUnavailable(status: OSStatus)
    case hotKeyRegistrationUnavailable(status: OSStatus)
    case escapeEventTapUnavailable
    case escapeRunLoopSourceUnavailable
}

@MainActor
package final class CustomHotKeyMonitor {
    private let target: VoiceTriggerTarget
    private var box: CustomHotKeyBox?
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var cancelTap: CFMachPort?
    private var cancelSource: CFRunLoopSource?

    package init(
        target: VoiceTriggerTarget
    ) {
        self.target = target
    }

    package var isRegistered: Bool { hotKeyReference != nil && cancelTap != nil }

    @discardableResult
    package func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        unregister()

        let box = CustomHotKeyBox(target: target)
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        var eventHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            customHotKeyCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(box).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr, let eventHandler else {
            return .eventHandlerUnavailable(status: handlerStatus)
        }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x53504B52, id: 1)
        let registerStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &reference
        )
        guard registerStatus == noErr, let reference else {
            RemoveEventHandler(eventHandler)
            return .hotKeyRegistrationUnavailable(status: registerStatus)
        }

        let escapeMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let cancelTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: escapeMask,
            callback: customCancelEventTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            UnregisterEventHotKey(reference)
            RemoveEventHandler(eventHandler)
            return .escapeEventTapUnavailable
        }
        guard let cancelSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            cancelTap,
            0
        ) else {
            CFMachPortInvalidate(cancelTap)
            UnregisterEventHotKey(reference)
            RemoveEventHandler(eventHandler)
            return .escapeRunLoopSourceUnavailable
        }

        self.box = box
        eventHandlerReference = eventHandler
        hotKeyReference = reference
        self.cancelTap = cancelTap
        self.cancelSource = cancelSource
        box.cancelTap = cancelTap
        CFRunLoopAddSource(CFRunLoopGetMain(), cancelSource, .commonModes)
        CGEvent.tapEnable(tap: cancelTap, enable: true)
        return .active
    }

    package func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        if let cancelSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), cancelSource, .commonModes)
        }
        if let cancelTap {
            CGEvent.tapEnable(tap: cancelTap, enable: false)
            CFMachPortInvalidate(cancelTap)
        }
        box?.stop()
        hotKeyReference = nil
        eventHandlerReference = nil
        cancelSource = nil
        cancelTap = nil
        box = nil
    }

}

private final class CustomHotKeyBox: @unchecked Sendable {
    let target: VoiceTriggerTarget
    var cancelTap: CFMachPort?
    var isDown = false
    var didEmitPress = false
    var secureInputTimer: DispatchSourceTimer?
    var escapePolicy = EscapeKeyEventPolicy()

    init(target: VoiceTriggerTarget) {
        self.target = target
    }

    func pressed() {
        guard !IsSecureEventInputEnabled() else { return }
        isDown = true
        didEmitPress = true
        target.receive(.pressed)
        startSecureInputMonitoring()
    }

    func released() {
        isDown = false
        stopSecureInputMonitoring()
        guard didEmitPress else { return }
        didEmitPress = false
        target.receive(.released)
    }

    func handleCancelTap(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            escapePolicy.reset()
            target.receive(.cancel)
            if let cancelTap {
                CGEvent.tapEnable(tap: cancelTap, enable: true)
                target.receive(.monitorRecovered)
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

    func stop() {
        let hadActivePress = didEmitPress
        isDown = false
        didEmitPress = false
        escapePolicy.reset()
        stopSecureInputMonitoring()
        if hadActivePress {
            target.receive(.cancel)
        }
    }

    private func startSecureInputMonitoring() {
        stopSecureInputMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isDown, self.didEmitPress else { return }
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
}

private let customHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let box = Unmanaged<CustomHotKeyBox>.fromOpaque(userData).takeUnretainedValue()
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        box.pressed()
    case UInt32(kEventHotKeyReleased):
        box.released()
    default:
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}

private let customCancelEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<CustomHotKeyBox>.fromOpaque(userInfo).takeUnretainedValue()
    return box.handleCancelTap(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}
