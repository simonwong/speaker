import AppKit
import SwiftUI

/// The one normalized centre-line geometry used by every Speaker identity
/// surface. Stroke width and colour belong to the surface displaying it.
package struct SpeakerBrandMarkShape: Shape {
    package init() {}

    package func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x,
                y: rect.minY + rect.height * y
            )
        }

        var path = Path()
        path.move(to: point(0.61, 0.24))
        path.addLine(to: point(0.82, 0.24))

        path.move(to: point(0.10, 0.49))
        path.addCurve(
            to: point(0.28, 0.37),
            control1: point(0.16, 0.49),
            control2: point(0.21, 0.37)
        )
        path.addCurve(
            to: point(0.46, 0.49),
            control1: point(0.35, 0.37),
            control2: point(0.38, 0.49)
        )
        path.addLine(to: point(0.92, 0.49))

        path.move(to: point(0.45, 0.63))
        path.addLine(to: point(0.82, 0.63))
        return path
    }
}

package struct SpeakerBrandMark: View {
    package init() {}

    package var body: some View {
        GeometryReader { proxy in
            SpeakerBrandMarkShape()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: max(
                            1,
                            min(proxy.size.width, proxy.size.height) * 0.055
                        ),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .accessibilityHidden(true)
    }
}

/// The dark identity tile used only when a surface is naming Speaker itself.
package enum SpeakerIdentityAccessibility: Sendable {
    case named
    case hidden
}

package struct SpeakerIdentityTile: View {
    package let size: CGFloat
    package let accessibility: SpeakerIdentityAccessibility

    package init(
        size: CGFloat,
        accessibility: SpeakerIdentityAccessibility = .hidden
    ) {
        self.size = size
        self.accessibility = accessibility
    }

    package var body: some View {
        SpeakerBrandMark()
            .foregroundStyle(SpeakerVisualIdentity.warmAccent)
            .padding(size * 0.08)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [
                        SpeakerVisualIdentity.iconSurfaceTop,
                        SpeakerVisualIdentity.iconSurfaceBottom,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(
                    cornerRadius: size * 0.20,
                    style: .continuous
                )
            )
            .accessibilityHidden(true)
            .overlay {
                accessibilityOverlay
            }
    }

    @ViewBuilder
    private var accessibilityOverlay: some View {
        switch accessibility {
        case .named:
            SpeakerAccessibilityImageLabel(label: "Speaker")
        case .hidden:
            EmptyView()
        }
    }
}

package struct SpeakerAppIconArtwork: View {
    package let size: CGFloat

    package init(size: CGFloat) {
        self.size = size
    }

    package var body: some View {
        SpeakerIdentityTile(size: size, accessibility: .hidden)
    }
}

package struct SpeakerMenuBarLabel: View {
    package let state: MenuBarIconState

    package init(state: MenuBarIconState) {
        self.state = state
    }

    package var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SpeakerBrandMark()
                .padding(.horizontal, 1)
                .padding(.vertical, 2)

            stateBadge
                .padding(.trailing, 1)
                .padding(.bottom, 1)
        }
        .frame(width: 20, height: 18)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
        .overlay {
            SpeakerAccessibilityImageLabel(label: accessibilityLabel)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .ready:
            EmptyView()
        case .recording:
            Circle()
                .fill(.primary)
                .frame(width: 4.5, height: 4.5)
                .overlay(Circle().stroke(.background, lineWidth: 1))
        case .needsPermission:
            Text("!")
                .font(.system(size: 6, weight: .heavy, design: .rounded))
                .foregroundStyle(.background)
                .frame(width: 8, height: 8)
                .background(.primary, in: Circle())
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .ready:
            "Speaker"
        case .recording:
            "Speaker，正在录音"
        case .needsPermission:
            "Speaker，需要完成权限设置"
        }
    }
}

/// A deterministic AppKit accessibility node for a decorative SwiftUI image.
/// SwiftUI may omit virtual image nodes while VoiceOver is not running, so the
/// visual stays hidden from AX and this transparent adapter owns the label.
private struct SpeakerAccessibilityImageLabel: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> SpeakerAccessibilityImageLabelView {
        SpeakerAccessibilityImageLabelView(label: label)
    }

    func updateNSView(
        _ view: SpeakerAccessibilityImageLabelView,
        context: Context
    ) {
        view.update(label: label)
    }
}

@MainActor
private final class SpeakerAccessibilityImageLabelView: NSView {
    init(label: String) {
        super.init(frame: .zero)
        update(label: label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
        setAccessibilityEnabled(true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
