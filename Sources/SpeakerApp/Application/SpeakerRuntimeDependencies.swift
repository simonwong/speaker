import AppKit
import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore

/// Facts read once from the running bundle's Info.plist.
struct SpeakerBundleInfo {
    let bundleIdentifier: String
    let buildInfo: SpeakerBuildInfoReader
    let feedURLString: String?
    let publicEDKey: String?
    let keychainService: String
    /// "keychain" selects the Keychain credential store; anything else keeps
    /// the owner-only local file.
    let credentialStorage: String?

    static let fallbackBundleIdentifier = "com.local.speaker"

    static func main() -> SpeakerBundleInfo {
        let bundle = Bundle.main
        func string(_ key: String) -> String? {
            bundle.object(forInfoDictionaryKey: key) as? String
        }
        return SpeakerBundleInfo(
            bundleIdentifier: bundle.bundleIdentifier ?? fallbackBundleIdentifier,
            buildInfo: .main,
            feedURLString: string("SUFeedURL"),
            publicEDKey: string("SUPublicEDKey"),
            keychainService: string("SpeakerKeychainService")
                ?? KeychainProviderCredentialStore.defaultService,
            credentialStorage: string("SpeakerCredentialStorage")
        )
    }
}

/// The provider credential store the runtime reads, plus the migrating
/// wrapper when older stores still need draining into it.
struct SpeakerCredentialSelection {
    let store: any ProviderCredentialStoring
    let migrating: MigratingProviderCredentialStore?
    let keychainService: String

    static func production(bundle: SpeakerBundleInfo) -> SpeakerCredentialSelection {
        let local = LocalFileProviderCredentialStore()
        guard bundle.credentialStorage == "keychain" else {
            return SpeakerCredentialSelection(
                store: local,
                migrating: nil,
                keychainService: bundle.keychainService
            )
        }
        var legacyStores: [any ProviderCredentialStoring] = []
        if bundle.keychainService != KeychainProviderCredentialStore.defaultService {
            legacyStores.append(KeychainProviderCredentialStore())
        }
        legacyStores.append(local)
        let migrating = MigratingProviderCredentialStore(
            primary: KeychainProviderCredentialStore(service: bundle.keychainService),
            legacy: LegacyProviderCredentialStoreChain(stores: legacyStores)
        )
        return SpeakerCredentialSelection(
            store: migrating,
            migrating: migrating,
            keychainService: bundle.keychainService
        )
    }
}

/// The workspace-level effects the runtime asks AppKit for.
@MainActor
struct SpeakerWorkspaceAccess {
    /// Fires when Speaker or any other application becomes active.
    let applicationActivations: AnyPublisher<Void, Never>
    let openURL: @Sendable (URL) -> Void
    let announce: AccessibilityAnnounce
    let terminate: @MainActor () -> Void

    static func production() -> SpeakerWorkspaceAccess {
        let speakerActivation = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in () }
        let workspaceActivation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .map { _ in () }
        return SpeakerWorkspaceAccess(
            applicationActivations:
                speakerActivation
                .merge(with: workspaceActivation)
                .eraseToAnyPublisher(),
            openURL: { NSWorkspace.shared.open($0) },
            announce: { message in
                NSAccessibility.post(
                    element: NSApplication.shared,
                    notification: .announcementRequested,
                    userInfo: [
                        NSAccessibility.NotificationUserInfoKey.announcement: message,
                        NSAccessibility.NotificationUserInfoKey.priority:
                            NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
            },
            terminate: { NSApp.terminate(nil) }
        )
    }
}

/// Everything the runtime reaches outside its own models. Production wires
/// the live adapters; a maintainer can construct the runtime with
/// deterministic replacements for any of them.
@MainActor
struct SpeakerRuntimeDependencies {
    var bundle: SpeakerBundleInfo
    var preferences: UserDefaults
    var launchArguments: [String]
    var operatingSystemVersion: String
    var audioCapture: any AudioCapturing & AudioCaptureEnvironmentProviding
    var history: SQLiteSessionHistory
    var legacyHistoryFileURL: URL
    var settingsStore: VersionedLocalAppSettingsStore
    var dictionaryStore: VersionedJSONPersonalDictionaryStore
    var legacyDictionaryFileURL: URL?
    var credentials: SpeakerCredentialSelection
    var dataErasureIntentFileURL: URL
    var localDataEraser: SpeakerOwnedLocalDataEraser
    var credentialEraser: SpeakerProviderCredentialEraser
    var permissionAccess: any PermissionAccess
    var loginItemService: any LoginItemServicing
    var makeUpdateDriver: SoftwareUpdateFeature.MakeDriver
    var workspace: SpeakerWorkspaceAccess
    var termination: SpeakerTerminationCoordinator

    static func production(
        termination: SpeakerTerminationCoordinator
    ) -> SpeakerRuntimeDependencies {
        let bundle = SpeakerBundleInfo.main()
        return SpeakerRuntimeDependencies(
            bundle: bundle,
            preferences: .standard,
            launchArguments: ProcessInfo.processInfo.arguments,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            audioCapture: AVAudioCapture(),
            history: SQLiteSessionHistory(
                fileURL: SQLiteSessionHistory.defaultFileURL()
            ),
            legacyHistoryFileURL: VersionedLocalSessionHistory.defaultFileURL(),
            settingsStore: VersionedLocalAppSettingsStore(
                fileURL: VersionedLocalAppSettingsStore.defaultFileURL()
            ),
            dictionaryStore: VersionedJSONPersonalDictionaryStore(
                fileURL: VersionedJSONPersonalDictionaryStore.defaultFileURL()
            ),
            legacyDictionaryFileURL:
                try? VersionedJSONPersonalDictionaryStore.applicationSupportFileURL(),
            credentials: .production(bundle: bundle),
            dataErasureIntentFileURL: SpeakerDataErasureIntentStore.defaultIntentFileURL(),
            localDataEraser: SpeakerOwnedLocalDataEraser(
                locations: SpeakerOwnedDataLocations.current(
                    bundleIdentifier: bundle.bundleIdentifier
                ),
                allowedLibraryRoot: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true),
                fileManager: .default
            ),
            credentialEraser: SpeakerProviderCredentialEraser(
                localFileURL: LocalFileProviderCredentialStore.defaultFileURL(),
                currentKeychainService: bundle.keychainService
            ),
            permissionAccess: SystemPermissionAccess(),
            loginItemService: LoginItemServiceAdapter(),
            makeUpdateDriver: { SparkleSoftwareUpdateDriver() },
            workspace: .production(),
            termination: termination
        )
    }
}
