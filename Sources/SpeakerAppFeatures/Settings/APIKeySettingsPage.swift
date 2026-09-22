import SpeakerCore
import SwiftUI

package struct APIKeySettingsPage: View {
    let doubao: DoubaoSettingsModel
    let refinement: RefinementSettingsModel
    let recognition: SpeechRecognitionSettingsModel

    package init(
        doubao: DoubaoSettingsModel, refinement: RefinementSettingsModel,
        recognition: SpeechRecognitionSettingsModel
    ) {
        self.doubao = doubao
        self.refinement = refinement
        self.recognition = recognition
    }

    package var body: some View {
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            SpeechRecognitionSettingsCard(model: recognition, doubao: doubao)
            RefinementProviderSettingsCard(model: refinement)
        }
    }
}

package struct DoubaoSettingsCard: View {
    @ObservedObject var model: DoubaoSettingsModel

    package init(model: DoubaoSettingsModel) { self.model = model }
    package var body: some View {
        SettingsCard(
            "豆包语音",
            subtitle: "单次录音上限：10 分钟",
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
        SpeakerRow("流式资源") {
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

package struct RefinementProviderSettingsCard: View {
    @ObservedObject var model: RefinementSettingsModel

    package init(model: RefinementSettingsModel) { self.model = model }

    package var body: some View {
        SettingsCard(
            "文字整理 · 可选",
            icon: "sparkles"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "服务商",
                    selection: Binding(
                        get: { model.selectedProvider },
                        set: { provider in Task { await model.selectProvider(provider) } }
                    )
                ) {
                    ForEach(RefinementProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("文字整理服务商")

                if model.selectedProvider != .custom {
                    Picker(
                        "模型",
                        selection: Binding(
                            get: {
                                model.isEditingModelID
                                    ? "__manual__" : model.selectedProfile.modelID
                            },
                            set: { modelID in
                                if modelID == "__manual__" {
                                    model.isEditingModelID = true
                                } else {
                                    Task { await model.selectModel(modelID) }
                                }
                            }
                        )
                    ) {
                        ForEach(model.modelIDs, id: \.self) { modelID in
                            Text(model.modelTitle(for: modelID)).tag(modelID)
                        }
                        Text("其他模型…").tag("__manual__")
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("文字整理模型")
                }

                if model.selectedProvider == .custom {
                    labeledField(
                        "API Base URL", placeholder: "https://api.example.com/v1",
                        text: $model.baseURLDraft)
                    Text(
                        "兼容 OpenAI 的 HTTPS 地址，无需填写 /chat/completions。"
                    )
                    .font(SpeakerTypography.footnote)
                    .foregroundStyle(.secondary)
                }
                if model.isEditingModelID {
                    labeledField("模型 ID", placeholder: "填写服务商提供的模型 ID", text: $model.modelIDDraft)
                    Button("保存模型配置", action: saveConfiguration)
                        .disabled(!model.hasProfileChanges)
                        .accessibilityHidden(true)
                        .overlay {
                            AccessibilityButtonBridge(
                                label: "保存模型配置", hint: "保存接口和模型，不会发送测试请求",
                                isEnabled: model.hasProfileChanges && !model.isMutating,
                                action: saveConfiguration)
                        }
                }
            }
            .disabled(model.isMutating)

            if let providerNotice = model.providerNotice {
                SettingsNotice(text: providerNotice, color: .red)
            }

            SettingsRowDivider()
            StatusBadge(text: statusText, icon: statusIcon, color: statusColor)

            ProviderKeyEditor(
                draft: $model.apiKeyDraft,
                providerName: model.providerName,
                hasStoredKey: model.hasStoredKey,
                isUpdating: model.isMutating,
                allowsSave: model.hasValidProfile && !model.hasProfileChanges,
                deletionMessage: "只删除当前服务商的 Key，并切回默认顺滑；其他服务商与历史记录不受影响。",
                save: { await model.saveAPIKey() },
                delete: { await model.deleteAPIKey() }
            )

            if !model.hasValidProfile || model.hasProfileChanges {
                Text("先保存模型配置，再填写或更换 Key。")
                    .font(SpeakerTypography.footnote).foregroundStyle(.secondary)
            }
            if model.hasStoredKey {
                HStack {
                    Button(model.isCheckingConnection ? "检查中…" : "检查连接") {
                        model.checkConnection()
                    }
                    .disabled(
                        model.isCheckingConnection || model.isMutating || model.hasProfileChanges)
                    if model.isCheckingConnection { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
            if let credentialNotice = model.credentialNotice {
                SettingsNotice(text: credentialNotice, color: .red)
            }
            if let connectionFailure = model.connectionFailure {
                SettingsNotice(text: connectionFailure, color: .red)
            }
        }
    }

    private func saveConfiguration() {
        Task { await model.saveProviderConfiguration() }
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>)
        -> some View
    {
        RefinementConfigurationField(label: label, placeholder: placeholder, text: text)
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

struct ProviderKeyEditor: View {
    @Binding var draft: String
    let providerName: String
    let hasStoredKey: Bool
    let isUpdating: Bool
    var allowsSave = true
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
                .buttonStyle(SettingsButtonStyle(prominent: true))
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
        !isUpdating && allowsSave && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveDraft() {
        Task { await save() }
    }

}

private struct RefinementConfigurationField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(SpeakerTypography.caption)
            RefinementConfigurationTextField(
                label: label, placeholder: placeholder, text: $text, isFocused: $isFocused
            )
            .frame(height: 20)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .settingsGlassSurface(focused: isFocused)
        }
    }
}

private struct RefinementConfigurationTextField: NSViewRepresentable {
    let label: String
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        field.setAccessibilityLabel(label)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isFocused: $isFocused) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            commit(field)
        }
        @objc func commit(_ field: NSTextField) {
            text.wrappedValue = field.stringValue
        }
    }
}
