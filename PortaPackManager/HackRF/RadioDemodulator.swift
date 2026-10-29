import Accelerate
import Foundation

/// Demodulationsarten. Der Rohwert ist gespeichert (Favoriten) und bleibt
/// unverändert – neue Fälle bekommen neue Rohwerte, alte nie umbenennen.
enum RadioMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case wfm = "UKW (WFM)"
    case nfm = "Sprechfunk (NFM)"
    case am = "AM"
    /// Einseitenband, oberes Seitenband (Amateurfunk über 10 MHz).
    case usb = "USB"
    /// Einseitenband, unteres Seitenband (Amateurfunk unter 10 MHz).
    case lsb = "LSB"
    /// Morsetelegrafie mit Überlagerungston (BFO).
    case cw = "CW"

    var id: String { rawValue }

    /// Anzeigename (der Rohwert ist gespeichert und bleibt deutsch).
    var title: String {
        switch self {
        case .wfm: String(localized: "UKW (WFM)")
        case .nfm: String(localized: "Sprechfunk (NFM)")
        case .am: "AM"
        case .usb: String(localized: "SSB oben (USB)")
        case .lsb: String(localized: "SSB unten (LSB)")
        case .cw: String(localized: "Morsen (CW)")
        }
    }

    /// Kurzform für Listen und Knöpfe.
    var shortTitle: String {
        switch self {
        case .wfm: String(localized: "UKW")
        case .nfm: "NFM"
        case .am: "AM"
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        }
    }

    /// Sinnvolle Abstimmschritte in kHz.
    var defaultStepKHz: Double {
        switch self {
        case .wfm: 100
        case .nfm: 12.5
        case .am: 5
        case .usb, .lsb: 0.1
        case .cw: 0.01
        }
    }

    /// Auswahl für „Schritt“ (kHz). SSB/CW fein (10 Hz … 1 kHz), sonst Kanalraster.
    var stepOptionsKHz: [Double] {
        switch self {
        case .usb, .lsb, .cw: [0.01, 0.1, 0.5, 1]
        default: [5, 8.33, 9, 10, 12.5, 25, 50, 100, 200]
        }
    }

    /// Einseitenband-Empfang (Produktdetektor mit AGC statt Diskriminator/Hüllkurve).
    var isSingleSideband: Bool { self == .usb || self == .lsb || self == .cw }

    /// Rauschsperre gibt es nur für AM/NFM (SSB/CW hört man ohne).
    var usesSquelch: Bool { self == .nfm || self == .am }

    /// Wählbare Filterbandbreiten in Hz (leer = fest, UKW). Bei NFM ist es das
    /// Kanalraster des Funkdienstes, sonst die Breite des Empfangsfilters.
    var bandwidthOptionsHz: [Double] {
        switch self {
        case .wfm: []
        case .nfm: [6_250, 12_500, 25_000]
        case .am: [6_000, 9_000, 10_000]
        case .usb, .lsb: [1_800, 2_400, 2_700, 3_000]
        case .cw: [250, 500, 1_000]
        }
    }

    /// Vorgabe: NFM und AM wie vor der Auswahl (16 bzw. 10 kHz breit), SSB 2,4 kHz, CW 500 Hz.
    var defaultBandwidthHz: Double? {
        switch self {
        case .wfm: nil
        case .nfm: 25_000
        case .am: 10_000
        case .usb, .lsb: 2_400
        case .cw: 500
        }
    }

    /// Bandbreite, wenn sie zur Betriebsart passt, sonst die Vorgabe (UKW: `nil`).
    func validBandwidth(_ hz: Double?) -> Double? {
        if let hz, bandwidthOptionsHz.contains(hz) { return hz }
        return defaultBandwidthHz
    }

    /// Durchlass des Einseitenband-Filters relativ zur Trägerfrequenz (Hz).
    /// SSB: 300 Hz über bzw. unter dem (unterdrückten) Träger beginnend; CW:
    /// symmetrisch um den Träger, hörbar wird er erst durch den BFO-Ton.
    func passband(bandwidthHz: Double) -> ClosedRange<Double> {
        switch self {
        case .lsb: -(RadioDemodulator.ssbLowCutHz + bandwidthHz)...(-RadioDemodulator.ssbLowCutHz)
        case .cw: (-bandwidthHz / 2)...(bandwidthHz / 2)
        default: RadioDemodulator.ssbLowCutHz...(RadioDemodulator.ssbLowCutHz + bandwidthHz)
        }
    }
}

/// Lesbare Bandbreite bzw. Schrittweite: „250 Hz“, „2,4 kHz“, „12,5 kHz“.
enum RadioUnits {
    static func hertz(_ hz: Double) -> String {
        hz < 1_000 ? "\(Int(hz.rounded())) Hz"
            : "\((hz / 1_000).formatted(.number.precision(.fractionLength(0...2)))) kHz"
    }
}

/// Demoduliert IQ-Blöcke (int8, 2,4 MS/s) zu Audio (Float, 48 kHz, stereo).
///
/// Kette: Frequenzversatz herausmischen → komplexer Tiefpass, ÷10 auf
/// 240 kHz → je Betriebsart:
/// - WFM: FM-Diskriminator bei 240 kHz liefert das MPX-Signal. Daraus:
///   Pilot-PLL auf 19 kHz, L−R aus dem 38-kHz-Hilfsträger (Stereo),
///   RDS vom 57-kHz-Hilfsträger, Trägerablage aus dem Mittelwert;
///   Deemphasis 50 µs, Tiefpass 15 kHz, ÷5
/// - NFM/AM: Tiefpass 16 kHz, ÷5 auf 48 kHz, dann der eigentliche Kanalfilter
///   bei 48 kHz (127 Abgriffe: NFM 8 kHz, AM 5 kHz), Diskriminator bzw.
///   Hüllkurve, Gleichanteil entfernen. Bis 29.10.2026 saß der Kanalfilter
///   (95 Abgriffe) bei 240 kHz – zu wenig Steilheit: Nachbarkanal NFM ±12,5 kHz
///   nur −32 dB, AM ±8,33 kHz nur −22 dB gedämpft. Jetzt ≥ 90 dB.
///   Breite wählbar (`bandwidthHz`, siehe `RadioMode.bandwidthOptionsHz`).
/// - USB/LSB/CW: ÷5 auf 48 kHz, ÷4 auf 12 kHz, dort ein komplexer, einseitiger
///   Bandpass (Kaiser, 511 Abgriffe, Übergang ≈ 100 Hz) – das falsche
///   Seitenband liegt im Sperrbereich. AGC auf der Hüllkurve (sofort an,
///   0,3 s halten, dann langsam ab), bei CW Verschiebung um den BFO-Ton,
///   Realteil = Ton, ×4 zurück auf 48 kHz.
///
/// Der HackRF wird um `offset` unter die Wunschfrequenz gelegt, damit die
/// Gleichspannungsspitze in der Bandmitte nicht im Nutzsignal liegt.
final class RadioDemodulator: @unchecked Sendable {
    static let inputRate = 2_400_000.0
    static let offset = 240_000.0            // = inputRate / 10 → Oszillator mit Periode 10
    static let audioRate = 48_000.0

    /// Untere Kante des SSB-Durchlasses über dem unterdrückten Träger.
    static let ssbLowCutHz = 300.0
    /// Abtastrate des Einseitenband-Zweigs.
    static let narrowRate = 12_000.0

    var mode: RadioMode = .wfm
    /// Filterbandbreite in Hz; passt sie nicht zur Betriebsart, gilt deren Vorgabe.
    var bandwidthHz: Double = 0
    /// CW: Tonhöhe, mit der ein genau abgestimmter Träger zu hören ist.
    var cwPitchHz: Double = 700
    /// Restablage zwischen Wunschfrequenz und HackRF-Abstimmung (Hz), die
    /// digital ausgeglichen wird – SSB/CW stimmen den HackRF nur im 10-kHz-Raster
    /// um (`RadioTuning`), Feinabstimmung in 10-Hz-Schritten geschieht hier.
    var fineOffsetHz: Double = 0
    var volume: Float = 0.5
    /// Stereo erlaubt; ohne Pilotton bleibt es ohnehin mono.
    var stereoEnabled = true

    /// RDS-Auswertung (nur WFM).
    let rds = RDSDemodulator()
    /// Pilotton erkannt und PLL eingerastet.
    private(set) var pilotLocked = false
    /// Mittlere Ablage des Trägers in Hz seit `resetCarrierOffset()`.
    var carrierOffsetHz: Double { offsetCount == 0 ? 0 : offsetSum / Double(offsetCount) * 240_000 / (2 * .pi) }
    /// Messdauer der Trägerablage in Sekunden.
    var carrierOffsetSeconds: Double { Double(offsetCount) / 240_000 }

    /// Kanalleistung in dBFS nach dem ersten Filter (für Anzeige und Suchlauf).
    private(set) var signalDB: Float = -100

    /// Rauschsperre für AM/NFM: Ton nur, wenn die Leistung im Sprachkanal so
    /// viele dB über dem gelernten Rauschboden liegt; 0 = aus. Ohne Sperre
    /// hört man im Flugfunk zwischen den Sprüchen nur Rauschen.
    var squelchDB: Float = 0
    private(set) var squelchOpen = true
    /// Leistung im Sprachkanal und gelernter Rauschboden (dBFS).
    private(set) var channelDB: Float = -100
    private(set) var channelFloorDB: Float = .nan
    private var squelchHold = 0.0
    private var squelchGain: Float = 1

    private let stage1: [Float]
    /// 240 → 48 kHz vor dem Kanalfilter (NFM/AM).
    private let narrowStage: [Float]
    private let wfmAudio: [Float]
    /// Kanalfilter AM/NFM bei 48 kHz für die eingestellte Bandbreite.
    private var narrowChannelFilter: [Float] = []
    /// NFM: Ton-Verstärkung nach dem Diskriminator (schmaler Hub → mehr).
    private var nfmAudioGain: Float = 2
    /// Einseitenband: 48 → 12 kHz und der komplexe Seitenbandfilter.
    private let ssbDecimator: FT8Decimator
    private var sidebandFilter: FT8Decimator?
    /// 12 → 48 kHz (Nullen einfügen, Tiefpass, ×4).
    private let upsampleFilter: [Float]
    private var histUp: [Float] = []
    /// Für welche Betriebsart/Bandbreite die Filter gebaut sind.
    private var builtFilters: String = ""
    private var agcPeak: Float = 0
    private var agcHold = 0
    private var bfoPhase = 0.0
    private var finePhase = 0.0
    private let oscillatorRe: [Float]
    private let oscillatorIm: [Float]
    private var phaseIndex = 0

    private var histRe: [Float] = []
    private var histIm: [Float] = []
    private var hist2Re: [Float] = []
    private var hist2Im: [Float] = []
    private var hist3Re: [Float] = []
    private var hist3Im: [Float] = []
    private var histAudio: [Float] = []
    private var lastRe: Float = 1, lastIm: Float = 0
    private var deemphasis: Float = 0
    private var deemphasisSide: Float = 0
    private var histSide: [Float] = []
    private var dcState: Float = 0

    // Pilot-PLL (19 kHz): θ folgt dem Pilotton sin(ωt).
    private var pilotPhase: Double = 0
    private var pilotFrequency: Double = 2 * .pi * 19_000 / 240_000
    private var pilotAmplitude: Double = 0
    private var pilotQuadrature: Double = 0

    private var offsetSum = 0.0
    private var offsetCount = 0

    init() {
        stage1 = Self.lowpass(taps: 95, cutoff: 100_000, rate: Self.inputRate)
        // Steil genug, dass Pilot (19 kHz) und 38-kHz-Mischprodukte nicht durchkommen.
        wfmAudio = Self.lowpass(taps: 159, cutoff: 15_000, rate: 240_000)
        // Faltungsschutz für ÷5: ab 38 kHz ≥ 90 dB, im Nachbarbereich 24–38 kHz ≥ 78 dB.
        narrowStage = Self.lowpass(taps: 95, cutoff: 16_000, rate: 240_000)
        // Kanalfilter bei 48 kHz: NFM eben bis 7,5 kHz, −6 dB bei 8, ≥ 90 dB ab 12,5 kHz;
        // AM eben bis 4,5 kHz, −6 dB bei 5, −67 dB bei 6 und ≥ 90 dB ab 8,33 kHz.
        // 48 → 12 kHz: eben bis ≈ 4 kHz, ≥ 74 dB ab 6,1 kHz – was in den
        // Durchlass (±3,3 kHz) fällt, kommt von ≥ 8,7 kHz.
        ssbDecimator = FT8Decimator(factor: 4, tapsRe: Self.lowpass(taps: 127, cutoff: 5_000, rate: Self.audioRate))
        upsampleFilter = Self.lowpass(taps: 127, cutoff: 4_500, rate: Self.audioRate).map { $0 * 4 }
        oscillatorRe = (0..<10).map { Float(cos(-2 * Double.pi * Double($0) / 10)) }
        oscillatorIm = (0..<10).map { Float(sin(-2 * Double.pi * Double($0) / 10)) }
    }

    func reset() {
        histRe = []; histIm = []; hist2Re = []; hist2Im = []; hist3Re = []; hist3Im = []; histAudio = []; histSide = []
        lastRe = 1; lastIm = 0; deemphasis = 0; deemphasisSide = 0; dcState = 0
        channelFloorDB = .nan; squelchHold = 0; squelchGain = 1; squelchOpen = true
        ssbDecimator.reset(); sidebandFilter?.reset(); histUp = []
        agcPeak = 0; agcHold = 0; bfoPhase = 0
        pilotPhase = 0; pilotFrequency = 2 * .pi * 19_000 / 240_000
        pilotAmplitude = 0; pilotQuadrature = 0; pilotLocked = false
        rds.reset()
        resetCarrierOffset()
    }

    func resetCarrierOffset() {
        offsetSum = 0
        offsetCount = 0
    }

    /// Gefensterter Sinc-Tiefpass (Blackman), auf Verstärkung 1 normiert.
    static func lowpass(taps: Int, cutoff: Double, rate: Double) -> [Float] {
        let fc = cutoff / rate
        let m = Double(taps - 1)
        var h = (0..<taps).map { n -> Double in
            let x = Double(n) - m / 2
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(n) / m) + 0.08 * cos(4 * .pi * Double(n) / m)
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map(Float.init)
    }

    /// Verarbeitet einen IQ-Block und liefert die Audioabtastwerte (links, rechts).
    func process(_ iq: Data) -> (left: [Float], right: [Float]) {
        let count = iq.count / 2
        guard count > 0 else { return ([], []) }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var k = phaseIndex
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                let c = oscillatorRe[k], s = oscillatorIm[k]
                re[n] = i * c - q * s
                im[n] = i * s + q * c
                k += 1
                if k == 10 { k = 0 }
            }
            phaseIndex = k
        }
        // Stufe 1: ÷10 auf 240 kHz
        var (c1Re, c1Im) = Self.decimateComplex(re, im, history: &histRe, &histIm, filter: stage1, factor: 10)
        if fineOffsetHz != 0 { shiftFine(&c1Re, &c1Im) }
        configureFilters()

        // Signalstärke
        var power: Float = 0
        if !c1Re.isEmpty {
            var a: Float = 0, b: Float = 0
            vDSP_measqv(c1Re, 1, &a, vDSP_Length(c1Re.count))
            vDSP_measqv(c1Im, 1, &b, vDSP_Length(c1Im.count))
            power = a + b
        }
        signalDB = 10 * log10(max(power, 1e-12))

        var audio: [Float]
        var side: [Float]?
        switch mode {
        case .wfm:
            let mpx = discriminate(c1Re, c1Im)
            offsetSum += Double(vDSP.sum(mpx))
            offsetCount += mpx.count
            rds.process(mpx)
            var mono = mpx
            var difference = trackPilot(mpx)
            // Deemphasis 50 µs (Europa) bei 240 kHz – für Summe und Differenz getrennt.
            let alpha = Float(1 - exp(-1 / (240_000 * 50e-6)))
            for n in mono.indices {
                deemphasis += alpha * (mono[n] - deemphasis)
                mono[n] = deemphasis
            }
            audio = Self.decimateReal(mono, history: &histAudio, filter: wfmAudio, factor: 5)
            if stereoEnabled && pilotLocked {
                for n in difference.indices {
                    deemphasisSide += alpha * (difference[n] - deemphasisSide)
                    difference[n] = deemphasisSide
                }
                side = Self.decimateReal(difference, history: &histSide, filter: wfmAudio, factor: 5)
            } else {
                histSide = []
                deemphasisSide = 0
            }
            // Hub 75 kHz ergibt bei 240 kHz rund ±2 rad – passt ohne Verstärkung.
        case .nfm:
            pilotLocked = false
            let (c2Re, c2Im) = narrowChannel(c1Re, c1Im, filter: narrowChannelFilter)
            let channel = channelPower(c2Re, c2Im)
            audio = discriminate(c2Re, c2Im)
            // Hub ±2,5–5 kHz → ±0,3–0,65 rad bei 48 kHz
            vDSP.multiply(nfmAudioGain, audio, result: &audio)
            removeDC(&audio)
            applySquelch(&audio, channelPower: channel, seconds: Double(count) / Self.inputRate)
        case .am:
            pilotLocked = false
            let (c2Re, c2Im) = narrowChannel(c1Re, c1Im, filter: narrowChannelFilter)
            audio = [Float](repeating: 0, count: c2Re.count)
            for n in audio.indices { audio[n] = (c2Re[n] * c2Re[n] + c2Im[n] * c2Im[n]).squareRoot() }
            removeDC(&audio)
            // Pegelanpassung auf den Sprachkanal (früher auf das ganze 200-kHz-
            // Band – starke Nachbarn machten leise, Rauschen dazwischen laut).
            let channel = channelPower(c2Re, c2Im)
            let rms = max(channel.squareRoot(), 1e-4)
            vDSP.multiply(0.3 / rms, audio, result: &audio)
            applySquelch(&audio, channelPower: channel, seconds: Double(count) / Self.inputRate)
        case .usb, .lsb, .cw:
            pilotLocked = false
            let (aRe, aIm) = Self.decimateComplex(c1Re, c1Im, history: &hist2Re, &hist2Im, filter: narrowStage, factor: 5)
            let (bRe, bIm) = ssbDecimator.process(aRe, aIm)
            let (yRe, yIm) = sidebandFilter?.process(bRe, bIm) ?? (bRe, bIm)
            if !yRe.isEmpty { channelDB = 10 * log10(max(channelPower(yRe, yIm), 1e-12)) }
            audio = interpolate(productDetect(yRe, yIm))
        }
        var left = audio, right = audio
        if let side, side.count == audio.count {
            vDSP.add(audio, side, result: &left)
            vDSP.subtract(audio, side, result: &right)
        }
        vDSP.multiply(volume, left, result: &left)
        vDSP.multiply(volume, right, result: &right)
        vDSP.clip(left, to: -1...1, result: &left)
        vDSP.clip(right, to: -1...1, result: &right)
        return (left, right)
    }

    /// Baut die Kanalfilter neu, wenn Betriebsart oder Bandbreite wechseln.
    private func configureFilters() {
        let bandwidth = mode.validBandwidth(bandwidthHz) ?? 0
        let key = "\(mode.rawValue)/\(bandwidth)"
        guard key != builtFilters else { return }
        builtFilters = key
        hist3Re = []; hist3Im = []
        switch mode {
        case .nfm, .am:
            narrowChannelFilter = Self.lowpass(taps: 127, cutoff: Self.channelCutoff(mode, bandwidthHz: bandwidth), rate: Self.audioRate)
            // Schmales Raster heißt kleiner Hub (±2,5 statt ±5 kHz) – lauter machen.
            nfmAudioGain = bandwidth >= 25_000 ? 2 : 4
        case .usb, .lsb, .cw:
            let band = mode.passband(bandwidthHz: bandwidth)
            let taps = Self.complexBandpass(taps: 511, low: band.lowerBound, high: band.upperBound, rate: Self.narrowRate)
            sidebandFilter = FT8Decimator(factor: 1, tapsRe: taps.re, tapsIm: taps.im)
            agcPeak = 0; agcHold = 0
        case .wfm:
            break
        }
    }

    /// Grenzfrequenz (−6 dB) des AM/NFM-Kanalfilters. AM: halbe Filterbreite.
    /// NFM nach Kanalraster: 25 kHz → 8 kHz (±5 kHz Hub), 12,5 kHz → 5,5 kHz
    /// (Carson: ±2,5 kHz Hub + 3 kHz Ton), 6,25 kHz → 3 kHz.
    static func channelCutoff(_ mode: RadioMode, bandwidthHz: Double) -> Double {
        switch mode {
        case .nfm: bandwidthHz >= 25_000 ? 8_000 : bandwidthHz >= 12_500 ? 5_500 : 3_000
        default: bandwidthHz / 2
        }
    }

    /// Komplexer Bandpass `low…high` (Hz, auch negativ) in Korrelationsform für
    /// `vDSP_desamp`: Kaiser-Tiefpass (β 7, ≈ 70 dB Sperrdämpfung) um die
    /// Bandmitte verschoben. Durchlassverstärkung 1, −6 dB an den Kanten.
    static func complexBandpass(taps: Int, low: Double, high: Double, rate: Double) -> (re: [Float], im: [Float]) {
        let h = AirbandChannelizer.kaiserLowpass(taps: taps, cutoff: (high - low) / 2 / rate, beta: 7)
        let w = -2 * Double.pi * (low + high) / 2 / rate
        return (h.enumerated().map { Float(Double($1) * cos(w * Double($0))) },
                h.enumerated().map { Float(Double($1) * sin(w * Double($0))) })
    }

    /// Restablage (`fineOffsetHz`) bei 240 kHz herausmischen, phasenstetig über Blöcke.
    private func shiftFine(_ re: inout [Float], _ im: inout [Float]) {
        let step = -2 * Double.pi * fineOffsetHz / 240_000
        var phase = finePhase
        for n in re.indices {
            let c = Float(cos(phase)), s = Float(sin(phase))
            let r = re[n], i = im[n]
            re[n] = r * c - i * s
            im[n] = r * s + i * c
            phase += step
        }
        finePhase = phase.truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// Produktdetektor bei 12 kHz: AGC auf der Hüllkurve – sofort herunter, wenn
    /// ein Spitzenwert kommt, 0,3 s halten, dann mit ≈ 14 dB/s wieder hoch
    /// (Sprechpausen pumpen nicht). CW verschiebt um den BFO-Ton; der Realteil
    /// des einseitigen Signals ist der Ton (LSB: negative Frequenzen klingen
    /// dabei richtig herum).
    private func productDetect(_ re: [Float], _ im: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: re.count)
        let hang = Int(0.3 * Self.narrowRate)
        let decay = Float(exp(-1 / (0.6 * Self.narrowRate)))
        let target: Float = 0.8, floor: Float = 1e-4
        let bfo = mode == .cw ? 2 * Double.pi * cwPitchHz / Self.narrowRate : 0
        var peak = agcPeak, hold = agcHold, phase = bfoPhase
        for n in re.indices {
            let r = re[n], i = im[n]
            let magnitude = (r * r + i * i).squareRoot()
            if magnitude > peak { peak = magnitude; hold = hang }
            else if hold > 0 { hold -= 1 }
            else { peak *= decay }
            let gain = target / max(peak, floor)
            if bfo == 0 {
                out[n] = r * gain
            } else {
                out[n] = (r * Float(cos(phase)) - i * Float(sin(phase))) * gain
                phase += bfo
                if phase > .pi { phase -= 2 * .pi }
            }
        }
        agcPeak = peak; agcHold = hold; bfoPhase = phase
        return out
    }

    /// 12 → 48 kHz: Nullen einfügen, Tiefpass (Spiegel ab 8,7 kHz ≥ 74 dB weg).
    private func interpolate(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return [] }
        var stuffed = [Float](repeating: 0, count: x.count * 4)
        for n in x.indices { stuffed[4 * n] = x[n] }
        return Self.decimateReal(stuffed, history: &histUp, filter: upsampleFilter, factor: 1)
    }

    /// NFM/AM: ÷5 auf 48 kHz, dann der schmale Kanalfilter.
    private func narrowChannel(_ re: [Float], _ im: [Float], filter: [Float]) -> ([Float], [Float]) {
        let (dRe, dIm) = Self.decimateComplex(re, im, history: &hist2Re, &hist2Im, filter: narrowStage, factor: 5)
        return Self.decimateComplex(dRe, dIm, history: &hist3Re, &hist3Im, filter: filter, factor: 1)
    }

    /// Rastet auf den Pilotton (19 kHz) ein und liefert das heruntergemischte
    /// Differenzsignal L−R (noch ungefiltert, bei 240 kHz). Der Hilfsträger
    /// sin(2ωt) ist phasenstarr an den Pilotton sin(ωt) gekoppelt.
    private func trackPilot(_ mpx: [Float]) -> [Float] {
        var difference = [Float](repeating: 0, count: mpx.count)
        let nominal = 2 * Double.pi * 19_000 / 240_000
        // Schleifenbandbreite ≈ 20 Hz, Dämpfung 0,7.
        let omega = 2 * Double.pi * 20 / 240_000
        let alpha = 2 * 0.707 * omega, beta = omega * omega
        let smoothing = 1.0 / 12_000            // ≈ 50 ms
        var theta = pilotPhase, frequency = pilotFrequency
        var amplitude = pilotAmplitude, quadrature = pilotQuadrature
        for n in mpx.indices {
            let x = Double(mpx[n])
            let s = sin(theta), c = cos(theta)
            // Hilfsträger sin(2θ) = 2·sin θ·cos θ – mit der Phase dieses Abtastwerts.
            difference[n] = Float(4 * x * s * c)
            amplitude += smoothing * (2 * x * s - amplitude)
            quadrature += smoothing * (2 * x * c - quadrature)
            // Phasendetektor: 2x·cos θ ≈ −A·sin(θ − ωt) plus Audio um 19 kHz, das die
            // schmale Schleife wegmittelt – deshalb nur grob begrenzen, nicht kappen.
            let error = max(-20, min(20, 2 * x * c / max(amplitude, 0.05)))
            frequency += beta * error
            frequency = max(nominal * 0.999, min(nominal * 1.001, frequency))
            theta += frequency + alpha * error
            if theta > .pi { theta -= 2 * .pi }
        }
        pilotPhase = theta
        pilotFrequency = frequency
        pilotAmplitude = amplitude
        pilotQuadrature = quadrature
        // Pilot mit ≥ 1,1 kHz Hub (0,03 rad), PLL in Phase.
        pilotLocked = amplitude > 0.03 && amplitude > 4 * abs(quadrature)
        return difference
    }

    /// FM-Diskriminator: Winkel zwischen aufeinanderfolgenden Abtastwerten.
    private func discriminate(_ re: [Float], _ im: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: re.count)
        var pr = lastRe, pi = lastIm
        for n in re.indices {
            let r = re[n], i = im[n]
            // x[n] · conj(x[n-1])
            let a = r * pr + i * pi
            let b = i * pr - r * pi
            out[n] = atan2f(b, a)
            pr = r; pi = i
        }
        lastRe = pr; lastIm = pi
        return out
    }

    private func channelPower(_ re: [Float], _ im: [Float]) -> Float {
        guard !re.isEmpty else { return 0 }
        var a: Float = 0, b: Float = 0
        vDSP_measqv(re, 1, &a, vDSP_Length(re.count))
        vDSP_measqv(im, 1, &b, vDSP_Length(im.count))
        return a + b
    }

    /// Rauschboden: folgt nach unten schnell, nach oben mit 0,3 dB/s (ein
    /// Funkspruch hebt ihn kaum an, ein Dauerträger nach rund einer Minute).
    /// Offen bleibt die Sperre 0,4 s über das Spruchende hinaus; Ein-/Ausblenden
    /// über den Block verhindert Knacken.
    private func applySquelch(_ audio: inout [Float], channelPower: Float, seconds: Double) {
        let db = 10 * log10(max(channelPower, 1e-12))
        channelDB = db
        if channelFloorDB.isNaN { channelFloorDB = db }
        else if db < channelFloorDB { channelFloorDB += (db - channelFloorDB) * 0.3 }
        else { channelFloorDB += Float(0.3 * seconds) }
        let open = squelchDB <= 0 || db > channelFloorDB + squelchDB
        if open { squelchHold = 0.4 } else { squelchHold -= seconds }
        squelchOpen = squelchHold > 0
        let target: Float = squelchOpen ? 1 : 0
        guard !audio.isEmpty, target != squelchGain || target == 0 else { return }
        let start = squelchGain, step = (target - start) / Float(audio.count)
        for n in audio.indices { audio[n] *= start + step * Float(n + 1) }
        squelchGain = target
    }

    private func removeDC(_ x: inout [Float]) {
        for n in x.indices {
            dcState += 0.001 * (x[n] - dcState)
            x[n] -= dcState
        }
    }

    // MARK: - Dezimierende FIR-Filter mit Überlapp

    static func decimateComplex(_ re: [Float], _ im: [Float], history hRe: inout [Float], _ hIm: inout [Float],
                                filter: [Float], factor: Int) -> ([Float], [Float]) {
        let taps = filter.count
        if hRe.isEmpty {
            hRe = [Float](repeating: 0, count: taps - 1)
            hIm = [Float](repeating: 0, count: taps - 1)
        }
        var inRe = hRe + re
        var inIm = hIm + im
        let outCount = (inRe.count - taps) / factor + 1
        guard outCount > 0 else { hRe = inRe; hIm = inIm; return ([], []) }
        var outRe = [Float](repeating: 0, count: outCount)
        var outIm = [Float](repeating: 0, count: outCount)
        // vDSP_desamp erwartet den Filter in umgekehrter Reihenfolge (Faltung).
        let reversed = Array(filter.reversed())
        vDSP_desamp(&inRe, vDSP_Stride(factor), reversed, &outRe, vDSP_Length(outCount), vDSP_Length(taps))
        vDSP_desamp(&inIm, vDSP_Stride(factor), reversed, &outIm, vDSP_Length(outCount), vDSP_Length(taps))
        let consumed = outCount * factor
        hRe = Array(inRe[consumed...])
        hIm = Array(inIm[consumed...])
        return (outRe, outIm)
    }

    static func decimateReal(_ x: [Float], history h: inout [Float], filter: [Float], factor: Int) -> [Float] {
        let taps = filter.count
        if h.isEmpty { h = [Float](repeating: 0, count: taps - 1) }
        var input = h + x
        let outCount = (input.count - taps) / factor + 1
        guard outCount > 0 else { h = input; return [] }
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(&input, vDSP_Stride(factor), Array(filter.reversed()), &out, vDSP_Length(outCount), vDSP_Length(taps))
        h = Array(input[(outCount * factor)...])
        return out
    }
}
