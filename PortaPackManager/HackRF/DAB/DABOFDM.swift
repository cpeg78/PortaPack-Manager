import Accelerate
import Foundation

/// Demoduliert DAB Mode I (2,048 MS/s, siehe `DABFrontEnd`): Rahmensuche über das
/// Nullsymbol, Frequenzkorrektur (Bruchteil über das Schutzintervall,
/// ganzzahlige Trägerablage über das Phasenreferenzsymbol), Feinzeitlage
/// über die PRS-Korrelation, FFT und DQPSK-Differenzdemodulation.
///
/// Ergebnis je Rahmen: weiche Bits (positiv = 0) für den FIC (3 Symbole)
/// und den MSC (72 Symbole), bereits frequenz-entschachtelt.
final class DABOFDMDemodulator: @unchecked Sendable {
    struct Frame: Sendable {
        var fic: [Int16]
        var msc: [Int16]
    }

    enum State: Equatable, Sendable {
        case searching
        case locked
    }

    private typealias M = DABMode

    /// FFT-Fenster beginnt so viele Abtastwerte vor dem Nutzteil (im
    /// Schutzintervall), damit kleine Zeitfehler und Echos nicht stören.
    static let windowAdvance = 64

    private(set) var state: State = .searching
    /// Aktuelle Frequenzkorrektur in Hz (positiv: Signal liegt zu hoch).
    private(set) var frequencyOffset: Double = 0
    /// Geschätzter Störabstand in dB (aus dem Phasenreferenzsymbol).
    private(set) var snr: Double = 0
    /// Rahmen seit der letzten Synchronisation.
    private(set) var framesDecoded = 0
    /// Erfolglose Suchversuche in Folge (für den Suchlauf: „kein DAB“).
    private(set) var failedSearches = 0

    private var re: [Float] = []
    private var im: [Float] = []
    private var frameStart = 0
    private var badFrames = 0
    private var coarseRounds = 0
    private var ncoPhase = 0.0

    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let prsRe = DABTables.prsReference.re
    private let prsIm = DABTables.prsReference.im
    private let interleaver = DABTables.frequencyInterleaver
    /// Differenz der PRS-Phasen benachbarter Träger (für die Grobsuche).
    private let prsDiffRe: [Float]
    private let prsDiffIm: [Float]

    // Arbeitsspeicher
    private var fftInRe = [Float](repeating: 0, count: M.fftSize)
    private var fftInIm = [Float](repeating: 0, count: M.fftSize)
    private var previousRe = [Float](repeating: 0, count: M.fftSize)
    private var previousIm = [Float](repeating: 0, count: M.fftSize)
    private var currentRe = [Float](repeating: 0, count: M.fftSize)
    private var currentIm = [Float](repeating: 0, count: M.fftSize)

    init() {
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(M.fftSize), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(M.fftSize), .INVERSE)!
        var dRe = [Float](repeating: 0, count: M.fftSize)
        var dIm = [Float](repeating: 0, count: M.fftSize)
        let pr = DABTables.prsReference
        for k in -767...768 where k != 0 && k != 1 {
            let a = (k + M.fftSize) % M.fftSize, b = (k - 1 + M.fftSize) % M.fftSize
            // P[k] · conj(P[k−1])
            dRe[a] = pr.re[a] * pr.re[b] + pr.im[a] * pr.im[b]
            dIm[a] = pr.im[a] * pr.re[b] - pr.re[a] * pr.im[b]
        }
        prsDiffRe = dRe
        prsDiffIm = dIm
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Setzt alles zurück (neuer Kanal). `frequencyOffset` bleibt als Startwert.
    func reset(keepFrequency: Bool = true) {
        re.removeAll(keepingCapacity: true)
        im.removeAll(keepingCapacity: true)
        state = .searching
        frameStart = 0
        badFrames = 0
        coarseRounds = 0
        framesDecoded = 0
        failedSearches = 0
        snr = 0
        if !keepFrequency { frequencyOffset = 0 }
    }

    // MARK: - Eingang

    /// Nimmt komplexe Abtastwerte (2,048 MS/s) entgegen und liefert alle
    /// fertig demodulierten Rahmen.
    func process(re r: [Float], im i: [Float]) -> [Frame] {
        var bRe = r, bIm = i
        mix(&bRe, &bIm)
        re.append(contentsOf: bRe)
        im.append(contentsOf: bIm)
        var frames: [Frame] = []
        while true {
            switch state {
            case .searching:
                guard acquire() else { return frames }
            case .locked:
                guard re.count >= frameStart + M.frameLength + M.nullLength + M.symbolLength else { return frames }
                if let frame = demodulateFrame() { frames.append(frame) }
            }
        }
    }

    /// Multipliziert mit exp(−j·2π·f·t) für die aktuelle Frequenzkorrektur.
    private func mix(_ r: inout [Float], _ i: inout [Float]) {
        let step = -2 * Double.pi * frequencyOffset / Double(M.sampleRate)
        guard step != 0 else { return }
        let count = r.count
        var phases = [Float](repeating: 0, count: count)
        var phase = ncoPhase
        for n in 0..<count {
            phases[n] = Float(phase)
            phase += step
            if phase > .pi { phase -= 2 * .pi } else if phase < -.pi { phase += 2 * .pi }
        }
        ncoPhase = phase
        var c = [Float](repeating: 0, count: count)
        var s = [Float](repeating: 0, count: count)
        var n32 = Int32(count)
        vvsincosf(&s, &c, phases, &n32)
        for n in 0..<count {
            let a = r[n], b = i[n]
            r[n] = a * c[n] - b * s[n]
            i[n] = a * s[n] + b * c[n]
        }
    }

    /// Verwirft Abtastwerte vor `index`.
    private func discard(upTo index: Int) {
        let n = min(index, re.count)
        guard n > 0 else { return }
        re.removeFirst(n)
        im.removeFirst(n)
        frameStart -= n
    }

    // MARK: - Synchronisation

    /// Sucht Nullsymbol, korrigiert die Frequenz und legt die Zeitlage fest.
    /// Liefert `false`, wenn mehr Daten nötig sind.
    private func acquire() -> Bool {
        let needed = M.frameLength + M.nullLength + M.symbolsPerFrame * M.symbolLength
        guard re.count >= needed else { return false }

        guard let nullStart = findNull(in: 0..<(M.frameLength + M.nullLength)) else {
            failedSearches += 1
            discard(upTo: M.frameLength)
            return true
        }
        let prsStart = nullStart + M.nullLength

        // 1. Bruchteil der Frequenzablage aus dem Schutzintervall.
        let fine = guardFrequency(firstSymbol: prsStart, symbols: M.symbolsPerFrame)
        if abs(fine) > 25 {
            retune(by: fine)
            return true
        }

        // 2. Ganzzahlige Trägerablage aus dem Phasenreferenzsymbol.
        loadWindow(at: prsStart + M.guardLength - Self.windowAdvance)
        fft(forward: true)
        let shift = coarseCarrierShift()
        if shift != 0 {
            coarseRounds += 1
            if coarseRounds > 4 {
                // Keine stabile Lösung – vermutlich kein DAB-Signal.
                coarseRounds = 0
                failedSearches += 1
                frequencyOffset = 0
            } else {
                retune(by: Double(shift) * M.carrierSpacing)
                return true
            }
        }
        coarseRounds = 0

        // 3. Feinzeitlage über die Korrelation mit dem PRS.
        guard let (peak, quality) = prsCorrelation(), quality > 8 else {
            failedSearches += 1
            discard(upTo: prsStart)
            return true
        }
        let timingError = peak > M.fftSize / 2 ? peak - M.fftSize : peak
        frameStart = nullStart + (timingError - Self.windowAdvance)
        if frameStart < 0 { frameStart += M.frameLength }
        state = .locked
        badFrames = 0
        failedSearches = 0
        return true
    }

    /// Ändert die Korrektur und verwirft die alten Daten.
    private func retune(by hz: Double) {
        frequencyOffset += hz
        if abs(frequencyOffset) > 60_000 { frequencyOffset = 0 }
        re.removeAll(keepingCapacity: true)
        im.removeAll(keepingCapacity: true)
        frameStart = 0
    }

    /// Fenster mit der geringsten Energie (Länge T_null), sofern deutlich
    /// leiser als der Durchschnitt.
    private func findNull(in range: Range<Int>) -> Int? {
        let end = range.upperBound + M.nullLength
        var prefix = [Double](repeating: 0, count: end + 1)
        for n in 0..<end {
            prefix[n + 1] = prefix[n] + Double(re[n] * re[n] + im[n] * im[n])
        }
        var best = 0
        var bestEnergy = Double.infinity
        var n = range.lowerBound
        while n < range.upperBound {
            let e = prefix[n + M.nullLength] - prefix[n]
            if e < bestEnergy { bestEnergy = e; best = n }
            n += 4
        }
        // Grobraster verfeinern.
        for m in max(0, best - 4)...min(range.upperBound - 1, best + 4) {
            let e = prefix[m + M.nullLength] - prefix[m]
            if e < bestEnergy { bestEnergy = e; best = m }
        }
        let average = prefix[end] / Double(end)
        guard average > 0, bestEnergy / Double(M.nullLength) < 0.35 * average else { return nil }
        return best
    }

    /// Frequenzablage (Bruchteil eines Trägerabstands) aus der Korrelation
    /// von Schutzintervall und Symbolende.
    private func guardFrequency(firstSymbol: Int, symbols: Int) -> Double {
        var sumRe: Double = 0, sumIm: Double = 0
        for l in 0..<symbols {
            let s = firstSymbol + l * M.symbolLength
            guard s + M.symbolLength <= re.count else { break }
            var accRe: Float = 0, accIm: Float = 0
            for i in 0..<M.guardLength {
                let a = s + i, b = s + i + M.fftSize
                // y[b] · conj(y[a])
                accRe += re[b] * re[a] + im[b] * im[a]
                accIm += im[b] * re[a] - re[b] * im[a]
            }
            sumRe += Double(accRe); sumIm += Double(accIm)
        }
        return atan2(sumIm, sumRe) / (2 * .pi) * M.carrierSpacing
    }

    /// Ganzzahlige Trägerablage: Korrelation der Phasendifferenzen
    /// benachbarter Träger mit denen des PRS (unabhängig von der Zeitlage).
    private func coarseCarrierShift() -> Int {
        var bestShift = 0
        var bestMetric: Float = -1
        let n = M.fftSize
        for shift in -35...35 {
            var accRe: Float = 0, accIm: Float = 0
            for k in -767...768 where k != 0 && k != 1 {
                let ref = (k + n) % n
                let a = (k + shift + n) % n, b = (k - 1 + shift + n) % n
                // Y[a]·conj(Y[b])
                let dRe = currentRe[a] * currentRe[b] + currentIm[a] * currentIm[b]
                let dIm = currentIm[a] * currentRe[b] - currentRe[a] * currentIm[b]
                // · conj(D_ref)
                accRe += dRe * prsDiffRe[ref] + dIm * prsDiffIm[ref]
                accIm += dIm * prsDiffRe[ref] - dRe * prsDiffIm[ref]
            }
            let metric = accRe * accRe + accIm * accIm
            if metric > bestMetric { bestMetric = metric; bestShift = shift }
        }
        return bestShift
    }

    /// Kanalimpulsantwort aus dem aktuellen Spektrum (muss das PRS sein).
    /// Liefert Index der Spitze und Verhältnis Spitze/Mittel.
    private func prsCorrelation() -> (Int, Float)? {
        for k in 0..<M.fftSize {
            // Y · conj(P)
            fftInRe[k] = currentRe[k] * prsRe[k] + currentIm[k] * prsIm[k]
            fftInIm[k] = currentIm[k] * prsRe[k] - currentRe[k] * prsIm[k]
        }
        var outRe = [Float](repeating: 0, count: M.fftSize)
        var outIm = [Float](repeating: 0, count: M.fftSize)
        vDSP_DFT_Execute(inverse, fftInRe, fftInIm, &outRe, &outIm)
        var magnitude = [Float](repeating: 0, count: M.fftSize)
        for k in 0..<M.fftSize { magnitude[k] = (outRe[k] * outRe[k] + outIm[k] * outIm[k]).squareRoot() }
        var peak: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(magnitude, 1, &peak, &index, vDSP_Length(M.fftSize))
        let mean = magnitude.reduce(0, +) / Float(M.fftSize)
        guard mean > 0 else { return nil }
        return (Int(index), peak / mean)
    }

    // MARK: - Rahmen

    private func demodulateFrame() -> Frame? {
        let prsStart = frameStart + M.nullLength
        // PRS: Zeitlage nachführen und Referenz für das erste Datensymbol.
        loadWindow(at: prsStart + M.guardLength - Self.windowAdvance)
        fft(forward: true)
        let correlation = prsCorrelation()
        estimateSNR()
        guard let (peak, quality) = correlation, quality > 5 else {
            badFrames += 1
            if badFrames > 4 { loseSync() } else { advanceFrame() }
            return nil
        }
        badFrames = 0
        let timingError = peak > M.fftSize / 2 ? peak - M.fftSize : peak
        let correction = timingError - Self.windowAdvance
        if abs(correction) > 2 && abs(correction) < 200 {
            // Neu ausrichten und dieses PRS noch einmal holen.
            frameStart += correction > 0 ? min(correction, 50) : max(correction, -50)
            if frameStart < 0 { loseSync(); return nil }
            loadWindow(at: frameStart + M.nullLength + M.guardLength - Self.windowAdvance)
            fft(forward: true)
        } else if abs(correction) >= 200 {
            loseSync()
            return nil
        }
        swap(&previousRe, &currentRe)
        swap(&previousIm, &currentIm)

        let fine = guardFrequency(firstSymbol: frameStart + M.nullLength, symbols: M.symbolsPerFrame)

        var fic = [Int16](repeating: 0, count: M.ficSymbols * M.bitsPerSymbol)
        var msc = [Int16](repeating: 0, count: M.mscSymbols * M.bitsPerSymbol)
        for l in 1..<M.symbolsPerFrame {
            let start = frameStart + M.nullLength + l * M.symbolLength + M.guardLength - Self.windowAdvance
            loadWindow(at: start)
            fft(forward: true)
            if l <= M.ficSymbols {
                fic.withUnsafeMutableBufferPointer { softBits(into: $0, offset: (l - 1) * M.bitsPerSymbol) }
            } else {
                msc.withUnsafeMutableBufferPointer { softBits(into: $0, offset: (l - 1 - M.ficSymbols) * M.bitsPerSymbol) }
            }
            swap(&previousRe, &currentRe)
            swap(&previousIm, &currentIm)
        }

        // Frequenz sanft nachführen (wirkt auf neue Abtastwerte).
        frequencyOffset += 0.3 * fine
        framesDecoded += 1
        advanceFrame()
        return Frame(fic: fic, msc: msc)
    }

    private func advanceFrame() {
        frameStart += M.frameLength
        // Verarbeitetes verwerfen, aber etwas Vorlauf für die Zeitkorrektur lassen.
        if frameStart > M.nullLength { discard(upTo: frameStart - M.nullLength / 2) }
    }

    private func loseSync() {
        state = .searching
        badFrames = 0
        if frameStart > 0 { discard(upTo: min(frameStart, re.count)) }
        frameStart = 0
    }

    /// Kopiert T_u Abtastwerte ab `start` in den FFT-Eingang.
    private func loadWindow(at start: Int) {
        let s = max(0, start)
        re.withUnsafeBufferPointer { r in
            im.withUnsafeBufferPointer { i in
                for n in 0..<M.fftSize {
                    let idx = s + n
                    fftInRe[n] = idx < r.count ? r[idx] : 0
                    fftInIm[n] = idx < i.count ? i[idx] : 0
                }
            }
        }
    }

    /// FFT des Eingangs nach `current`.
    private func fft(forward isForward: Bool) {
        vDSP_DFT_Execute(isForward ? forward : inverse, fftInRe, fftInIm, &currentRe, &currentIm)
    }

    /// DQPSK: Phasendifferenz zum vorigen Symbol, frequenz-entschachtelt.
    private func softBits(into out: UnsafeMutableBufferPointer<Int16>, offset: Int) {
        var products = [Float](repeating: 0, count: 2 * M.carriers)
        var magnitudeSum: Float = 0
        for n in 0..<M.carriers {
            let bin = interleaver[n]
            let a = currentRe[bin], b = currentIm[bin]
            let c = previousRe[bin], d = previousIm[bin]
            // Y_l · conj(Y_{l−1})
            let pr = a * c + b * d
            let pi = b * c - a * d
            products[n] = pr
            products[M.carriers + n] = pi
            magnitudeSum += abs(pr) + abs(pi)
        }
        let mean = magnitudeSum / Float(2 * M.carriers)
        guard mean > 0 else { return }
        // Mittlerer Betrag ≈ 60, starke Träger begrenzt auf ±127.
        let gain = 60 / mean
        for n in 0..<(2 * M.carriers) {
            out[offset + n] = Int16(max(-127, min(127, (products[n] * gain).rounded())))
        }
    }

    /// Störabstand aus dem PRS-Spektrum: Leistung der genutzten Träger
    /// gegen die Bins außerhalb (mit Abstand zur Bandkante).
    private func estimateSNR() {
        var signal: Float = 0, noise: Float = 0
        var signalCount = 0, noiseCount = 0
        for k in -700...700 where k != 0 {
            let bin = (k + M.fftSize) % M.fftSize
            signal += currentRe[bin] * currentRe[bin] + currentIm[bin] * currentIm[bin]
            signalCount += 1
        }
        for k in 790...900 {
            for bin in [k, M.fftSize - k] {
                noise += currentRe[bin] * currentRe[bin] + currentIm[bin] * currentIm[bin]
                noiseCount += 1
            }
        }
        guard noise > 0, signalCount > 0 else { return }
        let ratio = (signal / Float(signalCount)) / (noise / Float(noiseCount))
        let db = 10 * log10(Double(max(ratio - 1, 1e-3)))
        snr = snr == 0 ? db : 0.8 * snr + 0.2 * db
    }
}
