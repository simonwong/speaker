import Combine
import Foundation
import SpeakerCore

extension SpeechRecognitionProviderID {
    package var displayName: String {
        switch self {
        case .doubao: "豆包语音"
        case .openAI: "OpenAI 语音识别"
        case .qwen: "阿里千问语音识别"
        case .apple: "Apple 语音识别"
        }
    }
}

extension QwenASRRegion {
    package var displayName: String {
        switch self {
        case .beijing: "北京"
        case .singapore: "新加坡"
        }
    }
}

extension SpeechRecognitionMethod {
    package var displayName: String {
        switch self {
        case .streaming: "流式识别（边录边传）"
        case .completeRecording: "整段识别（录完上传）"
        case .unsupported: "不支持的识别方式"
        }
    }
}

@MainActor
package final class SpeechRecognitionSettingsModel: ObservableObject {
    @Published package private(set) var providers = SpeechRecognitionProviderSettings()
    @Published package private(set) var hasStoredKey = false
    /// Whether the selected profile and its credential have been read once,
    /// so `hasStoredKey == false` means a missing Key rather than "unread".
    @Published package private(set) var hasLoaded = false
    @Published package private(set) var isUpdatingProvider = false
    @Published package private(set) var isUpdatingKey = false
    @Published package private(set) var notice: String?
    @Published package var apiKeyDraft = ""
    /// The on-device language model's state; nil until read, or while a cloud
    /// provider is selected.
    @Published package private(set) var onDeviceModelStatus: OnDeviceSpeechModelStatus?
    /// Download progress from 0 to 1 while the on-device model installs.
    @Published package private(set) var modelInstallProgress: Double?

    private let credentials: any ProviderCredentialStoring
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: any AppSettingsStoring
    private let onDevice: any OnDeviceSpeechRecognizing
    /// Apple's on-device recognition needs macOS 26; earlier releases never list it.
    package let isOnDeviceSupported: Bool
    private var generation: UInt64 = 0
    private var isShutdown = false
    private var activeOperations = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    package init(
        credentials: any ProviderCredentialStoring,
        configuration: VoiceInputConfigurationController,
        settingsStore: any AppSettingsStoring,
        onDevice: any OnDeviceSpeechRecognizing = AppleSpeechRecognizer(),
        isOnDeviceSupported: Bool = AppleSpeechRecognizer.isSupported
    ) {
        self.credentials = credentials
        self.configuration = configuration
        self.settingsStore = settingsStore
        self.onDevice = onDevice
        self.isOnDeviceSupported = isOnDeviceSupported
    }

    /// The provider choices in display order: the on-device option, which needs
    /// no Key, comes first where this Mac can run it and is absent otherwise.
    package var availableProviders: [SpeechRecognitionProviderID] {
        let onDevice = SpeechRecognitionProviderID.allCases.filter(\.isOnDevice)
        let cloud = SpeechRecognitionProviderID.allCases.filter { !$0.isOnDevice }
        return (isOnDeviceSupported ? onDevice : []) + cloud
    }

    /// Whether the selected provider can transcribe now: a saved Key for a cloud
    /// provider, an installed language model for on-device recognition.
    package var isSelectedProviderReady: Bool {
        selectedProvider.isOnDevice ? onDeviceModelStatus == .installed : hasStoredKey
    }

    package var selectedProvider: SpeechRecognitionProviderID { providers.selectedProvider }
    package var selectedProfile: SpeechRecognitionProfile { providers.selectedProfile }
    package var providerName: String { selectedProvider.displayName }
    package var isMutating: Bool {
        isUpdatingKey || isUpdatingProvider || modelInstallProgress != nil
    }
    package var hasValidProfile: Bool { (try? selectedProfile.validated()) != nil }
    package var modelIDs: [String] {
        let listed = SpeechRecognitionProviderCatalog.modelIDs(
            for: selectedProvider, method: selectedProfile.method)
        let selected = selectedProfile.model
        return selected.isEmpty || listed.contains(selected) ? listed : listed + [selected]
    }

    package func load() async {
        guard !isMutating, !isShutdown else { return }
        activeOperations += 1
        defer { finishOperation() }
        isUpdatingProvider = true
        generation &+= 1
        let token = generation
        defer { isUpdatingProvider = false }
        let loaded = await settingsStore.load().settings.speechRecognitionProviders
            .resolved(onDeviceAvailable: isOnDeviceSupported)
        guard token == generation, !isShutdown else { return }
        providers = loaded
        await configuration.restoreRecognitionProvider(loaded.selectedProfile)
        guard token == generation, !isShutdown else { return }
        do {
            _ = try loaded.validated()
        } catch {
            guard token == generation, !isShutdown else { return }
            notice = SpeakerCopy.Failure.message(for: error)
            hasLoaded = true
            return
        }
        await readCredential(token: token, profile: selectedProfile)
        guard token == generation, !isShutdown else { return }
        hasLoaded = true
    }

    package func refresh() async {
        guard !isMutating, !isShutdown else { return }
        activeOperations += 1
        defer { finishOperation() }
        generation &+= 1
        await readCredential(token: generation, profile: selectedProfile)
    }

    private func readCredential(token: UInt64, profile: SpeechRecognitionProfile) async {
        guard let credentialID = profile.credentialProviderID else {
            let status = await onDevice.modelStatus()
            guard token == generation, !isShutdown else { return }
            hasStoredKey = false
            onDeviceModelStatus = status
            notice = nil
            return
        }
        onDeviceModelStatus = nil
        do {
            _ = try profile.validated()
            let value = try await credentials.apiKey(for: credentialID)
            guard token == generation, !isShutdown else { return }
            hasStoredKey = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            notice = nil
        } catch {
            guard token == generation, !isShutdown else { return }
            hasStoredKey = false
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func selectProvider(_ provider: SpeechRecognitionProviderID) async {
        guard provider != selectedProvider else { return }
        let retained = providers.profile(for: provider)
        let selected =
            (try? retained.validated())
            ?? SpeechRecognitionProfile(
                provider: provider, region: retained.region,
                method: SpeechRecognitionProviderCatalog.methods(for: provider).contains(
                    retained.method)
                    ? retained.method : .defaultMethod(for: provider))
        await saveProfile(selected)
    }

    package func selectMethod(_ method: SpeechRecognitionMethod) async {
        guard method != selectedProfile.method else { return }
        await saveProfile(
            SpeechRecognitionProfile(
                provider: selectedProvider, region: selectedProfile.region, method: method))
    }

    package func selectModel(_ model: String) async {
        await saveProfile(
            SpeechRecognitionProfile(
                provider: selectedProvider, model: model, region: selectedProfile.region,
                method: selectedProfile.method))
    }

    package func selectRegion(_ region: QwenASRRegion) async {
        guard selectedProvider == .qwen else { return }
        await saveProfile(
            SpeechRecognitionProfile(
                provider: .qwen, model: selectedProfile.model, region: region,
                method: selectedProfile.method))
    }

    private func saveProfile(_ profile: SpeechRecognitionProfile) async {
        guard !isMutating, !isShutdown else { return }
        activeOperations += 1
        defer { finishOperation() }
        isUpdatingProvider = true
        generation &+= 1
        let token = generation
        defer { isUpdatingProvider = false }
        do {
            let validated = try profile.validated()
            var updated = providers
            try updated.select(validated)
            _ = try await settingsStore.updateSpeechRecognitionProviders(updated)
            guard token == generation, !isShutdown else { return }
            try await configuration.selectRecognitionProvider(validated)
            guard token == generation, !isShutdown else { return }
            providers = updated
            hasStoredKey = false
            apiKeyDraft = ""
            await readCredential(token: token, profile: validated)
        } catch {
            guard token == generation, !isShutdown else { return }
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Downloads Apple's language model for the selected on-device provider.
    package func installOnDeviceModel() async {
        guard !isMutating, !isShutdown, selectedProvider.isOnDevice, modelInstallProgress == nil
        else { return }
        activeOperations += 1
        defer { finishOperation() }
        generation &+= 1
        let token = generation
        modelInstallProgress = 0
        defer { modelInstallProgress = nil }
        do {
            try await onDevice.installModel { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.modelInstallProgress != nil else { return }
                    self.modelInstallProgress = min(max(fraction, 0), 1)
                }
            }
            guard token == generation, !isShutdown else { return }
            notice = nil
        } catch {
            guard token == generation, !isShutdown else { return }
            notice = SpeakerCopy.Failure.message(for: error)
        }
        let status = await onDevice.modelStatus()
        guard token == generation, !isShutdown else { return }
        onDeviceModelStatus = status
    }

    package func saveAPIKey() async {
        guard !isMutating, !isShutdown, hasValidProfile, selectedProvider != .doubao,
            let credentialID = selectedProfile.credentialProviderID
        else { return }
        activeOperations += 1
        defer { finishOperation() }
        isUpdatingKey = true
        generation &+= 1
        let token = generation
        let draft = apiKeyDraft
        defer { isUpdatingKey = false }
        do {
            try await credentials.save(apiKey: draft, for: credentialID)
            guard token == generation, !isShutdown else { return }
            hasStoredKey = true
            if apiKeyDraft == draft { apiKeyDraft = "" }
            notice = nil
        } catch {
            guard token == generation, !isShutdown else { return }
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func deleteAPIKey() async {
        guard !isMutating, !isShutdown, selectedProvider != .doubao,
            let credentialID = selectedProfile.credentialProviderID
        else { return }
        activeOperations += 1
        defer { finishOperation() }
        isUpdatingKey = true
        generation &+= 1
        let token = generation
        let draft = apiKeyDraft
        defer { isUpdatingKey = false }
        do {
            try await credentials.deleteAPIKey(for: credentialID)
            guard token == generation, !isShutdown else { return }
            hasStoredKey = false
            if apiKeyDraft == draft { apiKeyDraft = "" }
            notice = nil
        } catch {
            guard token == generation, !isShutdown else { return }
            notice = SpeakerCopy.Failure.message(for: error)
        }
    }

    package func discardKeyDraft() { apiKeyDraft = "" }

    package func shutdown() async {
        isShutdown = true
        generation &+= 1
        apiKeyDraft = ""
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    private func finishOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

}
