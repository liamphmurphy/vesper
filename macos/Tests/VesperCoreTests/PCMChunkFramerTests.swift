import Foundation
import Testing
@testable import VesperCore

@Suite("PCMChunkFramer")
struct PCMChunkFramerTests {
    @Test("handles odd-byte boundaries across chunks")
    func oddByteBoundaries() {
        var framer = PCMChunkFramer(sampleRate: 24_000)
        // Two 16-bit little-endian samples: +16384 (0x00, 0x40) and -32768 (0x00, 0x80).
        let first = framer.decode(Data([0x00, 0x40, 0x00]))
        #expect(first.count == 1)
        #expect(abs(first[0] - 0.5) < 0.0001)

        let second = framer.decode(Data([0x80]))
        #expect(second.count == 1)
        #expect(abs(second[0] - (-1.0)) < 0.0001)
        #expect(framer.totalSamples == 2)
    }

    @Test("computes prebuffer byte threshold and duration")
    func prebufferAndDuration() {
        #expect(PCMChunkFramer.bytes(forSeconds: 0.12, sampleRate: 24_000) == 5_760)
        var framer = PCMChunkFramer(sampleRate: 24_000)
        _ = framer.decode(Data(repeating: 0, count: 48_000))
        #expect(abs(framer.decodedDuration - 1.0) < 0.0001)
    }
}
