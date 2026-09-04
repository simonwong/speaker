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
    /// then deletion, then insertion.
    public static func align<Unit: Equatable>(
        reference: [Unit],
        hypothesis: [Unit]
    ) -> EditCounts {
        let rows = reference.count + 1
        let columns = hypothesis.count + 1
        var distance = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
        for row in 0..<rows { distance[row][0] = row }
        for column in 0..<columns { distance[0][column] = column }
        if rows > 1, columns > 1 {
            for row in 1..<rows {
                for column in 1..<columns {
                    let cost = reference[row - 1] == hypothesis[column - 1] ? 0 : 1
                    distance[row][column] = min(
                        distance[row - 1][column - 1] + cost,
                        distance[row - 1][column] + 1,
                        distance[row][column - 1] + 1
                    )
                }
            }
        }

        var counts = EditCounts.zero
        var row = reference.count
        var column = hypothesis.count
        while row > 0 || column > 0 {
            if row > 0, column > 0 {
                let cost = reference[row - 1] == hypothesis[column - 1] ? 0 : 1
                if distance[row][column] == distance[row - 1][column - 1] + cost {
                    counts.substitutions += cost
                    row -= 1
                    column -= 1
                    continue
                }
            }
            if row > 0, distance[row][column] == distance[row - 1][column] + 1 {
                counts.deletions += 1
                row -= 1
                continue
            }
            counts.insertions += 1
            column -= 1
        }
        return counts
    }
}
