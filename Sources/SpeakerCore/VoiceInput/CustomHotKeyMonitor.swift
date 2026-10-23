@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation

public struct CustomHotKey: Codable, Equatable, Sendable {
    public enum PhysicalModifier: Equatable, Sendable {
        case leftOption
        case rightOption
        case leftControl
        case rightControl
        case leftShift
        case rightShift

        public init?(keyCode: UInt32) {
            switch Int(keyCode) {
            case kVK_Option: self = .leftOption
            case kVK_RightOption: self = .rightOption
            case kVK_Control: self = .leftControl
            case kVK_RightControl: self = .rightControl
            case kVK_Shift: self = .leftShift
            case kVK_RightShift: self = .rightShift
            default: return nil
            }
        }

        public var keyCode: UInt32 {
            switch self {
            case .leftOption: UInt32(kVK_Option)
            case .rightOption: UInt32(kVK_RightOption)
            case .leftControl: UInt32(kVK_Control)
            case .rightControl: UInt32(kVK_RightControl)
            case .leftShift: UInt32(kVK_Shift)
            case .rightShift: UInt32(kVK_RightShift)
            }
        }

        fileprivate var carbonModifiers: UInt32 {
            switch self {
            case .leftOption, .rightOption: UInt32(optionKey)
            case .leftControl, .rightControl: UInt32(controlKey)
            case .leftShift, .rightShift: UInt32(shiftKey)
            }
        }

        fileprivate var eventFlag: CGEventFlags {
            switch self {
            case .leftOption, .rightOption: .maskAlternate
            case .leftControl, .rightControl: .maskControl
            case .leftShift, .rightShift: .maskShift
            }
        }
    }

    public enum Trigger: Equatable, Sendable {
        case keyChord(keyCode: UInt32, modifiers: UInt32)
        case modifierOnly(PhysicalModifier)
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

    public static func modifierOnly(
        _ modifier: PhysicalModifier,
        displayName: String
    ) -> CustomHotKey {
        return CustomHotKey(
            keyCode: modifier.keyCode,
            modifiers: modifier.carbonModifiers,
            displayName: displayName
        )
    }

    public var trigger: Trigger {
        if let modifier = PhysicalModifier(keyCode: keyCode),
            modifier.carbonModifiers == modifiers
        {
            return .modifierOnly(modifier)
        }
        return .keyChord(keyCode: keyCode, modifiers: modifiers)
    }

    public var isModifierOnly: Bool {
        if case .modifierOnly = trigger { true } else { false }
    }

    package var modifierOnlyEventFlag: CGEventFlags? {
        guard case .modifierOnly(let modifier) = trigger else { return nil }
        return modifier.eventFlag
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
        let relevantModifiers =
            modifiers
            & UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard relevantModifiers != 0, !isReservedForCancellation else {
            return false
        }
        if keyCode == UInt32(kVK_Space),
            relevantModifiers == UInt32(optionKey)
        {
            return true
        }
        let intentModifiers =
            relevantModifiers
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

/// Registers a key chord as a Carbon hot key, or observes a single physical
/// modifier through `ShortcutEventTaps`. Both deliver edges to the shortcut
/// event tap thread, which also watches Escape while a session can use it.
@MainActor
package final class CustomHotKeyMonitor {
    private let target: VoiceTriggerTarget
    private var taps: ShortcutEventTaps?
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    package init(
        target: VoiceTriggerTarget
    ) {
        self.target = target
    }

    package var isRegistered: Bool {
        taps != nil
    }

    @discardableResult
    package func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        unregister()

        let modifierOnlyPolicy = ModifierOnlyFlagEventPolicy(hotKey: hotKey)
        let taps = ShortcutEventTaps(
            target: target,
            flagTrigger: modifierOnlyPolicy.map { .modifierOnly($0) } ?? .none
        )
        var eventHandler: EventHandlerRef?
        var reference: EventHotKeyRef?
        if modifierOnlyPolicy == nil {
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
                Unmanaged.passUnretained(taps).toOpaque(),
                &eventHandler
            )
            guard handlerStatus == noErr, let eventHandler else {
                return .eventHandlerUnavailable(status: handlerStatus)
            }

            let hotKeyID = SpeakerHotKeyIdentifier.voiceInput.eventHotKeyID
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

        if let failure = taps.install() {
            if let reference { UnregisterEventHotKey(reference) }
            if let eventHandler { RemoveEventHandler(eventHandler) }
            switch failure {
            case .eventTapUnavailable:
                return .shortcutEventTapUnavailable
            case .runLoopSourceUnavailable:
                return .shortcutRunLoopSourceUnavailable
            }
        }

        self.taps = taps
        eventHandlerReference = eventHandler
        hotKeyReference = reference
        return .active
    }

    package func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        taps?.uninstall()
        hotKeyReference = nil
        eventHandlerReference = nil
        taps = nil
    }

    deinit {
        taps?.uninstallLater()
    }
}

/// Carbon hands every hot key the App registers to every handler installed on
/// the application target, so the handler acts only on its own identifier
/// and passes the others along.
package enum SpeakerHotKeyIdentifier: UInt32, Sendable {
    case voiceInput = 1

    private static let signature: OSType = 0x5350_4B52

    package var eventHotKeyID: EventHotKeyID {
        EventHotKeyID(signature: Self.signature, id: rawValue)
    }

    package func matches(_ event: EventRef) -> Bool {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        return status == noErr && hotKeyID.signature == Self.signature
            && hotKeyID.id == rawValue
    }
}

private let customHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData, SpeakerHotKeyIdentifier.voiceInput.matches(event) else {
        return OSStatus(eventNotHandledErr)
    }
    let taps = Unmanaged<ShortcutEventTaps>.fromOpaque(userData).takeUnretainedValue()
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        taps.shortcutPressed()
    case UInt32(kEventHotKeyReleased):
        taps.shortcutReleased()
    default:
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}
