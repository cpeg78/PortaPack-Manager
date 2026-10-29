import Foundation

/// Äußerer BCH-Code der FEC-Blöcke (EN 302 755, 6.1.1, Tabellen 7a/7b):
/// GF(2¹⁶) mit x¹⁶+x⁵+x³+x²+1 (normale Rahmen, t = 12 bzw. 10) und GF(2¹⁴)
/// mit x¹⁴+x⁵+x³+x+1 (kurze Rahmen, t = 12). Das Generatorpolynom ist das
/// Produkt der Minimalpolynome von α, α³, …, α^(2t−1) – das ergibt genau die
/// Tabellenpolynome (geprüft gegen Tabelle 7b). Systematisch: erst die K_bch
/// Nachrichtenbits (höchste Potenz zuerst), dann die Parität d_{p−1} … d_0.
///
/// Nach dem LDPC-Dekoder bleiben bei schwachem Signal oft Blöcke mit einer
/// Handvoll Restfehlern (Trapping-Sets) – die repariert der BCH; und ein
/// LDPC-Wort mit erfülltem Syndrom, aber falschem Inhalt, fällt hier auf.
struct T2BCH: Sendable {
    let m: Int
    let t: Int
    /// N_bch = K_ldpc.
    let n: Int
    /// K_bch.
    let k: Int
    let parityBits: Int
    /// Generatorpolynom, niedrigste Potenz zuerst (g[0] = g[p] = 1).
    let generator: [UInt8]

    private let exp: [UInt16]
    private let log: [UInt16]
    private let order: Int
    private let mask: [UInt64]
    private let words: Int

    init(fec: T2FEC) {
        let m = fec.normal ? 16 : 14
        self.init(m: m, t: fec.bchParity / m, n: fec.kldpc)
    }

    init(m: Int, t: Int, n: Int) {
        precondition(m == 16 || m == 14)
        let primitive: UInt32 = m == 16 ? 0x1002D : 0x402B
        let order = (1 << m) - 1
        var exp = [UInt16](repeating: 0, count: 2 * order)
        var log = [UInt16](repeating: 0, count: 1 << m)
        var x: UInt32 = 1
        for i in 0..<order {
            exp[i] = UInt16(x); exp[i + order] = UInt16(x); log[Int(x)] = UInt16(i)
            x <<= 1
            if x & (1 << UInt32(m)) != 0 { x ^= primitive }
        }
        func mul(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 0 : Int(exp[Int(log[a]) + Int(log[b])]) }

        var g: [UInt8] = [1]
        var seen = Set<Int>()
        for i in stride(from: 1, through: 2 * t - 1, by: 2) where !seen.contains(i) {
            // Kreisteilungsklasse {i·2^j} → Minimalpolynom Π (x + α^c) mit Koeffizienten in GF(2).
            var coset: [Int] = []
            var c = i
            repeat { coset.append(c); seen.insert(c); c = (2 * c) % order } while c != i
            var poly = [1]
            for c in coset {
                let root = Int(exp[c])
                var next = [Int](repeating: 0, count: poly.count + 1)
                for (d, coefficient) in poly.enumerated() {
                    next[d + 1] ^= coefficient
                    next[d] ^= mul(coefficient, root)
                }
                poly = next
            }
            precondition(poly.allSatisfy { $0 <= 1 }, "Minimalpolynom nicht binär")
            var product = [UInt8](repeating: 0, count: g.count + poly.count - 1)
            for (a, ga) in g.enumerated() where ga == 1 {
                for (b, pb) in poly.enumerated() where pb == 1 { product[a + b] ^= 1 }
            }
            g = product
        }
        precondition(g.count - 1 == t * m, "Grad des Generators \(g.count - 1) statt \(t * m)")

        self.m = m; self.t = t; self.n = n
        parityBits = g.count - 1
        k = n - parityBits
        generator = g
        self.exp = exp; self.log = log; self.order = order
        words = (parityBits + 63) / 64
        var mask = [UInt64](repeating: 0, count: words)
        for b in 0..<parityBits where g[b] == 1 { mask[b / 64] |= 1 << UInt64(b % 64) }
        self.mask = mask
    }

    @inline(__always) private func mul(_ a: Int, _ b: Int) -> Int {
        a == 0 || b == 0 ? 0 : Int(exp[Int(log[a]) + Int(log[b])])
    }

    /// Rest von bits(x)·x^p mod g(x) als Schieberegister (Bit b = Koeffizient von x^b).
    private func remainder(_ bits: UnsafeBufferPointer<UInt8>, count: Int) -> [UInt64] {
        var reg = [UInt64](repeating: 0, count: words)
        let top = parityBits - 1
        let topWord = top / 64
        let topBit = UInt64(1) << UInt64(top % 64)
        let keep = (topBit << 1) &- 1
        reg.withUnsafeMutableBufferPointer { r in
            mask.withUnsafeBufferPointer { mk in
                for i in 0..<count {
                    let feedback = ((r[topWord] & topBit) != 0) != (bits[i] != 0)
                    var carry: UInt64 = 0
                    for w in 0..<words {
                        let next = r[w] >> 63
                        r[w] = (r[w] << 1) | carry
                        carry = next
                    }
                    r[topWord] &= keep
                    if feedback { for w in 0..<words { r[w] ^= mk[w] } }
                }
            }
        }
        return reg
    }

    /// Paritätsbits (d_{p−1} … d_0) zu `message` (K_bch Bits) – für Tests und den Testsender.
    func parity(_ message: [UInt8]) -> [UInt8] {
        precondition(message.count == k)
        let reg = message.withUnsafeBufferPointer { remainder($0, count: k) }
        return (0..<parityBits).map { i in
            let b = parityBits - 1 - i
            return UInt8((reg[b / 64] >> UInt64(b % 64)) & 1)
        }
    }

    /// Ist `bits[0..<n]` ein Kodewort?
    func check(_ bits: [UInt8]) -> Bool {
        bits.withUnsafeBufferPointer { remainder($0, count: n) }.allSatisfy { $0 == 0 }
    }

    /// Prüft `bits[0..<n]` und korrigiert bis zu t Fehler an Ort und Stelle.
    /// Rückgabe: Zahl der korrigierten Bits, nil wenn nicht korrigierbar.
    func correct(_ bits: inout [UInt8]) -> Int? {
        precondition(bits.count >= n)
        let reg = bits.withUnsafeBufferPointer { remainder($0, count: n) }
        if reg.allSatisfy({ $0 == 0 }) { return 0 }

        // Syndrome S_i = c(α^i) = R(α^i)·α^(−i·p), R = Rest von c·x^p.
        var syndromes = [Int](repeating: 0, count: 2 * t + 1)
        for i in 1...(2 * t) {
            let a = Int(exp[i])
            var s = 0
            for b in stride(from: parityBits - 1, through: 0, by: -1) {
                s = mul(s, a)
                if (reg[b / 64] >> UInt64(b % 64)) & 1 == 1 { s ^= 1 }
            }
            let shift = (order - (i * parityBits) % order) % order
            syndromes[i] = mul(s, Int(exp[shift]))
        }

        // Berlekamp–Massey → Fehlerstellenpolynom Λ.
        var lambda = [Int](repeating: 0, count: 2 * t + 2); lambda[0] = 1
        var previous = lambda
        var length = 0, gap = 1, previousDelta = 1
        for r in 1...(2 * t) {
            var delta = syndromes[r]
            for j in stride(from: 1, through: length, by: 1) where lambda[j] != 0 {
                delta ^= mul(lambda[j], syndromes[r - j])
            }
            if delta == 0 { gap += 1; continue }
            let scale = mul(delta, Int(exp[order - Int(log[previousDelta])]))
            var updated = lambda
            for j in 0..<(lambda.count - gap) where previous[j] != 0 {
                updated[j + gap] ^= mul(scale, previous[j])
            }
            if 2 * length <= r - 1 {
                length = r - length
                previous = lambda; previousDelta = delta; gap = 1
            } else {
                gap += 1
            }
            lambda = updated
        }
        guard length <= t, length > 0 else { return nil }

        // Chien-Suche: Λ(α^(−j)) = 0 ↔ Fehler im Term x^j ↔ Bitindex n−1−j.
        var terms = (0...length).map { lambda[$0] }
        let steps = (1...length).map { Int(exp[order - $0]) }
        var positions: [Int] = []
        for j in 0..<n {
            var sum = 0
            for i in 0...length { sum ^= terms[i] }
            if sum == 0 {
                positions.append(n - 1 - j)
                if positions.count == length { break }
            }
            for i in 1...length where terms[i] != 0 { terms[i] = mul(terms[i], steps[i - 1]) }
        }
        guard positions.count == length else { return nil }
        for p in positions { bits[p] ^= 1 }
        guard check(bits) else {
            for p in positions { bits[p] ^= 1 }
            return nil
        }
        return length
    }
}
