import AppKit
import Foundation
import SpeakerAppFeatures
import SpeakerCore

/// Owns the onboarding window and the preference that records its completion.
@MainActor
final class OnboardingPresenter {
    static let completionKey = "hasCompletedOnboarding"

    private let preferences: UserDefaults
    private let makeController:
        @MainActor (_ completion: @escaping () -> Void) -> SpeakerOnboardingWindowController
    private var controller: SpeakerOnboardingWindowController?

    init(
        preferences: UserDefaults,
        makeController: @escaping @MainActor (
            _ completion: @escaping () -> Void
        ) -> SpeakerOnboardingWindowController
    ) {
        self.preferences = preferences
        self.makeController = makeController
    }

    var isPresented: Bool { controller != nil }

    func present(force: Bool) {
        guard force || !preferences.bool(forKey: Self.completionKey) else {
            return
        }
        let controller = makeController { [weak self] in self?.complete() }
        self.controller = controller
        controller.show()
    }

    func complete() {
        preferences.set(true, forKey: Self.completionKey)
        close()
    }

    func close() {
        controller?.close()
        controller = nil
    }

#if DEBUG
    func resizeDebug(to size: CGSize) {
        controller?.resizeDebug(to: size)
    }

    func captureDebugSnapshot(to url: URL) throws {
        try controller?.captureDebugSnapshot(to: url)
    }
#endif
}

/// The production startup stages: each one forwards to the collaborator that
/// owns the work and reports a structured outcome for the sequence to phrase.
@MainActor
final class SpeakerRuntimeStartupStages: RuntimeStartupStages {
    private let settingsStore: VersionedLocalAppSettingsStore
    private let doubao: DoubaoSettingsModel
    private let migratingCredentials: MigratingProviderCredentialStore?
    private let dictionaryFileURL: URL
    private let legacyDictionaryFileURL: URL?
    private let dictionary: DictionarySettingsModel
    private let refinement: RefinementSettingsModel
    private let history: SQLiteSessionHistory
    private let legacyHistoryFileURL: URL
    private let historyModel: HistoryModel
    private let loginItem: LoginItemSettingsModel
    private let shortcut: VoiceShortcutFeature
    private let onboarding: OnboardingPresenter
    private let launchArguments: [String]

    init(
        settingsStore: VersionedLocalAppSettingsStore,
        doubao: DoubaoSettingsModel,
        migratingCredentials: MigratingProviderCredentialStore?,
        dictionaryFileURL: URL,
        legacyDictionaryFileURL: URL?,
        dictionary: DictionarySettingsModel,
        refinement: RefinementSettingsModel,
        history: SQLiteSessionHistory,
        legacyHistoryFileURL: URL,
        historyModel: HistoryModel,
        loginItem: LoginItemSettingsModel,
        shortcut: VoiceShortcutFeature,
        onboarding: OnboardingPresenter,
        launchArguments: [String]
    ) {
        self.settingsStore = settingsStore
        self.doubao = doubao
        self.migratingCredentials = migratingCredentials
        self.dictionaryFileURL = dictionaryFileURL
        self.legacyDictionaryFileURL = legacyDictionaryFileURL
        self.dictionary = dictionary
        self.refinement = refinement
        self.history = history
        self.legacyHistoryFileURL = legacyHistoryFileURL
        self.historyModel = historyModel
        self.loginItem = loginItem
        self.shortcut = shortcut
        self.onboarding = onboarding
        self.launchArguments = launchArguments
    }

    func loadSettings() async -> AppSettingsLoadResult {
        await settingsStore.load()
    }

    func loadDoubaoResource(rawValue: String?) async {
        await doubao.loadResource(rawValue: rawValue)
    }

    func migrateCredentials() async -> [ProviderID] {
        guard let migratingCredentials else { return [] }
        await migratingCredentials.migrateAllProviders()
        return await migratingCredentials.unmigratedProviders()
    }

    func migrateLegacyDictionary() async -> PersonalDictionaryMigrationOutcome? {
        guard let legacyDictionaryFileURL else { return nil }
        return await VersionedJSONPersonalDictionaryStore.migrateLegacyFileIfNeeded(
            from: legacyDictionaryFileURL,
            to: dictionaryFileURL
        )
    }

    func loadDictionary() async -> String? {
        await dictionary.load()
        return dictionary.recovery.map(DictionarySettingsModel.recoveryNotice(for:))
    }

    func loadRefinement() async {
        await refinement.load()
    }

    func scrubHistoryProviderMessages() async -> Bool {
        await history.scrubUntrustedProviderMessages()
    }

    func migrateLegacyHistory() async -> LegacyHistoryMigrationOutcome {
        guard FileManager.default.fileExists(atPath: legacyHistoryFileURL.path) else {
            return .notNeeded
        }
        let legacy = VersionedLocalSessionHistory(fileURL: legacyHistoryFileURL)
        if let notice = await legacy.persistenceStatus().notice {
            switch notice {
            case let .corruptedDataPreserved(backupURL, _):
                return .legacyCorrupted(backupName: backupURL.lastPathComponent)
            case .privacyMigrationFailed:
                return .legacyProtectionFailed
            case .corruptedRecordsSkipped, .writeFailed:
                return .legacyNotReady
            case .recoveryArchivePruneFailed:
                // Old evidence that refused to delete says nothing about the
                // legacy records, which loaded normally; migration continues.
                break
            }
        }
        let records = await legacy.allRecords()
        guard await history.importLegacyRecords(records) else {
            return .importRefused
        }
        do {
            try FileManager.default.removeItem(at: legacyHistoryFileURL)
        } catch {
            return .migratedLegacyFileRemains
        }
        return .migrated
    }

    func reconcileInterruptedSessions() async -> Bool {
        await history.reconcileInterruptedSessions() != nil
    }

    func applyHistoryRetention(_ policy: HistoryRetentionPolicy) async {
        _ = await history.applyRetentionPolicy(policy, now: Date())
    }

    func refreshHistory() async {
        await historyModel.refresh()
    }

    func restoreLoginItem(desiredEnabled: Bool) async {
        await loginItem.restore(desiredEnabled: desiredEnabled)
    }

    func restoreShortcut(_ preference: VoiceShortcutPreference) {
        shortcut.restore(preference)
    }

    func presentOnboarding() {
#if DEBUG
        if let captureURL = SpeakerDebugLaunchOptions.onboardingCaptureURL(
            in: launchArguments
        ) {
            onboarding.present(force: true)
            if let size = SpeakerDebugLaunchOptions.onboardingCaptureSize(
                in: launchArguments
            ) {
                onboarding.resizeDebug(to: size)
            }
            Task { @MainActor [onboarding] in
                await Task.yield()
                do {
                    try onboarding.captureDebugSnapshot(to: captureURL)
                    NSLog("Speaker onboarding captured: \(captureURL.path)")
                } catch {
                    NSLog("Speaker onboarding capture failed: \(error)")
                }
            }
            return
        }
#endif
        onboarding.present(force: false)
    }
}

/// The production shutdown stages, forwarded to the collaborators in the
/// order `RuntimeShutdownCoordinator` requires.
@MainActor
final class SpeakerRuntimeShutdownStages: RuntimeShutdownStages {
    private let shortcut: VoiceShortcutFeature
    private let permissionRefresh: PermissionRefreshCoordinator
    private let startup: RuntimeStartupSequence
    private let onboarding: OnboardingPresenter
    private let panel: VoiceInputPanelController
    private let refinement: RefinementSettingsModel
    private let doubao: DoubaoSettingsModel
    private let voiceInput: VoiceInputExperience

    init(
        shortcut: VoiceShortcutFeature,
        permissionRefresh: PermissionRefreshCoordinator,
        startup: RuntimeStartupSequence,
        onboarding: OnboardingPresenter,
        panel: VoiceInputPanelController,
        refinement: RefinementSettingsModel,
        doubao: DoubaoSettingsModel,
        voiceInput: VoiceInputExperience
    ) {
        self.shortcut = shortcut
        self.permissionRefresh = permissionRefresh
        self.startup = startup
        self.onboarding = onboarding
        self.panel = panel
        self.refinement = refinement
        self.doubao = doubao
        self.voiceInput = voiceInput
    }

    func stopTrigger() { shortcut.beginShutdown() }
    func stopPermissionRefresh() { permissionRefresh.stop() }
    func cancelStartup() { startup.cancel() }
    func closeOnboarding() { onboarding.close() }
    func closePanel() { panel.stop() }
    func shutdownRefinement() async { await refinement.shutdown() }
    func shutdownDoubao() async { await doubao.shutdown() }
    func shutdownVoiceInput() async { await voiceInput.shutdown() }
    func awaitStartup() async { await startup.waitUntilFinished() }
    func flushPersistence() async { await shortcut.flushPersistence() }
}

#if DEBUG
/// Debug-only launch options used by screenshot automation.
enum SpeakerDebugLaunchOptions {
    static func value(after option: String, in arguments: [String]) -> String? {
        guard let optionIndex = arguments.firstIndex(of: option),
              arguments.indices.contains(optionIndex + 1)
        else {
            return nil
        }
        return arguments[optionIndex + 1]
    }

    static func onboardingCaptureURL(in arguments: [String]) -> URL? {
        value(after: "--speaker-onboarding-capture", in: arguments)
            .map { URL(fileURLWithPath: $0) }
    }

    static func onboardingCaptureSize(in arguments: [String]) -> CGSize? {
        guard let raw = value(after: "--speaker-onboarding-size", in: arguments) else {
            return nil
        }
        let components = raw.split(separator: "x")
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width >= 360,
              height >= 360
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func visualScenario(in arguments: [String]) -> VoiceInputVisualScenario? {
        value(after: "--speaker-visual-scenario", in: arguments)
            .flatMap(VoiceInputVisualScenario.init(rawValue:))
    }

    static func visualCaptureURL(in arguments: [String]) -> URL? {
        value(after: "--speaker-visual-capture", in: arguments)
            .map { URL(fileURLWithPath: $0) }
    }
}
#endif
