import Foundation
import SpeakerCore
import SpeakerSpecSupport

@MainActor
final class FunctionKeyMonitorFake: FunctionKeyMonitoring {
    private let startResult: FunctionKeyMonitorStartResult
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

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
final class CustomShortcutMonitorFake: CustomShortcutMonitoring {
    private let registerResult: CustomShortcutRegistrationResult
    private(set) var isRegistered = false
    private(set) var registeredKeys: [CustomHotKey] = []
    private(set) var unregisterCount = 0

    init(registerResult: CustomShortcutRegistrationResult = .active) {
        self.registerResult = registerResult
    }

    func register(_ hotKey: CustomHotKey) -> CustomShortcutRegistrationResult {
        registeredKeys.append(hotKey)
        isRegistered = registerResult == .active
        return registerResult
    }

    func unregister() {
        unregisterCount += 1
        isRegistered = false
    }
}

actor ShortcutPersistenceFake {
    private var storedValues: [VoiceShortcutPreference] = []

    var values: [VoiceShortcutPreference] { storedValues }

    func save(_ preference: VoiceShortcutPreference) {
        storedValues.append(preference)
    }
}

actor FailOnceShortcutPersistenceFake {
    private var shouldFail = true
    private var storedValues: [VoiceShortcutPreference] = []

    var values: [VoiceShortcutPreference] { storedValues }

    func save(_ preference: VoiceShortcutPreference) throws {
        if shouldFail {
            shouldFail = false
            throw AppSettingsStoreError.writeFailed(reason: "temporary failure")
        }
        storedValues.append(preference)
    }
}

@MainActor
final class PermissionAccessStub: PermissionAccess {
    var snapshot: PermissionSnapshot
    var requestResults: [PermissionKind: PermissionSnapshot] = [:]
    private(set) var requestedPermissions: [PermissionKind] = []

    init(snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> PermissionSnapshot {
        snapshot
    }

    func request(_ permission: PermissionKind) async -> PermissionSnapshot {
        requestedPermissions.append(permission)
        let result = requestResults[permission] ?? snapshot
        snapshot = result
        return result
    }
}
