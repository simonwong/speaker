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
            switch presentation {
            case let .recording(peakPower, cancelAction):
                RecordingWaveformOverlay(
                    peakPower: peakPower,
                    palette: palette,
                    cancel: { _ = performAction(cancelAction) }
                )
            case let .pendingCopy(
                title,
                text,
                copyButtonTitle,
                copyAction,
                dismissAction
            ):
                PendingResultOverlay(
                    title: title,
                    text: text,
                    copyButtonTitle: copyButtonTitle,
                    palette: palette,
                    copy: { _ = performAction(copyAction) },
                    dismiss: { _ = performAction(dismissAction) }
                )
            case let .problem(
                icon,
                title,
                guidance,
                recoveryAction,
                dismissAction
            ):
                FailureResultOverlay(
                    icon: icon,
                    title: title,
                    guidance: guidance,
                    palette: palette,
                    recover: recoveryAction.map { action in
                        {
                            guard let effect = performAction(action) else {
                                return
                            }
                            routeEffect(effect)
                        }
                    },
                    dismiss: { _ = performAction(dismissAction) }
                )
            case let .processing(title, cancelAction):
                ProcessingIndicatorOverlay(
                    accessibilityTitle: title,
                    palette: palette,
                    cancel: { _ = performAction(cancelAction) }
                )
            case .hidden:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProcessingIndicatorOverlay: View {
    let accessibilityTitle: String
    let palette: VoiceInputHUDContrastPalette
    let cancel: () -> Void

    var body: some View {
        ActivityHUDSurface(
            width: 64,
            height: 32,
            palette: palette
        ) {
            HStack(spacing: 6) {
                ProcessingOrbitGlyph()
                    .frame(width: 24, height: 32)
                    .accessibilityLabel(accessibilityTitle)

                ActivityHUDCloseButton(
                    palette: palette,
                    help: "取消这次输入",
                    accessibilityHint: "停止当前处理并忽略迟到结果",
                    action: cancel
                )
            }
            .padding(.horizontal, 5)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProcessingOrbitGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            glyph(rotation: -35)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                glyph(
                    rotation:
                        timeline.date.timeIntervalSinceReferenceDate * 210
                )
            }
        }
    }

    private func glyph(rotation: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.13), lineWidth: 1.6)

            Circle()
                .trim(from: 0.06, to: 0.72)
                .stroke(
                    AngularGradient(
                        colors: [
                            .white.opacity(0.1),
                            .white.opacity(0.94),
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(
                        lineWidth: 1.8,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

private struct ActivityHUDSurface<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let palette: VoiceInputHUDContrastPalette
    let content: Content

    init(
        width: CGFloat,
        height: CGFloat,
        palette: VoiceInputHUDContrastPalette,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.height = height
        self.palette = palette
        self.content = content()
    }

    private var cornerRadius: CGFloat {
        height / 2
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
            .shadow(color: .black.opacity(0.26), radius: 12, y: 4)
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

private struct PendingResultOverlay: View {
    let title: String
    let text: String
    let copyButtonTitle: String
    let palette: VoiceInputHUDContrastPalette
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HUDSecondaryButton(
                title: copyButtonTitle,
                accessibilityHint: "将保留的文字复制到剪贴板",
                action: copy
            )
                .keyboardShortcut(.defaultAction)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        Color.secondary.opacity(palette.secondaryControlOpacity)
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .keyboardShortcut(.cancelAction)
            .accessibilityHidden(true)
            .overlay {
                HUDAccessibilityAction(
                    label: "关闭待复制文字",
                    hint: "不复制并关闭这个提示",
                    action: dismiss
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    .separator.opacity(palette.cardBorderOpacity),
                    lineWidth: palette.cardBorderLineWidth
                )
        }
        .shadow(color: .black.opacity(0.045), radius: 7, y: 2)
        .padding(5)
    }
}

private struct FailureResultOverlay: View {
    let icon: String
    let title: String
    let guidance: String
    let palette: VoiceInputHUDContrastPalette
    let recover: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red.opacity(palette.errorIconOpacity))
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(guidance)
            }

            Spacer(minLength: 8)

            if let recover {
                HUDSecondaryButton(
                    title: "设置",
                    accessibilityLabel: "打开语音识别设置",
                    accessibilityHint: "检查系统权限或语音识别服务配置",
                    action: recover
                )
                .keyboardShortcut(.defaultAction)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        Color.secondary.opacity(palette.secondaryControlOpacity)
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .keyboardShortcut(.cancelAction)
            .accessibilityHidden(true)
            .overlay {
                HUDAccessibilityAction(
                    label: "关闭错误提示",
                    hint: "关闭当前错误，不会自动重试",
                    action: dismiss
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    .separator.opacity(palette.cardBorderOpacity),
                    lineWidth: palette.cardBorderLineWidth
                )
        }
        .shadow(color: .black.opacity(0.045), radius: 7, y: 2)
        .padding(5)
    }
}

private struct HUDSecondaryButton: View {
    let title: String
    let accessibilityLabel: String?
    let accessibilityHint: String
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        accessibilityLabel: String? = nil,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.86))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    .primary.opacity(isHovered ? 0.14 : 0.09),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(.primary.opacity(isHovered ? 0.14 : 0.08))
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
}

private struct RecordingWaveformOverlay: View {
    let peakPower: Float?
    let palette: VoiceInputHUDContrastPalette
    let cancel: () -> Void

    private let barCount = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedStrength = 0.08

    var body: some View {
        ActivityHUDSurface(
            width: 96,
            height: 32,
            palette: palette
        ) {
            HStack(spacing: 4) {
                waveform

                ActivityHUDCloseButton(
                    palette: palette,
                    help: "取消这次输入",
                    accessibilityHint: "停止录音并忽略本次内容",
                    action: cancel
                )
            }
            .padding(.horizontal, 4)
        }
        .padding(5)
        .accessibilityElement(children: .contain)
        .onChange(of: inputStrength, initial: true) { _, strength in
            let duration = strength > displayedStrength ? 0.06 : 0.18
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: duration)
            ) {
                displayedStrength = strength
            }
        }
    }

    private var waveform: some View {
        HStack(spacing: 6) {
            RecordingPulseDot(reduceMotion: reduceMotion)
            .frame(width: 7, height: 30)
            .accessibilityHidden(true)

            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.46),
                                    Color.white.opacity(0.94),
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(
                            width: 2.6,
                            height: barHeight(index: index)
                        )
                }
            }
            .frame(width: 26, height: 21)
            .accessibilityHidden(true)
        }
        .frame(width: 60, height: 32)
        .accessibilityLabel("正在录音")
    }

    private var inputStrength: Double {
        guard let peakPower else { return 0.28 }
        return min(1, max(0.08, Double(peakPower + 55) / 55))
    }

    private func barHeight(index: Int) -> Double {
        let position = Double(index) / Double(max(1, barCount - 1))
        let envelope = 0.48 + sin(position * .pi) * 0.52
        return 3.5 + 17.5 * envelope * displayedStrength
    }
}

private struct RecordingPulseDot: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dot(pulse: 0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                dot(
                    pulse: (
                        sin(
                            timeline.date.timeIntervalSinceReferenceDate * 4.2
                        ) + 1
                    ) / 2
                )
            }
        }
    }

    private func dot(pulse: Double) -> some View {
        Circle()
            .fill(.red)
            .frame(width: 5.5, height: 5.5)
            .scaleEffect(0.92 + pulse * 0.12)
            .opacity(0.78 + pulse * 0.22)
            .shadow(color: .red.opacity(0.24), radius: 3)
    }
}

private struct ActivityHUDCloseButton: View {
    let palette: VoiceInputHUDContrastPalette
    let help: String
    let accessibilityHint: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
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
                label: "取消语音输入",
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
