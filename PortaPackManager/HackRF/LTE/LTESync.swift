import Accelerate
import Foundation

/// Eingangsstufe: 8-Bit-IQ wandeln, mischen, dezimieren, Spektrum.
enum LTEFrontEnd {
    /// Aufnahmerate: 1280 · 15 kHz – teilt sich ganzzahlig auf 1,92 MS/s (÷ 10)
    /// und trägt bis 20-MHz-Zellen (FFT 1280, CP 100/90).
    static let captureRate = 19_200_000.0
    static let searchRate = 1_920_000.0
    static let decimation = 10

    /// Vorzeichenbehaftete 8-Bit-Paare → Float (÷ 128), Gleichanteil entfernt.
    static func convert(_ data: Data) -> (re: [Float], im: [Float]) {
        let n = data.count / 2
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Int8.self).baseAddress else { return }
            vDSP_vflt8(base, 2, &re, 1, vDSP_Length(n))
            vDSP_vflt8(base + 1, 2, &im, 1, vDSP_Length(n))
        }
        var scale: Float = 1.0 / 128
        vDSP_vsmul(re, 1, &scale, &re, 1, vDSP_Length(n))
        vDSP_vsmul(im, 1, &scale, &im, 1, vDSP_Length(n))
        removeDC(&re, &im)
        return (re, im)
    }

    static func removeDC(_ re: inout [Float], _ im: inout [Float]) {
        guard !re.isEmpty else { return }
        var meanRe: Float = 0, meanIm: Float = 0
        vDSP_meanv(re, 1, &meanRe, vDSP_Length(re.count))
        vDSP_meanv(im, 1, &meanIm, vDSP_Length(im.count))
        var negRe = -meanRe, negIm = -meanIm
        vDSP_vsadd(re, 1, &negRe, &re, 1, vDSP_Length(re.count))
        vDSP_vsadd(im, 1, &negIm, &im, 1, vDSP_Length(im.count))
    }

    /// Anteil der Werte am Wandleranschlag (|I| oder |Q| ≥ 127).
    static func clippedFraction(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        let clipped = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int8.self).reduce(0) { $0 + ($1 >= 127 || $1 <= -127 ? 1 : 0) }
        }
        return Double(clipped) / Double(data.count)
    }

    /// Multipliziert mit e^(−j2π·hz·n/rate) (verschiebt das Signal um −hz).
    static func shift(_ re: inout [Float], _ im: inout [Float], hz: Double, rate: Double, startSample: Int = 0) {
        guard hz != 0 else { return }
        let n = re.count
        let chunk = 1024
        let step = -2 * Double.pi * hz / rate
        var phases = [Float](repeating: 0, count: chunk)
        var sines = [Float](repeating: 0, count: chunk), cosines = [Float](repeating: 0, count: chunk)
        var start = 0
        while start < n {
            let count = min(chunk, n - start)
            let base = (step * Double(start + startSample)).truncatingRemainder(dividingBy: 2 * .pi)
            for i in 0..<count { phases[i] = Float(base + step * Double(i)) }
            var c = Int32(count)
            vvsincosf(&sines, &cosines, phases, &c)
            for i in 0..<count {
                let r = re[start + i], q = im[start + i]
                re[start + i] = r * cosines[i] - q * sines[i]
                im[start + i] = r * sines[i] + q * cosines[i]
            }
            start += count
        }
    }

    /// Tiefpass (gefenstertes Sinc, Blackman), Gleichanteilverstärkung 1.
    static func lowpass(cutoff: Double, rate: Double, taps: Int) -> [Float] {
        let m = Double(taps - 1)
        var h = (0..<taps).map { i -> Double in
            let x = Double(i) - m / 2
            let sinc = x == 0 ? 2 * cutoff / rate : sin(2 * .pi * cutoff / rate * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / m) + 0.08 * cos(4 * .pi * Double(i) / m)
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map { Float($0) }
    }

    private static let searchFilter = lowpass(cutoff: 1_000_000, rate: captureRate, taps: 161)

    /// Schneidet den 1,92-MS/s-Kanal um `offsetHz` aus einer 19,2-MS/s-Aufnahme.
    static func channel(re: [Float], im: [Float], offsetHz: Double) -> (re: [Float], im: [Float]) {
        var r = re, q = im
        shift(&r, &q, hz: offsetHz, rate: captureRate)
        let filter = searchFilter
        let taps = filter.count
        guard r.count > taps else { return ([], []) }
        let outCount = (r.count - taps) / decimation + 1
        var outRe = [Float](repeating: 0, count: outCount), outIm = [Float](repeating: 0, count: outCount)
        vDSP_desamp(r, vDSP_Stride(decimation), filter, &outRe, vDSP_Length(outCount), vDSP_Length(taps))
        vDSP_desamp(q, vDSP_Stride(decimation), filter, &outIm, vDSP_Length(outCount), vDSP_Length(taps))
        return (outRe, outIm)
    }

    /// Mittleres Leistungsspektrum (dB, Mitte in der Mitte) mit FFT `size` (Hann-Fenster).
    static func powerSpectrum(re: [Float], im: [Float], size: Int = 1280, maxFrames: Int = 300) -> [Float] {
        let fft = LTEFFT(size: size)
        let frames = min(maxFrames, re.count / size)
        guard frames > 0 else { return [] }
        let step = re.count / size / frames * size
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var sum = [Float](repeating: 0, count: size)
        var wr = [Float](repeating: 0, count: size), wi = [Float](repeating: 0, count: size)
        var outRe = [Float](repeating: 0, count: size), outIm = [Float](repeating: 0, count: size)
        var power = [Float](repeating: 0, count: size)
        for f in 0..<frames {
            let base = f * step
            re.withUnsafeBufferPointer { r in vDSP_vmul(r.baseAddress! + base, 1, window, 1, &wr, 1, vDSP_Length(size)) }
            im.withUnsafeBufferPointer { q in vDSP_vmul(q.baseAddress! + base, 1, window, 1, &wi, 1, vDSP_Length(size)) }
            fft.forward(re: wr, im: wi, outRe: &outRe, outIm: &outIm)
            outRe.withUnsafeMutableBufferPointer { a in
                outIm.withUnsafeMutableBufferPointer { b in
                    var split = DSPSplitComplex(realp: a.baseAddress!, imagp: b.baseAddress!)
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size))
                }
            }
            vDSP_vadd(sum, 1, power, 1, &sum, 1, vDSP_Length(size))
        }
        let norm = Float(frames) * Float(size) * Float(size) / 4
        return (0..<size).map { i in
            let bin = (i + size / 2) % size
            return 10 * log10(max(sum[bin] / norm, 1e-15))
        }
    }
}

/// Ein Fund der Zellsuche: Synchronisation über PSS und SSS.
struct LTESyncHit: Sendable, Equatable {
    var nid1: Int
    var nid2: Int
    var extendedCP: Bool
    var tdd: Bool
    /// Beginn eines Funkrahmens (Teilrahmen 0) in Abtastwerten bei 1,92 MS/s, 0 ≤ Wert < 19 200.
    var frameStart: Int
    /// Frequenzablage des Signals gegenüber der Abstimmfrequenz.
    var cfoHz: Double
    /// PSS-Spitze über dem Median (linear).
    var pssStrength: Double
    /// SSS-Korrelation in Vielfachen der Streuung.
    var sssScore: Double

    var pci: Int { 3 * nid1 + nid2 }
}

/// Primäre und sekundäre Synchronisationssignale (36.211 6.11) und die Zellsuche.
enum LTECellSearch {
    static let pssRoots = [25, 29, 34]
    static let numerologyNormal = LTENumerology(fftSize: 128, extendedCP: false)
    static let numerologyExtended = LTENumerology(fftSize: 128, extendedCP: true)
    /// PSS-Wiederholung (5 ms) bei 1,92 MS/s.
    static let halfFrame = 9600

    /// Zadoff-Chu-Folge d(0..61).
    static func pss(_ nid2: Int) -> [LTEC] {
        let u = Double(pssRoots[nid2])
        return (0..<62).map { n -> LTEC in
            let nn = Double(n)
            let arg = n <= 30 ? -Double.pi * u * nn * (nn + 1) / 63 : -Double.pi * u * (nn + 1) * (nn + 2) / 63
            return LTEC.cis(arg)
        }
    }

    /// Vorzeichenbehaftete Frequenzzahl des PSS/SSS-Elements n (ohne DC).
    static func frequencyIndex(_ n: Int) -> Int { n < 31 ? n - 31 : n - 30 }

    private static func mSequence(taps: [Int]) -> [Int] {
        var x = [0, 0, 0, 0, 1]
        for i in 0..<26 { x.append(taps.reduce(0) { $0 ^ x[i + $1] }) }
        return x.map { 1 - 2 * $0 }
    }

    private static let sTilde = mSequence(taps: [2, 0])
    private static let cTilde = mSequence(taps: [3, 0])
    private static let zTilde = mSequence(taps: [4, 2, 1, 0])

    /// d(0..61) des SSS; `subframe5`: Folge der zweiten Rahmenhälfte.
    static func sss(nid1: Int, nid2: Int, subframe5: Bool) -> [Float] {
        let qPrime = nid1 / 30
        let q = (nid1 + qPrime * (qPrime + 1) / 2) / 30
        let mPrime = nid1 + q * (q + 1) / 2
        let m0 = mPrime % 31
        let m1 = (m0 + mPrime / 31 + 1) % 31
        var d = [Float](repeating: 0, count: 62)
        for n in 0..<31 {
            let s0 = sTilde[(n + m0) % 31], s1 = sTilde[(n + m1) % 31]
            let c0 = cTilde[(n + nid2) % 31], c1 = cTilde[(n + nid2 + 3) % 31]
            let z0 = zTilde[(n + m0 % 8) % 31], z1 = zTilde[(n + m1 % 8) % 31]
            if subframe5 {
                d[2 * n] = Float(s1 * c0)
                d[2 * n + 1] = Float(s0 * c1 * z1)
            } else {
                d[2 * n] = Float(s0 * c0)
                d[2 * n + 1] = Float(s1 * c1 * z0)
            }
        }
        return d
    }

    private static let sssTable: [[[Float]]] = (0..<3).map { nid2 in
        (0..<336).map { sss(nid1: $0 / 2, nid2: nid2, subframe5: $0 % 2 == 1) }
    }

    /// Nutzteil des PSS-Symbols im Zeitbereich (Energie 1) für FFT-Größe `size`.
    static func pssTemplate(_ nid2: Int, size: Int) -> (re: [Float], im: [Float]) {
        let d = pss(nid2)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        for n in 0..<62 {
            let bin = (frequencyIndex(n) + size) % size
            re[bin] = d[n].re
            im[bin] = d[n].im
        }
        let t = LTEFFT(size: size).inverse(re, im)
        var energy: Float = 0
        for i in 0..<size { energy += t.re[i] * t.re[i] + t.im[i] * t.im[i] }
        let scale = 1 / energy.squareRoot()
        return (t.re.map { $0 * scale }, t.im.map { $0 * scale })
    }

    private static let templates128 = (0..<3).map { pssTemplate($0, size: 128) }

    /// Sucht Zellen in einem 1,92-MS/s-Signal. `cfoHypotheses` in Hz (Raster
    /// ≤ 10 kHz); die Feinablage folgt aus den PSS-Hälften und dem CP.
    /// `only`: nur diese PCI (zum Wiederfinden einer bekannten Zelle).
    static func search(re: [Float], im: [Float], cfoHypotheses: [Double], only: Int? = nil,
                       maxCells: Int = 4, threshold: Double = 6) -> [LTESyncHit] {
        let n = re.count
        let size = 128
        let outCount = n - size
        guard outCount > halfFrame + 2000 else { return [] }
        let rate = LTEFrontEnd.searchRate

        // Fensterenergie über 128 Werte
        var power = [Float](repeating: 0, count: n)
        vDSP_vmma(re, 1, re, 1, im, 1, im, 1, &power, 1, vDSP_Length(n))
        var energy = [Float](repeating: 0, count: outCount)
        var running: Float = 0
        for i in 0..<size { running += power[i] }
        for t in 0..<outCount {
            energy[t] = running
            running += power[t + size] - power[t]
        }
        var energyAcc = [Float](repeating: 0, count: halfFrame)
        for t in 0..<outCount { energyAcc[t % halfFrame] += max(energy[t], 1e-12) }

        struct Peak {
            var nid2: Int
            var hypothesis: Double
            var tau: Int
            var metric: Float
            var ratio: Double
            var cross: LTEC
        }
        var peaks: [Peak] = []
        let ids = only.map { [$0 % 3] } ?? [0, 1, 2]
        var c1Re = [Float](repeating: 0, count: outCount), c1Im = [Float](repeating: 0, count: outCount)
        var c2Re = [Float](repeating: 0, count: outCount), c2Im = [Float](repeating: 0, count: outCount)
        for nid2 in ids {
            let template = templates128[nid2]
            for f in cfoHypotheses {
                // Gedrehte, konjugierte Vorlage
                var fRe = [Float](repeating: 0, count: size), fIm = [Float](repeating: 0, count: size)
                for i in 0..<size {
                    let rot = LTEC.cis(2 * .pi * f * Double(i) / rate)
                    let t = LTEC(template.re[i], template.im[i]) * rot
                    fRe[i] = t.re
                    fIm[i] = -t.im
                }
                re.withUnsafeBufferPointer { rp in
                    im.withUnsafeBufferPointer { ip in
                        fRe.withUnsafeMutableBufferPointer { fr in
                            fIm.withUnsafeMutableBufferPointer { fi in
                                var signal = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                                                             imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                                var signal2 = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp.baseAddress! + 64),
                                                              imagp: UnsafeMutablePointer(mutating: ip.baseAddress! + 64))
                                var filter1 = DSPSplitComplex(realp: fr.baseAddress!, imagp: fi.baseAddress!)
                                var filter2 = DSPSplitComplex(realp: fr.baseAddress! + 64, imagp: fi.baseAddress! + 64)
                                c1Re.withUnsafeMutableBufferPointer { a in
                                    c1Im.withUnsafeMutableBufferPointer { b in
                                        var out = DSPSplitComplex(realp: a.baseAddress!, imagp: b.baseAddress!)
                                        vDSP_zconv(&signal, 1, &filter1, 1, &out, 1, vDSP_Length(outCount), 64)
                                    }
                                }
                                c2Re.withUnsafeMutableBufferPointer { a in
                                    c2Im.withUnsafeMutableBufferPointer { b in
                                        var out = DSPSplitComplex(realp: a.baseAddress!, imagp: b.baseAddress!)
                                        vDSP_zconv(&signal2, 1, &filter2, 1, &out, 1, vDSP_Length(outCount), 64)
                                    }
                                }
                            }
                        }
                    }
                }
                var acc = [Float](repeating: 0, count: halfFrame)
                for t in 0..<outCount {
                    acc[t % halfFrame] += c1Re[t] * c1Re[t] + c1Im[t] * c1Im[t] + c2Re[t] * c2Re[t] + c2Im[t] * c2Im[t]
                }
                var metric = [Float](repeating: 0, count: halfFrame)
                for t in 0..<halfFrame { metric[t] = acc[t] / energyAcc[t] }
                var sorted = metric
                vDSP_vsort(&sorted, vDSP_Length(halfFrame), 1)
                let median = max(sorted[halfFrame / 2], 1e-9)
                // Die stärksten Spitzen dieser Hypothese
                var used = [Bool](repeating: false, count: halfFrame)
                for _ in 0..<maxCells + 2 {
                    var best = -1
                    var bestValue: Float = 0
                    for t in 0..<halfFrame where !used[t] && metric[t] > bestValue {
                        bestValue = metric[t]
                        best = t
                    }
                    guard best >= 0 else { break }
                    let ratio = Double(bestValue / median)
                    guard ratio >= threshold else { break }
                    for d in -4...4 { used[(best + d + halfFrame) % halfFrame] = true }
                    var cross = LTEC.zero
                    var t = best
                    while t < outCount {
                        cross += LTEC(c2Re[t], c2Im[t]) * LTEC(c1Re[t], -c1Im[t])
                        t += halfFrame
                    }
                    peaks.append(Peak(nid2: nid2, hypothesis: f, tau: best, metric: bestValue, ratio: ratio, cross: cross))
                }
            }
        }
        // Gleiche Spitze aus mehreren Frequenzhypothesen: die stärkste behalten.
        peaks.sort { $0.ratio > $1.ratio }
        var chosen: [Peak] = []
        for peak in peaks {
            let duplicate = chosen.contains { other in
                other.nid2 == peak.nid2 && min(abs(other.tau - peak.tau), halfFrame - abs(other.tau - peak.tau)) <= 4
            }
            if !duplicate { chosen.append(peak) }
            if chosen.count >= maxCells { break }
        }

        var hits: [LTESyncHit] = []
        for peak in chosen {
            let fine = peak.cross.phase * rate / (2 * .pi * 64)
            let cfo = peak.hypothesis + fine
            var r = re, q = im
            LTEFrontEnd.shift(&r, &q, hz: cfo, rate: rate)
            guard var hit = detectSSS(re: r, im: q, nid2: peak.nid2, tau: peak.tau, only: only) else { continue }
            hit.cfoHz = cfo + cpResidual(re: r, im: q, hit: hit)
            hit.pssStrength = peak.ratio
            if !hits.contains(where: { $0.pci == hit.pci && abs($0.frameStart - hit.frameStart) < 8 }) {
                hits.append(hit)
            }
        }
        return hits
    }

    /// SSS-Erkennung an allen PSS-Stellen: CP-Länge, FDD/TDD, N_ID1, Rahmenlage.
    static func detectSSS(re: [Float], im: [Float], nid2: Int, tau: Int, only: Int? = nil) -> LTESyncHit? {
        let fft = LTEFFT(size: 128)
        let pssRef = pss(nid2)
        let advance = 2
        func symbol(at start: Int) -> [LTEC]? {
            let s = start - advance
            guard s >= 0, s + 128 <= re.count else { return nil }
            var outRe = [Float](repeating: 0, count: 128), outIm = [Float](repeating: 0, count: 128)
            re.withUnsafeBufferPointer { rp in
                im.withUnsafeBufferPointer { ip in
                    fft.forward(re: rp.baseAddress! + s, im: ip.baseAddress! + s, outRe: &outRe, outIm: &outIm)
                }
            }
            return (0..<62).map { n in
                let m = frequencyIndex(n)
                let bin = (m + 128) % 128
                return LTEC(outRe[bin], outIm[bin]) * LTEC.cis(2 * .pi * Double(m * advance) / 128)
            }
        }
        var best: LTESyncHit?
        var bestScore = 0.0
        for extended in [false, true] {
            let num = extended ? numerologyExtended : numerologyNormal
            for tdd in [false, true] {
                // Lage des SSS relativ zum PSS-Nutzteil
                let sssOffset: Int
                if tdd {
                    let sf1 = -num.usefulStart(2)
                    sssOffset = sf1 - num.subframeLength + num.usefulStart(2 * num.symbolsPerSlot - 1)
                } else {
                    let sf = -num.usefulStart(num.symbolsPerSlot - 1)
                    sssOffset = sf + num.usefulStart(num.symbolsPerSlot - 2)
                }
                var z: [[Float]] = []
                var position = tau
                while position + 128 < re.count {
                    if let p = symbol(at: position), let s = symbol(at: position + sssOffset) {
                        z.append((0..<62).map { i in
                            let h = p[i] * pssRef[i].conj
                            return (s[i] * h.conj).re
                        })
                    } else {
                        z.append([Float](repeating: 0, count: 62))
                    }
                    position += halfFrame
                }
                guard !z.isEmpty else { continue }
                let spread = Double(z.reduce(Float(0)) { $0 + $1.reduce(0) { $0 + $1 * $1 } }).squareRoot()
                guard spread > 0 else { continue }
                let table = sssTable[nid2]
                let nid1Range = only.map { ($0 / 3)...($0 / 3) } ?? 0...167
                for nid1 in nid1Range {
                    for parity in 0..<2 {
                        var score: Float = 0
                        for (j, values) in z.enumerated() {
                            let sequence = table[2 * nid1 + ((j + parity) % 2)]
                            var dot: Float = 0
                            vDSP_dotpr(values, 1, sequence, 1, &dot, 62)
                            score += dot
                        }
                        let normalized = Double(score) / spread
                        if normalized > bestScore {
                            bestScore = normalized
                            // Halbrahmen j = 0 ist Teilrahmen 0, wenn parity == 0.
                            var frame: Int
                            if tdd {
                                frame = tau - num.usefulStart(2) - num.subframeLength
                            } else {
                                frame = tau - num.usefulStart(num.symbolsPerSlot - 1)
                            }
                            if parity == 1 { frame -= halfFrame }
                            frame = ((frame % num.frameLength) + num.frameLength) % num.frameLength
                            best = LTESyncHit(nid1: nid1, nid2: nid2, extendedCP: extended, tdd: tdd, frameStart: frame,
                                              cfoHz: 0, pssStrength: 0, sssScore: normalized)
                        }
                    }
                }
            }
        }
        guard let best, bestScore >= 5.5 else { return nil }
        return best
    }

    /// Restablage aus der CP-Korrelation aller Symbole (±7,5 kHz eindeutig).
    static func cpResidual(re: [Float], im: [Float], hit: LTESyncHit) -> Double {
        let num = hit.extendedCP ? numerologyExtended : numerologyNormal
        var acc = LTEC.zero
        var frame = hit.frameStart
        while frame < re.count {
            for sf in 0..<10 {
                for symbol in 0..<num.symbolsPerSubframe {
                    let useful = frame + sf * num.subframeLength + num.usefulStart(symbol)
                    let cp = num.cpLength(symbol % num.symbolsPerSlot)
                    let start = useful - cp
                    guard start >= 0, useful + 128 <= re.count else { continue }
                    for i in start..<useful {
                        acc += LTEC(re[i], im[i]) * LTEC(re[i + 128], -im[i + 128])
                    }
                }
            }
            frame += num.frameLength
        }
        guard acc.norm > 0 else { return 0 }
        // r(n)·r*(n+N) = e^(−j2πfN/fs)
        return -acc.phase * LTEFrontEnd.searchRate / (2 * .pi * 128)
    }
}
