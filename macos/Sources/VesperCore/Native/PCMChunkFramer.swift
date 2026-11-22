import Foundation

/// Converts arbitrarily chunked 16-bit signed little-endian mono PCM into normalized `Float`
/// samples (`-1.0…1.0`), carrying over any trailing odd byte across chunk boundaries so a sample
/// is never split across network reads.
public struct PCMChunkFramer: Sendable {
    public let sampleRate: Int
    private var trailingByte: UInt8?
    public private(set) var totalSamples: Int = 0

    public init(sampleRate: Int = 24_000) {
        self.sampleRate = max(1, sampleRate)
    }

    /// Bytes required to hold `seconds` of 16-bit mono PCM at `sampleRate`.
    public static func bytes(forSeconds seconds: Double, sampleRate: Int) -> Int {
        max(2, Int((Double(max(1, sampleRate)) * seconds).rounded()) * 2)
    }

    /// Duration in seconds of all complete samples decoded so far.
    public var decodedDuration: Double {
        Double(totalSamples) / Double(sampleRate)
    }

    /// Decodes the next raw byte chunk into normalized mono Float32 samples.
    public mutating func decode(_ data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let hasCarry = trailingByte != nil
        let available = data.count + (hasCarry ? 1 : 0)
        let sampleCount = available / 2
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)

        var idx = data.startIndex
        if let lo = trailingByte {
            let hi = data[idx]
            idx = data.index(after: idx)
            trailingByte = nil
            samples.append(Self.sample(lo: lo, hi: hi))
        }

        while data.distance(from: idx, to: data.endIndex) >= 2 {
            let lo = data[idx]
            let next = data.index(after: idx)
            let hi = data[next]
            idx = data.index(after: next)
            samples.append(Self.sample(lo: lo, hi: hi))
        }

        if idx < data.endIndex {
            trailingByte = data[idx]
        }

        totalSamples += samples.count
        return samples
    }

    private static func sample(lo: UInt8, hi: UInt8) -> Float {
        let raw = Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
        return max(-1.0, Float(raw) / 32768.0)
    }
}
