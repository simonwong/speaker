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
        case .custom(let keyCode, let modifiers, let displayName):
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
        case .custom(_, _, let displayName): displayName
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
        case .custom(let keyCode, let modifiers, let displayName):
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
        case .custom(let name, let prompt):
            self = .custom(name: name, prompt: prompt)
        }
    }

    public var textRefinementMode: TextRefinementMode {
        switch self {
        case .defaultSmooth:
            .defaultSmooth
        case .conciseCleanup:
            .conciseCleanup()
        case .fullRewrite:
            .fullRewrite()
        case .custom(let name, let prompt):
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
        case .custom(let name, let prompt):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(prompt, forKey: .prompt)
        }
    }
}

public enum HistoryRetentionPolicy: String, CaseIterable, Equatable, Sendable, Codable {
    case disabled
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    public var maximumAgeDays: Int? {
        switch self {
        case .disabled: nil
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneYear: 365
        case .forever: nil
        }
    }

    public var savesNewRecords: Bool {
        self != .disabled
    }
}

/// Per-mode user replacements for the built-in DeepSeek refinement prompts.
/// Modes without a built-in prompt (Default Smoothing, Custom Mode) can never
/// hold an override here.
public struct RefinementPromptOverrides: Equatable, Sendable, Codable {
    public var conciseCleanup: String?
    public var fullRewrite: String?

    public init(conciseCleanup: String? = nil, fullRewrite: String? = nil) {
        self.conciseCleanup = conciseCleanup
        self.fullRewrite = fullRewrite
    }

    package subscript(mode: BuiltInRefinementMode) -> String? {
        get {
            switch mode {
            case .conciseCleanup: conciseCleanup
            case .fullRewrite: fullRewrite
            }
        }
        set {
            switch mode {
            case .conciseCleanup: conciseCleanup = newValue
            case .fullRewrite: fullRewrite = newValue
            }
        }
    }

    public subscript(mode: TextRefinementMode) -> String? {
        get {
            guard let builtInMode = mode.builtInMode else { return nil }
            return self[builtInMode]
        }
        set {
            guard let builtInMode = mode.builtInMode else { return }
            self[builtInMode] = newValue
        }
    }
}

public struct SpeakerAppSettings: Equatable, Sendable, Codable {
    public var shortcut: VoiceShortcutPreference
    public var refinement: RefinementPreference
    public var savedCustomRefinement: RefinementPreference?
    public var refinementPromptOverrides: RefinementPromptOverrides
    public var launchAtLogin: Bool
    public var doubaoResourceID: String?
    public var historyRetention: HistoryRetentionPolicy
    public var historyRetentionWhenEnabled: HistoryRetentionPolicy

    public init(
        shortcut: VoiceShortcutPreference = .functionKey,
        refinement: RefinementPreference = .defaultSmooth,
        savedCustomRefinement: RefinementPreference? = nil,
        refinementPromptOverrides: RefinementPromptOverrides = RefinementPromptOverrides(),
        launchAtLogin: Bool = false,
        doubaoResourceID: String? = nil,
        historyRetention: HistoryRetentionPolicy = .forever,
        historyRetentionWhenEnabled: HistoryRetentionPolicy? = nil
    ) {
        self.shortcut = shortcut
        self.refinement = refinement
        self.savedCustomRefinement = savedCustomRefinement
        self.refinementPromptOverrides = refinementPromptOverrides
        self.launchAtLogin = launchAtLogin
        self.doubaoResourceID = doubaoResourceID
        self.historyRetention = historyRetention
        self.historyRetentionWhenEnabled = Self.enabledRetention(
            historyRetentionWhenEnabled ?? historyRetention
        )
    }

    public static let `default` = SpeakerAppSettings()

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case refinement
        case savedCustomRefinement
        case refinementPromptOverrides
        case launchAtLogin
        case doubaoResourceID
        case historyRetention
        case historyRetentionWhenEnabled
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
        // Incremental field: settings.json written before prompt overrides
        // existed decodes with no overrides.
        refinementPromptOverrides =
            try container.decodeIfPresent(
                RefinementPromptOverrides.self,
                forKey: .refinementPromptOverrides
            ) ?? RefinementPromptOverrides()
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        doubaoResourceID = try container.decodeIfPresent(
            String.self,
            forKey: .doubaoResourceID
        )
        // Preserve history until the user makes an explicit retention choice.
        // The hard record cap remains an independent resource-safety boundary.
        historyRetention =
            try container.decodeIfPresent(
                HistoryRetentionPolicy.self,
                forKey: .historyRetention
            ) ?? .forever
        let rememberedRetention =
            try container.decodeIfPresent(
                HistoryRetentionPolicy.self,
                forKey: .historyRetentionWhenEnabled
            ) ?? historyRetention
        historyRetentionWhenEnabled = Self.enabledRetention(
            rememberedRetention
        )
    }

    private static func enabledRetention(
        _ policy: HistoryRetentionPolicy
    ) -> HistoryRetentionPolicy {
        policy.savesNewRecords ? policy : .forever
    }
}

public typealias AppSettingsRecoveryReason = DocumentCorruption

public struct AppSettingsRecovery: Equatable, Sendable {
    public let backupURL: URL
    public let reason: AppSettingsRecoveryReason

    public init(backupURL: URL, reason: AppSettingsRecoveryReason) {
        self.backupURL = backupURL
        self.reason = reason
    }
}

/// Why the settings file could not be loaded or recovered. Details are the
/// privacy-safe reasons the document store already produced.
public enum AppSettingsLoadFailure: Equatable, Sendable {
    case protectionFailed
    case readFailed(detail: String)
    case preservationFailed(detail: String)
}

public enum AppSettingsLoadResult: Equatable, Sendable {
    case defaults(SpeakerAppSettings)
    case loaded(SpeakerAppSettings)
    case recovered(SpeakerAppSettings, recovery: AppSettingsRecovery)
    case recoveryFailed(SpeakerAppSettings, failure: AppSettingsLoadFailure)

    public var settings: SpeakerAppSettings {
        switch self {
        case .defaults(let settings),
            .loaded(let settings),
            .recovered(let settings, _),
            .recoveryFailed(let settings, _):
            settings
        }
    }
}

/// Structured settings-write failures; SpeakerAppFeatures renders the sentence.
public enum AppSettingsStoreError: Error, Equatable, Sendable {
    case writeFailed(reason: String)
    /// The existing file could not be read safely, so it was kept and the
    /// write refused rather than overwriting it.
    case sourceUnreadable(AppSettingsLoadFailure)
}

/// The settings-writing seam the Settings feature models depend on. It carries
/// only the operations those models call, so a specification can substitute a
/// fake store without a file on disk.
public protocol AppSettingsStoring: Sendable {
    func load() async -> AppSettingsLoadResult

    @discardableResult
    func updateRefinement(
        _ refinement: RefinementPreference
    ) async throws -> SpeakerAppSettings

    @discardableResult
    func updateSavedCustomRefinement(
        _ refinement: RefinementPreference
    ) async throws -> SpeakerAppSettings

    @discardableResult
    func updateRefinementPromptOverride(
        _ promptOverride: String?,
        for mode: TextRefinementMode
    ) async throws -> SpeakerAppSettings

    @discardableResult
    func updateHistoryRetention(
        _ policy: HistoryRetentionPolicy
    ) async throws -> SpeakerAppSettings
}

public actor VersionedLocalAppSettingsStore: AppSettingsStoring {
    public static let currentSchemaVersion = 1
    private static let maximumDocumentByteCount = 1 * 1_024 * 1_024

    private let documents: VersionedOwnerOnlyDocumentStore<SpeakerAppSettings>

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, fileProtection: .ownerOnly)
    }

    package init(
        fileURL: URL,
        fileProtection: LocalFileProtection
    ) {
        documents = VersionedOwnerOnlyDocumentStore(
            fileURL: fileURL,
            schema: Self.schema,
            maximumByteCount: Self.maximumDocumentByteCount,
            backupInfix: "recovery-",
            fileProtection: fileProtection
        )
    }

    /// Version dispatch is the migration seam. Each future document version
    /// decodes its own DTO and maps it into `SpeakerAppSettings` here.
    private static let schema = VersionedDocumentSchema<SpeakerAppSettings>(
        currentVersion: currentSchemaVersion,
        versionKey: .schemaVersion,
        decoders: [
            1: { data in
                try decoder.decode(SettingsDocumentV1.self, from: data).settings
            }
        ]
    )

    public static func defaultFileURL(
        fileManager: FileManager = .default,
        applicationDirectoryName: String = "Speaker"
    ) -> URL {
        let baseDirectory =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser

        return
            baseDirectory
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public func load() -> AppSettingsLoadResult {
        switch documents.load().outcome {
        case .absent:
            return .defaults(.default)
        case .loaded(let settings, _):
            return .loaded(settings)
        case .corruptedPreserved(let backupURL, let corruption):
            return .recovered(
                .default,
                recovery: AppSettingsRecovery(backupURL: backupURL, reason: corruption)
            )
        case .failed(.protectionFailed):
            return .recoveryFailed(.default, failure: .protectionFailed)
        case .failed(.readFailed(let detail)):
            return .recoveryFailed(.default, failure: .readFailed(detail: detail))
        case .failed(.preservationFailed(_, let detail)):
            return .recoveryFailed(.default, failure: .preservationFailed(detail: detail))
        }
    }

    public func save(_ settings: SpeakerAppSettings) throws {
        do {
            let document = SettingsDocumentV1(
                schemaVersion: Self.currentSchemaVersion,
                settings: settings
            )
            try documents.write(try Self.encoder.encode(document))
        } catch {
            throw AppSettingsStoreError.writeFailed(
                reason: PrivacySafeText.reason(for: error)
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

    /// Saves (or, when nil, restores) one built-in mode's prompt override
    /// without touching the selected refinement mode.
    @discardableResult
    public func updateRefinementPromptOverride(
        _ promptOverride: String?,
        for mode: TextRefinementMode
    ) throws -> SpeakerAppSettings {
        var settings = try settingsForUpdate()
        settings.refinementPromptOverrides[mode] = promptOverride
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
        if policy.savesNewRecords {
            settings.historyRetentionWhenEnabled = policy
        }
        settings.historyRetention = policy
        try save(settings)
        return settings
    }

    private func settingsForUpdate() throws -> SpeakerAppSettings {
        let result = load()
        guard case .recoveryFailed(_, let failure) = result else {
            return result.settings
        }
        throw AppSettingsStoreError.sourceUnreadable(failure)
    }
}

extension VersionedLocalAppSettingsStore {
    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    fileprivate static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

private struct SettingsDocumentV1: Codable {
    let schemaVersion: Int
    let settings: SpeakerAppSettings
}
