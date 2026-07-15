import Foundation
import NaturalLanguage

public struct DictionaryReplacement: Codable, Equatable, Sendable {
    public let entryID: UUID
    public let alias: String
    public let canonicalTerm: String
    public let matchedText: String
    public let utf16Location: Int
    public let utf16Length: Int

    public init(
        entryID: UUID,
        alias: String,
        canonicalTerm: String,
        matchedText: String,
        utf16Location: Int,
        utf16Length: Int
    ) {
        self.entryID = entryID
        self.alias = alias
        self.canonicalTerm = canonicalTerm
        self.matchedText = matchedText
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }
}

public struct DictionaryNormalizationResult: Codable, Equatable, Sendable {
    public let originalText: String
    public let normalizedText: String
    public let replacements: [DictionaryReplacement]

    public init(
        originalText: String,
        normalizedText: String,
        replacements: [DictionaryReplacement]
    ) {
        self.originalText = originalText
        self.normalizedText = normalizedText
        self.replacements = replacements
    }
}

public enum DictionaryAliasNormalizer {
    private struct AliasOwner {
        let alias: String
        let entry: DictionaryEntry
    }

    private struct Match {
        let range: NSRange
        let owner: AliasOwner
        let matchedText: String
    }

    public static func normalize(
        _ text: String,
        using snapshot: PersonalDictionarySnapshot
    ) -> DictionaryNormalizationResult {
        guard !text.isEmpty else {
            return DictionaryNormalizationResult(
                originalText: text,
                normalizedText: text,
                replacements: []
            )
        }

        let unambiguousAliases = uniqueAliases(in: snapshot)
        let tokenBoundaries = linguisticTokenBoundaries(in: text)
        var candidates: [Match] = []
        let wholeRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for owner in unambiguousAliases {
            let escapedAlias = NSRegularExpression.escapedPattern(for: owner.alias)
            let containsASCIIWordCharacter = owner.alias.unicodeScalars.contains { scalar in
                (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 95
            }
            let pattern = containsASCIIWordCharacter
                ? "(?<![A-Za-z0-9_])\(escapedAlias)(?![A-Za-z0-9_])"
                : escapedAlias
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for match in expression.matches(in: text, range: wholeRange) {
                guard let range = Range(match.range, in: text) else { continue }
                if !containsASCIIWordCharacter {
                    guard tokenBoundaries.contains(match.range.location),
                          tokenBoundaries.contains(NSMaxRange(match.range))
                    else { continue }
                }
                let matchedText = String(text[range])
                guard matchedText != owner.entry.canonicalTerm else { continue }
                candidates.append(Match(range: match.range, owner: owner, matchedText: matchedText))
            }
        }

        let orderedCandidates = candidates.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return DictionaryTermKey(lhs.owner.alias).value < DictionaryTermKey(rhs.owner.alias).value
        }

        var selected: [Match] = []
        var nextAvailableLocation = 0
        for candidate in orderedCandidates {
            guard candidate.range.location >= nextAvailableLocation else { continue }
            selected.append(candidate)
            nextAvailableLocation = NSMaxRange(candidate.range)
        }

        var normalizedText = text
        for match in selected.reversed() {
            guard let range = Range(match.range, in: normalizedText) else { continue }
            normalizedText.replaceSubrange(range, with: match.owner.entry.canonicalTerm)
        }

        let replacements = selected.map { match in
            DictionaryReplacement(
                entryID: match.owner.entry.id,
                alias: match.owner.alias,
                canonicalTerm: match.owner.entry.canonicalTerm,
                matchedText: match.matchedText,
                utf16Location: match.range.location,
                utf16Length: match.range.length
            )
        }
        return DictionaryNormalizationResult(
            originalText: text,
            normalizedText: normalizedText,
            replacements: replacements
        )
    }

    private static func linguisticTokenBoundaries(in text: String) -> Set<Int> {
        var boundaries: Set<Int> = [0, text.utf16.count]
        var runStart: String.Index?
        var index = text.startIndex

        func addRun(_ range: Range<String.Index>) {
            let run = String(text[range])
            let runOffset = NSRange(range, in: text).location
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = run
            tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { tokenRange, _ in
                let local = NSRange(tokenRange, in: run)
                boundaries.insert(runOffset + local.location)
                boundaries.insert(runOffset + NSMaxRange(local))
                return true
            }
        }

        while index < text.endIndex {
            let next = text.index(after: index)
            if isHan(text[index]) {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                addRun(start..<index)
                runStart = nil
            }
            index = next
        }
        if let start = runStart {
            addRun(start..<text.endIndex)
        }
        return boundaries
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }

    private static func uniqueAliases(in snapshot: PersonalDictionarySnapshot) -> [AliasOwner] {
        var claims: [String: [AliasOwner]] = [:]
        for entry in snapshot.entries where entry.isEnabled {
            for alias in entry.aliases {
                let key = DictionaryTermKey(alias).value
                guard !key.isEmpty else { continue }
                claims[key, default: []].append(AliasOwner(alias: alias, entry: entry))
            }
        }

        return claims.values.compactMap { owners in
            let uniqueOwners = Dictionary(grouping: owners, by: { $0.entry.id })
                .values
                .compactMap(\.first)
            guard uniqueOwners.count == 1, let owner = uniqueOwners.first else { return nil }
            guard DictionaryTermKey(owner.alias) != DictionaryTermKey(owner.entry.canonicalTerm) else {
                return nil
            }
            return owner
        }.sorted { lhs, rhs in
            if lhs.alias.count != rhs.alias.count { return lhs.alias.count > rhs.alias.count }
            let lhsKey = DictionaryTermKey(lhs.alias).value
            let rhsKey = DictionaryTermKey(rhs.alias).value
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.entry.id.uuidString < rhs.entry.id.uuidString
        }
    }
}
