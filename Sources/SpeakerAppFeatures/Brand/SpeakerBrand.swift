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
        path.move(to: point(0.08, 0.68))
        path.addCurve(
            to: point(0.30, 0.22),
            control1: point(0.18, 0.68),
            control2: point(0.20, 0.22)
        )
        path.addCurve(
            to: point(0.60, 0.60),
            control1: point(0.42, 0.22),
            control2: point(0.45, 0.60)
        )
        path.addLine(to: point(0.92, 0.60))
        return path
    }
}

private struct SpeakerLayeredBrandStrokeShape: Shape {
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let centreLine = SpeakerBrandMarkShape().path(in: rect)
        let rear = centreLine.strokedPath(
            StrokeStyle(
                lineWidth: lineWidth * 0.92,
                lineCap: .round,
                lineJoin: .round
            )
        )
        let front = centreLine.strokedPath(
            StrokeStyle(
                lineWidth: lineWidth * 0.83,
                lineCap: .round,
                lineJoin: .round
            )
        )
        var path = Path()
        path.addPath(
            rear,
            transform: CGAffineTransform(
                translationX: 0,
                y: rect.height * 0.022
            )
        )
        path.addPath(front)
        return path
    }
}

package struct SpeakerBrandMark: View {
    package init() {}

    package var body: some View {
        GeometryReader { proxy in
            let lineWidth = max(1, proxy.size.height * 0.29 * 1.14)
            SpeakerLayeredBrandStrokeShape(lineWidth: lineWidth)
                .fill()
        }
        .accessibilityHidden(true)
    }
}

private struct SpeakerFacetedBrandMark: View {
    var body: some View {
        GeometryReader { proxy in
            let lineWidth = proxy.size.height * 0.18 * 1.14 * 1.14
            let gradient = LinearGradient(
                stops: [
                    .init(color: Color(red: 0.953, green: 0.847, blue: 0.682), location: 0),
                    .init(color: Color(red: 1.000, green: 0.910, blue: 0.773), location: 0.32),
                    .init(color: Color(red: 0.949, green: 0.804, blue: 0.588), location: 0.62),
                    .init(color: Color(red: 0.910, green: 0.710, blue: 0.435), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            ZStack {
                SpeakerLayeredBrandStrokeShape(lineWidth: lineWidth)
                    .fill(gradient)

                ZStack {
                    NormalizedPolygon(points: [
                        CGPoint(x: 0.05, y: 0.88),
                        CGPoint(x: 0.28, y: 0.08),
                        CGPoint(x: 0.43, y: 0.18),
                        CGPoint(x: 0.52, y: 0.60),
                        CGPoint(x: 0.38, y: 0.56),
                        CGPoint(x: 0.22, y: 0.92),
                    ])
                    .fill(.white.opacity(0.18))

                    NormalizedPolygon(points: [
                        CGPoint(x: 0.43, y: 0.18),
                        CGPoint(x: 0.55, y: 0.43),
                        CGPoint(x: 0.61, y: 0.66),
                        CGPoint(x: 0.52, y: 0.60),
                    ])
                    .fill(Color(red: 0.651, green: 0.420, blue: 0.239).opacity(0.125))

                    NormalizedPolygon(points: [
                        CGPoint(x: 0.36, y: 0.20),
                        CGPoint(x: 0.43, y: 0.18),
                        CGPoint(x: 0.52, y: 0.60),
                        CGPoint(x: 0.46, y: 0.54),
                    ])
                    .fill(Color(red: 1.000, green: 0.945, blue: 0.827).opacity(0.04))
                }
                .mask {
                    SpeakerLayeredBrandStrokeShape(lineWidth: lineWidth)
                        .fill(.white)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct NormalizedPolygon: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(
            x: rect.minX + first.x * rect.width,
            y: rect.minY + first.y * rect.height
        ))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(
                x: rect.minX + point.x * rect.width,
                y: rect.minY + point.y * rect.height
            ))
        }
        path.closeSubpath()
        return path
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
        ZStack {
            LinearGradient(
                colors: [
                    SpeakerVisualIdentity.iconSurfaceTop,
                    SpeakerVisualIdentity.iconSurfaceBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(size <= 32 ? 0.05 : 0.09),
                    .clear,
                ],
                center: UnitPoint(x: 0.28, y: 0.22),
                startRadius: 0,
                endRadius: size * 0.48
            )

            mark
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: size * 0.215,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: size * 0.207,
                style: .continuous
            )
            .inset(by: max(0.5, size * 0.008))
            .stroke(
                Color.white.opacity(size <= 32 ? 0.064 : 0.128),
                lineWidth: max(0.6, size * 0.0045)
            )
        }
        .accessibilityHidden(true)
        .overlay {
            accessibilityOverlay
        }
    }

    @ViewBuilder
    private var mark: some View {
        let layout = markLayout
        if size * layout.width > 24 {
            SpeakerFacetedBrandMark()
                .frame(
                    width: size * layout.width,
                    height: size * layout.height
                )
        } else {
            SpeakerBrandMark()
                .foregroundStyle(SpeakerVisualIdentity.warmAccent)
                .frame(
                    width: size * layout.width,
                    height: size * layout.height
                )
        }
    }

    private var markLayout: (width: CGFloat, height: CGFloat) {
        if size <= 16 {
            (0.68, 0.42)
        } else if size <= 32 {
            (0.714, 0.44)
        } else {
            (0.68, 0.41)
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

private struct SpeakerMenuBarGlyph: View {
    let state: MenuBarIconState

    var body: some View {
        ZStack {
            SpeakerBrandMarkShape()
                .stroke(
                    Color.black,
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: 15.2, height: 10.6)
                .offset(y: 1.2)
        }
        .frame(width: 20, height: 18)
        .overlay(alignment: .topTrailing) {
            stateBadge
                .padding(.top, 0.4)
                .padding(.trailing, 0.8)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .ready:
            EmptyView()
        case .recording:
            Circle()
                .fill(Color.black)
                .frame(width: 3.5, height: 3.5)
        case .needsPermission:
            VStack(spacing: 0.5) {
                Capsule()
                    .fill(Color.black)
                    .frame(width: 1.4, height: 3)
                Circle()
                    .fill(Color.black)
                    .frame(width: 1.4, height: 1.4)
            }
            .frame(width: 4, height: 5)
        }
    }
}

package enum SpeakerMenuBarIconArtwork {
    @MainActor private static let readyImage = render(.ready)
    @MainActor private static let recordingImage = render(.recording)
    @MainActor private static let needsPermissionImage = render(.needsPermission)

    @MainActor
    package static func image(for state: MenuBarIconState) -> NSImage {
        switch state {
        case .ready:
            readyImage
        case .recording:
            recordingImage
        case .needsPermission:
            needsPermissionImage
        }
    }

    @MainActor
    package static var fallbackImage: NSImage {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .medium
        )
        let image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 20, height: 18))
        image.size = NSSize(width: 20, height: 18)
        image.isTemplate = true
        return image
    }

    @MainActor
    private static func render(_ state: MenuBarIconState) -> NSImage {
        let renderer = ImageRenderer(content: SpeakerMenuBarGlyph(state: state))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return fallbackImage }
        image.size = NSSize(width: 20, height: 18)
        image.isTemplate = true
        return image
    }
}

package struct SpeakerMenuBarLabel: View {
    package let state: MenuBarIconState

    package init(state: MenuBarIconState) {
        self.state = state
    }

    package var body: some View {
        Image(nsImage: SpeakerMenuBarIconArtwork.image(for: state))
            .renderingMode(.template)
            .frame(width: 20, height: 18)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
            .overlay {
                SpeakerAccessibilityImageLabel(label: accessibilityLabel)
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
