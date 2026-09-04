import Foundation

/// One sample's error rate: edit counts over the normalized reference length.
public struct ErrorRateResult: Equatable, Codable, Sendable {
    public let referenceLength: Int
    public let counts: EditCounts

    public init(referenceLength: Int, counts: EditCounts) {
        self.referenceLength = max(0, referenceLength)
        self.counts = counts
    }

    /// Errors divided by the reference length. An empty reference uses a
    /// denominator of one so inserted output still registers as error.
    public var rate: Double {
        Double(counts.total) / Double(max(referenceLength, 1))
    }
}

/// Corpus-level totals plus the mean of per-sample rates.
public struct ErrorRateAggregate: Equatable, Codable, Sendable {
    public let sampleCount: Int
    public let referenceLength: Int
    public let counts: EditCounts
    public let corpusRate: Double
    public let meanSampleRate: Double

    public init(results: [ErrorRateResult]) {
        sampleCount = results.count
        referenceLength = results.reduce(0) { $0 + $1.referenceLength }
        counts = results.reduce(EditCounts.zero) { $0 + $1.counts }
        corpusRate = results.isEmpty
            ? 0
            : Double(counts.total) / Double(max(referenceLength, 1))
        meanSampleRate = results.isEmpty
            ? 0
            : results.reduce(0.0) { $0 + $1.rate } / Double(results.count)
    }
}

public enum AccuracyMetrics {
    /// Character error rate over normalized, whitespace-free characters.
    public static func characterErrorRate(
        reference: String,
        hypothesis: String
    ) -> ErrorRateResult {
        let referenceUnits = TranscriptNormalizer.scoredCharacters(reference)
        let hypothesisUnits = TranscriptNormalizer.scoredCharacters(hypothesis)
        return ErrorRateResult(
            referenceLength: referenceUnits.count,
            counts: EditAlignment.align(reference: referenceUnits, hypothesis: hypothesisUnits)
        )
    }

    /// Word error rate over Latin tokens only, so mixed Mandarin-English
    /// samples report how the English spans fared independently of CER.
    public static func latinWordErrorRate(
        reference: String,
        hypothesis: String
    ) -> ErrorRateResult {
        let referenceTokens = latinTokens(in: reference)
        let hypothesisTokens = latinTokens(in: hypothesis)
        return ErrorRateResult(
            referenceLength: referenceTokens.count,
            counts: EditAlignment.align(reference: referenceTokens, hypothesis: hypothesisTokens)
        )
    }

    /// Maximal runs of ASCII letters, digits, and in-word apostrophes in the
    /// normalized text. CJK characters and other scripts never form tokens.
    public static func latinTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                tokens.append(String(current))
                current.removeAll()
            }
        }
        for scalar in TranscriptNormalizer.normalize(text).unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "'" {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
