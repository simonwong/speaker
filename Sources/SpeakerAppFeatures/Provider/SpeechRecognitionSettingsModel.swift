import Combine
import Foundation
import SpeakerCore

extension SpeechRecognitionProviderID {
    package var displayName: String {
        switch self {
        case .doubao: "豆包语音"
        case .openAI: "OpenAI 语音识别"
        case .qwen: "阿里千问语音识别"
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

@MainActor
package final class SpeechRecognitionSettingsModel: ObservableObject {
    @Published package private(set) var providers = SpeechRecognitionProviderSettings()
    @Published package private(set) var hasStoredKey = false
    @Published package private(set) var isUpdatingProvider = false
    @Published package private(set) var isUpdatingKey = false
    @Published package private(set) var notice: String?
    @Published package var apiKeyDraft = ""

    private let credentials: any ProviderCredentialStoring
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: any AppSettingsStoring
    private var generation: UInt64 = 0
    private var isShutdown = false
    private var activeOperations = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    package init(
        credentials: any ProviderCredentialStoring,
        configuration: VoiceInputConfigurationController,
        settingsStore: any AppSettingsStoring
    ) {
        self.credentials = credentials
        self.configuration = configuration
        self.settingsStore = settingsStore
    }

    package var selectedProvider: SpeechRecognitionProviderID { providers.selectedProvider }
    package var selectedProfile: SpeechRecognitionProfile { providers.selectedProfile }
    package var providerName: String { selectedProvider.displayName }
    package var isMutating: Bool { isUpdatingKey || isUpdatingProvider }
    package var hasValidProfile: Bool { (try? selectedProfile.validated()) != nil }
    package var modelIDs: [String] {
        let listed = SpeechRecognitionProviderCatalog.modelIDs(for: selectedProvider)
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
        guard token == generation, !isShutdown else { return }
        providers = loaded
        await configuration.restoreRecognitionProvider(loaded.selectedProfile)
        guard token == generation, !isShutdown else { return }
        do {
            _ = try loaded.validated()
        } catch {
            guard token == generation, !isShutdown else { return }
            notice = SpeakerCopy.Failure.message(for: error)
            return
        }
        await readCredential(token: token, profile: selectedProfile)
    }

    package func refresh() async {
        guard !isMutating, !isShutdown else { return }
        activeOperations += 1
        defer { finishOperation() }
        generation &+= 1
        await readCredential(token: generation, profile: selectedProfile)
    }

    private func readCredential(token: UInt64, profile: SpeechRecognitionProfile) async {
        do {
            _ = try profile.validated()
            let value = try await credentials.apiKey(for: profile.credentialProviderID)
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
            ?? SpeechRecognitionProfile(provider: provider, region: retained.region)
        await saveProfile(selected)
    }

    package func selectModel(_ model: String) async {
        await saveProfile(
            SpeechRecognitionProfile(
                provider: selectedProvider, model: model, region: selectedProfile.region))
    }

    package func selectRegion(_ region: QwenASRRegion) async {
        guard selectedProvider == .qwen else { return }
        await saveProfile(
            SpeechRecognitionProfile(provider: .qwen, model: selectedProfile.model, region: region))
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

    package func saveAPIKey() async {
        guard !isMutating, !isShutdown, hasValidProfile, selectedProvider != .doubao else { return }
        activeOperations += 1
        defer { finishOperation() }
        isUpdatingKey = true
        generation &+= 1
        let token = generation
        let profile = selectedProfile
        let draft = apiKeyDraft
        defer { isUpdatingKey = false }
        do {
            try await credentials.save(apiKey: draft, for: profile.credentialProviderID)
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
        guard !isMutating, !isShutdown, selectedProvider != .doubao else { return }
        activeOperations += 1
        defer { finishOperation() }
        isUpdatingKey = true
        generation &+= 1
        let token = generation
        let profile = selectedProfile
        let draft = apiKeyDraft
        defer { isUpdatingKey = false }
        do {
            try await credentials.deleteAPIKey(for: profile.credentialProviderID)
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
