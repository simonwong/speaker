import AppKit
@preconcurrency import Carbon
import Combine
import ServiceManagement
import SpeakerCore
import SwiftUI

@main
struct SpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var runtime: SpeakerRuntime

    init() {
        let runtime = SpeakerRuntime()
        _runtime = StateObject(wrappedValue: runtime)
        Task { @MainActor in
            runtime.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Speaker", systemImage: menuBarIcon) {
            MenuBarContent(
                permissions: runtime.permissions,
                sessions: runtime.sessions,
                refinement: runtime.refinementSettings,
                startRuntime: runtime.start
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(runtime: runtime)
        }

        Window("会话历史", id: "history") {
            HistoryView(model: runtime.historyModel)
        }
        .defaultSize(width: 720, height: 480)
    }

    private var menuBarIcon: String {
        if runtime.sessions.presentation.activity.isRecording {
            return "waveform.circle.fill"
        }
        return runtime.permissions.snapshot.allGranted
            ? "waveform"
            : "waveform.badge.exclamationmark"
    }
}

@MainActor
private final class SpeakerRuntime: ObservableObject {
    let permissions: PermissionModel
    let sessions: VoiceInputSessionModel
    let history: VersionedLocalSessionHistory
    let doubaoSettings: DoubaoSettingsModel
    let refinementSettings: RefinementSettingsModel
    let dictionarySettings: DictionarySettingsModel
    let historyModel: HistoryModel
    let loginItemSettings: LoginItemSettingsModel

    @Published private(set) var shortcutPreference: VoiceShortcutPreference = .functionKey
    @Published private(set) var shortcutNotice: String?

    private let fnMonitor: FnEventMonitor
    private let customHotKeyMonitor: CustomHotKeyMonitor
    private let sessionActor: VoiceInputSessions
    private let triggerDispatcher: VoiceInputTriggerDispatcher
    private let settingsStore: VersionedLocalAppSettingsStore
    private let panel: VoiceInputPanelController
    private var started = false
    private var permissionRefreshCancellable: AnyCancellable?

    init() {
        permissions = PermissionModel(access: SystemPermissionAccess())
        let audio = AVAudioCapture()
        let targets = AccessibilityInputTargets()
        let history = VersionedLocalSessionHistory(
            fileURL: VersionedLocalSessionHistory.defaultFileURL()
        )
        let credentials = KeychainProviderCredentialStore()
        let doubao = CredentialedDoubaoTranscriber(
            credentials: credentials,
            installationID: Self.installationID()
        )
        let deepSeek = CredentialedDeepSeekTextRefiner(credentials: credentials)
        let configuration = VoiceInputConfigurationController()
        let processor = DefaultVoiceTextProcessor(
            configuration: configuration,
            doubao: doubao,
            refinement: OptionalTextRefinementPipeline(refiner: deepSeek)
        )
        let dictionaryURL = (try? VersionedJSONPersonalDictionaryStore.applicationSupportFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("speaker-personal-dictionary.json")
        let dictionaryStore = VersionedJSONPersonalDictionaryStore(fileURL: dictionaryURL)
        let settingsStore = VersionedLocalAppSettingsStore(
            fileURL: VersionedLocalAppSettingsStore.defaultFileURL()
        )
        self.settingsStore = settingsStore
        let sessionActor = VoiceInputSessions(
            audioCapture: audio,
            targetCapture: targets,
            textProcessor: processor,
            delivery: targets,
            clipboard: SystemClipboardWriter(),
            history: history
        )
        let sessions = VoiceInputSessionModel(sessions: sessionActor)
        self.sessionActor = sessionActor
        self.sessions = sessions
        self.history = history
        doubaoSettings = DoubaoSettingsModel(service: doubao, settingsStore: settingsStore)
        refinementSettings = RefinementSettingsModel(
            service: deepSeek,
            configuration: configuration,
            settingsStore: settingsStore
        )
        dictionarySettings = DictionarySettingsModel(
            store: dictionaryStore,
            configuration: configuration
        )
        historyModel = HistoryModel(store: history, targets: targets)
        loginItemSettings = LoginItemSettingsModel(settingsStore: settingsStore)
        let triggerDispatcher = VoiceInputTriggerDispatcher(sessions: sessionActor)
        self.triggerDispatcher = triggerDispatcher
        let triggerHandler: @Sendable (GlobalVoiceTrigger) -> Void = { trigger in
            triggerDispatcher.send(trigger)
        }
        fnMonitor = FnEventMonitor(handler: triggerHandler)
        customHotKeyMonitor = CustomHotKeyMonitor(handler: triggerHandler)
        panel = VoiceInputPanelController(model: sessions)
    }

    func start() {
        guard !started else { return }
        started = true
        permissions.refresh()
        permissionRefreshCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.permissions.refresh()
                }
            }
        sessions.startObserving()
        Task {
            await permissions.requestMicrophoneIfNeeded()
            await permissions.requestAccessibilityIfNeeded()
        }
        panel.start()
        SpeakerTerminationCoordinator.shared.handler = { [weak self] in
            guard let self else { return }
            await self.triggerDispatcher.shutdown()
        }
        Task {
            let loadedSettings = await settingsStore.load()
            switch loadedSettings {
            case let .recovered(_, recovery):
                shortcutNotice = "设置文件已恢复为默认值，原文件保留在 \(recovery.backupURL.lastPathComponent)。"
            case let .recoveryFailed(_, reason):
                shortcutNotice = reason
            case .defaults, .loaded:
                break
            }
            await doubaoSettings.loadResource(
                rawValue: loadedSettings.settings.doubaoResourceID
            )
            activateShortcut(loadedSettings.settings.shortcut, persist: false)
            await dictionarySettings.load()
            await refinementSettings.load()
            await historyModel.refresh()
            await loginItemSettings.refresh()
        }
    }

    func useFunctionKey() {
        activateShortcut(.functionKey, persist: true)
    }

    func registerCustomShortcut(_ hotKey: CustomHotKey) {
        activateShortcut(.init(customHotKey: hotKey), persist: true)
    }

    private func activateShortcut(_ choice: VoiceShortcutPreference, persist: Bool) {
        switch choice {
        case .functionKey:
            customHotKeyMonitor.unregister()
            guard fnMonitor.start() else {
                shortcutNotice = "Fn 监听未能启动，请先授予辅助功能权限后重试。"
                return
            }
        case .custom:
            fnMonitor.stop()
            guard let hotKey = choice.customHotKey,
                  customHotKeyMonitor.register(hotKey)
            else {
                shortcutNotice = "该组合键已被其他应用占用，已继续使用 Fn。"
                _ = fnMonitor.start()
                shortcutPreference = .functionKey
                if persist { persistShortcut(.functionKey) }
                return
            }
        }

        shortcutPreference = choice
        shortcutNotice = nil
        if persist {
            persistShortcut(choice)
        }
    }

    private func persistShortcut(_ choice: VoiceShortcutPreference) {
        Task {
            do {
                try await settingsStore.updateShortcut(choice)
            } catch {
                shortcutNotice = error.localizedDescription
            }
        }
    }

    private static func installationID() -> String {
        let key = "localInstallationID"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

@MainActor
private final class DoubaoSettingsModel: ObservableObject {
    enum Status: Equatable {
        case loading
        case unconfigured
        case configured
        case checking
        case success(String?)
        case failure(String)
    }

    @Published var apiKeyDraft = ""
    @Published private(set) var status: Status = .loading
    @Published private(set) var hasStoredKey = false
    @Published private(set) var resource: DoubaoStreamingResource = .default

    private let service: CredentialedDoubaoTranscriber
    private let settingsStore: VersionedLocalAppSettingsStore

    init(
        service: CredentialedDoubaoTranscriber,
        settingsStore: VersionedLocalAppSettingsStore
    ) {
        self.service = service
        self.settingsStore = settingsStore
    }

    func loadResource(rawValue: String?) async {
        resource = rawValue.flatMap(DoubaoStreamingResource.init(rawValue:)) ?? .default
        await service.setResource(resource)
    }

    func selectResource(_ resource: DoubaoStreamingResource) async {
        self.resource = resource
        await service.setResource(resource)
        do {
            try await settingsStore.updateDoubaoResource(resource)
            status = hasStoredKey ? .configured : .unconfigured
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func refresh() async {
        do {
            hasStoredKey = try await service.hasAPIKey()
            status = hasStoredKey ? .configured : .unconfigured
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func save() async {
        do {
            try await service.saveAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            hasStoredKey = true
            status = .configured
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func checkConnection() async {
        status = .checking
        do {
            let requestID = try await service.checkConnection()
            status = .success(requestID)
        } catch let failure as DoubaoASRFailure {
            status = .failure(Self.message(for: failure.kind))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func delete() async {
        do {
            try await service.deleteAPIKey()
            apiKeyDraft = ""
            hasStoredKey = false
            status = .unconfigured
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    var hasConfiguredKey: Bool {
        hasStoredKey
    }

    var summary: String {
        switch status {
        case .loading:
            "正在读取 Keychain…"
        case .unconfigured:
            "未配置"
        case .configured:
            "已保存到本机 Keychain"
        case .checking:
            "正在检查连接…"
        case let .success(requestID):
            requestID.map { "连接成功 · \($0)" } ?? "连接成功"
        case let .failure(message):
            message
        }
    }

    private static func message(for kind: DoubaoASRFailureKind) -> String {
        switch kind {
        case .invalidCredential: "API Key 无效或未配置"
        case .resourceNotActivated: "尚未开通所选豆包流式语音资源"
        case .rateLimited: "请求过于频繁，请稍后重试"
        case .network: "无法连接豆包服务"
        case .cancelled: "连接检查已取消"
        case .serverBusy, .serviceUnavailable: "豆包服务暂时不可用"
        case .silence, .emptyTranscript: "连接成功"
        case .invalidRequest, .emptyAudio, .invalidAudioFormat, .invalidResponse:
            "豆包返回了无法识别的响应"
        }
    }
}

private enum RefinementChoice: String, CaseIterable, Identifiable {
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
private final class RefinementSettingsModel: ObservableObject {
    @Published private(set) var mode: TextRefinementMode = .defaultSmooth
    @Published var apiKeyDraft = ""
    @Published var customName = "我的整理规则"
    @Published var customPrompt = ""
    @Published private(set) var hasStoredKey = false
    @Published private(set) var isConnectionVerified = false
    @Published private(set) var notice: String?

    private let service: CredentialedDeepSeekTextRefiner
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: VersionedLocalAppSettingsStore
    private var connectionGeneration = 0

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
            notice = error.localizedDescription
        }

        let loadedSettings = await settingsStore.load().settings
        let loadedMode = loadedSettings.refinement.textRefinementMode
        let savedCustomMode = loadedSettings.savedCustomRefinement?.textRefinementMode
        if case let .custom(name, prompt) = savedCustomMode ?? loadedMode {
            customName = name
            customPrompt = prompt
        }
        if loadedMode.requiresDeepSeek, hasStoredKey {
            await checkConnection()
            guard isConnectionVerified else { return }
        }
        await select(Self.choice(for: loadedMode), persist: false)
    }

    func saveAPIKey() async {
        connectionGeneration &+= 1
        do {
            try await service.saveAPIKey(apiKeyDraft)
            connectionGeneration &+= 1
            apiKeyDraft = ""
            hasStoredKey = true
            isConnectionVerified = false
            await apply(.defaultSmooth, choice: .defaultSmooth, persist: true)
            notice = "DeepSeek Key 已保存；请检查连接后再启用进一步整理。"
        } catch {
            connectionGeneration &+= 1
            notice = error.localizedDescription
        }
    }

    func deleteAPIKey() async {
        connectionGeneration &+= 1
        do {
            try await service.deleteAPIKey()
            connectionGeneration &+= 1
            hasStoredKey = false
            isConnectionVerified = false
            apiKeyDraft = ""
            await select(.defaultSmooth)
            notice = "DeepSeek Key 已删除，已切回默认顺滑。"
        } catch {
            connectionGeneration &+= 1
            notice = error.localizedDescription
        }
    }

    func checkConnection() async {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        notice = "正在检查 DeepSeek 连接…"
        do {
            let requestID = try await service.checkConnection()
            guard generation == connectionGeneration else { return }
            isConnectionVerified = true
            notice = requestID.map { "DeepSeek 连接成功 · \($0)" } ?? "DeepSeek 连接成功。"
        } catch let failure as DeepSeekRefinementFailure {
            guard generation == connectionGeneration else { return }
            isConnectionVerified = false
            await apply(
                .defaultSmooth,
                choice: .defaultSmooth,
                persist: false
            )
            notice = Self.connectionMessage(for: failure.kind)
        } catch {
            guard generation == connectionGeneration else { return }
            isConnectionVerified = false
            await apply(
                .defaultSmooth,
                choice: .defaultSmooth,
                persist: false
            )
            notice = error.localizedDescription
        }
    }

    func select(_ choice: RefinementChoice, persist: Bool = true) async {
        if choice != .defaultSmooth, (!hasStoredKey || !isConnectionVerified) {
            notice = hasStoredKey
                ? "请先点击“检查连接”，验证 DeepSeek Key 后再启用进一步整理。"
                : "请先保存 DeepSeek API Key，再启用进一步整理。"
            await apply(.defaultSmooth, choice: .defaultSmooth, persist: persist)
            return
        }

        let selectedMode: TextRefinementMode
        switch choice {
        case .defaultSmooth:
            selectedMode = .defaultSmooth
        case .conciseCleanup:
            selectedMode = .conciseCleanup
        case .fullRewrite:
            selectedMode = .fullRewrite
        case .custom:
            selectedMode = .custom(name: customName, prompt: customPrompt)
        }

        do {
            try await configuration.selectRefinementMode(selectedMode)
            mode = try selectedMode.validated()
            notice = mode.requiresDeepSeek
                ? "此模式会把豆包文本和当前规则发送给 DeepSeek；不会发送音频。"
                : "默认顺滑只调用豆包，不调用 DeepSeek。"
            if persist {
                try await persistSelection(mode)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func saveCustomMode() async {
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
            await select(.custom)
        } catch {
            notice = error.localizedDescription
        }
    }

    func selectSavedCustomMode() async {
        await select(.custom)
    }

    private func apply(
        _ selectedMode: TextRefinementMode,
        choice: RefinementChoice,
        persist: Bool
    ) async {
        try? await configuration.selectRefinementMode(selectedMode)
        mode = selectedMode
        if persist { try? await persistSelection(selectedMode) }
    }

    private func persistSelection(_ selectedMode: TextRefinementMode) async throws {
        try await settingsStore.updateRefinement(
            RefinementPreference(mode: selectedMode)
        )
    }

    private static func choice(for mode: TextRefinementMode) -> RefinementChoice {
        switch mode {
        case .defaultSmooth: .defaultSmooth
        case .conciseCleanup: .conciseCleanup
        case .fullRewrite: .fullRewrite
        case .custom: .custom
        }
    }

    private static func connectionMessage(for kind: DeepSeekRefinementFailureKind) -> String {
        switch kind {
        case .invalidCredential, .authentication:
            "DeepSeek Key 无效，请重新保存后检查连接。"
        case .insufficientBalance:
            "DeepSeek 余额不足，请充值后重试。"
        case .rateLimited:
            "DeepSeek 请求过于频繁，请稍后重试。"
        case .network:
            "无法连接 DeepSeek，请检查网络。"
        case .timeout:
            "DeepSeek 连接检查超时，请稍后重试。"
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
private final class DictionarySettingsModel: ObservableObject {
    @Published var entries: [DictionaryEntry] = []
    @Published var draftCanonical = ""
    @Published var draftAliases = ""
    @Published private(set) var notice: String?

    private let store: VersionedJSONPersonalDictionaryStore
    private let configuration: VoiceInputConfigurationController
    private var saveTask: Task<Void, Never>?

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
            notice = nil
        } catch {
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

    private func save(_ candidate: [DictionaryEntry]) async -> Bool {
        do {
            let dictionary = try PersonalDictionary(entries: candidate)
            try await store.save(dictionary)
            entries = dictionary.entries
            await configuration.replaceDictionary(dictionary)
            notice = "词库已保存在本机；新的会话会使用更新后的快照。"
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
}

@MainActor
private final class HistoryModel: ObservableObject {
    @Published private(set) var records: [VoiceInputHistoryRecord] = []
    @Published var query = ""
    @Published private(set) var notice: String?

    let store: VersionedLocalSessionHistory
    private let targets: AccessibilityInputTargets

    init(store: VersionedLocalSessionHistory, targets: AccessibilityInputTargets) {
        self.store = store
        self.targets = targets
    }

    func refresh() async {
        records = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? await store.allRecords()
            : await store.search(query)
        let status = await store.persistenceStatus()
        switch status.notice {
        case let .corruptedDataPreserved(_, reason): notice = "已保留损坏的历史文件：\(reason)"
        case let .writeFailed(reason): notice = "历史写入失败：\(reason)"
        case nil: notice = nil
        }
    }

    func delete(_ id: VoiceInputSessionID) async {
        _ = await store.delete(sessionID: id)
        await refresh()
    }

    func clear() async {
        await store.clear()
        await refresh()
    }

    func redeliver(_ record: VoiceInputHistoryRecord) async {
        guard let text = record.finalText ?? record.transcription, !text.isEmpty else {
            notice = "这条记录没有可重新送达的文本。"
            return
        }
        notice = "请在 3 秒内聚焦目标输入框；Speaker 将重新捕获目标。"
        try? await Task.sleep(for: .seconds(3))
        let target = await targets.capture()
        switch target {
        case let .writable(snapshot):
            let outcome = await targets.deliver(
                text,
                to: snapshot,
                commitGate: DeliveryCommitGate()
            )
            switch outcome {
            case .delivered:
                notice = "历史文本已重新送达 \(snapshot.applicationName)。"
            case .pendingCopy:
                notice = "无法安全送达；请使用“复制最终文本”。"
            }
        case .unavailable:
            notice = "没有捕获到可写输入框；请使用“复制最终文本”。"
        }
    }
}

@MainActor
private final class LoginItemSettingsModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var notice: String?

    private let settingsStore: VersionedLocalAppSettingsStore

    init(settingsStore: VersionedLocalAppSettingsStore) {
        self.settingsStore = settingsStore
    }

    func refresh() async {
        isEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            notice = "登录项需要在“系统设置 → 通用 → 登录项”中批准。"
        }
        await persistCurrentState()
    }

    func setEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
            notice = isEnabled ? "已启用登录时启动。" : "已关闭登录时启动。"
            await persistCurrentState()
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            notice = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    private func persistCurrentState() async {
        do {
            try await settingsStore.updateLaunchAtLogin(isEnabled)
        } catch {
            notice = error.localizedDescription
        }
    }
}

@MainActor
private final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var notice: String?
    private var monitor: Any?

    func start(onCapture: @escaping (CustomHotKey) -> Void) {
        stop()
        isRecording = true
        notice = "请按下至少包含 ⌘、⌥、⌃ 或 ⇧ 的组合键。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = Self.carbonModifiers(event.modifierFlags)
            guard modifiers != 0 else {
                self.notice = "组合键必须包含至少一个修饰键。"
                return nil
            }
            let displayName = Self.displayName(event: event)
            self.stop()
            onCapture(CustomHotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                displayName: displayName
            ))
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

private extension VoiceShortcutPreference {
    var displayName: String {
        switch self {
        case .functionKey: "Fn"
        case let .custom(_, _, displayName): displayName
        }
    }
}

private final class SpeakerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let handler = SpeakerTerminationCoordinator.shared.handler else {
            return .terminateNow
        }
        Task {
            await handler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
private final class SpeakerTerminationCoordinator {
    static let shared = SpeakerTerminationCoordinator()
    var handler: (() async -> Void)?
}

private struct MenuBarContent: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var sessions: VoiceInputSessionModel
    @ObservedObject var refinement: RefinementSettingsModel
    let startRuntime: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Menu {
                Button("默认顺滑") { Task { await refinement.select(.defaultSmooth) } }
                Button("精简清理") { Task { await refinement.select(.conciseCleanup) } }
                Button("完整重写") { Task { await refinement.select(.fullRewrite) } }
                if let customModeName = refinement.savedCustomModeName {
                    Button(customModeName) {
                        Task { await refinement.selectSavedCustomMode() }
                    }
                }
            } label: {
                Label(refinement.mode.displayName, systemImage: "text.alignleft")
            }
            if let refinementNotice = refinement.notice {
                Label(refinementNotice, systemImage: "info.circle")
            }

            Label(sessionSummary, systemImage: sessionIcon)

            if sessions.presentation.activity.isActive {
                Button("取消当前输入") {
                    sessions.send(.cancel)
                }
            }

            if case .pendingCopy = sessions.presentation.activity {
                Button("复制待处理结果") {
                    sessions.send(.copyPendingResult)
                }
            }

            Divider()

            Label(permissionSummary, systemImage: permissionIcon)

            Button("会话历史") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("设置…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Divider()

            Button("退出 Speaker") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            startRuntime()
            permissions.refresh()
        }
    }

    private var permissionSummary: String {
        permissions.snapshot.allGranted ? "权限已就绪" : "需要完成权限设置"
    }

    private var permissionIcon: String {
        permissions.snapshot.allGranted ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var sessionSummary: String {
        sessions.presentation.activity.summary
    }

    private var sessionIcon: String {
        sessions.presentation.activity.icon
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case speech
    case refinement
    case dictionary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .speech: "语音识别"
        case .refinement: "文本整理"
        case .dictionary: "个人词库"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "快捷键、录音方式与启动选项"
        case .speech: "系统权限与豆包流式语音服务"
        case .refinement: "选择整理强度，按需接入 DeepSeek"
        case .dictionary: "维护专有名词和常见口语别名"
        }
    }

    var icon: String {
        switch self {
        case .general: "switch.2"
        case .speech: "waveform"
        case .refinement: "text.alignleft"
        case .dictionary: "text.book.closed"
        }
    }
}

private struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                Text(page.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
    }
}

private struct StatusBadge: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
            .lineLimit(1)
    }
}

private struct SettingsNotice: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

private struct SettingsView: View {
    @ObservedObject var runtime: SpeakerRuntime
    @StateObject private var shortcutRecorder = ShortcutRecorderModel()
    @State private var selection = SettingsPage.general

    private var permissions: PermissionModel { runtime.permissions }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.icon)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaker")
                        .font(.caption.weight(.semibold))
                    Text("语音随手输入")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsPageHeader(page: selection)

                    switch selection {
                    case .general:
                        GeneralSettingsPage(
                            runtime: runtime,
                            shortcutRecorder: shortcutRecorder,
                            loginItemSettings: runtime.loginItemSettings
                        )
                    case .speech:
                        SpeechSettingsPage(
                            permissions: permissions,
                            doubao: runtime.doubaoSettings
                        )
                    case .refinement:
                        RefinementSettingsPage(model: runtime.refinementSettings)
                    case .dictionary:
                        DictionarySettingsPage(model: runtime.dictionarySettings)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 860, height: 650)
        .task {
            permissions.refresh()
            await runtime.doubaoSettings.refresh()
            await runtime.loginItemSettings.refresh()
        }
        .onDisappear { shortcutRecorder.stop() }
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var runtime: SpeakerRuntime
    @ObservedObject var shortcutRecorder: ShortcutRecorderModel
    @ObservedObject var loginItemSettings: LoginItemSettingsModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "语音输入快捷键",
                subtitle: "长按时松开结束；短按时再次按下结束",
                icon: "keyboard"
            ) {
                HStack(spacing: 16) {
                    Text(runtime.shortcutPreference.displayName)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 16)
                        .frame(minWidth: 78, minHeight: 44)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(.separator.opacity(0.55), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前快捷键")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(runtime.shortcutPreference == .functionKey ? "默认 Fn" : "自定义组合键")
                            .font(.subheadline.weight(.medium))
                    }

                    Spacer()

                    Button("使用 Fn") {
                        shortcutRecorder.stop()
                        runtime.useFunctionKey()
                    }
                    .disabled(runtime.shortcutPreference == .functionKey)

                    Button(shortcutRecorder.isRecording ? "取消" : "录制新快捷键") {
                        if shortcutRecorder.isRecording {
                            shortcutRecorder.stop()
                        } else {
                            shortcutRecorder.start { hotKey in
                                runtime.registerCustomShortcut(hotKey)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if shortcutRecorder.isRecording, let notice = shortcutRecorder.notice {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(notice)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if let notice = runtime.shortcutNotice {
                    SettingsNotice(text: notice, color: .orange)
                }

                Divider()

                HStack(spacing: 12) {
                    GestureHint(
                        icon: "hand.tap",
                        title: "短按",
                        detail: "按一下开始，再按一下结束"
                    )
                    GestureHint(
                        icon: "hand.point.up.left",
                        title: "长按",
                        detail: "按住录音，松开结束"
                    )
                    GestureHint(
                        icon: "escape",
                        title: "取消",
                        detail: "录音期间按 Esc"
                    )
                }
            }

            SettingsCard(
                "启动与后台运行",
                subtitle: "Speaker 作为菜单栏应用安静运行",
                icon: "power"
            ) {
                Toggle(
                    "登录 Mac 时自动启动 Speaker",
                    isOn: Binding(
                        get: { loginItemSettings.isEnabled },
                        set: { enabled in
                            Task { await loginItemSettings.setEnabled(enabled) }
                        }
                    )
                )
                .toggleStyle(.switch)

                if let notice = loginItemSettings.notice {
                    SettingsNotice(text: notice, color: .orange)
                }
            }
        }
    }
}

private struct GestureHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeechSettingsPage: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var doubao: DoubaoSettingsModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "系统权限",
                subtitle: "只请求完成语音输入所必需的权限",
                icon: "checkmark.shield"
            ) {
                PermissionSettingsRow(
                    title: "辅助功能",
                    explanation: "监听全局快捷键，并把文本安全送达到结束录音时的输入框。",
                    kind: .accessibility,
                    state: permissions.snapshot.accessibility,
                    permissions: permissions
                )

                Divider()

                PermissionSettingsRow(
                    title: "麦克风",
                    explanation: "音频只在内存中流式处理，不会写入磁盘或历史。",
                    kind: .microphone,
                    state: permissions.snapshot.microphone,
                    permissions: permissions
                )
            }

            DoubaoSettingsCard(model: doubao)
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let explanation: String
    let kind: PermissionKind
    let state: PermissionState
    @ObservedObject var permissions: PermissionModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            StatusBadge(
                text: state == .granted ? "已授权" : "待完成",
                icon: state == .granted ? "checkmark" : "exclamationmark",
                color: color
            )

            if state != .granted {
                Button(buttonTitle) {
                    Task { await permissions.request(kind) }
                }
            }
        }
    }

    private var icon: String {
        switch kind {
        case .accessibility: "accessibility"
        case .microphone: "mic.fill"
        }
    }

    private var color: Color { state == .granted ? .green : .orange }

    private var buttonTitle: String {
        state == .notDetermined ? "请求授权" : "打开设置"
    }
}

private struct DoubaoSettingsCard: View {
    @ObservedObject var model: DoubaoSettingsModel
    @State private var confirmingDelete = false

    var body: some View {
        SettingsCard(
            "豆包流式语音",
            subtitle: "录音过程中实时转录，默认启用语义顺滑",
            icon: "waveform.badge.mic"
        ) {
            HStack {
                StatusBadge(
                    text: statusText,
                    icon: statusIcon,
                    color: statusColor
                )
                .help(model.summary)
                Spacer()
                Link(
                    "打开豆包控制台",
                    destination: URL(
                        string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default"
                    )!
                )
                .font(.caption)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("API Key")
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        SecureField(
                            model.hasConfiguredKey ? "输入新 Key 以替换当前凭据" : "输入豆包语音 API Key",
                            text: $model.apiKeyDraft
                        )
                        .textContentType(.password)

                        Button(model.hasConfiguredKey ? "替换 Key" : "保存 Key") {
                            Task { await model.save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.apiKeyDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }
                }

                GridRow {
                    Text("流式资源")
                        .font(.subheadline.weight(.medium))
                    Picker(
                        "流式资源",
                        selection: Binding(
                            get: { model.resource },
                            set: { resource in Task { await model.selectResource(resource) } }
                        )
                    ) {
                        ForEach(DoubaoStreamingResource.allCases, id: \.rawValue) { resource in
                            Text(resource.displayName).tag(resource)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300, alignment: .leading)
                }
            }

            HStack(spacing: 10) {
                if case .checking = model.status {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("检查连接") {
                    Task { await model.checkConnection() }
                }
                .disabled(!model.hasConfiguredKey || isChecking)

                Text("资源类型必须与控制台中已开通的套餐一致。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("删除 Key", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(!model.hasConfiguredKey)
            }
        }
        .confirmationDialog(
            "删除豆包 API Key？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                Task { await model.delete() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将无法进行新的语音转录，历史记录不会受影响。")
        }
    }

    private var isChecking: Bool {
        if case .checking = model.status { true } else { false }
    }

    private var statusIcon: String {
        switch model.status {
        case .loading: "clock"
        case .unconfigured: "key.slash"
        case .configured: "checkmark.shield"
        case .checking: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch model.status {
        case .loading: "正在读取 Keychain"
        case .unconfigured: "未配置"
        case .configured: "Key 已保存在本机"
        case .checking: "正在检查连接"
        case .success: "连接成功"
        case .failure: model.summary
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .success: .green
        case .failure: .red
        case .checking: .blue
        case .loading, .unconfigured, .configured: .secondary
        }
    }
}

private struct RefinementSettingsPage: View {
    @ObservedObject var model: RefinementSettingsModel
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                "整理模式",
                subtitle: "默认顺滑不调用 DeepSeek；其他模式需要先验证 Key",
                icon: "text.alignleft"
            ) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(RefinementChoice.allCases) { choice in
                        RefinementModeButton(
                            choice: choice,
                            selected: model.choice == choice,
                            locked: choice != .defaultSmooth
                                && (!model.hasStoredKey || !model.isConnectionVerified)
                        ) {
                            Task { await model.select(choice) }
                        }
                    }
                }

                if let notice = model.notice {
                    SettingsNotice(
                        text: notice,
                        color: model.isConnectionVerified ? .green : .secondary
                    )
                }
            }

            SettingsCard(
                "DeepSeek（可选）",
                subtitle: "仅发送豆包转录文本和整理规则，不发送音频",
                icon: "sparkles"
            ) {
                HStack {
                    StatusBadge(
                        text: deepSeekStatusText,
                        icon: deepSeekStatusIcon,
                        color: deepSeekStatusColor
                    )
                    Spacer()
                    Link(
                        "打开 DeepSeek 平台",
                        destination: URL(string: "https://platform.deepseek.com/api_keys")!
                    )
                    .font(.caption)
                }

                HStack(spacing: 8) {
                    SecureField(
                        model.hasStoredKey ? "输入新 Key 以替换当前凭据" : "输入 DeepSeek API Key",
                        text: $model.apiKeyDraft
                    )
                    .textContentType(.password)

                    Button(model.hasStoredKey ? "替换 Key" : "保存 Key") {
                        Task { await model.saveAPIKey() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.apiKeyDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                }

                HStack {
                    Button("检查连接") {
                        Task { await model.checkConnection() }
                    }
                    .disabled(!model.hasStoredKey)

                    Spacer()

                    Button("删除 Key", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(!model.hasStoredKey)
                }
            }
            .confirmationDialog(
                "删除 DeepSeek API Key？",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("删除 Key", role: .destructive) {
                    Task { await model.deleteAPIKey() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后会自动切回默认顺滑，豆包转录仍可正常使用。")
            }

            if model.choice == .custom {
                SettingsCard(
                    "自定义整理规则",
                    subtitle: "清楚描述希望保留、删除和重组的内容",
                    icon: "slider.horizontal.3"
                ) {
                    TextField("规则名称", text: $model.customName)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.customPrompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)

                        if model.customPrompt.isEmpty {
                            Text("例如：整理成简洁的工作邮件，保留所有数字和专有名词……")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 130)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.separator.opacity(0.7), lineWidth: 1)
                    }

                    HStack {
                        Text("\(model.customPrompt.count) / 4000")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(
                                model.customPrompt.count > 4_000 ? Color.red : .secondary
                            )
                        Spacer()
                        Button("保存并启用") {
                            Task { await model.saveCustomMode() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.customPrompt.count > 4_000
                        )
                    }
                }
            }
        }
    }

    private var deepSeekStatusText: String {
        if model.isConnectionVerified { return "已验证" }
        if model.hasStoredKey { return "已保存，待验证" }
        return "未配置"
    }

    private var deepSeekStatusIcon: String {
        if model.isConnectionVerified { return "checkmark.circle.fill" }
        if model.hasStoredKey { return "exclamationmark.circle.fill" }
        return "key.slash"
    }

    private var deepSeekStatusColor: Color {
        if model.isConnectionVerified { return .green }
        if model.hasStoredKey { return .orange }
        return .secondary
    }
}

private struct RefinementModeButton: View {
    let choice: RefinementChoice
    let selected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: choice.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : locked ? "lock.fill" : "circle")
                        .foregroundStyle(
                            selected ? Color.accentColor : Color.secondary.opacity(0.55)
                        )
                }
                Text(choice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(choice.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DictionarySettingsPage: View {
    @ObservedObject var model: DictionarySettingsModel
    @State private var pendingDeleteID: UUID?

    var body: some View {
        SettingsCard(
            "个人词库",
            subtitle: "识别后会把完整且无歧义的别名替换成标准写法",
            icon: "text.book.closed"
        ) {
            HStack {
                StatusBadge(
                    text: "\(model.entries.filter(\.isEnabled).count) 个启用词条",
                    icon: "checkmark",
                    color: .green
                )
                Spacer()
                Text("修改后自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("标准写法")
                        .font(.caption.weight(.medium))
                    TextField("例如：DeepSeek", text: $model.draftCanonical)
                }
                GridRow {
                    Text("口语别名")
                        .font(.caption.weight(.medium))
                    HStack(spacing: 8) {
                        TextField("例如：deep seek，深度求索", text: $model.draftAliases)
                            .onSubmit { Task { await model.add() } }
                        Button("添加词条") {
                            Task { await model.add() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.draftCanonical
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }
                }
            }

            Divider()

            if model.entries.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有词条")
                            .font(.subheadline.weight(.medium))
                        Text("添加产品名、人名或专业术语，提高最终文本一致性。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 8) {
                    ForEach($model.entries) { $entry in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $entry.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: entry.isEnabled) {
                                    model.scheduleSave()
                                }

                            TextField("标准写法", text: $entry.canonicalTerm)
                                .frame(minWidth: 130)
                                .onSubmit { Task { await model.saveEdits() } }
                                .onChange(of: entry.canonicalTerm) {
                                    model.scheduleSave()
                                }

                            TextField(
                                "别名（逗号分隔）",
                                text: Binding(
                                    get: { entry.aliases.joined(separator: "，") },
                                    set: { value in
                                        entry.aliases = value
                                            .split(whereSeparator: {
                                                $0 == "," || $0 == "，" || $0.isNewline
                                            })
                                            .map(String.init)
                                    }
                                )
                            )
                            .onSubmit { Task { await model.saveEdits() } }
                            .onChange(of: entry.aliases) {
                                model.scheduleSave()
                            }

                            Button {
                                pendingDeleteID = entry.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除词条")
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }

            if let notice = model.notice {
                SettingsNotice(text: notice)
            }
        }
        .confirmationDialog(
            "删除这个词条？",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除词条", role: .destructive) {
                guard let id = pendingDeleteID else { return }
                pendingDeleteID = nil
                Task { await model.delete(id) }
            }
            Button("取消", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text("删除后仅影响新的语音输入，已有会话历史不会改变。")
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var selection: VoiceInputSessionID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索豆包、DeepSeek、最终文本或诊断信息", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refresh() } }
                Button("搜索") { Task { await model.refresh() } }
                Button("刷新") { Task { await model.refresh() } }
                Button("全部清空", role: .destructive) {
                    Task { await model.clear() }
                }
                .disabled(model.records.isEmpty)
            }
            .padding(12)

            Divider()

            if model.records.isEmpty {
                ContentUnavailableView(
                    "还没有会话记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成第一次语音输入后，豆包与可选 DeepSeek 的阶段结果会显示在这里。")
                )
            } else {
                NavigationSplitView {
                    List(model.records, id: \.sessionID, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.finalText ?? record.transcription ?? "无文本")
                                .lineLimit(2)
                            Text("\(record.startedAt.formatted()) · \(record.applicationName ?? "无目标")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(record.sessionID)
                    }
                } detail: {
                    if let record = selectedRecord {
                        HistoryDetailView(
                            record: record,
                            redeliver: { Task { await model.redeliver(record) } },
                            delete: { Task { await model.delete(record.sessionID) } }
                        )
                    } else {
                        ContentUnavailableView("选择一条会话", systemImage: "text.magnifyingglass")
                    }
                }
            }

            if let notice = model.notice {
                Divider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.refresh() }
    }

    private var selectedRecord: VoiceInputHistoryRecord? {
        guard let selection else { return nil }
        return model.records.first { $0.sessionID == selection }
    }
}

private struct HistoryDetailView: View {
    let record: VoiceInputHistoryRecord
    let redeliver: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("时间", value: record.startedAt.formatted())
                LabeledContent("目标 App", value: record.applicationName ?? "无")
                LabeledContent("整理模式", value: record.refinementModeName ?? "默认顺滑")
                if let refinementPrompt = record.refinementPrompt {
                    HistoryTextBlock(title: "整理提示词快照", text: refinementPrompt)
                }
                LabeledContent("送达状态", value: record.outcome.historyLabel)
                LabeledContent("总耗时", value: "\(record.durationMilliseconds) ms")
                if !record.stageDurationsMilliseconds.isEmpty {
                    LabeledContent(
                        "阶段耗时",
                        value: record.stageDurationsMilliseconds
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key) \($0.value) ms" }
                            .joined(separator: " · ")
                    )
                }
                HistoryTextBlock(title: "豆包转录", text: record.transcription)
                if record.deepSeekText != nil || record.refinementStatus == "fellBack" {
                    HistoryTextBlock(title: "DeepSeek 结果", text: record.deepSeekText)
                    LabeledContent("DeepSeek 状态", value: record.refinementStatus ?? "未知")
                }
                HistoryTextBlock(title: "最终文本", text: record.finalText)
                if !record.dictionarySnapshotEntries.isEmpty {
                    Text("词库快照")
                        .font(.headline)
                    ForEach(record.dictionarySnapshotEntries) { entry in
                        Text(
                            entry.aliases.isEmpty
                                ? entry.canonicalTerm
                                : "\(entry.canonicalTerm) ← \(entry.aliases.joined(separator: "、"))"
                        )
                    }
                    if let context = record.dictionaryRequestContext {
                        LabeledContent("发送词数", value: "\(context.hotwords.count)")
                        LabeledContent("省略词数", value: "\(context.omissions.count)")
                    }
                }
                if !record.dictionaryReplacements.isEmpty {
                    Text("词库替换")
                        .font(.headline)
                    ForEach(record.dictionaryReplacements, id: \.utf16Location) { replacement in
                        Text("\(replacement.matchedText) → \(replacement.canonicalTerm)")
                    }
                }
                if let providerRequestID = record.providerRequestID {
                    LabeledContent(
                        "\(record.transcriptionProvider ?? "转录提供商")请求 ID",
                        value: providerRequestID
                    )
                }
                if let deepSeekRequestID = record.deepSeekRequestID {
                    LabeledContent("DeepSeek 请求 ID", value: deepSeekRequestID)
                }

                HStack {
                    Button("复制最终文本") {
                        copy(record.finalText ?? record.transcription ?? "")
                    }
                    .disabled(record.finalText == nil && record.transcription == nil)
                    Button("3 秒后重新送达", action: redeliver)
                        .disabled(record.finalText == nil && record.transcription == nil)
                    Button("删除记录", role: .destructive, action: delete)
                }
            }
            .padding(20)
            .textSelection(.enabled)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct HistoryTextBlock: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text ?? "无")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

@MainActor
private final class VoiceInputPanelController {
    private enum PanelLayout: Equatable {
        case standard
        case recording
        case pendingCopy
        case failed

        init(activity: VoiceInputActivity) {
            switch activity {
            case .recording: self = .recording
            case .pendingCopy: self = .pendingCopy
            case .failed: self = .failed
            case .idle, .preparing, .processing, .delivered, .cancelled: self = .standard
            }
        }
    }

    private let panel: NSPanel
    private let model: VoiceInputSessionModel
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var presentedLayout: PanelLayout?

    init(model: VoiceInputSessionModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: VoiceInputOverlay(model: model))
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = model.$presentation.sink { [weak self] presentation in
            self?.apply(presentation.activity)
        }
    }

    private func apply(_ activity: VoiceInputActivity) {
        hideTask?.cancel()
        hideTask = nil

        switch activity {
        case .idle:
            panel.orderOut(nil)
            presentedLayout = nil
        case .delivered, .cancelled:
            showPanel(for: activity)
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        case .preparing, .recording, .processing, .pendingCopy, .failed:
            showPanel(for: activity)
        }
    }

    private func showPanel(for activity: VoiceInputActivity) {
        let layout = PanelLayout(activity: activity)
        if presentedLayout != layout || !panel.isVisible {
            panel.setContentSize(Self.panelSize(for: layout))
            if let frame = NSScreen.main?.visibleFrame {
                let origin = NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.minY + 28
                )
                panel.setFrameOrigin(origin)
            }
            panel.orderFrontRegardless()
            presentedLayout = layout
        }
    }

    private static func panelSize(for layout: PanelLayout) -> NSSize {
        switch layout {
        case .recording:
            NSSize(width: 224, height: 76)
        case .pendingCopy:
            NSSize(width: 400, height: 120)
        case .failed:
            NSSize(width: 380, height: 112)
        case .standard:
            NSSize(width: 360, height: 104)
        }
    }
}

private struct VoiceInputOverlay: View {
    @ObservedObject var model: VoiceInputSessionModel

    var body: some View {
        Group {
            if model.presentation.activity.isRecording {
                RecordingWaveformOverlay(
                    peakPower: model.presentation.recordingTelemetry?.peakPower
                )
            } else {
                statusOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: model.presentation.activity.isRecording)
    }

    private var statusOverlay: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 14) {
                Image(systemName: model.presentation.activity.icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.presentation.activity.summary)
                        .font(.headline)
                    Text(model.presentation.activity.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let notice = model.presentation.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if model.presentation.activity.isActive {
                    Button("取消") {
                        model.send(.cancel)
                    }
                } else if case .pendingCopy = model.presentation.activity {
                    Button("复制") {
                        model.send(.copyPendingResult)
                    }
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .padding(.trailing, model.presentation.activity.isDismissible ? 20 : 0)

            if model.presentation.activity.isDismissible {
                Button {
                    model.send(.dismissResult)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
                .padding(8)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .padding(8)
    }
}

private struct RecordingWaveformOverlay: View {
    let peakPower: Float?

    private let barCount = 17

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 12) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .scaleEffect(0.88 + pulse(at: phase) * 0.18)
                    .opacity(0.72 + pulse(at: phase) * 0.28)
                    .shadow(color: .red.opacity(0.35), radius: 5)

                HStack(spacing: 3) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.5),
                                        Color.white,
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: 4, height: barHeight(index: index, phase: phase))
                    }
                }
                .frame(height: 38)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.9), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .padding(8)
        .accessibilityLabel("正在录音")
    }

    private var inputStrength: Double {
        guard let peakPower else { return 0.5 }
        return min(1, max(0.22, Double(peakPower + 55) / 55))
    }

    private func pulse(at phase: TimeInterval) -> Double {
        (sin(phase * 4.2) + 1) / 2
    }

    private func barHeight(index: Int, phase: TimeInterval) -> Double {
        let position = Double(index) / Double(max(1, barCount - 1))
        let envelope = 0.42 + sin(position * .pi) * 0.58
        let primary = (sin(phase * 8.4 + Double(index) * 0.82) + 1) / 2
        let secondary = (sin(phase * 5.1 - Double(index) * 0.47) + 1) / 2
        let motion = 0.18 + primary * 0.55 + secondary * 0.27
        return 6 + 30 * envelope * motion * (0.45 + inputStrength * 0.55)
    }
}

private extension VoiceInputActivity {
    var historyLabel: String {
        switch self {
        case .idle: "空闲"
        case .preparing: "准备中"
        case .recording: "录音中"
        case .processing: "处理中"
        case .delivered: "已自动送达"
        case .pendingCopy: "等待复制"
        case .cancelled: "已取消"
        case .failed: "失败"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .processing:
            true
        case .idle, .delivered, .pendingCopy, .cancelled, .failed:
            false
        }
    }

    var isDismissible: Bool {
        switch self {
        case .pendingCopy, .failed:
            true
        case .idle, .preparing, .recording, .processing, .delivered, .cancelled:
            false
        }
    }

    var summary: String {
        switch self {
        case .idle:
            "等待语音输入"
        case .preparing:
            "正在准备麦克风"
        case .recording:
            "正在录音"
        case let .processing(_, stage, _):
            switch stage {
            case .capturingTarget:
                "正在捕获输入目标"
            case .transcribing:
                "正在转录"
            case .refining:
                "正在进一步整理"
            case .delivering:
                "正在送达文本"
            }
        case .delivered:
            "文本已送达"
        case .pendingCopy:
            "等待复制"
        case .cancelled:
            "本次输入已取消"
        case .failed:
            "本次输入失败"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "长按讲话，或短按开始/再按结束"
        case .preparing:
            "请稍候"
        case .recording:
            "长按松开提交 · 短按再按一次提交 · Esc 取消"
        case let .processing(_, _, applicationName):
            applicationName.map { "输入目标：\($0)" } ?? "正在确定输入位置"
        case let .delivered(_, applicationName, _):
            "已写入 \(applicationName)"
        case let .pendingCopy(_, text, _):
            text
        case .cancelled:
            "已停止后续处理；不会送达或保存结果"
        case let .failed(_, failure):
            switch failure {
            case .recordingFailed: "无法完成录音"
            case .transcriptionFailed: "无法完成转录"
            case .providerNotConfigured: "请先在设置中配置豆包 API Key"
            case .providerCredentialUnavailable: "无法读取本机 Keychain；请解锁 Mac 后重试"
            case .noSpeechDetected: "没有检测到有效语音"
            case .providerResourceUnavailable: "豆包语音资源尚未开通"
            case .providerRateLimited: "请求过于频繁，请稍后再试"
            case .providerUnavailable: "豆包服务暂时不可用"
            case .networkUnavailable: "网络不可用，请检查连接"
            }
        }
    }

    var icon: String {
        switch self {
        case .idle:
            "waveform"
        case .preparing:
            "mic.badge.plus"
        case .recording:
            "mic.fill"
        case .processing:
            "sparkles"
        case .delivered:
            "checkmark.circle.fill"
        case .pendingCopy:
            "doc.on.clipboard"
        case .cancelled:
            "xmark.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}
