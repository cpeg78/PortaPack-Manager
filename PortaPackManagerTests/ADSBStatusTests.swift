import Foundation
import Testing
@testable import PortaPackManager

@Suite("ADS-B: Squawk, Notfall, Zielzustand, Betriebsstatus")
struct ADSBStatusTests {
    private func bytes(_ hex: String) -> [UInt8] { [UInt8](Data(hexString: hex)!) }

    /// DF17-Rahmen mit gültiger Prüfsumme.
    private func frame(icao: UInt32, me: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [17 << 3 | 5, UInt8(icao >> 16 & 0xFF), UInt8(icao >> 8 & 0xFF), UInt8(icao & 0xFF)] + me + [0, 0, 0]
        let crc = ADSBDemodulator.crc24(b)
        b[11] = UInt8(crc >> 16 & 0xFF); b[12] = UInt8(crc >> 8 & 0xFF); b[13] = UInt8(crc & 0xFF)
        return b
    }

    @Test("DF5: Squawk aus dem Kennungsfeld (pyModeS-Beispiel 0356)")
    func squawkFromIdentity() throws {
        let message = try #require(ADSBDemodulator.decodeModeS(bytes("2A00516D492B80"), icao: 0x123456))
        guard case let .surveillance(altitude, squawk, _) = message.content else { Issue.record("falscher Typ"); return }
        #expect(altitude == nil)
        #expect(squawk == 356)
        var tracker = AircraftTracker()
        tracker.ingest(message)
        // Ein einzelner Rahmen setzt den Code noch nicht, der zweite gleiche schon.
        #expect(tracker.aircraft[0x123456]?.squawk == nil)
        tracker.ingest(message)
        #expect(tracker.aircraft[0x123456]?.squawkText == "0356")
        #expect(tracker.aircraft[0x123456]?.emergency == nil)
    }

    @Test("Notfall-Squawks: 7700, 7600, 7500")
    func emergencySquawks() {
        // A1 A2 A4 B1 B2 B4 = 7700 im 13-Bit-Feld.
        #expect(ADSBDemodulator.squawkDigits(id13: 0x0AAA) == 7700)
        #expect(ADSBMessage.Emergency(squawk: 7700) == .general)
        #expect(ADSBMessage.Emergency(squawk: 7600) == .noCommunication)
        #expect(ADSBMessage.Emergency(squawk: 7500) == .unlawfulInterference)
        #expect(ADSBMessage.Emergency(squawk: 1000) == nil)
        #expect(ADSBDemodulator.squawkDigits(id13: 0) == nil)
    }

    @Test("TC 28: Notfallstatus samt Squawk")
    func emergencyStatus() throws {
        // Unterart 1, Status 4 (Funkausfall), Squawk 7700.
        let raw = frame(icao: 0x3C6586, me: [28 << 3 | 1, 4 << 5 | 0x0A, 0xAA, 0, 0, 0, 0])
        let message = try #require(ADSBDemodulator.decode(raw))
        guard case let .emergency(state, squawk) = message.content else { Issue.record("falscher Typ"); return }
        #expect(state == .noCommunication)
        #expect(squawk == 7700)
        var tracker = AircraftTracker()
        tracker.ingest(message)
        tracker.ingest(message)
        #expect(tracker.aircraft[0x3C6586]?.squawk == 7700)
        // Der gemeldete Status hat Vorrang vor dem Squawk.
        #expect(tracker.aircraft[0x3C6586]?.emergency == .noCommunication)
        // „Kein Notfall“ gemeldet, Squawk 7700: der Squawk zählt.
        let none = try #require(ADSBDemodulator.decode(frame(icao: 0x3C6586, me: [28 << 3 | 1, 0x0A, 0xAA, 0, 0, 0, 0])))
        tracker.ingest(none)
        #expect(tracker.aircraft[0x3C6586]?.emergency == .general)
    }

    @Test("TC 29: Sollhöhe, QNH, Sollkurs, Betriebsarten (pyModeS-Beispiel)")
    func targetState() throws {
        let message = try #require(ADSBDemodulator.decode(bytes("8DA05629EA21485CBF3F8CADAEEB")))
        guard case let .targetState(state) = message.content else { Issue.record("falscher Typ"); return }
        #expect(state.selectedAltitude == 16992)
        #expect(!state.fromFMS)
        #expect(abs((state.qnh ?? 0) - 1012.8) < 0.01)
        #expect(abs((state.selectedHeading ?? 0) - 66.8) < 0.1)
        #expect(state.modes == [.autopilot, .vnav, .tcas, .lnav])
        #expect(state.modes?.text == "Autopilot, LNAV, VNAV")
    }

    @Test("TC 5–8: Bodenposition und Rollgeschwindigkeit (pyModeS-Beispiele)")
    func surfacePosition() throws {
        let position = try #require(ADSBDemodulator.decode(bytes("8C4841753A9A153237AEF0F275BE")))
        guard case let .surfacePosition(_, _, odd, lat, lon) = position.content else { Issue.record("falscher Typ"); return }
        let fix = try #require(AircraftTracker.localPosition(cpr: (lat, lon), odd: odd, reference: (51.990, 4.375), surface: true))
        // Breite wie pyModeS; Länge von Hand: NL(52,32°) = 36, Zone 90°/35, (1 + 110320/131072) · 2,5714° = 4,7357°.
        #expect(abs(fix.lat - 52.32061) < 1e-4 && abs(fix.lon - 4.7357) < 1e-3)
        var tracker = AircraftTracker()
        tracker.receiver = (51.990, 4.375)
        tracker.ingest(position)
        let plane = try #require(tracker.aircraft[0x484175])
        #expect(plane.onGround)
        #expect(abs((plane.latitude ?? 0) - 52.32061) < 1e-4)
        // Dieselbe Meldung: Bewegung 41 → 17 kn, Kurs 33 · 360/128 = 92,8°.
        guard case let .surfacePosition(speed, track, _, _, _) = position.content else { Issue.record("falscher Typ"); return }
        #expect(speed == 17)
        #expect(abs((track ?? 0) - 92.8) < 0.1)
        #expect(ADSBDemodulator.surfaceSpeed(0) == nil && ADSBDemodulator.surfaceSpeed(124) == 175)
    }

    /// MB-Feld (Bytes 4–10) eines DF20/21-Rahmens.
    private func mb(_ hex: String) -> [UInt8] { Array(bytes(hex)[4..<11]) }

    @Test("Comm-B: BDS 2,0/4,0/5,0/6,0 nach pyModeS-Beispielen, Mehrdeutiges per ADS-B-Kurs")
    func commB() throws {
        #expect(CommB.identification(mb("A000083E202CC371C31DE0AA1CCF")) == "KLM1017")
        // Ungültige Zeichen (Index 1…31 außerhalb A–Z, „#“) → kein Rufzeichen; vorher
        // entfernte `callsign()` sie und jedes 0x20-Byte galt als BDS 2,0 (Review 05.11.2026).
        #expect(CommB.identification([0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == nil)
        #expect(CommB.identification([0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == nil)
        guard case let .verticalIntention(mcp, fms, qnh)? = CommB.verticalIntention(mb("A000029C85E42F313000007047D3")) else {
            Issue.record("BDS 4,0 nicht erkannt"); return
        }
        #expect(mcp == 3008 && fms == 3008 && abs((qnh ?? 0) - 1020) < 0.05)
        guard case let .trackAndTurn(roll, track, gs, tas)? = CommB.trackAndTurn(mb("A000139381951536E024D4CCF6B5")) else {
            Issue.record("BDS 5,0 nicht erkannt"); return
        }
        #expect(abs((roll ?? 0) - 2.1) < 0.05 && abs((track ?? 0) - 114.258) < 0.01 && gs == 438 && tas == 424)
        guard case let .headingAndSpeed(heading, ias, mach, rate)? = CommB.headingAndSpeed(mb("A00004128F39F91A7E27C46ADC21")) else {
            Issue.record("BDS 6,0 nicht erkannt"); return
        }
        #expect(abs((heading ?? 0) - 42.715) < 0.01 && ias == 252 && abs((mach ?? 0) - 0.42) < 0.005 && rate == -1920)
        // Zuordnung mit ADS-B-Bezug: Kurs 114°, 440 kn → BDS 5,0; Kurs 45° → BDS 6,0.
        var plane = Aircraft(icao: 1, lastSeen: Date())
        plane.track = 114; plane.groundSpeed = 440; plane.altitude = 37_000
        guard case .trackAndTurn? = CommB.infer(mb("A000139381951536E024D4CCF6B5"), plane: plane) else { Issue.record("5,0 nicht zugeordnet"); return }
        plane.track = 45; plane.groundSpeed = 300
        guard case .headingAndSpeed? = CommB.infer(mb("A00004128F39F91A7E27C46ADC21"), plane: plane) else { Issue.record("6,0 nicht zugeordnet"); return }
    }

    @Test("Comm-B BDS 6,0: auch die Trägheits-Steigrate muss unter 6000 ft/min liegen (Review 05.11.2026)")
    func commBBothVerticalRates() {
        var mb = mb("A00004128F39F91A7E27C46ADC21")      // Baro-Rate −1920 ft/min gültig
        func set(_ n: Int, _ on: Bool) {
            let mask = UInt8(0x80 >> ((n - 1) & 7))
            if on { mb[(n - 1) >> 3] |= mask } else { mb[(n - 1) >> 3] &= ~mask }
        }
        // Bits 46–56: Status an, Vorzeichen +, Wert 250 · 32 = 8000 ft/min.
        let bits = [true, false] + (0..<9).map { (250 >> (8 - $0)) & 1 == 1 }
        for (k, on) in bits.enumerated() { set(46 + k, on) }
        #expect(CommB.headingAndSpeed(mb) == nil)
    }

    @Test("Comm-B: Wind aus Luft- und Bodenvektor")
    func commBWind() {
        // Steuerkurs 90°, TAS 400 kn; über Grund Kurs 90°, 350 kn → 50 kn Gegenwind aus Osten (90°).
        var plane = Aircraft(icao: 2, lastSeen: Date())
        plane.track = 90; plane.groundSpeed = 350
        let now = Date()
        var state = CommB.State()
        state.trueAirspeed = 400; state.heading = 90; state.trackDate = now; state.headingDate = now
        let wind = CommB.wind(state, plane: plane, at: now)
        #expect(abs((wind?.speed ?? 0) - 50) < 0.01)
        #expect(abs((wind?.from ?? 0) - 90) < 0.01)
    }

    @Test("TC 31: ADS-B-Version und NACp")
    func operationalStatus() throws {
        let message = try #require(ADSBDemodulator.decode(frame(icao: 0x4CA2D5, me: [31 << 3, 0, 0, 0, 0, 2 << 5 | 9, 0])))
        guard case let .operationalStatus(version, nacp) = message.content else { Issue.record("falscher Typ"); return }
        #expect(version == 2)
        #expect(nacp == 9)
        // Version 0 kennt kein NACp an dieser Stelle.
        let old = try #require(ADSBDemodulator.decode(frame(icao: 0x4CA2D5, me: [31 << 3, 0, 0, 0, 0, 9, 0])))
        guard case .operationalStatus(0, nil) = old.content else { Issue.record("NACp bei Version 0"); return }
    }
}
