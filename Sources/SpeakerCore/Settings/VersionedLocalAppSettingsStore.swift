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

public struct SpeakerAppSettings: Equatable, Sendable, Codable {
    public var shortcut: VoiceShortcutPreference
    public var refinement: RefinementPreference
    public var launchAtLogin: Bool

    public init(
        shortcut: VoiceShortcutPreference = .functionKey,
        refinement: RefinementPreference = .defaultSmooth,
        launchAtLogin: Bool = false
    ) {
        self.shortcut = shortcut
        self.refinement = refinement
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = SpeakerAppSettings()
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

public actor VersionedLocalAppSettingsStore {
    public static let currentSchemaVersion = 1

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .defaults(.default)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return recover(
                reason: .corrupted(reason: Self.safeReason(for: error))
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
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw AppSettingsStoreError.writeFailed(
                reason: Self.safeReason(for: error)
            )
        }
    }

    private func recover(reason: AppSettingsRecoveryReason) -> AppSettingsLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("recovery-\(timestamp)-\(UUID().uuidString).json")

        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
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
