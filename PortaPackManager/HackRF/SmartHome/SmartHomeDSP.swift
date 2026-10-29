import Accelerate
import Foundation

/// Die vier Kanäle der Smart-Home-Seite. Alle liegen gleichzeitig im
/// Empfangsfenster (4 MS/s um 868,75 MHz).
enum SmartHomeChannel: Int, CaseIterable, Sendable, Hashable {
    /// 868,30 MHz: Homematic (BidCoS, 10 kbit/s FSK) und EnOcean (125 kbit/s ASK).
    case srd868_3
    /// 868,42 MHz: Z-Wave R1 (9,6 kbit/s Manchester) und R2 (40 kbit/s NRZ).
    case zwave
    /// 868,95 MHz: Wireless M-Bus T1 und C1.
    case wmbus
    /// 869,85 MHz: Z-Wave R3 (100 kbit/s).
    case zwaveR3

    var frequencyHz: Double {
        switch self {
        case .srd868_3: 868_300_000
        case .zwave: 868_420_000
        case .wmbus: 868_950_000
        case .zwaveR3: 869_850_000
        }
    }

    var frequencyMHz: Double { frequencyHz / 1e6 }
}

/// Ein Funkstoß auf einem Kanal: komplexes Basisband bei 400 kS/s. `signal`
/// ist der Bereich, in dem der Pegel über der Schwelle lag (davor und
/// danach etwas Rauschen als Vor- und Nachlauf).
struct SmartHomeBurst: Sendable {
    let channel: SmartHomeChannel
    var re: [Float]
    var im: [Float]
    var signal: Range<Int>
    var date: Date
    /// Mittlere Leistung im Stoß und Rauschen davor, dBFS.
    var powerDB: Double
    var noiseDB: Double
    var snrDB: Double { powerDB - noiseDB }
}

/// Empfangskette: HackRF bei 4 MS/s, Mitte 868,75 MHz. Je Kanal
/// herausmischen (Oszillator als Tabelle), in zwei Stufen ÷5 und ÷2 auf
/// 400 kS/s dezimieren (41 und 51 Abgriffe über `vDSP_desamp`) und dort
/// Funkstöße suchen. Erst die Stöße laufen durch die Dekoder – die meiste
/// Zeit ist Ruhe, und die Dekoder kosten dann nichts.
///
/// Die Mitte liegt so, dass die Gleichspannungsspitze des HackRF in keinen
/// Kanal fällt (−450, −330, +200, +1100 kHz) und Z-Wave R3 auf 869,85 MHz
/// noch sicher im Basisbandfilter liegt (3,5 MHz statt der sonst gewählten 2,5).
final class SmartHomeFrontEnd: @unchecked Sendable {
    static let inputRate = 4_000_000.0
    static let centerHz = 868_750_000.0
    static let channelRate = 400_000.0
    static let basebandFilterHz: UInt32 = 3_500_000

    /// Welche Kanäle verarbeitet werden (abgewählte kosten keine Rechenzeit).
    var enabled: Set<SmartHomeChannel> = Set(SmartHomeChannel.allCases)

    private var paths: [SmartHomeChannel: ChannelPath] = [:]
    private var inRe: [Float] = []
    private var inIm: [Float] = []

    init() {
        for channel in SmartHomeChannel.allCases {
            paths[channel] = ChannelPath(channel: channel, offsetHz: channel.frequencyHz - Self.centerHz)
        }
    }

    func reset() {
        for path in paths.values { path.reset() }
    }

    /// Rauschpegel je Kanal (dBFS) für die Anzeige.
    func noiseDB(_ channel: SmartHomeChannel) -> Double { paths[channel]?.detector.noiseDB ?? -100 }

    /// IQ-Block vom HackRF (int8, 4 MS/s).
    func process(_ iq: Data, date: Date = Date()) -> [SmartHomeBurst] {
        let count = iq.count / 2
        guard count > 0 else { return [] }
        if inRe.count != count {
            inRe = [Float](repeating: 0, count: count)
            inIm = [Float](repeating: 0, count: count)
        }
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            inRe.withUnsafeMutableBufferPointer { r in
                vDSP_vflt8(p.baseAddress!, 2, r.baseAddress!, 1, vDSP_Length(count))
            }
            inIm.withUnsafeMutableBufferPointer { i in
                vDSP_vflt8(p.baseAddress! + 1, 2, i.baseAddress!, 1, vDSP_Length(count))
            }
        }
        var bursts: [SmartHomeBurst] = []
        for channel in SmartHomeChannel.allCases where enabled.contains(channel) {
            guard let path = paths[channel] else { continue }
            bursts += path.process(re: inRe, im: inIm, date: date)
        }
        return bursts
    }

    /// Ein Kanal: Mischer, Dezimierer, Stoßsucher.
    final class ChannelPath {
        let channel: SmartHomeChannel
        private let period: Int
        private var oscRe: [Float] = []
        private var oscIm: [Float] = []
        private let step: Double
        private var phase = 0
        private let stage1: [Float]
        private let stage2: [Float]
        private var h1Re: [Float] = [], h1Im: [Float] = []
        private var h2Re: [Float] = [], h2Im: [Float] = []
        private var mixRe: [Float] = []
        private var mixIm: [Float] = []
        let detector: SmartHomeBurstDetector

        init(channel: SmartHomeChannel, offsetHz: Double) {
            self.channel = channel
            // Periode der Oszillatortabelle: kleinstes n mit n·f/fs ganzzahlig.
            let ratio = offsetHz / SmartHomeFrontEnd.inputRate
            var n = 1
            while n < 4000, abs((ratio * Double(n)).rounded() - ratio * Double(n)) > 1e-9 { n += 1 }
            period = n
            step = -2 * Double.pi * ratio
            // ÷5: Durchlass bis 160 kHz, Sperre ab 640 kHz (fällt dort auf ±160 zurück).
            stage1 = RadioDemodulator.lowpass(taps: 41, cutoff: 360_000, rate: SmartHomeFrontEnd.inputRate)
            // ÷2: Durchlass bis 160 kHz, Sperre ab 240 kHz.
            stage2 = RadioDemodulator.lowpass(taps: 51, cutoff: 195_000, rate: SmartHomeFrontEnd.inputRate / 5)
            detector = SmartHomeBurstDetector(channel: channel)
        }

        func reset() {
            phase = 0
            h1Re = []; h1Im = []; h2Re = []; h2Im = []
            detector.reset()
        }

        /// Tabelle lang genug für `count` Werte ab jeder Phase; Amplitude 1/128
        /// rechnet die int8-Werte gleich mit in Vollaussteuerung um.
        private func ensureTable(_ count: Int) {
            let needed = ((count + period) / period + 1) * period
            guard oscRe.count < needed else { return }
            oscRe = (0..<needed).map { Float(cos(step * Double($0 % period)) / 128) }
            oscIm = (0..<needed).map { Float(sin(step * Double($0 % period)) / 128) }
        }

        func process(re: [Float], im: [Float], date: Date) -> [SmartHomeBurst] {
            let count = re.count
            ensureTable(count)
            if mixRe.count != count {
                mixRe = [Float](repeating: 0, count: count)
                mixIm = [Float](repeating: 0, count: count)
            }
            let start = phase
            re.withUnsafeBufferPointer { ar in
                im.withUnsafeBufferPointer { ai in
                    oscRe.withUnsafeBufferPointer { br in
                        oscIm.withUnsafeBufferPointer { bi in
                            mixRe.withUnsafeMutableBufferPointer { cr in
                                mixIm.withUnsafeMutableBufferPointer { ci in
                                    var a = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: ar.baseAddress!),
                                                            imagp: UnsafeMutablePointer(mutating: ai.baseAddress!))
                                    var b = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: br.baseAddress! + start),
                                                            imagp: UnsafeMutablePointer(mutating: bi.baseAddress! + start))
                                    var c = DSPSplitComplex(realp: cr.baseAddress!, imagp: ci.baseAddress!)
                                    vDSP_zvmul(&a, 1, &b, 1, &c, 1, vDSP_Length(count), 1)
                                }
                            }
                        }
                    }
                }
            }
            phase = (phase + count) % period
            let (r1, i1) = RadioDemodulator.decimateComplex(mixRe, mixIm, history: &h1Re, &h1Im, filter: stage1, factor: 5)
            let (r2, i2) = RadioDemodulator.decimateComplex(r1, i1, history: &h2Re, &h2Im, filter: stage2, factor: 2)
            return detector.process(re: r2, im: i2, date: date)
        }
    }
}

/// Sucht Funkstöße im Kanal (400 kS/s): Leistung über ≈ 80 µs geglättet
/// (Schwankung des Rauschens dann ≈ ±20 %), Rauschen sehr träge in Ruhe
/// nachgeführt. Start ab 6 dB über dem Rauschen, Ende, wenn der Pegel
/// 0,6 ms lang unter 3 dB bleibt. Ein Dauerträger
/// (länger als 0,6 s) wird abgegeben und hebt die Rauschschätzung an.
final class SmartHomeBurstDetector {
    static let preRoll = 400            // 1 ms Vorlauf
    static let hangover = 240           // 0,6 ms
    static let maxLength = 240_000      // 0,6 s (Homematic-Weckfolgen sind bis 0,36 s lang)
    static let minLength = 160          // 0,4 ms
    static let startRatio: Float = 4    // 6 dB
    static let endRatio: Float = 2      // 3 dB
    static let minPower: Float = 1e-6   // −60 dBFS

    let channel: SmartHomeChannel
    private var noise: Float = 0
    private var smooth: Float = 0
    private var warmup = 0
    private var active = false
    private var below = 0
    private var ringRe = [Float](repeating: 0, count: preRoll)
    private var ringIm = [Float](repeating: 0, count: preRoll)
    private var ringPos = 0
    private var bRe: [Float] = []
    private var bIm: [Float] = []
    private var powerSum: Double = 0
    private var powerCount = 0
    private var startDate = Date()

    init(channel: SmartHomeChannel) { self.channel = channel }

    var noiseDB: Double { 10 * log10(Double(max(noise, 1e-12))) }

    func reset() {
        noise = 0; smooth = 0; warmup = 0
        active = false; below = 0
        bRe = []; bIm = []
    }

    func process(re: [Float], im: [Float], date: Date) -> [SmartHomeBurst] {
        var out: [SmartHomeBurst] = []
        let n = re.count
        for k in 0..<n {
            let r = re[k], i = im[k]
            let p = r * r + i * i
            smooth += (p - smooth) * 0.03125
            if warmup < 2000 {
                // Erste 5 ms: Rauschen schnell einlernen.
                warmup += 1
                noise += (smooth - noise) * 0.01
                push(r, i)
                continue
            }
            if !active {
                if smooth > noise * Self.startRatio && smooth > Self.minPower {
                    active = true
                    below = 0
                    powerSum = 0
                    powerCount = 0
                    // Vorlauf aus dem Ringpuffer in zeitlicher Reihenfolge.
                    bRe = Array(ringRe[ringPos...]) + Array(ringRe[..<ringPos])
                    bIm = Array(ringIm[ringPos...]) + Array(ringIm[..<ringPos])
                    bRe.reserveCapacity(20_000); bIm.reserveCapacity(20_000)
                    // Zeitpunkt: Blockzeit minus der noch folgenden Abtastwerte.
                    startDate = date.addingTimeInterval(-Double(n - k) / SmartHomeFrontEnd.channelRate)
                    bRe.append(r); bIm.append(i)
                } else {
                    noise += (smooth - noise) / 8192
                    push(r, i)
                }
            } else {
                bRe.append(r); bIm.append(i)
                if smooth < noise * Self.endRatio {
                    below += 1
                    if below >= Self.hangover {
                        if let burst = finish(trim: below - 40) { out.append(burst) }
                        active = false
                    }
                } else {
                    below = 0
                    powerSum += Double(p)
                    powerCount += 1
                    if bRe.count >= Self.maxLength {
                        // Dauerträger: abgeben und als Rauschen übernehmen.
                        let mean = Float(powerSum / Double(max(powerCount, 1)))
                        if let burst = finish(trim: 0) { out.append(burst) }
                        active = false
                        noise = max(noise, mean / 2)
                    }
                }
            }
        }
        return out
    }

    private func push(_ r: Float, _ i: Float) {
        ringRe[ringPos] = r
        ringIm[ringPos] = i
        ringPos += 1
        if ringPos == Self.preRoll { ringPos = 0 }
    }

    private func finish(trim: Int) -> SmartHomeBurst? {
        defer { bRe = []; bIm = [] }
        if trim > 0 && trim < bRe.count {
            bRe.removeLast(trim)
            bIm.removeLast(trim)
        }
        let signalEnd = max(Self.preRoll, bRe.count - 40)
        guard signalEnd - Self.preRoll >= Self.minLength, powerCount > 0 else { return nil }
        let power = 10 * log10(max(powerSum / Double(powerCount), 1e-12))
        return SmartHomeBurst(channel: channel, re: bRe, im: bIm, signal: Self.preRoll..<signalEnd,
                              date: startDate, powerDB: power, noiseDB: noiseDB)
    }
}

/// Bitgewinnung aus einem Funkstoß – für alle Funkarten gleich: Frequenz
/// (FSK) bzw. Betrag (ASK), Mittelwert über ein Bit als Optimalfilter,
/// Schwelle aus den Häufungen beider Symbole, Takt aus den Nulldurchgängen.
enum SmartHomeDemod {
    /// Gleitendes Mittel über `length` Werte (Ausgang gleich lang, Verzögerung `length − 1`).
    static func movingAverage(_ x: [Float], length: Int) -> [Float] {
        guard length > 1, x.count > length else { return x }
        var out = [Float](repeating: 0, count: x.count)
        var sum: Float = 0
        let scale = 1 / Float(length)
        for n in 0..<x.count {
            sum += x[n]
            if n >= length { sum -= x[n - length] }
            out[n] = sum * scale
        }
        return out
    }

    /// Momentanfrequenz in rad je Abtastwert; `smooth` mittelt vorher das IQ
    /// (schmaleres Filter für langsame Funkarten).
    static func frequency(re: [Float], im: [Float], smooth: Int = 1) -> [Float] {
        let r = movingAverage(re, length: smooth)
        let i = movingAverage(im, length: smooth)
        guard r.count > 1 else { return [] }
        var out = [Float](repeating: 0, count: r.count)
        for n in 1..<r.count {
            out[n] = atan2f(i[n] * r[n - 1] - r[n] * i[n - 1], r[n] * r[n - 1] + i[n] * i[n - 1])
        }
        out[0] = out[1]
        return out
    }

    static func amplitude(re: [Float], im: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: re.count)
        for n in re.indices { out[n] = (re[n] * re[n] + im[n] * im[n]).squareRoot() }
        return out
    }

    /// Schwelle zwischen beiden Symbolen: Mitte zwischen 10- und 90-%-Quantil.
    static func threshold(_ x: [Float], range: Range<Int>) -> Float {
        let range = range.clamped(to: x.indices)
        guard !range.isEmpty else { return 0 }
        let stride = max(1, range.count / 4096)
        var sample: [Float] = []
        sample.reserveCapacity(range.count / stride + 1)
        var n = range.lowerBound
        while n < range.upperBound { sample.append(x[n]); n += stride }
        sample.sort()
        return (sample[sample.count / 10] + sample[sample.count * 9 / 10]) / 2
    }

    /// Hub (Abstand der beiden Häufungen) im Bereich – zum Aussortieren von Rauschen.
    static func spread(_ x: [Float], range: Range<Int>) -> Float {
        let range = range.clamped(to: x.indices)
        guard range.count > 10 else { return 0 }
        let stride = max(1, range.count / 4096)
        var sample: [Float] = []
        var n = range.lowerBound
        while n < range.upperBound { sample.append(x[n]); n += stride }
        sample.sort()
        return sample[sample.count * 9 / 10] - sample[sample.count / 10]
    }

    /// Bits mit Taktrückgewinnung: Abtastung eine halbe Bitdauer nach jedem
    /// Nulldurchgang, der Takt wird bei jedem Durchgang zu 20 % nachgeführt.
    /// `x` sollte über eine Bitdauer gemittelt sein – dann liegt der
    /// Nulldurchgang mitten zwischen den Abtastpunkten.
    static func slice(_ x: [Float], range: Range<Int>, threshold: Float, samplesPerBit sps: Double,
                      gain: Double = 0.2) -> [UInt8] {
        let range = range.clamped(to: x.indices)
        guard range.count > 2 else { return [] }
        var bits: [UInt8] = []
        bits.reserveCapacity(Int(Double(range.count) / sps) + 2)
        var next = 0.0
        var locked = false
        var prev = x[range.lowerBound] - threshold
        for n in (range.lowerBound + 1)..<range.upperBound {
            let v = x[n] - threshold
            if (v > 0) != (prev > 0) {
                let crossing = Double(n - 1) + Double(prev / (prev - v))
                if !locked {
                    next = crossing + sps / 2
                    locked = true
                } else {
                    var error = crossing - (next - sps / 2)
                    error -= sps * (error / sps).rounded()
                    next += gain * error
                }
            }
            while locked && Double(n) >= next {
                let i = Int(next)
                let f = Float(next - Double(i))
                let s = i + 1 < x.count ? x[i] + (x[i + 1] - x[i]) * f : x[i]
                bits.append(s > threshold ? 1 : 0)
                next += sps
            }
            prev = v
        }
        return bits
    }

    /// Alle Fundstellen von `pattern` (Index nach dem Muster).
    static func find(_ pattern: [UInt8], in bits: [UInt8], limit: Int = 8) -> [Int] {
        guard !pattern.isEmpty, bits.count >= pattern.count else { return [] }
        var found: [Int] = []
        let last = bits.count - pattern.count
        var n = 0
        outer: while n <= last {
            for k in 0..<pattern.count where bits[n + k] != pattern[k] {
                n += 1
                continue outer
            }
            found.append(n + pattern.count)
            if found.count >= limit { break }
            n += pattern.count
        }
        return found
    }

    static func bits(of bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 8)
        for byte in bytes { for k in 0..<8 { out.append((byte >> (7 - k)) & 1) } }
        return out
    }

    /// Bytes ab Bitposition `from`, MSB zuerst; `nil`, wenn die Bits nicht reichen.
    static func bytes(_ bits: [UInt8], from: Int, count: Int) -> [UInt8]? {
        guard from >= 0, from + count * 8 <= bits.count else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        for k in 0..<count {
            var byte: UInt8 = 0
            for b in 0..<8 { byte = byte << 1 | bits[from + k * 8 + b] }
            out[k] = byte
        }
        return out
    }

    static func inverted(_ bits: [UInt8]) -> [UInt8] { bits.map { $0 ^ 1 } }

    /// Komplexes Tiefpassfilter (63 Abgriffe) über einen Stoß; Verzögerung 31 Abtastwerte.
    static let lowpassDelay = 31
    static func lowpass(re: [Float], im: [Float], cutoffHz: Double) -> ([Float], [Float]) {
        let taps = RadioDemodulator.lowpass(taps: 2 * lowpassDelay + 1, cutoff: cutoffHz, rate: SmartHomeFrontEnd.channelRate)
        var hRe: [Float] = [], hIm: [Float] = []
        return RadioDemodulator.decimateComplex(re, im, history: &hRe, &hIm, filter: taps, factor: 1)
    }

    /// FSK-Bits eines Stoßes in beiden Polaritäten (welche Frequenz „1“ ist,
    /// unterscheidet sich je Hersteller; das Sync-Wort entscheidet).
    /// `cutoffHz`: zusätzliches Kanalfilter für schmale Funkarten – hält den
    /// Nachbarn 120 kHz daneben heraus (Homematic ↔ Z-Wave).
    static func fskBits(_ burst: SmartHomeBurst, samplesPerBit sps: Double, cutoffHz: Double? = nil) -> [[UInt8]] {
        var re = burst.re, im = burst.im
        var delay = 0
        var ranges = [burst.signal]
        if let cutoffHz {
            (re, im) = lowpass(re: re, im: im, cutoffHz: cutoffHz)
            delay = lowpassDelay
            // Im schmalen Kanal neu abgrenzen: ein Nachbar im breiten Kanal
            // verlängert den Stoß, und die Schwelle stimmte dann nicht mehr.
            ranges = activeRanges(re: re, im: im, minLength: Int(20 * sps))
        }
        let fm = frequency(re: re, im: im)
        let filtered = movingAverage(fm, length: max(1, Int(sps.rounded())))
        var out: [[UInt8]] = []
        for range in ranges {
            // Signalbereich um die Filterverzögerung verschoben.
            let shift = (cutoffHz == nil ? delay : 0) + Int(sps.rounded()) / 2
            let shifted = (range.lowerBound + shift)..<(range.upperBound + shift)
            let threshold = threshold(filtered, range: shifted)
            let bits = slice(filtered, range: shifted, threshold: threshold, samplesPerBit: sps)
            out += [bits, inverted(bits)]
        }
        return out
    }

    /// Bereiche, in denen das (gefilterte) Signal höchstens 10 dB unter dem
    /// Spitzenpegel liegt – Lücken bis 0,25 ms werden überbrückt. Höchstens vier,
    /// die längsten zuerst.
    static func activeRanges(re: [Float], im: [Float], minLength: Int) -> [Range<Int>] {
        var power = [Float](repeating: 0, count: re.count)
        for n in re.indices { power[n] = re[n] * re[n] + im[n] * im[n] }
        let smooth = movingAverage(power, length: 32)
        guard let peak = smooth.max(), peak > 0 else { return [] }
        let level = peak / 10
        var ranges: [Range<Int>] = []
        var start: Int?
        var lastHigh = 0
        for n in smooth.indices {
            if smooth[n] > level {
                if start == nil { start = n }
                lastHigh = n
            } else if let s = start, n - lastHigh > 100 {
                ranges.append(s..<(lastHigh + 1))
                start = nil
            }
        }
        if let s = start { ranges.append(s..<(lastHigh + 1)) }
        // Gleitendes Mittel verzögert um 16 – zurückschieben.
        return ranges.map { max(0, $0.lowerBound - 16)..<max(0, $0.upperBound - 16) }
            .filter { $0.count >= minLength }
            .sorted { $0.count > $1.count }
            .prefix(4).map { $0 }
    }

    /// ASK-Bits (Träger an = 1) eines Stoßes.
    static func askBits(_ burst: SmartHomeBurst, samplesPerBit sps: Double) -> [UInt8] {
        let amp = movingAverage(amplitude(re: burst.re, im: burst.im), length: max(1, Int(sps)))
        // Schwelle zwischen Rauschen (Vorlauf) und Trägerpegel im Stoß.
        let pre = min(burst.signal.lowerBound, amp.count)
        let low = pre > 10 ? amp[0..<pre].sorted()[pre / 2] : 0
        let signal = burst.signal.clamped(to: amp.indices)
        guard !signal.isEmpty else { return [] }
        let sorted = amp[signal].sorted()
        let high = sorted[sorted.count * 9 / 10]
        let level = (low + high) / 2
        let start = max(0, burst.signal.lowerBound - 20)
        return slice(amp, range: start..<min(amp.count, burst.signal.upperBound + 20),
                     threshold: level, samplesPerBit: sps)
    }
}
