import Foundation

/// Loads the current BYOK credential at request time so changing the Keychain
/// value never requires rebuilding the long-lived voice-input session actor.
public actor CredentialedDoubaoTranscriber: SpeechTranscribing {
    private let credentials: any ProviderCredentialStoring
    private let installationID: String
    private let connector: any DoubaoWebSocketConnecting
    private var resource: DoubaoStreamingResource

    public init(
        credentials: any ProviderCredentialStoring,
        installationID: String,
        resource: DoubaoStreamingResource = .default,
        connector: any DoubaoWebSocketConnecting = URLSessionDoubaoWebSocketConnector()
    ) {
        self.credentials = credentials
        self.installationID = installationID
        self.resource = resource
        self.connector = connector
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        try await transcribe(audio, hotwords: [], context: nil)
    }

    public func transcribe(
        _ audio: CapturedAudio,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        let pcm = try Self.pcm16LE(from: audio.data)
        return try await transcribe(
            Self.chunkStream(from: pcm),
            hotwords: hotwords,
            context: context
        )
    }

    public func transcribe(
        _ audioChunks: AsyncStream<Data>,
        hotwords: [String],
        context: String?
    ) async throws -> TranscriptionResult {
        guard let apiKey = try await credentials.apiKey(for: .doubao) else {
            throw DoubaoASRFailure(kind: .invalidCredential)
        }
        let client = DoubaoStreamingASRClient(
            configuration: .init(
                apiKey: apiKey,
                resource: resource,
                installationID: installationID,
                hotwords: hotwords,
                context: context
            ),
            connector: connector
        )
        return try await client.transcribe(audioChunks)
    }

    public func setResource(_ resource: DoubaoStreamingResource) {
        self.resource = resource
    }

    public func currentResource() -> DoubaoStreamingResource { resource }

    public func hasAPIKey() async throws -> Bool {
        try await credentials.apiKey(for: .doubao) != nil
    }

    public func saveAPIKey(_ apiKey: String) async throws {
        try await credentials.save(apiKey: apiKey, for: .doubao)
    }

    public func deleteAPIKey() async throws {
        try await credentials.deleteAPIKey(for: .doubao)
    }

    /// A valid silent PCM stream exercises authentication and resource activation.
    /// The provider's documented silence response therefore counts as a
    /// successful connection check and avoids storing a spoken sample.
    public func checkConnection() async throws -> String? {
        do {
            return try await transcribe(
                Self.chunkStream(from: Self.silentProbePCM),
                hotwords: [],
                context: nil
            ).providerRequestID
        } catch let failure as DoubaoASRFailure
            where failure.kind == .silence || failure.kind == .emptyTranscript {
            return failure.providerRequestID
        }
    }

    private static let silentProbePCM = Data(repeating: 0, count: 16_000 * 2 * 400 / 1_000)

    private static func chunkStream(from pcm: Data) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let chunkSize = 6_400
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkSize, pcm.count)
                continuation.yield(pcm.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    private static func pcm16LE(from data: Data) throws -> Data {
        guard data.count >= 12 else {
            guard !data.isEmpty else { throw DoubaoASRFailure(kind: .emptyAudio) }
            return data
        }
        guard String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE"
        else {
            return data
        }

        var offset = 12
        while offset + 8 <= data.count {
            let identifier = String(
                data: data.subdata(in: offset..<(offset + 4)),
                encoding: .ascii
            )
            let sizeOffset = offset + 4
            let size = Int(data[sizeOffset])
                | Int(data[sizeOffset + 1]) << 8
                | Int(data[sizeOffset + 2]) << 16
                | Int(data[sizeOffset + 3]) << 24
            let payloadStart = offset + 8
            guard size >= 0, payloadStart + size <= data.count else {
                throw DoubaoASRFailure(kind: .invalidAudioFormat)
            }
            if identifier == "data" {
                guard size > 0 else { throw DoubaoASRFailure(kind: .emptyAudio) }
                return data.subdata(in: payloadStart..<(payloadStart + size))
            }
            offset = payloadStart + size + (size % 2)
        }
        throw DoubaoASRFailure(kind: .invalidAudioFormat)
    }
}

extension CredentialedDoubaoTranscriber: ContextualSpeechTranscribing {}
extension CredentialedDoubaoTranscriber: StreamingContextualSpeechTranscribing {}
