import Foundation
import Testing
@testable import PortaPackManager

@Suite("Satellitenbahnen")
struct SatelliteTests {
    static let tleText = """
    METEOR-M2 3
    1 57166U 23091A   26299.27775164 -.00000010  00000+0  14498-4 0  9998
    2 57166  98.5927 351.4664 0004688 137.9984 222.1555 14.24054972173172
    METEOR-M2 4
    1 59051U 24039A   26299.30034872 -.00000015  00000+0  13037-4 0  9997
    2 59051  98.7204 257.0563 0007569 143.2187 216.9512 14.22441249137902
    """

    /// Bezugswerte aus python-sgp4 2.x (Vallado-C++), WGS-72, gleiche TLE.
    static let reference: [(Int, Double, [Double], [Double])] = [
        (0, 0.0, [7115.57412722971, -1067.6957121419018, -0.0021789465733131346], [-0.1748069702854731, -1.0976209802799242, 7.359892286921832]),
        (0, 360.0, [-6578.754055170529, 1352.1673984464774, -2576.5404085615783], [2.8102167247461893, 0.6379569623504444, -6.8634543340131]),
        (0, 1440.0, [629.7667167954429, -1160.0629744062494, 7057.943226175907], [-7.3577523019107565, 0.8552444993008176, 0.7927933858485781]),
        (0, 4320.0, [-2196.6923762595316, 1239.8087358943571, -6742.460753172328], [7.039266959871796, -0.33254934102637745, -2.3583112744477157]),
        (1, 0.0, [-1613.3184553139617, -7019.505842126649, 0.008515254147669207], [-1.0959745564979329, 0.2632132176184926, 7.352727083472579]),
        (1, 360.0, [1849.436783207496, 6523.551887240287, -2413.52074348547], [0.48249529680427694, -2.687448576434067, -6.923946276403783]),
        (1, 1440.0, [-1353.2828755876312, -1244.501257306786, 6946.356335372816], [1.280075325086764, 7.175817238651224, 1.5268743549997847]),
        (1, 4320.0, [1604.0057903206623, 4014.2944625663445, -5761.680121338141], [-0.3888190746937044, -6.034066426956986, -4.3212041973185]),
    ]

    @Test func tleWirdGelesen() throws {
        let tles = TLE.parse(Self.tleText)
        #expect(tles.count == 2)
        #expect(tles[0].name == "METEOR-M2 3")
        #expect(tles[0].catalogNumber == 57166)
        #expect(abs(tles[0].bstar - 0.14498e-4) < 1e-12)
        #expect(abs(tles[1].meanMotion - 14.22441249 * 2 * .pi / 1440) < 1e-12)
        // Epoche 2026, Tag 299.27775164 = 26.10.2026 06:39:57 UTC
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: tles[0].epoch)
        #expect(components.month == 10 && components.day == 26 && components.hour == 6 && components.minute == 39)
    }

    @Test func sgp4StimmtMitReferenzUeberein() throws {
        let tles = TLE.parse(Self.tleText)
        for (index, minutes, r, v) in Self.reference {
            let state = try SGP4(tles[index]).propagate(minutes: minutes)
            let dr = state.position - SIMD3(r[0], r[1], r[2])
            let dv = state.velocity - SIMD3(v[0], v[1], v[2])
            #expect((dr * dr).sum().squareRoot() < 1e-3, "Position \(index) bei \(minutes) min: \(dr)")
            #expect((dv * dv).sum().squareRoot() < 1e-6, "Geschwindigkeit \(index) bei \(minutes) min: \(dv)")
        }
    }
}

@Suite("Überflüge")
struct PassPredictionTests {
    /// Bezug: eigenständiges Skript mit python-sgp4 (30-s-Raster, gleiche
    /// Formeln für Ort/Sternzeit, Gipfel im 1-s-Raster) – Hamburger Rathaus
    /// 53,55° N 9,99° O, ab 26.10.2026 12:56 UTC: M2-4 14:05–14:20 (39,4° um
    /// 14:12), M2-3 18:37–18:51 (37,6°), 20:16–20:31 (43,8°), M2-4 27.10.
    /// 02:14–02:29 (51,1°).
    @Test func ueberfluegeWieReferenz() throws {
        let tles = TLE.parse(SatelliteTests.tleText)
        let station = GroundStation(latitude: 53.55, longitude: 9.99, altitudeKm: 0.05)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12, minute: 56))!
        let m23 = PassPredictor.passes(WeatherSatellite.all[0], tle: tles[0], station: station, from: start, hours: 14, minElevation: 20)
        let m24 = PassPredictor.passes(WeatherSatellite.all[1], tle: tles[1], station: station, from: start, hours: 14, minElevation: 20)
        func hm(_ d: Date) -> String {
            let c = utc.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour!, c.minute!)
        }
        #expect(m23.map { hm($0.culmination) } == ["18:44", "20:24"] || m23.map { hm($0.culmination) } == ["18:43", "20:23"])
        #expect(m23.count == 2 && abs(m23[0].maxElevation - 37.6) < 0.5 && abs(m23[1].maxElevation - 43.8) < 0.5)
        #expect(m24.count == 2 && abs(m24[0].maxElevation - 39.4) < 0.5 && abs(m24[1].maxElevation - 51.1) < 0.5)
        // Auf-/Untergang innerhalb der 30-s-Rasterung der Referenz.
        let rise = utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 14, minute: 5))!
        #expect(abs(m24[0].start.timeIntervalSince(rise)) < 60)
        #expect(m24[0].daylight)
        #expect(!m24[1].daylight)
    }

    @Test func sonnenhoeheGrob() {
        let station = GroundStation(latitude: 53.55, longitude: 9.99)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Mittag Ende Oktober in Norddeutschland ≈ 24°, Mitternacht deutlich unter 0.
        let noon = utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 11, minute: 25))!
        let night = utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 25))!
        #expect(abs(station.sunElevation(at: noon) - 24) < 1.5)
        #expect(station.sunElevation(at: night) < -40)
    }
}

@Suite("Empfangsplan")
@MainActor
struct PlannerJobTests {
    private func pass(_ culmination: TimeInterval, satellite: WeatherSatellite = WeatherSatellite.all[1]) -> SatellitePass {
        let c = Date(timeIntervalSince1970: 1_793_000_000 + culmination)
        return SatellitePass(satellite: satellite, start: c.addingTimeInterval(-420), end: c.addingTimeInterval(420),
                             culmination: c, maxElevation: 40, startAzimuth: 180, endAzimuth: 0, sunElevation: 20)
    }

    @Test func neuGerechneterUeberflugBleibtDerselbeTermin() {
        let first = ReceptionPlanner.Job(kind: .pass(pass(0)))
        let recomputed = ReceptionPlanner.Job(kind: .pass(pass(25)))
        #expect(first.same(as: recomputed))
        #expect(!first.same(as: ReceptionPlanner.Job(kind: .pass(pass(6000)))))
        #expect(!first.same(as: ReceptionPlanner.Job(kind: .pass(pass(0, satellite: WeatherSatellite.all[0])))))
        #expect(!first.same(as: nil))
    }
}

struct SondeHubTrafficTests {
    @Test func nurSondenInReichweiteUndUeberDemHorizont() throws {
        let json = """
        {"NAH":{"lat":53.9,"lon":9.9,"alt":12000,"type":"RS41","frequency":403.5},
         "FERN":{"lat":52.21,"lon":14.12,"alt":8602,"type":"RS41","frequency":405.1},
         "TIEF":{"lat":54.9,"lon":9.99,"alt":100,"type":"RS41","frequency":402.2},
         "KAPUTT":{"type":"DFM"}}
        """
        let found = try SondeHubTraffic.inRange(Data(json.utf8), latitude: 53.55, longitude: 9.99, rangeKm: 250)
        #expect(found.map(\.serial) == ["NAH"])
        #expect(abs(found[0].distanceKm - 39.4) < 1)
        #expect(found[0].frequencyMHz == 403.5)
    }
}
