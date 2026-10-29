import Foundation
import OSLog

/// Inhalt der Datenablage (Application Support) je Bereich: Einträge in der
/// Archiv-Datenbank bzw. Dateien und Größe der übrigen Ordner. Für den Reiter
/// „Archiv“ der Einstellungen; rechnet abseits des Main Actor.
struct ArchiveStat: Identifiable, Sendable, Equatable {
    var id: String          // Bereich (`ArchiveBackup.Area`) bzw. Ordnername relativ zur Ablage
    var files = 0
    var bytes: Int64 = 0
    var entries: Int?       // Sichtungen, Flüge bzw. Übertragungen
    var distinct: Int?      // verschiedene Flugzeuge/Schiffe, Meldungen (Sonden) bzw. Kanäle (Flugfunk)
    var oldest: Date?
    /// Liegt in der Archiv-Datenbank (keine eigenen Dateien).
    var inDatabase = false
}

enum ArchiveBackup {
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Archiv")

    /// Ordner mit IQ-Aufnahmen – groß, deshalb in Sicherungen nur auf Wunsch.
    static let recordingsFolder = "Aufnahmen"

    /// Bereiche in der Datenbank.
    enum Area {
        static let adsb = "db:adsb"
        static let ais = "db:ais"
        static let sondes = "db:sonden"
        static let database = ArchiveDatabase.fileName
    }

    /// Feste Reihenfolge der bekannten Ordner; alles Weitere landet in „Sonstiges“.
    /// `Archiv` und `Radiosonden` gibt es nur noch, solange die Übernahme alter
    /// Dateien aussteht.
    static let knownFolders = ["Flugfunk", "Aufnahmen", "Belegung", "SSTV", "Wettersatellit",
                               ArchiveMigration.oldFolderName, "Archiv", "Radiosonden"]
    static let otherID = "*"

    // MARK: Übersicht

    static func stats(root: URL, database: ArchiveDatabase = .shared) -> [ArchiveStat] {
        var result: [ArchiveStat] = []
        let summaries = try? database.sync { db in
            (try db.sightingSummary(kind: .adsb), try db.sightingSummary(kind: .ais), try db.sondeSummary(), try db.airbandSummary())
        }
        func stat(_ id: String, _ summary: SQLiteConnection.Summary?) -> ArchiveStat {
            ArchiveStat(id: id, entries: summary?.entries ?? 0, distinct: summary?.distinct ?? 0, oldest: summary?.oldest, inDatabase: true)
        }
        result.append(stat(Area.adsb, summaries?.0))
        result.append(stat(Area.ais, summaries?.1))
        result.append(stat(Area.sondes, summaries?.2))
        var counted = Set<String>()
        for folder in knownFolders {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            var stat = ArchiveStat(id: folder)
            (stat.files, stat.bytes) = size(of: url)
            counted.insert(url.standardizedFileURL.path)
            if folder == "Flugfunk" {
                stat.entries = summaries?.3.entries ?? 0
                stat.distinct = summaries?.3.distinct ?? 0
                stat.oldest = summaries?.3.oldest
            }
            result.append(stat)
        }
        // Die Datenbankdatei selbst (samt WAL).
        var db = ArchiveStat(id: Area.database)
        for suffix in ["", "-wal", "-shm"] {
            let url = root.appendingPathComponent(ArchiveDatabase.fileName + suffix)
            counted.insert(url.standardizedFileURL.path)
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                if suffix.isEmpty { db.files += 1 }
                db.bytes += Int64(size)
            }
        }
        result.append(db)
        // Rest der Ablage (Frequenzspeicher, Einstellungsdateien …) ohne die
        // bekannten Ordner und ihre Elternordner.
        var other = ArchiveStat(id: otherID)
        let fm = FileManager.default
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in walker {
                if counted.contains(url.standardizedFileURL.path) { walker.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                other.files += 1
                other.bytes += Int64(values?.fileSize ?? 0)
            }
        }
        result.append(other)
        return result
    }

    /// Dateien und Bytes unterhalb eines Ordners.
    static func size(of folder: URL) -> (files: Int, bytes: Int64) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
        }
        return (files, bytes)
    }

    static func dayDate(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: Sicherung

    enum BackupError: Error, LocalizedError {
        case tool(String)
        case unsafe(String)
        case notABackup

        var errorDescription: String? {
            switch self {
            case .tool(let detail): String(localized: "Sicherung fehlgeschlagen: \(detail)")
            case .unsafe(let name): String(localized: "Die Sicherung enthält einen unzulässigen Pfad (\(name)).")
            case .notABackup: String(localized: "Diese Datei ist keine Sicherung des PortaPack Managers.")
            }
        }
    }

    /// Kennzeichnet eine Sicherung; liegt im obersten Ordner des ZIP.
    static let markerName = "PortaPack-Sicherung.txt"

    /// Was nicht als Datei in die Sicherung kommt: die Datenbank (kommt als
    /// konsistente Kopie), ihre Nebendateien, beschädigte Altfassungen und die schon
    /// übernommenen Archivdateien.
    static func isExcludedFromBackup(_ name: String) -> Bool {
        name.hasPrefix(".") || name == ArchiveMigration.oldFolderName
            || name.hasPrefix(ArchiveDatabase.fileName) || name.hasPrefix("Archiv-beschädigt-")
    }

    /// Schreibt die Ablage als ZIP nach `destination`; IQ-Aufnahmen nur mit
    /// `includeRecordings`. Die Datenbank kommt als konsistente Kopie
    /// (`VACUUM INTO`) hinein, auch während Empfänger schreiben.
    static func createBackup(root: URL, database: ArchiveDatabase = .shared, destination: URL,
                             includeRecordings: Bool, now: Date = Date()) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let top = staging.appendingPathComponent("PortaPack-Sicherung", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            if name == recordingsFolder && !includeRecordings { continue }
            if isExcludedFromBackup(name) { continue }
            try fm.copyItem(at: root.appendingPathComponent(name), to: top.appendingPathComponent(name))
        }
        try database.copy(to: top.appendingPathComponent(ArchiveDatabase.fileName))
        let marker = "PortaPack Manager – Sicherung vom \(ISOTime.string(now))\n"
        try Data(marker.utf8).write(to: top.appendingPathComponent(markerName))
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try ditto(["-c", "-k", "--keepParent", top.path, destination.path])
    }

    struct RestoreResult: Equatable, Sendable {
        var restored = 0
        var skipped = 0
        /// Einträge, die neu ins Archiv kamen (aus der Datenbank der Sicherung oder
        /// aus alten Archivdateien).
        var imported = 0
    }

    /// Spielt eine Sicherung ein: übernimmt jede Datei, die es in der Ablage
    /// noch nicht gibt, und fügt fehlende Archiveinträge hinzu; Vorhandenes bleibt
    /// unverändert (nichts wird überschrieben). Alte Sicherungen mit Tagesdateien
    /// werden wie bei der Übernahme in die Datenbank eingelesen.
    static func restore(from zip: URL, root: URL, database: ArchiveDatabase = .shared) throws -> RestoreResult {
        let listing = try ZipDirectory.read(zip)
        if let bad = listing.entries.first(where: { !$0.isSafe }) { throw BackupError.unsafe(bad.name) }
        guard listing.entries.contains(where: { $0.name.hasSuffix("/" + markerName) || $0.name == markerName }) else {
            throw BackupError.notABackup
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try ditto(["-x", "-k", zip.path, staging.path])
        // Oberster Ordner ist der mit der Kennzeichnung.
        guard let markerURL = findMarker(in: staging) else { throw BackupError.notABackup }
        let top = markerURL.deletingLastPathComponent()
        var result = try merge(from: top, into: root)
        let backupDB = top.appendingPathComponent(ArchiveDatabase.fileName)
        if fm.fileExists(atPath: backupDB.path) {
            result.imported += try database.merge(from: backupDB)
        }
        let legacy = ArchiveMigration.importAll(from: top, into: database).outcome
        result.imported += legacy.added
        if let failure = legacy.failures.first { throw BackupError.tool(failure) }
        return result
    }

    static func findMarker(in folder: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == markerName { return url }
        return nil
    }

    /// Archivdateien von vor der Datenbank und die Datenbank selbst – sie kommen
    /// über `ArchiveMigration` bzw. `ArchiveDatabase.merge` ins Archiv, nicht als
    /// Datei in die Ablage.
    static func isLegacyArchive(_ relative: String) -> Bool {
        relative.hasPrefix("Archiv/") || relative.hasPrefix("Radiosonden/") || relative == "Flugfunk/Verlauf.json"
            || relative.hasPrefix(ArchiveMigration.oldFolderName + "/")
            || relative.hasPrefix(ArchiveDatabase.fileName)
    }

    /// Kopiert alle Dateien aus `source` nach `root`, die dort fehlen (ohne
    /// Archivdateien und Datenbank, siehe `isLegacyArchive`).
    static func merge(from source: URL, into root: URL) throws -> RestoreResult {
        let fm = FileManager.default
        var result = RestoreResult()
        let base = source.standardizedFileURL.path
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return result }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, url.lastPathComponent != markerName else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if isLegacyArchive(relative) { continue }
            let target = root.appendingPathComponent(relative)
            if fm.fileExists(atPath: target.path) {
                result.skipped += 1
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target)
            result.restored += 1
        }
        return result
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.error("ditto: \(text, privacy: .public)")
            throw BackupError.tool(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
