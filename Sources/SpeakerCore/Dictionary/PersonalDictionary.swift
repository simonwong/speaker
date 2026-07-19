import Foundation

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let word: String

    public init(
        id: UUID = UUID(),
        word: String
    ) {
        self.id = id
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case word
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            word: try container.decode(String.self, forKey: .word)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(word, forKey: .word)
    }
}

extension DictionaryEntry {
    static func stableOrder(_ lhs: DictionaryEntry, _ rhs: DictionaryEntry) -> Bool {
        let lhsKey = DictionaryTermKey(lhs.word).value
        let rhsKey = DictionaryTermKey(rhs.word).value
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public enum PersonalDictionaryValidationIssue: Equatable, Sendable {
    case emptyWord(entryID: UUID)
    case duplicateWord(word: String, entryIDs: [UUID])
}

extension PersonalDictionaryValidationIssue: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyWord:
            "词条不能为空。"
        case let .duplicateWord(word, _):
            "词条“\(word)”已存在。"
        }
    }
}

public struct PersonalDictionaryValidationError: Error, Equatable, Sendable {
    public let issues: [PersonalDictionaryValidationIssue]

    public init(issues: [PersonalDictionaryValidationIssue]) {
        self.issues = issues
    }
}

extension PersonalDictionaryValidationError: LocalizedError {
    public var errorDescription: String? {
        issues.first?.errorDescription ?? "个人词库无效。"
    }
}

public enum PersonalDictionaryValidator {
    public static func validate(_ entries: [DictionaryEntry]) -> [PersonalDictionaryValidationIssue] {
        var issues: [PersonalDictionaryValidationIssue] = []

        for entry in entries where entry.word.isEmpty {
            issues.append(.emptyWord(entryID: entry.id))
        }

        let wordGroups = Dictionary(grouping: entries.filter { !$0.word.isEmpty }) {
            DictionaryTermKey($0.word).value
        }
        for group in wordGroups.values where group.count > 1 {
            let ordered = group.sorted(by: DictionaryEntry.stableOrder)
            issues.append(
                .duplicateWord(
                    word: ordered[0].word,
                    entryIDs: ordered.map(\.id)
                )
            )
        }

        return issues.sorted(by: issueOrder)
    }

    private static func issueOrder(
        _ lhs: PersonalDictionaryValidationIssue,
        _ rhs: PersonalDictionaryValidationIssue
    ) -> Bool {
        issueKey(lhs) < issueKey(rhs)
    }

    private static func issueKey(_ issue: PersonalDictionaryValidationIssue) -> String {
        switch issue {
        case let .emptyWord(id):
            "0:\(id.uuidString)"
        case let .duplicateWord(word, _):
            "1:\(DictionaryTermKey(word).value)"
        }
    }
}

public struct PersonalDictionary: Equatable, Sendable {
    public static let empty = try! PersonalDictionary(entries: [])

    public let entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry]) throws {
        let issues = PersonalDictionaryValidator.validate(entries)
        guard issues.isEmpty else {
            throw PersonalDictionaryValidationError(issues: issues)
        }
        self.entries = entries
    }

    public func snapshot(
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> PersonalDictionarySnapshot {
        PersonalDictionarySnapshot(
            id: id,
            createdAt: createdAt,
            entries: entries
        )
    }
}

public struct PersonalDictionarySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let entries: [DictionaryEntry]

    public init(id: UUID = UUID(), createdAt: Date = Date(), entries: [DictionaryEntry]) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
    }
}

struct DictionaryTermKey: Hashable, Sendable {
    let value: String

    init(_ term: String) {
        value = term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
