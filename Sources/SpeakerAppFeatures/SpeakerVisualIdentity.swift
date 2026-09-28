import SwiftUI

/// Speaker's two brand colours, the two printed layers of the app icon: gold
/// behind, coral in front. Coral marks live voice activity; usage traces run
/// from gold for light use to coral for heavy use.
package enum SpeakerVisualIdentity {
    package static let warmAccent = Color(
        red: 0.97,
        green: 0.87,
        blue: 0.71
    )
    /// One step deeper than `warmAccent`, for the small filled areas that need
    /// more contrast against a light window ground.
    package static let warmAccentDeep = Color(
        red: warmAccentDeepComponents.red,
        green: warmAccentDeepComponents.green,
        blue: warmAccentDeepComponents.blue
    )
    /// The app icon's translucent front layer, printed over the gold one.
    package static let warmCoral = Color(
        red: warmCoralLight.red,
        green: warmCoralLight.green,
        blue: warmCoralLight.blue
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

    /// `warmCoral`, lifted one step on dark surfaces so it keeps its weight.
    package static func warmCoral(for colorScheme: ColorScheme) -> Color {
        let components = coralComponents(for: colorScheme)
        return Color(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
    }

    /// The usage-trace colour for a share of the busiest value: deep gold near
    /// zero, `warmCoral(for:)` at one.
    package static func usageTrace(
        _ fraction: Double,
        colorScheme: ColorScheme
    ) -> Color {
        let t = min(1, max(0, fraction))
        let coral = coralComponents(for: colorScheme)
        return Color(
            red: warmAccentDeepComponents.red * (1 - t) + coral.red * t,
            green: warmAccentDeepComponents.green * (1 - t) + coral.green * t,
            blue: warmAccentDeepComponents.blue * (1 - t) + coral.blue * t
        )
    }

    private typealias Components = (red: Double, green: Double, blue: Double)

    private static let warmAccentDeepComponents: Components = (0.86, 0.70, 0.46)
    private static let warmCoralLight: Components = (0.933, 0.416, 0.298)
    private static let warmCoralBright: Components = (1.0, 0.557, 0.431)

    private static func coralComponents(for colorScheme: ColorScheme) -> Components {
        colorScheme == .dark ? warmCoralBright : warmCoralLight
    }
}
