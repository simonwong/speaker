@preconcurrency import ApplicationServices
import AppKit
import Foundation

public actor AccessibilityInputTargets: InputTargetCapturing, TextDelivering {
    private struct StoredTarget {
        let element: AXUIElement
        let selectedRange: CFTypeRef
        let originalValue: String?
    }

    private var targets: [UUID: StoredTarget] = [:]

    public init() {}

    public func capture() async -> InputTargetCaptureResult {
        guard AXIsProcessTrusted() else {
            return .unavailable(.unsupportedTarget)
        }

        let system = AXUIElementCreateSystemWide()
        guard let application = copyElement(
            from: system,
            attribute: "AXFocusedApplication"
        ), let element = copyElement(
            from: application,
            attribute: "AXFocusedUIElement"
        ) else {
            return .unavailable(.missingTarget)
        }

        if copyString(from: element, attribute: "AXSubrole") == "AXSecureTextField" {
            return .unavailable(.secureTarget)
        }

        guard let selectedRange = copyValue(
            from: element,
            attribute: "AXSelectedTextRange"
        ) else {
            return .unavailable(.unsupportedTarget)
        }

        var selectedTextSettable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            element,
            "AXSelectedText" as CFString,
            &selectedTextSettable
        )
        guard settableError == .success, selectedTextSettable.boolValue else {
            return .unavailable(.unsupportedTarget)
        }

        let pid = processIdentifier(of: application)
        let applicationName = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? "未知应用"
        let id = UUID()
        targets[id] = StoredTarget(
            element: element,
            selectedRange: selectedRange,
            originalValue: copyString(from: element, attribute: "AXValue")
        )
        return .writable(.init(id: id, applicationName: applicationName))
    }

    public func deliver(
        _ text: String,
        to target: InputTargetSnapshot
    ) async -> DeliveryOutcome {
        guard let stored = targets.removeValue(forKey: target.id) else {
            return .pendingCopy(.invalidatedTarget)
        }

        if copyString(from: stored.element, attribute: "AXSubrole") == "AXSecureTextField" {
            return .pendingCopy(.secureTarget)
        }

        guard copyValue(from: stored.element, attribute: "AXRole") != nil else {
            return .pendingCopy(.invalidatedTarget)
        }

        if let originalValue = stored.originalValue,
           copyString(from: stored.element, attribute: "AXValue") != originalValue {
            return .pendingCopy(.changedTarget)
        }

        let rangeResult = AXUIElementSetAttributeValue(
            stored.element,
            "AXSelectedTextRange" as CFString,
            stored.selectedRange
        )
        guard rangeResult == .success else {
            return .pendingCopy(map(rangeResult))
        }

        let textResult = AXUIElementSetAttributeValue(
            stored.element,
            "AXSelectedText" as CFString,
            text as CFString
        )
        guard textResult == .success else {
            return .pendingCopy(map(textResult))
        }
        return .delivered
    }

    private func copyElement(
        from element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        guard let value = copyValue(from: element, attribute: attribute) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyString(
        from element: AXUIElement,
        attribute: String
    ) -> String? {
        copyValue(from: element, attribute: attribute) as? String
    }

    private func copyValue(
        from element: AXUIElement,
        attribute: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        return error == .success ? value : nil
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func map(_ error: AXError) -> PendingCopyReason {
        switch error {
        case .invalidUIElement:
            .invalidatedTarget
        case .attributeUnsupported, .notImplemented:
            .unsupportedTarget
        case .cannotComplete:
            .deliveryFailed
        default:
            .deliveryFailed
        }
    }
}
