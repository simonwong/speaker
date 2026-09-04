import Foundation
import SpeakerCore
import SpeakerSpecSupport

enum AudioStreamSpecs: CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async {
        await runAsync("PCM streaming emits consecutive chunks without crashing", failures: &failures) {
            var buffer = PCMChunkBuffer(chunkSize: 6_400)
            let chunks = buffer.append(Data(repeating: 1, count: 12_800))
            try expect(chunks.count == 2)
            try expect(chunks.allSatisfy { $0.count == 6_400 })
        }

        await runAsync("audio stream terminates instead of silently dropping when its byte budget is exhausted", failures: &failures) {
            let exhaustion = LockedCounter()
            let buffer = BoundedAudioChunkStream(
                maximumBufferedBytes: 12,
                nominalChunkSize: 4,
                onBufferExhausted: { exhaustion.increment() }
            )
            try expect(buffer.yield(Data(repeating: 1, count: 4)) == .accepted)
            try expect(buffer.yield(Data(repeating: 2, count: 4)) == .accepted)
            try expect(buffer.yield(Data(repeating: 3, count: 4)) == .accepted)
            try expect(buffer.yield(Data(repeating: 4, count: 4)) == .bufferExhausted)
            try expect(buffer.yield(Data(repeating: 5, count: 4)) == .terminated)
            try expect(buffer.didExhaustBuffer)
            try expect(exhaustion.value == 1)

            var received: [Data] = []
            for await chunk in buffer.stream {
                received.append(chunk)
            }
            try expect(received.count == 3)
        }
    }
}
