import Foundation
import Testing
@testable import PortaPackManager

@Suite("Sondenarchiv")
struct SondeArchiveTests {
    static let header = "empfangen;typ;seriennummer;rahmen;frequenz_mhz;breite;laenge;hoehe_m;steigen_ms;wind_ms;kurs;temperatur;feuchte;batterie_v\n"

    @Test("CSV wird gelesen, Flüge je Seriennummer über Dateien zusammengefasst")
    func grouping() {
        let a = Self.header + """
        2026-10-28T10:47:02Z;RS41;V3051090;1060;404.900;53.64949;10.11973;753;3.7;7.2;89;;;2.9
        2026-10-28T10:47:04Z;RS41;V3051090;1061;404.900;53.64949;10.11983;757;3.8;6.0;92;12.5;80;2.9
        kaputt;;;
        2026-10-28T10:50:00Z;DFM;D123;;403.500;;;;;;;;;
        """
        let b = Self.header + """
        2026-10-28T11:38:24Z;RS41;V3051090;4100;404.900;53.91543;10.57704;16733;4.8;20;60;-60.5;5;2.6
        2026-10-28T12:10:00Z;RS41;V3051090;5000;404.900;54.10000;10.90000;8000;-12.0;30;70;-40.0;20;2.5
        2026-10-28T12:10:00Z;RS41;V3051090;5000;404.900;54.10000;10.90000;8000;-12.0;30;70;-40.0;20;2.5
        """
        let flights = SondeArchive.flights(from: SondeArchive.parse(a) + SondeArchive.parse(b))
        #expect(flights.count == 2)
        let f = try! #require(flights.first { $0.serial == "V3051090" })
        #expect(f.samples.count == 4)                  // Doppelte entfernt
        #expect(f.peak?.altitude == 16733)
        #expect(f.burst)
        #expect(f.minTemperature == -60.5)
        #expect(f.frequencyMHz == 404.9)
        #expect(f.launch?.altitude == 753)
        #expect((f.distanceKm ?? 0) > 40)
        // Neueste zuerst: D123 begann 10:50, V3051090 um 10:47.
        #expect(flights.first?.serial == "D123")
    }

    @Test("Ausdünnen behält Anfang und Ende")
    func thinning() {
        let samples = (0..<5000).map { SondeSample(date: Date(timeIntervalSince1970: Double($0)), altitude: Double($0)) }
        let thin = SondeArchive.thinned(samples, limit: 800)
        #expect(thin.count == 800)
        #expect(thin.first?.altitude == 0)
        #expect(thin.last?.altitude == 4999)
    }

    @Test("Export ergibt wieder lesbare Zeilen")
    func roundTrip() {
        let flight = SondeFlight(serial: "V1", type: "RS41", samples: [
            SondeSample(date: Date(timeIntervalSince1970: 1_800_000_000), frequencyMHz: 404.9, latitude: 53.5,
                        longitude: 10, altitude: 1000, temperature: -3.5, humidity: 70)])
        let parsed = SondeArchive.parse(SondeArchive.csv(flight))
        #expect(parsed.count == 1)
        #expect(parsed.first?.sample.temperature == -3.5)
        #expect(parsed.first?.serial == "V1")
    }
}
