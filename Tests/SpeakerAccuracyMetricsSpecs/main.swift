import Foundation
import SpeakerAccuracyMetrics
import SpeakerSpecSupport

private func manifestError(
    _ json: String,
    baseDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
) -> EvaluationManifestError? {
    do {
        _ = try EvaluationManifest.parse(Data(json.utf8), baseDirectory: baseDirectory)
        return nil
    } catch let error as EvaluationManifestError {
        return error
    } catch {
        return nil
    }
}

private func wavData(
    sampleRate: UInt32 = 16_000,
    channels: UInt16 = 1,
    bitsPerSample: UInt16 = 16,
    audioFormat: UInt16 = 1,
    frameCount: Int = 16_000
) -> Data {
    let blockAlign = channels * bitsPerSample / 8
    let pcm = Data(count: frameCount * Int(blockAlign))
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.append(littleEndian: UInt32(36 + pcm.count))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.append(littleEndian: UInt32(16))
    data.append(littleEndian: audioFormat)
    data.append(littleEndian: channels)
    data.append(littleEndian: sampleRate)
    data.append(littleEndian: sampleRate * UInt32(blockAlign))
    data.append(littleEndian: blockAlign)
    data.append(littleEndian: bitsPerSample)
    data.append(contentsOf: Array("data".utf8))
    data.append(littleEndian: UInt32(pcm.count))
    data.append(pcm)
    return data
}

extension Data {
    fileprivate mutating func append(littleEndian value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    fileprivate mutating func append(littleEndian value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

@main
private struct SpeakerAccuracyMetricsSpecs {
    @MainActor
    static func main() {
        var failures: [String] = []

        run("normalization removes punctuation and merges whitespace", failures: &failures) {
            let normalized = TranscriptNormalizer.normalize("你好，  世界！  Hello,   world.")
            try expect(normalized == "你好 世界 hello world", "unexpected normalization: \(normalized)")
        }

        run("normalization folds Latin case, full-width forms, and NFKC", failures: &failures) {
            try expect(
                TranscriptNormalizer.normalize("ＤｅｅｐＳｅｅｋ ２.０") == "deepseek 2 0",
                "full-width forms were not folded"
            )
            try expect(
                TranscriptNormalizer.normalize("ﬁle") == "file",
                "NFKC ligature was not decomposed"
            )
            try expect(
                TranscriptNormalizer.normalize("Speaker")
                    == TranscriptNormalizer.normalize("SPEAKER"),
                "Latin case was not folded"
            )
        }

        run("normalization keeps apostrophes inside Latin words", failures: &failures) {
            try expect(
                TranscriptNormalizer.normalize("Don’t stop 'quoted'") == "don't stop quoted",
                "apostrophe handling changed: \(TranscriptNormalizer.normalize("Don’t stop 'quoted'"))"
            )
        }

        run("identical text scores zero errors", failures: &failures) {
            let cer = AccuracyMetrics.characterErrorRate(
                reference: "你好 world", hypothesis: "你好，World！")
            try expect(cer.counts == .zero, "CER counts were \(cer.counts)")
            try expect(cer.rate == 0, "CER rate was \(cer.rate)")
            try expect(cer.referenceLength == 7, "reference length was \(cer.referenceLength)")
            let wer = AccuracyMetrics.latinWordErrorRate(
                reference: "Hello World", hypothesis: "hello, world")
            try expect(wer.counts == .zero && wer.rate == 0, "WER was \(wer)")
        }

        run(
            "alignment reports exact substitution, deletion, and insertion counts",
            failures: &failures
        ) {
            let substitution = EditAlignment.align(
                reference: Array("abcd"), hypothesis: Array("abxd"))
            try expect(
                substitution == EditCounts(substitutions: 1, deletions: 0, insertions: 0),
                "substitution counts were \(substitution)")
            let deletion = EditAlignment.align(reference: Array("abcd"), hypothesis: Array("abd"))
            try expect(
                deletion == EditCounts(substitutions: 0, deletions: 1, insertions: 0),
                "deletion counts were \(deletion)")
            let insertion = EditAlignment.align(
                reference: Array("abcd"), hypothesis: Array("abcde"))
            try expect(
                insertion == EditCounts(substitutions: 0, deletions: 0, insertions: 1),
                "insertion counts were \(insertion)")
            let mixed = EditAlignment.align(
                reference: Array("kitten"), hypothesis: Array("sitting"))
            try expect(
                mixed == EditCounts(substitutions: 2, deletions: 0, insertions: 1),
                "mixed counts were \(mixed)")
            try expect(mixed.total == 3, "mixed total was \(mixed.total)")
            let emptyHypothesis = EditAlignment.align(
                reference: Array("abc"), hypothesis: Array(""))
            try expect(
                emptyHypothesis == EditCounts(substitutions: 0, deletions: 3, insertions: 0),
                "empty hypothesis counts were \(emptyHypothesis)")
            let emptyReference = EditAlignment.align(reference: Array(""), hypothesis: Array("ab"))
            try expect(
                emptyReference == EditCounts(substitutions: 0, deletions: 0, insertions: 2),
                "empty reference counts were \(emptyReference)")
        }

        run("CER uses the normalized reference character count as denominator", failures: &failures)
        {
            let cer = AccuracyMetrics.characterErrorRate(
                reference: "我们用 Speaker 输入", hypothesis: "我们用 speaker 输")
            try expect(cer.referenceLength == 12, "reference length was \(cer.referenceLength)")
            try expect(
                cer.counts == EditCounts(substitutions: 0, deletions: 1, insertions: 0),
                "counts were \(cer.counts)")
            try expect(abs(cer.rate - 1.0 / 12.0) < 1e-9, "rate was \(cer.rate)")
            let empty = AccuracyMetrics.characterErrorRate(reference: "", hypothesis: "ab")
            try expect(
                empty.referenceLength == 0 && empty.counts.insertions == 2 && empty.rate == 2,
                "empty reference rate was \(empty)")
        }

        run("Latin token extraction ignores CJK text and pure punctuation", failures: &failures) {
            let tokens = AccuracyMetrics.latinTokens(in: "我用 DeepSeek 和 Claude-Code 写 v2.0 版本，OK？")
            try expect(
                tokens == ["deepseek", "claude", "code", "v2", "0", "ok"], "tokens were \(tokens)")
            try expect(
                AccuracyMetrics.latinTokens(in: "纯中文，没有拉丁字母。").isEmpty,
                "CJK-only text produced tokens")
        }

        run("Latin WER counts token edits only", failures: &failures) {
            let wer = AccuracyMetrics.latinWordErrorRate(
                reference: "请打开 Speaker 然后用 DeepSeek 精修",
                hypothesis: "请打开 speaker 然后用 deep seek 精修"
            )
            try expect(wer.referenceLength == 2, "reference tokens were \(wer.referenceLength)")
            try expect(
                wer.counts == EditCounts(substitutions: 1, deletions: 0, insertions: 1),
                "counts were \(wer.counts)")
            try expect(wer.rate == 1.0, "rate was \(wer.rate)")
        }

        run("aggregate rates use corpus totals and per-sample means", failures: &failures) {
            let aggregate = ErrorRateAggregate(results: [
                ErrorRateResult(
                    referenceLength: 10,
                    counts: EditCounts(substitutions: 1, deletions: 0, insertions: 0)),
                ErrorRateResult(
                    referenceLength: 30,
                    counts: EditCounts(substitutions: 0, deletions: 3, insertions: 0)),
            ])
            try expect(
                aggregate.referenceLength == 40,
                "total reference length was \(aggregate.referenceLength)")
            try expect(
                aggregate.counts == EditCounts(substitutions: 1, deletions: 3, insertions: 0),
                "counts were \(aggregate.counts)")
            try expect(
                abs(aggregate.corpusRate - 0.1) < 1e-9, "corpus rate was \(aggregate.corpusRate)")
            try expect(
                abs(aggregate.meanSampleRate - 0.1) < 1e-9,
                "mean sample rate was \(aggregate.meanSampleRate)")
            try expect(
                ErrorRateAggregate(results: []).corpusRate == 0, "empty aggregate was not zero")
        }

        run("manifest parses samples and resolves relative WAV paths", failures: &failures) {
            let json = """
                {"samples":[{"id":"office-1","wav":"clips/office-1.wav","reference":"我们用 Speaker","tags":["office","mixed"]},
                            {"id":"quiet-1","wav":"/private/tmp/quiet.wav","reference":"安静"}]}
                """
            let manifest = try EvaluationManifest.parse(
                Data(json.utf8),
                baseDirectory: URL(fileURLWithPath: "/private/tmp/eval", isDirectory: true)
            )
            try expect(manifest.samples.count == 2, "sample count was \(manifest.samples.count)")
            try expect(
                manifest.samples[0].wavURL.path == "/private/tmp/eval/clips/office-1.wav",
                "relative path was \(manifest.samples[0].wavURL.path)")
            try expect(
                manifest.samples[1].wavURL.path == "/private/tmp/quiet.wav",
                "absolute path was \(manifest.samples[1].wavURL.path)")
            try expect(
                manifest.samples[0].tags == ["office", "mixed"],
                "tags were \(manifest.samples[0].tags)")
            try expect(manifest.samples[1].tags.isEmpty, "missing tags were not empty")
        }

        run(
            "manifest validation reports malformed JSON, empty lists, empty fields, and duplicate ids",
            failures: &failures
        ) {
            try expect(manifestError("{") == .malformedJSON, "malformed JSON was not reported")
            try expect(
                manifestError("{\"samples\":[]}") == .noSamples,
                "empty sample list was not reported")
            try expect(
                manifestError(
                    "{\"samples\":[{\"id\":\" \",\"wav\":\"a.wav\",\"reference\":\"x\"}]}")
                    == .emptySampleID(index: 0),
                "empty id was not reported"
            )
            try expect(
                manifestError("{\"samples\":[{\"id\":\"a\",\"wav\":\"\",\"reference\":\"x\"}]}")
                    == .emptyWAVPath(sampleID: "a"),
                "empty wav path was not reported"
            )
            try expect(
                manifestError(
                    "{\"samples\":[{\"id\":\"a\",\"wav\":\"a.wav\",\"reference\":\"，。\"}]}")
                    == .emptyReference(sampleID: "a"),
                "punctuation-only reference was not reported"
            )
            try expect(
                manifestError(
                    "{\"samples\":[{\"id\":\"a\",\"wav\":\"a.wav\",\"reference\":\"x\"},{\"id\":\"a\",\"wav\":\"b.wav\",\"reference\":\"y\"}]}"
                ) == .duplicateSampleID("a"),
                "duplicate id was not reported"
            )
        }

        run(
            "WAV validation accepts 16 kHz 16-bit mono PCM and rejects everything else",
            failures: &failures
        ) {
            let valid = try PCM16MonoWAV.parse(wavData())
            try expect(valid.pcm.count == 32_000, "pcm byte count was \(valid.pcm.count)")
            try expect(
                abs(valid.durationSeconds - 1) < 1e-9, "duration was \(valid.durationSeconds)")

            func failure(_ data: Data) -> WAVFormatError? {
                do {
                    _ = try PCM16MonoWAV.parse(data)
                    return nil
                } catch let error as WAVFormatError {
                    return error
                } catch {
                    return nil
                }
            }
            try expect(failure(Data("not a wav".utf8)) == .notRIFFWave, "non-WAV data was accepted")
            try expect(
                failure(wavData(sampleRate: 44_100)) == .unsupportedSampleRate(44_100),
                "44.1 kHz was accepted")
            try expect(
                failure(wavData(channels: 2)) == .unsupportedChannelCount(2), "stereo was accepted")
            try expect(
                failure(wavData(bitsPerSample: 24)) == .unsupportedBitDepth(24),
                "24-bit was accepted")
            try expect(
                failure(wavData(audioFormat: 3)) == .unsupportedEncoding(3),
                "float encoding was accepted")
            try expect(
                failure(wavData(frameCount: 0)) == .emptyData, "empty data chunk was accepted")
        }

        SpecSummary.finish(failures: failures, label: "accuracy metrics specs")
    }
}
