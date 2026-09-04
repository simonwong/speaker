import Foundation

public enum EvaluationManifestError: Error, Equatable, Sendable {
    case malformedJSON
    case noSamples
    case emptySampleID(index: Int)
    case duplicateSampleID(String)
    case emptyWAVPath(sampleID: String)
    case emptyReference(sampleID: String)
}

extension EvaluationManifestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .malformedJSON:
            "manifest is not valid JSON of the form {\"samples\":[{\"id\",\"wav\",\"reference\",\"tags\"?}]}"
        case .noSamples:
            "manifest lists no samples"
        case .emptySampleID(let index):
            "sample at index \(index) has an empty id"
        case .duplicateSampleID(let id):
            "sample id \"\(id)\" appears more than once"
        case .emptyWAVPath(let sampleID):
            "sample \"\(sampleID)\" has an empty wav path"
        case .emptyReference(let sampleID):
            "sample \"\(sampleID)\" has a reference with no scorable characters"
        }
    }
}

/// One user-supplied evaluation sample. The reference text is user data and
/// must never be copied into default reports.
public struct EvaluationSample: Equatable, Sendable {
    public let id: String
    public let wavURL: URL
    public let reference: String
    public let tags: [String]

    public init(id: String, wavURL: URL, reference: String, tags: [String]) {
        self.id = id
        self.wavURL = wavURL
        self.reference = reference
        self.tags = tags
    }
}

public struct EvaluationManifest: Equatable, Sendable {
    public let samples: [EvaluationSample]

    public init(samples: [EvaluationSample]) {
        self.samples = samples
    }

    private struct Document: Decodable {
        struct Sample: Decodable {
            let id: String
            let wav: String
            let reference: String
            let tags: [String]?
        }

        let samples: [Sample]
    }

    /// Parses and validates a manifest. Relative `wav` paths resolve against
    /// `baseDirectory`, normally the manifest's own directory.
    public static func parse(_ data: Data, baseDirectory: URL) throws -> EvaluationManifest {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw EvaluationManifestError.malformedJSON
        }
        guard !document.samples.isEmpty else { throw EvaluationManifestError.noSamples }

        var seenIDs = Set<String>()
        var samples: [EvaluationSample] = []
        for (index, sample) in document.samples.enumerated() {
            let id = sample.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw EvaluationManifestError.emptySampleID(index: index) }
            guard seenIDs.insert(id).inserted else {
                throw EvaluationManifestError.duplicateSampleID(id)
            }
            let wavPath = sample.wav.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wavPath.isEmpty else { throw EvaluationManifestError.emptyWAVPath(sampleID: id) }
            guard !TranscriptNormalizer.scoredCharacters(sample.reference).isEmpty else {
                throw EvaluationManifestError.emptyReference(sampleID: id)
            }
            let wavURL =
                wavPath.hasPrefix("/")
                ? URL(fileURLWithPath: wavPath)
                : URL(fileURLWithPath: wavPath, relativeTo: baseDirectory).standardizedFileURL
            samples.append(
                EvaluationSample(
                    id: id,
                    wavURL: wavURL,
                    reference: sample.reference,
                    tags: (sample.tags ?? []).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                ))
        }
        return EvaluationManifest(samples: samples)
    }
}
