import Foundation
import SpeakerCore

/// What happened to the legacy `history.json` file during startup.
package enum LegacyHistoryMigrationOutcome: Equatable, Sendable {
    /// No legacy file exists.
    case notNeeded
    /// Every legacy record now lives in the SQLite store and the file is gone.
    case migrated
    /// Records were imported but the legacy file could not be deleted.
    case migratedLegacyFileRemains
    /// The legacy file was corrupt; a copy was preserved under `backupName`.
    case legacyCorrupted(backupName: String)
    /// The legacy file's permissions could not be tightened; it stays untouched.
    case legacyProtectionFailed
    /// The legacy store reported a problem that blocks a safe migration.
    case legacyNotReady
    /// The SQLite store refused the import; the legacy file stays.
    case importRefused
}

/// The stages the startup sequence runs, in order. Each stage owns one
/// collaborator; the sequence owns the order, the cancellation checkpoints, and
/// the notices derived from stage outcomes.
@MainActor
package protocol RuntimeStartupStages: AnyObject {
    func loadSettings() async -> AppSettingsLoadResult
    func loadDoubaoResource(rawValue: String?) async
    /// Migrates provider credentials into the current store. Returns the
    /// providers whose legacy credential is still unmigrated, or an empty
    /// array when nothing needs saying.
    func migrateCredentials() async -> [ProviderID]
    /// Moves the legacy Personal Dictionary file, or nil when no legacy
    /// location exists.
    func migrateLegacyDictionary() async -> PersonalDictionaryMigrationOutcome?
    /// Loads the Personal Dictionary. Returns a notice when the stored file
    /// had to be recovered.
    func loadDictionary() async -> String?
    func loadRefinement() async
    /// Whether the history store finished scrubbing untrusted provider text.
    func scrubHistoryProviderMessages() async -> Bool
    func migrateLegacyHistory() async -> LegacyHistoryMigrationOutcome
    /// Whether interrupted sessions were reconciled.
    func reconcileInterruptedSessions() async -> Bool
    func applyHistoryRetention(_ policy: HistoryRetentionPolicy) async
    func refreshHistory() async
    func restoreLoginItem(desiredEnabled: Bool) async
    func restoreShortcut(_ preference: VoiceShortcutPreference)
    func presentOnboarding()
}

/// The ordered startup migration sequence of the runtime.
///
/// Global input is activated last: a startup-time key press must never run
/// with default provider, resource, or refinement settings. Cancellation is
/// checked between stages, and a cancelled sequence never activates the
/// shortcut or presents onboarding.
@MainActor
package final class RuntimeStartupSequence {
    package typealias Publish = @MainActor (String) -> Void

    private let stages: any RuntimeStartupStages
    private let publish: Publish
    private var task: Task<Void, Never>?

    package init(stages: any RuntimeStartupStages, publish: @escaping Publish) {
        self.stages = stages
        self.publish = publish
    }

    /// Whether the sequence is still running.
    package var isRunning: Bool { task != nil }

    /// Starts the sequence once; later calls are ignored.
    package func start() {
        guard task == nil else { return }
        let stages = self.stages
        let publish = self.publish
        task = Task { @MainActor [weak self] in
            defer { self?.task = nil }
            await Self.run(stages, publish: publish)
        }
    }

    /// Asks a running sequence to stop at its next checkpoint.
    package func cancel() {
        task?.cancel()
    }

    /// Waits for a running sequence to finish or reach its cancellation
    /// checkpoint. Returns immediately when nothing is running.
    package func waitUntilFinished() async {
        await task?.value
    }

    package static func run(
        _ stages: any RuntimeStartupStages,
        publish: Publish
    ) async {
        let loadedSettings = await stages.loadSettings()
        guard !Task.isCancelled else { return }
        switch loadedSettings {
        case .recovered(_, let recovery):
            publish(
                SpeakerCopy.Startup.settingsRecovered(
                    backupName: recovery.backupURL.lastPathComponent
                ))
        case .recoveryFailed(_, let failure):
            publish(SpeakerCopy.Startup.settingsLoadFailed(failure))
        case .defaults, .loaded:
            break
        }
        let settings = loadedSettings.settings
        await stages.loadDoubaoResource(rawValue: settings.doubaoResourceID)
        guard !Task.isCancelled else { return }
        if let notice = SpeakerCopy.Startup.credentialMigrationIncomplete(
            providers: await stages.migrateCredentials()
        ) {
            publish(notice)
        }
        guard !Task.isCancelled else { return }
        if let notice = await stages.migrateLegacyDictionary()
            .flatMap(SpeakerCopy.Startup.legacyDictionaryNotice)
        {
            publish(notice)
        }
        guard !Task.isCancelled else { return }
        if let notice = await stages.loadDictionary() {
            publish(notice)
        }
        guard !Task.isCancelled else { return }
        await stages.loadRefinement()
        guard !Task.isCancelled else { return }
        if await stages.scrubHistoryProviderMessages() {
            guard !Task.isCancelled else { return }
            if let notice = SpeakerCopy.Startup.legacyHistoryNotice(
                await stages.migrateLegacyHistory()
            ) {
                publish(notice)
            }
            guard !Task.isCancelled else { return }
            if await !stages.reconcileInterruptedSessions() {
                publish(SpeakerCopy.Startup.interruptedSessionsNotReconciled)
            }
            guard !Task.isCancelled else { return }
            await stages.applyHistoryRetention(settings.historyRetention)
        } else {
            publish(SpeakerCopy.Startup.historyPrivacyScrubIncomplete)
        }
        guard !Task.isCancelled else { return }
        await stages.refreshHistory()
        guard !Task.isCancelled else { return }
        await stages.restoreLoginItem(desiredEnabled: settings.launchAtLogin)
        guard !Task.isCancelled else { return }
        stages.restoreShortcut(settings.shortcut)
        stages.presentOnboarding()
    }
}
