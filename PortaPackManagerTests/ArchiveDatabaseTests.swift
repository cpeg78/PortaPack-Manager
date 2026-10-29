import Foundation
import SQLite3
import Testing
@testable import PortaPackManager

@Suite("Archiv-Datenbank")
struct ArchiveDatabaseTests {
    @Test("Neue Datei: WAL, Schema-Stand, inkrementelles Vacuum, Fremdschlüssel")
    func pragmas() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let (mode, version, vacuum, keys) = try db.database.sync { conn in
            (try conn.query("PRAGMA journal_mode") { $0.text(0) ?? "" }.first ?? "",
             conn.userVersion,
             try conn.scalar("PRAGMA auto_vacuum") ?? -1,
             try conn.scalar("PRAGMA foreign_keys") ?? -1)
        }
        #expect(mode == "wal")
        #expect(version == ArchiveDatabase.schemaVersion)
        #expect(vacuum == 2)   // INCREMENTAL
        #expect(keys == 1)
    }

    @Test("Spur als BLOB: Rundlauf mit und ohne Höhe")
    func trackCodec() {
        let track: [[Double]] = [[53.12345, 9.98765], [53.2, 10.1, 11_582], [-33.9, -151.2, -12]]
        let data = TrackCodec.encode(track)
        #expect(data.count == 36)
        #expect(TrackCodec.decode(data) == track)
        #expect(TrackCodec.decode(Data()) == [])
    }

    @Test("Beschädigte Datei wird umbenannt und neu angelegt, mit Hinweis")
    func corruptFile() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let url = db.folder.appendingPathComponent(ArchiveDatabase.fileName)
        try Data(repeating: 0x42, count: 8192).write(to: url)
        let database = ArchiveDatabase(url: url)
        #expect(try database.sync { try $0.sightings(kind: .adsb, days: nil) }.isEmpty)
        #expect(database.notice != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: db.folder.path)
        #expect(names.contains { $0.hasPrefix("Archiv-beschädigt-") })
    }

    @Test("Volltextsuche in Flugfunk-Abschriften (FTS5, Umlaute und Groß/klein egal)")
    func fullText() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        let log = AirbandLog(folder: db.folder.appendingPathComponent("Flugfunk"), database: db.database)
        let a = AirbandTransmission(start: Date(timeIntervalSince1970: 1), duration: 2, index: 1, name: "", peakDB: 1)
        let b = AirbandTransmission(start: Date(timeIntervalSince1970: 2), duration: 2, index: 2, name: "", peakDB: 1)
        log.insert([a, b])
        log.setTranscript(a.id, text: "Lufthansa 4AB, descend flight level eight zero, contact Bremen Radar", language: "en", confidence: 0.8)
        log.setTranscript(b.id, text: "Christoph 29, Landung frei Piste zwo drei, Wind ruhig", language: "de", confidence: 0.6)
        #expect(await log.search("bremen").map(\.id) == [a.id])
        #expect(await log.search("\"piste zwo\"").map(\.id) == [b.id])
        #expect(await log.search("LANDUNG").first?.transcript?.contains("Piste") == true)
        // Abschrift ändern und Eintrag löschen halten den Index aktuell.
        log.setTranscript(a.id, text: "Speedbird 12, cleared to land", language: "en", confidence: 0.9)
        #expect(await log.search("bremen").isEmpty)
        log.delete(b)
        #expect(await log.search("landung").isEmpty)
        #expect(await log.search("cleared").first?.transcriptLanguage == "en")
    }

    @Test("Fehlerhafte SQL-Anweisung: Fehler statt Absturz, Datenbank bleibt nutzbar")
    func errors() throws {
        let db = TestDatabase()
        defer { db.remove() }
        #expect(throws: SQLiteError.self) { try db.database.sync { try $0.execute("SELECT * FROM gibtsnicht") } }
        db.database.write { try $0.execute("INSERT INTO gibtsnicht VALUES (1)") }   // nur protokolliert
        #expect(try db.database.sync { try $0.scalar("SELECT COUNT(*) FROM sightings") } == 0)
    }
}

/// Leistung mit synthetischen Daten in einer Temp-Datenbank. Die Werte stehen in
/// `Docs/Erfahrungen/Datenbank.md` (Release mit `ENABLE_TESTABILITY=YES`).
@Suite("Archiv-Datenbank: Leistung", .serialized)
struct ArchiveDatabaseBenchmarks {
    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func report(_ text: String) {
        print("BENCH " + text)
    }

    @Test("100 000 Sichtungen: Einfügen, Tag, Kennung, Tagesliste")
    func sightings() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let clock = ContinuousClock()
        let base = 1_760_000_000.0
        var generator = SystemRandomNumberGenerator()
        // 365 Tage, 5000 verschiedene Flugzeuge, je Sichtung 40 Spurpunkte mit Höhe.
        let total = 100_000
        let batches = (0..<(total / 1000)).map { batch in
            (0..<1000).map { i -> (sighting: ArchiveSighting, day: String) in
                let n = batch * 1000 + i
                let first = base + Double(n) * 315.36
                let key = String(format: "%06X", 0x3C0000 + (n * 7919) % 5000)
                let track = (0..<40).map { (p: Int) -> [Double] in
                    let step = Double(p) * 0.01
                    return [53.0 + step, 10.0 + step, Double(9000 + p * 10)]
                }
                let s = ArchiveSighting(id: "\(key)-\(Int(first))", key: key, name: "DLH\(n % 900)", registration: "D-A\(n % 99)",
                                        type: "Airbus A320", operatorName: "Lufthansa", route: "Hamburg (HAM) → München (MUC)",
                                        first: Date(timeIntervalSince1970: first), last: Date(timeIntervalSince1970: first + 600),
                                        messages: Int.random(in: 10...900, using: &generator), maxAltitudeM: 11_000, maxSpeed: 850,
                                        minDistanceKm: 12.5, track: track)
                return (s, String(format: "2026-%03d", n * 365 / total))
            }
        }
        let insert = clock.measure {
            for batch in batches { try? db.database.sync { try $0.upsertSightings(batch, kind: .adsb) } }
        }
        let count = try db.database.sync { try $0.scalar("SELECT COUNT(*) FROM sightings") }
        #expect(count == total)
        let rate = Double(total) / (Self.ms(insert) / 1000)
        Self.report("Sichtungen einfügen: \(total) in \(Int(Self.ms(insert))) ms = \(Int(rate))/s")

        var dayRows = 0
        let day = clock.measure { dayRows = (try? db.database.sync { try $0.sightings(kind: .adsb, days: ["2026-180"]) })?.count ?? 0 }
        Self.report("Sichtungen eines Tages (\(dayRows) mit Spur): \(String(format: "%.1f", Self.ms(day))) ms")

        var keyRows = 0
        let key = clock.measure { keyRows = (try? db.database.sync { try $0.sightings(kind: .adsb, key: "3C0000") })?.count ?? 0 }
        Self.report("Alle Tage nach Kennung (\(keyRows) Sichtungen): \(String(format: "%.1f", Self.ms(key))) ms")

        var dayCount = 0
        let days = clock.measure { dayCount = (try? db.database.sync { try $0.sightingDays(kind: .adsb) })?.count ?? 0 }
        Self.report("Tagesliste (\(dayCount) Tage): \(String(format: "%.1f", Self.ms(days))) ms")

        var summary = SQLiteConnection.Summary()
        let stats = clock.measure { summary = (try? db.database.sync { try $0.sightingSummary(kind: .adsb) }) ?? .init() }
        Self.report("Übersicht COUNT/DISTINCT (\(summary.entries), \(summary.distinct)): \(String(format: "%.1f", Self.ms(stats))) ms")

        var all = 0
        let everything = clock.measure { all = (try? db.database.sync { try $0.sightings(kind: .adsb, days: nil) })?.count ?? 0 }
        Self.report("Alle Sichtungen lesen (\(all)): \(Int(Self.ms(everything))) ms")
        Self.report("Dateigröße 100 000 Sichtungen: \(db.database.fileSize() / 1_048_576) MB")

        #expect(dayRows > 200)
        #expect(keyRows == 20)
        #expect(dayCount == 365)
        #expect(Self.ms(day) < 200)
        #expect(Self.ms(key) < 200)
    }

    @Test("1 Mio. Sondenmeldungen: Einfügen, Flug, laufender Flug, jüngste Flüge")
    func sondes() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let clock = ContinuousClock()
        let total = 1_000_000
        let perFlight = 5000
        let base = 1_760_000_000.0
        let insert = clock.measure {
            for chunk in stride(from: 0, to: total, by: 10_000) {
                let rows = (chunk..<(chunk + 10_000)).map { n -> SondeArchive.Row in
                    let flight = n / perFlight, i = n % perFlight
                    return SondeArchive.Row(serial: String(format: "V%07d", flight), type: "RS41", frame: i, sample: SondeSample(
                        date: Date(timeIntervalSince1970: base + Double(flight) * 43_200 + Double(i)), frequencyMHz: 404.9,
                        latitude: 53.6 + Double(i) * 1e-4, longitude: 10.1 + Double(i) * 1e-4, altitude: Double(i) * 6,
                        verticalSpeed: 5, windSpeed: 12, heading: 90, temperature: 15 - Double(i) * 0.015, humidity: 60, battery: 2.8))
                }
                try? db.database.sync { try $0.insertSondeRows(rows, window: "w\(chunk / perFlight)") }
            }
        }
        #expect(try db.database.sync { try $0.scalar("SELECT COUNT(*) FROM sonde_samples") } == total)
        Self.report("Sondenmeldungen einfügen: \(total) in \(Int(Self.ms(insert))) ms = \(Int(Double(total) / (Self.ms(insert) / 1000)))/s")

        var samples = 0
        let flight = clock.measure { samples = SondeArchive.load(serial: "V0000100", database: db.database)?.samples.count ?? 0 }
        Self.report("Ein Flug (\(samples) Meldungen): \(String(format: "%.1f", Self.ms(flight))) ms")
        #expect(samples == perFlight)

        let now = Date(timeIntervalSince1970: base + 199 * 43_200 + 6000)
        var current = 0
        let live = clock.measure {
            current = SondeArchive.loadCurrent(serial: "V0000199", database: db.database, now: now)?.samples.count ?? 0
        }
        Self.report("Laufender Flug (\(current) Meldungen): \(String(format: "%.1f", Self.ms(live))) ms")

        var recent = 0
        let latest = clock.measure { recent = SondeArchive.recent(limit: 20, database: db.database).count }
        Self.report("Jüngste 20 Flüge: \(Int(Self.ms(latest))) ms")
        #expect(recent == 20)

        var flights = 0
        let all = clock.measure { flights = SondeArchive.load(database: db.database).count }
        Self.report("Sondenarchiv komplett (\(flights) Flüge): \(Int(Self.ms(all))) ms")
        Self.report("Dateigröße 1 Mio. Sondenmeldungen: \(db.database.fileSize() / 1_048_576) MB")
        #expect(flights == total / perFlight)
    }

    @Test("Volltextsuche über 100 000 Flugfunk-Abschriften")
    func fullText() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let clock = ContinuousClock()
        let words = ["descend", "climb", "flight", "level", "contact", "radar", "tower", "runway", "cleared", "land",
                     "takeoff", "wind", "knots", "heading", "squawk", "approach", "Bremen", "Hamburg", "Langen", "Piste",
                     "Landung", "frei", "zwo", "drei", "fünf", "Rollhalt", "Vorfeld", "Lufthansa", "Condor", "Eurowings"]
        let total = 100_000
        var generator = SystemRandomNumberGenerator()
        let items = (0..<total).map { n -> AirbandTransmission in
            var t = AirbandTransmission(start: Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 30), duration: 4,
                                        index: n % 2000, name: "", peakDB: 12)
            t.transcript = (0..<12).map { _ in words[Int.random(in: 0..<words.count, using: &generator)] }.joined(separator: " ")
                + " \(n)"
            t.transcriptLanguage = "de"
            return t
        }
        let insert = clock.measure {
            for chunk in stride(from: 0, to: total, by: 5000) {
                let part = Array(items[chunk..<(chunk + 5000)])
                try? db.database.sync { try $0.insertTransmissions(part) }
            }
        }
        Self.report("Abschriften einfügen (mit FTS): \(total) in \(Int(Self.ms(insert))) ms = \(Int(Double(total) / (Self.ms(insert) / 1000)))/s")
        var hits = 0
        let word = clock.measure { hits = (try? db.database.sync { try $0.searchTransmissions("rollhalt", limit: 200) })?.count ?? 0 }
        Self.report("Volltext ein Wort (200 von vielen Treffern): \(String(format: "%.1f", Self.ms(word))) ms")
        #expect(hits == 200)
        let rare = clock.measure { hits = (try? db.database.sync { try $0.searchTransmissions("\"99999\"", limit: 200) })?.count ?? 0 }
        Self.report("Volltext seltener Begriff (\(hits) Treffer): \(String(format: "%.1f", Self.ms(rare))) ms")
        #expect(hits == 1)
        let phrase = clock.measure { hits = (try? db.database.sync { try $0.searchTransmissions("\"piste zwo\" AND bremen", limit: 200) })?.count ?? 0 }
        Self.report("Volltext Phrase + Wort (\(hits) Treffer): \(String(format: "%.1f", Self.ms(phrase))) ms")
        Self.report("Dateigröße 100 000 Abschriften: \(db.database.fileSize() / 1_048_576) MB")
        #expect(Self.ms(word) < 500)
    }
}

/// Übernahme an einer **Kopie** echter Archivdateien prüfen (nie am Original –
/// die Übernahme verschiebt die Dateien):
/// `TEST_RUNNER_ARCHIVE_COPY=<ordner> xcodebuild test … -only-testing:PortaPackManagerTests/ArchiveMigrationCopyTests`
private let archiveCopyFolder = ProcessInfo.processInfo.environment["ARCHIVE_COPY"].map { URL(fileURLWithPath: $0) }

@Suite("Übernahme an einer Archivkopie", .enabled(if: archiveCopyFolder != nil))
struct ArchiveMigrationCopyTests {
    @Test("Kopie der echten Ablage übernehmen")
    func migrateCopy() throws {
        let root = try #require(archiveCopyFolder)
        let db = TestDatabase()
        defer { db.remove() }
        let files = ArchiveMigration.legacyFiles(in: root)
        let outcome = ArchiveMigration.run(root: root, database: db.database)
        print("BENCH Übernahme Kopie: \(files.count) Dateien, \(outcome.entries) Einträge, \(outcome.moved) verschoben, Fehler: \(outcome.failures)")
        #expect(outcome.failures.isEmpty)
        let counts = try db.database.sync { conn in
            (try conn.sightingSummary(kind: .adsb), try conn.sightingSummary(kind: .ais), try conn.sondeSummary(), try conn.airbandSummary())
        }
        print("BENCH Kopie in der DB: ADS-B \(counts.0.entries)/\(counts.0.distinct), AIS \(counts.1.entries)/\(counts.1.distinct), Sonden \(counts.2.entries) Flüge/\(counts.2.distinct) Meldungen, Flugfunk \(counts.3.entries), \(db.database.fileSize() / 1024) KB")
    }
}
