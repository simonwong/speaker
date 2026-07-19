import Foundation

/// Compatibility payload for history created before Personal Dictionary
/// entries became request-scoped words. New sessions never create replacements.
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
