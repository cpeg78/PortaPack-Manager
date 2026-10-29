import Foundation
import Testing
@testable import PortaPackManager

@Suite("Sondenvorhersage")
struct SondeForecastTests {
    private static let sites = Data("""
    {"10035": {"station_name": "Schleswig (Germany)", "position": [9.55, 54.53], "alt": 43,
               "times": ["0:00:00", "0:12:00"], "rs_types": [["41", "402.5"]], "burst_altitude": 33000},
     "10304": {"station_name": "Meppen (Germany)", "position": [7.33, 52.72],
               "times": ["2:11:00", "3:11:00"], "rs_types": ["41"]},
     "-17": {"station_name": "Pinneberg (Germany)", "position": [9.8, 53.65], "times": [], "rs_types": ["41"]}}
    """.utf8)

    private static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test("Startplätze: ohne Startzeiten weggelassen, Frequenz aus rs_types")
    func parseSites() throws {
        let sites = try SondeForecast.parseSites(Self.sites).sorted { $0.id < $1.id }
        #expect(sites.map(\.name) == ["Schleswig", "Meppen"])
        #expect(sites[0].frequencyMHz == 402.5)
        #expect(sites[1].frequencyMHz == nil)
        #expect(sites[1].burstAltitude == 33_000)
    }

    @Test("Start = Termin − 75 min, Wochentag beachtet (27.10.2026 ist ein Dienstag)")
    func launches() throws {
        let sites = try SondeForecast.parseSites(Self.sites)
        let start = Self.utc("2026-10-27T10:45:00Z"), end = Self.utc("2026-10-27T12:45:00Z")
        let schleswig = sites.first { $0.id == "10035" }!
        #expect(SondeForecast.launches(of: schleswig, from: start, to: end) == [Self.utc("2026-10-27T10:45:00Z")])
        let meppen = sites.first { $0.id == "10304" }!
        // Dienstag = 2 → 11:00 − 75 min liegt vor dem Fenster, also Fensterbeginn.
        #expect(SondeForecast.launches(of: meppen, from: start, to: end) == [start])
        let wednesday = Self.utc("2026-10-28T10:45:00Z")
        #expect(SondeForecast.launches(of: meppen, from: wednesday, to: wednesday.addingTimeInterval(7200)).count == 1)
        let night = Self.utc("2026-10-27T22:45:00Z")
        #expect(SondeForecast.launches(of: schleswig, from: night, to: night.addingTimeInterval(7200)) == [night])
    }

    @Test("Bahn: Reichweite, Funkhorizont, nächster Punkt, Landung")
    func flight() throws {
        let site = try SondeForecast.parseSites(Self.sites).first { $0.id == "10035" }!
        let home = GroundStation(latitude: 53.55, longitude: 9.99)        // Hamburger Rathaus
        let json = Data("""
        {"prediction": [
          {"stage": "ascent", "trajectory": [
            {"altitude": 43, "datetime": "2026-10-27T10:45:00Z", "latitude": 54.53, "longitude": 9.55},
            {"altitude": 9000, "datetime": "2026-10-27T11:15:00Z", "latitude": 54.30, "longitude": 9.9},
            {"altitude": 30000, "datetime": "2026-10-27T12:25:00Z", "latitude": 54.4, "longitude": 11.5}]},
          {"stage": "descent", "trajectory": [
            {"altitude": 200, "datetime": "2026-10-27T13:20:00Z", "latitude": 54.5, "longitude": 12.5}]}]}
        """.utf8)
        let f = try SondeForecast.flight(from: json, site: site, launch: Self.utc("2026-10-27T10:45:00Z"), home: home, rangeKm: 110)
        // Am Boden in 113 km liegt der Startplatz hinter dem Horizont (≈ 11 km);
        // in 9 km Höhe ≈ 84 km entfernt und sichtbar; 30 km hoch ≈ 137 km – zu weit.
        #expect(f.inRange == Self.utc("2026-10-27T11:15:00Z")...Self.utc("2026-10-27T11:15:00Z"))
        #expect(abs(f.closestKm - 84) < 3)
        #expect(f.closestAltitude == 9000)
        #expect(f.landingKm > 190)
        #expect(f.frequencyMHz == 402.5)
    }
}
