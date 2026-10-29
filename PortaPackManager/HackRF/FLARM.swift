import Accelerate
import Foundation

/// FLARM/OGN-Funk auf 868,2 MHz: GFSK 100 kbit/s, Pakete mit Präambel,
/// Sync-Wort und CRC-16/CCITT. **Erkennung, nicht Entschlüsselung**: FLARM
/// verschleiert die Nutzdaten (zeit- und firmwareabhängig, nicht offen
/// dokumentiert), deshalb werden hier nur CRC-geprüfte Pakete mit Rohbytes
/// und Pegel gemeldet. Sync-Wort und CRC-Umfang sind nach OGN nachgebaut und
/// einstellbar; ohne echte Aufnahme nicht endgültig bestätigt.
enum FLARMLink {
    static let frequencyMHz = 868.2
    static let bitRate = 100_000.0
    /// Sync-Wort nach OGN (`rfm.h`, FLARM-Konfiguration des SX1276).
    static let defaultSync: [UInt8] = [0x99, 0xA5, 0xA9, 0x55, 0x66, 0x65, 0x96]
    /// Paketlänge (FLARM/OGN: 26 Byte inkl. 2 CRC-Byte am Ende).
    static let packetBytes = 26

    /// CRC-16/CCITT (Poly 0x1021, Start 0xFFFF) – OGN/FLARM-Rahmenprüfung.
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

/// Ein erkanntes FLARM/OGN-Paket.
struct FLARMPacket: Sendable, Equatable {
    /// Rohbytes ohne Sync (inkl. CRC am Ende).
    var bytes: [UInt8]
    var crcValid: Bool
    var rssiDB: Double
    var offsetKHz: Double
    var date: Date

    var hex: String { bytes.map { String(format: "%02X", $0) }.joined() }
}

/// GFSK-Demodulator für FLARM/OGN: HackRF 2 MS/s, 500 kHz unter dem Kanal,
/// Mischen mit Periode 4, Tiefpass + ÷5 auf 400 kHz (4 Abtastwerte je Bit),
/// FM-Diskriminator, Sync per Korrelation, feste Paketlänge, CRC.
final class FLARMDemodulator {
    static let inputRate = 2_000_000.0
    static let offset = 500_000.0
    static let rate = 400_000.0
    static let decimation = 5
    static let samplesPerBit = 4

    private let sync: [UInt8]
    private let syncBits: [Float]
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

    private static let maximumSamples = (56 + FLARMLink.packetBytes * 8) * samplesPerBit + 8

    init(sync: [UInt8] = FLARMLink.defaultSync) {
        self.sync = sync
        syncBits = sync.flatMap { byte in (0..<8).map { Float((byte >> (7 - $0)) & 1) == 1 ? 1 : -1 } }
        let count = 41
        let cutoff = 150_000.0 / Self.inputRate
        let taps = (0..<count).map { n -> Float in
            let k = Double(n - count / 2)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * k) / (.pi * k)
            return Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(count - 1))))
        }
        let sum = taps.reduce(0, +)
        self.taps = taps.map { $0 / sum }
    }

    func reset() {
        carryRe = []; carryIm = []; mixerPhase = 0; lastRe = 0; lastIm = 0
        frequency = []; power = []; noise = 0; crcErrors = 0
    }

    func process(_ block: Data) -> [FLARMPacket] {
        let count = block.count / 2
        guard count > 0 else { return [] }
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
        let tapCount = taps.count
        guard re.count >= tapCount else { carryRe = re; carryIm = im; return [] }
        let outCount = (re.count - tapCount) / Self.decimation + 1
        var outRe = [Float](repeating: 0, count: outCount)
        var outIm = [Float](repeating: 0, count: outCount)
        vDSP_desamp(re, vDSP_Stride(Self.decimation), taps, &outRe, vDSP_Length(outCount), vDSP_Length(tapCount))
        vDSP_desamp(im, vDSP_Stride(Self.decimation), taps, &outIm, vDSP_Length(outCount), vDSP_Length(tapCount))
        carryRe = Array(re[(outCount * Self.decimation)...])
        carryIm = Array(im[(outCount * Self.decimation)...])

        var pr = lastRe, pi = lastIm
        var blockPower = [Float](repeating: 0, count: outCount)
        var angles = [Float](repeating: 0, count: outCount)
        for n in 0..<outCount {
            let a = outRe[n], b = outIm[n]
            angles[n] = atan2(b * pr - a * pi, a * pr + b * pi)
            blockPower[n] = a * a + b * b
            pr = a; pi = b
        }
        lastRe = pr; lastIm = pi
        frequency += angles
        power += blockPower
        updateNoise(blockPower)
        return scan()
    }

    private func updateNoise(_ values: [Float]) {
        let step = max(1, values.count / 2048)
        var sample = stride(from: 0, to: values.count, by: step).map { values[$0] }
        guard !sample.isEmpty else { return }
        sample.sort()
        let floor = max(sample[sample.count / 10], 1e-9)
        noise = noise == 0 ? floor : 0.8 * noise + 0.2 * floor
    }

    private func score(_ start: Int) -> Float {
        let spb = Self.samplesPerBit
        var mean: Float = 0
        for k in 0..<syncBits.count { mean += frequency[start + k * spb] }
        mean /= Float(syncBits.count)
        var correlation: Float = 0, magnitude: Float = 0
        for k in 0..<syncBits.count {
            let v = frequency[start + k * spb] - mean
            correlation += syncBits[k] * v
            magnitude += abs(v)
        }
        return magnitude > 0 ? correlation / magnitude : 0
    }

    private func scan() -> [FLARMPacket] {
        let spb = Self.samplesPerBit
        var packets: [FLARMPacket] = []
        let gate = noise * 4
        let limit = frequency.count - Self.maximumSamples
        var n = 1
        while n < limit {
            guard power[n] > gate, abs(score(n)) >= 0.7 else { n += 1; continue }
            var best = n, bestScore = abs(score(n))
            for k in 1...spb { let s = abs(score(n + k)); if s > bestScore { best = n + k; bestScore = s } }
            let inverted = score(best) < 0
            if let packet = decode(at: best, inverted: inverted) {
                packets.append(packet)
                n = best + (syncBits.count + FLARMLink.packetBytes * 8) * spb
            } else {
                n = best + spb
            }
        }
        let consumed = min(max(0, n - 1), frequency.count)
        frequency.removeFirst(consumed)
        power.removeFirst(consumed)
        return packets
    }

    private func decode(at start: Int, inverted: Bool) -> FLARMPacket? {
        let spb = Self.samplesPerBit
        var mean: Float = 0
        let totalBits = syncBits.count + FLARMLink.packetBytes * 8
        for k in 0..<totalBits { mean += frequency[start + k * spb] }
        mean /= Float(totalBits)
        func bit(_ index: Int) -> UInt8 {
            let v = frequency[start + index * spb] - mean
            let one = (v > 0) != inverted
            return one ? 1 : 0
        }
        var bytes = [UInt8](repeating: 0, count: FLARMLink.packetBytes)
        for byteIndex in 0..<FLARMLink.packetBytes {
            var b: UInt8 = 0
            for k in 0..<8 { b = b << 1 | bit(syncBits.count + byteIndex * 8 + k) }
            bytes[byteIndex] = b
        }
        let crc = FLARMLink.crc16(bytes[0..<(FLARMLink.packetBytes - 2)])
        let carried = UInt16(bytes[FLARMLink.packetBytes - 2]) << 8 | UInt16(bytes[FLARMLink.packetBytes - 1])
        let valid = crc == carried
        if !valid { crcErrors += 1 }
        var level: Float = 0
        for k in 0..<(syncBits.count * spb) { level += power[start + k] }
        level /= Float(syncBits.count * spb)
        return FLARMPacket(bytes: bytes, crcValid: valid,
                           rssiDB: 10 * log10(Double(max(level, 1e-12))), offsetKHz: 0, date: Date())
    }
}
