import SwiftUI

package struct VoiceInputHUDContrastPalette: Equatable, Sendable {
    package let darkBorderOpacity: Double
    package let darkBorderLineWidth: Double
    package let darkDividerOpacity: Double
    package let darkControlBackgroundOpacity: Double
    package let darkControlForegroundOpacity: Double
    package let errorIconOpacity: Double
    package let glassTintOpacity: Double
    package let fallbackTintTopOpacity: Double
    package let fallbackTintBottomOpacity: Double

    package init(increased: Bool) {
        if increased {
            darkBorderOpacity = 0.3
            darkBorderLineWidth = 1.5
            darkDividerOpacity = 0.32
            darkControlBackgroundOpacity = 0.2
            darkControlForegroundOpacity = 1
            errorIconOpacity = 1
            glassTintOpacity = 0.18
            fallbackTintTopOpacity = 0.15
            fallbackTintBottomOpacity = 0.22
        } else {
            darkBorderOpacity = 0.12
            darkBorderLineWidth = 1
            darkDividerOpacity = 0.13
            darkControlBackgroundOpacity = 0.08
            darkControlForegroundOpacity = 0.5
            errorIconOpacity = 0.7
            glassTintOpacity = 0.1
            fallbackTintTopOpacity = 0.07
            fallbackTintBottomOpacity = 0.15
        }
    }
}

private struct VoiceInputHUDIncreasedContrastOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    package var voiceInputHUDIncreasedContrastOverride: Bool? {
        get { self[VoiceInputHUDIncreasedContrastOverrideKey.self] }
        set { self[VoiceInputHUDIncreasedContrastOverrideKey.self] = newValue }
    }
}
