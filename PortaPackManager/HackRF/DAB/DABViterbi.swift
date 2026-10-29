import Foundation

/// Faltungscode von DAB (EN 300 401 §11.1.1): Einflusslänge 7, Mutter-Code
/// Rate 1/4 mit den Polynomen 133, 171, 145, 133 (oktal). Nach den Nutzbits
/// folgen sechs Nullbits, die das Register leeren.
///
/// Weiche Bits: positiv heißt „0“, negativ „1“, 0 heißt „unbekannt“
/// (punktiert). Der Betrag ist die Zuverlässigkeit (bis ±127).
enum DABConvolutionalCode {
    static let polynomials: [Int] = [0o133, 0o171, 0o145, 0o133]
    static let tailBits = 6

    /// Ausgangssymbol (x0 x1 x2 x3 als 4-Bit-Zahl, x0 oben) für ein
    /// 7-Bit-Register (neues Bit in Bit 6, ältestes in Bit 0).
    static func symbol(register: Int) -> Int {
        var symbol = 0
        for poly in polynomials {
            symbol = symbol << 1 | ((register & poly).nonzeroBitCount & 1)
        }
        return symbol
    }

    /// Kodiert Bits (0/1) zum unpunktierten Mutter-Codewort ((n + 6) · 4 Bits).
    static func encode(_ bits: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((bits.count + tailBits) * 4)
        var state = 0
        for bit in bits + [UInt8](repeating: 0, count: tailBits) {
            let register = Int(bit) << 6 | state
            let symbol = Self.symbol(register: register)
            for j in stride(from: 3, through: 0, by: -1) { out.append(UInt8(symbol >> j & 1)) }
            state = register >> 1
        }
        return out
    }
}

/// Punktierung nach EN 300 401 §11: Folgen aus (Anzahl 128-Bit-Blöcke,
/// Punktierungsvektor), danach die 24 Schlussbits mit PI_X.
struct DABPuncturing: Sendable {
    /// (Blöcke zu 128 Mutter-Bits, Vektor-Index 1…24).
    let segments: [(blocks: Int, vector: Int)]

    var motherBits: Int { segments.reduce(0) { $0 + $1.blocks * 128 } + 24 }

    var transmittedBits: Int {
        var count = 0
        for (blocks, vector) in segments {
            count += blocks * 4 * DABTables.punctureVectors[vector - 1].filter { $0 }.count
        }
        return count + DABTables.tailPuncture.filter { $0 }.count
    }

    /// Nutzbits des Codeworts (Mutter-Bits / 4 − 6).
    var dataBits: Int { motherBits / 4 - DABConvolutionalCode.tailBits }

    /// Setzt die empfangenen weichen Bits an ihre Stelle im Mutter-Code; die
    /// punktierten Stellen bleiben 0.
    func depuncture(_ input: UnsafeBufferPointer<Int16>) -> [Int16] {
        var out = [Int16](repeating: 0, count: motherBits)
        var read = 0
        var write = 0
        out.withUnsafeMutableBufferPointer { o in
            for (blocks, vector) in segments {
                let pattern = DABTables.punctureVectors[vector - 1]
                for _ in 0..<blocks {
                    for j in 0..<128 {
                        if pattern[j & 31] {
                            if read < input.count { o[write] = input[read] }
                            read += 1
                        }
                        write += 1
                    }
                }
            }
            for keep in DABTables.tailPuncture {
                if keep {
                    if read < input.count { o[write] = input[read] }
                    read += 1
                }
                write += 1
            }
        }
        return out
    }

    /// Gegenstück für Tests: entfernt die punktierten Bits.
    func puncture(_ mother: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        for (blocks, vector) in segments {
            let pattern = DABTables.punctureVectors[vector - 1]
            for _ in 0..<blocks {
                for j in 0..<128 {
                    if pattern[j & 31] { out.append(mother[index]) }
                    index += 1
                }
            }
        }
        for keep in DABTables.tailPuncture {
            if keep { out.append(mother[index]) }
            index += 1
        }
        return out
    }

    /// FIC: 21 Blöcke mit PI_16, 3 mit PI_15 (2304 → 768 Bits).
    static let fic = DABPuncturing(segments: [(21, 16), (3, 15)])

    /// EEP-A/B für einen Unterkanal (§11.3.2). `bitrate` in kbit/s.
    /// `nil` bei Bitrate 0 bzw. negativen Blockzahlen – ein Unterkanal mit
    /// 1–11 CU aus FIG 0/1 ergäbe sonst `0..<-3` (Funkrahmen aus der Luft –
    /// sonst Absturz).
    static func eep(profileB: Bool, level: Int, bitrate n: Int) -> DABPuncturing? {
        guard n > 0, let puncturing = eepUnchecked(profileB: profileB, level: level, bitrate: n),
              puncturing.isValid else { return nil }
        return puncturing
    }

    /// Alle Blockzahlen ≥ 0, Vektoren 1…24.
    var isValid: Bool {
        segments.allSatisfy { $0.blocks >= 0 && (1...DABTables.punctureVectors.count).contains($0.vector) }
    }

    private static func eepUnchecked(profileB: Bool, level: Int, bitrate n: Int) -> DABPuncturing? {
        if !profileB {
            switch level {
            case 1: return DABPuncturing(segments: [(6 * n / 8 - 3, 24), (3, 23)])
            case 2:
                if n == 8 { return DABPuncturing(segments: [(5, 13), (1, 12)]) }
                return DABPuncturing(segments: [(2 * n / 8 - 3, 14), (4 * n / 8 + 3, 13)])
            case 3: return DABPuncturing(segments: [(6 * n / 8 - 3, 8), (3, 7)])
            case 4: return DABPuncturing(segments: [(4 * n / 8 - 3, 3), (2 * n / 8 + 3, 2)])
            default: return nil
            }
        }
        let vectors = [1: (10, 9), 2: (6, 5), 3: (4, 3), 4: (2, 1)]
        guard let (pi1, pi2) = vectors[level] else { return nil }
        return DABPuncturing(segments: [(24 * n / 32 - 3, pi1), (3, pi2)])
    }

    /// UEP (Kurzform) nach Tabellenindex der FIG 0/1.
    static func uep(bitrate: Int, level: Int) -> DABPuncturing? {
        guard let profile = DABTables.uepProfiles.first(where: { $0.bitrate == bitrate && $0.level == level }) else { return nil }
        var segments: [(Int, Int)] = []
        for (l, pi) in zip(profile.l, profile.pi) where l > 0 && pi > 0 { segments.append((l, pi)) }
        let puncturing = DABPuncturing(segments: segments)
        return puncturing.isValid ? puncturing : nil
    }
}

/// Viterbi-Dekoder mit weichen Eingängen und ganzzahligen Metriken.
final class DABViterbi: @unchecked Sendable {
    /// Ausgangssymbole der beiden Vorgänger je Folgezustand.
    private let symbolFrom0: [UInt8]
    private let symbolFrom1: [UInt8]
    private var decisions: [UInt64] = []

    init() {
        var s0 = [UInt8](repeating: 0, count: 64)
        var s1 = [UInt8](repeating: 0, count: 64)
        for next in 0..<64 {
            let input = next >> 5
            let predecessor = (next << 1) & 63
            s0[next] = UInt8(DABConvolutionalCode.symbol(register: input << 6 | predecessor))
            s1[next] = UInt8(DABConvolutionalCode.symbol(register: input << 6 | predecessor | 1))
        }
        symbolFrom0 = s0
        symbolFrom1 = s1
    }

    /// Dekodiert `(bits + 6) · 4` weiche Mutter-Bits zu `bits` Nutzbits.
    func decode(_ soft: [Int16], bits: Int) -> [UInt8] {
        let steps = bits + DABConvolutionalCode.tailBits
        precondition(soft.count >= steps * 4)
        if decisions.count < steps { decisions = [UInt64](repeating: 0, count: steps) }

        var metric = [Int32](repeating: -1_000_000, count: 64)
        var next = [Int32](repeating: 0, count: 64)
        metric[0] = 0
        var branch = [Int32](repeating: 0, count: 16)

        soft.withUnsafeBufferPointer { input in
            symbolFrom0.withUnsafeBufferPointer { sym0 in
                symbolFrom1.withUnsafeBufferPointer { sym1 in
                    decisions.withUnsafeMutableBufferPointer { decision in
                        for t in 0..<steps {
                            let a = Int32(input[4 * t]), b = Int32(input[4 * t + 1])
                            let c = Int32(input[4 * t + 2]), d = Int32(input[4 * t + 3])
                            // Zweigmetrik: +weich bei erwarteter 0, −weich bei 1.
                            for symbol in 0..<16 {
                                branch[symbol] = (symbol & 8 == 0 ? a : -a) + (symbol & 4 == 0 ? b : -b)
                                    + (symbol & 2 == 0 ? c : -c) + (symbol & 1 == 0 ? d : -d)
                            }
                            var word: UInt64 = 0
                            for state in 0..<64 {
                                let p0 = (state << 1) & 63
                                let m0 = metric[p0] + branch[Int(sym0[state])]
                                let m1 = metric[p0 | 1] + branch[Int(sym1[state])]
                                if m1 > m0 {
                                    next[state] = m1
                                    word |= 1 << UInt64(state)
                                } else {
                                    next[state] = m0
                                }
                            }
                            decision[t] = word
                            swap(&metric, &next)
                        }
                    }
                }
            }
        }

        // Rückverfolgung ab Zustand 0 (das Register endet leer).
        var out = [UInt8](repeating: 0, count: bits)
        var state = 0
        for t in stride(from: steps - 1, through: 0, by: -1) {
            if t < bits { out[t] = UInt8(state >> 5) }
            let chosen = Int(decisions[t] >> UInt64(state) & 1)
            state = ((state << 1) & 63) | chosen
        }
        return out
    }
}

/// Bits ↔ Bytes (MSB zuerst).
enum DABBits {
    static func pack(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bits.count / 8)
        for i in 0..<out.count {
            var value: UInt8 = 0
            for j in 0..<8 { value = value << 1 | (bits[8 * i + j] & 1) }
            out[i] = value
        }
        return out
    }

    static func unpack(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for j in stride(from: 7, through: 0, by: -1) { out.append(byte >> UInt8(j) & 1) }
        }
        return out
    }
}
