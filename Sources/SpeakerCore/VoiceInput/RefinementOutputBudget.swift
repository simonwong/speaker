import Foundation

/// Sizes the completion budget of one refinement request from its transcript, so a long
/// full rewrite is not cut off at a fixed limit while short requests keep the old floor.
package enum RefinementOutputBudget {
    /// The completion budget sent for a short transcript, and the lower bound for every
    /// non-thinking model.
    package static let standardMinimum = 2_048
    /// GLM 5.3 Flash always reasons; reasoning and the final answer share this budget.
    package static let thinkingMinimum = 8_192
    /// Ceiling for models without a documented larger output limit, including Custom.
    package static let conservativeMaximum = 8_192
    /// The largest budget the client sends to any model.
    package static let clientMaximum = 16_384

    package static func minimumOutputTokens(
        provider: RefinementProviderID, model: String
    ) -> Int {
        provider == .glm && model == "glm-5.3-flash" ? thinkingMinimum : standardMinimum
    }

    /// The model's output ceiling. Only `glm-4.7-flash` documents a larger output limit
    /// (128K) in docs/research/refinement-default-models.md; it is capped at the client
    /// bound. Every other model, and every manually entered or Custom model, is unknown
    /// and stays at the conservative ceiling.
    package static func maximumOutputTokens(
        provider: RefinementProviderID, model: String
    ) -> Int {
        provider == .glm && model == "glm-4.7-flash" ? clientMaximum : conservativeMaximum
    }

    /// `max(minimum, estimate × 1.5)`, never above `maximum`.
    package static func outputTokenLimit(
        forTranscript text: String, minimum: Int, maximum: Int
    ) -> Int {
        let estimate = estimatedTokenCount(of: text)
        let scaled = estimate + (estimate + 1) / 2
        return min(maximum, max(minimum, scaled))
    }

    /// A deterministic, deliberately generous token estimate. Each CJK ideograph, kana, or
    /// Hangul syllable counts as one token. Each run of other letters and digits is one
    /// word and counts one token per started four characters. Every other non-whitespace
    /// scalar, such as punctuation or emoji, counts as one token; whitespace counts as none.
    package static func estimatedTokenCount(of text: String) -> Int {
        var count = 0
        var wordLength = 0
        for scalar in text.unicodeScalars {
            if isCountedPerCharacter(scalar) {
                count += (wordLength + 3) / 4 + 1
                wordLength = 0
            } else if CharacterSet.alphanumerics.contains(scalar) {
                wordLength += 1
            } else {
                count += (wordLength + 3) / 4
                wordLength = 0
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
            }
        }
        return count + (wordLength + 3) / 4
    }

    private static func isCountedPerCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic
            || (0x3040...0x30FF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value)
    }
}
