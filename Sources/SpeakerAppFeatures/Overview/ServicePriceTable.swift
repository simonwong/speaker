import Foundation
import SpeakerCore

/// The currency a provider publishes its price in. Estimates are shown per
/// currency and never converted.
package enum ServiceCurrency: String, CaseIterable, Equatable, Sendable {
    case cny
    case usd

    package var symbol: String {
        switch self {
        case .cny: "¥"
        case .usd: "$"
        }
    }
}

/// Published prices that the overview's estimated cost multiplies usage by.
///
/// This is the only place prices live. When a provider changes its price,
/// update the entry, its source comment, and `updatedOn` together. Prices are
/// list prices for ordinary requests: no free quota, no cache discount, and no
/// off-peak rate is applied, so an estimate is an upper bound for an account
/// that has those. A model missing from the table is priced "未知", never
/// guessed from a neighbour.
package enum ServicePriceTable {
    /// The day every price below was last checked against its source.
    package static let updatedOn = "2026-10-22"

    package struct RecognitionPrice: Equatable, Sendable {
        package let currency: ServiceCurrency
        package let perAudioHour: Double

        /// A price of zero means the service is free.
        package static let free = RecognitionPrice(currency: .cny, perAudioHour: 0)
    }

    package struct RefinementPrice: Equatable, Sendable {
        package let currency: ServiceCurrency
        package let inputPerMillionTokens: Double
        package let outputPerMillionTokens: Double

        package var isFree: Bool { inputPerMillionTokens == 0 && outputPerMillionTokens == 0 }
    }

    /// Tokens assumed per character sent or received. DeepSeek documents about
    /// 0.6 token per Chinese character and 0.3 per English character
    /// (https://api-docs.deepseek.com/zh-cn/quick_start/token_usage). Speaker's
    /// prompts and most dictation are Chinese, so the Chinese rate is used for
    /// every character and every provider.
    package static let tokensPerCharacter = 0.6

    /// The price of one Speech Recognition Provider model, or nil when unknown.
    /// `modelID` is empty for Session Records that did not name a model.
    package static func recognitionPrice(provider: String, modelID: String) -> RecognitionPrice? {
        switch SpeechRecognitionProviderID(rawValue: provider) {
        case .apple:
            // Runs on this Mac; no provider bills it.
            return .free
        case .doubao:
            // Volcengine 豆包流式语音识别模型 2.0 小时版: 标价 1 元/小时, billed
            // per second, as Speaker's website states (site/src/routes/doubao.tsx).
            // The Volcengine console's billing page is authoritative. Speaker
            // sends every Doubao session to this one resource.
            return RecognitionPrice(currency: .cny, perAudioHour: 1)
        case .openAI:
            // https://developers.openai.com/api/docs/pricing, per audio minute.
            let perMinute: Double? =
                switch modelID {
                case "gpt-transcribe": 0.0045
                case "gpt-live-transcribe": 0.017
                case "gpt-4o-transcribe": 0.006
                case "gpt-4o-mini-transcribe": 0.003
                default: nil
                }
            return perMinute.map { RecognitionPrice(currency: .usd, perAudioHour: $0 * 60) }
        case .qwen:
            // Alibaba Cloud Model Studio, 华北 2（北京）, per audio second
            // (https://help.aliyun.com/zh/model-studio/model-pricing). Session
            // Records do not store the region; Singapore lists 0.00026 and
            // 0.00066 元/秒, so a Singapore Key costs more than shown.
            let perSecond: Double? =
                switch modelID {
                case "qwen3-asr-flash": 0.00022
                case "qwen3-asr-flash-realtime": 0.00033
                default: nil
                }
            return perSecond.map { RecognitionPrice(currency: .cny, perAudioHour: $0 * 3_600) }
        case nil:
            return nil
        }
    }

    /// The price of one Refinement Provider model, or nil when unknown. A
    /// Custom Refinement Provider has no published price.
    package static func refinementPrice(
        provider: RefinementProviderID,
        modelID: String
    ) -> RefinementPrice? {
        switch (provider, modelID) {
        // https://api-docs.deepseek.com/zh-cn/quick_start/pricing/: peak-time
        // rate (Beijing weekdays 09:00–12:00 and 14:00–18:00); off-peak is
        // 1 / 4. The retired name routes to the same model at the same price.
        case (.deepSeek, "deepseek-flash"), (.deepSeek, "deepseek-v4-flash"):
            return RefinementPrice(
                currency: .cny, inputPerMillionTokens: 2, outputPerMillionTokens: 8)
        // https://developers.openai.com/api/docs/models/gpt-5.6-luna
        case (.openAI, "gpt-5.6-luna"):
            return RefinementPrice(
                currency: .usd, inputPerMillionTokens: 0.20, outputPerMillionTokens: 1.20)
        // https://platform.kimi.com/docs/pricing/chat: cache-miss input rate.
        case (.kimi, "kimi-k2.6"):
            return RefinementPrice(
                currency: .cny, inputPerMillionTokens: 6.50, outputPerMillionTokens: 27.00)
        // https://docs.bigmodel.cn/cn/guide/start/pricing. GLM-5.3-Flash
        // always reasons; its reasoning tokens are billed as output and are
        // not counted here.
        case (.glm, "glm-5.3-flash"):
            return RefinementPrice(
                currency: .cny, inputPerMillionTokens: 0.8, outputPerMillionTokens: 2.8)
        case (.glm, "glm-4.7-flash"):
            return RefinementPrice(
                currency: .cny, inputPerMillionTokens: 0, outputPerMillionTokens: 0)
        case (.glm, "glm-4.7-flashx"):
            return RefinementPrice(
                currency: .cny, inputPerMillionTokens: 0.5, outputPerMillionTokens: 3)
        case (.glm, "glm-5.2"):
            return RefinementPrice(
                currency: .cny, inputPerMillionTokens: 8, outputPerMillionTokens: 28)
        default:
            return nil
        }
    }
}
