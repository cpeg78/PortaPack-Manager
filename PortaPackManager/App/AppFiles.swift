import Foundation
import OSLog

/// Ablageorte der App und Pflege der Archive (Fund 28.10.2026: Archive lagen
/// ungepackt, abrufbare Daten wie die 29-MB-Flugzeugdatenbank lagen neben ihnen
/// und gingen in jedes Time-Machine-Backup).
///
/// - **Application Support**: was sich nicht wiederbeschaffen lässt (Archive,
///   Sondenprotokolle, Bilder, Mitschnitte, Messreihen).
/// - **Caches**: was die App jederzeit neu lädt (Flugzeugdatenbank, Strecken,
///   Funkfeuer, Bahndaten). Time Machine sichert Caches nicht; macOS darf sie leeren.
enum AppFiles {
    static let bundleFolder = "de.christiangolz.portapackmanager"

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var caches: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Alles Abrufbare, das früher in Application Support lag.
    static let cacheNames = ["Flugzeugdatenbank.tsv", "Flugzeugdatenbank-online.json", "Flugstrecken.json",
                             "navaids.csv", "Bahndaten.tle", "Amateursatelliten.tle"]

    /// Beim Start: alte Ablage aufräumen, auch für Seiten, die nie geöffnet werden.
    static func migrateCaches() {
        for name in cacheNames { _ = cacheFile(name) }
    }

    /// Datei im Cache-Ordner. Liegt sie noch am alten Ort (Application Support),
    /// wird sie beim ersten Zugriff verschoben.
    static func cacheFile(_ name: String) -> URL {
        let target = caches.appendingPathComponent(name)
        let old = support.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path) {
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: old) }
            else { try? fm.moveItem(at: old, to: target) }
        }
        return target
    }
}

/// Gepackte Archivdateien von vor der Datenbank: `<name>` wurde zu `<name>.lzma`.
/// Gelesen werden sie nur noch bei der Übernahme (`ArchiveMigration`) und beim
/// Einspielen alter Sicherungen.
enum PackedFile {
    static let suffix = ".lzma"

    static func packedURL(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix) }

    /// Name ohne `.lzma`.
    static func plainName(_ name: String) -> String { name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name }

    /// Inhalt einer Datei, die selbst gepackt sein kann (Endung `.lzma`).
    static func readAny(_ url: URL) -> Data? {
        guard url.lastPathComponent.hasSuffix(suffix) else { return try? Data(contentsOf: url) }
        guard let packed = try? Data(contentsOf: url) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzma) as Data
    }
}

/// Pflege des Archivs (Datenbank): beim Start zuerst die Übernahme alter
/// Archivdateien, dann – und alle sechs Stunden – die Aufbewahrungsfrist: Einträge
/// älter als die Frist löschen und den Platz per `incremental_vacuum` freigeben.
/// Packen wie bei den Tagesdateien entfällt; die Datenbank ist kompakt genug.
enum ArchiveMaintenance {
    /// Aufbewahrung in Tagen; 0 = unbegrenzt (Vorgabe).
    static let retentionKey = "archiveRetentionDays"
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Archiv")

    struct Result: Equatable, Sendable {
        var deleted = 0
    }

    /// Zahl der Einträge, die eine Frist von `retentionDays` löschen würde – für
    /// die Rückfrage vor dem Verkürzen.
    static func expiringCount(database: ArchiveDatabase = .shared, retentionDays: Int, now: Date = Date()) -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return (try? database.sync { try $0.countExpiring(before: cutoff) }) ?? 0
    }

    /// Löscht Einträge älter als `retentionDays` (0 = nie) samt der Mitschnitte
    /// gelöschter Flugfunk-Einträge in `recordings`.
    static func run(database: ArchiveDatabase = .shared, recordings: URL? = nil, retentionDays: Int,
                    now: Date = Date()) -> Result {
        guard retentionDays > 0 else { return Result() }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        do {
            let deleted = try database.sync { db -> Int in
                if let recordings {
                    for name in try db.transmissionRecordings(before: cutoff) {
                        try? FileManager.default.removeItem(at: recordings.appendingPathComponent(name))
                    }
                }
                return try db.deleteExpiring(before: cutoff)
            }
            if deleted > 0 { database.vacuumIncrementally() }
            return Result(deleted: deleted)
        } catch {
            log.error("Aufbewahrung: \(String(describing: error), privacy: .public)")
            return Result()
        }
    }

    @MainActor private static var task: Task<Void, Never>?

    @MainActor
    static func start() {
        guard task == nil else { return }
        task = Task {
            await ArchiveMigrationState.shared.start(root: AppFiles.support, database: .shared)
            while !Task.isCancelled {
                await Task.detached(priority: .background) { runLogged() }.value
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Sofort einmal pflegen (nach Änderung der Aufbewahrung).
    static func runNow() {
        Task.detached(priority: .utility) { runLogged() }
    }

    private static func runLogged() {
        let days = UserDefaults.standard.integer(forKey: retentionKey)
        let result = run(recordings: AirbandLog.standard.recordingsFolder, retentionDays: days)
        if result.deleted > 0 { log.notice("Archiv gepflegt: \(result.deleted) Einträge gelöscht") }
    }
}
