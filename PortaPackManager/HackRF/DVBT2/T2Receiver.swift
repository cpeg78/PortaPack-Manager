import Accelerate
import Foundation

/// DVB-T2-Empfänger: IQ vom HackRF → Synchronisation → L1 → PLP → Transportstrom.
///
/// Nicht threadsicher: alle Aufrufe aus derselben (seriellen) Warteschlange;
/// nur die LDPC-Dekodierung verteilt sich intern auf mehrere Kerne.
final class T2Receiver: @unchecked Sendable {
    struct Status: Sendable, Equatable {
        var stage = String(localized: "Suche Fernsehsignal …")
        var locked = false
        var fft: T2FFTSize?
        var guardInterval: T2GuardInterval?
        var pattern: T2PilotPattern?
        var extended = false
        var frequencyOffsetHz: Double = 0
        /// Abtastratenablage (gemessen über die Drift der Symbollage); positiv: der HackRF
        /// tastet schneller ab als nominal (mehr Abtastwerte je Symbol).
        var sampleRateOffsetPPM: Double = 0
        /// Störabstand der Datenzellen aus den Piloten (dB).
        var snr: Double = 0
        var pre: T2L1Pre?
        var post: T2L1Post?
        var plpID: Int?
        var frames = 0
        var blocksGood = 0
        var blocksBad = 0
        /// Vom äußeren BCH korrigierte Bits / gerettete Blöcke / falsche LDPC-Wörter.
        var bchCorrectedBits = 0
        var bchRescuedBlocks = 0
        var ldpcFalseBlocks = 0
        var bbFramesGood = 0
        var packets = 0
        var ldpcIterations = 0
        var message: String?
    }

    /// Bekommt die Transportstrom-Pakete (188 Bytes) des gewählten PLP.
    var packetHandler: (([UInt8]) -> Void)?
    /// Gewünschtes PLP (nil = erstes Daten-PLP).
    var preferredPLP: Int?

    private let frontEnd = T2FrontEnd()
    private var re: [Float] = []
    private var im: [Float] = []
    /// Absoluter Index von `re[0]`.
    private var bufferStart = 0
    private var status = Status()

    private struct Lock {
        var fft: T2FFTSize
        var guardInterval: T2GuardInterval
        var layout: T2Layout
        var pre: T2L1Pre
        var post: T2L1Post
        /// Absoluter Beginn des nächsten P1.
        var p1: Int
        /// Frequenzablage in Trägerabständen (ganzzahlig + Bruchteil).
        var offset: Double
        /// FFT-Fenster so viele Abtastwerte vor dem Ende des Schutzintervalls.
        var backoff: Int
        var frameIndex: Int
        var framesSincePost = 0
        var failures = 0
        /// Abtastratenablage: Verschiebung der Symbollage je Abtastwert (relativ, z. B. 5e-6).
        var drift = 0.0
        /// Nachkommaanteil der P1-Lage (die Drift summiert Bruchteile über die Rahmen).
        var p1Fraction = 0.0
    }
    private var lock: Lock?
    private var plpDecoder: T2PLPDecoder?
    private var ffts: [Int: T2FFT] = [:]
    private var cpeReference: [Float] = []

    func reset() {
        frontEnd.reset()
        re = []; im = []
        bufferStart = 0
        lock = nil
        plpDecoder = nil
        noiseHistory = []
        status = Status()
    }

    var debug = false
    /// Nur für Prüfwerkzeuge, siehe `T2PLPDecoder.headerProbe`.
    var headerProbe: (([UInt8]) -> Void)?
    /// Mittelung der Streupiloten über ±so viele Symbole (statischer Empfang).
    var averaging = 8
    private func debugLog(_ text: @autoclosure () -> String) { if debug { print("[T2] " + text()) } }

    func currentStatus() -> Status {
        var s = status
        if let d = plpDecoder {
            s.blocksGood = d.blocksGood
            s.blocksBad = d.blocksBad
            s.bchCorrectedBits = d.bchCorrectedBits
            s.bchRescuedBlocks = d.bchRescuedBlocks
            s.ldpcFalseBlocks = d.ldpcFalseBlocks
            s.bbFramesGood = d.extractor.framesGood
            s.packets = d.extractor.packets
            s.ldpcIterations = d.lastIterations
        }
        return s
    }

    private func fft(_ size: Int) -> T2FFT {
        if let f = ffts[size] { return f }
        let f = T2FFT(size: size)
        ffts[size] = f
        return f
    }

    // MARK: - Eingang

    func process(_ block: Data) {
        frontEnd.process(block, re: &re, im: &im)
        if lock == nil { acquire() }
        while let current = lock {
            let needed = current.p1 - bufferStart + current.layout.frameSamples + 4096
            guard re.count >= needed else { break }
            processFrame()
        }
        // Puffer begrenzen.
        let keepFrom: Int
        if let current = lock { keepFrom = current.p1 - bufferStart - 4096 } else { keepFrom = re.count - 3_200_000 }
        if keepFrom > 0 {
            re.removeFirst(min(keepFrom, re.count))
            im.removeFirst(min(keepFrom, im.count))
            bufferStart += min(keepFrom, keepFrom)
        }
    }

    // MARK: - Erfassung

    private func acquire() {
        // Längster T2-Rahmen 250 ms + Reserve für die Auswertung danach.
        let span = 2_350_000
        guard re.count >= span + 400_000 else { return }
        let detections = re.withUnsafeBufferPointer { r in
            im.withUnsafeBufferPointer { i in
                T2P1.search(re: r.baseAddress!, im: i.baseAddress!, count: span, absoluteStart: bufferStart)
            }
        }
        guard let best = detections.max(by: { $0.metric < $1.metric }) else {
            status.stage = String(localized: "Kein Fernsehsignal gefunden")
            dropSearched(span)
            return
        }
        // Ersten Kandidaten nehmen, der fast so stark ist wie der beste.
        let first = detections.first { $0.metric > 0.7 * best.metric } ?? best
        if !tryLock(at: first.position) { dropSearched(first.position + 2048) }
    }

    private func dropSearched(_ count: Int) {
        let n = min(count, re.count)
        re.removeFirst(n); im.removeFirst(n)
        bufferStart += n
    }

    private func tryLock(at p: Int) -> Bool {
        guard let p1 = re.withUnsafeBufferPointer({ r in
            im.withUnsafeBufferPointer { i in T2P1.decode(re: r.baseAddress!, im: i.baseAddress!, at: p, fft: fft(1024)) }
        }) else { return false }
        guard p1.s1 == 0 else {
            status.message = p1.s1 == 1 ? String(localized: "MISO-Sendung – wird nicht unterstützt") : String(localized: "Kein DVB-T2-Base-Signal (S1 = \(p1.s1))")
            return false
        }
        guard let size = T2FFTSize.from(s2: p1.s2) else { return false }
        let n = size.size
        // Schutzintervall über die Korrelation mit dem Symbolende.
        var bestGI: (T2GuardInterval, Double, Double)?
        for gi in T2GuardInterval.allCases {
            let g = gi.samples(size)
            var accRe = 0.0, accIm = 0.0, energy = 0.0
            for l in 1...6 {
                let s = p + 2048 + l * (n + g)
                guard s + n + g < re.count else { break }
                for k in 0..<g {
                    let a = s + k, b = s + k + n
                    accRe += Double(re[a] * re[b] + im[a] * im[b])
                    accIm += Double(im[a] * re[b] - re[a] * im[b])
                    energy += Double(re[a] * re[a] + im[a] * im[a] + re[b] * re[b] + im[b] * im[b]) / 2
                }
            }
            let metric = (accRe * accRe + accIm * accIm).squareRoot() / max(energy, 1e-9)
            if bestGI == nil || metric > bestGI!.1 { bestGI = (gi, metric, atan2(accIm, accRe)) }
        }
        guard let (gi, giMetric, giPhase) = bestGI, giMetric > 0.2 else { return false }
        debugLog("GI \(gi.name) Metrik \(giMetric) Phase \(giPhase)")
        let fraction = -giPhase / (2 * .pi)         // Ablage in Trägern, Bruchteil
        // Ganzzahliger Teil: um die P1-Schätzung herum über die P2-Piloten.
        let coarse = Double(p1.shift * n / 1024)
        let span = max(2, n / 2048 + 2)
        var bestInteger = 0
        var bestScore = -1.0
        let p2Start = bufferStart + p + 2048 + gi.samples(size)
        var symRe = [Float](repeating: 0, count: n), symIm = symRe
        func spectrum(offset: Double) {
            extractSymbol(start: p2Start - gi.samples(size) / 8, length: n, offset: offset, re: &symRe, im: &symIm)
            fft(n).forward(&symRe, &symIm)
        }
        spectrum(offset: fraction)
        let kmax = size.kmaxNormal, kext = size.kext
        let step = size == .k32 ? 6 : 3
        for m in (Int(coarse) - span)...(Int(coarse) + span) {
            var sRe = 0.0, sIm = 0.0
            var previous: (Float, Float)?
            for k in stride(from: 0, through: kmax, by: step) {
                let bin = ((k - kmax / 2 + m) % n + n) % n
                let sign: Float = (T2Reference.prbs[k + kext] ^ T2Reference.frameSequence[0]) == 0 ? 1 : -1
                let value = (symRe[bin] * sign, symIm[bin] * sign)
                if let p = previous {
                    sRe += Double(value.0 * p.0 + value.1 * p.1)
                    sIm += Double(value.1 * p.0 - value.0 * p.1)
                }
                previous = value
            }
            let score = sRe * sRe + sIm * sIm
            if score > bestScore { bestScore = score; bestInteger = m }
        }
        let offset = Double(bestInteger) + fraction
        debugLog("Ablage ganz \(bestInteger) (grob \(coarse)) Bruch \(fraction)")
        // L1-pre und L1-post lesen.
        let backoff = gi.samples(size) / 8
        let absolute = bufferStart + p
        let p2 = decodeP2(p1: absolute, fft: size, gi: gi, offset: offset, backoff: backoff, layout: nil)
        guard let pre = p2.flatMap({ T2L1Decoder.decodePre(re: $0.re, im: $0.im, weights: $0.w) }) else {
            status.stage = String(localized: "Signalbeschreibung nicht lesbar (L1-pre)")
            return false
        }
        guard pre.guardInterval == gi.rawValue, let pattern = T2PilotPattern(rawValue: pre.pilotPattern),
              let layout = T2Layout(fft: size, guardInterval: gi, pattern: pattern, extended: pre.extendedCarriers,
                                    toneReservation: pre.toneReservation, dataSymbols: pre.dataSymbols) else {
            status.message = String(localized: "Unbekannte Betriebsart")
            return false
        }
        guard let post = p2.flatMap({ T2L1Decoder.decodePost(re: $0.re, im: $0.im, weights: $0.w, pre: pre) }) else {
            status.stage = String(localized: "Signalbeschreibung nicht lesbar (L1-post)")
            return false
        }
        // processFrame zählt den Rahmen hoch – er beginnt mit genau diesem Rahmen.
        let frames = max(1, pre.t2Frames)
        lock = Lock(fft: size, guardInterval: gi, layout: layout, pre: pre, post: post, p1: absolute,
                    offset: offset, backoff: backoff, frameIndex: (post.frameIndex + frames - 1) % frames)
        status.locked = true
        status.stage = String(localized: "Empfang")
        status.fft = size
        status.guardInterval = gi
        status.pattern = pattern
        status.extended = layout.extended
        status.pre = pre
        status.post = post
        status.frequencyOffsetHz = offset * T2FrontEnd.outputRate / Double(n)
        status.message = nil
        selectPLP(post)
        return true
    }

    private func selectPLP(_ post: T2L1Post) {
        let candidates = post.plps.filter { $0.type != 0 && $0.payloadType == 3 }
        let plp = candidates.first { $0.id == preferredPLP } ?? candidates.first
        status.plpID = plp?.id
        if plpDecoder?.plp.id != plp?.id || plpDecoder?.plp.codeRate != plp?.codeRate {
            plpDecoder = plp.flatMap(T2PLPDecoder.init)
            plpDecoder?.extractor.packetHandler = { [weak self] packet in self?.packetHandler?(packet) }
            plpDecoder?.headerProbe = headerProbe
        }
    }

    // MARK: - Symbole

    /// N Abtastwerte ab absolutem `start`, um die Frequenzablage gedreht.
    private func extractSymbol(start: Int, length: Int, offset: Double, re outRe: inout [Float], im outIm: inout [Float]) {
        let local = start - bufferStart
        let n = Double(length)
        // Phase −2π·offset·t/N mit absolutem t (Double, damit große Indizes genau bleiben).
        let phase0 = -2 * Double.pi * (offset * Double(start)).truncatingRemainder(dividingBy: n) / n
        let step = -2 * Double.pi * offset / n
        var c = cos(phase0), s = sin(phase0)
        let cs = cos(step), ss = sin(step)
        for i in 0..<length {
            let a = re[local + i], b = im[local + i]
            outRe[i] = a * Float(c) - b * Float(s)
            outIm[i] = a * Float(s) + b * Float(c)
            let nc = c * cs - s * ss
            s = s * cs + c * ss
            c = nc
            if i & 1023 == 1023 {          // Betrag nachführen
                let norm = 1 / (c * c + s * s).squareRoot()
                c *= norm; s *= norm
            }
        }
    }

    /// Spektrum eines Symbols, nach Trägerindex 0…kmax geordnet. `delay`: das
    /// Symbol liegt so viele Abtastwerte später als nominal (Abtastratenablage) –
    /// ganzzahlig über die Fensterlage, der Rest als Phasenrampe über die Träger.
    private func symbolSpectrum(p1: Int, symbol l: Int, fft size: T2FFTSize, gi: T2GuardInterval, offset: Double,
                                backoff: Int, kmax: Int, delay: Double = 0) -> (re: [Float], im: [Float]) {
        let n = size.size, g = gi.samples(size)
        let shift = Int(delay.rounded())
        var r = [Float](repeating: 0, count: n), i = r
        extractSymbol(start: p1 + 2048 + l * (n + g) + g - backoff + shift, length: n, offset: offset, re: &r, im: &i)
        fft(n).forward(&r, &i)
        var outRe = [Float](repeating: 0, count: kmax + 1), outIm = outRe
        for k in 0...kmax {
            let bin = ((k - kmax / 2) % n + n) % n
            outRe[k] = r[bin]; outIm[k] = i[bin]
        }
        let rest = delay - Double(shift)
        if rest != 0 { Self.delay(re: &outRe, im: &outIm, by: rest, fftSize: n) }
        return (outRe, outIm)
    }

    /// Phasenrampe e^{j2π(k − kmax/2)·d/N}: verschiebt das Symbol um d Abtastwerte früher.
    static func delay(re: inout [Float], im: inout [Float], by d: Double, fftSize n: Int) {
        let kmax = re.count - 1
        let step = 2 * Double.pi * d / Double(n)
        let start = -Double(kmax / 2) * step
        var c = cos(start), s = sin(start)
        let cs = cos(step), ss = sin(step)
        for k in 0...kmax {
            let a = re[k], b = im[k]
            re[k] = a * Float(c) - b * Float(s)
            im[k] = a * Float(s) + b * Float(c)
            let nc = c * cs - s * ss
            s = s * cs + c * ss
            c = nc
        }
    }

    /// Verschiebung der Symbollage von Symbol zu Symbol (Abtastwerte) aus den
    /// Continual Pilots benachbarter Datensymbole: Korrelation getrennt für die
    /// untere und obere Bandhälfte; die Phasendifferenz der Hälften ist
    /// unabhängig von der gemeinsamen Phase (CPE) und wächst mit der Drift.
    private func symbolDrift(spectra: [(re: [Float], im: [Float])], layout: T2Layout) -> Double? {
        let np2 = layout.fft.p2Symbols
        let last = layout.frameClosing ? layout.symbolsPerFrame - 2 : layout.symbolsPerFrame - 1
        guard last > np2 else { return nil }
        let cps = layout.continualPilots
        let middle = layout.kmax / 2
        var sumLower = 0.0, sumUpper = 0.0, countLower = 0, countUpper = 0
        for k in cps { if k < middle { sumLower += Double(k); countLower += 1 } else { sumUpper += Double(k); countUpper += 1 } }
        guard countLower > 0, countUpper > 0 else { return nil }
        let spread = sumUpper / Double(countUpper) - sumLower / Double(countLower)
        var cRe = 0.0, cIm = 0.0
        for l in (np2 + 1)...last {
            let a = spectra[l - 1 - np2], b = spectra[l - np2]
            var lowRe: Float = 0, lowIm: Float = 0, upRe: Float = 0, upIm: Float = 0
            for k in cps {
                let sg = T2Reference.sign(symbol: l, carrier: k, layout: layout) * T2Reference.sign(symbol: l - 1, carrier: k, layout: layout)
                let zr = (b.re[k] * a.re[k] + b.im[k] * a.im[k]) * sg
                let zi = (b.im[k] * a.re[k] - b.re[k] * a.im[k]) * sg
                if k < middle { lowRe += zr; lowIm += zi } else { upRe += zr; upIm += zi }
            }
            cRe += Double(upRe * lowRe + upIm * lowIm)
            cIm += Double(upIm * lowRe - upRe * lowIm)
        }
        guard cRe != 0 || cIm != 0 else { return nil }
        // Phase = 2π·Verschiebung·Spreizung/N; positiv = das Fenster liegt von Symbol zu Symbol später
        // relativ zum Symbol (das Symbol kommt also früher als erwartet).
        return atan2(cIm, cRe) * Double(layout.fft.size) / (2 * .pi * spread)
    }

    /// P2-Symbole → Datenzellen (frequenz-deinterleavt) samt Gewicht |H|²/N0.
    private func decodeP2(p1: Int, fft size: T2FFTSize, gi: T2GuardInterval, offset: Double, backoff: Int,
                          layout: T2Layout?) -> (re: [[Float]], im: [[Float]], w: [[Float]])? {
        // Im normalen Trägermodus indizieren – die Datenträger des P2 sind in beiden Modi physikalisch gleich.
        let kext = layout?.extended == true ? size.kext : 0
        let kmax = size.kmaxNormal + 2 * kext
        let step = size == .k32 ? 6 : 3
        let reserved = Set(T2Tables.p2ReservedCarriers(fftK: size.rawValue).map { $0 + kext })
        let carriers = (0...kmax).filter { k in
            k % step != 0 && !(kext > 0 && (k < kext || k > kmax - kext)) && !reserved.contains(k)
        }
        let ap2: Float = size == .k32 ? Float(37).squareRoot() / 5 : Float(31).squareRoot() / 5
        let interleaver = T2Interleavers.frequency(size, count: carriers.count, odd: false)
        let interleaverOdd = T2Interleavers.frequency(size, count: carriers.count, odd: true)
        var outRe: [[Float]] = [], outIm: [[Float]] = [], outW: [[Float]] = []
        for l in 0..<size.p2Symbols {
            let spectrum = symbolSpectrum(p1: p1, symbol: l, fft: size, gi: gi, offset: offset, backoff: backoff, kmax: kmax)
            let pilots = Array(stride(from: 0, through: kmax, by: step))
            let values = pilots.map { k -> (Float, Float) in
                let sign: Float = (T2Reference.prbs[k + (kext > 0 ? 0 : size.kext)] ^ T2Reference.frameSequence[l]) == 0 ? 1 : -1
                return (spectrum.re[k] * sign / ap2, spectrum.im[k] * sign / ap2)
            }
            let h = interpolate(size: size, grid: pilots, values: values, kmax: kmax, step: step)
            // Rauschen grob aus dem Pilotrest (Feinschätzung macht der L1-Dekoder über BPSK).
            var hdRe = [Float](repeating: 0, count: carriers.count), hdIm = hdRe, hdW = hdRe
            for (p, k) in carriers.enumerated() {
                let hr = h.re[k], hi = h.im[k]
                let mag = max(hr * hr + hi * hi, 1e-12)
                hdRe[p] = (spectrum.re[k] * hr + spectrum.im[k] * hi) / mag
                hdIm[p] = (spectrum.im[k] * hr - spectrum.re[k] * hi) / mag
                hdW[p] = mag
            }
            let h0 = l % 2 == 0 ? interleaver : interleaverOdd
            var xRe = [Float](repeating: 0, count: carriers.count), xIm = xRe, xW = xRe
            for p in 0..<carriers.count {
                let to = Int(h0[p])
                xRe[to] = hdRe[p]; xIm[to] = hdIm[p]; xW[to] = hdW[p]
            }
            outRe.append(xRe); outIm.append(xIm); outW.append(xW)
        }
        // Rauschen aus den L1-pre-Zellen (BPSK, ±1): N0 relativ zu |H|².
        let np2 = size.p2Symbols
        var noise: Float = 0
        var count = 0
        for p in 0..<T2L1Decoder.preCells {
            let l = p % np2, i = p / np2
            let e = (abs(outRe[l][i]) - 1) * (abs(outRe[l][i]) - 1) + outIm[l][i] * outIm[l][i]
            noise += outW[l][i] * e
            count += 1
        }
        let n0 = max(noise / Float(count), 1e-12)
        for l in 0..<np2 { for i in outW[l].indices { outW[l][i] /= n0 } }
        return (outRe, outIm, outW)
    }

    /// Kanal zwischen Pilotträgern interpolieren: über den Verzögerungsbereich
    /// (IFFT → Fenster um die Impulsantwort → FFT). Keine Drehung der
    /// Impulsantwort: N/Dx ist oft nicht ganzzahlig (16K/6 = 2730,67), dann
    /// überlappen die Ausläufer an der Periodengrenze mit dem nächsten Abbild.
    private func interpolate(size: T2FFTSize, grid: [Int], values: [(Float, Float)], kmax: Int, step: Int) -> (re: [Float], im: [Float]) {
        let n = size.size
        guard grid.count > 1 else { return ([Float](repeating: 1, count: kmax + 1), [Float](repeating: 0, count: kmax + 1)) }
        let period = n / step
        var xr = [Float](repeating: 0, count: n), xi = xr
        for (index, k) in grid.enumerated() { xr[k] = values[index].0; xi[k] = values[index].1 }
        fft(n).inverse(&xr, &xi)
        var power = [Float](repeating: 0, count: period)
        for t in 0..<period { power[t] = xr[t] * xr[t] + xi[t] * xi[t] }
        let peak = power.max() ?? 0
        // Anteile über −25 dB der Spitze, mit Rand für die Ausläufer gebrochener Verzögerungen.
        var keep = [Bool](repeating: false, count: period)
        let margin = max(32, period / 32)
        for t in 0..<period where power[t] > peak * 0.003 {
            for d in -margin...margin { keep[((t + d) % period + period) % period] = true }
        }
        for t in 0..<n where t >= period || !keep[t] { xr[t] = 0; xi[t] = 0 }
        fft(n).forward(&xr, &xi)
        let scale = Float(step) / Float(n)
        var outRe = [Float](repeating: 0, count: kmax + 1), outIm = outRe
        for k in 0...kmax { outRe[k] = xr[k] * scale; outIm[k] = xi[k] * scale }
        return (outRe, outIm)
    }

    // MARK: - Rahmen

    private func processFrame() {
        guard var current = lock else { return }
        let layout = current.layout
        let size = current.fft, gi = current.guardInterval
        let kmax = layout.kmax
        let lf = layout.symbolsPerFrame
        let np2 = size.p2Symbols

        // P2 und L1: L1-pre ist statisch; L1-post bei statischer Einteilung nur gelegentlich neu.
        guard let p2 = decodeP2(p1: current.p1, fft: size, gi: gi, offset: current.offset, backoff: current.backoff, layout: layout) else { return }
        let staticPLPs = current.post.plps.allSatisfy(\.staticFlag)
        current.frameIndex = (current.frameIndex + 1) % max(1, current.pre.t2Frames)
        if !staticPLPs || current.framesSincePost >= 40 {
            if let post = T2L1Decoder.decodePost(re: p2.re, im: p2.im, weights: p2.w, pre: current.pre) {
                if post.plps.map(\.id) != current.post.plps.map(\.id) || post.plps.map(\.codeRate) != current.post.plps.map(\.codeRate) {
                    current.post = post
                    lock = current
                    selectPLP(post)
                }
                current.post = post
                current.frameIndex = post.frameIndex
                current.framesSincePost = 0
                current.failures = 0
            } else {
                current.failures += 1
            }
        }
        current.framesSincePost += 1
        status.post = current.post

        // Datensymbole: Spektren, Gleichphase (CPE), Kanal über Nachbarsymbole gemittelt.
        var spectra: [(re: [Float], im: [Float])] = []
        spectra.reserveCapacity(lf)
        let symbolLength = Double(layout.symbolSamples)
        for l in np2..<lf {
            spectra.append(symbolSpectrum(p1: current.p1, symbol: l, fft: size, gi: gi, offset: current.offset,
                                          backoff: current.backoff, kmax: kmax, delay: current.drift * Double(l) * symbolLength))
        }
        // Restliche Abtastratenablage dieses Rahmens messen und gleich ausgleichen.
        if let perSymbol = symbolDrift(spectra: spectra, layout: layout) {
            for l in np2..<lf {
                var symbol = spectra[l - np2]
                Self.delay(re: &symbol.re, im: &symbol.im, by: -perSymbol * Double(l), fftSize: size.size)
                spectra[l - np2] = symbol
            }
            current.drift -= 0.5 * perSymbol / symbolLength
            status.sampleRateOffsetPPM = current.drift * 1e6
            debugLog("Drift \(perSymbol) Abtastwerte je Symbol, gesamt \(current.drift * 1e6) ppm")
        }
        let cps = layout.continualPilots
        let asp = layout.pattern.amplitude
        func sign(_ l: Int, _ k: Int) -> Float { T2Reference.sign(symbol: l, carrier: k, layout: layout) }
        // CPE relativ zum ersten Datensymbol über die Continual Pilots.
        var cpe = [Float](repeating: 0, count: lf)
        let firstData = np2
        for l in np2..<lf where !layout.isFrameClosing(l) {
            var sRe: Float = 0, sIm: Float = 0
            let a = spectra[l - np2], b = spectra[firstData - np2]
            for k in cps {
                let sa = sign(l, k), sb = sign(firstData, k)
                let ar = a.re[k] * sa, ai = a.im[k] * sa, br = b.re[k] * sb, bi = b.im[k] * sb
                sRe += ar * br + ai * bi
                sIm += ai * br - ar * bi
            }
            cpe[l] = atan2(sIm, sRe)
        }
        if layout.frameClosing { cpe[lf - 1] = cpe[lf - 2] }

        let half = max(averaging, layout.pattern.dy)
        let dx = layout.pattern.dx
        let kext = layout.extended ? size.kext : 0
        let grid = Array(stride(from: kext % dx, through: kmax, by: dx))
        // Rauschen je Träger aus den Resten der Streupiloten (für |H|²/σ²(k)).
        var noiseSum = [Float](repeating: 0, count: kmax + 1)
        var noiseCount = [Float](repeating: 0, count: kmax + 1)
        var cellsRe: [Float] = [], cellsIm: [Float] = [], cellsW: [Float] = []
        // Zuerst die PLP-Zellen des P2 (nach dem L1).
        let l1Cells = T2L1Decoder.preCells + current.pre.l1PostSize
        for l in 0..<np2 {
            let from = l1Cells / np2
            cellsRe += p2.re[l][from...]; cellsIm += p2.im[l][from...]
            cellsW += p2.w[l][from...].map { $0 }   // P2-Gewichte schon auf N0 bezogen
        }
        let p2CellCount = cellsRe.count
        var dataWeights: [Float] = []
        var dataCarriers: [Int32] = []
        var dataRe: [Float] = [], dataIm: [Float] = []
        for l in np2..<lf {
            let fc = layout.isFrameClosing(l)
            var acc = [Float](repeating: 0, count: (kmax + 1) * 2)
            var count = [Float](repeating: 0, count: kmax + 1)
            let window = fc ? (max(np2, l - half)...l) : (max(np2, l - half)...min(layout.frameClosing ? lf - 2 : lf - 1, l + half))
            for m in window {
                let pilots = layout.scatteredPilots(symbol: m)
                let s = spectra[m - np2]
                let rot = -cpe[m]
                let c = cos(rot), sn = sin(rot)
                for k in pilots {
                    let sg = sign(m, k) / asp
                    let r = s.re[k] * sg, i = s.im[k] * sg
                    acc[2 * k] += r * c - i * sn
                    acc[2 * k + 1] += r * sn + i * c
                    count[k] += 1
                }
            }
            var gridK: [Int] = [], values: [(Float, Float)] = []
            for k in grid where count[k] > 0 { gridK.append(k); values.append((acc[2 * k] / count[k], acc[2 * k + 1] / count[k])) }
            var h = interpolate(size: size, grid: gridK, values: values, kmax: kmax, step: dx)
            let c = cos(cpe[l]), sn = sin(cpe[l])
            for k in 0...kmax {
                let r = h.re[k], i = h.im[k]
                h.re[k] = r * c - i * sn; h.im[k] = r * sn + i * c
            }
            // Rauschen aus den eigenen Piloten.
            let s = spectra[l - np2]
            for k in layout.scatteredPilots(symbol: l) {
                let sg = sign(l, k)
                let er = s.re[k] * sg - asp * h.re[k], ei = s.im[k] * sg - asp * h.im[k]
                noiseSum[k] += er * er + ei * ei
                noiseCount[k] += 1
            }
            let carriers = layout.dataCarriers(symbol: l)
            let interleaver = frequencyInterleaver(size, count: carriers.count, odd: l % 2 == 1)
            var xRe = [Float](repeating: 0, count: carriers.count), xIm = xRe, xW = xRe
            var xK = [Int32](repeating: 0, count: carriers.count)
            for (p, k) in carriers.enumerated() {
                let hr = h.re[k], hi = h.im[k]
                let mag = max(hr * hr + hi * hi, 1e-12)
                let to = Int(interleaver[p])
                xRe[to] = (s.re[k] * hr + s.im[k] * hi) / mag
                xIm[to] = (s.im[k] * hr - s.re[k] * hi) / mag
                xW[to] = mag
                xK[to] = Int32(k)
            }
            let active = fc ? layout.frameClosingActive : carriers.count
            dataRe += xRe[0..<active]; dataIm += xIm[0..<active]; dataWeights += xW[0..<active]
            dataCarriers += xK[0..<active]
        }
        let sigma2 = noiseProfile(sum: noiseSum, count: noiseCount)
        // Störabstand der Datenzellen: mittleres |H|² über mittlere Rauschleistung der Streupiloten.
        // (Früher aus den Continual Pilots: las wegen deren Interpolationsfehler 0,2 dB, mit
        // 0-dB-Echo 0,5 dB zu niedrig; dieser Wert liegt in der Simulation auf 0,1 dB genau.)
        var signalSum = 0.0, noiseTotal = 0.0
        for i in dataWeights.indices { signalSum += Double(dataWeights[i]); noiseTotal += Double(sigma2[Int(dataCarriers[i])]) }
        status.snr = 10 * log10(max(signalSum / max(noiseTotal, 1e-12), 1e-6))
        cellsRe += dataRe; cellsIm += dataIm
        cellsW.reserveCapacity(cellsW.count + dataWeights.count)
        for i in dataWeights.indices { cellsW.append(dataWeights[i] / sigma2[Int(dataCarriers[i])]) }
        _ = p2CellCount

        // PLP-Zellen herausschneiden und dekodieren.
        if let decoder = plpDecoder, let plp = current.post.plps.first(where: { $0.id == decoder.plp.id }) {
            let interval = max(1, plp.frameInterval)
            let relative = current.frameIndex - plp.firstFrame
            if relative >= 0 && relative % interval == 0 && plp.blocks > 0 {
                let positionInIF = (relative / interval) % decoder.framesPerIF
                let total = plp.blocks * decoder.cellsPerBlock / decoder.framesPerIF
                var sliceRe: [Float] = [], sliceIm: [Float] = [], sliceW: [Float] = []
                if plp.type == 2, current.post.subSlicesPerFrame > 1 {
                    let slices = current.post.subSlicesPerFrame
                    let perSlice = total / slices
                    for i in 0..<slices {
                        let start = plp.start + i * current.post.subSliceInterval
                        guard start + perSlice <= cellsRe.count else { break }
                        sliceRe += cellsRe[start..<(start + perSlice)]
                        sliceIm += cellsIm[start..<(start + perSlice)]
                        sliceW += cellsW[start..<(start + perSlice)]
                    }
                } else if plp.start + total <= cellsRe.count {
                    sliceRe = Array(cellsRe[plp.start..<(plp.start + total)])
                    sliceIm = Array(cellsIm[plp.start..<(plp.start + total)])
                    sliceW = Array(cellsW[plp.start..<(plp.start + total)])
                }
                if sliceRe.count == total {
                    decoder.add(re: sliceRe[...], im: sliceIm[...], weight: sliceW[...], blocks: plp.blocks, positionInIF: positionInIF)
                }
            }
        }
        status.frames += 1

        // Zeitnachführung über die Impulsantwort des P2 und Frequenznachführung über die CPE-Steigung.
        trackTiming(&current, p2Spectrum: nil)
        if lf - np2 > 4 {
            let last = layout.frameClosing ? lf - 2 : lf - 1
            let slope = Double(cpe[last] - cpe[np2]) / Double(last - np2)   // rad je Symbol
            let symbolDuration = Double(layout.symbolSamples) / Double(size.size)
            current.offset += 0.5 * slope / (2 * .pi * symbolDuration)
            status.frequencyOffsetHz = current.offset * T2FrontEnd.outputRate / Double(size.size)
        }
        // Nächster Rahmen: um die Drift verschoben (Bruchteile aufsummiert).
        current.p1Fraction += Double(layout.frameSamples) * current.drift
        let whole = current.p1Fraction.rounded()
        current.p1Fraction -= whole
        current.p1 += layout.frameSamples + Int(whole)
        if current.failures > 10 {
            lock = nil
            status.locked = false
            status.stage = String(localized: "Signal verloren")
        } else {
            lock = current
        }
    }

    /// Rauschleistung je Träger: Pilotreste über ±`noiseWindow` Träger gemittelt und
    /// über die Rahmen nachgeführt. Fängt ungleichmäßiges Rauschen ab, etwa
    /// Reste eines Nachbarkanals an der Bandkante (Messung siehe CLAUDE.md).
    private var noiseHistory: [Float] = []
    static let noiseWindow = 48

    private func noiseProfile(sum: [Float], count: [Float]) -> [Float] {
        let n = sum.count
        var prefixSum = [Double](repeating: 0, count: n + 1), prefixCount = prefixSum
        for k in 0..<n {
            prefixSum[k + 1] = prefixSum[k] + Double(sum[k])
            prefixCount[k + 1] = prefixCount[k] + Double(count[k])
        }
        let total = prefixSum[n] / max(1, prefixCount[n])
        var profile = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let lo = max(0, k - Self.noiseWindow), hi = min(n, k + Self.noiseWindow + 1)
            let c = prefixCount[hi] - prefixCount[lo]
            profile[k] = Float(c > 0 ? (prefixSum[hi] - prefixSum[lo]) / c : total)
        }
        if noiseHistory.count == n {
            for k in 0..<n { profile[k] = 0.5 * profile[k] + 0.5 * noiseHistory[k] }
        }
        noiseHistory = profile
        let floor = Float(total) * 1e-3 + 1e-12
        return profile.map { max($0, floor) }
    }

    /// Hält das FFT-Fenster über der Impulsantwort: früheste Spur bei `backoff`.
    private func trackTiming(_ current: inout Lock, p2Spectrum: Any?) {
        let size = current.fft, gi = current.guardInterval
        let n = size.size
        let kmax = current.layout.kmax
        let kext = current.layout.extended ? size.kext : 0
        let step = size == .k32 ? 6 : 3
        let spectrum = symbolSpectrum(p1: current.p1, symbol: 0, fft: size, gi: gi, offset: current.offset,
                                      backoff: current.backoff, kmax: kmax)
        var xr = [Float](repeating: 0, count: n), xi = xr
        for k in stride(from: 0, through: kmax, by: step) {
            let sign: Float = (T2Reference.prbs[k + (kext > 0 ? 0 : size.kext)] ^ T2Reference.frameSequence[0]) == 0 ? 1 : -1
            xr[k] = spectrum.re[k] * sign; xi[k] = spectrum.im[k] * sign
        }
        fft(n).inverse(&xr, &xi)
        let period = n / step
        var power = [Float](repeating: 0, count: period)
        for t in 0..<period { power[t] = xr[t] * xr[t] + xi[t] * xi[t] }
        guard let peak = power.max(), peak > 0 else { return }
        // Verzögerungen relativ zum Fensteranfang, zentriert: −period/2 … period/2.
        var earliest = Int.max, latest = Int.min
        for t in 0..<period where power[t] > peak * 0.03 {
            let d = t < period / 2 ? t : t - period
            earliest = min(earliest, d); latest = max(latest, d)
        }
        guard earliest != Int.max else { return }
        // Ziel: Mitte des störfreien Bereichs → früheste Spur bei backoff + (G − Spreizung)/2 … vereinfacht:
        // früheste Spur soll bei `backoff` liegen (Fenster beginnt `backoff` vor dem Ende des Schutzintervalls).
        let g = gi.samples(size)
        let spread = latest - earliest
        let wanted = max(16, min(g / 2, (g - spread) / 2))
        let drift = earliest - wanted
        debugLog("Impulsantwort: früheste \(earliest), späteste \(latest), Ziel \(wanted), Korrektur \(drift)")
        if abs(drift) > 2 {
            current.p1 += drift / 2 + (drift > 0 ? 1 : -1)
        }
    }

    private var interleaverCache: [String: [Int32]] = [:]
    private func frequencyInterleaver(_ size: T2FFTSize, count: Int, odd: Bool) -> [Int32] {
        let key = "\(size.rawValue)-\(count)-\(odd)"
        if let h = interleaverCache[key] { return h }
        let h = T2Interleavers.frequency(size, count: count, odd: odd)
        interleaverCache[key] = h
        return h
    }
}

