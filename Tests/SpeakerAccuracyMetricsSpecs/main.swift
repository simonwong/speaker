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

private func littleEndianBytes(_ value: UInt32) -> Data {
    var data = Data()
    data.append(littleEndian: value)
    return data
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

private func matrixAlignment(reference: [Int], hypothesis: [Int]) -> EditCounts {
    let rows = reference.count + 1
    let columns = hypothesis.count + 1
    var distance = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
    for row in 0..<rows { distance[row][0] = row }
    for column in 0..<columns { distance[0][column] = column }
    if rows > 1, columns > 1 {
        for row in 1..<rows {
            for column in 1..<columns {
                let cost = reference[row - 1] == hypothesis[column - 1] ? 0 : 1
                distance[row][column] = min(
                    distance[row - 1][column - 1] + cost,
                    distance[row - 1][column] + 1,
                    distance[row][column - 1] + 1
                )
            }
        }
    }

    var counts = EditCounts.zero
    var row = reference.count
    var column = hypothesis.count
    while row > 0 || column > 0 {
        if row > 0, column > 0 {
            let cost = reference[row - 1] == hypothesis[column - 1] ? 0 : 1
            if distance[row][column] == distance[row - 1][column - 1] + cost {
                counts.substitutions += cost
                row -= 1
                column -= 1
                continue
            }
        }
        if row > 0, distance[row][column] == distance[row - 1][column] + 1 {
            counts.deletions += 1
            row -= 1
            continue
        }
        counts.insertions += 1
        column -= 1
    }
    return counts
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

        run(
            "alignment preserves deterministic counts for every short binary sequence",
            failures: &failures
        ) {
            let sequences = (0...5).flatMap { length in
                (0..<(1 << length)).map { value in
                    (0..<length).map { (value >> $0) & 1 }
                }
            }
            for reference in sequences {
                for hypothesis in sequences {
                    try expect(
                        EditAlignment.align(reference: reference, hypothesis: hypothesis)
                            == matrixAlignment(reference: reference, hypothesis: hypothesis),
                        "alignment changed for \(reference) and \(hypothesis)"
                    )
                }
            }
        }

        run("alignment handles long transcripts", failures: &failures) {
            let reference = Array(repeating: 0, count: 2_500)
            var hypothesis = reference
            hypothesis[1_250] = 1
            hypothesis.append(2)
            try expect(
                EditAlignment.align(reference: reference, hypothesis: hypothesis)
                    == EditCounts(substitutions: 1, deletions: 0, insertions: 1)
            )
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

        run(
            "WAV validation rejects truncated containers and incomplete PCM frames",
            failures: &failures
        ) {
            let valid = wavData(frameCount: 2)
            var shortRIFF = valid
            shortRIFF.replaceSubrange(4..<8, with: littleEndianBytes(36))
            var oversizedChunk = valid
            oversizedChunk.replaceSubrange(40..<44, with: littleEndianBytes(UInt32.max))
            var oddPCM = valid
            oddPCM.replaceSubrange(40..<44, with: littleEndianBytes(3))
            var wrongAlignment = valid
            wrongAlignment[32] = 4
            var wrongByteRate = valid
            wrongByteRate.replaceSubrange(28..<32, with: littleEndianBytes(16_000))
            for (name, malformed) in [
                ("truncated RIFF", Data(valid.dropLast())),
                ("data outside RIFF", shortRIFF),
                ("oversized chunk", oversizedChunk),
                ("incomplete frame", oddPCM),
                ("wrong block alignment", wrongAlignment),
                ("wrong byte rate", wrongByteRate),
            ] {
                try expectThrows(WAVFormatError.self, "accepted \(name)") {
                    _ = try PCM16MonoWAV.parse(malformed)
                }
            }
        }

        run(
            "WAV validation accepts padded metadata within the declared container",
            failures: &failures
        ) {
            var data = wavData(frameCount: 2)
            var metadata = Data("JUNK".utf8)
            metadata.append(littleEndian: UInt32(3))
            metadata.append(contentsOf: [1, 2, 3, 0])
            data.insert(contentsOf: metadata, at: 36)
            data.replaceSubrange(4..<8, with: littleEndianBytes(UInt32(data.count - 8)))
            let parsed = try PCM16MonoWAV.parse(data)
            try expect(parsed.pcm == Data(count: 4))
            data.append(contentsOf: [9, 9, 9])
            let withTrailingBytes = try PCM16MonoWAV.parse(data)
            try expect(withTrailingBytes == parsed)
        }

        run("WAV validation accepts Data slices with nonzero indices", failures: &failures) {
            let valid = wavData(frameCount: 2)
            var prefixed = Data([0, 0, 0])
            prefixed.append(valid)
            let slice = prefixed.dropFirst(3)
            try expect(slice.startIndex == 3)
            let parsed = try PCM16MonoWAV.parse(slice)
            try expect(parsed.pcm == Data(count: 4))
        }

        SpecSummary.finish(failures: failures, label: "accuracy metrics specs")
    }
}
