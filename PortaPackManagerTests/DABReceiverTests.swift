import Foundation
import Testing
@testable import PortaPackManager

@Suite("DAB: Empfangskette")
struct DABReceiverTests {
    /// DSE mit PAD (ein Lauftext-Segment) vor eine AU setzen.
    private func withPAD(_ unit: [UInt8], label: String) -> [UInt8] {
        let chars = Array(label.utf8)
        var group: [UInt8] = [0x80 | 0x40 | 0x20 | UInt8(chars.count - 1), 0xF0] + chars
        let crc = DABCRC.ccitt(group)
        group += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        let field = group + [UInt8](repeating: 0, count: 24 - group.count)
        let xpad: [UInt8] = [UInt8(5 << 5 | 2), 0x00] + field          // CI: 24 Bytes, Typ 2
        let pad = xpad.reversed() + [0x20, 0x02]
        // ID_DSE (100), Tag 0, byte_align 1 → 0x81; dann Länge
        return [0x81, UInt8(pad.count)] + pad + unit
    }

    @Test("Vom OFDM-Signal bis zu Ton und Lauftext")
    func endToEnd() throws {
        // Unterkanal 3: EEP 3-A, 48 kbit/s, ab CU 0 (wie exampleFIBs)
        let subchannel = DABSubchannel(id: 3, startCU: 0, sizeCU: 36, protection: .eep(profileB: false, level: 3))
        let puncturing = subchannel.puncturing!
        let s = subchannel.bitrate / 8

        // AAC-LC, 48 kHz, Mono: 6 AUs je Superframe
        let units = DABAudioTestSupport.encodeTone(frequency: 1000, seconds: 3, sampleRate: 48_000,
                                                   channels: 1, he: false, bitrate: 32_000)
        try #require(units.count > 100)
        var logical: [[UInt8]] = []
        var index = 0
        while index + 6 <= units.count {
            var group = Array(units[index..<(index + 6)])
            group[0] = withPAD(group[0], label: "DAB+ Testton")
            let sf = try #require(DABAudioTestSupport.superframe(units: group, formatByte: 0x40, s: s))
            let length = sf.count / 5
            for f in 0..<5 { logical.append(Array(sf[(f * length)..<((f + 1) * length)])) }
            index += 6
        }

        // Kanalcodierung + Zeitverschachtelung über alle CIFs
        let prbs = DABTables.prbs(count: puncturing.dataBits)
        let coded: [[UInt8]] = logical.map { bytes in
            var bits = DABBits.unpack(bytes)
            for i in bits.indices { bits[i] ^= prbs[i] }
            return puncturing.puncture(DABConvolutionalCode.encode(bits))
        }
        let fic = DABTestTransmitter.ficBits(DABTestTransmitter.exampleFIBs())
        let length = subchannel.sizeCU * 64
        let frameCount = min(16, logical.count / 4)
        try #require(frameCount == 16)
        var frames: [[UInt8]] = []
        for f in 0..<frameCount {
            var msc = [UInt8](repeating: 0, count: 72 * DABMode.bitsPerSymbol)
            for c in 0..<4 {
                let r = f * 4 + c
                for i in 0..<length {
                    let source = r - DABSubchannelDecoder.interleaveMap[i & 15]
                    msc[c * DABMode.cifBits + i] = source >= 0 ? coded[source][i] : 0
                }
            }
            frames.append(fic + msc)
        }
        let signal = DABTestTransmitter.frames(frames, frequencyOffset: 4_321, noise: 0.2, seed: 21)

        let receiver = DABReceiver()
        final class Sink: @unchecked Sendable { var left: [Float] = [] }
        let sink = Sink()
        receiver.audioHandler = { left, _ in sink.left += left }
        receiver.select(serviceID: 0xD310)
        var start = 0
        while start < signal.re.count {
            let end = min(start + 50_000, signal.re.count)
            receiver.process(re: Array(signal.re[start..<end]), im: Array(signal.im[start..<end]))
            start = end
        }
        let status = receiver.status()
        #expect(status.synchronized)
        #expect(status.ensemble.label == "Test-Mux")
        #expect(status.format == "AAC-LC · Mono · 48 kHz")
        #expect(status.accessUnitsGood >= 12)
        #expect(status.accessUnitsBad == 0)
        #expect(status.dynamicLabel == "DAB+ Testton")
        #expect(sink.left.count > 20_000)
        let frequency = DABAudioTestSupport.dominantFrequency(sink.left, rate: 48_000)
        #expect(abs(frequency - 1000 * 16 / 15) < 20)
    }
}
