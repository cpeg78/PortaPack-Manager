import Foundation
import Testing
@testable import PortaPackManager

@Suite("FLARM/OGN")
struct FLARMTests {
    @Test("CRC-16/CCITT über die Nutzbytes")
    func crc() {
        // Prüfwert von „123456789“ für CRC-16/CCITT-FALSE (Start 0xFFFF) = 0x29B1.
        #expect(FLARMLink.crc16(Array("123456789".utf8)[...]) == 0x29B1)
    }

    /// Erzeugt GFSK-IQ (2 MS/s) für Sync + Nutzbytes, MSB zuerst.
    static func iq(bytes: [UInt8], amplitude: Float = 60, noise: Float = 1.5) -> Data {
        let spb = FLARMDemodulator.samplesPerBit * FLARMDemodulator.decimation   // 20 Abtastwerte/Bit bei 2 MS/s
        var bits: [Float] = []
        for byte in bytes { for k in 0..<8 { bits.append(Float((byte >> (7 - k)) & 1) == 1 ? 1 : -1) } }
        let lead = 2000, trail = 6000
        var phase: Float = 0
        let dev = Float(2 * Double.pi * 50_000 / FLARMDemodulator.inputRate)   // ±50 kHz Hub
        var rng = SystemRandomNumberGenerator()
        var data = Data(count: (lead + bits.count * spb + trail) * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var idx = 0
            func put(_ i: Float, _ q: Float) {
                // Auf +fs/4 (500 kHz) drehen, damit der −fs/4-Mischer es auf Basisband bringt.
                var ri = i, rq = q
                switch idx & 3 {
                case 1: ri = -q; rq = i
                case 2: ri = -i; rq = -q
                case 3: ri = q; rq = -i
                default: break
                }
                p[2 * idx] = Int8(max(-127, min(127, (ri + Float.random(in: -noise...noise, using: &rng)).rounded())))
                p[2 * idx + 1] = Int8(max(-127, min(127, (rq + Float.random(in: -noise...noise, using: &rng)).rounded())))
                idx += 1
            }
            for _ in 0..<lead { put(0, 0) }
            for bit in bits {
                for _ in 0..<spb {
                    phase += dev * bit
                    put(amplitude * cos(phase), amplitude * sin(phase))
                }
            }
            for _ in 0..<trail { put(0, 0) }
        }
        return data
    }

    @Test("Erkennt ein Paket mit gültigem CRC über GFSK")
    func detect() throws {
        var packet: [UInt8] = FLARMLink.defaultSync
        var payload: [UInt8] = (0..<(FLARMLink.packetBytes - 2)).map { UInt8(($0 * 7 + 3) & 0xFF) }
        let crc = FLARMLink.crc16(payload[...])
        payload += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        packet += payload
        let demod = FLARMDemodulator()
        var packets = demod.process(Self.iq(bytes: packet))
        packets += demod.process(Data(count: 2 * 8192))
        let found = try #require(packets.first { $0.crcValid })
        #expect(found.bytes == payload)
    }

    @Test("Rauschen allein liefert keine gültigen Pakete")
    func noise() {
        let demod = FLARMDemodulator()
        let packets = demod.process(Self.iq(bytes: [], amplitude: 0, noise: 8))
        #expect(!packets.contains { $0.crcValid })
    }
}
