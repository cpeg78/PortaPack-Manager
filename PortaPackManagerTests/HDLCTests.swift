import Foundation
import Testing
@testable import PortaPackManager

/// Erzeugt FM-IQ wie vom HackRF (int8, 2,4 MS/s, 240 kHz unter der Mitte).
enum TestSignals {
    /// Reproduzierbares Rauschen (LCG + Box-Muller).
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// Summiert Träger mit den gegebenen Momentanfrequenzen (Hz relativ zur
    /// Mitte, je Abtastwert bei 2,4 MS/s) und fügt Rauschen hinzu.
    static func iq(carriers: [[Double]], amplitude: Double = 40, noise: Double = 0, seed: UInt64 = 1) -> Data {
        let n = carriers.map(\.count).max() ?? 0
        let rate = FMChannelizer.inputRate
        var phases = [Double](repeating: 0, count: carriers.count)
        var rng = Noise(state: seed)
        var data = Data(count: n * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<n {
                var i = noise * rng.gaussian(), q = noise * rng.gaussian()
                for c in carriers.indices where k < carriers[c].count {
                    phases[c] += 2 * .pi * (FMChannelizer.offset + carriers[c][k]) / rate
                    i += amplitude * cos(phases[c])
                    q += amplitude * sin(phases[c])
                }
                p[2 * k] = Int8(max(-127, min(127, i.rounded())))
                p[2 * k + 1] = Int8(max(-127, min(127, q.rounded())))
            }
        }
        return data
    }

    /// Verarbeitet IQ in Blöcken, wie sie vom HackRF kommen.
    static func blocks(_ data: Data, size: Int = 262_144) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }
}

@Suite("HDLC")
struct HDLCTests {
    @Test("CRC-16/X.25 hat den Prüfwert 0x906E")
    func crcCheckValue() {
        #expect(CRC16X25.checksum(Array("123456789".utf8)) == 0x906E)
    }

    @Test("Rahmen übersteht Bit-Stuffing und NRZI")
    func roundTrip() {
        // Viele Einsen erzwingen eingefügte Nullen.
        let payload: [UInt8] = [0xFF, 0xFF, 0x7E, 0x7E, 0x01, 0xFE, 0x3F, 0xFC, 0x55, 0xAA, 0x00, 0xFF, 0x12]
        let levels = HDLCEncoder.nrzi(HDLCEncoder.bits(for: payload, leadingFlags: 3, trailingFlags: 2))
        var nrzi = NRZIDecoder()
        var deframer = HDLCDeframer(minimumBytes: 5)
        var frames: [[UInt8]] = []
        for level in levels {
            if let frame = deframer.push(nrzi.decode(level)) { frames.append(frame) }
        }
        #expect(frames == [payload])
    }

    @Test("Verfälschter Rahmen wird verworfen")
    func corrupted() {
        var bits = HDLCEncoder.bits(for: Array("Hallo Welt, APRS!".utf8), leadingFlags: 2)
        bits[40] ^= 1
        var deframer = HDLCDeframer(minimumBytes: 5)
        #expect(bits.compactMap { deframer.push($0) }.isEmpty)
    }
}
