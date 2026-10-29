import Foundation

/// Eine Sichtung im Archiv: ein Flugzeug oder Schiff von der ersten bis zur
/// letzten Meldung (Lücke über 30 min = neue Sichtung).
struct ArchiveSighting: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var key: String              // ICAO-Adresse (hex) bzw. MMSI
    var name: String?            // Rufzeichen bzw. Schiffsname
    var registration: String?    // Kennzeichen bzw. Rufzeichen (AIS)
    var type: String?
    var operatorName: String?
    var route: String?           // „Hamburg (HAM) → Zürich (ZRH)“ bzw. Ziel
    var first: Date
    var last: Date
    var messages: Int
    var maxAltitudeM: Int?
    var maxSpeed: Double?        // km/h (ADS-B) bzw. kn (AIS)
    var minDistanceKm: Double?
    /// Ausgedünnte Spur [Breite, Länge, Höhe in m] – ein Punkt je ≥ 1 km. Die
    /// Höhe steht erst seit 29.10.2026 darin (ältere Punkte haben nur zwei Werte).
    var track: [[Double]] = []

    var duration: TimeInterval { last.timeIntervalSince(first) }

    /// Wie oft die Maschine in dieser Sichtung in Bodennähe kam und wieder stieg
    /// (Platzrunden, Touch-and-go, Landung). Aus der Höhe der Spur.
    var approaches: Int { Self.approaches(track.compactMap { $0.count > 2 ? $0[2] : nil }) }

    /// Zählt Tiefpunkte: Bezug ist die niedrigste gesehene Höhe (die Platzhöhe
    /// kennt die App nicht; sie muss unter 1500 m liegen). Gezählt wird, wenn die Höhe nach mindestens `high`
    /// Metern darüber wieder unter `low` Meter darüber fällt.
    nonisolated static func approaches(_ altitudes: [Double], low: Double = 250, high: Double = 500) -> Int {
        // Nur, wenn die Maschine überhaupt tief war – sonst zählte ein Überflug in
        // 9–11 km als „Anflug“ (Flugplätze liegen hier weit unter 1500 m).
        guard let base = altitudes.min(), base < 1500 else { return 0 }
        var count = 0, up = false
        for a in altitudes {
            if a > base + high { up = true }
            else if up, a < base + low { count += 1; up = false }
        }
        return count
    }
}

/// Was ein Empfänger je Ziel und Takt meldet.
struct SightingUpdate {
    var key: String
    var name: String?
    var registration: String?
    var type: String?
    var operatorName: String?
    var route: String?
    var lastSeen: Date
    var messages: Int
    var latitude: Double?
    var longitude: Double?
    var altitudeM: Int?
    var speed: Double?
}

/// Archiv aller Sichtungen in der Tabelle `sightings` der Archiv-Datenbank
/// (seit 29.10.2026; vorher je Tag eine JSON-Datei `Archiv/ADS-B/2026-10-26.json`).
/// Eine Sichtung gehört zum Tag ihrer ersten Meldung (Ortszeit) – wie früher die Datei.
///
/// Laufende Sichtungen liegen im Speicher; `save()` schreibt die geänderten
/// gebündelt in einer Transaktion abseits des Main Actors. Alles, was liest,
/// sichert vorher – die serielle Warteschlange der Datenbank liefert dann den
/// neuesten Stand.
@MainActor
final class TrafficArchive {
    static let adsb = TrafficArchive(kind: .adsb, database: .shared)
    static let ais = TrafficArchive(kind: .ais, database: .shared)

    /// Abstand, ab dem eine erneute Meldung als neue Sichtung zählt.
    static let gap: TimeInterval = 30 * 60

    let kind: ArchiveKind
    let database: ArchiveDatabase
    /// Laufende Sichtung je Ziel samt Tag.
    private var open: [String: (sighting: ArchiveSighting, day: String)] = [:]
    private var lastSeenByKey: [String: Date] = [:]
    /// Ziele, deren letzte Meldung vor diesem Zeitpunkt lag, hat `save()` aus
    /// `lastSeenByKey`/`open` entfernt. Meldet ein Empfänger sie mit dem alten
    /// Zeitstempel weiter (die Flugzeugliste hält Ziele bis zu einer Stunde), sind
    /// sie schon erfasst und werden übergangen – sonst entstünde nach Mitternacht
    /// eine doppelte Sichtung.
    private var prunedBefore = Date.distantPast
    /// Ziele mit ungesicherten Änderungen.
    private var dirty: Set<String> = []
    /// Abgeschlossene Sichtungen mit ungesicherten Änderungen (das Ziel kam nach
    /// über 30 min wieder, bevor `save()` lief).
    private var finished: [(sighting: ArchiveSighting, day: String)] = []
    private var lastSave = Date()
    /// Erste Meldung dieser Sitzung: Nur bis `gap` danach kann eine Sichtung aus
    /// der Zeit vor dem Neustart fortgesetzt werden – später fragt `record` die
    /// Datenbank nicht mehr.
    private var sessionStart: Date?

    init(kind: ArchiveKind, database: ArchiveDatabase) {
        self.kind = kind
        self.database = database
    }

    /// Eigener Standort (gemeinsam für alle Kartenseiten), für die Entfernung.
    static var home: (lat: Double, lon: Double)? {
        let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
        return lat == 0 && lon == 0 ? nil : (lat, lon)
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Nimmt die Meldungen eines Takts auf; nur Ziele mit neuer Meldung zählen.
    func record(_ updates: [SightingUpdate], home: (lat: Double, lon: Double)?) {
        for update in updates {
            if let seen = lastSeenByKey[update.key], seen >= update.lastSeen { continue }
            if lastSeenByKey[update.key] == nil, update.lastSeen < prunedBefore { continue }
            let previous = lastSeenByKey[update.key]
            lastSeenByKey[update.key] = update.lastSeen
            if sessionStart == nil { sessionStart = update.lastSeen }
            // Nach einem Neustart der App: laufende Sichtung aus der Datenbank fortsetzen
            // (eine indizierte Abfrage, nur in der ersten halben Stunde der Sitzung).
            if open[update.key] == nil, previous == nil, let begin = sessionStart,
               update.lastSeen.timeIntervalSince(begin) <= Self.gap {
                let kind = kind, key = update.key, after = update.lastSeen.addingTimeInterval(-Self.gap)
                if let resumed = try? database.sync({ try $0.latestSighting(kind: kind, key: key, after: after) }) {
                    open[update.key] = resumed
                }
            }
            var entry: (sighting: ArchiveSighting, day: String)
            if let current = open[update.key], update.lastSeen.timeIntervalSince(current.sighting.last) < Self.gap {
                entry = current
            } else {
                if let current = open[update.key], dirty.contains(update.key) { finished.append(current) }
                let day = Self.dayStamp(update.lastSeen)
                entry = (ArchiveSighting(id: "\(update.key)-\(Int(update.lastSeen.timeIntervalSince1970))", key: update.key,
                                         first: update.lastSeen, last: update.lastSeen, messages: 0), day)
            }
            var sighting = entry.sighting
            sighting.last = max(sighting.last, update.lastSeen)
            sighting.messages = max(sighting.messages, update.messages)
            if let v = update.name, !v.isEmpty { sighting.name = v }
            if let v = update.registration, !v.isEmpty { sighting.registration = v }
            if let v = update.type, !v.isEmpty { sighting.type = v }
            if let v = update.operatorName, !v.isEmpty { sighting.operatorName = v }
            if let v = update.route, !v.isEmpty { sighting.route = v }
            if let alt = update.altitudeM { sighting.maxAltitudeM = max(sighting.maxAltitudeM ?? alt, alt) }
            if let speed = update.speed { sighting.maxSpeed = max(sighting.maxSpeed ?? speed, speed) }
            if let lat = update.latitude, let lon = update.longitude {
                if let home {
                    let d = GeoMath.distanceKm(lat1: home.lat, lon1: home.lon, lat2: lat, lon2: lon)
                    sighting.minDistanceKm = min(sighting.minDistanceKm ?? d, d)
                }
                let far = sighting.track.last.map { GeoMath.distanceKm(lat1: $0[0], lon1: $0[1], lat2: lat, lon2: lon) >= 1 } ?? true
                if far {
                    var point = [(lat * 1e5).rounded() / 1e5, (lon * 1e5).rounded() / 1e5]
                    if let alt = update.altitudeM { point.append(Double(alt)) }
                    sighting.track.append(point)
                }
            }
            open[update.key] = (sighting, entry.day)
            dirty.insert(update.key)
        }
        if Date().timeIntervalSince(lastSave) > 60 { save() }
    }

    /// Schreibt geänderte Sichtungen (auch beim Stoppen eines Empfängers).
    ///
    /// Auf dem Main Actor nur der Schnappschuss der geänderten Sichtungen; das
    /// Schreiben ist eine Transaktion auf der Warteschlange der Datenbank. Spätere
    /// Schreibläufe überholen nie frühere. Auf das Ende warten: `flush()`.
    func save() {
        lastSave = Date()
        let changed = finished + dirty.compactMap { open[$0] }
        dirty.removeAll()
        finished.removeAll()
        // Ziele ohne Meldung seit mehr als `gap` vergessen (Review L6): ihre nächste
        // Meldung ist ohnehin eine neue Sichtung.
        let cutoff = Date().addingTimeInterval(-Self.gap)
        if lastSeenByKey.values.contains(where: { $0 < cutoff }) {
            lastSeenByKey = lastSeenByKey.filter { $0.value >= cutoff }
            open = open.filter { lastSeenByKey[$0.key] != nil }
            prunedBefore = max(prunedBefore, cutoff)
        }
        guard !changed.isEmpty else { return }
        let kind = kind
        database.write("Sichtungen sichern") { try $0.upsertSightings(changed, kind: kind) }
    }

    /// Wartet, bis alle angestoßenen Schreibläufe in der Datenbank sind.
    func flush() async {
        await database.flush()
    }

    /// Vorhandene Tage, neueste zuerst. Liest abseits des Main Actors.
    func loadDays() async -> [String] {
        save()
        let kind = kind
        do {
            return try await database.read { try $0.sightingDays(kind: kind) }
        } catch {
            ArchiveDatabase.log.error("Archivtage: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Vorhandene Tage, synchron – nur für Tests und kleine Abfragen.
    func availableDays() -> [String] {
        save()
        let kind = kind
        return (try? database.sync { try $0.sightingDays(kind: kind) }) ?? []
    }

    /// Sichtungen eines Tages, zuletzt gesehene zuerst (synchron).
    func sightings(day: String) -> [ArchiveSighting] {
        save()
        let kind = kind
        return (try? database.sync { try $0.sightings(kind: kind, days: [day]) }) ?? []
    }

    /// Sichtungen mehrerer Tage (`nil` = alle), zuletzt gesehene zuerst – abseits
    /// des Main Actors gelesen.
    func sightings(days wanted: [String]?) async -> [ArchiveSighting] {
        save()
        let kind = kind
        do {
            return try await database.read { try $0.sightings(kind: kind, days: wanted) }
        } catch {
            ArchiveDatabase.log.error("Sichtungen lesen: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Sichtungen mit Meldungen nach `since`, zuletzt gesehene zuerst.
    func sightings(since: Date) async -> [ArchiveSighting] {
        save()
        let kind = kind
        return (try? await database.read { try $0.sightings(kind: kind, since: since) }) ?? []
    }

    /// Alle Sichtungen einer Kennung über alle Tage, neueste zuerst.
    func sightings(key: String) async -> [ArchiveSighting] {
        save()
        let kind = kind
        return (try? await database.read { try $0.sightings(kind: kind, key: key) }) ?? []
    }

    /// CSV eines Tages (Semikolon, für Tabellenkalkulation).
    func csv(day: String, speedUnit: String) -> String {
        Self.csv(sightings(day: day), speedUnit: speedUnit)
    }

    /// CSV beliebiger Sichtungen, älteste zuerst.
    nonisolated static func csv(_ sightings: [ArchiveSighting], speedUnit: String) -> String {
        var text = "kennung;name;kennzeichen;typ;betreiber;strecke_ziel;erste;letzte;meldungen;max_hoehe_m;max_tempo_\(speedUnit);min_entfernung_km\n"
        for s in sightings.sorted(by: { $0.last < $1.last }) {
            let fields: [String] = [s.key, s.name ?? "", s.registration ?? "", s.type ?? "", s.operatorName ?? "", s.route ?? "",
                                    ISOTime.string(s.first), ISOTime.string(s.last), String(s.messages),
                                    s.maxAltitudeM.map(String.init) ?? "", s.maxSpeed.map { String(format: "%.0f", $0) } ?? "",
                                    s.minDistanceKm.map { String(format: "%.1f", $0) } ?? ""]
            text += fields.map(Self.csvField).joined(separator: ";") + "\n"
        }
        return text
    }

    /// Ein CSV-Feld: immer in Anführungszeichen, `"` verdoppelt. Namen und Ziele
    /// kommen frei wählbar per Funk (AIS-Zeichensatz enthält `= + - @`) – ein
    /// Schiff „=HYPERLINK(…)“ würde in der Tabellenkalkulation sonst zur Formel.
    /// Führende Formelzeichen entschärft ein vorangestelltes `'`.
    nonisolated static func csvField(_ value: String) -> String {
        var v = value
        if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
