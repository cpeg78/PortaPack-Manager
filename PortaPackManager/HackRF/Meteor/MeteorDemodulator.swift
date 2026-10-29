import Accelerate
import Foundation

/// (O)QPSK-Demodulator für METEOR-M LRPT: Kanal herausmischen und
/// dezimieren, RRC-Matched-Filter (α 0,6), Takt mit Gardner, Träger mit
/// Costas-Schleife 4. Ordnung, grobe Frequenzsuche per FFT. Liefert weiche
/// Symbole (I, Q, I, Q, …) als Int8.
///
/// OQPSK (METEOR-M2-3/2-4): Q liegt eine halbe Symboldauer hinter I. Die
/// Taktschleife tastet in halben Symbolen ab; I kommt aus den geraden, Q aus
/// den ungeraden Zeitpunkten – so wird OQPSK zu QPSK, und der Costas-Fehler
/// gilt unverändert (Vorbild meteor_demod `demod_oqpsk`).
final class MeteorDemodulator {
    enum Modulation: String, Sendable {
        case qpsk, oqpsk
    }

    static let rolloff = 0.6
    static let constellationSize = 600

    let inputRate: Double
    let symbolRate: Double
    let modulation: Modulation
    let decimation: Int
    let rate: Double                      // nach der Dezimierung
    let samplesPerSymbol: Double

    // Mischer (Tabellen-NCO)
    private let mixStep: UInt32
    private var mixPhase: UInt32 = 0
    private static let tableBits = 12
    private static let cosTable: [Float] = (0..<(1 << tableBits)).map { Float(cos(2 * Double.pi * Double($0) / Double(1 << tableBits))) }
    private static let sinTable: [Float] = (0..<(1 << tableBits)).map { Float(sin(2 * Double.pi * Double($0) / Double(1 << tableBits))) }

    // Filter
    private let decimator: [Float]
    private let rrc: [Float]
    private var hRe: [Float] = [], hIm: [Float] = []
    private var rRe: [Float] = [], rIm: [Float] = []

    // AGC und Träger
    private var power: Float = 1
    private var carrierPhase: Float = 0
    private var carrierFrequency: Float = 0       // rad je Abtastwert (nach Dezimierung)
    private var alpha: Float = 0, beta: Float = 0
    private var lockMetric: Float = 0
    private(set) var locked = false

    // Takt
    private var history: [(Float, Float)] = [(0, 0), (0, 0), (0, 0), (0, 0)]
    private var tau: Double = 0
    private var halfStep: Double
    private let nominalHalfStep: Double
    private var halfIndex = 0
    private var halves: [(Float, Float)] = []     // letzte Halbsymbol-Abtastungen
    private var amplitude: Float = 1

    // Grobe Frequenzsuche
    private let fftSize = 4096
    private var fftBuffer: [(Float, Float)] = []
    private var fftAverage: [Float]
    private var fftCount = 0
    private let dft: vDSP.DiscreteFourierTransform<Float>?

    // Anzeige
    private(set) var constellation: [(Float, Float)] = []
    private var constellationIndex = 0
    private(set) var levelDB: Float = -100

    /// Frequenzablage des Trägers in Hz (positiv = Signal liegt höher).
    var frequencyOffset: Double { Double(carrierFrequency) * rate / (2 * .pi) }

    /// `offset`: Lage des Kanals relativ zur Mittenfrequenz der Abtastwerte.
    init(inputRate: Double, offset: Double, symbolRate: Double = 72_000, modulation: Modulation = .oqpsk) {
        self.inputRate = inputRate
        self.symbolRate = symbolRate
        self.modulation = modulation
        decimation = max(1, Int(inputRate / (4 * symbolRate)))
        rate = inputRate / Double(decimation)
        samplesPerSymbol = rate / symbolRate
        nominalHalfStep = samplesPerSymbol / 2
        halfStep = nominalHalfStep
        let step = (-offset / inputRate).truncatingRemainder(dividingBy: 1)
        mixStep = UInt32(truncatingIfNeeded: Int64((step < 0 ? step + 1 : step) * 4_294_967_296.0))
        if decimation > 1 {
            let cutoff = 0.5 * symbolRate * (1 + Self.rolloff) + 12_000
            let transition = max(rate / 2 - cutoff, 10_000)
            var taps = Int(5.5 * inputRate / transition) | 1
            taps = min(max(taps, 31), 401)
            decimator = RadioDemodulator.lowpass(taps: taps, cutoff: cutoff, rate: inputRate)
        } else {
            decimator = [1]
        }
        rrc = Self.rootRaisedCosine(samplesPerSymbol: samplesPerSymbol, rolloff: Self.rolloff, span: 8)
        fftAverage = [Float](repeating: 0, count: fftSize)
        dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: fftSize, direction: .forward,
                                                 transformType: .complexComplex, ofType: Float.self)
        setLoopBandwidth(0.02)
    }

    /// RRC-Impulsantwort, auf Energie 1 normiert.
    static func rootRaisedCosine(samplesPerSymbol sps: Double, rolloff a: Double, span: Int) -> [Float] {
        let count = Int(Double(span) * sps) | 1
        let center = Double(count - 1) / 2
        var h = (0..<count).map { i -> Double in
            let t = (Double(i) - center) / sps
            if abs(t) < 1e-9 { return 1 - a + 4 * a / .pi }
            if abs(abs(4 * a * t) - 1) < 1e-9 {
                return a / 2.0.squareRoot() * ((1 + 2 / .pi) * sin(.pi / (4 * a)) + (1 - 2 / .pi) * cos(.pi / (4 * a)))
            }
            return (sin(.pi * t * (1 - a)) + 4 * a * t * cos(.pi * t * (1 + a))) / (.pi * t * (1 - pow(4 * a * t, 2)))
        }
        let energy = h.reduce(0) { $0 + $1 * $1 }.squareRoot()
        h = h.map { $0 / energy }
        return h.map(Float.init)
    }

    /// Schleifenbandbreite (normiert auf die Symbolrate), Dämpfung 0,707.
    private func setLoopBandwidth(_ bn: Float) {
        let zeta: Float = 0.707
        let theta = bn / (zeta + 1 / (4 * zeta))
        let d = 1 + 2 * zeta * theta + theta * theta
        alpha = 4 * zeta * theta / d / 1.41      // Detektorverstärkung ≈ √2
        beta = 4 * theta * theta / d / 1.41
    }

    func reset() {
        hRe = []; hIm = []; rRe = []; rIm = []
        carrierPhase = 0; carrierFrequency = 0; lockMetric = 0; locked = false
        tau = 0; halfStep = nominalHalfStep; halfIndex = 0; halves = []
        fftBuffer = []; fftCount = 0; fftAverage = [Float](repeating: 0, count: fftSize)
        setLoopBandwidth(0.02)
    }

    /// HackRF-Block (8-Bit-IQ).
    func process(_ iq: Data) -> [Int8] {
        let n = iq.count / 2
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        iq.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int8.self)
            for i in 0..<n {
                re[i] = Float(s[2 * i]) / 128
                im[i] = Float(s[2 * i + 1]) / 128
            }
        }
        return process(re: re, im: im)
    }

    /// Komplexe Abtastwerte mit `inputRate`.
    func process(re inRe: [Float], im inIm: [Float]) -> [Int8] {
        var re = inRe, im = inIm
        if mixStep != 0 {
            let shift = UInt32(32 - Self.tableBits)
            var phase = mixPhase
            Self.cosTable.withUnsafeBufferPointer { ct in
                Self.sinTable.withUnsafeBufferPointer { st in
                    for i in 0..<re.count {
                        let k = Int(phase >> shift)
                        let c = ct[k], s = st[k]
                        let r = re[i], m = im[i]
                        re[i] = r * c - m * s
                        im[i] = r * s + m * c
                        phase &+= mixStep
                    }
                }
            }
            mixPhase = phase
        }
        var (dRe, dIm) = decimation > 1
            ? RadioDemodulator.decimateComplex(re, im, history: &hRe, &hIm, filter: decimator, factor: decimation)
            : (re, im)
        guard !dRe.isEmpty else { return [] }
        var p: Float = 0, q: Float = 0
        vDSP_measqv(dRe, 1, &p, vDSP_Length(dRe.count))
        vDSP_measqv(dIm, 1, &q, vDSP_Length(dIm.count))
        levelDB = 10 * log10(max(p + q, 1e-12))
        if !locked { coarseFrequency(dRe, dIm) }
        (dRe, dIm) = RadioDemodulator.decimateComplex(dRe, dIm, history: &rRe, &rIm, filter: rrc, factor: 1)
        return demodulate(dRe, dIm)
    }

    /// Mittelt Leistungsspektren und setzt den Träger auf den Schwerpunkt
    /// des Signals (±1,2 × Symbolrate um die Mitte), solange nicht gerastet.
    private func coarseFrequency(_ re: [Float], _ im: [Float]) {
        guard let dft else { return }
        for i in 0..<re.count {
            fftBuffer.append((re[i], im[i]))
            guard fftBuffer.count == fftSize else { continue }
            let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
            let bRe = (0..<fftSize).map { fftBuffer[$0].0 * window[$0] }
            let bIm = (0..<fftSize).map { fftBuffer[$0].1 * window[$0] }
            fftBuffer.removeAll(keepingCapacity: true)
            var oRe = [Float](repeating: 0, count: fftSize), oIm = [Float](repeating: 0, count: fftSize)
            dft.transform(inputReal: bRe, inputImaginary: bIm, outputReal: &oRe, outputImaginary: &oIm)
            for k in 0..<fftSize { fftAverage[k] += oRe[k] * oRe[k] + oIm[k] * oIm[k] }
            fftCount += 1
            if fftCount == 8 { estimateFromSpectrum() }
        }
    }

    private func estimateFromSpectrum() {
        defer {
            fftCount = 0
            fftAverage = [Float](repeating: 0, count: fftSize)
        }
        let binHz = rate / Double(fftSize)
        let span = Int(1.2 * symbolRate / binHz)
        guard span * 2 < fftSize else { return }
        var bins: [(Double, Float)] = []
        for k in -span...span {
            bins.append((Double(k) * binHz, fftAverage[(k + fftSize) % fftSize]))
        }
        let sorted = bins.map(\.1).sorted()
        let floor = sorted[sorted.count / 5]
        let peak = sorted[sorted.count - 1 - sorted.count / 20]
        // Nur bei deutlichem Signal (≥ 4 dB über dem Rauschen) nachführen.
        guard peak > floor * 2.5 else { return }
        // Signalbreite ist bekannt: Lage mit der besten Energie im Fenster (1+α)/2·Rs.
        let half = Int(0.5 * symbolRate * (1 + Self.rolloff) / binHz)
        var bestCenter = 0, bestSum: Float = -1
        for c in stride(from: -span + half, through: span - half, by: 1) {
            var sum: Float = 0
            for k in (c - half)...(c + half) { sum += max(0, bins[k + span].1 - floor) }
            if sum > bestSum { bestSum = sum; bestCenter = c }
        }
        let estimate = Double(bestCenter) * binHz
        carrierFrequency = Float(2 * .pi * estimate / rate)
    }

    @inline(__always)
    private func interpolate(_ mu: Float) -> (Float, Float) {
        // Kubische Lagrange-Interpolation zwischen history[1] und history[2].
        let m1 = history[0], p0 = history[1], p1 = history[2], p2 = history[3]
        let c0 = -mu * (mu - 1) * (mu - 2) / 6
        let c1 = (mu + 1) * (mu - 1) * (mu - 2) / 2
        let c2 = -(mu + 1) * mu * (mu - 2) / 2
        let c3 = (mu + 1) * mu * (mu - 1) / 6
        return (c0 * m1.0 + c1 * p0.0 + c2 * p1.0 + c3 * p2.0,
                c0 * m1.1 + c1 * p0.1 + c2 * p1.1 + c3 * p2.1)
    }

    private func demodulate(_ re: [Float], _ im: [Float]) -> [Int8] {
        var soft: [Int8] = []
        soft.reserveCapacity(Int(Double(re.count) / samplesPerSymbol * 2) + 4)
        let sps = Float(samplesPerSymbol)
        for i in 0..<re.count {
            // AGC
            let pw = re[i] * re[i] + im[i] * im[i]
            power += 0.0005 * (pw - power)
            let gain = 1 / max(power, 1e-12).squareRoot()
            // Träger zurückdrehen
            let c = cos(carrierPhase), s = sin(carrierPhase)
            let x = (re[i] * c + im[i] * s) * gain
            let y = (im[i] * c - re[i] * s) * gain
            carrierPhase += carrierFrequency
            if carrierPhase > .pi { carrierPhase -= 2 * .pi } else if carrierPhase < -.pi { carrierPhase += 2 * .pi }
            history[0] = history[1]; history[1] = history[2]; history[2] = history[3]; history[3] = (x, y)

            tau -= 1
            while tau < -1 {
                let mu = Float(max(0, min(1, tau + 2)))
                halves.append(interpolate(mu))
                if halves.count > 4 { halves.removeFirst(halves.count - 4) }
                halfIndex += 1
                tau += halfStep
                // Symbol vollständig: QPSK nach dem Haupt-, OQPSK nach dem Halbzeitpunkt.
                let complete = modulation == .qpsk ? halfIndex % 2 == 0 : halfIndex % 2 == 1
                if complete, halves.count == 4 {
                    symbol(&soft, sps: sps)
                }
            }
        }
        return soft
    }

    /// Wertet die letzten Halbsymbole aus: Gardner, Costas, weiche Werte.
    private func symbol(_ soft: inout [Int8], sps: Float) {
        let zI: Float, zQ: Float, error: Float
        if modulation == .qpsk {
            // halves: [k−1, k−½, k] an den Positionen 1, 2, 3.
            let prev = halves[1], mid = halves[2], cur = halves[3]
            zI = cur.0; zQ = cur.1
            error = mid.0 * (prev.0 - cur.0) + mid.1 * (prev.1 - cur.1)
        } else {
            // I an geraden, Q an ungeraden Halbzeitpunkten: [I k−1, Q k−1, I k, Q k].
            let i0 = halves[0], q0 = halves[1], i1 = halves[2], q1 = halves[3]
            zI = i1.0; zQ = q1.1
            error = q0.0 * (i0.0 - i1.0) + i1.1 * (q0.1 - q1.1)
        }
        // Takt: spät abgetastet → Fehler negativ → früher.
        let timing = Double(max(-1, min(1, error)))
        tau += 0.08 * timing * Double(sps / 4)
        halfStep += 0.0002 * timing
        halfStep = max(nominalHalfStep * 0.995, min(nominalHalfStep * 1.005, halfStep))

        // Costas (QPSK, Punkte auf den Diagonalen)
        let sI: Float = zI >= 0 ? 1 : -1, sQ: Float = zQ >= 0 ? 1 : -1
        let phaseError = max(-1, min(1, sI * zQ - sQ * zI))
        carrierPhase += alpha * phaseError
        carrierFrequency += beta * phaseError / sps
        let limit = Float(2 * Double.pi * 0.25 * symbolRate / rate)
        carrierFrequency = max(-limit, min(limit, carrierFrequency))

        // Rastererkennung: −cos 4φ ≈ 1 auf den Diagonalen.
        let r2 = zI * zI + zQ * zQ
        if r2 > 1e-9 {
            let c4 = (zI * zI * zI * zI - 6 * zI * zI * zQ * zQ + zQ * zQ * zQ * zQ) / (r2 * r2)
            lockMetric += 0.002 * (-c4 - lockMetric)
        }
        if !locked, lockMetric > 0.5 {
            locked = true
            setLoopBandwidth(0.006)
        } else if locked, lockMetric < 0.25 {
            locked = false
            setLoopBandwidth(0.02)
        }

        amplitude += 0.002 * ((abs(zI) + abs(zQ)) / 2 - amplitude)
        let scale = 48 / max(amplitude, 1e-6)
        soft.append(Int8(max(-127, min(127, (zI * scale).rounded()))))
        soft.append(Int8(max(-127, min(127, (zQ * scale).rounded()))))

        if constellation.count < Self.constellationSize {
            constellation.append((zI / max(amplitude, 1e-6), zQ / max(amplitude, 1e-6)))
        } else {
            constellation[constellationIndex] = (zI / max(amplitude, 1e-6), zQ / max(amplitude, 1e-6))
            constellationIndex = (constellationIndex + 1) % Self.constellationSize
        }
    }

    /// Gütemaß der Rasterung (0…1).
    var lockQuality: Float { max(0, min(1, lockMetric)) }
}
