import Foundation

/// Kanalkodierung von LoRa (Semtech SX127x/SX126x), Bit für Bit nach
/// gr-lora_sdr (tapparelj): Whitening, expliziter Kopf mit Prüfsumme,
/// Hamming-Kodes, diagonaler Interleaver, Gray-Abbildung und CRC-16.
///
/// Zählweise wie in gr-lora_sdr: `codingRate` 1…4 steht für 4/5…4/8.
enum LoRaCoding {
    // MARK: - Whitening

    /// Whitening-Folge (LFSR x⁸ + x⁶ + x⁵ + x⁴ + 1, Start 0xFF) – identisch
    /// mit der Tabelle `whitening_seq` in gr-lora_sdr. Gilt nur für die
    /// Nutzdaten, nicht für Kopf und CRC.
    static let whiteningSequence: [UInt8] = {
        var state: UInt8 = 0xFF
        var sequence: [UInt8] = []
        sequence.reserveCapacity(256)
        for _ in 0..<256 {
            sequence.append(state)
            let bit = ((state >> 7) ^ (state >> 5) ^ (state >> 4) ^ (state >> 3)) & 1
            state = (state << 1) | bit
        }
        return sequence
    }()

    /// Whitening ist ein XOR – Hin- und Rückweg sind gleich.
    static func whiten(_ bytes: [UInt8]) -> [UInt8] {
        bytes.enumerated().map { $0.element ^ whiteningSequence[$0.offset % whiteningSequence.count] }
    }

    // MARK: - CRC

    /// Nutzdaten-CRC wie im LoRa-Chip: CRC-16/CCITT (0x1021, Start 0) über
    /// alle Bytes bis auf die letzten zwei, danach mit diesen beiden
    /// verknüpft. Übertragen wird das niedrige Byte zuerst.
    static func payloadCRC(_ payload: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        let body = payload.count >= 2 ? payload.count - 2 : 0
        for byte in payload.prefix(body) {
            var data = byte
            for _ in 0..<8 {
                if ((crc & 0x8000) >> 8) ^ UInt16(data & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
                data <<= 1
            }
        }
        if payload.count >= 2 {
            crc ^= UInt16(payload[payload.count - 1]) ^ (UInt16(payload[payload.count - 2]) << 8)
        } else if let only = payload.first {
            crc ^= UInt16(only)
        }
        return crc
    }

    // MARK: - Kopf

    /// Die fünf Kopf-Nibbles: Länge (hoch, niedrig), Koderate und CRC-Flag,
    /// Prüfsumme (1 + 4 Bit).
    static func headerNibbles(length: Int, codingRate: Int, hasCRC: Bool) -> [UInt8] {
        let n0 = UInt8(length >> 4 & 0x0F), n1 = UInt8(length & 0x0F)
        let n2 = UInt8(codingRate << 1) | (hasCRC ? 1 : 0)
        return [n0, n1, n2] + headerChecksum(n0, n1, n2)
    }

    /// Prüfsumme des expliziten Kopfs (gr-lora_sdr `header_impl.cc`).
    static func headerChecksum(_ h0: UInt8, _ h1: UInt8, _ h2: UInt8) -> [UInt8] {
        func b(_ n: UInt8, _ bit: Int) -> UInt8 { (n >> UInt8(bit)) & 1 }
        let c4 = b(h0, 3) ^ b(h0, 2) ^ b(h0, 1) ^ b(h0, 0)
        let c3 = b(h0, 3) ^ b(h1, 3) ^ b(h1, 2) ^ b(h1, 1) ^ b(h2, 0)
        let c2 = b(h0, 2) ^ b(h1, 3) ^ b(h1, 0) ^ b(h2, 3) ^ b(h2, 1)
        let c1 = b(h0, 1) ^ b(h1, 2) ^ b(h1, 0) ^ b(h2, 2) ^ b(h2, 1) ^ b(h2, 0)
        let c0 = b(h0, 0) ^ b(h1, 1) ^ b(h2, 3) ^ b(h2, 2) ^ b(h2, 1) ^ b(h2, 0)
        return [c4, c3 << 3 | c2 << 2 | c1 << 1 | c0]
    }

    struct Header: Equatable, Sendable {
        var length: Int
        var codingRate: Int
        var hasCRC: Bool
    }

    /// Prüft und liest den Kopf aus den ersten fünf Nibbles.
    static func parseHeader(_ nibbles: [UInt8]) -> Header? {
        guard nibbles.count >= 5 else { return nil }
        let check = headerChecksum(nibbles[0], nibbles[1], nibbles[2])
        guard check[0] == nibbles[3] & 0x01, check[1] == nibbles[4] & 0x0F else { return nil }
        let length = Int(nibbles[0]) << 4 | Int(nibbles[1])
        let codingRate = Int(nibbles[2] >> 1)
        guard length > 0, (1...4).contains(codingRate) else { return nil }
        return Header(length: length, codingRate: codingRate, hasCRC: nibbles[2] & 1 == 1)
    }

    // MARK: - Hamming

    /// Kodewort mit 4 + `codingRate` Bits. Das höchste Bit ist Datenbit 0.
    static func hammingEncode(_ nibble: UInt8, codingRate: Int) -> UInt8 {
        let b0 = nibble & 1, b1 = nibble >> 1 & 1, b2 = nibble >> 2 & 1, b3 = nibble >> 3 & 1
        if codingRate == 1 {
            return b0 << 4 | b1 << 3 | b2 << 2 | b3 << 1 | (b0 ^ b1 ^ b2 ^ b3)
        }
        let p0 = b0 ^ b1 ^ b2, p1 = b1 ^ b2 ^ b3, p2 = b0 ^ b1 ^ b3, p3 = b0 ^ b2 ^ b3
        let full = b0 << 7 | b1 << 6 | b2 << 5 | b3 << 4 | p0 << 3 | p1 << 2 | p2 << 1 | p3
        return full >> UInt8(4 - codingRate)
    }

    /// Alle 16 Kodewörter je Koderate, für die Dekodierung nach kleinstem Abstand.
    private static let codebooks: [[UInt8]] = (0...4).map { cr in
        cr == 0 ? [] : (0..<16).map { hammingEncode(UInt8($0), codingRate: cr) }
    }

    /// Dekodiert ein Kodewort. 4/7 und 4/8 korrigieren einen Bitfehler,
    /// 4/5 und 4/6 erkennen nur (dann werden die Datenbits direkt genommen).
    /// `corrected` meldet, ob das Kodewort nicht fehlerfrei war.
    static func hammingDecode(_ codeword: UInt8, codingRate: Int) -> (nibble: UInt8, corrected: Bool) {
        let length = 4 + codingRate
        if codingRate >= 3 {
            var best = 0, bestDistance = Int.max
            for (value, word) in codebooks[codingRate].enumerated() {
                let distance = (word ^ codeword).nonzeroBitCount
                if distance < bestDistance { best = value; bestDistance = distance }
            }
            return (UInt8(best), bestDistance > 0)
        }
        var nibble: UInt8 = 0
        for k in 0..<4 { nibble |= (codeword >> UInt8(length - 1 - k) & 1) << UInt8(k) }
        return (nibble, codebooks[codingRate][Int(nibble)] != codeword)
    }

    // MARK: - Interleaver und Gray

    /// Diagonaler Interleaver eines Blocks: `codewords` (`rows` Stück zu je
    /// `cwLength` Bits) → `cwLength` Symbolwerte mit `sf` Bits (vor der
    /// Gray-Abbildung). `reduced`: nur sf − 2 Bits je Symbol, dahinter ein
    /// Paritätsbit und eine 0 (Kopfblock und Low-Data-Rate-Optimierung).
    static func interleave(_ codewords: [UInt8], cwLength: Int, sf: Int, reduced: Bool) -> [Int] {
        let rows = reduced ? sf - 2 : sf
        let words = codewords + Array(repeating: 0, count: max(0, rows - codewords.count))
        return (0..<cwLength).map { i in
            var value = 0, parity = 0
            for j in 0..<rows {
                let word = words[((i - j - 1) % rows + rows) % rows]
                let bit = Int(word >> UInt8(cwLength - 1 - i) & 1)
                value = value << 1 | bit
                parity ^= bit
            }
            return reduced ? (value << 2 | parity << 1) : value
        }
    }

    /// Umkehrung: `cwLength` Werte mit je `rows` Bits → `rows` Kodewörter.
    static func deinterleave(_ values: [Int], cwLength: Int, rows: Int) -> [UInt8] {
        var words = [UInt8](repeating: 0, count: rows)
        for i in 0..<cwLength {
            for j in 0..<rows {
                let bit = UInt8(values[i] >> (rows - 1 - j) & 1)
                let row = ((i - j - 1) % rows + rows) % rows
                words[row] |= bit << UInt8(cwLength - 1 - i)
            }
        }
        return words
    }

    /// Sender: Symbolwert → Chirp-Verschiebung (inverses Gray, dann +1).
    static func symbolForValue(_ value: Int, sf: Int) -> Int {
        var binary = value, shift = value >> 1
        while shift != 0 {
            binary ^= shift
            shift >>= 1
        }
        return (binary + 1) & ((1 << sf) - 1)
    }

    /// Empfänger: FFT-Spitze → Symbolwert mit `sf` bzw. sf − 2 Bits.
    static func valueForSymbol(_ bin: Int, sf: Int, reduced: Bool) -> Int {
        var s = (bin - 1) & ((1 << sf) - 1)
        if reduced { s >>= 2 }
        return s ^ (s >> 1)
    }

    // MARK: - Rahmen

    /// Anzahl Symbole nach der Präambel (Kopfblock + Nutzdatenblöcke).
    static func symbolCount(length: Int, codingRate: Int, hasCRC: Bool, sf: Int, lowDataRate: Bool) -> Int {
        let nibbles = 5 + 2 * length + (hasCRC ? 4 : 0)
        let rest = max(0, nibbles - (sf - 2))
        let perBlock = lowDataRate ? sf - 2 : sf
        return 8 + (rest + perBlock - 1) / perBlock * (4 + codingRate)
    }

    /// Kodiert Nutzdaten zu Symbolen (Sendeseite, für Tests und Prüfungen).
    static func encode(_ payload: [UInt8], sf: Int, codingRate: Int, hasCRC: Bool = true,
                       lowDataRate: Bool = false) -> [Int] {
        let white = whiten(payload)
        var nibbles = headerNibbles(length: payload.count, codingRate: codingRate, hasCRC: hasCRC)
        for byte in white { nibbles += [byte & 0x0F, byte >> 4] }
        if hasCRC {
            let crc = payloadCRC(payload)
            nibbles += [UInt8(crc & 0xF), UInt8(crc >> 4 & 0xF), UInt8(crc >> 8 & 0xF), UInt8(crc >> 12 & 0xF)]
        }
        var symbols: [Int] = []
        var index = 0
        var first = true
        while index < nibbles.count {
            let reduced = first || lowDataRate
            let rows = reduced ? sf - 2 : sf
            let cr = first ? 4 : codingRate
            let block = nibbles[index..<min(index + rows, nibbles.count)]
            let words = block.map { hammingEncode($0, codingRate: cr) }
            let values = interleave(words, cwLength: 4 + cr, sf: sf, reduced: reduced)
            symbols += values.map { symbolForValue($0, sf: sf) }
            index += rows
            first = false
        }
        return symbols
    }
}
