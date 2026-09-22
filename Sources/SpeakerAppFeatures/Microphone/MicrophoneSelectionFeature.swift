import Combine
import Foundation
import SpeakerCore

package struct MicrophoneChoice: Identifiable, Equatable {
    package let preference: MicrophonePreference
    package let title: String
    package var id: MicrophonePreference { preference }
}

package enum MicrophoneTestStatus: Equatable {
    case idle
    case starting
    case testing
    case stopping
}

package struct MicrophoneSelectionState: Equatable {
    package var routing: MicrophoneRoutingSnapshot
    package var testStatus: MicrophoneTestStatus = .idle
    package var testLevel: Double = 0
    package var testError: String?
    package var persistenceFailed = false
    package var isPreferenceReady = false

    package var preference: MicrophonePreference { routing.preference }

    package var resolvedDevice: MicrophoneDevice? {
        guard routing.devices.isAvailable else { return nil }
        return switch preference {
        case .systemDefault:
            routing.devices.devices.first { $0.deviceID == routing.devices.systemDefaultDeviceID }
        case .device(let uid):
            routing.devices.devices.first { $0.uid == uid }
        }
    }

    package var choices: [MicrophoneChoice] {
        let systemDevice = routing.devices.devices.first {
            $0.deviceID == routing.devices.systemDefaultDeviceID
        }
        var choices = [
            MicrophoneChoice(
                preference: .systemDefault,
                title: routing.devices.isAvailable
                    ? systemDevice.map { "跟随系统（\(deviceTitle($0))）" } ?? "跟随系统"
                    : "跟随系统（列表不可用）"
            )
        ]
        if routing.devices.isAvailable {
            choices += routing.devices.devices.map {
                MicrophoneChoice(preference: .device(uid: $0.uid), title: deviceTitle($0))
            }
        }
        if case .device = preference, resolvedDevice == nil {
            choices.append(
                MicrophoneChoice(
                    preference: preference,
                    title: routing.devices.isAvailable ? "所选麦克风（已断开）" : "所选麦克风（列表不可用）"
                ))
        }
        return choices
    }

    package var selectionTitle: String {
        choices.first { $0.preference == preference }?.title ?? "跟随系统"
    }

    package var deviceNotice: String? {
        guard routing.devices.isAvailable else {
            return "无法读取麦克风列表。请重试；Speaker 不会自动改用其他设备。"
        }
        guard resolvedDevice != nil else {
            return preference == .systemDefault
                ? "当前没有可用的系统输入设备。请连接麦克风后重试。"
                : "所选麦克风已断开。请重新连接，或手动选择其他麦克风。"
        }
        return nil
    }

    package var captureDescription: String? {
        guard isPreferenceReady else { return "正在加载…" }
        if let actual = routing.actualDevice {
            let prefix = routing.isTesting ? "正在测试" : "本次录音"
            if actual.uid != resolvedDevice?.uid {
                return "\(prefix)：\(deviceTitle(actual))；下次使用新选择"
            }
            return "\(prefix)：\(deviceTitle(actual))。"
        }
        return nil
    }

    private func deviceTitle(_ device: MicrophoneDevice) -> String {
        let matching = routing.devices.devices.filter { $0.name == device.name }
            .sorted { $0.uid < $1.uid }
        guard matching.count > 1, let index = matching.firstIndex(where: { $0.uid == device.uid })
        else {
            return device.name
        }
        return "\(device.name)（\(index + 1)）"
    }

    package var canStartTest: Bool {
        isPreferenceReady && testStatus == .idle && routing.actualDevice == nil
            && routing.devices.isAvailable && resolvedDevice != nil
    }
}

@MainActor
package final class MicrophoneSelectionFeature: ObservableObject {
    package typealias PersistPreference = @Sendable (MicrophonePreference) async throws -> Void
    @Published package private(set) var state: MicrophoneSelectionState

    private let microphones: MicrophoneRouting
    private let levelTester: any MicrophoneLevelTesting
    private let persistPreference: PersistPreference
    private var observation: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var persistenceGeneration: UInt = 0
    private var levelCommand: Task<Void, Never>?
    private var levelObservation: Task<Void, Never>?
    private var levelGeneration: UInt = 0
    private var hasUserSelection = false
    private var hasRestored = false
    private var isShuttingDown = false

    package init(
        microphones: MicrophoneRouting,
        levelTester: any MicrophoneLevelTesting,
        persistPreference: @escaping PersistPreference
    ) {
        self.microphones = microphones
        self.levelTester = levelTester
        self.persistPreference = persistPreference
        state = MicrophoneSelectionState(routing: microphones.snapshot())
    }

    package func start() {
        guard !isShuttingDown, observation == nil else { return }
        let stream = microphones.observe()
        observation = Task { @MainActor [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
                // Buffered events can precede a synchronous user selection.
                self.state.routing = self.microphones.snapshot()
            }
        }
    }

    package func select(_ preference: MicrophonePreference) {
        guard !isShuttingDown else { return }
        hasUserSelection = true
        hasRestored = true
        state.isPreferenceReady = true
        microphones.select(preference)
        state.routing = microphones.snapshot()
        state.testError = nil
        persist(preference)
    }

    package func restore(_ preference: MicrophonePreference) {
        guard !isShuttingDown, !hasRestored, !hasUserSelection else { return }
        hasRestored = true
        state.isPreferenceReady = true
        microphones.select(preference)
        state.routing = microphones.snapshot()
    }

    package func refresh() {
        guard !isShuttingDown else { return }
        microphones.refresh()
        state.routing = microphones.snapshot()
    }

    package func retryPersistence() {
        guard !isShuttingDown, state.persistenceFailed else { return }
        persist(state.preference)
    }

    package func startLevelTest() {
        guard !isShuttingDown, state.canStartTest else { return }
        levelGeneration &+= 1
        let generation = levelGeneration
        state.testStatus = .starting
        state.testError = nil
        state.testLevel = 0
        let previous = levelCommand
        levelCommand = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.isShuttingDown, generation == self.levelGeneration else { return }
            do {
                let stream = try await self.levelTester.startLevelTest()
                guard generation == self.levelGeneration, !self.isShuttingDown else { return }
                self.state.testStatus = .testing
                self.state.routing = self.microphones.snapshot()
                self.levelObservation = Task { @MainActor [weak self] in
                    do {
                        for try await telemetry in stream {
                            guard let self, !Task.isCancelled, generation == self.levelGeneration
                            else { return }
                            self.state.testLevel = min(
                                1, max(0, Double(telemetry.peakPower + 60) / 60))
                        }
                    } catch {
                        guard let self, !Task.isCancelled, generation == self.levelGeneration else {
                            return
                        }
                        self.state.testError = Self.testError(error)
                    }
                    guard let self, generation == self.levelGeneration else { return }
                    self.state.testStatus = .idle
                    self.state.testLevel = 0
                    self.state.routing = self.microphones.snapshot()
                }
            } catch {
                guard generation == self.levelGeneration, !self.isShuttingDown else { return }
                self.state.testStatus = .idle
                self.state.testError = Self.testError(error)
                self.state.routing = self.microphones.snapshot()
            }
        }
    }

    package func stopLevelTest() {
        levelGeneration &+= 1
        let generation = levelGeneration
        state.testStatus = .stopping
        state.testLevel = 0
        levelObservation?.cancel()
        levelObservation = nil
        let previous = levelCommand
        levelCommand = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.levelTester.stopLevelTest()
            guard generation == self.levelGeneration else { return }
            self.state.testStatus = .idle
            self.state.routing = self.microphones.snapshot()
        }
    }

    package func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        observation?.cancel()
        observation = nil
        stopLevelTest()
        microphones.shutdown()
    }

    package func flushPersistence() async {
        await levelCommand?.value
        await persistenceTask?.value
    }

    private func persist(_ preference: MicrophonePreference) {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previous = persistenceTask
        persistenceTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.persistPreference(preference)
                guard generation == self.persistenceGeneration else { return }
                self.state.persistenceFailed = false
            } catch {
                guard generation == self.persistenceGeneration else { return }
                self.state.persistenceFailed = true
            }
        }
    }

    private static func testError(_ error: any Error) -> String {
        switch error as? AudioCaptureError {
        case .microphonePermissionDenied:
            "麦克风权限未开启。请在权限设置中允许 Speaker 使用麦克风。"
        case .microphoneUnavailable, .microphoneSelectionFailed:
            "无法使用所选麦克风。请重新连接或选择其他设备。"
        case .alreadyRecording:
            "正在进行语音输入，请结束录音后再测试。"
        default:
            "麦克风测试未能完成。请检查设备后重试。"
        }
    }
}
