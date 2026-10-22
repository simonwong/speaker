import SpeakerCore
import SwiftUI

package struct SpeechRecognitionSettingsCard: View {
    @ObservedObject var model: SpeechRecognitionSettingsModel
    let doubao: DoubaoSettingsModel

    /// Settings already titles its section 语音识别, so it hides the card's
    /// own header; onboarding shows the card alone and keeps it.
    private let showsHeader: Bool

    package init(
        model: SpeechRecognitionSettingsModel,
        doubao: DoubaoSettingsModel,
        showsHeader: Bool = true
    ) {
        self.model = model
        self.doubao = doubao
        self.showsHeader = showsHeader
    }

    package var body: some View {
        Group {
            if showsHeader {
                SettingsCard("语音识别", icon: "waveform") { rows }
            } else {
                SettingsCard { rows }
            }
        }
        .onDisappear { model.discardKeyDraft() }
    }

    @ViewBuilder
    private var rows: some View {
        SpeakerRow("服务商") {
            Picker(
                "服务商",
                selection: Binding(
                    get: { model.selectedProvider },
                    set: { provider in Task { await model.selectProvider(provider) } }
                )
            ) {
                ForEach(model.availableProviders, id: \.self) { provider in
                    Text(
                        provider.isOnDevice
                            ? "\(provider.displayName)（免 Key）" : provider.displayName
                    )
                    .tag(provider)
                }
            }
            .settingsTrailingMenu()
            .accessibilityLabel("语音识别服务商")
            .disabled(model.isMutating)
        }

        SettingsRowDivider()

        if model.selectedProvider == .doubao {
            DoubaoRecognitionSettings(model: doubao)
                .disabled(model.isMutating)
        } else if model.selectedProvider.isOnDevice {
            OnDeviceRecognitionSettings(model: model)
        } else {
            profileControls
            SettingsRowDivider()
            ProviderKeyEditor(
                draft: $model.apiKeyDraft,
                providerName: model.providerName,
                hasStoredKey: model.hasStoredKey,
                isUpdating: model.isMutating,
                allowsSave: model.hasValidProfile,
                status: ProviderKeyStatus(
                    text: model.hasStoredKey ? "已配置" : "未配置",
                    icon: model.hasStoredKey ? "checkmark.circle.fill" : "key.circle.fill",
                    color: model.hasStoredKey ? SpeakerVisualIdentity.settledGreen : .secondary),
                links: [
                    .console(for: model.selectedProvider, region: model.selectedProfile.region)
                ].compactMap { $0 },
                deletionMessage: "只删除当前语音识别服务与地域的 Key；文字整理 Key 不受影响。",
                save: { await model.saveAPIKey() },
                delete: { await model.deleteAPIKey() })
        }
        if let notice = model.notice {
            SettingsNotice(text: notice, color: .red)
        }
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
            SettingsRowDivider()
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
                SettingsRowDivider()
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

/// Apple's on-device recognition has no Key. The only thing to set up is the
/// system language model, which Speaker can ask macOS to download.
private struct OnDeviceRecognitionSettings: View {
    @ObservedObject var model: SpeechRecognitionSettingsModel

    var body: some View {
        SpeakerRow("语言模型") { modelStatus }
        SettingsRowDivider()
        SettingsNotice(
            text: "在这台 Mac 上识别，录音不上传，也不需要 API Key。识别语言跟随系统首选语言。"
                + "中英混说和标点不如云端服务，建议同时开启文字整理。")
    }

    @ViewBuilder
    private var modelStatus: some View {
        if let progress = model.modelInstallProgress {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在下载语言模型")
        } else {
            switch model.onDeviceModelStatus {
            case nil:
                ProgressView().controlSize(.small)
            case .installed:
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SpeakerVisualIdentity.settledGreen)
            case .notInstalled:
                Button("下载模型") { Task { await model.installOnDeviceModel() } }
                    .help("由 macOS 从 Apple 下载这门语言的识别模型")
                    .disabled(model.isMutating)
            case .unsupported:
                Text("这台 Mac 不支持当前语言")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
