import Foundation

/// Bitzeilen eines Pakets, wie rtl_433s `bitbuffer_t`: mehrere Zeilen
/// (Wiederholungen oder Teilpakete), Bits MSB-first in Bytes gepackt.
struct SensorBitBuffer: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        var bytes: [UInt8] = []
        var count = 0
        /// Synchronisierpulse vor dieser Zeile.
        var syncs = 0

        func bit(_ index: Int) -> UInt8 {
            (bytes[index >> 3] >> (7 - UInt8(index & 7))) & 1
        }

        /// Hexdarstellung wie rtl_433: `{36}e2ab5f1c0`.
        var hex: String {
            "{\(count)}" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private(set) var rows: [Row] = []

    var isEmpty: Bool { rows.allSatisfy { $0.count == 0 } }

    mutating func add(_ bit: UInt8) {
        if rows.isEmpty { rows.append(Row()) }
        var row = rows[rows.count - 1]
        if row.count % 8 == 0 { row.bytes.append(0) }
        if bit != 0 { row.bytes[row.count >> 3] |= 0x80 >> UInt8(row.count & 7) }
        row.count += 1
        rows[rows.count - 1] = row
    }

    /// Neue Zeile beginnen (wie `bitbuffer_add_row`).
    mutating func addRow() {
        if rows.isEmpty { rows.append(Row()) }
        rows.append(Row())
    }

    /// Sync-Puls: neue Zeile, falls die aktuelle schon Bits hat.
    mutating func addSync() {
        if rows.isEmpty { rows.append(Row()) }
        if rows[rows.count - 1].count > 0 { rows.append(Row()) }
        rows[rows.count - 1].syncs += 1
    }

    /// Leere Zeilen am Ende entfernen (rtl_433 zählt sie zwar mit, sie
    /// tragen aber nichts bei).
    mutating func trimTrailingEmptyRows() {
        while rows.count > 1, rows[rows.count - 1].count == 0 { rows.removeLast() }
    }

    func inverted() -> SensorBitBuffer {
        var copy = self
        for r in copy.rows.indices {
            for b in copy.rows[r].bytes.indices { copy.rows[r].bytes[b] ^= 0xFF }
            // Bits jenseits des Zeilenendes wieder löschen
            let rest = copy.rows[r].count & 7
            if rest != 0, let last = copy.rows[r].bytes.indices.last {
                copy.rows[r].bytes[last] &= UInt8(0xFF00 >> rest & 0xFF)
            }
        }
        return copy
    }

    /// Erste Zeile mit mindestens `minBits`, die mindestens `minRepeats`-mal
    /// (sich selbst eingeschlossen) identisch vorkommt.
    func repeatedRow(minRepeats: Int, minBits: Int) -> Int? {
        rows.indices.first { i in
            rows[i].count >= minBits && rows.filter { $0.count == rows[i].count && $0.bytes == rows[i].bytes }.count >= minRepeats
        }
    }

    /// Position des Musters (MSB-first, `bits` lang) ab `start`, sonst `nil`.
    func search(row: Int, from start: Int = 0, pattern: [UInt8], bits: Int) -> Int? {
        let r = rows[row]
        guard r.count >= bits else { return nil }
        var position = start
        while position + bits <= r.count {
            var match = true
            for k in 0..<bits where r.bit(position + k) != (pattern[k >> 3] >> (7 - UInt8(k & 7))) & 1 {
                match = false
                break
            }
            if match { return position }
            position += 1
        }
        return nil
    }

    /// `count` Bits ab Bitposition `start` als Bytes (fehlende Bits = 0).
    func extract(row: Int, from start: Int, bits count: Int) -> [UInt8] {
        let r = rows[row]
        var out = [UInt8](repeating: 0, count: (count + 7) / 8)
        for k in 0..<count where start + k < r.count && r.bit(start + k) == 1 {
            out[k >> 3] |= 0x80 >> UInt8(k & 7)
        }
        return out
    }

    /// Aus einer Hexdarstellung `{36}e2ab5f1c0` (für Tests und Nachbauten).
    static func parse(_ text: String) -> SensorBitBuffer {
        var buffer = SensorBitBuffer()
        for token in text.split(separator: " ") {
            guard token.hasPrefix("{"), let close = token.firstIndex(of: "}"),
                  let count = Int(token[token.index(after: token.startIndex)..<close]) else { continue }
            let hex = Array(token[token.index(after: close)...])
            if !buffer.rows.isEmpty { buffer.addRow() }
            for k in 0..<count {
                let nibbleIndex = k / 4
                guard nibbleIndex < hex.count, let nibble = UInt8(String(hex[nibbleIndex]), radix: 16) else {
                    buffer.add(0)
                    continue
                }
                buffer.add((nibble >> (3 - UInt8(k % 4))) & 1)
            }
        }
        return buffer
    }
}

/// Prüfsummen aus rtl_433 (`bit_util.c`), bitgenau nachgebaut.
enum SensorChecksum {
    static func crc4(_ data: [UInt8], polynomial: UInt8, initial: UInt8) -> UInt8 {
        var remainder = UInt32(initial) << 4
        let poly = UInt32(polynomial) << 4
        for byte in data {
            remainder ^= UInt32(byte)
            for _ in 0..<8 {
                remainder = remainder & 0x80 != 0 ? (remainder << 1) ^ poly : remainder << 1
            }
        }
        return UInt8((remainder >> 4) & 0x0F)
    }

    static func crc8(_ data: [UInt8], polynomial: UInt8, initial: UInt8) -> UInt8 {
        var remainder = initial
        for byte in data {
            remainder ^= byte
            for _ in 0..<8 {
                remainder = remainder & 0x80 != 0 ? (remainder << 1) ^ polynomial : remainder << 1
            }
        }
        return remainder
    }

    /// LFSR-Digest, Bytes rückwärts, Bits LSB-first (`lfsr_digest8_reflect`).
    static func lfsrDigest8Reflect(_ data: [UInt8], generator: UInt8, key initialKey: UInt8) -> UInt8 {
        var sum: UInt8 = 0
        var key = initialKey
        for byte in data.reversed() {
            for i in 0..<8 {
                if (byte >> UInt8(i)) & 1 != 0 { sum ^= key }
                key = key & 0x80 != 0 ? (key << 1) ^ generator : key << 1
            }
        }
        return sum
    }

    /// 16-Bit-LFSR-Digest, Bytes vorwärts, Bits MSB-first (`lfsr_digest16`).
    static func lfsrDigest16(_ data: [UInt8], generator: UInt16, key initialKey: UInt16) -> UInt16 {
        var sum: UInt16 = 0
        var key = initialKey
        for byte in data {
            for i in stride(from: 7, through: 0, by: -1) {
                if (byte >> UInt8(i)) & 1 != 0 { sum ^= key }
                key = key & 1 != 0 ? (key >> 1) ^ generator : key >> 1
            }
        }
        return sum
    }

    static func addBytes(_ data: [UInt8]) -> Int {
        data.reduce(0) { $0 + Int($1) }
    }
}
