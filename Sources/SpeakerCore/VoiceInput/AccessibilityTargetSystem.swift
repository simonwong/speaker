import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import Foundation
import os

package enum AccessibilityTargetScope: Sendable {
    case element
    case window
}

/// `@unchecked` because `AXUIElement` is not annotated `Sendable`. The
/// reference is immutable, and the Accessibility API accepts an element from
/// any thread.
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
    /// A bounded window of the value around the selection, or `nil` when the
    /// value is unreadable or longer than
    /// `AccessibilityValueEvidenceLimits.maximumCharacterCount`. Without it,
    /// delivery is paste-only and the paste stays unconfirmed.
    package let valueSample: AccessibilityTextSample?
    package let processID: pid_t
    package let applicationName: String

    package init(
        reference: AccessibilityTargetReference,
        selection: NSRange?,
        valueSample: AccessibilityTextSample?,
        processID: pid_t,
        applicationName: String
    ) {
        self.reference = reference
        self.selection = selection
        self.valueSample = valueSample
        self.processID = processID
        self.applicationName = applicationName
    }
}

package struct AccessibilityReleaseTarget: Sendable {
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

package enum AccessibilityReleaseCapture: Sendable {
    case process(processID: pid_t)
    case target(AccessibilityReleaseTarget)
    case unavailable(processID: pid_t, reason: PendingCopyReason)

    package var processID: pid_t {
        switch self {
        case .process(let processID): processID
        case .target(let target): target.processID
        case .unavailable(let processID, _): processID
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
        return .success(
            NSRange(
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

/// An element-scope target receives an automatic paste only with a positive
/// sign that it edits text. Any one signal is enough; the costlier ones are
/// read only when the cheaper ones are missing.
package enum AccessibilityEditableSignal {
    package static let textRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        "AXSearchField",
    ]

    package static func isEditable(
        role: String?,
        subrole: String?,
        hasSelectedTextRange: Bool,
        isValueSettable: () -> Bool,
        hasEditableAncestor: () -> Bool
    ) -> Bool {
        if let role, textRoles.contains(role) { return true }
        if subrole == kAXSearchFieldSubrole { return true }
        if hasSelectedTextRange { return true }
        return isValueSettable() || hasEditableAncestor()
    }
}

package enum AccessibilityPasteResult: Equatable, Sendable {
    case posted
    case secureTarget
    case targetChanged
    case clipboardFailed
    /// The clipboard is too large to set aside and restore, so it was left
    /// untouched.
    case clipboardTooLarge
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
    /// Reads the part of the value in `range`, clamped to the value. Returns
    /// `nil` when the value is absent or longer than
    /// `AccessibilityValueEvidenceLimits.maximumCharacterCount`.
    func textSample(
        of target: AccessibilityTargetReference,
        in range: NSRange
    ) async -> AccessibilityOperationResult<AccessibilityTextSample?>
    func focusedState(
        _ target: AccessibilityTargetReference,
        in processID: pid_t
    ) async -> AccessibilityOperationResult<Bool>
    func isFrontmost(processID: pid_t) async -> Bool
    func selection(
        of target: AccessibilityTargetReference
    ) async -> AccessibilityOperationResult<NSRange?>
    /// Posts one Command-V. The user's clipboard comes back only after
    /// `receipt` concludes, as `PasteboardDeliveryTransaction` describes.
    func paste(
        _ text: String,
        to target: AccessibilityTargetReference,
        in processID: pid_t,
        receipt: PasteReceipt
    ) async -> AccessibilityPasteResult
    func shutdown() async
}

extension AccessibilityTargetSystem {
    package var captureDiagnostic: String? { nil }

    package func shutdown() async {}

    package func captureFocusedTarget(
        in processID: pid_t
    ) async -> AccessibilityTargetCapture {
        let capture = await captureFocusedTarget()
        guard case .writable(let evidence) = capture,
            evidence.processID != processID
        else { return capture }
        return .unavailable(.invalidatedTarget)
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
        @Sendable (String) async -> Result<
            PasteboardDeliveryTransaction, PasteboardPreparationFailure
        >
    private let focusedTargetState:
        (
            @Sendable (
                AccessibilityTargetReference,
                pid_t
            ) async -> AccessibilityOperationResult<Bool>
        )?
    private let postPasteCommand: @Sendable () async -> Bool
    private let pasteboardRestoreCoordinator: PasteboardRestoreCoordinator
    /// Shared by every copy of this value.
    private let lastCaptureDiagnostic = OSAllocatedUnfairLock<String?>(initialState: nil)

    package var captureDiagnostic: String? {
        lastCaptureDiagnostic.withLock { $0 }
    }

    private func recordCaptureDiagnostic(_ diagnostic: String) {
        lastCaptureDiagnostic.withLock { $0 = diagnostic }
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
            -> Result<PasteboardDeliveryTransaction, PasteboardPreparationFailure> = { text in
                await PasteboardDeliveryTransaction.prepare(text: text)
            },
        focusedTargetState:
            (
                @Sendable (
                    AccessibilityTargetReference,
                    pid_t
                ) async -> AccessibilityOperationResult<Bool>
            )? = nil,
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
        case .success(let value?):
            application = value
        case .success(nil):
            return .unavailable(.missingTarget)
        case .failure(let failure):
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
        case .success(let value?):
            focusedElement = AccessibilityTargetReference(element: value)
        case .success(nil), .failure(.attributeUnsupported),
            .failure(.notImplemented):
            focusedElement = nil
        case .failure(let failure):
            return .unavailable(failure.pendingCopyReason)
        }

        let focusedWindow: AccessibilityTargetReference?
        if focusedElement == nil {
            switch readElement(
                from: application,
                attribute: kAXFocusedWindowAttribute
            ) {
            case .success(let value?):
                focusedWindow = AccessibilityTargetReference(
                    element: value,
                    scope: .window
                )
            case .success(nil), .failure(.attributeUnsupported),
                .failure(.notImplemented):
                focusedWindow = nil
            case .failure(let failure):
                return .unavailable(failure.pendingCopyReason)
            }
        } else {
            focusedWindow = nil
        }

        guard
            let target = AccessibilityReleaseTargetSelection.select(
                focusedElement: focusedElement,
                focusedWindow: focusedWindow,
                processID: processID
            )
        else {
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
        let focusedAttribute =
            switch target.reference.scope {
            case .element: kAXFocusedUIElementAttribute
            case .window: kAXFocusedWindowAttribute
            }
        switch readElement(
            from: application,
            attribute: focusedAttribute
        ) {
        case .success(let focused?) where CFEqual(focused, expected):
            break
        case .success:
            return .unavailable(.invalidatedTarget)
        case .failure(let failure):
            return .unavailable(failure.pendingCopyReason)
        }
        return await inspectTarget(target)
    }

    private func inspectTarget(
        _ target: AccessibilityReleaseTarget
    ) async -> AccessibilityTargetCapture {
        guard let element = target.reference.element else {
            recordCaptureDiagnostic("inspect.invalidReference")
            return .unavailable(.invalidatedTarget)
        }
        _ = AXUIElementSetMessagingTimeout(element, 1)

        if target.reference.scope == .window {
            let runningApplication = NSRunningApplication(
                processIdentifier: target.processID
            )
            return .writable(
                .init(
                    reference: target.reference,
                    selection: nil,
                    valueSample: nil,
                    processID: target.processID,
                    applicationName: runningApplication?.localizedName
                        ?? Self.unknownApplicationName
                ))
        }

        let subrole: String?
        switch readString(from: element, attribute: kAXSubroleAttribute) {
        case .success(let value?) where value == kAXSecureTextFieldSubrole:
            return .unavailable(.secureTarget)
        case .success(let value):
            subrole = value
        case .failure(.attributeUnsupported), .failure(.notImplemented):
            subrole = nil
        case .failure(let failure):
            recordCaptureDiagnostic(
                "inspect.subrole.\(failure)"
            )
            return .unavailable(failure.pendingCopyReason)
        }

        let selection: NSRange?
        switch readRange(
            from: element,
            attribute: kAXSelectedTextRangeAttribute
        ) {
        case .success(let value?):
            selection = value
        case .success(nil), .failure(.attributeUnsupported),
            .failure(.notImplemented):
            selection = nil
        case .failure(let failure):
            recordCaptureDiagnostic(
                "inspect.selection.\(failure)"
            )
            return .unavailable(failure.pendingCopyReason)
        }

        let role: String?
        switch readString(from: element, attribute: kAXRoleAttribute) {
        case .success(let value):
            role = value
        case .failure(.attributeUnsupported), .failure(.notImplemented):
            role = nil
        case .failure(let failure):
            recordCaptureDiagnostic(
                "inspect.role.\(failure)"
            )
            return .unavailable(failure.pendingCopyReason)
        }
        let isEditable = AccessibilityEditableSignal.isEditable(
            role: role,
            subrole: subrole,
            hasSelectedTextRange: selection != nil,
            isValueSettable: {
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(
                    element,
                    kAXValueAttribute as CFString,
                    &settable
                ) == .success && settable.boolValue
            },
            hasEditableAncestor: {
                if case .success(.some) = readValue(
                    from: element,
                    attribute: Self.editableAncestorAttribute
                ) {
                    return true
                }
                return false
            }
        )
        guard isEditable else {
            recordCaptureDiagnostic("inspect.notEditable")
            return .unavailable(.missingTarget)
        }

        let valueSample: AccessibilityTextSample?
        switch readEvidenceSample(from: element, selection: selection) {
        case .success(let sample):
            valueSample = sample
        case .failure(.attributeUnsupported), .failure(.notImplemented):
            valueSample = nil
        case .failure(let failure):
            recordCaptureDiagnostic(
                "inspect.value.\(failure)"
            )
            return .unavailable(failure.pendingCopyReason)
        }

        let runningApplication = NSRunningApplication(
            processIdentifier: target.processID
        )
        return .writable(
            .init(
                reference: target.reference,
                selection: selection,
                valueSample: valueSample,
                processID: target.processID,
                applicationName: runningApplication?.localizedName ?? Self.unknownApplicationName
            ))
    }

    /// The Input Target's application name when macOS reports none. It only
    /// appears in adapter diagnostics, never in product copy or history.
    static let unknownApplicationName = "unknown"

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

    package func textSample(
        of target: AccessibilityTargetReference,
        in range: NSRange
    ) async -> AccessibilityOperationResult<AccessibilityTextSample?> {
        guard let element = target.element else {
            return .failure(.invalidUIElement)
        }
        switch readCharacterCount(from: element) {
        case .success(let length?):
            return readTextSample(from: element, in: range, length: length)
        case .success(nil), .failure(.attributeUnsupported),
            .failure(.notImplemented):
            return readWholeValueSample(from: element) {
                AccessibilityTextSample(value: $0, range: range)
            }
        case .failure(let failure):
            return .failure(failure)
        }
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
        let focusedAttribute =
            switch target.scope {
            case .element: kAXFocusedUIElementAttribute
            case .window: kAXFocusedWindowAttribute
            }
        switch readElement(
            from: application,
            attribute: focusedAttribute
        ) {
        case .success(let focused?):
            return .success(CFEqual(focused, expected))
        case .success(nil):
            return .success(false)
        case .failure(let failure):
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
        in processID: pid_t,
        receipt: PasteReceipt
    ) async -> AccessibilityPasteResult {
        guard canPostEvents(),
            let restoreReservation = await pasteboardRestoreCoordinator.reserve()
        else { return .eventFailed }
        guard !text.isEmpty else {
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .clipboardFailed
        }
        let transaction: PasteboardDeliveryTransaction
        switch await preparePasteboardTransaction(text) {
        case .success(let prepared):
            transaction = prepared
        case .failure(.tooLarge):
            await pasteboardRestoreCoordinator.abandon(restoreReservation)
            return .clipboardTooLarge
        case .failure(.unavailable):
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
        let focusState =
            if let focusedTargetState {
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
        case .failure(let failure):
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
            reservation: restoreReservation,
            receipt: receipt
        )
        return .posted
    }

    package func shutdown() async {
        await pasteboardRestoreCoordinator.shutdown()
    }

    /// Chromium and WebKit expose this on elements inside an editable region.
    private static let editableAncestorAttribute = "AXEditableAncestor"

    /// The capture-time evidence window. The length is read first so a long
    /// value is never transferred.
    private func readEvidenceSample(
        from element: AXUIElement,
        selection: NSRange?
    ) -> AccessibilityOperationResult<AccessibilityTextSample?> {
        switch readCharacterCount(from: element) {
        case .success(let length?):
            guard
                let range = AccessibilityValueEvidence.sampleRange(
                    around: selection,
                    length: length
                )
            else { return .success(nil) }
            return readTextSample(from: element, in: range, length: length)
        case .success(nil), .failure(.attributeUnsupported),
            .failure(.notImplemented):
            return readWholeValueSample(from: element) {
                AccessibilityTextSample.evidence(fromValue: $0, selection: selection)
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func readCharacterCount(
        from element: AXUIElement
    ) -> AccessibilityOperationResult<Int?> {
        switch readValue(
            from: element,
            attribute: kAXNumberOfCharactersAttribute
        ) {
        case .success(let value):
            return .success(value as? Int)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Reads `range` with `AXStringForRange`. A target that cannot read a
    /// range, or returns a window of the wrong length, falls back to the
    /// capped whole-value read.
    private func readTextSample(
        from element: AXUIElement,
        in range: NSRange,
        length: Int
    ) -> AccessibilityOperationResult<AccessibilityTextSample?> {
        guard length >= 0,
            length <= AccessibilityValueEvidenceLimits.maximumCharacterCount
        else { return .success(nil) }
        let clamped = AccessibilityValueEvidence.clamp(range, toLength: length)
        guard clamped.length > 0 else {
            return .success(
                AccessibilityTextSample(length: length, range: clamped, codeUnits: [])
            )
        }
        var cfRange = CFRange(location: clamped.location, length: clamped.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return .failure(.other)
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        switch error {
        case .success:
            if let text = value as? String {
                let sample = AccessibilityTextSample(
                    length: length,
                    range: clamped,
                    text: text
                )
                if sample.codeUnits.count == clamped.length {
                    return .success(sample)
                }
            }
        case .noValue, .parameterizedAttributeUnsupported,
            .attributeUnsupported, .notImplemented, .illegalArgument:
            break
        default:
            return .failure(map(error))
        }
        return readWholeValueSample(from: element) {
            AccessibilityTextSample(value: $0, range: range)
        }
    }

    /// The fallback for targets without `AXStringForRange`. The whole value
    /// still crosses IPC, but a value over the limit is never used.
    private func readWholeValueSample(
        from element: AXUIElement,
        sample: (String) -> AccessibilityTextSample?
    ) -> AccessibilityOperationResult<AccessibilityTextSample?> {
        switch readString(from: element, attribute: kAXValueAttribute) {
        case .success(let value?):
            guard
                value.utf16.count
                    <= AccessibilityValueEvidenceLimits.maximumCharacterCount
            else { return .success(nil) }
            return .success(sample(value))
        case .success(nil):
            return .success(nil)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func readElement(
        from element: AXUIElement,
        attribute: String
    ) -> AccessibilityOperationResult<AXUIElement?> {
        switch readValue(from: element, attribute: attribute) {
        case .success(let value):
            guard let value else { return .success(nil) }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .failure(.other)
            }
            return .success(unsafeDowncast(value, to: AXUIElement.self))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func readString(
        from element: AXUIElement,
        attribute: String
    ) -> AccessibilityOperationResult<String?> {
        switch readValue(from: element, attribute: attribute) {
        case .success(let value):
            return .success(value as? String)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func readRange(
        from element: AXUIElement,
        attribute: String
    ) -> AccessibilityOperationResult<NSRange?> {
        switch readValue(from: element, attribute: attribute) {
        case .success(let value):
            return AccessibilityTextRangeDecoder.decode(value)
        case .failure(let error):
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
