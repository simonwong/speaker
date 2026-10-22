import Foundation

/// How much of an Input Target's value Speaker reads as evidence.
package enum AccessibilityValueEvidenceLimits {
    /// A value longer than this is never used as evidence, so delivery to it
    /// is paste-only and its paste stays unconfirmed. The same bound caps the
    /// whole-value read used when a target cannot read a range.
    package static let maximumCharacterCount = 20_000
    /// Characters read on each side of the selection.
    package static let contextCharacterCount = 256
}

/// A window of a target's value. Lengths and ranges count UTF-16 code units,
/// as Accessibility does. The window is kept as code units because its edges
/// can split a surrogate pair, which a Swift `String` would repair.
package struct AccessibilityTextSample: Equatable, Sendable {
    /// The length of the whole value.
    package let length: Int
    /// The part of the value that `codeUnits` holds, within `0...length`.
    package let range: NSRange
    package let codeUnits: [UInt16]

    package init(length: Int, range: NSRange, codeUnits: [UInt16]) {
        self.length = length
        self.range = range
        self.codeUnits = codeUnits
    }

    package init(length: Int, range: NSRange, text: String) {
        self.init(length: length, range: range, codeUnits: Array(text.utf16))
    }

    /// Cuts the window `range`, clamped to the value, out of a whole value.
    package init(value: String, range: NSRange) {
        let whole = Array(value.utf16)
        let clamped = AccessibilityValueEvidence.clamp(range, toLength: whole.count)
        self.init(
            length: whole.count,
            range: clamped,
            codeUnits: Array(whole[clamped.location..<NSMaxRange(clamped)])
        )
    }

    /// The capture-time evidence for a whole value, or `nil` when the value
    /// is too long to use.
    package static func evidence(
        fromValue value: String,
        selection: NSRange?
    ) -> Self? {
        guard
            let range = AccessibilityValueEvidence.sampleRange(
                around: selection,
                length: value.utf16.count
            )
        else { return nil }
        return Self(value: value, range: range)
    }

    /// Whether this reading shows `evidence`: the same whole length and the
    /// same code units from the start of `evidence`'s window. A reading may
    /// cover more than `evidence` does.
    package func shows(_ evidence: AccessibilityTextSample) -> Bool {
        guard length == evidence.length,
            range.location == evidence.range.location,
            codeUnits.count >= evidence.codeUnits.count
        else { return false }
        return codeUnits.prefix(evidence.codeUnits.count).elementsEqual(evidence.codeUnits)
    }
}

package enum AccessibilityValueEvidence {
    /// The window read as evidence: the selection with up to
    /// `contextCharacterCount` characters on each side, or the start of the
    /// value when there is no usable selection. `nil` when the value is too
    /// long to use as evidence.
    package static func sampleRange(around selection: NSRange?, length: Int) -> NSRange? {
        guard length >= 0,
            length <= AccessibilityValueEvidenceLimits.maximumCharacterCount
        else { return nil }
        let context = AccessibilityValueEvidenceLimits.contextCharacterCount
        guard let selection,
            selection.location >= 0,
            selection.length >= 0,
            NSMaxRange(selection) <= length
        else {
            return NSRange(location: 0, length: min(length, 2 * context))
        }
        let start = max(0, selection.location - context)
        let end = min(length, NSMaxRange(selection) + context)
        return NSRange(location: start, length: end - start)
    }

    package static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let start = min(max(0, range.location), length)
        let end = min(max(start, range.location + max(0, range.length)), length)
        return NSRange(location: start, length: end - start)
    }
}

/// What a readable target's value should show once a paste replaces its
/// selection, judged on the evidence window and the value's length rather
/// than the whole value.
package struct AccessibilityPasteExpectation: Sendable {
    package enum Reading: Equatable, Sendable {
        case expected
        case original
        case other
    }

    package let original: AccessibilityTextSample
    package let expected: AccessibilityTextSample

    /// `nil` when the selection does not lie inside the evidence window.
    package init?(
        original: AccessibilityTextSample,
        selection: NSRange?,
        inserting text: String
    ) {
        guard let selection,
            selection.location >= original.range.location,
            selection.length >= 0,
            NSMaxRange(selection) <= NSMaxRange(original.range),
            original.codeUnits.count == original.range.length
        else { return nil }
        let selectionStart = selection.location - original.range.location
        let selectionEnd = NSMaxRange(selection) - original.range.location
        let inserted = Array(text.utf16)
        let expectedUnits =
            Array(original.codeUnits[..<selectionStart])
            + inserted
            + Array(original.codeUnits[selectionEnd...])
        self.original = original
        expected = AccessibilityTextSample(
            length: original.length - selection.length + inserted.count,
            range: NSRange(location: original.range.location, length: expectedUnits.count),
            codeUnits: expectedUnits
        )
    }

    /// One read covers both the original and the expected window.
    package var receiptRange: NSRange {
        NSRange(
            location: original.range.location,
            length: max(original.range.length, expected.range.length)
        )
    }

    package func classify(_ reading: AccessibilityTextSample) -> Reading {
        if reading.shows(expected) { return .expected }
        if reading.shows(original) { return .original }
        return .other
    }
}
