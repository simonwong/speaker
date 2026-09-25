import SwiftUI

package enum AdaptiveGlassSurfaceStyle: Equatable, Sendable {
    case liquidGlass
    case systemMaterial
    case opaque
}

private struct AdaptiveGlassSurfaceStyleOverrideKey: EnvironmentKey {
    static let defaultValue: AdaptiveGlassSurfaceStyle? = nil
}

extension EnvironmentValues {
    package var adaptiveGlassSurfaceStyleOverride: AdaptiveGlassSurfaceStyle? {
        get { self[AdaptiveGlassSurfaceStyleOverrideKey.self] }
        set { self[AdaptiveGlassSurfaceStyleOverrideKey.self] = newValue }
    }

    /// The style every main-window surface draws in: the override when a spec
    /// sets one, otherwise the system policy.
    package var adaptiveGlassSurfaceStyle: AdaptiveGlassSurfaceStyle {
        adaptiveGlassSurfaceStyleOverride
            ?? AdaptiveGlassSurfacePolicy.resolve(
                reduceTransparency: accessibilityReduceTransparency)
    }
}

package enum AdaptiveGlassSurfacePolicy {
    package static func resolve(
        reduceTransparency: Bool
    ) -> AdaptiveGlassSurfaceStyle {
        resolve(
            reduceTransparency: reduceTransparency,
            supportsLiquidGlass: {
                if #available(macOS 26.0, *) { return true }
                return false
            }()
        )
    }

    package static func resolve(
        reduceTransparency: Bool,
        supportsLiquidGlass: Bool
    ) -> AdaptiveGlassSurfaceStyle {
        if reduceTransparency { return .opaque }
        return supportsLiquidGlass ? .liquidGlass : .systemMaterial
    }
}
