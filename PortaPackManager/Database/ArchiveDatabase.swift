import Foundation
import OSLog
import SQLite3

/// Das Archiv der App als eine SQLite-Datei (`Archiv.sqlite` unter Application
/// Support): Sichtungen (ADS-B, AIS), Sondenmeldungen, Flugfunk-Verlauf und –
/// vorbereitet – ACARS/VDL2-Meldungen. Seit 29.10.2026; vorher Tagesdateien
/// (JSON, gepackt `.lzma`) und Sonden-CSV, die `ArchiveMigration` übernimmt.
///
/// Eine Verbindung, eine serielle Warteschlange: Schreiben läuft gebündelt in
/// Transaktionen abseits des Main Actors (`write`), Lesen für die Oberfläche
/// asynchron (`read`). Was später geschrieben wurde, liest jeder spätere Aufruf –
/// die Warteschlange hält die Reihenfolge. WAL-Modus, Schema-Stand in
/// `PRAGMA user_version`. Fehler werden protokolliert, nie zum Absturz; eine
/// beschädigte Datei wird umbenannt und neu angelegt (`notice`).
final class ArchiveDatabase: @unchecked Sendable {
    static let fileName = "Archiv.sqlite"
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Datenbank")

    /// Die Datenbank der App. Im Testwirt eine Wegwerfdatei im Temp-Ordner – Tests
    /// berühren die echte Ablage nie, auch nicht über einen vergessenen Standardwert.
    static let shared: ArchiveDatabase = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("PortaPackManager-Test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return ArchiveDatabase(url: folder.appendingPathComponent(fileName))
        }
        return ArchiveDatabase(url: AppFiles.support.appendingPathComponent(fileName))
    }()

    let url: URL
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    /// Nur auf `queue` benutzen.
    private var connection: SQLiteConnection?
    private let noticeLock = NSLock()
    private var storedNotice: String?

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "de.christiangolz.portapackmanager.archiv-db", qos: .utility)
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Hinweis für Einstellungen ▸ Archiv (beschädigte Datei ersetzt, Platte voll).
    var notice: String? {
        get { noticeLock.withLock { storedNotice } }
        set { noticeLock.withLock { storedNotice = newValue } }
    }

    // MARK: Zugriff

    /// Synchron auf der Warteschlange – nur abseits des Main Actors oder für
    /// kleine, indizierte Abfragen. Wartet auf alle vorher angestoßenen Schreibläufe.
    func sync<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try perform(body) }
        return try queue.sync { try perform(body) }
    }

    /// Asynchron lesen (oder schreiben und auf das Ergebnis warten).
    func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.perform(body) })
            }
        }
    }

    /// Schreiben ohne Warten, als eine Transaktion. Fehler landen im Protokoll.
    func write(_ label: String = "Schreiben", _ body: @escaping @Sendable (SQLiteConnection) throws -> Void) {
        queue.async {
            do {
                try self.perform { db in try db.transaction { try body(db) } }
            } catch {
                Self.log.error("\(label, privacy: .public) fehlgeschlagen: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Wartet, bis alle angestoßenen Schreibläufe erledigt sind.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Öffnet bei Bedarf, führt aus und behandelt Fehler (beschädigt → neu anlegen,
    /// Platte voll → Hinweis). Läuft auf `queue`.
    private func perform<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let db = try open()
        do {
            return try body(db)
        } catch let error as SQLiteError {
            if error.isCorrupt {
                Self.log.fault("Archiv beschädigt: \(error.description, privacy: .public)")
                replaceCorrupt()
            } else if error.isFull {
                Self.log.error("Archiv: Platte voll – \(error.description, privacy: .public)")
                notice = String(localized: "Das Archiv konnte nicht schreiben: Der Speicher ist voll. Neue Sichtungen und Meldungen gehen verloren, bis wieder Platz ist.")
            }
            throw error
        }
    }

    private func open() throws -> SQLiteConnection {
        if let connection { return connection }
        do {
            let db = try Self.openAndPrepare(url)
            connection = db
            return db
        } catch let error as SQLiteError where error.isCorrupt {
            Self.log.fault("Archiv nicht lesbar: \(error.description, privacy: .public)")
            replaceCorrupt()
            let db = try Self.openAndPrepare(url)
            connection = db
            return db
        }
    }

    /// Benennt eine beschädigte Datei um (samt WAL) und legt beim nächsten Zugriff
    /// eine neue an. Gelöscht wird nichts – die alte Datei bleibt zur Rettung liegen.
    private func replaceCorrupt() {
        connection = nil
        let stamp = ISOTime.string(Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent().appendingPathComponent("\(base)-beschädigt-\(stamp).sqlite")
        let fm = FileManager.default
        try? fm.moveItem(at: url, to: target)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix)) }
        }
        notice = String(localized: "Die Archiv-Datenbank war beschädigt und wurde neu angelegt. Die alte Datei liegt als „\(target.lastPathComponent)“ daneben.")
    }

    private static func openAndPrepare(_ url: URL) throws -> SQLiteConnection {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(url: url)
        try db.execute("PRAGMA busy_timeout = 5000")
        // Erst lesen: eine kaputte Datei fällt hier mit SQLITE_NOTADB/CORRUPT auf.
        let version = try db.scalar("PRAGMA user_version") ?? 0
        let tables = try db.scalar("SELECT COUNT(*) FROM sqlite_master") ?? 0
        if version == 0 && tables == 0 {
            // Muss vor der ersten Tabelle stehen; danach gibt `incremental_vacuum` Platz frei.
            try db.execute("PRAGMA auto_vacuum = INCREMENTAL")
        }
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try migrate(db, from: version)
        return db
    }

    // MARK: Schema

    /// Schema-Stände: Eintrag i hebt `user_version` von i auf i + 1. Nur anhängen,
    /// nie ändern – ältere Dateien durchlaufen alle fehlenden Schritte.
    static let migrations: [String] = [
        """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);

        CREATE TABLE sightings (
            id INTEGER PRIMARY KEY,
            kind INTEGER NOT NULL,
            sid TEXT NOT NULL,
            key TEXT NOT NULL,
            day TEXT NOT NULL,
            name TEXT,
            registration TEXT,
            type TEXT,
            operator TEXT,
            route TEXT,
            first REAL NOT NULL,
            last REAL NOT NULL,
            messages INTEGER NOT NULL DEFAULT 0,
            max_altitude INTEGER,
            max_speed REAL,
            min_distance REAL,
            track BLOB,
            UNIQUE (kind, sid)
        );
        CREATE INDEX sightings_kind_last ON sightings (kind, last);
        CREATE INDEX sightings_kind_key ON sightings (kind, key, last);
        CREATE INDEX sightings_kind_day ON sightings (kind, day);

        CREATE TABLE sonde_samples (
            id INTEGER PRIMARY KEY,
            serial TEXT NOT NULL,
            type TEXT NOT NULL,
            time INTEGER NOT NULL,
            frame INTEGER,
            frequency REAL,
            latitude REAL,
            longitude REAL,
            altitude REAL,
            vertical_speed REAL,
            wind_speed REAL,
            heading REAL,
            temperature REAL,
            humidity REAL,
            battery REAL,
            window TEXT,
            UNIQUE (serial, time)
        );
        CREATE INDEX sonde_samples_time ON sonde_samples (time);

        CREATE TABLE airband_transmissions (
            id INTEGER PRIMARY KEY,
            uuid TEXT NOT NULL UNIQUE,
            start REAL NOT NULL,
            duration REAL NOT NULL,
            channel INTEGER NOT NULL,
            name TEXT NOT NULL DEFAULT '',
            peak_db REAL NOT NULL DEFAULT 0,
            recording TEXT,
            transcript TEXT,
            transcript_lang TEXT,
            transcript_confidence REAL
        );
        CREATE INDEX airband_start ON airband_transmissions (start);
        CREATE VIRTUAL TABLE airband_fts USING fts5 (
            transcript, content = 'airband_transmissions', content_rowid = 'id',
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER airband_fts_insert AFTER INSERT ON airband_transmissions BEGIN
            INSERT INTO airband_fts (rowid, transcript) VALUES (new.id, new.transcript);
        END;
        CREATE TRIGGER airband_fts_delete AFTER DELETE ON airband_transmissions BEGIN
            INSERT INTO airband_fts (airband_fts, rowid, transcript) VALUES ('delete', old.id, old.transcript);
        END;
        CREATE TRIGGER airband_fts_update AFTER UPDATE OF transcript ON airband_transmissions BEGIN
            INSERT INTO airband_fts (airband_fts, rowid, transcript) VALUES ('delete', old.id, old.transcript);
            INSERT INTO airband_fts (rowid, transcript) VALUES (new.id, new.transcript);
        END;

        CREATE TABLE acars_messages (
            id INTEGER PRIMARY KEY,
            time REAL NOT NULL,
            source TEXT NOT NULL,
            frequency REAL,
            registration TEXT NOT NULL DEFAULT '',
            flight TEXT NOT NULL DEFAULT '',
            label TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL DEFAULT '',
            UNIQUE (source, time, registration, label)
        );
        CREATE INDEX acars_time ON acars_messages (time);
        CREATE VIRTUAL TABLE acars_fts USING fts5 (
            text, content = 'acars_messages', content_rowid = 'id',
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER acars_fts_insert AFTER INSERT ON acars_messages BEGIN
            INSERT INTO acars_fts (rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER acars_fts_delete AFTER DELETE ON acars_messages BEGIN
            INSERT INTO acars_fts (acars_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        CREATE TRIGGER acars_fts_update AFTER UPDATE OF text ON acars_messages BEGIN
            INSERT INTO acars_fts (acars_fts, rowid, text) VALUES ('delete', old.id, old.text);
            INSERT INTO acars_fts (rowid, text) VALUES (new.id, new.text);
        END;
        """,
        // 2 (29.10.2026): Spracherkennung – erkanntes Rufzeichen eines ADS-B-Flugzeugs
        // samt ICAO-Adresse (Verknüpfung „Flugzeug zeigen“) und die aufbereitete
        // Abschrift (Ziffern statt Zahlwörter) zusätzlich zum Rohtext im Volltextindex:
        // „123.875“ findet so auch „123 decimal 875“.
        """
        ALTER TABLE airband_transmissions ADD COLUMN transcript_callsign TEXT;
        ALTER TABLE airband_transmissions ADD COLUMN transcript_icao TEXT;
        ALTER TABLE airband_transmissions ADD COLUMN transcript_text TEXT;
        DROP TRIGGER airband_fts_insert;
        DROP TRIGGER airband_fts_delete;
        DROP TRIGGER airband_fts_update;
        DROP TABLE airband_fts;
        CREATE VIRTUAL TABLE airband_fts USING fts5 (
            transcript, transcript_text, content = 'airband_transmissions', content_rowid = 'id',
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER airband_fts_insert AFTER INSERT ON airband_transmissions BEGIN
            INSERT INTO airband_fts (rowid, transcript, transcript_text) VALUES (new.id, new.transcript, new.transcript_text);
        END;
        CREATE TRIGGER airband_fts_delete AFTER DELETE ON airband_transmissions BEGIN
            INSERT INTO airband_fts (airband_fts, rowid, transcript, transcript_text)
                VALUES ('delete', old.id, old.transcript, old.transcript_text);
        END;
        CREATE TRIGGER airband_fts_update AFTER UPDATE OF transcript, transcript_text ON airband_transmissions BEGIN
            INSERT INTO airband_fts (airband_fts, rowid, transcript, transcript_text)
                VALUES ('delete', old.id, old.transcript, old.transcript_text);
            INSERT INTO airband_fts (rowid, transcript, transcript_text) VALUES (new.id, new.transcript, new.transcript_text);
        END;
        INSERT INTO airband_fts (airband_fts) VALUES ('rebuild');
        """,
    ]

    static var schemaVersion: Int { migrations.count }

    private static func migrate(_ db: SQLiteConnection, from version: Int) throws {
        guard version < migrations.count else {
            if version > migrations.count {
                log.error("Archiv hat Schema \(version), diese App kennt nur \(migrations.count)")
            }
            return
        }
        for step in version..<migrations.count {
            try db.transaction {
                try db.execute(migrations[step])
                try db.setUserVersion(step + 1)
            }
            log.notice("Archiv-Schema auf Stand \(step + 1)")
        }
    }

    // MARK: Pflege

    /// Konsistente Kopie nach `target` (`VACUUM INTO`) – für Sicherungen, auch
    /// während geschrieben wird.
    func copy(to target: URL) throws {
        try? FileManager.default.removeItem(at: target)
        try sync { db in
            try db.run("VACUUM INTO ?", [target.path])
        }
    }

    /// Größe der Datei samt WAL in Bytes.
    func fileSize() -> Int64 {
        [url.path, url.path + "-wal"].reduce(Int64(0)) { sum, path in
            sum + ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0)
        }
    }

    /// Fügt eine andere Archivdatei hinzu: nur Einträge, die hier fehlen (natürliche
    /// Schlüssel, `INSERT OR IGNORE`) – nichts wird überschrieben. Liefert die Zahl
    /// neuer Einträge.
    func merge(from source: URL) throws -> Int {
        try sync { db in
            let check = try SQLiteConnection(url: source, readOnly: true)
            let version = try check.scalar("PRAGMA user_version") ?? 0
            if version > Self.schemaVersion { throw ArchiveDatabaseError.newerSchema(version) }
            let tables = Set(try check.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) ?? "" })
            try db.run("ATTACH DATABASE ? AS src", [source.path])
            defer { db.clearCache(); try? db.execute("DETACH DATABASE src") }
            // Rufzeichen der Abschriften gibt es erst ab Schema 2.
            let airbandColumns = "uuid, start, duration, channel, name, peak_db, recording, transcript, transcript_lang, transcript_confidence"
                + (version >= 2 ? ", transcript_callsign, transcript_icao, transcript_text" : "")
            let copies: [(table: String, columns: String)] = [
                ("sightings", "kind, sid, key, day, name, registration, type, operator, route, first, last, messages, max_altitude, max_speed, min_distance, track"),
                ("sonde_samples", "serial, type, time, frame, frequency, latitude, longitude, altitude, vertical_speed, wind_speed, heading, temperature, humidity, battery, window"),
                ("airband_transmissions", airbandColumns),
                ("acars_messages", "time, source, frequency, registration, flight, label, text"),
            ]
            return try db.transaction {
                var added = 0
                for copy in copies where tables.contains(copy.table) {
                    added += try db.run("INSERT OR IGNORE INTO main.\(copy.table) (\(copy.columns)) SELECT \(copy.columns) FROM src.\(copy.table)")
                }
                return added
            }
        }
    }

    /// Gibt freie Seiten an das Dateisystem zurück und frischt die Statistik auf.
    func vacuumIncrementally() {
        queue.async {
            do {
                try self.perform { db in
                    try db.execute("PRAGMA incremental_vacuum")
                    try db.execute("PRAGMA optimize")
                    try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                }
            } catch {
                Self.log.error("Aufräumen fehlgeschlagen: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

enum ArchiveDatabaseError: Error, LocalizedError {
    case newerSchema(Int)

    var errorDescription: String? {
        switch self {
        case .newerSchema: String(localized: "Die Sicherung stammt aus einer neueren Version der App. Bitte die App aktualisieren.")
        }
    }
}
