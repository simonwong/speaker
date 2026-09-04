/// The single accessibility announcement seam.
///
/// Presentation code hands user-facing messages to this closure; the App owns
/// the only `NSAccessibility` announcement post behind it.
package typealias AccessibilityAnnounce = @MainActor (String) -> Void
