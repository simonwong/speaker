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

/// The two-colour print that carries the mark: a gold rear stroke and a
/// translucent coral front stroke, offset along one diagonal. The menu bar
/// glyph repeats the same offset in a single template colour.
private enum SpeakerPrintedMark {
    /// Unit direction from the rear layer to the front layer: down and to the
    /// right, 50 degrees from vertical.
    static let direction = CGVector(
        dx: sin(50 * CGFloat.pi / 180),
        dy: cos(50 * CGFloat.pi / 180)
    )
    static let frontOpacity = 0.78
    /// The gold layer is drawn wider than the coral one, so it shows along
    /// the coral's edges while the two layers still mostly overlap.
    static let rearWidthScale: CGFloat = 1.35
    static let rearGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.953, green: 0.847, blue: 0.682), location: 0),
            .init(color: Color(red: 1.000, green: 0.910, blue: 0.773), location: 0.32),
            .init(color: Color(red: 0.949, green: 0.804, blue: 0.588), location: 0.62),
            .init(color: Color(red: 0.910, green: 0.710, blue: 0.435), location: 1),
        ],
        startPoint: UnitPoint(x: 0.018, y: 0.5),
        endPoint: UnitPoint(x: 0.982, y: 0.5)
    )

    static func stroke(lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }
}

/// Mark geometry for one tile size. Small tiles use a larger frame, a thicker
/// stroke, and a wider layer offset so both layers stay visible.
private struct SpeakerPrintedMarkMetrics {
    let markSize: CGSize
    let lineWidth: CGFloat
    /// Half the offset between the layers; the rear moves by its negation.
    let halfOffset: CGSize
    /// Blur applied to the gold seen through the coral front layer.
    let frostRadius: CGFloat

    init(tileSize size: CGFloat) {
        let frame: (width: CGFloat, height: CGFloat)
        let lineFraction: CGFloat
        let offsetFraction: CGFloat
        if size <= 16 {
            frame = (0.68, 0.42)
            lineFraction = 0.13
            offsetFraction = 0.07
        } else if size <= 32 {
            frame = (0.714, 0.44)
            lineFraction = 0.10
            offsetFraction = 0.055
        } else {
            frame = (0.68, 0.41)
            lineFraction = 0.08
            offsetFraction = 0.045
        }
        let offset = size * offsetFraction
        markSize = CGSize(width: size * frame.width, height: size * frame.height)
        lineWidth = size * lineFraction
        halfOffset = CGSize(
            width: SpeakerPrintedMark.direction.dx * offset / 2,
            height: SpeakerPrintedMark.direction.dy * offset / 2
        )
        frostRadius = size * 0.008
    }
}

/// The light identity tile used only when a surface is naming Speaker itself.
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
            surface
            printedMark
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
                Color.black.opacity(size <= 32 ? 0.1 : 0.07),
                lineWidth: max(0.6, size * 0.0045)
            )
        }
        .accessibilityHidden(true)
        .overlay {
            accessibilityOverlay
        }
    }

    private var surface: some View {
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
                colors: [Color.white.opacity(0.7), .clear],
                center: UnitPoint(x: 0.28, y: 0.22),
                startRadius: 0,
                endRadius: size * 0.55
            )
        }
    }

    /// The coral front layer multiplies over whatever is behind it. Inside
    /// its outline, the sharp gold is replaced by the surface and a blurred
    /// copy of the gold, so the overlap reads as frosted glass.
    private var printedMark: some View {
        let metrics = SpeakerPrintedMarkMetrics(tileSize: size)
        let half = metrics.halfOffset
        return ZStack {
            rearStroke(metrics)
                .offset(x: -half.width, y: -half.height)

            ZStack {
                surface
                rearStroke(metrics)
                    .offset(x: -half.width, y: -half.height)
                    .blur(radius: metrics.frostRadius)
            }
            .mask {
                markStroke(metrics, Color.white)
                    .offset(x: half.width, y: half.height)
            }

            markStroke(metrics, SpeakerVisualIdentity.warmCoral)
                .offset(x: half.width, y: half.height)
                .opacity(SpeakerPrintedMark.frontOpacity)
                .blendMode(.multiply)
        }
        .compositingGroup()
    }

    private func rearStroke(_ metrics: SpeakerPrintedMarkMetrics) -> some View {
        markStroke(
            metrics,
            SpeakerPrintedMark.rearGradient,
            lineWidth: metrics.lineWidth * SpeakerPrintedMark.rearWidthScale
        )
    }

    private func markStroke(
        _ metrics: SpeakerPrintedMarkMetrics,
        _ paint: some ShapeStyle,
        lineWidth: CGFloat? = nil
    ) -> some View {
        SpeakerBrandMarkShape()
            .stroke(
                paint,
                style: SpeakerPrintedMark.stroke(lineWidth: lineWidth ?? metrics.lineWidth)
            )
            .frame(width: metrics.markSize.width, height: metrics.markSize.height)
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

    /// The rear layer sits up and to the left of the front one, on the app
    /// icon's diagonal. Recording raises the rear layer's opacity.
    private static let halfOffset = CGSize(
        width: SpeakerPrintedMark.direction.dx * 0.675,
        height: SpeakerPrintedMark.direction.dy * 0.675
    )

    var body: some View {
        let half = Self.halfOffset
        ZStack {
            stroke
                .opacity(state == .recording ? 0.8 : 0.4)
                .offset(x: -half.width, y: -half.height)
            stroke
                .offset(x: half.width, y: half.height)
        }
        .frame(width: 20, height: 18)
        .overlay(alignment: .topTrailing) {
            stateBadge
                .padding(.top, 0.4)
                .padding(.trailing, 0.8)
        }
    }

    private var stroke: some View {
        SpeakerBrandMarkShape()
            .stroke(Color.black, style: SpeakerPrintedMark.stroke(lineWidth: 2))
            .frame(width: 15.2, height: 10.6)
            .offset(y: 1.2)
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
        let image =
            NSImage(
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
