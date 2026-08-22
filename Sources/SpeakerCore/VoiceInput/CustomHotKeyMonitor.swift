@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation

public struct CustomHotKey: Codable, Equatable, Sendable {
    public enum Trigger: Equatable, Sendable {
        case keyChord(keyCode: UInt32, modifiers: UInt32)
        case modifierOnly(keyCode: UInt32)
    }

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

    public static func modifierOnly(keyCode: UInt32) -> CustomHotKey? {
        let configuration: (modifiers: UInt32, displayName: String)? = switch Int(keyCode) {
        case kVK_Option: (UInt32(optionKey), "左 ⌥")
        case kVK_RightOption: (UInt32(optionKey), "右 ⌥")
        case kVK_Control: (UInt32(controlKey), "左 ⌃")
        case kVK_RightControl: (UInt32(controlKey), "右 ⌃")
        case kVK_Shift: (UInt32(shiftKey), "左 ⇧")
        case kVK_RightShift: (UInt32(shiftKey), "右 ⇧")
        default: nil
        }
        guard let configuration else { return nil }
        return CustomHotKey(
            keyCode: keyCode,
            modifiers: configuration.modifiers,
            displayName: configuration.displayName
        )
    }

    public var trigger: Trigger {
        if Self.modifierOnly(keyCode: keyCode)?.modifiers == modifiers {
            return .modifierOnly(keyCode: keyCode)
        }
        return .keyChord(keyCode: keyCode, modifiers: modifiers)
    }

    public var isModifierOnly: Bool {
        if case .modifierOnly = trigger { true } else { false }
    }

    package var modifierOnlyEventFlag: CGEventFlags? {
        guard isModifierOnly else { return nil }
        return switch Int(keyCode) {
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Shift, kVK_RightShift: .maskShift
        default: nil
        }
    }

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

    /// A supported physical modifier can be dedicated to Speaker. Key chords
    /// remain conservative: Option-Space is the single-modifier exception and
    /// every other chord needs two intent modifiers.
    public var isSafeForGlobalVoiceInput: Bool {
        if isModifierOnly { return true }
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

package struct ModifierOnlyFlagEventPolicy: Sendable {
    private let keyCode: Int64
    private let eventFlag: CGEventFlags
    private(set) var isDown = false

    package init?(hotKey: CustomHotKey) {
        guard let eventFlag = hotKey.modifierOnlyEventFlag else { return nil }
        keyCode = Int64(hotKey.keyCode)
        self.eventFlag = eventFlag
    }

    package mutating func handle(
        keyCode: Int64,
        flags: CGEventFlags
    ) -> ModifierFlagEventDisposition {
        guard keyCode == self.keyCode else { return .passThrough }
        if isDown {
            isDown = false
            return .consume(.released)
        }
        guard flags.contains(eventFlag) else { return .passThrough }
        isDown = true
        return .consume(.pressed)
    }

    package mutating func reset() {
        isDown = false
    }
}

package enum CustomShortcutRegistrationResult: Equatable, Sendable {
    case active
    case eventHandlerUnavailable(status: OSStatus)
    case hotKeyRegistrationUnavailable(status: OSStatus)
    case shortcutEventTapUnavailable
    case shortcutRunLoopSourceUnavailable
}

@MainActor
package final class CustomHotKeyMonitor {
    private let target: VoiceTriggerTarget
    private var box: CustomHotKeyBox?
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?

    package init(
        target: VoiceTriggerTarget
    ) {
        self.target = target
    }

    package var isRegistered: Bool {
        eventTap != nil && (hotKeyReference != nil || box?.modifierOnlyPolicy != nil)
    }

    @discardableResult
    package func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        unregister()

        let box = CustomHotKeyBox(target: target, hotKey: hotKey)
        var eventHandler: EventHandlerRef?
        var reference: EventHotKeyRef?
        if box.modifierOnlyPolicy == nil {
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

            let hotKeyID = EventHotKeyID(signature: 0x53504B52, id: 1)
            let registerStatus = RegisterEventHotKey(
                hotKey.keyCode,
                hotKey.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                OptionBits(0),
                &reference
            )
            guard registerStatus == noErr, reference != nil else {
                RemoveEventHandler(eventHandler)
                return .hotKeyRegistrationUnavailable(status: registerStatus)
            }
        }

        var eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        if box.modifierOnlyPolicy != nil {
            eventMask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: customShortcutEventTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            if let reference { UnregisterEventHotKey(reference) }
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return .shortcutEventTapUnavailable
        }
        guard let eventSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            if let reference { UnregisterEventHotKey(reference) }
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return .shortcutRunLoopSourceUnavailable
        }

        self.box = box
        eventHandlerReference = eventHandler
        hotKeyReference = reference
        self.eventTap = eventTap
        self.eventSource = eventSource
        box.eventTap = eventTap
        CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return .active
    }

    package func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        if let eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        box?.stop()
        hotKeyReference = nil
        eventHandlerReference = nil
        eventSource = nil
        eventTap = nil
        box = nil
    }

}

private final class CustomHotKeyBox: @unchecked Sendable {
    let target: VoiceTriggerTarget
    var eventTap: CFMachPort?
    var modifierOnlyPolicy: ModifierOnlyFlagEventPolicy?
    var isDown = false
    var didEmitPress = false
    var secureInputTimer: DispatchSourceTimer?
    var escapePolicy = EscapeKeyEventPolicy()

    init(target: VoiceTriggerTarget, hotKey: CustomHotKey) {
        self.target = target
        modifierOnlyPolicy = ModifierOnlyFlagEventPolicy(hotKey: hotKey)
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

    func handleEventTap(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            modifierOnlyPolicy?.reset()
            isDown = false
            didEmitPress = false
            escapePolicy.reset()
            stopSecureInputMonitoring()
            target.receive(.cancel)
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                target.receive(.monitorRecovered)
            }
            return false
        case .flagsChanged:
            guard var modifierOnlyPolicy else { return false }
            let disposition = modifierOnlyPolicy.handle(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags
            )
            self.modifierOnlyPolicy = modifierOnlyPolicy
            guard case let .consume(trigger) = disposition else { return false }
            switch trigger {
            case .pressed: pressed()
            case .released: released()
            }
            return true
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

private let customShortcutEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<CustomHotKeyBox>.fromOpaque(userInfo).takeUnretainedValue()
    return box.handleEventTap(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}
