@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import AppKit
import Foundation

package struct AccessibilityTargetReference: @unchecked Sendable, Equatable {
    package let id: UUID
    fileprivate let element: AXUIElement?

    package init(id: UUID = UUID()) {
        self.id = id
        element = nil
    }

    fileprivate init(element: AXUIElement) {
        id = UUID()
        self.element = element
    }

    package static func == (
        lhs: AccessibilityTargetReference,
        rhs: AccessibilityTargetReference
    ) -> Bool {
        lhs.id == rhs.id
    }
}

package struct AccessibilityTargetEvidence: Sendable {
    package let reference: AccessibilityTargetReference
    package let selection: NSRange
    package let originalValue: String
    package let processID: pid_t
    package let applicationBundleIdentifier: String?
    package let applicationName: String
    package let supportsDirectInsertion: Bool

    package init(
        reference: AccessibilityTargetReference,
        selection: NSRange,
        originalValue: String,
        processID: pid_t,
        applicationBundleIdentifier: String?,
        applicationName: String,
        supportsDirectInsertion: Bool
    ) {
        self.reference = reference
        self.selection = selection
        self.originalValue = originalValue
        self.processID = processID
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
        self.supportsDirectInsertion = supportsDirectInsertion
    }
}

package struct AccessibilityReleaseTarget: @unchecked Sendable {
    package let reference: AccessibilityTargetReference
    package let processID: pid_t

    package init(
        reference: AccessibilityTargetReference,
        processID: pid_t
    ) {
        self.reference = reference
        self.processID = processID
    }
}

package enum AccessibilityReleaseCapture: @unchecked Sendable {
    case target(AccessibilityReleaseTarget)
    case unavailable(processID: pid_t, reason: PendingCopyReason)

    package var processID: pid_t {
        switch self {
        case let .target(target): target.processID
        case let .unavailable(processID, _): processID
        }
    }
}

package enum AccessibilityTargetCapture: Sendable {
    case writable(AccessibilityTargetEvidence)
    case unavailable(PendingCopyReason)
}

package enum AccessibilityOperationFailure: Equatable, Sendable {
    case invalidUIElement
    case attributeUnsupported
    case notImplemented
    case cannotComplete
    case other

    package var pendingCopyReason: PendingCopyReason {
        switch self {
        case .invalidUIElement:
            .invalidatedTarget
        case .attributeUnsupported, .notImplemented:
            .unsupportedTarget
        case .cannotComplete:
            .targetApplicationUnresponsive
        case .other:
            .deliveryFailed
        }
    }
}

package enum AccessibilityOperationResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(AccessibilityOperationFailure)
}

package protocol AccessibilityTargetSystem: Sendable {
    func captureFocusedTarget() async -> AccessibilityTargetCapture
    func captureTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture
    func secureInputEnabled() async -> Bool
    func subrole(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?>
    func role(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?>
    func value(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?>
    func setSelection(
        _ selection: NSRange,
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<Void>
    func setSelectedText(
        _ text: String,
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<Void>
    func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool>
    func isFrontmost(processID: pid_t) async -> Bool
    func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?>
    func postUnicode(_ text: String, to processID: pid_t) async -> Bool
}

package struct LiveAccessibilityTargetSystem: AccessibilityTargetSystem {
    private enum RawReadResult {
        case success(CFTypeRef?)
        case failure(AccessibilityOperationFailure)
    }

    private let isProcessTrusted: @Sendable () -> Bool

    package init(
        isProcessTrusted: @escaping @Sendable () -> Bool = {
            AXIsProcessTrusted()
        }
    ) {
        self.isProcessTrusted = isProcessTrusted
    }

    package func captureFocusedTarget() async -> AccessibilityTargetCapture {
        guard isProcessTrusted() else {
            return .unavailable(.accessibilityPermissionMissing)
        }
        guard !IsSecureEventInputEnabled() else {
            return .unavailable(.secureTarget)
        }

        let system = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(system, 1)
        let application: AXUIElement
        switch readElement(
            from: system,
            attribute: kAXFocusedApplicationAttribute
        ) {
        case let .success(value?):
            application = value
        case .success(nil):
            return .unavailable(.missingTarget)
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }
        let element: AXUIElement
        switch readElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute
        ) {
        case let .success(value?):
            element = value
        case .success(nil):
            return .unavailable(.missingTarget)
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }
        return await inspectTarget(
            AccessibilityReleaseTarget(
                reference: AccessibilityTargetReference(element: element),
                processID: processIdentifier(of: application)
            )
        )
    }

    /// Freezes the exact focused AX element inside the physical release
    /// callback. The 80 ms IPC budget keeps the event tap responsive; failure
    /// is intentionally represented by no exact target and later fails closed.
    package func captureReleaseTarget() -> AccessibilityReleaseCapture {
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier ?? 0
        guard isProcessTrusted() else {
            return .unavailable(
                processID: frontmostProcessID,
                reason: .accessibilityPermissionMissing
            )
        }
        guard !IsSecureEventInputEnabled() else {
            return .unavailable(
                processID: frontmostProcessID,
                reason: .secureTarget
            )
        }
        let system = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(system, 0.08)
        let application: AXUIElement
        switch readElement(
            from: system,
            attribute: kAXFocusedApplicationAttribute
        ) {
        case let .success(value?):
            application = value
        case .success(nil):
            return .unavailable(
                processID: frontmostProcessID,
                reason: .missingTarget
            )
        case let .failure(failure):
            return .unavailable(
                processID: frontmostProcessID,
                reason: failure.pendingCopyReason
            )
        }
        let element: AXUIElement
        switch readElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute
        ) {
        case let .success(value?):
            element = value
        case .success(nil):
            return .unavailable(
                processID: frontmostProcessID,
                reason: .missingTarget
            )
        case let .failure(failure):
            return .unavailable(
                processID: frontmostProcessID,
                reason: failure.pendingCopyReason
            )
        }
        return .target(
            AccessibilityReleaseTarget(
                reference: AccessibilityTargetReference(element: element),
                processID: processIdentifier(of: application)
            )
        )
    }

    package func captureTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture {
        guard isProcessTrusted() else {
            return .unavailable(.accessibilityPermissionMissing)
        }
        guard !IsSecureEventInputEnabled() else {
            return .unavailable(.secureTarget)
        }
        guard let expected = target.reference.element else {
            return .unavailable(.invalidatedTarget)
        }
        let application = AXUIElementCreateApplication(target.processID)
        _ = AXUIElementSetMessagingTimeout(application, 1)
        switch readElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute
        ) {
        case let .success(focused?) where CFEqual(focused, expected):
            break
        case .success:
            return .unavailable(.invalidatedTarget)
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }
        return await inspectTarget(target)
    }

    private func inspectTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture {
        guard let element = target.reference.element else {
            return .unavailable(.invalidatedTarget)
        }
        _ = AXUIElementSetMessagingTimeout(element, 1)

        switch readString(from: element, attribute: kAXSubroleAttribute) {
        case let .success(subrole?) where subrole == kAXSecureTextFieldSubrole:
            return .unavailable(.secureTarget)
        case .success, .failure(.attributeUnsupported),
             .failure(.notImplemented):
            break
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }

        let selection: NSRange
        switch readRange(
            from: element,
            attribute: kAXSelectedTextRangeAttribute
        ) {
        case let .success(value?):
            selection = value
        case .success(nil):
            return .unavailable(.unsupportedTarget)
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }

        let supportsDirectInsertion = await selectedTextIsSettable(element)

        let originalValue: String
        switch readString(
            from: element,
            attribute: kAXValueAttribute
        ) {
        case let .success(value?):
            originalValue = value
        case .success(nil):
            return .unavailable(.unsupportedTarget)
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }

        let runningApplication = NSRunningApplication(
            processIdentifier: target.processID
        )
        return .writable(.init(
            reference: target.reference,
            selection: selection,
            originalValue: originalValue,
            processID: target.processID,
            applicationBundleIdentifier: runningApplication?.bundleIdentifier,
            applicationName: runningApplication?.localizedName ?? "未知应用",
            supportsDirectInsertion: supportsDirectInsertion
        ))
    }

    package func secureInputEnabled() async -> Bool {
        IsSecureEventInputEnabled()
    }

    package func subrole(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        return readString(from: element, attribute: kAXSubroleAttribute)
    }

    package func role(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        return readString(from: element, attribute: kAXRoleAttribute)
    }

    package func value(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<String?> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        return readString(from: element, attribute: kAXValueAttribute)
    }

    package func setSelection(
        _ selection: NSRange,
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<Void> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        var range = CFRange(
            location: selection.location,
            length: selection.length
        )
        guard let value = AXValueCreate(.cfRange, &range) else {
            return .failure(.other)
        }
        return map(AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ))
    }

    package func setSelectedText(
        _ text: String,
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<Void> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        return map(AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ))
    }

    package func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool> {
        guard let expected = target.element else {
            return .failure(.invalidUIElement)
        }
        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(application, 1)
        switch readElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute
        ) {
        case let .success(focused?):
            return .success(CFEqual(focused, expected))
        case .success(nil):
            return .success(false)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    package func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        return readRange(
            from: element,
            attribute: kAXSelectedTextRangeAttribute
        )
    }

    package func isFrontmost(processID: pid_t) async -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }

    package func postUnicode(_ text: String, to processID: pid_t) async -> Bool {
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

    private func readElement(
        from element: AXUIElement,
        attribute: String
    ) -> AccessibilityOperationResult<AXUIElement?> {
        switch readValue(from: element, attribute: attribute) {
        case let .success(value):
            guard let value else { return .success(nil) }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .failure(.other)
            }
            return .success(unsafeDowncast(value, to: AXUIElement.self))
        case let .failure(error):
            return .failure(error)
        }
    }

    private func selectedTextIsSettable(_ element: AXUIElement) async -> Bool {
        for attempt in 0..<2 {
            var settable = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &settable
            )
            if error == .success {
                return settable.boolValue
            }
            guard error == .cannotComplete, attempt == 0 else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func readString(
        from element: AXUIElement,
        attribute: String
    ) -> AccessibilityOperationResult<String?> {
        switch readValue(from: element, attribute: attribute) {
        case let .success(value):
            return .success(value as? String)
        case let .failure(error):
            return .failure(error)
        }
    }

    private func readRange(
        from element: AXUIElement,
        attribute: String
    ) -> AccessibilityOperationResult<NSRange?> {
        switch readValue(from: element, attribute: attribute) {
        case let .success(value):
            guard let value else { return .success(nil) }
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return .failure(.other)
            }
            let axValue = unsafeDowncast(value, to: AXValue.self)
            guard AXValueGetType(axValue) == .cfRange else {
                return .failure(.other)
            }
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else {
                return .failure(.other)
            }
            return .success(NSRange(
                location: range.location,
                length: range.length
            ))
        case let .failure(error):
            return .failure(error)
        }
    }

    private func readValue(
        from element: AXUIElement,
        attribute: String
    ) -> RawReadResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard error == .success else {
            return .failure(map(error))
        }
        return .success(value)
    }

    private func map(
        _ result: AXError
    ) -> AccessibilityOperationResult<Void> {
        result == .success ? .success(()) : .failure(map(result))
    }

    private func map(_ error: AXError) -> AccessibilityOperationFailure {
        switch error {
        case .invalidUIElement:
            .invalidUIElement
        case .attributeUnsupported:
            .attributeUnsupported
        case .notImplemented:
            .notImplemented
        case .cannotComplete:
            .cannotComplete
        default:
            .other
        }
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}
