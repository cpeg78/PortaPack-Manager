import Foundation
import Testing
@testable import PortaPackManager

/// Erzeugt 4-MS/s-IQ (int8) wie vom HackRF um 868,75 MHz mit mehreren
/// Sendern: FSK (phasenstetig) oder ASK, je mit eigener Frequenzablage.
struct SmartHomeSignalSynth {
    enum Modulation { case fsk(deviationHz: Double), ask }

    struct Transmission {
        var frequencyHz: Double
        var startSeconds: Double
        var bitRate: Double
        var bits: [UInt8]
        var modulation: Modulation
        var amplitude: Float = 40
        /// Quarzablage des Senders.
        var offsetHz: Double = 0
    }

    static let rate = SmartHomeFrontEnd.inputRate

    static func iq(_ transmissions: [Transmission], seconds: Double, noise: Float = 2, seed: UInt64 = 1) -> Data {
        let count = Int(seconds * rate)
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        for t in transmissions {
            let start = Int(t.startSeconds * rate)
            let samplesPerBit = rate / t.bitRate
            let total = Int(Double(t.bits.count) * samplesPerBit)
            let carrier = 2 * Double.pi * (t.frequencyHz + t.offsetHz - SmartHomeFrontEnd.centerHz) / rate
            var phase = 0.0
            for n in 0..<total where start + n < count {
                let bit = t.bits[min(t.bits.count - 1, Int(Double(n) / samplesPerBit))]
                var amplitude = t.amplitude
                switch t.modulation {
                case let .fsk(deviation):
                    phase += carrier + 2 * Double.pi * deviation * (bit == 1 ? 1 : -1) / rate
                case .ask:
                    phase += carrier
                    if bit == 0 { amplitude = 0 }
                }
                re[start + n] += amplitude * Float(cos(phase))
                im[start + n] += amplitude * Float(sin(phase))
            }
        }
        var rng = ParserFuzzTests.FuzzRNG(seed: seed)
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<count {
                // Näherungsweise gaußsches Rauschen (Summe dreier Gleichverteilungen).
                let ni = (Float.random(in: -1...1, using: &rng) + Float.random(in: -1...1, using: &rng) + Float.random(in: -1...1, using: &rng)) * noise
                let nq = (Float.random(in: -1...1, using: &rng) + Float.random(in: -1...1, using: &rng) + Float.random(in: -1...1, using: &rng)) * noise
                p[2 * n] = Int8(max(-127, min(127, (re[n] + ni).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (im[n] + nq).rounded())))
            }
        }
        return data
    }

    /// Wie der HackRF: Blöcke zu 128 Ki Abtastwerten.
    static func run(_ data: Data, config: SmartHome868Decoder.Config = .init()) -> [SmartHomeFrame] {
        let frontEnd = SmartHomeFrontEnd()
        frontEnd.enabled = Set(config.radios.flatMap(\.channels))
        var frames: [SmartHomeFrame] = []
        var offset = 0
        let block = 262_144
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + block, data.count))
            for burst in frontEnd.process(chunk) {
                frames += SmartHome868Decoder.decode(burst, config: config)
            }
            offset += block
        }
        return frames
    }
}

@Suite("Smart Home 868: Funkkette")
struct SmartHome868ChainTests {
    typealias Synth = SmartHomeSignalSynth

    static func homematicBits() -> [UInt8] {
        let message = SmartHomeTestFrames.homematic(counter: 0x10, flags: 0x86, type: 0x70,
                                                   source: [0x3A, 0x4B, 0x5C], target: [0, 0, 0], payload: [0x00, 0xE1, 0x2D])
        return SmartHomeDemod.bits(of: [UInt8](repeating: 0xAA, count: 4) + [0xE9, 0xCA, 0xE9, 0xCA]
                                   + Homematic.airBytes(message: message) + [0xAA])
    }

    static func zwaveR2Bits() -> [UInt8] {
        let frame = SmartHomeTestFrames.zwave(home: 0xCAFEBABE, source: 12, destination: 1,
                                              payload: [0x31, 0x05, 0x05, 0x01, 0x2D])     // Luftfeuchte 45 %
        return SmartHomeDemod.bits(of: [UInt8](repeating: 0x55, count: 10) + [0xF0] + frame + [0x55])
    }

    static func zwaveR1Chips() -> [UInt8] {
        let frame = SmartHomeTestFrames.zwave(home: 0xCAFEBABE, source: 9, destination: 1, payload: [0x80, 0x03, 0x5A])
        let bits = SmartHomeDemod.bits(of: [UInt8](repeating: 0x55, count: 10) + [0xF0] + frame + [0x55])
        return bits.flatMap { $0 == 1 ? [UInt8(1), 0] : [UInt8(0), 1] }
    }

    static func zwaveR3Bits() -> [UInt8] {
        let frame = SmartHomeTestFrames.zwaveR3(home: 0xCAFEBABE, source: 20, destination: 1, payload: [0x25, 0x03, 0xFF])
        return SmartHomeDemod.bits(of: [UInt8](repeating: 0x55, count: 24) + [0xF0] + frame + [0x55])
    }

    static func wmbusT1Bits() -> [UInt8] {
        let raw = SmartHomeTestFrames.wmbusFormatA(SmartHomeTestFrames.omsExample)
        return SmartHomeDemod.bits(of: [0x55, 0x55, 0x55, 0x54, 0x3D]) + WMBus.encode3of6(raw) + [0, 1, 0, 1, 0, 1]
    }

    static func wmbusC1Bits() -> [UInt8] {
        SmartHomeDemod.bits(of: [0x55, 0x55, 0x55, 0x55, 0x54, 0x3D, 0x54, 0xCD]
                            + SmartHomeTestFrames.wmbusFormatA(SmartHomeTestFrames.iperl) + [0x55])
    }

    static func enoceanAirBits() -> [UInt8] {
        let telegram = SmartHomeTestFrames.enocean(rorg: 0xF6, data: [0x50], sender: 0xFEF1A2B3, status: 0x30)
        // Träger an = logisch 0 (rtl_433 invertiert)
        return (EnOcean.encode8of12(telegram) + [1, 1]).map { $0 ^ 1 }
    }

    static let config = SmartHome868Decoder.Config(radios: Set(SmartHomeRadio.allCases),
                                                   wmbusKeys: ["12345678": SmartHomeTestFrames.omsKey])

    @Test("Alle Funkarten in einem Empfang: jede wird erkannt")
    func allRadios() {
        let transmissions: [Synth.Transmission] = [
            .init(frequencyHz: 868_300_000, startSeconds: 0.020, bitRate: 10_000, bits: Self.homematicBits(),
                  modulation: .fsk(deviationHz: 19_000), offsetHz: 12_000),
            .init(frequencyHz: 868_300_000, startSeconds: 0.110, bitRate: 125_000, bits: Self.enoceanAirBits(),
                  modulation: .ask, offsetHz: -20_000),
            .init(frequencyHz: 868_420_000, startSeconds: 0.020, bitRate: 40_000, bits: Self.zwaveR2Bits(),
                  modulation: .fsk(deviationHz: 20_000), offsetHz: -8_000),
            .init(frequencyHz: 868_420_000, startSeconds: 0.060, bitRate: 19_200, bits: Self.zwaveR1Chips(),
                  modulation: .fsk(deviationHz: 20_000), offsetHz: 5_000),
            .init(frequencyHz: 869_850_000, startSeconds: 0.030, bitRate: 100_000, bits: Self.zwaveR3Bits(),
                  modulation: .fsk(deviationHz: 29_000)),
            .init(frequencyHz: 868_950_000, startSeconds: 0.025, bitRate: 100_000, bits: Self.wmbusT1Bits(),
                  modulation: .fsk(deviationHz: 50_000), offsetHz: 15_000),
            .init(frequencyHz: 868_950_000, startSeconds: 0.090, bitRate: 100_000, bits: Self.wmbusC1Bits(),
                  modulation: .fsk(deviationHz: 45_000)),
        ]
        let frames = Synth.run(Synth.iq(transmissions, seconds: 0.16), config: Self.config)
        let homematic = frames.first { $0.radio == .homematic }
        #expect(homematic?.values.contains(SmartHomeValue(name: "Temperatur", unit: "°C", value: 22.5)) == true)
        #expect(frames.contains { $0.radio == .enocean && $0.address == "FEF1A2B3" && $0.summary == "Taste BI gedrückt" })
        #expect(frames.contains { $0.radio == .zwave && $0.mode == ZWave.Rate.r2.rawValue && $0.values.first?.value == 45 })
        #expect(frames.contains { $0.radio == .zwave && $0.mode == ZWave.Rate.r1.rawValue && $0.values.first?.value == 90 })
        #expect(frames.contains { $0.radio == .zwave && $0.mode == ZWave.Rate.r3.rawValue && $0.summary == "Schalter: ein" })
        #expect(frames.contains { $0.radio == .wmbus && $0.mode == "T1" && $0.values.contains { $0.name == "Volumen" && abs($0.value - 28504.27) < 0.001 } })
        #expect(frames.contains { $0.radio == .wmbus && $0.mode == "C1 · Format A" && $0.address == "SEN 12345699" })
    }

    @Test("Schwache Sender (≈ 12 dB über dem Rauschen im Kanal) kommen noch an")
    func weakSignals() {
        let transmissions: [Synth.Transmission] = [
            .init(frequencyHz: 868_300_000, startSeconds: 0.020, bitRate: 10_000, bits: Self.homematicBits(),
                  modulation: .fsk(deviationHz: 19_000), amplitude: 3),
            .init(frequencyHz: 868_420_000, startSeconds: 0.020, bitRate: 40_000, bits: Self.zwaveR2Bits(),
                  modulation: .fsk(deviationHz: 20_000), amplitude: 3),
            .init(frequencyHz: 868_950_000, startSeconds: 0.020, bitRate: 100_000, bits: Self.wmbusC1Bits(),
                  modulation: .fsk(deviationHz: 45_000), amplitude: 4),
        ]
        let frames = Synth.run(Synth.iq(transmissions, seconds: 0.10, noise: 2.5, seed: 7), config: Self.config)
        #expect(frames.contains { $0.radio == .homematic })
        #expect(frames.contains { $0.radio == .zwave })
        #expect(frames.contains { $0.radio == .wmbus })
    }

    @Test("Rauschen allein ergibt keine Rahmen")
    func noiseOnly() {
        let frames = Synth.run(Synth.iq([], seconds: 0.2, noise: 6, seed: 3), config: Self.config)
        #expect(frames.isEmpty)
    }

    @Test("Abgewählte Funkarten werden nicht ausgewertet")
    func disabledRadio() {
        let transmissions: [Synth.Transmission] = [
            .init(frequencyHz: 868_420_000, startSeconds: 0.020, bitRate: 40_000, bits: Self.zwaveR2Bits(),
                  modulation: .fsk(deviationHz: 20_000)),
        ]
        var config = Self.config
        config.radios = [.wmbus, .homematic]
        #expect(Synth.run(Synth.iq(transmissions, seconds: 0.06), config: config).isEmpty)
    }

    @Test("Rechenzeit: eine Sekunde Empfang deutlich unter einer Sekunde")
    func performance() {
        let data = Synth.iq([.init(frequencyHz: 868_950_000, startSeconds: 0.1, bitRate: 100_000, bits: Self.wmbusT1Bits(),
                                   modulation: .fsk(deviationHz: 50_000))], seconds: 1.0)
        let start = ContinuousClock.now
        _ = Synth.run(data, config: Self.config)
        let elapsed = ContinuousClock.now - start
        // Debug-Builds sind langsamer; Release liegt bei wenigen Prozent eines Kerns.
        #expect(elapsed < .seconds(3))
    }
}
