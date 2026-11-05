import Foundation

/// Ein Messpunkt einer Radiosonde aus dem Meldungsprotokoll (`SondeLog`).
struct SondeSample: Sendable, Equatable {
    var date: Date
    var frequencyMHz: Double?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var verticalSpeed: Double?
    var windSpeed: Double?
    var heading: Double?
    var temperature: Double?
    var humidity: Double?
    var battery: Double?
    /// Seit Schema 3 (04.11.2026): Luftdruck (hPa, nur RS41-SGP), GPS-Satelliten,
    /// Zellstrom einer angehängten Ozonsonde (µA). Ältere Meldungen: nil.
    var pressure: Double?
    var satellites: Int?
    var ozoneCurrent: Double?
    /// Rahmennummer der Sonde (für die Empfangsquote).
    var frame: Int?

    var hasPosition: Bool { latitude != nil && longitude != nil && altitude != nil }

    /// Woher der Wind weht (meteorologisch, Grad): Gegenrichtung des Kurses der
    /// mit dem Wind treibenden Sonde.
    static func windFrom(heading: Double) -> Double {
        (heading + 180).truncatingRemainder(dividingBy: 360)
    }
}

/// Ein Flug: alle Meldungen einer Seriennummer, über Dateien hinweg.
struct SondeFlight: Identifiable, Sendable, Equatable {
    var serial: String
    var type: String
    /// Nach Zeit sortiert.
    var samples: [SondeSample]

    var id: String { serial }
    var first: Date { samples.first?.date ?? .distantPast }
    var last: Date { samples.last?.date ?? .distantPast }
    var duration: TimeInterval { last.timeIntervalSince(first) }
    var positioned: [SondeSample] { samples.filter(\.hasPosition) }

    /// Höchster Punkt (meist das Platzen).
    var peak: SondeSample? { samples.filter { $0.altitude != nil }.max { $0.altitude! < $1.altitude! } }
    var launch: SondeSample? { samples.first(where: \.hasPosition) }
    var lastPosition: SondeSample? { samples.last(where: \.hasPosition) }
    var minTemperature: Double? { samples.compactMap(\.temperature).min() }
    var minPressure: Double? { samples.compactMap(\.pressure).min() }

    /// Anteil der gehörten Rahmen zwischen erstem und letztem (RS41 zählt je
    /// Sekunde einen Rahmen hoch). Nur bei durchgehender Zählung ohne Überlauf.
    var frameCoverage: Double? {
        let frames = samples.compactMap(\.frame)
        guard frames.count >= 10, let first = frames.min(), let last = frames.max(), last > first,
              last - first < 30_000 else { return nil }
        return min(1, Double(Set(frames).count) / Double(last - first + 1))
    }

    /// Geplatzt und im Sinkflug gehört: letzte Höhe deutlich unter dem Gipfel.
    var burst: Bool {
        guard let top = peak?.altitude, let end = lastPosition?.altitude else { return false }
        return top > 5000 && end < top - 300
    }

    /// Häufigste Frequenz.
    var frequencyMHz: Double? {
        let counts = Dictionary(samples.compactMap(\.frequencyMHz).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }

    /// Strecke vom ersten bis zum letzten Punkt mit Position (Luftlinie, km).
    var distanceKm: Double? {
        guard let a = launch, let b = lastPosition, let la = a.latitude, let lo = a.longitude,
              let lb = b.latitude, let lob = b.longitude else { return nil }
        return GeoMath.distanceKm(lat1: la, lon1: lo, lat2: lb, lon2: lob)
    }
}

/// Sondenmeldungen aus der Archiv-Datenbank (Tabelle `sonde_samples`, seit
/// 29.10.2026; vorher je Empfangsfenster eine CSV-Datei, siehe `ArchiveMigration`),
/// zu Flügen zusammengefasst – für den Verlauf auf der Sondenseite und das
/// Sondenarchiv. CSV bleibt Austauschformat (Export, alte Protokolle).
enum SondeArchive {
    struct Row: Sendable {
        var serial: String
        var type: String
        var frame: Int? = nil
        var sample: SondeSample
    }

    /// Zeilen einer CSV-Datei; Kopfzeile und kaputte Zeilen werden übersprungen.
    static func parse(_ text: String) -> [Row] {
        // `ISOTime` statt `ISO8601DateFormatter`: ≈ 0,5 statt ≈ 40–350 µs je Zeile (Review L1).
        var rows: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: ";", omittingEmptySubsequences: false)
            guard f.count >= 14, !f[2].isEmpty, let date = ISOTime.date(f[0]) else { continue }
            func d(_ i: Int) -> Double? { Double(f[i]) }
            // Druck, Satelliten und Ozon gibt es erst seit 04.11.2026 (Spalten 14–16).
            func optional(_ i: Int) -> Double? { i < f.count ? d(i) : nil }
            rows.append(Row(serial: unquote(String(f[2])), type: unquote(String(f[1])), frame: Int(f[3]), sample: SondeSample(
                date: date, frequencyMHz: d(4), latitude: d(5), longitude: d(6), altitude: d(7),
                verticalSpeed: d(8), windSpeed: d(9), heading: d(10), temperature: d(11), humidity: d(12),
                battery: d(13), pressure: optional(14), satellites: optional(15).map { Int($0) },
                ozoneCurrent: optional(16), frame: Int(f[3]))))
        }
        return rows
    }

    /// Ein Feld aus dem Export (`TrafficArchive.csvField`) zurückwandeln:
    /// Anführungszeichen und den Formelschutz `'` entfernen.
    static func unquote(_ field: String) -> String {
        guard field.count >= 2, field.hasPrefix("\""), field.hasSuffix("\"") else { return field }
        var inner = String(field.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        if inner.hasPrefix("'"), let next = inner.dropFirst().first, "=+-@\t\r".contains(next) { inner.removeFirst() }
        return inner
    }

    /// Flüge aus beliebig vielen Dateien, neueste zuerst.
    static func flights(from rows: [Row]) -> [SondeFlight] {
        var grouped: [String: (type: String, samples: [SondeSample])] = [:]
        for row in rows {
            var sample = row.sample
            if sample.frame == nil { sample.frame = row.frame }
            grouped[row.serial, default: (row.type, [])].samples.append(sample)
        }
        return grouped.map { serial, entry in
            // Sortieren, doppelte Zeitstempel (dieselbe Meldung zweimal) entfernen.
            var seen = Set<Date>()
            let samples = entry.samples.sorted { $0.date < $1.date }.filter { seen.insert($0.date).inserted }
            return SondeFlight(serial: serial, type: entry.type, samples: samples)
        }
        .sorted { $0.first > $1.first }
    }

    /// Alle Flüge, neueste zuerst. Nicht auf dem Main Actor aufrufen (liest alle Meldungen).
    /// Flüge unter `minimumSamples` Meldungen (Zufallstreffer am Rand der Reichweite)
    /// fallen weg – sie füllten die Archivliste ohne Bahn und Profil (Nutzer,
    /// 29.10.2026; Schwelle 2 → 100 am 04.11.2026). Die Archivpflege löscht sie,
    /// sobald sie sechs Stunden ruhen (`ArchiveMaintenance.pruneShortSondeFlights`).
    static func load(database: ArchiveDatabase = .shared, minimum: Int = minimumSamples) -> [SondeFlight] {
        let rows = (try? database.sync { try $0.sondeRows() }) ?? []
        return flights(from: rows).filter { $0.samples.count >= minimum }
    }
    /// Bei einer Meldung je Sekunde gut anderthalb Minuten Empfang.
    static let minimumSamples = 100

    /// Die jüngsten `limit` Flüge (mit mindestens `minimumSamples` Meldungen), neueste zuerst –
    /// ohne das ganze Archiv zu lesen.
    static func recent(limit: Int, database: ArchiveDatabase = .shared, minimum: Int = minimumSamples) -> [SondeFlight] {
        let rows = (try? database.sync { db -> [Row] in
            try db.recentSondeSerials(limit: limit, minimum: minimum).flatMap { try db.sondeRows(serial: $0) }
        }) ?? []
        return flights(from: rows)
    }

    /// Entfernt alle Meldungen einer Seriennummer aus dem Archiv. Liefert die Zahl
    /// entfernter Meldungen. Nicht auf dem Main Actor. Gleichzeitiges Anhängen
    /// (`SondeLog.append`) läuft über dieselbe Warteschlange – nichts geht verloren.
    @discardableResult
    static func delete(serial: String, database: ArchiveDatabase = .shared) -> Int {
        (try? database.sync { db in try db.transaction { try db.deleteSonde(serial: serial) } }) ?? 0
    }

    /// Ein Flug.
    static func load(serial: String, database: ArchiveDatabase = .shared) -> SondeFlight? {
        let rows = (try? database.sync { try $0.sondeRows(serial: serial) }) ?? []
        return flights(from: rows).first
    }

    /// Laufender Flug: nur Meldungen der letzten `within` Sekunden. Die Sondenseite
    /// fragt alle 10 s (Review 28.10.2026, W10). `isCancelled` bricht vor dem Lesen ab.
    static func loadCurrent(serial: String, database: ArchiveDatabase = .shared, now: Date = Date(),
                            within: TimeInterval = 24 * 3600, isCancelled: () -> Bool = { false }) -> SondeFlight? {
        if isCancelled() { return nil }
        let since = now.addingTimeInterval(-within)
        let rows = (try? database.sync { try $0.sondeRows(serial: serial, since: since) }) ?? []
        return flights(from: rows).first
    }

    /// Zahl der Empfangsfenster mit Meldungen (früher: Protokolldateien).
    static func windowCount(database: ArchiveDatabase = .shared) -> Int {
        (try? database.sync { try $0.sondeWindowCount() }) ?? 0
    }

    /// Für Diagramme ausdünnen: höchstens `limit` Punkte, gleichmäßig verteilt.
    static func thinned(_ samples: [SondeSample], limit: Int = 800) -> [SondeSample] {
        guard samples.count > limit, limit > 1 else { return samples }
        let step = Double(samples.count - 1) / Double(limit - 1)
        return (0..<limit).map { samples[Int((Double($0) * step).rounded())] }
    }

    /// CSV eines einzelnen Flugs (Kopfzeile wie `SondeLog`).
    static func csv(_ flight: SondeFlight) -> String {
        func f(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "" }
        return SondeLog.header + flight.samples.map { s in
            // Typ und Seriennummer sind Text aus dem Protokoll – als Formel-sicheres Feld (Review Y6).
            [ISOTime.string(s.date), TrafficArchive.csvField(flight.type), TrafficArchive.csvField(flight.serial),
             s.frame.map(String.init) ?? "",
             f(s.frequencyMHz, "%.3f"),
             f(s.latitude, "%.5f"), f(s.longitude, "%.5f"), f(s.altitude, "%.0f"), f(s.verticalSpeed, "%.1f"),
             f(s.windSpeed, "%.1f"), f(s.heading, "%.0f"), f(s.temperature, "%.1f"), f(s.humidity, "%.0f"),
             f(s.battery, "%.1f"), f(s.pressure, "%.2f"), s.satellites.map(String.init) ?? "",
             f(s.ozoneCurrent, "%.4f")].joined(separator: ";") + "\n"
        }.joined()
    }
}
