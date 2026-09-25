import SpeakerCore
import SwiftUI

package struct SpeechRecognitionSettingsCard: View {
    @ObservedObject var model: SpeechRecognitionSettingsModel
    let doubao: DoubaoSettingsModel

    package init(model: SpeechRecognitionSettingsModel, doubao: DoubaoSettingsModel) {
        self.model = model
        self.doubao = doubao
    }

    package var body: some View {
        VStack(spacing: SpeakerSurfaceMetrics.cardSpacing) {
            SettingsCard("语音识别", icon: "waveform") {
                SpeakerRow("服务商") {
                    Picker(
                        "服务商",
                        selection: Binding(
                            get: { model.selectedProvider },
                            set: { provider in Task { await model.selectProvider(provider) } }
                        )
                    ) {
                        ForEach(SpeechRecognitionProviderID.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .settingsTrailingMenu()
                    .accessibilityLabel("语音识别服务商")
                    .disabled(model.isMutating)
                }

                if model.selectedProvider != .doubao {
                    profileControls
                    SettingsRowDivider()
                    StatusBadge(
                        text: model.hasStoredKey ? "已配置" : "未配置",
                        icon: model.hasStoredKey ? "checkmark.circle.fill" : "key.circle.fill",
                        color: model.hasStoredKey ? .green : .secondary)
                    ProviderKeyEditor(
                        draft: $model.apiKeyDraft,
                        providerName: model.providerName,
                        hasStoredKey: model.hasStoredKey,
                        isUpdating: model.isMutating,
                        allowsSave: model.hasValidProfile,
                        deletionMessage: "只删除当前语音识别服务与地域的 Key；文字整理 Key 不受影响。",
                        save: { await model.saveAPIKey() },
                        delete: { await model.deleteAPIKey() })
                    Text(
                        model.selectedProvider == .openAI
                            ? "单次录音上限：5 分钟"
                            : "单次录音上限：3 分钟"
                    )
                    .font(SpeakerTypography.footnote).foregroundStyle(.secondary)
                }
                if let notice = model.notice {
                    SettingsNotice(text: notice, color: .red)
                }
            }
            if model.selectedProvider == .doubao {
                DoubaoSettingsCard(model: doubao)
                    .disabled(model.isMutating)
            }
        }
        .onDisappear { model.discardKeyDraft() }
    }

    private var profileControls: some View {
        Group {
            SpeakerRow("识别方式") {
                Picker(
                    "识别方式",
                    selection: Binding(
                        get: { model.selectedProfile.method },
                        set: { method in Task { await model.selectMethod(method) } }
                    )
                ) {
                    if model.selectedProfile.method == .unsupported {
                        Text(SpeechRecognitionMethod.unsupported.displayName)
                            .tag(SpeechRecognitionMethod.unsupported)
                            .disabled(true)
                    }
                    ForEach(
                        SpeechRecognitionProviderCatalog.methods(for: model.selectedProvider),
                        id: \.self
                    ) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .settingsTrailingMenu()
                .accessibilityLabel("语音识别方式")
            }
            if model.selectedProvider == .qwen {
                SpeakerRow("地域") {
                    Picker(
                        "地域",
                        selection: Binding(
                            get: { model.selectedProfile.region },
                            set: { region in Task { await model.selectRegion(region) } }
                        )
                    ) {
                        ForEach(QwenASRRegion.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .settingsTrailingMenu()
                    .accessibilityLabel("语音识别地域")
                }
            }
            SpeakerRow("模型") {
                Picker(
                    "模型",
                    selection: Binding(
                        get: { model.selectedProfile.model },
                        set: { modelID in Task { await model.selectModel(modelID) } }
                    )
                ) {
                    ForEach(model.modelIDs, id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                }
                .settingsTrailingMenu()
                .accessibilityLabel("语音识别模型")
            }
        }
        .disabled(model.isMutating)
    }
}
