import Accelerate
import Foundation

/// Bitübertragung von Bluetooth LE (1M-PHY) auf den Werbekanälen:
/// Whitening, CRC-24 und die feste Zugriffsadresse.
enum BLELink {
    /// Zugriffsadresse aller Werbepakete.
    static let advertisingAccessAddress: UInt32 = 0x8E89_BED6
    static let advertisingChannels = [37, 38, 39]

    static func frequencyMHz(channel: Int) -> Double {
        switch channel {
        case 37: 2402
        case 38: 2426
        case 39: 2480
        case 0...10: 2404 + 2 * Double(channel)
        default: 2428 + 2 * Double(channel - 11)
        }
    }

    /// Präambel (0xAA, weil das unterste Bit der Zugriffsadresse 0 ist) und
    /// Zugriffsadresse – 40 Bits in Sendereihenfolge (jeweils LSB zuerst).
    static let syncBits: [UInt8] = {
        let preamble: [UInt8] = (0..<8).map { UInt8((0xAA >> $0) & 1) }
        let address: [UInt8] = (0..<32).map { UInt8((advertisingAccessAddress >> UInt32($0)) & 1) }
        return preamble + address
    }()

    /// Whitening (x⁷ + x⁴ + 1, Startwert aus der Kanalnummer); symmetrisch,
    /// also zugleich das Entwhitening. Bytes laufen LSB zuerst durch.
    static func whiten(_ bytes: [UInt8], channel: Int) -> [UInt8] {
        var state = reverse(UInt8(channel)) | 0x02
        return bytes.map { byte in
            var out = byte
            var mask: UInt8 = 1
            while mask != 0 {
                if state & 0x80 != 0 {
                    state ^= 0x11
                    out ^= mask
                }
                state <<= 1
                mask <<= 1
            }
            return out
        }
    }

    /// CRC-24 (x²⁴ + x¹⁰ + x⁹ + x⁶ + x⁴ + x³ + x + 1, Start 0x555555) über
    /// Kopf und Nutzdaten, Bits LSB zuerst.
    static func crc(_ bytes: [UInt8], initial: UInt32 = 0x55_5555) -> UInt32 {
        var state = initial
        for byte in bytes {
            var data = byte
            for _ in 0..<8 {
                let top = (state >> 23) & 1
                state = (state << 1) & 0xFF_FFFF
                if top != UInt32(data & 1) { state ^= 0x00_065B }
                data >>= 1
            }
        }
        return state
    }

    /// Die drei CRC-Bytes, wie sie im Paket stehen (das höchste Bit wird
    /// zuerst gesendet, Bytes aber LSB zuerst gelesen).
    static func crcBytes(_ pdu: [UInt8]) -> [UInt8] {
        let value = crc(pdu)
        return [reverse(UInt8(value >> 16 & 0xFF)), reverse(UInt8(value >> 8 & 0xFF)), reverse(UInt8(value & 0xFF))]
    }

    static func reverse(_ byte: UInt8) -> UInt8 {
        var input = byte, output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }
}

/// Ein empfangenes Werbepaket mit gültiger CRC.
struct BLEPacket: Sendable, Equatable {
    /// Kanal, mit dem das Entwhitening passte.
    var channel: Int
    /// Kopf (2 Bytes) und Nutzdaten, ohne CRC.
    var pdu: [UInt8]
    var rssiDB: Double
    var offsetKHz: Double
    var date: Date
}

/// GFSK-Demodulator für BLE-Werbepakete: 8 MS/s vom HackRF, der 2 MHz unter
/// dem Kanal steht (DC-Spitze außerhalb), Mischen mit Periode 4, FIR ÷2 auf
/// 4 MS/s (4 Abtastwerte je Bit), FM-Diskriminator. Gesucht wird die
/// Präambel samt Zugriffsadresse per normierter Korrelation – nur dort, wo
/// der Pegel deutlich über dem Rauschen liegt.
final class BLEDemodulator {
    static let inputRate = 8_000_000.0
    static let offset = 2_000_000.0
    static let rate = 4_000_000.0
    static let samplesPerBit = 4
    /// Mindestgüte der Korrelation (1 = alle Bits passen perfekt).
    static let syncThreshold: Float = 0.7

    private let taps: [Float]
    private var carryRe: [Float] = []
    private var carryIm: [Float] = []
    private var mixerPhase = 0
    private var lastRe: Float = 0
    private var lastIm: Float = 0
    /// Diskriminator (rad je Abtastung) und Leistung, mit Rest aus dem Vorblock.
    private var frequency: [Float] = []
    private var power: [Float] = []
    private var noise: Float = 0

    private let pattern: [Float] = BLELink.syncBits.map { $0 == 1 ? 1 : -1 }
    private let patternMean: Float
    private let patternVariance: Float

    /// Paketanfänge mit Sync, aber falscher CRC (Störung, zu schwach).
    private(set) var crcErrors = 0
    var noiseDB: Double { 10 * log10(Double(max(noise, 1e-12))) }

    /// Längstes Paket: Sync + Kopf + 255 Bytes + CRC.
    private static let maximumSamples = (40 + (2 + 255 + 3) * 8) * samplesPerBit + 8

    init() {
        // Tiefpass ±750 kHz bei 8 MS/s, Hamming, 31 Abgriffe.
        let count = 31
        let cutoff = 750_000.0 / Self.inputRate
        var taps = (0..<count).map { n -> Float in
            let k = Double(n - count / 2)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * k) / (.pi * k)
            return Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(count - 1))))
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        self.taps = taps
        let values: [Float] = BLELink.syncBits.map { $0 == 1 ? 1 : -1 }
        let mean = values.reduce(0, +) / Float(values.count)
        patternMean = mean
        patternVariance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    }

    func reset() {
        carryRe = []
        carryIm = []
        mixerPhase = 0
        lastRe = 0
        lastIm = 0
        frequency = []
        power = []
        noise = 0
        crcErrors = 0
    }

    /// Verarbeitet einen HackRF-Block (int8 I/Q). `channel` ist der
    /// eingestellte Werbekanal; passt dessen Whitening nicht, werden die
    /// anderen beiden versucht (Umschalten mitten im Block).
    func process(_ block: Data, channel: Int) -> [BLEPacket] {
        let count = block.count / 2
        guard count > 0 else { return [] }
        // Mischen mit e^(−jπn/2): (1, −j, −1, j).
        var re = carryRe, im = carryIm
        re.reserveCapacity(re.count + count)
        im.reserveCapacity(im.count + count)
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                switch (mixerPhase + n) & 3 {
                case 0: re.append(i); im.append(q)
                case 1: re.append(q); im.append(-i)
                case 2: re.append(-i); im.append(-q)
                default: re.append(-q); im.append(i)
                }
            }
        }
        mixerPhase = (mixerPhase + count) & 3

        // FIR ÷2.
        let tapCount = taps.count
        guard re.count >= tapCount else {
            carryRe = re
            carryIm = im
            return []
        }
        let outCount = (re.count - tapCount) / 2 + 1
        var outRe = [Float](repeating: 0, count: outCount)
        var outIm = [Float](repeating: 0, count: outCount)
        vDSP_desamp(re, 2, taps, &outRe, vDSP_Length(outCount), vDSP_Length(tapCount))
        vDSP_desamp(im, 2, taps, &outIm, vDSP_Length(outCount), vDSP_Length(tapCount))
        carryRe = Array(re[(outCount * 2)...])
        carryIm = Array(im[(outCount * 2)...])

        // Diskriminator: arg(x[n]·x*[n−1]).
        var crossRe = [Float](repeating: 0, count: outCount)
        var crossIm = [Float](repeating: 0, count: outCount)
        var blockPower = [Float](repeating: 0, count: outCount)
        var previousRe = lastRe, previousIm = lastIm
        for n in 0..<outCount {
            let a = outRe[n], b = outIm[n]
            crossRe[n] = a * previousRe + b * previousIm
            crossIm[n] = b * previousRe - a * previousIm
            blockPower[n] = a * a + b * b
            previousRe = a
            previousIm = b
        }
        lastRe = previousRe
        lastIm = previousIm
        var angles = [Float](repeating: 0, count: outCount)
        var length = Int32(outCount)
        vvatan2f(&angles, crossIm, crossRe, &length)
        frequency += angles
        power += blockPower

        updateNoise(blockPower)
        return scan(channel: channel)
    }

    /// Rauschboden als unteres Drittel der Leistung (Pakete sind kurz).
    private func updateNoise(_ values: [Float]) {
        let step = max(1, values.count / 2048)
        var sample = stride(from: 0, to: values.count, by: step).map { values[$0] }
        guard !sample.isEmpty else { return }
        sample.sort()
        let floor = max(sample[sample.count / 3], 1e-9)
        noise = noise == 0 ? floor : 0.8 * noise + 0.2 * floor
    }

    private func score(_ start: Int) -> Float {
        var mean: Float = 0
        for k in 0..<40 { mean += frequency[start + k * Self.samplesPerBit] }
        mean /= 40
        var correlation: Float = 0, magnitude: Float = 0
        for k in 0..<40 {
            let v = frequency[start + k * Self.samplesPerBit] - mean
            correlation += pattern[k] * v
            magnitude += abs(v)
        }
        return magnitude > 0 ? correlation / magnitude : 0
    }

    private func scan(channel: Int) -> [BLEPacket] {
        var packets: [BLEPacket] = []
        let gate = noise * 4   // 6 dB über dem Rauschen
        let limit = frequency.count - Self.maximumSamples
        var n = 1   // eine Abtastung Vorlauf für den Nachbarversuch
        while n < limit {
            guard power[n] > gate, score(n) >= Self.syncThreshold else {
                n += 1
                continue
            }
            // Bitmitte: bestes Ergebnis der nächsten Abtastungen.
            var best = n, bestScore = score(n)
            for k in 1...Self.samplesPerBit {
                let s = score(n + k)
                if s > bestScore { best = n + k; bestScore = s }
            }
            // Scheitert die CRC, die Nachbarabtastungen versuchen (Bitmitte
            // nicht genau getroffen).
            if let (packet, samples) = decode(at: best, channel: channel)
                ?? decode(at: best + 1, channel: channel) ?? decode(at: best - 1, channel: channel) {
                packets.append(packet)
                n = best + samples
            } else {
                if bestScore > 0.85 { crcErrors += 1 }
                n = best + Self.samplesPerBit
            }
        }
        let consumed = min(max(0, n - 1), frequency.count)
        frequency.removeFirst(consumed)
        power.removeFirst(consumed)
        return packets
    }

    /// Liest ab dem Paketanfang `start` (erstes Präambelbit) Kopf, Nutzdaten
    /// und CRC. Liefert das Paket und seine Länge in Abtastwerten.
    private func decode(at start: Int, channel: Int) -> (BLEPacket, Int)? {
        let spb = Self.samplesPerBit
        // Ablage und Hub per kleinster Quadrate über die 40 Sync-Bits.
        var mean: Float = 0
        for k in 0..<40 { mean += frequency[start + k * spb] }
        mean /= 40
        var slope: Float = 0
        for k in 0..<40 { slope += (pattern[k] - patternMean) * (frequency[start + k * spb] - mean) }
        slope /= patternVariance
        guard slope > 0 else { return nil }
        let carrier = mean - slope * patternMean

        func rawByte(_ index: Int) -> UInt8 {
            var byte: UInt8 = 0
            for bit in 0..<8 {
                let position = start + (40 + index * 8 + bit) * spb
                if frequency[position] - carrier > 0 { byte |= 1 << UInt8(bit) }
            }
            return byte
        }

        let header = [rawByte(0), rawByte(1)]
        let candidates = [channel] + BLELink.advertisingChannels.filter { $0 != channel }
        for candidate in candidates {
            let length = Int(BLELink.whiten(header, channel: candidate)[1])
            let raw = header + (2..<(2 + length + 3)).map(rawByte)
            let clear = BLELink.whiten(raw, channel: candidate)
            let pdu = Array(clear.prefix(2 + length))
            guard Array(clear.suffix(3)) == BLELink.crcBytes(pdu) else { continue }
            var level: Float = 0
            for k in 0..<(40 * spb) { level += power[start + k] }
            level /= Float(40 * spb)
            let packet = BLEPacket(channel: candidate, pdu: pdu,
                                   rssiDB: 10 * log10(Double(max(level, 1e-12))),
                                   offsetKHz: Double(carrier) * Self.rate / (2 * .pi) / 1000,
                                   date: Date())
            return (packet, (40 + raw.count * 8) * spb)
        }
        return nil
    }
}
