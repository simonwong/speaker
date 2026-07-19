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
    let overviewModel: OverviewModel
    let mainWindow = MainWindowModel()
    let loginItemSettings: LoginItemSettingsModel
    let settingsNavigation: SettingsNavigationModel
    let shortcut: VoiceShortcutFeature
    let diagnostics: DiagnosticNoticeModel
    let softwareUpdate: SoftwareUpdateFeature
    private let globalInteraction: GlobalVoiceInteractionRouter
    private let providerRuntimeDiagnostics:
        VoiceProviderRuntimeDiagnostics

    private(set) lazy var settingsWorkspace = SettingsWorkspace(
        navigation: settingsNavigation,
        permissions: permissions,
        shortcut: shortcut,
        loginItemSettings: loginItemSettings,
        history: historyModel,
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
        refreshPermissions: { [weak self] in
            self?.refreshPermissions()
        },
        copyDiagnostics: { [weak self] in
            guard let self else { return }
            await self.copyDiagnostics()
        }
    )

    private let settingsStore: VersionedLocalAppSettingsStore
    private let legacyHistoryFileURL: URL
    private let dictionaryFileURL: URL
    private let legacyDictionaryFileURL: URL?
    private let migratingCredentials: MigratingProviderCredentialStore?
    private let currentKeychainService: String
    private let dataErasureIntentStore: SpeakerDataErasureIntentStore
    private let panel: VoiceInputPanelController
    private let permissionRefreshCoordinator: PermissionRefreshCoordinator
    private var started = false
    private var childStateCancellables = Set<AnyCancellable>()
    private let shortcutAnnouncementCoordinator: ShortcutAnnouncementCoordinator
    private var onboardingController: SpeakerOnboardingWindowController?
    private var startupTask: Task<Void, Never>?
    private var isQuiescingForErasure = false
#if DEBUG
    private var visualScenarioCancellable: AnyCancellable?
#endif

    private lazy var credentialEraser = SpeakerProviderCredentialEraser(
        localFileURL: LocalFileProviderCredentialStore.defaultFileURL(),
        currentKeychainService: currentKeychainService
    )
    private lazy var localDataEraser = SpeakerOwnedLocalDataEraser(
        locations: SpeakerOwnedDataLocations.current(
            bundleIdentifier: Bundle.main.bundleIdentifier
                ?? "com.local.speaker"
        ),
        allowedLibraryRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true),
        fileManager: .default
    )
    private(set) var dataErasure: SpeakerDataErasureCoordinator!

    private func makeDataErasureCoordinator() -> SpeakerDataErasureCoordinator {
        SpeakerDataErasureCoordinator(
            dependencies: SpeakerDataErasureDependencies(
            persistIntent: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try self.dataErasureIntentStore.persist()
            },
            quiesceRuntime: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                await self.quiesceForDataErasure()
            },
            eraseLoginItem: {
                try await SpeakerLoginItemEraser.erase()
            },
            eraseProviderCredentials: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try await self.credentialEraser.erase()
            },
            closeHistory: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                guard await self.history.closeForErasure() else {
                    throw SpeakerDataErasureReason.busy
                }
            },
            eraseApplicationSupport: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try self.localDataEraser.eraseApplicationSupport()
            },
            eraseLegacyData: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try self.localDataEraser.eraseLegacyData()
            },
            eraseCaches: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try self.localDataEraser.eraseCaches()
            },
            erasePreferences: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try self.dataErasureIntentStore.erasePreferences()
            },
            verifyErasure: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try SpeakerLoginItemEraser.verify()
                try await self.credentialEraser.verify()
                try self.localDataEraser.verify()
            },
            clearIntent: { [weak self] in
                guard let self else {
                    throw SpeakerDataErasureReason.io
                }
                try self.dataErasureIntentStore.clearIntent()
            },
            requestExit: {
                SpeakerTerminationCoordinator.shared.handler = nil
                NSApp.terminate(nil)
            }
            )
        )
    }

    init() {
        LegacyPrivacyStateCleaner.removeObsoleteIdentifiers(
            from: .standard
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "com.local.speaker"
        let signingMode = SpeakerSigningMode(
            infoValue: Bundle.main.object(
                forInfoDictionaryKey: "SpeakerSigningMode"
            ) as? String
        )
        softwareUpdate = SoftwareUpdateFeature(
            configuration: .init(
                signingMode: signingMode,
                feedURLString: Bundle.main.object(
                    forInfoDictionaryKey: "SUFeedURL"
                ) as? String,
                publicEDKey: Bundle.main.object(
                    forInfoDictionaryKey: "SUPublicEDKey"
                ) as? String
            ),
            makeDriver: {
                SparkleSoftwareUpdateDriver()
            }
        )
        dataErasureIntentStore = SpeakerDataErasureIntentStore(
            intentFileURL: SpeakerDataErasureIntentStore.defaultIntentFileURL(),
            preferences: .standard,
            preferenceDomainNames: [
                bundleIdentifier,
                "com.local.speaker",
            ]
        )
        permissions = PermissionModel(access: SystemPermissionAccess())
        let audio = AVAudioCapture()
        let targets = AccessibilityInputTargets()
        let legacyHistoryFileURL = VersionedLocalSessionHistory.defaultFileURL()
        self.legacyHistoryFileURL = legacyHistoryFileURL
        let history = SQLiteSessionHistory(
            fileURL: SQLiteSessionHistory.defaultFileURL()
        )
        let localCredentials = LocalFileProviderCredentialStore()
        let configuredKeychainService = Bundle.main.object(
            forInfoDictionaryKey: "SpeakerKeychainService"
        ) as? String ?? KeychainProviderCredentialStore.defaultService
        currentKeychainService = configuredKeychainService
        let credentials: any ProviderCredentialStoring
        let migratingCredentials: MigratingProviderCredentialStore?
        if Bundle.main.object(forInfoDictionaryKey: "SpeakerCredentialStorage") as? String
            == "keychain"
        {
            let service = configuredKeychainService
            var legacyStores: [any ProviderCredentialStoring] = []
            if service != KeychainProviderCredentialStore.defaultService {
                legacyStores.append(KeychainProviderCredentialStore())
            }
            legacyStores.append(localCredentials)
            let migrating = MigratingProviderCredentialStore(
                primary: KeychainProviderCredentialStore(service: service),
                legacy: LegacyProviderCredentialStoreChain(stores: legacyStores)
            )
            credentials = migrating
            migratingCredentials = migrating
        } else {
            credentials = localCredentials
            migratingCredentials = nil
        }
        self.migratingCredentials = migratingCredentials
        let providerRuntimeDiagnostics =
            VoiceProviderRuntimeDiagnostics()
        self.providerRuntimeDiagnostics = providerRuntimeDiagnostics
        let doubao = CredentialedDoubaoTranscriber(
            credentials: credentials,
            runtimeDiagnostics: providerRuntimeDiagnostics
        )
        let deepSeek = CredentialedDeepSeekTextRefiner(credentials: credentials)
        let configuration = VoiceInputConfigurationController()
        let processor = DefaultVoiceTextProcessor(
            configuration: configuration,
            doubao: doubao,
            refinement: OptionalTextRefinementPipeline(refiner: deepSeek)
        )
        let dictionaryURL = VersionedJSONPersonalDictionaryStore.defaultFileURL()
        dictionaryFileURL = dictionaryURL
        legacyDictionaryFileURL = try?
            VersionedJSONPersonalDictionaryStore.applicationSupportFileURL()
        let dictionaryStore = VersionedJSONPersonalDictionaryStore(fileURL: dictionaryURL)
        let settingsStore = VersionedLocalAppSettingsStore(
            fileURL: VersionedLocalAppSettingsStore.defaultFileURL()
        )
        self.settingsStore = settingsStore
        let settingsNavigation = SettingsNavigationModel()
        self.settingsNavigation = settingsNavigation
        diagnostics = DiagnosticNoticeModel()
        let sessionActor = VoiceInputSessions(
            audioCapture: audio,
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
            announce: Self.announceAccessibility
        )
        self.voiceInput = voiceInput
        let globalInteraction = GlobalVoiceInteractionRouter(
            voiceTarget: voiceInput.shortcutTarget
        )
        self.globalInteraction = globalInteraction
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
        historyModel = HistoryModel(
            store: history,
            targets: targets,
            settingsStore: settingsStore,
            clipboard: SystemClipboardWriter(),
            announce: Self.announceAccessibility,
            interactionRouter: globalInteraction
        )
        overviewModel = OverviewModel(store: history)
        loginItemSettings = LoginItemSettingsModel(
            service: LoginItemServiceAdapter(),
            settingsStore: settingsStore
        )
        let permissionModel = permissions
        let shortcut = VoiceShortcutFeature(
            target: globalInteraction.shortcutTarget,
            accessibilityGranted: { [weak permissionModel] in
                permissionModel?.snapshot.accessibility == .granted
            },
            persistPreference: { choice in
                _ = try await settingsStore.updateShortcut(choice)
            }
        )
        self.shortcut = shortcut
        permissionRefreshCoordinator = PermissionRefreshCoordinator(
            permissions: permissions,
            shortcut: shortcut
        )
        shortcutAnnouncementCoordinator = ShortcutAnnouncementCoordinator(
            feature: shortcut,
            announce: Self.announceAccessibility
        )
        panel = VoiceInputPanelController(
            experience: voiceInput,
            routeEffect: { effect in
                switch effect {
                case .openSpeechSettings:
                    settingsNavigation.open(.apiKeys)
                }
            }
        )
        dataErasure = makeDataErasureCoordinator()

        permissions.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &childStateCancellables)
        voiceInput.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &childStateCancellables)

    }

    func start() {
        guard !started else { return }
        started = true
        if let request = DeliverySmokeRunner.request() {
            Task { @MainActor in
                await DeliverySmokeRunner.run(request)
            }
            return
        }
        if dataErasureIntentStore.isPending {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.dataErasure.eraseAllAndExit()
                if case let .incomplete(failure) = outcome {
                    self.mainWindow.select(.about)
                    self.diagnostics.publish(
                        Self.dataErasureMessage(for: failure)
                    )
                }
            }
            return
        }
#if DEBUG
        if let scenario = Self.visualScenario() {
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
        let speakerActivation = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in () }
        let workspaceActivation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .map { _ in () }
        permissionRefreshCoordinator.start(
            observing: speakerActivation
            .merge(with: workspaceActivation)
            .eraseToAnyPublisher()
        )
        speakerActivation
            .merge(with: workspaceActivation)
            .sink { [weak loginItemSettings] _ in
                Task { @MainActor [weak loginItemSettings] in
                    await loginItemSettings?.refresh()
                }
            }
            .store(in: &childStateCancellables)
        voiceInput.start()
        panel.start()
        SpeakerTerminationCoordinator.shared.handler = { [weak self] in
            guard let self else { return }
            self.shortcut.beginShutdown()
            self.permissionRefreshCoordinator.stop()
            let startupTask = self.startupTask
            startupTask?.cancel()
            self.onboardingController?.close()
            self.onboardingController = nil
            self.historyModel.shutdown()
            await self.refinementSettings.shutdown()
            await self.doubaoSettings.shutdown()
            await self.dictionarySettings.shutdown()
            await self.voiceInput.shutdown()
            await startupTask?.value
            await self.shortcut.flushPersistence()
        }
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startupTask = nil }
            let loadedSettings = await self.settingsStore.load()
            guard !Task.isCancelled else { return }
            switch loadedSettings {
            case let .recovered(_, recovery):
                self.diagnostics.publish("设置文件已恢复为默认值，原文件保留在 \(recovery.backupURL.lastPathComponent)。")
            case let .recoveryFailed(_, reason):
                self.diagnostics.publish(reason)
            case .defaults, .loaded:
                break
            }
            await self.doubaoSettings.loadResource(
                rawValue: loadedSettings.settings.doubaoResourceID
            )
            guard !Task.isCancelled else { return }
            if let migratingCredentials = self.migratingCredentials {
                await migratingCredentials.migrateAllProviders()
                guard !Task.isCancelled else { return }
                if let notice = await migratingCredentials.migrationNotice() {
                    self.diagnostics.publish(notice)
                }
            }
            await self.migrateLegacyDictionaryIfNeeded()
            guard !Task.isCancelled else { return }
            await self.dictionarySettings.load()
            guard !Task.isCancelled else { return }
            await self.refinementSettings.load()
            guard !Task.isCancelled else { return }
            let historyPrivacyScrubbed =
                await self.history.scrubUntrustedProviderMessages()
            guard !Task.isCancelled else { return }
            if historyPrivacyScrubbed {
                await self.migrateLegacyHistoryIfNeeded()
                guard !Task.isCancelled else { return }
                if await self.history.reconcileInterruptedSessions() == nil {
                    self.diagnostics.publish(
                        "上次运行中断的会话历史未能完成恢复，请在“关于”中复制诊断信息。"
                    )
                }
                guard !Task.isCancelled else { return }
                _ = await self.history.applyRetentionPolicy(
                    loadedSettings.settings.historyRetention,
                    now: Date()
                )
            } else {
                self.diagnostics.publish(
                    "旧版会话历史的隐私清理未完成；Speaker 已保留明确错误供你处理。"
                )
            }
            guard !Task.isCancelled else { return }
            await self.historyModel.refresh()
            guard !Task.isCancelled else { return }
            await self.loginItemSettings.restore(
                desiredEnabled: loadedSettings.settings.launchAtLogin
            )
            guard !Task.isCancelled else { return }
            // Activate global input only after every session dependency has
            // restored its persisted state. A startup-time key press must
            // never run with default provider/resource/refinement settings.
            self.shortcut.restore(loadedSettings.settings.shortcut)
#if DEBUG
            if let captureURL = Self.onboardingCaptureURL() {
                self.presentOnboarding(force: true)
                if let size = Self.onboardingCaptureSize() {
                    self.onboardingController?.resizeDebug(to: size)
                }
                await Task.yield()
                do {
                    try self.onboardingController?
                        .captureDebugSnapshot(to: captureURL)
                    NSLog(
                        "Speaker onboarding captured: \(captureURL.path)"
                    )
                } catch {
                    NSLog(
                        "Speaker onboarding capture failed: \(error)"
                    )
                }
            } else {
                self.presentOnboarding(force: false)
            }
#else
            self.presentOnboarding(force: false)
#endif
        }
    }

    func refreshPermissions() {
        synchronizePermissionAndShortcutState()
    }

    func requestPermission(_ permission: PermissionKind) async {
        _ = await permissions.request(permission)
        synchronizePermissionAndShortcutState()
    }

    func copyDiagnostics() async {
        let historyStatus = await history.persistenceStatus()
        let latestRecord = await history.latestRecord()
        let activeProvider =
            await providerRuntimeDiagnostics.activeSnapshot()
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "unknown"
        let credentialStorage = Bundle.main.object(
            forInfoDictionaryKey: "SpeakerCredentialStorage"
        ) as? String ?? "unknown"
        let signingMode = SpeakerSigningMode(
            infoValue: Bundle.main.object(
                forInfoDictionaryKey: "SpeakerSigningMode"
            ) as? String
        )
        let activity = voiceInput.state.diagnosticCode
        let historyNotice: String = switch historyStatus.notice {
        case nil: "none"
        case .corruptedDataPreserved: "corruptedDataPreserved"
        case .corruptedRecordsSkipped: "corruptedRecordsSkipped"
        case .privacyMigrationFailed: "privacyMigrationFailed"
        case .writeFailed: "writeFailed"
        }
        let report = SpeakerDiagnosticReport.make(from: .init(
            version: version,
            build: build,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            signingMode: signingMode.diagnosticValue,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            credentialStorage: credentialStorage,
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
            activeProvider: activeProvider,
            latestRecord: latestRecord
        ))
        let copied = await SystemClipboardWriter().copy(report)
        diagnostics.publish(
            copied ? "诊断信息已复制，不包含文字、音频或 API Key。" : "复制失败，请重试。"
        )
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onboardingController?.close()
        onboardingController = nil
    }

    private func presentOnboarding(force: Bool) {
        guard force
            || !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        else {
            return
        }
        let controller = SpeakerOnboardingWindowController(
            permissions: permissions,
            doubao: doubaoSettings,
            requestPermission: requestPermission,
            refreshPermissions: refreshPermissions,
            completion: { [weak self] in self?.completeOnboarding() }
        )
        onboardingController = controller
        controller.show()
    }

    private func migrateLegacyHistoryIfNeeded() async {
        guard FileManager.default.fileExists(atPath: legacyHistoryFileURL.path) else {
            return
        }
        let legacy = VersionedLocalSessionHistory(fileURL: legacyHistoryFileURL)
        let legacyStatus = await legacy.persistenceStatus()
        if let notice = legacyStatus.notice {
            switch notice {
            case let .corruptedDataPreserved(backupURL, _):
                diagnostics.publish(
                    "旧版历史文件损坏，已保留为 \(backupURL.lastPathComponent)。"
                )
            case .privacyMigrationFailed:
                diagnostics.publish(
                    "旧版会话历史的文件权限无法收紧，已停止迁移并保留原文件。"
                )
            case .corruptedRecordsSkipped, .writeFailed:
                diagnostics.publish(
                    "旧版会话历史尚未满足安全迁移条件，原文件仍保留。"
                )
            }
            return
        }
        let records = await legacy.allRecords()
        guard await history.importLegacyRecords(records) else {
            diagnostics.publish("旧版会话历史尚未完成迁移，原文件仍保留。")
            return
        }
        do {
            try FileManager.default.removeItem(at: legacyHistoryFileURL)
        } catch {
            diagnostics.publish("会话历史已迁移，但旧版 history.json 未能删除。")
        }
    }

    private func migrateLegacyDictionaryIfNeeded() async {
        guard let legacyDictionaryFileURL else { return }
        switch await VersionedJSONPersonalDictionaryStore
            .migrateLegacyFileIfNeeded(
                from: legacyDictionaryFileURL,
                to: dictionaryFileURL
            ) {
        case .notNeeded, .primaryAlreadyExists, .migrated:
            break
        case .migratedLegacyCleanupFailed:
            diagnostics.publish(
                "个人词库已迁移，但旧版词库文件未能删除。"
            )
        case .failed:
            diagnostics.publish(
                "旧版个人词库未能迁移，原文件仍保留。"
            )
        }
    }

    private func synchronizePermissionAndShortcutState() {
        permissionRefreshCoordinator.refreshNow()
    }

    private func quiesceForDataErasure() async {
        guard !isQuiescingForErasure else { return }
        isQuiescingForErasure = true
        shortcut.beginShutdown()
        permissionRefreshCoordinator.stop()
        let startupTask = startupTask
        startupTask?.cancel()
        onboardingController?.close()
        onboardingController = nil
        historyModel.shutdown()
        await refinementSettings.shutdown()
        await doubaoSettings.shutdown()
        await dictionarySettings.shutdown()
        await voiceInput.shutdown()
        await startupTask?.value
        await shortcut.flushPersistence()
    }

    private static func dataErasureMessage(
        for failure: SpeakerDataErasureFailure
    ) -> String {
        guard let issue = failure.issues.first else {
            return "本地数据未能全部清除，请重试。"
        }
        return switch issue.reason {
        case .accessDenied:
            "macOS 拒绝删除部分 Speaker 数据，请检查文件权限后重试。"
        case .interactionUnavailable:
            "凭据存储当前不可用，请解锁 Mac 后重试清除。"
        case .busy:
            "本地历史仍在使用中，Speaker 未删除数据库；请重试。"
        case .unsafePath:
            "Speaker 拒绝删除未通过安全校验的路径。"
        case .verificationMismatch:
            "清除结果未通过验证，Speaker 已保留重试状态。"
        case .io:
            "部分 Speaker 本地数据无法删除，请关闭占用后重试。"
        }
    }

#if DEBUG
    private static func onboardingCaptureURL() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(
            of: "--speaker-onboarding-capture"
        ), arguments.indices.contains(optionIndex + 1)
        else {
            return nil
        }
        return URL(fileURLWithPath: arguments[optionIndex + 1])
    }

    private static func onboardingCaptureSize() -> CGSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(
            of: "--speaker-onboarding-size"
        ), arguments.indices.contains(optionIndex + 1)
        else {
            return nil
        }
        let components = arguments[optionIndex + 1].split(separator: "x")
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

    private static func visualScenario() -> VoiceInputVisualScenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(
            of: "--speaker-visual-scenario"
        ), arguments.indices.contains(optionIndex + 1)
        else {
            return nil
        }
        return VoiceInputVisualScenario(rawValue: arguments[optionIndex + 1])
    }

    private func captureVisualScenarioIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(
            of: "--speaker-visual-capture"
        ), arguments.indices.contains(optionIndex + 1)
        else {
            return
        }
        let url = URL(fileURLWithPath: arguments[optionIndex + 1])
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

    private static func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority:
                    NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
