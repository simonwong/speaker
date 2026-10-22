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

/// The parts of Doubao recognition that Settings drives besides its Key: the
/// streaming resource the next session uses, and an explicit connection check.
package protocol DoubaoRecognitionServicing: Sendable {
    func setResource(_ resource: DoubaoStreamingResource) async
    func checkConnection() async throws -> String?
}

extension CredentialedDoubaoTranscriber: DoubaoRecognitionServicing {}

@MainActor
package final class SpeechRecognitionSettingsModel: ObservableObject {
    @Published package private(set) var providers = SpeechRecognitionProviderSettings()
    /// Whether the selected profile and its credential have been read once,
    /// so `hasStoredKey == false` means a missing Key rather than "unread".
    @Published package private(set) var hasLoaded = false
    @Published package private(set) var isUpdatingProvider = false
    /// The on-device language model's state; nil until read, or while a cloud
    /// provider is selected.
    @Published package private(set) var onDeviceModelStatus: OnDeviceSpeechModelStatus?
    /// Download progress from 0 to 1 while the on-device model installs.
    @Published package private(set) var modelInstallProgress: Double?
    /// The Doubao streaming resource the next Doubao session uses.
    @Published package private(set) var doubaoResource: DoubaoStreamingResource = .default
    @Published private var profileNotice: String?
    @Published private var doubaoResourceFailure: String?

    private let credentials: any ProviderCredentialStoring
    private let configuration: VoiceInputConfigurationController
    private let settingsStore: any AppSettingsStoring
    private let onDevice: any OnDeviceSpeechRecognizing
    private let doubao: any DoubaoRecognitionServicing
    /// The selected profile's Key. It is retargeted whenever the selected
    /// profile changes, so it always edits that profile's credential namespace.
    private let credential: ProviderCredentialEditor
    private var credentialChanges: AnyCancellable?
    /// Apple's on-device recognition needs macOS 26; earlier releases never list it.
    package let isOnDeviceSupported: Bool
    private var generation: UInt64 = 0
    private var isShutdown = false
    private var activeOperations = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    /// Production passes the Doubao transcriber the Voice Input Session uses,
    /// so a resource chosen here reaches the next session.
    package init(
        credentials: any ProviderCredentialStoring,
        configuration: VoiceInputConfigurationController,
        settingsStore: any AppSettingsStoring,
        onDevice: any OnDeviceSpeechRecognizing = AppleSpeechRecognizer(),
        isOnDeviceSupported: Bool = AppleSpeechRecognizer.isSupported,
        doubao: (any DoubaoRecognitionServicing)? = nil
    ) {
        self.credentials = credentials
        self.configuration = configuration
        self.settingsStore = settingsStore
        self.onDevice = onDevice
        self.isOnDeviceSupported = isOnDeviceSupported
        self.doubao = doubao ?? CredentialedDoubaoTranscriber(credentials: credentials)
        credential = ProviderCredentialEditor(
            namespace: Self.credentialNamespace(
                for: SpeechRecognitionProviderSettings().selectedProfile, in: credentials))
        credentialChanges = credential.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// The provider choices in display order: the on-device option, which needs
    /// no Key, comes first where this Mac can run it and is absent otherwise.
    package var availableProviders: [SpeechRecognitionProviderID] {
        let onDevice = SpeechRecognitionProviderID.allCases.filter(\.isOnDevice)
        let cloud = SpeechRecognitionProviderID.allCases.filter { !$0.isOnDevice }
        return (isOnDeviceSupported ? onDevice : []) + cloud
    }

    /// The one readiness rule for the selected provider: a valid profile, then
    /// a saved Key for a cloud provider or an installed language model for
    /// on-device recognition, then a successful connection check where the
    /// provider offers one.
    package var readiness: SpeechRecognitionReadiness {
        guard hasLoaded else { return .unread }
        if selectedProvider.isOnDevice {
            guard let onDeviceModelStatus else { return .unread }
            return hasValidProfile && onDeviceModelStatus == .installed ? .ready : .needsSetup
        }
        guard hasValidProfile, hasStoredKey else { return .needsSetup }
        guard offersConnectionCheck else { return .ready }
        if case .verified = credential.connection { return .ready }
        return .unverified
    }

    /// Doubao is the one Speech Recognition Provider whose Key Settings checks
    /// explicitly, because the Key works only with an activated resource.
    package var offersConnectionCheck: Bool { selectedProvider == .doubao }

    package var selectedProvider: SpeechRecognitionProviderID { providers.selectedProvider }
    package var selectedProfile: SpeechRecognitionProfile { providers.selectedProfile }
    package var providerName: String { selectedProvider.displayName }
    package var hasStoredKey: Bool { credential.hasStoredKey }
    package var isUpdatingKey: Bool { credential.isUpdating }
    package var apiKeyDraft: String {
        get { credential.draft }
        set { credential.draft = newValue }
    }
    /// The latest profile, language-model, or Key problem.
    package var notice: String? { credential.failure ?? profileNotice }
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

    /// Doubao's Key and connection state as its status line shows it.
    package var doubaoStatus: DoubaoConnectionStatus {
        guard hasLoaded else { return .loading }
        switch credential.connection {
        case .checking: return .checking
        case .verified(let requestID): return .success(requestID)
        case .failed(let message): return .failure(message)
        case .unchecked: break
        }
        if let message = doubaoResourceFailure ?? credential.failure {
            return .failure(message)
        }
        return hasStoredKey ? .configured : .unconfigured
    }

    /// A failed connection check or resource change, shown under the Doubao
    /// rows; Key problems appear in `notice`.
    package var doubaoProblem: String? {
        if case .failed(let message) = credential.connection { return message }
        return doubaoResourceFailure
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
        credential.retarget(
            to: Self.credentialNamespace(for: loaded.selectedProfile, in: credentials))
        await configuration.restoreRecognitionProvider(loaded.selectedProfile)
        guard token == generation, !isShutdown else { return }
        do {
            _ = try loaded.validated()
        } catch {
            guard token == generation, !isShutdown else { return }
            profileNotice = SpeakerCopy.Failure.message(for: error)
            hasLoaded = true
            return
        }
        await readSetup(token: token)
        guard token == generation, !isShutdown else { return }
        hasLoaded = true
    }

    package func refresh() async {
        guard !isMutating, !isShutdown else { return }
        activeOperations += 1
        defer { finishOperation() }
        generation &+= 1
        await readSetup(token: generation)
    }

    /// Reads what the selected profile needs: its language model on the Mac,
    /// or its Key.
    private func readSetup(token: UInt64) async {
        let profile = selectedProfile
        guard profile.credentialProviderID != nil else {
            let status = await onDevice.modelStatus()
            guard token == generation, !isShutdown else { return }
            onDeviceModelStatus = status
            profileNotice = nil
            return
        }
        onDeviceModelStatus = nil
        do {
            _ = try profile.validated()
        } catch {
            guard token == generation, !isShutdown else { return }
            profileNotice = SpeakerCopy.Failure.message(for: error)
            return
        }
        await credential.refresh()
        guard token == generation, !isShutdown else { return }
        profileNotice = nil
    }

    /// A valid cloud profile's credential namespace; nil for on-device
    /// recognition and for a profile Speaker cannot run.
    private static func credentialNamespace(
        for profile: SpeechRecognitionProfile,
        in credentials: any ProviderCredentialStoring
    ) -> ProviderCredentialNamespace? {
        guard (try? profile.validated()) != nil, let id = profile.credentialProviderID else {
            return nil
        }
        return .stored(in: credentials, for: id)
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
            credential.retarget(to: Self.credentialNamespace(for: validated, in: credentials))
            await readSetup(token: token)
        } catch {
            guard token == generation, !isShutdown else { return }
            profileNotice = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Applies the Doubao resource saved in settings at launch.
    package func loadDoubaoResource(rawValue: String?) async {
        guard !isShutdown else { return }
        let selected = rawValue.flatMap(DoubaoStreamingResource.init(rawValue:)) ?? .default
        credential.invalidateConnection()
        doubaoResource = selected
        await doubao.setResource(selected)
    }

    /// A new resource takes effect for the next session and needs its own
    /// connection check.
    package func selectDoubaoResource(_ selected: DoubaoStreamingResource) async {
        guard !isMutating, !isShutdown else { return }
        activeOperations += 1
        defer { finishOperation() }
        credential.invalidateConnection()
        doubaoResource = selected
        doubaoResourceFailure = nil
        await doubao.setResource(selected)
        do {
            try await settingsStore.updateDoubaoResource(selected)
        } catch {
            guard doubaoResource == selected, !isShutdown else { return }
            doubaoResourceFailure = SpeakerCopy.Failure.message(for: error)
        }
    }

    /// Checks the saved Doubao Key against the selected resource with a short
    /// silent request. A result that arrives after the Key or resource changed
    /// is discarded.
    package func checkConnection() {
        guard offersConnectionCheck, !isMutating, !isShutdown else { return }
        let doubao = doubao
        let resource = doubaoResource
        credential.checkConnection(
            { try await doubao.checkConnection() },
            describeFailure: { error in
                if let failure = error as? DoubaoASRFailure {
                    DoubaoResourcePresentation.connectionFailure(failure, resource: resource)
                } else {
                    SpeakerCopy.Failure.message(for: error)
                }
            })
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
            profileNotice = nil
        } catch {
            guard token == generation, !isShutdown else { return }
            profileNotice = SpeakerCopy.Failure.message(for: error)
        }
        let status = await onDevice.modelStatus()
        guard token == generation, !isShutdown else { return }
        onDeviceModelStatus = status
    }

    package func saveAPIKey() async {
        guard !isMutating, !isShutdown, hasValidProfile else { return }
        if await credential.save() { profileNotice = nil }
    }

    package func deleteAPIKey() async {
        guard !isMutating, !isShutdown else { return }
        if await credential.delete() { profileNotice = nil }
    }

    package func discardKeyDraft() { credential.discardDraft() }

    package func shutdown() async {
        isShutdown = true
        generation &+= 1
        await credential.shutdown()
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
