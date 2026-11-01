import Accelerate
import Foundation

/// Konstanten von 802.11a/g (OFDM, 20 MHz): Präambeln, Piloten, Datenraten,
/// Verschachtelung – nach IEEE 802.11-2016, Abschnitt 17.
enum WLANOFDM {
    static let fftSize = 64
    static let guardSamples = 16
    static let symbolSamples = 80
    static let pilotSubcarriers = [-21, -7, 7, 21]
    static let pilotValues: [Float] = [1, 1, 1, -1]
    /// Datenträger −26…26 ohne 0 und ohne Piloten (48), aufsteigend.
    static let dataSubcarriers: [Int] = (-26...26).filter { $0 != 0 && !pilotSubcarriers.contains($0) }
    static let usedSubcarriers: [Int] = (-26...26).filter { $0 != 0 }

    /// Kurzpräambel im Frequenzbereich: Träger ±4, ±8, …, ±24 mit (±1 ± j)·√(13/6).
    static let shortTrainingFrequency: [Int: (re: Float, im: Float)] = {
        let a = Float((13.0 / 6.0).squareRoot())
        let plus: [Int] = [-24, -16, -4, 12, 16, 20, 24]
        let minus: [Int] = [-20, -12, -8, 4, 8]
        var map: [Int: (Float, Float)] = [:]
        for k in plus { map[k] = (a, a) }
        for k in minus { map[k] = (-a, -a) }
        return map
    }()

    /// Langpräambel im Frequenzbereich, Träger −26…26 (Index 26 = Träger 0).
    static let longTrainingFrequency: [Float] = [
        1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1,
        0,
        1, -1, -1, 1, 1, -1, 1, -1, 1, -1, -1, -1, -1, -1, 1, 1, -1, -1, 1, -1, 1, -1, 1, 1, 1, 1,
    ]

    static func longTraining(_ subcarrier: Int) -> Float { longTrainingFrequency[subcarrier + 26] }

    /// Ein OFDM-Symbol (64 Werte) im Zeitbereich aus Trägern −26…26 (IDFT).
    static func timeSymbol(_ spectrum: [Int: (re: Float, im: Float)]) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: fftSize), im = [Float](repeating: 0, count: fftSize)
        for n in 0..<fftSize {
            var sr: Float = 0, si: Float = 0
            for (k, v) in spectrum {
                let phase = 2 * Float.pi * Float(k * n) / Float(fftSize)
                sr += v.re * cos(phase) - v.im * sin(phase)
                si += v.re * sin(phase) + v.im * cos(phase)
            }
            re[n] = sr / Float(fftSize)
            im[n] = si / Float(fftSize)
        }
        return (re, im)
    }

    /// Kurzpräambel (ein 64er-Symbol, periodisch mit 16) im Zeitbereich.
    static let shortTrainingTime = timeSymbol(shortTrainingFrequency)
    /// Langpräambel (ein 64er-Symbol) im Zeitbereich.
    static let longTrainingTime = timeSymbol(Dictionary(uniqueKeysWithValues: usedSubcarriers.map { ($0, (longTraining($0), Float(0))) }))

    /// Pilotpolarität p₀…p₁₂₆: der Verwürfler mit Startzustand 1111111, 0 → +1.
    static let pilotPolarity: [Float] = scrambler(seed: 0x7F, count: 127).map { $0 == 0 ? 1 : -1 }

    /// Verwürfler x⁷ + x⁴ + 1; `seed` sind die sieben Zustandsbits (x1 in Bit 0).
    static func scrambler(seed: UInt8, count: Int) -> [UInt8] {
        var state = seed & 0x7F
        return (0..<count).map { _ in
            let bit = (state >> 6 ^ state >> 3) & 1       // x7 ⊕ x4
            state = (state << 1 | bit) & 0x7F
            return bit
        }
    }

    enum Puncturing: Sendable { case r12, r23, r34 }

    struct Rate: Sendable, Equatable {
        let mbps: Int
        let bitsPerSubcarrier: Int
        let codedBitsPerSymbol: Int
        let dataBitsPerSymbol: Int
        let puncturing: Puncturing
        /// RATE-Feld, Bit 0 = zuerst gesendetes Bit R1.
        let code: UInt8

        static func == (a: Rate, b: Rate) -> Bool { a.mbps == b.mbps }
    }

    static let rates: [Rate] = [
        Rate(mbps: 6, bitsPerSubcarrier: 1, codedBitsPerSymbol: 48, dataBitsPerSymbol: 24, puncturing: .r12, code: 0b1011),
        Rate(mbps: 9, bitsPerSubcarrier: 1, codedBitsPerSymbol: 48, dataBitsPerSymbol: 36, puncturing: .r34, code: 0b1111),
        Rate(mbps: 12, bitsPerSubcarrier: 2, codedBitsPerSymbol: 96, dataBitsPerSymbol: 48, puncturing: .r12, code: 0b1010),
        Rate(mbps: 18, bitsPerSubcarrier: 2, codedBitsPerSymbol: 96, dataBitsPerSymbol: 72, puncturing: .r34, code: 0b1110),
        Rate(mbps: 24, bitsPerSubcarrier: 4, codedBitsPerSymbol: 192, dataBitsPerSymbol: 96, puncturing: .r12, code: 0b1001),
        Rate(mbps: 36, bitsPerSubcarrier: 4, codedBitsPerSymbol: 192, dataBitsPerSymbol: 144, puncturing: .r34, code: 0b1101),
        Rate(mbps: 48, bitsPerSubcarrier: 6, codedBitsPerSymbol: 288, dataBitsPerSymbol: 192, puncturing: .r23, code: 0b1000),
        Rate(mbps: 54, bitsPerSubcarrier: 6, codedBitsPerSymbol: 288, dataBitsPerSymbol: 216, puncturing: .r34, code: 0b1100),
    ]

    static func rate(code: UInt8) -> Rate? { rates.first { $0.code == code } }
    static func rate(mbps: Int) -> Rate? { rates.first { $0.mbps == mbps } }

    /// Verschachtelung eines Symbols: Position des kodierten Bits k nach beiden
    /// Permutationen (17.3.5.7).
    static func interleaverMap(_ rate: Rate) -> [Int] {
        let n = rate.codedBitsPerSymbol
        let s = max(rate.bitsPerSubcarrier / 2, 1)
        return (0..<n).map { k in
            let i = (n / 16) * (k % 16) + k / 16
            return s * (i / s) + (i + n - (16 * i) / n) % s
        }
    }

    /// Skalierung der Konstellation auf das Raster ±1, ±3, …
    static func constellationScale(_ bitsPerSubcarrier: Int) -> Float {
        switch bitsPerSubcarrier {
        case 1: 1
        case 2: Float(2.0.squareRoot())
        case 4: Float(10.0.squareRoot())
        default: Float(42.0.squareRoot())
        }
    }

    /// Anzahl der Datensymbole für `length` Nutzbytes.
    static func symbolCount(length: Int, rate: Rate) -> Int {
        (16 + 8 * length + 6 + rate.dataBitsPerSymbol - 1) / rate.dataBitsPerSymbol
    }
}

/// Ein 802.11-Rahmen mit gültiger FCS, wie ihn der HackRF-Empfänger liefert.
struct WLANPacket: Sendable, Equatable {
    enum Modulation: String, Sendable { case dsss = "DSSS", ofdm = "OFDM" }
    var modulation: Modulation
    var rateMbps: Double
    /// MPDU ohne FCS.
    var mpdu: [UInt8]
    var rssiDB: Double
    var offsetKHz: Double
    var date: Date
}

/// OFDM-Empfänger (802.11a/g, 6–54 Mbit/s) bei 20 MS/s: Kurzpräambel per
/// Autokorrelation (Abstand 16), Langpräambel per Kreuzkorrelation,
/// Frequenzablage grob (Kurz-) und fein (Langpräambel), Kanalschätzung aus
/// beiden Langsymbolen, SIGNAL und Daten mit Pilotnachführung (Phase und
/// Steigung), weiche Bits → Entschachtelung → Entpunktierung → Viterbi
/// (`MeteorViterbi`, gleiche Polynome 133/171) → Entwürfelung → FCS.
final class WLANOFDMDemodulator {
    /// Höchstdauer eines Rahmens (Symbole à 4 µs): 4 ms.
    static let maximumSymbols = 1000
    static let maximumSamples = (320 + 80 * (1 + maximumSymbols))
    /// Autokorrelation: normierte Güte, ab der die Kurzpräambel als erkannt gilt.
    static let plateauThreshold: Float = 0.5

    private(set) var preambles = 0
    /// Arbeitspuffer der Präambelsuche, über Blöcke wiederverwendet (vorher je Block
    /// acht neue Felder à ≈ 0,5 MB samt Nullfüllen – 31.10.2026).
    private var prodRe: [Float] = [], prodIm: [Float] = [], mags: [Float] = []
    private var cRe: [Float] = [], cIm: [Float] = [], p: [Float] = [], m: [Float] = [], p2: [Float] = []
    private(set) var signalErrors = 0
    private(set) var fcsErrors = 0

    private let fft = vDSP_create_fftsetup(6, FFTRadix(kFFTRadix2))!
    deinit { vDSP_destroy_fftsetup(fft) }

    /// Sucht Rahmen in `count` Abtastwerten ab `from`. Liefert die Pakete und
    /// die Stelle, bis zu der der Puffer abgearbeitet ist (bei einem
    /// angefangenen Rahmen dessen Anfang – er wartet auf mehr Daten).
    func detect(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, from: Int, noise: Float)
        -> (packets: [WLANPacket], consumed: Int) {
        let window = 48
        guard count > window + 16 + 400, from < count else { return ([], from) }
        let metricCount = count - 16 - window + 1
        // C[n] = Σ x[n+k]·conj(x[n+k+16]), P[n] = Σ |x[n+k+16]|² über k < 48.
        WLANScratch.size(&prodRe, count - 16); WLANScratch.size(&prodIm, count - 16); WLANScratch.size(&mags, count - 16)
        WLANScratch.size(&cRe, metricCount); WLANScratch.size(&cIm, metricCount); WLANScratch.size(&p, metricCount)
        WLANScratch.size(&m, metricCount); WLANScratch.size(&p2, metricCount)
        var a = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re + 16), imagp: UnsafeMutablePointer(mutating: im + 16))
        var b = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re), imagp: UnsafeMutablePointer(mutating: im))
        prodRe.withUnsafeMutableBufferPointer { pr in
            prodIm.withUnsafeMutableBufferPointer { pi in
                var c = DSPSplitComplex(realp: pr.baseAddress!, imagp: pi.baseAddress!)
                vDSP_zvcmul(&a, 1, &b, 1, &c, 1, vDSP_Length(count - 16))
                vDSP_zvmags(&a, 1, &mags, 1, vDSP_Length(count - 16))
            }
        }
        vDSP_vswsum(prodRe, 1, &cRe, 1, vDSP_Length(metricCount), vDSP_Length(window))
        vDSP_vswsum(prodIm, 1, &cIm, 1, vDSP_Length(metricCount), vDSP_Length(window))
        vDSP_vswsum(mags, 1, &p, 1, vDSP_Length(metricCount), vDSP_Length(window))
        cRe.withUnsafeMutableBufferPointer { r in
            cIm.withUnsafeMutableBufferPointer { i in
                var c = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_zvmags(&c, 1, &m, 1, vDSP_Length(metricCount))
            }
        }
        vDSP_vsq(p, 1, &p2, 1, vDSP_Length(metricCount))
        var eps = Float(1e-12)
        vDSP_vsadd(p2, 1, &eps, &p2, 1, vDSP_Length(metricCount))
        vDSP_vdiv(p2, 1, m, 1, &m, 1, vDSP_Length(metricCount))

        let gate = noise * Float(window) * 4
        var packets: [WLANPacket] = []
        var n = max(0, from)
        let limit = metricCount - 400
        while n < limit {
            guard m[n] > Self.plateauThreshold, p[n] > gate else { n += 1; continue }
            let start = n
            var end = n
            var sumRe: Float = 0, sumIm: Float = 0
            while end < metricCount, end - start < 220, m[end] > Self.plateauThreshold * 0.8 {
                sumRe += cRe[end]
                sumIm += cIm[end]
                end += 1
            }
            guard end - start >= 48 else { n = end + 1; continue }
            preambles += 1
            // Grobe Ablage aus der Autokorrelation: arg C = −2π·f·16.
            let coarse = -atan2(sumIm, sumRe) / (2 * Float.pi * 16)
            // Reicht der Puffer für Präambel + SIGNAL?
            guard start + 320 + 80 + 80 < count else { return (packets, start) }
            guard let ltfStart = findLongTraining(re: re, im: im, count: count, from: start + 64, to: min(start + 260, count - 200),
                                                  cfo: coarse) else {
                n = max(end, start + 160)
                continue
            }
            switch decode(re: re, im: im, count: count, ltfStart: ltfStart, coarse: coarse) {
            case let .packet(packet, endSample):
                packets.append(packet)
                n = endSample
            case .needMore:
                return (packets, start)
            case .failed:
                n = ltfStart + 128
            }
        }
        return (packets, max(from, n))
    }

    private enum Outcome { case packet(WLANPacket, Int), needMore, failed }

    /// Kreuzkorrelation mit der Langpräambel (zwei Symbole im Abstand 64) im
    /// Bereich `from..<to`; liefert den Beginn des ersten vollen Langsymbols.
    private func findLongTraining(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, from: Int, to: Int,
                                  cfo: Float) -> Int? {
        guard to > from else { return nil }
        let ltf = WLANOFDM.longTrainingTime
        var best = from, bestValue: Float = 0
        var ltfEnergy: Float = 0
        for k in 0..<64 { ltfEnergy += ltf.re[k] * ltf.re[k] + ltf.im[k] * ltf.im[k] }
        // Ablage einmal je Abtastwert herausdrehen statt für jede Lage n erneut: jeder Wert
        // kommt in bis zu 128 Lagen vor (vorher ≈ 25 000 sin/cos je Präambel, und Präambel-
        // Fehlalarme gibt es tausende pro Sekunde – 31.10.2026). Gleiche Formel → gleiche Werte.
        let span = min(to + 127, count) - from
        var rotRe = [Float](repeating: 0, count: span), rotIm = [Float](repeating: 0, count: span)
        for j in 0..<span {
            let phase = -2 * Float.pi * cfo * Float(from + j)
            let c = cos(phase), s = sin(phase)
            rotRe[j] = re[from + j] * c - im[from + j] * s
            rotIm[j] = re[from + j] * s + im[from + j] * c
        }
        for n in from..<to {
            guard n + 128 <= count else { break }
            var total: Float = 0
            for half in 0..<2 {
                var sr: Float = 0, si: Float = 0, energy: Float = 0
                let base = n + 64 * half - from
                for k in 0..<64 {
                    let xr = rotRe[base + k], xi = rotIm[base + k]
                    sr += xr * ltf.re[k] + xi * ltf.im[k]
                    si += xi * ltf.re[k] - xr * ltf.im[k]
                    energy += xr * xr + xi * xi
                }
                total += (sr * sr + si * si).squareRoot() / max((energy * ltfEnergy).squareRoot(), 1e-9)
            }
            if total > bestValue { bestValue = total; best = n }
        }
        return bestValue > 1.0 ? best : nil
    }

    private func decode(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, ltfStart: Int, coarse: Float) -> Outcome {
        // Feine Ablage aus den beiden Langsymbolen (nach grober Korrektur).
        var sr: Float = 0, si: Float = 0
        for k in 0..<64 {
            let (ar, ai) = rotated(re, im, ltfStart + k, cfo: coarse)
            let (br, bi) = rotated(re, im, ltfStart + 64 + k, cfo: coarse)
            sr += ar * br + ai * bi
            si += ai * br - ar * bi
        }
        let cfo = coarse - atan2(si, sr) / (2 * Float.pi * 64)
        let advance = 4   // FFT-Fenster vier Werte vor dem Schutzintervallende

        var level: Float = 0
        for k in 0..<128 { level += re[ltfStart + k] * re[ltfStart + k] + im[ltfStart + k] * im[ltfStart + k] }
        level /= 128

        // Kanalschätzung.
        let y1 = spectrum(re, im, start: ltfStart - advance, cfo: cfo)
        let y2 = spectrum(re, im, start: ltfStart + 64 - advance, cfo: cfo)
        var hRe = [Float](repeating: 0, count: 64), hIm = [Float](repeating: 0, count: 64)
        var meanH2: Float = 0
        for k in WLANOFDM.usedSubcarriers {
            let i = k & 63
            let l = WLANOFDM.longTraining(k)
            hRe[i] = (y1.re[i] + y2.re[i]) / 2 * l
            hIm[i] = (y1.im[i] + y2.im[i]) / 2 * l
            meanH2 += hRe[i] * hRe[i] + hIm[i] * hIm[i]
        }
        meanH2 /= Float(WLANOFDM.usedSubcarriers.count)
        guard meanH2 > 0 else { return .failed }

        // SIGNAL.
        let signalStart = ltfStart + 128 + 16 - advance
        guard let bpsk = WLANOFDM.rate(mbps: 6) else { return .failed }
        let signalSoft = softBits(spectrum(re, im, start: signalStart, cfo: cfo), hRe: hRe, hIm: hIm, meanH2: meanH2,
                                  rate: bpsk, pilotIndex: 0)
        let signalBits = viterbi(signalSoft, puncturing: .r12)
        guard signalBits.count >= 24 else { return .failed }
        let code = UInt8(signalBits[0]) | UInt8(signalBits[1]) << 1 | UInt8(signalBits[2]) << 2 | UInt8(signalBits[3]) << 3
        var length = 0
        for i in 0..<12 { length |= Int(signalBits[5 + i]) << i }
        let parity = signalBits[0..<18].reduce(0) { $0 ^ Int($1) }
        guard let rate = WLANOFDM.rate(code: code), signalBits[4] == 0, parity == 0,
              signalBits[18..<24].allSatisfy({ $0 == 0 }), length > 4 else {
            signalErrors += 1
            return .failed
        }
        let symbols = WLANOFDM.symbolCount(length: length, rate: rate)
        guard symbols <= Self.maximumSymbols else { signalErrors += 1; return .failed }
        let endSample = ltfStart + 128 + 80 * (1 + symbols)
        guard endSample <= count else { return .needMore }

        // Daten.
        var soft: [Int8] = []
        soft.reserveCapacity(symbols * rate.codedBitsPerSymbol)
        for s in 0..<symbols {
            let start = ltfStart + 128 + 80 * (1 + s) + 16 - advance
            soft += softBits(spectrum(re, im, start: start, cfo: cfo), hRe: hRe, hIm: hIm, meanH2: meanH2,
                             rate: rate, pilotIndex: (s + 1) % 127)
        }
        let bits = viterbi(soft, puncturing: rate.puncturing)
        guard bits.count >= 16 + 8 * length else { return .failed }
        // Entwürfeln: die ersten sieben SERVICE-Bits sind 0 → Startzustand.
        var x = [UInt8](repeating: 0, count: bits.count)
        var clear = [UInt8](repeating: 0, count: bits.count)
        for i in 0..<bits.count {
            x[i] = i < 7 ? bits[i] : x[i - 4] ^ x[i - 7]
            clear[i] = bits[i] ^ x[i]
        }
        var mpdu = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            var byte: UInt8 = 0
            for bit in 0..<8 { byte |= clear[16 + 8 * i + bit] << UInt8(bit) }
            mpdu[i] = byte
        }
        guard WLANCRC32.verify(mpdu) else { fcsErrors += 1; return .failed }
        let packet = WLANPacket(modulation: .ofdm, rateMbps: Double(rate.mbps), mpdu: Array(mpdu.dropLast(4)),
                                rssiDB: 10 * log10(Double(max(level, 1e-12))),
                                offsetKHz: Double(cfo) * 20_000, date: Date())
        return .packet(packet, endSample)
    }

    @inline(__always)
    private func rotated(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, _ n: Int, cfo: Float) -> (Float, Float) {
        let phase = -2 * Float.pi * cfo * Float(n)
        let c = cos(phase), s = sin(phase)
        return (re[n] * c - im[n] * s, re[n] * s + im[n] * c)
    }

    /// FFT eines 64er-Fensters ab `start`, Ablage herausgedreht.
    private func spectrum(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, start: Int, cfo: Float) -> (re: [Float], im: [Float]) {
        var inRe = [Float](repeating: 0, count: 64), inIm = [Float](repeating: 0, count: 64)
        for k in 0..<64 { (inRe[k], inIm[k]) = rotated(re, im, start + k, cfo: cfo) }
        var outRe = [Float](repeating: 0, count: 64), outIm = [Float](repeating: 0, count: 64)
        inRe.withUnsafeMutableBufferPointer { ir in
            inIm.withUnsafeMutableBufferPointer { ii in
                outRe.withUnsafeMutableBufferPointer { or in
                    outIm.withUnsafeMutableBufferPointer { oi in
                        var input = DSPSplitComplex(realp: ir.baseAddress!, imagp: ii.baseAddress!)
                        var output = DSPSplitComplex(realp: or.baseAddress!, imagp: oi.baseAddress!)
                        vDSP_fft_zop(fft, &input, 1, &output, 1, 6, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
        }
        return (outRe, outIm)
    }

    /// Entzerrt ein Symbol, führt Phase und Steigung über die Piloten nach und
    /// liefert die weichen Bits in Sendereihenfolge (positiv = 0, wie der
    /// Viterbi sie erwartet), mit |H|² gewichtet.
    private func softBits(_ y: (re: [Float], im: [Float]), hRe: [Float], hIm: [Float], meanH2: Float,
                          rate: WLANOFDM.Rate, pilotIndex: Int) -> [Int8] {
        var zRe = [Float](repeating: 0, count: 64), zIm = [Float](repeating: 0, count: 64), weight = [Float](repeating: 0, count: 64)
        for k in WLANOFDM.usedSubcarriers {
            let i = k & 63
            let h2 = hRe[i] * hRe[i] + hIm[i] * hIm[i]
            guard h2 > meanH2 * 1e-4 else { continue }
            zRe[i] = (y.re[i] * hRe[i] + y.im[i] * hIm[i]) / h2
            zIm[i] = (y.im[i] * hRe[i] - y.re[i] * hIm[i]) / h2
            weight[i] = min(h2 / meanH2, 2)
        }
        // Piloten: gemeinsame Phase und Steigung über den Träger.
        let polarity = WLANOFDM.pilotPolarity[pilotIndex]
        var sumRe: Float = 0, sumIm: Float = 0
        var pilots: [(k: Float, re: Float, im: Float)] = []
        for (j, k) in WLANOFDM.pilotSubcarriers.enumerated() {
            let i = k & 63
            let expected = WLANOFDM.pilotValues[j] * polarity
            let vr = zRe[i] * expected, vi = zIm[i] * expected
            pilots.append((Float(k), vr, vi))
            sumRe += vr * weight[i]
            sumIm += vi * weight[i]
        }
        let common = atan2(sumIm, sumRe)
        var num: Float = 0, den: Float = 0
        for pilot in pilots {
            var d = atan2(pilot.im, pilot.re) - common
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            num += pilot.k * d
            den += pilot.k * pilot.k
        }
        let slope = den > 0 ? num / den : 0

        let scale = WLANOFDM.constellationScale(rate.bitsPerSubcarrier)
        var soft = [Int8](repeating: 0, count: rate.codedBitsPerSymbol)
        let inverse = Self.deinterleavers[rate.mbps] ?? Self.inverse(WLANOFDM.interleaverMap(rate))
        var index = 0
        for k in WLANOFDM.dataSubcarriers {
            let i = k & 63
            let phase = -(common + slope * Float(k))
            let c = cos(phase), s = sin(phase)
            let zr = (zRe[i] * c - zIm[i] * s) * scale
            let zi = (zRe[i] * s + zIm[i] * c) * scale
            let w = weight[i] * 40
            func put(_ value: Float) {
                let v = -value * w                      // 1 = positiv, Viterbi: positiv = 0
                soft[inverse[index]] = Int8(max(-120, min(120, v)))
                index += 1
            }
            switch rate.bitsPerSubcarrier {
            case 1:
                put(zr)
            case 2:
                put(zr); put(zi)
            case 4:
                put(zr); put(2 - abs(zr)); put(zi); put(2 - abs(zi))
            default:
                put(zr); put(4 - abs(zr)); put(2 - abs(abs(zr) - 4))
                put(zi); put(4 - abs(zi)); put(2 - abs(abs(zi) - 4))
            }
        }
        return soft
    }

    /// Umkehrung der Verschachtelung: empfangene Position → kodiertes Bit.
    private static func inverse(_ map: [Int]) -> [Int] {
        var inverse = [Int](repeating: 0, count: map.count)
        for (k, j) in map.enumerated() { inverse[j] = k }
        return inverse
    }

    private static let deinterleavers: [Int: [Int]] = Dictionary(uniqueKeysWithValues: WLANOFDM.rates.map { ($0.mbps, inverse(WLANOFDM.interleaverMap($0))) })

    /// Entpunktieren und Viterbi; 802.11 sendet A (133) vor B (171), der
    /// Dekoder erwartet (171, 133).
    private func viterbi(_ soft: [Int8], puncturing: WLANOFDM.Puncturing) -> [UInt8] {
        var pairs: [Int8] = []
        pairs.reserveCapacity(soft.count * 2)
        switch puncturing {
        case .r12:
            var i = 0
            while i + 1 < soft.count { pairs.append(soft[i + 1]); pairs.append(soft[i]); i += 2 }
        case .r23:
            var i = 0
            while i + 2 < soft.count {
                pairs.append(soft[i + 1]); pairs.append(soft[i])
                pairs.append(0); pairs.append(soft[i + 2])
                i += 3
            }
        case .r34:
            var i = 0
            while i + 3 < soft.count {
                pairs.append(soft[i + 1]); pairs.append(soft[i])
                pairs.append(0); pairs.append(soft[i + 2])
                pairs.append(soft[i + 3]); pairs.append(0)
                i += 4
            }
        }
        let decoder = MeteorViterbi()
        return pairs.withUnsafeBufferPointer { decoder.decode($0, flush: true) }
    }
}
