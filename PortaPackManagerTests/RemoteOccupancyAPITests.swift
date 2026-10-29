import Foundation
import ImageIO
import Testing
@testable import PortaPackManager

/// `/api/occupancy` und `/occupancy.png` des Fernzugriffs: Form der Antwort,
/// Bandwahl, neue Aufzeichnung, Wärmebild. Ohne Gerät; eigene UserDefaults
/// und ein eigener Ablageordner (nie die der App).
@Suite("Fernzugriff: Belegungsmonitor")
@MainActor
struct RemoteOccupancyAPITests {
    private static let plan = OccupancyPlan(startMHz: 433.05, endMHz: 434.79, binKHz: 10)   // 174 Bins

    /// Monitor mit eigenem Ordner und eigenen Einstellungen.
    private final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-occ-\(UUID().uuidString)")
        let suite = "RemoteOccupancyAPITests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: OccupancyStore
        let monitor: OccupancyMonitor

        @MainActor init() {
            defaults = UserDefaults(suiteName: suite)!
            store = OccupancyStore(folder: folder)
            monitor = OccupancyMonitor(store: store, defaults: defaults)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    /// `count` Minuten-Scheiben bis `end`; Bin 10 ist in jeder zweiten zu 50 % belegt.
    private static func recording(count: Int, end: Date) -> OccupancyRecording {
        var rec = OccupancyRecording(name: "433 MHz ISM", plan: plan, sliceSeconds: 60, thresholdDB: 10)
        let bins = plan.binCount
        rec.slices = (0..<count).map { i in
            var occ = [UInt8](repeating: 0, count: bins)
            if i % 2 == 0 { occ[10] = OccupancySlice.encodeOccupancy(0.5) }
            return OccupancySlice(start: end.addingTimeInterval(Double(i - count) * 60), floorDB: -60, visits: 20,
                                  mean: [UInt8](repeating: OccupancySlice.encodeDB(-58), count: bins),
                                  peak: [UInt8](repeating: OccupancySlice.encodeDB(-50), count: bins),
                                  occupancy: occ)
        }
        return rec
    }

    private func open(_ fixture: Fixture, _ rec: OccupancyRecording) async throws {
        let url = fixture.store.newURL()
        try fixture.store.write(rec, to: url)
        fixture.monitor.open(url)
        // Die Auswertung (aktivste Frequenzen) läuft im Hintergrund.
        for _ in 0..<200 where fixture.monitor.active.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func json(_ state: RemoteOccupancyAPI.State) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    }

    @Test("Zustand: Band, Vorlagen, Aufzeichnung, Ausschnitt und aktivste Frequenzen")
    func stateShape() async throws {
        let f = Fixture()
        let now = Date()
        try await open(f, Self.recording(count: 120, end: now))
        let state = RemoteOccupancyAPI.state(f.monitor, hours: 1, now: now)
        let object = try json(state)
        for key in ["running", "startMHz", "endMHz", "binKHz", "bins", "sliceSeconds", "thresholdDB", "rounds",
                    "presets", "recording", "view", "legend", "active", "revision"] {
            #expect(object[key] != nil, "Feld \(key) fehlt")
        }
        #expect(state.running == false)
        #expect(state.presets.count == OccupancyPreset.all.count)
        #expect(state.presets.contains { $0.id == "PMR446" })
        let rec = try #require(state.recording)
        #expect(rec.slices == 120)
        #expect(rec.seconds == 7200)
        #expect(rec.continues)
        // Ausschnitt der letzten Stunde: 60 Scheiben, endet mit der jüngsten.
        let view = try #require(state.view)
        #expect(view.rows == 60)
        #expect(view.t1 == (now.timeIntervalSince1970 * 1000).rounded())
        let active = try #require(state.active.first)
        #expect(abs(active.mhz - Self.plan.binCenterMHz(10)) < 1e-4)
        #expect(abs(active.occ - 25) < 0.5)
        #expect(active.last != nil)
        // Keine Dateipfade in der Antwort.
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!text.contains(f.folder.lastPathComponent))
        #expect(!text.contains(".ppocc"))
    }

    @Test("Bandwahl über Vorlage und Bereich, ohne laufenden Monitor")
    func chooseBand() throws {
        let f = Fixture()
        let m = f.monitor
        #expect(RemoteOccupancyAPI.apply(["preset": "PMR446"], monitor: m, device: nil) != nil)
        #expect(m.presetName == "PMR446")
        #expect(m.startMHz == 446.0 && m.endMHz == 446.2)
        // Gemerkt in den eigenen Einstellungen.
        #expect(f.defaults.string(forKey: "occupancyPreset") == "PMR446")

        #expect(RemoteOccupancyAPI.apply(["preset": "Gibt es nicht"], monitor: m, device: nil) == "Unbekannte Vorlage.")
        #expect(m.presetName == "PMR446")

        _ = RemoteOccupancyAPI.apply(["start": "144,0", "end": "146"], monitor: m, device: nil)
        #expect(m.startMHz == 144 && m.endMHz == 146)
        #expect(m.presetName == "2-m-Band")

        _ = RemoteOccupancyAPI.apply(["start": "150", "end": "151.5"], monitor: m, device: nil)
        #expect(m.presetName == nil)

        for (s, e) in [("146", "144"), ("100", "1200"), ("0.5", "2"), ("abc", "5"), ("nan", "100")] {
            let message = RemoteOccupancyAPI.apply(["start": s, "end": e], monitor: m, device: nil)
            #expect(message?.hasPrefix("Ungültiger Bereich") == true, "\(s)–\(e)")
            #expect(m.startMHz == 150 && m.endMHz == 151.5)
        }
        // Ohne Aktion keine Meldung.
        #expect(RemoteOccupancyAPI.apply(["hours": "6"], monitor: m, device: nil) == nil)
    }

    @Test("Neue Aufzeichnung ohne Lauf schließt die geöffnete, die Datei bleibt")
    func freshWhileStopped() async throws {
        let f = Fixture()
        try await open(f, Self.recording(count: 10, end: Date()))
        #expect(f.monitor.recording != nil)
        let message = RemoteOccupancyAPI.apply(["fresh": "1"], monitor: f.monitor, device: nil)
        #expect(message?.contains("neue Aufzeichnung") == true)
        #expect(f.monitor.recording == nil)
        #expect(f.store.list().count == 1)
        #expect(RemoteOccupancyAPI.state(f.monitor).recording == nil)
    }

    @Test("Zeitraum wird begrenzt")
    func hoursParameter() {
        #expect(RemoteOccupancyAPI.hoursParameter(nil) == 6)
        #expect(RemoteOccupancyAPI.hoursParameter("24") == 24)
        #expect(RemoteOccupancyAPI.hoursParameter("0") == 0.25)
        #expect(RemoteOccupancyAPI.hoursParameter("1e9") == 168)
        #expect(RemoteOccupancyAPI.hoursParameter("nan") == 6)
    }

    @Test("Wärmebild: PNG in der verlangten, begrenzten Größe; leerer Zeitraum ohne Bild")
    func heatmapPNG() throws {
        let now = Date()
        let rec = Self.recording(count: 90, end: now)
        let data = try #require(RemoteOccupancyAPI.renderPNG(recording: rec, hours: 6, width: 400, height: 240,
                                                             metric: .occupancy, now: now))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        func size(_ data: Data) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return (image.width, image.height)
        }
        #expect(try size(data) == (400, 240))
        let big = try #require(RemoteOccupancyAPI.renderPNG(recording: rec, hours: 6, width: 5000, height: 9000,
                                                            metric: .peak, now: now))
        #expect(try size(big) == (1600, 1600))
        // Aufzeichnung endete vor zwei Tagen: in den letzten 24 h nichts.
        #expect(RemoteOccupancyAPI.renderPNG(recording: rec, hours: 24, width: 400, height: 240, metric: .occupancy,
                                             now: now.addingTimeInterval(2 * 86_400)) == nil)
        #expect(RemoteOccupancyAPI.slices(rec, hours: 0.5, now: now).count == 30)
    }
}
