import Foundation

/// CRC-16/X.25 (ISO 3309, HDLC-FCS): reflektiert, Polynom 0x1021, Start-
/// und Endwert 0xFFFF. AX.25 (APRS) und AIS sichern ihre Rahmen damit; die
/// Prüfsumme steht mit dem niederwertigen Byte zuerst am Rahmenende.
enum CRC16X25 {
    private static let table: [UInt16] = (0..<256).map { n -> UInt16 in
        var crc = UInt16(n)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        return crc
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)] }
        return crc ^ 0xFFFF
    }

    /// Prüft einen Rahmen samt angehängter FCS (2 Bytes, LSB zuerst).
    static func isValid(frameWithFCS bytes: [UInt8]) -> Bool {
        guard bytes.count > 2 else { return false }
        let fcs = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        return checksum(bytes.dropLast(2)) == fcs
    }
}

/// Sucht HDLC-Rahmen in einem Strom von Datenbits (nach der NRZI-Dekodierung):
/// Flaggen `01111110`, Entfernen der nach fünf Einsen eingefügten Null,
/// Abbruch bei sieben Einsen, Bytes mit dem niederwertigen Bit zuerst.
/// Geliefert werden nur Rahmen mit gültiger FCS – ohne die FCS selbst.
struct HDLCDeframer {
    var minimumBytes = 10
    var maximumBytes = 400

    private var pattern: UInt8 = 0
    private var accumulator: UInt8 = 0
    private var bitCount = 0
    private var buffer: [UInt8] = []
    private var inFrame = false

    /// Verarbeitet ein Datenbit; liefert einen vollständigen, geprüften Rahmen.
    mutating func push(_ bit: UInt8) -> [UInt8]? {
        pattern = (pattern >> 1) | (bit << 7)
        if pattern == 0x7E {
            // Flagge: Der Rahmen endete byteweise, danach stehen die ersten
            // sieben Flaggenbits im Akkumulator.
            var result: [UInt8]?
            if inFrame, bitCount == 7, buffer.count >= minimumBytes + 2, CRC16X25.isValid(frameWithFCS: buffer) {
                result = Array(buffer.dropLast(2))
            }
            inFrame = true
            buffer.removeAll(keepingCapacity: true)
            accumulator = 0
            bitCount = 0
            return result
        }
        if pattern == 0xFE {
            // Sieben Einsen: Abbruch, warten auf die nächste Flagge.
            inFrame = false
            return nil
        }
        if pattern & 0xFC == 0x7C {
            return nil   // eingefügte Null nach fünf Einsen
        }
        guard inFrame else { return nil }
        accumulator = (accumulator >> 1) | (bit << 7)
        bitCount += 1
        if bitCount == 8 {
            buffer.append(accumulator)
            bitCount = 0
            accumulator = 0
            if buffer.count > maximumBytes + 2 { inFrame = false }
        }
        return nil
    }
}

/// Gegenstück zum Deframer: baut Bitfolgen zum Senden – genutzt von den Tests.
enum HDLCEncoder {
    /// Datenbits (vor NRZI): Vorlaufflaggen, Nutzdaten mit FCS und
    /// Bit-Stuffing, Endflagge(n).
    static func bits(for payload: [UInt8], leadingFlags: Int = 1, trailingFlags: Int = 1) -> [UInt8] {
        let flag: [UInt8] = [0, 1, 1, 1, 1, 1, 1, 0]
        var out: [UInt8] = []
        for _ in 0..<leadingFlags { out += flag }
        let fcs = CRC16X25.checksum(payload)
        var ones = 0
        for byte in payload + [UInt8(fcs & 0xFF), UInt8(fcs >> 8)] {
            for k in 0..<8 {
                let bit = (byte >> k) & 1
                out.append(bit)
                if bit == 1 {
                    ones += 1
                    if ones == 5 { out.append(0); ones = 0 }
                } else {
                    ones = 0
                }
            }
        }
        for _ in 0..<trailingFlags { out += flag }
        return out
    }

    /// NRZI-Kodierung: eine Null wechselt den Pegel, eine Eins hält ihn.
    static func nrzi(_ bits: [UInt8], initial: UInt8 = 0) -> [UInt8] {
        var level = initial
        return bits.map { bit in
            if bit == 0 { level ^= 1 }
            return level
        }
    }
}

/// NRZI-Dekodierung: gleicher Pegel wie zuvor → 1, Wechsel → 0.
struct NRZIDecoder {
    private var last: UInt8 = 0

    mutating func decode(_ level: UInt8) -> UInt8 {
        defer { last = level }
        return level == last ? 1 : 0
    }
}

/// Bit-Takt-Rückgewinnung wie in direwolf: Ein 32-Bit-Phasenzähler läuft
/// je Abtastwert um `Bitrate/Abtastrate` weiter; beim Überlauf wird
/// abgetastet (Bitmitte), bei jedem Vorzeichenwechsel des Signals wird die
/// Phase Richtung null gezogen (Bitgrenze). Der Abtastwert wird zwischen
/// den beiden Nachbarwerten linear interpoliert.
struct BitClock {
    private let step: Int64
    private var phase: Int64 = 0
    private var last: Float = 0
    private let inertia: Double

    init(bitRate: Double, sampleRate: Double, inertia: Double = 0.7) {
        step = Int64((bitRate / sampleRate * 4_294_967_296).rounded())
        self.inertia = inertia
    }

    /// Verarbeitet einen Wert; liefert den Wert zur Bitmitte, wenn fällig.
    mutating func push(_ x: Float) -> Float? {
        var sample: Float?
        let previous = phase
        phase += step
        if phase >= 2_147_483_648 {
            phase -= 4_294_967_296
            // Überlaufzeitpunkt zwischen `last` und `x` interpolieren.
            let fraction = Float(Double(2_147_483_648 - previous) / Double(step))
            sample = last + (x - last) * min(max(fraction, 0), 1)
        }
        if (x >= 0) != (last >= 0) {
            phase = Int64(Double(phase) * inertia)
        }
        last = x
        return sample
    }
}

/// Schmalband-FM-Vorstufe für Datendienste: der HackRF liegt 240 kHz unter
/// der Mittenfrequenz (Gleichspannungsspitze außerhalb), Mischen mit dem
/// Periode-10-Oszillator, Tiefpass ÷10 auf 240 kHz, je Kanal mischen,
/// Kanalfilter ÷5 auf 48 kHz und FM-Diskriminator (rad/Abtastwert).
final class FMChannelizer: @unchecked Sendable {
    static let inputRate = 2_400_000.0
    static let offset = 240_000.0
    static let midRate = 240_000.0
    static let outputRate = 48_000.0

    /// Kanalversatz zur Mittenfrequenz in Hz.
    let channelOffsets: [Double]
    /// Kanalleistung in dBFS je Kanal.
    private(set) var channelPowerDB: [Float]

    private let stage1: [Float]
    private let channelFilter: [Float]
    private let oscRe: [Float]
    private let oscIm: [Float]
    private var oscIndex = 0
    private var histRe: [Float] = []
    private var histIm: [Float] = []
    private var channels: [ChannelState]

    private struct ChannelState {
        var phase = 0.0
        var histRe: [Float] = []
        var histIm: [Float] = []
        var lastRe: Float = 1
        var lastIm: Float = 0
    }

    init(channelOffsets: [Double], stage1Cutoff: Double, channelCutoff: Double) {
        self.channelOffsets = channelOffsets
        channelPowerDB = channelOffsets.map { _ in -100 }
        stage1 = RadioDemodulator.lowpass(taps: 63, cutoff: stage1Cutoff, rate: Self.inputRate)
        channelFilter = RadioDemodulator.lowpass(taps: 63, cutoff: channelCutoff, rate: Self.midRate)
        oscRe = (0..<10).map { Float(cos(-2 * Double.pi * Double($0) / 10)) }
        oscIm = (0..<10).map { Float(sin(-2 * Double.pi * Double($0) / 10)) }
        channels = channelOffsets.map { _ in ChannelState() }
    }

    func reset() {
        histRe = []; histIm = []
        channels = channelOffsets.map { _ in ChannelState() }
    }

    /// IQ-Block (int8, 2,4 MS/s) → Diskriminatorwerte je Kanal (48 kHz).
    func process(_ iq: Data) -> [[Float]] {
        let count = iq.count / 2
        guard count > 0 else { return channelOffsets.map { _ in [] } }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var k = oscIndex
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                let c = oscRe[k], s = oscIm[k]
                re[n] = i * c - q * s
                im[n] = i * s + q * c
                k += 1
                if k == 10 { k = 0 }
            }
            oscIndex = k
        }
        let (midRe, midIm) = RadioDemodulator.decimateComplex(re, im, history: &histRe, &histIm, filter: stage1, factor: 10)
        var outputs: [[Float]] = []
        for index in channels.indices {
            var state = channels[index]
            var cRe = midRe, cIm = midIm
            let offset = channelOffsets[index]
            if offset != 0 {
                let increment = -2 * Double.pi * offset / Self.midRate
                for n in cRe.indices {
                    let c = Float(cos(state.phase)), s = Float(sin(state.phase))
                    let r = cRe[n], i = cIm[n]
                    cRe[n] = r * c - i * s
                    cIm[n] = r * s + i * c
                    state.phase += increment
                }
                state.phase = state.phase.truncatingRemainder(dividingBy: 2 * .pi)
            }
            let (bRe, bIm) = RadioDemodulator.decimateComplex(cRe, cIm, history: &state.histRe, &state.histIm,
                                                              filter: channelFilter, factor: 5)
            var power: Float = 0
            var out = [Float](repeating: 0, count: bRe.count)
            var pr = state.lastRe, pi = state.lastIm
            for n in bRe.indices {
                let r = bRe[n], i = bIm[n]
                power += r * r + i * i
                out[n] = atan2f(i * pr - r * pi, r * pr + i * pi)
                pr = r; pi = i
            }
            state.lastRe = pr; state.lastIm = pi
            if !bRe.isEmpty { channelPowerDB[index] = 10 * log10(max(power / Float(bRe.count), 1e-12)) }
            channels[index] = state
            outputs.append(out)
        }
        return outputs
    }
}
