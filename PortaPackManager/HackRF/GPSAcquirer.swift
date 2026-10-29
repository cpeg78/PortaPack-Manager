import Accelerate
import Foundation

/// Ergebnis der Akquisition eines Satelliten.
struct GPSFix: Sendable, Identifiable {
    let prn: Int
    let dopplerHz: Double      // Trägerablage (Satellitenbewegung + Empfängerdrift)
    let codePhaseChips: Double // Verschiebung des C/A-Codes in Chips
    let snrDB: Double          // Spitze/Mittel der Korrelation
    /// Spitze über der Schwelle aus der Falschalarmrate (`GPSDetection`).
    let acquired: Bool
    /// Grobe C/N0-Schätzung aus der Spitze (dB-Hz), 0 ohne Treffer.
    var cn0: Double = 0
    /// Gefunden von der Schwachsignal-Suche (kohärent 10 ms, viele Blöcke).
    var weak = false
    var id: Int { prn }

    static func none(_ prn: Int) -> GPSFix {
        GPSFix(prn: prn, dopplerHz: 0, codePhaseChips: 0, snrDB: 0, acquired: false)
    }
}

/// Schwelle der Akquisition aus der Falschalarmrate.
///
/// Ohne Signal ist die nichtkohärente Summe von M Korrelationsleistungen
/// (normiert auf die mittlere Rauschleistung eines Blocks) Gamma(M, 1)-verteilt.
/// Die Schwelle T erfüllt P(Gamma(M) > T) = Pfa je Zelle, mit
/// Pfa(Zelle) = Pfa(Suche) / Zahl der Zellen (Codephasen × Doppler-Stufen).
/// Verglichen wird Spitze/Mittel der Doppler-Zeile mit T/M.
enum GPSDetection {
    /// Falschalarmrate je Satellit und Suchlauf.
    static let searchFalseAlarm = 1e-4

    /// P(Gamma(m, 1) > t) für ganzzahliges m: e^−t · Σ_{k<m} t^k/k!.
    static func gammaTail(_ m: Int, _ t: Double) -> Double {
        var term = -t                        // log(t^k/k! · e^−t), k = 0
        var sum = 0.0
        var maxLog = -Double.infinity
        var logs = [Double]()
        logs.reserveCapacity(m)
        for k in 0..<m {
            if k > 0 { term += log(t) - log(Double(k)) }
            logs.append(term)
            maxLog = max(maxLog, term)
        }
        for l in logs { sum += exp(l - maxLog) }
        return exp(maxLog) * sum
    }

    /// Schwelle für Spitze/Mittel bei `blocks` nichtkohärenten Blöcken und `cells` Zellen.
    static func ratioThreshold(blocks m: Int, cells: Int, pfa: Double = searchFalseAlarm) -> Double {
        let target = pfa / Double(max(cells, 1))
        var lo = Double(m), hi = Double(m) + 20 * Double(m).squareRoot() + 60
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if gammaTail(m, mid) > target { lo = mid } else { hi = mid }
        }
        return hi / Double(m)
    }
}

/// GPS-L1-C/A-Akquisition per paralleler Code-Phasen-Suche (FFT).
///
/// Für jeden Satelliten und jede Doppler-Stufe wird das Signal mit dem
/// C/A-Code korreliert. Eine hohe, scharfe Spitze bedeutet: Dieser Satellit
/// ist zu empfangen. 2,048 MS/s → 1 ms = 2048 Abtastwerte = FFT-Größe.
///
/// Zwei Betriebsarten über dieselbe Rechnung (`search`):
/// - **Grobsuche** (`acquire`): 1 ms kohärent, 8 Blöcke nichtkohärent,
///   250-Hz-Raster – schnell, findet Satelliten ab ≈ 38 dB-Hz.
/// - **Schwachsignal-Suche** (`acquireWeak`): 10 ms kohärent (der Code ist
///   periodisch, die 10 ms werden vor der FFT auf 1 ms gefaltet), viele Blöcke
///   nichtkohärent, 50-Hz-Raster; die Codeverschiebung durch den Doppler wird
///   zwischen den Blöcken ausgeglichen. Ein Bitwechsel im Block kostet im
///   Mittel < 1 dB – hingenommen statt zwei Ausrichtungen zu rechnen.
///
/// Der Doppler f = 1000·K + r (K ganzzahlig, 0 ≤ r < 1000 Hz) wird zerlegt:
/// r wird vor der FFT abgezogen, K ist eine Verschiebung der FFT um K Stufen
/// (FFT-Auflösung 1 kHz). So braucht ein Block nur so viele FFTs, wie es
/// Reste r gibt – nicht eine je Doppler-Stufe.
final class GPSAcquirer: @unchecked Sendable {
    static let sampleRate: UInt32 = 2_048_000
    static let frequency: UInt64 = 1_575_420_000     // GPS L1
    static let fftSize = 2048
    static let dopplerSpanHz = 10_000.0
    static let dopplerStepHz = 500.0
    /// Nicht-kohärente Mittelung der Grobsuche (ms).
    static let integrationMs = 8
    /// Kohärente Länge der Schwachsignal-Suche (ms) und ihr Doppler-Raster.
    static let weakCoherentMs = 10
    static let weakStepHz = 50.0

    /// Suchauftrag der Schwachsignal-Suche: ein PRN und sein Doppler-Fenster.
    struct Target: Sendable, Equatable {
        var prn: Int
        var doppler: ClosedRange<Double>
    }

    /// Ein schon verfolgter, starker Satellit. Sein Code streut in die Codes
    /// anderer PRNs Nebenspitzen bis −21 dB (Kreuzkorrelation); eine Spitze,
    /// die er erklärt, ist kein Satellit. Ein einzelner Satellit mit 50 dB-Hz
    /// ließ die lange Suche sonst *alle* 31 übrigen PRNs „finden“.
    struct Interferer: Sendable, Equatable {
        var prn: Int
        var dopplerHz: Double
        /// Codephase der Replik (Kanal-Konvention, Chips) am ersten Abtastwert des Suchpuffers.
        var codePhase: Double
        var cn0: Double
    }

    private let log2n = vDSP_Length(log2(Double(fftSize)))
    private let setup: FFTSetup
    private let coarseStep: Double
    private let codeFFT: [(re: [Float], im: [Float])]  // je PRN: konj. FFT des Codes

    /// `dopplerStepHz`: Raster der Grobsuche. 500 Hz reicht zum Erkennen; für
    /// die Übergabe ans Tracking (FLL-Fangbereich ±250 Hz) nimmt der Empfänger 250 Hz.
    init(dopplerStepHz: Double = GPSAcquirer.dopplerStepHz) {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        coarseStep = dopplerStepHz
        let n = GPSAcquirer.fftSize

        // FFT jedes C/A-Codes, konjugiert (für die Korrelation per IFFT).
        let setup = self.setup
        let log2n = self.log2n
        var codes = [(re: [Float], im: [Float])]()
        for prn in 1...GPSCACode.prnCount {
            var re = GPSCACode.sampled(prn: prn, samples: n)
            var im = [Float](repeating: 0, count: n)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            var neg: Float = -1
            vDSP_vsmul(im, 1, &neg, &im, 1, vDSP_Length(n))
            codes.append((re, im))
        }
        codeFFT = codes
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Grobsuche über `integrationMs` Millisekunden. `samples` sind komplexe
    /// Werte bei 2,048 MS/s (re, im, re, im …), mindestens
    /// `fftSize · integrationMs` Paare. `prns` schränkt die Suche ein.
    /// Thread-sicher (nur unveränderliche Tabellen).
    func acquire(_ samples: [Float], prns: [Int]? = nil, interferers: [Interferer] = []) -> [GPSFix] {
        let span = GPSAcquirer.dopplerSpanHz
        let targets = (prns ?? Array(1...GPSCACode.prnCount)).map { Target(prn: $0, doppler: -span...span) }
        var fixes = search(samples, targets: targets, coherentMs: 1, blocks: GPSAcquirer.integrationMs,
                           step: coarseStep, interpolate: false, interferers: interferers)
        let searched = Set(fixes.map(\.prn))
        fixes += (1...GPSCACode.prnCount).filter { !searched.contains($0) }.map { GPSFix.none($0) }
        return fixes.sorted { $0.snrDB > $1.snrDB }
    }

    /// Schwachsignal-Suche: `coherentMs` kohärent, so viele Blöcke, wie
    /// `samples` hergeben (höchstens `maxBlocks`). Liefert nur die gesuchten PRNs.
    func acquireWeak(_ samples: [Float], targets: [Target], coherentMs: Int = GPSAcquirer.weakCoherentMs,
                     maxBlocks: Int = .max, interferers: [Interferer] = []) -> [GPSFix] {
        let available = samples.count / 2 / (GPSAcquirer.fftSize * coherentMs)
        let blocks = min(available, maxBlocks)
        guard blocks > 0 else { return [] }
        return search(samples, targets: targets, coherentMs: coherentMs, blocks: blocks,
                      step: GPSAcquirer.weakStepHz, interpolate: true, interferers: interferers)
            .map { var f = $0; f.weak = true; return f }
            .sorted { $0.snrDB > $1.snrDB }
    }

    // MARK: Rechnung

    /// Gemeinsamer Kern beider Suchen (siehe Typbeschreibung).
    private func search(_ samples: [Float], targets: [Target], coherentMs: Int, blocks: Int,
                        step: Double, interpolate: Bool, interferers: [Interferer]) -> [GPSFix] {
        let n = GPSAcquirer.fftSize
        let fs = Double(GPSAcquirer.sampleRate)
        guard !targets.isEmpty, samples.count >= 2 * n * coherentMs * blocks else { return [] }

        // Reste r (Hz) im Raster; je Ziel die Doppler-Stufen.
        let residueCount = max(1, Int((1000 / step).rounded()))
        let residues = (0..<residueCount).map { Double($0) * step }
        func bins(_ range: ClosedRange<Double>) -> [Double] {
            let lo = (range.lowerBound / step).rounded(.down), hi = (range.upperBound / step).rounded(.up)
            return stride(from: lo, through: hi, by: 1).map { $0 * step }
        }
        let targetBins = targets.map { bins($0.doppler) }
        var usedResidues = Set<Int>()
        for list in targetBins { for f in list { usedResidues.insert(residueIndex(f, step: step, count: residueCount)) } }

        // Vorwärts-FFTs: je Block und benötigtem Rest einmal.
        let blockLen = n * coherentMs
        var spectra = [[(re: [Float], im: [Float])?]](repeating: [(re: [Float], im: [Float])?](repeating: nil, count: residueCount),
                                                      count: blocks)
        var foldR = [Float](repeating: 0, count: n), foldI = [Float](repeating: 0, count: n)
        var msR = [Float](repeating: 0, count: n), msI = [Float](repeating: 0, count: n)
        var carR = [Float](repeating: 0, count: n), carI = [Float](repeating: 0, count: n)
        for j in usedResidues.sorted() {
            let r = residues[j]
            for k in 0..<n {
                let ph = -2 * Double.pi * r * Double(k) / fs
                carR[k] = Float(cos(ph)); carI[k] = Float(sin(ph))
            }
            for b in 0..<blocks {
                vDSP_vclr(&foldR, 1, vDSP_Length(n)); vDSP_vclr(&foldI, 1, vDSP_Length(n))
                for m in 0..<coherentMs {
                    let base = (b * blockLen + m * n) * 2
                    samples.withUnsafeBufferPointer { s in
                        msR.withUnsafeMutableBufferPointer { mr in
                            msI.withUnsafeMutableBufferPointer { mi in
                                // Interleaved → getrennt.
                                s.baseAddress!.advanced(by: base).withMemoryRebound(to: DSPComplex.self, capacity: n) { c in
                                    var split = DSPSplitComplex(realp: mr.baseAddress!, imagp: mi.baseAddress!)
                                    vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n))
                                }
                            }
                        }
                    }
                    // Gewicht e^(−j2π r m·1 ms): Phase des Restes am Beginn der m-ten ms.
                    let ph = -2 * Double.pi * r * Double(m) * 1e-3
                    var wr = Float(cos(ph)), wi = Float(sin(ph))
                    msR.withUnsafeMutableBufferPointer { mr in msI.withUnsafeMutableBufferPointer { mi in
                        foldR.withUnsafeMutableBufferPointer { fr in foldI.withUnsafeMutableBufferPointer { fi in
                            withUnsafeMutablePointer(to: &wr) { pwr in withUnsafeMutablePointer(to: &wi) { pwi in
                                var a = DSPSplitComplex(realp: mr.baseAddress!, imagp: mi.baseAddress!)
                                var w = DSPSplitComplex(realp: pwr, imagp: pwi)
                                var f = DSPSplitComplex(realp: fr.baseAddress!, imagp: fi.baseAddress!)
                                vDSP_zvsma(&a, 1, &w, &f, 1, &f, 1, vDSP_Length(n))
                            }}
                        }}
                    }}
                }
                var outR = [Float](repeating: 0, count: n), outI = [Float](repeating: 0, count: n)
                multiplyComplex(foldR, foldI, carR, carI, into: &outR, &outI, count: n)
                outR.withUnsafeMutableBufferPointer { r in outI.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }}
                spectra[b][j] = (outR, outI)
            }
        }

        var accum = [Float](repeating: 0, count: n)
        var prodR = [Float](repeating: 0, count: n), prodI = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n)

        /// Nichtkohärente Summe einer Doppler-Zeile in `accum`.
        func row(prn: Int, doppler f: Double) {
            let code = codeFFT[prn - 1]
            let j = residueIndex(f, step: step, count: residueCount)
            let kShift = Int(((f - residues[j]) / 1000).rounded())
            let shift = ((kShift % n) + n) % n
            vDSP_vclr(&accum, 1, vDSP_Length(n))
            for b in 0..<blocks {
                guard let spec = spectra[b][j] else { continue }
                // Z[i] = U[(i + K) mod n] · C*[i] in zwei Abschnitten.
                let first = n - shift
                multiplyComplex(spec.re, spec.im, code.re, code.im, into: &prodR, &prodI,
                                count: first, aOffset: shift, bOffset: 0, outOffset: 0)
                if shift > 0 {
                    multiplyComplex(spec.re, spec.im, code.re, code.im, into: &prodR, &prodI,
                                    count: shift, aOffset: 0, bOffset: first, outOffset: first)
                }
                prodR.withUnsafeMutableBufferPointer { r in prodI.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n))
                }}
                // Codeverschiebung durch den Doppler seit Block 0 (in Abtastwerten):
                // Der Code läuft um f/L1 schneller, die Spitze wandert zu kleineren Indizes.
                let t = Double(b * coherentMs) * 1e-3
                let drift = Int((GPSConst.chipRate * f / GPSConst.l1 * t * Double(n) / Double(GPSCACode.chips)).rounded())
                let d = ((drift % n) + n) % n
                // accum[i] += power[(i − drift) mod n]
                accum.withUnsafeMutableBufferPointer { a in power.withUnsafeBufferPointer { p in
                    if d == 0 {
                        vDSP_vadd(a.baseAddress!, 1, p.baseAddress!, 1, a.baseAddress!, 1, vDSP_Length(n))
                    } else {
                        vDSP_vadd(a.baseAddress! + d, 1, p.baseAddress!, 1, a.baseAddress! + d, 1, vDSP_Length(n - d))
                        vDSP_vadd(a.baseAddress!, 1, p.baseAddress! + (n - d), 1, a.baseAddress!, 1, vDSP_Length(d))
                    }
                }}
            }
        }

        let tc = Double(coherentMs) * 1e-3
        // Die C/N0 aus einer Spitze knapp über der Schwelle ist nach oben verzerrt
        // (Maximum vieler Rauschzellen): In der Grobsuche (8 Blöcke) erschienen die
        // Nebenspitzen zweier 50-dB-Hz-Satelliten (je −27 dB, zusammen ≈ 25 dB-Hz)
        // mit 35 dB-Hz. Schwache Satelliten neben starken findet ohnehin die lange Suche.
        let margin = blocks < 16 ? 12.0 : 6.0
        /// Erklären die Störer die Spitze (Leistungssumme ihrer Kreuzkorrelation, bis auf `margin`)?
        func explained(prn: Int, doppler f: Double, index: Int, ratio: Float) -> Bool {
            let cn0 = 10 * log10(max(Double(ratio) - 1, 1e-6) / tc)
            let replica = -Double(index) * Double(GPSCACode.chips) / Double(n)
            var leaked = 0.0                     // erwartete Leistung relativ zu 1 Hz (linear C/N0)
            for i in interferers where i.prn != prn && i.cn0 > cn0 {
                let df = i.dopplerHz - f
                // Über `coherentMs` Perioden summiert sich die Nebenspitze nur nahe
                // k·1 kHz (Dirichlet-Kern); sonst wäre jede echte schwache Spitze „erklärt“.
                var dr = 0.0, di = 0.0
                for m in 0..<coherentMs {
                    dr += cos(2 * .pi * df * Double(m) * 1e-3); di += sin(2 * .pi * df * Double(m) * 1e-3)
                }
                let gain = (dr * dr + di * di).squareRoot() / Double(coherentMs)
                guard gain > 0.1 else { continue }
                let r = GPSCACode.crossCorrelation(i.prn, prn, offsetChips: replica - i.codePhase, dopplerHz: df) * gain
                leaked += r * r * pow(10, i.cn0 / 10)
            }
            return leaked > 0 && 10 * log10(leaked) >= cn0 - margin
        }

        var fixes: [GPSFix] = []
        for (t, target) in targets.enumerated() {
            let list = targetBins[t]
            let threshold = GPSDetection.ratioThreshold(blocks: blocks, cells: list.count * n)
            var bestRatio: Float = 0, bestIdx = 0, bestBin = 0
            for (k, f) in list.enumerated() {
                row(prn: target.prn, doppler: f)
                var peak: Float = 0
                var idx: vDSP_Length = 0
                vDSP_maxvi(accum, 1, &peak, &idx, vDSP_Length(n))
                var mean: Float = 0
                vDSP_meanv(accum, 1, &mean, vDSP_Length(n))
                let ratio = peak / max(mean, 1e-12)
                guard ratio > bestRatio else { continue }
                // Nur Spitzen über der Schwelle prüfen – die anderen entscheiden nichts.
                if !interferers.isEmpty && Double(ratio) >= threshold
                    && explained(prn: target.prn, doppler: f, index: Int(idx), ratio: ratio) { continue }
                bestRatio = ratio; bestIdx = Int(idx); bestBin = k
            }
            let detected = Double(bestRatio) >= threshold
            var doppler = list.isEmpty ? 0 : list[bestBin]
            var phase = Double(bestIdx)
            if interpolate && detected {
                // Feinwerte per Parabel: Codephase in der besten Zeile, Doppler über
                // die Nachbarzeilen an derselben Codephase.
                row(prn: target.prn, doppler: doppler)
                let c0 = Double(accum[bestIdx]), cm = Double(accum[(bestIdx + n - 1) % n]), cp = Double(accum[(bestIdx + 1) % n])
                phase += Self.parabola(cm, c0, cp)
                row(prn: target.prn, doppler: doppler - step)
                let dm = Double(accum[bestIdx])
                row(prn: target.prn, doppler: doppler + step)
                let dp = Double(accum[bestIdx])
                doppler += step * Self.parabola(dm, c0, dp)
            }
            let ratio = Double(bestRatio)
            let snr = 10 * log10(max(ratio, 1))
            let cn0 = ratio > 1 ? 10 * log10((ratio - 1) / (Double(coherentMs) * 1e-3)) : 0
            var phaseChips = phase * Double(GPSCACode.chips) / Double(n)
            if phaseChips < 0 { phaseChips += Double(GPSCACode.chips) }
            fixes.append(GPSFix(prn: target.prn, dopplerHz: doppler, codePhaseChips: phaseChips,
                                snrDB: snr, acquired: detected, cn0: detected ? cn0 : 0))
        }
        return fixes
    }

    /// Lage des Scheitels einer Parabel durch (−1, a), (0, b), (1, c), begrenzt auf ±½.
    private static func parabola(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let den = a - 2 * b + c
        guard den < 0 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (a - c) / den))
    }

    private func residueIndex(_ f: Double, step: Double, count: Int) -> Int {
        let r = f - 1000 * (f / 1000).rounded(.down)
        return Int((r / step).rounded()) % count
    }

    /// Elementweises komplexes Produkt (a·b) über `count` Werte ab den Versätzen.
    private func multiplyComplex(_ ar: [Float], _ ai: [Float], _ br: [Float], _ bi: [Float],
                                 into cr: inout [Float], _ ci: inout [Float], count: Int,
                                 aOffset: Int = 0, bOffset: Int = 0, outOffset: Int = 0) {
        ar.withUnsafeBufferPointer { a1 in ai.withUnsafeBufferPointer { a2 in
            br.withUnsafeBufferPointer { b1 in bi.withUnsafeBufferPointer { b2 in
                cr.withUnsafeMutableBufferPointer { c1 in ci.withUnsafeMutableBufferPointer { c2 in
                    var a = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: a1.baseAddress! + aOffset),
                                            imagp: UnsafeMutablePointer(mutating: a2.baseAddress! + aOffset))
                    var b = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: b1.baseAddress! + bOffset),
                                            imagp: UnsafeMutablePointer(mutating: b2.baseAddress! + bOffset))
                    var c = DSPSplitComplex(realp: c1.baseAddress! + outOffset, imagp: c2.baseAddress! + outOffset)
                    vDSP_zvmul(&a, 1, &b, 1, &c, 1, vDSP_Length(count), 1)
                }}
            }}
        }}
    }
}
