import Darwin
import Combine
import Foundation
import SpeakerAppFeatures
import SpeakerCore

@main
struct SpeakerAppScenarioSpecs {
    @MainActor
    static func main() async {
        var failures: [String] = []
        var executed = 0

        run("Doubao refresh preserves a verified connection for an existing key", failures: &failures, executed: &executed) {
            let status = DoubaoConnectionStatus.success("request-id")
            try expect(
                status.afterCredentialRefresh(keyExists: true)
                    == .success("request-id")
            )
        }

        run("Doubao refresh drops verification when the key disappears", failures: &failures, executed: &executed) {
            try expect(
                DoubaoConnectionStatus.success(nil)
                    .afterCredentialRefresh(keyExists: false) == .unconfigured
            )
        }

        run("Doubao refresh clears a stale connection error for an existing key", failures: &failures, executed: &executed) {
            try expect(
                DoubaoConnectionStatus.failure("旧错误")
                    .afterCredentialRefresh(keyExists: true) == .configured
            )
        }

        run("onboarding requires both permissions and a verified connection", failures: &failures, executed: &executed) {
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

        run("onboarding exposes only valid permission and provider actions", failures: &failures, executed: &executed) {
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
            "data erasure preserves strict ordering and exits only after verification",
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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

        run("build signing mode exposes the permission identity boundary", failures: &failures, executed: &executed) {
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

        run(
            "software updates fail closed until the complete production identity exists",
            failures: &failures,
            executed: &executed
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
                    == .unavailable(
                        diagnosticCode: "update.development-build"
                    )
            )
            try expect(
                SoftwareUpdateConfiguration(
                    signingMode: .developerID,
                    feedURLString:
                        "http://updates.example.com/appcast.xml",
                    publicEDKey: validKey
                ).availability
                    == .unavailable(
                        diagnosticCode: "update.invalid-feed"
                    )
            )
            try expect(
                SoftwareUpdateConfiguration(
                    signingMode: .developerID,
                    feedURLString:
                        "https://updates.example.com/appcast.xml",
                    publicEDKey: "REPLACE_WITH_PUBLIC_KEY"
                ).availability
                    == .unavailable(
                        diagnosticCode: "update.invalid-public-key"
                    )
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

        await runAsync(
            "software update feature exposes only semantic product state",
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
        ) {
            let reportURL = URL(
                fileURLWithPath: "/private/tmp",
                isDirectory: true
            ).appendingPathComponent("speaker-delivery-smoke-spec.txt")
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

        run("startup privacy cleanup removes only the obsolete installation identifier", failures: &failures, executed: &executed) {
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

        run("voice HUD footprints stay compact", failures: &failures, executed: &executed) {
            try expect(
                VoiceInputPanelLayout.processing.size
                    == .init(width: 72, height: 40)
            )
            try expect(VoiceInputPanelLayout.processing.size.width < 96)
            try expect(
                VoiceInputPanelLayout.recording.size
                    == .init(width: 106, height: 42)
            )
            try expect(
                VoiceInputPanelLayout.pendingCopy.size
                    == .init(width: 312, height: 68)
            )
            try expect(
                VoiceInputPanelLayout.problem.size
                    == .init(width: 300, height: 72)
            )
        }

        await runAsync(
            "activating another app refreshes permission and restores the shortcut",
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
                VoiceInputNotice.persistenceFailure("会话历史写入失败")
                    .userMessage == "会话历史写入失败"
            )
        }

        run(
            "voice input failures are localized by the app presentation layer",
            failures: &failures,
            executed: &executed
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
        }

        run(
            "missing Accessibility permission is not presented as an unsupported editor",
            failures: &failures,
            executed: &executed
        ) {
            try expect(
                PendingCopyReason.accessibilityPermissionMissing.userTitle
                    == "辅助功能权限不可用"
            )
        }

        run(
            "diagnostic report includes latest structured failure evidence without user content",
            failures: &failures,
            executed: &executed
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
                    "directReceipt.unconfirmed",
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
                    DictionaryEntry(canonicalTerm: "SECRET TERM"),
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
                    "latestDeliveryDiagnostic: directReceipt.unconfirmed"
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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
            failures: &failures,
            executed: &executed
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

        run(
            "history redelivery follows the latest activated target process",
            failures: &failures,
            executed: &executed
        ) {
            var state = HistoryRedeliveryTargetState()
            state.activated(
                processIdentifier: 41,
                applicationName: "App A",
                isSpeaker: false
            )
            state.activated(
                processIdentifier: 42,
                applicationName: "App B",
                isSpeaker: false
            )

            try expect(
                state.shortcutConfirmation(
                    frontmostProcessIdentifier: 42
                ) == 42
            )
            try expect(
                state.shortcutConfirmation(
                    frontmostProcessIdentifier: 41
                ) == nil
            )
        }

        run(
            "history redelivery rejects Speaker and terminated targets",
            failures: &failures,
            executed: &executed
        ) {
            var state = HistoryRedeliveryTargetState()
            state.activated(
                processIdentifier: 41,
                applicationName: "Editor",
                isSpeaker: false
            )
            state.activated(
                processIdentifier: 10,
                applicationName: "Speaker",
                isSpeaker: true
            )
            try expect(state.candidate == nil)

            state.activated(
                processIdentifier: 42,
                applicationName: "Editor",
                isSpeaker: false
            )
            state.terminated(processIdentifier: 42)
            try expect(state.candidate == nil)
        }

        run(
            "history mouse confirmation requires one stable target for down and up",
            failures: &failures,
            executed: &executed
        ) {
            var state = HistoryRedeliveryTargetState()
            state.activated(
                processIdentifier: 41,
                applicationName: "App A",
                isSpeaker: false
            )
            state.mouseDown(frontmostProcessIdentifier: 41)
            state.activated(
                processIdentifier: 42,
                applicationName: "App B",
                isSpeaker: false
            )
            try expect(
                state.mouseUp(frontmostProcessIdentifier: 42) == nil
            )

            state.mouseDown(frontmostProcessIdentifier: 42)
            try expect(
                state.mouseUp(frontmostProcessIdentifier: 42) == 42
            )
        }

        run("onboarding fits the visible screen and keeps a useful resizable minimum", failures: &failures, executed: &executed) {
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

        run("voice HUD increases every low-emphasis contrast token", failures: &failures, executed: &executed) {
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
                increased.cardBorderOpacity > standard.cardBorderOpacity
            )
            try expect(
                increased.cardBorderLineWidth > standard.cardBorderLineWidth
            )
            try expect(
                increased.secondaryControlOpacity
                    > standard.secondaryControlOpacity
            )
            try expect(
                increased.errorIconOpacity > standard.errorIconOpacity
            )
        }

        run("onboarding remains ready after an unchanged credential refresh", failures: &failures, executed: &executed) {
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

        run("login item awaiting approval stays enabled and exposes recovery", failures: &failures, executed: &executed) {
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

        run("missing login item registration remains explicitly recoverable", failures: &failures, executed: &executed) {
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

        run("unavailable login item never presents an effective enabled state", failures: &failures, executed: &executed) {
            let presentation = LoginItemPresentation(
                desiredEnabled: true,
                serviceState: .notFound
            )

            try expect(!presentation.isEnabled)
            try expect(presentation.registrationState == .unavailable)
            try expect(presentation.notice != nil)
        }

        await runAsync("login item model respects a system-disabled registration until the user acts", failures: &failures, executed: &executed) {
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

        await runAsync("login item model persists an explicit re-enable", failures: &failures, executed: &executed) {
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

        await runAsync("login item model rolls the system registration back when persistence fails", failures: &failures, executed: &executed) {
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

        run("DeepSeek modes stay inactive until a key is available", failures: &failures, executed: &executed) {
            let unavailable = RefinementActivationPlan(
                desiredMode: .fullRewrite,
                hasStoredKey: false
            )
            try expect(unavailable.activeMode == .defaultSmooth)
            try expect(unavailable.deferredMode == .fullRewrite)

            let available = RefinementActivationPlan(
                desiredMode: .fullRewrite,
                hasStoredKey: true
            )
            try expect(available.activeMode == .fullRewrite)
            try expect(available.deferredMode == nil)
        }

        await runAsync("Doubao connection result cannot revive a deleted key", failures: &failures, executed: &executed) {
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

        await runAsync("Doubao connection result is bound to the checked resource", failures: &failures, executed: &executed) {
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

        run("recording takes priority over the menu bar permission warning", failures: &failures, executed: &executed) {
            let activity = VoiceInputActivity.recording(VoiceInputSessionID())
            let permissions = PermissionSnapshot(
                accessibility: .denied,
                microphone: .denied
            )

            try expect(
                MenuBarPresentation.systemImage(
                    isRecording: activity.isRecording,
                    permissions: permissions
                ) == "waveform.circle.fill"
            )
        }

        run("menu bar reflects permission state outside recording", failures: &failures, executed: &executed) {
            let granted = PermissionSnapshot(
                accessibility: .granted,
                microphone: .granted
            )
            let missing = PermissionSnapshot(
                accessibility: .granted,
                microphone: .denied
            )

            try expect(
                MenuBarPresentation.systemImage(
                    isRecording: false,
                    permissions: granted
                ) == "waveform"
            )
            try expect(
                MenuBarPresentation.systemImage(
                    isRecording: false,
                    permissions: missing
                ) == "waveform.badge.exclamationmark"
            )
        }

        run("processing is not presented as active recording in the menu bar", failures: &failures, executed: &executed) {
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
                MenuBarPresentation.systemImage(
                    isRecording: activity.isRecording,
                    permissions: granted
                ) == "waveform"
            )
        }

        run("menu commands route to the intended product destination", failures: &failures, executed: &executed) {
            let navigation = SettingsNavigationModel()
            var events: [String] = []
            let router = MenuBarCommandRouter(
                navigation: navigation,
                openSettings: {
                    events.append(
                        "settings.\(navigation.page.rawValue)"
                    )
                },
                openHistory: { events.append("history") },
                activate: { events.append("activate") },
                terminate: { events.append("terminate") }
            )

            router.perform(.permissionSettings)
            try expect(navigation.page == .permissions)
            try expect(
                events == ["settings.permissions", "activate"]
            )

            router.perform(.about)
            try expect(navigation.page == .about)
            try expect(
                events.suffix(2) == ["settings.about", "activate"]
            )

            router.perform(.history)
            try expect(events.suffix(2) == ["history", "activate"])

            router.perform(.settings)
            try expect(
                events.suffix(2) == ["settings.about", "activate"],
                "ordinary settings did not preserve the current page"
            )

            router.perform(.quit)
            try expect(events.last == "terminate")
        }

        run("voice activity presentation is shared by experience and history", failures: &failures, executed: &executed) {
            let id = VoiceInputSessionID()
            let transcribing = VoiceInputActivity.processing(
                id,
                .transcribing,
                applicationName: "TextEdit"
            )
            try expect(transcribing.isActive)
            try expect(transcribing.compactTitle == "正在转成文字…")
            try expect(transcribing.icon == "sparkles")
            try expect(transcribing.historyLabel == "处理中")
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

        run("initial shortcut state does not announce an activation", failures: &failures, executed: &executed) {
            let feature = makeFeature()
            var announcements: [String] = []
            let coordinator = ShortcutAnnouncementCoordinator(
                feature: feature,
                announce: { announcements.append($0) }
            )

            try expect(announcements.isEmpty)
            withExtendedLifetime(coordinator) {}
        }

        run("successful shortcut activation announces exactly once", failures: &failures, executed: &executed) {
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

        run("shortcut activation failure announces its precise boundary", failures: &failures, executed: &executed) {
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

        await runAsync("persistence retry announces both failure and recovery", failures: &failures, executed: &executed) {
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

        await runAsync("voice experience owns Esc immediately and fences triggers after shutdown", failures: &failures, executed: &executed) {
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

        await runAsync("voice experience consumes Esc while processing and cancels the processor", failures: &failures, executed: &executed) {
            let processor = ExperienceHangingProcessor()
            let sessions = VoiceInputSessions(
                audioCapture: ExperienceAudioCaptureFake(),
                targetCapture: ExperienceTargetCaptureFake(),
                textProcessor: processor,
                delivery: ExperienceDeliveryFake(),
                clipboard: ExperienceClipboardFake(),
                history: ExperienceHistoryFake()
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

        await runAsync("successful automatic input stays visually silent but announces completion", failures: &failures, executed: &executed) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: ExperienceAudioCaptureFake(),
                targetCapture: ExperienceWritableTargetCaptureFake(),
                transcriber: ExperienceTranscriberFake(),
                delivery: ExperienceSuccessfulDeliveryFake(),
                clipboard: ExperienceClipboardFake(),
                history: ExperienceHistoryFake()
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

        await runAsync("clipboard failure produces one retained-result announcement", failures: &failures, executed: &executed) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: ExperienceAudioCaptureFake(),
                targetCapture: ExperienceTargetCaptureFake(),
                transcriber: ExperienceTranscriberFake(),
                delivery: ExperienceDeliveryFake(),
                clipboard: ExperienceClipboardFake(succeeds: false),
                history: ExperienceHistoryFake()
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

        await runAsync("successful copy is announced without leaving a stale menu notice", failures: &failures, executed: &executed) {
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

        await runAsync("history failure announces only the newly reported problem", failures: &failures, executed: &executed) {
            let announcements = AnnouncementRecorder()
            let sessions = VoiceInputSessions(
                audioCapture: ExperienceAudioCaptureFake(),
                targetCapture: ExperienceTargetCaptureFake(),
                textProcessor: ExperienceFallbackProcessor(),
                delivery: ExperienceDeliveryFake(),
                clipboard: ExperienceClipboardFake(),
                history: ExperienceHistoryFake(
                    failureNotice: "会话历史写入失败：磁盘不可用",
                    failureDelay: .milliseconds(80)
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

        await runAsync("voice experience rejects stale retained-text actions from an older session", failures: &failures, executed: &executed) {
            let fixture = makeVoiceExperienceFixture()
            let experience = fixture.experience
            experience.start()

            experience.shortcutTarget.receive(.pressed)
            let firstRecordingStarted = await waitUntil {
                experience.state.isRecording
            }
            try expect(firstRecordingStarted)
            experience.shortcutTarget.receive(.released)
            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)

            let retainedTextPresented = await waitUntil {
                if case .pendingCopy = experience.state.overlay { true } else { false }
            }
            try expect(retainedTextPresented)
            guard case let .pendingCopy(
                _,
                _,
                _,
                staleCopyAction,
                dismissAction
            ) = experience.state.overlay else {
                throw SpecFailure(message: "pending-copy actions were not presented")
            }

            experience.shortcutTarget.receive(.pressed)
            experience.shortcutTarget.receive(.released)
            try? await Task.sleep(for: .milliseconds(30))
            guard case .pendingCopy = experience.state.overlay else {
                throw SpecFailure(
                    message: "a new shortcut discarded retained text"
                )
            }

            experience.perform(dismissAction)
            let resultDismissed = await waitUntil {
                experience.state.diagnosticCode == "idle"
            }
            try expect(resultDismissed)

            experience.shortcutTarget.receive(.pressed)
            let secondRecordingStarted = await waitUntil {
                experience.state.isRecording
            }
            try expect(secondRecordingStarted)
            experience.perform(staleCopyAction)
            try? await Task.sleep(for: .milliseconds(30))

            try expect(experience.state.isRecording)
            let copyCount = await fixture.clipboard.copyCount
            try expect(copyCount == 0)
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

        await runAsync("voice experience projects terminal persistence notices", failures: &failures, executed: &executed) {
            let fixture = makeVoiceExperienceFixture(
                history: ExperienceHistoryFake(
                    failureNotice: "会话历史写入失败：磁盘不可用"
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

        await runAsync("stale cancel capability cannot cancel a newer recording", failures: &failures, executed: &executed) {
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

        await runAsync("recovery action routes to speech settings and dismisses the failure", failures: &failures, executed: &executed) {
            let sessions = VoiceInputSessions(
                audioCapture: ExperienceAudioCaptureFake(),
                targetCapture: ExperienceTargetCaptureFake(),
                textProcessor: ExperienceFailingProcessor(),
                delivery: ExperienceDeliveryFake(),
                clipboard: ExperienceClipboardFake(),
                history: ExperienceHistoryFake()
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

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            Darwin.exit(1)
        }

        print("PASS: \(executed) app scenario specs")
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
    let audio: ExperienceAudioCaptureFake
    let clipboard: ExperienceClipboardFake
    let announcements: AnnouncementRecorder
}

@MainActor
private func makeVoiceExperienceFixture(
    history: any SessionHistoryRecording = ExperienceHistoryFake()
) -> VoiceExperienceFixture {
    let audio = ExperienceAudioCaptureFake()
    let clipboard = ExperienceClipboardFake()
    let sessions = VoiceInputSessions(
        audioCapture: audio,
        targetCapture: ExperienceTargetCaptureFake(),
        transcriber: ExperienceTranscriberFake(),
        delivery: ExperienceDeliveryFake(),
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

private actor ExperienceAudioCaptureFake: AudioCapturing {
    private(set) var startCount = 0

    func start() async throws {
        startCount += 1
    }

    func stop() async throws -> CapturedAudio {
        CapturedAudio(
            data: Data([1, 2, 3]),
            duration: .seconds(1),
            peakPower: -12
        )
    }

    func cancel() async {}
}

private actor ExperienceTargetCaptureFake: InputTargetCapturing {
    func capture() async -> InputTargetCaptureResult {
        .unavailable(.missingTarget)
    }
}

private actor ExperienceWritableTargetCaptureFake: InputTargetCapturing {
    func capture() async -> InputTargetCaptureResult {
        .writable(.init(id: UUID(), applicationName: "TextEdit"))
    }
}

private actor ExperienceTranscriberFake: SpeechTranscribing {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        .init(text: "保留的文字", providerRequestID: "scenario-request")
    }
}

private actor ExperienceDeliveryFake: TextDelivering {
    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        .pendingCopy(.deliveryFailed)
    }
}

private actor ExperienceSuccessfulDeliveryFake: TextDelivering {
    func deliver(
        _ text: String,
        to target: InputTargetSnapshot,
        commitGate: DeliveryCommitGate
    ) async -> DeliveryOutcome {
        guard await commitGate.commit() else {
            return .pendingCopy(.deliveryFailed)
        }
        return .delivered
    }
}

private actor ExperienceClipboardFake: ClipboardWriting {
    private(set) var copyCount = 0
    private let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func copy(_ text: String) async -> Bool {
        copyCount += 1
        return succeeds
    }
}

private actor ExperienceHistoryFake: SessionHistoryRecording {
    let failureNotice: String?
    let failureDelay: Duration?

    init(
        failureNotice: String? = nil,
        failureDelay: Duration? = nil
    ) {
        self.failureNotice = failureNotice
        self.failureDelay = failureDelay
    }

    func save(_ record: VoiceInputHistoryRecord) async {}

    func persistenceFailureNotice() async -> String? {
        if let failureDelay {
            try? await Task.sleep(for: failureDelay)
        }
        return failureNotice
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

private struct ExperienceFallbackProcessor: VoiceTextProcessing {
    func captureSnapshot() async -> VoiceTextProcessingSnapshot {
        .empty
    }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        await progress(.init(stage: .refining))
        return VoiceTextProcessingResult(
            doubaoText: "豆包结果",
            normalizedText: "豆包结果",
            deepSeekText: nil,
            finalText: "豆包结果",
            doubaoRequestID: "doubao-request",
            deepSeekRequestID: nil,
            refinementStatus: .fellBack,
            refinementFailure: .init(kind: .network),
            dictionaryReplacements: []
        )
    }
}

private struct ExperienceFailingProcessor: VoiceTextProcessing {
    func captureSnapshot() async -> VoiceTextProcessingSnapshot {
        .empty
    }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        throw VoiceTextProcessingFailure(userFailure: .providerNotConfigured)
    }
}

private actor ExperienceHangingProcessor: VoiceTextProcessing {
    private(set) var cancellationCount = 0

    func captureSnapshot() async -> VoiceTextProcessingSnapshot {
        .empty
    }

    func process(
        _ audio: CapturedAudio,
        snapshot: VoiceTextProcessingSnapshot,
        progress: @escaping @Sendable (VoiceTextProcessingProgress) async -> Void
    ) async throws -> VoiceTextProcessingResult {
        await progress(.init(stage: .transcribing))
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
        throw VoiceTextProcessingFailure(userFailure: .transcriptionFailed)
    }
}

private struct SpecFailure: Error {
    let message: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed"
) throws {
    guard condition() else { throw SpecFailure(message: message) }
}

@MainActor
private func run(
    _ name: String,
    failures: inout [String],
    executed: inout Int,
    body: () throws -> Void
) {
    executed += 1
    do {
        try body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

@MainActor
private func runAsync(
    _ name: String,
    failures: inout [String],
    executed: inout Int,
    body: () async throws -> Void
) async {
    executed += 1
    do {
        try await body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
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

    init(snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> PermissionSnapshot {
        snapshot
    }

    func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        snapshot
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
