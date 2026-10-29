import Foundation
import Testing
@testable import PortaPackManager

@Suite("ADS-B")
struct ADSBDecoderTests {
    private func bytes(_ hex: String) -> [UInt8] { [UInt8](Data(hexString: hex)!) }

    @Test("Kennung aus einer bekannten Nachricht (KLM1023)")
    func identification() throws {
        let message = try #require(ADSBDemodulator.decode(bytes("8D4840D6202CC371C32CE0576098")))
        #expect(message.icaoHex == "4840D6")
        guard case let .identification(callsign, _) = message.content else { Issue.record("falscher Typ"); return }
        #expect(callsign == "KLM1023")
    }

    @Test("Verfälschte Nachricht fällt durch die CRC")
    func crc() {
        #expect(ADSBDemodulator.decode(bytes("8D4840D6202CC371C32CE0576099")) == nil)
    }

    @Test("Position aus Gerade/Ungerade-Paar (Lehrbuchbeispiel)")
    func position() throws {
        let even = try #require(ADSBDemodulator.decode(bytes("8D40621D58C382D690C8AC2863A7")))
        let odd = try #require(ADSBDemodulator.decode(bytes("8D40621D58C386435CC412692AD6")))
        var tracker = AircraftTracker()
        tracker.ingest(odd)
        tracker.ingest(even)
        let plane = try #require(tracker.aircraft[0x40621D])
        #expect(plane.altitude == 38000)
        #expect(abs((plane.latitude ?? 0) - 52.2572) < 0.001)
        #expect(abs((plane.longitude ?? 0) - 3.9194) < 0.001)
    }

    @Test("Geschwindigkeit und Kurs")
    func velocity() throws {
        let message = try #require(ADSBDemodulator.decode(bytes("8D485020994409940838175B284F")))
        guard case let .velocity(speed, track, vr) = message.content else { Issue.record("falscher Typ"); return }
        #expect(abs(speed - 159.2) < 0.1)
        #expect(abs(track - 182.88) < 0.1)
        #expect(vr == -832)
    }

    /// Gerade Meldung des Lehrbuchbeispiels: lat_cpr 93000, lon_cpr 51372.
    private func evenPosition(lat: Int = 93000, lon: Int = 51372, at date: Date) -> ADSBMessage {
        ADSBMessage(icao: 0x40621D, downlinkFormat: 17, typeCode: 11,
                    content: .airbornePosition(altitude: 38000, oddFormat: false, latCPR: lat, lonCPR: lon),
                    raw: [], date: date)
    }

    @Test("Örtliche Dekodierung (Lehrbuchbeispiel, Bezug 52,258 / 3,918)")
    func localDecoding() throws {
        let p = try #require(AircraftTracker.localPosition(cpr: (93000, 51372), odd: false, reference: (52.258, 3.918)))
        #expect(abs(p.lat - 52.25720) < 0.00001)
        #expect(abs(p.lon - 3.91937) < 0.00001)
    }

    @Test("Eine einzelne Meldung genügt, wenn der eigene Standort bekannt ist")
    func singleMessageWithReceiver() throws {
        var tracker = AircraftTracker()
        tracker.ingest(evenPosition(at: Date()))
        #expect(tracker.aircraft[0x40621D]?.latitude == nil)   // ohne Standort: Paar nötig
        tracker = AircraftTracker()
        tracker.receiver = (52.0, 4.5)                          // ≈ 50 km entfernt
        tracker.ingest(evenPosition(at: Date()))
        let plane = try #require(tracker.aircraft[0x40621D])
        #expect(abs((plane.latitude ?? 0) - 52.2572) < 0.001)
        #expect(abs((plane.longitude ?? 0) - 3.9194) < 0.001)
    }

    @Test("Außerhalb der halben Zone wird nicht örtlich dekodiert")
    func receiverTooFar() {
        var tracker = AircraftTracker()
        tracker.receiver = (49.0, 3.9)   // ≈ 360 km südlich: Ergebnis wäre gespiegelt
        tracker.ingest(evenPosition(at: Date()))
        #expect(tracker.aircraft[0x40621D]?.latitude == nil)
    }

    @Test("Unmögliche Sprünge werden verworfen, plausible übernommen")
    func plausibility() throws {
        let start = Date()
        var tracker = AircraftTracker()
        tracker.receiver = (52.0, 4.5)
        tracker.ingest(evenPosition(at: start))
        // 20 s später 0,9° (≈ 100 km) weiter: zu weit für ein Flugzeug.
        tracker.ingest(evenPosition(lat: 113_000, at: start.addingTimeInterval(20)))
        var plane = try #require(tracker.aircraft[0x40621D])
        #expect(abs((plane.latitude ?? 0) - 52.2572) < 0.001)
        // Kleiner Schritt (≈ 0,5 km) ist plausibel.
        tracker.ingest(evenPosition(lat: 93_100, at: start.addingTimeInterval(25)))
        plane = try #require(tracker.aircraft[0x40621D])
        #expect((plane.latitude ?? 0) > 52.2572)
        #expect(plane.positionDate == start.addingTimeInterval(25))
    }

    // MARK: - Beast-Format (Einspeisung)

    @Test("Beast: lange Nachricht ohne Zeitstempel")
    func beastLong() throws {
        let frame = try #require(BeastFormat.frame(bytes("8D4840D6202CC371C32CE0576098"), signal: 0x80))
        #expect(frame == bytes("1A33000000000000808D4840D6202CC371C32CE0576098"))
    }

    @Test("Beast: 0x1A in Zeitstempel, Pegel und Nachricht wird verdoppelt")
    func beastEscaping() throws {
        let frame = try #require(BeastFormat.frame(bytes("5D1A2B3C4D5E6F"), timestamp: 0x00_001A_00_001A, signal: 0x1A))
        #expect(frame == bytes("1A3200001A1A00001A1A1A1A5D1A1A2B3C4D5E6F"))
    }

    @Test("Beast: Kopf bleibt unverdoppelt, falsche Längen fallen weg")
    func beastLengths() {
        #expect(BeastFormat.frame([UInt8](repeating: 0x1A, count: 7), signal: 0)?.count == 23)   // 2 Kopf + 6 + 1 + 7·2
        #expect(BeastFormat.frame([UInt8](repeating: 0, count: 8), signal: 0) == nil)
        #expect(BeastFormat.frame([], signal: 0) == nil)
    }

    @Test("Beast: Pegelbyte wie readsb (Amplitude · 255, Signal > 0 mindestens 1)")
    func beastSignal() {
        #expect(BeastFormat.signalByte(amplitude: 0) == 0)
        #expect(BeastFormat.signalByte(amplitude: 0.0001) == 1)
        #expect(BeastFormat.signalByte(amplitude: 0.5) == 128)
        #expect(BeastFormat.signalByte(amplitude: 1) == 255)
        #expect(BeastFormat.signalByte(amplitude: 3) == 255)
    }

    @Test("Einspeiseziele: Häkchen plus eigene Ziele, doppelte nur einmal")
    func beastEndpoints() {
        let list = BeastFeeder.endpoints(presets: "adsbfi,unbekannt",
                                         custom: "feed.adsb.fi:30004, 192.168.1.5:30005\nkaputt")
        let names: [String] = list.map { "\($0.host):\($0.port)" }
        #expect(names == ["feed.adsb.fi:30004", "192.168.1.5:30005"])
        #expect(BeastFeeder.endpoints(presets: "", custom: "").isEmpty)
    }

    @Test("Demodulator liefert den Pegel der Präambel (halbe Aussteuerung → 0,5)")
    func demodulatorSignal() throws {
        let raw = bytes("8D4840D6202CC371C32CE0576098")
        var half = [Bool](repeating: false, count: 16)          // Präambel in halben Bits
        for k in [0, 2, 7, 9] { half[k] = true }
        for i in 0..<112 {
            let bit = raw[i / 8] & (0x80 >> UInt8(i % 8)) != 0
            half += bit ? [true, false] : [false, true]
        }
        var iq = Data(repeating: 0, count: 2 * 40)
        for high in half { iq += [high ? UInt8(64) : 0, 0] }
        iq += Data(repeating: 0, count: 2 * 400)
        let messages = ADSBDemodulator().process(iq)
        let message = try #require(messages.first)
        #expect(message.rawHex == "8D4840D6202CC371C32CE0576098")
        #expect(abs(message.signal - 0.5) < 0.001)
        #expect(BeastFormat.signalByte(amplitude: message.signal) == 128)
    }

    @Test("Beast: Stationskennung wie readsb (1A E4 + 36 Zeichen)")
    func beastUUID() {
        let bytes = BeastFormat.uuidMessage("0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")
        #expect(bytes.count == 38)
        #expect(Array(bytes.prefix(2)) == [0x1A, 0xE4])
        #expect(String(decoding: bytes.dropFirst(2), as: UTF8.self) == "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
        #expect(String(decoding: BeastFormat.uuidMessage("abc").dropFirst(2), as: UTF8.self) == "abc" + String(repeating: "f", count: 33))
    }
}
