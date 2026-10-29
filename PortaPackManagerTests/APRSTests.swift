import Foundation
import Testing
@testable import PortaPackManager

@Suite("APRS")
struct APRSTests {
    private func frame(_ source: String, _ destination: String, _ info: String, path: [String] = ["WIDE1-1", "WIDE2-1"]) -> AX25Frame {
        AX25Frame(destination: AX25Address(destination), source: AX25Address(source),
                  digipeaters: path.map { AX25Address($0) }, info: Array(info.utf8))
    }

    /// AX.25-Rahmen → HDLC → NRZI → AFSK (Mark 1200, Space 2200) → FM ±3 kHz.
    private func afskIQ(_ frames: [AX25Frame], spaceGain: Double = 1, noise: Double = 3) -> Data {
        var freq: [Double] = []
        let rate = FMChannelizer.inputRate
        let samplesPerBit = rate / 1200
        var tonePhase = 0.0
        var clock = 0.0
        freq += [Double](repeating: 0, count: Int(rate * 0.05))
        for frame in frames {
            let levels = HDLCEncoder.nrzi(HDLCEncoder.bits(for: frame.encoded(), leadingFlags: 12, trailingFlags: 3))
            for level in levels {
                clock += samplesPerBit
                let count = Int(clock.rounded())
                clock -= Double(count)
                let tone = level == 1 ? 1200.0 : 2200.0
                let gain = level == 1 ? 1 : spaceGain
                for _ in 0..<count {
                    tonePhase += 2 * .pi * tone / rate
                    freq.append(3_000 * gain * sin(tonePhase))
                }
            }
            freq += [Double](repeating: 0, count: Int(rate * 0.1))
        }
        return TestSignals.iq(carriers: [freq], noise: noise)
    }

    private func decode(_ iq: Data) -> [AX25Frame] {
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 8_000)
        let demod = AFSKDemodulator()
        var out: [AX25Frame] = []
        for block in TestSignals.blocks(iq) {
            out += demod.process(front.process(block)[0]).compactMap(AX25Frame.parse)
        }
        return out
    }

    @Test("AX.25-Rahmen: Rundreise samt Pfad")
    func ax25() {
        let f = frame("DL1ABC-9", "APRS", "!4903.50N/07201.75W>Test")
        let parsed = AX25Frame.parse(f.encoded())
        #expect(parsed == f)
        #expect(parsed?.tnc2 == "DL1ABC-9>APRS,WIDE1-1,WIDE2-1:!4903.50N/07201.75W>Test")
    }

    @Test("Ende zu Ende: AFSK über NFM-IQ wird dekodiert, auch mit Twist")
    func endToEnd() {
        let frames = [frame("DL1ABC-9", "APRS", "!4903.50N/07201.75W>088/036Mobil /A=001234"),
                      frame("DB0XYZ", "APRS", ">Digi Testort", path: [])]
        for gain in [0.5, 2.0] {
            let decoded = decode(afskIQ(frames, spaceGain: gain))
            #expect(decoded == frames, "Space-Verstärkung \(gain)")
        }
        let packet = APRSPacket.parse(frames[0])
        #expect(packet.source == "DL1ABC-9")
        #expect(abs((packet.latitude ?? 0) - 49.058333) < 1e-5)
        #expect(abs((packet.longitude ?? 0) + 72.029167) < 1e-5)
    }

    @Test("Aus Rauschen entstehen keine Pakete")
    func noiseOnly() {
        let iq = TestSignals.iq(carriers: [], noise: 20, seed: 7) + TestSignals.iq(carriers: [[Double](repeating: 0, count: 2_400_000)], noise: 20, seed: 9)
        #expect(decode(iq).isEmpty)
    }

    @Test("Unkomprimierte Position mit Kurs, Tempo und Höhe")
    func uncompressed() throws {
        let p = try #require(APRSPacket.parse(tnc2: "DL1ABC-9>APRS,WIDE1-1:!4903.50N/07201.75W>088/036Mobil unterwegs /A=001234"))
        #expect(p.kind == .position)
        #expect(abs(p.latitude! - 49.058333) < 1e-5)
        #expect(abs(p.longitude! + 72.029167) < 1e-5)
        #expect(p.symbolTable == "/" && p.symbolCode == ">")
        #expect(p.courseDegrees == 88 && p.speedKnots == 36)
        #expect(abs(p.altitudeMeters! - 376.12) < 0.01)
        #expect(p.comment == "Mobil unterwegs")
        #expect(p.path == "WIDE1-1")
    }

    @Test("Position mit Zeitstempel")
    func timestamped() throws {
        let p = try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:@092345z4903.50N/07201.75W-Heim"))
        #expect(abs(p.latitude! - 49.058333) < 1e-5)
        #expect(p.symbolCode == "-")
        #expect(p.comment == "Heim")
    }

    @Test("Komprimierte Position (Beispiel aus der APRS-Spezifikation)")
    func compressed() throws {
        let p = try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:!/5L!!<*e7>7P[Kommentar"))
        #expect(abs(p.latitude! - 49.5) < 1e-4)
        #expect(abs(p.longitude! + 72.75) < 1e-4)
        #expect(p.courseDegrees == 88)
        #expect(abs(p.speedKnots! - 36.2) < 0.1)
        #expect(p.symbolCode == ">")
        #expect(p.comment == "Kommentar")
    }

    @Test("Mic-E: Breite aus dem Ziel, Länge, Tempo und Kurs aus dem Info-Feld")
    func micE() throws {
        // 33°25,64' N, 112°07,74' W, 20 kn, 251°, „Unterwegs“, Höhe 61 m.
        // Tempo und Kurs mit den druckbaren Varianten (+800 bzw. +400).
        let alt = 10_061
        let altChars = String(decoding: [UInt8(alt / 8281 + 33), UInt8(alt / 91 % 91 + 33), UInt8(alt % 91 + 33)], as: UTF8.self)
        let p = try #require(APRSPacket.parse(tnc2: "DL1ABC-9>SS2UVT,WIDE1-1:`(#fn\"O>/\(altChars)}Mobil"))
        #expect(p.kind == .micE)
        #expect(abs(p.latitude! - (33 + 25.64 / 60)) < 1e-6)
        #expect(abs(p.longitude! + (112 + 7.74 / 60)) < 1e-6)
        #expect(p.speedKnots == 20)
        #expect(p.courseDegrees == 251)
        #expect(p.micEMessage == "Unterwegs")
        #expect(p.altitudeMeters == 61)
        #expect(p.symbolCode == ">" && p.symbolTable == "/")
        #expect(p.comment == "Mobil")
    }

    @Test("Objekt, Status, Nachricht und Wetter")
    func otherTypes() throws {
        let object = try #require(APRSPacket.parse(tnc2: "DB0ABC>APRS:;LEADER   *092345z4903.50N/07201.75W>Gruppe"))
        #expect(object.kind == .object && object.objectName == "LEADER" && object.stationID == "LEADER")
        #expect(abs(object.latitude! - 49.058333) < 1e-5)

        let item = try #require(APRSPacket.parse(tnc2: "DB0ABC>APRS:)AID #2!4903.50N/07201.75WA"))
        #expect(item.kind == .item && item.objectName == "AID #2")

        let status = try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:>Unterwegs nach Hause"))
        #expect(status.kind == .status && status.comment == "Unterwegs nach Hause")

        let message = try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS::DL2XYZ   :Hallo{01"))
        #expect(message.kind == .message && message.comment == "an DL2XYZ: Hallo{01")

        let weather = try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:!4903.50N/07201.75W_220/004g005t077r000p000P000h50b09900"))
        #expect(weather.kind == .weather)
        #expect(weather.weather?.contains("25.0 °C") == true)
        #expect(weather.weather?.contains("50 %") == true)
        #expect(weather.weather?.contains("990.0 hPa") == true)
    }

    @Test("Drittanbieter-Paket wird ausgepackt")
    func thirdParty() throws {
        let p = try #require(APRSPacket.parse(tnc2: "DB0IGT>APRS,WIDE2-1:}DL9XYZ>APRS,TCPIP,DB0IGT*:!4903.50N/07201.75W-Heim"))
        #expect(p.source == "DL9XYZ")
        #expect(p.latitude != nil)
    }

    @Test("Stationsliste sammelt Spur und Paketzahl")
    func tracker() throws {
        var tracker = APRSStationTracker()
        tracker.ingest(try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:!4903.50N/07201.75W>")))
        tracker.ingest(try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:!4904.50N/07201.75W>")))
        tracker.ingest(try #require(APRSPacket.parse(tnc2: "DL1ABC>APRS:>Status")))
        let station = try #require(tracker.sorted.first)
        #expect(station.packets == 3 && station.trail.count == 2)
        #expect(abs(station.latitude! - (49 + 4.5 / 60)) < 1e-6)
    }
}
