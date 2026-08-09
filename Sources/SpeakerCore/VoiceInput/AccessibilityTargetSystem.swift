@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import AppKit
import Foundation

package enum AccessibilityTargetScope: Sendable {
    case element
    case window
}

package struct AccessibilityTargetReference: @unchecked Sendable, Equatable {
    package let id: UUID
    package let scope: AccessibilityTargetScope
    fileprivate let element: AXUIElement?

    package init(
        id: UUID = UUID(),
        scope: AccessibilityTargetScope = .element
    ) {
        self.id = id
        self.scope = scope
        element = nil
    }

    fileprivate init(
        element: AXUIElement,
        scope: AccessibilityTargetScope = .element
    ) {
        id = UUID()
        self.scope = scope
        self.element = element
    }

    package static func == (
        lhs: AccessibilityTargetReference,
        rhs: AccessibilityTargetReference
    ) -> Bool {
        lhs.id == rhs.id
    }
}

package enum AccessibilityReleaseTargetSelection {
    package static func select(
        focusedElement: AccessibilityTargetReference?,
        focusedWindow: AccessibilityTargetReference?,
        processID: pid_t
    ) -> AccessibilityReleaseTarget? {
        guard let reference = focusedElement ?? focusedWindow else {
            return nil
        }
        return AccessibilityReleaseTarget(
            reference: reference,
            processID: processID
        )
    }
}

package struct AccessibilityTargetEvidence: Sendable {
    package let reference: AccessibilityTargetReference
    package let selection: NSRange?
    package let originalValue: String?
    package let processID: pid_t
    package let applicationName: String

    package init(
        reference: AccessibilityTargetReference,
        selection: NSRange?,
        originalValue: String?,
        processID: pid_t,
        applicationName: String
    ) {
        self.reference = reference
        self.selection = selection
        self.originalValue = originalValue
        self.processID = processID
        self.applicationName = applicationName
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
    case process(processID: pid_t)
    case target(AccessibilityReleaseTarget)
    case unavailable(processID: pid_t, reason: PendingCopyReason)

    package var processID: pid_t {
        switch self {
        case let .process(processID): processID
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

package enum AccessibilityTextRangeDecoder {
    package static func decode(
        _ value: CFTypeRef?
    ) -> AccessibilityOperationResult<NSRange?> {
        guard let value else { return .success(nil) }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return .success(nil)
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return .success(nil)
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return .failure(.other)
        }
        return .success(NSRange(
            location: range.location,
            length: range.length
        ))
    }
}

package enum AccessibilityAttributeReadPolicy {
    package static func isAbsent(_ error: AXError) -> Bool {
        error == .noValue
    }
}

package enum AccessibilityPasteResult: Equatable, Sendable {
    case posted
    case secureTarget
    case targetChanged
    case clipboardFailed
    case eventFailed
    case targetFailure(AccessibilityOperationFailure)
}

package protocol AccessibilityTargetSystem: Sendable {
    var captureDiagnostic: String? { get }
    func captureFocusedTarget() async -> AccessibilityTargetCapture
    func captureFocusedTarget(
        in processID: pid_t
    ) async -> AccessibilityTargetCapture
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
    func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool>
    func isFrontmost(processID: pid_t) async -> Bool
    func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?>
    func paste(
        _ text: String,
        to target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityPasteResult
    func shutdown() async
}

package extension AccessibilityTargetSystem {
    var captureDiagnostic: String? { nil }

    func shutdown() async {}

    func captureFocusedTarget(
        in processID: pid_t
    ) async -> AccessibilityTargetCapture {
        let capture = await captureFocusedTarget()
        guard case let .writable(evidence) = capture,
              evidence.processID != processID
        else { return capture }
        return .unavailable(.invalidatedTarget)
    }
}

private final class AccessibilityCaptureDiagnosticBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        lock.withLock { storedValue }
    }

    func set(_ value: String) {
        lock.withLock { storedValue = value }
    }
}

package struct LiveAccessibilityTargetSystem: AccessibilityTargetSystem {
    private enum RawReadResult {
        case success(CFTypeRef?)
        case failure(AccessibilityOperationFailure)
    }

    private let isProcessTrusted: @Sendable () -> Bool
    private let isSecureInputEnabled: @Sendable () -> Bool
    private let frontmostProcessIdentifier: @Sendable () -> pid_t
    private let canPostEvents: @Sendable () -> Bool
    private let preparePasteboardTransaction:
        @Sendable (String) async -> PasteboardDeliveryTransaction?
    private let focusedTargetState:
        (@Sendable (
            AccessibilityTargetReference,
            pid_t
        ) async -> AccessibilityOperationResult<Bool>)?
    private let postPasteCommand: @Sendable () async -> Bool
    private let pasteboardRestoreCoordinator: PasteboardRestoreCoordinator
    private let captureDiagnosticBox = AccessibilityCaptureDiagnosticBox()

    package var captureDiagnostic: String? {
        captureDiagnosticBox.value
    }

    package init(
        isProcessTrusted: @escaping @Sendable () -> Bool = {
            AXIsProcessTrusted()
        },
        isSecureInputEnabled: @escaping @Sendable () -> Bool = {
            IsSecureEventInputEnabled()
        },
        frontmostProcessIdentifier: @escaping @Sendable () -> pid_t = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        },
        canPostEvents: @escaping @Sendable () -> Bool = {
            CGPreflightPostEventAccess()
        },
        preparePasteboardTransaction:
            @escaping @Sendable (String) async
                -> PasteboardDeliveryTransaction? = { text in
                    await PasteboardDeliveryTransaction.prepare(text: text)
                },
        focusedTargetState:
            (@Sendable (
                AccessibilityTargetReference,
                pid_t
            ) async -> AccessibilityOperationResult<Bool>)? = nil,
        postPasteCommand: @escaping @Sendable () async -> Bool = {
            await PasteboardDeliveryTransaction.postCommandV()
        },
        pasteboardRestoreCoordinator: PasteboardRestoreCoordinator = .init()
    ) {
        self.isProcessTrusted = isProcessTrusted
        self.isSecureInputEnabled = isSecureInputEnabled
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.canPostEvents = canPostEvents
        self.preparePasteboardTransaction = preparePasteboardTransaction
        self.focusedTargetState = focusedTargetState
        self.postPasteCommand = postPasteCommand
        self.pasteboardRestoreCoordinator = pasteboardRestoreCoordinator
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
        return await captureFocusedTarget(
            in: application,
            processID: processIdentifier(of: application)
        )
    }

    /// Freezes only the frontmost process inside the physical release callback.
    /// Target-App AX IPC must wait until the event tap has returned, otherwise
    /// the callback can prevent that App from servicing the AX request.
    package func captureReleaseProcess() -> AccessibilityReleaseCapture {
        let frontmostProcessID = frontmostProcessIdentifier()
        guard frontmostProcessID > 0 else {
            return .unavailable(
                processID: frontmostProcessID,
                reason: .missingTarget
            )
        }
        return .process(processID: frontmostProcessID)
    }

    package func captureFocusedTarget(
        in processID: pid_t
    ) async -> AccessibilityTargetCapture {
        guard isProcessTrusted() else {
            return .unavailable(.accessibilityPermissionMissing)
        }
        guard !isSecureInputEnabled() else {
            return .unavailable(.secureTarget)
        }
        guard frontmostProcessIdentifier() == processID else {
            return .unavailable(.invalidatedTarget)
        }
        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(application, 1)
        return await captureFocusedTarget(
            in: application,
            processID: processID
        )
    }

    private func captureFocusedTarget(
        in application: AXUIElement,
        processID: pid_t
    ) async -> AccessibilityTargetCapture {
        let focusedElement: AccessibilityTargetReference?
        switch readElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute
        ) {
        case let .success(value?):
            focusedElement = AccessibilityTargetReference(element: value)
        case .success(nil), .failure(.attributeUnsupported),
             .failure(.notImplemented):
            focusedElement = nil
        case let .failure(failure):
            return .unavailable(failure.pendingCopyReason)
        }

        let focusedWindow: AccessibilityTargetReference?
        if focusedElement == nil {
            switch readElement(
                from: application,
                attribute: kAXFocusedWindowAttribute
            ) {
            case let .success(value?):
                focusedWindow = AccessibilityTargetReference(
                    element: value,
                    scope: .window
                )
            case .success(nil), .failure(.attributeUnsupported),
                 .failure(.notImplemented):
                focusedWindow = nil
            case let .failure(failure):
                return .unavailable(failure.pendingCopyReason)
            }
        } else {
            focusedWindow = nil
        }

        guard let target = AccessibilityReleaseTargetSelection.select(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow,
            processID: processID
        ) else {
            return .unavailable(.missingTarget)
        }
        return await inspectTarget(target)
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
        let focusedAttribute = switch target.reference.scope {
        case .element: kAXFocusedUIElementAttribute
        case .window: kAXFocusedWindowAttribute
        }
        switch readElement(
            from: application,
            attribute: focusedAttribute
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
            captureDiagnosticBox.set("inspect.invalidReference")
            return .unavailable(.invalidatedTarget)
        }
        _ = AXUIElementSetMessagingTimeout(element, 1)

        if target.reference.scope == .window {
            let runningApplication = NSRunningApplication(
                processIdentifier: target.processID
            )
            return .writable(.init(
                reference: target.reference,
                selection: nil,
                originalValue: nil,
                processID: target.processID,
                applicationName: runningApplication?.localizedName
                    ?? "未知应用"
            ))
        }

        switch readString(from: element, attribute: kAXSubroleAttribute) {
        case let .success(subrole?) where subrole == kAXSecureTextFieldSubrole:
            return .unavailable(.secureTarget)
        case .success, .failure(.attributeUnsupported),
             .failure(.notImplemented):
            break
        case let .failure(failure):
            captureDiagnosticBox.set(
                "inspect.subrole.\(failure)"
            )
            return .unavailable(failure.pendingCopyReason)
        }

        let selection: NSRange?
        switch readRange(
            from: element,
            attribute: kAXSelectedTextRangeAttribute
        ) {
        case let .success(value?):
            selection = value
        case .success(nil), .failure(.attributeUnsupported),
             .failure(.notImplemented):
            selection = nil
        case let .failure(failure):
            captureDiagnosticBox.set(
                "inspect.selection.\(failure)"
            )
            return .unavailable(failure.pendingCopyReason)
        }

        let originalValue: String?
        switch readString(
            from: element,
            attribute: kAXValueAttribute
        ) {
        case let .success(value?):
            originalValue = value
        case .success(nil), .failure(.attributeUnsupported),
             .failure(.notImplemented):
            originalValue = nil
        case let .failure(failure):
            captureDiagnosticBox.set(
                "inspect.value.\(failure)"
            )
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
            applicationName: runningApplication?.localizedName ?? "未知应用"
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

    package func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool> {
        guard let expected = target.element else {
            return .failure(.invalidUIElement)
        }
        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetMessagingTimeout(application, 1)
        let focusedAttribute = switch target.scope {
        case .element: kAXFocusedUIElementAttribute
        case .window: kAXFocusedWindowAttribute
        }
        switch readElement(
            from: application,
            attribute: focusedAttribute
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

    package func paste(
        _ text: String,
        to target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityPasteResult {
        guard canPostEvents(),
              let restoreReservation = await pasteboardRestoreCoordinator.reserve()
        else { return .eventFailed }
        guard !text.isEmpty,
              let transaction = await preparePasteboardTransaction(text)
        else {
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .clipboardFailed
        }

        try? await Task.sleep(for: .milliseconds(100))
        guard !isSecureInputEnabled() else {
            await transaction.restoreIfOwned()
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .secureTarget
        }
        guard frontmostProcessIdentifier() == processID else {
            await transaction.restoreIfOwned()
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .targetChanged
        }
        let focusState = if let focusedTargetState {
            await focusedTargetState(target, processID)
        } else {
            await focusedState(target, in: processID)
        }
        switch focusState {
        case .success(true):
            break
        case .success(false):
            await transaction.restoreIfOwned()
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .targetChanged
        case let .failure(failure):
            await transaction.restoreIfOwned()
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .targetFailure(failure)
        }
        guard await transaction.stillOwnsPasteboard() else {
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .clipboardFailed
        }
        guard canPostEvents() else {
            await transaction.restoreIfOwned()
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .eventFailed
        }
        guard await postPasteCommand() else {
            await transaction.restoreIfOwned()
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .eventFailed
        }
        await pasteboardRestoreCoordinator.schedule(
            transaction,
            reservation: restoreReservation
        )
        return .posted
    }

    package func shutdown() async {
        await pasteboardRestoreCoordinator.shutdown()
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
            return AccessibilityTextRangeDecoder.decode(value)
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
        if AccessibilityAttributeReadPolicy.isAbsent(error) {
            return .success(nil)
        }
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
