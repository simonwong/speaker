import CryptoKit
import Darwin
import Foundation
import SpeakerAccuracyMetrics
import SpeakerCore

// Offline accuracy evaluation against user-supplied samples. Real Doubao
// requests are billed and run only behind `--confirm-paid-requests`; every
// other invocation validates inputs and prints the plan without network use.

private enum ExitCode {
    static let usage: Int32 = 64
    static let invalidInput: Int32 = 65
    static let environment: Int32 = 66
}

private enum ModelGeneration: String, CaseIterable {
    case model1 = "1.0"
    case model2 = "2.0"

    func resource(matching configured: DoubaoStreamingResource) -> DoubaoStreamingResource {
        let concurrent = configured == .model1Concurrent || configured == .model2Concurrent
        switch self {
        case .model1: return concurrent ? .model1Concurrent : .model1Duration
        case .model2: return concurrent ? .model2Concurrent : .model2Duration
        }
    }
}

private enum SmoothingSetting: String, CaseIterable {
    case on
    case off

    var purpose: SpeechTranscriptionPurpose {
        self == .on ? .defaultSmoothing : .refinementSource
    }
}

private enum DictionaryAttachment: String, CaseIterable {
    case with
    case without
}

private struct Options {
    var manifestURL: URL?
    var generations: [ModelGeneration] = [.model2]
    var smoothing: [SmoothingSetting] = [.on]
    var dictionaryFileURL: URL?
    var attachments: [DictionaryAttachment]?
    var outputURL: URL?
    var includeText = false
    var confirmPaidRequests = false
}

private struct Variant {
    let id: String
    let generation: ModelGeneration
    let resource: DoubaoStreamingResource
    let smoothing: SmoothingSetting
    let attachment: DictionaryAttachment
    let hotwords: [String]
    let entryCount: Int
}

private struct LoadedSample {
    let sample: EvaluationSample
    let audio: PCM16MonoWAV
}

private struct LoadedDictionary {
    let entries: [DictionaryEntry]
    let hotwords: [String]
}

private struct VariantReport: Encodable {
    let id: String
    let model: String
    let resource: String
    let semanticSmoothing: Bool
    let dictionaryAttached: Bool
    let dictionaryEntryCount: Int
    let hotwordCount: Int
    var entries: [String]?
}

private struct RateReport: Encodable {
    let referenceLength: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let rate: Double

    init(_ result: ErrorRateResult) {
        referenceLength = result.referenceLength
        substitutions = result.counts.substitutions
        deletions = result.counts.deletions
        insertions = result.counts.insertions
        rate = result.rate
    }
}

private struct AggregateRateReport: Encodable {
    let sampleCount: Int
    let referenceLength: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let corpusRate: Double
    let meanSampleRate: Double

    init(_ aggregate: ErrorRateAggregate) {
        sampleCount = aggregate.sampleCount
        referenceLength = aggregate.referenceLength
        substitutions = aggregate.counts.substitutions
        deletions = aggregate.counts.deletions
        insertions = aggregate.counts.insertions
        corpusRate = aggregate.corpusRate
        meanSampleRate = aggregate.meanSampleRate
    }
}

private struct SampleResultReport: Encodable {
    let variant: String
    let sample: String
    let tags: [String]
    let audioSeconds: Double
    let outcome: String
    let failureKind: String?
    let providerRequestID: String?
    let durationMilliseconds: Int
    let cer: RateReport?
    let latinWER: RateReport?
    var reference: String?
    var hypothesis: String?
}

private struct VariantAggregateReport: Encodable {
    let variant: String
    let sampleCount: Int
    let succeededCount: Int
    let failedCount: Int
    let cer: AggregateRateReport
    let latinWER: AggregateRateReport
}

private struct TagAggregateReport: Encodable {
    let variant: String
    let tag: String
    let sampleCount: Int
    let cer: AggregateRateReport
    let latinWER: AggregateRateReport
}

private struct Report: Encodable {
    let schemaVersion = 1
    let generatedAt: String
    let includesText: Bool
    let manifestSHA256: String
    let sampleCount: Int
    let variants: [VariantReport]
    let results: [SampleResultReport]
    let aggregates: [VariantAggregateReport]
    let tagAggregates: [TagAggregateReport]
    let totalDurationMilliseconds: Int
}

private struct SampleOutcome {
    let result: SampleResultReport
    let cer: ErrorRateResult?
    let wer: ErrorRateResult?
}

@main
private struct SpeakerAccuracyEvaluator {
    static func main() async {
        disableCoreDumps()
        let options: Options
        do {
            options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        } catch let error as UsageError {
            printError(error.message)
            printUsage()
            exit(ExitCode.usage)
        } catch {
            printUsage()
            exit(ExitCode.usage)
        }

        guard let manifestURL = options.manifestURL else {
            printError("--manifest is required.")
            printUsage()
            exit(ExitCode.usage)
        }

        let manifestData: Data
        let manifest: EvaluationManifest
        do {
            manifestData = try loadRegularFileNoFollow(manifestURL, maximumBytes: 4 * 1_024 * 1_024)
            manifest = try EvaluationManifest.parse(
                manifestData,
                baseDirectory: manifestURL.deletingLastPathComponent()
            )
        } catch let error as EvaluationManifestError {
            printError("Manifest is invalid: \(error).")
            exit(ExitCode.invalidInput)
        } catch {
            printError("Manifest could not be read as a regular file.")
            exit(ExitCode.invalidInput)
        }

        var samples: [LoadedSample] = []
        var sampleProblems = 0
        for sample in manifest.samples {
            do {
                let data = try loadRegularFileNoFollow(sample.wavURL, maximumBytes: 256 * 1_024 * 1_024)
                samples.append(LoadedSample(sample: sample, audio: try PCM16MonoWAV.parse(data)))
            } catch let error as WAVFormatError {
                sampleProblems += 1
                printError("Sample \"\(sample.id)\": \(error).")
            } catch {
                sampleProblems += 1
                printError("Sample \"\(sample.id)\": WAV file could not be read as a regular file.")
            }
        }
        guard sampleProblems == 0 else {
            printError("\(sampleProblems) sample(s) failed validation; nothing was sent.")
            exit(ExitCode.invalidInput)
        }

        var dictionary: LoadedDictionary?
        if let dictionaryFileURL = options.dictionaryFileURL {
            do {
                dictionary = try loadDictionary(dictionaryFileURL)
            } catch let error as PersonalDictionaryValidationError {
                printError("Dictionary file is invalid: \(error.localizedDescription)")
                exit(ExitCode.invalidInput)
            } catch {
                printError("Dictionary file must be a regular JSON file containing an array of Entry strings.")
                exit(ExitCode.invalidInput)
            }
        }
        let attachments = options.attachments ?? (dictionary == nil ? [.without] : [.with])
        if attachments.contains(.with), dictionary == nil {
            printError("--dictionary with requires --dictionary-file.")
            exit(ExitCode.usage)
        }

        let configuredResource = await configuredDoubaoResource()
        let variants = makeVariants(
            options: options,
            attachments: attachments,
            dictionary: dictionary,
            configuredResource: configuredResource
        )
        let totalAudioSeconds = samples.reduce(0.0) { $0 + $1.audio.durationSeconds }

        print("Manifest: \(samples.count) sample(s), \(formatSeconds(totalAudioSeconds)) of audio, sha256 \(sha256Hex(manifestData)).")
        print("Variants (\(variants.count)):")
        for variant in variants {
            print("  \(variant.id): resource=\(variant.resource.rawValue) semanticSmoothing=\(variant.smoothing == .on) dictionary=\(variant.attachment == .with) hotwords=\(variant.hotwords.count)")
        }
        print("Planned requests: \(variants.count * samples.count) streaming Doubao request(s), about \(formatSeconds(totalAudioSeconds * Double(variants.count))) of billed audio.")

        guard options.confirmPaidRequests else {
            print("Plan only. Re-run with --confirm-paid-requests and --output <report.json> to make these paid BYOK requests.")
            exit(0)
        }
        guard let outputURL = options.outputURL else {
            printError("--output <report.json> is required with --confirm-paid-requests.")
            exit(ExitCode.usage)
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            printError("Output report already exists; choose a fresh path.")
            exit(ExitCode.usage)
        }

        let credentials = LocalFileProviderCredentialStore()
        do {
            guard let key = try await credentials.apiKey(for: .doubao), !key.isEmpty else {
                printError("No Doubao API key is saved in the development credential store.")
                exit(ExitCode.environment)
            }
        } catch {
            printError("The development credential store could not be read.")
            exit(ExitCode.environment)
        }

        let runStarted = ContinuousClock.now
        var outcomes: [SampleOutcome] = []
        for variant in variants {
            let transcriber = CredentialedDoubaoTranscriber(
                credentials: credentials,
                resource: variant.resource
            )
            let context = SpeechTranscriptionContext(
                hotwords: variant.hotwords,
                purpose: variant.smoothing.purpose
            )
            for loaded in samples {
                print("[\(variant.id)] \(loaded.sample.id) …", terminator: "")
                let outcome = await evaluate(
                    loaded,
                    variant: variant,
                    context: context,
                    transcriber: transcriber
                )
                outcomes.append(outcome)
                if let cer = outcome.cer, let wer = outcome.wer {
                    print(" CER \(formatRate(cer.rate)) WER \(formatRate(wer.rate)) (\(outcome.result.durationMilliseconds) ms)")
                } else {
                    print(" \(outcome.result.outcome) \(outcome.result.failureKind ?? "") (\(outcome.result.durationMilliseconds) ms)")
                }
            }
        }
        let totalDuration = runStarted.duration(to: .now)

        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let manifestHash = sha256Hex(manifestData)
        let redacted = makeReport(
            generatedAt: generatedAt,
            includesText: false,
            manifestHash: manifestHash,
            sampleCount: samples.count,
            variants: variants,
            dictionary: dictionary,
            outcomes: outcomes,
            totalDuration: totalDuration
        )
        do {
            try writeOwnerOnly(redacted, to: outputURL)
            print("Report written to \(outputURL.path) (no transcript, reference, or Entry text).")
            if options.includeText {
                let textURL = outputURL.deletingPathExtension().appendingPathExtension("with-text.json")
                let withText = makeReport(
                    generatedAt: generatedAt,
                    includesText: true,
                    manifestHash: manifestHash,
                    sampleCount: samples.count,
                    variants: variants,
                    dictionary: dictionary,
                    outcomes: outcomes,
                    totalDuration: totalDuration
                )
                try writeOwnerOnly(withText, to: textURL)
                print("WARNING: \(textURL.path) contains transcript, reference, and Entry text. Keep it local; do not commit it or attach it to an issue.")
            }
        } catch {
            printError("Report could not be written securely.")
            exit(ExitCode.environment)
        }

        for aggregate in redacted.aggregates {
            print("\(aggregate.variant): \(aggregate.succeededCount)/\(aggregate.sampleCount) succeeded, corpus CER \(formatRate(aggregate.cer.corpusRate)), corpus Latin WER \(formatRate(aggregate.latinWER.corpusRate))")
        }
    }

    // MARK: Evaluation

    private static func evaluate(
        _ loaded: LoadedSample,
        variant: Variant,
        context: SpeechTranscriptionContext,
        transcriber: CredentialedDoubaoTranscriber
    ) async -> SampleOutcome {
        let started = ContinuousClock.now
        func milliseconds() -> Int {
            Int(started.duration(to: .now).components.seconds * 1_000)
                + Int(started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let result = try await transcriber.transcribe(
                pacedAudioChunks(loaded.audio.pcm),
                context: context
            )
            let cer = AccuracyMetrics.characterErrorRate(
                reference: loaded.sample.reference,
                hypothesis: result.text
            )
            let wer = AccuracyMetrics.latinWordErrorRate(
                reference: loaded.sample.reference,
                hypothesis: result.text
            )
            return SampleOutcome(
                result: SampleResultReport(
                    variant: variant.id,
                    sample: loaded.sample.id,
                    tags: loaded.sample.tags,
                    audioSeconds: loaded.audio.durationSeconds,
                    outcome: "succeeded",
                    failureKind: nil,
                    providerRequestID: result.providerRequestID,
                    durationMilliseconds: milliseconds(),
                    cer: RateReport(cer),
                    latinWER: RateReport(wer),
                    reference: loaded.sample.reference,
                    hypothesis: result.text
                ),
                cer: cer,
                wer: wer
            )
        } catch let failure as DoubaoASRFailure {
            return SampleOutcome(
                result: SampleResultReport(
                    variant: variant.id,
                    sample: loaded.sample.id,
                    tags: loaded.sample.tags,
                    audioSeconds: loaded.audio.durationSeconds,
                    outcome: "failed",
                    failureKind: failure.kind.rawValue,
                    providerRequestID: failure.providerRequestID,
                    durationMilliseconds: milliseconds(),
                    cer: nil,
                    latinWER: nil,
                    reference: loaded.sample.reference,
                    hypothesis: nil
                ),
                cer: nil,
                wer: nil
            )
        } catch {
            return SampleOutcome(
                result: SampleResultReport(
                    variant: variant.id,
                    sample: loaded.sample.id,
                    tags: loaded.sample.tags,
                    audioSeconds: loaded.audio.durationSeconds,
                    outcome: "failed",
                    failureKind: "unexpected",
                    providerRequestID: nil,
                    durationMilliseconds: milliseconds(),
                    cer: nil,
                    latinWER: nil,
                    reference: loaded.sample.reference,
                    hypothesis: nil
                ),
                cer: nil,
                wer: nil
            )
        }
    }

    private static func makeReport(
        generatedAt: String,
        includesText: Bool,
        manifestHash: String,
        sampleCount: Int,
        variants: [Variant],
        dictionary: LoadedDictionary?,
        outcomes: [SampleOutcome],
        totalDuration: Duration
    ) -> Report {
        let variantReports = variants.map { variant in
            VariantReport(
                id: variant.id,
                model: variant.generation.rawValue,
                resource: variant.resource.rawValue,
                semanticSmoothing: variant.smoothing == .on,
                dictionaryAttached: variant.attachment == .with,
                dictionaryEntryCount: variant.entryCount,
                hotwordCount: variant.hotwords.count,
                entries: includesText && variant.attachment == .with
                    ? dictionary?.entries.map(\.word)
                    : nil
            )
        }
        let results = outcomes.map { outcome -> SampleResultReport in
            var result = outcome.result
            if !includesText {
                result.reference = nil
                result.hypothesis = nil
            }
            return result
        }
        var aggregates: [VariantAggregateReport] = []
        var tagAggregates: [TagAggregateReport] = []
        for variant in variants {
            let variantOutcomes = outcomes.filter { $0.result.variant == variant.id }
            let succeeded = variantOutcomes.filter { $0.cer != nil }
            aggregates.append(VariantAggregateReport(
                variant: variant.id,
                sampleCount: variantOutcomes.count,
                succeededCount: succeeded.count,
                failedCount: variantOutcomes.count - succeeded.count,
                cer: AggregateRateReport(ErrorRateAggregate(results: succeeded.compactMap(\.cer))),
                latinWER: AggregateRateReport(ErrorRateAggregate(results: succeeded.compactMap(\.wer)))
            ))
            let tags = Set(succeeded.flatMap(\.result.tags)).sorted()
            for tag in tags {
                let tagged = succeeded.filter { $0.result.tags.contains(tag) }
                tagAggregates.append(TagAggregateReport(
                    variant: variant.id,
                    tag: tag,
                    sampleCount: tagged.count,
                    cer: AggregateRateReport(ErrorRateAggregate(results: tagged.compactMap(\.cer))),
                    latinWER: AggregateRateReport(ErrorRateAggregate(results: tagged.compactMap(\.wer)))
                ))
            }
        }
        return Report(
            generatedAt: generatedAt,
            includesText: includesText,
            manifestSHA256: manifestHash,
            sampleCount: sampleCount,
            variants: variantReports,
            results: results,
            aggregates: aggregates,
            tagAggregates: tagAggregates,
            totalDurationMilliseconds: Int(totalDuration.components.seconds * 1_000)
                + Int(totalDuration.components.attoseconds / 1_000_000_000_000_000)
        )
    }

    private static func makeVariants(
        options: Options,
        attachments: [DictionaryAttachment],
        dictionary: LoadedDictionary?,
        configuredResource: DoubaoStreamingResource
    ) -> [Variant] {
        var variants: [Variant] = []
        for generation in options.generations {
            for smoothing in options.smoothing {
                for attachment in attachments {
                    let hotwords = attachment == .with ? dictionary?.hotwords ?? [] : []
                    variants.append(Variant(
                        id: "model\(generation.rawValue)-smoothing_\(smoothing.rawValue)-dictionary_\(attachment.rawValue)",
                        generation: generation,
                        resource: generation.resource(matching: configuredResource),
                        smoothing: smoothing,
                        attachment: attachment,
                        hotwords: hotwords,
                        entryCount: attachment == .with ? dictionary?.entries.count ?? 0 : 0
                    ))
                }
            }
        }
        return variants
    }

    private static func loadDictionary(_ url: URL) throws -> LoadedDictionary {
        let data = try loadRegularFileNoFollow(url, maximumBytes: 8 * 1_024 * 1_024)
        let words = try JSONDecoder().decode([String].self, from: data)
        let entries = words.map { DictionaryEntry(word: $0) }
        let personalDictionary = try PersonalDictionary(entries: entries)
        let context = DictionaryRequestContextBuilder.makeContext(
            from: personalDictionary.snapshot()
        )
        return LoadedDictionary(entries: entries, hotwords: context.hotwords)
    }

    private static func configuredDoubaoResource() async -> DoubaoStreamingResource {
        let settings = await VersionedLocalAppSettingsStore(
            fileURL: VersionedLocalAppSettingsStore.defaultFileURL()
        ).load().settings
        return settings.doubaoResourceID.flatMap(
            DoubaoStreamingResource.init(rawValue:)
        ) ?? .default
    }

    /// 200 ms packets paced in real time, matching Speaker's live capture.
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

    // MARK: Options

    private struct UsageError: Error {
        let message: String
    }

    private static func parseOptions(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError(message: "\(flag) requires a value.") }
            return arguments[index]
        }
        func list<Value: RawRepresentable & CaseIterable>(
            _ raw: String,
            as type: Value.Type,
            flag: String
        ) throws -> [Value] where Value.RawValue == String {
            var parsed: [Value] = []
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard let value = Value(rawValue: part) else {
                    let allowed = Value.allCases.map(\.rawValue).joined(separator: "|")
                    throw UsageError(message: "\(flag) accepts \(allowed), not \"\(part)\".")
                }
                if !parsed.contains(where: { $0.rawValue == value.rawValue }) { parsed.append(value) }
            }
            guard !parsed.isEmpty else { throw UsageError(message: "\(flag) requires at least one value.") }
            return parsed
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--manifest":
                options.manifestURL = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
            case "--resources":
                options.generations = try list(try value(for: argument), as: ModelGeneration.self, flag: argument)
            case "--smoothing":
                options.smoothing = try list(try value(for: argument), as: SmoothingSetting.self, flag: argument)
            case "--dictionary-file":
                options.dictionaryFileURL = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
            case "--dictionary":
                options.attachments = try list(try value(for: argument), as: DictionaryAttachment.self, flag: argument)
            case "--output":
                options.outputURL = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
            case "--include-text":
                options.includeText = true
            case "--confirm-paid-requests":
                options.confirmPaidRequests = true
            default:
                throw UsageError(message: "Unknown argument \"\(argument)\".")
            }
            index += 1
        }
        return options
    }

    private static func printUsage() {
        printError(
            """
            Usage: SpeakerAccuracyEvaluator --manifest <manifest.json> [options]
              --resources 1.0,2.0          Doubao model generations to compare (default 2.0)
              --smoothing on,off           Doubao semantic smoothing variants (default on)
              --dictionary-file <json>     JSON array of Personal Dictionary Entry strings sent as hotwords
              --dictionary with,without    Attach the dictionary file or not (default: with when a file is given)
              --output <report.json>       Fresh path for the text-free JSON report (required for paid runs)
              --include-text               Also write <output>.with-text.json containing transcript, reference, and Entry text
              --confirm-paid-requests      Make the billed BYOK Doubao requests; without it only the plan is printed
            The manifest is {"samples":[{"id":"...","wav":"16k-16bit-mono.wav","reference":"...","tags":["..."]}]}.
            """
        )
    }

    // MARK: Helpers

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func formatRate(_ rate: Double) -> String {
        String(format: "%.2f%%", rate * 100)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeOwnerOnly(_ report: Report, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func loadRegularFileNoFollow(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size > 0,
              information.st_size <= maximumBytes
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let data = try handle.readToEnd(), data.count == Int(information.st_size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func disableCoreDumps() {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &limit)
    }
}
