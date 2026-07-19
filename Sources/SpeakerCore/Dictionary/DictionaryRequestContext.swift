import Foundation

public struct DictionaryProviderCapacity: Equatable, Sendable {
    /// Doubao documents 100 provider tokens for bidirectional streaming but
    /// publishes no compatible tokenizer. This 100-entry guard is conservative
    /// request hygiene, not a claim that every Entry maps to one provider token.
    public static let doubao = DictionaryProviderCapacity(
        maximumHotwordCount: 100
    )

    public let maximumHotwordCount: Int

    public init(maximumHotwordCount: Int) {
        self.maximumHotwordCount = max(0, maximumHotwordCount)
    }
}

public enum DictionaryContextOmissionReason: String, Codable, Equatable, Sendable {
    case providerCountLimit
    /// Retained only so historical records written before the direct-hotword
    /// migration remain readable.
    case providerTermLengthLimit
}

public struct DictionaryContextOmission: Codable, Equatable, Sendable {
    public let entryID: UUID
    public let word: String
    public let reason: DictionaryContextOmissionReason

    public init(entryID: UUID, word: String, reason: DictionaryContextOmissionReason) {
        self.entryID = entryID
        self.word = word
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case entryID
        case word
        case canonicalTerm
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try container.decode(UUID.self, forKey: .entryID)
        word = try container.decodeIfPresent(String.self, forKey: .word)
            ?? container.decode(String.self, forKey: .canonicalTerm)
        reason = try container.decode(DictionaryContextOmissionReason.self, forKey: .reason)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryID, forKey: .entryID)
        try container.encode(word, forKey: .word)
        try container.encode(reason, forKey: .reason)
    }
}

public struct DictionaryRequestContext: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let hotwords: [String]
    public let includedEntryIDs: [UUID]
    public let omissions: [DictionaryContextOmission]

    public init(
        snapshotID: UUID,
        hotwords: [String],
        includedEntryIDs: [UUID],
        omissions: [DictionaryContextOmission]
    ) {
        self.snapshotID = snapshotID
        self.hotwords = hotwords
        self.includedEntryIDs = includedEntryIDs
        self.omissions = omissions
    }
}

public enum DictionaryRequestContextBuilder {
    public static func makeContext(
        from snapshot: PersonalDictionarySnapshot,
        capacity: DictionaryProviderCapacity = .doubao
    ) -> DictionaryRequestContext {
        var hotwords: [String] = []
        var includedEntryIDs: [UUID] = []
        var omissions: [DictionaryContextOmission] = []

        for entry in snapshot.entries {
            guard hotwords.count < capacity.maximumHotwordCount else {
                omissions.append(
                    DictionaryContextOmission(
                        entryID: entry.id,
                        word: entry.word,
                        reason: .providerCountLimit
                    )
                )
                continue
            }
            hotwords.append(entry.word)
            includedEntryIDs.append(entry.id)
        }

        return DictionaryRequestContext(
            snapshotID: snapshot.id,
            hotwords: hotwords,
            includedEntryIDs: includedEntryIDs,
            omissions: omissions
        )
    }
}
