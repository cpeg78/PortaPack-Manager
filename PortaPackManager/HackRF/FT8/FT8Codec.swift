import Foundation

/// Kanalkodierung von FT8: CRC-14, LDPC(174,91), Gray-Abbildung auf 8-GFSK,
/// drei Costas-Felder 7×7 – und die Gegenrichtung (Belief Propagation, OSD).
enum FT8Codec {
    static let costas: [Int] = [3, 1, 4, 0, 6, 5, 2]
    /// 3 Bit → Ton.
    static let grayMap: [Int] = [0, 1, 3, 2, 5, 6, 4, 7]
    /// Ton → 3 Bit.
    static let grayUnmap: [Int] = { var u = [Int](repeating: 0, count: 8); for (i, t) in grayMap.enumerated() { u[t] = i }; return u }()
    static let symbolCount = 79
    /// Indizes der 58 Datensymbole.
    static let dataSymbols: [Int] = Array(7..<36) + Array(43..<72)

    // MARK: - CRC-14 (Polynom 0x2757 über 77 Bit + 5 Nullbits, wie WSJT-X)

    static func crc14(_ bits: [UInt8]) -> UInt16 {
        var reg: UInt16 = 0
        for i in 0..<82 {
            let bit = i < 77 ? bits[i] : 0
            let top = (reg >> 13) & 1
            reg = (reg << 1) & 0x3FFF
            if top ^ UInt16(bit) == 1 { reg ^= 0x2757 }
        }
        return reg
    }

    /// 77 Nachrichtenbits → 91 Bits (mit CRC).
    static func addCRC(_ bits77: [UInt8]) -> [UInt8] {
        let c = crc14(bits77)
        return Array(bits77.prefix(77)) + (0..<14).map { UInt8((c >> UInt16(13 - $0)) & 1) }
    }

    static func checkCRC(_ bits91: [UInt8]) -> Bool {
        var c: UInt16 = 0
        for i in 77..<91 { c = c << 1 | UInt16(bits91[i]) }
        return crc14(bits91) == c
    }

    // MARK: - LDPC

    /// Generatorzeilen als Bitmasken über 91 Bit (zwei UInt64, MSB = Bit 0).
    private static let generatorMasks: [(UInt64, UInt64)] = FT8Tables.generator.map { row in
        var a: UInt64 = 0, b: UInt64 = 0
        for i in 0..<91 {
            let bit = UInt64((row[i / 8] >> UInt8(7 - i % 8)) & 1)
            if i < 64 { a |= bit << UInt64(63 - i) } else { b |= bit << UInt64(63 - (i - 64)) }
        }
        return (a, b)
    }

    /// 91 Bits → 174-Bit-Codewort (systematisch: Nachricht zuerst).
    static func encode(_ bits91: [UInt8]) -> [UInt8] {
        var a: UInt64 = 0, b: UInt64 = 0
        for i in 0..<91 where bits91[i] != 0 {
            if i < 64 { a |= 1 << UInt64(63 - i) } else { b |= 1 << UInt64(63 - (i - 64)) }
        }
        var out = Array(bits91.prefix(91))
        for (ga, gb) in generatorMasks {
            out.append(UInt8(((ga & a).nonzeroBitCount + (gb & b).nonzeroBitCount) & 1))
        }
        return out
    }

    /// Anzahl verletzter Paritätsprüfungen.
    static func parityErrors(_ cw: [UInt8]) -> Int {
        var errors = 0
        for (m, row) in FT8Tables.nm.enumerated() {
            var x: UInt8 = 0
            for k in 0..<Int(FT8Tables.numRows[m]) { x ^= cw[Int(row[k]) - 1] }
            if x != 0 { errors += 1 }
        }
        return errors
    }

    /// Codewort → 79 Töne.
    static func tones(codeword cw: [UInt8]) -> [Int] {
        var tones = [Int](repeating: 0, count: 79)
        for i in 0..<7 {
            tones[i] = costas[i]; tones[36 + i] = costas[i]; tones[72 + i] = costas[i]
        }
        for (d, s) in dataSymbols.enumerated() {
            let v = Int(cw[3 * d]) << 2 | Int(cw[3 * d + 1]) << 1 | Int(cw[3 * d + 2])
            tones[s] = grayMap[v]
        }
        return tones
    }

    static func tones(message bits77: [UInt8]) -> [Int] {
        tones(codeword: encode(addCRC(bits77)))
    }

    // MARK: - Belief Propagation

    private static let nmIndex: [[Int]] = FT8Tables.nm.enumerated().map { m, row in (0..<Int(FT8Tables.numRows[m])).map { Int(row[$0]) - 1 } }
    private static let mnIndex: [[Int]] = FT8Tables.mn.map { $0.map { Int($0) - 1 } }
    /// Für jede Prüfung m und Position k darin: welche der drei Prüfungen des Bits ist m.
    private static let edgeSlot: [[Int]] = nmIndex.enumerated().map { m, bits in bits.map { n in mnIndex[n].firstIndex(of: m)! } }

    /// Log-Likelihoods (positiv = Bit 1) → Codewort, `nil` wenn keine gültige Lösung.
    /// Liefert auch die Zahl der Iterationen.
    static func beliefPropagation(_ llr: [Float], maxIterations: Int = 30) -> [UInt8]? {
        let n = 174
        var tov = [Float](repeating: 0, count: n * 3)      // Prüfung → Bit
        var toc = [Float](repeating: 0, count: 83 * 7)     // Bit → Prüfung (als tanh)
        var hard = [UInt8](repeating: 0, count: n)
        for _ in 0..<maxIterations {
            for i in 0..<n {
                hard[i] = (llr[i] + tov[3 * i] + tov[3 * i + 1] + tov[3 * i + 2]) > 0 ? 1 : 0
            }
            if parityErrors(hard) == 0 {
                return hard.contains(1) ? hard : nil
            }
            for m in 0..<83 {
                let bits = nmIndex[m]
                for (k, bit) in bits.enumerated() {
                    let slot = edgeSlot[m][k]
                    var t = llr[bit]
                    for j in 0..<3 where j != slot { t += tov[3 * bit + j] }
                    toc[m * 7 + k] = tanh(-t / 2)
                }
            }
            for m in 0..<83 {
                let bits = nmIndex[m]
                for (k, bit) in bits.enumerated() {
                    var prod: Float = 1
                    for j in 0..<bits.count where j != k { prod *= toc[m * 7 + j] }
                    let clamped = max(-0.999_999, min(0.999_999, prod))
                    tov[3 * bit + edgeSlot[m][k]] = -2 * atanh(clamped)
                }
            }
        }
        return nil
    }

    // MARK: - Ordered Statistics Decoding

    private struct Row174 {
        var w: (UInt64, UInt64, UInt64) = (0, 0, 0)
        @inline(__always) func bit(_ i: Int) -> Bool {
            switch i >> 6 {
            case 0: return (w.0 >> UInt64(i & 63)) & 1 == 1
            case 1: return (w.1 >> UInt64(i & 63)) & 1 == 1
            default: return (w.2 >> UInt64(i & 63)) & 1 == 1
            }
        }
        @inline(__always) mutating func set(_ i: Int, _ v: Bool) {
            let mask = UInt64(1) << UInt64(i & 63)
            switch i >> 6 {
            case 0: w.0 = v ? w.0 | mask : w.0 & ~mask
            case 1: w.1 = v ? w.1 | mask : w.1 & ~mask
            default: w.2 = v ? w.2 | mask : w.2 & ~mask
            }
        }
        @inline(__always) mutating func xor(_ o: Row174) { w.0 ^= o.w.0; w.1 ^= o.w.1; w.2 ^= o.w.2 }
    }

    /// Systematische Generatormatrix 91 × 174.
    private static let generatorRows: [Row174] = (0..<91).map { i in
        var r = Row174()
        r.set(i, true)
        for (j, row) in FT8Tables.generator.enumerated() where (row[i / 8] >> UInt8(7 - i % 8)) & 1 == 1 {
            r.set(91 + j, true)
        }
        return r
    }

    /// OSD der Ordnung 1 (plus Paare unter den unsichersten Bits der
    /// zuverlässigsten Basis): sortiert die Bits nach Zuverlässigkeit, bringt
    /// die Generatormatrix auf die 91 zuverlässigsten unabhängigen Stellen,
    /// kodiert deren harte Entscheidung neu und probiert Kippungen.
    /// Liefert das Codewort mit der kleinsten gewichteten Abweichung, wenn die
    /// CRC passt und die Zahl harter Abweichungen klein genug ist.
    static func osd(_ llr: [Float], maxHardErrors: Int = 36, pairDepth: Int = 16) -> [UInt8]? {
        let n = 174
        var perm = Array(0..<n)
        perm.sort { abs(llr[$0]) > abs(llr[$1]) }
        // Permutierte Matrix spaltenweise: g[r] hat Bit k = G[r][perm[k]].
        var g = [Row174](repeating: Row174(), count: 91)
        for r in 0..<91 {
            for k in 0..<n where generatorRows[r].bit(perm[k]) { g[r].set(k, true) }
        }
        // Gauß-Elimination mit Spaltentausch.
        for id in 0..<91 {
            var pivotCol = -1, pivotRow = -1
            search: for col in id..<n {
                for r in id..<91 where g[r].bit(col) {
                    pivotCol = col; pivotRow = r
                    break search
                }
            }
            guard pivotCol >= 0 else { return nil }
            if pivotCol != id {
                for r in 0..<91 {
                    let a = g[r].bit(id), b = g[r].bit(pivotCol)
                    if a != b { g[r].set(id, b); g[r].set(pivotCol, a) }
                }
                perm.swapAt(id, pivotCol)
            }
            if pivotRow != id { g.swapAt(id, pivotRow) }
            let p = g[id]
            for r in 0..<91 where r != id && g[r].bit(id) { g[r].xor(p) }
        }
        // Harte Entscheidungen in permutierter Ordnung.
        var hard = Row174()
        var weight = [Float](repeating: 0, count: n)
        for k in 0..<n {
            hard.set(k, llr[perm[k]] > 0)
            weight[k] = abs(llr[perm[k]])
        }
        var c0 = Row174()
        for r in 0..<91 where hard.bit(r) { c0.xor(g[r]) }

        func discrepancy(_ c: Row174) -> (Float, Int) {
            var d = c
            d.xor(hard)
            var sum: Float = 0
            var count = 0
            for (wi, word) in [d.w.0, d.w.1, d.w.2].enumerated() {
                var x = word
                while x != 0 {
                    let b = x.trailingZeroBitCount
                    let k = wi * 64 + b
                    if k < n { sum += weight[k]; count += 1 }
                    x &= x - 1
                }
            }
            return (sum, count)
        }

        var best = c0
        var (bestD, _) = discrepancy(c0)
        for i in 0..<91 {
            var c = c0
            c.xor(g[i])
            let (d, _) = discrepancy(c)
            if d < bestD { bestD = d; best = c }
        }
        // Paare unter den unsichersten Stellen der Basis.
        let low = max(0, 91 - pairDepth)
        for i in low..<91 {
            for j in (i + 1)..<91 {
                var c = c0
                c.xor(g[i]); c.xor(g[j])
                let (d, _) = discrepancy(c)
                if d < bestD { bestD = d; best = c }
            }
        }
        let (_, hardErrors) = discrepancy(best)
        guard hardErrors <= maxHardErrors else { return nil }
        var cw = [UInt8](repeating: 0, count: n)
        for k in 0..<n where best.bit(k) { cw[perm[k]] = 1 }
        guard cw.contains(1), parityErrors(cw) == 0, checkCRC(cw) else { return nil }
        return cw
    }

    // MARK: - Modulator (GFSK, BT = 2, wie WSJT-X gen_ft8wave)

    static let symbolSamples = 1920       // bei 12 kHz
    static let toneSpacing = 6.25

    static func gfskPulse(_ bt: Double, _ t: Double) -> Double {
        let c = Double.pi * (2 / log(2.0)).squareRoot()
        return 0.5 * (erf(c * bt * (t + 0.5)) - erf(c * bt * (t - 0.5)))
    }

    /// Phasenschritte je Abtastwert für eine Tonfolge (ohne Trägerfrequenz).
    /// Länge `tones.count * nsps`; Ton 0 liegt bei 0 Hz.
    static func phaseSteps(tones: [Int], samplesPerSymbol nsps: Int = symbolSamples, bt: Double = 2) -> [Double] {
        let n = tones.count
        let pulse = (0..<(3 * nsps)).map { gfskPulse(bt, (Double($0) - 1.5 * Double(nsps)) / Double(nsps)) }
        let peak = 2 * Double.pi / Double(nsps)
        var dphi = [Double](repeating: 0, count: (n + 2) * nsps)
        for j in 0..<n {
            let ib = j * nsps
            for i in 0..<(3 * nsps) { dphi[ib + i] += peak * pulse[i] * Double(tones[j]) }
        }
        for i in 0..<(2 * nsps) {
            dphi[i] += peak * Double(tones[0]) * pulse[nsps + i]
            dphi[n * nsps + i] += peak * Double(tones[n - 1]) * pulse[i]
        }
        return Array(dphi[nsps..<(nsps + n * nsps)])
    }

    /// Komplexes Basisbandsignal (12 kHz) einer FT8-Aussendung: Ton 0 bei
    /// `frequency` Hz, Amplitude 1, weiche Rampen an Anfang und Ende.
    static func waveform(tones: [Int], frequency: Double, sampleRate: Double = 12_000,
                         phase: Double = 0) -> (re: [Float], im: [Float]) {
        let steps = phaseSteps(tones: tones)
        let n = steps.count
        let carrier = 2 * Double.pi * frequency / sampleRate
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var phi = phase
        let ramp = symbolSamples / 8
        for i in 0..<n {
            var a = 1.0
            if i < ramp { a = (1 - cos(2 * Double.pi * Double(i) / Double(2 * ramp))) / 2 }
            if i >= n - ramp { a = (1 + cos(2 * Double.pi * Double(i - (n - ramp)) / Double(2 * ramp))) / 2 }
            re[i] = Float(a * cos(phi))
            im[i] = Float(a * sin(phi))
            phi = (phi + steps[i] + carrier).truncatingRemainder(dividingBy: 2 * .pi)
        }
        return (re, im)
    }
}
