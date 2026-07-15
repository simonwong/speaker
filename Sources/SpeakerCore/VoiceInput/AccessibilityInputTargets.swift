@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import AppKit
import Foundation

public actor AccessibilityInputTargets: InputTargetCapturing, InputTargetDiscarding, TextDelivering {
    private struct StoredTarget {
        let element: AXUIElement
        let selectedRange: CFTypeRef
        let selection: CFRange
        let originalValue: String
        let processID: pid_t
        let bundleIdentifier: String?
        let supportsDirectInsertion: Bool
    }

    private var targets: [UUID: StoredTarget] = [:]
    private let verifiedUnicodeDeliveryBundleIdentifiers: Set<String>

    public init(verifiedUnicodeDeliveryBundleIdentifiers: Set<String> = []) {
        self.verifiedUnicodeDeliveryBundleIdentifiers = verifiedUnicodeDeliveryBundleIdentifiers
    }

    public func capture() async -> InputTargetCaptureResult {
        guard AXIsProcessTrusted() else {
            return .unavailable(.unsupportedTarget)
        }
        guard !IsSecureEventInputEnabled() else {
            return .unavailable(.secureTarget)
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
        ), let selection = extractRange(from: selectedRange) else {
            return .unavailable(.unsupportedTarget)
        }

        var selectedTextSettable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            element,
            "AXSelectedText" as CFString,
            &selectedTextSettable
        )
        let supportsDirectInsertion = settableError == .success
            && selectedTextSettable.boolValue

        guard let originalValue = copyString(from: element, attribute: "AXValue") else {
            return .unavailable(.unsupportedTarget)
        }

        let pid = processIdentifier(of: application)
        let runningApplication = NSRunningApplication(processIdentifier: pid)
        let applicationName = runningApplication?.localizedName ?? "未知应用"
        let id = UUID()
        targets[id] = StoredTarget(
            element: element,
            selectedRange: selectedRange,
            selection: selection,
            originalValue: originalValue,
            processID: pid,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            supportsDirectInsertion: supportsDirectInsertion
        )
        return .writable(.init(id: id, applicationName: applicationName))
    }

    public func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard let stored = targets.removeValue(forKey: target.id) else {
            return .pendingCopy(.invalidatedTarget)
        }

        if copyString(from: stored.element, attribute: "AXSubrole") == "AXSecureTextField" {
            return .pendingCopy(.secureTarget)
        }
        guard !IsSecureEventInputEnabled() else {
            return .pendingCopy(.secureTarget)
        }

        guard copyValue(from: stored.element, attribute: "AXRole") != nil else {
            return .pendingCopy(.invalidatedTarget)
        }

        if copyString(from: stored.element, attribute: "AXValue") != stored.originalValue {
            return .pendingCopy(.changedTarget)
        }

        guard let expectedValue = replacingSelection(in: stored, with: text) else {
            return .pendingCopy(.unsupportedTarget)
        }

        var directError: AXError?
        var committed = false
        if stored.supportsDirectInsertion {
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
            committed = true
            let rangeResult = AXUIElementSetAttributeValue(
                stored.element,
                "AXSelectedTextRange" as CFString,
                stored.selectedRange
            )
            directError = rangeResult
            if rangeResult == .success {
                guard copyString(from: stored.element, attribute: "AXValue") == stored.originalValue else {
                    return .pendingCopy(.changedTarget)
                }
                guard !IsSecureEventInputEnabled() else {
                    return .pendingCopy(.secureTarget)
                }
                let textResult = AXUIElementSetAttributeValue(
                    stored.element,
                    "AXSelectedText" as CFString,
                    text as CFString
                )
                directError = textResult
                if textResult == .success {
                    return copyString(from: stored.element, attribute: "AXValue") == expectedValue
                        ? .delivered
                        : .pendingCopy(.deliveryFailed)
                }
            }
        }

        // A PID-targeted event has no delivery receipt. Keep this adapter off
        // unless the current process was explicitly verified by local smoke.
        guard let bundleIdentifier = stored.bundleIdentifier,
              verifiedUnicodeDeliveryBundleIdentifiers.contains(bundleIdentifier)
        else {
            return .pendingCopy(directError.map(map) ?? .unsupportedTarget)
        }
        guard isStillFocused(stored.element) else {
            return .pendingCopy(.invalidatedTarget)
        }
        guard copyString(from: stored.element, attribute: "AXValue") == stored.originalValue else {
            return .pendingCopy(.changedTarget)
        }
        guard let currentSelection = copyValue(
            from: stored.element,
            attribute: "AXSelectedTextRange"
        ), CFEqual(currentSelection, stored.selectedRange) else {
            return .pendingCopy(.changedTarget)
        }
        if !committed {
            guard await commitGate.commit() else {
                return .pendingCopy(.deliveryFailed)
            }
        }
        guard !IsSecureEventInputEnabled() else {
            return .pendingCopy(.secureTarget)
        }
        guard postUnicode(text, to: stored.processID) else {
            return .pendingCopy(directError.map(map) ?? .deliveryFailed)
        }
        try? await Task.sleep(for: .milliseconds(80))
        return copyString(from: stored.element, attribute: "AXValue") == expectedValue
            ? .delivered
            : .pendingCopy(.deliveryFailed)
    }

    public func discard(_ target: InputTargetSnapshot) async {
        targets[target.id] = nil
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

    private func extractRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func replacingSelection(in stored: StoredTarget, with text: String) -> String? {
        let original = stored.originalValue as NSString
        let range = NSRange(
            location: stored.selection.location,
            length: stored.selection.length
        )
        guard range.location >= 0, range.length >= 0,
              NSMaxRange(range) <= original.length
        else { return nil }
        return original.replacingCharacters(in: range, with: text)
    }

    private func isStillFocused(_ expected: AXUIElement) -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let application = copyElement(
            from: system,
            attribute: "AXFocusedApplication"
        ), let focused = copyElement(
            from: application,
            attribute: "AXFocusedUIElement"
        ) else { return false }
        return CFEqual(focused, expected)
    }

    private func postUnicode(_ text: String, to processID: pid_t) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
              )
        else { return false }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
        }
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        return true
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
