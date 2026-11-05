import Foundation
import Testing
@testable import PortaPackManager

/// Zusatzdaten der RS41 (04.11.2026): Konfiguration aus den Kalibrierfragmenten,
/// Zusatzinstrumente (XDATA), Druck/Feuchte-Hilfsformeln, Speicherung.
@Suite("Radiosonden: Zusatzdaten")
struct SondeExtrasTests {
    @Test("Kalibrierfragmente: Modell, Frequenz, Firmware, Abschaltung")
    func configuration() {
        var cal = RS41.Calibration()
        // Fragment 0: 400 MHz + 40 kHz × 0x7A + 20 kHz (0x80) = 404,900 MHz.
        cal.bytes[2] = 0x80; cal.bytes[3] = 0x7A; cal.received[0x00] = true
        cal.bytes[0x15] = 0x34; cal.bytes[0x16] = 0x12; cal.received[0x01] = true
        cal.bytes[0x2B] = 1; cal.bytes[0x27] = 0xFF; cal.bytes[0x28] = 0xFF; cal.received[0x02] = true
        cal.bytes[0x320] = 0x10; cal.bytes[0x321] = 0x0E; cal.received[0x32] = true   // 3600 s
        for (i, c) in "RS41-SGP".utf8.enumerated() { cal.bytes[0x218 + i] = c }
        cal.received[0x21] = true
        for (i, c) in "RSM414".utf8.enumerated() { cal.bytes[0x222 + i] = c }
        cal.received[0x22] = true
        let c = RS41.configuration(cal)
        #expect(c.frequencyMHz == 404.9)
        #expect(c.firmware == 0x1234)
        #expect(c.subtype == "RS41-SGP")
        #expect(c.mainboard == "RSM414")
        #expect(c.burstKill == true)
        #expect(c.activeCountdown == 3600)
        // Fragment 0x32 kam mit Rahmen 1000; 30 Rahmen später sind 30 s vergangen.
        cal.countdownFrame = 1000
        #expect(RS41.configuration(cal, frame: 1030).activeCountdown == 3570)
        #expect(RS41.configuration(cal, frame: 5).activeCountdown == 3600)   // Sprung → Rohwert
        // Anzeige zählt seit dem letzten Kontakt weiter (Fund 05.11.2026: blieb stehen).
        var report = SondeReport(kind: .rs41, serial: "X1", model: "RS41")
        report.configuration = RS41.configuration(cal, frame: 1000)
        let seen = Date(timeIntervalSince1970: 0)
        #expect(SondeView.countdownText(report, lastSeen: seen, now: seen.addingTimeInterval(1200))
                == String(localized: "Abschaltung um \(seen.addingTimeInterval(3600).formatted(date: .omitted, time: .shortened)) (in \(Duration.seconds(2400).formatted(.time(pattern: .hourMinute))) h)"))
        #expect(SondeView.countdownText(report, lastSeen: seen, now: seen.addingTimeInterval(4000)) == String(localized: "Abschaltzeit erreicht"))
        // Ohne Abschaltung (weder burst kill noch Timer) zählt der Countdown nicht.
        cal.bytes[0x2B] = 0
        #expect(RS41.configuration(cal).activeCountdown == nil)
        // Fehlende Fragmente: nichts erfunden.
        let empty = RS41.configuration(RS41.Calibration())
        #expect(empty == SondeConfiguration())
    }

    @Test("XDATA: Ozonsonden OIF411 (Messwerte und Kennung) und ECC")
    func instruments() throws {
        let oif = try #require(SondeInstrument.parse("05010A2805DC08C06482").first)
        #expect(oif.id == 5 && oif.number == 1)
        #expect(oif.pumpTemperature == 26)
        #expect(oif.cellCurrent == 2.4)
        #expect(oif.batteryVolts == 14)
        #expect(oif.pumpCurrent == 100)
        let id = try #require(SondeInstrument.parse("0501L123456700000103I").first)
        #expect(id.serial == "L1234567")
        #expect(id.cellCurrent == nil)
        let merged = SondeInstrument.merge([id], with: [oif])
        #expect(merged.count == 1 && merged[0].serial == "L1234567" && merged[0].cellCurrent == 2.4)
        let both = SondeInstrument.parse("010207D00A28648C#08011234")
        #expect(both.count == 2)
        #expect(both[0].cellCurrent == 2 && both[0].pumpTemperature == 26 && both[0].batteryVolts == 14)
        #expect(both[1].id == 8 && both[1].cellCurrent == nil)
        #expect(SondeInstrument.parse("zz").isEmpty)
        #expect(SondeInstrument.parse("0501").first?.cellCurrent == nil)   // zu kurz: nur Kennung
    }

    @Test("Normatmosphäre und Sättigungsdampfdruck")
    func formulas() {
        #expect(abs(RS41.standardPressure(0) - 1013.25) < 0.01)
        #expect(abs(RS41.standardPressure(11_000) - 226.3) < 0.5)
        #expect(abs(RS41.standardPressure(5_000) - 540.2) < 1)
        #expect(abs(RS41.standardPressure(30_000) - 11.97) < 0.4)   // Näherung wie rs41mod: 11,7
        #expect(abs(RS41.vaporSaturation(0) - 611) < 2)
        #expect(abs(RS41.vaporSaturation(20) - 2339) < 5)
    }

    @Test("Druck, Satelliten und Ozon überstehen Datenbank und CSV")
    func storage() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        var report = SondeReport(kind: .rs41, serial: "S1234567", model: "RS41")
        report.frame = 100
        report.latitude = 53.6; report.longitude = 10.1; report.altitude = 15_000
        report.pressure = 120.456; report.satellites = 11
        report.instruments = [SondeInstrument(id: 5, number: 1, cellCurrent: 3.21)]
        report.frequency = 404_900_000
        SondeLog.append([report], window: "w", received: Date(timeIntervalSince1970: 1_793_000_000), database: db.database)
        await db.database.flush()
        let sample = try #require(SondeArchive.load(serial: "S1234567", database: db.database)?.samples.first)
        #expect(sample.pressure == 120.46)
        #expect(sample.satellites == 11)
        #expect(sample.ozoneCurrent == 3.21)
        #expect(sample.frame == 100)
        let flight = SondeFlight(serial: "S1234567", type: "RS41", samples: [sample])
        let parsed = try #require(SondeArchive.parse(SondeArchive.csv(flight)).first)
        #expect(parsed.sample.pressure == 120.46 && parsed.sample.satellites == 11 && parsed.sample.ozoneCurrent == 3.21)
        // Alte CSV ohne die neuen Spalten bleibt lesbar.
        let old = "2026-10-28T10:47:02Z;RS41;V3051090;1060;404.900;53.6;10.1;753;3.7;7.2;89;;;2.9"
        #expect(SondeArchive.parse(old).first?.sample.pressure == nil)
    }

    @Test("Empfangsquote aus den Rahmennummern")
    func coverage() {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        let frames = Array(0..<50) + Array(100..<150)   // 100 von 150 Rahmen
        let samples = frames.map { SondeSample(date: base.addingTimeInterval(Double($0)), frame: $0) }
        let flight = SondeFlight(serial: "X", type: "RS41", samples: samples)
        #expect(abs((flight.frameCoverage ?? 0) - 100.0 / 150) < 1e-9)
        #expect(SondeFlight(serial: "X", type: "RS41", samples: Array(samples.prefix(5))).frameCoverage == nil)
    }
}
