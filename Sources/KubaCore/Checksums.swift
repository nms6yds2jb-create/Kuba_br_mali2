import Foundation

public enum Checksum {
    /// Soma simples de 8 bits.
    public static func sum8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    public static func xor8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 ^ $1 }
    }

    /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF).
    public static func crc16CCITT<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (IEEE 802.3, o mesmo do zip).
    public static func crc32<S: Sequence>(_ bytes: S, seed: UInt32 = 0) -> UInt32 where S.Element == UInt8 {
        var crc = ~seed
        for byte in bytes {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }
}
