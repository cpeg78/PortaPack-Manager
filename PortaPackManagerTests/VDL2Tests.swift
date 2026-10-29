import Foundation
import Testing
@testable import PortaPackManager

/// VDL2-Sender für die Tests: AVLC-Rahmen → Bitstopfen → Reed-Solomon →
/// Verschachtelung → Kopf → Verwürfler → D8PSK (Raised Cosine, α 0,6).
enum VDL2TestTransmitter {
    static func avlc(source: UInt32, destination: UInt32, acarsText: String) -> [UInt8] {
        var body = VDL2Coding.encodeAddress(destination, type: .groundDelegated, status: false)
            + VDL2Coding.encodeAddress(source, type: .aircraft, status: false)
        body.append(0x00)                                   // I-Rahmen
        // ACARS: Modus 2, Kennzeichen, Quittung NAK, Label H1, Block-ID 3, STX, Text, ETX
        var acars: [UInt8] = [0xFF, 0xFF, 0x01]
        acars += Array("2.D-AIZZ".utf8) + [0x15] + Array("H1".utf8) + Array("3".utf8) + [0x02]
        acars += Array("M01ALH123A".utf8) + Array(acarsText.utf8) + [0x03, 0x41, 0x42, 0x7F]
        body += acars
        let fcs = VDL2Coding.crc16(body) ^ 0xFFFF
        return body + [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
    }

    static func stuffed(_ frame: [UInt8]) -> [UInt8] {
        let flag: [UInt8] = [0, 1, 1, 1, 1, 1, 1, 0]
        var out = flag
        var ones = 0
        for bit in VDL2Coding.bitsLSBFirst(frame) {
            out.append(bit)
            if bit == 1 { ones += 1; if ones == 5 { out.append(0); ones = 0 } } else { ones = 0 }
        }
        return out + flag
    }

    /// Daten- und Prüfbits nach dem Kopf (vor dem Verwürfler).
    static func payloadBits(_ stream: [UInt8]) -> (bits: [UInt8], lengthBits: Int) {
        let length = stream.count
        let layout = VDL2Coding.layout(lengthBits: length)!
        var bytes = VDL2Coding.bytesLSBFirst(stream + [UInt8](repeating: 0, count: (8 - length % 8) % 8))
        bytes += [UInt8](repeating: 0, count: max(0, layout.dataOctets - bytes.count))
        // Blöcke bilden wie der Empfänger sie liest (zeilenweise Tabelle).
        var table = [[UInt8]](repeating: [UInt8](repeating: 0, count: 255), count: layout.blocks)
        _ = VDL2Coding.deinterleave(bytes, rows: layout.blocks, width: 249, offset: 0, into: &table)
        let lastFEC = VDL2Coding.fecCount(lastBlock: layout.lastBlockOctets)
        for r in 0..<layout.blocks {
            let parity = VDL2ReedSolomon.parity(Array(table[r][0..<249]))
            let count = r == layout.blocks - 1 ? lastFEC : 6
            for i in 0..<count { table[r][249 + i] = parity[i] }
        }
        let fecRows = lastFEC == 0 ? layout.blocks - 1 : layout.blocks
        let fec = fecRows > 0 ? VDL2Coding.interleave(Array(table[0..<fecRows]), count: layout.fecOctets, width: 6, offset: 249) : []
        return (VDL2Coding.bitsLSBFirst(bytes) + VDL2Coding.bitsLSBFirst(fec), length)
    }

    static func bits(frames: [[UInt8]]) -> [UInt8] {
        let stream = frames.flatMap(stuffed)
        let (payload, length) = payloadBits(stream)
        let header = VDL2Coding.encodeHeader(lengthBits: length)
        var bits = (0..<25).map { UInt8((header >> UInt32(24 - $0)) & 1) } + payload
        var state = VDL2Coding.scramblerSeed
        VDL2Coding.scramble(&bits, state: &state)
        while bits.count % 3 != 0 { bits.append(0) }
        return bits
    }

    /// Symbolphasen (Vielfache von π/4): Präambel, dann Daten differentiell.
    static func phases(bits: [UInt8]) -> [Int] {
        var phases = VDL2Coding.preamblePhases
        var phase = phases.last!
        for k in stride(from: 0, to: bits.count, by: 3) {
            let value = bits[k] << 2 | bits[k + 1] << 1 | bits[k + 2]
            let symbol = VDL2Coding.gray.firstIndex(of: value)!
            phase += symbol
            phases.append(phase)
        }
        return phases + [phase, phase, phase]
    }

    /// int8-IQ bei 2,1 MS/s, Kanal bei `offset` Hz, mit Frequenzablage und Rauschen.
    static func iq(phases: [Int], offset: Double, frequencyError: Double = 0, amplitude: Double = 40,
                   noise: Int = 0, lead: Double = 0.01, seed: UInt32 = 7) -> Data {
        let rate = VDL2Channelizer.inputRate, sps = rate / VDL2Coding.symbolRate
        let total = Int(lead * rate) + Int(Double(phases.count + 8) * sps) + Int(lead * rate)
        let start = Double(Int(lead * rate))
        var data = Data(count: total * 2)
        var state = seed
        let alphaRC = 0.6
        func pulse(_ t: Double) -> Double {
            if abs(t) < 1e-9 { return 1 }
            let x = .pi * t, d = 1 - 4 * alphaRC * alphaRC * t * t
            if abs(d) < 1e-9 { return .pi / 4 * sin(x) / x }
            return sin(x) / x * cos(alphaRC * x) / d
        }
        let symRe = phases.map { cos(Double($0) * .pi / 4) }, symIm = phases.map { sin(Double($0) * .pi / 4) }
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<total {
                let t = (Double(n) - start) / sps
                var re = 0.0, im = 0.0
                let center = Int(t.rounded())
                let low = max(0, center - 5), high = min(phases.count - 1, center + 5)
                if low <= high { for k in low...high {
                    let w = pulse(t - Double(k))
                    re += w * symRe[k]; im += w * symIm[k]
                } }
                let angle = 2 * .pi * (offset + frequencyError) * Double(n) / rate
                let c = cos(angle), s = sin(angle)
                var i = amplitude * (re * c - im * s), q = amplitude * (re * s + im * c)
                if noise > 0 {
                    state = state &* 1_664_525 &+ 1_013_904_223; i += Double(Int(state >> 16) % (2 * noise + 1) - noise)
                    state = state &* 1_664_525 &+ 1_013_904_223; q += Double(Int(state >> 16) % (2 * noise + 1) - noise)
                }
                p[2 * n] = Int8(max(-127, min(127, i.rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, q.rounded())))
            }
        }
        return data
    }
}

@Suite("VDL2")
struct VDL2Tests {
    @Test("Burst beginnt mitten im Flag: kein Absturz beim Entstopfen")
    func unstuffPartialFlag() {
        // Nur die letzten sieben Bits eines Flags, dann ein Rahmen mit Flag.
        let byte: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0]
        let flag: [UInt8] = [0, 1, 1, 1, 1, 1, 1, 0]
        let bits = Array(flag.dropFirst()) + byte + flag
        #expect(VDL2Coding.unstuffFrames(bits) == [byte])
    }

    @Test("Kopf: Länge hin und zurück, Einzelfehler korrigiert")
    func header() {
        for length in [100, 1234, 8191] {
            let word = VDL2Coding.encodeHeader(lengthBits: length)
            #expect(VDL2Coding.syndrome(word) == 0)
            #expect(VDL2Coding.decodeHeader(word)?.lengthBits == length)
            #expect(VDL2Coding.decodeHeader(word ^ (1 << 7))?.lengthBits == length)
        }
    }

    @Test("Reed-Solomon (255,249): drei Fehler, und kurze Blöcke mit Auslöschungen")
    func reedSolomon() {
        let data = (0..<249).map { UInt8(($0 * 37 + 11) & 0xFF) }
        var word = data + VDL2ReedSolomon.parity(data)
        word[3] ^= 0x55; word[100] ^= 0x01; word[250] ^= 0xFF
        #expect(VDL2ReedSolomon.decode(&word) == 3)
        #expect(Array(word[0..<249]) == data)

        // Letzter Block mit 40 Byte und 4 Prüfbytes: 2 Auslöschungen + 1 Fehler.
        var short = [UInt8](repeating: 0, count: 255)
        for i in 0..<40 { short[i] = UInt8(i * 7 & 0xFF) }
        let parity = VDL2ReedSolomon.parity(Array(short[0..<249]))
        for i in 0..<4 { short[249 + i] = parity[i] }
        let original = short
        short[10] ^= 0x33
        #expect(VDL2ReedSolomon.decode(&short, erasures: [253, 254]) != nil)
        #expect(Array(short[0..<253]) == Array(original[0..<253]))
    }

    @Test("Bits → Rahmen: ACARS über AVLC wird gelesen")
    func frameChain() throws {
        let frame = VDL2TestTransmitter.avlc(source: 0x3C6586, destination: 0x10916A, acarsText: "HALLO VDL2")
        let parsed = try #require(VDL2Coding.parseAVLC(frame))
        #expect(parsed.source == 0x3C6586 && parsed.sourceType == .aircraft)
        #expect(parsed.destination == 0x10916A && parsed.destinationType == .groundDelegated)
        #expect(parsed.acars?.registration == "D-AIZZ")
        #expect(parsed.acars?.label == "H1")
        #expect(parsed.acars?.text.hasSuffix("HALLO VDL2") == true)

        var bits = VDL2TestTransmitter.bits(frames: [frame, frame])
        var state = VDL2Coding.scramblerSeed
        VDL2Coding.scramble(&bits, state: &state)
        let header = bits[0..<25].reduce(UInt32(0)) { $0 << 1 | UInt32($1) }
        let decoded = try #require(VDL2Coding.decodeHeader(header))
        let layout = try #require(VDL2Coding.layout(lengthBits: decoded.lengthBits))
        let result = try #require(VDL2ChannelDecoder.frames(bits: Array(bits.dropFirst(25)), layout: layout, lengthBits: decoded.lengthBits))
        #expect(result.frames.count == 2)
        #expect(result.frames.allSatisfy { $0 == frame })
    }

    @Test("Funkstrecke: 2,1 MS/s, Kanal 136,975 MHz, Ablage und Rauschen")
    func radio() {
        let frame = VDL2TestTransmitter.avlc(source: 0x4CA4EF, destination: 0x2A1B3C, acarsText: String(repeating: "POSITION REPORT ", count: 12))
        let phases = VDL2TestTransmitter.phases(bits: VDL2TestTransmitter.bits(frames: [frame]))
        for (error, noise) in [(0.0, 0), (400.0, 6), (-900.0, 10)] {
            let receiver = VDL2Receiver()
            let iq = VDL2TestTransmitter.iq(phases: phases, offset: 136_975_000 - VDL2Receiver.centerHz,
                                            frequencyError: error, noise: noise)
            var frames: [VDL2Frame] = []
            var offset = 0
            while offset < iq.count {
                frames += receiver.process(iq.subdata(in: offset..<min(offset + 262_144, iq.count)))
                offset += 262_144
            }
            #expect(frames.count == 1, "Ablage \(error) Hz, Rauschen \(noise): \(receiver.syncs) Syncs, \(receiver.bursts) Bursts, \(receiver.badBursts) schlecht")
            #expect(frames.first?.frequencyMHz == 136.975)
            #expect(frames.first?.acars?.registration == "D-AIZZ")
        }
    }
}
