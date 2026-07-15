@preconcurrency import Carbon
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
}

@MainActor
public final class CustomHotKeyMonitor {
    private let handler: @Sendable (GlobalVoiceTrigger) -> Void
    private var box: CustomHotKeyBox?
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    public init(handler: @escaping @Sendable (GlobalVoiceTrigger) -> Void) {
        self.handler = handler
    }

    @discardableResult
    public func register(_ hotKey: CustomHotKey) -> Bool {
        unregister()

        let box = CustomHotKeyBox(handler: handler)
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
            return false
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
            return false
        }

        self.box = box
        eventHandlerReference = eventHandler
        hotKeyReference = reference
        return true
    }

    public func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        hotKeyReference = nil
        eventHandlerReference = nil
        box = nil
    }

}

private final class CustomHotKeyBox: @unchecked Sendable {
    let handler: @Sendable (GlobalVoiceTrigger) -> Void

    init(handler: @escaping @Sendable (GlobalVoiceTrigger) -> Void) {
        self.handler = handler
    }
}

private let customHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let box = Unmanaged<CustomHotKeyBox>.fromOpaque(userData).takeUnretainedValue()
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        box.handler(.pressed)
    case UInt32(kEventHotKeyReleased):
        box.handler(.released)
    default:
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}
