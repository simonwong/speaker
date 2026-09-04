import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport

/// A gate one stage can wait on so a case observes the sequence mid-flight.
@MainActor
private final class StageGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class StartupStagesFake: RuntimeStartupStages {
    var calls: [String] = []
    var settings: AppSettingsLoadResult = .loaded(.default)
    var unmigratedProviders: [ProviderID] = []
    var legacyDictionary: PersonalDictionaryMigrationOutcome?
    var dictionaryNotice: String?
    var scrubSucceeds = true
    var legacyHistory: LegacyHistoryMigrationOutcome = .notNeeded
    var reconciles = true
    var restoredShortcut: VoiceShortcutPreference?
    var restoredLoginItem: Bool?
    var appliedRetention: HistoryRetentionPolicy?
    var scrubGate: StageGate?

    func loadSettings() async -> AppSettingsLoadResult {
        calls.append("loadSettings")
        return settings
    }

    func loadDoubaoResource(rawValue: String?) async {
        calls.append("loadDoubaoResource")
    }

    func migrateCredentials() async -> [ProviderID] {
        calls.append("migrateCredentials")
        return unmigratedProviders
    }

    func migrateLegacyDictionary() async -> PersonalDictionaryMigrationOutcome? {
        calls.append("migrateLegacyDictionary")
        return legacyDictionary
    }

    func loadDictionary() async -> String? {
        calls.append("loadDictionary")
        return dictionaryNotice
    }

    func loadRefinement() async {
        calls.append("loadRefinement")
    }

    func scrubHistoryProviderMessages() async -> Bool {
        calls.append("scrubHistory")
        await scrubGate?.wait()
        return scrubSucceeds
    }

    func migrateLegacyHistory() async -> LegacyHistoryMigrationOutcome {
        calls.append("migrateLegacyHistory")
        return legacyHistory
    }

    func reconcileInterruptedSessions() async -> Bool {
        calls.append("reconcileInterruptedSessions")
        return reconciles
    }

    func applyHistoryRetention(_ policy: HistoryRetentionPolicy) async {
        calls.append("applyHistoryRetention")
        appliedRetention = policy
    }

    func refreshHistory() async {
        calls.append("refreshHistory")
    }

    func restoreLoginItem(desiredEnabled: Bool) async {
        calls.append("restoreLoginItem")
        restoredLoginItem = desiredEnabled
    }

    func restoreShortcut(_ preference: VoiceShortcutPreference) {
        calls.append("restoreShortcut")
        restoredShortcut = preference
    }

    func presentOnboarding() {
        calls.append("presentOnboarding")
    }
}

@MainActor
private final class ShutdownStagesFake: RuntimeShutdownStages {
    var calls: [String] = []
    var voiceInputGate: StageGate?

    func stopTrigger() { calls.append("stopTrigger") }
    func stopPermissionRefresh() { calls.append("stopPermissionRefresh") }
    func cancelStartup() { calls.append("cancelStartup") }
    func closeOnboarding() { calls.append("closeOnboarding") }
    func closePanel() { calls.append("closePanel") }
    func shutdownRefinement() async { calls.append("shutdownRefinement") }
    func shutdownDoubao() async { calls.append("shutdownDoubao") }

    func shutdownVoiceInput() async {
        calls.append("shutdownVoiceInput")
        await voiceInputGate?.wait()
    }

    func awaitStartup() async { calls.append("awaitStartup") }
    func flushPersistence() async { calls.append("flushPersistence") }
}

enum RuntimeLifecycleSpecs {
    private static let fullStartupOrder = [
        "loadSettings",
        "loadDoubaoResource",
        "migrateCredentials",
        "migrateLegacyDictionary",
        "loadDictionary",
        "loadRefinement",
        "scrubHistory",
        "migrateLegacyHistory",
        "reconcileInterruptedSessions",
        "applyHistoryRetention",
        "refreshHistory",
        "restoreLoginItem",
        "restoreShortcut",
        "presentOnboarding",
    ]

    private static let shutdownOrder = [
        "stopTrigger",
        "stopPermissionRefresh",
        "cancelStartup",
        "closeOnboarding",
        "closePanel",
        "shutdownRefinement",
        "shutdownDoubao",
        "shutdownVoiceInput",
        "awaitStartup",
        "flushPersistence",
    ]

    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("startup restores persisted state in migration order and activates the shortcut last", failures: &failures) {
            let stages = StartupStagesFake()
            let customShortcut = VoiceShortcutPreference.custom(
                keyCode: 49,
                modifiers: 0x100,
                displayName: "⌘Space"
            )
            stages.settings = .loaded(SpeakerAppSettings(
                shortcut: customShortcut,
                launchAtLogin: true,
                historyRetention: .thirtyDays
            ))
            var notices: [String] = []
            let sequence = RuntimeStartupSequence(stages: stages) { notices.append($0) }

            sequence.start()
            sequence.start()
            await sequence.waitUntilFinished()

            try expect(stages.calls == fullStartupOrder, "unexpected order \(stages.calls)")
            try expect(stages.restoredShortcut == customShortcut)
            try expect(stages.restoredLoginItem == true)
            try expect(stages.appliedRetention == .thirtyDays)
            try expect(notices.isEmpty, "a clean startup published \(notices)")
            try expect(!sequence.isRunning)
        }

        await runAsync("startup cancelled mid-migration never activates the shortcut or presents onboarding", failures: &failures) {
            let stages = StartupStagesFake()
            let gate = StageGate()
            stages.scrubGate = gate
            var notices: [String] = []
            let sequence = RuntimeStartupSequence(stages: stages) { notices.append($0) }

            sequence.start()
            let reachedScrub = await eventually(before: .seconds(2)) {
                stages.calls.last == "scrubHistory"
            }
            try expect(reachedScrub, "the sequence never reached the history scrub")
            try expect(sequence.isRunning)

            sequence.cancel()
            gate.open()
            await sequence.waitUntilFinished()

            try expect(stages.calls.last == "scrubHistory", "stages ran after cancellation: \(stages.calls)")
            try expect(!stages.calls.contains("restoreShortcut"), "a cancelled startup activated the shortcut")
            try expect(!stages.calls.contains("presentOnboarding"))
            try expect(notices.isEmpty)
            try expect(!sequence.isRunning)
        }

        await runAsync("startup publishes recovery and migration notices from stage outcomes", failures: &failures) {
            let stages = StartupStagesFake()
            let backupURL = URL(fileURLWithPath: "/tmp/settings.recovery-1.json")
            stages.settings = .recovered(
                .default,
                recovery: AppSettingsRecovery(
                    backupURL: backupURL,
                    reason: .unsupportedVersion(9)
                )
            )
            stages.unmigratedProviders = [.deepSeek, .doubao]
            stages.legacyDictionary = .failed
            stages.dictionaryNotice = "dictionary recovered"
            stages.legacyHistory = .legacyCorrupted(backupName: "history.corrupt-1.json")
            stages.reconciles = false
            var notices: [String] = []
            let sequence = RuntimeStartupSequence(stages: stages) { notices.append($0) }

            sequence.start()
            await sequence.waitUntilFinished()

            try expect(stages.calls == fullStartupOrder, "unexpected order \(stages.calls)")
            try expect(notices == [
                SpeakerCopy.Startup.settingsRecovered(backupName: "settings.recovery-1.json"),
                SpeakerCopy.Startup.credentialMigrationIncomplete(
                    providers: [.deepSeek, .doubao]
                )!,
                SpeakerCopy.Startup.legacyDictionaryMigrationFailed,
                "dictionary recovered",
                SpeakerCopy.Startup.legacyHistoryNotice(
                    .legacyCorrupted(backupName: "history.corrupt-1.json")
                )!,
                SpeakerCopy.Startup.interruptedSessionsNotReconciled,
            ], "unexpected notices \(notices)")
        }

        await runAsync("unreadable legacy dictionary source is reported once and does not stop startup", failures: &failures) {
            let stages = StartupStagesFake()
            stages.legacyDictionary = .failed
            var notices: [String] = []
            let sequence = RuntimeStartupSequence(stages: stages) { notices.append($0) }

            sequence.start()
            await sequence.waitUntilFinished()

            try expect(notices == [SpeakerCopy.Startup.legacyDictionaryMigrationFailed])
            try expect(stages.calls.contains("loadDictionary"))
            try expect(stages.calls.last == "presentOnboarding")

            for outcome in [
                PersonalDictionaryMigrationOutcome.notNeeded,
                .primaryAlreadyExists,
                .migrated,
            ] {
                try expect(
                    SpeakerCopy.Startup.legacyDictionaryNotice(outcome) == nil,
                    "\(outcome) produced a notice"
                )
            }
            try expect(
                SpeakerCopy.Startup.legacyDictionaryNotice(.migratedLegacyCleanupFailed)
                    == SpeakerCopy.Startup.legacyDictionaryCleanupFailed
            )
        }

        await runAsync("incomplete history privacy scrub skips history migration but still restores the shortcut", failures: &failures) {
            let stages = StartupStagesFake()
            stages.scrubSucceeds = false
            var notices: [String] = []
            let sequence = RuntimeStartupSequence(stages: stages) { notices.append($0) }

            sequence.start()
            await sequence.waitUntilFinished()

            try expect(stages.calls == [
                "loadSettings",
                "loadDoubaoResource",
                "migrateCredentials",
                "migrateLegacyDictionary",
                "loadDictionary",
                "loadRefinement",
                "scrubHistory",
                "refreshHistory",
                "restoreLoginItem",
                "restoreShortcut",
                "presentOnboarding",
            ], "unexpected order \(stages.calls)")
            try expect(notices == [SpeakerCopy.Startup.historyPrivacyScrubIncomplete])
        }

        await runAsync("shutdown converges through every stage in order exactly once", failures: &failures) {
            let stages = ShutdownStagesFake()
            let coordinator = RuntimeShutdownCoordinator(stages: stages)
            try expect(!coordinator.hasStarted)

            await coordinator.converge()

            try expect(stages.calls == shutdownOrder, "unexpected order \(stages.calls)")
            try expect(coordinator.hasStarted)

            await coordinator.converge()
            try expect(stages.calls == shutdownOrder, "a second convergence repeated stages: \(stages.calls)")
        }

        await runAsync("termination and erasure quiesce share one in-flight convergence", failures: &failures) {
            let stages = ShutdownStagesFake()
            let gate = StageGate()
            stages.voiceInputGate = gate
            let coordinator = RuntimeShutdownCoordinator(stages: stages)

            let termination = Task { @MainActor in await coordinator.converge() }
            let reachedVoiceInput = await eventually(before: .seconds(2)) {
                stages.calls.last == "shutdownVoiceInput"
            }
            try expect(reachedVoiceInput, "convergence never reached the Voice Input shutdown")
            var erasureFinished = false
            let erasure = Task { @MainActor in
                await coordinator.converge()
                erasureFinished = true
            }
            await Task.yield()
            try expect(!erasureFinished, "the second caller returned before convergence finished")
            try expect(stages.calls.count == 8, "the second caller restarted stages: \(stages.calls)")

            gate.open()
            await termination.value
            await erasure.value

            try expect(erasureFinished)
            try expect(stages.calls == shutdownOrder, "unexpected order \(stages.calls)")
        }
    }
}
