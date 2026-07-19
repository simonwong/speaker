import Foundation

/// The Personal Dictionary Entry persisted in a Session Record. New records
/// contain only `word`; `legacyAliases` exists solely to preserve search and
/// detail behavior when importing history written by the former alias model.
public struct RecordedDictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let word: String
    public let legacyAliases: [String]

    public init(
        id: UUID = UUID(),
        word: String,
        legacyAliases: [String] = []
    ) {
        self.id = id
        self.word = word
        self.legacyAliases = legacyAliases
    }

    public init(_ entry: DictionaryEntry) {
        self.init(id: entry.id, word: entry.word)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case word
        case canonicalTerm
        case aliases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        word = try container.decodeIfPresent(String.self, forKey: .word)
            ?? container.decode(String.self, forKey: .canonicalTerm)
        legacyAliases = try container.decodeIfPresent(
            [String].self,
            forKey: .aliases
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(word, forKey: .word)
        if !legacyAliases.isEmpty {
            try container.encode(legacyAliases, forKey: .aliases)
        }
    }
}
