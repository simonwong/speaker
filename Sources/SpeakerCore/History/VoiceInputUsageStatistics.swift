import Foundation

/// Aggregated voice-input usage for one local day. `day` is the start of that
/// day in the aggregation calendar.
public struct VoiceInputDailyUsage: Equatable, Sendable {
    public let day: Date
    public let recognizedCharacterCount: Int
    public let speakingMilliseconds: Int
    public let sessionCount: Int

    public init(
        day: Date,
        recognizedCharacterCount: Int,
        speakingMilliseconds: Int,
        sessionCount: Int
    ) {
        self.day = day
        self.recognizedCharacterCount = recognizedCharacterCount
        self.speakingMilliseconds = speakingMilliseconds
        self.sessionCount = sessionCount
    }
}

/// All-time totals plus per-day buckets across the recorded Voice Input Sessions.
///
/// `daily` holds one entry per day that saw at least one session, ascending by
/// `day`; callers that need a fixed calendar window (for example a contribution
/// heatmap) fill the gaps themselves.
public struct VoiceInputUsageSummary: Equatable, Sendable {
    public let totalRecognizedCharacterCount: Int
    public let totalSpeakingMilliseconds: Int
    public let totalSessionCount: Int
    public let daily: [VoiceInputDailyUsage]

    public init(
        totalRecognizedCharacterCount: Int,
        totalSpeakingMilliseconds: Int,
        totalSessionCount: Int,
        daily: [VoiceInputDailyUsage]
    ) {
        self.totalRecognizedCharacterCount = totalRecognizedCharacterCount
        self.totalSpeakingMilliseconds = totalSpeakingMilliseconds
        self.totalSessionCount = totalSessionCount
        self.daily = daily
    }

    public static let empty = VoiceInputUsageSummary(
        totalRecognizedCharacterCount: 0,
        totalSpeakingMilliseconds: 0,
        totalSessionCount: 0,
        daily: []
    )
}

/// Folds Voice Input Session records into a `VoiceInputUsageSummary` one session
/// at a time.
///
/// Memory stays bounded by the number of distinct days rather than the number of
/// records, so a store can stream rows through it without materializing its whole
/// table.
public struct VoiceInputUsageAccumulator {
    private struct Bucket {
        var characters = 0
        var milliseconds = 0
        var sessions = 0
    }

    private let calendar: Calendar
    private var buckets: [Date: Bucket] = [:]
    private var totalCharacters = 0
    private var totalMilliseconds = 0
    private var totalSessions = 0

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public mutating func add(
        startedAt: Date,
        recognizedCharacterCount: Int,
        speakingMilliseconds: Int
    ) {
        let characters = max(0, recognizedCharacterCount)
        let milliseconds = max(0, speakingMilliseconds)
        let day = calendar.startOfDay(for: startedAt)
        var bucket = buckets[day] ?? Bucket()
        bucket.characters += characters
        bucket.milliseconds += milliseconds
        bucket.sessions += 1
        buckets[day] = bucket
        totalCharacters += characters
        totalMilliseconds += milliseconds
        totalSessions += 1
    }

    public mutating func add(_ record: VoiceInputHistoryRecord) {
        add(
            startedAt: record.startedAt,
            recognizedCharacterCount: record.recognizedCharacterCount,
            speakingMilliseconds: record.speakingMilliseconds
        )
    }

    public func summary() -> VoiceInputUsageSummary {
        let daily = buckets.keys.sorted().map { day -> VoiceInputDailyUsage in
            let bucket = buckets[day] ?? Bucket()
            return VoiceInputDailyUsage(
                day: day,
                recognizedCharacterCount: bucket.characters,
                speakingMilliseconds: bucket.milliseconds,
                sessionCount: bucket.sessions
            )
        }
        return VoiceInputUsageSummary(
            totalRecognizedCharacterCount: totalCharacters,
            totalSpeakingMilliseconds: totalMilliseconds,
            totalSessionCount: totalSessions,
            daily: daily
        )
    }
}

public enum VoiceInputUsageStatistics {
    public static func summarize<Records: Sequence>(
        _ records: Records,
        calendar: Calendar = .current
    ) -> VoiceInputUsageSummary where Records.Element == VoiceInputHistoryRecord {
        var accumulator = VoiceInputUsageAccumulator(calendar: calendar)
        for record in records {
            accumulator.add(record)
        }
        return accumulator.summary()
    }
}

public extension VoiceInputHistoryRecord {
    /// The delivered text's length, falling back to the raw transcription.
    ///
    /// Redacted or secure sessions retain no body text, so they contribute zero.
    var recognizedCharacterCount: Int {
        (finalText ?? transcription).map(\.count) ?? 0
    }

    /// The measured recording duration for this session, or zero when recording
    /// never completed. This is speaking time only, not total session wall clock.
    var speakingMilliseconds: Int {
        max(0, stageDurationsMilliseconds["recording"] ?? 0)
    }
}
