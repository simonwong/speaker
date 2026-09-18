import Foundation

/// Substitution, deletion, and insertion counts from one Levenshtein alignment.
public struct EditCounts: Equatable, Codable, Sendable {
    public static let zero = EditCounts(substitutions: 0, deletions: 0, insertions: 0)

    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int

    public init(substitutions: Int, deletions: Int, insertions: Int) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
    }

    public var total: Int { substitutions + deletions + insertions }

    public static func + (lhs: EditCounts, rhs: EditCounts) -> EditCounts {
        EditCounts(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions
        )
    }
}

public enum EditAlignment {
    /// Minimum-edit alignment of `hypothesis` against `reference` with unit
    /// costs. Ties are broken deterministically: match or substitution first,
    /// then deletion, then insertion. Working memory is linear in hypothesis length.
    public static func align<Unit: Equatable>(
        reference: [Unit],
        hypothesis: [Unit]
    ) -> EditCounts {
        guard !reference.isEmpty else {
            return EditCounts(substitutions: 0, deletions: 0, insertions: hypothesis.count)
        }
        guard !hypothesis.isEmpty else {
            return EditCounts(substitutions: 0, deletions: reference.count, insertions: 0)
        }

        var row = (0...hypothesis.count).map {
            EditCounts(substitutions: 0, deletions: 0, insertions: $0)
        }
        for (referenceIndex, referenceUnit) in reference.enumerated() {
            var diagonal = row[0]
            row[0] = EditCounts(substitutions: 0, deletions: referenceIndex + 1, insertions: 0)
            for (hypothesisIndex, hypothesisUnit) in hypothesis.enumerated() {
                let column = hypothesisIndex + 1
                let above = row[column]
                var best = diagonal
                best.substitutions += referenceUnit == hypothesisUnit ? 0 : 1
                var deletion = above
                deletion.deletions += 1
                if deletion.total < best.total { best = deletion }
                var insertion = row[column - 1]
                insertion.insertions += 1
                if insertion.total < best.total { best = insertion }
                row[column] = best
                diagonal = above
            }
        }
        return row[hypothesis.count]
    }
}
