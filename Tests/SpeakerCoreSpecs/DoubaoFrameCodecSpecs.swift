import Foundation
import SpeakerCore
import SpeakerSpecSupport

/// The Doubao binary frame layout, independent of any socket.
enum DoubaoFrameCodecSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        run("Doubao full client request frame carries a JSON header and its payload size", failures: &failures) {
            let payload = Data(#"{"user":{"uid":"u"}}"#.utf8)
            let frame = DoubaoStreamingFrameCodec.fullClientRequest(payload: payload)

            try expect(Array(frame.prefix(4)) == [0x11, 0x10, 0x10, 0x00], "header bytes were \(Array(frame.prefix(4)))")
            try expect(Array(frame[4..<8]) == [0x00, 0x00, 0x00, UInt8(payload.count)])
            try expect(frame.suffix(payload.count) == payload)
        }

        run("Doubao audio request frames mark only the final chunk", failures: &failures) {
            let audio = Data([1, 2, 3])
            let streaming = DoubaoStreamingFrameCodec.audioRequest(payload: audio, isFinal: false)
            let final = DoubaoStreamingFrameCodec.audioRequest(payload: audio, isFinal: true)

            try expect(streaming[1] == 0x20, "streaming audio flags were \(streaming[1])")
            try expect(final[1] == 0x22, "final audio flags were \(final[1])")
            try expect(streaming[2] == 0x00, "audio frames must be raw, not JSON")
            try expect(streaming.suffix(3) == audio && final.suffix(3) == audio)
        }

        run("Doubao decoder reads the error code that precedes an error payload", failures: &failures) {
            let frame = try DoubaoStreamingFrameCodec.decode(
                makeDoubaoServerError(code: 55_000_031, message: "busy")
            )

            try expect(frame.messageType == 0x0F)
            try expect(frame.errorCode == 55_000_031, "error code was \(String(describing: frame.errorCode))")
            try expect(frame.sequence == nil)
            try expect(frame.payload == Data(#"{"message":"busy"}"#.utf8))
        }

        run("Doubao decoder reads the sequence and final flag of a result frame", failures: &failures) {
            let sequenced = try DoubaoStreamingFrameCodec.decode(
                makeDoubaoServerFrame(
                    messageType: 0x09,
                    flags: 0x03,
                    prefix: UInt32(bitPattern: -7),
                    payload: Data(#"{"result":{"text":"好"}}"#.utf8)
                )
            )
            try expect(sequenced.sequence == -7, "sequence was \(String(describing: sequenced.sequence))")
            try expect(sequenced.isFinal)
            try expect(sequenced.serialization == 0x01)
            try expect(sequenced.errorCode == nil)

            let unsequenced = try DoubaoStreamingFrameCodec.decode(
                makeDoubaoServerFrame(
                    messageType: 0x09,
                    flags: 0x00,
                    prefix: 0,
                    payload: Data()
                )
            )
            // Without the sequence flag the prefix word is the payload size.
            try expect(unsequenced.sequence == nil)
            try expect(!unsequenced.isFinal)
        }

        run("Doubao decoder rejects truncated and compressed frames as invalid responses", failures: &failures) {
            let truncated = Data([0x11, 0x90, 0x10, 0x00, 0x00, 0x00, 0x00])
            try expectDecodeFailure(truncated, "seven bytes cannot hold a header")

            var shortPayload = Data([0x11, 0x90, 0x10, 0x00])
            appendUInt32BE(9, to: &shortPayload)
            shortPayload.append(contentsOf: [1, 2])
            try expectDecodeFailure(shortPayload, "payload size exceeding the frame")

            var compressed = Data([0x11, 0x90, 0x11, 0x00])
            appendUInt32BE(0, to: &compressed)
            try expectDecodeFailure(compressed, "gzip compression is not negotiated")
        }
    }

    private static func expectDecodeFailure(_ data: Data, _ reason: String) throws {
        do {
            _ = try DoubaoStreamingFrameCodec.decode(data)
            throw SpecFailure(message: "decoded a frame although \(reason)")
        } catch let failure as DoubaoASRFailure {
            try expect(failure.kind == .invalidResponse, "\(reason) mapped to \(failure.kind)")
        }
    }
}
