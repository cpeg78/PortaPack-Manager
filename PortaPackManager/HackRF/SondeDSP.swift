import Accelerate
import Foundation

/// Harte Bitentscheidung mit Taktrückgewinnung: Nulldurchgänge ziehen die
/// Symbolgrenze nach, entschieden wird in Symbolmitte. Das Eingangssignal ist
/// schon über ≈ ein Symbol gemittelt (`SondeChannel`), die Entscheidung in der
/// Mitte entspricht also Integrieren über das Symbol.
///
/// Nachführung 0,1 je Nulldurchgang (bis 29.10.2026: 0,3). Mit 0,3 zog jeder
/// verrauschte Nulldurchgang den Takt so weit, dass er im Rauschen Bits
/// verlor oder doppelte – Simulation RS41 bei Eb/N0 10 dB: Bitfehler 23 %
/// statt 5 %. Einrasten dauert mit 0,1 etwa 20 Nulldurchgänge (≈ 40 Bit) –
/// die Sonden senden ohne Pause, das ist lange vor dem nächsten Rahmenkopf.
final class SondeSlicer {
    let samplesPerSymbol: Double
    private var phase = 0.0          // 0 = Symbolgrenze, 0,5 = Mitte
    private var last: Float = 0
    private let gain = 0.1

    init(samplesPerSymbol: Double) {
        self.samplesPerSymbol = samplesPerSymbol
    }

    func process(_ samples: [Float]) -> [UInt8] {
        var bits: [UInt8] = []
        bits.reserveCapacity(Int(Double(samples.count) / samplesPerSymbol) + 2)
        let step = 1 / samplesPerSymbol
        for v in samples {
            let previous = last
            last = v
            if (previous < 0) != (v < 0), previous != v {
                // Lage des Nulldurchgangs innerhalb dieses Schritts.
                let fraction = Double(previous / (previous - v))
                var error = phase + fraction * step
                error -= error.rounded()
                phase -= gain * error
                if phase < 0 { phase += 1 }
            }
            let before = phase
            phase += step
            if before < 0.5, phase >= 0.5 { bits.append(v > 0 ? 1 : 0) }
            if phase >= 1 { phase -= 1 }
        }
        return bits
    }
}

/// Ein Sondenkanal: aus dem Breitbandsignal herausmischen, auf 50 kS/s
/// dezimieren, FM-demodulieren und parallel RS41 und DFM dekodieren.
///
/// Kette (seit 29.10.2026): ÷25 (Tiefpass 25 kHz), ÷8 auf 50 kS/s (Tiefpass
/// 12 kHz, nur gegen Faltung), Feinmischer mit Frequenznachlauf (AFC),
/// schmaler Kanalfilter 6 kHz bei 50 kS/s, Diskriminator, Mittel über ein
/// Symbol (9 Werte), Bitentscheidung. Vorher lag der einzige Kanalfilter bei
/// 8 kHz mit 79 Abgriffen auf 400 kS/s – gesperrt erst ab ≈ 20 kHz – und
/// gemittelt wurde über ein halbes Symbol. Simulation RS41 (GFSK BT 0,5,
/// ±2,4 kHz), Bitfehler bei Eb/N0 10/12 dB: vorher 23 %/12 %, nachher
/// 2 %/0,07 % (Ablage 0,5 kHz); bei 4 kHz Ablage vorher 45 %/45 %, nachher
/// 3 %/0,05 %. Ohne AFC kostete der schmale Filter bei 4 kHz Ablage alles.
final class SondeChannel {
    static let channelRate = 50_000.0
    /// Grenzfrequenz des schmalen Kanalfilters. RS41 (4800 Bd, ±2,4 kHz) und
    /// DFM (2500 Bd Manchester = 5000 Halbbit/s) passen beide hinein.
    static let channelCutoff = 6_000.0
    /// Weiter darf der Frequenznachlauf nicht laufen; dahinter beginnt der
    /// nächste Suchkanal (Raster 5 kHz) und der Faltungsschutz der 2. Stufe.
    static let maxAFC = 6_000.0
    /// Streuung des Diskriminators (rad²), unter der ein Signal im Kanal gilt.
    static let afcVarianceLimit: Float = 0.33

    let offset: Double                 // Hz relativ zur Mittenfrequenz
    private let oscRe: [Float]
    private let oscIm: [Float]
    private var oscIndex = 0

    private let stage1: [Float]
    private let stage2: [Float]
    private let channelFilter: [Float]
    private let factor1: Int
    private let factor2 = 8
    private var h1Re: [Float] = [], h1Im: [Float] = []
    private var h2Re: [Float] = [], h2Im: [Float] = []
    private var h3Re: [Float] = [], h3Im: [Float] = []
    private var lastRe: Float = 1, lastIm: Float = 0
    private var dc: Float = 0
    private var smooth: [Float] = []
    /// Länge des gleitenden Mittels: ≈ ein Symbol (RS41 10,4, DFM 10 Werte).
    private static let smoothLength = 9
    /// Frequenznachlauf in Hz (Träger liegt bei `offset + afcHz`).
    private(set) var afcHz = 0.0
    private var afcPhaseRe: Float = 1, afcPhaseIm: Float = 0

    private let rs41Slicer = SondeSlicer(samplesPerSymbol: channelRate / RS41.baudRate)
    private let dfmSlicer = SondeSlicer(samplesPerSymbol: channelRate / DFMDecoder.chipRate)
    private let rs41 = RS41Decoder()
    private let dfm = DFMDecoder()

    /// Leistung im Kanal (dBFS), zuletzt.
    private(set) var levelDB: Float = -100

    /// `inputRate` muss ein Vielfaches von 400 kHz sein. Der Versatz wird auf
    /// 1 kHz gerundet, damit die Oszillatortabelle periodisch bleibt.
    init(offset: Double, inputRate: Double) {
        let rounded = (offset / 1000).rounded() * 1000
        self.offset = rounded
        factor1 = Int(inputRate / 400_000)
        let period = Int(inputRate / 1000)
        oscRe = (0..<period).map { Float(cos(-2 * Double.pi * rounded * Double($0) / inputRate)) }
        oscIm = (0..<period).map { Float(sin(-2 * Double.pi * rounded * Double($0) / inputRate)) }
        stage1 = RadioDemodulator.lowpass(taps: 159, cutoff: 25_000, rate: inputRate)
        stage2 = RadioDemodulator.lowpass(taps: 79, cutoff: 12_000, rate: 400_000)
        channelFilter = RadioDemodulator.lowpass(taps: 63, cutoff: Self.channelCutoff, rate: Self.channelRate)
    }

    /// Verarbeitet einen Block (Float-IQ, ohne Gleichanteil).
    func process(re: [Float], im: [Float]) -> [SondeReport] {
        let filtered = demodulate(re: re, im: im)
        guard !filtered.isEmpty else { return [] }
        var reports = rs41.process(bits: rs41Slicer.process(filtered))
        reports += dfm.process(chips: dfmSlicer.process(filtered))
        return reports
    }

    /// Bis vor die Bitentscheidung: Frequenzverlauf (rad je Abtastwert bei
    /// 50 kS/s, ohne Gleichanteil), über ein Symbol gemittelt.
    func demodulate(re: [Float], im: [Float]) -> [Float] {
        let n = re.count
        var mixedRe = [Float](repeating: 0, count: n)
        var mixedIm = [Float](repeating: 0, count: n)
        let period = oscRe.count
        var k = oscIndex
        oscRe.withUnsafeBufferPointer { cr in
            oscIm.withUnsafeBufferPointer { ci in
                for i in 0..<n {
                    let c = cr[k], s = ci[k]
                    mixedRe[i] = re[i] * c - im[i] * s
                    mixedIm[i] = re[i] * s + im[i] * c
                    k += 1
                    if k == period { k = 0 }
                }
            }
        }
        oscIndex = k
        let (aRe, aIm) = RadioDemodulator.decimateComplex(mixedRe, mixedIm, history: &h1Re, &h1Im, filter: stage1, factor: factor1)
        var (bRe, bIm) = RadioDemodulator.decimateComplex(aRe, aIm, history: &h2Re, &h2Im, filter: stage2, factor: factor2)
        guard !bRe.isEmpty else { return [] }

        // Feinmischer: Träger um den Frequenznachlauf zurück auf 0 Hz.
        let step = -2 * Double.pi * afcHz / Self.channelRate
        let stepRe = Float(cos(step)), stepIm = Float(sin(step))
        var cr = afcPhaseRe, ci = afcPhaseIm
        for i in bRe.indices {
            let r = bRe[i], m = bIm[i]
            bRe[i] = r * cr - m * ci
            bIm[i] = r * ci + m * cr
            let nr = cr * stepRe - ci * stepIm
            ci = cr * stepIm + ci * stepRe
            cr = nr
        }
        let norm = 1 / (cr * cr + ci * ci).squareRoot()
        afcPhaseRe = cr * norm; afcPhaseIm = ci * norm

        let (cRe, cIm) = RadioDemodulator.decimateComplex(bRe, bIm, history: &h3Re, &h3Im, filter: channelFilter, factor: 1)
        guard !cRe.isEmpty else { return [] }

        var power: Float = 0, q: Float = 0
        vDSP_measqv(cRe, 1, &power, vDSP_Length(cRe.count))
        vDSP_measqv(cIm, 1, &q, vDSP_Length(cIm.count))
        levelDB = 10 * log10(max(power + q, 1e-12))

        // FM-Diskriminator, Gleichanteil (Frequenzablage) laufend abziehen.
        var fm = [Float](repeating: 0, count: cRe.count)
        var pr = lastRe, pi = lastIm
        var sum: Float = 0, squares: Float = 0
        for i in fm.indices {
            let r = cRe[i], m = cIm[i]
            let v = atan2f(m * pr - r * pi, r * pr + m * pi)
            pr = r; pi = m
            sum += v
            squares += v * v
            dc += 0.002 * (v - dc)
            fm[i] = v - dc
        }
        lastRe = pr; lastIm = pi
        // Frequenznachlauf: die halbe mittlere Restablage je Block nachstellen
        // (Daten sind verwürfelt bzw. Manchester – im Mittel ohne Gleichanteil).
        // Nur mit Signal im Kanal: Rauschen allein hat hinter dem 6-kHz-Filter
        // eine Streuung von ≈ 0,4 rad² (gemessen 0,37–0,50), eine Sonde schon bei
        // Eb/N0 4 dB unter 0,29. Ohne Signal läuft der Nachlauf langsam auf 0
        // zurück, statt im Rauschen bis an den Anschlag zu wandern.
        let mean = sum / Float(fm.count)
        let variance = squares / Float(fm.count) - mean * mean
        if variance < Self.afcVarianceLimit {
            let residualHz = Double(mean) * Self.channelRate / (2 * .pi)
            afcHz = max(-Self.maxAFC, min(Self.maxAFC, afcHz + 0.5 * residualHz))
        } else {
            afcHz *= 0.9
        }

        // Gleitendes Mittel über ≈ ein Symbol gegen Rauschen.
        let length = Self.smoothLength
        let input = smooth + fm
        var filtered = [Float](repeating: 0, count: fm.count)
        for i in fm.indices {
            var total: Float = 0
            for j in 0..<length {
                let index = i + smooth.count - j
                if index >= 0 { total += input[index] }
            }
            filtered[i] = total / Float(length)
        }
        smooth = Array(input.suffix(length - 1))
        return filtered
    }
}

/// RS41-Rahmen aus harten Bits: Kopfsuche (beide Polaritäten, bis zu 4
/// Bitfehler), Bytes LSB zuerst, Entwürfeln, Reed-Solomon, Auswertung.
final class RS41Decoder {
    private static let headerBits: [UInt8] = RS41.rawHeader.flatMap { byte in (0..<8).map { (byte >> $0) & 1 } }
    private var window: UInt64 = 0
    private var filled = 0
    private var collecting: [UInt8]?
    private var currentByte: UInt8 = 0
    private var bitCount = 0
    private var inverted = false
    private var calibration: [String: RS41.Calibration] = [:]
    private static let headerWord: UInt64 = headerBits.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64(63 - $1.offset) }

    /// Rahmen mit erfolgreicher Reed-Solomon-Prüfung bzw. -Korrektur.
    private(set) var framesCorrected = 0

    func process(bits: [UInt8]) -> [SondeReport] {
        var reports: [SondeReport] = []
        for raw in bits {
            if collecting != nil {
                let bit = inverted ? raw ^ 1 : raw
                currentByte |= bit << UInt8(bitCount)
                bitCount += 1
                if bitCount == 8 {
                    collecting!.append(currentByte)
                    currentByte = 0
                    bitCount = 0
                    if let report = frameProgress() { reports.append(report) }
                }
                continue
            }
            window = window << 1 | UInt64(raw)
            filled = min(filled + 1, 64)
            guard filled == 64 else { continue }
            let errors = (window ^ Self.headerWord).nonzeroBitCount
            if errors <= 4 || errors >= 60 {
                inverted = errors >= 60
                collecting = RS41.rawHeader
                currentByte = 0
                bitCount = 0
                filled = 0
            }
        }
        return reports
    }

    /// Wertet aus, sobald genug Bytes für die erkannte Rahmenlänge da sind.
    private func frameProgress() -> SondeReport? {
        guard let bytes = collecting else { return nil }
        if bytes.count == RS41.standardLength {
            var probe = bytes
            RS41.applyMask(&probe)
            if RS41.isExtended(probe) { return nil }   // weiter sammeln
        } else if bytes.count < RS41.extendedLength {
            return nil
        }
        collecting = nil
        var frame = bytes
        RS41.applyMask(&frame)
        // Reed-Solomon rechnet immer mit voller Länge (Rest = 0).
        let length = frame.count
        var padded = frame + [UInt8](repeating: 0, count: RS41.extendedLength - length)
        if RS41.correct(&padded) != nil {
            framesCorrected += 1
            frame = Array(padded[0..<length])
        }
        return RS41.parse(frame, calibration: &calibration)
    }
}

/// Empfang des ganzen Sondenbands: 10 MS/s um 403 MHz (≈ 399,5–406,5 MHz),
/// aktive Träger per FFT finden, je Träger einen Kanal dekodieren.
final class SondeReceiver: @unchecked Sendable {
    static let sampleRate: UInt32 = 10_000_000
    static let centerFrequency: UInt64 = 403_000_000
    static let maxChannels = 4
    /// Nutzbare Breite (Basisbandfilter 7 MHz).
    static let usableHalfWidth = 3_400_000.0

    struct Channel: Sendable, Identifiable, Equatable {
        var frequency: Double
        var levelDB: Float
        var pinned: Bool
        var lastDecoded: Date?
        var id: Double { frequency }
    }

    private let lock = NSLock()
    private let analyzer = SpectrumAnalyzer(fftSize: 8192)
    /// Zeiten (`active`, `decoded`, `since`) in Sekunden der Abtastuhr `clock` –
    /// so verhält sich die Wiedergabe einer Aufnahme wie der Live-Empfang.
    private var channels: [Double: (channel: SondeChannel, pinned: Bool, active: Double, decoded: Double?, lastDecoded: Date?, since: Double)] = [:]
    /// Verdrängte Träger: erst ab dieser Abtastzeit wieder probieren.
    private var cooldown: [Double: Double] = [:]
    private var clock = 0.0
    /// So lange darf ein Kanal ohne Dekodierung einen Platz halten, wenn ein
    /// anderer Träger wartet. Live 26.10.2026: eine HackRF-Störlinie (400,000)
    /// und ein breiter Fremdträger hielten zwei der vier Plätze dauerhaft.
    static let trialSeconds = 20.0
    static let cooldownSeconds = 60.0
    /// Dauerstörer (Hz, absolut), die die Suche nie belegen sollen: unterhalb
    /// des Sondenbands und die Liste aus den Einstellungen (`SondeBlockList`,
    /// ab Werk leer). Feste Kanäle (`pin`) gelten trotzdem.
    static func isBlocked(_ frequency: Double) -> Bool {
        SondeBlockList.shared.contains(frequency)
    }
    private var pending: [SondeReport] = []
    private var blocks = 0
    /// Schwelle über dem Rauschboden in dB.
    var threshold: Float = 8

    func reset() {
        lock.withLock {
            channels.removeAll()
            cooldown.removeAll()
            clock = 0
            pending.removeAll()
            blocks = 0
        }
        _ = analyzer.takeSpectrum()
    }

    /// Hält einen Kanal fest (manuelle Frequenz in Hz), auch ohne erkannten Träger.
    func pin(_ frequency: Double) {
        let offset = frequency - Double(Self.centerFrequency)
        guard abs(offset) < Self.usableHalfWidth else { return }
        lock.withLock {
            // Ein schon erkannter Kanal auf demselben Träger wird übernommen.
            let key = channels.keys.first { abs($0 - offset) <= 5000 } ?? (offset / 1000).rounded() * 1000
            if var entry = channels[key] {
                entry.pinned = true
                channels[key] = entry
            } else {
                channels[key] = (SondeChannel(offset: key, inputRate: Double(Self.sampleRate)), true, clock, nil, nil, clock)
            }
        }
    }

    func unpin(_ frequency: Double) {
        let offset = frequency - Double(Self.centerFrequency)
        lock.withLock {
            let key = channels.keys.first { abs($0 - offset) <= 5000 } ?? (offset / 1000).rounded() * 1000
            _ = channels.removeValue(forKey: key)
        }
    }

    var activeChannels: [Channel] {
        lock.withLock {
            channels.map { key, entry in
                Channel(frequency: Double(Self.centerFrequency) + key, levelDB: entry.channel.levelDB,
                        pinned: entry.pinned, lastDecoded: entry.lastDecoded)
            }
            .sorted { $0.frequency < $1.frequency }
        }
    }

    func takeReports() -> [SondeReport] {
        lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
    }

    /// Verarbeitet einen IQ-Block (int8, verschränkt) auf dem Empfangsthread.
    func process(_ iq: Data) {
        analyzer.process(iq, maxFFTs: 2)
        let count = iq.count / 2
        guard count > 0 else { return }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    vDSP_vflt8(p.baseAddress!, 2, r.baseAddress!, 1, vDSP_Length(count))
                    vDSP_vflt8(p.baseAddress! + 1, 2, i.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
        // Skalieren und Gleichanteil (DC-Spitze des HackRF) entfernen.
        var meanRe: Float = 0, meanIm: Float = 0
        vDSP_meanv(re, 1, &meanRe, vDSP_Length(count))
        vDSP_meanv(im, 1, &meanIm, vDSP_Length(count))
        var shiftRe = -meanRe, shiftIm = -meanIm, scale: Float = 1 / 128
        vDSP_vsadd(re, 1, &shiftRe, &re, 1, vDSP_Length(count))
        vDSP_vsadd(im, 1, &shiftIm, &im, 1, vDSP_Length(count))
        vDSP_vsmul(re, 1, &scale, &re, 1, vDSP_Length(count))
        vDSP_vsmul(im, 1, &scale, &im, 1, vDSP_Length(count))

        let active = lock.withLock { channels }
        var produced: [SondeReport] = []
        var decoded: [Double] = []
        for (key, entry) in active {
            var reports = entry.channel.process(re: re, im: im)
            for i in reports.indices { reports[i].frequency = Double(Self.centerFrequency) + key }
            if !reports.isEmpty { decoded.append(key) }
            produced += reports
        }

        let detect = lock.withLock {
            blocks += 1
            return blocks % 40 == 0       // etwa alle 0,5 s
        }
        let spectrum = detect ? analyzer.takeSpectrum() : nil
        lock.withLock {
            pending += produced
            clock += Double(count) / Double(Self.sampleRate)
            let now = clock, date = Date()
            for key in decoded { channels[key]?.decoded = now; channels[key]?.lastDecoded = date; channels[key]?.active = now }
            guard let spectrum else { return }
            cooldown = cooldown.filter { $0.value > now }
            for offset in Self.carriers(in: spectrum, sampleRate: Double(Self.sampleRate), threshold: threshold) {
                if Self.isBlocked(Double(Self.centerFrequency) + offset) { continue }
                if let key = channels.keys.first(where: { abs($0 - offset) <= 5000 }) {
                    channels[key]?.active = now
                    continue
                }
                guard !cooldown.keys.contains(where: { abs($0 - offset) <= 5000 }) else { continue }
                if channels.count >= Self.maxChannels {
                    // Den am längsten erfolglosen Kanal für den neuen Träger räumen.
                    let idle = channels.filter { !$0.value.pinned
                        && now - ($0.value.decoded ?? $0.value.since) > Self.trialSeconds }
                    guard let victim = idle.min(by: { ($0.value.decoded ?? $0.value.since) < ($1.value.decoded ?? $1.value.since) })?.key
                    else { continue }
                    channels.removeValue(forKey: victim)
                    cooldown[victim] = now + Self.cooldownSeconds
                }
                let key = (offset / 1000).rounded() * 1000
                channels[key] = (SondeChannel(offset: key, inputRate: Double(Self.sampleRate)), false, now, nil, nil, now)
            }
            // Kanäle ohne Träger und ohne Dekodierung seit 30 s wieder freigeben.
            for (key, entry) in channels where !entry.pinned
                && now - entry.active > 30
                && now - (entry.decoded ?? -.infinity) > 30 {
                channels.removeValue(forKey: key)
            }
        }
    }

    /// Findet Träger im (FFT-verschobenen) Spektrum in dB: zusammenhängende
    /// Bereiche über Rauschboden + `threshold`, 3–20 Bins breit (≈ 4–24 kHz).
    /// Schmale Linien (HackRF-Störlinien, Träger ohne Modulation) fallen raus.
    ///
    /// Bandmitte (403,000 MHz): der `SpectrumAnalyzer` zieht den Gleichanteil
    /// je Block ab, die DC-Spitze steht also nicht im Spektrum. Bis 29.10.2026
    /// wurde trotzdem alles in ±1,5 kHz um die Mitte verworfen – eine Sonde auf
    /// genau 403,000 MHz ging nur über „Festhalten“. Jetzt zählt ein Träger an
    /// der Mitte, wenn er mindestens 5 Bins (≈ 6 kHz) breit ist; Sonden sind
    /// 7–9 Bins breit, ein Rest der DC-Spitze nur 1–3.
    static func carriers(in spectrum: [Float], sampleRate: Double, threshold: Float) -> [Double] {
        let n = spectrum.count
        let floor = spectrum.sorted()[n / 2]
        let binWidth = sampleRate / Double(n)
        var result: [Double] = []
        var start: Int?
        var gap = 0
        func finish(_ s: Int, _ e: Int) {
            let width = e - s + 1
            guard (3...20).contains(width) else { return }
            var weight = 0.0, sum = 0.0
            for k in s...e {
                let p = pow(10, Double(spectrum[k] - floor) / 10)
                weight += p
                sum += p * Double(k)
            }
            let offset = (sum / weight - Double(n / 2)) * binWidth
            // Ein schmaler Rest der Gleichspannungsspitze in Bandmitte ist kein Sender.
            if abs(offset) < 3000, width < 5 { return }
            if abs(offset) < usableHalfWidth { result.append(offset) }
        }
        var lastAbove = 0
        for k in 0..<n {
            if spectrum[k] > floor + threshold {
                if start == nil { start = k }
                lastAbove = k
                gap = 0
            } else if let s = start {
                gap += 1
                if gap > 1 { finish(s, lastAbove); start = nil }
            }
        }
        if let s = start { finish(s, lastAbove) }
        return result
    }
}
