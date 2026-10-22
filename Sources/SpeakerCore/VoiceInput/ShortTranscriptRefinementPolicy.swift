import Foundation

/// Decides when Concise Cleanup has nothing to change in a transcript, so the
/// session delivers the recognition Stage Result without a refinement request
/// and records the refinement as skipped.
///
/// The rule is deliberately narrow. Only the built-in Concise Cleanup prompt
/// qualifies: Full Rewrite restructures text, and a Custom Mode or a saved
/// prompt override may ask for anything. A non-empty Personal Dictionary keeps
/// refinement, because it is the second chance to correct a misheard Entry.
/// The transcript itself must already look finished: short, ending in a
/// sentence mark, on one line, and free of the fillers, stutters, and
/// self-corrections that Concise Cleanup removes.
package enum ShortTranscriptRefinementPolicy {
    /// The most characters, not counting whitespace and punctuation, a
    /// transcript may have and still skip refinement.
    package static let maximumCharacterCount = 10

    private static let sentenceEndings: Set<Character> = ["。", "！", "？", "…", ".", "!", "?"]

    /// Fillers and self-correction phrases that Concise Cleanup acts on.
    private static let chineseCleanupMarkers = [
        "嗯", "啊", "呃", "额", "哦", "唉", "诶", "哎",
        "那个", "这个", "就是", "然后", "不对", "不是", "我是说", "应该是",
    ]
    private static let latinCleanupMarkers: Set<String> = [
        "um", "umm", "uh", "uhm", "er", "erm", "ah", "hmm", "like",
    ]

    package static func skipsRefinement(
        of transcript: String,
        mode: TextRefinementMode,
        dictionaryWords: [String]
    ) -> Bool {
        guard case .conciseCleanup(promptOverride: nil) = mode,
            dictionaryWords.isEmpty
        else { return false }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last, sentenceEndings.contains(last),
            !text.contains(where: \.isNewline)
        else { return false }
        let letters = text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
        guard !letters.isEmpty, letters.count <= maximumCharacterCount else { return false }
        guard !chineseCleanupMarkers.contains(where: { text.contains($0) }) else {
            return false
        }
        let latinWords = text.lowercased().split { !$0.isLetter || !$0.isASCII }
        guard !latinWords.contains(where: { latinCleanupMarkers.contains(String($0)) }) else {
            return false
        }
        return !hasStutter(Array(letters))
    }

    /// A character said three times in a row, or a run of two or more
    /// characters said twice in a row. A doubled single character such as
    /// 谢谢 is ordinary speech.
    private static func hasStutter(_ letters: [Character]) -> Bool {
        for index in letters.indices.dropFirst(2)
        where letters[index] == letters[index - 1] && letters[index] == letters[index - 2] {
            return true
        }
        guard letters.count >= 4 else { return false }
        for length in 2...(letters.count / 2) {
            for start in 0...(letters.count - 2 * length)
            where letters[start..<start + length] == letters[start + length..<start + 2 * length] {
                return true
            }
        }
        return false
    }
}
