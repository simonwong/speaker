import SpeakerCore
import SwiftUI

package struct MicrophoneSelectionPicker: View {
    @ObservedObject var model: MicrophoneSelectionFeature

    package init(model: MicrophoneSelectionFeature) {
        self.model = model
    }

    package var body: some View {
        Picker(
            "麦克风",
            selection: Binding(get: { model.state.preference }, set: { model.select($0) })
        ) {
            ForEach(model.state.choices) { choice in
                Text(choice.title).tag(choice.preference)
            }
        }
        .accessibilityLabel("麦克风")
        .accessibilityValue(model.state.selectionTitle)
        .help(model.state.selectionTitle)
    }
}

package struct MicrophoneSelectionMenu: View {
    @ObservedObject var model: MicrophoneSelectionFeature

    package init(model: MicrophoneSelectionFeature) {
        self.model = model
    }

    package var body: some View {
        Menu {
            MicrophoneSelectionPicker(model: model)
                .pickerStyle(.inline)
            if let notice = model.state.deviceNotice {
                Text(notice)
                Button("刷新麦克风列表", action: model.refresh)
            }
            if let description = model.state.captureDescription {
                Text(description)
            }
            if model.state.persistenceFailed {
                Text("麦克风选择尚未保存，退出后可能恢复旧选择。")
                Button("重试保存麦克风选择", action: model.retryPersistence)
            }
        } label: {
            Label("麦克风：\(model.state.selectionTitle)", systemImage: "mic")
        }
    }
}

package struct MicrophoneSettingsPage: View {
    @ObservedObject var model: MicrophoneSelectionFeature

    package init(model: MicrophoneSelectionFeature) {
        self.model = model
    }

    package var body: some View {
        SettingsCard {
            SpeakerRow("输入设备", detail: model.state.captureDescription) {
                MicrophoneSelectionPicker(model: model)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .trailing)
            }
            if let notice = model.state.deviceNotice {
                SettingsNotice(text: notice, color: .orange)
                Button("刷新麦克风列表", action: model.refresh)
            }
            if model.state.persistenceFailed {
                SettingsNotice(
                    text: "麦克风选择尚未保存，退出后可能恢复旧选择。",
                    color: .orange
                )
                Button("重试保存麦克风选择", action: model.retryPersistence)
            }
            SettingsRowDivider()
            SpeakerRow("测试麦克风") {
                switch model.state.testStatus {
                case .idle:
                    Button("开始测试", action: model.startLevelTest)
                        .disabled(!model.state.canStartTest)
                case .starting, .testing:
                    Button("停止测试", action: model.stopLevelTest)
                case .stopping:
                    Text("正在停止…").foregroundStyle(.secondary)
                }
            }
            if model.state.testStatus == .testing {
                ProgressView(value: model.state.testLevel)
                    .accessibilityLabel("麦克风输入电平")
                    .accessibilityValue("\(Int(model.state.testLevel * 100))%")
            }
            if let error = model.state.testError {
                SettingsNotice(text: error, color: .orange)
            }
        }
        .onDisappear {
            if model.state.testStatus != .idle { model.stopLevelTest() }
        }
    }
}
