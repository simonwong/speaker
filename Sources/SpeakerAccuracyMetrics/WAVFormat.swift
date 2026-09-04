import Foundation

public enum WAVFormatError: Error, Equatable, Sendable {
    case notRIFFWave
    case missingFormatChunk
    case unsupportedEncoding(UInt16)
    case unsupportedChannelCount(UInt16)
    case unsupportedSampleRate(UInt32)
    case unsupportedBitDepth(UInt16)
    case missingDataChunk
    case emptyData
}

extension WAVFormatError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notRIFFWave: "not a RIFF/WAVE file"
        case .missingFormatChunk: "missing fmt chunk"
        case let .unsupportedEncoding(format): "unsupported encoding \(format); expected PCM (1)"
        case let .unsupportedChannelCount(channels): "unsupported channel count \(channels); expected mono"
        case let .unsupportedSampleRate(rate): "unsupported sample rate \(rate) Hz; expected 16000 Hz"
        case let .unsupportedBitDepth(bits): "unsupported bit depth \(bits); expected 16-bit"
        case .missingDataChunk: "missing data chunk"
        case .emptyData: "data chunk is empty"
        }
    }
}

/// The exact audio contract Speaker streams to Doubao: 16 kHz, 16-bit, mono PCM.
public struct PCM16MonoWAV: Equatable, Sendable {
    public static let sampleRate: UInt32 = 16_000
    public static let bytesPerFrame = 2

    public let pcm: Data

    public var durationSeconds: Double {
        Double(pcm.count) / Double(Self.bytesPerFrame) / Double(Self.sampleRate)
    }

    public static func parse(_ data: Data) throws -> PCM16MonoWAV {
        guard data.count >= 12,
              string(data, 0..<4) == "RIFF",
              string(data, 8..<12) == "WAVE"
        else { throw WAVFormatError.notRIFFWave }

        var offset = 12
        var sawFormat = false
        var pcm: Data?
        while offset + 8 <= data.count {
            let chunkID = string(data, offset..<(offset + 4))
            let chunkSize = Int(uint32(data, offset + 4))
            let bodyStart = offset + 8
            let bodyEnd = min(bodyStart + chunkSize, data.count)
            if chunkID == "fmt " {
                guard bodyEnd - bodyStart >= 16 else { throw WAVFormatError.missingFormatChunk }
                let audioFormat = uint16(data, bodyStart)
                let channels = uint16(data, bodyStart + 2)
                let sampleRate = uint32(data, bodyStart + 4)
                let bitsPerSample = uint16(data, bodyStart + 14)
                guard audioFormat == 1 else { throw WAVFormatError.unsupportedEncoding(audioFormat) }
                guard channels == 1 else { throw WAVFormatError.unsupportedChannelCount(channels) }
                guard sampleRate == Self.sampleRate else { throw WAVFormatError.unsupportedSampleRate(sampleRate) }
                guard bitsPerSample == 16 else { throw WAVFormatError.unsupportedBitDepth(bitsPerSample) }
                sawFormat = true
            } else if chunkID == "data" {
                guard sawFormat else { throw WAVFormatError.missingFormatChunk }
                pcm = data.subdata(in: bodyStart..<bodyEnd)
                break
            }
            offset = bodyStart + chunkSize + (chunkSize % 2)
        }
        guard sawFormat else { throw WAVFormatError.missingFormatChunk }
        guard let pcm else { throw WAVFormatError.missingDataChunk }
        guard pcm.count >= Self.bytesPerFrame else { throw WAVFormatError.emptyData }
        return PCM16MonoWAV(pcm: pcm)
    }

    private static func string(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data.subdata(in: range), as: UTF8.self)
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }
}
