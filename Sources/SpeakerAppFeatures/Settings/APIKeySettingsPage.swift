import SpeakerCore
import SwiftUI

/// The API Keys page: one card per provider seam, Doubao first because
/// transcription cannot start without it.
struct APIKeySettingsPage: View {
    let doubao: DoubaoSettingsModel
    let refinement: RefinementSettingsModel

    var body: some View {
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            DoubaoSettingsCard(model: doubao)
            DeepSeekSettingsCard(model: refinement)
        }
    }
}

private struct DoubaoSettingsCard: View {
    @ObservedObject var model: DoubaoSettingsModel
    @State private var confirmingDelete = false
    @State private var isReplacingKey = false

    private var mode: APIKeyCardMode {
        APIKeyCardPresentation.mode(
            hasStoredKey: model.hasConfiguredKey,
            isReplacingKey: isReplacingKey
        )
    }

    var body: some View {
        SettingsCard(
            "豆包语音",
            subtitle: "边说边转录，默认启用语义顺滑",
            icon: "waveform.badge.mic"
        ) {
            statusRow

            SettingsRowDivider()

            if mode == .enterKey {
                keyInput(
                    placeholder: "输入豆包语音 API Key",
                    saveTitle: "保存 Key"
                )
            } else {
                resourceRow
                actionRow

                if mode == .replacingKey {
                    keyInput(
                        placeholder: "输入新 Key 替换当前凭据",
                        saveTitle: "保存"
                    )
                }
            }
        }
        .confirmationDialog(
            "删除豆包 API Key？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                Task { await model.delete() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将无法进行新的语音转录，历史记录不会受影响。")
        }
        .onChange(of: model.hasConfiguredKey) { _, hasKey in
            if !hasKey { isReplacingKey = false }
        }
    }

    private var statusRow: some View {
        HStack {
            StatusBadge(
                text: status.text,
                icon: status.symbolName,
                color: status.tint
            )
            .help(model.summary)
            Spacer()
            Link(
                "打开豆包控制台",
                destination: ExternalLinks.doubaoConsoleAPIKeys
            )
            .font(SpeakerTypography.caption)
        }
    }

    private var resourceRow: some View {
        SpeakerRow("流式资源", detail: "须与控制台已开通的套餐一致") {
            Picker(
                "流式资源",
                selection: Binding(
                    get: { model.resource },
                    set: { resource in Task { await model.selectResource(resource) } }
                )
            ) {
                ForEach(DoubaoStreamingResource.allCases, id: \.rawValue) { resource in
                    Text(resource.displayName).tag(resource)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if case .checking = model.status {
                ProgressView()
                    .controlSize(.small)
            }

            Button("检查连接") {
                model.checkConnection()
            }
            .disabled(isChecking)

            Button(isReplacingKey ? "收起" : "更换 Key") {
                isReplacingKey.toggle()
            }
            .disabled(isChecking)

            Spacer()

            Button("删除 Key", role: .destructive) {
                confirmingDelete = true
            }
        }
    }

    private func keyInput(
        placeholder: String,
        saveTitle: String
    ) -> some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $model.apiKeyDraft)
                .textContentType(.password)

            Button(saveTitle) {
                Task {
                    await model.save()
                    isReplacingKey = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.apiKeyDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
    }

    private var isChecking: Bool {
        if case .checking = model.status { true } else { false }
    }

    private var status: DoubaoStatusPresentation {
        DoubaoStatusPresentation(status: model.status)
    }
}

private struct DeepSeekSettingsCard: View {
    @ObservedObject var model: RefinementSettingsModel
    @State private var confirmingDelete = false
    @State private var isReplacingKey = false

    private var mode: APIKeyCardMode {
        APIKeyCardPresentation.mode(
            hasStoredKey: model.hasStoredKey,
            isReplacingKey: isReplacingKey
        )
    }

    var body: some View {
        SettingsCard(
            "DeepSeek · 可选",
            subtitle: "只接收豆包转录文本与整理提示词，不接收音频",
            icon: "sparkles"
        ) {
            statusRow

            SettingsRowDivider()

            if mode == .enterKey {
                keyInput(
                    placeholder: "输入 DeepSeek API Key",
                    saveTitle: "保存 Key"
                )
            } else {
                actionRow

                if mode == .replacingKey {
                    keyInput(
                        placeholder: "输入新 Key 替换当前凭据",
                        saveTitle: "保存"
                    )
                }
            }

            if let credentialNotice = model.credentialNotice {
                SettingsNotice(text: credentialNotice, color: .red)
            }
            if let connectionFailure = model.connectionFailure {
                SettingsNotice(text: connectionFailure, color: .red)
            }
        }
        .confirmationDialog(
            "删除 DeepSeek API Key？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                Task { await model.deleteAPIKey() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后会自动切回默认顺滑，豆包转录仍可正常使用。")
        }
        .onChange(of: model.hasStoredKey) { _, hasKey in
            if !hasKey { isReplacingKey = false }
        }
    }

    private var statusRow: some View {
        HStack {
            StatusBadge(
                text: statusText,
                icon: statusIcon,
                color: statusColor
            )
            Spacer()
            Link(
                "打开 DeepSeek 平台",
                destination: ExternalLinks.deepSeekAPIKeys
            )
            .font(SpeakerTypography.caption)
        }
    }

    private var actionRow: some View {
        HStack {
            Button {
                model.checkConnection()
            } label: {
                if model.isCheckingConnection {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text("检查中…")
                    }
                } else {
                    Text("检查连接")
                }
            }
            .disabled(model.isCheckingConnection)

            Button(isReplacingKey ? "收起" : "更换 Key") {
                isReplacingKey.toggle()
            }
            .disabled(model.isCheckingConnection)

            Spacer()

            Button("删除 Key", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(model.isCheckingConnection)
        }
    }

    private func keyInput(
        placeholder: String,
        saveTitle: String
    ) -> some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $model.apiKeyDraft)
                .textContentType(.password)

            Button(saveTitle) {
                Task {
                    await model.saveAPIKey()
                    isReplacingKey = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.apiKeyDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                    || model.isCheckingConnection
            )
        }
    }

    private var statusText: String {
        if model.isConnectionVerified { return "已验证" }
        if model.connectionFailure != nil { return "连接失败" }
        if model.hasStoredKey { return "已配置" }
        return "未配置"
    }

    private var statusIcon: String {
        if model.isConnectionVerified { return "checkmark.circle.fill" }
        if model.connectionFailure != nil { return "xmark.circle.fill" }
        if model.hasStoredKey { return "checkmark.shield" }
        return "key.slash"
    }

    private var statusColor: Color {
        if model.isConnectionVerified { return .green }
        if model.connectionFailure != nil { return .red }
        if model.hasStoredKey { return .green }
        return .secondary
    }
}
