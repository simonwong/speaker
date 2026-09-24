import SwiftUI

/// Settings and onboarding buttons: native glass buttons on macOS 26, bordered
/// buttons before it and under Reduce Transparency.
package struct SettingsButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    @Environment(\.adaptiveGlassSurfaceStyle) private var surfaceStyle

    @ViewBuilder
    package func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            if prominent {
                Button(configuration).buttonStyle(.glassProminent)
            } else {
                Button(configuration).buttonStyle(.glass)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .speakerField(focused: focused)
    }
}
