import Foundation
import SpeakerAppFeatures
import SpeakerCore
import SpeakerSpecSupport

/// The overview's estimated cost and response time: what is priced, how each
/// currency is totalled, and when a latency number is shown at all.
enum OverviewServiceSpecs {
    @MainActor
    static func run(failures: inout [String]) async {
        SpeakerSpecSupport.run(
            "estimated cost totals each currency on its own and prices only published services",
            failures: &failures
        ) {
            let services = VoiceInputServiceUsage(
                recognition: [
                    .init(
                        provider: "apple", modelID: "speech-transcriber",
                        sessionCount: 3, recordingMilliseconds: 3_600_000),
                    .init(
                        provider: "doubao", modelID: "bigmodel_async",
                        sessionCount: 40, recordingMilliseconds: 2 * 3_600_000),
                    .init(
                        provider: "openai", modelID: "gpt-transcribe",
                        sessionCount: 5, recordingMilliseconds: 10 * 60_000),
                    .init(
                        provider: "openai", modelID: "whisper-1",
                        sessionCount: 1, recordingMilliseconds: 60_000),
                    .init(
                        provider: "qwen", modelID: "qwen3-asr-flash-realtime",
                        sessionCount: 2, recordingMilliseconds: 1_000_000),
                ],
                refinement: [
                    .init(
                        provider: .custom, modelID: "", requestCount: 4,
                        inputCharacterCount: 4_000, outputCharacterCount: 400),
                    .init(
                        provider: .deepSeek, modelID: "deepseek-flash", requestCount: 10,
                        inputCharacterCount: 1_000_000, outputCharacterCount: 100_000),
                    .init(
                        provider: .glm, modelID: "glm-4.7-flash", requestCount: 2,
                        inputCharacterCount: 2_000, outputCharacterCount: 200),
                    .init(
                        provider: .openAI, modelID: "gpt-5.6-luna", requestCount: 3,
                        inputCharacterCount: 1_000_000, outputCharacterCount: 1_000_000),
                ],
                releaseToDeliveryMilliseconds: [:]
            )

            let estimate = OverviewServicePresentation.costEstimate(services)
            let amounts = Dictionary(
                estimate.lines.map { ($0.service, $0.amount) },
                uniquingKeysWith: { first, _ in first }
            )

            // Doubao 2 h × ¥1 + Qwen realtime 1,000 s × ¥0.00033
            // + DeepSeek (600,000 × ¥2 + 60,000 × ¥8) / 1M tokens.
            let expectedCNY = 2.0 + 0.33 + 1.68
            // OpenAI gpt-transcribe 10 min × $0.0045
            // + Luna (600,000 × $0.20 + 600,000 × $1.20) / 1M tokens.
            let expectedUSD = 0.045 + 0.84
            try expect(
                abs((estimate.totals[.cny] ?? -1) - expectedCNY) < 0.000_1,
                "CNY total was \(String(describing: estimate.totals[.cny]))"
            )
            try expect(
                abs((estimate.totals[.usd] ?? -1) - expectedUSD) < 0.000_1,
                "USD total was \(String(describing: estimate.totals[.usd]))"
            )
            try expect(
                estimate.totalTexts == ["¥4.01", "$0.89"],
                "totals read \(estimate.totalTexts)"
            )
            try expect(amounts["Apple 语音识别 · speech-transcriber"] == .free)
            try expect(amounts["GLM整理 · glm-4.7-flash"] == .free)
            try expect(
                amounts["自定义整理"] == .unknown, "custom was \(String(describing: amounts["自定义整理"]))")
            try expect(amounts["OpenAI 语音识别 · whisper-1"] == .unknown)
            try expect(
                estimate.lines.first { $0.service == "自定义整理" }?.amountText == "未知"
            )
            try expect(
                estimate.lines.first { $0.service == "豆包语音 · bigmodel_async" }?.usage
                    == "录音 2 时 0 分"
            )
            try expect(OverviewServicePresentation.costDisclaimer == "按公开价格估算，非账单")
            try expect(
                OverviewServicePresentation.priceDateText
                    == "价格更新于 \(ServicePriceTable.updatedOn)"
            )
        }

        SpeakerSpecSupport.run(
            "estimated cost says when there is no usage and never rounds a charge down to zero",
            failures: &failures
        ) {
            let empty = OverviewServicePresentation.costEstimate(.empty)
            try expect(empty.lines.isEmpty)
            try expect(empty.totalTexts.isEmpty)

            let tiny = OverviewServicePresentation.costEstimate(
                VoiceInputServiceUsage(
                    recognition: [
                        .init(
                            provider: "doubao", modelID: "bigmodel_async",
                            sessionCount: 1, recordingMilliseconds: 3_000)
                    ],
                    refinement: [],
                    releaseToDeliveryMilliseconds: [:]
                ))
            try expect(tiny.totalTexts == ["不到 ¥0.01"], "tiny total read \(tiny.totalTexts)")
            try expect(tiny.lines.first?.usage == "录音 3 秒")
        }

        SpeakerSpecSupport.run(
            "response time shows no number below five delivered sessions and no tail below twenty",
            failures: &failures
        ) {
            let services = VoiceInputServiceUsage(
                recognition: [],
                refinement: [],
                releaseToDeliveryMilliseconds: [
                    "qwen": [900, 1_000, 1_100, 1_200],
                    "doubao": [600, 700, 800, 900, 1_000],
                    "openai": Array(stride(from: 100, through: 2_000, by: 100)),
                ]
            )

            let lines = OverviewServicePresentation.latencyLines(services)
            let byService = Dictionary(
                lines.map { ($0.service, $0) }, uniquingKeysWith: { first, _ in first })

            try expect(
                lines.map(\.service) == ["豆包语音", "OpenAI 语音识别", "阿里千问语音识别"],
                "lines were ordered \(lines.map(\.service))"
            )
            let qwen = byService["阿里千问语音识别"]
            try expect(qwen?.medianMilliseconds == nil)
            try expect(qwen?.ninetiethPercentileMilliseconds == nil)
            try expect(qwen?.summary.contains("样本不足") == true, qwen?.summary ?? "")
            try expect(
                qwen?.summary.contains("1.") == false, "an insufficient line showed a number")

            let doubao = byService["豆包语音"]
            try expect(doubao?.medianMilliseconds == 800)
            try expect(doubao?.ninetiethPercentileMilliseconds == nil)
            try expect(doubao?.summary == "中位 0.8 秒", doubao?.summary ?? "")

            let openAI = byService["OpenAI 语音识别"]
            try expect(openAI?.sampleCount == 20)
            try expect(openAI?.medianMilliseconds == 1_000)
            try expect(openAI?.ninetiethPercentileMilliseconds == 1_800)
            try expect(openAI?.summary == "中位 1.0 秒 · 90% 在 1.8 秒内", openAI?.summary ?? "")
        }

        SpeakerSpecSupport.run(
            "response-time percentiles use the nearest rank", failures: &failures
        ) {
            let samples = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1_000]
            try expect(OverviewServicePresentation.percentile(0.5, of: samples) == 500)
            try expect(OverviewServicePresentation.percentile(0.9, of: samples) == 900)
            try expect(OverviewServicePresentation.percentile(0.9, of: [42]) == 42)
            try expect(OverviewServicePresentation.seconds(12_400) == "12 秒")
        }

        await runAsync(
            "overview state carries service usage from the history store",
            failures: &failures
        ) {
            let services = VoiceInputServiceUsage(
                recognition: [
                    .init(
                        provider: "doubao", modelID: "bigmodel_async",
                        sessionCount: 1, recordingMilliseconds: 1_000)
                ],
                refinement: [],
                releaseToDeliveryMilliseconds: ["doubao": [500]]
            )
            let summary = VoiceInputUsageSummary(
                totalRecognizedCharacterCount: 4, totalSpeakingMilliseconds: 1_000,
                totalSessionCount: 1, daily: [], services: services
            )
            let store = DashboardHistoryStoreFake(records: [], summary: summary)
            let model = OverviewModel(store: store)
            await model.refresh()
            try expect(model.dashboardState.summary.services == services)
        }
    }
}
