import AppKit
import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore

@MainActor
final class SpeakerRuntime: ObservableObject {
    let permissions: PermissionModel
    let voiceInput: VoiceInputExperience
    let history: SQLiteSessionHistory
    let doubaoSettings: DoubaoSettingsModel
    let refinementSettings: RefinementSettingsModel
    let dictionarySettings: DictionarySettingsModel
    let historyModel: HistoryModel
    let historyRetention: HistoryRetentionSettingsModel
    let overviewModel: OverviewModel
    let mainWindow = MainWindowModel()
    let loginItemSettings: LoginItemSettingsModel
    let settingsNavigation: SettingsNavigationModel
    let shortcut: VoiceShortcutFeature
    let diagnostics: DiagnosticNoticeModel
    let softwareUpdate: SoftwareUpdateFeature
    let dataErasure: SpeakerDataErasureCoordinator

    private let dependencies: SpeakerRuntimeDependencies
    private let globalInteraction: GlobalVoiceInteractionRouter
    private let providerRuntimeDiagnostics: VoiceProviderRuntimeDiagnostics
    private let dataErasureIntentStore: SpeakerDataErasureIntentStore
    private let panel: VoiceInputPanelController
    private let permissionRefreshCoordinator: PermissionRefreshCoordinator
    private let onboardingPermissionCoordinator: OnboardingPermissionCoordinator
    private let shortcutAnnouncementCoordinator: ShortcutAnnouncementCoordinator
    private let onboarding: OnboardingPresenter
    private let startup: RuntimeStartupSequence
    private let shutdown: RuntimeShutdownCoordinator
    private var started = false
    private var runtimeCancellables = Set<AnyCancellable>()
    #if DEBUG
        private var visualScenarioCancellable: AnyCancellable?
    #endif

    private(set) lazy var settingsWorkspace = SettingsWorkspace(
        navigation: settingsNavigation,
        permissions: permissions,
        shortcut: shortcut,
        loginItemSettings: loginItemSettings,
        historyRetention: historyRetention,
        doubao: doubaoSettings,
        refinement: refinementSettings,
        dictionary: dictionarySettings,
        softwareUpdate: softwareUpdate,
        diagnostics: diagnostics,
        dataErasure: dataErasure,
        requestPermission: { [weak self] permission in
            guard let self else { return }
            await self.requestPermission(permission)
        },
        routeEffects: SettingsRouteEffects(
            openURL: dependencies.workspace.openURL
        ),
        refreshPermissions: { [weak self] in
            self?.refreshPermissions()
        },
        copyDiagnostics: { [weak self] in
            guard let self else { return }
            await self.copyDiagnostics()
        }
    )

    convenience init(termination: SpeakerTerminationCoordinator) {
        self.init(dependencies: .production(termination: termination))
    }

    init(dependencies: SpeakerRuntimeDependencies) {
        self.dependencies = dependencies
        let bundle = dependencies.bundle
        let announce = dependencies.workspace.announce
        LegacyPrivacyStateCleaner.removeObsoleteIdentifiers(
            from: dependencies.preferences
        )
        softwareUpdate = SoftwareUpdateFeature(
            configuration: .init(
                signingMode: bundle.buildInfo.signingMode,
                feedURLString: bundle.feedURLString,
                publicEDKey: bundle.publicEDKey
            ),
            makeDriver: dependencies.makeUpdateDriver
        )
        let dataErasureIntentStore = SpeakerDataErasureIntentStore(
            intentFileURL: dependencies.dataErasureIntentFileURL,
            preferences: dependencies.preferences,
            preferenceDomainNames: [
                bundle.bundleIdentifier,
                SpeakerBundleInfo.fallbackBundleIdentifier,
            ]
        )
        self.dataErasureIntentStore = dataErasureIntentStore
        let permissions = PermissionModel(access: dependencies.permissionAccess)
        self.permissions = permissions
        let targets = AccessibilityInputTargets()
        let history = dependencies.history
        self.history = history
        let providerRuntimeDiagnostics = VoiceProviderRuntimeDiagnostics()
        self.providerRuntimeDiagnostics = providerRuntimeDiagnostics
        let doubao = CredentialedDoubaoTranscriber(
            credentials: dependencies.credentials.store,
            runtimeDiagnostics: providerRuntimeDiagnostics
        )
        let deepSeek = CredentialedDeepSeekTextRefiner(
            credentials: dependencies.credentials.store
        )
        let configuration = VoiceInputConfigurationController()
        let processor = DefaultVoiceTextProcessor(
            configuration: configuration,
            doubao: doubao,
            refinement: OptionalTextRefinementPipeline(refiner: deepSeek)
        )
        let settingsStore = dependencies.settingsStore
        let settingsNavigation = SettingsNavigationModel()
        self.settingsNavigation = settingsNavigation
        let diagnostics = DiagnosticNoticeModel()
        self.diagnostics = diagnostics
        let sessionActor = VoiceInputSessions(
            audioCapture: dependencies.audioCapture,
            targetCapture: targets,
            textProcessor: processor,
            delivery: targets,
            clipboard: SystemClipboardWriter(),
            history: history
        )
        let voiceInput = VoiceInputExperience(
            sessions: sessionActor,
            releaseCaptureHint: {
                targets.releaseCaptureHint()
            },
            announce: announce
        )
        self.voiceInput = voiceInput
        let globalInteraction = GlobalVoiceInteractionRouter(
            voiceTarget: voiceInput.shortcutTarget
        )
        self.globalInteraction = globalInteraction
        let doubaoSettings = DoubaoSettingsModel(
            service: doubao,
            settingsStore: settingsStore
        )
        self.doubaoSettings = doubaoSettings
        let refinementSettings = RefinementSettingsModel(
            service: deepSeek,
            configuration: configuration,
            settingsStore: settingsStore
        )
        self.refinementSettings = refinementSettings
        let dictionarySettings = DictionarySettingsModel(
            store: dependencies.dictionaryStore,
            configuration: configuration
        )
        self.dictionarySettings = dictionarySettings
        historyRetention = HistoryRetentionSettingsModel(
            store: history,
            settingsStore: settingsStore
        )
        let historyModel = HistoryModel(
            store: history,
            clipboard: SystemClipboardWriter(),
            dictionary: dictionarySettings,
            announce: announce
        )
        self.historyModel = historyModel
        overviewModel = OverviewModel(store: history)
        let loginItemSettings = LoginItemSettingsModel(
            service: dependencies.loginItemService,
            settingsStore: settingsStore
        )
        self.loginItemSettings = loginItemSettings
        let shortcut = VoiceShortcutFeature(
            target: globalInteraction.shortcutTarget,
            accessibilityGranted: { [weak permissions] in
                permissions?.snapshot.accessibility == .granted
            },
            persistPreference: { choice in
                _ = try await settingsStore.updateShortcut(choice)
            }
        )
        self.shortcut = shortcut
        let permissionRefreshCoordinator = PermissionRefreshCoordinator(
            permissions: permissions,
            shortcut: shortcut
        )
        self.permissionRefreshCoordinator = permissionRefreshCoordinator
        let onboardingPermissionCoordinator = OnboardingPermissionCoordinator(
            permissions: permissions,
            synchronize: { [permissionRefreshCoordinator] in
                permissionRefreshCoordinator.refreshNow()
            }
        )
        self.onboardingPermissionCoordinator = onboardingPermissionCoordinator
        shortcutAnnouncementCoordinator = ShortcutAnnouncementCoordinator(
            feature: shortcut,
            announce: announce
        )
        let panel = VoiceInputPanelController(
            experience: voiceInput,
            routeEffect: { effect in
                switch effect {
                case .openSpeechSettings:
                    settingsNavigation.open(.apiKeys)
                }
            }
        )
        self.panel = panel
        let onboarding = OnboardingPresenter(
            preferences: dependencies.preferences,
            makeController: { completion in
                SpeakerOnboardingWindowController(
                    permissions: permissions,
                    doubao: doubaoSettings,
                    requestPermission: { permission in
                        await onboardingPermissionCoordinator.request(permission)
                    },
                    refreshPermissions: {
                        permissionRefreshCoordinator.refreshNow()
                    },
                    announce: announce,
                    completion: completion
                )
            }
        )
        self.onboarding = onboarding
        let startup = RuntimeStartupSequence(
            stages: SpeakerRuntimeStartupStages(
                settingsStore: settingsStore,
                doubao: doubaoSettings,
                migratingCredentials: dependencies.credentials.migrating,
                dictionaryFileURL: dependencies.dictionaryStore.fileURL,
                legacyDictionaryFileURL: dependencies.legacyDictionaryFileURL,
                dictionary: dictionarySettings,
                refinement: refinementSettings,
                history: history,
                legacyHistoryFileURL: dependencies.legacyHistoryFileURL,
                historyModel: historyModel,
                loginItem: loginItemSettings,
                shortcut: shortcut,
                onboarding: onboarding,
                launchArguments: dependencies.launchArguments
            ),
            publish: { [diagnostics] notice in diagnostics.publish(notice) }
        )
        self.startup = startup
        let shutdown = RuntimeShutdownCoordinator(
            stages: SpeakerRuntimeShutdownStages(
                shortcut: shortcut,
                permissionRefresh: permissionRefreshCoordinator,
                startup: startup,
                onboarding: onboarding,
                panel: panel,
                refinement: refinementSettings,
                doubao: doubaoSettings,
                voiceInput: voiceInput
            )
        )
        self.shutdown = shutdown
        dataErasure = SpeakerDataErasureCoordinator(
            dependencies: Self.makeDataErasureDependencies(
                intentStore: dataErasureIntentStore,
                shutdown: shutdown,
                history: history,
                credentialEraser: dependencies.credentialEraser,
                localDataEraser: dependencies.localDataEraser,
                termination: dependencies.termination,
                terminate: dependencies.workspace.terminate
            )
        )
    }

    private static func makeDataErasureDependencies(
        intentStore: SpeakerDataErasureIntentStore,
        shutdown: RuntimeShutdownCoordinator,
        history: SQLiteSessionHistory,
        credentialEraser: SpeakerProviderCredentialEraser,
        localDataEraser: SpeakerOwnedLocalDataEraser,
        termination: SpeakerTerminationCoordinator,
        terminate: @escaping @MainActor () -> Void
    ) -> SpeakerDataErasureDependencies {
        SpeakerDataErasureDependencies(
            persistIntent: { try intentStore.persist() },
            quiesceRuntime: { await shutdown.converge() },
            eraseLoginItem: { try await SpeakerLoginItemEraser.erase() },
            eraseProviderCredentials: { try await credentialEraser.erase() },
            closeHistory: {
                guard await history.closeForErasure() else {
                    throw SpeakerDataErasureReason.busy
                }
            },
            eraseApplicationSupport: { try localDataEraser.eraseApplicationSupport() },
            eraseLegacyData: { try localDataEraser.eraseLegacyData() },
            eraseCaches: { try localDataEraser.eraseCaches() },
            erasePreferences: { try intentStore.erasePreferences() },
            verifyErasure: {
                try SpeakerLoginItemEraser.verify()
                try await credentialEraser.verify()
                try localDataEraser.verify()
            },
            clearIntent: { try intentStore.clearIntent() },
            requestExit: {
                termination.handler = nil
                terminate()
            }
        )
    }

    func start() {
        guard !started else { return }
        started = true
        if let request = DeliverySmokeRunner.request(
            arguments: dependencies.launchArguments
        ) {
            Task { @MainActor in
                await DeliverySmokeRunner.run(request)
            }
            return
        }
        if dataErasureIntentStore.isPending {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.dataErasure.eraseAllAndExit()
                if case .incomplete(let failure) = outcome {
                    self.mainWindow.select(.about)
                    self.diagnostics.publish(
                        SpeakerCopy.LocalDataErase.failureMessage(failure)
                    )
                }
            }
            return
        }
        #if DEBUG
            if let scenario = SpeakerDebugLaunchOptions.visualScenario(
                in: dependencies.launchArguments
            ) {
                NSLog(
                    "Speaker visual scenario requested: \(scenario.rawValue), "
                        + "appRunning=\(NSApp.isRunning)"
                )
                panel.start()
                if NSApp.isRunning {
                    voiceInput.presentVisualScenario(scenario)
                    captureVisualScenarioIfRequested()
                } else {
                    visualScenarioCancellable = NotificationCenter.default
                        .publisher(
                            for: NSApplication.didFinishLaunchingNotification
                        )
                        .prefix(1)
                        .sink { [weak self] _ in
                            NSLog("Speaker visual scenario received didFinishLaunching")
                            self?.voiceInput.presentVisualScenario(scenario)
                            self?.captureVisualScenarioIfRequested()
                            self?.visualScenarioCancellable = nil
                        }
                }
                return
            }
        #endif
        permissions.refresh()
        softwareUpdate.start()
        let activations = dependencies.workspace.applicationActivations
        permissionRefreshCoordinator.start(observing: activations)
        activations
            .sink { [weak loginItemSettings] _ in
                Task { @MainActor [weak loginItemSettings] in
                    await loginItemSettings?.refresh()
                }
            }
            .store(in: &runtimeCancellables)
        voiceInput.start()
        panel.start()
        dependencies.termination.handler = { [shutdown] in
            await shutdown.converge()
        }
        startup.start()
    }

    func refreshPermissions() {
        permissionRefreshCoordinator.refreshNow()
    }

    func requestPermission(_ permission: PermissionKind) async {
        _ = await permissions.request(permission)
        permissionRefreshCoordinator.refreshNow()
    }

    func copyDiagnostics() async {
        let historyStatus = await history.persistenceStatus()
        let latestRecord = await history.latestRecord()
        let activeProvider =
            await providerRuntimeDiagnostics.activeSnapshot()
        let audioCaptureEnvironment =
            await dependencies.audioCapture.captureEnvironmentSnapshot()
        let bundle = dependencies.bundle
        let buildIdentity = bundle.buildInfo.buildIdentity
        let activity = voiceInput.state.diagnosticCode
        let historyNotice: String =
            switch historyStatus.notice {
            case nil: "none"
            case .corruptedDataPreserved: "corruptedDataPreserved"
            case .corruptedRecordsSkipped: "corruptedRecordsSkipped"
            case .privacyMigrationFailed: "privacyMigrationFailed"
            case .writeFailed: "writeFailed"
            case .recoveryArchivePruneFailed: "recoveryArchivePruneFailed"
            }
        let report = SpeakerDiagnosticReport.make(
            from: .init(
                version: buildIdentity.version,
                build: buildIdentity.build,
                sourceRevision: buildIdentity.sourceRevision,
                bundleIdentifier: bundle.bundleIdentifier,
                signingMode: bundle.buildInfo.signingMode.diagnosticValue,
                operatingSystem: dependencies.operatingSystemVersion,
                credentialStorage: bundle.credentialStorage ?? "unknown",
                accessibility: permissions.snapshot.accessibility,
                microphone: permissions.snapshot.microphone,
                shortcut: shortcut.preference.displayName,
                activity: activity,
                refinement: refinementSettings.mode.diagnosticKind,
                doubaoConfigured: doubaoSettings.hasConfiguredKey,
                doubaoResource: doubaoSettings.resource.rawValue,
                deepSeekConfigured: refinementSettings.hasStoredKey,
                deepSeekVerified: refinementSettings.isConnectionVerified,
                historyRecordCount: historyStatus.recordCount,
                historyPersistence: historyNotice,
                audioCaptureEnvironment: audioCaptureEnvironment,
                activeProvider: activeProvider,
                latestRecord: latestRecord
            ))
        let copied = await SystemClipboardWriter().copy(report)
        diagnostics.publish(
            copied
                ? SpeakerCopy.Diagnostics.copied
                : SpeakerCopy.Diagnostics.copyFailed
        )
    }

    #if DEBUG
        private func captureVisualScenarioIfRequested() {
            guard
                let url = SpeakerDebugLaunchOptions.visualCaptureURL(
                    in: dependencies.launchArguments
                )
            else {
                return
            }
            Task { @MainActor [weak self] in
                await Task.yield()
                do {
                    try self?.panel.captureDebugSnapshot(to: url)
                    NSLog("Speaker visual scenario captured: \(url.path)")
                } catch {
                    NSLog("Speaker visual scenario capture failed: \(error)")
                }
            }
        }
    #endif
}
