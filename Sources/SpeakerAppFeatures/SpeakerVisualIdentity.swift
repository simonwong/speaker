import SwiftUI

/// Product-wide warm accent derived from the app icon's glyph tone. It marks
/// live voice activity and the usage traces produced by that activity.
package enum SpeakerVisualIdentity {
    package static let warmAccent = Color(
        red: 0.97,
        green: 0.87,
        blue: 0.71
    )
    package static let iconSurfaceTop = Color(
        red: 0.13,
        green: 0.13,
        blue: 0.14
    )
    package static let iconSurfaceBottom = Color(
        red: 0.08,
        green: 0.08,
        blue: 0.09
    )
}
