import Foundation
import Testing
@testable import PortaPackManager

/// `/api/sondes` des Fernzugriffs: Form der JSON-Antwort, Landeschätzung wie am Mac,
/// Ausdünnen der Bahn, strenge Seriennummern.
@Suite("Fernzugriff: Wetterballons")
struct RemoteSondesTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Sonde im Sinkflug nach dem Platzen, mit 2000 Bahnpunkten.
    private static func fallingSonde() -> Sonde {
        var tracker = SondeTracker()
        for i in 0..<2000 {
            var report = SondeReport(kind: .rs41, serial: "X4917657", model: "RS41-SGP")
            let up = i < 1500
            report.latitude = 53 + Double(i) * 0.0001
            report.longitude = 9 + Double(i) * 0.0002
            report.altitude = up ? Double(i) * 20 : 30_000 - Double(i - 1500) * 30
            report.verticalSpeed = up ? 5 : -15
            report.groundSpeed = 10; report.heading = 90
            report.temperature = -20.04; report.humidity = 12.6
            report.frequency = 402_500_000
            tracker.ingest(report, at: now.addingTimeInterval(Double(i - 2000)))
        }
        return tracker.sorted[0]
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test("Liste enthält Heimatstandort, Bahn (≤ 600 Punkte) und Landeschätzung")
    func liste() throws {
        let sonde = Self.fallingSonde()
        let list = RemoteSondes.list([sonde], home: GroundStation(latitude: 53.1, longitude: 9.2), groundAltitude: 100, now: Self.now)
        let object = try json(list)
        #expect(Set(object.keys) == ["home", "groundAltitude", "live"])
        let live = try #require((object["live"] as? [[String: Any]])?.first)
        #expect(live["serial"] as? String == "X4917657")
        #expect(live["frequency"] as? Double == 402.5)
        #expect(live["burst"] as? Bool == true)
        #expect(live["temperature"] as? Double == -20)
        let track = try #require(live["track"] as? [[Double]])
        #expect(track.count == RemoteSondes.maxPoints)
        #expect(track.allSatisfy { $0.count == 3 })
        // Landung genau wie am Mac.
        let expected = try #require(sonde.landing(groundAltitude: 100))
        let landing = try #require(live["landing"] as? [String: Any])
        #expect(abs((landing["lat"] as? Double ?? 0) - expected.lat) < 1e-4)
        #expect(abs((landing["lon"] as? Double ?? 0) - expected.lon) < 1e-4)
        #expect(landing["minutes"] as? Int == Int((expected.seconds / 60).rounded()))
    }

    @Test("Ohne Standort und ohne Sinkflug fehlen Heimat und Landung")
    func ohneStandort() throws {
        var tracker = SondeTracker()
        var report = SondeReport(kind: .rs41, serial: "W4041361", model: "RS41")
        report.latitude = 53; report.longitude = 9; report.altitude = 5000; report.verticalSpeed = 5
        tracker.ingest(report, at: Self.now)
        let object = try json(RemoteSondes.list(tracker.sorted, home: nil, groundAltitude: 100, now: Self.now))
        #expect(object["home"] == nil)
        let live = try #require((object["live"] as? [[String: Any]])?.first)
        #expect(live["landing"] == nil)
        #expect(live["age"] as? Int == 0)
    }

    @Test("Archivflug wird auf höchstens 600 Punkte ausgedünnt, erster und letzter bleiben")
    func archivflug() throws {
        let start = Self.now
        let samples = (0..<1700).map { (i: Int) -> SondeSample in
            let x = Double(i)
            let positioned = i % 3 != 0
            var sample = SondeSample(date: start.addingTimeInterval(x))
            sample.latitude = positioned ? 53 : nil
            sample.longitude = positioned ? 9 : nil
            sample.altitude = x * 18
            sample.temperature = 10 - x * 0.04
            sample.humidity = 50
            return sample
        }
        let flight = SondeFlight(serial: "X3753765", type: "RS41", samples: samples)
        let object = try json(RemoteSondes.track(flight))
        #expect(Set(object.keys) == ["serial", "type", "start", "end", "peak", "burst", "total", "points"])
        #expect(object["total"] as? Int == 1700)
        let points = try #require(object["points"] as? [[String: Any]])
        #expect(points.count == 600)
        let firstT: Double = start.timeIntervalSince1970 * 1000
        let lastT: Double = firstT + 1_699_000
        #expect(points.first?["t"] as? Double == firstT)
        #expect(points.last?["t"] as? Double == lastT)
        #expect(points.first?["lat"] == nil)   // ohne Position fehlt das Feld
        #expect(points.first?["temp"] as? Double == 10)
    }

    @Test("Seriennummern nur aus Großbuchstaben und Ziffern")
    func seriennummern() {
        #expect(RemoteSondes.isValidSerial("X4917657"))
        #expect(RemoteSondes.isValidSerial("12345"))
        for bad in ["", "x4917657", "X49/..", "X49;1", "M10-123", "Ä1", String(repeating: "A", count: 17), "X4917657\n"] {
            #expect(!RemoteSondes.isValidSerial(bad), "\(bad)")
        }
    }

    @Test("Ungültige Seriennummer wird abgewiesen")
    @MainActor func abweisen() async {
        let response = await RemoteSondes.handle(["serial": "../etc"])
        guard case .data(let status, _, _) = response else { Issue.record("keine Daten"); return }
        #expect(status == 400)
    }
}
