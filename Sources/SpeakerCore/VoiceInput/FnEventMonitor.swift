@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation

public enum GlobalVoiceTrigger: Equatable, Sendable {
    case pressed
    case released
    case cancel
    case monitorRecovered
}

@MainActor
public final class FnEventMonitor {
    private let handler: @Sendable (GlobalVoiceTrigger) -> Void
    private var box: FnEventTapBox?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(handler: @escaping @Sendable (GlobalVoiceTrigger) -> Void) {
        self.handler = handler
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }

        let box = FnEventTapBox(handler: handler)
        let mask = eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: fnEventTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        box.tap = tap
        self.box = box
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        guard let tap else { return }
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
    let handler: @Sendable (GlobalVoiceTrigger) -> Void
    var tap: CFMachPort?
    var fnIsDown = false

    init(handler: @escaping @Sendable (GlobalVoiceTrigger) -> Void) {
        self.handler = handler
    }

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                handler(.monitorRecovered)
            }
        case .flagsChanged:
            let isDown = event.flags.contains(.maskSecondaryFn)
            guard isDown != fnIsDown else { return }
            fnIsDown = isDown
            if isDown {
                guard !IsSecureEventInputEnabled() else { return }
                handler(.pressed)
            } else {
                handler(.released)
            }
        case .keyDown:
            if fnIsDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                handler(.cancel)
            }
        default:
            break
        }
    }
}

private let fnEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let box = Unmanaged<FnEventTapBox>.fromOpaque(userInfo).takeUnretainedValue()
    box.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
