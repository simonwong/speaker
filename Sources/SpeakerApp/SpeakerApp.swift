import AppKit
import SpeakerCore
import SwiftUI

@main
struct SpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var permissions: PermissionModel

    init() {
        let access = SystemPermissionAccess()
        _permissions = StateObject(wrappedValue: PermissionModel(access: access))
    }

    var body: some Scene {
        MenuBarExtra("Speaker", systemImage: menuBarIcon) {
            MenuBarContent(permissions: permissions)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(permissions: permissions)
        }

        Window("会话历史", id: "history") {
            HistoryEmptyView()
        }
        .defaultSize(width: 720, height: 480)
    }

    private var menuBarIcon: String {
        permissions.snapshot.allGranted ? "waveform" : "waveform.badge.exclamationmark"
    }
}

private final class SpeakerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var permissions: PermissionModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Label("默认顺滑", systemImage: "text.alignleft")

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
            permissions.refresh()
        }
    }

    private var permissionSummary: String {
        permissions.snapshot.allGranted ? "权限已就绪" : "需要完成权限设置"
    }

    private var permissionIcon: String {
        permissions.snapshot.allGranted ? "checkmark.circle" : "exclamationmark.triangle"
    }
}

private struct SettingsView: View {
    @ObservedObject var permissions: PermissionModel

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
                LabeledContent("快捷键", value: "Fn（即将启用）")
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
