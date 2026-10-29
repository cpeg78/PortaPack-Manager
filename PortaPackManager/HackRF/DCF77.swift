import Accelerate
import Foundation

/// Zeitzeichensender DCF77 (77,5 kHz, Mainflingen bei Frankfurt). Amplituden-
/// modulation: zu Beginn jeder Sekunde sinkt der Träger auf 15 % – 100 ms lang
/// für eine 0, 200 ms für eine 1; in Sekunde 59 bleibt die Absenkung aus
/// (Minutenmarke). Die 59 Bits einer Minute tragen die Zeit der **folgenden**
/// Minute (BCD, drei Paritätsbits). In einer Minute mit Schaltsekunde (Bit 19
/// kündigt sie eine Stunde vorher an) folgt auf Bit 58 noch eine Sekunde 59 mit
/// einer 0, die Marke liegt dann in Sekunde 60. Die zusätzliche Phasenmodulation (Pseudo-
/// zufallsfolge, ±13°) und die verschlüsselten Wetterdaten (Bits 1–14) werden
/// nicht ausgewertet.
enum DCF77Code {
    static let frequencyHz = 77_500.0
    static let weekdays = ["", String(localized: "Montag"), String(localized: "Dienstag"), String(localized: "Mittwoch"),
                            String(localized: "Donnerstag"), String(localized: "Freitag"), String(localized: "Samstag"),
                            String(localized: "Sonntag")]

    struct Time: Sendable, Equatable {
        var minute = 0, hour = 0, day = 1, weekday = 1, month = 1, year = 0
        /// Bit 17 (MESZ) / Bit 18 (MEZ) – genau eines ist gesetzt.
        var cest = false, cet = true
        /// Bit 15: Rufbit (Störung/Alarm beim Betreiber).
        var callBit = false
        /// Bit 16: in der kommenden Stunde wechselt die Zeitzone.
        var summerTimeChange = false
        /// Bit 19: zum Ende der Stunde wird eine Schaltsekunde eingefügt.
        var leapSecondAnnounced = false
        /// Bits 1–14, verschlüsselte Wetter-/Katastrophenschutzdaten (Rohwert, Bit 1 unten).
        var civil: UInt16 = 0

        var timeZone: TimeZone { TimeZone(secondsFromGMT: cest ? 7200 : 3600)! }
        var zoneName: String { cest ? String(localized: "MESZ") : String(localized: "MEZ") }
        var weekdayName: String { (1...7).contains(weekday) ? DCF77Code.weekdays[weekday] : "?" }

        var date: Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(from: DateComponents(year: 2000 + year, month: month, day: day,
                                                      hour: hour, minute: minute, second: 0))
        }
    }

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case length, startBit, timeStartBit, minuteParity, hourParity, dateParity, range

        var description: String {
            switch self {
            case .length: String(localized: "nicht 59 Bits")
            case .startBit: String(localized: "Bit 0 ist nicht 0")
            case .timeStartBit: String(localized: "Bit 20 ist nicht 1")
            case .minuteParity: String(localized: "Prüfbit der Minute falsch")
            case .hourParity: String(localized: "Prüfbit der Stunde falsch")
            case .dateParity: String(localized: "Prüfbit des Datums falsch")
            case .range: String(localized: "Wert außerhalb des Bereichs")
            }
        }
    }

    private static let weights = [1, 2, 4, 8, 10, 20, 40, 80]

    private static func bcd(_ bits: ArraySlice<UInt8>) -> Int {
        zip(bits, weights).reduce(0) { $0 + ($1.0 == 1 ? $1.1 : 0) }
    }

    private static func bcdBits(_ value: Int, count: Int) -> [UInt8] {
        let low = value % 10, high = value / 10
        return (0..<count).map { k in
            k < 4 ? UInt8((low >> k) & 1) : UInt8((high >> (k - 4)) & 1)
        }
    }

    private static func parityEven(_ bits: ArraySlice<UInt8>) -> Bool {
        bits.reduce(0) { $0 + Int($1) } % 2 == 0
    }

    /// 59 Bits (Sekunden 0–58) → Zeit der folgenden Minute. 60 Bits nur in
    /// einer Minute mit Schaltsekunde: Bit 59 muss 0 sein, die folgende Minute
    /// eine volle Stunde, und die Schaltsekunde muss angekündigt sein (Bit 19
    /// in dieser oder `announced` aus der vorigen Minute).
    static func decode(_ bits: [UInt8], leapAnnounced announced: Bool = false) -> Result<Time, DecodeError> {
        if bits.count == 60 {
            guard bits[59] == 0 else { return .failure(.length) }
            let time = decode(Array(bits.prefix(59)))
            guard case .success(let t) = time else { return time }
            guard t.minute == 0, t.leapSecondAnnounced || announced else { return .failure(.length) }
            return time
        }
        guard bits.count == 59 else { return .failure(.length) }
        guard bits[0] == 0 else { return .failure(.startBit) }
        guard bits[20] == 1 else { return .failure(.timeStartBit) }
        guard parityEven(bits[21...28]) else { return .failure(.minuteParity) }
        guard parityEven(bits[29...35]) else { return .failure(.hourParity) }
        guard parityEven(bits[36...58]) else { return .failure(.dateParity) }
        var time = Time()
        time.minute = bcd(bits[21...27])
        time.hour = bcd(bits[29...34])
        time.day = bcd(bits[36...41])
        time.weekday = bcd(bits[42...44])
        time.month = bcd(bits[45...49])
        time.year = bcd(bits[50...57])
        time.callBit = bits[15] == 1
        time.summerTimeChange = bits[16] == 1
        time.cest = bits[17] == 1
        time.cet = bits[18] == 1
        time.leapSecondAnnounced = bits[19] == 1
        time.civil = (1...14).reduce(0) { $0 | (UInt16(bits[$1]) << ($1 - 1)) }
        guard (0...59).contains(time.minute), (0...23).contains(time.hour),
              (1...31).contains(time.day), (1...7).contains(time.weekday),
              (1...12).contains(time.month), time.cest != time.cet else { return .failure(.range) }
        return .success(time)
    }

    /// Umkehrung von `decode` – für Tests und den Testsender.
    static func encode(_ time: Time) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 59)
        for k in 1...14 { bits[k] = UInt8((time.civil >> (k - 1)) & 1) }
        bits[15] = time.callBit ? 1 : 0
        bits[16] = time.summerTimeChange ? 1 : 0
        bits[17] = time.cest ? 1 : 0
        bits[18] = time.cet ? 1 : 0
        bits[19] = time.leapSecondAnnounced ? 1 : 0
        bits[20] = 1
        bits.replaceSubrange(21...27, with: bcdBits(time.minute, count: 7))
        bits[28] = parityEven(bits[21...27]) ? 0 : 1
        bits.replaceSubrange(29...34, with: bcdBits(time.hour, count: 6))
        bits[35] = parityEven(bits[29...34]) ? 0 : 1
        bits.replaceSubrange(36...41, with: bcdBits(time.day, count: 6))
        bits.replaceSubrange(42...44, with: bcdBits(time.weekday, count: 3))
        bits.replaceSubrange(45...49, with: bcdBits(time.month, count: 5))
        bits.replaceSubrange(50...57, with: bcdBits(time.year, count: 8))
        bits[58] = parityEven(bits[36...57]) ? 0 : 1
        return bits
    }
}

/// Vom IQ-Strom zur Hüllkurve: HackRF 2 MS/s, abgestimmt 200 kHz **über** dem
/// Sender (DC-Spitze außerhalb), Mischer mit Periode 10, dann drei FIR-Stufen
/// ÷10 auf 2 kS/s, eine vierte ÷20 auf 100 S/s (±40 Hz, die Phasenmodulation
/// bei ±650 Hz fällt heraus), Betrag = Hüllkurve mit 10 ms Raster. Auf dem
/// 2-kS/s-Signal werden einmal je Sekunde Trägerablage und Rauschabstand per
/// DFT geschätzt.
///
/// Der HackRF ist unter 1 MHz außerhalb seines Datenblatts (Mischer-LO
/// 2,6 GHz + f, das geht bis 0 Hz, nur die Empfindlichkeit sinkt). Ob der
/// Pegel reicht, zeigt der Rauschabstand.
final class DCF77Demodulator {
    static let inputRate = 2_000_000.0
    static let offset = 200_000.0
    static let envelopeRate = 100.0
    static let mixerPeriod = 10

    private struct Stage {
        let factor: Int
        let taps: [Float]
        var carryRe: [Float] = []
        var carryIm: [Float] = []

        mutating func run(_ re: [Float], _ im: [Float]) -> (re: [Float], im: [Float]) {
            var allRe = carryRe + re, allIm = carryIm + im
            guard allRe.count >= taps.count else { carryRe = allRe; carryIm = allIm; return ([], []) }
            let outCount = (allRe.count - taps.count) / factor + 1
            var outRe = [Float](repeating: 0, count: outCount)
            var outIm = [Float](repeating: 0, count: outCount)
            vDSP_desamp(allRe, vDSP_Stride(factor), taps, &outRe, vDSP_Length(outCount), vDSP_Length(taps.count))
            vDSP_desamp(allIm, vDSP_Stride(factor), taps, &outIm, vDSP_Length(outCount), vDSP_Length(taps.count))
            allRe.removeFirst(outCount * factor)
            allIm.removeFirst(outCount * factor)
            carryRe = allRe; carryIm = allIm
            return (outRe, outIm)
        }
    }

    private static func taps(count: Int, cutoff: Double) -> [Float] {
        var taps = (0..<count).map { n -> Float in
            let k = Double(n - count / 2)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * k) / (.pi * k)
            return Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(count - 1))))
        }
        let sum = taps.reduce(0, +)
        for n in taps.indices { taps[n] /= sum }
        return taps
    }

    /// (Teiler, Tap-Zahl, Grenzfrequenz relativ zur Eingangsrate der Stufe).
    private static let design: [(factor: Int, count: Int, cutoff: Double)] = [
        (10, 61, 0.03),   // 2 MS/s → 200 kS/s, ±60 kHz
        (10, 61, 0.03),   // → 20 kS/s, ±6 kHz
        (10, 61, 0.03),   // → 2 kS/s, ±600 Hz
        (20, 121, 0.02),  // → 100 S/s, ±40 Hz
    ]

    /// Gruppenlaufzeit aller Stufen (für die Zeitmarke der Sekunden).
    static let groupDelay: TimeInterval = {
        var rate = inputRate, delay = 0.0
        for stage in design {
            delay += Double(stage.count - 1) / 2 / rate
            rate /= Double(stage.factor)
        }
        return delay + 0.5 / envelopeRate
    }()

    private var stages: [Stage]
    private var mixerPhase = 0
    private let mixCos: [Float]
    private let mixSin: [Float]
    private var spectrumRe: [Float] = []
    private var spectrumIm: [Float] = []
    private static let spectrumLength = 2048

    private(set) var carrierOffsetHz = 0.0
    private(set) var snrDB = 0.0
    private(set) var levelDBFS = -100.0

    init() {
        stages = Self.design.map { Stage(factor: $0.factor, taps: Self.taps(count: $0.count, cutoff: $0.cutoff)) }
        // Signal liegt bei −200 kHz: mit e^{+j2π·0,1·n} auf 0 Hz drehen.
        mixCos = (0..<Self.mixerPeriod).map { Float(cos(2 * Double.pi * Double($0) / Double(Self.mixerPeriod))) }
        mixSin = (0..<Self.mixerPeriod).map { Float(sin(2 * Double.pi * Double($0) / Double(Self.mixerPeriod))) }
    }

    func reset() {
        for n in stages.indices { stages[n].carryRe = []; stages[n].carryIm = [] }
        mixerPhase = 0
        spectrumRe = []; spectrumIm = []
        carrierOffsetHz = 0; snrDB = 0; levelDBFS = -100
    }

    /// Liefert die Hüllkurve (100 S/s, 1,0 = Vollausschlag des Wandlers).
    func process(_ block: Data) -> [Float] {
        let count = block.count / 2
        guard count > 0 else { return [] }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var phase = mixerPhase
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                let c = mixCos[phase], s = mixSin[phase]
                re[n] = i * c - q * s
                im[n] = i * s + q * c
                phase += 1
                if phase == Self.mixerPeriod { phase = 0 }
            }
        }
        mixerPhase = (mixerPhase + count) % Self.mixerPeriod

        var signal = (re: re, im: im)
        for n in stages.indices {
            signal = stages[n].run(signal.re, signal.im)
            if n == 2 { analyzeCarrier(signal.re, signal.im) }
            if signal.re.isEmpty { return [] }
        }
        var envelope = [Float](repeating: 0, count: signal.re.count)
        for n in envelope.indices {
            envelope[n] = (signal.re[n] * signal.re[n] + signal.im[n] * signal.im[n]).squareRoot()
        }
        return envelope
    }

    /// Einmal je Sekunde (2048 Werte bei 2 kS/s): Spitze im Bereich ±125 Hz,
    /// Rauschabstand zum Median der übrigen Bins, Pegel als RMS.
    private func analyzeCarrier(_ re: [Float], _ im: [Float]) {
        spectrumRe += re
        spectrumIm += im
        let n = Self.spectrumLength
        guard spectrumRe.count >= n else { return }
        let xr = Array(spectrumRe.prefix(n)), xi = Array(spectrumIm.prefix(n))
        spectrumRe.removeFirst(n); spectrumIm.removeFirst(n)

        var sumSquares: Float = 0
        vDSP_svesq(xr, 1, &sumSquares, vDSP_Length(n))
        var sumSquaresIm: Float = 0
        vDSP_svesq(xi, 1, &sumSquaresIm, vDSP_Length(n))
        levelDBFS = 10 * log10(Double(max((sumSquares + sumSquaresIm) / Float(n), 1e-12)))

        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let bins = -128...128
        let rate = Self.inputRate / 1000   // 2 kS/s
        var powers: [Double] = []
        powers.reserveCapacity(bins.count)
        for k in bins {
            let w = -2 * Double.pi * Double(k) / Double(n)
            let cr = Float(cos(w)), ci = Float(sin(w))
            var rotRe: Float = 1, rotIm: Float = 0
            var accRe: Float = 0, accIm: Float = 0
            for t in 0..<n {
                let a = xr[t] * window[t], b = xi[t] * window[t]
                accRe += a * rotRe - b * rotIm
                accIm += a * rotIm + b * rotRe
                let nr = rotRe * cr - rotIm * ci
                rotIm = rotRe * ci + rotIm * cr
                rotRe = nr
            }
            powers.append(Double(accRe * accRe + accIm * accIm))
        }
        guard let peak = powers.indices.max(by: { powers[$0] < powers[$1] }) else { return }
        var offset = Double(peak + bins.lowerBound)
        if peak > 0, peak < powers.count - 1 {
            // Parabelinterpolation um die Spitze (Hann-Fenster: Bruchteil des Bins).
            let a = log(max(powers[peak - 1], 1e-30)), b = log(max(powers[peak], 1e-30)), c = log(max(powers[peak + 1], 1e-30))
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-9 { offset += 0.5 * (a - c) / denominator }
        }
        carrierOffsetHz = offset * rate / Double(n)
        var rest = powers
        rest.removeSubrange(max(0, peak - 3)...min(powers.count - 1, peak + 3))
        rest.sort()
        let median = max(rest[rest.count / 2], 1e-30)
        snrDB = 10 * log10(max(powers[peak], 1e-30) / median)
    }
}

/// Von der Hüllkurve (100 S/s) zur Zeit: Sekundentakt über eine 1-s-Faltung
/// (Mittel je 10-ms-Lage, Kantenmaß 100 ms vor/nach), je Sekunde Dauer der
/// Absenkung unter 55 % des Trägers → 0/1/Minutenmarke; nach der Marke werden
/// 59 Bits dekodiert. Dazu die Abweichung der Rechneruhr: Beginn der Sekunde
/// 0 (Rechnerzeit) gegen die dekodierte Minute.
final class DCF77Decoder {
    static let rate = 100

    struct Second: Identifiable, Sendable, Equatable {
        enum Kind: Sendable { case zero, one, marker, unknown }
        let id: Int
        let kind: Kind
        /// Dauer der Absenkung in ms (0 = Minutenmarke).
        let lowMS: Int
        let date: Date
        /// Sekunde innerhalb der Minute (0–58, 59 = Marke; mit Schaltsekunde
        /// 59 = eingefügte Sekunde, 60 = Marke), nil vor der ersten Marke.
        let index: Int?
    }

    private var buffer: [Float] = []
    private var bufferStart = 0
    private var total = 0
    private var fold = [Float](repeating: 0, count: rate)
    private var foldSamples = 0
    private var nextSecond: Int?
    private var secondCounter = 0
    private var endDate = Date()
    private var delay: TimeInterval = 0
    private var minuteKnown = false
    private var weakSeconds = 0
    /// Hatte die vorige Sekunde eine Absenkung? Eine echte Minutenmarke folgt
    /// immer auf Bit 58 – zwei Sekunden ohne Absenkung hintereinander sind
    /// Störung oder Signalverlust, keine neue Minute.
    private var previousHadDip = false

    private(set) var locked = false
    /// Tiefe der Sekundenmarke relativ zum Träger (0…1), aus der Faltung.
    private(set) var contrast: Float = 0
    private(set) var phase = 0
    private(set) var bits: [UInt8?] = []
    private(set) var seconds: [Second] = []
    private(set) var time: DCF77Code.Time?
    private(set) var timeDate: Date?
    /// Rechneruhr minus Sendezeit; positiv = Rechner geht vor.
    private(set) var clockOffset: TimeInterval?
    private(set) var minutesDecoded = 0
    private(set) var minutesFailed = 0
    /// Minuten mit eingefügter Schaltsekunde (60 Bits), seit dem Start.
    private(set) var leapSeconds = 0
    private(set) var lastError: String?

    func reset() {
        buffer = []; bufferStart = 0; total = 0
        display = []; displaySum = 0; displayCount = 0
        fold = [Float](repeating: 0, count: Self.rate); foldSamples = 0
        nextSecond = nil; secondCounter = 0; minuteKnown = false; weakSeconds = 0; previousHadDip = false
        locked = false; contrast = 0; phase = 0; bits = []; seconds = []
        time = nil; timeDate = nil; clockOffset = nil
        minutesDecoded = 0; minutesFailed = 0; leapSeconds = 0; lastError = nil
    }

    /// Letzte `count` Hüllkurvenwerte (für die Anzeige).
    func recentEnvelope(_ count: Int) -> [Float] { Array(buffer.suffix(count)) }

    /// Anzeigeverlauf: Mittel über je `displayAverage` Werte (40 ms), die letzten
    /// `displaySeconds` Sekunden – ruhiger als die Rohwerte, Absenkungen von
    /// 100/200 ms bleiben deutlich sichtbar.
    static let displayAverage = 4
    static let displaySeconds = 20
    static var displayRate: Int { rate / displayAverage }
    private(set) var display: [Float] = []
    private var displaySum: Float = 0
    private var displayCount = 0

    /// `endDate`: Rechnerzeit des letzten Eingangswerts, `delay`: Gruppenlaufzeit davor.
    func feed(_ samples: [Float], endDate: Date, delay: TimeInterval) {
        guard !samples.isEmpty else { return }
        self.endDate = endDate
        self.delay = delay
        let before = total / Self.rate
        for x in samples {
            let slot = total % Self.rate
            fold[slot] = foldSamples < Self.rate ? x : fold[slot] + 0.08 * (x - fold[slot])
            total += 1
            if foldSamples < 10 * Self.rate { foldSamples += 1 }
        }
        buffer += samples
        for x in samples {
            displaySum += x
            displayCount += 1
            if displayCount == Self.displayAverage {
                display.append(displaySum / Float(displayCount))
                displaySum = 0; displayCount = 0
            }
        }
        let displayLimit = Self.displaySeconds * Self.displayRate
        if display.count > displayLimit + 50 { display.removeFirst(display.count - displayLimit) }
        if total / Self.rate != before, foldSamples >= 5 * Self.rate { updatePhase() }
        evaluateSeconds()
        if let next = nextSecond {
            let keep = next - 20
            if keep > bufferStart {
                buffer.removeFirst(min(buffer.count, keep - bufferStart))
                bufferStart = keep
            }
        } else if buffer.count > 3 * Self.rate {
            let drop = buffer.count - 3 * Self.rate
            buffer.removeFirst(drop); bufferStart += drop
        }
    }

    private func sampleDate(_ index: Int) -> Date {
        endDate.addingTimeInterval(-delay - Double(total - 1 - index) / Double(Self.rate))
    }

    private func edgeScore(_ k: Int) -> Float {
        let r = Self.rate
        var before: Float = 0, after: Float = 0
        for d in 1...10 { before += fold[(k - d + r) % r] }
        for d in 0..<10 { after += fold[(k + d) % r] }
        return (before - after) / 10
    }

    private func updatePhase() {
        let r = Self.rate
        let high = fold.reduce(0, +) / Float(r)
        guard high > 1e-6 else { lose(); return }
        var best = 0, bestScore: Float = -1
        for k in 0..<r {
            let s = edgeScore(k)
            if s > bestScore { bestScore = s; best = k }
        }
        let depth = bestScore / high
        if !locked {
            guard depth > 0.2 else { contrast = depth; return }
            locked = true
            contrast = depth
            phase = best
            // Erste vollständige Sekunde mit etwas Vorlauf im Puffer.
            var start = bufferStart + 10
            start += (phase - start % r + r) % r
            nextSecond = start
            bits = []; minuteKnown = false
            return
        }
        if depth < 0.08 {
            weakSeconds += 1
            if weakSeconds >= 5 { lose() }
            return
        }
        weakSeconds = 0
        contrast = depth
        var shift = best - phase
        if shift > r / 2 { shift -= r } else if shift < -r / 2 { shift += r }
        if shift == 0 { return }
        if abs(shift) <= 3 {
            phase = best
            if let next = nextSecond { nextSecond = next + shift }
        } else if bestScore > 1.5 * edgeScore(phase) {
            phase = best
            if let next = nextSecond { nextSecond = next + shift }
            bits = []; minuteKnown = false
            lastError = String(localized: "Sekundentakt neu gefunden")
        }
    }

    private func lose() {
        locked = false; contrast = 0; weakSeconds = 0
        nextSecond = nil; bits = []; minuteKnown = false; previousHadDip = false
    }

    private func evaluateSeconds() {
        let r = Self.rate
        while let s = nextSecond, s + r <= total {
            let li = s - bufferStart
            guard li >= 5 else { nextSecond = s + r; continue }
            var tail = Array(buffer[(li + 35)..<(li + r)])
            tail.sort()
            let high = tail[tail.count / 2]
            let threshold = 0.55 * high
            var lowMS = 0
            if high > 1e-6 {
                var j = li - 3
                while j < li + 6, buffer[j] >= threshold { j += 1 }
                if j < li + 6 {
                    var n = 0
                    while j + n < li + r, buffer[j + n] < threshold { n += 1 }
                    lowMS = n * 1000 / r
                }
            }
            var kind: Second.Kind
            switch lowMS {
            case 0..<40: kind = previousHadDip ? .marker : .unknown
            case 40...150: kind = .zero
            case 151...280: kind = .one
            default: kind = .unknown
            }
            previousHadDip = lowMS >= 40
            let date = sampleDate(s)
            secondCounter += 1
            var index: Int?
            switch kind {
            case .marker:
                index = minuteKnown ? max(59, bits.count) : nil
                finishMinute(markerDate: date)
            default:
                if minuteKnown { index = bits.count }
                bits.append(kind == .zero ? 0 : kind == .one ? 1 : nil)
                // 60 Bits nur mit Schaltsekunde (prüft `finishMinute`).
                if bits.count > 60 {
                    lastError = String(localized: "Minutenmarke fehlt")
                    bits = []; minuteKnown = false
                    minutesFailed += 1
                }
            }
            seconds.append(Second(id: secondCounter, kind: kind, lowMS: lowMS, date: date, index: index))
            if seconds.count > 120 { seconds.removeFirst(seconds.count - 120) }
            nextSecond = s + r
        }
    }

    private func finishMinute(markerDate: Date) {
        defer { bits = []; minuteKnown = true }
        guard minuteKnown else { return }   // erste, angeschnittene Minute
        guard bits.count == 59 || bits.count == 60 else {
            minutesFailed += 1
            lastError = String(localized: "Minute mit \(bits.count) statt 59 Sekunden")
            return
        }
        let values = bits.compactMap { $0 }
        guard values.count == bits.count else {
            minutesFailed += 1
            lastError = String(localized: "\(bits.count - values.count) Sekunden nicht lesbar")
            return
        }
        // Schaltsekunde: angekündigt in der vorigen Minute (Bit 19) – zählt mit.
        let announced = time?.leapSecondAnnounced == true
        switch DCF77Code.decode(values, leapAnnounced: announced) {
        case .success(let decoded):
            if values.count == 60 { leapSeconds += 1 }
            time = decoded
            minutesDecoded += 1
            lastError = nil
            // Die gesendete Zeit gilt ab der Sekunde nach der Marke.
            let start = markerDate.addingTimeInterval(1)
            timeDate = start
            if let real = decoded.date { clockOffset = start.timeIntervalSince(real) }
        case .failure(let error):
            minutesFailed += 1
            lastError = error.description
        }
    }
}
