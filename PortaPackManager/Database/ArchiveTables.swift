import Foundation

/// Art der Sichtung in der Tabelle `sightings`.
enum ArchiveKind: Int, Sendable, CaseIterable {
    case adsb = 0
    case ais = 1
}

/// Spur als kompaktes BLOB: je Punkt drei Int32 (Little Endian) – Breite und Länge
/// in 1e-5 Grad (so fein rundete schon das JSON-Archiv), Höhe in Metern oder
/// `Int32.min` ohne Höhe. 12 Byte je Punkt statt ≈ 30 Byte JSON.
enum TrackCodec {
    static let noAltitude = Int32.min

    static func encode(_ track: [[Double]]) -> Data {
        var data = Data(capacity: track.count * 12)
        func append(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for point in track where point.count >= 2 {
            append(Int32(clamping: Int((point[0] * 1e5).rounded())))
            append(Int32(clamping: Int((point[1] * 1e5).rounded())))
            if point.count > 2, point[2].isFinite { append(Int32(clamping: Int(point[2].rounded()))) } else { append(noAltitude) }
        }
        return data
    }

    static func decode(_ data: Data) -> [[Double]] {
        let count = data.count / 12
        guard count > 0 else { return [] }
        var result: [[Double]] = []
        result.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lat = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 12, as: Int32.self))
                let lon = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Int32.self))
                let alt = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Int32.self))
                var point = [Double(lat) / 1e5, Double(lon) / 1e5]
                if alt != noAltitude { point.append(Double(alt)) }
                result.append(point)
            }
        }
        return result
    }
}

// MARK: - Sichtungen

extension SQLiteConnection {
    private static let sightingColumns =
        "sid, key, name, registration, type, operator, route, first, last, messages, max_altitude, max_speed, min_distance, track"

    private static func sighting(_ s: SQLiteStatement) -> ArchiveSighting {
        ArchiveSighting(id: s.text(0) ?? "", key: s.text(1) ?? "", name: s.text(2), registration: s.text(3), type: s.text(4),
                        operatorName: s.text(5), route: s.text(6),
                        first: Date(timeIntervalSince1970: s.double(7)), last: Date(timeIntervalSince1970: s.double(8)),
                        messages: s.int(9), maxAltitudeM: s.optionalInt(10), maxSpeed: s.optionalDouble(11),
                        minDistanceKm: s.optionalDouble(12), track: s.blob(13).map(TrackCodec.decode) ?? [])
    }

    private static func sightingValues(_ s: ArchiveSighting, kind: ArchiveKind, day: String) -> [any SQLiteBindable] {
        [kind.rawValue, s.id, s.key, day, s.name, s.registration, s.type, s.operatorName, s.route,
         s.first.timeIntervalSince1970, s.last.timeIntervalSince1970, s.messages, s.maxAltitudeM, s.maxSpeed,
         s.minDistanceKm, s.track.isEmpty ? nil : TrackCodec.encode(s.track)]
    }

    private static let insertSighting = """
        INSERT INTO sightings (kind, sid, key, day, name, registration, type, operator, route, first, last, messages,
                               max_altitude, max_speed, min_distance, track)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static let insertMissingSighting = "INSERT OR IGNORE" + insertSighting.dropFirst("INSERT".count)

    /// Schreibt Sichtungen; vorhandene (gleiche Art und ID) werden ersetzt – der
    /// Empfänger schreibt seine laufenden Sichtungen immer wieder.
    func upsertSightings(_ entries: [(sighting: ArchiveSighting, day: String)], kind: ArchiveKind) throws {
        let sql = Self.insertSighting + """

            ON CONFLICT (kind, sid) DO UPDATE SET
                name = excluded.name, registration = excluded.registration, type = excluded.type,
                operator = excluded.operator, route = excluded.route, first = excluded.first, last = excluded.last,
                messages = excluded.messages, max_altitude = excluded.max_altitude, max_speed = excluded.max_speed,
                min_distance = excluded.min_distance, track = excluded.track
            """
        try transaction {
            for entry in entries { try run(sql, Self.sightingValues(entry.sighting, kind: kind, day: entry.day)) }
        }
    }

    /// Fügt nur fehlende Sichtungen hinzu (Übernahme, Sicherung); liefert die Zahl neuer.
    @discardableResult
    func insertMissingSightings(_ entries: [ArchiveSighting], kind: ArchiveKind, day: String) throws -> Int {
        try transaction {
            var added = 0
            for entry in entries {
                added += try run(Self.insertMissingSighting, Self.sightingValues(entry, kind: kind, day: day))
            }
            return added
        }
    }

    /// Wie viele der IDs in der Tabelle stehen (Prüfung nach der Übernahme).
    func countSightings(ids: [String], kind: ArchiveKind) throws -> Int {
        var found = 0
        for id in ids {
            found += try scalar("SELECT COUNT(*) FROM sightings WHERE kind = ? AND sid = ?", [kind.rawValue, id]) ?? 0
        }
        return found
    }

    /// Sichtungen der Tage (Tag der ersten Meldung, Ortszeit); `nil` = alle Tage.
    func sightings(kind: ArchiveKind, days: [String]?) throws -> [ArchiveSighting] {
        let base = "SELECT \(Self.sightingColumns) FROM sightings WHERE kind = ?"
        guard let days else {
            return try query(base + " ORDER BY last DESC", [kind.rawValue], row: Self.sighting)
        }
        var result: [ArchiveSighting] = []
        for day in days {
            result += try query(base + " AND day = ?", [kind.rawValue, day], row: Self.sighting)
        }
        return result.sorted { $0.last > $1.last }
    }

    /// Sichtungen, deren letzte Meldung nach `since` lag.
    func sightings(kind: ArchiveKind, since: Date) throws -> [ArchiveSighting] {
        try query("SELECT \(Self.sightingColumns) FROM sightings WHERE kind = ? AND last >= ? ORDER BY last DESC",
                  [kind.rawValue, since.timeIntervalSince1970], row: Self.sighting)
    }

    /// Alle Sichtungen einer Kennung über alle Tage, neueste zuerst.
    func sightings(kind: ArchiveKind, key: String) throws -> [ArchiveSighting] {
        try query("SELECT \(Self.sightingColumns) FROM sightings WHERE kind = ? AND key = ? ORDER BY last DESC",
                  [kind.rawValue, key], row: Self.sighting)
    }

    /// Jüngste Sichtung einer Kennung, die nach `after` noch Meldungen hatte – zum
    /// Fortsetzen nach einem Neustart der App.
    func latestSighting(kind: ArchiveKind, key: String, after: Date) throws -> (sighting: ArchiveSighting, day: String)? {
        try query("SELECT \(Self.sightingColumns), day FROM sightings WHERE kind = ? AND key = ? AND last >= ? ORDER BY last DESC LIMIT 1",
                  [kind.rawValue, key, after.timeIntervalSince1970]) { (Self.sighting($0), $0.text(14) ?? "") }.first
    }

    /// Tage mit Sichtungen, neueste zuerst. Springt über den Index (je Tag ein
    /// Suchschritt) statt alle Zeilen zu lesen.
    func sightingDays(kind: ArchiveKind) throws -> [String] {
        try query("""
            WITH RECURSIVE d(day) AS (
                SELECT MAX(day) FROM sightings WHERE kind = ?1
                UNION ALL
                SELECT (SELECT MAX(day) FROM sightings WHERE kind = ?1 AND day < d.day) FROM d WHERE d.day IS NOT NULL
            )
            SELECT day FROM d WHERE day IS NOT NULL
            """, [kind.rawValue]) { $0.text(0) ?? "" }
    }
}

// MARK: - Radiosonden

extension SQLiteConnection {
    private static let insertSample = """
        INSERT OR IGNORE INTO sonde_samples (serial, type, time, frame, frequency, latitude, longitude, altitude,
            vertical_speed, wind_speed, heading, temperature, humidity, battery, window)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    /// Fügt Meldungen hinzu; eine Meldung derselben Sonde mit derselben Sekunde
    /// zählt als schon vorhanden (so entfernte auch das CSV-Archiv Doppelte).
    @discardableResult
    func insertSondeRows(_ rows: [SondeArchive.Row], window: String?) throws -> Int {
        try transaction {
            var added = 0
            for row in rows {
                let s = row.sample
                added += try run(Self.insertSample, [
                    row.serial, row.type, Int(s.date.timeIntervalSince1970.rounded(.down)), row.frame, s.frequencyMHz,
                    s.latitude, s.longitude, s.altitude, s.verticalSpeed, s.windSpeed, s.heading, s.temperature,
                    s.humidity, s.battery, window,
                ])
            }
            return added
        }
    }

    func countSondeRows(_ keys: [(serial: String, time: Int)]) throws -> Int {
        var found = 0
        for key in keys {
            found += try scalar("SELECT COUNT(*) FROM sonde_samples WHERE serial = ? AND time = ?", [key.serial, key.time]) ?? 0
        }
        return found
    }

    private static let sampleColumns =
        "serial, type, time, frame, frequency, latitude, longitude, altitude, vertical_speed, wind_speed, heading, temperature, humidity, battery"

    private static func sondeRow(_ s: SQLiteStatement) -> SondeArchive.Row {
        SondeArchive.Row(serial: s.text(0) ?? "", type: s.text(1) ?? "", frame: s.optionalInt(3), sample: SondeSample(
            date: Date(timeIntervalSince1970: s.double(2)), frequencyMHz: s.optionalDouble(4), latitude: s.optionalDouble(5),
            longitude: s.optionalDouble(6), altitude: s.optionalDouble(7), verticalSpeed: s.optionalDouble(8),
            windSpeed: s.optionalDouble(9), heading: s.optionalDouble(10), temperature: s.optionalDouble(11),
            humidity: s.optionalDouble(12), battery: s.optionalDouble(13)))
    }

    /// Meldungen, wahlweise einer Sonde und/oder ab einem Zeitpunkt.
    func sondeRows(serial: String? = nil, since: Date? = nil) throws -> [SondeArchive.Row] {
        var sql = "SELECT \(Self.sampleColumns) FROM sonde_samples"
        var conditions: [String] = []
        var values: [any SQLiteBindable] = []
        if let serial { conditions.append("serial = ?"); values.append(serial) }
        if let since { conditions.append("time >= ?"); values.append(Int(since.timeIntervalSince1970.rounded(.down))) }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        return try query(sql + " ORDER BY serial, time", values, row: Self.sondeRow)
    }

    /// Seriennummern der jüngsten Flüge (mindestens `minimum` Meldungen), neueste zuerst.
    func recentSondeSerials(limit: Int, minimum: Int) throws -> [String] {
        try query("""
            SELECT serial FROM sonde_samples GROUP BY serial HAVING COUNT(*) >= ?
            ORDER BY MIN(time) DESC LIMIT ?
            """, [minimum, limit]) { $0.text(0) ?? "" }
    }

    func deleteSonde(serial: String) throws -> Int {
        try run("DELETE FROM sonde_samples WHERE serial = ?", [serial])
    }

    /// Zahl der Empfangsfenster (früher: Protokolldateien) mit Meldungen.
    func sondeWindowCount() throws -> Int {
        try scalar("SELECT COUNT(DISTINCT window) FROM sonde_samples") ?? 0
    }
}

// MARK: - Flugfunk

extension SQLiteConnection {
    private static let transmissionColumns =
        "uuid, start, duration, channel, name, peak_db, recording, transcript, transcript_lang, transcript_confidence, transcript_callsign, transcript_icao"

    private static func transmission(_ s: SQLiteStatement) -> AirbandTransmission {
        var t = AirbandTransmission(id: UUID(uuidString: s.text(0) ?? "") ?? UUID(), start: Date(timeIntervalSince1970: s.double(1)),
                                    duration: s.double(2), index: s.int(3), name: s.text(4) ?? "", peakDB: Float(s.double(5)))
        t.recording = s.text(6)
        t.transcript = s.text(7)
        t.transcriptLanguage = s.text(8)
        t.transcriptConfidence = s.optionalDouble(9)
        t.callsign = s.text(10)
        t.aircraftICAO = s.text(11)
        return t
    }

    @discardableResult
    func insertTransmissions(_ items: [AirbandTransmission]) throws -> Int {
        try transaction {
            var added = 0
            for t in items {
                added += try run("""
                    INSERT OR IGNORE INTO airband_transmissions (\(Self.transmissionColumns), transcript_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [t.id.uuidString, t.start.timeIntervalSince1970, t.duration, t.index, t.name, t.peakDB,
                          t.recording, t.transcript, t.transcriptLanguage, t.transcriptConfidence, t.callsign, t.aircraftICAO,
                          t.transcript.map(AirbandTranscriptFormatter.format)])
            }
            return added
        }
    }

    func countTransmissions(ids: [UUID]) throws -> Int {
        var found = 0
        for id in ids {
            found += try scalar("SELECT COUNT(*) FROM airband_transmissions WHERE uuid = ?", [id.uuidString]) ?? 0
        }
        return found
    }

    func recentTransmissions(limit: Int) throws -> [AirbandTransmission] {
        try query("SELECT \(Self.transmissionColumns) FROM airband_transmissions ORDER BY start DESC LIMIT ?", [limit],
                  row: Self.transmission)
    }

    private static var prefixedTransmissionColumns: String {
        transmissionColumns.split(separator: ",").map { "t." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
    }

    /// Volltextsuche in den Abschriften (FTS5-Syntax), beste Treffer zuerst.
    func searchTransmissions(_ match: String, limit: Int) throws -> [AirbandTransmission] {
        try query("""
            SELECT \(Self.prefixedTransmissionColumns)
            FROM airband_fts JOIN airband_transmissions t ON t.id = airband_fts.rowid
            WHERE airband_fts MATCH ? ORDER BY rank LIMIT ?
            """, [match, limit], row: Self.transmission)
    }

    /// Sprüche, in denen die Erkennung dieses Rufzeichen gefunden hat, neueste zuerst.
    func transmissions(callsign: String, limit: Int) throws -> [AirbandTransmission] {
        try query("""
            SELECT \(Self.transmissionColumns) FROM airband_transmissions
            WHERE transcript_callsign = ? ORDER BY start DESC LIMIT ?
            """, [callsign, limit], row: Self.transmission)
    }

    /// Rohtext, dazu die aufbereitete Fassung nur für den Volltextindex.
    func setTranscript(id: UUID, text: String?, language: String?, confidence: Double?,
                       callsign: String? = nil, icao: String? = nil) throws {
        try run("""
            UPDATE airband_transmissions SET transcript = ?, transcript_lang = ?, transcript_confidence = ?,
                transcript_callsign = ?, transcript_icao = ?, transcript_text = ? WHERE uuid = ?
            """, [text, language, confidence, callsign, icao, text.map(AirbandTranscriptFormatter.format), id.uuidString])
    }

    /// Rufzeichen der ADS-B-Sichtungen seit `since`, zuletzt gesehene zuerst –
    /// Hinweise für die Spracherkennung (Flugzeuge in Reichweite).
    func recentCallsigns(since: Date, limit: Int) throws -> [AirbandCallsign] {
        try query("""
            SELECT name, key, MAX(last) AS seen FROM sightings
            WHERE kind = 0 AND last >= ? AND name IS NOT NULL AND name != ''
            GROUP BY name ORDER BY seen DESC LIMIT ?
            """, [since.timeIntervalSince1970, limit]) { s in
            AirbandCallsign(callsign: (s.text(0) ?? "").trimmingCharacters(in: .whitespaces), icao: s.text(1))
        }
    }

    /// Mitschnitt-Dateinamen der Einträge (zum Löschen der Dateien).
    func transmissionRecordings(before: Date? = nil) throws -> [String] {
        if let before {
            return try query("SELECT recording FROM airband_transmissions WHERE recording IS NOT NULL AND start < ?",
                             [before.timeIntervalSince1970]) { $0.text(0) ?? "" }
        }
        return try query("SELECT recording FROM airband_transmissions WHERE recording IS NOT NULL") { $0.text(0) ?? "" }
    }
}

// MARK: - Zählen und Aufbewahrung

extension SQLiteConnection {
    struct Summary: Sendable, Equatable {
        var entries = 0
        var distinct = 0
        var oldest: Date?
    }

    func sightingSummary(kind: ArchiveKind) throws -> Summary {
        try query("SELECT COUNT(*), COUNT(DISTINCT key), MIN(first) FROM sightings WHERE kind = ?", [kind.rawValue]) {
            Summary(entries: $0.int(0), distinct: $0.int(1), oldest: $0.optionalDouble(2).map(Date.init(timeIntervalSince1970:)))
        }.first ?? Summary()
    }

    /// Flüge (Seriennummern) und Meldungen.
    func sondeSummary() throws -> Summary {
        try query("SELECT COUNT(DISTINCT serial), COUNT(*), MIN(time) FROM sonde_samples") {
            Summary(entries: $0.int(0), distinct: $0.int(1), oldest: $0.optionalDouble(2).map(Date.init(timeIntervalSince1970:)))
        }.first ?? Summary()
    }

    func airbandSummary() throws -> Summary {
        try query("SELECT COUNT(*), COUNT(DISTINCT channel), MIN(start) FROM airband_transmissions") {
            Summary(entries: $0.int(0), distinct: $0.int(1), oldest: $0.optionalDouble(2).map(Date.init(timeIntervalSince1970:)))
        }.first ?? Summary()
    }

    /// Einträge vor `cutoff` – was eine Aufbewahrungsfrist löschen würde.
    func countExpiring(before cutoff: Date) throws -> Int {
        let t = cutoff.timeIntervalSince1970
        return (try scalar("SELECT COUNT(*) FROM sightings WHERE last < ?", [t]) ?? 0)
            + (try scalar("SELECT COUNT(*) FROM sonde_samples WHERE time < ?", [Int(t)]) ?? 0)
            + (try scalar("SELECT COUNT(*) FROM airband_transmissions WHERE start < ?", [t]) ?? 0)
            + (try scalar("SELECT COUNT(*) FROM acars_messages WHERE time < ?", [t]) ?? 0)
    }

    /// Löscht alles vor `cutoff`; liefert die Zahl gelöschter Einträge.
    func deleteExpiring(before cutoff: Date) throws -> Int {
        let t = cutoff.timeIntervalSince1970
        return try transaction {
            try run("DELETE FROM sightings WHERE last < ?", [t])
                + run("DELETE FROM sonde_samples WHERE time < ?", [Int(t)])
                + run("DELETE FROM airband_transmissions WHERE start < ?", [t])
                + run("DELETE FROM acars_messages WHERE time < ?", [t])
        }
    }
}
