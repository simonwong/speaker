import Darwin
import CryptoKit
import Foundation
import SpeakerCore
import SpeakerProviderEvidence

private enum RequestedProvider: String, CaseIterable {
    case doubao
    case deepSeek = "deepseek"
}

private enum SmokeCommand {
    case connection([RequestedProvider])
    case matrix(MatrixOptions)
}

private struct SmokeResult {
    let provider: EvidenceProvider
    let caseID: ProviderMatrixCaseID
    let status: EvidenceStatus
    let outcome: EvidenceOutcome
    let providerStatusCode: String?
    let requestID: String?
}

private struct MatrixOptions {
    let doubaoSampleURL: URL?
    let evidenceDirectoryURL: URL
    let candidateVersion: String
    let candidateBuild: String
}

private struct EvidenceContext {
    let environment: ProviderEvidenceEnvironment
    let providers: [ProviderEvidenceConfiguration]
    let doubaoResource: DoubaoStreamingResource
}

private extension SmokeResult {
    var evidenceCase: ProviderEvidenceCase {
        ProviderEvidenceCase(
            provider: provider,
            caseID: caseID,
            status: status,
            outcome: outcome,
            providerStatusCode: providerStatusCode,
            requestID: requestID
        )
    }
}

private actor FixedCredentialStore: ProviderCredentialStoring {
    private var values: [ProviderID: String]

    init(values: [ProviderID: String]) {
        self.values = values
    }

    func save(apiKey: String, for provider: ProviderID) {
        values[provider] = apiKey
    }

    func apiKey(for provider: ProviderID) -> String? {
        values[provider]
    }

    func deleteAPIKey(for provider: ProviderID) {
        values[provider] = nil
    }
}

private struct PCM16MonoSample {
    static let sampleRate = 16_000
    static let bytesPerFrame = 2

    let data: Data

    init(wavData: Data) throws {
        guard wavData.count >= 44,
              String(data: wavData.prefix(4), encoding: .ascii) == "RIFF",
              String(data: wavData.dropFirst(8).prefix(4), encoding: .ascii)
                == "WAVE"
        else {
            throw SampleError.invalidWAV
        }

        var offset = 12
        var formatIsSupported = false
        var audioData: Data?
        while offset + 8 <= wavData.count {
            let identifier = String(
                data: wavData.subdata(in: offset..<(offset + 4)),
                encoding: .ascii
            )
            let chunkSize = Self.uint32LE(wavData, at: offset + 4)
            let payloadStart = offset + 8
            guard chunkSize <= Int.max,
                  payloadStart <= wavData.count,
                  Int(chunkSize) <= wavData.count - payloadStart
            else {
                throw SampleError.invalidWAV
            }
            let payloadSize = Int(chunkSize)
            if identifier == "fmt ", payloadSize >= 16 {
                let audioFormat = Self.uint16LE(wavData, at: payloadStart)
                let channels = Self.uint16LE(wavData, at: payloadStart + 2)
                let sampleRate = Self.uint32LE(wavData, at: payloadStart + 4)
                let bitsPerSample = Self.uint16LE(wavData, at: payloadStart + 14)
                formatIsSupported = audioFormat == 1
                    && channels == 1
                    && sampleRate == Self.sampleRate
                    && bitsPerSample == 16
            } else if identifier == "data", payloadSize > 0 {
                audioData = wavData.subdata(
                    in: payloadStart..<(payloadStart + payloadSize)
                )
            }
            offset = payloadStart + payloadSize + (payloadSize % 2)
        }
        guard formatIsSupported,
              let audioData,
              audioData.count >= 60 * Self.sampleRate * Self.bytesPerFrame,
              audioData.count.isMultiple(of: Self.bytesPerFrame)
        else {
            throw SampleError.unsupportedFormat
        }
        data = audioData
    }

    func pcm(durationSeconds: Int) -> Data {
        let byteCount = durationSeconds * Self.sampleRate * Self.bytesPerFrame
        return data.prefix(byteCount)
    }

    private static func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    enum SampleError: Error {
        case invalidWAV
        case unsupportedFormat
    }
}

@main
private struct SpeakerProviderSmoke {
    static func main() async {
        disableCoreDumps()
        guard let command = parseCommand() else {
            printUsage()
            exit(64)
        }

        let credentials = LocalFileProviderCredentialStore()
        let results: [SmokeResult]
        var evidenceURL: URL?
        switch command {
        case let .connection(providers):
            var checks: [SmokeResult] = []
            for provider in providers {
                switch provider {
                case .doubao:
                    checks.append(await checkDoubaoConnection(credentials: credentials))
                case .deepSeek:
                    checks.append(await checkDeepSeekConnection(credentials: credentials))
                }
            }
            results = checks
        case let .matrix(options):
            let context: EvidenceContext
            do {
                context = try await makeEvidenceContext(options: options)
            } catch {
                printFixedError("Unable to establish the evidence environment.")
                exit(65)
            }
            results = await runMatrix(
                credentials: credentials,
                doubaoSampleURL: options.doubaoSampleURL,
                doubaoResource: context.doubaoResource
            )
            do {
                let evidence = ProviderMatrixEvidence(
                    generatedAt: Date(),
                    environment: context.environment,
                    providers: context.providers,
                    cases: results.map(\.evidenceCase)
                )
                evidenceURL = try ProviderEvidenceFile.writeAtomically(
                    evidence,
                    toNewDirectory: options.evidenceDirectoryURL
                )
            } catch {
                printFixedError("Provider evidence could not be written securely.")
                exit(73)
            }
        }

        for result in results {
            print(result.evidenceCase.privacySafeSummary)
        }
        if let evidenceURL {
            print("evidence=written file=\(evidenceURL.lastPathComponent)")
        }
        if results.contains(where: { $0.status == .fail }) {
            exit(1)
        }
        switch command {
        case .connection:
            if results.allSatisfy({ $0.status == .skip }) { exit(2) }
        case .matrix:
            if results.contains(where: { $0.status == .skip }) { exit(2) }
        }
    }

    private static func parseCommand() -> SmokeCommand? {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let first = arguments.first?.lowercased() ?? "all"
        if first == "matrix" {
            arguments.removeFirst()
            var sampleURL: URL?
            var evidenceDirectoryURL: URL?
            var candidateVersion: String?
            var candidateBuild: String?
            var confirmedPaidRequests = false
            while !arguments.isEmpty {
                switch arguments[0] {
                case "--confirm-paid-requests" where !confirmedPaidRequests:
                    confirmedPaidRequests = true
                    arguments.removeFirst()
                case "--doubao-sample" where sampleURL == nil:
                    guard arguments.count >= 2 else { return nil }
                    sampleURL = URL(fileURLWithPath: arguments[1])
                    arguments.removeFirst(2)
                case "--evidence-directory" where evidenceDirectoryURL == nil:
                    guard arguments.count >= 2 else { return nil }
                    evidenceDirectoryURL = URL(fileURLWithPath: arguments[1])
                    arguments.removeFirst(2)
                case "--candidate-version" where candidateVersion == nil:
                    guard arguments.count >= 2 else { return nil }
                    candidateVersion = arguments[1]
                    arguments.removeFirst(2)
                case "--candidate-build" where candidateBuild == nil:
                    guard arguments.count >= 2 else { return nil }
                    candidateBuild = arguments[1]
                    arguments.removeFirst(2)
                default:
                    return nil
                }
            }
            guard confirmedPaidRequests,
                  let evidenceDirectoryURL,
                  let candidateVersion,
                  let candidateBuild
            else { return nil }
            return .matrix(MatrixOptions(
                doubaoSampleURL: sampleURL,
                evidenceDirectoryURL: evidenceDirectoryURL,
                candidateVersion: candidateVersion,
                candidateBuild: candidateBuild
            ))
        }
        guard arguments.count <= 1 else { return nil }
        switch first {
        case "all": return .connection(RequestedProvider.allCases)
        case "doubao": return .connection([.doubao])
        case "deepseek": return .connection([.deepSeek])
        default: return nil
        }
    }

    private static func printUsage() {
        let usage = """
        Usage:
          ./scripts/provider-smoke [doubao|deepseek|all]
          ./scripts/provider-smoke matrix --confirm-paid-requests --evidence-directory /new/private/directory --candidate-version 1.2.3 --candidate-build 42 [--doubao-sample /path/to/60s-16k-mono-pcm.wav]
        """
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
    }

    private static func runMatrix(
        credentials: LocalFileProviderCredentialStore,
        doubaoSampleURL: URL?,
        doubaoResource: DoubaoStreamingResource
    ) async -> [SmokeResult] {
        var results: [SmokeResult] = []
        results.append(await checkDoubaoConnection(
            credentials: credentials,
            resource: doubaoResource
        ))
        results.append(contentsOf: await checkDoubaoAudioMatrix(
            credentials: credentials,
            sampleURL: doubaoSampleURL,
            resource: doubaoResource
        ))
        results.append(await checkDoubaoInvalidCredential(
            resource: doubaoResource
        ))
        results.append(await checkDeepSeekConnection(credentials: credentials))
        results.append(contentsOf: await checkDeepSeekModes(credentials: credentials))
        results.append(await checkDeepSeekCancellation(credentials: credentials))
        results.append(await checkDeepSeekInvalidCredential())
        return results
    }

    private static func checkDoubaoConnection(
        credentials: LocalFileProviderCredentialStore,
        resource: DoubaoStreamingResource? = nil
    ) async -> SmokeResult {
        do {
            guard try await credentials.apiKey(for: .doubao) != nil else {
                return result(.doubaoConnection, .skip, .notConfigured)
            }
            let resolvedResource: DoubaoStreamingResource
            if let resource {
                resolvedResource = resource
            } else {
                resolvedResource = await configuredDoubaoResource()
            }
            let service = CredentialedDoubaoTranscriber(
                credentials: credentials,
                resource: resolvedResource
            )
            announceStarted(.doubaoConnection)
            let requestID = try await service.checkConnection()
            return result(.doubaoConnection, .pass, .passed, requestID: requestID)
        } catch {
            return doubaoFailureResult(error, caseID: .doubaoConnection)
        }
    }

    private static func checkDoubaoAudioMatrix(
        credentials: LocalFileProviderCredentialStore,
        sampleURL: URL?,
        resource: DoubaoStreamingResource
    ) async -> [SmokeResult] {
        guard (try? await credentials.apiKey(for: .doubao)) != nil else {
            return doubaoAudioCaseIDs.map { result($0, .skip, .notConfigured) }
        }
        guard let sampleURL else {
            return doubaoAudioCaseIDs.map { result($0, .skip, .sampleMissing) }
        }
        do {
            let sample = try PCM16MonoSample(
                wavData: loadRegularFileNoFollow(sampleURL, maximumBytes: 64 * 1_024 * 1_024)
            )
            let service = CredentialedDoubaoTranscriber(
                credentials: credentials,
                resource: resource
            )
            var results: [SmokeResult] = []
            let audioCases: [(Int, ProviderMatrixCaseID)] = [
                (1, .doubaoAudio1Second), (5, .doubaoAudio5Seconds),
                (15, .doubaoAudio15Seconds), (60, .doubaoAudio60Seconds),
            ]
            for (seconds, caseID) in audioCases {
                do {
                    announceStarted(caseID)
                    let transcription = try await service.transcribe(
                        pacedAudioChunks(sample.pcm(durationSeconds: seconds)),
                        hotwords: [],
                        context: nil
                    )
                    guard !transcription.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    else {
                        results.append(result(
                            caseID, .fail, .emptyTranscript,
                            requestID: transcription.providerRequestID
                        ))
                        continue
                    }
                    results.append(result(
                        caseID, .pass, .passed,
                        requestID: transcription.providerRequestID
                    ))
                } catch {
                    results.append(doubaoFailureResult(error, caseID: caseID))
                }
            }
            announceStarted(.doubaoCancelStreaming)
            let cancellation = Task {
                try await service.transcribe(
                    pacedAudioChunks(sample.pcm(durationSeconds: 60)),
                    hotwords: [],
                    context: nil
                )
            }
            try? await Task.sleep(for: .milliseconds(600))
            cancellation.cancel()
            do {
                _ = try await cancellation.value
                results.append(result(
                    .doubaoCancelStreaming, .fail, .acceptedAfterCancellation
                ))
            } catch let failure as DoubaoASRFailure
                where failure.kind == .cancelled
            {
                results.append(result(
                    .doubaoCancelStreaming, .pass, .cancelled,
                    requestID: failure.providerRequestID
                ))
            } catch {
                results.append(doubaoFailureResult(
                    error,
                    caseID: .doubaoCancelStreaming
                ))
            }
            return results
        } catch {
            return doubaoAudioCaseIDs.map { result($0, .fail, .invalidSample) }
        }
    }

    private static func checkDoubaoInvalidCredential(
        resource: DoubaoStreamingResource
    ) async -> SmokeResult {
        let service = CredentialedDoubaoTranscriber(
            credentials: FixedCredentialStore(values: [.doubao: "speaker-invalid-key"]),
            resource: resource
        )
        do {
            announceStarted(.doubaoInvalidCredential)
            _ = try await service.checkConnection()
            return result(.doubaoInvalidCredential, .fail, .unexpected)
        } catch let failure as DoubaoASRFailure
            where failure.kind == .invalidCredential
        {
            return result(
                .doubaoInvalidCredential, .pass, .invalidCredential,
                requestID: failure.providerRequestID
            )
        } catch {
            return doubaoFailureResult(error, caseID: .doubaoInvalidCredential)
        }
    }

    private static func checkDeepSeekConnection(
        credentials: LocalFileProviderCredentialStore
    ) async -> SmokeResult {
        do {
            guard try await credentials.apiKey(for: .deepSeek) != nil else {
                return result(.deepSeekConnection, .skip, .notConfigured)
            }
            let service = CredentialedDeepSeekTextRefiner(
                credentials: credentials
            )
            announceStarted(.deepSeekConnection)
            let requestID = try await service.checkConnection()
            return result(.deepSeekConnection, .pass, .passed, requestID: requestID)
        } catch {
            return deepSeekFailureResult(error, caseID: .deepSeekConnection)
        }
    }

    private static func checkDeepSeekModes(
        credentials: LocalFileProviderCredentialStore
    ) async -> [SmokeResult] {
        guard (try? await credentials.apiKey(for: .deepSeek)) != nil else {
            return deepSeekModeCaseIDs.map { result($0, .skip, .notConfigured) }
        }
        let modes: [(String, ProviderMatrixCaseID, String, TextRefinementMode)] = [
            (
                "concise",
                .deepSeekModeConcise,
                "嗯，我想说，就是这个版本是 2.0，然后周五交付，周五交付。",
                .conciseCleanup
            ),
            (
                "rewrite",
                .deepSeekModeRewrite,
                "版本是 2.0。周五交付。不得增加原文没有的信息。",
                .fullRewrite
            ),
            (
                "custom",
                .deepSeekModeCustom,
                "版本是 2.0，交付日是周五。负责人是小林。",
                .custom(
                    name: "实测规则",
                    prompt: "保持全部事实和数字，整理为恰好两行，不要添加标题或新信息。"
                )
            ),
        ]
        let service = CredentialedDeepSeekTextRefiner(credentials: credentials)
        var results: [SmokeResult] = []
        for (name, caseID, source, mode) in modes {
            do {
                announceStarted(caseID)
                let refined = try await service.refine(source, using: mode)
                guard deepSeekOracle(
                    source: source,
                    output: refined.text,
                    modeName: name
                )
                else {
                    results.append(result(caseID, .fail, .semanticOracleFailed))
                    continue
                }
                results.append(result(
                    caseID, .pass, .passed,
                    requestID: refined.providerRequestID
                ))
            } catch {
                results.append(deepSeekFailureResult(error, caseID: caseID))
            }
        }
        return results
    }

    private static func checkDeepSeekCancellation(
        credentials: LocalFileProviderCredentialStore
    ) async -> SmokeResult {
        guard (try? await credentials.apiKey(for: .deepSeek)) != nil else {
            return result(.deepSeekCancelInFlight, .skip, .notConfigured)
        }
        let service = CredentialedDeepSeekTextRefiner(credentials: credentials)
        announceStarted(.deepSeekCancelInFlight)
        let request = Task {
            try await service.refine(
                String(repeating: "这是等待中取消的固定非敏感测试文本。", count: 120),
                using: .fullRewrite
            )
        }
        await Task.yield()
        request.cancel()
        do {
            _ = try await request.value
            return result(
                .deepSeekCancelInFlight, .fail, .acceptedAfterCancellation
            )
        } catch let failure as DeepSeekRefinementFailure
            where failure.kind == .cancelled
        {
            return result(
                .deepSeekCancelInFlight, .pass, .cancelled,
                requestID: failure.providerRequestID
            )
        } catch is CancellationError {
            return result(.deepSeekCancelInFlight, .pass, .cancelled)
        } catch {
            return deepSeekFailureResult(error, caseID: .deepSeekCancelInFlight)
        }
    }

    private static func checkDeepSeekInvalidCredential() async -> SmokeResult {
        let service = CredentialedDeepSeekTextRefiner(
            credentials: FixedCredentialStore(values: [.deepSeek: "speaker-invalid-key"])
        )
        do {
            announceStarted(.deepSeekInvalidCredential)
            _ = try await service.refine("凭据边界检查。", using: .conciseCleanup)
            return result(.deepSeekInvalidCredential, .fail, .unexpected)
        } catch let failure as DeepSeekRefinementFailure
            where failure.kind == .authentication
        {
            return result(
                .deepSeekInvalidCredential, .pass, .authentication,
                requestID: failure.providerRequestID
            )
        } catch {
            return deepSeekFailureResult(error, caseID: .deepSeekInvalidCredential)
        }
    }

    private static func configuredDoubaoResource() async -> DoubaoStreamingResource {
        let settings = await VersionedLocalAppSettingsStore(
            fileURL: VersionedLocalAppSettingsStore.defaultFileURL()
        ).load().settings
        return settings.doubaoResourceID.flatMap(
            DoubaoStreamingResource.init(rawValue:)
        ) ?? .default
    }

    private static func makeEvidenceContext(
        options: MatrixOptions
    ) async throws -> EvidenceContext {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let commit = try gitOutput(["rev-parse", "--verify", "HEAD^{commit}"], root: root)
        let status = try gitOutput(
            ["status", "--porcelain", "--untracked-files=all"],
            root: root,
            permitEmpty: true
        )
        let packageData = try loadRegularFileNoFollow(
            root.appendingPathComponent("Package.resolved"),
            maximumBytes: 4 * 1_024 * 1_024
        )
        let packageHash = SHA256.hash(data: packageData)
            .map { String(format: "%02x", $0) }
            .joined()
        let resource = await configuredDoubaoResource()
        let architecture: String
#if arch(arm64)
        architecture = "arm64"
#elseif arch(x86_64)
        architecture = "x86_64"
#else
        architecture = "unsupported"
#endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let environment = ProviderEvidenceEnvironment(
            sourceCommit: commit,
            sourceTreeClean: status.isEmpty,
            packageResolvedSHA256: packageHash,
            candidateVersion: options.candidateVersion,
            candidateBuild: options.candidateBuild,
            macOSVersion: macOSVersion,
            architecture: architecture
        )
        let providers = [
            ProviderEvidenceConfiguration(
                provider: .doubao,
                credentialSource: .developmentOwnerOnlyFile,
                resource: resource.rawValue,
                model: "bigmodel"
            ),
            ProviderEvidenceConfiguration(
                provider: .deepSeek,
                credentialSource: .developmentOwnerOnlyFile,
                resource: nil,
                model: "deepseek-v4-flash"
            ),
        ]
        let validationFixture = ProviderMatrixEvidence(
            generatedAt: Date(),
            environment: environment,
            providers: providers,
            cases: ProviderMatrixCaseID.allCases.map {
                ProviderEvidenceCase(
                    provider: $0.provider,
                    caseID: $0,
                    status: .skip,
                    outcome: .notConfigured
                )
            }
        )
        try validationFixture.validate(
            requirePassingCases: false,
            requireSignedAppKeychain: false
        )
        return EvidenceContext(
            environment: environment,
            providers: providers,
            doubaoResource: resource
        )
    }

    private static func gitOutput(
        _ arguments: [String],
        root: URL,
        permitEmpty: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderEvidenceError.invalidSchema("sourceRepository")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 4 * 1_024 * 1_024,
              let value = String(data: data, encoding: .utf8)
        else { throw ProviderEvidenceError.invalidSchema("sourceRepository") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard permitEmpty || !trimmed.isEmpty else {
            throw ProviderEvidenceError.invalidSchema("sourceRepository")
        }
        return trimmed
    }

    private static func doubaoFailureResult(
        _ error: Error,
        caseID: ProviderMatrixCaseID
    ) -> SmokeResult {
        if let failure = error as? DoubaoASRFailure {
            return result(
                caseID,
                .fail,
                .providerFailure,
                providerStatusCode: failure.providerStatusCode,
                requestID: failure.providerRequestID
            )
        }
        if error is ProviderCredentialStoreError {
            return result(caseID, .fail, .credentialFailure)
        }
        return result(caseID, .fail, .unexpected)
    }

    private static func deepSeekFailureResult(
        _ error: Error,
        caseID: ProviderMatrixCaseID
    ) -> SmokeResult {
        if let failure = error as? DeepSeekRefinementFailure {
            return result(
                caseID,
                .fail,
                .providerFailure,
                providerStatusCode: failure.httpStatusCode.map(String.init),
                requestID: failure.providerRequestID
            )
        }
        if error is ProviderCredentialStoreError {
            return result(caseID, .fail, .credentialFailure)
        }
        return result(caseID, .fail, .unexpected)
    }

    private static func result(
        _ caseID: ProviderMatrixCaseID,
        _ status: EvidenceStatus,
        _ outcome: EvidenceOutcome,
        providerStatusCode: String? = nil,
        requestID: String? = nil
    ) -> SmokeResult {
        SmokeResult(
            provider: caseID.provider,
            caseID: caseID,
            status: status,
            outcome: outcome,
            providerStatusCode: ProviderMatrixEvidence.safeToken(providerStatusCode),
            requestID: ProviderMatrixEvidence.safeToken(requestID)
        )
    }

    private static func announceStarted(_ caseID: ProviderMatrixCaseID) {
        print("provider=\(caseID.provider.rawValue) case=\(caseID.rawValue) state=RUNNING")
        fflush(stdout)
    }

    private static var doubaoAudioCaseIDs: [ProviderMatrixCaseID] {
        [
            .doubaoAudio1Second, .doubaoAudio5Seconds,
            .doubaoAudio15Seconds, .doubaoAudio60Seconds,
            .doubaoCancelStreaming,
        ]
    }

    private static var deepSeekModeCaseIDs: [ProviderMatrixCaseID] {
        [.deepSeekModeConcise, .deepSeekModeRewrite, .deepSeekModeCustom]
    }

    private static func printFixedError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func deepSeekOracle(
        source: String,
        output: String,
        modeName: String
    ) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              ["2.0", "周五"].allSatisfy(trimmed.contains),
              asciiNumberTokens(in: trimmed).isSubset(of: asciiNumberTokens(in: source))
        else { return false }
        switch modeName {
        case "concise":
            return !trimmed.contains("嗯")
                && !trimmed.contains("就是")
                && trimmed.components(separatedBy: "周五").count - 1 == 1
        case "rewrite":
            return trimmed.contains("不得增加") || trimmed.contains("不增加")
        case "custom":
            return trimmed.contains("小林")
                && trimmed.split(separator: "\n", omittingEmptySubsequences: true).count == 2
        default:
            return false
        }
    }

    private static func asciiNumberTokens(in text: String) -> Set<String> {
        Set(
            text.split { !$0.isNumber }
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    private static func pacedAudioChunks(_ pcm: Data) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let producer = Task {
                let chunkSize = 6_400
                var offset = 0
                while offset < pcm.count, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { break }
                    let end = min(offset + chunkSize, pcm.count)
                    continuation.yield(pcm.subdata(in: offset..<end))
                    offset = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private static func loadRegularFileNoFollow(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PCM16MonoSample.SampleError.invalidWAV }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size > 0,
              information.st_size <= maximumBytes
        else {
            throw PCM16MonoSample.SampleError.invalidWAV
        }
        guard let data = try handle.readToEnd(),
              data.count == Int(information.st_size)
        else {
            throw PCM16MonoSample.SampleError.invalidWAV
        }
        return data
    }

    private static func disableCoreDumps() {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &limit)
    }
}
