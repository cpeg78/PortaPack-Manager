import Foundation

/// Bitverschachtelung und Abbildung auf Zellen (6.1.3, 6.2, 6.3) – hier
/// rückwärts: Zellen eines FEC-Blocks → LLR in Kodewort-Reihenfolge.
final class T2BitMapper: @unchecked Sendable {
    let fec: T2FEC
    let modulation: T2Modulation
    let rotated: Bool
    /// `position[q·η + bit]` = Index des Kodewortbits für Bit `bit` von Zelle q.
    let position: [Int32]
    var cells: Int { fec.nldpc / modulation.bitsPerCell }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: T2BitMapper] = [:]

    static func mapper(fec: T2FEC, modulation: T2Modulation, rotated: Bool) -> T2BitMapper {
        let key = "\(fec.normal)-\(fec.rate.rawValue)-\(modulation.rawValue)-\(rotated)"
        return lock.withLock {
            if let m = cache[key] { return m }
            let m = T2BitMapper(fec: fec, modulation: modulation, rotated: rotated)
            cache[key] = m
            return m
        }
    }

    private init(fec: T2FEC, modulation: T2Modulation, rotated: Bool) {
        self.fec = fec
        self.modulation = modulation
        self.rotated = rotated
        levels = Self.axisLevels(perAxis: modulation.bitsPerCell / 2)
        let n = fec.nldpc
        let eta = modulation.bitsPerCell
        let demux = Self.demux(fec: fec, modulation: modulation)
        let substreams = demux.count
        let split = substreams == 2 * eta

        // v_j → u_i: Spaltendrehung (nicht bei QPSK).
        let twist = Self.twist(fec: fec, modulation: modulation)
        func columnTwist(_ j: Int) -> Int {
            guard let twist else { return j }
            let nc = twist.count, nr = n / nc
            let r = j / nc, c = j % nc
            return c * nr + ((r - twist[c]) % nr + nr) % nr
        }
        // u_i → λ: Paritätsverschachtelung.
        let k = fec.kldpc, q = fec.q
        func parity(_ i: Int) -> Int {
            guard twist != nil, i >= k else { return i }
            let t = (i - k) / 360, s = (i - k) % 360
            return k + q * s + t
        }
        var position = [Int32](repeating: 0, count: n)
        for d in 0..<(n / substreams) {
            for index in 0..<substreams {
                let e = demux[index]
                let cell = split ? 2 * d + (e < eta ? 0 : 1) : d
                let bit = split ? e % eta : e
                position[cell * eta + bit] = Int32(parity(columnTwist(d * substreams + index)))
            }
        }
        self.position = position
    }

    /// Demultiplexer: Ausgangsbit e für Eingangsbit di mod N (Tabelle 13 a–c).
    static func demux(fec: T2FEC, modulation: T2Modulation) -> [Int] {
        switch modulation {
        case .qpsk: return [0, 1]
        case .qam16:
            if fec.rate == .r3_5 && fec.normal { return [0, 5, 1, 2, 4, 7, 3, 6] }
            return [7, 1, 4, 2, 5, 3, 6, 0]
        case .qam64:
            if fec.rate == .r3_5 && fec.normal { return [2, 7, 6, 9, 0, 3, 1, 8, 4, 11, 5, 10] }
            return [11, 7, 3, 10, 6, 2, 9, 5, 1, 8, 4, 0]
        case .qam256:
            if !fec.normal { return [7, 3, 1, 5, 2, 6, 4, 0] }
            if fec.rate == .r3_5 { return [2, 11, 3, 4, 0, 9, 1, 8, 10, 13, 7, 14, 6, 15, 5, 12] }
            if fec.rate == .r2_3 { return [7, 2, 9, 0, 4, 6, 13, 3, 14, 10, 15, 5, 8, 12, 11, 1] }
            return [15, 1, 13, 3, 8, 11, 9, 5, 10, 6, 4, 7, 12, 2, 14, 0]
        }
    }

    /// Spaltendrehung t_c (Tabelle 10); `nil` = keine Bitverschachtelung.
    static func twist(fec: T2FEC, modulation: T2Modulation) -> [Int]? {
        switch modulation {
        case .qpsk: return nil
        case .qam16: return fec.normal ? [0, 0, 2, 4, 4, 5, 7, 7] : [0, 0, 0, 1, 7, 20, 20, 21]
        case .qam64: return fec.normal ? [0, 0, 2, 2, 3, 4, 4, 5, 5, 7, 8, 9] : [0, 0, 0, 2, 2, 2, 3, 3, 3, 6, 7, 7]
        case .qam256: return fec.normal ? [0, 2, 2, 2, 2, 3, 7, 15, 16, 20, 22, 22, 27, 27, 28, 32] : [0, 0, 0, 1, 7, 20, 20, 21]
        }
    }

    // MARK: - Demapping

    /// Normierung der Konstellation (Tabelle 15).
    static func norm(_ modulation: T2Modulation) -> Float {
        [2, 10, 42, 170][modulation.rawValue]
    }

    /// Stufen einer Gray-PAM-Achse je Bitmuster (Bit 0 = höchstwertig) –
    /// passend zu `axis`: erstes Bit = Vorzeichen, dann |x| − L/2 …
    static func axisLevels(perAxis: Int) -> [Float] {
        let count = 1 << perAxis
        var table = [Float](repeating: 0, count: count)
        for l in 0..<count {
            let x = Float(2 * l - count + 1)
            var bits = [Float](repeating: 0, count: 8)
            axis(x, levels: perAxis, weight: 1, into: &bits, stride: 1, offset: 0)
            var index = 0
            for i in 0..<perAxis { index = index << 1 | (bits[i] < 0 ? 1 : 0) }
            table[index] = x
        }
        return table
    }

    /// Achsenstufen je Bitmuster (siehe `axisLevels`).
    private let levels: [Float]

    /// Kalibrierte LLR (positiv = 0) eines FEC-Blocks in Kodewort-Reihenfolge:
    /// Log-MAP je Achse über alle Stufen. `weights` = |H|²/N0 je Zelle (Zellen
    /// bereits entzerrt). Gegenüber den linearen Näherungen (max-log, nur
    /// innerste Entscheidungsgrenze) gemessen 0,4 dB besser im 0-dB-Echo-Kanal.
    func llr(re: UnsafePointer<Float>, im: UnsafePointer<Float>, weights: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        if rotated {
            rotatedLLR(re: re, im: im, weights: weights, into: out)
            return
        }
        let eta = modulation.bitsPerCell
        let perAxis = eta / 2
        let norm = Self.norm(modulation)
        let scale = norm.squareRoot()
        let count = cells
        let levels = levels
        let size = levels.count
        position.withUnsafeBufferPointer { pos in
            levels.withUnsafeBufferPointer { lv in
                withUnsafeTemporaryAllocation(of: Float.self, capacity: 2 * size) { buffer in
                    let metric = buffer.baseAddress!, power = metric + size
                    for q in 0..<count {
                        // Je Achse: Varianz in Stufeneinheiten N0·Norm/(2|H|²) → Faktor w/Norm.
                        let k = weights[q] / norm
                        let base = q * eta
                        for axis in 0..<2 {
                            let x = (axis == 0 ? re[q] : im[q]) * scale
                            var best: Float = -.infinity
                            for i in 0..<size {
                                let d = x - lv[i]
                                metric[i] = -k * d * d
                                best = max(best, metric[i])
                            }
                            for i in 0..<size { power[i] = expf(metric[i] - best) }
                            for b in 0..<perAxis {
                                let shift = perAxis - 1 - b
                                var sum0: Float = 0, sum1: Float = 0
                                var best0: Float = -.infinity, best1: Float = -.infinity
                                for i in 0..<size {
                                    if (i >> shift) & 1 == 0 { sum0 += power[i]; best0 = max(best0, metric[i]) }
                                    else { sum1 += power[i]; best1 = max(best1, metric[i]) }
                                }
                                // Bei verschwindender Summe (weit entfernt) bleibt die Max-Log-Differenz.
                                let value = sum0 > 1e-30 && sum1 > 1e-30 ? logf(sum0) - logf(sum1) : best0 - best1
                                out[Int(pos[base + 2 * b + axis])] = value
                            }
                        }
                    }
                }
            }
        }
    }

    /// Max-Log-LLR einer Gray-PAM-Achse (Stufen auf ungeraden Zahlen):
    /// erstes Bit ∝ x, dann |x| − L/2, ||x| − L/2| − L/4 …
    @inline(__always)
    private static func axis(_ x: Float, levels: Int, weight: Float, into bits: inout [Float], stride: Int, offset: Int) {
        bits[offset] = x * weight
        var t = x
        var half = Float(1 << levels) / 2
        for i in 1..<levels {
            t = abs(t) - half
            bits[offset + stride * i] = t * weight
            half /= 2
        }
    }

    // Gedrehte Konstellation: 2D-Max-Log über alle Punkte; Q-Anteil von Zelle q steckt in Zelle q+1.
    private lazy var rotatedPoints: [(re: Float, im: Float, bits: Int)] = {
        let eta = modulation.bitsPerCell, perAxis = eta / 2
        let scale = 1 / Self.norm(modulation).squareRoot()
        let phi = modulation.rotation * .pi / 180
        let c = Float(cos(phi)), s = Float(sin(phi))
        var points: [(Float, Float, Int)] = []
        let levels = 1 << perAxis
        for word in 0..<(1 << eta) {
            // Stufe der Achse, deren Gray-Bits y_offset, y_offset+2, … zum Wort passen.
            func level(_ offset: Int) -> Float {
                for l in 0..<levels {
                    let x = Float(2 * l - levels + 1)
                    var bits = [Float](repeating: 0, count: 8)
                    Self.axis(x, levels: perAxis, weight: 1, into: &bits, stride: 1, offset: 0)
                    let matches = (0..<perAxis).allSatisfy { i in
                        (bits[i] < 0 ? 1 : 0) == (word >> (eta - 1 - (offset + 2 * i))) & 1
                    }
                    if matches { return x }
                }
                return 0
            }
            let i = level(0) * scale, q = level(1) * scale
            points.append((c * i - s * q, s * i + c * q, word))
        }
        return points
    }()

    private func rotatedLLR(re: UnsafePointer<Float>, im: UnsafePointer<Float>, weights: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let eta = modulation.bitsPerCell
        let count = cells
        let points = rotatedPoints
        position.withUnsafeBufferPointer { pos in
            var best0 = [Float](repeating: 0, count: 8), best1 = best0
            for q in 0..<count {
                let next = (q + 1) % count
                let x = re[q], y = im[next]
                let wx = weights[q], wy = weights[next]
                for b in 0..<eta { best0[b] = .infinity; best1[b] = .infinity }
                for p in points {
                    let d = wx * (x - p.re) * (x - p.re) + wy * (y - p.im) * (y - p.im)
                    for b in 0..<eta {
                        if (p.bits >> (eta - 1 - b)) & 1 == 0 { best0[b] = min(best0[b], d) } else { best1[b] = min(best1[b], d) }
                    }
                }
                let base = q * eta
                for b in 0..<eta { out[Int(pos[base + b])] = best1[b] - best0[b] }
            }
        }
    }
}
