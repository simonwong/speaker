import SwiftUI

/// Product-wide warm accent derived from the app icon's glyph tone. It marks
/// live voice activity and the usage traces produced by that activity.
package enum SpeakerVisualIdentity {
    package static let warmAccent = Color(
        red: 0.97,
        green: 0.87,
        blue: 0.71
    )
    /// One step deeper than `warmAccent`, for the small filled areas that need
    /// more contrast against a light window ground.
    package static let warmAccentDeep = Color(
        red: 0.86,
        green: 0.70,
        blue: 0.46
    )
    package static let iconSurfaceTop = Color(
        red: 0.984,
        green: 0.973,
        blue: 0.953
    )
    package static let iconSurfaceBottom = Color(
        red: 0.894,
        green: 0.867,
        blue: 0.824
    )
    /// The app icon's translucent front layer, printed over the gold one.
    package static let iconPrintCoral = Color(
        red: 0.933,
        green: 0.416,
        blue: 0.298
    )
}
