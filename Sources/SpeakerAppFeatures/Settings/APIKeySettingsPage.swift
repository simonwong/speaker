import SpeakerCore
import SwiftUI

/// The API Keys page: one card per provider seam, Doubao first because
/// transcription cannot start without it.
package struct APIKeySettingsPage: View {
    let doubao: DoubaoSettingsModel
    let refinement: RefinementSettingsModel

    package init(doubao: DoubaoSettingsModel, refinement: RefinementSettingsModel) {
        self.doubao = doubao
        self.refinement = refinement
    }

    package var body: some View {
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            DoubaoSettingsCard(model: doubao)
            DeepSeekSettingsCard(model: refinement)
        }
    }
}

package struct DoubaoSettingsCard: View {
    @ObservedObject var model: DoubaoSettingsModel

    package init(model: DoubaoSettingsModel) { self.model = model }
    package var body: some View {
        SettingsCard(
            "豆包语音",
            subtitle: "边说边转录，默认启用语义顺滑",
            icon: "waveform.badge.mic"
        ) {
            statusRow

            SettingsRowDivider()

            ProviderKeyEditor(
                draft: $model.apiKeyDraft,
                providerName: "豆包语音",
                hasStoredKey: model.hasConfiguredKey,
                isUpdating: model.isUpdatingKey,
                deletionMessage: "删除后将无法进行新的语音转录，历史记录不会受影响。",
                save: { await model.save() },
                delete: { await model.delete() }
            )

            if model.hasConfiguredKey {
                resourceRow
                actionRow
            }
            if case .failure(let message) = model.status {
                SettingsNotice(text: message, color: .red)
            }
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
            .disabled(model.isUpdatingKey)
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
            .disabled(isChecking || model.isUpdatingKey)
            Spacer()
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
    var body: some View {
        SettingsCard(
            "DeepSeek · 可选",
            subtitle: "只接收豆包转录文本与整理提示词，不接收音频",
            icon: "sparkles"
        ) {
            statusRow

            SettingsRowDivider()

            ProviderKeyEditor(
                draft: $model.apiKeyDraft,
                providerName: "DeepSeek",
                hasStoredKey: model.hasStoredKey,
                isUpdating: model.isUpdatingKey,
                deletionMessage: "删除后会自动切回默认顺滑，豆包转录仍可正常使用。",
                save: { await model.saveAPIKey() },
                delete: { await model.deleteAPIKey() }
            )

            if model.hasStoredKey {
                actionRow
            }

            if let credentialNotice = model.credentialNotice {
                SettingsNotice(text: credentialNotice, color: .red)
            }
            if let connectionFailure = model.connectionFailure {
                SettingsNotice(text: connectionFailure, color: .red)
            }
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
            .disabled(model.isCheckingConnection || model.isUpdatingKey)
            Spacer()
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

private struct ProviderKeyEditor: View {
    @Binding var draft: String
    let providerName: String
    let hasStoredKey: Bool
    let isUpdating: Bool
    let deletionMessage: String
    let save: @MainActor () async -> Void
    let delete: @MainActor () async -> Void
    @State private var confirmingDelete = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                keyField.frame(minWidth: 180)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                keyField
                actions
            }
        }
        .disabled(isUpdating)
        .confirmationDialog(
            "删除 \(providerName) API Key？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除 Key", role: .destructive) {
                Task { await delete() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
    }

    private var keyField: some View {
        SecureField(
            hasStoredKey ? "输入新 Key 替换当前凭据" : "输入 \(providerName) API Key",
            text: $draft
        )
        .textContentType(.password)
        .accessibilityLabel("\(providerName) API Key")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if isUpdating {
                ProgressView().controlSize(.small)
            }
            Button(saveTitle, action: saveDraft)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .accessibilityHidden(true)
                .overlay {
                    AccessibilityButtonBridge(
                        label: saveTitle,
                        hint: "保存 \(providerName) API Key，不会自动发起连接检查",
                        isEnabled: canSave,
                        action: saveDraft
                    )
                }

            if hasStoredKey {
                Button("删除 Key", role: .destructive) {
                    confirmingDelete = true
                }
                .accessibilityHidden(true)
                .overlay {
                    AccessibilityButtonBridge(
                        label: "删除 Key",
                        hint: "删除 \(providerName) API Key 前需要确认",
                        isEnabled: !isUpdating,
                        action: { confirmingDelete = true }
                    )
                }
            }
        }
    }

    private var saveTitle: String {
        isUpdating ? "处理中…" : hasStoredKey ? "保存更换" : "保存 Key"
    }

    private var canSave: Bool {
        !isUpdating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveDraft() {
        Task { await save() }
    }

}
