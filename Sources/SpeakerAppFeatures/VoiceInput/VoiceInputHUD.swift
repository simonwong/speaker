@preconcurrency import AppKit
import SwiftUI

package struct VoiceInputHUD: View {
    let presentation: VoiceInputOverlayPresentation
    let performAction:
        (VoiceInputExperienceAction) -> VoiceInputExperienceEffect?
    let routeEffect: (VoiceInputExperienceEffect) -> Void
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    package init(
        presentation: VoiceInputOverlayPresentation,
        performAction:
            @escaping (VoiceInputExperienceAction) -> VoiceInputExperienceEffect?,
        routeEffect: @escaping (VoiceInputExperienceEffect) -> Void
    ) {
        self.presentation = presentation
        self.performAction = performAction
        self.routeEffect = routeEffect
    }

    private var palette: VoiceInputHUDContrastPalette {
        VoiceInputHUDContrastPalette(
            increased: colorSchemeContrast == .increased
        )
    }

    package var body: some View {
        Group {
            if let activity = ActivityPillModel(presentation) {
                ActivityPill(
                    model: activity,
                    palette: palette,
                    cancel: { _ = performAction(activity.cancelAction) }
                )
            } else {
                noticeBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noticeBody: some View {
        switch presentation {
        case let .pendingCopy(
            _,
            text,
            copyButtonTitle,
            copyAction,
            dismissAction
        ):
            PendingCopyStrip(
                text: text,
                copyButtonTitle: copyButtonTitle,
                palette: palette,
                copy: { _ = performAction(copyAction) },
                dismiss: { _ = performAction(dismissAction) }
            )
        case let .problem(icon, title, guidance, _, dismissAction):
            ProblemStrip(
                icon: icon,
                title: title,
                guidance: guidance,
                palette: palette,
                dismiss: { _ = performAction(dismissAction) }
            )
        case .hidden, .recording, .processing:
            Color.clear
        }
    }
}

/// One pill serves both live phases of a session — recording and processing —
/// so the surface keeps a single SwiftUI identity from press to result. The
/// panel footprint never changes between the two and only the waveform's
/// motion source crossfades, which is what makes the transition read as one
/// object changing state rather than two windows swapping.
private struct ActivityPillModel: Equatable {
    enum Phase: Equatable {
        case recording(peakPower: Float?)
        case processing
    }

    let phase: Phase
    let accessibilityTitle: String
    let cancelHint: String
    let cancelAction: VoiceInputExperienceAction

    init?(_ presentation: VoiceInputOverlayPresentation) {
        switch presentation {
        case let .recording(peakPower, cancelAction):
            phase = .recording(peakPower: peakPower)
            accessibilityTitle = "正在录音"
            cancelHint = "停止录音并忽略本次内容"
            self.cancelAction = cancelAction
        case let .processing(title, cancelAction):
            phase = .processing
            accessibilityTitle = title
            cancelHint = "停止当前处理并忽略迟到结果"
            self.cancelAction = cancelAction
        case .hidden, .pendingCopy, .problem:
            return nil
        }
    }

    var isProcessing: Bool {
        phase == .processing
    }
}

private struct ActivityPill: View {
    let model: ActivityPillModel
    let palette: VoiceInputHUDContrastPalette
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Double] = Array(
        repeating: 0,
        count: ActivityWaveform.barCount
    )
    @State private var isHovered = false

    var body: some View {
        ActivityHUDSurface(
            width: 118,
            height: 34,
            palette: palette
        ) {
            ZStack {
                ActivityWaveform(
                    phase: model.phase,
                    levels: levels,
                    reduceMotion: reduceMotion
                )
                .opacity(isHovered ? 0.3 : 1)
                .animation(
                    .easeInOut(duration: 0.35),
                    value: model.isProcessing
                )
                .accessibilityLabel(model.accessibilityTitle)

                HStack {
                    Spacer()
                    ActivityHUDCloseButton(
                        palette: palette,
                        help: "取消这次输入",
                        accessibilityHint: model.cancelHint,
                        action: cancel
                    )
                }
                .padding(.trailing, 4)
                .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(5)
        .accessibilityElement(children: .contain)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
        .onChange(of: liveStrength, initial: true) { _, strength in
            guard case .recording = model.phase else { return }
            var advanced = levels
            advanced.removeFirst()
            advanced.append(strength)
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.1)
            ) {
                levels = advanced
            }
        }
    }

    /// Microphone power mapped into 0…1 bar strength. The gamma keeps room
    /// noise near the floor so silence reads as a flat dotted line while
    /// normal speech still spans most of the pill height.
    private var liveStrength: Double {
        guard case let .recording(peakPower) = model.phase,
              let peakPower
        else { return 0 }
        let normalized = min(1, max(0, (Double(peakPower) + 52) / 44))
        return pow(normalized, 1.4)
    }
}

/// The pill's only content: a row of centre-anchored bars. While recording
/// the bars replay the recent microphone history (new samples enter on the
/// right); while processing they run a self-driven travelling wave in a
/// cooler tone, signalling "no longer listening, still working".
private struct ActivityWaveform: View {
    static let barCount = 15

    let phase: ActivityPillModel.Phase
    let levels: [Double]
    let reduceMotion: Bool

    var body: some View {
        if phase == .processing, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                bars(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(at: 0)
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        HStack(spacing: 3.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(barGradient)
                    .frame(
                        width: 2.5,
                        height: barHeight(index: index, time: time)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var barGradient: LinearGradient {
        switch phase {
        case .recording:
            LinearGradient(
                colors: [
                    SpeakerVisualIdentity.warmAccent.opacity(0.5),
                    SpeakerVisualIdentity.warmAccent.opacity(0.98),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        case .processing:
            LinearGradient(
                colors: [
                    Color.white.opacity(0.32),
                    Color.white.opacity(0.68),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> Double {
        switch phase {
        case .recording:
            return 3 + 17 * (levels.indices.contains(index) ? levels[index] : 0)
        case .processing:
            let position = Double(index) / Double(Self.barCount - 1)
            let envelope = 0.7 + 0.3 * sin(position * .pi)
            let swell = reduceMotion
                ? 0.35
                : 0.5 + 0.5 * sin(time * 3.4 - Double(index) * 0.55)
            return 3 + 13 * envelope * swell
        }
    }
}

private struct ActivityHUDSurface<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let palette: VoiceInputHUDContrastPalette
    let content: Content

    init(
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat? = nil,
        palette: VoiceInputHUDContrastPalette,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius ?? height / 2
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: width, height: height)
            .background {
                ZStack {
                    HUDVisualEffect()
                    LinearGradient(
                        colors: [
                            .black.opacity(0.34),
                            .black.opacity(0.48),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                ))
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(
                                palette.darkBorderOpacity + 0.03
                            ),
                            .white.opacity(
                                max(0.04, palette.darkBorderOpacity * 0.55)
                            ),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: palette.darkBorderLineWidth
                )
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }
}

private struct HUDVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// One-line retained-text strip. There is no headline on purpose: the
/// transcribed text sitting next to a copy button is self-explanatory, and
/// the strip never blocks the shortcut — a new press abandons the text and
/// starts over.
private struct PendingCopyStrip: View {
    let text: String
    let copyButtonTitle: String
    let palette: VoiceInputHUDContrastPalette
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ActivityHUDSurface(
            width: 384,
            height: 44,
            palette: palette
        ) {
            HStack(spacing: 9) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SpeakerVisualIdentity.warmAccent)
                    .accessibilityHidden(true)

                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HUDSecondaryButton(
                    title: "复制",
                    accessibilityLabel: copyButtonTitle,
                    accessibilityHint: "将保留的文字复制到剪贴板",
                    palette: palette,
                    action: copy
                )
                .keyboardShortcut(.defaultAction)

                ActivityHUDCloseButton(
                    palette: palette,
                    accessibilityLabel: "关闭待复制文字",
                    help: "关闭",
                    accessibilityHint: "不复制并关闭这个提示",
                    respondsToEscape: true,
                    action: dismiss
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 9)
        }
        .padding(5)
    }
}

/// One-line failure strip. Recovery guidance lives in the tooltip and the
/// menu bar item; the strip itself only names the failure, because the cause
/// varies (network, key, permission) and re-recording is always the primary
/// way out.
private struct ProblemStrip: View {
    let icon: String
    let title: String
    let guidance: String
    let palette: VoiceInputHUDContrastPalette
    let dismiss: () -> Void

    var body: some View {
        ActivityHUDSurface(
            width: 320,
            height: 44,
            palette: palette
        ) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        .red.opacity(max(0.82, palette.errorIconOpacity))
                    )
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title + "\n" + guidance)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ActivityHUDCloseButton(
                    palette: palette,
                    accessibilityLabel: "关闭错误提示",
                    help: "关闭",
                    accessibilityHint: "关闭当前错误，不会自动重试",
                    respondsToEscape: true,
                    action: dismiss
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 9)
        }
        .padding(5)
    }
}

private struct HUDSecondaryButton: View {
    let title: String
    let accessibilityLabel: String?
    let accessibilityHint: String
    let palette: VoiceInputHUDContrastPalette
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        accessibilityLabel: String? = nil,
        accessibilityHint: String,
        palette: VoiceInputHUDContrastPalette,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.palette = palette
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(foregroundOpacity))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(.white.opacity(backgroundOpacity), in: Capsule())
                .overlay {
                    Capsule().stroke(.white.opacity(borderOpacity))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        .overlay {
            HUDAccessibilityAction(
                label: accessibilityLabel ?? title,
                hint: accessibilityHint,
                action: action
            )
        }
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovered
            }
        }
    }

    private var foregroundOpacity: Double {
        max(isHovered ? 0.98 : 0.92, palette.darkControlForegroundOpacity)
    }

    private var backgroundOpacity: Double {
        max(isHovered ? 0.18 : 0.12, palette.darkControlBackgroundOpacity)
    }

    private var borderOpacity: Double {
        max(isHovered ? 0.16 : 0.1, palette.darkBorderOpacity)
    }
}

private struct ActivityHUDCloseButton: View {
    let palette: VoiceInputHUDContrastPalette
    var accessibilityLabel: String = "取消语音输入"
    let help: String
    let accessibilityHint: String
    var respondsToEscape: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        if respondsToEscape {
            button.keyboardShortcut(.cancelAction)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(
                    .white.opacity(
                        isHovered
                            ? max(
                                0.92,
                                palette.darkControlForegroundOpacity
                            )
                            : palette.darkControlForegroundOpacity
                    )
                )
                .frame(width: 24, height: 24)
                .background(
                    .white.opacity(
                        isHovered
                            ? palette.darkControlBackgroundOpacity
                            : 0
                    ),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityHidden(true)
        .overlay {
            HUDAccessibilityAction(
                label: accessibilityLabel,
                hint: accessibilityHint,
                action: action
            )
        }
    }
}

/// An invisible accessibility adapter over a visually identical SwiftUI
/// control. AppKit can discover and press this view even when SwiftUI lazily
/// omits its virtual accessibility children while VoiceOver is not running.
/// Mouse hit-testing deliberately falls through to the original SwiftUI
/// button, preserving hover, click and keyboard-shortcut behaviour.
private struct HUDAccessibilityAction: NSViewRepresentable {
    let label: String
    let hint: String
    let action: () -> Void

    func makeNSView(context: Context) -> HUDAccessibilityActionView {
        HUDAccessibilityActionView(
            label: label,
            hint: hint,
            action: action
        )
    }

    func updateNSView(
        _ view: HUDAccessibilityActionView,
        context: Context
    ) {
        view.update(label: label, hint: hint, action: action)
    }
}

@MainActor
private final class HUDAccessibilityActionView:
    NSView,
    @preconcurrency NSAccessibilityButton
{
    private var accessibilityAction: () -> Void

    init(label: String, hint: String, action: @escaping () -> Void) {
        accessibilityAction = action
        super.init(frame: .zero)
        update(label: label, hint: hint, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) {
        accessibilityAction = action
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(hint)
        setAccessibilityEnabled(true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        accessibilityAction()
        return true
    }
}
