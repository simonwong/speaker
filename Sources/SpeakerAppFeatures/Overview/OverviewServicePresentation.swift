import Foundation
import SpeakerCore

/// What the overview shows for one service's estimated cost.
package enum ServiceCostAmount: Equatable, Sendable {
    case free
    /// No published price is known for this service.
    case unknown
    case estimate(ServiceCurrency, Double)
}

/// One row of the estimated-cost block: a service, the usage it was estimated
/// from, and the amount.
package struct ServiceCostLine: Equatable, Sendable {
    package let service: String
    package let usage: String
    package let amount: ServiceCostAmount

    package init(service: String, usage: String, amount: ServiceCostAmount) {
        self.service = service
        self.usage = usage
        self.amount = amount
    }

    package var amountText: String {
        OverviewServicePresentation.amountText(amount)
    }
}

/// The whole estimated-cost block: one total per currency that has a priced
/// service, then one line per service.
package struct ServiceCostEstimate: Equatable, Sendable {
    package let totals: [ServiceCurrency: Double]
    package let lines: [ServiceCostLine]

    package init(totals: [ServiceCurrency: Double], lines: [ServiceCostLine]) {
        self.totals = totals
        self.lines = lines
    }

    /// Totals in a fixed currency order, formatted.
    package var totalTexts: [String] {
        ServiceCurrency.allCases.compactMap { currency in
            totals[currency].map { OverviewServicePresentation.money($0, currency: currency) }
        }
    }
}

/// Release-to-delivery time for one Speech Recognition Provider. The median
/// and 90th percentile are nil when there are too few samples to show them.
package struct ServiceLatencyLine: Equatable, Sendable {
    package let service: String
    package let sampleCount: Int
    package let medianMilliseconds: Int?
    package let ninetiethPercentileMilliseconds: Int?

    package init(
        service: String,
        sampleCount: Int,
        medianMilliseconds: Int?,
        ninetiethPercentileMilliseconds: Int?
    ) {
        self.service = service
        self.sampleCount = sampleCount
        self.medianMilliseconds = medianMilliseconds
        self.ninetiethPercentileMilliseconds = ninetiethPercentileMilliseconds
    }

    /// The row's value, e.g. `中位 1.2 秒 · 90% 在 2.8 秒内`.
    package var summary: String {
        guard let medianMilliseconds else {
            return OverviewServicePresentation.insufficientSamplesText(sampleCount)
        }
        var text = "中位 \(OverviewServicePresentation.seconds(medianMilliseconds))"
        if let ninetiethPercentileMilliseconds {
            text +=
                " · 90% 在 \(OverviewServicePresentation.seconds(ninetiethPercentileMilliseconds))内"
        }
        return text
    }
}

/// Presentation policy for the overview's estimated cost and response time.
/// Product copy and prices stay here, not in `SpeakerCore`.
package enum OverviewServicePresentation {
    package static let costTitle = "估算费用"
    package static let costDisclaimer = "按公开价格估算，非账单"
    package static var priceDateText: String { "价格更新于 \(ServicePriceTable.updatedOn)" }
    package static let noUsageText = "还没有用量"
    package static let freeText = "免费"
    package static let unknownText = "未知"

    package static let latencyTitle = "响应速度"
    package static let latencyDefinition = "从松开快捷键到文字送达，只算成功送达的会话"
    package static let noLatencyText = "还没有成功送达的记录"

    /// Below this many delivered sessions a provider shows no number.
    package static let minimumLatencySamples = 5
    /// Below this many, the 90th percentile is one of the few slowest
    /// sessions rather than a tail, so only the median is shown.
    package static let minimumNinetiethPercentileSamples = 20

    // MARK: Cost

    package static func costEstimate(_ services: VoiceInputServiceUsage) -> ServiceCostEstimate {
        var totals: [ServiceCurrency: Double] = [:]
        var lines: [ServiceCostLine] = []

        for usage in services.recognition where usage.sessionCount > 0 {
            let amount: ServiceCostAmount
            if let price = ServicePriceTable.recognitionPrice(
                provider: usage.provider, modelID: usage.modelID)
            {
                if price.perAudioHour == 0 {
                    amount = .free
                } else {
                    let hours = Double(max(0, usage.recordingMilliseconds)) / 3_600_000
                    amount = .estimate(price.currency, hours * price.perAudioHour)
                }
            } else {
                amount = .unknown
            }
            lines.append(
                ServiceCostLine(
                    service: recognitionServiceName(
                        provider: usage.provider, modelID: usage.modelID),
                    usage: recordingTime(milliseconds: usage.recordingMilliseconds),
                    amount: amount
                ))
        }

        for usage in services.refinement where usage.requestCount > 0 {
            let amount: ServiceCostAmount
            if let price = ServicePriceTable.refinementPrice(
                provider: usage.provider, modelID: usage.modelID)
            {
                if price.isFree {
                    amount = .free
                } else {
                    let input = estimatedTokens(characters: usage.inputCharacterCount)
                    let output = estimatedTokens(characters: usage.outputCharacterCount)
                    amount = .estimate(
                        price.currency,
                        (input * price.inputPerMillionTokens
                            + output * price.outputPerMillionTokens) / 1_000_000
                    )
                }
            } else {
                amount = .unknown
            }
            lines.append(
                ServiceCostLine(
                    service: refinementServiceName(
                        provider: usage.provider, modelID: usage.modelID),
                    usage: "\(usage.requestCount.formatted(.number.grouping(.automatic))) 次整理",
                    amount: amount
                ))
        }

        for line in lines {
            if case .estimate(let currency, let value) = line.amount {
                totals[currency, default: 0] += value
            }
        }
        return ServiceCostEstimate(totals: totals, lines: lines)
    }

    package static func estimatedTokens(characters: Int) -> Double {
        Double(max(0, characters)) * ServicePriceTable.tokensPerCharacter
    }

    package static func amountText(_ amount: ServiceCostAmount) -> String {
        switch amount {
        case .free: freeText
        case .unknown: unknownText
        case .estimate(let currency, let value): money(value, currency: currency)
        }
    }

    /// Two decimals; a positive amount that rounds to zero says so instead of
    /// showing a free-looking `¥0.00`.
    package static func money(_ value: Double, currency: ServiceCurrency) -> String {
        if value > 0, value < 0.005 {
            return "不到 \(currency.symbol)0.01"
        }
        return currency.symbol + String(format: "%.2f", max(0, value))
    }

    package static func recordingTime(milliseconds: Int) -> String {
        let duration = VoiceInputUsagePresentation.speakingDuration(milliseconds: milliseconds)
        if duration.hours > 0 {
            return "录音 \(duration.hours) 时 \(duration.minutes) 分"
        }
        if duration.minutes > 0 {
            return "录音 \(duration.minutes) 分"
        }
        return "录音 \(duration.seconds) 秒"
    }

    package static func recognitionServiceName(provider: String, modelID: String) -> String {
        let name = SpeechRecognitionProviderID(rawValue: provider)?.displayName ?? provider
        return modelID.isEmpty ? name : "\(name) · \(modelID)"
    }

    package static func refinementServiceName(
        provider: RefinementProviderID,
        modelID: String
    ) -> String {
        let name = "\(provider.displayName)整理"
        return modelID.isEmpty ? name : "\(name) · \(modelID)"
    }

    // MARK: Latency

    /// One line per Speech Recognition Provider with delivered samples, in
    /// the providers' settings order; unknown stored providers follow.
    package static func latencyLines(_ services: VoiceInputServiceUsage) -> [ServiceLatencyLine] {
        let known = SpeechRecognitionProviderID.allCases.map(\.rawValue)
        let providers =
            known.filter { services.releaseToDeliveryMilliseconds[$0] != nil }
            + services.releaseToDeliveryMilliseconds.keys
            .filter { !known.contains($0) }
            .sorted()
        return providers.compactMap { provider in
            guard let samples = services.releaseToDeliveryMilliseconds[provider],
                !samples.isEmpty
            else { return nil }
            let sorted = samples.sorted()
            let showsMedian = sorted.count >= minimumLatencySamples
            return ServiceLatencyLine(
                service: SpeechRecognitionProviderID(rawValue: provider)?.displayName ?? provider,
                sampleCount: sorted.count,
                medianMilliseconds: showsMedian ? percentile(0.5, of: sorted) : nil,
                ninetiethPercentileMilliseconds: sorted.count >= minimumNinetiethPercentileSamples
                    ? percentile(0.9, of: sorted) : nil
            )
        }
    }

    /// Nearest-rank percentile of ascending samples: the smallest sample
    /// that at least `fraction` of the samples do not exceed.
    package static func percentile(_ fraction: Double, of sorted: [Int]) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    /// `0.8 秒`, `1.2 秒`, `12 秒`.
    package static func seconds(_ milliseconds: Int) -> String {
        let seconds = Double(max(0, milliseconds)) / 1_000
        return seconds < 10
            ? String(format: "%.1f 秒", seconds)
            : "\(Int(seconds.rounded())) 秒"
    }

    package static func insufficientSamplesText(_ count: Int) -> String {
        "样本不足（\(count) 次，满 \(minimumLatencySamples) 次后显示）"
    }
}
