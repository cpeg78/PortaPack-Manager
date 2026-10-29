import Foundation
import Testing
@testable import PortaPackManager

@Suite("ACARS")
struct ACARSTests {
    /// Reproduzierbares Gaußrauschen (Box-Muller über einen LCG).
    struct Noise {
        var seed: UInt64
        mutating func uniform() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(seed >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }

    private let downlink = ACARSEncoder.block(registration: ".D-AIBC", acknowledge: 0x15, label: "H1", blockID: "3",
                                              messageNumber: "M01A", flight: "LH1234", text: "#DFBTEST POS N50123E008456")
    private let uplink = ACARSEncoder.block(registration: "D-ABYA", acknowledge: 0x33, label: "RA", blockID: "B",
                                            text: "QUSTRXMLH~1FREIGABE ERTEILT")

    // MARK: - Prüfsumme und Rahmen

    @Test("CRC-16/KERMIT: Prüfwert von „123456789“ ist 0x2189")
    func crcCheckValue() {
        #expect(ACARSCRC.checksum(Array("123456789".utf8)) == 0x2189)
    }

    @Test("Block mit angehängter CRC (niederwertiges Byte zuerst) ergibt Rest 0")
    func crcResidue() {
        let crc = ACARSCRC.checksum(downlink)
        #expect(ACARSCRC.checksum(downlink + [UInt8(crc & 0xFF), UInt8(crc >> 8)]) == 0)
    }

    @Test("Ungerade Parität: SYN, SOH, ETX und ETB wie in acarsdec")
    func parity() {
        #expect(ACARSFrame.withParity(0x16) == 0x16)
        #expect(ACARSFrame.withParity(0x01) == 0x01)
        #expect(ACARSFrame.withParity(0x03) == 0x83)
        #expect(ACARSFrame.withParity(0x17) == 0x97)
        #expect(ACARSFrame.withParity(0x7F) == 0x7F)
    }

    private func crcBytes(_ block: [UInt8]) -> [UInt8] {
        let crc = ACARSCRC.checksum(block)
        return [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    @Test("Felder einer Meldung vom Flugzeug")
    func parseDownlink() throws {
        let (text, corrected) = try #require(ACARSFrame.validate(downlink, crc: crcBytes(downlink)))
        #expect(corrected == 0)
        let message = try #require(ACARSFrame.parse(text))
        #expect(message.mode == "2")
        #expect(message.registration == "D-AIBC")
        #expect(message.acknowledge == "!")
        #expect(message.label == "H1")
        #expect(message.blockID == "3")
        #expect(message.isDownlink)
        #expect(message.messageNumber == "M01A")
        #expect(message.flight == "LH1234")
        #expect(message.text == "#DFBTEST POS N50123E008456")
        #expect(!message.continued)
    }

    @Test("Felder einer Meldung zum Flugzeug: keine Flugnummer")
    func parseUplink() throws {
        let (text, _) = try #require(ACARSFrame.validate(uplink, crc: crcBytes(uplink)))
        let message = try #require(ACARSFrame.parse(text))
        #expect(!message.isDownlink)
        #expect(message.registration == "D-ABYA")
        #expect(message.acknowledge == "3")
        #expect(message.flight == nil)
        #expect(message.text == "QUSTRXMLH~1FREIGABE ERTEILT")
    }

    @Test("Quittung ohne Text (Label _DEL) und ETB-Fortsetzung")
    func emptyAndContinued() throws {
        let ack = ACARSEncoder.block(registration: "OE-LBA", acknowledge: 0x41, label: "_\u{7F}", blockID: "5", text: "")
        #expect(ack.count == 13)
        let (text, _) = try #require(ACARSFrame.validate(ack, crc: crcBytes(ack)))
        let message = try #require(ACARSFrame.parse(text))
        #expect(message.label == "_d")
        #expect(message.text.isEmpty)

        let part = ACARSEncoder.block(registration: "D-AIBC", label: "H1", blockID: "2", messageNumber: "M02A",
                                      flight: "LH1234", text: "TEIL 1", end: ACARSFrame.etb)
        let parsed = try #require(ACARSFrame.validate(part, crc: crcBytes(part)).flatMap { ACARSFrame.parse($0.text) })
        #expect(parsed.continued)
        #expect(parsed.text == "TEIL 1")
    }

    @Test("Ein und zwei Paritätsfehler werden über die CRC korrigiert, falsche CRC verworfen")
    func errorCorrection() throws {
        let crc = crcBytes(downlink)
        var damaged = downlink
        damaged[20] ^= 0x04
        let one = try #require(ACARSFrame.validate(damaged, crc: crc))
        #expect(one.corrected == 1)
        #expect(ACARSFrame.parse(one.text)?.text == "#DFBTEST POS N50123E008456")

        damaged[30] ^= 0x40
        let two = try #require(ACARSFrame.validate(damaged, crc: crc))
        #expect(two.corrected == 2)

        #expect(ACARSFrame.validate(downlink, crc: [crc[0] ^ 1, crc[1]]) == nil)
    }

    // MARK: - MSK

    private func decode(_ audio: [Float]) -> [ACARSMessage] {
        let decoder = ACARSChannelDecoder()
        var messages: [ACARSMessage] = []
        var start = 0
        while start < audio.count {
            let end = min(start + 1000, audio.count)
            for block in decoder.process(Array(audio[start..<end])) {
                if let (text, _) = ACARSFrame.validate(block.text, crc: block.crc), let message = ACARSFrame.parse(text) {
                    messages.append(message)
                }
            }
            start = end
        }
        return messages
    }

    @Test("MSK-Ton mit Rauschen (≈ 9 dB) bei 12,5 kHz", arguments: [false, true])
    func mskAudio(inverted: Bool) {
        let bits = ACARSEncoder.bits(ACARSEncoder.transmission(downlink) + ACARSEncoder.transmission(uplink))
        var noise = Noise(seed: 42)
        let lead = (0..<3000).map { _ in Float(0.2 * noise.gaussian()) }
        let audio = lead + ACARSEncoder.audio(bits, sampleRate: ACARSChannelDecoder.sampleRate).map { sample in
            (inverted ? -sample : sample) + Float(0.25 * noise.gaussian())
        } + lead
        let messages = decode(audio)
        #expect(messages.count == 2)
        #expect(messages.first?.flight == "LH1234")
        #expect(messages.last?.registration == "D-ABYA")
    }

    @Test("Bitwechsel-Kodierung: gleiche Bits 2400 Hz, Wechsel 1200 Hz")
    func toneMapping() {
        // Eins nach Vorlauf-Eins: 2400 Hz = ein voller Umlauf je Bit (5 Abtastwerte bei 12 kHz).
        let same = ACARSEncoder.audio([1], sampleRate: 12_000)
        let change = ACARSEncoder.audio([0], sampleRate: 12_000)
        #expect(same.count >= 5 && change.count >= 5)
        #expect(abs(same[1] - Float(sin(2 * Double.pi * 2400 / 12_000))) < 1e-6)
        #expect(abs(change[1] - Float(sin(2 * Double.pi * 1200 / 12_000))) < 1e-6)
    }

    // MARK: - Kanalplan und HackRF-Strom

    @Test("Kanalplan: Mitte auf dem Raster, kein Kanal auf der DC-Spitze")
    func plan() throws {
        let plan = try #require(ACARSPlan.plan(ACARSPlan.defaultMHz))
        #expect(plan.active == [131.525, 131.725, 131.825])
        #expect(plan.outside.isEmpty)
        #expect(plan.centerHz.truncatingRemainder(dividingBy: ACARSPlan.gridHz) == 0)
        for mhz in plan.active {
            let offset = abs(mhz * 1e6 - plan.centerHz)
            #expect(offset >= ACARSPlan.dcGapHz && offset <= ACARSPlan.usableHz)
        }
        let wide = try #require(ACARSPlan.plan([129.125, 131.525, 131.725, 131.825]))
        #expect(wide.outside == [129.125])
        #expect(ACARSPlan.plan(ACARSPlan.europeanMHz)?.active.count == 6)
    }

    /// AM-Träger je Kanal bei 2 MS/s, Hüllkurve = 1 + m · MSK-Ton.
    private func iq(_ channels: [(offset: Double, block: [UInt8], delay: Double)], amplitude: Double = 30,
                    noiseSigma: Double = 6, seconds: Double = 0.5) -> Data {
        let rate = ACARSChannelizer.inputRate
        let count = Int(seconds * rate)
        var re = [Double](repeating: 0, count: count)
        var im = [Double](repeating: 0, count: count)
        for channel in channels {
            let audio = ACARSEncoder.audio(ACARSEncoder.bits(ACARSEncoder.transmission(channel.block)), sampleRate: rate)
            let start = Int(channel.delay * rate)
            let step = 2 * Double.pi * channel.offset / rate
            for n in 0..<min(audio.count, count - start) {
                let a = amplitude * (1 + 0.5 * Double(audio[n]))
                let phase = step * Double(start + n) + 0.3
                re[start + n] += a * cos(phase)
                im[start + n] += a * sin(phase)
            }
        }
        var noise = Noise(seed: 7)
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<count {
                p[2 * n] = Int8(max(-127, min(127, (re[n] + noiseSigma * noise.gaussian()).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (im[n] + noiseSigma * noise.gaussian()).rounded())))
            }
        }
        return data
    }

    @Test("Drei Kanäle gleichzeitig aus einem 2-MS/s-Strom mit Rauschen")
    func multiChannel() throws {
        let plan = try #require(ACARSPlan.plan(ACARSPlan.defaultMHz))
        let ack = ACARSEncoder.block(registration: "OE-LBA", acknowledge: 0x41, label: "_\u{7F}", blockID: "5", text: "")
        let blocks = [downlink, uplink, ack]
        let data = iq(plan.active.enumerated().map { index, mhz in
            (offset: mhz * 1e6 - plan.centerHz, block: blocks[index], delay: 0.02 + 0.03 * Double(index))
        })
        let receiver = ACARSReceiver(plan: plan)
        var messages: [ACARSMessage] = []
        var start = 0
        while start < data.count {
            let end = min(start + 262_144, data.count)
            messages += receiver.process(data.subdata(in: start..<end))
            start = end
        }
        #expect(messages.count == 3)
        let byChannel = Dictionary(grouping: messages, by: \.frequencyMHz)
        #expect(byChannel[131.525]?.first?.flight == "LH1234")
        #expect(byChannel[131.725]?.first?.registration == "D-ABYA")
        #expect(byChannel[131.825]?.first?.label == "_d")
        #expect(receiver.crcErrors == 0)
    }
}
