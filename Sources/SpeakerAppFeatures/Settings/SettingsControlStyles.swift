import SwiftUI

package struct SettingsButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.adaptiveGlassSurfaceStyleOverride) private var surfaceOverride

    @ViewBuilder
    package func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), usesGlass {
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

    private var usesGlass: Bool {
        (surfaceOverride
            ?? AdaptiveGlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency))
            == .liquidGlass
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
            .settingsGlassSurface(focused: focused)
    }
}

private struct SettingsGlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool
    var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.adaptiveGlassSurfaceStyleOverride) private var surfaceOverride
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var surfaceStyle: AdaptiveGlassSurfaceStyle {
        surfaceOverride
            ?? AdaptiveGlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency)
    }

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                if focused || contrast == .increased {
                    shape.strokeBorder(
                        focused ? Color.accentColor : Color.primary.opacity(0.55),
                        lineWidth: focused ? 2 : 1
                    )
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if #available(macOS 26.0, *), surfaceStyle == .liquidGlass {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else if surfaceStyle == .opaque {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder((tint ?? .primary).opacity(0.2), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder((tint ?? .primary).opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

extension View {
    nonisolated package func settingsGlassSurface(
        cornerRadius: CGFloat = SpeakerSurfaceMetrics.controlCornerRadius,
        tint: Color? = nil,
        interactive: Bool = false,
        focused: Bool = false
    ) -> some View {
        modifier(
            SettingsGlassSurface(
                cornerRadius: cornerRadius, tint: tint, interactive: interactive, focused: focused))
    }
}
