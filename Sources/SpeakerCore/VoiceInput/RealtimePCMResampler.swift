import Foundation

package struct RealtimePCMResampler {
    private static let radius = 32
    private static let kernels: [[Double]] = (0..<3).map { phase in
        let fraction = Double(phase) / 3
        let weights = (-radius...radius).map { offset -> Double in
            let distance = fraction - Double(offset)
            guard abs(distance) <= Double(radius) else { return 0 }
            let x = Double.pi * distance * 0.94
            let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
            let window =
                0.42 + 0.5 * cos(Double.pi * distance / Double(radius))
                + 0.08 * cos(2 * Double.pi * distance / Double(radius))
            return sinc * window
        }
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }
    private var samples: [Double] = []
    private var base = 0
    private var total = 0
    private var nextOutput = 0
    private var first: Double?
    private var last: Double = 0
    private var lowByte: UInt8?

    package init() {}

    package mutating func append(_ pcm: Data, final: Bool = false) throws -> Data {
        for byte in pcm {
            if let lowByte {
                let value = Double(Int16(bitPattern: UInt16(lowByte) | UInt16(byte) << 8))
                if first == nil { first = value }
                last = value
                samples.append(value)
                total += 1
                self.lowByte = nil
            } else {
                lowByte = byte
            }
        }
        if final, lowByte != nil { throw RealtimeSpeechTransportError.invalidMessage }
        var output = Data()
        let outputCount = total * 3 / 2
        while nextOutput < outputCount {
            let numerator = nextOutput * 2
            let center = numerator / 3
            if !final, center + Self.radius >= total { break }
            let kernel = Self.kernels[numerator % 3]
            var value = 0.0
            for offset in -Self.radius...Self.radius {
                let index = center + offset
                let sample: Double
                if index < 0 {
                    sample = first ?? 0
                } else if index >= total {
                    sample = last
                } else {
                    sample = samples[index - base]
                }
                value += sample * kernel[offset + Self.radius]
            }
            let sample = Int16(max(-32_768, min(32_767, value.rounded())))
            output.append(UInt8(truncatingIfNeeded: sample))
            output.append(UInt8(truncatingIfNeeded: sample >> 8))
            nextOutput += 1
        }
        let keepFrom = max(base, min(total, nextOutput * 2 / 3 - Self.radius))
        samples.removeFirst(keepFrom - base)
        base = keepFrom
        return output
    }
}
