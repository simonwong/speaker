import AppKit
import SwiftUI

/// Speaker's brand colours, the two printed layers of the app icon. Coral,
/// the front layer, is the primary brand colour: it marks live voice activity
/// and heavy use. Gold, the rear layer, is the secondary one: it carries light
/// use and quiet brand details. Controls keep the system accent colour.
package enum SpeakerVisualIdentity {
    /// The primary brand colour, tuned for light surfaces.
    package static let warmCoral = Color(
        red: warmCoralLight.red,
        green: warmCoralLight.green,
        blue: warmCoralLight.blue
    )
    /// The secondary brand colour.
    package static let warmGold = Color(
        red: warmGoldComponents.red,
        green: warmGoldComponents.green,
        blue: warmGoldComponents.blue
    )
    /// One step deeper than `warmGold`, for the small filled areas that need
    /// more contrast against a light window ground.
    package static let warmGoldDeep = Color(
        red: warmGoldDeepComponents.red,
        green: warmGoldDeepComponents.green,
        blue: warmGoldDeepComponents.blue
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
    /// A muted green for settled, healthy states. It says "fine" without
    /// competing with the warm brand colours or with states that need action.
    package static let settledGreen = Color(
        nsColor: NSColor(name: "SpeakerSettledGreen") { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
                ? NSColor(srgbRed: 0.435, green: 0.643, blue: 0.529, alpha: 1)
                : NSColor(srgbRed: 0.490, green: 0.710, blue: 0.584, alpha: 1)
        }
    )

    /// `warmCoral`, lifted one step on dark surfaces so it keeps its weight.
    package static func warmCoral(for colorScheme: ColorScheme) -> Color {
        let components = colorScheme == .dark ? warmCoralBright : warmCoralLight
        return Color(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
    }

    /// The usage-trace colour for a share of the busiest value. On light
    /// surfaces it is a solid blend from gold to `warmCoral`, never coral
    /// thinned over the light ground, so the ramp stays warm instead of
    /// turning pink. Thin gold reads muddy on dark surfaces, so there the ramp
    /// is the bright coral faded into the ground.
    package static func usageTrace(
        _ fraction: Double,
        colorScheme: ColorScheme
    ) -> Color {
        let t = min(1, max(0, fraction))
        if colorScheme == .dark {
            return warmCoral(for: .dark).opacity(0.3 + 0.7 * t)
        }
        return Color(
            red: warmGoldComponents.red * (1 - t) + warmCoralLight.red * t,
            green: warmGoldComponents.green * (1 - t) + warmCoralLight.green * t,
            blue: warmGoldComponents.blue * (1 - t) + warmCoralLight.blue * t
        )
    }

    private typealias Components = (red: Double, green: Double, blue: Double)

    private static let warmCoralLight: Components = (0.933, 0.416, 0.298)
    private static let warmCoralBright: Components = (1.0, 0.557, 0.431)
    private static let warmGoldComponents: Components = (0.97, 0.87, 0.71)
    private static let warmGoldDeepComponents: Components = (0.86, 0.70, 0.46)
}
