import Accelerate
import Foundation

/// Modulationsparameter eines LoRa-Kanals.
struct LoRaParameters: Sendable, Equatable {
    var spreadingFactor: Int
    /// Bandbreite in Hz (125, 250 oder 500 kHz).
    var bandwidth: Double
    /// Sync-Wort (Meshtastic 0x2B, LoRaWAN 0x34, privat 0x12).
    var syncWord: UInt8 = 0x2B

    var symbolSamples: Int { 1 << spreadingFactor }
    var symbolSeconds: Double { Double(symbolSamples) / bandwidth }
    /// Low-Data-Rate-Optimierung schalten SX126x/RadioLib ab 16 ms Symbolzeit
    /// ein (SF11/250 kHz = 8,2 ms → aus; SF11/125 kHz = 16,4 ms → an).
    var lowDataRate: Bool { symbolSeconds >= 0.016 }
    /// Die beiden Sync-Symbole: je Nibble × 8.
    var syncSymbols: (Int, Int) { (Int(syncWord >> 4) << 3, Int(syncWord & 0x0F) << 3) }
}

/// Ein empfangener LoRa-Rahmen.
struct LoRaFrame: Sendable, Equatable {
    var payload: [UInt8]
    var codingRate: Int
    /// `nil`: Rahmen ohne CRC.
    var crcValid: Bool?
    /// Störabstand im Kanal (wie der Chip ihn meldet: bezogen auf die Bandbreite).
    var snrDB: Double
    /// Pegel des Signals in dBFS.
    var levelDB: Double
    var frequencyOffsetHz: Double
    /// Korrigierte Hamming-Kodewörter (Hinweis auf schwachen Empfang).
    var correctedCodewords: Int
    var date: Date
}

/// LoRa-Empfänger: HackRF mit 2 MS/s, der Kanal liegt 500 kHz über der
/// HackRF-Mitte (DC-Spitze weit weg). Mischen mit Periode 4, FIR auf
/// 4 × Bandbreite, dann ein schmaler Kanalfilter. Je Symbol wird jede vierte
/// Abtastung genommen (Raster mit Viertel-Chip-Auflösung), entfaltet
/// (Dechirp) und per FFT ausgewertet: Präambel suchen, auf die
/// Symbolgrenze ausrichten, Sync-Wort prüfen, aus den Down-Chirps Frequenz-
/// und Zeitablage trennen, Kopf und Nutzdaten dekodieren. Die Taktablage
/// folgt aus der Frequenzablage (gleicher Quarz im Sender) und wird je
/// Symbol nachgeführt.
final class LoRaDemodulator {
    static let inputRate = 2_000_000.0
    static let offset = 500_000.0
    /// Überabtastung im Kanal (Abtastwerte je Chip).
    static let oversampling = 4
    /// Mindestverhältnis Spitze zu mittlerer Leistung einer FFT-Zeile.
    static let detectThreshold: Float = 12
    /// So viele gleiche Präambel-Symbole hintereinander lösen die Synchronisation aus.
    static let preambleRun = 4

    let parameters: LoRaParameters
    /// Mittenfrequenz des Kanals (für die Taktablage aus der Frequenzablage).
    let centerFrequency: Double

    private let n: Int
    private let os = LoRaDemodulator.oversampling
    private let fft: vDSP_DFT_Setup
    private let upRe: [Float], upIm: [Float]

    // Vorstufe
    private let stage1Taps: [Float]
    private let stage1Factor: Int
    private let channelTaps: [Float]
    private var carry1Re: [Float] = [], carry1Im: [Float] = []
    private var carry2Re: [Float] = [], carry2Im: [Float] = []
    private var mixerPhase = 0

    // Abtastwerte mit `os` × Bandbreite. Alle Lagen zählen in diesen Werten.
    private var re: [Float] = [], im: [Float] = []
    private var position = 0
    private var state = State.search

    // Suche
    private var runBin = -1
    private var runLength = 0

    // Ausgerichtet
    private var alignedStart = 0
    private var alignedCount = 0
    private var preamble: [PreambleWindow] = []

    // Rahmen
    private var frame = FrameTiming()

    private(set) var crcErrors = 0
    private(set) var headerErrors = 0
    private(set) var detections = 0
    private(set) var noiseDB = -100.0

    private enum State { case search, preamble, sync2, down, frame }

    /// Ein Präambelfenster im ausgerichteten Raster.
    private struct PreambleWindow {
        var index: Int
        /// Lage des Up-Tons in FFT-Zeilen (mit Feinlage).
        var tone: Double
        var level: Float
        /// FFT-Werte bei den Zeilen −1, 0, +1.
        var re: [Float]
        var im: [Float]
    }

    private struct FrameTiming {
        var start = 0.0           // genauer Anfang der Nutzsymbole (Abtastwerte)
        var anchor = 0            // Anfang des ersten Down-Chirp-Fensters
        var cfo = 0.0             // Frequenzablage in FFT-Zeilen
        var drift = 0.0           // Taktablage (relativ)
        var levelDB = -100.0
        var header: LoRaCoding.Header?
        var nibbles: [UInt8] = []
        var corrected = 0
        var peakSum = 0.0
        var noiseSum = 0.0
        var symbolsRead = 0
    }

    init(parameters: LoRaParameters, centerFrequency: Double) {
        self.parameters = parameters
        self.centerFrequency = centerFrequency
        n = parameters.symbolSamples
        fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        // Referenz-Upchirp wie gr-lora_sdr `build_upchirp(id = 0)`.
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        let count = Double(n)
        for k in 0..<n {
            let x = Double(k)
            let phase = 2 * Double.pi * (x * x / (2 * count) - 0.5 * x)
            re[k] = Float(cos(phase))
            im[k] = Float(sin(phase))
        }
        upRe = re
        upIm = im

        let channelRate = parameters.bandwidth * Double(LoRaDemodulator.oversampling)
        stage1Factor = max(1, Int((Self.inputRate / channelRate).rounded()))
        // Stufe 1: grob, nur gegen Faltung beim Dezimieren (Faltung beginnt
        // erst bei 3,5 × Bandbreite).
        stage1Taps = Self.lowpass(count: 8 * stage1Factor + 1, cutoff: 1.2 * parameters.bandwidth / Self.inputRate)
        // Stufe 2: Kanalfilter ±0,5 × Bandbreite – was darüber liegt, faltet
        // beim Herausgreifen jeder vierten Abtastung in den Kanal.
        channelTaps = Self.lowpass(count: 65, cutoff: 0.55 * parameters.bandwidth / (Self.inputRate / Double(stage1Factor)))
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    /// Tiefpass (Hamming-gefensterter sinc), `cutoff` relativ zur Abtastrate.
    private static func lowpass(count: Int, cutoff: Double) -> [Float] {
        var taps = (0..<count).map { k -> Double in
            let x = Double(k - count / 2)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            return sinc * (0.54 - 0.46 * cos(2 * .pi * Double(k) / Double(count - 1)))
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return taps.map(Float.init)
    }

    func reset() {
        carry1Re = []; carry1Im = []; carry2Re = []; carry2Im = []
        mixerPhase = 0
        re = []; im = []
        position = 0
        state = .search
        runBin = -1
        runLength = 0
        crcErrors = 0
        headerErrors = 0
        detections = 0
    }

    // MARK: - Vorstufe

    /// Verarbeitet einen HackRF-Block (int8 I/Q) und liefert fertige Rahmen.
    func process(_ block: Data) -> [LoRaFrame] {
        let count = block.count / 2
        guard count > 0 else { return [] }
        // Mischen mit e^(−jπn/2): der Kanal bei +fs/4 rückt nach 0 Hz.
        var mixRe = carry1Re, mixIm = carry1Im
        mixRe.reserveCapacity(mixRe.count + count)
        mixIm.reserveCapacity(mixIm.count + count)
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<count {
                let i = Float(p[2 * k]) / 128, q = Float(p[2 * k + 1]) / 128
                switch (mixerPhase + k) & 3 {
                case 0: mixRe.append(i); mixIm.append(q)
                case 1: mixRe.append(q); mixIm.append(-i)
                case 2: mixRe.append(-i); mixIm.append(-q)
                default: mixRe.append(-q); mixIm.append(i)
                }
            }
        }
        mixerPhase = (mixerPhase + count) & 3
        let (s1Re, s1Im) = Self.filter(mixRe, mixIm, taps: stage1Taps, factor: stage1Factor,
                                       carryRe: &carry1Re, carryIm: &carry1Im)
        let (s2Re, s2Im) = Self.filter(carry2Re + s1Re, carry2Im + s1Im, taps: channelTaps, factor: 1,
                                       carryRe: &carry2Re, carryIm: &carry2Im)
        return process(re: s2Re, im: s2Im)
    }

    private static func filter(_ re: [Float], _ im: [Float], taps: [Float], factor: Int,
                               carryRe: inout [Float], carryIm: inout [Float]) -> ([Float], [Float]) {
        guard re.count >= taps.count else {
            carryRe = re
            carryIm = im
            return ([], [])
        }
        let outCount = (re.count - taps.count) / factor + 1
        var outRe = [Float](repeating: 0, count: outCount)
        var outIm = [Float](repeating: 0, count: outCount)
        vDSP_desamp(re, vDSP_Stride(factor), taps, &outRe, vDSP_Length(outCount), vDSP_Length(taps.count))
        vDSP_desamp(im, vDSP_Stride(factor), taps, &outIm, vDSP_Length(outCount), vDSP_Length(taps.count))
        carryRe = Array(re[(outCount * factor)...])
        carryIm = Array(im[(outCount * factor)...])
        return (outRe, outIm)
    }

    // MARK: - Symbolebene

    /// Verarbeitet Kanal-Abtastwerte mit 4 × Bandbreite (für Tests direkt nutzbar).
    func process(re newRe: [Float], im newIm: [Float]) -> [LoRaFrame] {
        re += newRe
        im += newIm
        var frames: [LoRaFrame] = []
        while true {
            let progressed: Bool
            switch state {
            case .search: progressed = searchStep()
            case .preamble, .sync2, .down: progressed = alignedStep()
            case .frame:
                let (done, frame) = frameStep()
                if let frame { frames.append(frame) }
                progressed = done
            }
            if !progressed { break }
        }
        trim()
        return frames
    }

    /// Verworfene Abtastwerte vorn abschneiden.
    private func trim() {
        let keep: Int
        switch state {
        case .search: keep = position
        case .preamble, .sync2, .down: keep = alignedStart
        case .frame: keep = frame.anchor
        }
        let drop = min(max(0, keep - os), re.count)
        guard drop > 4 * n * os else { return }
        re.removeFirst(drop)
        im.removeFirst(drop)
        position -= drop
        alignedStart -= drop
        frame.anchor -= drop
        frame.start -= Double(drop)
    }

    private struct Spectrum {
        var bin: Int
        var peak: Float
        var mean: Float
        var re: [Float]
        var im: [Float]
        var ratio: Float { peak / mean }
    }

    /// Ein Symbol ab `start` (jede `os`-te Abtastung) entfalten – mit dem
    /// konjugierten Up-Chirp oder (`down`) dem Up-Chirp –, optional um
    /// `tone` FFT-Zeilen zurückdrehen, dann FFT.
    private func spectrum(at start: Int, down: Bool = false, tone: Double = 0) -> Spectrum {
        var xRe = [Float](repeating: 0, count: n), xIm = [Float](repeating: 0, count: n)
        let sign: Float = down ? 1 : -1
        let os = os
        re.withUnsafeBufferPointer { r in
            im.withUnsafeBufferPointer { i in
                let step = -2 * Double.pi * tone / Double(n)
                let stepRe = cos(step), stepIm = sin(step)
                var rotRe = 1.0, rotIm = 0.0
                for k in 0..<n {
                    let a = r[start + k * os], b = i[start + k * os]
                    let cr = upRe[k], ci = sign * upIm[k]
                    var yr = a * cr - b * ci
                    var yi = a * ci + b * cr
                    if tone != 0 {
                        let fr = Float(rotRe), fi = Float(rotIm)
                        (yr, yi) = (yr * fr - yi * fi, yr * fi + yi * fr)
                        (rotRe, rotIm) = (rotRe * stepRe - rotIm * stepIm, rotRe * stepIm + rotIm * stepRe)
                    }
                    xRe[k] = yr
                    xIm[k] = yi
                }
            }
        }
        var outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(fft, xRe, xIm, &outRe, &outIm)
        var power = [Float](repeating: 0, count: n)
        outRe.withUnsafeMutableBufferPointer { r in
            outIm.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n))
            }
        }
        var peak: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(power, 1, &peak, &index, vDSP_Length(n))
        var total: Float = 0
        vDSP_sve(power, 1, &total, vDSP_Length(n))
        // Bei sauberem Signal kann der Rest rundungsbedingt ≤ 0 werden.
        let mean = max((total - peak) / Float(n - 1), peak * 1e-9, 1e-30)
        return Spectrum(bin: Int(index), peak: peak, mean: mean, re: outRe, im: outIm)
    }

    /// Kleinster Abstand zweier FFT-Zeilen (zyklisch).
    private func distance(_ a: Int, _ b: Int) -> Int {
        let d = ((a - b) % n + n) % n
        return min(d, n - d)
    }

    /// Vorzeichenbehaftete Zeile in (−N/2, N/2].
    private func signed(_ bin: Int) -> Int {
        let b = (bin % n + n) % n
        return b > n / 2 ? b - n : b
    }

    /// Lage eines Tons mit Feinlage (Jacobsen: für das Rechteckfenster
    /// nahezu erwartungstreu), vorzeichenbehaftet in (−N/2, N/2].
    private func fineTone(_ s: Spectrum) -> Double {
        let k = s.bin, left = (k + n - 1) % n, right = (k + 1) % n
        // δ = Re[(X[k−1] − X[k+1]) / (2X[k] − X[k−1] − X[k+1])]
        let numRe = Double(s.re[left] - s.re[right]), numIm = Double(s.im[left] - s.im[right])
        let denRe = Double(2 * s.re[k] - s.re[left] - s.re[right])
        let denIm = Double(2 * s.im[k] - s.im[left] - s.im[right])
        let norm = denRe * denRe + denIm * denIm
        let delta = norm > 0 ? max(-0.5, min(0.5, (numRe * denRe + numIm * denIm) / norm)) : 0
        return Double(signed(k)) + delta
    }

    // MARK: - Suche und Synchronisation

    private func searchStep() -> Bool {
        guard position + n * os <= re.count else { return false }
        let s = spectrum(at: position)
        noiseDB = 0.9 * noiseDB + 0.1 * 10 * log10(Double(s.mean) / Double(n))
        if s.ratio >= Self.detectThreshold {
            runLength = runLength > 0 && distance(s.bin, runBin) <= 1 ? runLength + 1 : 1
            runBin = s.bin
        } else {
            runLength = 0
        }
        position += n * os
        if runLength >= Self.preambleRun {
            // Ein Up-Chirp, dessen Fenster `d` Chips nach der Symbolgrenze
            // beginnt, erscheint bei Zeile d + cfo. cfo vorerst 0 annehmen
            // und auf die Grenze zurückgehen.
            alignedStart = position + (n - runBin) % n * os
            alignedCount = 0
            preamble = []
            runLength = 0
            state = .preamble
            detections += 1
        }
        return true
    }

    private func abortToSearch(at start: Int) {
        position = start
        runLength = 0
        state = .search
    }

    /// Ausgerichtete Fenster: Präambel, Sync-Wort, erster Down-Chirp.
    private func alignedStep() -> Bool {
        let start = alignedStart + alignedCount * n * os
        guard start + n * os <= re.count else { return false }
        let (sync1, sync2) = parameters.syncSymbols
        switch state {
        case .preamble:
            let s = spectrum(at: start)
            if distance(s.bin, 0) <= 1, s.ratio >= Self.detectThreshold {
                let bins = [n - 1, 0, 1]
                preamble.append(PreambleWindow(index: alignedCount, tone: fineTone(s), level: s.peak,
                                               re: bins.map { s.re[$0] }, im: bins.map { s.im[$0] }))
                alignedCount += 1
                if alignedCount > 70 { abortToSearch(at: start + n * os) }
            } else if distance(s.bin, sync1) <= 2, !preamble.isEmpty {
                alignedCount += 1
                state = .sync2
            } else {
                abortToSearch(at: start + n * os)
            }
        case .sync2:
            let s = spectrum(at: start)
            if distance(s.bin, sync2) <= 2 {
                alignedCount += 1
                state = .down
            } else {
                abortToSearch(at: start)
            }
        case .down:
            let s = spectrum(at: start, down: true)
            if s.ratio >= Self.detectThreshold {
                startFrame(downWindow: start, spectrum: s)
            } else {
                abortToSearch(at: start)
            }
        case .search, .frame:
            break
        }
        return true
    }

    /// Frequenz- und Zeitablage aus Präambel (Up) und erstem Down-Chirp.
    ///
    /// Im ausgerichteten Raster beginnt jedes Fenster `d` Chips nach der
    /// Symbolgrenze. Ein Up-Chirp erscheint dann als Ton bei d + cfo, ein
    /// Down-Chirp bei cfo − d. Die Phasendrehung von Fenster zu Fenster
    /// sieht dagegen nur die Frequenzablage (der Zeitversatz dreht nicht
    /// mit) – sie liefert den Bruchteil von cfo am genauesten.
    private func startFrame(downWindow: Int, spectrum s: Spectrum) {
        let anchorIndex = Double(alignedCount)
        let count = Double(preamble.count)
        let meanIndex = preamble.reduce(0.0) { $0 + Double($1.index) } / count
        let meanTone = preamble.reduce(0.0) { $0 + $1.tone } / count
        // Phasendrehung bei der Zeile, die dem Up-Ton am nächsten liegt.
        let column = max(-1, min(1, Int(meanTone.rounded()))) + 1
        var sumRe = 0.0, sumIm = 0.0
        for (a, b) in zip(preamble, preamble.dropFirst()) where b.index == a.index + 1 {
            let ar = Double(a.re[column]), ai = Double(a.im[column])
            let br = Double(b.re[column]), bi = Double(b.im[column])
            sumRe += br * ar + bi * ai
            sumIm += bi * ar - br * ai
        }
        let fraction = atan2(sumIm, sumRe) / (2 * .pi)
        let down = fineTone(s)
        // Die Taktablage verschiebt den Up-Ton von Fenster zu Fenster um N·e;
        // der Mittelwert gilt für die mittlere Fensterlage, nicht für den Anker.
        var drift = 0.0, cfo = 0.0, up = meanTone
        for _ in 0..<2 {
            up = meanTone + (anchorIndex - meanIndex) * Double(n) * drift
            let rough = (up + down) / 2
            cfo = sumRe == 0 && sumIm == 0 ? rough : fraction + (rough - fraction).rounded()
            drift = cfo * parameters.bandwidth / Double(n) / centerFrequency
        }
        let d = (up - down) / 2
        frame = FrameTiming()
        frame.anchor = downWindow
        frame.start = Double(downWindow) + (2.25 * Double(n) - d) * Double(os)
        frame.cfo = cfo
        frame.drift = drift
        let level = Double(preamble.reduce(Float(0)) { $0 + $1.level }) / count / Double(n * n)
        frame.levelDB = 10 * log10(max(level, 1e-20))
        state = .frame
    }

    // MARK: - Rahmen

    /// Fensteranfang und Restton (in FFT-Zeilen) des Nutzsymbols `k`: Das
    /// Fenster beginnt auf dem nächsten Viertel-Chip; der Rest (≤ ⅛ Chip)
    /// und die Frequenzablage werden als Ton herausgedreht.
    private func payloadWindow(_ k: Int) -> (start: Int, tone: Double) {
        let exact = frame.start + Double(k * n * os) * (1 - frame.drift)
        let start = Int(exact.rounded())
        return (start, (Double(start) - exact) / Double(os) + frame.cfo)
    }

    /// Liest Symbole, sobald genug Abtastwerte da sind. Liefert (Fortschritt, Rahmen).
    private func frameStep() -> (Bool, LoRaFrame?) {
        let sf = parameters.spreadingFactor
        let needed: Int
        if let header = frame.header {
            needed = LoRaCoding.symbolCount(length: header.length, codingRate: header.codingRate,
                                            hasCRC: header.hasCRC, sf: sf, lowDataRate: parameters.lowDataRate)
        } else {
            needed = 8
        }
        guard payloadWindow(needed - 1).start + n * os <= re.count else { return (false, nil) }

        var bins: [Int] = []
        for k in frame.symbolsRead..<needed {
            let (start, tone) = payloadWindow(k)
            let s = spectrum(at: start, tone: tone)
            bins.append(s.bin)
            frame.peakSum += Double(s.peak)
            frame.noiseSum += Double(s.mean)
        }
        frame.symbolsRead = needed

        guard let header = frame.header else {
            // Kopfblock: 8 Symbole, sf − 2 Bits, 4/8.
            let values = bins.map { LoRaCoding.valueForSymbol($0, sf: sf, reduced: true) }
            var nibbles: [UInt8] = []
            for word in LoRaCoding.deinterleave(values, cwLength: 8, rows: sf - 2) {
                let (nibble, corrected) = LoRaCoding.hammingDecode(word, codingRate: 4)
                nibbles.append(nibble)
                if corrected { frame.corrected += 1 }
            }
            guard let header = LoRaCoding.parseHeader(nibbles) else {
                headerErrors += 1
                abortToSearch(at: Int(frame.start.rounded()))
                return (true, nil)
            }
            frame.header = header
            frame.nibbles = Array(nibbles.dropFirst(5))
            return (true, nil)
        }

        // Nutzdatenblöcke.
        let reduced = parameters.lowDataRate
        let rows = reduced ? sf - 2 : sf
        let cwLength = 4 + header.codingRate
        var index = 0
        while index + cwLength <= bins.count {
            let values = bins[index..<(index + cwLength)].map { LoRaCoding.valueForSymbol($0, sf: sf, reduced: reduced) }
            for word in LoRaCoding.deinterleave(values, cwLength: cwLength, rows: rows) {
                let (nibble, corrected) = LoRaCoding.hammingDecode(word, codingRate: header.codingRate)
                frame.nibbles.append(nibble)
                if corrected { frame.corrected += 1 }
            }
            index += cwLength
        }
        let byteCount = header.length + (header.hasCRC ? 2 : 0)
        var bytes: [UInt8] = []
        var k = 0
        while k + 1 < frame.nibbles.count, bytes.count < byteCount {
            bytes.append(frame.nibbles[k] | frame.nibbles[k + 1] << 4)
            k += 2
        }
        let payload = LoRaCoding.whiten(Array(bytes.prefix(header.length)))
        var crcValid: Bool?
        if header.hasCRC, bytes.count >= byteCount {
            let received = UInt16(bytes[header.length]) | UInt16(bytes[header.length + 1]) << 8
            crcValid = received == LoRaCoding.payloadCRC(payload)
            if crcValid == false { crcErrors += 1 }
        }
        let symbols = Double(max(1, frame.symbolsRead))
        let peak = frame.peakSum / symbols, noise = frame.noiseSum / symbols
        let snr = max(peak - noise, 1e-20) / (Double(n) * max(noise, 1e-20))
        let result = LoRaFrame(payload: payload, codingRate: header.codingRate, crcValid: crcValid,
                               snrDB: 10 * log10(snr), levelDB: frame.levelDB,
                               frequencyOffsetHz: frame.cfo * parameters.bandwidth / Double(n),
                               correctedCodewords: frame.corrected, date: Date())
        abortToSearch(at: payloadWindow(needed).start)
        return (true, result)
    }
}
