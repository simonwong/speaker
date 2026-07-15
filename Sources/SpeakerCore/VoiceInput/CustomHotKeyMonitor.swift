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
}

@MainActor
public final class CustomHotKeyMonitor {
    private let handler: @Sendable (GlobalVoiceTrigger) -> Void
    private var box: CustomHotKeyBox?
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var cancelTap: CFMachPort?
    private var cancelSource: CFRunLoopSource?

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

        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let cancelTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: customCancelEventTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ), let cancelSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            cancelTap,
            0
        ) else {
            UnregisterEventHotKey(reference)
            RemoveEventHandler(eventHandler)
            return false
        }

        self.box = box
        eventHandlerReference = eventHandler
        hotKeyReference = reference
        self.cancelTap = cancelTap
        self.cancelSource = cancelSource
        box.cancelTap = cancelTap
        CFRunLoopAddSource(CFRunLoopGetMain(), cancelSource, .commonModes)
        CGEvent.tapEnable(tap: cancelTap, enable: true)
        return true
    }

    public func unregister() {
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
    let handler: @Sendable (GlobalVoiceTrigger) -> Void
    var cancelTap: CFMachPort?
    var isDown = false
    var didEmitPress = false
    var secureInputTimer: DispatchSourceTimer?

    init(handler: @escaping @Sendable (GlobalVoiceTrigger) -> Void) {
        self.handler = handler
    }

    func pressed() {
        guard !IsSecureEventInputEnabled() else { return }
        isDown = true
        didEmitPress = true
        handler(.pressed)
        startSecureInputMonitoring()
    }

    func released() {
        isDown = false
        stopSecureInputMonitoring()
        guard didEmitPress else { return }
        didEmitPress = false
        handler(.released)
    }

    func handleCancelTap(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let cancelTap {
                CGEvent.tapEnable(tap: cancelTap, enable: true)
                handler(.monitorRecovered)
            }
        case .keyDown:
            guard isDown, didEmitPress,
                  event.getIntegerValueField(.keyboardEventKeycode) == 53
            else { return }
            didEmitPress = false
            stopSecureInputMonitoring()
            handler(.cancel)
        default:
            break
        }
    }

    func stop() {
        isDown = false
        didEmitPress = false
        stopSecureInputMonitoring()
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
            self.handler(.cancel)
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
    box.handleCancelTap(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
