import Foundation

/// Deterministic text normalization shared by every accuracy metric so that
/// formatting differences (punctuation, width, case, whitespace) never count
/// as recognition errors.
public enum TranscriptNormalizer {
    /// Applies NFKC (which also folds full-width forms to half-width), lowers
    /// Latin case, replaces punctuation and symbols with spaces, keeps
    /// apostrophes that sit inside a Latin word, and collapses whitespace.
    public static func normalize(_ text: String) -> String {
        let folded = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let scalars = Array(folded.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        for (index, scalar) in scalars.enumerated() {
            if isApostrophe(scalar) {
                if index > 0, index + 1 < scalars.count,
                   isLatinLetter(scalars[index - 1]),
                   isLatinLetter(scalars[index + 1]) {
                    output.append("'")
                } else {
                    output.append(" ")
                }
            } else if isSeparator(scalar) {
                output.append(" ")
            } else {
                output.append(scalar)
            }
        }
        return String(output)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The character sequence scored by CER: normalized text without any
    /// whitespace, so spacing between mixed-language segments is not an error.
    public static func scoredCharacters(_ text: String) -> [Character] {
        normalize(text).filter { !$0.isWhitespace }
    }

    private static func isApostrophe(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "'" || scalar == "\u{2019}"
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && scalar.properties.isAlphabetic
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol,
             .otherSymbol, .control, .format:
            return true
        default:
            return false
        }
    }
}
