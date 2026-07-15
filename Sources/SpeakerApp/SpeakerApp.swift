import AppKit
import Combine
import SpeakerCore
import SwiftUI

@main
struct SpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var runtime: SpeakerRuntime

    init() {
        _runtime = StateObject(wrappedValue: SpeakerRuntime())
    }

    var body: some Scene {
        MenuBarExtra("Speaker", systemImage: menuBarIcon) {
            MenuBarContent(
                permissions: runtime.permissions,
                sessions: runtime.sessions,
                startRuntime: runtime.start
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(runtime: runtime)
        }

        Window("会话历史", id: "history") {
            HistoryEmptyView()
        }
        .defaultSize(width: 720, height: 480)
    }

    private var menuBarIcon: String {
        if runtime.sessions.presentation.activity.isRecording {
            return "waveform.circle.fill"
        }
        return runtime.permissions.snapshot.allGranted
            ? "waveform"
            : "waveform.badge.exclamationmark"
    }
}

@MainActor
private final class SpeakerRuntime: ObservableObject {
    let permissions: PermissionModel
    let sessions: VoiceInputSessionModel
    let history: MemorySessionHistory

    @Published private(set) var shortcutChoice: ShortcutChoice
    @Published private(set) var shortcutNotice: String?

    private let fnMonitor: FnEventMonitor
    private let customHotKeyMonitor: CustomHotKeyMonitor
    private let panel: VoiceInputPanelController
    private var started = false

    init() {
        permissions = PermissionModel(access: SystemPermissionAccess())
        let audio = AVAudioCapture()
        let targets = AccessibilityInputTargets()
        let history = MemorySessionHistory()
        let sessionActor = VoiceInputSessions(
            audioCapture: audio,
            targetCapture: targets,
            transcriber: LocalPreviewTranscriber(),
            delivery: targets,
            clipboard: SystemClipboardWriter(),
            history: history
        )
        let sessions = VoiceInputSessionModel(sessions: sessionActor)
        self.sessions = sessions
        self.history = history
        let triggerHandler: @Sendable (GlobalVoiceTrigger) -> Void = { trigger in
            let command: VoiceInputCommand?
            switch trigger {
            case .pressed:
                command = .pressed
            case .released:
                command = .released
            case .cancel:
                command = .cancel
            case .monitorRecovered:
                command = nil
            }
            if let command {
                Task {
                    await sessionActor.send(command)
                }
            }
        }
        fnMonitor = FnEventMonitor(handler: triggerHandler)
        customHotKeyMonitor = CustomHotKeyMonitor(handler: triggerHandler)
        panel = VoiceInputPanelController(model: sessions)
        shortcutChoice = ShortcutChoice(
            rawValue: UserDefaults.standard.string(forKey: "voiceShortcut") ?? ""
        ) ?? .fn
    }

    func start() {
        guard !started else { return }
        started = true
        permissions.refresh()
        sessions.startObserving()
        activateShortcut(shortcutChoice, persist: false)
        panel.start()
    }

    func selectShortcut(_ choice: ShortcutChoice) {
        guard choice != shortcutChoice else { return }
        activateShortcut(choice, persist: true)
    }

    private func activateShortcut(_ choice: ShortcutChoice, persist: Bool) {
        switch choice {
        case .fn:
            customHotKeyMonitor.unregister()
            guard fnMonitor.start() else {
                shortcutNotice = "Fn 监听未能启动，请先授予辅助功能权限后重试。"
                return
            }
        case .optionSpace:
            fnMonitor.stop()
            guard customHotKeyMonitor.register(.optionSpace) else {
                shortcutNotice = "⌥ Space 已被其他应用占用，已继续使用 Fn。"
                _ = fnMonitor.start()
                shortcutChoice = .fn
                return
            }
        }

        shortcutChoice = choice
        shortcutNotice = nil
        if persist {
            UserDefaults.standard.set(choice.rawValue, forKey: "voiceShortcut")
        }
    }
}

private enum ShortcutChoice: String, CaseIterable, Identifiable {
    case fn
    case optionSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: "Fn"
        case .optionSpace: "⌥ Space"
        }
    }
}

private final class SpeakerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var permissions: PermissionModel
    @ObservedObject var sessions: VoiceInputSessionModel
    let startRuntime: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Label("默认顺滑", systemImage: "text.alignleft")

            Label(sessionSummary, systemImage: sessionIcon)

            if sessions.presentation.activity.isActive {
                Button("取消当前输入") {
                    sessions.send(.cancel)
                }
            }

            if case .pendingCopy = sessions.presentation.activity {
                Button("复制待处理结果") {
                    sessions.send(.copyPendingResult)
                }
            }

            Divider()

            Label(permissionSummary, systemImage: permissionIcon)

            Button("会话历史") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("设置…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Divider()

            Button("退出 Speaker") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            startRuntime()
            permissions.refresh()
        }
    }

    private var permissionSummary: String {
        permissions.snapshot.allGranted ? "权限已就绪" : "需要完成权限设置"
    }

    private var permissionIcon: String {
        permissions.snapshot.allGranted ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var sessionSummary: String {
        sessions.presentation.activity.summary
    }

    private var sessionIcon: String {
        sessions.presentation.activity.icon
    }
}

private struct SettingsView: View {
    @ObservedObject var runtime: SpeakerRuntime

    private var permissions: PermissionModel { runtime.permissions }

    var body: some View {
        Form {
            Section("系统权限") {
                PermissionRow(
                    title: "辅助功能",
                    explanation: "用于监听全局快捷键、捕获输入目标并安全送达文本。",
                    kind: .accessibility,
                    state: permissions.snapshot.accessibility,
                    permissions: permissions
                )

                PermissionRow(
                    title: "麦克风",
                    explanation: "用于按住快捷键期间录制当前语音。",
                    kind: .microphone,
                    state: permissions.snapshot.microphone,
                    permissions: permissions
                )
            }

            Section("语音输入") {
                Picker(
                    "按住说话快捷键",
                    selection: Binding(
                        get: { runtime.shortcutChoice },
                        set: { runtime.selectShortcut($0) }
                    )
                ) {
                    ForEach(ShortcutChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                if let shortcutNotice = runtime.shortcutNotice {
                    Text(shortcutNotice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledContent("整理模式", value: "默认顺滑")
                LabeledContent("豆包", value: "未配置")
                LabeledContent("DeepSeek", value: "未配置（可选）")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
        .task {
            permissions.refresh()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let explanation: String
    let kind: PermissionKind
    let state: PermissionState
    @ObservedObject var permissions: PermissionModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(buttonTitle) {
                Task {
                    await permissions.request(kind)
                }
            }
            .disabled(state == .granted)
        }
    }

    private var icon: String {
        state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var color: Color {
        state == .granted ? .green : .orange
    }

    private var buttonTitle: String {
        switch state {
        case .granted:
            "已授权"
        case .notDetermined:
            "请求授权"
        case .denied:
            "打开授权"
        }
    }
}

private struct HistoryEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            "还没有会话记录",
            systemImage: "clock.arrow.circlepath",
            description: Text("完成第一次语音输入后，豆包与可选 DeepSeek 的阶段结果会显示在这里。")
        )
    }
}

@MainActor
private final class VoiceInputPanelController {
    private let panel: NSPanel
    private let model: VoiceInputSessionModel
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init(model: VoiceInputSessionModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: VoiceInputOverlay(model: model))
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = model.$presentation.sink { [weak self] presentation in
            self?.apply(presentation.activity)
        }
    }

    private func apply(_ activity: VoiceInputActivity) {
        hideTask?.cancel()
        hideTask = nil

        switch activity {
        case .idle:
            panel.orderOut(nil)
        case .delivered, .cancelled:
            showPanel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        case .preparing, .recording, .processing, .pendingCopy, .failed:
            showPanel()
        }
    }

    private func showPanel() {
        if let frame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 36
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }
}

private struct VoiceInputOverlay: View {
    @ObservedObject var model: VoiceInputSessionModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.presentation.activity.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.presentation.activity.summary)
                    .font(.headline)
                Text(model.presentation.activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if model.presentation.activity.isActive {
                Button("取消") {
                    model.send(.cancel)
                }
            } else if case .pendingCopy = model.presentation.activity {
                Button("复制") {
                    model.send(.copyPendingResult)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .frame(minHeight: 86)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .padding(8)
    }
}

private extension VoiceInputActivity {
    var isActive: Bool {
        switch self {
        case .preparing, .recording, .processing:
            true
        case .idle, .delivered, .pendingCopy, .cancelled, .failed:
            false
        }
    }

    var summary: String {
        switch self {
        case .idle:
            "等待语音输入"
        case .preparing:
            "正在准备麦克风"
        case .recording:
            "正在录音"
        case let .processing(_, stage, _):
            switch stage {
            case .capturingTarget:
                "正在捕获输入目标"
            case .transcribing:
                "正在转录"
            case .delivering:
                "正在送达文本"
            }
        case .delivered:
            "文本已送达"
        case .pendingCopy:
            "等待复制"
        case .cancelled:
            "本次输入已取消"
        case .failed:
            "本次输入失败"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "按住 Fn 开始讲话"
        case .preparing:
            "请稍候"
        case .recording:
            "松开 Fn 提交，按 Esc 取消"
        case let .processing(_, _, applicationName):
            applicationName.map { "输入目标：\($0)" } ?? "正在确定输入位置"
        case let .delivered(_, applicationName, _):
            "已写入 \(applicationName)"
        case let .pendingCopy(_, text, _):
            text
        case .cancelled:
            "没有发送音频或文本"
        case let .failed(_, failure):
            failure == .recordingFailed ? "无法完成录音" : "无法完成转录"
        }
    }

    var icon: String {
        switch self {
        case .idle:
            "waveform"
        case .preparing:
            "mic.badge.plus"
        case .recording:
            "mic.fill"
        case .processing:
            "sparkles"
        case .delivered:
            "checkmark.circle.fill"
        case .pendingCopy:
            "doc.on.clipboard"
        case .cancelled:
            "xmark.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}
