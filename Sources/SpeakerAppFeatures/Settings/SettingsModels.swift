import AppKit
@preconcurrency import Carbon
import Combine
import SpeakerCore

@MainActor
package final class DiagnosticNoticeModel: ObservableObject {
    @Published private(set) var notice: String?

    package init() {}

    package func publish(_ notice: String?) {
        self.notice = notice
    }
}

package struct SettingsRouteEffects {
    let openURL: (URL) -> Void

    package init(openURL: @escaping (URL) -> Void) {
        self.openURL = openURL
    }
}

@MainActor
package final class SettingsWorkspace {
    let navigation: SettingsNavigationModel
    let permissions: PermissionModel
    let shortcut: VoiceShortcutFeature
    let loginItemSettings: LoginItemSettingsModel
    let historyRetention: HistoryRetentionSettingsModel
    let doubao: DoubaoSettingsModel
    let refinement: RefinementSettingsModel
    let dictionary: DictionarySettingsModel
    let softwareUpdate: SoftwareUpdateFeature
    let diagnostics: DiagnosticNoticeModel
    let dataErasure: SpeakerDataErasureCoordinator
    let requestPermission: (PermissionKind) async -> Void
    package let routeEffects: SettingsRouteEffects

    private let refreshPermissions: () -> Void
    private let copyDiagnosticsAction: () async -> Void

    package init(
        navigation: SettingsNavigationModel,
        permissions: PermissionModel,
        shortcut: VoiceShortcutFeature,
        loginItemSettings: LoginItemSettingsModel,
        historyRetention: HistoryRetentionSettingsModel,
        doubao: DoubaoSettingsModel,
        refinement: RefinementSettingsModel,
        dictionary: DictionarySettingsModel,
        softwareUpdate: SoftwareUpdateFeature,
        diagnostics: DiagnosticNoticeModel,
        dataErasure: SpeakerDataErasureCoordinator,
        requestPermission: @escaping (PermissionKind) async -> Void,
        routeEffects: SettingsRouteEffects,
        refreshPermissions: @escaping () -> Void,
        copyDiagnostics: @escaping () async -> Void
    ) {
        self.navigation = navigation
        self.permissions = permissions
        self.shortcut = shortcut
        self.loginItemSettings = loginItemSettings
        self.historyRetention = historyRetention
        self.doubao = doubao
        self.refinement = refinement
        self.dictionary = dictionary
        self.softwareUpdate = softwareUpdate
        self.diagnostics = diagnostics
        self.dataErasure = dataErasure
        self.requestPermission = requestPermission
        self.routeEffects = routeEffects
        self.refreshPermissions = refreshPermissions
        copyDiagnosticsAction = copyDiagnostics
    }

    func refresh() async {
        guard dataErasure.state == .idle else { return }
        refreshPermissions()
        await doubao.refresh()
        await loginItemSettings.refresh()
        await historyRetention.refresh()
    }

    func copyDiagnostics() async {
        await copyDiagnosticsAction()
    }
}

package enum RefinementChoice: String, CaseIterable, Identifiable {
    case defaultSmooth
    case conciseCleanup
    case fullRewrite
    case custom

    package var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultSmooth: "默认顺滑"
        case .conciseCleanup: "精简清理"
        case .fullRewrite: "完整重写"
        case .custom: "自定义"
        }
    }

    var subtitle: String {
        switch self {
        case .defaultSmooth: "只使用豆包语义顺滑"
        case .conciseCleanup: "清理重复、停顿和口语"
        case .fullRewrite: "重组为清晰完整的文本"
        case .custom: "按照你自己的提示词整理"
        }
    }

    var icon: String {
        switch self {
        case .defaultSmooth: "waveform"
        case .conciseCleanup: "text.badge.checkmark"
        case .fullRewrite: "sparkles"
        case .custom: "slider.horizontal.3"
        }
    }

    package init(mode: TextRefinementMode) {
        switch mode.builtInMode {
        case .conciseCleanup:
            self = .conciseCleanup
        case .fullRewrite:
            self = .fullRewrite
        case nil:
            self = mode == .defaultSmooth ? .defaultSmooth : .custom
        }
    }

    package var builtInMode: BuiltInRefinementMode? {
        switch self {
        case .conciseCleanup: .conciseCleanup
        case .fullRewrite: .fullRewrite
        case .defaultSmooth, .custom: nil
        }
    }

    func refinementMode(
        promptOverrides: RefinementPromptOverrides
    ) -> TextRefinementMode? {
        if let builtInMode {
            return builtInMode.refinementMode(
                promptOverride: promptOverrides[builtInMode]
            )
        }
        return self == .defaultSmooth ? .defaultSmooth : nil
    }
}

@MainActor
package final class RefinementSettingsModel: ObservableObject {
    @Published package private(set) var mode: TextRefinementMode = .defaultSmooth
    @Published package var apiKeyDraft = ""
    @Published package var customName = "我的模式"
    @Published package var customPrompt = ""
    @Published package var promptDraft = ""
    @Published package private(set) var promptOverrides = RefinementPromptOverrides()
    @Published package private(set) var inspectedPromptMode: BuiltInRefinementMode?
    @Published private(set) var isEditingCustomMode = false
    @Published package private(set) var hasStoredKey = false
    @Published package private(set) var isConnectionVerified = false
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var connectionFailure: String?
    @Published private(set) var credentialNotice: String?
    @Published private(set) var notice: String?

    private let service: any DeepSeekSettingsServicing
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: any AppSettingsStoring
    private var connectionGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var deferredMode: TextRefinementMode?

    package init(
        service: any DeepSeekSettingsServicing,
        configuration: VoiceInputConfigurationController,
        settingsStore: any AppSettingsStoring
    ) {
        self.service = service
        self.configuration = configuration
        self.settingsStore = settingsStore
    }

    var choice: RefinementChoice {
        RefinementChoice(mode: mode)
    }

    /// The prompt editor state for the active mode, or nil when the mode has
    /// no prompt UI (Default Smoothing, or Custom Mode's dedicated editor).
    package var promptEditorState: RefinementPromptEditorState? {
        guard let inspectedPromptMode else { return nil }
        return RefinementPromptPresentation.editorState(
            for: inspectedPromptMode,
            promptOverride: promptOverrides[inspectedPromptMode]
        )
    }

    /// The single save-enabled condition for Custom Mode; the card renders it
    /// rather than recomputing the rule.
    package var canSaveCustomMode: Bool {
        hasStoredKey
            && !customName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            && customName.count <= TextRefinementMode.maximumCustomNameLength
            && !customPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            && customPrompt.count
                <= TextRefinementMode.maximumCustomPromptLength
    }

    package var savedCustomModeName: String? {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || prompt.isEmpty ? nil : name
    }

    package func load() async {
        do {
            hasStoredKey = try await service.hasAPIKey()
        } catch {
            credentialNotice = SpeakerCopy.Failure.message(for: error)
        }

        let loadedSettings = await settingsStore.load().settings
        promptOverrides = loadedSettings.refinementPromptOverrides
        let loadedMode = loadedSettings.refinement.textRefinementMode
            .applyingPromptOverrides(loadedSettings.refinementPromptOverrides)
        let savedCustomMode = loadedSettings.savedCustomRefinement?.textRefinementMode
        if case let .custom(name, prompt) = savedCustomMode ?? loadedMode {
            customName = name
            customPrompt = prompt
        }
        do {
            let validated = try loadedMode.validated()
            let activation = RefinementActivationPlan(
                desiredMode: validated,
                hasStoredKey: hasStoredKey
            )
            try await configuration.selectRefinementMode(
                activation.activeMode
            )
            mode = activation.activeMode
            deferredMode = activation.deferredMode
            inspectedPromptMode = validated.builtInMode
            syncPromptDraft()
            if activation.deferredMode != nil {
                notice = "已保留“\(validated.displayName)”模式；保存 DeepSeek Key 后会自动恢复使用。"
            } else {
                notice = nil
            }
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func saveAPIKey() async {
        await cancelConnectionCheck()
        do {
            try await service.saveAPIKey(apiKeyDraft)
            connectionGeneration &+= 1
            apiKeyDraft = ""
            hasStoredKey = true
            isConnectionVerified = false
            connectionFailure = nil
            credentialNotice = nil
            if let deferredMode {
                let restoredMode = deferredMode.applyingPromptOverrides(
                    promptOverrides
                )
                try await configuration.selectRefinementMode(restoredMode)
                mode = restoredMode
                inspectedPromptMode = restoredMode.builtInMode
                self.deferredMode = nil
                syncPromptDraft()
            }
            notice = nil
        } catch {
            connectionGeneration &+= 1
            credentialNotice = SpeakerCopy.Failure.message(for: error)
        }
    }

    func deleteAPIKey() async {
        await cancelConnectionCheck()
        do {
            try await service.deleteAPIKey()
            connectionGeneration &+= 1
            hasStoredKey = false
            isConnectionVerified = false
            connectionFailure = nil
            credentialNotice = nil
            apiKeyDraft = ""
            deferredMode = nil
            await select(.defaultSmooth)
        } catch {
            connectionGeneration &+= 1
            credentialNotice = SpeakerCopy.Failure.message(for: error)
        }
    }

    func checkConnection() {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let previousTask = connectionTask
        let service = service
        isCheckingConnection = true
        connectionFailure = nil
        connectionTask = Task { @MainActor [weak self] in
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled else { return }

            let result: Result<String?, Error>
            do {
                result = .success(try await service.checkConnection())
            } catch {
                result = .failure(error)
            }

            guard let self,
                  generation == connectionGeneration,
                  !Task.isCancelled
            else { return }
            connectionTask = nil
            isCheckingConnection = false
            switch result {
            case .success:
                isConnectionVerified = true
                connectionFailure = nil
            case let .failure(failure as DeepSeekRefinementFailure):
                isConnectionVerified = false
                connectionFailure = Self.connectionMessage(
                    for: failure.kind
                )
            case let .failure(error):
                isConnectionVerified = false
                connectionFailure = SpeakerCopy.Failure.message(for: error)
            }
        }
    }

    package func shutdown() async {
        await cancelConnectionCheck()
    }

    private func cancelConnectionCheck() async {
        connectionGeneration &+= 1
        let task = connectionTask
        connectionTask = nil
        task?.cancel()
        await task?.value
        isCheckingConnection = false
    }

    package func select(
        _ choice: RefinementChoice,
        persist: Bool = true
    ) async {
        if let builtInMode = choice.builtInMode {
            inspectPrompt(builtInMode)
        } else {
            inspectedPromptMode = nil
        }

        if choice == .custom {
            isEditingCustomMode = true
            notice = hasStoredKey
                ? nil
                : "可先编辑规则；保存 DeepSeek API Key 后才能启用。"
            return
        }

        isEditingCustomMode = false

        if choice != .defaultSmooth, !hasStoredKey {
            notice = "提示词可查看和编辑；保存 DeepSeek API Key 后才能启用该模式。"
            return
        }

        guard let selectedMode = choice.refinementMode(
            promptOverrides: promptOverrides
        ) else { return }

        do {
            try await configuration.selectRefinementMode(selectedMode)
            mode = try selectedMode.validated()
            syncPromptDraft()
            notice = nil
            if persist {
                try await persistSelection(mode)
            }
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Saves the inspected built-in mode's prompt override, taking
    /// effect for new sessions through the same `deepSeekInstruction` request path.
    package func savePromptOverride() async {
        guard let promptEditorState else { return }
        do {
            let updatedMode = try promptEditorState.mode
                .refinementMode(promptOverride: promptDraft)
                .validated()
            try await settingsStore.updateRefinementPromptOverride(
                updatedMode.promptOverride,
                for: updatedMode
            )
            promptOverrides[promptEditorState.mode] = updatedMode.promptOverride
            try await applyEditedPromptModeIfSelected(updatedMode)
            syncPromptDraft()
            notice = nil
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Restores the inspected built-in mode's built-in prompt and clears the
    /// saved override.
    package func restoreDefaultPrompt() async {
        guard let promptEditorState else { return }
        do {
            let updatedMode = promptEditorState.mode.refinementMode()
            try await settingsStore.updateRefinementPromptOverride(
                nil,
                for: updatedMode
            )
            promptOverrides[promptEditorState.mode] = nil
            try await applyEditedPromptModeIfSelected(updatedMode)
            syncPromptDraft()
            notice = nil
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    private func syncPromptDraft() {
        promptDraft = promptEditorState?.effectivePrompt ?? promptDraft
    }

    private func inspectPrompt(_ mode: BuiltInRefinementMode) {
        inspectedPromptMode = mode
        syncPromptDraft()
    }

    private func applyEditedPromptModeIfSelected(
        _ updatedMode: TextRefinementMode
    ) async throws {
        guard let editedBuiltInMode = updatedMode.builtInMode else { return }
        if mode.builtInMode == editedBuiltInMode {
            try await configuration.selectRefinementMode(updatedMode)
            mode = updatedMode
        }
        if deferredMode?.builtInMode == editedBuiltInMode {
            deferredMode = updatedMode
        }
    }

    package func saveCustomMode() async {
        guard hasStoredKey else {
            notice = "请先保存 DeepSeek API Key，再保存并启用自定义规则。"
            return
        }
        do {
            let customMode = try TextRefinementMode.custom(
                name: customName,
                prompt: customPrompt
            ).validated()
            try await settingsStore.updateSavedCustomRefinement(
                RefinementPreference(mode: customMode)
            )
            if case let .custom(name, prompt) = customMode {
                customName = name
                customPrompt = prompt
            }
            try await configuration.selectRefinementMode(customMode)
            mode = customMode
            inspectedPromptMode = nil
            isEditingCustomMode = false
            notice = nil
            try await persistSelection(customMode)
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func selectSavedCustomMode() async {
        guard hasStoredKey else {
            notice = "请先保存 DeepSeek API Key。"
            return
        }
        do {
            let customMode = try TextRefinementMode.custom(
                name: customName,
                prompt: customPrompt
            ).validated()
            try await configuration.selectRefinementMode(customMode)
            mode = customMode
            inspectedPromptMode = nil
            isEditingCustomMode = false
            notice = nil
            try await persistSelection(customMode)
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    private func persistSelection(_ selectedMode: TextRefinementMode) async throws {
        try await settingsStore.updateRefinement(
            RefinementPreference(mode: selectedMode)
        )
    }

    private static func connectionMessage(for kind: DeepSeekRefinementFailureKind) -> String {
        switch kind {
        case .invalidCredential, .authentication:
            "DeepSeek Key 无效，请重新保存后检查连接。"
        case .credentialAccessDenied:
            "macOS 拒绝访问 DeepSeek 凭据，请检查当前构建身份后重试。"
        case .credentialInteractionUnavailable:
            "DeepSeek 凭据当前不可用，请解锁 Mac 后重试。"
        case .credentialMalformed:
            "已保存的 DeepSeek Key 无法读取，请删除后重新保存。"
        case .credentialStorageUnavailable:
            "本机凭据存储暂时不可用，请稍后重试。"
        case .insufficientBalance:
            "DeepSeek 余额不足，请充值后重试。"
        case .rateLimited:
            "DeepSeek 请求过于频繁，请稍后重试。"
        case .network:
            "无法连接 DeepSeek，请检查网络。"
        case .systemNetworkTimeout:
            "系统报告 DeepSeek 网络请求超时。"
        case .cancelled:
            "DeepSeek 连接检查已取消。"
        case .serverError, .serviceUnavailable, .insufficientSystemResource:
            "DeepSeek 服务暂时不可用，请稍后重试。"
        default:
            "DeepSeek 返回了无法验证的响应，请稍后重试。"
        }
    }
}

@MainActor
package final class DictionarySettingsModel: ObservableObject {
    @Published package var entries: [DictionaryEntry] = []
    @Published package var draftWord = ""
    @Published package private(set) var notice: String?
    /// Set when the last load preserved a corrupt dictionary file.
    @Published package private(set) var recovery: PersonalDictionaryRecovery?

    private let store: any PersonalDictionaryStoring
    private let configuration: VoiceInputConfigurationController
    private var allowsPersistence = false

    package init(
        store: any PersonalDictionaryStoring,
        configuration: VoiceInputConfigurationController
    ) {
        self.store = store
        self.configuration = configuration
    }

    package var sentEntryCount: Int {
        requestContext.hotwords.count
    }

    package var sendingCountText: String {
        "\(sentEntryCount)/\(DictionaryProviderCapacity.doubao.maximumHotwordCount) 条"
    }

    package var omittedEntryIDs: Set<UUID> {
        Set(requestContext.omissions.map(\.entryID))
    }

    package func qualityHint(
        for entry: DictionaryEntry
    ) -> DictionaryEntryQualityHint {
        DictionaryEntryQualityPolicy.hint(for: entry.word)
    }

    package func load() async {
        do {
            let result = try await store.load()
            entries = result.dictionary.entries
            await configuration.replaceDictionary(result.dictionary)
            allowsPersistence = true
            recovery = result.recovery
            notice = result.recovery.map(Self.recoveryNotice)
        } catch {
            allowsPersistence = false
            recovery = nil
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package static func recoveryNotice(
        for recovery: PersonalDictionaryRecovery
    ) -> String {
        "个人词库文件已损坏，已从空词库继续；原文件保留在 \(recovery.backupURL.lastPathComponent)。"
    }

    @discardableResult
    package func add() async -> Bool {
        guard await add(word: draftWord) else { return false }
        draftWord = ""
        return true
    }

    @discardableResult
    package func add(word: String) async -> Bool {
        let entry = DictionaryEntry(word: word)
        return await save(entries + [entry])
    }

    package func delete(_ id: UUID) async {
        _ = await save(entries.filter { $0.id != id })
    }

    private var requestContext: DictionaryRequestContext {
        DictionaryRequestContextBuilder.makeContext(
            from: PersonalDictionarySnapshot(entries: entries)
        )
    }

    private func save(_ candidate: [DictionaryEntry]) async -> Bool {
        guard allowsPersistence else {
            notice = "个人词库未能安全加载，已停止保存以避免覆盖原文件。请修复文件后重新打开 Speaker。"
            return false
        }
        do {
            let dictionary = try PersonalDictionary(entries: candidate)
            try await store.save(dictionary)
            entries = dictionary.entries
            await configuration.replaceDictionary(dictionary)
            notice = nil
            return true
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
            return false
        }
    }
}

package struct ShortcutRecorderModifierPolicy {
    private var candidate: CustomHotKey?

    package init() {}

    package mutating func handle(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> CustomHotKey? {
        guard let modifier = CustomHotKey.PhysicalModifier(
            keyCode: UInt32(keyCode)
        ) else {
            candidate = nil
            return nil
        }
        let hotKey = CustomHotKey.modifierOnly(
            modifier,
            displayName: modifier.displayName
        )
        let expectedFlag: NSEvent.ModifierFlags = switch modifier {
        case .leftOption, .rightOption: .option
        case .leftControl, .rightControl: .control
        case .leftShift, .rightShift: .shift
        }
        let relevantFlags = flags.intersection([.command, .option, .control, .shift])
        if flags.contains(expectedFlag) {
            candidate = relevantFlags == expectedFlag ? hotKey : nil
            return nil
        }
        defer { candidate = nil }
        guard candidate == hotKey, relevantFlags.isEmpty else { return nil }
        return hotKey
    }

    package mutating func reset() {
        candidate = nil
    }
}

private extension CustomHotKey.PhysicalModifier {
    var displayName: String {
        switch self {
        case .leftOption: "左 ⌥"
        case .rightOption: "右 ⌥"
        case .leftControl: "左 ⌃"
        case .rightControl: "右 ⌃"
        case .leftShift: "左 ⇧"
        case .rightShift: "右 ⇧"
        }
    }
}

package enum ShortcutRecorderInput {
    case flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags)
    case keyDown(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    )
}

package enum ShortcutRecorderDecision: Equatable {
    case consume
    case cancel
    case capture(CustomHotKey)
    case reject(String)
}

package struct ShortcutRecorderPolicy {
    package static let recordingPrompt =
        "请单独按下左/右 ⌥、⌃、⇧，或输入一个安全组合键。"

    private var modifierPolicy = ShortcutRecorderModifierPolicy()

    package init() {}

    package mutating func handle(
        _ input: ShortcutRecorderInput
    ) -> ShortcutRecorderDecision {
        switch input {
        case let .flagsChanged(keyCode, flags):
            if let hotKey = modifierPolicy.handle(keyCode: keyCode, flags: flags) {
                return .capture(hotKey)
            }
            if [kVK_Command, kVK_RightCommand].contains(Int(keyCode)),
               !flags.contains(.command)
            {
                return .reject("不支持单独使用 Command；请选择左/右 ⌥、⌃ 或 ⇧。")
            }
            return .consume
        case let .keyDown(keyCode, flags, charactersIgnoringModifiers):
            modifierPolicy.reset()
            guard keyCode != UInt16(kVK_Escape) else { return .cancel }
            let modifiers = Self.carbonModifiers(flags)
            guard modifiers != 0 else {
                return .reject("组合键必须包含至少一个修饰键。")
            }
            let hotKey = CustomHotKey(
                keyCode: UInt32(keyCode),
                modifiers: modifiers,
                displayName: Self.displayName(
                    keyCode: keyCode,
                    flags: flags,
                    charactersIgnoringModifiers: charactersIgnoringModifiers
                )
            )
            guard !hotKey.conflictsWithCommonEditingShortcut else {
                return .reject("这个组合键是常用编辑命令，请换一个组合键。")
            }
            guard hotKey.isSafeForGlobalVoiceInput else {
                return .reject(Self.recordingPrompt)
            }
            return .capture(hotKey)
        }
    }

    package mutating func reset() {
        modifierPolicy.reset()
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func displayName(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> String {
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        let key: String = switch Int(keyCode) {
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Space: "Space"
        case kVK_Escape: "Esc"
        default: charactersIgnoringModifiers?.uppercased() ?? "Key \(keyCode)"
        }
        return prefix + key
    }
}

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var notice: String?
    private var monitor: Any?
    private var policy = ShortcutRecorderPolicy()

    func start(onCapture: @escaping (CustomHotKey) -> Void) {
        stop()
        isRecording = true
        notice = ShortcutRecorderPolicy.recordingPrompt
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            let input: ShortcutRecorderInput = if event.type == .flagsChanged {
                .flagsChanged(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags
                )
            } else {
                .keyDown(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                )
            }
            switch self.policy.handle(input) {
            case .consume:
                break
            case .cancel:
                self.stop()
            case let .capture(hotKey):
                self.stop()
                onCapture(hotKey)
            case let .reject(message):
                self.notice = message
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        policy.reset()
        isRecording = false
    }
}
