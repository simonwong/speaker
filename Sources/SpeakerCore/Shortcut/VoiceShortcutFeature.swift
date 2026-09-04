import Combine
import Foundation

@MainActor
package protocol FunctionKeyMonitoring: AnyObject {
    var isRunning: Bool { get }
    @discardableResult func start() -> FunctionKeyMonitorStartResult
    func stop()
}

@MainActor
package protocol CustomShortcutMonitoring: AnyObject {
    var isRegistered: Bool { get }
    @discardableResult func register(
        _ hotKey: CustomHotKey
    ) -> CustomShortcutRegistrationResult
    func unregister()
}

extension FnEventMonitor: FunctionKeyMonitoring {}
extension CustomHotKeyMonitor: CustomShortcutMonitoring {}

package enum VoiceShortcutActivation: Equatable, Sendable {
    case waitingForAccessibility(VoiceShortcutPreference)
    case active(VoiceShortcutPreference)
    case unavailable(VoiceShortcutPreference)
    case stopped

    package var activePreference: VoiceShortcutPreference? {
        guard case .active(let preference) = self else { return nil }
        return preference
    }
}

package struct VoiceShortcutNotice: Equatable, Sendable {
    package enum Level: Equatable, Sendable {
        case information
        case warning
        case error
    }

    package enum Recovery: Equatable, Sendable {
        case openAccessibilitySettings
        case retryActivation
        case retryPersistence
    }

    package enum FallbackReason: Equatable, Sendable {
        case incompleteConfiguration
        case reservedForCancellation
        case editingConflict
        case unsafeShortcut
        case activationFailed(CustomShortcutRegistrationResult)
    }

    package enum Kind: Equatable, Sendable {
        case accessibilityRequired
        case functionKeyActivationFailed(FunctionKeyMonitorStartResult)
        case fellBackToFunctionKey(FallbackReason)
        case fallbackUnavailable(
            FallbackReason,
            FunctionKeyMonitorStartResult
        )
        case persistenceFailed
    }

    package let kind: Kind

    package var level: Level {
        switch kind {
        case .accessibilityRequired: .information
        case .fellBackToFunctionKey: .warning
        case .functionKeyActivationFailed,
            .fallbackUnavailable,
            .persistenceFailed:
            .error
        }
    }

    package var recovery: Recovery? {
        switch kind {
        case .accessibilityRequired: .openAccessibilitySettings
        case .functionKeyActivationFailed, .fallbackUnavailable:
            .retryActivation
        case .persistenceFailed: .retryPersistence
        case .fellBackToFunctionKey: nil
        }
    }
}

/// Owns the complete shortcut activation policy behind one command interface.
///
/// Callers do not coordinate the Fn event tap, Carbon hot key, Accessibility
/// permission, conflict fallback and settings persistence themselves. The live
/// App and deterministic specs use the same seam with different monitor
/// adapters.
@MainActor
package final class VoiceShortcutFeature: ObservableObject {
    package typealias AccessibilityCheck = @MainActor () -> Bool
    package typealias PersistPreference = @Sendable (VoiceShortcutPreference) async throws -> Void

    @Published package private(set) var preference: VoiceShortcutPreference = .functionKey
    @Published package private(set) var activation: VoiceShortcutActivation =
        .waitingForAccessibility(.functionKey)
    @Published package private(set) var notice: VoiceShortcutNotice?
    @Published package private(set) var persistenceConfirmation: VoiceShortcutPreference?

    private let functionKeyMonitor: any FunctionKeyMonitoring
    private let customShortcutMonitor: any CustomShortcutMonitoring
    private let accessibilityGranted: AccessibilityCheck
    private let persistPreference: PersistPreference
    private var persistenceGeneration = 0
    private var persistenceTask: Task<Void, Never>?
    private var hasUserSelection = false
    private var hasRestoredPreference = false
    private var isShuttingDown = false
    private var failedPersistencePreference: VoiceShortcutPreference?

    private static let accessibilityNotice = VoiceShortcutNotice(
        kind: .accessibilityRequired
    )

    package convenience init(
        target: VoiceTriggerTarget,
        accessibilityGranted: @escaping AccessibilityCheck,
        persistPreference: @escaping PersistPreference
    ) {
        self.init(
            functionKeyMonitor: FnEventMonitor(target: target),
            customShortcutMonitor: CustomHotKeyMonitor(target: target),
            accessibilityGranted: accessibilityGranted,
            persistPreference: persistPreference
        )
    }

    package init(
        functionKeyMonitor: any FunctionKeyMonitoring,
        customShortcutMonitor: any CustomShortcutMonitoring,
        accessibilityGranted: @escaping AccessibilityCheck,
        persistPreference: @escaping PersistPreference
    ) {
        self.functionKeyMonitor = functionKeyMonitor
        self.customShortcutMonitor = customShortcutMonitor
        self.accessibilityGranted = accessibilityGranted
        self.persistPreference = persistPreference
    }

    package func select(_ preference: VoiceShortcutPreference) {
        guard !isShuttingDown else { return }
        hasUserSelection = true
        hasRestoredPreference = true
        activate(preference, persist: true)
    }

    package func retryActivation() {
        guard !isShuttingDown else { return }
        activate(preference, persist: false)
    }

    package func retryPersistence() {
        guard !isShuttingDown, let failedPersistencePreference else { return }
        persistLater(failedPersistencePreference)
    }

    package func restore(_ preference: VoiceShortcutPreference) {
        guard !isShuttingDown else { return }
        hasRestoredPreference = true
        guard !hasUserSelection else { return }
        activate(preference, persist: false)
    }

    package func synchronize() {
        guard !isShuttingDown else { return }
        synchronizeActivation()
    }

    package func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        functionKeyMonitor.stop()
        customShortcutMonitor.unregister()
        activation = .stopped
    }

    package func flushPersistence() async {
        await persistenceTask?.value
    }

    private func activate(
        _ choice: VoiceShortcutPreference,
        persist: Bool
    ) {
        preference = choice
        guard accessibilityGranted() else {
            functionKeyMonitor.stop()
            customShortcutMonitor.unregister()
            activation = .waitingForAccessibility(choice)
            notice = Self.accessibilityNotice
            if persist { persistLater(choice) }
            return
        }

        switch choice {
        case .functionKey:
            customShortcutMonitor.unregister()
            let result = functionKeyMonitor.start()
            guard result == .active else {
                activation = .unavailable(.functionKey)
                notice = VoiceShortcutNotice(
                    kind: .functionKeyActivationFailed(result)
                )
                if persist { persistLater(.functionKey) }
                return
            }
        case .custom:
            functionKeyMonitor.stop()
            guard let hotKey = choice.customHotKey else {
                fallbackToFunctionKey(
                    reason: .incompleteConfiguration,
                    persist: true
                )
                return
            }
            guard !hotKey.isReservedForCancellation else {
                fallbackToFunctionKey(
                    reason: .reservedForCancellation,
                    persist: true
                )
                return
            }
            guard !hotKey.conflictsWithCommonEditingShortcut else {
                fallbackToFunctionKey(
                    reason: .editingConflict,
                    persist: persist
                )
                return
            }
            guard hotKey.isSafeForGlobalVoiceInput else {
                fallbackToFunctionKey(
                    reason: .unsafeShortcut,
                    persist: persist
                )
                return
            }
            let result = customShortcutMonitor.register(hotKey)
            guard result == .active else {
                fallbackToFunctionKey(
                    reason: .activationFailed(result),
                    persist: persist
                )
                return
            }
        }

        preference = choice
        activation = .active(choice)
        notice = nil
        if persist { persistLater(choice) }
    }

    private func synchronizeActivation() {
        guard hasRestoredPreference else { return }
        guard accessibilityGranted() else {
            functionKeyMonitor.stop()
            customShortcutMonitor.unregister()
            activation = .waitingForAccessibility(preference)
            notice = Self.accessibilityNotice
            return
        }

        switch preference {
        case .functionKey where !functionKeyMonitor.isRunning:
            activate(.functionKey, persist: false)
        case .custom where !customShortcutMonitor.isRegistered:
            activate(preference, persist: false)
        case .functionKey, .custom:
            break
        }
    }

    private func fallbackToFunctionKey(
        reason: VoiceShortcutNotice.FallbackReason,
        persist: Bool
    ) {
        customShortcutMonitor.unregister()
        preference = .functionKey
        let result = functionKeyMonitor.start()
        if result == .active {
            activation = .active(.functionKey)
            notice = VoiceShortcutNotice(
                kind: .fellBackToFunctionKey(reason)
            )
        } else {
            activation = .unavailable(.functionKey)
            notice = VoiceShortcutNotice(
                kind: .fallbackUnavailable(reason, result)
            )
        }
        if persist { persistLater(.functionKey) }
    }

    private func persistLater(_ choice: VoiceShortcutPreference) {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previousTask = persistenceTask
        persistenceTask = Task { @MainActor [weak self, previousTask] in
            await previousTask?.value
            guard let self else { return }
            do {
                try await self.persistPreference(choice)
                guard generation == self.persistenceGeneration else { return }
                self.failedPersistencePreference = nil
                let recoveredFromFailure = self.notice?.recovery == .retryPersistence
                if recoveredFromFailure {
                    self.notice = nil
                    self.persistenceConfirmation = choice
                }
            } catch {
                guard generation == self.persistenceGeneration else { return }
                self.failedPersistencePreference = choice
                self.notice = VoiceShortcutNotice(
                    kind: .persistenceFailed
                )
            }
        }
    }
}
