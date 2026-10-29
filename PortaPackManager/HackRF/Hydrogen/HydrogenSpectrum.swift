import Accelerate
import Foundation

/// Messverfahren der Grundlinienkorrektur.
enum HydrogenMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Abwechselnd LO = Mitte − x und Mitte + x; die Linie wandert im
    /// Basisband, der Frequenzgang des Empfängers nicht. (A − B)/B, gefaltet.
    case frequencySwitching
    /// Erst eine Referenz (kalter Himmel oder Abschlusswiderstand), dann die
    /// Messung mit derselben Einstellung: (S − R)/R.
    case reference

    var id: Self { self }
    var title: String {
        switch self {
        case .frequencySwitching: String(localized: "Frequenzumschaltung")
        case .reference: String(localized: "Referenzmessung")
        }
    }
}

/// Ein Spektrum über der Himmelsfrequenz: Werte relativ zum Systemrauschen
/// (0,01 = 1 % von T_sys), `nan` = ungültig.
struct HydrogenSpectrum: Sendable, Equatable {
    var startHz: Double
    var stepHz: Double
    var values: [Double]

    func frequencyHz(_ i: Int) -> Double { startHz + Double(i) * stepHz }
    var count: Int { values.count }
}

/// Aufbereitung ohne Gerät (testbar).
enum HydrogenProcessing {
    /// Nutzbarer Anteil des Basisbands (Filterflanken außen).
    static let usableFraction = 0.8
    /// Bins um die Gleichspannungsspitze, die verworfen werden.
    static let dcGuardBins = 3

    static func binHz(sampleRate: Double, fftSize: Int) -> Double { sampleRate / Double(fftSize) }

    /// Ist der (geshiftete) Bin nutzbar?
    static func usable(_ k: Int, fftSize: Int) -> Bool {
        let offset = k - fftSize / 2
        return abs(offset) > dcGuardBins && Double(abs(offset)) <= Double(fftSize / 2) * usableFraction
    }

    /// Versatz zwischen den beiden LO-Stellungen in ganzen Bins (B − A = 2x).
    static func shiftBins(offsetHz: Double, sampleRate: Double, fftSize: Int) -> Int {
        Int((2 * offsetHz / binHz(sampleRate: sampleRate, fftSize: fftSize)).rounded())
    }

    /// LO-Stellungen so, dass der Versatz genau ganze Bins beträgt.
    static func localOscillators(centerHz: Double, offsetHz: Double, sampleRate: Double, fftSize: Int) -> (a: Double, b: Double) {
        let shift = Double(shiftBins(offsetHz: offsetHz, sampleRate: sampleRate, fftSize: fftSize)) * binHz(sampleRate: sampleRate, fftSize: fftSize)
        return (centerHz - shift / 2, centerHz + shift / 2)
    }

    /// Frequenzumschaltung falten: q = (A − B)/B; die Linie steht in q bei
    /// f − LO_A positiv und bei f − LO_B negativ. L(f) = ½·(q[f−LO_A] − q[f−LO_B])
    /// – gültig, wo beide Basisbandstellen nutzbar sind (Mitte ± (Rand − x)).
    /// Achse: Himmelsfrequenz auf dem Raster von A.
    static func fold(a: [Double], b: [Double], loA: Double, loB: Double, sampleRate: Double) -> HydrogenSpectrum {
        let n = a.count
        let bin = binHz(sampleRate: sampleRate, fftSize: n)
        let shift = Int(((loB - loA) / bin).rounded())
        var q = [Double](repeating: .nan, count: n)
        for k in 0..<n where usable(k, fftSize: n) && b[k] > 0 { q[k] = (a[k] - b[k]) / b[k] }
        var out = [Double](repeating: .nan, count: n)
        for k in 0..<n {
            let kb = k - shift
            guard kb >= 0, kb < n, q[k].isFinite, q[kb].isFinite else { continue }
            out[k] = 0.5 * (q[k] - q[kb])
        }
        // Auf den gültigen Bereich zuschneiden.
        guard let first = out.firstIndex(where: \.isFinite), let last = out.lastIndex(where: \.isFinite) else {
            return HydrogenSpectrum(startHz: loA, stepHz: bin, values: [])
        }
        return HydrogenSpectrum(startHz: loA + Double(first - n / 2) * bin, stepHz: bin, values: Array(out[first...last]))
    }

    /// Referenzverfahren: (S − R)/R auf dem nutzbaren Basisband.
    static func referenceRatio(signal s: [Double], reference r: [Double], lo: Double, sampleRate: Double) -> HydrogenSpectrum {
        let n = s.count
        let bin = binHz(sampleRate: sampleRate, fftSize: n)
        var out = [Double](repeating: .nan, count: n)
        for k in 0..<n where usable(k, fftSize: n) && r[k] > 0 { out[k] = (s[k] - r[k]) / r[k] }
        guard let first = out.firstIndex(where: \.isFinite), let last = out.lastIndex(where: \.isFinite) else {
            return HydrogenSpectrum(startHz: lo, stepHz: bin, values: [])
        }
        return HydrogenSpectrum(startHz: lo + Double(first - n / 2) * bin, stepHz: bin, values: Array(out[first...last]))
    }

    /// Gleitender Mittelwert über `width` Bins (ungültige Werte übersprungen).
    static func smooth(_ values: [Double], width: Int) -> [Double] {
        guard width > 1 else { return values }
        let half = width / 2
        var out = [Double](repeating: .nan, count: values.count)
        for i in values.indices where values[i].isFinite {
            var sum = 0.0, n = 0
            for j in max(0, i - half)...min(values.count - 1, i + half) where values[j].isFinite {
                sum += values[j]; n += 1
            }
            out[i] = sum / Double(n)
        }
        return out
    }

    /// Polynom-Grundlinie (Grad 0…3) außerhalb des ausgeschlossenen Bereichs
    /// anpassen und abziehen. `x`: Abszisse je Wert (z. B. km/s).
    static func subtractBaseline(_ values: [Double], x: [Double], exclude: ClosedRange<Double>, order: Int) -> [Double] {
        guard order >= 0 else { return values }
        let points = values.indices.filter { values[$0].isFinite && !exclude.contains(x[$0]) }
        let terms = order + 1
        guard points.count > terms * 3 else { return values }
        // Abszisse normieren (numerisch stabil).
        let xs = points.map { x[$0] }
        let mid = (xs.min()! + xs.max()!) / 2, scale = max(1e-9, (xs.max()! - xs.min()!) / 2)
        var ata = [Double](repeating: 0, count: terms * terms)
        var atb = [Double](repeating: 0, count: terms)
        for i in points {
            let u = (x[i] - mid) / scale
            var powers = [Double](repeating: 1, count: terms)
            for p in 1..<max(terms, 1) where p < terms { powers[p] = powers[p - 1] * u }
            for r in 0..<terms {
                atb[r] += powers[r] * values[i]
                for c in 0..<terms { ata[r * terms + c] += powers[r] * powers[c] }
            }
        }
        guard let coeff = solve(ata, atb, n: terms) else { return values }
        return values.indices.map { i in
            guard values[i].isFinite else { return .nan }
            let u = (x[i] - mid) / scale
            var y = 0.0, p = 1.0
            for c in coeff { y += c * p; p *= u }
            return values[i] - y
        }
    }

    /// Gauß-Elimination mit Pivotsuche für kleine Systeme.
    static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var m = a, v = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0 * n + col]) < abs(m[$1 * n + col]) }), abs(m[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for c in 0..<n { m.swapAt(col * n + c, pivot * n + c) }
                v.swapAt(col, pivot)
            }
            for r in (col + 1)..<n {
                let f = m[r * n + col] / m[col * n + col]
                for c in col..<n { m[r * n + c] -= f * m[col * n + c] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for c in (r + 1)..<n { s -= m[r * n + c] * x[c] }
            x[r] = s / m[r * n + r]
        }
        return x
    }

    /// Fertig aufbereitete Kurve: Abszisse (MHz oder km/s LSR) und Werte.
    struct Curve: Sendable {
        var mhz: [Double]
        var velocity: [Double]
        var values: [Double]

        /// Höchster Wert im Bereich |v| ≤ limit.
        func peak(limit: Double = 300) -> (velocity: Double, mhz: Double, value: Double)? {
            var best: Int?
            for i in values.indices where values[i].isFinite && abs(velocity[i]) <= limit {
                if best == nil || values[i] > values[best!] { best = i }
            }
            return best.map { (velocity[$0], mhz[$0], values[$0]) }
        }

        /// Schwerpunkt (km/s) der Werte über der halben Höhe um das Maximum –
        /// robuster als das Maximum allein, das bei breiten Linien im Rauschen wandert.
        func centroid(limit: Double = 300) -> Double? {
            guard let peak = peak(limit: limit), peak.value > 0,
                  let top = values.indices.first(where: { velocity[$0] == peak.velocity }) else { return nil }
            var lo = top, hi = top
            while lo > 0, values[lo - 1].isFinite, values[lo - 1] >= peak.value / 2 { lo -= 1 }
            while hi < values.count - 1, values[hi + 1].isFinite, values[hi + 1] >= peak.value / 2 { hi += 1 }
            var sum = 0.0, weight = 0.0
            for i in lo...hi { sum += velocity[i] * values[i]; weight += values[i] }
            return weight > 0 ? sum / weight : nil
        }

        /// Streuung außerhalb des Linienbereichs (Rauschen).
        func noise(exclude: ClosedRange<Double>) -> Double? {
            let outside = values.indices.filter { values[$0].isFinite && !exclude.contains(velocity[$0]) }.map { values[$0] }
            guard outside.count > 10 else { return nil }
            let mean = outside.reduce(0, +) / Double(outside.count)
            return (outside.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(outside.count)).squareRoot()
        }
    }

    /// Glätten (Breite in kHz), Grundlinie abziehen, Achsen rechnen.
    static func curve(_ spectrum: HydrogenSpectrum, lsrCorrection: Double, smoothingKHz: Double,
                      baselineOrder: Int, excludeKmS: Double) -> Curve {
        let mhz = spectrum.values.indices.map { spectrum.frequencyHz($0) / 1e6 }
        let velocity = spectrum.values.indices.map { HydrogenAstronomy.velocity(frequencyHz: spectrum.frequencyHz($0)) + lsrCorrection }
        let width = Int((smoothingKHz * 1000 / spectrum.stepHz).rounded())
        var values = smooth(spectrum.values, width: width)
        if baselineOrder >= 0 {
            values = subtractBaseline(values, x: velocity, exclude: -excludeKmS...excludeKmS, order: baselineOrder)
        }
        return Curve(mhz: mhz, velocity: velocity, values: values)
    }
}

/// Summiert FFT-Leistungsspektren je Phase (Empfangsfaden).
final class HydrogenAccumulator: @unchecked Sendable {
    enum Phase: Sendable { case off, a, b }

    let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let lock = NSLock()
    private var phase = Phase.off
    private var sumA: [Double]
    private var sumB: [Double]
    private(set) var countA = 0
    private(set) var countB = 0

    init(fftSize: Int) {
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = w
        sumA = [Double](repeating: 0, count: fftSize)
        sumB = [Double](repeating: 0, count: fftSize)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func setPhase(_ p: Phase) { lock.withLock { phase = p } }

    func resetA() { lock.withLock { sumA = [Double](repeating: 0, count: fftSize); countA = 0 } }
    func resetB() { lock.withLock { sumB = [Double](repeating: 0, count: fftSize); countB = 0 } }

    /// Mittelwerte (geshiftet, Index 0 = −fs/2) und Rahmenzahlen.
    func snapshot() -> (a: [Double], countA: Int, b: [Double], countB: Int) {
        lock.withLock {
            let half = fftSize / 2
            func shifted(_ s: [Double], _ n: Int) -> [Double] {
                guard n > 0 else { return [] }
                let scaled = s.map { $0 / Double(n) }
                return Array(scaled[half...] + scaled[..<half])
            }
            return (shifted(sumA, countA), countA, shifted(sumB, countB), countB)
        }
    }

    /// Setzt Summen wieder ein (Fortsetzen nach Pause).
    func restore(a: [Double], countA: Int, b: [Double], countB: Int) {
        lock.withLock {
            let half = fftSize / 2
            func unshift(_ s: [Double], _ n: Int) -> [Double] {
                guard s.count == fftSize, n > 0 else { return [Double](repeating: 0, count: fftSize) }
                let back = Array(s[half...] + s[..<half])   // n gerade: Shift ist sein eigenes Inverses
                return back.map { $0 * Double(n) }
            }
            sumA = unshift(a, countA); self.countA = a.count == fftSize ? countA : 0
            sumB = unshift(b, countB); self.countB = b.count == fftSize ? countB : 0
        }
    }

    func process(_ iq: Data) {
        let current = lock.withLock { phase }
        guard current != .off else { return }
        let n = fftSize
        let frames = iq.count / (2 * n)
        guard frames > 0 else { return }
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n)
        var block = [Double](repeating: 0, count: n)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: Int8.self).baseAddress!
            // Gleichanteil des Blocks abziehen (wie `SpectrumAnalyzer`).
            var sumI = 0, sumQ = 0
            for k in 0..<(frames * n) { sumI += Int(base[2 * k]); sumQ += Int(base[2 * k + 1]) }
            var dcI = -Float(sumI) / Float(frames * n), dcQ = -Float(sumQ) / Float(frames * n)
            for f in 0..<frames {
                let p = base + f * 2 * n
                vDSP_vflt8(p, 2, &re, 1, vDSP_Length(n))
                vDSP_vflt8(p + 1, 2, &im, 1, vDSP_Length(n))
                vDSP_vsadd(re, 1, &dcI, &re, 1, vDSP_Length(n))
                vDSP_vsadd(im, 1, &dcQ, &im, 1, vDSP_Length(n))
                vDSP_vmul(re, 1, window, 1, &re, 1, vDSP_Length(n))
                vDSP_vmul(im, 1, window, 1, &im, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n))
                    }
                }
                for k in 0..<n { block[k] += Double(power[k]) }
            }
        }
        lock.withLock {
            // Phase während der Rechnung gewechselt (umgestimmt)? Dann verwerfen.
            guard phase == current else { return }
            if current == .a {
                vDSP_vaddD(sumA, 1, block, 1, &sumA, 1, vDSP_Length(n)); countA += frames
            } else {
                vDSP_vaddD(sumB, 1, block, 1, &sumB, 1, vDSP_Length(n)); countB += frames
            }
        }
    }
}
