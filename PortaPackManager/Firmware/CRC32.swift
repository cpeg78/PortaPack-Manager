import Foundation

/// CRC-32 in der Variante der Mayhem-Firmware (`crc32 <pfad>`):
/// MSB-first, Polynom 0x04C11DB7, Startwert 0xFFFFFFFF, Ausgabe ⊕ 0xFFFFFFFF.
/// Das ist **nicht** die zlib-Variante (die ist reflektiert); gemeinhin heißt
/// sie CRC-32/BZIP2.
enum MayhemCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var remainder = UInt32(index) << 24
        for _ in 0..<8 {
            remainder = (remainder & 0x8000_0000) != 0
                ? (remainder << 1) ^ 0x04C1_1DB7
                : remainder << 1
        }
        return remainder
    }

    static func checksum(_ data: Data) -> UInt32 {
        var remainder: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                let index = Int((remainder >> 24) ^ UInt32(byte)) & 0xFF
                remainder = (remainder << 8) ^ table[index]
            }
        }
        return remainder ^ 0xFFFF_FFFF
    }
}
