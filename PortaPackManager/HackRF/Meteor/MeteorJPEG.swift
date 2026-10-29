import Foundation

/// JPEG-ähnliche Kompression der MSU-MR-Bilddaten (APID 64–69): je Paket
/// 14 MCUs zu 8×8 Pixeln, Huffman-Tabellen und Quantisierung wie JPEG
/// (Luminanz, Anhang K), Qualitätsfaktor je Paket, DC-Prädiktion beginnt in
/// jedem Paket bei 0. Nach SatDump `lrpt/segment.cpp`, `huffman.cpp`.
enum MeteorJPEG {
    static let mcusPerSegment = 14
    static let segmentWidth = 8 * mcusPerSegment          // 112 Pixel
    static let segmentsPerLine = 14
    static let lineWidth = segmentWidth * segmentsPerLine  // 1568 Pixel

    /// Standard-Quantisierungstabelle (Luminanz), natürliche Reihenfolge.
    static let baseQuantization: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]

    /// Zickzack-Index → natürliche Position.
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    /// Quantisierung mit Qualitätsfaktor – Formel wie SatDump (für QF < 20
    /// nicht wie IJG, sondern 200 − 2·QF).
    static func quantization(quality qf: Int) -> [Int] {
        let q = Float(qf)
        let f: Float = (q >= 20 && q < 50) ? 5000 / q : 200 - 2 * q
        return baseQuantization.map { max(1, Int(f / 100 * Float($0) + 0.5)) }
    }

    // MARK: Huffman (JPEG Anhang K.3/K.5, gegen SatDump `tables.h` geprüft)

    static let dcBits: [Int] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    static let dcValues: [UInt8] = Array(0...11)
    static let acBits: [Int] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    static let acValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    /// Kanonische Codes: Symbol → (Code, Länge).
    static func codes(bits: [Int], values: [UInt8]) -> [UInt8: (code: Int, length: Int)] {
        var table: [UInt8: (Int, Int)] = [:]
        var code = 0, k = 0
        for length in 1...16 {
            for _ in 0..<bits[length - 1] {
                table[values[k]] = (code, length)
                code += 1
                k += 1
            }
            code <<= 1
        }
        return table
    }

    /// 16-Bit-Nachschlagetabelle: (Symbol << 8 | Länge), 0 = ungültig.
    private static func lookup(bits: [Int], values: [UInt8]) -> [UInt16] {
        var table = [UInt16](repeating: 0, count: 65536)
        for (symbol, entry) in codes(bits: bits, values: values) {
            let shift = 16 - entry.length
            let base = entry.code << shift
            for fill in 0..<(1 << shift) {
                table[base | fill] = UInt16(symbol) << 8 | UInt16(entry.length)
            }
        }
        return table
    }

    static let dcLookup = lookup(bits: dcBits, values: dcValues)
    static let acLookup = lookup(bits: acBits, values: acValues)

    // MARK: IDCT

    /// cos((2x+1)uπ/16)·C(u)/2, [x*8+u].
    private static let idctTable: [Float] = (0..<64).map { i in
        let x = i / 8, u = i % 8
        let c: Double = u == 0 ? 1 / 2.0.squareRoot() : 1
        return Float(c / 2 * cos(Double(2 * x + 1) * Double(u) * .pi / 16))
    }

    /// Inverse 8×8-DCT (Koeffizienten natürlich geordnet) → Pixel 0…255.
    static func inverseDCT(_ coefficients: [Float]) -> [UInt8] {
        var temp = [Float](repeating: 0, count: 64)
        // Zeilen: über v (Spalten der Koeffizienten) zu Pixelspalten y.
        for u in 0..<8 {
            for y in 0..<8 {
                var sum: Float = 0
                for v in 0..<8 { sum += idctTable[y * 8 + v] * coefficients[u * 8 + v] }
                temp[u * 8 + y] = sum
            }
        }
        var out = [UInt8](repeating: 0, count: 64)
        for x in 0..<8 {
            for y in 0..<8 {
                var sum: Float = 0
                for u in 0..<8 { sum += idctTable[x * 8 + u] * temp[u * 8 + y] }
                out[x * 8 + y] = UInt8(max(0, min(255, (sum + 128).rounded())))
            }
        }
        return out
    }

    // MARK: Segment

    /// Ein dekodiertes Bildpaket: 8 Zeilen × 112 Pixel, `decodedMCUs` gültig.
    struct Segment: Sendable {
        var mcuNumber: Int
        var quality: Int
        var pixels: [UInt8]          // 8 × 112, zeilenweise
        var decodedMCUs: Int
    }

    /// Zerlegt die Nutzdaten eines MSU-MR-Pakets (ohne Primärkopf): 8 Byte
    /// Zeit, MCU-Nummer, QT, DC/AC, QFM (0xFFF0), QF, dann Huffman-Daten.
    static func decodeSegment(_ payload: [UInt8]) -> Segment? {
        guard payload.count > 14 else { return nil }
        let mcuNumber = Int(payload[8])
        let qt = payload[9], dcac = payload[10]
        let qfm = Int(payload[11]) << 8 | Int(payload[12])
        let qf = Int(payload[13])
        guard qt == 0, dcac == 0, qfm == 0xFFF0, mcuNumber % mcusPerSegment == 0,
              mcuNumber < mcusPerSegment * segmentsPerLine else { return nil }
        let table = quantization(quality: qf)
        var reader = BitReader(bytes: Array(payload[14...]))
        var pixels = [UInt8](repeating: 0, count: 8 * segmentWidth)
        var dc = 0
        var decoded = 0
        mcuLoop: for m in 0..<mcusPerSegment {
            var zz = [Int](repeating: 0, count: 64)
            guard let category = reader.huffman(dcLookup), category <= 11,
                  let diff = reader.signed(Int(category)) else { break }
            dc += diff
            zz[0] = dc
            var k = 1
            while k < 64 {
                guard let symbol = reader.huffman(acLookup) else { break mcuLoop }
                let run = Int(symbol >> 4), size = Int(symbol & 0x0F)
                if size == 0 {
                    if run == 15 { k += 16; continue }
                    break                                // EOB
                }
                k += run
                guard let value = reader.signed(size) else { break mcuLoop }
                if k > 63 { break }
                zz[k] = value
                k += 1
            }
            var coefficients = [Float](repeating: 0, count: 64)
            for z in 0..<64 where zz[z] != 0 {
                let position = zigzag[z]
                coefficients[position] = Float(zz[z] * table[position])
            }
            let block = inverseDCT(coefficients)
            for row in 0..<8 {
                for col in 0..<8 { pixels[row * segmentWidth + m * 8 + col] = block[row * 8 + col] }
            }
            decoded += 1
        }
        guard decoded > 0 else { return nil }
        return Segment(mcuNumber: mcuNumber, quality: qf, pixels: pixels, decodedMCUs: decoded)
    }

    /// Liest Bits MSB zuerst.
    struct BitReader {
        let bytes: [UInt8]
        var position = 0
        var bitCount: Int { bytes.count * 8 }

        func peek16() -> Int {
            var v = 0
            for i in 0..<16 {
                let p = position + i
                let bit = p < bitCount ? Int(bytes[p >> 3] >> (7 - UInt8(p & 7)) & 1) : 0
                v = v << 1 | bit
            }
            return v
        }

        mutating func huffman(_ table: [UInt16]) -> UInt8? {
            guard position < bitCount else { return nil }
            let entry = table[peek16()]
            let length = Int(entry & 0xFF)
            guard length > 0, position + length <= bitCount else { return nil }
            position += length
            return UInt8(entry >> 8)
        }

        mutating func bits(_ n: Int) -> Int? {
            guard position + n <= bitCount else { return nil }
            var v = 0
            for _ in 0..<n {
                v = v << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
                position += 1
            }
            return v
        }

        /// JPEG-„Extend“: führende 0 heißt negativ.
        mutating func signed(_ n: Int) -> Int? {
            guard n > 0 else { return 0 }
            guard let v = bits(n) else { return nil }
            return v < (1 << (n - 1)) ? v - (1 << n) + 1 : v
        }
    }
}
