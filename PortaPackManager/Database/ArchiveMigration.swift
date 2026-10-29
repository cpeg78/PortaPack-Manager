import Foundation
import Observation

/// Liest die Archivdateien von vor der Datenbank: Tagesdateien der Sichtungen
/// (JSON, auch gepackt `.lzma`), Sondenprotokolle (CSV) und den Flugfunk-Verlauf
/// (JSON). Wirft bei unlesbaren Dateien – die Übernahme darf nichts stillschweigend
/// verlieren.
enum LegacyArchive {
    enum ReadError: Error, LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "„\(name)“ ist nicht lesbar.")
            }
        }
    }

    static func data(_ url: URL) throws -> Data {
        guard let data = PackedFile.readAny(url) else { throw ReadError.unreadable(url.lastPathComponent) }
        return data
    }

    static func sightings(_ url: URL) throws -> [ArchiveSighting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let entries = try decoder.decode([ArchiveSighting].self, from: try data(url))
            // Wie früher beim Laden: eine ID nur einmal (die letzte gewinnt).
            var seen = Set<String>()
            return entries.reversed().filter { seen.insert($0.id).inserted }.reversed()
        } catch is DecodingError {
            throw ReadError.unreadable(url.lastPathComponent)
        }
    }

    static func sondeRows(_ url: URL) throws -> [SondeArchive.Row] {
        SondeArchive.parse(String(decoding: try data(url), as: UTF8.self))
    }

    static func transmissions(_ url: URL) throws -> [AirbandTransmission] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([AirbandTransmission].self, from: try data(url))
        } catch is DecodingError {
            throw ReadError.unreadable(url.lastPathComponent)
        }
    }
}

/// Übernahme der Archivdateien in die Datenbank (einmalig beim ersten Start nach
/// der Umstellung, außerdem beim Einspielen alter Sicherungen).
///
/// Ablauf: jede Datei lesen, in einer Transaktion einfügen (`INSERT OR IGNORE` über
/// natürliche Schlüssel) und prüfen, dass jeder gelesene Eintrag in der Datenbank
/// steht. Erst wenn das für **alle** Dateien stimmt, werden sie nach
/// `Archiv-vor-Datenbank/` verschoben – gelöscht wird nichts. Bei einem Fehler
/// bleibt alles liegen und der nächste Start versucht es erneut; weil Einfügen
/// idempotent ist, setzt ein abgebrochener Lauf sauber fort.
enum ArchiveMigration {
    static let oldFolderName = "Archiv-vor-Datenbank"

    enum Source: Sendable, Equatable {
        case sightings(ArchiveKind, day: String)
        case sonde(window: String)
        case airband
    }

    struct LegacyFile: Sendable, Equatable {
        var url: URL
        /// Pfad relativ zur Ablage, z. B. „Archiv/ADS-B/2026-10-26.json.lzma“.
        var relative: String
        var source: Source
    }

    struct Progress: Sendable, Equatable {
        var done: Int
        var total: Int
    }

    struct Outcome: Sendable, Equatable {
        var files = 0
        /// Gelesene Einträge.
        var entries = 0
        /// Davon neu in der Datenbank (der Rest stand schon darin).
        var added = 0
        var moved = 0
        var failures: [String] = []
    }

    enum MigrationError: Error, LocalizedError {
        case mismatch(file: String, read: Int, stored: Int)

        var errorDescription: String? {
            switch self {
            case .mismatch(let file, let read, let stored):
                String(localized: "„\(file)“: \(read) Einträge gelesen, aber nur \(stored) in der Datenbank.")
            }
        }
    }

    /// Alle Altdateien unter `root`.
    static func legacyFiles(in root: URL) -> [LegacyFile] {
        let fm = FileManager.default
        var result: [LegacyFile] = []
        func list(_ folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []).sorted()
        }
        for (kind, folder) in [(ArchiveKind.adsb, "Archiv/ADS-B"), (.ais, "Archiv/AIS")] {
            for name in list(folder) {
                let plain = PackedFile.plainName(name)
                guard plain.hasSuffix(".json") else { continue }
                result.append(LegacyFile(url: root.appendingPathComponent("\(folder)/\(name)"), relative: "\(folder)/\(name)",
                                         source: .sightings(kind, day: String(plain.dropLast(5)))))
            }
        }
        for name in list("Radiosonden") {
            let plain = PackedFile.plainName(name)
            guard plain.hasSuffix(".csv") else { continue }
            result.append(LegacyFile(url: root.appendingPathComponent("Radiosonden/\(name)"), relative: "Radiosonden/\(name)",
                                     source: .sonde(window: String(plain.dropLast(4)))))
        }
        let airband = root.appendingPathComponent("Flugfunk/Verlauf.json")
        if fm.fileExists(atPath: airband.path) {
            result.append(LegacyFile(url: airband, relative: "Flugfunk/Verlauf.json", source: .airband))
        }
        return result
    }

    /// Liest eine Datei, fügt fehlende Einträge ein und prüft gelesen == vorhanden.
    /// Liefert gelesene und neu eingefügte Einträge.
    @discardableResult
    static func importFile(_ file: LegacyFile, into database: ArchiveDatabase) throws -> (read: Int, added: Int) {
        switch file.source {
        case .sightings(let kind, let day):
            let entries = try LegacyArchive.sightings(file.url)
            let (added, stored) = try database.sync { db in
                try db.transaction {
                    (try db.insertMissingSightings(entries, kind: kind, day: day),
                     try db.countSightings(ids: entries.map(\.id), kind: kind))
                }
            }
            guard stored == entries.count else {
                throw MigrationError.mismatch(file: file.relative, read: entries.count, stored: stored)
            }
            return (entries.count, added)
        case .sonde(let window):
            let rows = try LegacyArchive.sondeRows(file.url)
            // Gleiche Sonde, gleiche Sekunde zählt einmal (wie beim Lesen der CSV).
            var keys: [(serial: String, time: Int)] = []
            var seen = Set<String>()
            for row in rows {
                let time = Int(row.sample.date.timeIntervalSince1970.rounded(.down))
                if seen.insert("\(row.serial)|\(time)").inserted { keys.append((row.serial, time)) }
            }
            let (added, stored) = try database.sync { db in
                try db.transaction {
                    (try db.insertSondeRows(rows, window: window), try db.countSondeRows(keys))
                }
            }
            guard stored == keys.count else {
                throw MigrationError.mismatch(file: file.relative, read: keys.count, stored: stored)
            }
            return (keys.count, added)
        case .airband:
            var seen = Set<UUID>()
            let items = try LegacyArchive.transmissions(file.url).filter { seen.insert($0.id).inserted }
            let (added, stored) = try database.sync { db in
                try db.transaction {
                    (try db.insertTransmissions(items), try db.countTransmissions(ids: items.map(\.id)))
                }
            }
            guard stored == items.count else {
                throw MigrationError.mismatch(file: file.relative, read: items.count, stored: stored)
            }
            return (items.count, added)
        }
    }

    /// Übernimmt alle Altdateien aus `root` (ohne zu verschieben).
    static func importAll(from root: URL, into database: ArchiveDatabase,
                          progress: (Progress) -> Void = { _ in }) -> (outcome: Outcome, files: [LegacyFile]) {
        let files = legacyFiles(in: root)
        var outcome = Outcome(files: files.count)
        for (i, file) in files.enumerated() {
            do {
                let counts = try importFile(file, into: database)
                outcome.entries += counts.read
                outcome.added += counts.added
            } catch {
                ArchiveDatabase.log.error("Übernahme \(file.relative, privacy: .public): \(error.localizedDescription, privacy: .public)")
                outcome.failures.append(error.localizedDescription)
            }
            progress(Progress(done: i + 1, total: files.count))
        }
        return (outcome, files)
    }

    /// Übernahme beim Start: alles einlesen, prüfen, dann verschieben.
    static func run(root: URL, database: ArchiveDatabase, progress: (Progress) -> Void = { _ in }) -> Outcome {
        let result = importAll(from: root, into: database, progress: progress)
        var outcome = result.outcome
        let files = result.files
        guard outcome.failures.isEmpty, !files.isEmpty else { return outcome }
        let fm = FileManager.default
        let target = root.appendingPathComponent(oldFolderName, isDirectory: true)
        for file in files {
            var destination = target.appendingPathComponent(file.relative)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Liegt dort schon eine gleichnamige Datei (abgebrochener Lauf), nicht überschreiben.
                var n = 2
                while fm.fileExists(atPath: destination.path) {
                    destination = target.appendingPathComponent(file.relative + "-\(n)")
                    n += 1
                }
                try fm.moveItem(at: file.url, to: destination)
                outcome.moved += 1
            } catch {
                outcome.failures.append(error.localizedDescription)
            }
        }
        // Leere Ordner der alten Ablage wegräumen (Flugfunk bleibt: Mitschnitte).
        for folder in ["Archiv/ADS-B", "Archiv/AIS", "Archiv", "Radiosonden"] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            let rest = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
            if rest.isEmpty { try? fm.removeItem(at: url) }
        }
        ArchiveDatabase.log.notice("Archiv übernommen: \(outcome.files) Dateien, \(outcome.entries) Einträge, \(outcome.moved) verschoben")
        return outcome
    }

    /// Dateien und Bytes im Ordner der alten Dateien.
    static func oldFiles(root: URL) -> (files: Int, bytes: Int64) {
        ArchiveBackup.size(of: root.appendingPathComponent(oldFolderName, isDirectory: true))
    }

    static func deleteOldFiles(root: URL) throws {
        let url = root.appendingPathComponent(oldFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Stand der Übernahme für Einstellungen ▸ Archiv.
@MainActor @Observable
final class ArchiveMigrationState {
    static let shared = ArchiveMigrationState()

    private(set) var running = false
    private(set) var progress: ArchiveMigration.Progress?
    private(set) var outcome: ArchiveMigration.Outcome?

    /// Übernahme im Hintergrund; kehrt zurück, wenn sie fertig ist.
    func start(root: URL, database: ArchiveDatabase) async {
        guard !running else { return }
        guard !ArchiveMigration.legacyFiles(in: root).isEmpty else { return }
        running = true
        let result = await Task.detached(priority: .utility) {
            ArchiveMigration.run(root: root, database: database) { progress in
                Task { @MainActor in ArchiveMigrationState.shared.progress = progress }
            }
        }.value
        outcome = result
        running = false
        progress = nil
    }
}
