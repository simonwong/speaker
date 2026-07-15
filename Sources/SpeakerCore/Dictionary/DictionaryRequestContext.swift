import Foundation

public struct DictionaryProviderCapacity: Equatable, Sendable {
    public static let doubao = DictionaryProviderCapacity(
        maximumHotwordCount: 5_000,
        maximumCharactersPerHotword: 9
    )

    public let maximumHotwordCount: Int
    public let maximumCharactersPerHotword: Int?

    public init(maximumHotwordCount: Int, maximumCharactersPerHotword: Int? = nil) {
        self.maximumHotwordCount = max(0, maximumHotwordCount)
        self.maximumCharactersPerHotword = maximumCharactersPerHotword.map { max(0, $0) }
    }
}

public enum DictionaryContextOmissionReason: String, Codable, Equatable, Sendable {
    case providerCountLimit
    case providerTermLengthLimit
}

public struct DictionaryContextOmission: Codable, Equatable, Sendable {
    public let entryID: UUID
    public let canonicalTerm: String
    public let reason: DictionaryContextOmissionReason

    public init(entryID: UUID, canonicalTerm: String, reason: DictionaryContextOmissionReason) {
        self.entryID = entryID
        self.canonicalTerm = canonicalTerm
        self.reason = reason
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

        for entry in snapshot.entries.sorted(by: DictionaryEntry.stableOrder) {
            if let maximumLength = capacity.maximumCharactersPerHotword,
               entry.canonicalTerm.count > maximumLength
            {
                omissions.append(
                    DictionaryContextOmission(
                        entryID: entry.id,
                        canonicalTerm: entry.canonicalTerm,
                        reason: .providerTermLengthLimit
                    )
                )
                continue
            }
            guard hotwords.count < capacity.maximumHotwordCount else {
                omissions.append(
                    DictionaryContextOmission(
                        entryID: entry.id,
                        canonicalTerm: entry.canonicalTerm,
                        reason: .providerCountLimit
                    )
                )
                continue
            }
            hotwords.append(entry.canonicalTerm)
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
