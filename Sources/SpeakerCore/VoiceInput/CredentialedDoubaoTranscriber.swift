import Foundation

/// Loads the current BYOK credential at request time so changing the Keychain
/// value never requires rebuilding the long-lived voice-input session actor.
public actor CredentialedDoubaoTranscriber: SpeechTranscribing {
    private let credentials: any ProviderCredentialStoring
    private let installationID: String
    private let transport: any DoubaoASRTransport

    public init(
        credentials: any ProviderCredentialStoring,
        installationID: String,
        transport: any DoubaoASRTransport = URLSessionDoubaoASRTransport()
    ) {
        self.credentials = credentials
        self.installationID = installationID
        self.transport = transport
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        guard let apiKey = try await credentials.apiKey(for: .doubao) else {
            throw DoubaoASRFailure(kind: .invalidCredential)
        }
        let client = DoubaoFlashASRClient(
            configuration: .init(
                apiKey: apiKey,
                installationID: installationID
            ),
            transport: transport
        )
        return try await client.transcribe(audio)
    }

    public func hasAPIKey() async throws -> Bool {
        try await credentials.apiKey(for: .doubao) != nil
    }

    public func saveAPIKey(_ apiKey: String) async throws {
        try await credentials.save(apiKey: apiKey, for: .doubao)
    }

    public func deleteAPIKey() async throws {
        try await credentials.deleteAPIKey(for: .doubao)
    }

    /// A valid silent WAV exercises authentication and resource activation.
    /// The provider's documented silence response therefore counts as a
    /// successful connection check and avoids storing a spoken sample.
    public func checkConnection() async throws -> String? {
        do {
            return try await transcribe(Self.silentProbeAudio).providerRequestID
        } catch let failure as DoubaoASRFailure
            where failure.kind == .silence || failure.kind == .emptyTranscript {
            return failure.providerRequestID
        }
    }

    private static let silentProbeAudio = CapturedAudio(
        data: makeSilentWAV(sampleRate: 16_000, milliseconds: 400),
        duration: .milliseconds(400),
        peakPower: -160
    )

    private static func makeSilentWAV(sampleRate: Int, milliseconds: Int) -> Data {
        let sampleCount = sampleRate * milliseconds / 1_000
        let dataSize = sampleCount * 2
        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVEfmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }
}
