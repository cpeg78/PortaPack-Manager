import AppKit
import Foundation
import MapKit
import Testing
@testable import PortaPackManager

/// Regressionstests zu den Funden des Reviews vom 28.10.2026 im Bereich
/// Oberfläche, Leistung, Fernzugriff und FT8.
@Suite("Review 28.10.: Oberfläche, Leistung, Fernzugriff")
@MainActor
struct ReviewFixOberflaecheTests {

    // MARK: W1

    @Test("Fernzugriff: NaN, Unendlich und Überlauf werden als Zahl abgewiesen")
    func endlicheWerteAusDerAbfrage() {
        #expect(RemoteWeather.finite("nan") == nil)
        #expect(RemoteWeather.finite("inf") == nil)
        #expect(RemoteWeather.finite("-inf") == nil)
        #expect(RemoteWeather.finite("1e400") == nil)
        #expect(RemoteWeather.finite("abc") == nil)
        #expect(RemoteWeather.finite(nil) == nil)
        #expect(RemoteWeather.finite("25") == 25)
        // Der frühere Weg ließ NaN durch die Klemmung – genau das darf nicht mehr gespeichert werden.
        #expect(min(max(Double.nan, 10), 70).isNaN)
    }

    // MARK: W8

    @Test("Mausrad-Monitor: nur eigenes Fenster und eigener Bereich")
    func mausradNurImEigenenBereich() {
        let window = NSObject(), other = NSObject()
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(ScrollWheelMonitor.accepts(eventWindow: window, viewWindow: window, hidden: false,
                                           location: CGPoint(x: 50, y: 50), bounds: bounds))
        #expect(!ScrollWheelMonitor.accepts(eventWindow: other, viewWindow: window, hidden: false,
                                            location: CGPoint(x: 50, y: 50), bounds: bounds))
        #expect(!ScrollWheelMonitor.accepts(eventWindow: window, viewWindow: window, hidden: false,
                                            location: CGPoint(x: 250, y: 50), bounds: bounds))
        #expect(!ScrollWheelMonitor.accepts(eventWindow: window, viewWindow: window, hidden: true,
                                            location: CGPoint(x: 50, y: 50), bounds: bounds))
        // Ansicht ohne Fenster (Seite verlassen): nichts annehmen.
        #expect(!ScrollWheelMonitor.accepts(eventWindow: window, viewWindow: nil, hidden: false,
                                            location: CGPoint(x: 50, y: 50), bounds: bounds))
    }

    @Test("Kartenzoom: ohne Hover nichts verbrauchen, Entfernen setzt Hover zurück")
    func kartenzoomOhneHoverReichtWeiter() {
        let zoom = MapScrollZoom()
        zoom.region = MKCoordinateRegion(center: .init(latitude: 53, longitude: 10),
                                         span: .init(latitudeDelta: 1, longitudeDelta: 1))
        let event = ScrollWheelArea.Event(dx: 0, dy: 5, precise: true, modifiers: [], location: .zero)
        var applied: MKCoordinateRegion?
        #expect(!zoom.handle(event, convert: { _ in nil }, apply: { applied = $0 }))
        #expect(applied == nil)
        zoom.cursor = CGPoint(x: 10, y: 10)
        #expect(zoom.handle(event, convert: { _ in nil }, apply: { applied = $0 }))
        #expect((applied?.span.latitudeDelta ?? 1) < 1)
        zoom.reset()
        #expect(zoom.cursor == nil)
        // Seitliches Wischen wird verbraucht, zoomt aber nicht.
        let region = MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 1, longitudeDelta: 1))
        #expect(MapScrollZoom.zoomed(region, dx: 10, dy: 1, precise: true, anchor: region.center) == nil)
    }

    // MARK: W10

    @Test("Sondenverlauf: Seriennummer bleibt, bis gewählt wird oder die Sonde verstummt")
    func sondenverlaufBleibtStehen() {
        let now = Date()
        let heard: [(serial: String, lastSeen: Date)] = [("A", now.addingTimeInterval(-5)), ("B", now)]
        // Ohne bisherige: die zuletzt gehörte.
        #expect(SondeView.followedSerial(current: nil, selected: nil, heard: heard, now: now) == "B")
        // Bisherige noch zu hören: bleibt, obwohl B neuer ist.
        #expect(SondeView.followedSerial(current: "A", selected: nil, heard: heard, now: now) == "A")
        // Auswahl gewinnt.
        #expect(SondeView.followedSerial(current: "A", selected: "B", heard: heard, now: now) == "B")
        // Verstummt (länger als 120 s): Wechsel zur zuletzt gehörten.
        let silent: [(serial: String, lastSeen: Date)] = [("A", now.addingTimeInterval(-300)), ("B", now)]
        #expect(SondeView.followedSerial(current: "A", selected: nil, heard: silent, now: now) == "B")
        #expect(SondeView.followedSerial(current: nil, selected: nil, heard: [], now: now) == nil)
    }

    @Test("Laufender Flug: nur Meldungen der letzten 24 h")
    func laufenderFlugNurAusHeutigemProtokoll() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let now = ISOTime.date("2026-10-28T12:00:00Z")!
        let line = "2026-10-28T10:47:02Z;RS41;V3051090;1060;404.900;53.6;10.1;753;3.7;7.2;89;;;2.9\n"
        let old = "2026-10-01T10:47:02Z;RS41;V3051090;1060;404.900;53.6;10.1;753;3.7;7.2;89;;;2.9\n"
        try db.database.sync { try $0.insertSondeRows(SondeArchive.parse(SondeLog.header + line + old), window: "x") }
        let flight = try #require(SondeArchive.loadCurrent(serial: "V3051090", database: db.database, now: now))
        #expect(flight.samples.count == 1)
        #expect(SondeArchive.loadCurrent(serial: "V3051090", database: db.database, now: now, isCancelled: { true }) == nil)
        #expect(SondeArchive.loadCurrent(serial: "X", database: db.database, now: now) == nil)
    }

    // MARK: W11

    @Test("Archiv: vergangene Tage kommen aus der Datenbank, ohne Zwischenspeicher")
    @MainActor func archivHaeltVergangeneTageNicht() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        let sighting = ArchiveSighting(id: "ABC-1", key: "ABC", first: Date(timeIntervalSince1970: 1_790_000_000),
                                       last: Date(timeIntervalSince1970: 1_790_000_600), messages: 3)
        try db.database.sync { try $0.insertMissingSightings([sighting], kind: .adsb, day: "2026-09-20") }
        let archive = TrafficArchive(kind: .adsb, database: db.database)
        let loaded = await archive.sightings(days: ["2026-09-20"])
        #expect(loaded.map(\.id) == ["ABC-1"])
        // Eintrag weg → nichts liefert ihn weiter.
        try db.database.sync { _ = try $0.run("DELETE FROM sightings") }
        #expect(archive.sightings(day: "2026-09-20").isEmpty)
        #expect(await archive.sightings(days: ["2026-09-20"]).isEmpty)
        // CSV aus beliebigen Sichtungen: älteste zuerst.
        var newer = sighting
        newer.id = "ABC-2"
        newer.last = sighting.last.addingTimeInterval(3600)
        let csv = TrafficArchive.csv([newer, sighting], speedUnit: "kmh").split(separator: "\n")
        #expect(csv.count == 3)
        #expect(csv[1].contains(ISO8601DateFormatter().string(from: sighting.last)))
    }

    @Test("Archivtabelle: Filtern und Sortieren als reine Funktionen")
    func archivtabelleFiltertUndSortiert() {
        let a = ArchiveSighting(id: "1", key: "AAA", name: "LUFTHANSA", first: Date(timeIntervalSince1970: 0),
                                last: Date(timeIntervalSince1970: 100), messages: 1)
        let b = ArchiveSighting(id: "2", key: "BBB", name: "CONDOR", first: Date(timeIntervalSince1970: 0),
                                last: Date(timeIntervalSince1970: 200), messages: 1)
        #expect(ArchiveView.filter([a, b], search: " condor ").map(\.id) == ["2"])
        #expect(ArchiveView.sort([a, b], order: []).map(\.id) == ["2", "1"])
    }

    // MARK: W12

    @Test("Aufbewahrung: Zahl betroffener Einträge und nur Verkürzen fragt nach")
    func aufbewahrungZaehltUndFragt() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let now = Date()
        for (id, age) in [("a", 40.0), ("b", 100), ("c", 5)] {
            let date = now.addingTimeInterval(-age * 86_400)
            let s = ArchiveSighting(id: id, key: id, first: date, last: date, messages: 1)
            try db.database.sync { try $0.insertMissingSightings([s], kind: .ais, day: "d") }
        }
        #expect(ArchiveMaintenance.expiringCount(database: db.database, retentionDays: 30, now: now) == 2)
        #expect(ArchiveMaintenance.expiringCount(database: db.database, retentionDays: 90, now: now) == 1)
        #expect(ArchiveMaintenance.expiringCount(database: db.database, retentionDays: 0, now: now) == 0)
        #expect(ArchiveRetentionPicker.isShortening(from: 0, to: 30))
        #expect(ArchiveRetentionPicker.isShortening(from: 365, to: 90))
        #expect(!ArchiveRetentionPicker.isShortening(from: 90, to: 365))
        #expect(!ArchiveRetentionPicker.isShortening(from: 90, to: 0))
        #expect(ArchiveRetentionPicker.message(.init(days: 30, entries: 2)).contains("2 Archiveinträge"))
    }

    // MARK: Y5, Y15

    @Test("FT8-Wasserfall: Zeitbereich übersteht einen Uhrsprung zurück")
    func wasserfallZeitbereichNachUhrsprung() {
        // `first...last` mit 100 > 90 brach früher ab.
        #expect(FT8Model.timeSpan([100, 101, 90]) == 90...101)
        #expect(FT8Model.timeSpan([5]) == 5...5)
        #expect(FT8Model.timeSpan([]) == nil)
    }

    @Test("WSPR: nach Ablauf der Frist wird nichts mehr gerechnet")
    func wsprHaeltDieFristEin() {
        let x = FT8Signal(re: [Float](repeating: 0.01, count: 114 * 12_000), im: [Float](repeating: 0, count: 114 * 12_000))
        let start = Date()
        let results = WSPRDecoder().decode(x, centers: [1500, 1700], hashes: WSPRCallHashes(), deadline: Date.distantPast)
        #expect(results.isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(WSPRDecoder.cycleBudget < 120)
    }

    // MARK: Y16

    @Test("DSC-Schiffsnamen: neuere Sichtung gewinnt, leere Namen zählen nicht")
    func schiffsnamenNeuereGewinnt() {
        let old = ArchiveSighting(id: "1", key: "211000001", name: "ALT", first: Date(timeIntervalSince1970: 0),
                                  last: Date(timeIntervalSince1970: 10), messages: 1)
        let new = ArchiveSighting(id: "2", key: "211000001", name: "NEU ", first: Date(timeIntervalSince1970: 20),
                                  last: Date(timeIntervalSince1970: 30), messages: 1)
        let blank = ArchiveSighting(id: "3", key: "211000002", name: "  ", first: Date(timeIntervalSince1970: 0),
                                    last: Date(timeIntervalSince1970: 40), messages: 1)
        let names = ShipNameDirectory.names(from: [new, old, blank])
        #expect(names == [211_000_001: "NEU"])
    }

    // MARK: Y18

    @Test("Wärmebild: abgebrochener Renderlauf liefert kein Bild")
    func waermebildBrichtAb() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let slices = (0..<50).map {
            OccupancySlice(start: start.addingTimeInterval(Double($0) * 60), floorDB: -60, visits: 1,
                           mean: [UInt8](repeating: 100, count: 64), peak: [UInt8](repeating: 120, count: 64),
                           occupancy: [UInt8](repeating: 10, count: 64))
        }
        let timeline = OccupancyTimeline(slices: slices, sliceSeconds: 60)
        func render(_ cancelled: Bool) -> CGImage? {
            OccupancyHeatmapRenderer.render(slices: slices, timeline: timeline, binCount: 64, metric: .occupancy,
                                            lo: 0, hi: 1, rowOffset: 0, rowsVisible: 50, width: 64, height: 64,
                                            isCancelled: { cancelled })
        }
        #expect(render(false) != nil)
        #expect(render(true) == nil)
    }

    // MARK: Y19

    @Test("Zigbee-Karte: Netze und Kanten nur bei geänderten Geräten neu")
    func zigbeeKarteRechnetNurBeiAenderung() {
        let memo = ZigbeeMapView.DerivedMemo()
        var node = ZigbeeNode(key: .init(pan: 0x1A62, address: 0), channel: 15, lastSeen: Date(timeIntervalSince1970: 0))
        let key = ZigbeeMapView.DerivedMemo.Key(nodes: [node], channel: 15, chosenPAN: nil, allLinks: false, layoutSet: [])
        _ = memo.derived(key)
        _ = memo.derived(key)
        _ = memo.derived(key)
        #expect(memo.computations == 1)
        node.heard += 1
        let changed = ZigbeeMapView.DerivedMemo.Key(nodes: [node], channel: 15, chosenPAN: nil, allLinks: false, layoutSet: [])
        #expect(memo.derived(changed).shown.count == 1)
        #expect(memo.computations == 2)
    }

    // MARK: Y22

    @Test("Fernzugriffsschlüssel: alter Wert wird unverändert in den Schlüsselbund übernommen")
    func schluesselMigrationBehaeltWert() throws {
        let suite = "review-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("abcd2345wxyz", forKey: "remoteToken")
        let store = RemoteTokenStore.memory()
        let token = store.loadOrMigrate(defaults: defaults, key: "remoteToken", make: { "neu-neu-neu1" })
        #expect(token == "abcd2345wxyz")
        #expect(store.load() == .found("abcd2345wxyz"))
        #expect(defaults.string(forKey: "remoteToken") == nil)
        // Zweiter Start: aus dem Schlüsselbund, derselbe Wert.
        #expect(store.loadOrMigrate(defaults: defaults, key: "remoteToken", make: { "neu-neu-neu1" }) == "abcd2345wxyz")
    }

    @Test("Fernzugriffsschlüssel: unlesbarer Schlüsselbund sperrt niemanden aus")
    func schluesselbundFehlerBehaeltAltenWert() throws {
        let suite = "review-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("abcd2345wxyz", forKey: "remoteToken")
        let failing = RemoteTokenStore.memory(failing: true)
        #expect(failing.loadOrMigrate(defaults: defaults, key: "remoteToken", make: { "neu-neu-neu1" }) == "abcd2345wxyz")
        #expect(defaults.string(forKey: "remoteToken") == "abcd2345wxyz")
        // Ganz neu: erzeugt und gesichert.
        let fresh = RemoteTokenStore.memory()
        let other = try #require(UserDefaults(suiteName: suite + "-2"))
        defer { other.removePersistentDomain(forName: suite + "-2") }
        #expect(fresh.loadOrMigrate(defaults: other, key: "remoteToken", make: { "neu-neu-neu1" }) == "neu-neu-neu1")
        #expect(fresh.load() == .found("neu-neu-neu1"))
        #expect(other.string(forKey: "remoteToken") == nil)
    }

    @Test("HTTP-Server: Grenze je Gegenstelle und insgesamt")
    func serverGrenzeJeGegenstelle() {
        let busy = [String?](repeating: "192.168.1.5", count: 16)
        #expect(!RemoteHTTPServer.admits(peer: "192.168.1.5", openPeers: busy))
        #expect(RemoteHTTPServer.admits(peer: "192.168.1.6", openPeers: busy))
        #expect(RemoteHTTPServer.admits(peer: "192.168.1.5", openPeers: Array(busy.prefix(15))))
        let full = [String?](repeating: nil, count: RemoteHTTPServer.maximumOpen)
        #expect(!RemoteHTTPServer.admits(peer: "10.0.0.1", openPeers: full))
        #expect(RemoteHTTPServer.admits(peer: nil, openPeers: busy))
    }

    @Test("Fernzugriffsseite nimmt den Schlüssel aus der Adresszeile")
    func seiteEntferntSchluesselAusAdresse() {
        #expect(RemotePage.html.contains("history.replaceState"))
        #expect(RemotePage.html.contains("searchParams.delete('k')"))
        // Die Web-App vom Home-Bildschirm startet weiter mit Schlüssel.
        #expect(RemotePage.manifest(token: "abc").contains("\"start_url\":\"/?k=abc\""))
    }

    // MARK: Nitpicks

    @Test("3D-Netzkarte: Schildbilder hängen am Erscheinungsbild")
    func schildbilderJeErscheinungsbild() {
        let light = ZigbeeMap3DView.Coordinator.labelKey("Koordinator", highlighted: false, dimmed: false, dark: false)
        let dark = ZigbeeMap3DView.Coordinator.labelKey("Koordinator", highlighted: false, dimmed: false, dark: true)
        #expect(light != dark)
    }
}
