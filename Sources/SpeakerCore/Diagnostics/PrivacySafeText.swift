import Foundation

/// A local error that already describes itself without exposing user content.
/// Errors whose payload is purely technical adopt this so the one privacy-safe
/// formatter reuses their wording instead of an `NSError` summary.
package protocol PrivacySafeDescribing {
    var privacySafeDescription: String { get }
}

/// The single generator of privacy-safe technical text in Speaker.
///
/// A local failure becomes an error domain, code, and description; a network
/// failure becomes the stable `URLError` classification and nothing else.
/// No other type turns an error into a diagnostic string, so transcript text,
/// credentials, file contents, and raw provider messages have exactly one
/// place where they can be kept out of notices, diagnostics, and Session
/// Records.
package enum PrivacySafeText {
    /// A content-free reason for a local failure.
    package static func reason(for error: Error) -> String {
        if let describing = error as? any PrivacySafeDescribing {
            return describing.privacySafeDescription
        }
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    /// The stable classification of a network failure, or `nil` when the error
    /// did not come from URL loading. A provider's own message never appears.
    package static func networkMessage(for error: Error) -> String? {
        guard let urlError = error as? URLError else { return nil }
        return String(describing: urlError.code)
    }
}
