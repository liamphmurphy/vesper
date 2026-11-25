import Compression
import Foundation

/// Compact pure-Swift ZIP writer (method 8 raw DEFLATE via Apple `Compression`, falling back to
/// method 0 STORE when uncompressed is smaller or empty). Used by native `.docx` and `.pptx`
/// exporters without third-party dependencies.
public enum MinimalZipWriter {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }

        public init(path: String, utf8: String) {
            self.path = path
            self.data = Data(utf8.utf8)
        }
    }

    /// Builds a standard ZIP archive containing `entries` in order.
    public static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let raw = entry.data
            let crc = crc32(raw)
            let compressed = deflateRaw(raw)
            let useDeflate = compressed != nil && compressed!.count < raw.count
            let payload = useDeflate ? compressed! : raw
            let method: UInt16 = useDeflate ? 8 : 0
            let localOffset = UInt32(out.count)

            // Local file header (PK\x03\x04)
            out.appendLE(UInt32(0x0403_4B50))
            out.appendLE(UInt16(20)) // version needed: 2.0
            out.appendLE(UInt16(0x0800)) // UTF-8 filename flag
            out.appendLE(method)
            out.appendLE(UInt16(0)) // mod time
            out.appendLE(UInt16(0x5421)) // mod date (2022-01-01)
            out.appendLE(crc)
            out.appendLE(UInt32(payload.count))
            out.appendLE(UInt32(raw.count))
            out.appendLE(UInt16(nameData.count))
            out.appendLE(UInt16(0)) // extra length
            out.append(nameData)
            out.append(payload)

            // Central directory header (PK\x01\x02)
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20)) // version made by
            central.appendLE(UInt16(20)) // version needed
            central.appendLE(UInt16(0x0800)) // UTF-8 flag
            central.appendLE(method)
            central.appendLE(UInt16(0)) // mod time
            central.appendLE(UInt16(0x5421)) // mod date
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(raw.count))
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0)) // extra length
            central.appendLE(UInt16(0)) // comment length
            central.appendLE(UInt16(0)) // disk number start
            central.appendLE(UInt16(0)) // internal attributes
            central.appendLE(UInt32(0)) // external attributes
            central.appendLE(localOffset)
            central.append(nameData)
        }

        let centralOffset = UInt32(out.count)
        let centralSize = UInt32(central.count)
        out.append(central)

        // End of central directory record (PK\x05\x06)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0)) // disk number
        out.appendLE(UInt16(0)) // central dir disk
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(centralSize)
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0)) // comment length
        return out
    }

    /// Standard IEEE 802.3 CRC-32.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = max(64, data.count + 64)
        var dst = Data(count: capacity)
        let written: Int = data.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                guard let s = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let d = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        dst.count = written
        return dst
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
