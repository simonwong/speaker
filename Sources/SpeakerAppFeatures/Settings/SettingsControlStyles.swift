import SwiftUI

/// Settings and onboarding buttons: native glass buttons on macOS 26, bordered
/// buttons before it and under Reduce Transparency.
///
/// A regular-size button grows to the large capsule: at regular size the
/// glass is a small rounded rectangle that all but vanishes on the glass
/// card, and the large capsule matches the fields and menus beside it. A
/// caller that asks for a smaller size keeps it.
package struct SettingsButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle
    @Environment(\.controlSize) private var controlSize

    package func makeBody(configuration: Configuration) -> some View {
        styled(configuration)
            .buttonBorderShape(.capsule)
            .controlSize(controlSize == .regular ? .large : controlSize)
    }

    @ViewBuilder
    private func styled(_ configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            if prominent {
                Button(configuration).buttonStyle(.glassProminent)
            } else {
                // Glass over the glass card can sample nearly the card's own
                // colour and vanish; a faint capsule underneath keeps its edge.
                Button(configuration).buttonStyle(.glass)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        } else if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

package struct SettingsTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    package func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 12)
            .frame(minHeight: SpeakerSurfaceMetrics.fieldHeight)
            .speakerField(focused: focused)
    }
}
