import Foundation
import Testing
@testable import PortaPackManager

@Suite("Archivpflege und Übernahme in die Datenbank")
struct ArchiveMaintenanceTests {
    private static let sondeLines = [
        "2026-10-28T10:47:02Z;RS41;V3051090;1060;404.900;53.6;10.1;753;3.7;7.2;89;;;2.9",
        "2026-10-28T10:47:03Z;RS41;V3051090;1061;404.900;53.6;10.1;757;3.7;7.2;89;;;2.9",
        "2026-10-28T10:47:04Z;RS41;X1111111;7;402.500;53.7;10.2;900;3.7;7.2;89;;;2.9",
        "2026-10-28T10:47:04Z;RS41;X1111111;7;402.500;53.7;10.2;900;3.7;7.2;89;;;2.9",   // doppelt
    ]

    private func sighting(_ id: String, key: String, last: TimeInterval = 1_793_000_600) -> ArchiveSighting {
        ArchiveSighting(id: id, key: key, name: "TEST", first: Date(timeIntervalSince1970: last - 600),
                        last: Date(timeIntervalSince1970: last), messages: 3, maxAltitudeM: 11_000,
                        track: [[53.5, 10.0], [53.6, 10.1, 9000]])
    }

    private func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// Alte Ablage wie vor der Datenbank: ein ungepackter und ein gepackter ADS-B-Tag,
    /// ein AIS-Tag, ein gepacktes Sondenprotokoll, ein Flugfunk-Verlauf.
    private func writeLegacy(in root: URL) throws {
        let fm = FileManager.default
        for folder in ["Archiv/ADS-B", "Archiv/AIS", "Radiosonden", "Flugfunk/Mitschnitte"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try json([sighting("A-1", key: "A"), sighting("B-1", key: "B")]).write(to: root.appendingPathComponent("Archiv/ADS-B/2026-10-28.json"))
        try TestDatabase.lzma(try json([sighting("A-0", key: "A", last: 1_792_900_000)]))
            .write(to: root.appendingPathComponent("Archiv/ADS-B/2026-10-27.json.lzma"))
        try json([sighting("211-1", key: "211000000")]).write(to: root.appendingPathComponent("Archiv/AIS/2026-10-28.json"))
        try TestDatabase.lzma(Data((SondeLog.header + Self.sondeLines.joined(separator: "\n") + "\n").utf8))
            .write(to: root.appendingPathComponent("Radiosonden/2026-10-28_1145.csv.lzma"))
        try json([AirbandTransmission(start: Date(timeIntervalSince1970: 1_793_000_000), duration: 2, index: 420, name: "Turm", peakDB: 12)])
            .write(to: root.appendingPathComponent("Flugfunk/Verlauf.json"))
    }

    @Test("Übernahme: alles eingelesen und geprüft, dann verschoben – nichts gelöscht")
    func migration() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let root = db.folder
        try writeLegacy(in: root)
        var steps: [ArchiveMigration.Progress] = []
        let outcome = ArchiveMigration.run(root: root, database: db.database) { steps.append($0) }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.files == 5)
        #expect(outcome.moved == 5)
        #expect(outcome.entries == 3 + 1 + 3 + 1)   // Sonde: doppelte Zeile zählt einmal
        #expect(steps.last == .init(done: 5, total: 5))
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Archiv").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Radiosonden").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Flugfunk/Mitschnitte").path))
        let old = root.appendingPathComponent(ArchiveMigration.oldFolderName)
        #expect(fm.fileExists(atPath: old.appendingPathComponent("Archiv/ADS-B/2026-10-27.json.lzma").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("Flugfunk/Verlauf.json").path))
        #expect(ArchiveMigration.oldFiles(root: root).files == 5)

        let adsb = try db.database.sync { try $0.sightings(kind: .adsb, days: nil) }
        #expect(Set(adsb.map(\.id)) == ["A-0", "A-1", "B-1"])
        #expect(adsb.first { $0.id == "A-1" }?.track == [[53.5, 10.0], [53.6, 10.1, 9000]])
        #expect(try db.database.sync { try $0.sightingDays(kind: .adsb) } == ["2026-10-28", "2026-10-27"])
        #expect(SondeArchive.load(database: db.database).map(\.serial).sorted() == ["V3051090"])   // X1111111 hat nur eine Meldung
        #expect(SondeArchive.windowCount(database: db.database) == 1)
        #expect(AirbandLog(folder: root.appendingPathComponent("Flugfunk"), database: db.database).load().map(\.name) == ["Turm"])

        // Zweiter Lauf: nichts mehr zu tun.
        #expect(ArchiveMigration.run(root: root, database: db.database).files == 0)
        try ArchiveMigration.deleteOldFiles(root: root)
        #expect(!fm.fileExists(atPath: old.path))
    }

    @Test("Übernahme mit einer kaputten Datei: nichts wird verschoben, ein späterer Lauf setzt fort")
    func migrationFailure() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let root = db.folder
        try writeLegacy(in: root)
        let broken = root.appendingPathComponent("Archiv/AIS/2026-10-29.json")
        try Data("{kaputt".utf8).write(to: broken)
        let first = ArchiveMigration.run(root: root, database: db.database)
        #expect(first.failures.count == 1)
        #expect(first.moved == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archiv/ADS-B/2026-10-28.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ArchiveMigration.oldFolderName).path))
        // Was lesbar war, steht schon in der Datenbank – der nächste Lauf fügt nichts doppelt ein.
        #expect(try db.database.sync { try $0.sightings(kind: .adsb, days: nil) }.count == 3)
        try FileManager.default.removeItem(at: broken)
        let second = ArchiveMigration.run(root: root, database: db.database)
        #expect(second.failures.isEmpty)
        #expect(second.added == 0)
        #expect(second.moved == 5)
        #expect(try db.database.sync { try $0.sightings(kind: .adsb, days: nil) }.count == 3)
    }

    @Test("Aufbewahrung löscht alte Einträge aller Bereiche samt Mitschnitten, unbegrenzt löscht nichts")
    func retention() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let now = Date()
        let recordings = db.folder.appendingPathComponent("Mitschnitte")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: recordings.appendingPathComponent("alt.m4a"))
        var oldCall = AirbandTransmission(start: now.addingTimeInterval(-400 * 86_400), duration: 1, index: 1, name: "", peakDB: 1)
        oldCall.recording = "alt.m4a"
        let newCall = AirbandTransmission(start: now, duration: 1, index: 1, name: "", peakDB: 1)
        try db.database.sync { conn in
            try conn.insertMissingSightings([sighting("alt", key: "A", last: now.addingTimeInterval(-400 * 86_400).timeIntervalSince1970),
                                             sighting("neu", key: "A", last: now.timeIntervalSince1970)], kind: .adsb, day: "x")
            try conn.insertSondeRows(SondeArchive.parse(SondeLog.header + "2025-01-01T10:47:02Z;RS41;V1;1;404.900;53.6;10.1;753;3.7;7.2;89;;;2.9\n"), window: "w")
            try conn.insertTransmissions([oldCall, newCall])
        }
        #expect(ArchiveMaintenance.run(database: db.database, retentionDays: 0, now: now).deleted == 0)
        let expiring = ArchiveMaintenance.expiringCount(database: db.database, retentionDays: 365, now: now)
        #expect(expiring == 3)
        let result = ArchiveMaintenance.run(database: db.database, recordings: recordings, retentionDays: 365, now: now)
        #expect(result.deleted == 3)
        #expect(try db.database.sync { try $0.sightings(kind: .adsb, days: nil) }.map(\.id) == ["neu"])
        #expect(try db.database.sync { try $0.recentTransmissions(limit: 10) }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: recordings.appendingPathComponent("alt.m4a").path))
    }

    @Test("Sondenarchiv: Flug löschen, andere Sonden bleiben")
    func sondeDelete() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let extra = "2026-10-28T10:47:05Z;RS41;X1111111;8;402.500;53.7;10.2;905;3.7;7.2;89;;;2.9"
        try db.database.sync { try $0.insertSondeRows(SondeArchive.parse(SondeLog.header + (Self.sondeLines + [extra]).joined(separator: "\n")), window: "w") }
        #expect(SondeArchive.delete(serial: "V3051090", database: db.database) == 2)
        let flights = SondeArchive.load(database: db.database)
        #expect(flights.map(\.serial) == ["X1111111"])
        #expect(flights.first?.samples.count == 2)
        #expect(SondeArchive.recent(limit: 5, database: db.database).map(\.serial) == ["X1111111"])
    }
}
