import Foundation
@testable import PortaPackManager

/// Testsignale für METEOR-LRPT: MSU-MR-Pakete (JPEG-kodiert), VCDUs,
/// CADUs, Faltungscode und (O)QPSK-Basisband.
enum MeteorSignalFactory {
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func byte() -> UInt8 { UInt8(next() & 0xFF) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        /// Normalverteilt (Box-Muller).
        mutating func gaussian() -> Double {
            let u = max(unit(), 1e-12), v = unit()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    // MARK: JPEG

    struct BitWriter {
        var bytes: [UInt8] = []
        var current: UInt8 = 0
        var count = 0
        mutating func write(_ value: Int, _ length: Int) {
            guard length > 0 else { return }
            for i in stride(from: length - 1, through: 0, by: -1) {
                current = current << 1 | UInt8((value >> i) & 1)
                count += 1
                if count == 8 { bytes.append(current); current = 0; count = 0 }
            }
        }
        mutating func finish() -> [UInt8] {
            while count != 0 { write(1, 1) }
            return bytes
        }
    }

    static let dcCodes = MeteorJPEG.codes(bits: MeteorJPEG.dcBits, values: MeteorJPEG.dcValues)
    static let acCodes = MeteorJPEG.codes(bits: MeteorJPEG.acBits, values: MeteorJPEG.acValues)

    static func category(_ v: Int) -> Int {
        var a = abs(v), c = 0
        while a > 0 { a >>= 1; c += 1 }
        return c
    }

    static func amplitudeBits(_ v: Int, _ size: Int) -> Int { v >= 0 ? v : v + (1 << size) - 1 }

    /// Vorwärts-DCT eines 8×8-Blocks (Pixel − 128), natürliche Reihenfolge.
    static func forwardDCT(_ block: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 64)
        for u in 0..<8 {
            for v in 0..<8 {
                var sum = 0.0
                for x in 0..<8 {
                    for y in 0..<8 {
                        sum += block[x * 8 + y] * cos(Double(2 * x + 1) * Double(u) * .pi / 16)
                            * cos(Double(2 * y + 1) * Double(v) * .pi / 16)
                    }
                }
                let cu = u == 0 ? 1 / 2.0.squareRoot() : 1, cv = v == 0 ? 1 / 2.0.squareRoot() : 1
                out[u * 8 + v] = sum * cu * cv / 4
            }
        }
        return out
    }

    /// Nutzdaten eines MSU-MR-Pakets für einen Streifen 8 × 112 Pixel.
    static func segmentPayload(pixels: [UInt8], mcuNumber: Int, quality: Int = 80) -> [UInt8] {
        precondition(pixels.count == 8 * MeteorJPEG.segmentWidth)
        let table = MeteorJPEG.quantization(quality: quality)
        var writer = BitWriter()
        var previousDC = 0
        for m in 0..<MeteorJPEG.mcusPerSegment {
            var block = [Double](repeating: 0, count: 64)
            for r in 0..<8 {
                for c in 0..<8 { block[r * 8 + c] = Double(pixels[r * MeteorJPEG.segmentWidth + m * 8 + c]) - 128 }
            }
            let coefficients = forwardDCT(block)
            let zz = (0..<64).map { z -> Int in
                let p = MeteorJPEG.zigzag[z]
                return Int((coefficients[p] / Double(table[p])).rounded())
            }
            let diff = zz[0] - previousDC
            previousDC = zz[0]
            let dcCat = category(diff)
            let dcCode = dcCodes[UInt8(dcCat)]!
            writer.write(dcCode.code, dcCode.length)
            writer.write(amplitudeBits(diff, dcCat), dcCat)
            var run = 0
            let last = (1..<64).last { zz[$0] != 0 } ?? 0
            if last > 0 {
                for k in 1...last {
                    if zz[k] == 0 { run += 1; continue }
                    while run > 15 {
                        let zrl = acCodes[0xF0]!
                        writer.write(zrl.code, zrl.length)
                        run -= 16
                    }
                    let size = category(zz[k])
                    let code = acCodes[UInt8(run << 4 | size)]!
                    writer.write(code.code, code.length)
                    writer.write(amplitudeBits(zz[k], size), size)
                    run = 0
                }
            }
            if last < 63 {
                let eob = acCodes[0x00]!
                writer.write(eob.code, eob.length)
            }
        }
        let header: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, UInt8(mcuNumber), 0, 0, 0xFF, 0xF0, UInt8(quality)]
        return header + writer.finish()
    }

    /// Testbild eines Kanals: Verläufe mit kanalabhängigem Muster.
    static func pixel(channel: Int, row: Int, column: Int) -> UInt8 {
        let v = (column / 4 + row * 2 + channel * 40) % 200 + 20
        return UInt8(v)
    }

    /// Pakete für `groups` Zeilengruppen und die Kanäle (APID-Reihenfolge),
    /// Paketzähler wie am Satelliten: 14 je Kanal, dann ein Telemetriepaket.
    static func imagePackets(apids: [Int], groups: Int, startSequence: Int = 100) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        var sequence = startSequence
        for g in 0..<groups {
            for apid in apids {
                for s in 0..<MeteorJPEG.segmentsPerLine {
                    var strip = [UInt8](repeating: 0, count: 8 * MeteorJPEG.segmentWidth)
                    for r in 0..<8 {
                        for c in 0..<MeteorJPEG.segmentWidth {
                            strip[r * MeteorJPEG.segmentWidth + c] = pixel(channel: apid - 63, row: g * 8 + r,
                                                                            column: s * MeteorJPEG.segmentWidth + c)
                        }
                    }
                    let payload = segmentPayload(pixels: strip, mcuNumber: s * MeteorJPEG.mcusPerSegment)
                    packets.append(MeteorPacketDemux.packet(apid: apid, sequence: sequence & 0x3FFF, payload: payload))
                    sequence += 1
                }
            }
            packets.append(MeteorPacketDemux.packet(apid: 70, sequence: sequence & 0x3FFF,
                                                    payload: [UInt8](repeating: 0x55, count: 60)))
            sequence += 1
        }
        return packets
    }

    // MARK: Kanal

    /// VCDU (892 Bytes) → CADU (1024 Bytes): RS, Verwürfelung, Synchronwort.
    static func cadu(_ vcdu: [UInt8]) -> [UInt8] {
        var block = MeteorReedSolomon.encodeInterleaved(vcdu)
        MeteorRandomizer.apply(&block)
        return [0x1A, 0xCF, 0xFC, 0x1D] + block
    }

    static func bits(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { byte in (0..<8).reversed().map { (byte >> UInt8($0)) & 1 } }
    }

    /// Kanalbits: optional NRZ-M, dann Faltungscode.
    static func codedBits(_ cadus: [[UInt8]], differential: Bool) -> [UInt8] {
        var data = cadus.flatMap { bits($0) }
        if differential {
            var last: UInt8 = 0
            for i in data.indices {
                last ^= data[i]
                data[i] = last
            }
        }
        return MeteorConvolutionalCode.encode(data)
    }

    /// Weiche Werte: 0 → +A, 1 → −A, plus Rauschen.
    static func soft(_ coded: [UInt8], amplitude: Double = 40, noise: Double, random: inout Random) -> [Int8] {
        coded.map { bit in
            let v = (bit == 0 ? amplitude : -amplitude) + noise * random.gaussian()
            return Int8(max(-127, min(127, v.rounded())))
        }
    }

    /// (O)QPSK-Basisband mit RRC-Pulsformung, Frequenzablage, Phase,
    /// Taktversatz und Rauschen (`snr` in dB je Symbol).
    static func baseband(_ coded: [UInt8], samplesPerSymbol sps: Int, oqpsk: Bool, frequency: Double,
                         sampleRate: Double, phase: Double, snr: Double, delay: Int,
                         random: inout Random) -> (re: [Float], im: [Float]) {
        let symbols = coded.count / 2
        let pulse = MeteorDemodulator.rootRaisedCosine(samplesPerSymbol: Double(sps), rolloff: 0.6, span: 8)
        let total = (symbols + 16) * sps + pulse.count + delay
        var iBase = [Double](repeating: 0, count: total)
        var qBase = [Double](repeating: 0, count: total)
        let half = oqpsk ? sps / 2 : 0
        for k in 0..<symbols {
            let a = coded[2 * k] == 0 ? 1.0 : -1.0
            let b = coded[2 * k + 1] == 0 ? 1.0 : -1.0
            let start = delay + k * sps
            for (j, h) in pulse.enumerated() {
                iBase[start + j] += a * Double(h)
                qBase[start + half + j] += b * Double(h)
            }
        }
        // Rauschen: Es/N0 bezogen auf die Symbolenergie nach dem RRC.
        let symbolEnergy = 2.0
        let n0 = symbolEnergy / pow(10, snr / 10)
        let sigma = (n0 / 2).squareRoot()
        var re = [Float](repeating: 0, count: total)
        var im = [Float](repeating: 0, count: total)
        for n in 0..<total {
            let theta = phase + 2 * .pi * frequency * Double(n) / sampleRate
            let c = cos(theta), s = sin(theta)
            let i = iBase[n], q = qBase[n]
            re[n] = Float((i * c - q * s) * 0.1 + sigma * 0.1 * random.gaussian())
            im[n] = Float((i * s + q * c) * 0.1 + sigma * 0.1 * random.gaussian())
        }
        return (re, im)
    }
}
