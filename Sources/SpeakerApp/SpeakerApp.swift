import AppKit
import Combine
import SpeakerCore
import SwiftUI

@main
struct SpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var runtime: SpeakerRuntime

    init() {
        _runtime = StateObject(wrappedValue: SpeakerRuntime())
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

    @Published private(set) var shortcutChoice: ShortcutChoice
    @Published private(set) var shortcutNotice: String?

    private let fnMonitor: FnEventMonitor
    private let customHotKeyMonitor: CustomHotKeyMonitor
    private let panel: VoiceInputPanelController
    private var started = false

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
        let sessionActor = VoiceInputSessions(
            audioCapture: audio,
            targetCapture: targets,
            textProcessor: processor,
            delivery: targets,
            clipboard: SystemClipboardWriter(),
            history: history
        )
        let sessions = VoiceInputSessionModel(sessions: sessionActor)
        self.sessions = sessions
        self.history = history
        doubaoSettings = DoubaoSettingsModel(service: doubao)
        refinementSettings = RefinementSettingsModel(
            service: deepSeek,
            configuration: configuration
        )
        dictionarySettings = DictionarySettingsModel(
            store: dictionaryStore,
            configuration: configuration
        )
        historyModel = HistoryModel(store: history)
        let triggerHandler: @Sendable (GlobalVoiceTrigger) -> Void = { trigger in
            let command: VoiceInputCommand?
            switch trigger {
            case .pressed:
                command = .pressed
            case .released:
                command = .released
            case .cancel:
                command = .cancel
            case .monitorRecovered:
                command = nil
            }
            if let command {
                Task {
                    await sessionActor.send(command)
                }
            }
        }
        fnMonitor = FnEventMonitor(handler: triggerHandler)
        customHotKeyMonitor = CustomHotKeyMonitor(handler: triggerHandler)
        panel = VoiceInputPanelController(model: sessions)
        shortcutChoice = ShortcutChoice(
            rawValue: UserDefaults.standard.string(forKey: "voiceShortcut") ?? ""
        ) ?? .fn
    }

    func start() {
        guard !started else { return }
        started = true
        permissions.refresh()
        sessions.startObserving()
        activateShortcut(shortcutChoice, persist: false)
        panel.start()
        Task {
            await dictionarySettings.load()
            await refinementSettings.load()
            await historyModel.refresh()
        }
    }

    func selectShortcut(_ choice: ShortcutChoice) {
        guard choice != shortcutChoice else { return }
        activateShortcut(choice, persist: true)
    }

    private func activateShortcut(_ choice: ShortcutChoice, persist: Bool) {
        switch choice {
        case .fn:
            customHotKeyMonitor.unregister()
            guard fnMonitor.start() else {
                shortcutNotice = "Fn 监听未能启动，请先授予辅助功能权限后重试。"
                return
            }
        case .optionSpace:
            fnMonitor.stop()
            guard customHotKeyMonitor.register(.optionSpace) else {
                shortcutNotice = "⌥ Space 已被其他应用占用，已继续使用 Fn。"
                _ = fnMonitor.start()
                shortcutChoice = .fn
                return
            }
        }

        shortcutChoice = choice
        shortcutNotice = nil
        if persist {
            UserDefaults.standard.set(choice.rawValue, forKey: "voiceShortcut")
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

    private let service: CredentialedDoubaoTranscriber

    init(service: CredentialedDoubaoTranscriber) {
        self.service = service
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
        case .resourceNotActivated: "尚未开通豆包极速版语音资源"
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
}

@MainActor
private final class RefinementSettingsModel: ObservableObject {
    @Published private(set) var mode: TextRefinementMode = .defaultSmooth
    @Published var apiKeyDraft = ""
    @Published var customName = "我的整理规则"
    @Published var customPrompt = ""
    @Published private(set) var hasStoredKey = false
    @Published private(set) var notice: String?

    private let service: CredentialedDeepSeekTextRefiner
    private let configuration: VoiceInputConfigurationController

    init(
        service: CredentialedDeepSeekTextRefiner,
        configuration: VoiceInputConfigurationController
    ) {
        self.service = service
        self.configuration = configuration
    }

    var choice: RefinementChoice {
        switch mode {
        case .defaultSmooth: .defaultSmooth
        case .conciseCleanup: .conciseCleanup
        case .fullRewrite: .fullRewrite
        case .custom: .custom
        }
    }

    func load() async {
        do {
            hasStoredKey = try await service.hasAPIKey()
        } catch {
            notice = error.localizedDescription
        }

        let savedChoice = RefinementChoice(
            rawValue: UserDefaults.standard.string(forKey: "refinementChoice") ?? ""
        ) ?? .defaultSmooth
        customName = UserDefaults.standard.string(forKey: "customRefinementName")
            ?? "我的整理规则"
        customPrompt = UserDefaults.standard.string(forKey: "customRefinementPrompt") ?? ""
        await select(savedChoice, persist: false)
    }

    func saveAPIKey() async {
        do {
            try await service.saveAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            hasStoredKey = true
            notice = "DeepSeek Key 已保存到本机 Keychain。"
        } catch {
            notice = error.localizedDescription
        }
    }

    func deleteAPIKey() async {
        do {
            try await service.deleteAPIKey()
            hasStoredKey = false
            apiKeyDraft = ""
            await select(.defaultSmooth)
            notice = "DeepSeek Key 已删除，已切回默认顺滑。"
        } catch {
            notice = error.localizedDescription
        }
    }

    func select(_ choice: RefinementChoice, persist: Bool = true) async {
        if choice != .defaultSmooth, !hasStoredKey {
            notice = "请先保存 DeepSeek API Key，再启用进一步整理。"
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
                persistSelection(choice)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func saveCustomMode() async {
        await select(.custom)
    }

    private func apply(
        _ selectedMode: TextRefinementMode,
        choice: RefinementChoice,
        persist: Bool
    ) async {
        try? await configuration.selectRefinementMode(selectedMode)
        mode = selectedMode
        if persist { persistSelection(choice) }
    }

    private func persistSelection(_ choice: RefinementChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: "refinementChoice")
        UserDefaults.standard.set(customName, forKey: "customRefinementName")
        UserDefaults.standard.set(customPrompt, forKey: "customRefinementPrompt")
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
        _ = await save(entries)
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

    init(store: VersionedLocalSessionHistory) {
        self.store = store
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
}

private enum ShortcutChoice: String, CaseIterable, Identifiable {
    case fn
    case optionSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: "Fn"
        case .optionSpace: "⌥ Space"
        }
    }
}

private final class SpeakerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
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
            Label(refinement.mode.displayName, systemImage: "text.alignleft")

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

private struct SettingsView: View {
    @ObservedObject var runtime: SpeakerRuntime

    private var permissions: PermissionModel { runtime.permissions }

    var body: some View {
        Form {
            Section("系统权限") {
                PermissionRow(
                    title: "辅助功能",
                    explanation: "用于监听全局快捷键、捕获输入目标并安全送达文本。",
                    kind: .accessibility,
                    state: permissions.snapshot.accessibility,
                    permissions: permissions
                )

                PermissionRow(
                    title: "麦克风",
                    explanation: "用于按住快捷键期间录制当前语音。",
                    kind: .microphone,
                    state: permissions.snapshot.microphone,
                    permissions: permissions
                )
            }

            Section("语音输入") {
                Picker(
                    "按住说话快捷键",
                    selection: Binding(
                        get: { runtime.shortcutChoice },
                        set: { runtime.selectShortcut($0) }
                    )
                ) {
                    ForEach(ShortcutChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                if let shortcutNotice = runtime.shortcutNotice {
                    Text(shortcutNotice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

            }

            DoubaoSettingsSection(model: runtime.doubaoSettings)
            RefinementSettingsSection(model: runtime.refinementSettings)
            DictionarySettingsSection(model: runtime.dictionarySettings)
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 760)
        .task {
            permissions.refresh()
            await runtime.doubaoSettings.refresh()
            await runtime.refinementSettings.load()
            await runtime.dictionarySettings.load()
        }
    }
}

private struct RefinementSettingsSection: View {
    @ObservedObject var model: RefinementSettingsModel

    var body: some View {
        Section("文本整理") {
            Picker(
                "整理模式",
                selection: Binding(
                    get: { model.choice },
                    set: { choice in Task { await model.select(choice) } }
                )
            ) {
                ForEach(RefinementChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }

            SecureField("DeepSeek API Key（可选）", text: $model.apiKeyDraft)
                .textContentType(.password)

            HStack {
                Button("保存 DeepSeek Key") {
                    Task { await model.saveAPIKey() }
                }
                .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("删除 Key", role: .destructive) {
                    Task { await model.deleteAPIKey() }
                }
                .disabled(!model.hasStoredKey)
            }

            if model.choice == .custom {
                TextField("规则名称", text: $model.customName)
                TextEditor(text: $model.customPrompt)
                    .font(.body)
                    .frame(minHeight: 72)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                HStack {
                    Text("最多 4000 字符")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存并启用自定义规则") {
                        Task { await model.saveCustomMode() }
                    }
                }
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DictionarySettingsSection: View {
    @ObservedObject var model: DictionarySettingsModel

    var body: some View {
        Section("个人词库") {
            ForEach($model.entries) { $entry in
                HStack(alignment: .firstTextBaseline) {
                    Toggle("", isOn: $entry.isEnabled)
                        .labelsHidden()
                        .onChange(of: entry.isEnabled) {
                            Task { await model.saveEdits() }
                        }
                    TextField("标准写法", text: $entry.canonicalTerm)
                        .onSubmit { Task { await model.saveEdits() } }
                    TextField(
                        "别名（逗号分隔）",
                        text: Binding(
                            get: { entry.aliases.joined(separator: "，") },
                            set: { value in
                                entry.aliases = value
                                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
                                    .map(String.init)
                            }
                        )
                    )
                    .onSubmit { Task { await model.saveEdits() } }
                    Button(role: .destructive) {
                        Task { await model.delete(entry.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("新增标准写法", text: $model.draftCanonical)
                TextField("口语别名（逗号分隔）", text: $model.draftAliases)
                Button("添加") {
                    Task { await model.add() }
                }
                .disabled(model.draftCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DoubaoSettingsSection: View {
    @ObservedObject var model: DoubaoSettingsModel

    var body: some View {
        Section("豆包语音") {
            SecureField("输入 API Key", text: $model.apiKeyDraft)
                .textContentType(.password)

            HStack {
                Button("保存") {
                    Task { await model.save() }
                }
                .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("检查连接") {
                    Task { await model.checkConnection() }
                }
                .disabled(!model.hasConfiguredKey)

                Spacer()

                Button("删除 Key", role: .destructive) {
                    Task { await model.delete() }
                }
                .disabled(!model.hasConfiguredKey)
            }

            Text(model.summary)
                .font(.caption)
                .foregroundStyle(statusColor)
                .textSelection(.disabled)
        }
    }

    private var statusColor: Color {
        if case .failure = model.status { return .red }
        if case .success = model.status { return .green }
        return .secondary
    }
}

private struct PermissionRow: View {
    let title: String
    let explanation: String
    let kind: PermissionKind
    let state: PermissionState
    @ObservedObject var permissions: PermissionModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(buttonTitle) {
                Task {
                    await permissions.request(kind)
                }
            }
            .disabled(state == .granted)
        }
    }

    private var icon: String {
        state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var color: Color {
        state == .granted ? .green : .orange
    }

    private var buttonTitle: String {
        switch state {
        case .granted:
            "已授权"
        case .notDetermined:
            "请求授权"
        case .denied:
            "打开授权"
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
                        HistoryDetailView(record: record) {
                            Task { await model.delete(record.sessionID) }
                        }
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
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("时间", value: record.startedAt.formatted())
                LabeledContent("目标 App", value: record.applicationName ?? "无")
                LabeledContent("整理模式", value: record.refinementModeName ?? "默认顺滑")
                LabeledContent("送达状态", value: record.outcome.historyLabel)
                HistoryTextBlock(title: "豆包转录", text: record.transcription)
                if record.deepSeekText != nil || record.refinementStatus == "fellBack" {
                    HistoryTextBlock(title: "DeepSeek 结果", text: record.deepSeekText)
                    LabeledContent("DeepSeek 状态", value: record.refinementStatus ?? "未知")
                }
                HistoryTextBlock(title: "最终文本", text: record.finalText)
                if !record.dictionaryReplacements.isEmpty {
                    Text("词库替换")
                        .font(.headline)
                    ForEach(record.dictionaryReplacements, id: \.utf16Location) { replacement in
                        Text("\(replacement.matchedText) → \(replacement.canonicalTerm)")
                    }
                }
                if let providerRequestID = record.providerRequestID {
                    LabeledContent("豆包请求 ID", value: providerRequestID)
                }
                if let deepSeekRequestID = record.deepSeekRequestID {
                    LabeledContent("DeepSeek 请求 ID", value: deepSeekRequestID)
                }

                HStack {
                    Button("复制最终文本") {
                        copy(record.finalText ?? record.transcription ?? "")
                    }
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
    private let panel: NSPanel
    private let model: VoiceInputSessionModel
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init(model: VoiceInputSessionModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
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
        case .delivered, .cancelled:
            showPanel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        case .preparing, .recording, .processing, .pendingCopy, .failed:
            showPanel()
        }
    }

    private func showPanel() {
        if let frame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 36
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }
}

private struct VoiceInputOverlay: View {
    @ObservedObject var model: VoiceInputSessionModel

    var body: some View {
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
            }

            Spacer()

            if model.presentation.activity.isActive {
                Button("取消") {
                    model.send(.cancel)
                }
            } else if case .pendingCopy = model.presentation.activity {
                Button("复制") {
                    model.send(.copyPendingResult)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .frame(minHeight: 86)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .padding(8)
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
            "按住 Fn 开始讲话"
        case .preparing:
            "请稍候"
        case .recording:
            "松开 Fn 提交，按 Esc 取消"
        case let .processing(_, _, applicationName):
            applicationName.map { "输入目标：\($0)" } ?? "正在确定输入位置"
        case let .delivered(_, applicationName, _):
            "已写入 \(applicationName)"
        case let .pendingCopy(_, text, _):
            text
        case .cancelled:
            "没有发送音频或文本"
        case let .failed(_, failure):
            switch failure {
            case .recordingFailed: "无法完成录音"
            case .transcriptionFailed: "无法完成转录"
            case .providerNotConfigured: "请先在设置中配置豆包 API Key"
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
