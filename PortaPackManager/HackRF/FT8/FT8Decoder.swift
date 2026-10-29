import Accelerate
import Foundation

/// Eine FT8-Dekodierung.
struct FT8Decode: Sendable, Identifiable {
    let id = UUID()
    /// Frequenz von Ton 0 im Audioband (Hz über der Skalenfrequenz).
    var frequency: Double
    /// Zeitversatz zum Sollbeginn (0,5 s nach Zyklusbeginn) in Sekunden.
    var dt: Double
    /// Rauschabstand in 2500 Hz Bandbreite (dB).
    var snr: Double
    var bits77: [UInt8]
    var tones: [Int]
    var message: FT8Message
    /// Beginn des Signals im Puffer (Abtastwert bei 12 kHz).
    var startSample: Double
    /// 1 = erster Durchgang, 2… = nach Abziehen bereits dekodierter Signale.
    var pass: Int
    /// Nur über OSD gefunden (nicht über Belief Propagation).
    var viaOSD: Bool
    /// Gemessene Frequenzdrift in Hz/s (0, wenn ohne Driftsuche dekodiert).
    var drift: Double = 0
}

/// FT8-Dekoder nach der WSJT-X-Spezifikation, arbeitet auf komplexem
/// Basisband (12 kHz, Index 0 = Zyklusbeginn, 15 s).
///
/// Ablauf je Durchgang:
/// 1. Spektrogramm: 1920er-Fenster (ein Symbol) im Halbsymbolraster, FFT 3840
///    (3,125 Hz je Bin, doppelte Frequenzauflösung).
/// 2. Kandidaten: Costas-Korrelation über Frequenz (Ton 0 im Suchbereich) und
///    Zeitversatz −1,3 … +2,5 s; Bewertung wie WSJT-X `sync8` (Leistung im
///    Sollton gegen den Mittelwert der übrigen Töne, alle drei oder nur die
///    letzten beiden Costas-Felder), normiert auf das 40-%-Quantil.
/// 3. Je Kandidat: aus einer großen FFT des ganzen Puffers den Bereich um das
///    Signal ausschneiden, auf 187,5 Hz (30 Abtastwerte je Symbol) zurückrechnen,
///    Feinsuche ±2 Hz/±80 ms über die kohärente Costas-Korrelation.
/// 4. Symbolspektren (8 Töne), weiche Bits aus Einzelsymbolen und kohärent
///    aus 2 bzw. 3 aufeinanderfolgenden Symbolen (wie WSJT-X `ft8b`).
/// 5. LDPC(174,91) per Belief Propagation, sonst OSD; CRC-14 prüft.
/// 6. Erfolgreiche Signale werden mit ihrer GFSK-Wellenform und geglätteter
///    komplexer Amplitude abgezogen, dann folgt der nächste Durchgang.
final class FT8Decoder: @unchecked Sendable {
    struct Options: Sendable {
        var minFrequency = 200.0
        var maxFrequency = 3000.0
        var osd = true
        var subtraction = true
        var maxPasses = 3
        var maxCandidates = 250
        var syncMin: Float = 1.5
        /// Driftsuche für Kandidaten, die ohne Drift nicht dekodieren: bis
        /// ±`maxDrift` Hz/s in Schritten von `driftStep`. Ein HackRF ohne TCXO
        /// läuft beim Aufwärmen bei 144 MHz einige 10 Hz je Minute weg – über
        /// die 12,6 s einer Aussendung mehrere Hz, bei 6,25 Hz Tonabstand.
        var maxDrift = 1.6
        var driftStep = 0.2
        var driftSyncMin: Float = 1.7
    }

    static let sampleRate = 12_000.0
    static let slotSamples = 180_000
    static let nominalStart = 0.5

    let options: Options
    private let nfft = 3840
    private let halfStep = 960
    private let binHz = 3.125
    private let spectrumFFT: FT8DFT
    private let bigN = 196_608
    private let smallN = 3072
    private let bigFFT: FT8DFT
    private let smallIFFT: FT8DFT
    private var bigDF: Double { Self.sampleRate / Double(bigN) }
    private var downRate: Double { Double(smallN) * bigDF }   // 187,5 Hz
    private let samplesPerSymbol = 30

    init(options: Options = Options()) {
        self.options = options
        spectrumFFT = FT8DFT(length: nfft)
        bigFFT = FT8DFT(length: bigN)
        smallIFFT = FT8DFT(length: smallN, inverse: true)
    }

    /// Dekodiert einen 15-s-Zyklus. `signal` beginnt am Zyklusbeginn.
    func decode(_ signal: FT8Signal, hashes: FT8CallHashes) -> [FT8Decode] {
        var work = signal.slice(from: 0, count: Self.slotSamples)
        var results: [FT8Decode] = []
        var seen = Set<String>()
        let passes = options.subtraction ? max(1, options.maxPasses) : 1
        for pass in 1...passes {
            let found = decodePass(work, pass: pass, hashes: hashes, known: results)
            var fresh: [FT8Decode] = []
            for d in found where !seen.contains(d.message.text) {
                seen.insert(d.message.text)
                fresh.append(d)
            }
            results += fresh
            guard options.subtraction, !fresh.isEmpty, pass < passes else { break }
            for d in fresh { subtract(d, from: &work) }
        }
        return results
    }

    // MARK: - Spektrogramm und Kandidaten

    struct Candidate: Sendable {
        var bin: Int        // Ton 0 in 3,125-Hz-Bins (darf negativ sein)
        var step: Int       // Signalbeginn in Halbsymbolen (960 Abtastwerte)
        var sync: Float
        var frequency: Double { Double(bin) * 3.125 }
    }

    /// Leistungsspektrogramm: [Zeitschritt][Bin − binLow].
    func spectrogram(_ x: FT8Signal) -> (power: [[Float]], binLow: Int) {
        let binLow = Int((options.minFrequency / binHz).rounded(.down)) - 2
        let binHigh = Int(((options.maxFrequency + 7 * 6.25) / binHz).rounded(.up)) + 2
        let steps = (x.count - 1920) / halfStep + 1
        var inRe = [Float](repeating: 0, count: nfft), inIm = [Float](repeating: 0, count: nfft)
        var outRe = [Float](repeating: 0, count: nfft), outIm = [Float](repeating: 0, count: nfft)
        var power: [[Float]] = []
        power.reserveCapacity(steps)
        for t in 0..<steps {
            let start = t * halfStep
            for i in 0..<1920 { inRe[i] = x.re[start + i]; inIm[i] = x.im[start + i] }
            spectrumFFT.run(inRe, inIm, &outRe, &outIm)
            var row = [Float](repeating: 0, count: binHigh - binLow + 1)
            for b in binLow...binHigh {
                let k = (b % nfft + nfft) % nfft
                row[b - binLow] = outRe[k] * outRe[k] + outIm[k] * outIm[k]
            }
            power.append(row)
        }
        return (power, binLow)
    }

    func candidates(_ power: [[Float]], binLow: Int) -> [Candidate] {
        guard let width = power.first?.count else { return [] }
        let steps = power.count
        let firstBin = Int((options.minFrequency / binHz).rounded(.down))
        let lastBin = Int((options.maxFrequency / binHz).rounded(.up))
        // Summe über die Töne 0…6 je Zeitschritt/Bin.
        var sum7 = [[Float]](repeating: [Float](repeating: 0, count: width), count: steps)
        for t in 0..<steps {
            for b in 0..<width {
                var s: Float = 0
                for k in 0..<7 where b + 2 * k < width { s += power[t][b + 2 * k] }
                sum7[t][b] = s
            }
        }
        let nominal = 6   // 0,48 s ≈ Sollbeginn 0,5 s
        let stepRange = -16...(nominal + 32)
        var bestPerBin: [(bin: Int, step: Int, sync: Float)] = []
        var nearPerBin: [(bin: Int, step: Int, sync: Float)] = []
        for bin in firstBin...lastBin {
            let b = bin - binLow
            guard b >= 0, b + 14 < width else { continue }
            var best: (Int, Float) = (nominal, 0)
            var near: (Int, Float) = (nominal, 0)
            for step in stepRange {
                var ta: Float = 0, tb: Float = 0, tc: Float = 0
                var sa: Float = 0, sb: Float = 0, sc: Float = 0
                for j in 0..<7 {
                    let tone = 2 * FT8Codec.costas[j]
                    let t1 = step + 2 * j, t2 = step + 2 * (36 + j), t3 = step + 2 * (72 + j)
                    if t1 >= 0, t1 < steps { ta += power[t1][b + tone]; sa += sum7[t1][b] }
                    if t2 >= 0, t2 < steps { tb += power[t2][b + tone]; sb += sum7[t2][b] }
                    if t3 >= 0, t3 < steps { tc += power[t3][b + tone]; sc += sum7[t3][b] }
                }
                let abc = (sa + sb + sc - ta - tb - tc) > 0 ? (ta + tb + tc) / ((sa + sb + sc - ta - tb - tc) / 6) : 0
                let bc = (sb + sc - tb - tc) > 0 ? (tb + tc) / ((sb + sc - tb - tc) / 6) : 0
                let ab = (sa + sb - ta - tb) > 0 ? (ta + tb) / ((sa + sb - ta - tb) / 6) : 0
                let sync = max(abc, bc, ab)
                if sync > best.1 { best = (step, sync) }
                if abs(step - nominal) <= 3, sync > near.1 { near = (step, sync) }
            }
            bestPerBin.append((bin, best.0, best.1))
            nearPerBin.append((bin, near.0, near.1))
        }
        guard !bestPerBin.isEmpty else { return [] }
        func normalized(_ list: [(bin: Int, step: Int, sync: Float)]) -> [Candidate] {
            let sorted = list.map(\.sync).sorted()
            let base = max(sorted[Int(Double(sorted.count) * 0.4)], 1e-9)
            return list.map { Candidate(bin: $0.bin, step: $0.step, sync: $0.sync / base) }
        }
        var all = normalized(bestPerBin).filter { $0.sync >= options.syncMin }
        all += normalized(nearPerBin).filter { $0.sync >= options.syncMin }
        all.sort { $0.sync > $1.sync }
        // Nachbarn desselben Signals zusammenfassen (±1 Bin, ±1 Schritt).
        var kept: [Candidate] = []
        for c in all {
            if kept.contains(where: { abs($0.bin - c.bin) <= 1 && abs($0.step - c.step) <= 1 }) { continue }
            kept.append(c)
            if kept.count >= options.maxCandidates { break }
        }
        return kept
    }

    // MARK: - Ein Durchgang

    private func decodePass(_ x: FT8Signal, pass: Int, hashes: FT8CallHashes, known: [FT8Decode]) -> [FT8Decode] {
        let (power, binLow) = spectrogram(x)
        let cands = candidates(power, binLow: binLow)
        guard !cands.isEmpty else { return [] }
        // Große FFT des ganzen Puffers (einmal je Durchgang).
        var inRe = [Float](repeating: 0, count: bigN), inIm = [Float](repeating: 0, count: bigN)
        for i in 0..<min(x.count, bigN) { inRe[i] = x.re[i]; inIm[i] = x.im[i] }
        var specRe = [Float](), specIm = [Float]()
        bigFFT.run(inRe, inIm, &specRe, &specIm)

        var out: [FT8Decode] = []
        var failed: [Candidate] = []
        for c in cands {
            // Schon (in diesem oder einem früheren Durchgang) dekodiert?
            if (known + out).contains(where: { abs($0.frequency - c.frequency) < 3.5 && abs($0.startSample - Double(c.step * halfStep)) < 1500 }) {
                continue
            }
            if let d = decodeCandidate(c, specRe: specRe, specIm: specIm, pass: pass, hashes: hashes, drift: false) {
                if out.contains(where: { $0.message.text == d.message.text }) { continue }
                out.append(d)
            } else {
                failed.append(c)
            }
        }
        // Driftsuche erst danach, nur im ersten Durchgang, nur für Kandidaten mit
        // Sync ≥ `driftSyncMin` und abseits schon dekodierter Signale – sonst
        // kostet sie auf vollem Band ein Vielfaches der übrigen Rechenzeit.
        guard options.maxDrift > 0, pass == 1 else { return out }
        for c in failed where c.sync >= options.driftSyncMin {
            if (known + out).contains(where: { abs($0.frequency - c.frequency) < 7 && abs($0.startSample - Double(c.step * halfStep)) < 3000 }) {
                continue
            }
            if let d = decodeCandidate(c, specRe: specRe, specIm: specIm, pass: pass, hashes: hashes, drift: true) {
                if out.contains(where: { $0.message.text == d.message.text }) { continue }
                out.append(d)
            }
        }
        return out
    }

    /// Bereich um `f0` ausschneiden und auf 187,5 Hz herunterrechnen (Ton 0 bei ≈ 0 Hz).
    private func downsample(specRe: [Float], specIm: [Float], f0: Double) -> (FT8Signal, Double) {
        let df = bigDF
        let k0 = Int((f0 / df).rounded())
        let lowBins = Int((1.5 * 6.25 / df).rounded())
        let highBins = Int((8.5 * 6.25 / df).rounded())
        let taper = 100
        var re = [Float](repeating: 0, count: smallN), im = [Float](repeating: 0, count: smallN)
        for o in -lowBins...highBins {
            let src = ((k0 + o) % bigN + bigN) % bigN
            let dst = (o % smallN + smallN) % smallN
            var w: Float = 1
            let fromEdge = min(o + lowBins, highBins - o)
            if fromEdge < taper { w = Float(0.5 * (1 - cos(Double.pi * Double(fromEdge) / Double(taper)))) }
            re[dst] = specRe[src] * w
            im[dst] = specIm[src] * w
        }
        var outRe = [Float](), outIm = [Float]()
        smallIFFT.run(re, im, &outRe, &outIm)
        let scale = 1 / Float(bigN)
        vDSP_vsmul(outRe, 1, [scale], &outRe, 1, vDSP_Length(smallN))
        vDSP_vsmul(outIm, 1, [scale], &outIm, 1, vDSP_Length(smallN))
        return (FT8Signal(re: outRe, im: outIm), Double(k0) * df)
    }

    /// DFT-Referenzen der 8 Töne über ein Symbol (30 Abtastwerte).
    private lazy var toneRefRe: [[Float]] = (0..<8).map { k in (0..<30).map { Float(cos(-2 * Double.pi * Double(k * $0) / 30)) } }
    private lazy var toneRefIm: [[Float]] = (0..<8).map { k in (0..<30).map { Float(sin(-2 * Double.pi * Double(k * $0) / 30)) } }

    /// Komplexes Symbolspektrum: Symbol `s` ab Index `i0`, Ton `k`.
    @inline(__always)
    private func symbolBin(_ z: FT8Signal, _ start: Int, _ k: Int) -> (Float, Float) {
        var sr: Float = 0, si: Float = 0
        let rr = toneRefRe[k], ri = toneRefIm[k]
        for n in 0..<30 {
            let idx = start + n
            guard idx >= 0, idx < z.count else { continue }
            let a = z.re[idx], b = z.im[idx]
            sr += a * rr[n] - b * ri[n]
            si += a * ri[n] + b * rr[n]
        }
        return (sr, si)
    }

    private func costasSync(_ z: FT8Signal, _ i0: Int) -> Float {
        var s: Float = 0
        for m in [0, 36, 72] {
            for j in 0..<7 {
                let (a, b) = symbolBin(z, i0 + 30 * (m + j), FT8Codec.costas[j])
                s += a * a + b * b
            }
        }
        return s
    }

    /// `drift: false` dekodiert ohne Drift, `true` sucht nur noch mit Drift
    /// (für Kandidaten, die ohne schon gescheitert sind).
    private func decodeCandidate(_ c: Candidate, specRe: [Float], specIm: [Float], pass: Int,
                                 hashes: FT8CallHashes, drift: Bool) -> FT8Decode? {
        let (z0, baseFreq) = downsample(specRe: specRe, specIm: specIm, f0: c.frequency)
        // Feinsuche: Frequenz ±2 Hz in 0,25-Hz-Schritten, Zeit ±15 Abtastwerte (±80 ms).
        let coarse = c.step * halfStep / 64
        var best: (sync: Float, i0: Int, df: Double) = (0, coarse, 0)
        var bestZ = z0
        for di in -8...8 {
            let df = Double(di) * 0.25 + (c.frequency - baseFreq)
            let z = z0.shifted(by: df, sampleRate: downRate)
            for i0 in (coarse - 15)...(coarse + 15) {
                let s = costasSync(z, i0)
                if s > best.sync { best = (s, i0, df); bestZ = z }
            }
        }
        if !drift {
            return decodeSymbols(bestZ, i0: best.i0, sync: c.sync, pass: pass, hashes: hashes,
                                 frequency: baseFreq + best.df)
        }
        // Driftsuche (Review 29.10.2026): ohne sie dekodierte FT8 bei −18 dB und
        // 0,5 Hz/s nur 3 von 8 Zyklen, ab 0,8 Hz/s praktisch nichts mehr; mit ihr
        // 0,8 Hz/s 8/8, 1,5 Hz/s 5/8 (−12 dB: 8/8). Rechenzeit volles Band
        // (20 Signale) 0,37 → 1,2 s, Rauschzyklus 0,03 → 0,05 s. Erst die
        // Drift herausnehmen (um die Signalmitte), dann fein Frequenz und Zeit
        // nachsuchen; dekodiert wird nur, wenn die Costas-Korrelation deutlich
        // besser wird als ohne Drift – sonst kostet Rauschen OSD-Läufe.
        guard options.maxDrift > 0, options.driftStep > 0 else { return nil }
        let center = (Double(best.i0) + 30 * 39.5) / downRate
        var drifted: (sync: Float, i0: Int, df: Double, rate: Double, z: FT8Signal)?
        func search(rates: [Double], dfs: [Double], times: [Int]) {
            for rate in rates where rate != 0 {
                let chirped = z0.dechirped(rate: rate, center: center, sampleRate: downRate)
                for df in dfs {
                    let z = chirped.shifted(by: df, sampleRate: downRate)
                    for i0 in times {
                        let s = costasSync(z, i0)
                        if s > (drifted?.sync ?? 0) { drifted = (s, i0, df, rate, z) }
                    }
                }
            }
        }
        // Grob: Drift im Raster `driftStep`, Frequenz ±1 Hz um die bisherige
        // Lage und um einen Ton daneben (bei ≈ 1 Hz/s liegen die äußeren
        // Costas-Felder genau einen Ton versetzt, der Kandidat dann oft auch),
        // Zeit ±6 Abtastwerte in Dreierschritten …
        let steps = Int((options.maxDrift / options.driftStep).rounded())
        search(rates: (-steps...steps).map { Double($0) * options.driftStep },
               dfs: [-6.25, 0, 6.25].flatMap { tone in (-4...4).map { best.df + tone + Double($0) * 0.25 } },
               times: Array(stride(from: best.i0 - 6, through: best.i0 + 6, by: 3)))
        // … dann fein um das Beste.
        if let coarse = drifted {
            search(rates: [-0.5, 0, 0.5].map { coarse.rate + $0 * options.driftStep },
                   dfs: [-0.125, 0, 0.125].map { coarse.df + $0 },
                   times: Array((coarse.i0 - 2)...(coarse.i0 + 2)))
        }
        guard let drifted, drifted.sync > 1.2 * best.sync else { return nil }
        guard var d = decodeSymbols(drifted.z, i0: drifted.i0, sync: c.sync, pass: pass, hashes: hashes,
                                    frequency: baseFreq + drifted.df) else { return nil }
        d.drift = drifted.rate
        return d
    }

    /// Ab der Feinsuche: Symbolspektren, weiche Bits, LDPC, Nachkontrolle.
    private func decodeSymbols(_ z: FT8Signal, i0: Int, sync: Float, pass: Int, hashes: FT8CallHashes,
                               frequency: Double) -> FT8Decode? {
        // Symbolspektren.
        var csRe = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 79)
        var csIm = csRe
        var mag = csRe
        for s in 0..<79 {
            for k in 0..<8 {
                let (a, b) = symbolBin(z, i0 + 30 * s, k)
                csRe[s][k] = a; csIm[s][k] = b
                mag[s][k] = (a * a + b * b).squareRoot()
            }
        }
        // Mindestens 7 der 21 Costas-Symbole müssen hart stimmen.
        var nsync = 0
        for m in [0, 36, 72] {
            for j in 0..<7 {
                let row = mag[m + j]
                if row.firstIndex(of: row.max()!) == FT8Codec.costas[j] { nsync += 1 }
            }
        }
        guard nsync >= 7 else { return nil }

        let metrics = (1...3).map { softMetrics(nsym: $0, re: csRe, im: csIm) }
        var codeword: [UInt8]?
        var viaOSD = false
        for llr in metrics {
            if let cw = FT8Codec.beliefPropagation(llr), FT8Codec.checkCRC(cw) { codeword = cw; break }
        }
        if codeword == nil, options.osd, nsync >= 10 || sync >= 2.5 {
            for llr in [metrics[0], metrics[2]] {
                if let cw = FT8Codec.osd(llr) { codeword = cw; viaOSD = true; break }
            }
        }
        guard let cw = codeword else { return nil }
        let bits77 = Array(cw.prefix(77))
        // Alles null ist zwar ein gültiges Codewort, aber nie eine Aussendung.
        guard bits77.contains(1), let message = FT8Message.unpack(bits77, hashes: hashes) else { return nil }
        let tones = FT8Codec.tones(codeword: cw)
        // Nachkontrolle: die Töne müssen zur Messung passen (gegen Fehldekodierungen über OSD).
        var hardOK = 0
        var xsig: Float = 0, xnoi: Float = 0
        for s in 0..<79 {
            let row = mag[s]
            if row.firstIndex(of: row.max()!) == tones[s] { hardOK += 1 }
            xsig += row[tones[s]] * row[tones[s]]
            xnoi += row[(tones[s] + 4) % 8] * row[(tones[s] + 4) % 8]
        }
        if viaOSD, hardOK < 30 { return nil }
        let ratio = Double(xsig / max(xnoi, 1e-20))
        var snr = ratio > 1.0001 ? 10 * log10(ratio - 1) - 26.0 : -26
        snr = max(-26, min(49, snr))
        let start = Double(i0) * 64
        return FT8Decode(frequency: frequency, dt: Double(i0) / downRate - Self.nominalStart, snr: snr,
                         bits77: bits77, tones: tones, message: message, startSample: start, pass: pass, viaOSD: viaOSD)
    }

    /// Weiche Bits (WSJT-X `ft8b`): Maximum der Beträge über alle Tonfolgen mit
    /// Bit = 1 minus über alle mit Bit = 0, für Gruppen von `nsym` Symbolen
    /// (kohärent addiert); normiert auf die Standardabweichung, × 2,83.
    func softMetrics(nsym: Int, re: [[Float]], im: [[Float]]) -> [Float] {
        var bm = [Float](repeating: 0, count: 174)
        for half in 0..<2 {
            var k = 0
            while k < 29 {
                let g = min(nsym, 29 - k)
                let first = 7 + 36 * half + k
                let combos = 1 << (3 * g)
                var s2 = [Float](repeating: 0, count: combos)
                for i in 0..<combos {
                    var ar: Float = 0, ai: Float = 0
                    for j in 0..<g {
                        let v = (i >> (3 * (g - 1 - j))) & 7
                        let tone = FT8Codec.grayMap[v]
                        ar += re[first + j][tone]
                        ai += im[first + j][tone]
                    }
                    s2[i] = (ar * ar + ai * ai).squareRoot()
                }
                let nbits = 3 * g
                let base = 3 * (29 * half + k)
                for ib in 0..<nbits {
                    var max1: Float = -1, max0: Float = -1
                    let shift = nbits - 1 - ib
                    for i in 0..<combos {
                        if (i >> shift) & 1 == 1 { max1 = max(max1, s2[i]) } else { max0 = max(max0, s2[i]) }
                    }
                    bm[base + ib] = max1 - max0
                }
                k += g
            }
        }
        var mean: Float = 0, sq: Float = 0
        vDSP_meanv(bm, 1, &mean, 174)
        vDSP_measqv(bm, 1, &sq, 174)
        let sigma = max((sq - mean * mean).squareRoot(), 1e-12)
        return bm.map { 2.83 * $0 / sigma }
    }

    // MARK: - Abziehen

    /// Zieht ein dekodiertes Signal ab: Referenz-Wellenform r(t), komplexe
    /// Amplitude c(t) = Tiefpass[x·r*], dann x − c·r (wie WSJT-X `subtractft8`).
    func subtract(_ d: FT8Decode, from x: inout FT8Signal) {
        let ref = FT8Codec.waveform(tones: d.tones, frequency: d.frequency, sampleRate: Self.sampleRate)
        let n = ref.re.count
        // Zeitlage auf 12 kHz verfeinern (±48 Abtastwerte, nichtkohärent je Symbol).
        var bestStart = Int(d.startSample.rounded())
        var bestScore: Float = -1
        for off in stride(from: -48, through: 48, by: 4) {
            let start = Int(d.startSample.rounded()) + off
            var score: Float = 0
            for s in 0..<79 {
                var ar: Float = 0, ai: Float = 0
                let lo = s * 1920
                for i in stride(from: lo, to: lo + 1920, by: 2) {
                    let k = start + i
                    guard k >= 0, k < x.count else { continue }
                    let a = x.re[k], b = x.im[k], c = ref.re[i], e = ref.im[i]
                    ar += a * c + b * e
                    ai += b * c - a * e
                }
                score += ar * ar + ai * ai
            }
            if score > bestScore { bestScore = score; bestStart = start }
        }
        // c = x · conj(r)
        var cr = [Float](repeating: 0, count: n), ci = [Float](repeating: 0, count: n)
        var valid = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let k = bestStart + i
            guard k >= 0, k < x.count else { continue }
            let a = x.re[k], b = x.im[k], c = ref.re[i], e = ref.im[i]
            cr[i] = a * c + b * e
            ci[i] = b * c - a * e
            valid[i] = 1
        }
        let sr = Self.smooth(cr, width: 960), si = Self.smooth(ci, width: 960), sv = Self.smooth(valid, width: 960)
        for i in 0..<n {
            let k = bestStart + i
            guard k >= 0, k < x.count, sv[i] > 0.05 else { continue }
            let ar = sr[i] / sv[i], ai = si[i] / sv[i]
            let c = ref.re[i], e = ref.im[i]
            x.re[k] -= ar * c - ai * e
            x.im[k] -= ar * e + ai * c
        }
    }

    /// Zweifacher gleitender Mittelwert (Dreiecksfenster der Breite 2·width).
    static func smooth(_ x: [Float], width: Int) -> [Float] {
        func box(_ v: [Float]) -> [Float] {
            let n = v.count
            var prefix = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { prefix[i + 1] = prefix[i] + Double(v[i]) }
            let h = width / 2
            return (0..<n).map { i in
                let lo = max(0, i - h), hi = min(n, i + h + 1)
                return Float((prefix[hi] - prefix[lo]) / Double(width + 1))
            }
        }
        return box(box(x))
    }
}
