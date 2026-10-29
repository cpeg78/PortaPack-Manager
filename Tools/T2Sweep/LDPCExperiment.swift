import Foundation

// Zellebene ohne OFDM: K23-FEC-Blöcke (64-QAM 1/2, 64K) mit Gaußrauschen,
// verschiedene Demapper und Dekoder im Vergleich. Trennt die Verluste von
// LLR-Bildung und LDPC von denen der Kanalschätzung.

enum LDPCExperiment {
    /// `app`: `T2BitMapper.llr` des Empfängers; `maxlog`/`logmap`: Bezugsrechnungen hier.
    enum Demapper: String { case app, maxlog, logmap }
    enum Decoder: String { case kernel, float, oms, nms, corr2, pwl }
    /// Parameter der Varianten (β für OMS in LLR-Einheiten, α für NMS).
    nonisolated(unsafe) static var beta: Float = 0.3
    nonisolated(unsafe) static var alpha: Float = 0.8

    static func run(snrs: [Double], blocks: Int, demapper: Demapper, decoder: Decoder, iterations: Int, rayleigh: Bool) {
        let tx = T2TestTransmitter(seed: 5)
        let fec = tx.fec
        let code = T2LDPCCode.code(fec)
        let mapper = T2BitMapper.mapper(fec: fec, modulation: tx.modulation, rotated: false)
        print("# Zellebene: \(demapper.rawValue)-Demapper, \(decoder.rawValue)-Dekoder, \(iterations) Iterationen\(rayleigh ? ", 0-dB-Echo-Kanal" : "")")
        print("# Es/N0[dB]  gut/alle   mittl. Iter")
        var random = T2SimRandom(state: 77)
        let clock = Date()
        for snr in snrs {
            let n0 = Float(pow(10, -snr / 10))
            var good = 0, total = 0, iterSum = 0
            var batch: [[Float]] = []
            var words: [[UInt8]] = []
            func flush() {
                guard !batch.isEmpty else { return }
                switch decoder {
                case .kernel:
                    let d = T2LDPCBatchDecoder(code: code)
                    let out = d.decode(batch, maxIterations: iterations)
                    for (r, w) in zip(out, words) { total += 1; if r.ok && r.bits == w { good += 1 } }
                    iterSum += d.iterations * batch.count
                default:
                    for (llr, w) in zip(batch, words) {
                        let (bits, ok, it) = decoder == .float ? floatLayered(llr, code: code, maxIterations: iterations)
                            : variantLayered(llr, code: code, maxIterations: iterations, variant: decoder)
                        total += 1; if ok && bits == w { good += 1 }
                        iterSum += it
                    }
                }
                batch = []; words = []
            }
            for _ in 0..<blocks {
                let info = (0..<fec.kbch).map { _ in random.bit() }
                let word = tx.encode(info)
                let cells = tx.cells(word)
                let count = cells.re.count
                var re = cells.re, im = cells.im
                var w = [Float](repeating: 1 / n0, count: count)
                let sigma = (n0 / 2).squareRoot()
                for q in 0..<count {
                    if rayleigh {
                        // Zweiwegekanal 0 dB: H = 1 + e^{jφ}, φ gleichverteilt je Zelle, E|H|² = 2.
                        // C/N = E|H|²/N0 ⇒ N0 = 2·n0; entzerrt bleibt Rauschen N0/|H|².
                        let phi = Float(2 * Double.pi * random.uniform())
                        let h2 = max(1e-9, 2 + 2 * cos(phi))
                        let s = (2 * n0 / h2 / 2).squareRoot()
                        re[q] += s * random.gauss(); im[q] += s * random.gauss()
                        w[q] = h2 / (2 * n0)
                    } else {
                        re[q] += sigma * random.gauss(); im[q] += sigma * random.gauss()
                    }
                }
                var llr = [Float](repeating: 0, count: fec.nldpc)
                switch demapper {
                case .app:
                    re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in w.withUnsafeBufferPointer { wp in
                        llr.withUnsafeMutableBufferPointer { o in mapper.llr(re: r.baseAddress!, im: i.baseAddress!, weights: wp.baseAddress!, into: o.baseAddress!) }
                    } } }
                case .maxlog, .logmap:
                    exactLLR(re: re, im: im, weights: w, mapper: mapper, exact: demapper == .logmap, into: &llr)
                }
                batch.append(llr); words.append(word)
                if batch.count == 8 { flush() }
            }
            flush()
            print(String(format: "%9.2f  %4d/%-4d  %6.1f  %6.1f s", snr, good, total, Double(iterSum) / Double(max(1, total)), Date().timeIntervalSince(clock)))
            fflush(stdout)
        }
    }

    /// Max-Log- bzw. Log-MAP-LLR je Achse (positiv = 0), Gewicht = |H|²/N0.
    static func exactLLR(re: [Float], im: [Float], weights: [Float], mapper: T2BitMapper, exact: Bool, into out: inout [Float]) {
        let eta = mapper.modulation.bitsPerCell, perAxis = eta / 2
        let levels = T2TestTransmitter.levels(perAxis: perAxis)
        let scale = T2BitMapper.norm(mapper.modulation).squareRoot()
        let count = re.count
        for q in 0..<count {
            // Rauschvarianz je Achse in Stufeneinheiten: N0/2 · Norm / |H|² → Faktor 1/(2σ²) = w/Norm.
            let k = weights[q] / (scale * scale)
            for axis in 0..<2 {
                let x = (axis == 0 ? re[q] : im[q]) * scale
                for b in 0..<perAxis {
                    var best0 = -Float.infinity, best1 = -Float.infinity
                    var sum0: Float = 0, sum1: Float = 0
                    var metrics = [Float](repeating: 0, count: levels.count)
                    var maxMetric = -Float.infinity
                    for (index, level) in levels.enumerated() {
                        let d = x - level
                        metrics[index] = -k * d * d
                        maxMetric = max(maxMetric, metrics[index])
                    }
                    for (index, _) in levels.enumerated() {
                        let bit = (index >> (perAxis - 1 - b)) & 1
                        let m = metrics[index]
                        if bit == 0 { best0 = max(best0, m); sum0 += exp(m - maxMetric) } else { best1 = max(best1, m); sum1 += exp(m - maxMetric) }
                    }
                    let value = exact ? log(max(sum0, 1e-30)) - log(max(sum1, 1e-30)) : best0 - best1
                    out[Int(mapper.position[q * eta + 2 * b + axis])] = value
                }
            }
        }
    }

    /// Geschichtetes Sum-Product in Fließkomma (Bezug).
    static func floatLayered(_ llr: [Float], code: T2LDPCCode, maxIterations: Int) -> ([UInt8], Bool, Int) {
        var totals = llr
        var messages = [Float](repeating: 0, count: code.edges)
        var q = [Float](repeating: 0, count: 64)
        var bits = [UInt8](repeating: 0, count: code.n)
        for iteration in 1...maxIterations {
            for c in 0..<code.m {
                let start = Int(code.offsets[c]), end = Int(code.offsets[c + 1])
                var product: Double = 1
                var zeros = 0
                for e in start..<end {
                    let x = totals[Int(code.variables[e])] - messages[e]
                    q[e - start] = x
                    let t = tanh(Double(max(-40, min(40, x))) / 2)
                    if abs(t) < 1e-15 { zeros += 1 } else { product *= t }
                }
                for e in start..<end {
                    let x = q[e - start]
                    let t = tanh(Double(max(-40, min(40, x))) / 2)
                    var p: Double
                    if abs(t) < 1e-15 { p = zeros == 1 ? product : 0 } else { p = zeros > 0 ? 0 : product / t }
                    p = max(-0.999_999_999_9, min(0.999_999_999_9, p))
                    let out = Float(2 * atanh(p))
                    messages[e] = out
                    totals[Int(code.variables[e])] = x + out
                }
            }
            for v in 0..<code.n { bits[v] = totals[v] < 0 ? 1 : 0 }
            if bits.withUnsafeBufferPointer({ code.check($0.baseAddress!) }) { return (bits, true, iteration) }
        }
        return (bits, false, maxIterations)
    }

    /// x ⊞ y für Beträge (positiv), exakt.
    @inline(__always) static func boxplus(_ x: Float, _ y: Float) -> Float {
        min(x, y) + log1p(exp(-(x + y))) - log1p(exp(-abs(x - y)))
    }

    /// Stückweise lineare Korrektur: log(1+e^{−x}) ≈ max(0, 5/8 − x/4).
    @inline(__always) static func pwl(_ x: Float) -> Float { max(0, 0.625 - x / 4) }

    /// Geschichtete Varianten mit einfacher Prüfknotenrechnung.
    static func variantLayered(_ llr: [Float], code: T2LDPCCode, maxIterations: Int, variant: Decoder) -> ([UInt8], Bool, Int) {
        var totals = llr
        var messages = [Float](repeating: 0, count: code.edges)
        var q = [Float](repeating: 0, count: 64)
        var fwd = [Float](repeating: 0, count: 64), bwd = fwd
        var bits = [UInt8](repeating: 0, count: code.n)
        for iteration in 1...maxIterations {
            for c in 0..<code.m {
                let start = Int(code.offsets[c]), end = Int(code.offsets[c + 1])
                let d = end - start
                var m1 = Float.infinity, m2 = Float.infinity, m3 = Float.infinity
                var index1 = -1
                var negative = false
                for e in start..<end {
                    let x = totals[Int(code.variables[e])] - messages[e]
                    q[e - start] = x
                    let a = abs(x)
                    if x < 0 { negative.toggle() }
                    if a < m1 { m3 = m2; m2 = m1; m1 = a; index1 = e - start } else if a < m2 { m3 = m2; m2 = a } else if a < m3 { m3 = a }
                }
                if variant == .pwl {
                    // Vorwärts-rückwärts mit stückweise linearer Korrektur.
                    func bp(_ x: Float, _ y: Float) -> Float { max(0, min(x, y) + pwl(x + y) - pwl(abs(x - y))) }
                    fwd[0] = abs(q[0])
                    for j in 1..<d { fwd[j] = bp(fwd[j - 1], abs(q[j])) }
                    bwd[d - 1] = abs(q[d - 1])
                    for j in stride(from: d - 2, through: 0, by: -1) { bwd[j] = bp(bwd[j + 1], abs(q[j])) }
                    for j in 0..<d {
                        let mag = j == 0 ? bwd[1] : (j == d - 1 ? fwd[d - 2] : bp(fwd[j - 1], bwd[j + 1]))
                        let x = q[j]
                        let out = (negative != (x < 0)) ? -mag : mag
                        messages[start + j] = out
                        totals[Int(code.variables[start + j])] = x + out
                    }
                    continue
                }
                let others1: Float, othersMin: Float
                switch variant {
                case .oms:
                    others1 = max(0, m2 - beta); othersMin = max(0, m1 - beta)
                case .nms:
                    others1 = alpha * m2; othersMin = alpha * m1
                default: // corr2
                    others1 = max(0, boxplus(m2, m3) - beta); othersMin = max(0, boxplus(m1, m2) - beta)
                }
                for j in 0..<d {
                    let x = q[j]
                    let mag = j == index1 ? others1 : othersMin
                    let out = (negative != (x < 0)) ? -mag : mag
                    messages[start + j] = out
                    totals[Int(code.variables[start + j])] = x + out
                }
            }
            for v in 0..<code.n { bits[v] = totals[v] < 0 ? 1 : 0 }
            if bits.withUnsafeBufferPointer({ code.check($0.baseAddress!) }) { return (bits, true, iteration) }
        }
        return (bits, false, maxIterations)
    }
}
