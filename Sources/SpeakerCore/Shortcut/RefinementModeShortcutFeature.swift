@preconcurrency import Carbon
import Combine
import Foundation

/// A global key chord that runs one action when pressed. It has no release
/// edge and no Escape handling, unlike the recording shortcut.
@MainActor
package protocol ActionShortcutMonitoring: AnyObject {
    var isRegistered: Bool { get }
    @discardableResult func register(
        _ hotKey: CustomHotKey
    ) -> CustomShortcutRegistrationResult
    func unregister()
}

/// Why a key chord cannot become the Refinement Mode shortcut.
package enum RefinementModeShortcutRejection: Equatable, Sendable {
    case modifierOnly
    case reservedForCancellation
    case editingConflict
    case unsafeShortcut
    case sameAsRecordingShortcut
}

package enum RefinementModeShortcutActivation: Equatable, Sendable {
    case notSet
    case active(CustomHotKey)
    /// The saved chord matches the recording shortcut, which keeps it.
    case conflict(CustomHotKey)
    case unavailable(CustomHotKey, CustomShortcutRegistrationResult)
    case stopped
}

/// Owns the optional shortcut that steps to the next Refinement Mode. It
/// validates a chord with the recording shortcut's safety rules, refuses the
/// recording shortcut itself, registers it as a Carbon hot key, and persists
/// the choice. What a press does belongs to the caller; the shortcut never
/// looks at the frontmost App.
@MainActor
package final class RefinementModeShortcutFeature: ObservableObject {
    package typealias RecordingShortcut = @MainActor () -> VoiceShortcutPreference
    package typealias PersistShortcut = @Sendable (CustomHotKey?) async throws -> Void

    @Published package private(set) var hotKey: CustomHotKey?
    @Published package private(set) var activation: RefinementModeShortcutActivation = .notSet
    @Published package private(set) var persistenceFailed = false

    private let monitor: any ActionShortcutMonitoring
    private let recordingShortcut: RecordingShortcut
    private let persist: PersistShortcut
    private var persistenceTask: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var hasUserSelection = false
    private var isShuttingDown = false

    package convenience init(
        action: @escaping @Sendable () -> Void,
        recordingShortcut: @escaping RecordingShortcut,
        persist: @escaping PersistShortcut
    ) {
        self.init(
            monitor: CarbonActionHotKeyMonitor(identifier: .refinementMode, action: action),
            recordingShortcut: recordingShortcut,
            persist: persist
        )
    }

    package init(
        monitor: any ActionShortcutMonitoring,
        recordingShortcut: @escaping RecordingShortcut,
        persist: @escaping PersistShortcut
    ) {
        self.monitor = monitor
        self.recordingShortcut = recordingShortcut
        self.persist = persist
    }

    /// The first rule `hotKey` breaks, or nil when it can step Refinement
    /// Modes. Only key chords qualify: a lone modifier is reserved for the
    /// recording shortcut.
    nonisolated package static func rejection(
        for hotKey: CustomHotKey,
        recordingShortcut: VoiceShortcutPreference
    ) -> RefinementModeShortcutRejection? {
        if hotKey.isModifierOnly { return .modifierOnly }
        if hotKey.isReservedForCancellation { return .reservedForCancellation }
        if hotKey.conflictsWithCommonEditingShortcut { return .editingConflict }
        if !hotKey.isSafeForGlobalVoiceInput { return .unsafeShortcut }
        if let recording = recordingShortcut.customHotKey, recording.hasSameKeys(as: hotKey) {
            return .sameAsRecordingShortcut
        }
        return nil
    }

    /// Whether `recording` would take the chord this shortcut uses.
    package func conflicts(withRecordingShortcut recording: CustomHotKey) -> Bool {
        hotKey?.hasSameKeys(as: recording) == true
    }

    /// Registers and saves `hotKey`, or returns why it was refused without
    /// changing anything.
    @discardableResult
    package func select(_ hotKey: CustomHotKey) -> RefinementModeShortcutRejection? {
        guard !isShuttingDown else { return nil }
        if let rejection = Self.rejection(for: hotKey, recordingShortcut: recordingShortcut()) {
            return rejection
        }
        hasUserSelection = true
        activate(hotKey)
        persistLater(hotKey)
        return nil
    }

    package func clear() {
        guard !isShuttingDown else { return }
        hasUserSelection = true
        monitor.unregister()
        hotKey = nil
        activation = .notSet
        persistLater(nil)
    }

    /// Applies the saved chord at launch. A chord saved before it became
    /// unsafe or equal to the recording shortcut stays saved but inactive.
    package func restore(_ hotKey: CustomHotKey?) {
        guard !isShuttingDown, !hasUserSelection else { return }
        guard let hotKey else {
            monitor.unregister()
            self.hotKey = nil
            activation = .notSet
            return
        }
        guard Self.rejection(for: hotKey, recordingShortcut: recordingShortcut()) == nil else {
            monitor.unregister()
            self.hotKey = hotKey
            activation = .conflict(hotKey)
            return
        }
        activate(hotKey)
    }

    package func retryPersistence() {
        guard !isShuttingDown, persistenceFailed else { return }
        persistLater(hotKey)
    }

    package func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        monitor.unregister()
        activation = .stopped
    }

    package func flushPersistence() async {
        await persistenceTask?.value
    }

    private func activate(_ hotKey: CustomHotKey) {
        self.hotKey = hotKey
        let result = monitor.register(hotKey)
        activation = result == .active ? .active(hotKey) : .unavailable(hotKey, result)
    }

    private func persistLater(_ hotKey: CustomHotKey?) {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previousTask = persistenceTask
        let persist = persist
        persistenceTask = Task { @MainActor [weak self, previousTask] in
            await previousTask?.value
            do {
                try await persist(hotKey)
                guard let self, generation == self.persistenceGeneration else { return }
                self.persistenceFailed = false
            } catch {
                guard let self, generation == self.persistenceGeneration else { return }
                self.persistenceFailed = true
            }
        }
    }
}

extension CustomHotKey {
    /// The same physical keys, whatever the display names say.
    package func hasSameKeys(as other: CustomHotKey) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// Registers one key chord as a Carbon hot key and runs `action` on each
/// press. Carbon calls the handler on the main thread; the action only
/// schedules work, so the handler returns immediately.
@MainActor
package final class CarbonActionHotKeyMonitor: ActionShortcutMonitoring {
    private let relay: ActionHotKeyRelay
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    package init(
        identifier: SpeakerHotKeyIdentifier,
        action: @escaping @Sendable () -> Void
    ) {
        relay = ActionHotKeyRelay(identifier: identifier, action: action)
    }

    package var isRegistered: Bool {
        hotKeyReference != nil
    }

    @discardableResult
    package func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        unregister()
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]
        var eventHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            actionHotKeyCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(relay).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr, let eventHandler else {
            return .eventHandlerUnavailable(status: handlerStatus)
        }
        var reference: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            relay.identifier.eventHotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &reference
        )
        guard registerStatus == noErr, let reference else {
            RemoveEventHandler(eventHandler)
            return .hotKeyRegistrationUnavailable(status: registerStatus)
        }
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
        hotKeyReference = nil
        eventHandlerReference = nil
    }
}

private final class ActionHotKeyRelay: Sendable {
    let identifier: SpeakerHotKeyIdentifier
    let action: @Sendable () -> Void

    init(identifier: SpeakerHotKeyIdentifier, action: @escaping @Sendable () -> Void) {
        self.identifier = identifier
        self.action = action
    }
}

private let actionHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let relay = Unmanaged<ActionHotKeyRelay>.fromOpaque(userData).takeUnretainedValue()
    guard relay.identifier.matches(event) else { return OSStatus(eventNotHandledErr) }
    relay.action()
    return noErr
}
