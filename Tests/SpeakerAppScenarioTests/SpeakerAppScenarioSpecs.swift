import Darwin
import AppKit
@preconcurrency import Carbon
import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerCoreSpecFakes
import SpeakerSpecSupport

@main
struct SpeakerAppScenarioSpecs {
    @MainActor
    static func main() async {
        var failures: [String] = []

        run("Doubao refresh preserves a verified connection for an existing key", failures: &failures) {
            let status = DoubaoConnectionStatus.success("request-id")
            try expect(
                status.afterCredentialRefresh(keyExists: true)
                    == .success("request-id")
            )
        }

        run("Doubao refresh drops verification when the key disappears", failures: &failures) {
            try expect(
                DoubaoConnectionStatus.success(nil)
                    .afterCredentialRefresh(keyExists: false) == .unconfigured
            )
        }

        run("Doubao refresh clears a stale connection error for an existing key", failures: &failures) {
            try expect(
                DoubaoConnectionStatus.failure("旧错误")
                    .afterCredentialRefresh(keyExists: true) == .configured
            )
        }

        run("onboarding requires both permissions and a verified connection", failures: &failures) {
            let ready = OnboardingPresentation(
                permissions: .init(
                    accessibility: .granted,
                    microphone: .granted
                ),
                doubaoStatus: .success(nil),
                hasStoredDoubaoKey: true
            )
            let missingPermission = OnboardingPresentation(
                permissions: .init(
                    accessibility: .denied,
                    microphone: .granted
                ),
                doubaoStatus: .success(nil),
                hasStoredDoubaoKey: true
            )
            let unverified = OnboardingPresentation(
                permissions: ready.permissions,
                doubaoStatus: .configured,
                hasStoredDoubaoKey: true
            )
            let deletedKeyWithStaleSuccess = OnboardingPresentation(
                permissions: ready.permissions,
                doubaoStatus: .success("stale-request"),
                hasStoredDoubaoKey: false
            )

            try expect(ready.isReady)
            try expect(!missingPermission.isReady)
            try expect(!unverified.isReady)
            try expect(!deletedKeyWithStaleSuccess.isReady)
        }

        run("shortcut recorder captures one physical modifier on release", failures: &failures) {
            var policy = ShortcutRecorderPolicy()
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Option),
                    flags: [.option]
                )) == .consume
            )
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Option),
                    flags: []
                )) == .capture(
                    CustomHotKey.modifierOnly(
                        .leftOption,
                        displayName: "左 ⌥"
                    )
                )
            )

            policy.reset()
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_RightOption),
                    flags: [.option]
                )) == .consume
            )
            try expect(
                policy.handle(.keyDown(
                    keyCode: UInt16(kVK_Space),
                    flags: [.option],
                    charactersIgnoringModifiers: " "
                )) == .capture(CustomHotKey(
                    keyCode: UInt32(kVK_Space),
                    modifiers: UInt32(optionKey),
                    displayName: "⌥Space"
                ))
            )

            policy.reset()
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Option),
                    flags: [.option]
                )) == .consume
            )
            guard case .reject = policy.handle(.keyDown(
                keyCode: UInt16(kVK_ANSI_A),
                flags: [.option],
                charactersIgnoringModifiers: "a"
            )) else {
                throw SpecFailure(message: "unsafe Option chord was accepted")
            }
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Option),
                    flags: []
                )) == .consume
            )

            policy.reset()
            try expect(
                policy.handle(.keyDown(
                    keyCode: UInt16(kVK_Escape),
                    flags: [],
                    charactersIgnoringModifiers: nil
                )) == .cancel
            )
            try expect(
                policy.handle(.flagsChanged(
                    keyCode: UInt16(kVK_Command),
                    flags: [.command]
                )) == .consume
            )
            guard case .reject = policy.handle(.flagsChanged(
                keyCode: UInt16(kVK_Command),
                flags: []
            )) else {
                throw SpecFailure(message: "Command alone was accepted")
            }
        }

        run("onboarding exposes only valid permission and provider actions", failures: &failures) {
            let presentation = OnboardingPresentation(
                permissions: .init(
                    accessibility: .denied,
                    microphone: .notDetermined
                ),
                doubaoStatus: .checking,
                hasStoredDoubaoKey: true
            )

            try expect(
                presentation.permissionAction(for: .microphone)
                    == .request
            )
            try expect(
                presentation.permissionAction(for: .accessibility)
                    == .openSystemSettings
            )
            try expect(!presentation.canCheckConnection)
            try expect(!presentation.canSelectResource)
            try expect(!presentation.canComplete)

            let restricted = OnboardingPresentation(
                permissions: .init(
                    accessibility: .restricted,
                    microphone: .granted
                ),
                doubaoStatus: .configured,
                hasStoredDoubaoKey: true
            )
            try expect(
                restricted.permissionAction(for: .accessibility) == nil
            )
            try expect(
                restricted.permissionAction(for: .microphone) == nil
            )
            try expect(restricted.canCheckConnection)
            try expect(restricted.canSelectResource)
        }

        await runAsync(
            "onboarding advances from an explicit microphone grant only",
            failures: &failures
        ) {
            let grantedAccess = ScenarioPermissionAccess(
                snapshot: .init(
                    accessibility: .denied,
                    microphone: .notDetermined
                ),
                requestSnapshots: [
                    .microphone: .init(
                        accessibility: .denied,
                        microphone: .granted
                    ),
                ]
            )
            let grantedPermissions = PermissionModel(access: grantedAccess)
            var grantedSynchronizations = 0
            let grantedCoordinator = OnboardingPermissionCoordinator(
                permissions: grantedPermissions,
                synchronize: { grantedSynchronizations += 1 }
            )

            await grantedCoordinator.request(.microphone)

            try expect(
                grantedAccess.requestedPermissions
                    == [.microphone, .accessibility]
            )
            try expect(grantedSynchronizations == 2)

            for terminalState in [
                PermissionState.denied,
                PermissionState.restricted,
            ] {
                let stoppedAccess = ScenarioPermissionAccess(
                    snapshot: .init(
                        accessibility: .denied,
                        microphone: .notDetermined
                    ),
                    requestSnapshots: [
                        .microphone: .init(
                            accessibility: .denied,
                            microphone: terminalState
                        ),
                    ]
                )
                let stoppedPermissions = PermissionModel(access: stoppedAccess)
                var stoppedSynchronizations = 0
                let stoppedCoordinator = OnboardingPermissionCoordinator(
                    permissions: stoppedPermissions,
                    synchronize: { stoppedSynchronizations += 1 }
                )

                await stoppedCoordinator.request(.microphone)

                try expect(stoppedAccess.requestedPermissions == [.microphone])
                try expect(stoppedSynchronizations == 1)
            }
        }

        await runAsync(
            "data erasure preserves strict ordering and exits only after verification",
            failures: &failures
        ) {
            let harness = DataErasureHarness()
            let coordinator = SpeakerDataErasureCoordinator(
                dependencies: harness.dependencies()
            )

            let outcome = await coordinator.eraseAllAndExit()

            try expect(outcome == .exitRequested)
            try expect(
                harness.calls == [
                    "intent",
                    "runtime",
                    "login",
                    "credentials",
                    "history",
                    "applicationSupport",
                    "legacy",
                    "caches",
                    "preferences",
                    "verification",
                    "clearIntent",
                    "exit",
                ]
            )
            try expect(harness.exitCount == 1)
        }

        run(
            "data erasure intent survives preference deletion until verification commits",
            failures: &failures
        ) {
            let suiteName = "speaker-erasure-intent-spec-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw SpecFailure(message: "could not create isolated defaults")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-erasure-intent-\(UUID().uuidString)",
                    isDirectory: true
                )
            let intentFileURL = directory.appendingPathComponent("erase.pending")
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            defaults.set("keep-until-commit", forKey: "sample")
            let store = SpeakerDataErasureIntentStore(
                intentFileURL: intentFileURL,
                preferences: defaults,
                preferenceDomainNames: [suiteName]
            )

            try store.persist()
            try expect(store.isPending)
            try expect(defaults.string(forKey: "sample") == "keep-until-commit")
            try store.persist()
            try expect(store.isPending)

            try store.erasePreferences()
            try expect(store.isPending)
            try expect(defaults.persistentDomain(forName: suiteName)?.isEmpty != false)

            try store.clearIntent()
            try expect(!store.isPending)
            try expect(!FileManager.default.fileExists(atPath: directory.path))
        }

        run(
            "data erasure intent never follows a symbolic-link parent",
            failures: &failures
        ) {
            let suiteName = "speaker-erasure-intent-link-spec-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw SpecFailure(message: "could not create isolated defaults")
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-erasure-intent-link-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: root)
            }
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            let linkedDirectory = root.appendingPathComponent("Speaker", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            let sentinel = outside.appendingPathComponent("erase.pending")
            try Data("external-sentinel".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory,
                withDestinationURL: outside
            )
            let store = SpeakerDataErasureIntentStore(
                intentFileURL: linkedDirectory.appendingPathComponent("erase.pending"),
                preferences: defaults,
                preferenceDomainNames: [suiteName]
            )

            do {
                try store.persist()
                throw SpecFailure(message: "intent was written through a symlink parent")
            } catch let reason as SpeakerDataErasureReason {
                try expect(reason == .io)
            }
            do {
                try store.clearIntent()
                throw SpecFailure(message: "intent was removed through a symlink parent")
            } catch let reason as SpeakerDataErasureReason {
                try expect(reason == .io)
            }
            try expect(store.isPending, "unsafe intent path did not fail closed")
            let retainedSentinel = try Data(contentsOf: sentinel)
            try expect(
                retainedSentinel == Data("external-sentinel".utf8),
                "external intent sentinel was changed"
            )
        }

        await runAsync(
            "data erasure stops before credentials when login item removal fails",
            failures: &failures
        ) {
            let harness = DataErasureHarness(failing: ["login"])
            let coordinator = SpeakerDataErasureCoordinator(
                dependencies: harness.dependencies()
            )

            let outcome = await coordinator.eraseAllAndExit()

            guard case let .incomplete(failure) = outcome else {
                throw SpecFailure(message: "failure was reported as success")
            }
            try expect(
                harness.calls == ["intent", "runtime", "login"]
            )
            try expect(failure.issues.first?.stage == .loginItem)
            try expect(
                failure.remaining.contains(.providerCredentials)
            )
            try expect(harness.exitCount == 0)
        }

        await runAsync(
            "data erasure attempts independent path groups but preserves preferences on failure",
            failures: &failures
        ) {
            let harness = DataErasureHarness(
                failing: ["applicationSupport", "caches"]
            )
            let coordinator = SpeakerDataErasureCoordinator(
                dependencies: harness.dependencies()
            )

            let outcome = await coordinator.eraseAllAndExit()

            guard case let .incomplete(failure) = outcome else {
                throw SpecFailure(message: "partial deletion was reported as success")
            }
            try expect(harness.calls.contains("legacy"))
            try expect(harness.calls.contains("caches"))
            try expect(!harness.calls.contains("preferences"))
            try expect(!harness.calls.contains("verification"))
            try expect(failure.issues.count == 2)
            try expect(failure.remaining.contains(.preferences))
            try expect(harness.exitCount == 0)
        }

        await runAsync(
            "data erasure keeps its recovery intent when final verification fails",
            failures: &failures
        ) {
            let harness = DataErasureHarness(failing: ["verification"])
            let coordinator = SpeakerDataErasureCoordinator(
                dependencies: harness.dependencies()
            )

            let outcome = await coordinator.eraseAllAndExit()

            guard case let .incomplete(failure) = outcome else {
                throw SpecFailure(message: "verification failure was reported as success")
            }
            try expect(failure.issues.first?.stage == .verification)
            try expect(harness.calls.contains("preferences"))
            try expect(!harness.calls.contains("clearIntent"))
            try expect(harness.exitCount == 0)
        }

        await runAsync(
            "concurrent data erasure callers share one non-cancellable operation",
            failures: &failures
        ) {
            let harness = DataErasureHarness(operationDelay: .milliseconds(8))
            let coordinator = SpeakerDataErasureCoordinator(
                dependencies: harness.dependencies()
            )
            let cancelledWaiter = Task {
                await coordinator.eraseAllAndExit()
            }
            try await Task.sleep(for: .milliseconds(4))
            cancelledWaiter.cancel()
            let secondWaiter = Task {
                await coordinator.eraseAllAndExit()
            }

            let secondOutcome = await secondWaiter.value
            _ = await cancelledWaiter.value

            try expect(secondOutcome == .exitRequested)
            try expect(harness.calls.filter { $0 == "intent" }.count == 1)
            try expect(harness.calls.filter { $0 == "verification" }.count == 1)
            try expect(harness.exitCount == 1)
        }

        run(
            "owned local data erasure deletes only verified Library descendants",
            failures: &failures
        ) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-owned-data-spec-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            let locations = SpeakerOwnedDataLocations(
                applicationSupport: library.appendingPathComponent(
                    "Application Support/Speaker",
                    isDirectory: true
                ),
                legacyApplicationSupport: library.appendingPathComponent(
                    "Application Support/com.local.speaker",
                    isDirectory: true
                ),
                caches: [
                    library.appendingPathComponent(
                        "Caches/com.local.speaker",
                        isDirectory: true
                    ),
                ],
                savedApplicationState: [
                    library.appendingPathComponent(
                        "Saved Application State/com.local.speaker.savedState",
                        isDirectory: true
                    ),
                ]
            )
            let allLocations = [
                locations.applicationSupport,
                locations.legacyApplicationSupport,
            ] + locations.caches + locations.savedApplicationState
            for location in allLocations {
                try FileManager.default.createDirectory(
                    at: location,
                    withIntermediateDirectories: true
                )
                try Data("owned".utf8).write(
                    to: location.appendingPathComponent("sentinel")
                )
            }
            let eraser = SpeakerOwnedLocalDataEraser(
                locations: locations,
                allowedLibraryRoot: library
            )

            try eraser.eraseApplicationSupport()
            try eraser.eraseLegacyData()
            try eraser.eraseCaches()
            try eraser.verify()

            try expect(
                allLocations.allSatisfy {
                    !FileManager.default.fileExists(atPath: $0.path)
                }
            )
            try expect(
                FileManager.default.fileExists(atPath: root.path),
                "eraser removed an ancestor outside its owned paths"
            )
        }

        run(
            "owned local data erasure fails closed for an unsafe path",
            failures: &failures
        ) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-unsafe-data-spec-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            let unsafe = root.appendingPathComponent(
                "Outside/Speaker",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: unsafe,
                withIntermediateDirectories: true
            )
            let locations = SpeakerOwnedDataLocations(
                applicationSupport: unsafe,
                legacyApplicationSupport: library.appendingPathComponent(
                    "Application Support/com.local.speaker"
                ),
                caches: [],
                savedApplicationState: []
            )
            let eraser = SpeakerOwnedLocalDataEraser(
                locations: locations,
                allowedLibraryRoot: library
            )

            do {
                try eraser.eraseApplicationSupport()
                throw SpecFailure(message: "unsafe path was deleted")
            } catch let reason as SpeakerDataErasureReason {
                try expect(reason == .unsafePath)
            }
            try expect(FileManager.default.fileExists(atPath: unsafe.path))
        }

        run(
            "owned local data erasure rejects a parent symlink escaping Library",
            failures: &failures
        ) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-symlink-data-spec-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let outsideCaches = root.appendingPathComponent(
                "OutsideCaches",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: library,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outsideCaches.appendingPathComponent("Speaker"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: library.appendingPathComponent("Caches"),
                withDestinationURL: outsideCaches
            )
            let locations = SpeakerOwnedDataLocations(
                applicationSupport: library.appendingPathComponent(
                    "Application Support/Speaker"
                ),
                legacyApplicationSupport: library.appendingPathComponent(
                    "Application Support/com.local.speaker"
                ),
                caches: [library.appendingPathComponent("Caches/Speaker")],
                savedApplicationState: []
            )
            let eraser = SpeakerOwnedLocalDataEraser(
                locations: locations,
                allowedLibraryRoot: library
            )

            do {
                try eraser.eraseCaches()
                throw SpecFailure(message: "symlink escape was deleted")
            } catch let reason as SpeakerDataErasureReason {
                try expect(reason == .unsafePath)
            }
            try expect(
                FileManager.default.fileExists(
                    atPath: outsideCaches
                        .appendingPathComponent("Speaker")
                        .path
                )
            )
        }

        run(
            "owned data locations include legacy cache for a production bundle",
            failures: &failures
        ) {
            let locations = SpeakerOwnedDataLocations.current(
                bundleIdentifier: "com.example.Speaker"
            )

            try expect(
                locations.caches.contains {
                    $0.lastPathComponent == "com.local.speaker"
                }
            )
        }

        run(
            "every surface reads one Doubao status presentation",
            failures: &failures
        ) {
            let checking = DoubaoStatusPresentation(status: .checking)
            try expect(checking.text == "正在检查连接")
            try expect(checking.symbolName == "arrow.triangle.2.circlepath")

            try expect(
                DoubaoStatusPresentation(status: .loading).text
                    == "正在读取本机配置"
            )
            try expect(
                DoubaoStatusPresentation(status: .unconfigured).symbolName
                    == "key.slash"
            )
            try expect(
                DoubaoStatusPresentation(status: .configured).text == "已配置"
            )
            try expect(
                DoubaoStatusPresentation(status: .success("id")).text
                    == "连接成功"
            )
            try expect(
                DoubaoStatusPresentation(status: .failure("网络中断")).text
                    == "网络中断"
            )
        }

        run(
            "every erase entry point explains a reason with one sentence",
            failures: &failures
        ) {
            let failure = SpeakerDataErasureFailure(
                issues: [
                    .init(stage: .caches, reason: .unsafePath),
                    .init(stage: .preferences, reason: .io),
                ],
                remaining: [.caches]
            )

            try expect(
                SpeakerCopy.LocalDataErase.failureMessage(failure)
                    == SpeakerCopy.LocalDataErase.message(for: .unsafePath)
            )
            try expect(
                SpeakerCopy.LocalDataErase.failureMessage(
                    SpeakerDataErasureFailure(issues: [], remaining: [])
                ) == SpeakerCopy.LocalDataErase.incomplete
            )
        }

        run(
            "build info reads signing mode and version from one bundle reader",
            failures: &failures
        ) {
            let reader = SpeakerBuildInfoReader { key in
                switch key {
                case "SpeakerSigningMode": "developer-id"
                case "CFBundleShortVersionString": "1.2.3"
                case "CFBundleVersion": "45"
                case "SpeakerSourceRevision": "abc123"
                default: nil
                }
            }

            try expect(reader.signingMode == .developerID)
            try expect(
                reader.buildIdentity.displayText
                    == "版本 1.2.3（45）· 源码 abc123"
            )
            try expect(
                SpeakerBuildInfoReader { _ in nil }.signingMode == .unknown
            )
        }

        run("build signing mode exposes the permission identity boundary", failures: &failures) {
            let adHoc = SpeakerSigningMode(infoValue: "development-ad-hoc")
            try expect(adHoc == .developmentAdHoc)
            try expect(!adHoc.permissionIdentityIsStable)
            try expect(
                adHoc.permissionIdentityNotice?.contains("麦克风和辅助功能")
                    == true
            )
            try expect(adHoc.diagnosticValue == "development-ad-hoc")

            let local = SpeakerSigningMode(infoValue: "development-signed")
            try expect(!local.permissionIdentityIsStable)
            try expect(local.displayName == "本机具名签名")
            try expect(
                local.permissionIdentityNotice?.contains("同一个代码签名 identity")
                    == true
            )
            try expect(local.permitsLocalDeliverySmoke)

            let production = SpeakerSigningMode(infoValue: "developer-id")
            try expect(production.permissionIdentityIsStable)
            try expect(production.displayName == "正式发布签名")
            try expect(!production.permitsLocalDeliverySmoke)

            let unknown = SpeakerSigningMode(infoValue: nil)
            try expect(unknown == .unknown)
            try expect(unknown.permissionIdentityNotice != nil)
            try expect(!unknown.permissionIdentityIsStable)
            try expect(!unknown.permitsLocalDeliverySmoke)
        }

        run("build identity presents version, numeric build and source revision", failures: &failures) {
            let identity = SpeakerBuildIdentity(
                version: "1.2.3",
                build: "45",
                sourceRevision: "abc123def456-dirty"
            )

            try expect(
                identity.displayText
                    == "版本 1.2.3（45）· 源码 abc123def456-dirty"
            )
        }

        run(
            "software updates fail closed until the complete production identity exists",
            failures: &failures
        ) {
            let validKey = Data(repeating: 7, count: 32)
                .base64EncodedString()
            try expect(
                SoftwareUpdateConfiguration(
                    signingMode: .developmentSigned,
                    feedURLString:
                        "https://updates.example.com/appcast.xml",
                    publicEDKey: validKey
                ).availability
                    == .unavailable(.developmentBuild)
            )
            try expect(
                SoftwareUpdateState
                    .unavailable(.developmentBuild)
                    .unavailableMessage
                    == "检查更新仅用于正式发布版本。"
            )
            try expect(
                SoftwareUpdateConfiguration(
                    signingMode: .developerID,
                    feedURLString:
                        "http://updates.example.com/appcast.xml",
                    publicEDKey: validKey
                ).availability
                    == .unavailable(.invalidFeed)
            )
            try expect(
                SoftwareUpdateConfiguration(
                    signingMode: .developerID,
                    feedURLString:
                        "https://updates.example.com/appcast.xml",
                    publicEDKey: "REPLACE_WITH_PUBLIC_KEY"
                ).availability
                    == .unavailable(.invalidPublicKey)
            )
            try expect(
                SoftwareUpdateConfiguration(
                    signingMode: .developerID,
                    feedURLString:
                        "https://updates.example.com/appcast.xml",
                    publicEDKey: validKey
                ).availability == .ready
            )
        }

        run(
            "software update staging feed accepts only this repository immutable release",
            failures: &failures
        ) {
            let stableFeed =
                "https://github.com/simonwong/speaker/releases/latest/download/appcast.xml"
            let candidateFeed =
                "https://github.com/simonwong/speaker/releases/download/v1.2.3/appcast.xml"
            try expect(
                SoftwareUpdateFeedOverridePolicy.stagingFeedURL(
                    arguments: [
                        "SpeakerApp",
                        "--speaker-update-feed",
                        candidateFeed,
                    ],
                    stableFeedURLString: stableFeed
                ) == candidateFeed
            )
            for rejected in [
                "https://evil.example/releases/download/v1.2.3/appcast.xml",
                "https://github.com/simonwong/speaker/releases/latest/download/appcast.xml",
                "https://github.com/simonwong/speaker/releases/download/latest/appcast.xml",
                "https://github.com/simonwong/speaker/releases/download/v1.2/appcast.xml",
                "https://github.com:444/simonwong/speaker/releases/download/v1.2.3/appcast.xml",
                "https://user@github.com/simonwong/speaker/releases/download/v1.2.3/appcast.xml",
                "https://github.com/simonwong/speaker/releases/download/v01.2.3/appcast.xml",
                "https://github.com/simonwong/other/releases/download/v1.2.3/appcast.xml",
            ] {
                try expect(
                    SoftwareUpdateFeedOverridePolicy.stagingFeedURL(
                        arguments: [
                            "SpeakerApp",
                            "--speaker-update-feed",
                            rejected,
                        ],
                        stableFeedURLString: stableFeed
                    ) == nil
                )
            }
        }

        await runAsync(
            "software update feature exposes only semantic product state",
            failures: &failures
        ) {
            let driver = SoftwareUpdateDriverFake()
            let feature = SoftwareUpdateFeature(
                configuration: .init(
                    signingMode: .developerID,
                    feedURLString:
                        "https://updates.example.com/appcast.xml",
                    publicEDKey: Data(repeating: 9, count: 32)
                        .base64EncodedString()
                ),
                makeDriver: { driver }
            )

            try expect(feature.state.isAvailable)
            try expect(!feature.state.canCheckForUpdates)
            feature.start()
            try expect(feature.state.canCheckForUpdates)
            feature.checkForUpdates()
            feature.setAutomaticallyChecksForUpdates(true)

            try expect(driver.checkCount == 1)
            try expect(feature.state.automaticallyChecksForUpdates)
            try expect(driver.automaticChecksEnabled)
        }

        run(
            "delivery smoke launch arguments are accepted only for local development builds",
            failures: &failures
        ) {
            let reportURL = URL(
                fileURLWithPath: "/private/tmp/speaker-delivery-smoke-spec",
                isDirectory: true
            ).appendingPathComponent("report.txt")
            let arguments = [
                "SpeakerApp",
                "--speaker-delivery-smoke-pid",
                "42",
                "--speaker-delivery-smoke-report",
                reportURL.path,
            ]
            let local = DeliverySmokeLaunchRequest(
                arguments: arguments,
                signingMode: .developmentSigned
            )
            try expect(
                local?.processID == 42,
                "local development arguments were rejected"
            )
            try expect(
                local?.reportURL == reportURL.standardizedFileURL,
                "the accepted report path changed unexpectedly"
            )
            try expect(local?.captureOnly == false)
            try expect(local?.usesFrontmostTarget == false)
            try expect(local?.exercisesVoiceSession == false)
            try expect(local?.triggerURL == nil)
            let triggerURL = reportURL.deletingLastPathComponent()
                .appendingPathComponent("trigger.txt")
            let armedArguments = arguments + [
                "--speaker-delivery-smoke-trigger",
            ]
            let armed = DeliverySmokeLaunchRequest(
                arguments: armedArguments,
                signingMode: .developmentSigned
            )
            try expect(armed?.triggerURL == triggerURL.standardizedFileURL)
            let sessionArguments = arguments + [
                "--speaker-delivery-smoke-session",
            ]
            let session = DeliverySmokeLaunchRequest(
                arguments: sessionArguments,
                signingMode: .developmentSigned
            )
            try expect(session?.exercisesVoiceSession == true)
            let captureOnlyArguments = [
                "SpeakerApp",
                "--speaker-delivery-smoke-capture-only",
                "--speaker-delivery-smoke-report",
                reportURL.path,
            ]
            let captureOnly = DeliverySmokeLaunchRequest(
                arguments: captureOnlyArguments,
                signingMode: .developmentSigned
            )
            try expect(captureOnly?.processID == nil)
            try expect(captureOnly?.captureOnly == true)
            try expect(captureOnly?.usesFrontmostTarget == true)
            let frontmostDelivery = DeliverySmokeLaunchRequest(
                arguments: [
                    "SpeakerApp",
                    "--speaker-delivery-smoke-frontmost",
                    "--speaker-delivery-smoke-report",
                    reportURL.path,
                ],
                signingMode: .developmentSigned
            )
            try expect(frontmostDelivery?.processID == nil)
            try expect(frontmostDelivery?.captureOnly == false)
            try expect(frontmostDelivery?.usesFrontmostTarget == true)
            try expect(
                DeliverySmokeLaunchRequest(
                    arguments: arguments,
                    signingMode: .developerID
                ) == nil,
                "formal release accepted a hidden delivery mutation entry point"
            )
            var escapedArguments = arguments
            escapedArguments[4] = "/private/tmp/nested/report.txt"
            try expect(
                DeliverySmokeLaunchRequest(
                    arguments: escapedArguments,
                    signingMode: .developmentSigned
                ) == nil,
                "a nested temporary report path escaped the dedicated root"
            )
        }

        run("startup privacy cleanup removes only the obsolete installation identifier", failures: &failures) {
            let suiteName = "speaker-privacy-spec-\(UUID().uuidString)"
            let legacySuiteName = "speaker-legacy-privacy-spec-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw SpecFailure(message: "could not create isolated defaults")
            }
            guard let legacyDefaults = UserDefaults(suiteName: legacySuiteName) else {
                throw SpecFailure(message: "could not create legacy defaults")
            }
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                legacyDefaults.removePersistentDomain(forName: legacySuiteName)
            }
            defaults.set("legacy-stable-identifier", forKey: "localInstallationID")
            defaults.set(true, forKey: "hasCompletedOnboarding")
            legacyDefaults.set(
                "legacy-bundle-identifier",
                forKey: "localInstallationID"
            )

            LegacyPrivacyStateCleaner.removeObsoleteIdentifiers(
                from: defaults,
                legacyDefaults: legacyDefaults
            )

            try expect(defaults.object(forKey: "localInstallationID") == nil)
            try expect(
                legacyDefaults.object(forKey: "localInstallationID") == nil
            )
            try expect(defaults.bool(forKey: "hasCompletedOnboarding"))
        }

        await runAsync(
            "activating another app refreshes permission and restores the shortcut",
            failures: &failures
        ) {
            let events = PassthroughSubject<Void, Never>()
            let access = ScenarioPermissionAccess(
                snapshot: .init(
                    accessibility: .denied,
                    microphone: .granted
                )
            )
            let permissions = PermissionModel(access: access)
            let functionMonitor = FunctionMonitorFake()
            let shortcut = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: CustomMonitorFake(),
                accessibilityGranted: {
                    permissions.snapshot.accessibility == .granted
                },
                persistPreference: { _ in }
            )
            shortcut.restore(.functionKey)
            let coordinator = PermissionRefreshCoordinator(
                permissions: permissions,
                shortcut: shortcut
            )
            coordinator.start(observing: events.eraseToAnyPublisher())

            try expect(
                shortcut.activation
                    == .waitingForAccessibility(.functionKey)
            )
            try expect(!functionMonitor.isRunning)

            access.snapshot = .init(
                accessibility: .granted,
                microphone: .granted
            )
            events.send(())

            let restored = await waitUntil {
                permissions.snapshot.accessibility == .granted
                    && functionMonitor.isRunning
            }
            try expect(restored)
            try expect(shortcut.activation == .active(.functionKey))
        }

        run(
            "runtime permission revocation stops shortcuts without repeating VoiceOver warnings",
            failures: &failures
        ) {
            let access = ScenarioPermissionAccess(
                snapshot: .init(
                    accessibility: .granted,
                    microphone: .granted
                )
            )
            let permissions = PermissionModel(access: access)
            let functionMonitor = FunctionMonitorFake()
            let shortcut = VoiceShortcutFeature(
                functionKeyMonitor: functionMonitor,
                customShortcutMonitor: CustomMonitorFake(),
                accessibilityGranted: {
                    permissions.snapshot.accessibility == .granted
                },
                persistPreference: { _ in }
            )
            var announcements: [String] = []
            let announcementsCoordinator = ShortcutAnnouncementCoordinator(
                feature: shortcut,
                announce: { announcements.append($0) }
            )
            let permissionCoordinator = PermissionRefreshCoordinator(
                permissions: permissions,
                shortcut: shortcut
            )

            shortcut.restore(.functionKey)
            try expect(functionMonitor.startCount == 1)
            try expect(functionMonitor.isRunning)

            access.snapshot = .init(
                accessibility: .denied,
                microphone: .granted
            )
            permissionCoordinator.refreshNow()
            permissionCoordinator.refreshNow()
            permissionCoordinator.refreshNow()

            try expect(!functionMonitor.isRunning)
            try expect(shortcut.activation == .waitingForAccessibility(.functionKey))
            try expect(
                announcements.filter {
                    $0 == "需要辅助功能权限；授权后，已选择的快捷键会自动生效。"
                }.count == 1
            )

            access.snapshot = .init(
                accessibility: .granted,
                microphone: .granted
            )
            permissionCoordinator.refreshNow()
            permissionCoordinator.refreshNow()

            try expect(functionMonitor.isRunning)
            try expect(functionMonitor.startCount == 2)
            try expect(
                announcements.filter { $0 == "Fn 快捷键已启用" }.count == 2
            )
            withExtendedLifetime(announcementsCoordinator) {}
        }

        run(
            "voice input notices are localized by the app presentation layer",
            failures: &failures
        ) {
            try expect(VoiceInputNotice.copied.userMessage == "文字已复制")
            try expect(
                VoiceInputNotice.refinementFellBack(.network).userMessage
                    == "DeepSeek 请求发生网络错误，已使用豆包结果。"
            )
            try expect(
                VoiceInputNotice.refinementFellBack(.authentication).userMessage
                    == "DeepSeek 鉴权失败，已使用豆包结果。"
            )
            try expect(
                VoiceInputNotice.refinementFellBack(.rateLimited).userMessage
                    == "DeepSeek 请求被限流，已使用豆包结果。"
            )
            try expect(
                VoiceInputNotice.refinementFellBack(.unexpected).userMessage
                    == "DeepSeek 整理失败，已使用豆包结果。"
            )
            try expect(
                VoiceInputNotice.persistenceFailure(.writeFailed(reason: "磁盘不可用"))
                    .userMessage == "会话历史写入失败：磁盘不可用"
            )
            try expect(
                VoiceInputNotice.persistenceFailure(
                    .privacyMigrationFailed(reason: .databaseUnavailable)
                ).userMessage == "旧版会话历史的隐私清理失败：本地历史数据库不可用。"
            )
            try expect(
                VoiceInputNotice.persistenceFailure(.corruptedRecordsSkipped(count: 2))
                    .userMessage == "有 2 条本地历史记录已损坏，其他记录仍可使用。"
            )
        }

        run(
            "voice input failures are localized by the app presentation layer",
            failures: &failures
        ) {
            let denied = VoiceInputFailure.microphonePermissionDenied
            try expect(denied.userTitle == "麦克风权限未开启")
            try expect(denied.userGuidance == "请在系统设置中允许 Speaker 使用麦克风。")
            try expect(denied.userIcon == "mic.slash.fill")
            try expect(denied.needsSettings)

            let deviceFailure = VoiceInputFailure.recordingFailed
            try expect(deviceFailure.userTitle == "录音没有完成")
            try expect(!deviceFailure.userGuidance.contains("权限"))
            try expect(deviceFailure.userIcon == "mic.slash.fill")
            try expect(!deviceFailure.needsSettings)

            let recordingLimit = VoiceInputFailure.recordingLimitReached
            try expect(recordingLimit.userTitle == "录音已达到 10 分钟上限")
            try expect(
                recordingLimit.userGuidance
                    == "为保护隐私并避免持续计费，本次语音输入已停止。请重新开始。"
            )
            try expect(recordingLimit.userIcon == "timer")
            try expect(!recordingLimit.needsSettings)
        }

        run(
            "missing Accessibility permission is not presented as an unsupported editor",
            failures: &failures
        ) {
            try expect(
                PendingCopyReason.accessibilityPermissionMissing.userTitle
                    == "辅助功能权限不可用"
            )
        }

        run(
            "diagnostic report renders audio capture environment and unknown fallbacks",
            failures: &failures
        ) {
            func report(
                _ environment: AudioCaptureEnvironmentSnapshot?
            ) -> String {
                SpeakerDiagnosticReport.make(from: .init(
                    version: "1.2.3",
                    build: "45",
                    sourceRevision: "abc123",
                    bundleIdentifier: "com.example.speaker",
                    signingMode: "development",
                    operatingSystem: "macOS test",
                    credentialStorage: "keychain",
                    accessibility: .granted,
                    microphone: .granted,
                    shortcut: "Fn",
                    activity: "idle",
                    refinement: "defaultSmooth",
                    doubaoConfigured: true,
                    doubaoResource: "volc.bigasr.sauc.duration",
                    deepSeekConfigured: false,
                    deepSeekVerified: false,
                    historyRecordCount: 0,
                    historyPersistence: "none",
                    audioCaptureEnvironment: environment,
                    latestRecord: nil
                ))
            }

            let current = report(.init(
                voiceProcessingRequested: true,
                voiceProcessingActive: false,
                voiceProcessingEnableFailure: .audioSystem,
                automaticGainControlEnabled: false,
                preferredMicrophoneMode: .voiceIsolation,
                activeMicrophoneMode: .standard
            ))
            try expect(current.contains("audioCaptureVoiceProcessingRequested: true"))
            try expect(current.contains("audioCaptureVoiceProcessingActive: false"))
            try expect(current.contains("audioCaptureVoiceProcessingEnableFailure: audioSystem"))
            try expect(current.contains("audioCaptureAGCEnabled: false"))
            try expect(current.contains("audioCapturePreferredMicrophoneMode: voiceIsolation"))
            try expect(current.contains("audioCaptureActiveMicrophoneMode: standard"))

            let unavailable = report(nil)
            for key in [
                "audioCaptureVoiceProcessingRequested",
                "audioCaptureVoiceProcessingActive",
                "audioCaptureVoiceProcessingEnableFailure",
                "audioCaptureAGCEnabled",
                "audioCapturePreferredMicrophoneMode",
                "audioCaptureActiveMicrophoneMode",
            ] {
                try expect(unavailable.contains("\(key): unknown"))
            }
        }

        run(
            "diagnostic report includes latest structured failure evidence without user content",
            failures: &failures
        ) {
            let record = VoiceInputHistoryRecord(
                sessionID: VoiceInputSessionID(),
                startedAt: Date(),
                applicationName: "Private Client App",
                transcription: "SECRET TRANSCRIPT",
                finalText: "SECRET FINAL TEXT",
                transcriptionProvider: "doubao",
                providerRequestID: "request-safe-id",
                providerErrorCode: "provider-safe-code",
                providerOperation: "transcription",
                providerStatusCode: "503",
                providerMessage: "SECRET PROVIDER MESSAGE",
                deliveryDiagnosticCode:
                    "pasteReceipt.unconfirmed",
                deepSeekText: "SECRET DEEPSEEK TEXT",
                deepSeekRequestID: "deepseek-safe-id",
                refinementModeName: "SECRET CUSTOM NAME",
                refinementPrompt: "SECRET PROMPT",
                refinementStatus: "fellBack",
                refinementFailureCode: "server",
                refinementFailureStatusCode: "500",
                refinementFailureMessage: "SECRET REFINEMENT MESSAGE",
                cancelledAtStage: "doubao",
                dictionarySnapshotEntries: [
                    RecordedDictionaryEntry(word: "SECRET TERM"),
                ],
                durationMilliseconds: 1_234,
                stageDurationsMilliseconds: [
                    "doubao": 900,
                    "targetCapture": 20,
                ],
                outcome: .failed(
                    VoiceInputSessionID(),
                    .providerUnavailable
                )
            )
            let report = SpeakerDiagnosticReport.make(from: .init(
                version: "1.2.3",
                build: "45",
                sourceRevision: "abc123def456-dirty",
                bundleIdentifier: "com.example.speaker",
                signingMode: "developer-id",
                operatingSystem: "macOS test",
                credentialStorage: "keychain",
                accessibility: .granted,
                microphone: .granted,
                shortcut: "Fn",
                activity: "failed.providerUnavailable",
                refinement: "custom",
                doubaoConfigured: true,
                doubaoResource: "volc.bigasr.sauc.duration",
                deepSeekConfigured: true,
                deepSeekVerified: false,
                historyRecordCount: 7,
                historyPersistence: "none",
                activeProvider: .init(
                    provider: "doubao",
                    operation: .voiceInput,
                    phase: .awaitingFinal,
                    requestID: "active-safe-id",
                    providerRequestID: "active-server-safe-id",
                    httpStatusCode: 101
                ),
                latestRecord: record
            ))

            try expect(report.contains("activeProviderPhase: awaitingFinal"))
            try expect(
                report.contains("sourceRevision: abc123def456-dirty")
            )
            try expect(report.contains("activeProviderRequestID: active-safe-id"))
            try expect(
                report.contains(
                    "activeProviderServerRequestID: active-server-safe-id"
                )
            )
            try expect(report.contains("latestProviderRequestID: request-safe-id"))
            try expect(report.contains("latestProviderCode: provider-safe-code"))
            try expect(
                report.contains(
                    "latestDeliveryDiagnostic: pasteReceipt.unconfirmed"
                )
            )
            try expect(report.contains("latestDeepSeekRequestID: deepseek-safe-id"))
            try expect(report.contains("latestSessionStages: doubao=900,targetCapture=20"))
            try expect(report.contains("latestCancelledAtStage: doubao"))
            for secret in [
                "SECRET TRANSCRIPT",
                "SECRET FINAL TEXT",
                "SECRET PROVIDER MESSAGE",
                "SECRET DEEPSEEK TEXT",
                "SECRET CUSTOM NAME",
                "SECRET PROMPT",
                "SECRET REFINEMENT MESSAGE",
                "SECRET TERM",
                "Private Client App",
            ] {
                try expect(
                    !report.contains(secret),
                    "diagnostic report leaked \(secret)"
                )
            }
        }

        await runAsync(
            "global interaction router forwards idle shortcut sequences to voice input",
            failures: &failures
        ) {
            let voice = RouterVoiceRecorder()
            let router = GlobalVoiceInteractionRouter(
                voiceTarget: voice.target
            )

            router.shortcutTarget.receive(.pressed)
            router.shortcutTarget.receive(.released)
            router.shortcutTarget.receive(.cancel)
            router.shortcutTarget.receive(.monitorRecovered)

            try expect(
                voice.triggers == [
                    .pressed,
                    .released,
                    .cancel,
                    .monitorRecovered,
                ]
            )
        }

        await runAsync(
            "exclusive shortcut confirmation consumes its complete press release sequence",
            failures: &failures
        ) {
            let voice = RouterVoiceRecorder()
            let router = GlobalVoiceInteractionRouter(
                voiceTarget: voice.target
            )
            var confirmations = 0
            router.beginExclusiveInteraction(
                confirm: {
                    confirmations += 1
                    return true
                },
                cancel: {}
            )

            router.shortcutTarget.receive(.pressed)
            let confirmed = await waitUntil { confirmations == 1 }
            router.shortcutTarget.receive(.released)

            try expect(confirmed)
            try expect(voice.triggers.isEmpty)
            try expect(!router.hasExclusiveInteraction)
        }

        await runAsync(
            "rejected exclusive confirmation stays armed and can be retried",
            failures: &failures
        ) {
            let voice = RouterVoiceRecorder()
            let router = GlobalVoiceInteractionRouter(
                voiceTarget: voice.target
            )
            var attempts = 0
            router.beginExclusiveInteraction(
                confirm: {
                    attempts += 1
                    return attempts == 2
                },
                cancel: {}
            )

            router.shortcutTarget.receive(.pressed)
            _ = await waitUntil { attempts == 1 }
            router.shortcutTarget.receive(.released)
            try expect(router.hasExclusiveInteraction)

            router.shortcutTarget.receive(.pressed)
            let accepted = await waitUntil { attempts == 2 }
            router.shortcutTarget.receive(.released)

            try expect(accepted)
            try expect(!router.hasExclusiveInteraction)
            try expect(voice.triggers.isEmpty)
        }

        await runAsync(
            "exclusive Escape cancels once and consumes a pending shortcut release",
            failures: &failures
        ) {
            let voice = RouterVoiceRecorder()
            let router = GlobalVoiceInteractionRouter(
                voiceTarget: voice.target
            )
            var cancellationCount = 0
            router.beginExclusiveInteraction(
                confirm: {
                    try? await Task.sleep(for: .milliseconds(40))
                    return true
                },
                cancel: {
                    cancellationCount += 1
                }
            )

            router.shortcutTarget.receive(.pressed)
            try expect(router.shortcutTarget.shouldConsumeEscape())
            router.shortcutTarget.receive(.cancel)
            router.shortcutTarget.receive(.released)
            let cancelled = await waitUntil { cancellationCount == 1 }

            try expect(cancelled)
            try expect(!router.hasExclusiveInteraction)
            try expect(voice.triggers.isEmpty)
        }

        run(
            "exclusive interaction cannot displace active voice input",
            failures: &failures
        ) {
            let voice = RouterVoiceRecorder(escapeActive: true)
            let router = GlobalVoiceInteractionRouter(
                voiceTarget: voice.target
            )

            let began = router.beginExclusiveInteraction(
                confirm: { true },
                cancel: {}
            )

            try expect(!began)
            try expect(!router.hasExclusiveInteraction)
            try expect(router.shortcutTarget.shouldConsumeEscape())
        }

        run("onboarding fits the visible screen and keeps a useful resizable minimum", failures: &failures) {
            let largeScreen = OnboardingWindowLayout(
                visibleFrame: .init(x: 0, y: 0, width: 1_440, height: 900)
            )
            try expect(
                largeScreen.initialSize
                    == OnboardingWindowLayout.preferredSize
            )

            let compactScreen = OnboardingWindowLayout(
                visibleFrame: .init(x: 0, y: 0, width: 580, height: 540)
            )
            try expect(
                compactScreen.initialSize.width
                    <= compactScreen.availableSize.width
            )
            try expect(
                compactScreen.initialSize.height
                    <= compactScreen.availableSize.height
            )
            try expect(
                compactScreen.effectiveMinimumSize.width
                    <= compactScreen.initialSize.width
            )
            try expect(
                compactScreen.effectiveMinimumSize.height
                    <= compactScreen.initialSize.height
            )

            let tinyScreen = OnboardingWindowLayout(
                visibleFrame: .init(x: 0, y: 0, width: 480, height: 430)
            )
            try expect(tinyScreen.initialSize.width == 416)
            try expect(tinyScreen.initialSize.height == 366)
            try expect(
                tinyScreen.effectiveMinimumSize == tinyScreen.initialSize
            )
        }

        run("voice HUD increases every low-emphasis contrast token", failures: &failures) {
            let standard = VoiceInputHUDContrastPalette(increased: false)
            let increased = VoiceInputHUDContrastPalette(increased: true)

            try expect(
                increased.darkBorderOpacity > standard.darkBorderOpacity
            )
            try expect(
                increased.darkBorderLineWidth > standard.darkBorderLineWidth
            )
            try expect(
                increased.darkDividerOpacity > standard.darkDividerOpacity
            )
            try expect(
                increased.darkControlBackgroundOpacity
                    > standard.darkControlBackgroundOpacity
            )
            try expect(
                increased.darkControlForegroundOpacity
                    > standard.darkControlForegroundOpacity
            )
            try expect(
                increased.errorIconOpacity > standard.errorIconOpacity
            )
            try expect(standard.glassTintOpacity < 0.2)
            try expect(standard.fallbackTintTopOpacity < 0.2)
            try expect(standard.fallbackTintBottomOpacity < 0.25)
        }

        run("glass surfaces honor native availability and Reduce Transparency", failures: &failures) {
            try expect(
                AdaptiveGlassSurfacePolicy.resolve(
                    reduceTransparency: false,
                    supportsLiquidGlass: true
                ) == .liquidGlass
            )
            try expect(
                AdaptiveGlassSurfacePolicy.resolve(
                    reduceTransparency: false,
                    supportsLiquidGlass: false
                ) == .systemMaterial
            )
            try expect(
                AdaptiveGlassSurfacePolicy.resolve(
                    reduceTransparency: true,
                    supportsLiquidGlass: true
                ) == .opaque
            )
            try expect(
                AdaptiveGlassSurfacePolicy.resolve(
                    reduceTransparency: true,
                    supportsLiquidGlass: false
                ) == .opaque
            )
        }

        run("onboarding remains ready after an unchanged credential refresh", failures: &failures) {
            let refreshedStatus = DoubaoConnectionStatus.success("verified")
                .afterCredentialRefresh(keyExists: true)
            let presentation = OnboardingPresentation(
                permissions: .init(
                    accessibility: .granted,
                    microphone: .granted
                ),
                doubaoStatus: refreshedStatus,
                hasStoredDoubaoKey: true
            )

            try expect(presentation.isReady)
        }

        run("login item awaiting approval stays enabled and exposes recovery", failures: &failures) {
            let presentation = LoginItemPresentation(
                desiredEnabled: true,
                serviceState: .requiresApproval
            )

            try expect(presentation.isEnabled)
            try expect(
                presentation.registrationState == .awaitingApproval
            )
            try expect(presentation.showsSystemSettingsButton)
        }

        run("missing login item registration remains explicitly recoverable", failures: &failures) {
            let presentation = LoginItemPresentation(
                desiredEnabled: true,
                serviceState: .notRegistered
            )

            try expect(!presentation.isEnabled)
            try expect(
                presentation.registrationState == .registrationMissing
            )
            try expect(
                presentation.notice?.contains("打开开关") == true
            )
        }

        run("unavailable login item never presents an effective enabled state", failures: &failures) {
            let presentation = LoginItemPresentation(
                desiredEnabled: true,
                serviceState: .notFound
            )

            try expect(!presentation.isEnabled)
            try expect(presentation.registrationState == .unavailable)
            try expect(presentation.notice != nil)
        }

        await runAsync("login item model respects a system-disabled registration until the user acts", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-login-item-restore-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = ScenarioLoginItemService(state: .notRegistered)
            let model = LoginItemSettingsModel(
                service: service,
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")
                )
            )

            await model.restore(desiredEnabled: true)

            try expect(!model.isEnabled)
            try expect(service.registerCount == 0)
            try expect(model.notice?.contains("打开开关") == true)
        }

        await runAsync("login item model persists an explicit re-enable", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-login-item-enable-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let settingsStore = VersionedLocalAppSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json")
            )
            let service = ScenarioLoginItemService(state: .notRegistered)
            let model = LoginItemSettingsModel(
                service: service,
                settingsStore: settingsStore
            )
            await model.restore(desiredEnabled: true)

            await model.setEnabled(true)

            let persistedSettings = await settingsStore.load().settings
            try expect(model.isEnabled)
            try expect(service.registerCount == 1)
            try expect(model.notice == nil)
            try expect(persistedSettings.launchAtLogin)
        }

        await runAsync("login item model rolls the system registration back when persistence fails", failures: &failures) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-login-item-failure-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let invalidParent = root.appendingPathComponent("not-a-directory")
            try Data("occupied".utf8).write(to: invalidParent)
            let service = ScenarioLoginItemService(state: .notRegistered)
            let model = LoginItemSettingsModel(
                service: service,
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: invalidParent.appendingPathComponent("settings.json")
                )
            )
            await model.restore(desiredEnabled: false)

            await model.setEnabled(true)

            try expect(!model.isEnabled)
            try expect(service.registerCount == 1)
            try expect(service.unregisterCount == 1)
            try expect(model.notice?.contains("无法更新登录项") == true)
        }

        run("DeepSeek modes stay inactive until a key is available", failures: &failures) {
            let unavailable = RefinementActivationPlan(
                desiredMode: .fullRewrite(),
                hasStoredKey: false
            )
            try expect(unavailable.activeMode == .defaultSmooth)
            try expect(unavailable.deferredMode == .fullRewrite())

            let available = RefinementActivationPlan(
                desiredMode: .fullRewrite(),
                hasStoredKey: true
            )
            try expect(available.activeMode == .fullRewrite())
            try expect(available.deferredMode == nil)
        }

        run("only DeepSeek built-in modes expose a prompt editor", failures: &failures) {
            try expect(
                RefinementChoice(mode: .conciseCleanup()) == .conciseCleanup
            )
            try expect(
                RefinementChoice(mode: .fullRewrite()) == .fullRewrite
            )
            try expect(
                RefinementChoice.conciseCleanup.builtInMode == .conciseCleanup
            )
            try expect(
                RefinementChoice.fullRewrite.builtInMode == .fullRewrite
            )
            try expect(
                RefinementPromptPresentation.editorState(for: .defaultSmooth) == nil
            )
            try expect(
                RefinementPromptPresentation.editorState(
                    for: .custom(name: "邮件", prompt: "整理成邮件")
                ) == nil
            )

            let concise = RefinementPromptPresentation.editorState(for: .conciseCleanup())
            let builtInConcise = TextRefinementMode.conciseCleanup().deepSeekInstruction
            try expect(concise?.defaultPrompt == builtInConcise)
            try expect(concise?.effectivePrompt == builtInConcise)
            try expect(concise?.isOverridden == false)

            let overridden = RefinementPromptPresentation.editorState(
                for: .fullRewrite(promptOverride: "自定义提示词")
            )
            try expect(
                overridden?.defaultPrompt
                    == TextRefinementMode.fullRewrite().deepSeekInstruction
            )
            try expect(overridden?.effectivePrompt == "自定义提示词")
            try expect(overridden?.isOverridden == true)
            try expect(overridden?.defaultPrompt != overridden?.effectivePrompt)
        }

        run("refinement prompt editor gates save and restore on the draft", failures: &failures) {
            let state = RefinementPromptPresentation.editorState(for: .conciseCleanup())
            try expect(state != nil)
            guard let state else { return }

            try expect(!state.canRestoreDefault(draft: state.defaultPrompt))
            try expect(state.canRestoreDefault(draft: "改成别的"))

            // Nothing to save while the draft matches the prompt in effect.
            try expect(!state.canSave(draft: state.effectivePrompt))
            try expect(!state.canSave(draft: "   "))
            try expect(
                !state.canSave(
                    draft: String(
                        repeating: "x",
                        count: TextRefinementMode.maximumCustomPromptLength + 1
                    )
                )
            )
            try expect(state.canSave(draft: "新提示词"))
        }

        await runAsync(
            "dictionary settings exposes provider capacity and saves a hinted Entry",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-capacity-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = VersionedJSONPersonalDictionaryStore(
                fileURL: directory.appendingPathComponent("dictionary.json")
            )
            let initialEntries = (1...100).map {
                DictionaryEntry(word: "Entry \($0)")
            }
            try await store.save(PersonalDictionary(entries: initialEntries))
            let configuration = VoiceInputConfigurationController()
            let model = DictionarySettingsModel(
                store: store,
                configuration: configuration
            )

            await model.load()
            model.draftWord = "1234567890"
            await model.add()

            try expect(model.entries.count == 101)
            try expect(model.sentEntryCount == 100)
            try expect(model.sendingCountText == "100/100 条")
            try expect(model.omittedEntryIDs == Set([model.entries[100].id]))
            try expect(model.qualityHint(for: model.entries[100]) == .tooLong)
            let persisted = try await store.load().dictionary
            try expect(persisted.entries.last?.word == "1234567890")
        }

        await runAsync(
            "dictionary settings reports a preserved corrupt dictionary and keeps saving",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-dictionary-recovery-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent("personal-dictionary.json")
            try Data("not-json".utf8).write(to: fileURL)
            let store = VersionedJSONPersonalDictionaryStore(fileURL: fileURL)
            let model = DictionarySettingsModel(
                store: store,
                configuration: VoiceInputConfigurationController()
            )

            await model.load()

            guard let recovery = model.recovery else {
                throw SpecFailure(message: "corrupt dictionary produced no recovery")
            }
            try expect(model.entries.isEmpty)
            try expect(
                model.notice == DictionarySettingsModel.recoveryNotice(for: recovery)
            )
            try expect(
                model.notice?.contains(recovery.backupURL.lastPathComponent) == true,
                "notice does not name the preserved file"
            )
            let added = await model.add(word: "Speaker")
            try expect(added, "saving after recovery was refused")
            try expect(model.notice == nil)
            let persisted = try await store.load()
            try expect(persisted.dictionary.entries.map(\.word) == ["Speaker"])
            try expect(persisted.recovery == nil)
            try expect(FileManager.default.fileExists(atPath: recovery.backupURL.path))
        }

        await runAsync(
            "history adds an edited candidate through the shared Personal Dictionary model",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-history-dictionary-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = VersionedJSONPersonalDictionaryStore(
                fileURL: directory.appendingPathComponent("dictionary.json")
            )
            let configuration = VoiceInputConfigurationController()
            let dictionary = DictionarySettingsModel(
                store: store,
                configuration: configuration
            )
            await dictionary.load()
            let sessionID = VoiceInputSessionID()
            let record = VoiceInputHistoryRecord(
                sessionID: sessionID,
                startedAt: Date(timeIntervalSince1970: 1),
                applicationName: nil,
                transcription: "Use SpeakerBeta today",
                finalText: "Use SpeakerBeta today",
                outcome: .pendingCopy(
                    sessionID,
                    text: "Use SpeakerBeta today",
                    reason: .missingTarget
                )
            )
            let retainedRecord = record
            let composer = HistoryDictionaryEntryComposerState(
                transcription: record.transcription
            )
            try expect(composer?.candidates.contains("SpeakerBeta") == true)

            let added = await HistoryDictionaryEntryAddition.perform(
                word: "  SpeakerBetaFixed  ",
                using: dictionary
            )

            try expect(added.kind == .success)
            try expect(record == retainedRecord)
            let persisted = try await store.load().dictionary
            try expect(persisted.entries.map(\.word) == ["SpeakerBetaFixed"])
            let configured = await configuration.currentDictionary()
            try expect(configured.entries.map(\.word) == ["SpeakerBetaFixed"])

            let duplicate = await HistoryDictionaryEntryAddition.perform(
                word: "speakerbetafixed",
                using: dictionary
            )
            try expect(duplicate.kind == .warning)
            try expect(duplicate.message.contains("已存在"))
            let afterDuplicate = try await store.load().dictionary
            try expect(afterDuplicate.entries.count == 1)

            let noTextSessionID = VoiceInputSessionID()
            let noTextRecord = VoiceInputHistoryRecord(
                sessionID: noTextSessionID,
                startedAt: Date(timeIntervalSince1970: 2),
                applicationName: nil,
                transcription: nil,
                finalText: nil,
                outcome: .cancelled(noTextSessionID)
            )
            try expect(
                HistoryDictionaryEntryComposerState(
                    transcription: noTextRecord.transcription
                ) == nil
            )
            try expect(
                HistoryDictionaryEntryComposerState(transcription: "  \n") == nil
            )
        }

        await runAsync(
            "built-in prompts stay inspectable and editable without a DeepSeek key",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-refinement-prompt-no-key-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let settingsStore = VersionedLocalAppSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json")
            )
            let configuration = VoiceInputConfigurationController()
            let model = RefinementSettingsModel(
                service: CredentialedDeepSeekTextRefiner(
                    credentials: ScenarioProviderCredentialStore()
                ),
                configuration: configuration,
                settingsStore: settingsStore
            )

            await model.load()
            await model.select(.conciseCleanup)

            try expect(model.mode == .defaultSmooth)
            try expect(model.promptEditorState?.title == "精简清理")
            try expect(
                model.promptDraft
                    == TextRefinementMode.conciseCleanup().deepSeekInstruction
            )

            model.promptDraft = "无 Key 时保存的精简规则"
            await model.savePromptOverride()

            let persisted = await settingsStore.load().settings
            try expect(
                persisted.refinementPromptOverrides.conciseCleanup
                    == "无 Key 时保存的精简规则"
            )
            let currentMode = await configuration.currentRefinementMode()
            try expect(currentMode == .defaultSmooth)
        }

        await runAsync(
            "saving a key restores the deferred mode and its current prompt draft",
            failures: &failures
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-refinement-prompt-deferred-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let settingsStore = VersionedLocalAppSettingsStore(
                fileURL: directory.appendingPathComponent("settings.json")
            )
            try await settingsStore.updateRefinement(.fullRewrite)
            try await settingsStore.updateRefinementPromptOverride(
                "初始完整重写规则",
                for: .fullRewrite()
            )
            let credentials = ScenarioProviderCredentialStore()
            let configuration = VoiceInputConfigurationController()
            let model = RefinementSettingsModel(
                service: CredentialedDeepSeekTextRefiner(
                    credentials: credentials
                ),
                configuration: configuration,
                settingsStore: settingsStore
            )

            await model.load()
            try expect(model.mode == .defaultSmooth)
            try expect(model.promptEditorState?.title == "完整重写")
            try expect(model.promptDraft == "初始完整重写规则")

            model.promptDraft = "保存 Key 前更新的完整重写规则"
            await model.savePromptOverride()
            model.apiKeyDraft = "scenario-deepseek-key"
            await model.saveAPIKey()

            let expectedMode = TextRefinementMode.fullRewrite(
                promptOverride: "保存 Key 前更新的完整重写规则"
            )
            try expect(model.mode == expectedMode)
            try expect(model.promptDraft == "保存 Key 前更新的完整重写规则")
            let currentMode = await configuration.currentRefinementMode()
            try expect(currentMode == expectedMode)
        }

        await runAsync("Doubao connection result cannot revive a deleted key", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-doubao-settings-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = ScenarioDoubaoSettingsService(hasKey: true)
            let model = DoubaoSettingsModel(
                service: service,
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")
                )
            )
            await model.refresh()

            model.checkConnection()
            let checking = await waitUntil {
                if case .checking = model.status { true } else { false }
            }
            var checkStarted = false
            for _ in 0..<50 {
                if await service.isCheckPending {
                    checkStarted = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            await model.delete()
            await service.finishCheck(.success("stale-request"))
            try? await Task.sleep(for: .milliseconds(30))

            try expect(checking)
            try expect(checkStarted)
            try expect(!model.hasStoredKey)
            try expect(model.status == .unconfigured)
        }

        await runAsync("Doubao connection result is bound to the checked resource", failures: &failures) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "speaker-doubao-resource-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = ScenarioDoubaoSettingsService(hasKey: true)
            let model = DoubaoSettingsModel(
                service: service,
                settingsStore: VersionedLocalAppSettingsStore(
                    fileURL: directory.appendingPathComponent("settings.json")
                )
            )
            await model.refresh()

            model.checkConnection()
            for _ in 0..<50 {
                if await service.isCheckPending { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            await model.selectResource(.model1Concurrent)
            await service.finishCheck(.success("old-resource-request"))
            try? await Task.sleep(for: .milliseconds(30))

            try expect(model.resource == .model1Concurrent)
            try expect(model.status == .configured)
        }

        await runAsync(
            "refinement settings save a custom mode through injected fakes",
            failures: &failures
        ) {
            let settingsStore = ScenarioAppSettingsStore()
            let configuration = VoiceInputConfigurationController()
            let model = RefinementSettingsModel(
                service: ScenarioDeepSeekSettingsService(hasKey: true),
                configuration: configuration,
                settingsStore: settingsStore
            )

            await model.load()
            try expect(model.hasStoredKey)

            model.customName = "工作邮件"
            model.customPrompt = ""
            try expect(!model.canSaveCustomMode)

            model.customPrompt = "整理成简洁的工作邮件。"
            try expect(model.canSaveCustomMode)

            await model.saveCustomMode()

            let expectedMode = TextRefinementMode.custom(
                name: "工作邮件",
                prompt: "整理成简洁的工作邮件。"
            )
            try expect(model.mode == expectedMode)
            let saved = await settingsStore.settings
            try expect(
                saved.savedCustomRefinement == RefinementPreference(mode: expectedMode)
            )
            try expect(saved.refinement == RefinementPreference(mode: expectedMode))
            let currentMode = await configuration.currentRefinementMode()
            try expect(currentMode == expectedMode)
        }

        await runAsync(
            "custom mode cannot be saved without a stored DeepSeek key",
            failures: &failures
        ) {
            let model = RefinementSettingsModel(
                service: ScenarioDeepSeekSettingsService(hasKey: false),
                configuration: VoiceInputConfigurationController(),
                settingsStore: ScenarioAppSettingsStore()
            )

            await model.load()
            model.customName = "工作邮件"
            model.customPrompt = "整理成简洁的工作邮件。"

            try expect(!model.hasStoredKey)
            try expect(!model.canSaveCustomMode)
        }

        await runAsync(
            "dictionary settings persist through the injected dictionary store",
            failures: &failures
        ) {
            let store = ScenarioPersonalDictionaryStore(words: ["Speaker"])
            let configuration = VoiceInputConfigurationController()
            let model = DictionarySettingsModel(
                store: store,
                configuration: configuration
            )

            await model.load()
            try expect(model.entries.map(\.word) == ["Speaker"])

            model.draftWord = "豆包"
            let added = await model.add()
            try expect(added)

            try expect(model.entries.map(\.word) == ["Speaker", "豆包"])
            let persisted = await store.storedWords
            try expect(persisted == ["Speaker", "豆包"])
            let configured = await configuration.currentDictionary()
            try expect(configured.entries.map(\.word) == ["Speaker", "豆包"])
        }

        await runAsync(
            "history retention saves the policy and reports an unfinished cleanup",
            failures: &failures
        ) {
            let history = ScenarioHistoryRetentionStore(appliesRetention: false)
            let settingsStore = ScenarioAppSettingsStore()
            let model = HistoryRetentionSettingsModel(
                store: history,
                settingsStore: settingsStore
            )

            await model.refresh()
            try expect(model.retentionPolicy == .forever)

            await model.setRetentionPolicy(.thirtyDays)

            try expect(model.retentionPolicy == .thirtyDays)
            let saved = await settingsStore.settings
            try expect(saved.historyRetention == .thirtyDays)
            let appliedPolicies = await history.appliedPolicies
            try expect(appliedPolicies == [.thirtyDays])
            try expect(model.notice != nil)
        }

        run("recording takes priority over the menu bar permission warning", failures: &failures) {
            let activity = VoiceInputActivity.recording(VoiceInputSessionID())
            let permissions = PermissionSnapshot(
                accessibility: .denied,
                microphone: .denied
            )

            try expect(
                MenuBarPresentation.iconState(
                    isRecording: activity.isRecording,
                    permissions: permissions
                ) == .recording
            )
        }

        run("menu bar reflects permission state outside recording", failures: &failures) {
            let granted = PermissionSnapshot(
                accessibility: .granted,
                microphone: .granted
            )
            let missing = PermissionSnapshot(
                accessibility: .granted,
                microphone: .denied
            )

            try expect(
                MenuBarPresentation.iconState(
                    isRecording: false,
                    permissions: granted
                ) == .ready
            )
            try expect(
                MenuBarPresentation.iconState(
                    isRecording: false,
                    permissions: missing
                ) == .needsPermission
            )
        }

        run("processing is not presented as active recording in the menu bar", failures: &failures) {
            let activity = VoiceInputActivity.processing(
                VoiceInputSessionID(),
                .transcribing,
                applicationName: nil
            )
            let granted = PermissionSnapshot(
                accessibility: .granted,
                microphone: .granted
            )

            try expect(
                MenuBarPresentation.iconState(
                    isRecording: activity.isRecording,
                    permissions: granted
                ) == .ready
            )
        }

        run("main window uses one minimum and one responsive breakpoint", failures: &failures) {
            let minimum = MainWindowLayout(availableWidth: 720)
            let justBelowRegular = MainWindowLayout(availableWidth: 779)
            let regular = MainWindowLayout(availableWidth: 780)

            try expect(
                MainWindowLayout.minimumContentSize
                    == CGSize(width: 720, height: 560)
            )
            try expect(
                MainWindowLayout.preferredContentSize
                    == CGSize(width: 900, height: 640)
            )
            try expect(
                minimum.widthClass == .compact
            )
            try expect(
                justBelowRegular.widthClass == .compact
            )
            try expect(
                regular.widthClass == .regular
            )
            try expect(
                MainWindowLayout(availableWidth: 900).widthClass == .regular
            )
            try expect(minimum.pageHorizontalPadding == 18)
            try expect(regular.pageHorizontalPadding == 24)
            try expect(minimum.overviewMetricDividerPadding == 18)
            try expect(regular.overviewMetricDividerPadding == 34)
        }

        run("settings and main window expose the approved information architecture", failures: &failures) {
            try expect(
                SettingsGroup.allCases == [
                    .shortcut,
                    .permissions,
                    .apiKeys,
                    .refinement,
                    .general,
                    .localData,
                ]
            )
            try expect(
                SettingsGroup.allCases.map(\.title) == [
                    "快捷键",
                    "权限",
                    "API Key",
                    "整理",
                    "通用",
                    "本地数据",
                ]
            )
            try expect(
                MainWindowTab.allCases == [
                    .overview,
                    .history,
                    .dictionary,
                    .settings,
                    .about,
                ]
            )
            try expect(MainWindowTab.about.title == "关于")
            try expect(
                AboutSection.allCases.map(\.title) == [
                    "隐私边界",
                    "版本",
                ]
            )
            try expect(HistoryRetentionPolicy.disabled.maximumAgeDays == nil)
            try expect(
                HistoryRetentionPolicy.allCases.map(\.displayName) == [
                    "不保存",
                    "最近 30 天",
                    "最近 90 天",
                    "最近一年",
                    "不按日期清理",
                ]
            )
            try expect(
                [
                    HistoryRecordStatus.delivered,
                    .deliveryUnconfirmed,
                    .refinementFellBack,
                    .pendingCopy,
                ].map(\.label) == [
                    "已送达",
                    "已发送·未确认",
                    "已送达·整理回退",
                    "待复制结果",
                ]
            )
        }

        run("API key cards show a persistent input only before a key is saved", failures: &failures) {
            try expect(
                APIKeyCardPresentation.mode(
                    hasStoredKey: false,
                    isReplacingKey: false
                ) == .enterKey
            )
            try expect(
                APIKeyCardPresentation.mode(
                    hasStoredKey: false,
                    isReplacingKey: true
                ) == .enterKey
            )
            try expect(
                APIKeyCardPresentation.mode(
                    hasStoredKey: true,
                    isReplacingKey: false
                ) == .configured
            )
            try expect(
                APIKeyCardPresentation.mode(
                    hasStoredKey: true,
                    isReplacingKey: true
                ) == .replacingKey
            )
        }

        run("main window visibility drives dock activation policy once per transition", failures: &failures) {
            var appliedPolicies: [MainWindowActivationPolicy] = []
            let feature = MainWindowVisibilityFeature {
                appliedPolicies.append($0)
            }

            feature.mainWindowDidOpen()
            feature.mainWindowDidOpen()
            feature.mainWindowWillClose()
            feature.mainWindowWillClose()
            feature.mainWindowDidOpen()

            try expect(
                appliedPolicies == [.regular, .accessory, .regular]
            )
        }

        run("settings navigation presents ordinary entry at the top", failures: &failures) {
            let navigation = SettingsNavigationModel()

            try expect(navigation.presentationRequest == nil)

            navigation.open(.permissions)
            guard let request = navigation.presentationRequest else {
                throw SpecFailure(message: "permission presentation was not requested")
            }
            try expect(request.target == .section(.permissions))
            navigation.completePresentation(request)
            try expect(navigation.presentationRequest == nil)
        }

        run("settings navigation emits every explicit presentation request", failures: &failures) {
            let navigation = SettingsNavigationModel()

            navigation.open(.permissions)
            guard let firstRequest = navigation.presentationRequest else {
                throw SpecFailure(message: "permission presentation was not requested")
            }
            try expect(firstRequest.target == .section(.permissions))
            navigation.completePresentation(firstRequest)
            try expect(navigation.presentationRequest == nil)

            navigation.open(.permissions)
            guard let repeatedRequest = navigation.presentationRequest else {
                throw SpecFailure(message: "repeated permission presentation was not requested")
            }
            try expect(repeatedRequest != firstRequest)
            try expect(repeatedRequest.target == .section(.permissions))

            navigation.openTop()
            try expect(navigation.presentationRequest?.target == .top)
        }

        run("data erasure keeps failure recovery reachable", failures: &failures) {
            let failure = SpeakerDataErasureFailure(
                issues: [],
                remaining: [.history]
            )
            try expect(
                SpeakerDataErasureState.idle.workspaceRoute == .normal
            )
            try expect(
                SpeakerDataErasureState.erasing.workspaceRoute == .erasing
            )
            try expect(
                SpeakerDataErasureState.failed(failure).workspaceRoute
                    == .aboutRecovery
            )
        }

        run("menu bar presents only compact contextual shortcuts in exact order", failures: &failures) {
            let idle = MenuBarVoiceCapabilities()
            let active = MenuBarVoiceCapabilities(
                showsStatus: true,
                canCancel: true
            )
            let retainedText = MenuBarVoiceCapabilities(
                showsStatus: true,
                canCopyRetainedText: true,
                canDismiss: true
            )
            let blockedPermission = MenuBarVoiceCapabilities(
                showsStatus: true,
                canRecover: true,
                canDismiss: true
            )

            try expect(
                MenuBarPresentation.rows(
                    voice: idle,
                    workspaceRoute: .normal
                ) == [
                    .openSpeaker,
                    .refinementMode,
                    .divider,
                    .settings,
                    .divider,
                    .quit,
                ]
            )
            try expect(
                MenuBarPresentation.rows(
                    voice: active,
                    workspaceRoute: .normal
                ) == [
                    .openSpeaker,
                    .refinementMode,
                    .divider,
                    .voiceStatus,
                    .cancelVoiceInput,
                    .divider,
                    .settings,
                    .divider,
                    .quit,
                ]
            )
            try expect(
                MenuBarPresentation.rows(
                    voice: retainedText,
                    workspaceRoute: .normal
                ) == [
                    .openSpeaker,
                    .refinementMode,
                    .divider,
                    .voiceStatus,
                    .copyRetainedText,
                    .dismissVoiceInput,
                    .divider,
                    .settings,
                    .divider,
                    .quit,
                ]
            )
            try expect(
                MenuBarPresentation.rows(
                    voice: blockedPermission,
                    workspaceRoute: .normal
                ) == [
                    .openSpeaker,
                    .refinementMode,
                    .divider,
                    .voiceStatus,
                    .recoverVoiceInput,
                    .dismissVoiceInput,
                    .divider,
                    .settings,
                    .divider,
                    .quit,
                ]
            )
            let dataErasureRows: [MenuBarRow] = [
                .dataErasureStatus,
                .dataErasureRecovery,
                .divider,
                .quit,
            ]
            try expect(
                MenuBarPresentation.rows(
                    voice: idle,
                    workspaceRoute: .erasing
                ) == dataErasureRows
            )
            try expect(
                MenuBarPresentation.rows(
                    voice: idle,
                    workspaceRoute: .aboutRecovery
                ) == dataErasureRows
            )
        }

        run("menu commands route to the intended product destination", failures: &failures) {
            let navigation = SettingsNavigationModel()
            var events: [String] = []
            let router = MenuBarCommandRouter(
                navigation: navigation,
                openOverview: { events.append("overview") },
                openSettings: { events.append("settings") },
                openDataErasureRecovery: {
                    events.append("data-erasure-recovery")
                },
                activate: { events.append("activate") },
                terminate: { events.append("terminate") }
            )

            router.perform(.overview)
            try expect(events == ["overview", "activate"])

            router.perform(.permissionSettings)
            try expect(
                navigation.presentationRequest?.target
                    == .section(.permissions)
            )
            try expect(events.suffix(2) == ["settings", "activate"])

            router.perform(.dataErasureRecovery)
            try expect(
                navigation.presentationRequest?.target
                    == .section(.permissions)
            )
            try expect(
                events.suffix(2) == ["data-erasure-recovery", "activate"]
            )

            router.perform(.settings)
            try expect(
                navigation.presentationRequest?.target == .top,
                "ordinary settings did not return to the page top"
            )
            try expect(events.suffix(2) == ["settings", "activate"])

            router.perform(.quit)
            try expect(events.last == "terminate")
        }

        run("voice activity presentation is shared across experience surfaces", failures: &failures) {
            let id = VoiceInputSessionID()
            let transcribing = VoiceInputActivity.processing(
                id,
                .transcribing,
                applicationName: "TextEdit"
            )
            try expect(transcribing.isActive)
            try expect(transcribing.compactTitle == "正在转成文字…")
            try expect(transcribing.icon == "sparkles")
            try expect(
                transcribing.accessibilityAnnouncement
                    == "正在等待豆包返回文字"
            )

            let delivered = VoiceInputActivity.delivered(
                id,
                applicationName: "TextEdit",
                text: "完成"
            )
            try expect(delivered.compactTitle == "已完成")
            try expect(delivered.accessibilityAnnouncement == "文字已输入")
            try expect(
                delivered.accessibilityAnnouncement?.contains("TextEdit")
                    == false
            )
            try expect(
                PendingCopyReason.changedTarget.userTitle
                    == "输入位置已经变化"
            )
        }

        run("initial shortcut state does not announce an activation", failures: &failures) {
            let feature = makeFeature()
            var announcements: [String] = []
            let coordinator = ShortcutAnnouncementCoordinator(
                feature: feature,
                announce: { announcements.append($0) }
            )

            try expect(announcements.isEmpty)
            withExtendedLifetime(coordinator) {}
        }

        run("successful shortcut activation announces exactly once", failures: &failures) {
            let feature = makeFeature()
            var announcements: [String] = []
            let coordinator = ShortcutAnnouncementCoordinator(
                feature: feature,
                announce: { announcements.append($0) }
            )

            feature.restore(.functionKey)

            try expect(announcements == ["Fn 快捷键已启用"])
            withExtendedLifetime(coordinator) {}
        }

        run("shortcut activation failure announces its precise boundary", failures: &failures) {
            let feature = makeFeature(functionResult: .eventTapUnavailable)
            var announcements: [String] = []
            let coordinator = ShortcutAnnouncementCoordinator(
                feature: feature,
                announce: { announcements.append($0) }
            )

            feature.select(.functionKey)

            try expect(announcements == ["无法创建 Fn 键的系统事件监听。"])
            withExtendedLifetime(coordinator) {}
        }

        await runAsync("persistence retry announces both failure and recovery", failures: &failures) {
            let persistence = FailOncePersistence()
            let feature = VoiceShortcutFeature(
                functionKeyMonitor: FunctionMonitorFake(),
                customShortcutMonitor: CustomMonitorFake(),
                accessibilityGranted: { true },
                persistPreference: { preference in
                    try await persistence.save(preference)
                }
            )
            var announcements: [String] = []
            let coordinator = ShortcutAnnouncementCoordinator(
                feature: feature,
                announce: { announcements.append($0) }
            )

            feature.select(.functionKey)
            await feature.flushPersistence()
            feature.retryPersistence()
            await feature.flushPersistence()

            try expect(announcements.first == "Fn 快捷键已启用")
            try expect(announcements.contains("无法保存快捷键设置"))
            try expect(announcements.last == "Fn 快捷键设置已保存。")
            withExtendedLifetime(coordinator) {}
        }

        await runAsync("voice experience owns Esc immediately and fences triggers after shutdown", failures: &failures) {
            let fixture = makeVoiceExperienceFixture()
            let experience = fixture.experience
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            try expect(
                experience.shortcutTarget.shouldConsumeEscape(),
                "Esc was not owned synchronously with the physical press"
            )
            experience.shortcutTarget.receive(.cancel)
            _ = await waitUntil {
                experience.state.diagnosticCode == "cancelled"
                    || experience.state.diagnosticCode == "idle"
            }

            await experience.shutdown()
            experience.shortcutTarget.receive(.pressed)
            try expect(
                !experience.shortcutTarget.shouldConsumeEscape(),
                "a trigger revived Esc ownership after shutdown"
            )
        }

        await runAsync("voice experience consumes Esc while processing and cancels the processor", failures: &failures) {
            let processor = HangingVoiceTextProcessor()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: processor,
                delivery: TextDeliveryFake(
                    result: .pendingCopy(.deliveryFailed),
                    commitsBeforeDelivering: false
                ),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { _ in }
            )
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let processingStarted = await waitUntil {
                experience.state.diagnosticCode == "processing.transcribing"
            }
            let consumesEscape = experience.shortcutTarget.shouldConsumeEscape()
            experience.shortcutTarget.receive(.cancel)
            let cancelled = await waitUntil {
                experience.state.diagnosticCode == "cancelled"
            }
            try? await Task.sleep(for: .milliseconds(30))
            let processorCancelled = await processor.cancellationCount == 1
            await experience.shutdown()

            try expect(processingStarted)
            try expect(
                consumesEscape,
                "Esc would pass through to the focused app while Speaker was processing"
            )
            try expect(cancelled)
            try expect(
                processorCancelled,
                "cancelling processing did not cancel the active text processor"
            )
        }

        await runAsync("successful automatic input stays visually silent but announces completion", failures: &failures) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(
                        .init(id: UUID(), applicationName: "TextEdit")
                    )
                ),
                transcriber: SpeechTranscriberFake(text: "保留的文字"),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { announcements.messages.append($0) }
            )
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let delivered = await waitUntil {
                experience.state.diagnosticCode == "delivered"
            }
            let overlayIsHidden = if case .hidden = experience.state.overlay {
                true
            } else {
                false
            }
            await experience.shutdown()

            try expect(delivered)
            try expect(
                overlayIsHidden,
                "successful input unexpectedly displayed a completion HUD"
            )
            try expect(
                announcements.messages.contains("文字已输入"),
                "VoiceOver received no completion feedback after automatic input"
            )
        }

        await runAsync(
            "an empty provider transcript ends silently",
            failures: &failures
        ) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(
                    result: .writable(
                        .init(id: UUID(), applicationName: "TextEdit")
                    )
                ),
                textProcessor: FailingVoiceTextProcessor(
                    failure: .init(
                        userFailure: .providerReturnedNoText,
                        providerDiagnostic: .init(
                            provider: "doubao",
                            code: "emptyTranscript"
                        )
                    )
                ),
                delivery: TextDeliveryFake(result: .delivered),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { announcements.messages.append($0) }
            )
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let ended = await waitUntil {
                experience.state.diagnosticCode
                    == "failed.providerReturnedNoText"
            }
            let overlayIsHidden = if case .hidden = experience.state.overlay {
                true
            } else {
                false
            }
            let menuIsIdle = experience.state.menu.status == nil
                && experience.state.menu.dismissAction == nil
                && experience.state.menu.recoveryAction == nil
            let announcedEmptyResult = announcements.messages.contains {
                $0.contains("没有返回文字")
            }
            await experience.shutdown()

            try expect(ended)
            try expect(
                overlayIsHidden && menuIsIdle,
                "an empty transcript remained visible as a user-facing problem"
            )
            try expect(
                !announcedEmptyResult,
                "an empty transcript was announced as a user-facing problem"
            )
        }

        await runAsync("clipboard failure produces one retained-result announcement", failures: &failures) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "保留的文字"),
                delivery: TextDeliveryFake(
                    result: .pendingCopy(.deliveryFailed),
                    commitsBeforeDelivering: false
                ),
                clipboard: ClipboardFake(succeeds: false),
                history: SessionHistoryFake()
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { announcements.messages.append($0) }
            )
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)
            _ = await waitUntil {
                if case .pendingCopy = experience.state.overlay { true } else { false }
            }
            guard case let .pendingCopy(
                _,
                _,
                _,
                copyAction,
                _
            ) = experience.state.overlay else {
                throw SpecFailure(message: "pending-copy action was not presented")
            }
            let announcementCountBeforeCopy = announcements.messages.count

            experience.perform(copyAction)
            let clipboardFailurePresented = await waitUntil {
                experience.state.diagnosticCode == "pendingCopy.clipboardFailed"
            }
            let copyAnnouncements = Array(
                announcements.messages.dropFirst(announcementCountBeforeCopy)
            )
            await experience.shutdown()

            try expect(clipboardFailurePresented)
            try expect(
                copyAnnouncements == [
                    "复制失败，请重试，文字已保留，可以选择复制",
                ],
                "clipboard failure announced overlapping messages: \(copyAnnouncements)"
            )
        }

        await runAsync("successful copy is announced without leaving a stale menu notice", failures: &failures) {
            let fixture = makeVoiceExperienceFixture()
            let experience = fixture.experience
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)
            _ = await waitUntil {
                if case .pendingCopy = experience.state.overlay { true } else { false }
            }
            guard case let .pendingCopy(
                _,
                _,
                _,
                copyAction,
                _
            ) = experience.state.overlay else {
                throw SpecFailure(message: "pending-copy action was not presented")
            }

            experience.perform(copyAction)
            let copied = await waitUntil {
                experience.state.diagnosticCode == "idle"
                    && fixture.announcements.messages.last == "文字已复制"
            }
            let menuNotice = experience.state.menu.notice
            await experience.shutdown()

            try expect(copied)
            try expect(
                menuNotice == nil,
                "copy success remained indefinitely in the menu: \(menuNotice ?? "")"
            )
        }

        await runAsync("history failure announces only the newly reported problem", failures: &failures) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: refinementFallbackProcessor(),
                delivery: TextDeliveryFake(
                    result: .pendingCopy(.deliveryFailed),
                    commitsBeforeDelivering: false
                ),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(
                    failureNotice: .writeFailed(reason: "磁盘不可用"),
                    failureNoticeDelay: .milliseconds(80)
                )
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { announcements.messages.append($0) }
            )
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)
            let historyFailurePresented = await waitUntil {
                experience.state.menu.notice?
                    .contains("会话历史写入失败") == true
            }
            let fallbackMessage = "DeepSeek 请求发生网络错误，已使用豆包结果。"
            let fallbackCount = announcements.messages.filter {
                $0.contains(fallbackMessage)
            }.count
            let historyFailureCount = announcements.messages.filter {
                $0 == "会话历史写入失败：磁盘不可用"
            }.count
            await experience.shutdown()

            try expect(historyFailurePresented)
            try expect(
                fallbackCount == 1,
                "an old DeepSeek fallback notice was announced \(fallbackCount) times"
            )
            try expect(
                historyFailureCount == 1,
                "history persistence failure was not announced as one new fact"
            )
        }

        await runAsync("voice experience replaces retained text on a new press and rejects stale actions", failures: &failures) {
            let fixture = makeVoiceExperienceFixture()
            let experience = fixture.experience
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            let firstRecordingStarted = await waitUntil {
                experience.state.isRecording
            }
            try expect(firstRecordingStarted, "first recording never started")
            // 短按切换语义:第一对按键开始录音,第二对结束。
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let retainedTextPresented = await waitUntil {
                if case .pendingCopy = experience.state.overlay { true } else { false }
            }
            try expect(retainedTextPresented, "pending copy never presented")
            guard case let .pendingCopy(
                _,
                _,
                _,
                staleCopyAction,
                _
            ) = experience.state.overlay else {
                throw SpecFailure(message: "pending-copy actions were not presented")
            }

            // 留存提示不挡快捷键:再按一次会丢弃留存文字并直接开新会话。
            experience.shortcutTarget.receive(.pressed)
            let secondRecordingStarted = await waitUntil {
                experience.state.isRecording
            }
            try expect(
                secondRecordingStarted,
                "a press during pending copy did not start a new recording"
            )
            if case .pendingCopy = experience.state.overlay {
                throw SpecFailure(
                    message: "retained text notice survived a new press"
                )
            }

            experience.perform(staleCopyAction)
            try? await Task.sleep(for: .milliseconds(30))

            try expect(
                experience.state.isRecording,
                "stale copy action interrupted the new recording"
            )
            let copyCount = await fixture.clipboard.copiedTexts.count
            try expect(copyCount == 0, "stale copy action reached the clipboard")
            let recordingAnnouncements = fixture.announcements.messages.filter {
                $0 == "Speaker 正在录音，按 Esc 可以取消"
            }
            try expect(
                recordingAnnouncements.count == 2,
                "the second session's recording phase was incorrectly deduplicated"
            )

            guard let cancelAction = experience.state.menu.cancelAction else {
                throw SpecFailure(message: "recording did not expose cancellation")
            }
            experience.perform(cancelAction)
            await experience.shutdown()
        }

        await runAsync("voice experience projects terminal persistence notices", failures: &failures) {
            let fixture = makeVoiceExperienceFixture(
                history: SessionHistoryFake(
                    failureNotice: .writeFailed(reason: "磁盘不可用")
                )
            )
            let experience = fixture.experience
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let noticePresented = await waitUntil {
                experience.state.menu.notice?
                    .contains("会话历史写入失败") == true
            }
            try expect(
                noticePresented,
                "the Experience layer discarded a terminal persistence notice"
            )
            await experience.shutdown()
        }

        await runAsync("stale cancel capability cannot cancel a newer recording", failures: &failures) {
            let fixture = makeVoiceExperienceFixture()
            let experience = fixture.experience
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            guard let staleCancelAction = experience.state.menu.cancelAction else {
                throw SpecFailure(message: "first session had no cancel action")
            }

            experience.shortcutTarget.receive(.cancel)
            experience.shortcutTarget.receive(.pressed)
            experience.perform(staleCancelAction)

            let secondRecordingSurvived = await waitUntil {
                experience.state.isRecording
            }
            try? await Task.sleep(for: .milliseconds(30))
            let startCount = await fixture.audio.startCount
            try expect(secondRecordingSurvived)
            try expect(
                startCount == 2 && experience.state.isRecording,
                "an old session-scoped cancel action cancelled the new session"
            )
            await experience.shutdown()
        }

        await runAsync(
            "recording limit guidance reaches the production HUD and menu state",
            failures: &failures
        ) {
            let clock = ScenarioVoiceInputClock()
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                transcriber: SpeechTranscriberFake(text: "保留的文字"),
                delivery: TextDeliveryFake(
                    result: .pendingCopy(.deliveryFailed),
                    commitsBeforeDelivering: false
                ),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake(),
                maximumRecordingDuration: .seconds(600),
                clock: clock
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { _ in }
            )
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(600))
            let presented = await waitUntil {
                experience.state.diagnosticCode
                    == "failed.recordingLimitReached"
            }

            try expect(presented)
            try expect(
                experience.state.menu.status?.title
                    == "录音已达到 10 分钟上限"
            )
            try expect(
                experience.state.menu.notice
                    == "为保护隐私并避免持续计费，本次语音输入已停止。请重新开始。"
            )
            if case let .problem(icon, title, guidance, recovery, _) =
                experience.state.overlay
            {
                try expect(icon == "timer")
                try expect(title == "录音已达到 10 分钟上限")
                try expect(
                    guidance
                        == "为保护隐私并避免持续计费，本次语音输入已停止。请重新开始。"
                )
                try expect(recovery == nil)
            } else {
                throw SpecFailure(message: "recording limit did not reach the HUD")
            }
            await experience.shutdown()
        }

        await runAsync("recovery action routes to speech settings and dismisses the failure", failures: &failures) {
            let sessions = VoiceInputSessions(
                audioCapture: AudioCaptureFake(),
                targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
                textProcessor: FailingVoiceTextProcessor(
                    failure: .init(userFailure: .providerNotConfigured)
                ),
                delivery: TextDeliveryFake(
                    result: .pendingCopy(.deliveryFailed),
                    commitsBeforeDelivering: false
                ),
                clipboard: ClipboardFake(),
                history: SessionHistoryFake()
            )
            let experience = VoiceInputExperience(
                sessions: sessions,
                announce: { _ in }
            )
            experience.start()
            experience.shortcutTarget.receive(.pressed)
            _ = await waitUntil { experience.state.isRecording }
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let failurePresented = await waitUntil {
                if case .problem = experience.state.overlay { true } else { false }
            }
            try expect(failurePresented)
            guard let recoveryAction = experience.state.menu.recoveryAction else {
                throw SpecFailure(message: "settings recovery was not exposed")
            }
            try expect(experience.perform(recoveryAction) == .openSpeechSettings)
            let dismissed = await waitUntil {
                experience.state.diagnosticCode == "idle"
            }
            try expect(dismissed)
            await experience.shutdown()
        }

        await ShortcutRecorderSpecs.run(failures: &failures)
        await RuntimeLifecycleSpecs.run(failures: &failures)
        await DashboardGroupingSpecs.run(failures: &failures)

        SpecSummary.finish(failures: failures, label: "app scenario specs")
    }

    @MainActor
    private static func makeFeature(
        functionResult: FunctionKeyMonitorStartResult = .active
    ) -> VoiceShortcutFeature {
        VoiceShortcutFeature(
            functionKeyMonitor: FunctionMonitorFake(startResult: functionResult),
            customShortcutMonitor: CustomMonitorFake(),
            accessibilityGranted: { true },
            persistPreference: { _ in }
        )
    }
}

@MainActor
private struct VoiceExperienceFixture {
    let experience: VoiceInputExperience
    let audio: AudioCaptureFake
    let clipboard: ClipboardFake
    let announcements: AnnouncementRecorder
}

@MainActor
private func makeVoiceExperienceFixture(
    history: any SessionHistoryRecording = SessionHistoryFake()
) -> VoiceExperienceFixture {
    let audio = AudioCaptureFake()
    let clipboard = ClipboardFake()
    let sessions = VoiceInputSessions(
        audioCapture: audio,
        targetCapture: TargetCaptureFake(result: .unavailable(.missingTarget)),
        transcriber: SpeechTranscriberFake(text: "保留的文字"),
        delivery: TextDeliveryFake(
            result: .pendingCopy(.deliveryFailed),
            commitsBeforeDelivering: false
        ),
        clipboard: clipboard,
        history: history
    )
    let announcements = AnnouncementRecorder()
    return VoiceExperienceFixture(
        experience: VoiceInputExperience(
            sessions: sessions,
            announce: { announcements.messages.append($0) }
        ),
        audio: audio,
        clipboard: clipboard,
        announcements: announcements
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private final class AnnouncementRecorder {
    var messages: [String] = []
}

/// A text processor whose Stage Result already records a DeepSeek fallback, so the
/// Experience layer has a refinement notice to project.
private func refinementFallbackProcessor() -> VoiceTextProcessorFake {
    VoiceTextProcessorFake(
        result: VoiceTextProcessingResult(
            doubaoText: "豆包结果",
            normalizedText: "豆包结果",
            deepSeekText: nil,
            finalText: "豆包结果",
            doubaoRequestID: "doubao-request",
            deepSeekRequestID: nil,
            refinementStatus: .fellBack,
            refinementFailure: .init(kind: .network)
        ),
        reportedStages: [.refining]
    )
}

/// A clock the scenario advances by hand. Sleepers resume only when the
/// clock passes their deadline, so a recording limit fires exactly when the
/// scenario says it does.
private final class ScenarioVoiceInputClock: VoiceInputClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: Duration = .zero
    private var sleepers: [Sleeper] = []

    var monotonicNow: Duration {
        lock.withLock { now }
    }

    var date: Date {
        Date(timeIntervalSinceReferenceDate: 0)
            .addingTimeInterval(monotonicNow.timeInterval)
    }

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    sleepers.append(
                        Sleeper(deadline: now + duration, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            let cancelled = lock.withLock {
                let cancelled = sleepers
                sleepers.removeAll()
                return cancelled
            }
            for sleeper in cancelled {
                sleeper.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            now += duration
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func waitUntilSleeping(count: Int) async {
        while lock.withLock({ sleepers.count }) < count { await Task.yield() }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

private actor ScenarioDoubaoSettingsService: DoubaoSettingsServicing {
    private var hasKey: Bool
    private var checkContinuation:
        CheckedContinuation<Result<String?, Error>, Never>?

    init(hasKey: Bool) {
        self.hasKey = hasKey
    }

    func setResource(_ resource: DoubaoStreamingResource) async {}

    func hasAPIKey() async throws -> Bool {
        hasKey
    }

    func saveAPIKey(_ apiKey: String) async throws {
        hasKey = !apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    func deleteAPIKey() async throws {
        hasKey = false
    }

    func checkConnection() async throws -> String? {
        let result = await withCheckedContinuation { continuation in
            checkContinuation = continuation
        }
        return try result.get()
    }

    var isCheckPending: Bool {
        checkContinuation != nil
    }

    func finishCheck(_ result: Result<String?, Error>) {
        checkContinuation?.resume(returning: result)
        checkContinuation = nil
    }
}

/// An in-memory stand-in for `VersionedLocalAppSettingsStore`, proving the
/// settings models depend on `AppSettingsStoring` rather than a file on disk.
private actor ScenarioAppSettingsStore: AppSettingsStoring {
    private(set) var settings: SpeakerAppSettings

    init(settings: SpeakerAppSettings = .default) {
        self.settings = settings
    }

    func load() -> AppSettingsLoadResult {
        .loaded(settings)
    }

    @discardableResult
    func updateRefinement(
        _ refinement: RefinementPreference
    ) -> SpeakerAppSettings {
        settings.refinement = refinement
        return settings
    }

    @discardableResult
    func updateSavedCustomRefinement(
        _ refinement: RefinementPreference
    ) -> SpeakerAppSettings {
        settings.savedCustomRefinement = refinement
        return settings
    }

    @discardableResult
    func updateRefinementPromptOverride(
        _ promptOverride: String?,
        for mode: TextRefinementMode
    ) -> SpeakerAppSettings {
        settings.refinementPromptOverrides[mode] = promptOverride
        return settings
    }

    @discardableResult
    func updateHistoryRetention(
        _ policy: HistoryRetentionPolicy
    ) -> SpeakerAppSettings {
        settings.historyRetention = policy
        return settings
    }
}

private actor ScenarioDeepSeekSettingsService: DeepSeekSettingsServicing {
    private var hasKey: Bool

    init(hasKey: Bool) {
        self.hasKey = hasKey
    }

    func hasAPIKey() -> Bool {
        hasKey
    }

    func saveAPIKey(_ apiKey: String) {
        hasKey = !apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    func deleteAPIKey() {
        hasKey = false
    }

    func checkConnection() -> String? {
        "scenario-deepseek-request"
    }
}

private actor ScenarioPersonalDictionaryStore: PersonalDictionaryStoring {
    private var stored: PersonalDictionary

    init(words: [String]) {
        stored = (try? PersonalDictionary(
            entries: words.map { DictionaryEntry(word: $0) }
        )) ?? .empty
    }

    var storedWords: [String] {
        stored.entries.map(\.word)
    }

    func load() -> PersonalDictionaryLoadResult {
        PersonalDictionaryLoadResult(dictionary: stored)
    }

    func save(_ dictionary: PersonalDictionary) {
        stored = dictionary
    }
}

/// A history store that records the retention policies it was asked to apply
/// and can report an unfinished cleanup.
private actor ScenarioHistoryRetentionStore: LocalSessionHistoryStoring {
    private let appliesRetention: Bool
    private var policy: HistoryRetentionPolicy = .forever
    private var records: [VoiceInputHistoryRecord] = []
    private(set) var appliedPolicies: [HistoryRetentionPolicy] = []

    init(appliesRetention: Bool) {
        self.appliesRetention = appliesRetention
    }

    func save(_ record: VoiceInputHistoryRecord) {
        records.append(record)
    }

    func allRecords() -> [VoiceInputHistoryRecord] {
        records
    }

    func record(sessionID: VoiceInputSessionID) -> VoiceInputHistoryRecord? {
        records.first { $0.sessionID == sessionID }
    }

    @discardableResult
    func delete(sessionID: VoiceInputSessionID) -> Bool {
        let remaining = records.filter { $0.sessionID != sessionID }
        defer { records = remaining }
        return remaining.count != records.count
    }

    @discardableResult
    func clear() -> Bool {
        records = []
        return true
    }

    func persistenceStatus() -> LocalHistoryPersistenceStatus {
        LocalHistoryPersistenceStatus(recordCount: records.count, notice: nil)
    }

    func clearPersistenceNotice() {}

    func currentRetentionPolicy() -> HistoryRetentionPolicy {
        policy
    }

    @discardableResult
    func applyRetentionPolicy(
        _ policy: HistoryRetentionPolicy,
        now: Date
    ) -> Bool {
        appliedPolicies.append(policy)
        self.policy = policy
        return appliesRetention
    }
}

@MainActor
private final class FunctionMonitorFake: FunctionKeyMonitoring {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let startResult: FunctionKeyMonitorStartResult

    init(startResult: FunctionKeyMonitorStartResult = .active) {
        self.startResult = startResult
    }

    func start() -> FunctionKeyMonitorStartResult {
        startCount += 1
        isRunning = startResult == .active
        return startResult
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

@MainActor
private final class ScenarioLoginItemService: LoginItemServicing {
    var state: LoginItemServiceState
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    init(state: LoginItemServiceState) {
        self.state = state
    }

    func register() throws {
        registerCount += 1
        state = .enabled
    }

    func unregister() async throws {
        unregisterCount += 1
        state = .notRegistered
    }

    func openSystemSettings() {
        openSystemSettingsCount += 1
    }
}

@MainActor
private final class CustomMonitorFake: CustomShortcutMonitoring {
    private(set) var isRegistered = false

    func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        isRegistered = true
        return .active
    }

    func unregister() {
        isRegistered = false
    }
}

@MainActor
private final class SoftwareUpdateDriverFake: SoftwareUpdateDriving {
    private(set) var checkCount = 0
    private(set) var automaticChecksEnabled = false
    private var observer:
        (@MainActor @Sendable (SoftwareUpdateDriverSnapshot) -> Void)?

    func start(
        observing: @escaping @MainActor @Sendable (
            SoftwareUpdateDriverSnapshot
        ) -> Void
    ) throws -> SoftwareUpdateDriverSnapshot {
        observer = observing
        return snapshot
    }

    func checkForUpdates() {
        checkCount += 1
    }

    func setAutomaticallyChecksForUpdates(
        _ enabled: Bool
    ) -> SoftwareUpdateDriverSnapshot {
        automaticChecksEnabled = enabled
        let snapshot = snapshot
        observer?(snapshot)
        return snapshot
    }

    private var snapshot: SoftwareUpdateDriverSnapshot {
        .init(
            canCheckForUpdates: true,
            automaticallyChecksForUpdates: automaticChecksEnabled
        )
    }
}

@MainActor
private final class ScenarioPermissionAccess: PermissionAccess {
    var snapshot: PermissionSnapshot
    private(set) var requestedPermissions: [PermissionKind] = []
    private let requestSnapshots: [PermissionKind: PermissionSnapshot]

    init(
        snapshot: PermissionSnapshot,
        requestSnapshots: [PermissionKind: PermissionSnapshot] = [:]
    ) {
        self.snapshot = snapshot
        self.requestSnapshots = requestSnapshots
    }

    func currentSnapshot() -> PermissionSnapshot {
        snapshot
    }

    func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        requestedPermissions.append(permission)
        if let requestedSnapshot = requestSnapshots[permission] {
            snapshot = requestedSnapshot
        }
        return snapshot
    }
}

private actor FailOncePersistence {
    private var shouldFail = true

    func save(_ preference: VoiceShortcutPreference) throws {
        if shouldFail {
            shouldFail = false
            throw PersistenceFailure()
        }
    }
}

private struct PersistenceFailure: LocalizedError {
    var errorDescription: String? { "无法保存快捷键设置" }
}

private actor ScenarioProviderCredentialStore: ProviderCredentialStoring {
    private var values: [ProviderID: String] = [:]

    func save(apiKey: String, for provider: ProviderID) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ProviderCredentialStoreError.emptyAPIKey
        }
        values[provider] = normalized
    }

    func apiKey(for provider: ProviderID) -> String? {
        values[provider]
    }

    func deleteAPIKey(for provider: ProviderID) {
        values[provider] = nil
    }
}

private final class RouterVoiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTriggers: [GlobalVoiceTrigger] = []
    private let escapeActive: Bool

    init(escapeActive: Bool = false) {
        self.escapeActive = escapeActive
    }

    lazy var target = VoiceTriggerTarget(
        receive: { [weak self] trigger in
            self?.lock.withLock {
                self?.storedTriggers.append(trigger)
            }
        },
        shouldConsumeEscape: { [weak self] in
            self?.escapeActive ?? false
        }
    )

    var triggers: [GlobalVoiceTrigger] {
        lock.withLock { storedTriggers }
    }
}

@MainActor
private final class DataErasureHarness {
    private(set) var calls: [String] = []
    private(set) var exitCount = 0
    private let failing: Set<String>
    private let operationDelay: Duration?

    init(
        failing: Set<String> = [],
        operationDelay: Duration? = nil
    ) {
        self.failing = failing
        self.operationDelay = operationDelay
    }

    func dependencies() -> SpeakerDataErasureDependencies {
        SpeakerDataErasureDependencies(
            persistIntent: { [weak self] in
                try await self?.perform("intent")
            },
            quiesceRuntime: { [weak self] in
                try await self?.perform("runtime")
            },
            eraseLoginItem: { [weak self] in
                try await self?.perform("login")
            },
            eraseProviderCredentials: { [weak self] in
                try await self?.perform("credentials")
            },
            closeHistory: { [weak self] in
                try await self?.perform("history")
            },
            eraseApplicationSupport: { [weak self] in
                try await self?.perform("applicationSupport")
            },
            eraseLegacyData: { [weak self] in
                try await self?.perform("legacy")
            },
            eraseCaches: { [weak self] in
                try await self?.perform("caches")
            },
            erasePreferences: { [weak self] in
                try await self?.perform("preferences")
            },
            verifyErasure: { [weak self] in
                try await self?.perform("verification")
            },
            clearIntent: { [weak self] in
                try await self?.perform("clearIntent")
            },
            requestExit: { [weak self] in
                self?.calls.append("exit")
                self?.exitCount += 1
            }
        )
    }

    private func perform(_ name: String) async throws {
        calls.append(name)
        if let operationDelay {
            try? await Task.sleep(for: operationDelay)
        }
        if failing.contains(name) {
            throw SpeakerDataErasureReason.io
        }
    }
}
