import Foundation

// Kanalkodierung nach 36.212: CRC, Faltungscode mit Tail-biting-Viterbi,
// Turbo-Code (QPP-Verschachteler, Max-Log-MAP) und Ratenanpassung.

/// Zyklische Prüfsummen (36.212 5.1.1), MSB zuerst, Startwert 0.
enum LTECRC {
    static let crc24A: UInt32 = 0x864CFB
    static let crc24B: UInt32 = 0x800063
    static let crc16: UInt32 = 0x1021

    static func compute(_ bits: ArraySlice<UInt8>, poly: UInt32, length: Int) -> UInt32 {
        let mask: UInt32 = length == 32 ? .max : (1 << UInt32(length)) - 1
        var crc: UInt32 = 0
        for bit in bits {
            let feedback = ((crc >> UInt32(length - 1)) & 1) ^ UInt32(bit & 1)
            crc = (crc << 1) & mask
            if feedback == 1 { crc ^= poly }
        }
        return crc
    }

    static func compute(_ bits: [UInt8], poly: UInt32, length: Int) -> UInt32 {
        compute(bits[...], poly: poly, length: length)
    }

    /// Hängt die Prüfsumme an; `mask` (z. B. RNTI, Antennenmaske) wird MSB-zuerst aufaddiert.
    static func attach(_ bits: [UInt8], poly: UInt32, length: Int, mask: UInt32 = 0) -> [UInt8] {
        let crc = compute(bits, poly: poly, length: length) ^ mask
        return bits + (0..<length).map { UInt8((crc >> UInt32(length - 1 - $0)) & 1) }
    }

    /// Prüft Nutzbits + angehängte Prüfsumme (mit Maske).
    static func check(_ bits: [UInt8], poly: UInt32, length: Int, mask: UInt32 = 0) -> Bool {
        guard bits.count > length else { return false }
        let payload = bits.count - length
        var received: UInt32 = 0
        for i in 0..<length { received = (received << 1) | UInt32(bits[payload + i] & 1) }
        return compute(bits[..<payload], poly: poly, length: length) ^ mask == received
    }
}

/// Faltungscode mit Tail-biting (36.212 5.1.3.1): Rate 1/3, Einflusslänge 7,
/// G0 = 133, G1 = 171, G2 = 165 (oktal).
enum LTEConvolutional {
    /// Ausgangsbits je (Zustand, Eingang): Zustand Bit j = c(k−1−j).
    private static let outputs: [UInt8] = {
        let generators = [0o133, 0o171, 0o165]
        var table = [UInt8](repeating: 0, count: 128)
        for state in 0..<64 {
            for u in 0..<2 {
                var out: UInt8 = 0
                for (i, g) in generators.enumerated() {
                    // Abgriff D^j: Bit (6 − j) des Generators.
                    var bit = ((g >> 6) & 1) & u
                    for j in 1...6 { bit ^= ((g >> (6 - j)) & 1) & ((state >> (j - 1)) & 1) }
                    out |= UInt8(bit) << UInt8(i)
                }
                table[state * 2 + u] = out
            }
        }
        return table
    }()

    /// Kodiert `c` (Tail-biting: Register mit den letzten sechs Bits vorbelegt) → drei Ströme.
    static func encode(_ c: [UInt8]) -> [[UInt8]] {
        let k = c.count
        var state = 0
        for j in 0..<6 { state |= Int(c[(k - 1 - j + 6 * k) % k] & 1) << j }
        var d: [[UInt8]] = Array(repeating: [UInt8](repeating: 0, count: k), count: 3)
        for n in 0..<k {
            let u = Int(c[n] & 1)
            let out = outputs[state * 2 + u]
            for i in 0..<3 { d[i][n] = (out >> UInt8(i)) & 1 }
            state = ((state << 1) | u) & 63
        }
        return d
    }

    /// Tail-biting-Viterbi über die zyklisch verlängerte Folge. `d`: drei
    /// Ströme weicher Bits (positiv = 0) der Länge K.
    static func decode(_ d: [[Float]]) -> [UInt8] {
        let k = d[0].count
        guard k > 0 else { return [] }
        let wrap = min(k, 64)
        let steps = k + 2 * wrap
        var metric = [Float](repeating: 0, count: 64)
        var next = [Float](repeating: 0, count: 64)
        var decisions = [UInt8](repeating: 0, count: steps * 64)
        // Zweigmetrik je 3-Bit-Muster vorab je Schritt.
        var branch = [Float](repeating: 0, count: 8)
        for t in 0..<steps {
            let n = ((t - wrap) % k + k) % k
            let l0 = d[0][n], l1 = d[1][n], l2 = d[2][n]
            for pattern in 0..<8 {
                branch[pattern] = (pattern & 1 == 0 ? l0 : -l0) + (pattern & 2 == 0 ? l1 : -l1) + (pattern & 4 == 0 ? l2 : -l2)
            }
            for ns in 0..<64 {
                let u = ns & 1
                let p0 = ns >> 1, p1 = (ns >> 1) | 32
                let m0 = metric[p0] + branch[Int(outputs[p0 * 2 + u])]
                let m1 = metric[p1] + branch[Int(outputs[p1 * 2 + u])]
                if m1 > m0 {
                    next[ns] = m1
                    decisions[t * 64 + ns] = 1
                } else {
                    next[ns] = m0
                    decisions[t * 64 + ns] = 0
                }
            }
            // Normieren, damit Float nicht wegläuft.
            let top = next.max() ?? 0
            for s in 0..<64 { metric[s] = next[s] - top }
        }
        var state = metric.indices.max { metric[$0] < metric[$1] } ?? 0
        var bits = [UInt8](repeating: 0, count: steps)
        for t in stride(from: steps - 1, through: 0, by: -1) {
            bits[t] = UInt8(state & 1)
            state = (state >> 1) | (Int(decisions[t * 64 + state]) << 5)
        }
        return Array(bits[wrap..<(wrap + k)])
    }
}

/// Ratenanpassung (36.212 5.1.4): Teilblock-Verschachteler mit 32 Spalten,
/// Ringpuffer, Bitauswahl.
enum LTERateMatching {
    /// Spaltenvertauschung für Faltungscodes (Tabelle 5.1.4-2), auch PDCCH-Quadrupel.
    static let permutation: [Int] = [1, 17, 9, 25, 5, 21, 13, 29, 3, 19, 11, 27, 7, 23, 15, 31,
                                     0, 16, 8, 24, 4, 20, 12, 28, 2, 18, 10, 26, 6, 22, 14, 30]
    /// Spaltenvertauschung für Turbo-Codes (Tabelle 5.1.4-1).
    static let turboPermutation: [Int] = [0, 16, 8, 24, 4, 20, 12, 28, 2, 18, 10, 26, 6, 22, 14, 30,
                                          1, 17, 9, 25, 5, 21, 13, 29, 3, 19, 11, 27, 7, 23, 15, 31]

    /// Für jeden Platz des verschachtelten Teilblocks die Herkunft in d (−1 = Leerstelle).
    static func subblock(length d: Int, turbo: Bool = false, thirdTurboStream: Bool = false) -> [Int] {
        let rows = (d + 31) / 32
        let kPi = rows * 32
        let dummy = kPi - d
        let p = turbo ? turboPermutation : permutation
        var out = [Int](repeating: -1, count: kPi)
        for k in 0..<kPi {
            let y: Int
            if thirdTurboStream {
                y = (p[k / rows] + 32 * (k % rows) + 1) % kPi
            } else {
                y = p[k / rows] + 32 * (k % rows)
            }
            out[k] = y < dummy ? -1 : y - dummy
        }
        return out
    }

    /// Ringpuffer des Faltungscodes: v0 ∥ v1 ∥ v2; Werte = Strom·D + Index.
    static func convolutionalBuffer(length d: Int) -> [Int] {
        let v = subblock(length: d)
        return (0..<3).flatMap { stream in v.map { $0 < 0 ? -1 : stream * d + $0 } }
    }

    /// Ringpuffer des Turbo-Codes: v0, dann v1/v2 verzahnt. `filler` Füllbits
    /// am Anfang von d0/d1 gelten als Leerstellen.
    static func turboBuffer(length d: Int, filler: Int = 0) -> [Int] {
        let v0 = subblock(length: d, turbo: true), v2 = subblock(length: d, turbo: true, thirdTurboStream: true)
        let kPi = v0.count
        var w = [Int](repeating: -1, count: 3 * kPi)
        for k in 0..<kPi {
            w[k] = v0[k] < filler ? -1 : v0[k]
            w[kPi + 2 * k] = v0[k] < filler ? -1 : d + v0[k]
            w[kPi + 2 * k + 1] = v2[k] < 0 ? -1 : 2 * d + v2[k]
        }
        return w
    }

    /// Startpunkt k0 für die Redundanzversion (Ncb = Kw).
    static func turboStart(length d: Int, rv: Int) -> Int {
        let rows = (d + 31) / 32
        let ncb = 3 * rows * 32
        return rows * (2 * Int((Double(ncb) / Double(8 * rows)).rounded(.up)) * rv + 2)
    }

    /// Herkunft der `e` ausgewählten Bits.
    static func select(_ buffer: [Int], count e: Int, start k0: Int = 0) -> [Int] {
        guard buffer.contains(where: { $0 >= 0 }) else { return [] }
        var out: [Int] = []
        out.reserveCapacity(e)
        var j = 0
        while out.count < e {
            let index = buffer[(k0 + j) % buffer.count]
            if index >= 0 { out.append(index) }
            j += 1
        }
        return out
    }

    // MARK: Faltungscode (PBCH, PDCCH)

    static func convolutionalEncode(_ c: [UInt8], count e: Int) -> [UInt8] {
        let d = LTEConvolutional.encode(c)
        let flat = d.flatMap { $0 }
        return select(convolutionalBuffer(length: c.count), count: e).map { flat[$0] }
    }

    /// Weiche Bits aufsammeln (Wiederholungen addieren) → drei Ströme der Länge K.
    static func convolutionalDematch(_ llr: [Float], k: Int) -> [[Float]] {
        var acc = [Float](repeating: 0, count: 3 * k)
        accumulateConvolutional(llr, k: k, into: &acc)
        return (0..<3).map { Array(acc[($0 * k)..<($0 * k + k)]) }
    }

    static func accumulateConvolutional(_ llr: [Float], k: Int, into acc: inout [Float]) {
        let order = select(convolutionalBuffer(length: k), count: llr.count)
        for (i, index) in order.enumerated() { acc[index] += llr[i] }
    }

    // MARK: Turbo-Code (PDSCH)

    static func turboEncode(_ d: [[UInt8]], count e: Int, rv: Int, filler: Int = 0) -> [UInt8] {
        let length = d[0].count
        let flat = d.flatMap { $0 }
        return select(turboBuffer(length: length, filler: filler), count: e, start: turboStart(length: length, rv: rv)).map { flat[$0] }
    }

    /// Weiche Bits in den Puffer (3 × D) addieren – mehrere Übertragungen kombinierbar.
    static func accumulateTurbo(_ llr: [Float], length d: Int, rv: Int, filler: Int = 0, into acc: inout [Float]) {
        let order = select(turboBuffer(length: d, filler: filler), count: llr.count, start: turboStart(length: d, rv: rv))
        for (i, index) in order.enumerated() { acc[index] += llr[i] }
    }
}

/// Turbo-Code (36.212 5.1.3.2): zwei RSC-Kodierer (g0 = 13, g1 = 15 oktal)
/// und QPP-Verschachteler; Dekoder Max-Log-MAP mit skaliertem Extrinsic.
enum LTETurbo {
    /// Blockgrößen K (Tabelle 5.1.3-3).
    static let blockSizes: [Int] = Array(stride(from: 40, through: 512, by: 8)) + Array(stride(from: 528, through: 1024, by: 16))
        + Array(stride(from: 1056, through: 2048, by: 32)) + Array(stride(from: 2112, through: 6144, by: 64))

    /// Parameter f1/f2 des QPP-Verschachtelers (Tabelle 5.1.3-3).
    static let f1: [Int] = [
        3, 7, 19, 7, 7, 11, 5, 11, 7, 41, 103, 15, 9, 17, 9, 21, 101, 21, 57, 23, 13, 27, 11, 27, 85, 29, 33, 15, 17,
        33, 103, 19, 19, 37, 19, 21, 21, 115, 193, 21, 133, 81, 45, 23, 243, 151, 155, 25, 51, 47, 91, 29, 29, 247,
        29, 89, 91, 157, 55, 31, 17, 35, 227, 65, 19, 37, 41, 39, 185, 43, 21, 155, 79, 139, 23, 217, 25, 17, 127,
        25, 239, 17, 137, 215, 29, 15, 147, 29, 59, 65, 55, 31, 17, 171, 67, 35, 19, 39, 19, 199, 21, 211, 21, 43,
        149, 45, 49, 71, 13, 17, 25, 183, 55, 127, 27, 29, 29, 57, 45, 31, 59, 185, 113, 31, 17, 171, 209, 253, 367,
        265, 181, 39, 27, 127, 143, 43, 29, 45, 157, 47, 13, 111, 443, 51, 51, 451, 257, 57, 313, 271, 179, 331, 363,
        375, 127, 31, 33, 43, 33, 477, 35, 233, 357, 337, 37, 71, 71, 37, 39, 127, 39, 39, 31, 113, 41, 251, 43, 21,
        43, 45, 45, 161, 89, 323, 47, 23, 47, 263
    ]
    static let f2: [Int] = [
        10, 12, 42, 16, 18, 20, 22, 24, 26, 84, 90, 32, 34, 108, 38, 120, 84, 44, 46, 48, 50, 52, 36, 56, 58, 60, 62,
        32, 198, 68, 210, 36, 74, 76, 78, 120, 82, 84, 86, 44, 90, 46, 94, 48, 98, 40, 102, 52, 106, 72, 110, 168,
        114, 58, 118, 180, 122, 62, 84, 64, 66, 68, 420, 96, 74, 76, 234, 80, 82, 252, 86, 44, 120, 92, 94, 48, 98,
        80, 102, 52, 106, 48, 110, 112, 114, 58, 118, 60, 122, 124, 84, 64, 66, 204, 140, 72, 74, 76, 78, 240, 82,
        252, 86, 88, 60, 92, 846, 48, 28, 80, 102, 104, 954, 96, 110, 112, 114, 116, 354, 120, 610, 124, 420, 64, 66,
        136, 420, 216, 444, 456, 468, 80, 164, 504, 172, 88, 300, 92, 188, 96, 28, 240, 204, 104, 212, 192, 220, 336,
        228, 232, 236, 120, 244, 248, 168, 64, 130, 264, 134, 408, 138, 280, 142, 480, 146, 444, 120, 152, 462, 234,
        158, 80, 96, 902, 166, 336, 170, 86, 174, 176, 178, 120, 182, 184, 186, 94, 190, 480
    ]

    /// Kleinste zulässige Blockgröße ≥ `bits`.
    static func blockSize(for bits: Int) -> Int? { blockSizes.first { $0 >= bits } }

    /// Π(i) = (f1·i + f2·i²) mod K.
    static func interleaver(k: Int) -> [Int]? {
        guard let index = blockSizes.firstIndex(of: k) else { return nil }
        let a = f1[index], b = f2[index]
        return (0..<k).map { i in (a * i + b * ((i * i) % k)) % k }
    }

    private static func step(_ state: Int, _ u: Int) -> (next: Int, parity: Int) {
        let s1 = state & 1, s2 = (state >> 1) & 1, s3 = (state >> 2) & 1
        let a = u ^ s2 ^ s3
        return (a | (s1 << 1) | (s2 << 2), a ^ s1 ^ s3)
    }

    private static func constituent(_ c: [UInt8]) -> (parity: [UInt8], tailX: [UInt8], tailZ: [UInt8]) {
        var state = 0
        var parity = [UInt8](repeating: 0, count: c.count)
        for (i, bit) in c.enumerated() {
            let (next, z) = step(state, Int(bit))
            parity[i] = UInt8(z)
            state = next
        }
        var tx: [UInt8] = [], tz: [UInt8] = []
        for _ in 0..<3 {
            let u = ((state >> 1) & 1) ^ ((state >> 2) & 1)
            let (next, z) = step(state, u)
            tx.append(UInt8(u))
            tz.append(UInt8(z))
            state = next
        }
        return (parity, tx, tz)
    }

    /// Kodiert einen Block (Füllbits als 0 übergeben) → d0, d1, d2 je K+4.
    static func encode(_ c: [UInt8]) -> [[UInt8]] {
        let k = c.count
        guard let pi = interleaver(k: k) else { return [] }
        let first = constituent(c)
        let second = constituent(pi.map { c[$0] })
        var d0 = c, d1 = first.parity, d2 = second.parity
        // Abschluss (5.1.3.2.2)
        d0 += [first.tailX[0], first.tailZ[1], second.tailX[0], second.tailZ[1]]
        d1 += [first.tailZ[0], first.tailX[2], second.tailZ[0], second.tailX[2]]
        d2 += [first.tailX[1], first.tailZ[2], second.tailX[1], second.tailZ[2]]
        return [d0, d1, d2]
    }

    private static let negInf: Float = -1e30

    /// Max-Log-MAP eines RSC-Kodierers. `sys`/`par` haben K+3 Werte (mit
    /// Abschluss), `apriori` K Werte. Liefert A-posteriori-LLR (K Werte).
    private static func bcjr(sys: [Float], par: [Float], apriori: [Float], k: Int) -> [Float] {
        let steps = k + 3
        var alpha = [Float](repeating: negInf, count: (steps + 1) * 8)
        var beta = [Float](repeating: negInf, count: (steps + 1) * 8)
        alpha[0] = 0
        beta[steps * 8] = 0
        // Übergänge vorab
        var nextState = [Int](repeating: 0, count: 16)
        var parity = [Int](repeating: 0, count: 16)
        for s in 0..<8 {
            for u in 0..<2 {
                let (n, z) = step(s, u)
                nextState[s * 2 + u] = n
                parity[s * 2 + u] = z
            }
        }
        func gamma(_ t: Int, _ u: Int, _ z: Int) -> Float {
            let ls = sys[t] + (t < k ? apriori[t] : 0)
            return 0.5 * ((u == 0 ? ls : -ls) + (z == 0 ? par[t] : -par[t]))
        }
        for t in 0..<steps {
            var top = negInf
            for s in 0..<8 {
                let a = alpha[t * 8 + s]
                guard a > negInf / 2 else { continue }
                for u in 0..<2 {
                    if t >= k, u != ((s >> 1) & 1) ^ ((s >> 2) & 1) { continue }
                    let n = nextState[s * 2 + u]
                    let v = a + gamma(t, u, parity[s * 2 + u])
                    if v > alpha[(t + 1) * 8 + n] { alpha[(t + 1) * 8 + n] = v }
                }
            }
            for s in 0..<8 { top = max(top, alpha[(t + 1) * 8 + s]) }
            for s in 0..<8 where alpha[(t + 1) * 8 + s] > negInf / 2 { alpha[(t + 1) * 8 + s] -= top }
        }
        for t in stride(from: steps - 1, through: 0, by: -1) {
            var top = negInf
            for s in 0..<8 {
                var best = negInf
                for u in 0..<2 {
                    if t >= k, u != ((s >> 1) & 1) ^ ((s >> 2) & 1) { continue }
                    let n = nextState[s * 2 + u]
                    let b = beta[(t + 1) * 8 + n]
                    guard b > negInf / 2 else { continue }
                    best = max(best, b + gamma(t, u, parity[s * 2 + u]))
                }
                beta[t * 8 + s] = best
                top = max(top, best)
            }
            for s in 0..<8 where beta[t * 8 + s] > negInf / 2 { beta[t * 8 + s] -= top }
        }
        var out = [Float](repeating: 0, count: k)
        for t in 0..<k {
            var m0 = negInf, m1 = negInf
            for s in 0..<8 {
                let a = alpha[t * 8 + s]
                guard a > negInf / 2 else { continue }
                for u in 0..<2 {
                    let n = nextState[s * 2 + u]
                    let b = beta[(t + 1) * 8 + n]
                    guard b > negInf / 2 else { continue }
                    let v = a + gamma(t, u, parity[s * 2 + u]) + b
                    if u == 0 { m0 = max(m0, v) } else { m1 = max(m1, v) }
                }
            }
            out[t] = m0 - m1
        }
        return out
    }

    /// Dekodiert d0/d1/d2 (je K+4 weiche Bits, positiv = 0). `accept` prüft
    /// nach jeder Iteration (CRC) und beendet früh. Liefert `nil`, wenn keine
    /// Iteration angenommen wurde.
    static func decode(_ d: [[Float]], k: Int, iterations: Int = 8, accept: ([UInt8]) -> Bool) -> [UInt8]? {
        guard let pi = interleaver(k: k), d.count == 3, d[0].count == k + 4 else { return nil }
        let d0 = d[0], d1 = d[1], d2 = d[2]
        // Systematik und Parität beider Kodierer samt Abschluss.
        let sys1 = Array(d0[0..<k]) + [d0[k], d2[k], d1[k + 1]]
        let par1 = Array(d1[0..<k]) + [d1[k], d0[k + 1], d2[k + 1]]
        let sys2 = pi.map { d0[$0] } + [d0[k + 2], d2[k + 2], d1[k + 3]]
        let par2 = Array(d2[0..<k]) + [d1[k + 2], d0[k + 3], d2[k + 3]]
        var la1 = [Float](repeating: 0, count: k)
        var la2 = [Float](repeating: 0, count: k)
        var bits = [UInt8](repeating: 0, count: k)
        let scale: Float = 0.75
        for _ in 0..<iterations {
            let l1 = bcjr(sys: sys1, par: par1, apriori: la1, k: k)
            for i in 0..<k { la2[i] = scale * (l1[pi[i]] - sys1[pi[i]] - la1[pi[i]]) }
            let l2 = bcjr(sys: sys2, par: par2, apriori: la2, k: k)
            for i in 0..<k {
                la1[pi[i]] = scale * (l2[i] - sys2[i] - la2[i])
                bits[pi[i]] = l2[i] < 0 ? 1 : 0
            }
            if accept(bits) { return bits }
        }
        return nil
    }
}
