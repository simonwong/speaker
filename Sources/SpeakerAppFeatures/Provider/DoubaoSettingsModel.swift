import Combine
import Foundation
import SpeakerCore

package protocol DoubaoSettingsServicing: Sendable {
    func setResource(_ resource: DoubaoStreamingResource) async
    func hasAPIKey() async throws -> Bool
    func saveAPIKey(_ apiKey: String) async throws
    func deleteAPIKey() async throws
    func checkConnection() async throws -> String?
}

extension CredentialedDoubaoTranscriber: DoubaoSettingsServicing {}

@MainActor
package final class DoubaoSettingsModel: ObservableObject {
    @Published package var apiKeyDraft = ""
    @Published package private(set) var status: DoubaoConnectionStatus = .loading
    @Published package private(set) var hasStoredKey = false
    @Published package private(set) var resource: DoubaoStreamingResource = .default

    private let service: any DoubaoSettingsServicing
    private let settingsStore: VersionedLocalAppSettingsStore
    private var generation: UInt64 = 0
    private var checkTask: Task<Void, Never>?

    package init(
        service: any DoubaoSettingsServicing,
        settingsStore: VersionedLocalAppSettingsStore
    ) {
        self.service = service
        self.settingsStore = settingsStore
    }

    package func loadResource(rawValue: String?) async {
        let selected = rawValue.flatMap(
            DoubaoStreamingResource.init(rawValue:)
        ) ?? .default
        let token = invalidateConnectionCheck()
        resource = selected
        await service.setResource(selected)
        guard token == generation else { return }
    }

    package func selectResource(
        _ selected: DoubaoStreamingResource
    ) async {
        let token = invalidateConnectionCheck()
        resource = selected
        await service.setResource(selected)
        do {
            try await settingsStore.updateDoubaoResource(selected)
            guard token == generation, resource == selected else { return }
            status = hasStoredKey ? .configured : .unconfigured
        } catch {
            guard token == generation, resource == selected else { return }
            status = .failure(error.localizedDescription)
        }
    }

    package func refresh() async {
        let token = generation
        do {
            let storedKeyExists = try await service.hasAPIKey()
            guard token == generation else { return }
            hasStoredKey = storedKeyExists
            status = status.afterCredentialRefresh(
                keyExists: storedKeyExists
            )
        } catch {
            guard token == generation else { return }
            status = .failure(error.localizedDescription)
        }
    }

    package func save() async {
        let token = invalidateConnectionCheck()
        do {
            try await service.saveAPIKey(apiKeyDraft)
            guard token == generation else { return }
            apiKeyDraft = ""
            hasStoredKey = true
            status = .configured
        } catch {
            guard token == generation else { return }
            status = .failure(error.localizedDescription)
        }
    }

    package func checkConnection() {
        let token = invalidateConnectionCheck()
        let checkedResource = resource
        status = .checking
        let service = service
        checkTask = Task { @MainActor [weak self] in
            let result: Result<String?, Error>
            do {
                result = .success(try await service.checkConnection())
            } catch {
                result = .failure(error)
            }
            guard let self,
                  token == generation,
                  resource == checkedResource,
                  hasStoredKey
            else { return }
            checkTask = nil
            switch result {
            case let .success(requestID):
                status = .success(requestID)
            case let .failure(failure as DoubaoASRFailure):
                status = .failure(Self.message(for: failure))
            case let .failure(error):
                status = .failure(error.localizedDescription)
            }
        }
    }

    package func delete() async {
        let token = invalidateConnectionCheck()
        do {
            try await service.deleteAPIKey()
            guard token == generation else { return }
            apiKeyDraft = ""
            hasStoredKey = false
            status = .unconfigured
        } catch {
            guard token == generation else { return }
            status = .failure(error.localizedDescription)
        }
    }

    package func shutdown() async {
        generation &+= 1
        let task = checkTask
        checkTask = nil
        task?.cancel()
        await task?.value
    }

    package var hasConfiguredKey: Bool {
        hasStoredKey
    }

    package var summary: String {
        switch status {
        case .loading:
            "正在读取本机配置…"
        case .unconfigured:
            "未配置"
        case .configured:
            "已保存在这台 Mac"
        case .checking:
            "正在检查连接…"
        case let .success(requestID):
            requestID.map { "连接成功 · \($0)" } ?? "连接成功"
        case let .failure(message):
            message
        }
    }

    @discardableResult
    private func invalidateConnectionCheck() -> UInt64 {
        generation &+= 1
        checkTask?.cancel()
        checkTask = nil
        return generation
    }

    private static func message(for failure: DoubaoASRFailure) -> String {
        if failure.kind == .cancelled { return "连接检查已取消" }
        return VoiceInputProblem(doubaoFailure: failure).failure.userTitle
    }
}
