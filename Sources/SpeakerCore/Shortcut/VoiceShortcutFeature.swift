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
        guard case let .active(preference) = self else { return nil }
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

    package let message: String
    package let level: Level
    package let recovery: Recovery?

    package init(message: String, level: Level, recovery: Recovery? = nil) {
        self.message = message
        self.level = level
        self.recovery = recovery
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
    @Published package private(set) var persistenceConfirmation: String?

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
        message: "需要辅助功能权限；授权后，已选择的快捷键会自动生效。",
        level: .information,
        recovery: .openAccessibilitySettings
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
                    message: functionKeyFailureMessage(result),
                    level: .error,
                    recovery: .retryActivation
                )
                if persist { persistLater(.functionKey) }
                return
            }
        case .custom:
            functionKeyMonitor.stop()
            guard let hotKey = choice.customHotKey else {
                fallbackToFunctionKey(
                    reason: "自定义快捷键配置不完整",
                    persist: true
                )
                return
            }
            guard !hotKey.isReservedForCancellation else {
                fallbackToFunctionKey(
                    reason: "Esc 保留用于取消当前语音输入",
                    persist: true
                )
                return
            }
            guard !hotKey.conflictsWithCommonEditingShortcut else {
                fallbackToFunctionKey(
                    reason: "这个组合键可能与 macOS 或当前 App 的菜单命令冲突",
                    persist: persist
                )
                return
            }
            guard hotKey.isSafeForGlobalVoiceInput else {
                fallbackToFunctionKey(
                    reason: "单个修饰键可能干扰正常输入；请使用 ⌥ Space 或至少两个 ⌘/⌥/⌃ 修饰键",
                    persist: persist
                )
                return
            }
            let result = customShortcutMonitor.register(hotKey)
            guard result == .active else {
                fallbackToFunctionKey(
                    reason: customShortcutFailureMessage(result),
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

    private func fallbackToFunctionKey(reason: String, persist: Bool) {
        customShortcutMonitor.unregister()
        preference = .functionKey
        let result = functionKeyMonitor.start()
        if result == .active {
            activation = .active(.functionKey)
            notice = VoiceShortcutNotice(
                message: "\(reason)，已继续使用 Fn。",
                level: .warning
            )
        } else {
            activation = .unavailable(.functionKey)
            notice = VoiceShortcutNotice(
                message: "\(reason)；\(functionKeyFailureMessage(result))",
                level: .error,
                recovery: .retryActivation
            )
        }
        if persist { persistLater(.functionKey) }
    }

    private func functionKeyFailureMessage(
        _ result: FunctionKeyMonitorStartResult
    ) -> String {
        switch result {
        case .active:
            "Fn 快捷键已启用。"
        case .eventTapUnavailable:
            "无法创建 Fn 键的系统事件监听。"
        case .runLoopSourceUnavailable:
            "Fn 键监听无法接入系统事件循环。"
        }
    }

    private func customShortcutFailureMessage(
        _ result: CustomShortcutRegistrationResult
    ) -> String {
        switch result {
        case .active:
            "自定义快捷键已启用"
        case .eventHandlerUnavailable:
            "无法安装自定义快捷键事件处理"
        case .hotKeyRegistrationUnavailable:
            "系统未接受这个自定义快捷键"
        case .escapeEventTapUnavailable:
            "自定义快捷键的 Esc 取消监听未能创建"
        case .escapeRunLoopSourceUnavailable:
            "自定义快捷键的 Esc 取消监听无法接入系统事件循环"
        }
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
                    self.persistenceConfirmation = "\(choice.displayName) 快捷键设置已保存。"
                }
            } catch {
                guard generation == self.persistenceGeneration else { return }
                self.failedPersistencePreference = choice
                self.notice = VoiceShortcutNotice(
                    message: error.localizedDescription,
                    level: .error,
                    recovery: .retryPersistence
                )
            }
        }
    }
}
