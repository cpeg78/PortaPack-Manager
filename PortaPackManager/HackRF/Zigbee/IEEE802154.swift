import Accelerate
import Foundation

/// Bitübertragung von IEEE 802.15.4 im 2,4-GHz-Band (Zigbee, Thread):
/// O-QPSK mit Halbsinus-Pulsen, 2 MChip/s, je 4 Bit ein Symbol aus 32 Chips,
/// 250 kbit/s. Kanäle 11–26 im 5-MHz-Raster ab 2405 MHz.
enum IEEE802154 {
    static let channels = Array(11...26)

    static func frequencyMHz(channel: Int) -> Double { 2405 + 5 * Double(channel - 11) }

    /// Chipfolgen der 16 Symbole (c0 zuerst). Symbol 1–7: jeweils um 4 Chips
    /// nach rechts rotiert; 8–15: wie 0–7 mit invertierten ungeraden Chips
    /// (IEEE 802.15.4-2006, Tabelle 24).
    static let chips: [[UInt8]] = {
        let zero: [UInt8] = Array("11011001110000110101001000101110").map { $0 == "1" ? 1 : 0 }
        var table: [[UInt8]] = []
        for s in 0..<8 {
            let shift = 4 * s
            table.append(Array(zero.suffix(shift) + zero.prefix(32 - shift)))
        }
        for s in 0..<8 {
            table.append(table[s].enumerated().map { $0.offset % 2 == 1 ? $0.element ^ 1 : $0.element })
        }
        return table
    }()

    /// Erwartetes Vorzeichen der Momentanfrequenz in den Chipintervallen 1…31
    /// eines Symbols. O-QPSK mit Halbsinus ist MSK: Im Intervall n (gerade
    /// Chips auf I, ungerade auf Q) dreht die Phase mit (−1)ⁿ⁺¹·aₙ·aₙ₋₁,
    /// a = ±1. Intervall 0 hängt vom Vorsymbol ab und bleibt außen vor.
    /// Folge: Symbol s + 8 ist genau das Negativ von Symbol s.
    static let frequencySigns: [[Float]] = chips.map { c in
        (1..<32).map { k in
            let a = Float(2 * Int(c[k]) - 1), b = Float(2 * Int(c[k - 1]) - 1)
            return (k % 2 == 1 ? 1 : -1) * a * b
        }
    }

    /// Start-of-Frame-Delimiter 0xA7 → Symbole 7, dann A (niederes Halbbyte zuerst).
    static let sfdSymbols: [Int] = [7, 0xA]

    /// FCS: CRC-16/KERMIT (ITU-T, reflektiert, Start 0), niederwertiges Byte zuerst.
    static func crc(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    static func withFCS(_ mpdu: [UInt8]) -> [UInt8] {
        let fcs = crc(mpdu)
        return mpdu + [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
    }

    /// Symbolfolge eines Rahmens: Präambel (8 × 0), SFD, Längenbyte, PSDU.
    static func symbols(psdu: [UInt8]) -> [Int] {
        let bytes: [UInt8] = [0, 0, 0, 0, 0xA7, UInt8(psdu.count & 0x7F)] + psdu
        return bytes.flatMap { [Int($0 & 0x0F), Int($0 >> 4)] }
    }

    /// Basisband (komplex, `samplesPerChip` je Chip) – für Tests und den Prüfstand.
    static func modulate(symbols: [Int], samplesPerChip: Int) -> (re: [Float], im: [Float]) {
        let chipStream = symbols.flatMap { chips[$0] }
        let total = (chipStream.count + 1) * samplesPerChip
        var re = [Float](repeating: 0, count: total)
        var im = [Float](repeating: 0, count: total)
        for (n, chip) in chipStream.enumerated() {
            let a: Float = chip == 1 ? 1 : -1
            // Halbsinus über zwei Chipdauern, beginnend bei Chip n.
            for t in 0..<(2 * samplesPerChip) {
                let index = n * samplesPerChip + t
                guard index < total else { break }
                let pulse = a * Float(sin(Double.pi * Double(t) / Double(2 * samplesPerChip)))
                if n % 2 == 0 { re[index] += pulse } else { im[index] += pulse }
            }
        }
        return (re, im)
    }
}

/// Ein empfangener 802.15.4-Rahmen mit gültiger FCS.
struct ZigbeeRadioFrame: Sendable, Equatable {
    var channel: Int
    /// MAC-Rahmen ohne FCS.
    var mpdu: [UInt8]
    var rssiDB: Double
    var offsetKHz: Double
    var date: Date
}

/// O-QPSK-Demodulator: 8 MS/s vom HackRF, der 2 MHz unter dem Kanal steht,
/// Mischen mit Periode 4, Tiefpass ohne Dezimierung (4 Werte je Chip),
/// FM-Diskriminator (MSK-Sicht). Je Chipintervall die Summe von vier
/// Diskriminatorwerten; Symbole per Korrelation mit `frequencySigns`.
/// Mit nur 2 Werten je Chip lag das Raster wegen der Filterverzögerung
/// stets ½ Wert daneben (Ablage um 18 kHz verschätzt, lange Rahmen verloren).
/// Gesucht wird die Präambel (Symbol 0), danach SFD, Längenbyte, Nutzdaten;
/// der Symboltakt wird je Symbol um ±½ Chip nachgeführt (40 ppm wären bei
/// 127 Bytes ⅓ Chip). Eine vertauschte I/Q-Lage macht aus s ein s + 8 – sie
/// fällt am SFD auf (F, 2 statt 7, A) und wird dann umgedreht.
///
/// Rechenaufwand (28.10.2026): Der Präambeltest lief für jeden Abtastwert über
/// der Rauschschwelle (≈ ⅔ aller Werte, 8 Mio./s), legte dabei jedes Mal ein
/// Array an und las 124 Werte mit Grenzprüfung – drei Viertel der CPU der
/// ganzen App. Jetzt: Chipsummen einmal je Block (vDSP), davor eine billige
/// Vorprüfung mit einer beweisbaren Obergrenze des Präambelwerts aus
/// Präfixsummen (`prepareBounds`, ≈ 20 Rechenschritte statt 160 je Wert).
/// Nur wo die Grenze die Schwelle erreicht (bei Rauschen wenige Prozent),
/// rechnet der genaue Test – mit denselben Schritten in derselben Reihenfolge
/// wie früher, also bitgleich. Es werden dieselben Rahmen gefunden
/// (`ZigbeeSpeedTests` vergleicht mit der alten Fassung).
final class ZigbeeDemodulator {
    static let inputRate = 8_000_000.0
    static let offset = 2_000_000.0
    static let rate = 8_000_000.0
    static let samplesPerChip = 4
    static let samplesPerSymbol = 128
    static let syncThreshold: Float = 0.6
    /// Analoges Basisbandfilter des MAX2837 (Gesamtbreite, also ±3 MHz). Der
    /// Kanal liegt bei +2 MHz und reicht bis ≈ +3,5 MHz; 8 MHz (bis 29.10.2026)
    /// ließ Störer 10–15 MHz *unter* dem Kanal (Nachbar-Zigbee, WLAN) kaum
    /// gedämpft an den Wandler, der sie bei 8 MS/s genau auf den Kanalrand
    /// faltet. Simuliert (`ZigbeeFilterTests`, Butterworth 3./5./7. Ordnung):
    /// 6 MHz kostet im Rauschen nichts, holt mit solchen Störern aber die
    /// Rahmen zurück; 5,5 MHz und schmaler beschneiden den Kanal selbst.
    static let basebandFilter: UInt32 = 6_000_000

    private let taps: [Float]
    private var carryRe: [Float] = []
    private var carryIm: [Float] = []
    private var mixerPhase = 0
    private var lastRe: Float = 0
    private var lastIm: Float = 0
    private var frequency: [Float] = []
    private var power: [Float] = []
    private var noise: Float = 0

    /// Chipsummen: `chips[i]` = Summe der vier Diskriminatorwerte ab i, in der
    /// Reihenfolge ((f₀ + f₁) + f₂) + f₃ wie früher `chipValue`.
    private var chips: [Float] = []
    /// Obergrenze des Präambelwerts je Position (`prepareBounds`).
    private var bounds: [Float] = []
    /// Präfixsummen für die Vorprüfung (Double: Summen über ≈ 150 000 Werte).
    private var prefix: [Double] = []
    private var absPrefix: [Double] = []
    /// Erwartete Vorzeichen der Intervalle 1…31 von Symbol 0.
    private let preambleSigns: [Float] = IEEE802154.frequencySigns[0]

    private(set) var crcErrors = 0
    var noiseDB: Double { 10 * log10(Double(max(noise, 1e-12))) }

    /// Platz für Präambeltest und Takt-Nachführung hinter einer Position.
    private static let lookahead = 2 * samplesPerSymbol + 8
    /// Sicherheitsabstand der Vorprüfung zur Schwelle: die Grenze ist exakt
    /// gerechnet eine Obergrenze; Rundung (Float-Summen über 31 Werte, ≈ 10⁻⁵)
    /// bleibt weit darunter.
    private static let boundMargin: Float = 0.002
    /// Präambeltest als Linearkombination der Präfixsumme F der Diskriminator-
    /// werte: Σₖ sₖ·(F[n+4k+4] − F[n+4k]) = Σⱼ cⱼ·F[n+4j] – nur an den
    /// Vorzeichenwechseln ist cⱼ ≠ 0 (15 Stellen statt 31 Chips).
    static let boundTerms: [(offset: Int, weight: Double)] = {
        let s = IEEE802154.frequencySigns[0].map(Double.init)        // s₁…s₃₁ an Stelle 0…30
        var terms: [(Int, Double)] = []
        for j in 1...32 {
            let incoming = j - 1 >= 1 ? s[j - 2] : 0                  // s_{j−1}
            let outgoing = j <= 31 ? s[j - 1] : 0                     // s_j
            let weight = incoming - outgoing
            if weight != 0 { terms.append((j * samplesPerChip, weight)) }
        }
        return terms
    }()
    private static let preambleSignSum = Double(IEEE802154.frequencySigns[0].reduce(0, +))

    private enum Outcome {
        case frame(ZigbeeRadioFrame, end: Int)
        case failed
        /// Rahmen reicht über das Ende der vorliegenden Daten – später erneut.
        case needMore
    }

    init() {
        // Tiefpass ±1,1 MHz bei 8 MS/s, Hamming, 31 Abgriffe.
        let count = 31
        let cutoff = 1_100_000.0 / Self.inputRate
        var taps = (0..<count).map { n -> Float in
            let k = Double(n - count / 2)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * k) / (.pi * k)
            return Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(count - 1))))
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        self.taps = taps
    }

    func reset() {
        carryRe = []; carryIm = []
        mixerPhase = 0
        lastRe = 0; lastIm = 0
        frequency = []; power = []
        chips = []; bounds = []; prefix = []; absPrefix = []
        noise = 0
        crcErrors = 0
    }

    func process(_ block: Data, channel: Int) -> [ZigbeeRadioFrame] {
        let count = block.count / 2
        guard count > 0 else { return [] }
        let carried = carryRe.count
        var re = carryRe, im = carryIm
        re.append(contentsOf: repeatElement(0, count: count))
        im.append(contentsOf: repeatElement(0, count: count))
        let phase = mixerPhase
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { q in
                    // Mischen mit e^(−jπn/2): Kanal (2 MHz über der Mitte) auf 0.
                    // Je Viertelphase eine eigene Schleife (ohne Verzweigung je Wert).
                    for offset in 0..<4 {
                        var n = offset
                        let rotation = (phase + offset) & 3
                        while n < count {
                            let i = Float(p[2 * n]) / 128, v = Float(p[2 * n + 1]) / 128
                            let k = carried + n
                            switch rotation {
                            case 0: r[k] = i; q[k] = v
                            case 1: r[k] = v; q[k] = -i
                            case 2: r[k] = -i; q[k] = -v
                            default: r[k] = -v; q[k] = i
                            }
                            n += 4
                        }
                    }
                }
            }
        }
        mixerPhase = (mixerPhase + count) & 3
        return processMixed(re: re, im: im, channel: channel)
    }

    /// Bereits gemischtes Basisband bei 8 MS/s (Tests).
    func processBaseband(re: [Float], im: [Float], channel: Int) -> [ZigbeeRadioFrame] {
        processMixed(re: carryRe + re, im: carryIm + im, channel: channel)
    }

    private func processMixed(re: [Float], im: [Float], channel: Int) -> [ZigbeeRadioFrame] {
        let tapCount = taps.count
        guard re.count >= tapCount else {
            carryRe = re; carryIm = im
            return []
        }
        let outCount = re.count - tapCount + 1
        var outRe = [Float](repeating: 0, count: outCount)
        var outIm = [Float](repeating: 0, count: outCount)
        vDSP_desamp(re, 1, taps, &outRe, vDSP_Length(outCount), vDSP_Length(tapCount))
        vDSP_desamp(im, 1, taps, &outIm, vDSP_Length(outCount), vDSP_Length(tapCount))
        carryRe = Array(re[outCount...])
        carryIm = Array(im[outCount...])

        var crossRe = [Float](repeating: 0, count: outCount)
        var crossIm = [Float](repeating: 0, count: outCount)
        var blockPower = [Float](repeating: 0, count: outCount)
        var previousRe = lastRe, previousIm = lastIm
        outRe.withUnsafeBufferPointer { a in
            outIm.withUnsafeBufferPointer { b in
                crossRe.withUnsafeMutableBufferPointer { cr in
                    crossIm.withUnsafeMutableBufferPointer { ci in
                        blockPower.withUnsafeMutableBufferPointer { pw in
                            for n in 0..<outCount {
                                let x = a[n], y = b[n]
                                cr[n] = x * previousRe + y * previousIm
                                ci[n] = y * previousRe - x * previousIm
                                pw[n] = x * x + y * y
                                previousRe = x; previousIm = y
                            }
                        }
                    }
                }
            }
        }
        lastRe = previousRe; lastIm = previousIm
        // Winkel direkt hinten an `frequency` schreiben (kein Zwischenarray).
        let base = frequency.count
        frequency.append(contentsOf: repeatElement(0, count: outCount))
        frequency.withUnsafeMutableBufferPointer { f in
            var length = Int32(outCount)
            vvatan2f(f.baseAddress! + base, crossIm, crossRe, &length)
        }
        power += blockPower
        updateNoise(blockPower)
        return scan(channel: channel)
    }

    private func updateNoise(_ values: [Float]) {
        let step = max(1, values.count / 2048)
        var sample = stride(from: 0, to: values.count, by: step).map { values[$0] }
        guard !sample.isEmpty else { return }
        // Unteres Zehntel: ein Rahmen kann den Block weitgehend füllen.
        // Auswahl statt Sortieren – derselbe Wert wie `sorted()[count / 10]`.
        let floor = max(Self.select(&sample, sample.count / 10), 1e-9)
        noise = noise == 0 ? floor : 0.8 * noise + 0.2 * floor
    }

    /// k-kleinster Wert (Hoare-Auswahl, wie `nth_element`); ordnet `values` um.
    static func select(_ values: inout [Float], _ k: Int) -> Float {
        values.withUnsafeMutableBufferPointer { b in
            var low = 0, high = b.count - 1
            while low < high {
                let pivot = b[(low + high) / 2]
                var i = low, j = high
                while i <= j {
                    while b[i] < pivot { i += 1 }
                    while b[j] > pivot { j -= 1 }
                    if i <= j { b.swapAt(i, j); i += 1; j -= 1 }
                }
                if k <= j { high = j } else if k >= i { low = i } else { break }
            }
            return b[k]
        }
    }

    // MARK: Präambelsuche

    /// Chipsummen für den ganzen Puffer (drei vDSP-Additionen, Reihenfolge wie früher).
    private func prepareChips() {
        let count = max(0, frequency.count - 3)
        if chips.count != count { chips = [Float](repeating: 0, count: count) }
        guard count > 0 else { return }
        frequency.withUnsafeBufferPointer { f in
            chips.withUnsafeMutableBufferPointer { c in
                let p = f.baseAddress!, out = c.baseAddress!, n = vDSP_Length(count)
                vDSP_vadd(p, 1, p + 1, 1, out, 1, n)
                vDSP_vadd(out, 1, p + 2, 1, out, 1, n)
                vDSP_vadd(out, 1, p + 3, 1, out, 1, n)
            }
        }
    }

    /// Obergrenze des Präambelwerts für jede Position, ohne die 31 Chips
    /// einzeln anzufassen. Mit vₖ = Chipsumme k, m = Σvₖ/31 gilt
    /// Wert = |Σ sₖ(vₖ − m)| / Σ|vₖ − m| und Σ|vₖ − m| ≥ Σ|vₖ| − |Σvₖ|
    /// (Dreiecksungleichung), also Wert ≤ |A − m·Σsₖ| / (Σ|vₖ| − |Σvₖ|) mit
    /// A = Σ sₖvₖ. A und Σvₖ kommen aus der Präfixsumme der Diskriminatorwerte,
    /// Σ|vₖ| aus einer Präfixsumme der Chipbeträge im Viererabstand. Ist der
    /// Nenner nicht positiv, gibt es keine Grenze (+∞, genauer Test nötig).
    private func prepareBounds(upTo count: Int) {
        if bounds.count < count { bounds = [Float](repeating: 0, count: count) }
        let n = frequency.count
        guard count > 0, n >= count + 128 else { return }
        if prefix.count < n + 1 { prefix = [Double](repeating: 0, count: n + 1) }
        if absPrefix.count < chips.count { absPrefix = [Double](repeating: 0, count: chips.count) }
        let signSum = Self.preambleSignSum
        frequency.withUnsafeBufferPointer { f in
            chips.withUnsafeBufferPointer { c in
                prefix.withUnsafeMutableBufferPointer { F in
                    absPrefix.withUnsafeMutableBufferPointer { Q in
                        bounds.withUnsafeMutableBufferPointer { out in
                            Self.runningSum(f.baseAddress!, into: F.baseAddress!, count: n)
                            for i in 0..<c.count {
                                Q[i] = Double(abs(c[i])) + (i >= 4 ? Q[i - 4] : 0)
                            }
                            // Vier Positionen zugleich. Die Stellen stammen aus
                            // `boundTerms` (Test „Vorprüfung: Stellen …“ wacht darüber):
                            // A = 2·(F₁₂ − F₃₆ + F₄₈ − F₅₂ + F₆₈ − F₇₂ + F₇₆ − F₈₀
                            //        + F₉₂ − F₁₀₀ + F₁₀₈ − F₁₁₂ + F₁₂₀) − F₄ − F₁₂₈.
                            let base = UnsafeRawPointer(F.baseAddress!), qBase = UnsafeRawPointer(Q.baseAddress!)
                            @inline(__always) func at(_ index: Int) -> SIMD4<Double> {
                                base.loadUnaligned(fromByteOffset: index &* 8, as: SIMD4<Double>.self)
                            }
                            var p = 0
                            while p + 4 <= count {
                                let plus = at(p + 12) + at(p + 48) + at(p + 68) + at(p + 76) + at(p + 92) + at(p + 108) + at(p + 120)
                                let minus = at(p + 36) + at(p + 52) + at(p + 72) + at(p + 80) + at(p + 100) + at(p + 112)
                                let first = at(p + 4), last = at(p + 128)
                                let a = 2 * (plus - minus) - first - last
                                let sum = last - first                                          // Σvₖ
                                let absSum = qBase.loadUnaligned(fromByteOffset: (p + 124) &* 8, as: SIMD4<Double>.self)
                                    - qBase.loadUnaligned(fromByteOffset: p &* 8, as: SIMD4<Double>.self)   // Σ|vₖ|
                                let denominator = absSum - Self.absolute(sum)
                                let ratio = Self.absolute(a - sum / 31 * signSum) / denominator
                                for lane in 0..<4 {
                                    out[p + lane] = denominator[lane] > 1e-9 ? Float(ratio[lane]) : .infinity
                                }
                                p += 4
                            }
                            let terms = Self.boundTerms
                            while p < count {
                                var a = 0.0
                                for term in terms { a += term.weight * F[p + term.offset] }
                                let sum = F[p + 128] - F[p + 4]
                                let absSum = Q[p + 124] - Q[p]
                                let denominator = absSum - abs(sum)
                                let numerator = abs(a - sum / 31 * signSum)
                                out[p] = denominator > 1e-9 ? Float(numerator / denominator) : .infinity
                                p += 1
                            }
                        }
                    }
                }
            }
        }
    }

    /// Stellen der Vorprüfung, wie sie `prepareBounds` fest verdrahtet (für den Test).
    static let wiredBoundTerms: [(offset: Int, weight: Double)] =
        [(4, -1), (12, 2), (36, -2), (48, 2), (52, -2), (68, 2), (72, -2), (76, 2), (80, -2),
         (92, 2), (100, -2), (108, 2), (112, -2), (120, 2), (128, -1)]

    /// Präfixsumme F[0] = 0, F[i + 1] = F[i] + f[i] in Double – in vier
    /// Abschnitten nebeneinander (vier unabhängige Ketten statt einer langen
    /// Abhängigkeit), danach um die Abschnittsenden verschoben.
    private static func runningSum(_ f: UnsafePointer<Float>, into F: UnsafeMutablePointer<Double>, count n: Int) {
        F[0] = 0
        let length = n / 4
        var r0 = 0.0, r1 = 0.0, r2 = 0.0, r3 = 0.0
        for i in 0..<length {
            r0 += Double(f[i]); F[i + 1] = r0
            r1 += Double(f[length + i]); F[length + i + 1] = r1
            r2 += Double(f[2 * length + i]); F[2 * length + i + 1] = r2
            r3 += Double(f[3 * length + i]); F[3 * length + i + 1] = r3
        }
        for i in (4 * length)..<n { r3 += Double(f[i]); F[i + 1] = r3 }
        // Abschnitt k beginnt bei F[k·length]; der Reihe nach anheben.
        for k in 1..<4 {
            var shift = F[k * length]
            let end = k == 3 ? n : (k + 1) * length
            vDSP_vsaddD(F + k * length + 1, 1, &shift, F + k * length + 1, 1, vDSP_Length(end - k * length))
        }
    }

    @inline(__always)
    private static func absolute(_ v: SIMD4<Double>) -> SIMD4<Double> { v.replacing(with: -v, where: v .< 0) }

    /// Präambeltest: Symbol 0 (ohne Ablage, Mittelwert abgezogen).
    @inline(__always)
    private func score(_ start: Int) -> Float { scalarScore(start) }

    /// Einzelner Präambelwert, Rechenschritte wie die SIMD-Fassung (und wie
    /// das frühere `preambleScore`).
    private func scalarScore(_ start: Int) -> Float {
        chips.withUnsafeBufferPointer { (c) -> Float in
            preambleSigns.withUnsafeBufferPointer { (s) -> Float in
                withUnsafeTemporaryAllocation(of: Float.self, capacity: 31) { (values) -> Float in
                    var mean: Float = 0
                    for k in 1..<32 { values[k - 1] = c[start + k * Self.samplesPerChip]; mean += values[k - 1] }
                    mean /= 31
                    var corr: Float = 0, magnitude: Float = 0
                    for k in 0..<31 {
                        let v = values[k] - mean
                        corr += s[k] * v
                        magnitude += abs(v)
                    }
                    return magnitude > 0 ? abs(corr) / magnitude : 0
                }
            }
        }
    }

    /// Korrelation der Intervalle 1…31 mit allen 16 Symbolen (Ablage `carrier`
    /// abgezogen): bestes Symbol und dessen Wert, normiert auf die Amplitude.
    private func symbol(at start: Int, carrier: Float) -> (symbol: Int, score: Float) {
        chips.withUnsafeBufferPointer { (c) -> (symbol: Int, score: Float) in
            Self.symbolColumns.withUnsafeBufferPointer { (columns) -> (symbol: Int, score: Float) in
                var magnitude: Float = 0
                // Alle acht Symbole zugleich: je Spur dieselbe Summenfolge wie einzeln.
                var corr = SIMD8<Float>(repeating: 0)
                for k in 1..<32 {
                    let v = c[start + k * Self.samplesPerChip] - carrier
                    magnitude += abs(v)
                    corr += columns[k - 1] * SIMD8(repeating: v)
                }
                guard magnitude > 0 else { return (0, 0) }
                var best = 0
                var bestScore = -Float.infinity
                for s in 0..<8 {
                    let value = corr[s]
                    // s + 8 ist das Negativ von s.
                    if value > bestScore { bestScore = value; best = s }
                    if -value > bestScore { bestScore = -value; best = s + 8 }
                }
                return (best, bestScore / magnitude)
            }
        }
    }

    /// Spalte k: Vorzeichen von Intervall k + 1 für die Symbole 0…7.
    private static let symbolColumns: [SIMD8<Float>] = (0..<31).map { k in
        SIMD8((0..<8).map { IEEE802154.frequencySigns[$0][k] })
    }

    private func scan(channel: Int) -> [ZigbeeRadioFrame] {
        var frames: [ZigbeeRadioFrame] = []
        let gate = noise * 4
        let limit = frequency.count - Self.lookahead
        prepareChips()
        prepareBounds(upTo: max(0, limit))
        let floor = Self.syncThreshold - Self.boundMargin
        var n = 0
        scanning: while n < limit {
            // Schneller Vorlauf: nur Werte über der Rauschschwelle, deren
            // Obergrenze die Präambelschwelle erreichen kann, bekommen den
            // genauen Test.
            let next: Int? = power.withUnsafeBufferPointer { (pw) -> Int? in
                bounds.withUnsafeBufferPointer { (bound) -> Int? in
                    var i = n
                    while i < limit {
                        if pw[i] > gate, bound[i] >= floor, scalarScore(i) >= Self.syncThreshold { return i }
                        i += 1
                    }
                    return nil
                }
            }
            guard let candidate = next else { n = limit; break }
            n = candidate
            guard score(n) >= Self.syncThreshold else {
                n += 1
                continue
            }
            var best = n, bestScore = score(n)
            for k in 1...Self.samplesPerChip {
                let s = score(n + k)
                if s > bestScore { best = n + k; bestScore = s }
            }
            switch decode(from: best, channel: channel) {
            case let .frame(frame, end):
                frames.append(frame)
                n = end
            case .failed:
                n = best + Self.samplesPerSymbol
            case .needMore:
                break scanning
            }
        }
        let consumed = min(max(0, n), frequency.count)
        frequency.removeFirst(consumed)
        power.removeFirst(consumed)
        return frames
    }

    /// Ab einem Präambelsymbol: Ablage schätzen, SFD suchen, Rahmen lesen.
    private func decode(from first: Int, channel: Int) -> Outcome {
        let sps = Self.samplesPerSymbol
        // Lage (vertauscht?) aus dem Vorzeichen der Korrelation mit Symbol 0.
        let signs = IEEE802154.frequencySigns[0]
        var correlation: Float = 0
        for k in 1..<32 { correlation += signs[k - 1] * chips[first + k * Self.samplesPerChip] }
        let inverted = correlation < 0
        // Ablage: MSK dreht die Phase je Chip um genau ±π/2. Über ein ganzes
        // Präambelsymbol (32 Intervalle, Intervall 0 zwischen zwei Nullsymbolen
        // ist +) ist die Sollsumme bekannt; der Rest ist die Ablage – unabhängig
        // davon, wie genau das Abtastraster liegt.
        // Das erste erkannte Symbol auslassen: Ohne Vorgänger stimmt sein
        // Intervall 0 nicht (kostete 12 kHz Schätzfehler).
        var offsetStart = first, symbolsForOffset = 1
        if first + 3 * sps + Self.lookahead < frequency.count, score(first + sps) >= Self.syncThreshold {
            offsetStart = first + sps
            symbolsForOffset = score(first + 2 * sps) >= Self.syncThreshold ? 2 : 1
        }
        var total: Float = 0
        for m in offsetStart..<(offsetStart + symbolsForOffset * sps) { total += frequency[m] }
        let expected = Float.pi / 2 * (signs.reduce(0, +) + 1) * Float(symbolsForOffset) * (inverted ? -1 : 1)
        let carrier = (total - expected) / Float(32 * symbolsForOffset)

        var position = first
        var exhausted = false
        func next() -> Int? {
            // Takt nachführen: ±1 Abtastwert (¼ Chip) probieren.
            guard position + sps + 4 < frequency.count else { exhausted = true; return nil }
            var best = symbol(at: position, carrier: carrier)
            var shift = 0
            for d in stride(from: -1, through: 1, by: 2) where position + d >= 0 {
                let candidate = symbol(at: position + d, carrier: carrier)
                if candidate.score > best.score * 1.05 { best = candidate; shift = d }
            }
            position += shift
            let value = inverted ? best.symbol ^ 8 : best.symbol
            position += sps
            return value
        }
        // Präambel überspringen (höchstens 12 Symbole), dann SFD 7, A.
        var preambleCount = 0
        var current = next()
        while current == 0, preambleCount < 12 {
            preambleCount += 1
            current = next()
        }
        guard current == IEEE802154.sfdSymbols[0], next() == IEEE802154.sfdSymbols[1] else {
            return exhausted ? .needMore : .failed
        }
        guard let low = next(), let high = next() else { return .needMore }
        let length = (low | high << 4) & 0x7F
        guard length >= 5 else { return .failed }
        var psdu: [UInt8] = []
        psdu.reserveCapacity(length)
        for _ in 0..<length {
            guard let lo = next(), let hi = next() else { return .needMore }
            psdu.append(UInt8(lo | hi << 4))
        }
        let mpdu = Array(psdu.dropLast(2))
        let fcs = UInt16(psdu[psdu.count - 2]) | UInt16(psdu[psdu.count - 1]) << 8
        guard IEEE802154.crc(mpdu) == fcs else {
            crcErrors += 1
            return .failed
        }
        var level: Float = 0
        let end = min(position, power.count)
        for k in first..<end { level += power[k] }
        level /= Float(max(1, end - first))
        // Ablage: `carrier` ist die Phasendrehung über einen Chip (4 Werte).
        let offset = Double(carrier) / Double(Self.samplesPerChip) * Self.rate / (2 * .pi) / 1000
        return .frame(ZigbeeRadioFrame(channel: channel, mpdu: mpdu, rssiDB: 10 * log10(Double(max(level, 1e-12))),
                                       offsetKHz: offset, date: Date()), end: position)
    }
}
