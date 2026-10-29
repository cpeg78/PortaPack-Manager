import Accelerate
import Foundation
@testable import PortaPackManager

// Unveränderte Kopie des Zigbee-Demodulators vor der CPU-Optimierung
// (Stand 896df48, 28.10.2026) – nur als Referenz für den Vergleichstest
// „alte und neue Erkennung finden dieselben Rahmen“ und den Benchmark.
// Nicht weiterentwickeln.

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
final class LegacyZigbeeDemodulator {
    static let inputRate = 8_000_000.0
    static let offset = 2_000_000.0
    static let rate = 8_000_000.0
    static let samplesPerChip = 4
    static let samplesPerSymbol = 128
    static let syncThreshold: Float = 0.6

    private let taps: [Float]
    private var carryRe: [Float] = []
    private var carryIm: [Float] = []
    private var mixerPhase = 0
    private var lastRe: Float = 0
    private var lastIm: Float = 0
    private var frequency: [Float] = []
    private var power: [Float] = []
    private var noise: Float = 0

    private(set) var crcErrors = 0
    var noiseDB: Double { 10 * log10(Double(max(noise, 1e-12))) }

    /// Platz für Präambeltest und Takt-Nachführung hinter einer Position.
    private static let lookahead = 2 * samplesPerSymbol + 8

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
        noise = 0
        crcErrors = 0
    }

    func process(_ block: Data, channel: Int) -> [ZigbeeRadioFrame] {
        let count = block.count / 2
        guard count > 0 else { return [] }
        var re = carryRe, im = carryIm
        re.reserveCapacity(re.count + count)
        im.reserveCapacity(im.count + count)
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                // Mischen mit e^(−jπn/2): Kanal (2 MHz über der Mitte) auf 0.
                switch (mixerPhase + n) & 3 {
                case 0: re.append(i); im.append(q)
                case 1: re.append(q); im.append(-i)
                case 2: re.append(-i); im.append(-q)
                default: re.append(-q); im.append(i)
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
        for n in 0..<outCount {
            let a = outRe[n], b = outIm[n]
            crossRe[n] = a * previousRe + b * previousIm
            crossIm[n] = b * previousRe - a * previousIm
            blockPower[n] = a * a + b * b
            previousRe = a; previousIm = b
        }
        lastRe = previousRe; lastIm = previousIm
        var angles = [Float](repeating: 0, count: outCount)
        var length = Int32(outCount)
        vvatan2f(&angles, crossIm, crossRe, &length)
        frequency += angles
        power += blockPower
        updateNoise(blockPower)
        return scan(channel: channel)
    }

    private func updateNoise(_ values: [Float]) {
        let step = max(1, values.count / 2048)
        var sample = stride(from: 0, to: values.count, by: step).map { values[$0] }
        guard !sample.isEmpty else { return }
        sample.sort()
        // Unteres Zehntel: ein Rahmen kann den Block weitgehend füllen.
        let floor = max(sample[sample.count / 10], 1e-9)
        noise = noise == 0 ? floor : 0.8 * noise + 0.2 * floor
    }

    /// Weicher Wert des Chipintervalls k eines Symbols ab `start`.
    @inline(__always)
    private func chipValue(_ start: Int, _ k: Int) -> Float {
        let index = start + k * Self.samplesPerChip
        return frequency[index] + frequency[index + 1] + frequency[index + 2] + frequency[index + 3]
    }

    /// Korrelation der Intervalle 1…31 mit allen 16 Symbolen (Ablage `carrier`
    /// abgezogen): bestes Symbol und dessen Wert, normiert auf die Amplitude.
    private func symbol(at start: Int, carrier: Float) -> (symbol: Int, score: Float) {
        var values = [Float](repeating: 0, count: 31)
        var magnitude: Float = 0
        for k in 1..<32 {
            let v = chipValue(start, k) - carrier
            values[k - 1] = v
            magnitude += abs(v)
        }
        guard magnitude > 0 else { return (0, 0) }
        var best = 0
        var bestScore = -Float.infinity
        for s in 0..<8 {
            var c: Float = 0
            let signs = IEEE802154.frequencySigns[s]
            for k in 0..<31 { c += signs[k] * values[k] }
            // s + 8 ist das Negativ von s.
            if c > bestScore { bestScore = c; best = s }
            if -c > bestScore { bestScore = -c; best = s + 8 }
        }
        return (best, bestScore / magnitude)
    }

    /// Präambeltest: Symbol 0 (ohne Ablage, Mittelwert abgezogen).
    private func preambleScore(_ start: Int) -> Float {
        var values = [Float](repeating: 0, count: 31)
        var mean: Float = 0
        for k in 1..<32 { values[k - 1] = chipValue(start, k); mean += values[k - 1] }
        mean /= 31
        var c: Float = 0, magnitude: Float = 0
        let signs = IEEE802154.frequencySigns[0]
        for k in 0..<31 {
            let v = values[k] - mean
            c += signs[k] * v
            magnitude += abs(v)
        }
        return magnitude > 0 ? abs(c) / magnitude : 0
    }

    private func scan(channel: Int) -> [ZigbeeRadioFrame] {
        var frames: [ZigbeeRadioFrame] = []
        let gate = noise * 4
        let limit = frequency.count - Self.lookahead
        var n = 0
        scanning: while n < limit {
            guard power[n] > gate, preambleScore(n) >= Self.syncThreshold else {
                n += 1
                continue
            }
            var best = n, bestScore = preambleScore(n)
            for k in 1...Self.samplesPerChip {
                let s = preambleScore(n + k)
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
        for k in 1..<32 { correlation += signs[k - 1] * chipValue(first, k) }
        let inverted = correlation < 0
        // Ablage: MSK dreht die Phase je Chip um genau ±π/2. Über ein ganzes
        // Präambelsymbol (32 Intervalle, Intervall 0 zwischen zwei Nullsymbolen
        // ist +) ist die Sollsumme bekannt; der Rest ist die Ablage – unabhängig
        // davon, wie genau das Abtastraster liegt.
        // Das erste erkannte Symbol auslassen: Ohne Vorgänger stimmt sein
        // Intervall 0 nicht (kostete 12 kHz Schätzfehler).
        var offsetStart = first, symbolsForOffset = 1
        if first + 3 * sps + Self.lookahead < frequency.count, preambleScore(first + sps) >= Self.syncThreshold {
            offsetStart = first + sps
            symbolsForOffset = preambleScore(first + 2 * sps) >= Self.syncThreshold ? 2 : 1
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
            for d in [-1, 1] where position + d >= 0 {
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
