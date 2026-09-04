import Foundation

public enum DictionaryEntryCandidateExtractor {
    public static let maximumCandidateCount = 12
    public static let minimumCandidateLength = 2

    public static func candidates(in text: String) -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []
        var token = ""

        func appendToken() {
            guard candidates.count < maximumCandidateCount,
                  token.unicodeScalars.count >= minimumCandidateLength,
                  token.unicodeScalars.contains(where: isLatinLetter)
            else {
                token.removeAll(keepingCapacity: true)
                return
            }
            let key = token.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                candidates.append(token)
            }
            token.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isCandidateScalar(scalar) {
                token.unicodeScalars.append(scalar)
            } else {
                appendToken()
            }
        }
        appendToken()
        return candidates
    }

    private static func isCandidateScalar(_ scalar: Unicode.Scalar) -> Bool {
        isLatinLetter(scalar)
            || (48...57).contains(scalar.value)
            || scalar == "-"
            || scalar == "."
            || scalar == "'"
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }
}
