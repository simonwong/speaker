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
            SettingsCard("语音识别", subtitle: "接收录音并转成文字；切换仅影响下一次录音", icon: "waveform") {
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
                .pickerStyle(.menu)
                .accessibilityLabel("语音识别服务商")
                .disabled(model.isMutating)

                if model.selectedProvider != .doubao {
                    profileControls
                        .disabled(model.isMutating)
                    SettingsRowDivider()
                    StatusBadge(
                        text: model.hasStoredKey ? "Key 已保存 · 待首次识别验证" : "未配置",
                        icon: model.hasStoredKey ? "key.fill" : "key.slash",
                        color: .secondary)
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
                        model.selectedProfile.method == .streaming
                            ? "录音时持续发送音频，结束后交付完整文字。取消会停止后续发送，已发送的音频无法撤回。"
                            : "录音结束并通过本地检查后发送完整音频，再交付识别文字。"
                    )
                    .font(SpeakerTypography.footnote).foregroundStyle(.secondary)
                    Text("首次识别时验证账号与模型；保存 Key 不会发送测试请求。此 Key 与文字整理独立。")
                        .font(SpeakerTypography.footnote).foregroundStyle(.secondary)
                    Text(
                        model.selectedProvider == .openAI
                            ? "每次录音最多 5 分钟；需使用 OpenAI 支持地区的账号与网络。"
                            : "每次录音最多 3 分钟；北京与新加坡 Key 分开保存，不会自动跨地域重试。"
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
        VStack(alignment: .leading, spacing: 12) {
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
            .pickerStyle(.menu)
            .accessibilityLabel("语音识别方式")
            Text("切换识别方式会选择对应模型；现有 Key 可继续使用。")
                .font(SpeakerTypography.footnote).foregroundStyle(.secondary)
            if model.selectedProvider == .qwen {
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
                .pickerStyle(.menu)
                .accessibilityLabel("语音识别地域")
            }
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
            .pickerStyle(.menu)
            .accessibilityLabel("语音识别模型")
        }
    }
}
