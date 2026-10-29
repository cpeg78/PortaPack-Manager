import Accelerate
import Foundation

/// Konventionelles VOR (und DVOR) auswerten.
///
/// Signal (ICAO Anhang 10): AM-Träger mit
/// - 30 Hz AM (Grad 30 %),
/// - Hilfsträger 9960 Hz (AM-Grad 30 %), frequenzmoduliert mit 30 Hz, Hub ±480 Hz,
/// - Kennung 1020 Hz in Morse (AM-Grad ≈ 10 %), gelegentlich Sprache.
///
/// Beim CVOR ist das 30-Hz-FM des Hilfsträgers die Bezugsphase und die 30-Hz-AM
/// die umlaufende (richtungsabhängige) Phase: AM = cos(ωt − θ), FM = cos(ωt).
/// Radial θ (vom Funkfeuer weg, missweisend) = Phase(FM) − Phase(AM).
///
/// **DVOR** tauscht die Rollen: dort ist die 30-Hz-AM der Bezug (ungerichtet
/// abgestrahlt) und das 30-Hz-FM entsteht als Doppler-Effekt der umlaufenden
/// Seitenbandantennen. Damit ein gewöhnlicher Empfänger dasselbe Radial
/// anzeigt, laufen die Seitenbänder **gegen** den Uhrzeigersinn um – die
/// FM-Phase eilt dann um θ vor: FM = cos(ωt + θ), AM = cos(ωt). Die Differenz
/// Phase(FM) − Phase(AM) ist wieder θ. Der Empfänger muss also nichts umkehren;
/// das prüft `VORTests` mit beiden Modellen.
///
/// Kette: 2,4 MS/s → Versatz 240 kHz herausmischen, ÷10 → 240 kHz → Kanalfilter
/// 18 kHz, ÷5 → 48 kHz komplex → Hüllkurve, geteilt durch den Träger (gleitend
/// über ≈ 1 s) = Modulationssignal m(t). Aus m(t):
/// - 30 Hz AM: Tiefpass 60 Hz, ÷100 → 480 Hz,
/// - Hilfsträger: mit 9960 Hz heruntermischen, Tiefpass 1,2 kHz, ÷10 → 4800 Hz,
///   FM-Diskriminator (Hz), Tiefpass 60 Hz, ÷10 → 480 Hz,
/// - Kennung: Betrag bei 1020 Hz je 10 ms (100 Werte/s) → `MorseDecoder`.
/// Beide 480-Hz-Ströme liegen auf demselben Zeitraster; die unterschiedlichen
/// Laufzeiten der Filter werden als Phase bei 30 Hz herausgerechnet.
final class VORDemodulator: @unchecked Sendable {
    static let inputRate = 2_400_000.0
    static let offset = 240_000.0
    static let basebandRate = 48_000.0
    static let lowRate = 480.0
    static let subcarrierHz = 9960.0
    static let identHz = 1020.0

    struct Reading: Equatable, Sendable {
        /// Radial vom Funkfeuer weg, bezogen auf die Nordausrichtung der Station (missweisend).
        var radial: Double
        /// Modulationsgrad der 30-Hz-AM (Soll 0,3).
        var amDepth: Double
        /// Modulationsgrad des 9960-Hz-Hilfsträgers (Soll 0,3).
        var subcarrierDepth: Double
        /// Hub des 30-Hz-FM in Hz (Soll 480).
        var deviationHz: Double
        /// Modulationsgrad der Kennung (Soll ≈ 0,1, nur während der Töne).
        var identDepth: Double
        /// Kanalleistung (dBFS).
        var signalDB: Double
        /// Anteil der Kanalleistung, der kohärent als Träger bei 0 Hz liegt (0…1).
        /// Ein VOR hat ≈ 0,8–0,95, reines Rauschen ≈ 0,002. Live 28.10.2026:
        /// Ohne Funkfeuer auf der Frequenz zeigte die Seite aus dem Rauschen eine
        /// Güte, ein Radial und Morse „E“ – jetzt gilt das als „kein Signal“.
        var carrierFraction: Double = 1
    }

    var volume: Float = 0.5
    let morse = MorseDecoder(rate: 100)
    private(set) var signalDB: Float = -100
    /// Geglätteter Trägeranteil (siehe `Reading.carrierFraction`).
    private(set) var carrierFraction: Double = 0
    private var coherentRe: Float = 0, coherentIm: Float = 0, coherentPower: Float = 0, coherentCount = 0

    private let stage1 = RadioDemodulator.lowpass(taps: 95, cutoff: 100_000, rate: 2_400_000)
    private let channel = RadioDemodulator.lowpass(taps: 191, cutoff: 18_000, rate: 240_000)
    private let am30 = RadioDemodulator.lowpass(taps: 1023, cutoff: 60, rate: 48_000)
    private let subFilter = RadioDemodulator.lowpass(taps: 255, cutoff: 1_200, rate: 48_000)
    private let ref30 = RadioDemodulator.lowpass(taps: 255, cutoff: 60, rate: 4_800)
    private let audioFilter = RadioDemodulator.lowpass(taps: 127, cutoff: 3_200, rate: 48_000)

    private let oscRe = (0..<10).map { Float(cos(-2 * Double.pi * Double($0) / 10)) }
    private let oscIm = (0..<10).map { Float(sin(-2 * Double.pi * Double($0) / 10)) }
    private var phase10 = 0
    // 9960/48000 = 83/400 → Periode 400; 1020/48000 = 17/800 → Periode 800.
    private let subRe = (0..<400).map { Float(cos(-2 * Double.pi * 83 * Double($0) / 400)) }
    private let subIm = (0..<400).map { Float(sin(-2 * Double.pi * 83 * Double($0) / 400)) }
    private let identRe = (0..<800).map { Float(cos(-2 * Double.pi * 17 * Double($0) / 800)) }
    private let identIm = (0..<800).map { Float(sin(-2 * Double.pi * 17 * Double($0) / 800)) }

    private var h1Re: [Float] = [], h1Im: [Float] = []
    private var h2Re: [Float] = [], h2Im: [Float] = []
    private var hAM: [Float] = []
    private var hSubRe: [Float] = [], hSubIm: [Float] = []
    private var hRef: [Float] = []
    private var hAudio: [Float] = []
    private var carrier: Float = 0
    private var basebandIndex = 0          // Zähler bei 48 kHz (für die Mischtabellen)
    private var lastSubRe: Float = 1, lastSubIm: Float = 0
    private var identAccRe: Float = 0, identAccIm: Float = 0, identCount = 0
    private var identLevels: [Float] = []

    /// Letzte ≤ 2 s der beiden 30-Hz-Ströme und ihr absoluter Index.
    private var amLow: [Float] = []
    private var fmLow: [Float] = []
    private var amLowStart = 0
    private var fmLowStart = 0
    private var subMagnitudeSum = 0.0
    private var subMagnitudeCount = 0
    private var basebandSamples = 0

    /// Laufzeiten bis zum 480-Hz-Raster (Sekunden).
    private var amDelay: Double { Double(am30.count - 1) / 2 / Self.basebandRate }
    private var fmDelay: Double {
        Double(subFilter.count - 1) / 2 / Self.basebandRate + 0.5 / 4_800 + Double(ref30.count - 1) / 2 / 4_800
    }

    func reset() {
        h1Re = []; h1Im = []; h2Re = []; h2Im = []; hAM = []; hSubRe = []; hSubIm = []; hRef = []; hAudio = []
        carrier = 0; basebandIndex = 0; phase10 = 0
        carrierFraction = 0; coherentRe = 0; coherentIm = 0; coherentPower = 0; coherentCount = 0
        lastSubRe = 1; lastSubIm = 0
        identAccRe = 0; identAccIm = 0; identCount = 0; identLevels = []
        amLow = []; fmLow = []; amLowStart = 0; fmLowStart = 0
        subMagnitudeSum = 0; subMagnitudeCount = 0; basebandSamples = 0
        morse.reset()
    }

    /// IQ-Block (int8, 2,4 MS/s, Funkfeuer 240 kHz über der Mittenfrequenz) → Ton (48 kHz).
    func process(_ iq: Data) -> [Float] {
        let count = iq.count / 2
        guard count > 0 else { return [] }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var k = phase10
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                re[n] = i * oscRe[k] - q * oscIm[k]
                im[n] = i * oscIm[k] + q * oscRe[k]
                k += 1
                if k == 10 { k = 0 }
            }
            phase10 = k
        }
        let (aRe, aIm) = RadioDemodulator.decimateComplex(re, im, history: &h1Re, &h1Im, filter: stage1, factor: 10)
        let (bRe, bIm) = RadioDemodulator.decimateComplex(aRe, aIm, history: &h2Re, &h2Im, filter: channel, factor: 5)
        return processBaseband(re: bRe, im: bIm)
    }

    /// Komplexes Basisband mit 48 kHz (Träger nahe 0 Hz) → Ton (48 kHz).
    func processBaseband(re: [Float], im: [Float]) -> [Float] {
        let count = re.count
        guard count > 0 else { return [] }
        var env = [Float](repeating: 0, count: count)
        var power: Float = 0
        for n in 0..<count {
            let p = re[n] * re[n] + im[n] * im[n]
            power += p
            env[n] = p.squareRoot()
        }
        signalDB = 10 * log10(max(power / Float(count), 1e-12))
        // Trägeranteil je 10 ms (480 Werte): Trägerfrequenz aus der mittleren Phasendrehung
        // von Wert zu Wert schätzen (dominiert vom Träger, bei Rauschen zufällig), heraus-
        // drehen und kohärent summieren: |Σz·e^(−jωn)|² / (N·Σ|z|²). So zählt auch ein Träger
        // einige 100 Hz neben 0 Hz (Quarzablage) voll; Rauschen bleibt bei ≈ 1/N.
        coherentRe = 0; coherentIm = 0; coherentPower = 0
        var start = 0
        while start + 480 <= count {
            var aRe: Float = 0, aIm: Float = 0, p: Float = 0
            for n in start..<(start + 480) {
                p += re[n] * re[n] + im[n] * im[n]
                if n > start {
                    aRe += re[n] * re[n - 1] + im[n] * im[n - 1]
                    aIm += im[n] * re[n - 1] - re[n] * im[n - 1]
                }
            }
            let w = atan2f(aIm, aRe)
            var sRe: Float = 0, sIm: Float = 0
            for n in start..<(start + 480) {
                let ph = -w * Float(n - start)
                let c = cosf(ph), sn = sinf(ph)
                sRe += re[n] * c - im[n] * sn
                sIm += re[n] * sn + im[n] * c
            }
            let fraction = p > 0 ? Double((sRe * sRe + sIm * sIm) / (480 * p)) : 0
            carrierFraction += 0.05 * (min(max(fraction, 0), 1) - carrierFraction)
            start += 480
        }
        // Modulationssignal m(t) = Hüllkurve / Träger − 1
        if carrier <= 0 { carrier = vDSP.mean(env) }
        let alpha: Float = 1 / 48_000
        var c = carrier
        var m = env
        for n in 0..<count {
            c += alpha * (env[n] - c)
            m[n] = c > 0 ? env[n] / c - 1 : 0
        }
        carrier = c
        basebandSamples += count

        // 30 Hz AM
        let am = RadioDemodulator.decimateReal(m, history: &hAM, filter: am30, factor: 100)
        append(am, to: &amLow, start: &amLowStart)

        // Hilfsträger 9960 Hz → FM-Diskriminator
        var sRe = [Float](repeating: 0, count: count)
        var sIm = [Float](repeating: 0, count: count)
        var idRe = identAccRe, idIm = identAccIm, idCount = identCount
        var k = basebandIndex
        for n in 0..<count {
            let x = m[n]
            let ks = k % 400, ki = k % 800
            sRe[n] = x * subRe[ks]
            sIm[n] = x * subIm[ks]
            idRe += x * identRe[ki]
            idIm += x * identIm[ki]
            idCount += 1
            if idCount == 480 {
                // Betrag bei 1020 Hz über 10 ms; ×2/N = Modulationsgrad.
                identLevels.append(2 * (idRe * idRe + idIm * idIm).squareRoot() / 480)
                idRe = 0; idIm = 0; idCount = 0
            }
            k += 1
            if k == 400 * 800 { k = 0 }
        }
        basebandIndex = k
        identAccRe = idRe; identAccIm = idIm; identCount = idCount
        if !identLevels.isEmpty {
            morse.feed(identLevels)
            recentIdent.append(contentsOf: identLevels)
            if recentIdent.count > 300 { recentIdent.removeFirst(recentIdent.count - 300) }
            identLevels = []
        }

        let (zRe, zIm) = RadioDemodulator.decimateComplex(sRe, sIm, history: &hSubRe, &hSubIm, filter: subFilter, factor: 10)
        var freq = [Float](repeating: 0, count: zRe.count)
        var pr = lastSubRe, pi = lastSubIm
        for n in zRe.indices {
            let r = zRe[n], i = zIm[n]
            freq[n] = atan2f(i * pr - r * pi, r * pr + i * pi) * Float(4_800 / (2 * Double.pi))
            subMagnitudeSum += Double((r * r + i * i).squareRoot())
            subMagnitudeCount += 1
            pr = r; pi = i
        }
        lastSubRe = pr; lastSubIm = pi
        let fm = RadioDemodulator.decimateReal(freq, history: &hRef, filter: ref30, factor: 10)
        append(fm, to: &fmLow, start: &fmLowStart)
        if subMagnitudeCount > 9_600 {
            // Gleitend über ≈ 2 s halten
            subMagnitudeSum *= 0.5
            subMagnitudeCount /= 2
        }

        // Hörbarer Ton: Kennung und Sprache, ohne Hilfsträger.
        var audio = RadioDemodulator.decimateReal(m, history: &hAudio, filter: audioFilter, factor: 1)
        vDSP.multiply(2 * volume, audio, result: &audio)
        vDSP.clip(audio, to: -1...1, result: &audio)
        return audio
    }

    private var recentIdent: [Float] = []

    private func append(_ values: [Float], to buffer: inout [Float], start: inout Int) {
        buffer.append(contentsOf: values)
        let limit = Int(2 * Self.lowRate)
        if buffer.count > limit {
            let drop = buffer.count - limit
            buffer.removeFirst(drop)
            start += drop
        }
    }

    /// Phase und Amplitude der 30-Hz-Komponente; Index = absoluter Abtastwert bei 480 Hz.
    private static func tone30(_ values: [Float], start: Int, from: Int, to: Int) -> (phase: Double, amplitude: Double) {
        var c = 0.0, s = 0.0
        for n in from..<to {
            let index = start + n
            let theta = 2 * Double.pi * Double(index % 16) / 16
            c += Double(values[n]) * cos(theta)
            s -= Double(values[n]) * sin(theta)
        }
        let count = Double(to - from)
        return (atan2(s, c), 2 * (c * c + s * s).squareRoot() / count)
    }

    /// Messung über die letzte Sekunde (nach ≥ 1,2 s Einschwingen); `nil`, solange zu wenig Daten.
    func reading() -> Reading? {
        guard Double(basebandSamples) / Self.basebandRate >= 1.2 else { return nil }
        let window = Int(Self.lowRate)
        // Gemeinsamer Bereich beider Ströme
        let end = min(amLowStart + amLow.count, fmLowStart + fmLow.count)
        let begin = end - window
        guard begin >= amLowStart, begin >= fmLowStart else { return nil }
        let a = Self.tone30(amLow, start: amLowStart, from: begin - amLowStart, to: end - amLowStart)
        let f = Self.tone30(fmLow, start: fmLowStart, from: begin - fmLowStart, to: end - fmLowStart)
        let omega = 2 * Double.pi * 30
        let phaseAM = a.phase + omega * amDelay
        let phaseFM = f.phase + omega * fmDelay
        var radial = (phaseFM - phaseAM) * 180 / .pi
        radial = radial.truncatingRemainder(dividingBy: 360)
        if radial < 0 { radial += 360 }
        let ident = recentIdent.max() ?? 0
        let sub = subMagnitudeCount > 0 ? 2 * subMagnitudeSum / Double(subMagnitudeCount) : 0
        return Reading(radial: radial, amDepth: a.amplitude, subcarrierDepth: sub, deviationHz: f.amplitude,
                       identDepth: Double(ident), signalDB: Double(signalDB), carrierFraction: carrierFraction)
    }
}
