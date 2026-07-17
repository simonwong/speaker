import SpeakerCore

private struct VoiceInputFailurePresentation {
    let title: String
    let guidance: String
    let icon: String
    let needsSettings: Bool
}

package extension VoiceInputFailure {
    var userTitle: String { appPresentation.title }
    var userGuidance: String { appPresentation.guidance }
    var userIcon: String { appPresentation.icon }
    var needsSettings: Bool { appPresentation.needsSettings }

    private var appPresentation: VoiceInputFailurePresentation {
        switch self {
        case .sessionInterrupted:
            .init(
                title: "上次语音输入被中断",
                guidance: "Speaker 上次运行时没有正常结束，这条会话无法继续。",
                icon: "bolt.slash.fill",
                needsSettings: false
            )
        case .recordingFailed:
            .init(
                title: "录音没有完成",
                guidance: "请重新录音；如果再次出现，可在“关于”中复制诊断信息。",
                icon: "mic.slash.fill",
                needsSettings: false
            )
        case .microphonePermissionDenied:
            .init(
                title: "麦克风权限未开启",
                guidance: "请在系统设置中允许 Speaker 使用麦克风。",
                icon: "mic.slash.fill",
                needsSettings: true
            )
        case .transcriptionFailed:
            .init(
                title: "没有完成语音识别",
                guidance: "语音已经停止，请稍后再试。",
                icon: "exclamationmark.triangle.fill",
                needsSettings: false
            )
        case .providerNotConfigured:
            .init(
                title: "还没有配置豆包",
                guidance: "在语音识别设置中填入 API Key 即可开始使用。",
                icon: "key.slash",
                needsSettings: true
            )
        case .providerAuthenticationFailed:
            .init(
                title: "豆包 API Key 无效",
                guidance: "请在设置中重新保存正确的 API Key。",
                icon: "key.slash",
                needsSettings: true
            )
        case .providerCredentialUnavailable:
            .init(
                title: "无法读取 API Key",
                guidance: "请在设置中重新保存 API Key。",
                icon: "key.slash",
                needsSettings: true
            )
        case .noSpeechDetected:
            .init(
                title: "没有听清楚",
                guidance: "靠近麦克风说话，再试一次。",
                icon: "waveform.slash",
                needsSettings: false
            )
        case .providerResourceUnavailable:
            .init(
                title: "豆包语音服务尚未开通",
                guidance: "请在火山引擎控制台开通对应资源。",
                icon: "exclamationmark.triangle.fill",
                needsSettings: true
            )
        case .providerRateLimited:
            .init(
                title: "操作太频繁",
                guidance: "稍等片刻后再试。",
                icon: "exclamationmark.triangle.fill",
                needsSettings: false
            )
        case .providerUnavailable:
            .init(
                title: "豆包服务暂时不可用",
                guidance: "稍后重试，录音不会保存在本机。",
                icon: "exclamationmark.triangle.fill",
                needsSettings: false
            )
        case .networkUnavailable:
            .init(
                title: "网络连接不可用",
                guidance: "请检查网络后再试。",
                icon: "wifi.slash",
                needsSettings: false
            )
        case .audioSendBufferExhausted:
            .init(
                title: "语音发送已中断",
                guidance: "待发送的音频已达到安全上限，请检查网络后重新录音。",
                icon: "waveform.badge.exclamationmark",
                needsSettings: false
            )
        case .recordingTooShort:
            .init(
                title: "录音时间太短",
                guidance: "请讲话后再松开快捷键。",
                icon: "mic.badge.xmark",
                needsSettings: false
            )
        case .localSilenceDetected:
            .init(
                title: "录音中没有检测到声音",
                guidance: "请检查麦克风输入电平后重试。",
                icon: "waveform.slash",
                needsSettings: false
            )
        case .providerReceivedNoAudio:
            .init(
                title: "豆包没有收到音频",
                guidance: "本次请求没有可识别的音频数据，请重新录音。",
                icon: "text.badge.xmark",
                needsSettings: false
            )
        case .providerReturnedNoText:
            .init(
                title: "豆包没有返回文字",
                guidance: "本次识别已经结束，但结果中没有文字。",
                icon: "text.badge.xmark",
                needsSettings: false
            )
        case .audioProcessingFailed:
            .init(
                title: "音频没有完成处理",
                guidance: "请重新录音；如果反复出现，可在“关于”中复制诊断信息。",
                icon: "waveform.badge.exclamationmark",
                needsSettings: false
            )
        case .audioDeviceChanged:
            .init(
                title: "录音设备发生变化",
                guidance: "本次录音已停止，请确认当前麦克风后重新录音。",
                icon: "mic.badge.xmark",
                needsSettings: false
            )
        }
    }
}
