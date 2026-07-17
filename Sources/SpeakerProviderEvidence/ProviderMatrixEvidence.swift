import Darwin
import Foundation

public enum ProviderEvidenceError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidSchema(String)
    case unsafePath
    case fileAlreadyExists
    case inputTooLarge
}

public enum EvidenceProvider: String, Codable, CaseIterable, Sendable {
    case doubao
    case deepSeek = "deepseek"
}

public enum EvidenceCredentialSource: String, Codable, Sendable {
    case developmentOwnerOnlyFile
    case signedAppKeychain
}

public enum EvidenceStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
}

public enum EvidenceOutcome: String, Codable, Sendable {
    case passed
    case cancelled
    case invalidCredential
    case authentication
    case notConfigured
    case sampleMissing
    case invalidSample
    case emptyTranscript
    case acceptedAfterCancellation
    case semanticOracleFailed
    case providerFailure
    case credentialFailure
    case unexpected
}

public enum ProviderMatrixCaseID: String, Codable, CaseIterable, Sendable {
    case doubaoConnection = "doubao.connection"
    case doubaoAudio1Second = "doubao.audio-1s"
    case doubaoAudio5Seconds = "doubao.audio-5s"
    case doubaoAudio15Seconds = "doubao.audio-15s"
    case doubaoAudio60Seconds = "doubao.audio-60s"
    case doubaoCancelStreaming = "doubao.cancel-streaming"
    case doubaoInvalidCredential = "doubao.invalid-credential"
    case deepSeekConnection = "deepseek.connection"
    case deepSeekModeConcise = "deepseek.mode-concise"
    case deepSeekModeRewrite = "deepseek.mode-rewrite"
    case deepSeekModeCustom = "deepseek.mode-custom"
    case deepSeekCancelInFlight = "deepseek.cancel-in-flight"
    case deepSeekInvalidCredential = "deepseek.invalid-credential"

    public var provider: EvidenceProvider {
        rawValue.hasPrefix("doubao.") ? .doubao : .deepSeek
    }
}

public struct ProviderEvidenceEnvironment: Codable, Equatable, Sendable {
    public let sourceCommit: String
    public let sourceTreeClean: Bool
    public let packageResolvedSHA256: String
    public let candidateVersion: String
    public let candidateBuild: String
    public let macOSVersion: String
    public let architecture: String

    public init(
        sourceCommit: String,
        sourceTreeClean: Bool,
        packageResolvedSHA256: String,
        candidateVersion: String,
        candidateBuild: String,
        macOSVersion: String,
        architecture: String
    ) {
        self.sourceCommit = sourceCommit
        self.sourceTreeClean = sourceTreeClean
        self.packageResolvedSHA256 = packageResolvedSHA256
        self.candidateVersion = candidateVersion
        self.candidateBuild = candidateBuild
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }
}

public struct ProviderEvidenceConfiguration: Codable, Equatable, Sendable {
    public let provider: EvidenceProvider
    public let credentialSource: EvidenceCredentialSource
    public let resource: String?
    public let model: String

    public init(
        provider: EvidenceProvider,
        credentialSource: EvidenceCredentialSource,
        resource: String?,
        model: String
    ) {
        self.provider = provider
        self.credentialSource = credentialSource
        self.resource = resource
        self.model = model
    }
}

public struct ProviderEvidenceCase: Codable, Equatable, Sendable {
    public let provider: EvidenceProvider
    public let caseID: ProviderMatrixCaseID
    public let status: EvidenceStatus
    public let outcome: EvidenceOutcome
    public let providerStatusCode: String?
    public let requestID: String?

    public init(
        provider: EvidenceProvider,
        caseID: ProviderMatrixCaseID,
        status: EvidenceStatus,
        outcome: EvidenceOutcome,
        providerStatusCode: String? = nil,
        requestID: String? = nil
    ) {
        self.provider = provider
        self.caseID = caseID
        self.status = status
        self.outcome = outcome
        self.providerStatusCode = ProviderMatrixEvidence.safeToken(providerStatusCode)
        self.requestID = ProviderMatrixEvidence.safeToken(requestID)
    }

    public var privacySafeSummary: String {
        "provider=\(provider.rawValue) case=\(caseID.rawValue) "
            + "result=\(status.rawValue) outcome=\(outcome.rawValue)"
            + providerStatusCode.map { " status=\($0)" }.orEmpty
            + requestID.map { " requestID=\($0)" }.orEmpty
    }
}

public struct ProviderMatrixEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumEvidenceBytes = 256 * 1_024
    public static let fileName = "speaker-provider-matrix.json"

    public let schemaVersion: Int
    public let generatedAt: Date
    public let environment: ProviderEvidenceEnvironment
    public let providers: [ProviderEvidenceConfiguration]
    public let cases: [ProviderEvidenceCase]

    public init(
        generatedAt: Date,
        environment: ProviderEvidenceEnvironment,
        providers: [ProviderEvidenceConfiguration],
        cases: [ProviderEvidenceCase]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.environment = environment
        self.providers = providers
        self.cases = cases
    }

    public static func safeToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 200,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 58 || byte == 95
              })
        else { return nil }
        return value
    }

    public func validate(
        requirePassingCases: Bool,
        requireSignedAppKeychain: Bool
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProviderEvidenceError.invalidSchema("schemaVersion")
        }
        guard Self.matches(environment.sourceCommit, "^[0-9a-f]{40}$"),
              Self.matches(environment.packageResolvedSHA256, "^[0-9a-f]{64}$"),
              Self.matches(environment.candidateVersion, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$"),
              Self.matches(environment.candidateBuild, "^[1-9][0-9]*$"),
              Self.matches(environment.macOSVersion, "^[0-9]+(\\.[0-9]+){1,2}$"),
              ["arm64", "x86_64"].contains(environment.architecture)
        else {
            throw ProviderEvidenceError.invalidSchema("environment")
        }
        guard !requirePassingCases || environment.sourceTreeClean else {
            throw ProviderEvidenceError.invalidSchema("sourceTreeDirty")
        }

        guard providers.count == EvidenceProvider.allCases.count,
              Set(providers.map(\.provider)).count == EvidenceProvider.allCases.count
        else {
            throw ProviderEvidenceError.invalidSchema("providers")
        }
        for provider in providers {
            if requireSignedAppKeychain,
               provider.credentialSource != .signedAppKeychain {
                throw ProviderEvidenceError.invalidSchema("credentialSource")
            }
            switch provider.provider {
            case .doubao:
                guard [
                    "volc.seedasr.sauc.duration",
                    "volc.seedasr.sauc.concurrent",
                    "volc.bigasr.sauc.duration",
                    "volc.bigasr.sauc.concurrent",
                ].contains(provider.resource), provider.model == "bigmodel" else {
                    throw ProviderEvidenceError.invalidSchema("doubaoConfiguration")
                }
            case .deepSeek:
                guard provider.resource == nil, provider.model == "deepseek-v4-flash" else {
                    throw ProviderEvidenceError.invalidSchema("deepSeekConfiguration")
                }
            }
        }

        guard cases.count == ProviderMatrixCaseID.allCases.count,
              Set(cases.map(\.caseID)).count == ProviderMatrixCaseID.allCases.count,
              Set(cases.map(\.caseID)) == Set(ProviderMatrixCaseID.allCases)
        else {
            throw ProviderEvidenceError.invalidSchema("caseSet")
        }
        for result in cases {
            guard result.provider == result.caseID.provider,
                  result.providerStatusCode == Self.safeToken(result.providerStatusCode),
                  result.requestID == Self.safeToken(result.requestID)
            else {
                throw ProviderEvidenceError.invalidSchema("caseIdentity")
            }
            let allowedOutcomes: Set<EvidenceOutcome>
            switch result.status {
            case .pass:
                allowedOutcomes = [.passed, .cancelled, .invalidCredential, .authentication]
            case .fail:
                allowedOutcomes = [
                    .invalidSample, .emptyTranscript, .acceptedAfterCancellation,
                    .semanticOracleFailed, .providerFailure, .credentialFailure,
                    .unexpected,
                ]
            case .skip:
                allowedOutcomes = [.notConfigured, .sampleMissing]
            }
            guard allowedOutcomes.contains(result.outcome) else {
                throw ProviderEvidenceError.invalidSchema("caseOutcome")
            }
            guard !requirePassingCases || result.status == .pass else {
                throw ProviderEvidenceError.invalidSchema("incompleteMatrix")
            }
        }
    }

    public func encoded() throws -> Data {
        try validate(requirePassingCases: false, requireSignedAppKeychain: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decodeStrict(_ data: Data) throws -> Self {
        guard data.count <= maximumEvidenceBytes else {
            throw ProviderEvidenceError.inputTooLarge
        }
        try StrictEvidenceJSON.validate(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let evidence = try decoder.decode(Self.self, from: data)
            try evidence.validate(requirePassingCases: false, requireSignedAppKeychain: false)
            return evidence
        } catch let error as ProviderEvidenceError {
            throw error
        } catch {
            throw ProviderEvidenceError.invalidJSON
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum ProviderEvidenceFile {
    public static func writeAtomically(
        _ evidence: ProviderMatrixEvidence,
        toNewDirectory directoryURL: URL
    ) throws -> URL {
        let parent = try SecureDirectory.openNoFollow(
            directoryURL.deletingLastPathComponent()
        )
        defer { close(parent) }
        let directoryName = try SecureDirectory.basename(of: directoryURL)
        guard mkdirat(parent, directoryName, S_IRWXU) == 0 else {
            throw errno == EEXIST
                ? ProviderEvidenceError.fileAlreadyExists
                : ProviderEvidenceError.unsafePath
        }
        do {
            let directory = openat(
                parent,
                directoryName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard directory >= 0 else { throw ProviderEvidenceError.unsafePath }
            defer { close(directory) }
            guard fchmod(directory, S_IRWXU) == 0 else {
                throw ProviderEvidenceError.unsafePath
            }
            var info = stat()
            guard fstat(directory, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o700
            else { throw ProviderEvidenceError.unsafePath }

            let data = try evidence.encoded()
            let temporary = ".provider-matrix-\(UUID().uuidString).tmp"
            let descriptor = openat(
                directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw ProviderEvidenceError.unsafePath }
            var shouldRemoveTemporary = true
            defer {
                close(descriptor)
                if shouldRemoveTemporary { _ = unlinkat(directory, temporary, 0) }
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw ProviderEvidenceError.unsafePath
            }
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: written),
                        bytes.count - written
                    )
                    guard count > 0 else { throw ProviderEvidenceError.unsafePath }
                    written += count
                }
            }
            guard fsync(descriptor) == 0,
                  renameatx_np(directory, temporary, directory, ProviderMatrixEvidence.fileName, UInt32(RENAME_EXCL)) == 0,
                  fsync(directory) == 0
            else {
                throw errno == EEXIST
                    ? ProviderEvidenceError.fileAlreadyExists
                    : ProviderEvidenceError.unsafePath
            }
            shouldRemoveTemporary = false
            return directoryURL.appendingPathComponent(ProviderMatrixEvidence.fileName)
        } catch {
            _ = unlinkat(parent, directoryName, AT_REMOVEDIR)
            throw error
        }
    }

    public static func readSecurely(from url: URL) throws -> Data {
        let parentURL = url.deletingLastPathComponent()
        let basename = try SecureDirectory.basename(of: url)
        let directory = try SecureDirectory.openNoFollow(parentURL)
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o777 == 0o700
        else { throw ProviderEvidenceError.unsafePath }
        let descriptor = openat(
            directory, basename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw ProviderEvidenceError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_size > 0,
              info.st_size <= ProviderMatrixEvidence.maximumEvidenceBytes
        else { throw ProviderEvidenceError.unsafePath }
        guard let data = try handle.readToEnd(), data.count == Int(info.st_size) else {
            throw ProviderEvidenceError.unsafePath
        }
        return data
    }
}

private enum SecureDirectory {
    static func basename(of url: URL) throws -> String {
        let value = url.lastPathComponent
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/") else {
            throw ProviderEvidenceError.unsafePath
        }
        return value
    }

    /// Opens every existing path component relative to the previously opened
    /// directory. This keeps validation and use on the same descriptor chain,
    /// so an ancestor cannot be swapped to a symlink between `lstat` and the
    /// final `open`.
    static func openNoFollow(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ProviderEvidenceError.unsafePath
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw ProviderEvidenceError.unsafePath
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProviderEvidenceError.unsafePath }
        for component in components {
            let next = openat(
                descriptor,
                String(component),
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard next >= 0 else {
                close(descriptor)
                throw ProviderEvidenceError.unsafePath
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }
}

private enum StrictEvidenceJSON {
    static func validate(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ProviderEvidenceError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw ProviderEvidenceError.invalidJSON
        }
        try exactKeys(root, ["schemaVersion", "generatedAt", "environment", "providers", "cases"])
        guard let environment = root["environment"] as? [String: Any],
              let providers = root["providers"] as? [[String: Any]],
              let cases = root["cases"] as? [[String: Any]]
        else { throw ProviderEvidenceError.invalidJSON }
        try exactKeys(environment, [
            "sourceCommit", "sourceTreeClean", "packageResolvedSHA256",
            "candidateVersion", "candidateBuild", "macOSVersion", "architecture",
        ])
        for provider in providers {
            try exactKeys(provider, ["provider", "credentialSource", "resource", "model"], optional: ["resource"])
        }
        for result in cases {
            try exactKeys(
                result,
                ["provider", "caseID", "status", "outcome", "providerStatusCode", "requestID"],
                optional: ["providerStatusCode", "requestID"]
            )
        }
    }

    private static func exactKeys(
        _ object: [String: Any],
        _ allowed: Set<String>,
        optional: Set<String> = []
    ) throws {
        let actual = Set(object.keys)
        guard actual.isSubset(of: allowed), allowed.subtracting(optional).isSubset(of: actual) else {
            throw ProviderEvidenceError.invalidSchema("unknownOrMissingField")
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
