import Foundation

public enum VoiceShortcutPreference: Equatable, Sendable, Codable {
    case functionKey
    case custom(keyCode: UInt32, modifiers: UInt32, displayName: String)

    public init(customHotKey: CustomHotKey?) {
        if let customHotKey {
            self = .custom(
                keyCode: customHotKey.keyCode,
                modifiers: customHotKey.modifiers,
                displayName: customHotKey.displayName
            )
        } else {
            self = .functionKey
        }
    }

    public var customHotKey: CustomHotKey? {
        switch self {
        case .functionKey:
            nil
        case let .custom(keyCode, modifiers, displayName):
            CustomHotKey(
                keyCode: keyCode,
                modifiers: modifiers,
                displayName: displayName
            )
        }
    }

    public var displayName: String {
        switch self {
        case .functionKey: "Fn"
        case let .custom(_, _, displayName): displayName
        }
    }

    private enum Kind: String, Codable {
        case functionKey
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifiers
        case displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .functionKey:
            self = .functionKey
        case .custom:
            self = .custom(
                keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                modifiers: try container.decode(UInt32.self, forKey: .modifiers),
                displayName: try container.decode(String.self, forKey: .displayName)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .functionKey:
            try container.encode(Kind.functionKey, forKey: .kind)
        case let .custom(keyCode, modifiers, displayName):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
            try container.encode(displayName, forKey: .displayName)
        }
    }
}

public enum RefinementPreference: Equatable, Sendable, Codable {
    case defaultSmooth
    case conciseCleanup
    case fullRewrite
    case custom(name: String, prompt: String)

    public init(mode: TextRefinementMode) {
        switch mode {
        case .defaultSmooth:
            self = .defaultSmooth
        case .conciseCleanup:
            self = .conciseCleanup
        case .fullRewrite:
            self = .fullRewrite
        case let .custom(name, prompt):
            self = .custom(name: name, prompt: prompt)
        }
    }

    public var textRefinementMode: TextRefinementMode {
        switch self {
        case .defaultSmooth:
            .defaultSmooth
        case .conciseCleanup:
            .conciseCleanup
        case .fullRewrite:
            .fullRewrite
        case let .custom(name, prompt):
            .custom(name: name, prompt: prompt)
        }
    }

    private enum Kind: String, Codable {
        case defaultSmooth
        case conciseCleanup
        case fullRewrite
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .defaultSmooth:
            self = .defaultSmooth
        case .conciseCleanup:
            self = .conciseCleanup
        case .fullRewrite:
            self = .fullRewrite
        case .custom:
            self = .custom(
                name: try container.decode(String.self, forKey: .name),
                prompt: try container.decode(String.self, forKey: .prompt)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultSmooth:
            try container.encode(Kind.defaultSmooth, forKey: .kind)
        case .conciseCleanup:
            try container.encode(Kind.conciseCleanup, forKey: .kind)
        case .fullRewrite:
            try container.encode(Kind.fullRewrite, forKey: .kind)
        case let .custom(name, prompt):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(prompt, forKey: .prompt)
        }
    }
}

public enum HistoryRetentionPolicy: String, CaseIterable, Equatable, Sendable, Codable {
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    public var maximumAgeDays: Int? {
        switch self {
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneYear: 365
        case .forever: nil
        }
    }
}

public struct SpeakerAppSettings: Equatable, Sendable, Codable {
    public var shortcut: VoiceShortcutPreference
    public var refinement: RefinementPreference
    public var savedCustomRefinement: RefinementPreference?
    public var launchAtLogin: Bool
    public var doubaoResourceID: String?
    public var historyRetention: HistoryRetentionPolicy

    public init(
        shortcut: VoiceShortcutPreference = .functionKey,
        refinement: RefinementPreference = .defaultSmooth,
        savedCustomRefinement: RefinementPreference? = nil,
        launchAtLogin: Bool = false,
        doubaoResourceID: String? = nil,
        historyRetention: HistoryRetentionPolicy = .forever
    ) {
        self.shortcut = shortcut
        self.refinement = refinement
        self.savedCustomRefinement = savedCustomRefinement
        self.launchAtLogin = launchAtLogin
        self.doubaoResourceID = doubaoResourceID
        self.historyRetention = historyRetention
    }

    public static let `default` = SpeakerAppSettings()

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case refinement
        case savedCustomRefinement
        case launchAtLogin
        case doubaoResourceID
        case historyRetention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decode(
            VoiceShortcutPreference.self,
            forKey: .shortcut
        )
        refinement = try container.decode(
            RefinementPreference.self,
            forKey: .refinement
        )
        savedCustomRefinement = try container.decodeIfPresent(
            RefinementPreference.self,
            forKey: .savedCustomRefinement
        )
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        doubaoResourceID = try container.decodeIfPresent(
            String.self,
            forKey: .doubaoResourceID
        )
        // Preserve history until the user makes an explicit retention choice.
        // The hard record cap remains an independent resource-safety boundary.
        historyRetention = try container.decodeIfPresent(
            HistoryRetentionPolicy.self,
            forKey: .historyRetention
        ) ?? .forever
    }
}

public enum AppSettingsRecoveryReason: Equatable, Sendable {
    case corrupted(reason: String)
    case unsupportedVersion(Int)
}

public struct AppSettingsRecovery: Equatable, Sendable {
    public let backupURL: URL
    public let reason: AppSettingsRecoveryReason

    public init(backupURL: URL, reason: AppSettingsRecoveryReason) {
        self.backupURL = backupURL
        self.reason = reason
    }
}

public enum AppSettingsLoadResult: Equatable, Sendable {
    case defaults(SpeakerAppSettings)
    case loaded(SpeakerAppSettings)
    case recovered(SpeakerAppSettings, recovery: AppSettingsRecovery)
    case recoveryFailed(SpeakerAppSettings, reason: String)

    public var settings: SpeakerAppSettings {
        switch self {
        case let .defaults(settings),
             let .loaded(settings),
             let .recovered(settings, _),
             let .recoveryFailed(settings, _):
            settings
        }
    }
}

public enum AppSettingsStoreError: Error, Equatable, Sendable {
    case writeFailed(reason: String)
}

extension AppSettingsStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .writeFailed(reason):
            "无法保存 Speaker 设置：\(reason)"
        }
    }
}

public actor VersionedLocalAppSettingsStore {
    public static let currentSchemaVersion = 1
    private static let maximumDocumentByteCount = 1 * 1_024 * 1_024

    private let fileURL: URL
    private let fileProtection: LocalFileProtection

    public init(fileURL: URL) {
        self.fileURL = fileURL
        fileProtection = .ownerOnly
    }

    package init(
        fileURL: URL,
        fileProtection: LocalFileProtection
    ) {
        self.fileURL = fileURL
        self.fileProtection = fileProtection
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser

        return baseDirectory
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public func load() -> AppSettingsLoadResult {
        Self.pruneRecoveryArtifacts(for: fileURL)
        do {
            try fileProtection.protect(fileURL)
        } catch {
            return .recoveryFailed(
                .default,
                reason: "无法保护设置文件权限，已停止加载本机设置。"
            )
        }
        let data: Data
        do {
            guard let storedData = try OwnerOnlyFilePersistence.read(
                from: fileURL,
                maximumByteCount: Self.maximumDocumentByteCount
            ) else {
                return .defaults(.default)
            }
            data = storedData
        } catch {
            return .recoveryFailed(
                .default,
                reason: "无法安全读取设置文件，已停止加载：\(Self.safeReason(for: error))"
            )
        }

        let version: Int
        do {
            version = try Self.decoder
                .decode(SettingsDocumentVersion.self, from: data)
                .schemaVersion
        } catch {
            return recover(
                reason: .corrupted(reason: Self.safeReason(for: error))
            )
        }

        // Version dispatch is the migration seam. Each future document version
        // can decode its own DTO and map it into `SpeakerAppSettings` here.
        switch version {
        case 1:
            do {
                let document = try Self.decoder.decode(SettingsDocumentV1.self, from: data)
                return .loaded(document.settings)
            } catch {
                return recover(
                    reason: .corrupted(reason: Self.safeReason(for: error))
                )
            }
        default:
            return recover(reason: .unsupportedVersion(version))
        }
    }

    public func save(_ settings: SpeakerAppSettings) throws {
        do {
            let document = SettingsDocumentV1(
                schemaVersion: Self.currentSchemaVersion,
                settings: settings
            )
            let data = try Self.encoder.encode(document)
            guard data.count <= Self.maximumDocumentByteCount else {
                throw OwnerOnlyFilePersistenceError.fileTooLarge(
                    maximumByteCount: Self.maximumDocumentByteCount
                )
            }
            try OwnerOnlyFilePersistence.write(data, to: fileURL)
        } catch {
            throw AppSettingsStoreError.writeFailed(
                reason: Self.safeReason(for: error)
            )
        }
    }

    @discardableResult
    public func updateShortcut(
        _ shortcut: VoiceShortcutPreference
    ) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.shortcut = shortcut
        try save(settings)
        return settings
    }

    @discardableResult
    public func updateRefinement(
        _ refinement: RefinementPreference
    ) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.refinement = refinement
        try save(settings)
        return settings
    }

    @discardableResult
    public func updateSavedCustomRefinement(
        _ refinement: RefinementPreference
    ) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.savedCustomRefinement = refinement
        try save(settings)
        return settings
    }

    @discardableResult
    public func updateLaunchAtLogin(_ enabled: Bool) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.launchAtLogin = enabled
        try save(settings)
        return settings
    }

    @discardableResult
    public func updateDoubaoResource(
        _ resource: DoubaoStreamingResource
    ) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.doubaoResourceID = resource.rawValue
        try save(settings)
        return settings
    }

    @discardableResult
    public func updateHistoryRetention(
        _ policy: HistoryRetentionPolicy
    ) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.historyRetention = policy
        try save(settings)
        return settings
    }

    private func settingsForUpdate() throws -> SpeakerAppSettings {
        let result = load()
        guard case let .recoveryFailed(_, reason) = result else {
            return result.settings
        }
        throw AppSettingsStoreError.writeFailed(
            reason: "原设置文件无法安全读取，已保留原文件且拒绝覆盖：\(reason)"
        )
    }

    private func recover(reason: AppSettingsRecoveryReason) -> AppSettingsLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("recovery-\(timestamp)-\(UUID().uuidString).json")

        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            Self.pruneRecoveryArtifacts(
                for: fileURL,
                preserving: backupURL
            )
            return .recovered(
                .default,
                recovery: AppSettingsRecovery(backupURL: backupURL, reason: reason)
            )
        } catch {
            return .recoveryFailed(
                .default,
                reason: "Settings could not be recovered: \(Self.safeReason(for: error))"
            )
        }
    }

    private static func pruneRecoveryArtifacts(
        for fileURL: URL,
        preserving preservedURL: URL? = nil
    ) {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        RecoveryArchivePruner.pruneRegularFiles(
            in: fileURL.deletingLastPathComponent(),
            prefix: "\(baseName).recovery-",
            suffix: ".json",
            preserving: preservedURL
        )
    }
}

private extension VersionedLocalAppSettingsStore {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }

    static func safeReason(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
}

private struct SettingsDocumentVersion: Decodable {
    let schemaVersion: Int
}

private struct SettingsDocumentV1: Codable {
    let schemaVersion: Int
    let settings: SpeakerAppSettings
}
