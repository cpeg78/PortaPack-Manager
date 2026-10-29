import Foundation

/// Holt einen Unterkanal aus dem MSC und dekodiert ihn zu Logikrahmen
/// (24 ms, 3 · Bitrate Bytes): Zeit-Entschachtelung über 16 CIFs,
/// Depunktierung, Viterbi, Energieverwischung (EN 300 401 §11–12).
final class DABSubchannelDecoder: @unchecked Sendable {
    /// Verzögerung je Bitposition modulo 16 (§12, Tabelle 30).
    static let interleaveMap = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]

    let subchannel: DABSubchannel
    private let puncturing: DABPuncturing
    private let viterbi = DABViterbi()
    private let prbs: [UInt8]
    private let length: Int
    /// Die letzten 16 CIFs dieses Unterkanals (Ringpuffer).
    private var history: [[Int16]]
    private var cifCount = 0

    init?(subchannel: DABSubchannel) {
        guard let puncturing = subchannel.puncturing else { return nil }
        self.subchannel = subchannel
        self.puncturing = puncturing
        length = subchannel.sizeCU * DABMode.capacityUnitBits
        prbs = DABTables.prbs(count: puncturing.dataBits)
        history = [[Int16]](repeating: [Int16](repeating: 0, count: length), count: 16)
    }

    func reset() { cifCount = 0 }

    /// Verarbeitet die MSC-Bits eines Rahmens (4 CIFs) und liefert die
    /// fertigen Logikrahmen (erst nach 15 CIFs Vorlauf).
    func process(msc: [Int16]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        let start = subchannel.startCU * DABMode.capacityUnitBits
        for cif in 0..<DABMode.cifsPerFrame {
            let base = cif * DABMode.cifBits + start
            guard base + length <= msc.count else { break }
            let slot = cifCount & 15
            history[slot] = Array(msc[base..<(base + length)])
            cifCount += 1
            guard cifCount >= 16 else { continue }
            frames.append(decodeLogicalFrame(newest: slot))
        }
        return frames
    }

    private func decodeLogicalFrame(newest: Int) -> [UInt8] {
        var soft = [Int16](repeating: 0, count: length)
        for i in 0..<length {
            let age = 15 - Self.interleaveMap[i & 15]
            soft[i] = history[(newest - age + 16) & 15][i]
        }
        let mother = soft.withUnsafeBufferPointer { puncturing.depuncture($0) }
        var bits = viterbi.decode(mother, bits: puncturing.dataBits)
        for i in bits.indices { bits[i] ^= prbs[i] }
        return DABBits.pack(bits)
    }
}

/// Reed-Solomon RS(120, 110) über GF(2⁸) (Polynom 0x11D, erste Nullstelle
/// α⁰), verkürzt aus RS(255, 245) – wie im DAB+-Superframe (TS 102 563 §6).
struct DABReedSolomon: Sendable {
    static let n = 120
    static let k = 110
    static let parity = 10

    private static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 512)
        var x = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { table[i] = table[i - 255] }
        return table
    }()

    private static let log: [Int] = {
        var table = [Int](repeating: 0, count: 256)
        for i in 0..<255 { table[Int(exp[i])] = i }
        return table
    }()

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }

    private static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 ? 0 : exp[(log[Int(a)] - log[Int(b)] + 255) % 255]
    }

    private static func power(_ e: Int) -> UInt8 { exp[((e % 255) + 255) % 255] }

    /// Generatorpolynom Π (x − αⁱ), i = 0…9; höchster Grad zuerst.
    private static let generator: [UInt8] = {
        var g: [UInt8] = [1]
        for i in 0..<parity {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j] ^= c
                next[j + 1] ^= mul(c, power(i))
            }
            g = next
        }
        return g
    }()

    /// Hängt 10 Prüfbytes an 110 Datenbytes an (für Tests).
    static func encode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == k)
        var remainder = [UInt8](repeating: 0, count: parity)
        for byte in data {
            let feedback = byte ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            if feedback != 0 {
                for j in 0..<parity { remainder[j] ^= mul(feedback, generator[j + 1]) }
            }
        }
        return data + remainder
    }

    /// Korrigiert ein Codewort (120 Bytes, Index 0 = höchste Potenz).
    /// Liefert die Zahl korrigierter Bytes oder `nil`, wenn nicht korrigierbar.
    static func decode(_ codeword: inout [UInt8]) -> Int? {
        // Syndrome S_j = r(α^j)
        var syndromes = [UInt8](repeating: 0, count: parity)
        var hasError = false
        for j in 0..<parity {
            var s: UInt8 = 0
            let a = power(j)
            for byte in codeword { s = mul(s, a) ^ byte }
            syndromes[j] = s
            if s != 0 { hasError = true }
        }
        guard hasError else { return 0 }

        // Berlekamp-Massey → Fehlerort-Polynom Λ (niedrigster Grad zuerst)
        var lambda: [UInt8] = [1]
        var previous: [UInt8] = [1]
        var l = 0
        var m = 1
        var b: UInt8 = 1
        for r in 0..<parity {
            var delta = syndromes[r]
            for i in 1...max(1, l) where i < lambda.count { delta ^= mul(lambda[i], syndromes[r - i]) }
            if delta == 0 {
                m += 1
                continue
            }
            let scale = div(delta, b)
            var t = lambda
            let needed = previous.count + m
            if t.count < needed { t += [UInt8](repeating: 0, count: needed - t.count) }
            for (i, c) in previous.enumerated() { t[i + m] ^= mul(scale, c) }
            if 2 * l <= r {
                previous = lambda
                l = r + 1 - l
                b = delta
                m = 1
            } else {
                m += 1
            }
            lambda = t
        }
        while lambda.count > 1 && lambda.last == 0 { lambda.removeLast() }
        let degree = lambda.count - 1
        guard degree > 0, degree <= parity / 2 else { return nil }

        // Ω = S · Λ mod x^10
        var omega = [UInt8](repeating: 0, count: parity)
        for i in 0..<parity {
            for j in 0...min(i, degree) { omega[i] ^= mul(syndromes[i - j], lambda[j]) }
        }

        // Chien-Suche über die 120 tatsächlich vorhandenen Stellen.
        var corrected = 0
        for position in 0..<n {
            let p = n - 1 - position          // Potenz der Stelle
            let inverse = power(-p)           // X⁻¹
            var value: UInt8 = 0
            var x: UInt8 = 1
            for c in lambda {
                value ^= mul(c, x)
                x = mul(x, inverse)
            }
            guard value == 0 else { continue }
            // Forney (erste Nullstelle α⁰): e = X · Ω(X⁻¹) / Λ'(X⁻¹)
            var numerator: UInt8 = 0
            x = 1
            for c in omega {
                numerator ^= mul(c, x)
                x = mul(x, inverse)
            }
            var denominator: UInt8 = 0
            x = 1
            for i in stride(from: 1, through: degree, by: 2) {
                denominator ^= mul(lambda[i], x)
                x = mul(x, mul(inverse, inverse))
            }
            guard denominator != 0 else { return nil }
            codeword[position] ^= mul(power(p), div(numerator, denominator))
            corrected += 1
        }
        return corrected == degree ? corrected : nil
    }
}
