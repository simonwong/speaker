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
    var didEmitPress = false
    var secureInputTimer: DispatchSourceTimer?

    init(handler: @escaping @Sendable (GlobalVoiceTrigger) -> Void) {
        self.handler = handler
    }

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let hadActivePress = didEmitPress
            fnIsDown = false
            didEmitPress = false
            stopSecureInputMonitoring()
            if hadActivePress {
                handler(.cancel)
            }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                handler(.monitorRecovered)
            }
        case .flagsChanged:
            let isDown = event.flags.contains(.maskSecondaryFn)
            guard isDown != fnIsDown else { return }
            fnIsDown = isDown
            if isDown {
                guard !IsSecureEventInputEnabled() else {
                    fnIsDown = false
                    return
                }
                didEmitPress = true
                handler(.pressed)
                startSecureInputMonitoring()
            } else {
                stopSecureInputMonitoring()
                if didEmitPress {
                    didEmitPress = false
                    handler(.released)
                }
            }
        case .keyDown:
            if fnIsDown, didEmitPress,
               event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                didEmitPress = false
                stopSecureInputMonitoring()
                handler(.cancel)
            }
        default:
            break
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
            self.handler(.cancel)
        }
        secureInputTimer = timer
        timer.resume()
    }

    private func stopSecureInputMonitoring() {
        secureInputTimer?.cancel()
        secureInputTimer = nil
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
    box.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
