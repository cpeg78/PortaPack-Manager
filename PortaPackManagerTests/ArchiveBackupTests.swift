import Foundation
import Testing
@testable import PortaPackManager

@Suite("Archiv-Übersicht und Sicherung")
struct ArchiveBackupTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ab-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sighting(_ id: String, key: String) -> ArchiveSighting {
        ArchiveSighting(id: id, key: key, first: Date(timeIntervalSince1970: 1_793_000_000), last: Date(timeIntervalSince1970: 1_793_000_600), messages: 3)
    }

    private func writeDay(_ day: String, _ entries: [ArchiveSighting], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: folder.appendingPathComponent(day + ".json"))
    }

    @Test("Übersicht zählt Sichtungen und verschiedene Flugzeuge per SQL, Dateien der übrigen Ordner")
    func stats() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let root = db.folder
        try db.database.sync { conn in
            try conn.insertMissingSightings([sighting("a1", key: "3c6444"), sighting("a2", key: "3c6444")], kind: .adsb, day: "2026-10-27")
            try conn.insertMissingSightings([sighting("b1", key: "4ca7b5")], kind: .adsb, day: "2026-10-28")
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("Frequenzen.json"))
        let stats = ArchiveBackup.stats(root: root, database: db.database)
        let plane = try #require(stats.first { $0.id == ArchiveBackup.Area.adsb })
        #expect(plane.entries == 3)
        #expect(plane.distinct == 2)
        #expect(plane.inDatabase)
        #expect(plane.oldest == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(stats.first { $0.id == ArchiveBackup.Area.ais }?.entries == 0)
        let file = try #require(stats.first { $0.id == ArchiveBackup.Area.database })
        #expect(file.bytes > 0)
        let other = try #require(stats.first { $0.id == ArchiveBackup.otherID })
        #expect(other.files == 1)
        #expect(other.bytes == 1)
    }

    @Test("Sicherung mit Datenbank und Einspielen: fehlende Dateien und Einträge kommen dazu, vorhandene bleiben")
    func roundTrip() throws {
        let source = TestDatabase(), target = TestDatabase()
        let out = try tempRoot()
        defer { source.remove(); target.remove(); try? FileManager.default.removeItem(at: out) }
        let root = source.folder
        try source.database.sync { try $0.insertMissingSightings([sighting("a1", key: "3c6444"), sighting("a2", key: "3c6444")], kind: .adsb, day: "2026-10-27") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Aufnahmen"), withIntermediateDirectories: true)
        try Data("iq".utf8).write(to: root.appendingPathComponent("Aufnahmen/a.iq"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("SSTV"), withIntermediateDirectories: true)
        try Data("neu".utf8).write(to: root.appendingPathComponent("SSTV/x.png"))

        let zip = out.appendingPathComponent("s.zip")
        try ArchiveBackup.createBackup(root: root, database: source.database, destination: zip, includeRecordings: false)
        let names = try ZipDirectory.read(zip).entries.map(\.name)
        #expect(names.contains { $0.hasSuffix("/" + ArchiveDatabase.fileName) })
        #expect(!names.contains { $0.hasSuffix("-wal") })

        // Im Ziel liegt dieselbe Bilddatei und eine der Sichtungen (verändert) schon – beides bleibt.
        try FileManager.default.createDirectory(at: target.folder.appendingPathComponent("SSTV"), withIntermediateDirectories: true)
        try Data("alt".utf8).write(to: target.folder.appendingPathComponent("SSTV/x.png"))
        var changed = sighting("a1", key: "3c6444")
        changed.messages = 99
        try target.database.sync { try $0.insertMissingSightings([changed], kind: .adsb, day: "2026-10-27") }
        let result = try ArchiveBackup.restore(from: zip, root: target.folder, database: target.database)
        #expect(result.restored == 0)
        #expect(result.skipped == 1)
        #expect(result.imported == 1)
        #expect(!FileManager.default.fileExists(atPath: target.folder.appendingPathComponent("Aufnahmen/a.iq").path))
        #expect(try String(contentsOf: target.folder.appendingPathComponent("SSTV/x.png"), encoding: .utf8) == "alt")
        let all = try target.database.sync { try $0.sightings(kind: .adsb, days: nil) }
        #expect(all.count == 2)
        #expect(all.first { $0.id == "a1" }?.messages == 99)
        // Zweites Einspielen ändert nichts.
        #expect(try ArchiveBackup.restore(from: zip, root: target.folder, database: target.database).imported == 0)
    }

    @Test("Alte Sicherung mit Tagesdateien wird in die Datenbank eingelesen, nicht als Datei kopiert")
    func legacyBackup() throws {
        let target = TestDatabase()
        let staging = try tempRoot(), out = try tempRoot()
        defer { target.remove(); try? FileManager.default.removeItem(at: staging); try? FileManager.default.removeItem(at: out) }
        let top = staging.appendingPathComponent("PortaPack-Sicherung")
        try writeDay("2026-10-27", [sighting("a1", key: "3c6444")], in: top.appendingPathComponent("Archiv/ADS-B"))
        let ais = top.appendingPathComponent("Archiv/AIS")
        try FileManager.default.createDirectory(at: ais, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try TestDatabase.lzma(try encoder.encode([sighting("s1", key: "211000000")])).write(to: ais.appendingPathComponent("2026-10-01.json.lzma"))
        try FileManager.default.createDirectory(at: top.appendingPathComponent("Radiosonden"), withIntermediateDirectories: true)
        try Data((SondeLog.header + "2026-10-28T10:47:02Z;RS41;V3051090;1060;404.900;53.6;10.1;753;3.7;7.2;89;;;2.9\n").utf8)
            .write(to: top.appendingPathComponent("Radiosonden/2026-10-28_1145.csv"))
        try Data("PortaPack Manager – Sicherung\n".utf8).write(to: top.appendingPathComponent(ArchiveBackup.markerName))
        let zip = out.appendingPathComponent("alt.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", top.path, zip.path]
        try process.run(); process.waitUntilExit()

        let result = try ArchiveBackup.restore(from: zip, root: target.folder, database: target.database)
        #expect(result.imported == 3)
        #expect(result.restored == 0)
        #expect(!FileManager.default.fileExists(atPath: target.folder.appendingPathComponent("Archiv").path))
        #expect(try target.database.sync { try $0.sightings(kind: .ais, days: ["2026-10-01"]) }.count == 1)
        #expect(try target.database.sync { try $0.sondeRows() }.count == 1)
    }

    @Test("Eine beliebige ZIP-Datei ist keine Sicherung")
    func foreignZip() throws {
        let root = try tempRoot(), out = try tempRoot()
        let db = TestDatabase()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out); db.remove() }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        let zip = out.appendingPathComponent("f.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", root.path, zip.path]
        try process.run(); process.waitUntilExit()
        #expect(throws: ArchiveBackup.BackupError.self) { try ArchiveBackup.restore(from: zip, root: out, database: db.database) }
    }
}
