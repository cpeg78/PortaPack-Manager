import Foundation
import Testing
@testable import PortaPackManager

/// Synthetische HackRF-Blöcke (int8, 2 MS/s) durch die ganze Kette:
/// Demodulator → Pulsfolge → Slicer → Dekoder.
@Suite("Funksensoren: Demodulator")
struct SensorDemodulatorTests {
    /// Abschnitt eines Signals: Dauer in µs, Träger an/aus, Frequenzablage.
    private struct Segment {
        var microseconds: Int
        var on: Bool
        var offsetHz: Double = 0
    }

    /// Erzeugt IQ wie vom HackRF, der `SensorDemodulator.offset` unter der
    /// Sollfrequenz steht; dazu etwas Rauschen (reproduzierbar).
    private func iq(_ segments: [Segment], carrierOffsetHz: Double, amplitude: Double = 50) -> Data {
        let rate = SensorDemodulator.inputRate
        let total = segments.reduce(0) { $0 + $1.microseconds } * Int(rate) / 1_000_000
        var data = Data(count: total * 2)
        var phase = 0.0
        var seed: UInt32 = 12345
        func noise() -> Double {
            seed = seed &* 1_103_515_245 &+ 12345
            return Double(Int(seed >> 16) % 7 - 3)
        }
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var k = 0
            for segment in segments {
                let count = segment.microseconds * Int(rate) / 1_000_000
                for _ in 0..<count where k < total {
                    phase += 2 * .pi * (SensorDemodulator.offset + carrierOffsetHz + segment.offsetHz) / rate
                    let a = segment.on ? amplitude : 0
                    p[2 * k] = Int8(max(-127, min(127, (a * cos(phase) + noise()).rounded())))
                    p[2 * k + 1] = Int8(max(-127, min(127, (a * sin(phase) + noise()).rounded())))
                    k += 1
                }
            }
        }
        return data
    }

    private func bits(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { byte in (0..<8).map { (byte >> (7 - UInt8($0))) & 1 } }
    }

    /// In Blöcken wie vom HackRF (256 KiB) verarbeiten.
    private func run(_ data: Data) -> [SensorPulseTrain] {
        let demod = SensorDemodulator()
        var trains: [SensorPulseTrain] = []
        var start = 0
        while start < data.count {
            let end = min(start + 262_144, data.count)
            trains += demod.process(data.subdata(in: start..<end))
            start = end
        }
        return trains
    }

    @Test("OOK: Nexus-TH mit 60 kHz Frequenzablage")
    func nexusOOK() throws {
        let payload = Array(bits([0xB5, 0x10, 0xBE, 0xF4, 0x70]).prefix(36))
        var segments = [Segment(microseconds: 20_000, on: false)]
        for _ in 0..<6 {
            for bit in payload {
                segments.append(Segment(microseconds: 500, on: true))
                segments.append(Segment(microseconds: bit == 1 ? 2000 : 1000, on: false))
            }
            segments.append(Segment(microseconds: 500, on: true))
            segments.append(Segment(microseconds: 4000, on: false))
        }
        segments.append(Segment(microseconds: 150_000, on: false))
        let trains = run(iq(segments, carrierOffsetHz: 60_000))
        #expect(trains.count == 1)
        let train = try #require(trains.first)
        #expect(train.modulation == .ook)
        #expect(abs(train.offsetKHz - 60) < 3)
        let readings = SensorDecoders.decode(train)
        #expect(readings.map(\.model) == ["Nexus-TH"])
        #expect(readings.first?.temperatureC == 19.0)
        #expect(readings.first?.humidity == 71)
    }

    /// FSK-Paket: Träger durchgehend an, 1 = +Hub, 0 = −Hub.
    private func fsk(_ payload: [UInt8], bitMicroseconds: Int, deviationHz: Double, carrierOffsetHz: Double) -> Data {
        var segments = [Segment(microseconds: 20_000, on: false)]
        for bit in payload {
            segments.append(Segment(microseconds: bitMicroseconds, on: true, offsetHz: bit == 1 ? deviationHz : -deviationHz))
        }
        segments.append(Segment(microseconds: 150_000, on: false))
        return iq(segments, carrierOffsetHz: carrierOffsetHz)
    }

    @Test("FSK: Bresser 6-in-1 auf 868 MHz, ±45 kHz Hub, 30 kHz daneben")
    func bresserFSK() throws {
        let message: [UInt8] = [0x5E, 0xAA, 0x18, 0x80, 0x02, 0xC3, 0x18, 0xFA, 0x8F, 0xFB, 0x27, 0x68, 0x11, 0x84, 0x81, 0xFF, 0xF0, 0x72]
        let payload = bits([0xAA, 0xAA, 0xAA, 0xAA, 0x2D, 0xD4] + message + [0x00])
        let trains = run(fsk(payload, bitMicroseconds: 122, deviationHz: 45_000, carrierOffsetHz: -30_000))
        let train = try #require(trains.first)
        #expect(train.modulation == .fsk)
        #expect(abs(train.deviationKHz - 90) < 15)
        let reading = try #require(SensorDecoders.decode(train).first)
        #expect(reading.model == "Bresser-6in1")
        #expect(reading.temperatureC == 11.8)
        #expect(reading.humidity == 81)
    }

    @Test("FSK: LaCrosse TX35-IT mit 105 µs je Bit")
    func lacrosseFSK() throws {
        let payload = bits([0xAA, 0xAA, 0xAA, 0x2D, 0xD4, 0x96, 0xA6, 0x41, 0x22, 0x50, 0x00])
        let trains = run(fsk(payload, bitMicroseconds: 105, deviationHz: 60_000, carrierOffsetHz: 10_000))
        let train = try #require(trains.first)
        let readings = SensorDecoders.decode(train)
        #expect(readings.contains { $0.model == "LaCrosse-TX35DTHIT" && $0.temperatureC == 24.1 && $0.humidity == 34 })
    }

    @Test("Reines Rauschen erzeugt keine Pakete")
    func noiseOnly() {
        let trains = run(iq([Segment(microseconds: 300_000, on: false)], carrierOffsetHz: 0))
        #expect(trains.isEmpty)
    }

    @Test("Kurze Störspitzen in einer Pause zerlegen das Paket nicht")
    func spikesInGap() throws {
        let payload = Array(bits([0xB5, 0x10, 0xBE, 0xF4, 0x70]).prefix(36))
        var segments = [Segment(microseconds: 20_000, on: false)]
        for repeatIndex in 0..<4 {
            for (index, bit) in payload.enumerated() {
                segments.append(Segment(microseconds: 500, on: true))
                if repeatIndex == 1 && index == 11 {
                    // Bit 11 ist eine 1: 2000-µs-Pause mit einer 10-µs-Spitze in der Mitte
                    segments.append(Segment(microseconds: 995, on: false))
                    segments.append(Segment(microseconds: 10, on: true))
                    segments.append(Segment(microseconds: 995, on: false))
                } else {
                    segments.append(Segment(microseconds: bit == 1 ? 2000 : 1000, on: false))
                }
            }
            segments.append(Segment(microseconds: 500, on: true))
            segments.append(Segment(microseconds: 4000, on: false))
        }
        segments.append(Segment(microseconds: 150_000, on: false))
        let trains = run(iq(segments, carrierOffsetHz: -20_000))
        #expect(trains.count == 1)
        #expect(SensorDecoders.decode(try #require(trains.first)).first?.model == "Nexus-TH")
    }
}
