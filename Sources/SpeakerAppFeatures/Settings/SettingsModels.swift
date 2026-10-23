import AppKit
@preconcurrency import Carbon
import Combine
import SpeakerCore

/// Startup and recovery warnings shown on the About page, plus the result of
/// the last diagnostics copy. Warnings accumulate so a later one never hides
/// an earlier one, and a copy result never replaces a warning.
@MainActor
package final class DiagnosticNoticeModel: ObservableObject {
    package enum CopyResult: Equatable, Sendable {
        case copied
        case failed
    }

    @Published package private(set) var warnings: [String] = []
    @Published package private(set) var copyResult: CopyResult?

    package init() {}

    package func publish(_ warning: String) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
    }

    package func publishCopyResult(_ result: CopyResult) {
        copyResult = result
    }

    package func dismissWarnings() {
        warnings = []
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
    let microphones: MicrophoneSelectionFeature
    let loginItemSettings: LoginItemSettingsModel
    let historyRetention: HistoryRetentionSettingsModel
    let recognition: SpeechRecognitionSettingsModel
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
        microphones: MicrophoneSelectionFeature,
        loginItemSettings: LoginItemSettingsModel,
        historyRetention: HistoryRetentionSettingsModel,
        recognition: SpeechRecognitionSettingsModel,
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
        self.microphones = microphones
        self.loginItemSettings = loginItemSettings
        self.historyRetention = historyRetention
        self.recognition = recognition
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
        microphones.refresh()
        await recognition.refresh()
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
        case .defaultSmooth: SpeakerCopy.RefinementMode.defaultSmooth
        case .conciseCleanup: SpeakerCopy.RefinementMode.conciseCleanup
        case .fullRewrite: SpeakerCopy.RefinementMode.fullRewrite
        case .custom: SpeakerCopy.RefinementMode.custom
        }
    }

    var subtitle: String {
        switch self {
        case .defaultSmooth: "直接使用识别结果，不额外整理"
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

    package init(selection: RefinementModeSelection) {
        switch selection {
        case .defaultSmooth: self = .defaultSmooth
        case .conciseCleanup: self = .conciseCleanup
        case .fullRewrite: self = .fullRewrite
        case .custom: self = .custom
        }
    }

    /// The list entry a built-in card selects. The Custom card stands for the
    /// whole Custom Mode list and selects no single entry.
    package var selection: RefinementModeSelection? {
        switch self {
        case .defaultSmooth: .defaultSmooth
        case .conciseCleanup: .conciseCleanup
        case .fullRewrite: .fullRewrite
        case .custom: nil
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

}

/// One row of the menu bar's Refinement Mode list.
package struct RefinementModeMenuEntry: Identifiable, Equatable {
    package let selection: RefinementModeSelection
    package let title: String
    package let isSelected: Bool
    /// Modes other than Default Smoothing need a saved Key.
    package let isEnabled: Bool

    package var id: RefinementModeSelection { selection }
}

@MainActor
package final class RefinementSettingsModel: ObservableObject {
    /// The mode new sessions use.
    @Published package private(set) var mode: TextRefinementMode = .defaultSmooth
    /// The list entry `mode` comes from.
    @Published package private(set) var selection: RefinementModeSelection = .defaultSmooth
    @Published package private(set) var customModes: [CustomRefinementMode] = []
    @Published package private(set) var providers = RefinementProviderSettings()
    @Published package private(set) var isUpdatingProvider = false
    @Published package var modelIDDraft = RefinementProviderProfile.defaultProfile(for: .deepSeek)
        .modelID
    @Published package var baseURLDraft = RefinementProviderProfile.defaultProfile(for: .deepSeek)
        .baseURL
    @Published package var isEditingModelID = false
    @Published package private(set) var providerNotice: String?
    @Published package var customName = RefinementSettingsModel.newCustomModeName
    @Published package var customPrompt = ""
    /// The Custom Mode the editor changes, or nil while it drafts a new one.
    @Published package private(set) var editingCustomModeID: UUID?
    @Published package var promptDraft = ""
    @Published package private(set) var promptOverrides = RefinementPromptOverrides()
    @Published package private(set) var inspectedPromptMode: BuiltInRefinementMode?
    @Published package private(set) var isEditingCustomMode = false
    @Published private(set) var notice: String?

    private let service: any RefinementProviderServicing
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: any AppSettingsStoring
    /// The selected profile's Key, retargeted whenever the profile changes.
    private let credential: ProviderCredentialEditor
    private var credentialChanges: AnyCancellable?
    /// The entry the user chose while its provider has no Key; it becomes
    /// active once the Key is saved.
    private var deferredSelection: RefinementModeSelection?
    private var providerDrafts:
        [RefinementProviderID: (modelID: String, baseURL: String, manual: Bool)] = [:]

    package var selectedProvider: RefinementProviderID { providers.selectedProvider }
    package var selectedProfile: RefinementProviderProfile { providers.selectedProfile }
    package var providerName: String { selectedProvider.displayName }
    package var hasStoredKey: Bool { credential.hasStoredKey }
    package var isUpdatingKey: Bool { credential.isUpdating }
    package var apiKeyDraft: String {
        get { credential.draft }
        set { credential.draft = newValue }
    }
    package var isConnectionVerified: Bool {
        if case .verified = credential.connection { true } else { false }
    }
    package var isCheckingConnection: Bool { credential.connection == .checking }
    package var connectionFailure: String? {
        if case .failed(let message) = credential.connection { message } else { nil }
    }
    var credentialNotice: String? { credential.failure }
    package var isMutating: Bool { isUpdatingKey || isUpdatingProvider }
    private var suggestedModelIDs: [String] {
        RefinementProviderCatalog.modelIDs(for: selectedProvider)
    }

    package func modelTitle(for modelID: String) -> String {
        modelID == suggestedModelIDs.first ? "\(modelID)（推荐）" : modelID
    }

    package var modelIDs: [String] {
        let listed = suggestedModelIDs
        let selected = selectedProfile.modelID
        return selected.isEmpty || listed.contains(selected) ? listed : listed + [selected]
    }

    package var hasValidProfile: Bool { (try? selectedProfile.validated()) != nil }
    package var hasProfileChanges: Bool {
        modelIDDraft != selectedProfile.modelID || baseURLDraft != selectedProfile.baseURL
    }

    package func selectProvider(_ provider: RefinementProviderID) async {
        guard !isMutating, provider != selectedProvider else { return }
        var updated = providers
        updated.selectedProvider = provider
        await updateProviderSettings(updated)
    }

    package func selectModel(_ modelID: String) async {
        guard !isMutating else { return }
        var profile = selectedProfile
        profile.modelID = modelID
        await saveProfile(profile)
    }

    package func saveProviderConfiguration() async {
        guard !isMutating else { return }
        await saveProfile(
            RefinementProviderProfile(
                provider: selectedProvider, modelID: modelIDDraft, baseURL: baseURLDraft))
    }

    private func saveProfile(_ profile: RefinementProviderProfile) async {
        do {
            let validated = try profile.validated()
            var updated = providers
            updated.profiles[validated.provider.rawValue] = validated
            await updateProviderSettings(updated)
        } catch {
            providerNotice = "请填写有效的模型 ID；自定义接口须使用不含凭据、查询参数或片段的 HTTPS Base URL。"
        }
    }

    private func updateProviderSettings(_ updated: RefinementProviderSettings) async {
        isUpdatingProvider = true
        defer { isUpdatingProvider = false }
        credential.invalidateConnection()
        do {
            let desiredSelection = deferredSelection ?? selection
            let profile = updated.selectedProfile
            let valid = (try? profile.validated()) != nil
            let configured = valid ? try await service.hasAPIKey(for: profile) : false
            try await settingsStore.updateRefinementProviders(updated)
            providerDrafts[selectedProvider] = (modelIDDraft, baseURLDraft, isEditingModelID)
            let activation = activation(for: desiredSelection, hasStoredKey: configured)
            if valid {
                try await configuration.selectRefinementProvider(
                    profile, mode: activation.activeMode)
            } else {
                try await configuration.selectRefinementMode(.defaultSmooth)
            }
            let switched = updated.selectedProvider != selectedProvider
            providers = updated
            apply(activation)
            credential.retarget(
                to: Self.credentialNamespace(for: profile, service: service),
                hasStoredKey: configured)
            providerNotice = nil
            if switched, let draft = providerDrafts[selectedProvider] {
                modelIDDraft = draft.modelID
                baseURLDraft = draft.baseURL
                isEditingModelID = draft.manual
            } else {
                syncProviderDrafts()
            }
            notice = activation.deferred == nil ? nil : "已保留整理模式；保存 \(providerName) Key 后会自动恢复。"
        } catch {
            providerNotice = SpeakerCopy.Failure.message(for: error)
        }
    }

    private func syncProviderDrafts() {
        modelIDDraft = selectedProfile.modelID
        baseURLDraft = selectedProfile.baseURL
        isEditingModelID = selectedProvider == .custom || !suggestedModelIDs.contains(modelIDDraft)
    }

    package init(
        service: any RefinementProviderServicing,
        configuration: VoiceInputConfigurationController,
        settingsStore: any AppSettingsStoring
    ) {
        self.service = service
        self.configuration = configuration
        self.settingsStore = settingsStore
        credential = ProviderCredentialEditor(
            namespace: Self.credentialNamespace(
                for: RefinementProviderSettings().selectedProfile, service: service))
        credentialChanges = credential.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// A valid profile's credential namespace. Custom Keys are bound to the
    /// profile's base URL by the service.
    private static func credentialNamespace(
        for profile: RefinementProviderProfile,
        service: any RefinementProviderServicing
    ) -> ProviderCredentialNamespace? {
        guard (try? profile.validated()) != nil else { return nil }
        return ProviderCredentialNamespace(
            hasKey: { try await service.hasAPIKey(for: profile) },
            save: { try await service.saveAPIKey($0, for: profile) },
            delete: { try await service.deleteAPIKey(for: profile.provider) })
    }

    package var choice: RefinementChoice {
        RefinementChoice(selection: selection)
    }

    package static let newCustomModeName = "我的模式"

    package var canAddCustomMode: Bool {
        customModes.count < CustomRefinementMode.maximumCount
    }

    /// The editor is changing the Custom Mode new sessions use.
    package var isEditingActiveCustomMode: Bool {
        editingCustomModeID != nil && selection.customModeID == editingCustomModeID
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

    /// Whether 保存并启用 is available: a valid draft and a saved Key. The
    /// card renders it rather than recomputing the rule.
    package var canSaveCustomMode: Bool {
        hasStoredKey && canSaveCustomModeDraft
    }

    /// Whether 保存 is available: a valid draft that fits in the list. Saving
    /// without enabling needs no Key.
    package var canSaveCustomModeDraft: Bool {
        (editingCustomModeID != nil || canAddCustomMode)
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

    package func load() async {
        let loadedSettings = await settingsStore.load().settings
        providers = loadedSettings.refinementProviders
        syncProviderDrafts()
        credential.retarget(
            to: Self.credentialNamespace(for: selectedProfile, service: service))
        await credential.refresh()
        promptOverrides = loadedSettings.refinementPromptOverrides
        customModes = loadedSettings.customRefinementModes
        let desired = loadedSettings.refinementSelection
        loadCustomModeDraft(desired.customModeID ?? customModes.first?.id)
        do {
            let desiredMode = try (resolvedMode(desired) ?? .defaultSmooth).validated()
            let activation = activation(for: desired, hasStoredKey: hasStoredKey)
            if hasValidProfile {
                try await configuration.selectRefinementProvider(
                    selectedProfile, mode: activation.activeMode)
            } else {
                try await configuration.selectRefinementMode(.defaultSmooth)
            }
            apply(activation)
            inspectedPromptMode = desired.builtInMode
            syncPromptDraft()
            if activation.deferred != nil {
                notice = "已保留“\(desiredMode.displayName)”模式；保存 \(providerName) Key 后会自动恢复使用。"
            } else {
                notice = nil
            }
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func saveAPIKey() async {
        guard !isMutating, hasValidProfile, !hasProfileChanges else { return }
        guard await credential.save() else { return }
        do {
            if let deferredSelection, let restoredMode = resolvedMode(deferredSelection) {
                try await configuration.selectRefinementMode(restoredMode)
                mode = restoredMode
                selection = deferredSelection
                inspectedPromptMode = deferredSelection.builtInMode
                self.deferredSelection = nil
                syncPromptDraft()
            }
            notice = nil
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func deleteAPIKey() async {
        guard !isMutating else { return }
        guard await credential.delete() else { return }
        deferredSelection = nil
        await select(.defaultSmooth)
    }

    package func checkConnection() {
        guard !isMutating, hasStoredKey, hasValidProfile, !hasProfileChanges else { return }
        let service = service
        let profile = selectedProfile
        let providerName = providerName
        credential.checkConnection(
            { try await service.checkConnection(profile: profile) },
            describeFailure: { error in
                if let failure = error as? TextRefinementFailure {
                    Self.connectionMessage(for: failure.kind, providerName: providerName)
                } else {
                    SpeakerCopy.Failure.message(for: error)
                }
            })
    }

    package func shutdown() async {
        await credential.shutdown()
    }

    package func select(
        _ choice: RefinementChoice,
        persist: Bool = true
    ) async {
        guard !isUpdatingProvider else { return }
        if let builtInMode = choice.builtInMode {
            inspectPrompt(builtInMode)
        } else {
            inspectedPromptMode = nil
        }

        if choice == .custom {
            loadCustomModeDraft(selection.customModeID ?? customModes.first?.id)
            isEditingCustomMode = true
            notice =
                hasStoredKey
                ? nil
                : "可先编辑自定义模式；保存 \(providerName) API Key 后才能启用。"
            return
        }

        isEditingCustomMode = false

        if choice != .defaultSmooth, !hasStoredKey {
            notice = "提示词可查看和编辑；保存 \(providerName) API Key 后才能启用该模式。"
            return
        }

        guard let selection = choice.selection else { return }
        await activate(selection, persist: persist)
    }

    /// Makes `selection` the mode for new sessions. A session already
    /// recording keeps the mode it captured when its shortcut was pressed.
    private func activate(_ selection: RefinementModeSelection, persist: Bool) async {
        guard let selectedMode = resolvedMode(selection) else { return }
        do {
            let validated = try selectedMode.validated()
            try await configuration.selectRefinementMode(validated)
            mode = validated
            self.selection = selection
            syncPromptDraft()
            notice = nil
            if persist {
                try await persistSelection(selection)
                deferredSelection = nil
            }
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// The menu's mode list: built-in modes, then every Custom Mode in list
    /// order, the same order the Refinement Mode shortcut steps through.
    package var menuEntries: [RefinementModeMenuEntry] {
        RefinementModeSelection.order(customModes: customModes).map { entry in
            RefinementModeMenuEntry(
                selection: entry,
                title: title(for: entry),
                isSelected: entry == selection,
                isEnabled: entry == .defaultSmooth || hasStoredKey
            )
        }
    }

    package func title(for entry: RefinementModeSelection) -> String {
        switch entry {
        case .defaultSmooth: SpeakerCopy.RefinementMode.defaultSmooth
        case .conciseCleanup: SpeakerCopy.RefinementMode.conciseCleanup
        case .fullRewrite: SpeakerCopy.RefinementMode.fullRewrite
        case .custom(let id):
            customModes.first { $0.id == id }?.name ?? SpeakerCopy.RefinementMode.custom
        }
    }

    /// Selects one entry of the mode list, as the menu does.
    package func selectMode(_ entry: RefinementModeSelection) async {
        if let id = entry.customModeID {
            isEditingCustomMode = false
            await selectCustomMode(id)
        } else {
            await select(RefinementChoice(selection: entry))
        }
    }

    private struct SelectionActivation {
        let active: RefinementModeSelection
        let activeMode: TextRefinementMode
        let deferred: RefinementModeSelection?
    }

    /// Default Smoothing stays live while a provider-backed choice waits for
    /// its Key; a Custom Mode no longer in the list falls back the same way.
    private func activation(
        for desired: RefinementModeSelection, hasStoredKey: Bool
    ) -> SelectionActivation {
        guard let desiredMode = resolvedMode(desired) else {
            return SelectionActivation(
                active: .defaultSmooth, activeMode: .defaultSmooth, deferred: nil)
        }
        let plan = RefinementActivationPlan(desiredMode: desiredMode, hasStoredKey: hasStoredKey)
        return plan.deferredMode == nil
            ? SelectionActivation(active: desired, activeMode: plan.activeMode, deferred: nil)
            : SelectionActivation(
                active: .defaultSmooth, activeMode: plan.activeMode, deferred: desired)
    }

    private func apply(_ activation: SelectionActivation) {
        mode = activation.activeMode
        selection = activation.active
        deferredSelection = activation.deferred
    }

    private func resolvedMode(_ selection: RefinementModeSelection) -> TextRefinementMode? {
        selection.refinementMode(customModes: customModes, promptOverrides: promptOverrides)
    }

    /// Saves the inspected built-in mode's prompt override, taking
    /// effect for new sessions through the same `refinementInstruction` request path.
    package func savePromptOverride() async {
        guard !isMutating else { return }
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
        guard !isMutating else { return }
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
        // A deferred built-in mode resolves its prompt when the Key arrives.
    }

    /// Opens the editor on a new Custom Mode draft.
    package func beginNewCustomMode() {
        guard !isMutating, canAddCustomMode else { return }
        loadCustomModeDraft(nil)
        inspectedPromptMode = nil
        isEditingCustomMode = true
    }

    /// Opens the editor on one saved Custom Mode.
    package func editCustomMode(_ id: UUID) {
        guard !isMutating, customModes.contains(where: { $0.id == id }) else { return }
        loadCustomModeDraft(id)
        inspectedPromptMode = nil
        isEditingCustomMode = true
    }

    private func loadCustomModeDraft(_ id: UUID?) {
        if let id, let saved = customModes.first(where: { $0.id == id }) {
            editingCustomModeID = saved.id
            customName = saved.name
            customPrompt = saved.prompt
        } else {
            editingCustomModeID = nil
            customName = Self.newCustomModeName
            customPrompt = ""
        }
    }

    /// Saves the editor's draft into the Custom Mode list and, by default,
    /// enables it. Saving the mode in use applies its new prompt to the next
    /// session; saving any other mode without enabling it changes nothing
    /// live and needs no Key.
    package func saveCustomMode(enabling: Bool = true) async {
        guard !isMutating else { return }
        guard !enabling || hasStoredKey else {
            notice = "请先保存 \(providerName) API Key，再保存并启用自定义模式。"
            return
        }
        do {
            let draft = try CustomRefinementMode(
                id: editingCustomModeID ?? UUID(),
                name: customName,
                prompt: customPrompt
            ).validated()
            let saved = try await settingsStore.saveCustomRefinementMode(draft)
            customModes = saved.customRefinementModes
            loadCustomModeDraft(draft.id)
            if enabling {
                try await configuration.selectRefinementMode(draft.textRefinementMode)
                mode = draft.textRefinementMode
                selection = .custom(draft.id)
                inspectedPromptMode = nil
                isEditingCustomMode = false
                try await persistSelection(selection)
                deferredSelection = nil
            } else if selection == .custom(draft.id) {
                try await configuration.selectRefinementMode(draft.textRefinementMode)
                mode = draft.textRefinementMode
            }
            notice = nil
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Makes one saved Custom Mode the mode for new sessions.
    package func selectCustomMode(_ id: UUID) async {
        guard !isMutating else { return }
        guard hasStoredKey else {
            notice = "请先保存 \(providerName) API Key。"
            return
        }
        guard customModes.contains(where: { $0.id == id }) else { return }
        inspectedPromptMode = nil
        await activate(.custom(id), persist: true)
    }

    /// Deletes one Custom Mode. Deleting the mode in use returns new sessions
    /// to Default Smoothing.
    package func deleteCustomMode(_ id: UUID) async {
        guard !isMutating else { return }
        do {
            let saved = try await settingsStore.deleteCustomRefinementMode(id: id)
            customModes = saved.customRefinementModes
            if deferredSelection == .custom(id) {
                deferredSelection = nil
            }
            if selection == .custom(id) {
                try await configuration.selectRefinementMode(.defaultSmooth)
                mode = .defaultSmooth
                selection = .defaultSmooth
            }
            if editingCustomModeID == id {
                loadCustomModeDraft(customModes.first?.id)
            }
            notice = nil
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Moves one Custom Mode up (negative) or down (positive) in the list,
    /// which is also the order the Refinement Mode shortcut steps through.
    package func moveCustomMode(_ id: UUID, by offset: Int) async {
        guard !isMutating, let index = customModes.firstIndex(where: { $0.id == id }) else {
            return
        }
        do {
            let saved = try await settingsStore.moveCustomRefinementMode(
                id: id, to: index + offset)
            customModes = saved.customRefinementModes
            notice = nil
        } catch {
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    private func persistSelection(_ selection: RefinementModeSelection) async throws {
        guard
            let preference = RefinementPreference(
                selection: selection, customModes: customModes)
        else { return }
        try await settingsStore.updateRefinement(preference)
    }

    private static func connectionMessage(
        for kind: TextRefinementFailureKind, providerName: String
    ) -> String {
        switch kind {
        case .invalidCredential, .authentication:
            "\(providerName) Key 无效，请重新保存后检查连接。"
        case .credentialAccessDenied:
            "macOS 拒绝访问 \(providerName) 凭据，请重新保存 Key。"
        case .credentialInteractionUnavailable:
            "\(providerName) 凭据当前不可用，请解锁 Mac 后重试。"
        case .credentialMalformed:
            "已保存的 \(providerName) Key 无法读取，请删除后重新保存。"
        case .credentialStorageUnavailable:
            "本机凭据存储暂时不可用，请稍后重试。"
        case .insufficientBalance:
            "\(providerName) 余额不足，请充值后重试。"
        case .rateLimited:
            "\(providerName) 请求过于频繁，请稍后重试。"
        case .network:
            "无法连接 \(providerName)，请检查网络。"
        case .systemNetworkTimeout:
            "系统报告 \(providerName) 网络请求超时。"
        case .cancelled:
            "\(providerName) 连接检查已取消。"
        case .serverError, .serviceUnavailable, .insufficientSystemResource:
            "\(providerName) 服务暂时不可用，请稍后重试。"
        default:
            "\(providerName) 返回了无法验证的响应，请稍后重试。"
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
    /// The entry the last delete removed, offered back until the next change.
    @Published package private(set) var recentlyDeleted: DictionaryEntry?
    private var recentlyDeletedIndex = 0

    private let store: any PersonalDictionaryStoring
    private let configuration: VoiceInputConfigurationController
    private var allowsPersistence = false
    /// The last queued mutation. Each one starts from the entries the
    /// previous one saved, so two quick deletes never write the first word
    /// back.
    private var pendingMutation: Task<Bool, Never>?

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
        let added = await mutate { $0 + [entry] }
        if added { recentlyDeleted = nil }
        return added
    }

    package func delete(_ id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        guard await mutate({ $0.filter { $0.id != id } }) else { return }
        recentlyDeleted = entry
        recentlyDeletedIndex = index
    }

    /// Puts the last deleted entry back where it was.
    @discardableResult
    package func undoDelete() async -> Bool {
        guard let entry = recentlyDeleted else { return false }
        let index = recentlyDeletedIndex
        let restored = await mutate { current in
            guard !current.contains(where: { $0.id == entry.id }) else { return current }
            var entries = current
            entries.insert(entry, at: min(index, entries.count))
            return entries
        }
        if restored { recentlyDeleted = nil }
        return restored
    }

    package func dismissUndo() {
        recentlyDeleted = nil
    }

    private func mutate(
        _ transform: @escaping ([DictionaryEntry]) -> [DictionaryEntry]
    ) async -> Bool {
        let previous = pendingMutation
        let mutation = Task {
            _ = await previous?.value
            return await save(transform(entries))
        }
        pendingMutation = mutation
        return await mutation.value
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
        guard
            let modifier = CustomHotKey.PhysicalModifier(
                keyCode: UInt32(keyCode)
            )
        else {
            candidate = nil
            return nil
        }
        let hotKey = CustomHotKey.modifierOnly(
            modifier,
            displayName: modifier.displayName
        )
        let expectedFlag: NSEvent.ModifierFlags =
            switch modifier {
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

extension CustomHotKey.PhysicalModifier {
    fileprivate var displayName: String {
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
    /// The answer to a chord that is not safe for a global shortcut.
    package static let recordingPrompt = "请换一个组合键，或单独按左/右 ⌥、⌃、⇧"
    package static let soloCommandPrompt = "不能单独使用 ⌘"
    package static let missingModifierPrompt = "组合键需要至少一个修饰键"
    package static let editingConflictPrompt = "这是常用编辑命令，请换一个"

    private var modifierPolicy = ShortcutRecorderModifierPolicy()

    package init() {}

    package mutating func handle(
        _ input: ShortcutRecorderInput
    ) -> ShortcutRecorderDecision {
        switch input {
        case .flagsChanged(let keyCode, let flags):
            if let hotKey = modifierPolicy.handle(keyCode: keyCode, flags: flags) {
                return .capture(hotKey)
            }
            if [kVK_Command, kVK_RightCommand].contains(Int(keyCode)),
                !flags.contains(.command)
            {
                return .reject(Self.soloCommandPrompt)
            }
            return .consume
        case .keyDown(let keyCode, let flags, let charactersIgnoringModifiers):
            modifierPolicy.reset()
            guard keyCode != UInt16(kVK_Escape) else { return .cancel }
            let modifiers = Self.carbonModifiers(flags)
            guard modifiers != 0 else {
                return .reject(Self.missingModifierPrompt)
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
                return .reject(Self.editingConflictPrompt)
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
        let key: String =
            switch Int(keyCode) {
            case kVK_Return: "Return"
            case kVK_Tab: "Tab"
            case kVK_Space: "Space"
            case kVK_Escape: "Esc"
            default: charactersIgnoringModifiers?.uppercased() ?? "Key \(keyCode)"
            }
        return prefix + key
    }
}

/// Records the recording shortcut from the Settings window. Only the window's
/// own key events reach it, so the live shortcut must be released while it
/// records; `onEnd` hands it back.
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    /// Why the last chord was refused. Recording continues.
    @Published private(set) var rejection: String?
    private var monitor: Any?
    private var policy = ShortcutRecorderPolicy()
    private var onEnd: (() -> Void)?

    /// Records one chord. A capture runs `onCapture` before `onEnd`, so the
    /// new shortcut is chosen before the old one would listen again.
    func start(
        onCapture: @escaping (CustomHotKey) -> Void,
        onEnd: @escaping () -> Void = {}
    ) {
        stop()
        isRecording = true
        rejection = nil
        policy = ShortcutRecorderPolicy()
        self.onEnd = onEnd
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            let input: ShortcutRecorderInput =
                if event.type == .flagsChanged {
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
            case .capture(let hotKey):
                onCapture(hotKey)
                self.stop()
            case .reject(let message):
                self.rejection = message
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
        rejection = nil
        let onEnd = onEnd
        self.onEnd = nil
        onEnd?()
    }
}
