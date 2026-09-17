@preconcurrency import AppKit
import SwiftUI

package struct VoiceInputHUD: View {
    let presentation: VoiceInputOverlayPresentation
    let performAction: (VoiceInputExperienceAction) -> VoiceInputExperienceEffect?
    let routeEffect: (VoiceInputExperienceEffect) -> Void
    @Environment(\.voiceInputPanelDismissal) private var activityDismissal
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.voiceInputHUDIncreasedContrastOverride)
    private var increasedContrastOverride

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
            increased: increasedContrastOverride
                ?? (colorSchemeContrast == .increased)
        )
    }

    package var body: some View {
        Group {
            if let activity = ActivityPillModel(presentation) {
                ActivityPill(
                    model: activity,
                    palette: palette,
                    dismissal: activityDismissal,
                    cancel: { _ = performAction(activity.cancelAction) },
                    finish: {
                        if let action = activity.finishAction {
                            _ = performAction(action)
                        }
                    }
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
        case .pendingCopy(
            _,
            let
                text,
            let
                copyButtonTitle,
            let
                copyAction,
            let
                dismissAction
        ):
            PendingCopyStrip(
                text: text,
                copyButtonTitle: copyButtonTitle,
                palette: palette,
                copy: { _ = performAction(copyAction) },
                dismiss: { _ = performAction(dismissAction) }
            )
        case .problem(let icon, let title, let guidance, _, let dismissAction):
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
    let layout: VoiceInputPanelLayout
    let accessibilityTitle: String
    let cancelHint: String
    let cancelAction: VoiceInputExperienceAction
    let finishAction: VoiceInputExperienceAction?

    init?(_ presentation: VoiceInputOverlayPresentation) {
        switch presentation {
        case .recording(let peakPower, let cancelAction, let finishAction):
            phase = .recording(peakPower: peakPower)
            layout = .recording
            accessibilityTitle = "正在录音"
            cancelHint = "停止录音并忽略本次内容"
            self.cancelAction = cancelAction
            self.finishAction = finishAction
        case .processing(let title, let cancelAction):
            phase = .processing
            layout = .processing
            accessibilityTitle = title
            cancelHint = "停止当前处理并忽略迟到结果"
            self.cancelAction = cancelAction
            finishAction = nil
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
    let dismissal: VoiceInputPanelDismissal?
    let cancel: () -> Void
    let finish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.voiceInputHUDHoverOverride) private var hoverOverride
    @State private var levels: [Double] = Array(
        repeating: 0,
        count: ActivityWaveform.barCount
    )
    @State private var isHovered = false
    @State private var isRevealed = false

    private var controlsVisible: Bool { hoverOverride ?? isHovered }

    var body: some View {
        ActivityHUDSurface(
            width: isRevealed ? contentSize.width : 10,
            height: contentSize.height,
            palette: palette
        ) {
            ZStack {
                ActivityWaveform(
                    phase: model.phase,
                    levels: levels,
                    reduceMotion: reduceMotion,
                    compact: controlsVisible
                )
                .frame(width: waveformWidth, height: contentSize.height)
                .mask {
                    Capsule()
                        .frame(
                            width: isRevealed ? waveformWidth : 2,
                            height: contentSize.height
                        )
                }
                .animation(
                    .easeInOut(duration: 0.35),
                    value: model.isProcessing
                )
                .accessibilityLabel(model.accessibilityTitle)

                HStack {
                    HUDIconButton(
                        symbol: "xmark",
                        palette: palette,
                        isVisible: controlsVisible,
                        accessibilityLabel: "取消语音输入",
                        help: "取消这次输入",
                        accessibilityHint: model.cancelHint,
                        action: cancel
                    )
                    Spacer()
                    if model.finishAction != nil {
                        HUDIconButton(
                            symbol: "checkmark",
                            palette: palette,
                            isVisible: controlsVisible,
                            prominent: true,
                            accessibilityLabel: "结束录音",
                            help: "结束录音并处理",
                            accessibilityHint: "保留本次录音并开始转成文字",
                            action: finish
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
        .padding(VoiceInputPanelLayout.contentInset)
        .accessibilityElement(children: .contain)
        .task {
            guard dismissal == nil else { return }
            guard !isRevealed else { return }
            guard !reduceMotion else {
                isRevealed = true
                return
            }
            await Task.yield()
            withAnimation(.smooth(duration: 0.42, extraBounce: 0.06)) {
                isRevealed = true
            }
        }
        .onChange(of: dismissal) { _, dismissal in
            let animation: Animation? =
                if reduceMotion {
                    nil
                } else if let dismissal {
                    .easeIn(duration: dismissal.fadeDuration)
                } else {
                    .smooth(duration: 0.3, extraBounce: 0.03)
                }
            withAnimation(animation) {
                isRevealed = dismissal == nil
            }
        }
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
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

    private var contentSize: CGSize {
        model.layout.contentSize
    }

    /// The waveform stops short of the pill edges so the cancel control has
    /// room without the bars ever touching the capsule.
    private var waveformWidth: CGFloat {
        contentSize.width - 22
    }

    /// Microphone power mapped into 0…1 bar strength. The gamma keeps room
    /// noise near the floor so silence reads as a flat dotted line while
    /// normal speech still spans most of the pill height.
    private var liveStrength: Double {
        guard case .recording(let peakPower) = model.phase,
            let peakPower
        else { return 0 }
        let normalized = min(1, max(0, (Double(peakPower) + 52) / 44))
        return pow(normalized, 1.4)
    }
}

/// A row of centre-anchored bars. While recording
/// the bars replay the recent microphone history (new samples enter on the
/// right); while processing they run a self-driven travelling wave in a
/// cooler tone, signalling "no longer listening, still working".
private struct ActivityWaveform: View {
    static let barCount = 15

    let phase: ActivityPillModel.Phase
    let levels: [Double]
    let reduceMotion: Bool
    let compact: Bool

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
        HStack(spacing: compact ? 1 : 3.5) {
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
                    Color.primary.opacity(0.32),
                    Color.primary.opacity(0.68),
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
            let swell =
                reduceMotion
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
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.adaptiveGlassSurfaceStyleOverride)
    private var surfaceStyleOverride
    @Environment(\.colorScheme) private var colorScheme

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
        surface
            .overlay {
                surfaceShape
                    .stroke(
                        LinearGradient(
                            colors: [
                                .primary.opacity(
                                    palette.darkBorderOpacity + 0.03
                                ),
                                .primary.opacity(
                                    max(0.04, palette.darkBorderOpacity * 0.55)
                                ),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: palette.darkBorderLineWidth
                    )
            }
            .environment(
                \.colorScheme,
                surfaceStyle == .opaque ? colorScheme : .dark
            )
    }

    @ViewBuilder
    private var surface: some View {
        switch surfaceStyle {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                ZStack {
                    systemMaterialBackdrop
                    framedContent.glassEffect(
                        .regular.tint(
                            .black.opacity(palette.glassTintOpacity)
                        ),
                        in: surfaceShape
                    )
                }
            } else {
                systemMaterialSurface
            }
        case .systemMaterial:
            systemMaterialSurface
        case .opaque:
            framedContent
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: surfaceShape
                )
        }
    }

    private var framedContent: some View {
        content
            .frame(width: width, height: height)
            .clipShape(surfaceShape)
    }

    private var systemMaterialSurface: some View {
        framedContent.background { systemMaterialBackdrop }
    }

    private var systemMaterialBackdrop: some View {
        ZStack {
            HUDVisualEffect(cornerRadius: cornerRadius)
            LinearGradient(
                colors: [
                    .black.opacity(palette.fallbackTintTopOpacity),
                    .black.opacity(palette.fallbackTintBottomOpacity),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: width, height: height)
        .clipShape(surfaceShape)
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
    }

    private var surfaceStyle: AdaptiveGlassSurfaceStyle {
        if let surfaceStyleOverride { return surfaceStyleOverride }
        return AdaptiveGlassSurfacePolicy.resolve(
            reduceTransparency: reduceTransparency
        )
    }
}

private struct HUDVisualEffect: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        applyShape(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        applyShape(to: view)
    }

    private func applyShape(to view: NSVisualEffectView) {
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

private struct PendingCopyStrip: View {
    let text: String
    let copyButtonTitle: String
    let palette: VoiceInputHUDContrastPalette
    let copy: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.voiceInputHUDHoverOverride) private var hoverOverride
    @State private var isHovered = false

    private var controlsVisible: Bool { hoverOverride ?? isHovered }

    private var contentSize: CGSize {
        VoiceInputPanelLayout.pendingCopy.contentSize
    }

    var body: some View {
        ActivityHUDSurface(
            width: contentSize.width,
            height: contentSize.height,
            palette: palette
        ) {
            ZStack {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, controlsVisible ? 38 : 16)
                    .padding(.trailing, 38)

                HStack {
                    HUDIconButton(
                        symbol: "xmark",
                        palette: palette,
                        isVisible: controlsVisible,
                        accessibilityLabel: "关闭待复制文字",
                        help: "关闭",
                        accessibilityHint: "不复制并关闭这个提示",
                        action: dismiss
                    )
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    HUDIconButton(
                        symbol: "doc.on.doc",
                        palette: palette,
                        accessibilityLabel: copyButtonTitle,
                        help: copyButtonTitle,
                        accessibilityHint: "将保留的文字复制到剪贴板",
                        action: copy
                    )
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 4)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
        .padding(VoiceInputPanelLayout.contentInset)
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                isHovered = hovered
            }
        }
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

    private var contentSize: CGSize {
        VoiceInputPanelLayout.problem.contentSize
    }

    var body: some View {
        ActivityHUDSurface(
            width: contentSize.width,
            height: contentSize.height,
            palette: palette
        ) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        .red.opacity(max(0.82, palette.errorIconOpacity))
                    )
                    .accessibilityHidden(true)

                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title + "\n" + guidance)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HUDIconButton(
                    symbol: "xmark",
                    palette: palette,
                    accessibilityLabel: "关闭错误提示",
                    help: "关闭",
                    accessibilityHint: "关闭当前错误，不会自动重试",
                    action: dismiss
                )
                .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 16)
            .padding(.trailing, 9)
        }
        .padding(VoiceInputPanelLayout.contentInset)
    }
}

private struct HUDIconButton: View {
    let symbol: String
    let palette: VoiceInputHUDContrastPalette
    var isVisible = true
    var prominent = false
    let accessibilityLabel: String
    let help: String
    let accessibilityHint: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    prominent
                        ? (colorScheme == .dark ? Color.black : Color.white)
                        : Color.primary.opacity(max(0.88, palette.darkControlForegroundOpacity))
                )
                .frame(width: 26, height: 26)
                .background(
                    Color.primary.opacity(
                        prominent
                            ? (isHovered ? 0.85 : 1)
                            : max(isHovered ? 0.24 : 0.14, palette.darkControlBackgroundOpacity)
                    ),
                    in: Circle()
                )
                .contentShape(Circle())
                .opacity(isVisible ? 1 : 0)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isVisible)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityHidden(true)
        .overlay {
            AccessibilityButtonBridge(
                label: accessibilityLabel,
                hint: accessibilityHint,
                action: action
            )
        }
    }
}

private struct VoiceInputHUDHoverOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    package var voiceInputHUDHoverOverride: Bool? {
        get { self[VoiceInputHUDHoverOverrideKey.self] }
        set { self[VoiceInputHUDHoverOverrideKey.self] = newValue }
    }
}
