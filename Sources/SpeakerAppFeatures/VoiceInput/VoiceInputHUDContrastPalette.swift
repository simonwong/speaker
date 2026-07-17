package struct VoiceInputHUDContrastPalette: Equatable, Sendable {
    package let darkBorderOpacity: Double
    package let darkBorderLineWidth: Double
    package let darkDividerOpacity: Double
    package let darkControlBackgroundOpacity: Double
    package let darkControlForegroundOpacity: Double
    package let cardBorderOpacity: Double
    package let cardBorderLineWidth: Double
    package let secondaryControlOpacity: Double
    package let errorIconOpacity: Double

    package init(increased: Bool) {
        if increased {
            darkBorderOpacity = 0.3
            darkBorderLineWidth = 1.5
            darkDividerOpacity = 0.32
            darkControlBackgroundOpacity = 0.2
            darkControlForegroundOpacity = 1
            cardBorderOpacity = 0.62
            cardBorderLineWidth = 1.5
            secondaryControlOpacity = 1
            errorIconOpacity = 1
        } else {
            darkBorderOpacity = 0.12
            darkBorderLineWidth = 1
            darkDividerOpacity = 0.13
            darkControlBackgroundOpacity = 0.08
            darkControlForegroundOpacity = 0.5
            cardBorderOpacity = 0.22
            cardBorderLineWidth = 1
            secondaryControlOpacity = 0.7
            errorIconOpacity = 0.7
        }
    }
}
