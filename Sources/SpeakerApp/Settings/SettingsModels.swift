import AppKit
@preconcurrency import Carbon
import Combine
import SpeakerAppFeatures
import SpeakerCore

@MainActor
final class DiagnosticNoticeModel: ObservableObject {
    @Published private(set) var notice: String?

    func publish(_ notice: String?) {
        self.notice = notice
    }
}

@MainActor
final class SettingsWorkspace {
    let navigation: SettingsNavigationModel
    let permissions: PermissionModel
    let shortcut: VoiceShortcutFeature
    let loginItemSettings: LoginItemSettingsModel
    let history: HistoryModel
    let doubao: DoubaoSettingsModel
    let refinement: RefinementSettingsModel
    let dictionary: DictionarySettingsModel
    let softwareUpdate: SoftwareUpdateFeature
    let diagnostics: DiagnosticNoticeModel
    let dataErasure: SpeakerDataErasureCoordinator
    let requestPermission: (PermissionKind) async -> Void

    private let refreshPermissions: () -> Void
    private let copyDiagnosticsAction: () async -> Void

    init(
        navigation: SettingsNavigationModel,
        permissions: PermissionModel,
        shortcut: VoiceShortcutFeature,
        loginItemSettings: LoginItemSettingsModel,
        history: HistoryModel,
        doubao: DoubaoSettingsModel,
        refinement: RefinementSettingsModel,
        dictionary: DictionarySettingsModel,
        softwareUpdate: SoftwareUpdateFeature,
        diagnostics: DiagnosticNoticeModel,
        dataErasure: SpeakerDataErasureCoordinator,
        requestPermission: @escaping (PermissionKind) async -> Void,
        refreshPermissions: @escaping () -> Void,
        copyDiagnostics: @escaping () async -> Void
    ) {
        self.navigation = navigation
        self.permissions = permissions
        self.shortcut = shortcut
        self.loginItemSettings = loginItemSettings
        self.history = history
        self.doubao = doubao
        self.refinement = refinement
        self.dictionary = dictionary
        self.softwareUpdate = softwareUpdate
        self.diagnostics = diagnostics
        self.dataErasure = dataErasure
        self.requestPermission = requestPermission
        self.refreshPermissions = refreshPermissions
        copyDiagnosticsAction = copyDiagnostics
    }

    func refresh() async {
        guard dataErasure.state == .idle else { return }
        refreshPermissions()
        await doubao.refresh()
        await loginItemSettings.refresh()
        await history.refresh()
    }

    func copyDiagnostics() async {
        await copyDiagnosticsAction()
    }
}

enum RefinementChoice: String, CaseIterable, Identifiable {
    case defaultSmooth
    case conciseCleanup
    case fullRewrite
    case custom

    var id: String { rawValue }

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
}

@MainActor
final class RefinementSettingsModel: ObservableObject {
    @Published private(set) var mode: TextRefinementMode = .defaultSmooth
    @Published var apiKeyDraft = ""
    @Published var customName = "我的整理规则"
    @Published var customPrompt = ""
    @Published private(set) var isEditingCustomMode = false
    @Published private(set) var hasStoredKey = false
    @Published private(set) var isConnectionVerified = false
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var connectionFailure: String?
    @Published private(set) var credentialNotice: String?
    @Published private(set) var notice: String?

    private let service: CredentialedDeepSeekTextRefiner
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: VersionedLocalAppSettingsStore
    private var connectionGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var deferredMode: TextRefinementMode?

    init(
        service: CredentialedDeepSeekTextRefiner,
        configuration: VoiceInputConfigurationController,
        settingsStore: VersionedLocalAppSettingsStore
    ) {
        self.service = service
        self.configuration = configuration
        self.settingsStore = settingsStore
    }

    var choice: RefinementChoice {
        switch mode {
        case .defaultSmooth: .defaultSmooth
        case .conciseCleanup: .conciseCleanup
        case .fullRewrite: .fullRewrite
        case .custom: .custom
        }
    }

    var savedCustomModeName: String? {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || prompt.isEmpty ? nil : name
    }

    func load() async {
        do {
            hasStoredKey = try await service.hasAPIKey()
        } catch {
            credentialNotice = error.localizedDescription
        }

        let loadedSettings = await settingsStore.load().settings
        let loadedMode = loadedSettings.refinement.textRefinementMode
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
            if activation.deferredMode != nil {
                notice = "已保留“\(validated.displayName)”模式；保存 DeepSeek Key 后会自动恢复使用。"
            } else {
                notice = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func saveAPIKey() async {
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
                try await configuration.selectRefinementMode(deferredMode)
                mode = deferredMode
                self.deferredMode = nil
            }
            notice = nil
        } catch {
            connectionGeneration &+= 1
            credentialNotice = error.localizedDescription
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
            credentialNotice = error.localizedDescription
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
                connectionFailure = error.localizedDescription
            }
        }
    }

    func shutdown() async {
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

    func select(_ choice: RefinementChoice, persist: Bool = true) async {
        if choice != .defaultSmooth, !hasStoredKey {
            notice = "请先保存 DeepSeek API Key，再启用进一步整理。"
            return
        }

        if choice == .custom {
            isEditingCustomMode = true
            notice = nil
            return
        }

        isEditingCustomMode = false

        let selectedMode: TextRefinementMode
        switch choice {
        case .defaultSmooth:
            selectedMode = .defaultSmooth
        case .conciseCleanup:
            selectedMode = .conciseCleanup
        case .fullRewrite:
            selectedMode = .fullRewrite
        case .custom:
            return
        }

        do {
            try await configuration.selectRefinementMode(selectedMode)
            mode = try selectedMode.validated()
            notice = nil
            if persist {
                try await persistSelection(mode)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func saveCustomMode() async {
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
            isEditingCustomMode = false
            notice = nil
            try await persistSelection(customMode)
        } catch {
            notice = error.localizedDescription
        }
    }

    func selectSavedCustomMode() async {
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
            isEditingCustomMode = false
            notice = nil
            try await persistSelection(customMode)
        } catch {
            notice = error.localizedDescription
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
final class DictionarySettingsModel: ObservableObject {
    @Published var entries: [DictionaryEntry] = []
    @Published var draftCanonical = ""
    @Published var draftAliases = ""
    @Published private(set) var notice: String?

    private let store: VersionedJSONPersonalDictionaryStore
    private let configuration: VoiceInputConfigurationController
    private var saveTask: Task<Void, Never>?
    private var allowsPersistence = false

    init(
        store: VersionedJSONPersonalDictionaryStore,
        configuration: VoiceInputConfigurationController
    ) {
        self.store = store
        self.configuration = configuration
    }

    func load() async {
        do {
            let dictionary = try await store.load()
            entries = dictionary.entries
            await configuration.replaceDictionary(dictionary)
            allowsPersistence = true
            notice = nil
        } catch {
            allowsPersistence = false
            notice = error.localizedDescription
        }
    }

    func add() async {
        let aliases = draftAliases
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
            .map(String.init)
        let entry = DictionaryEntry(canonicalTerm: draftCanonical, aliases: aliases)
        guard await save(entries + [entry]) else { return }
        draftCanonical = ""
        draftAliases = ""
    }

    func saveEdits() async {
        saveTask?.cancel()
        saveTask = nil
        _ = await save(entries)
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.saveEdits()
        }
    }

    func delete(_ id: UUID) async {
        _ = await save(entries.filter { $0.id != id })
    }

    func shutdown() async {
        let task = saveTask
        saveTask = nil
        task?.cancel()
        await task?.value
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
            notice = error.localizedDescription
            return false
        }
    }
}

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var notice: String?
    private var monitor: Any?

    func start(onCapture: @escaping (CustomHotKey) -> Void) {
        stop()
        isRecording = true
        notice = "请按下 ⌥ Space，或至少包含两个 ⌘、⌥、⌃ 的组合键。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode != UInt16(kVK_Escape) else {
                self.stop()
                return nil
            }
            let modifiers = Self.carbonModifiers(event.modifierFlags)
            guard modifiers != 0 else {
                self.notice = "组合键必须包含至少一个修饰键。"
                return nil
            }
            let displayName = Self.displayName(event: event)
            let hotKey = CustomHotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                displayName: displayName
            )
            guard !hotKey.conflictsWithCommonEditingShortcut else {
                self.notice = "这个组合键是常用编辑命令，请换一个组合键。"
                return nil
            }
            guard hotKey.isSafeForGlobalVoiceInput else {
                self.notice = "单个修饰键会干扰正常输入；请使用 ⌥ Space 或至少两个 ⌘、⌥、⌃ 修饰键。"
                return nil
            }
            self.stop()
            onCapture(hotKey)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func displayName(event: NSEvent) -> String {
        let flags = event.modifierFlags
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        let key: String = switch event.keyCode {
        case 36: "Return"
        case 48: "Tab"
        case 49: "Space"
        case 53: "Esc"
        default: event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        }
        return prefix + key
    }
}
