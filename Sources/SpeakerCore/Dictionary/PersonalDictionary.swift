import Foundation

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var canonicalTerm: String
    public var aliases: [String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        canonicalTerm: String,
        aliases: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.canonicalTerm = canonicalTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = Self.cleanAliases(aliases)
        self.isEnabled = isEnabled
    }

    private static func cleanAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.compactMap { alias in
            let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanAlias.isEmpty else { return nil }
            let key = DictionaryTermKey(cleanAlias).value
            guard seen.insert(key).inserted else { return nil }
            return cleanAlias
        }
    }
}

public enum PersonalDictionaryValidationIssue: Equatable, Sendable {
    case emptyCanonicalTerm(entryID: UUID)
    case duplicateCanonicalTerm(term: String, entryIDs: [UUID])
    case conflictingEnabledAlias(alias: String, entryIDs: [UUID])
}

extension PersonalDictionaryValidationIssue: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCanonicalTerm:
            "标准写法不能为空。"
        case let .duplicateCanonicalTerm(term, _):
            "标准写法“\(term)”已存在。"
        case let .conflictingEnabledAlias(alias, _):
            "口语别名“\(alias)”同时属于多个已启用词条。"
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

        for entry in entries where entry.canonicalTerm.isEmpty {
            issues.append(.emptyCanonicalTerm(entryID: entry.id))
        }

        let canonicalGroups = Dictionary(grouping: entries.filter { !$0.canonicalTerm.isEmpty }) {
            DictionaryTermKey($0.canonicalTerm).value
        }
        for group in canonicalGroups.values where group.count > 1 {
            let ordered = group.sorted(by: DictionaryEntry.stableOrder)
            issues.append(
                .duplicateCanonicalTerm(
                    term: ordered[0].canonicalTerm,
                    entryIDs: ordered.map(\.id)
                )
            )
        }

        struct AliasClaim {
            let spelling: String
            let entry: DictionaryEntry
        }
        var aliasClaims: [String: [AliasClaim]] = [:]
        for entry in entries where entry.isEnabled {
            for alias in entry.aliases {
                aliasClaims[DictionaryTermKey(alias).value, default: []].append(
                    AliasClaim(spelling: alias, entry: entry)
                )
            }
        }
        for claims in aliasClaims.values {
            let uniqueEntries = Dictionary(grouping: claims, by: { $0.entry.id })
                .values
                .compactMap(\.first)
                .sorted { DictionaryEntry.stableOrder($0.entry, $1.entry) }
            guard uniqueEntries.count > 1 else { continue }
            issues.append(
                .conflictingEnabledAlias(
                    alias: uniqueEntries[0].spelling,
                    entryIDs: uniqueEntries.map(\.entry.id)
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
        case let .emptyCanonicalTerm(id):
            "0:\(id.uuidString)"
        case let .duplicateCanonicalTerm(term, _):
            "1:\(DictionaryTermKey(term).value)"
        case let .conflictingEnabledAlias(alias, _):
            "2:\(DictionaryTermKey(alias).value)"
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

    public func snapshotEnabled(
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> PersonalDictionarySnapshot {
        PersonalDictionarySnapshot(
            id: id,
            createdAt: createdAt,
            entries: entries.filter(\.isEnabled).sorted(by: DictionaryEntry.stableOrder)
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
        self.entries = entries.filter(\.isEnabled).sorted(by: DictionaryEntry.stableOrder)
    }
}

extension DictionaryEntry {
    static func stableOrder(_ lhs: DictionaryEntry, _ rhs: DictionaryEntry) -> Bool {
        let lhsKey = DictionaryTermKey(lhs.canonicalTerm).value
        let rhsKey = DictionaryTermKey(rhs.canonicalTerm).value
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.id.uuidString < rhs.id.uuidString
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
