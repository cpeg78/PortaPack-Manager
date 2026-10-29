import Foundation
import MapKit
import Observation

/// Ein Flugplatz aus der OurAirports-Datenbank (`airports.csv`).
struct Airport: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case large = "large_airport"
        case medium = "medium_airport"
        case small = "small_airport"
        case seaplane = "seaplane_base"
        case heliport

        /// Vorrang beim Begrenzen: kleiner = wichtiger.
        var rank: Int {
            switch self {
            case .large: 0
            case .medium: 1
            case .small: 2
            case .seaplane: 3
            case .heliport: 4
            }
        }

        var title: String {
            switch self {
            case .large: String(localized: "Großer Flughafen")
            case .medium: String(localized: "Flughafen")
            case .small: String(localized: "Flugplatz")
            case .seaplane: String(localized: "Wasserflugplatz")
            case .heliport: String(localized: "Hubschrauberlandeplatz")
            }
        }

        /// Kurzform für den Fernzugriff.
        var short: String {
            switch self {
            case .large: "large"
            case .medium: "medium"
            case .small: "small"
            case .seaplane: "seaplane"
            case .heliport: "heliport"
            }
        }
    }

    /// Eindeutige Kennung bei OurAirports (oft = ICAO, sonst z. B. „DE-0123“).
    var ident: String
    /// ICAO-Kennung, falls sie von `ident` abweicht (`icao_code`, sonst `gps_code`).
    var icao: String?
    var iata: String?
    var name: String
    var kind: Kind
    var latitude: Double
    var longitude: Double
    var elevationFt: Int?
    var municipality: String?
    /// Linienverkehr (`scheduled_service = yes`).
    var scheduled: Bool

    var id: String { ident }
    /// Beschriftung auf der Karte: ICAO-Kennung, sonst die OurAirports-Kennung.
    var code: String { icao ?? ident }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Kompakte Ablage im Cache: je Flugplatz ein Array statt eines Objekts
/// (`[ident, icao, iata, name, typ, lat, lon, höhe, ort, linie]`) – rund halb so
/// groß und schneller gelesen als die 12-MB-CSV.
extension Airport: Codable {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        ident = try c.decode(String.self)
        icao = try c.decodeIfPresent(String.self)
        iata = try c.decodeIfPresent(String.self)
        name = try c.decode(String.self)
        let raw = try c.decode(String.self)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unbekannter Typ \(raw)")
        }
        self.kind = kind
        latitude = try c.decode(Double.self)
        longitude = try c.decode(Double.self)
        elevationFt = try c.decodeIfPresent(Int.self)
        municipality = try c.decodeIfPresent(String.self)
        scheduled = try c.decode(Int.self) != 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(ident)
        try c.encode(icao)
        try c.encode(iata)
        try c.encode(name)
        try c.encode(kind.rawValue)
        try c.encode(latitude)
        try c.encode(longitude)
        try c.encode(elevationFt)
        try c.encode(municipality)
        try c.encode(scheduled ? 1 : 0)
    }
}

/// `airports.csv` von OurAirports lesen und auf Flugplätze verdichten.
enum AirportCSV {
    /// Nur Flughäfen, Flugplätze, Hubschrauber- und Wasserlandeplätze; `closed`
    /// und `balloonport` fallen weg. Spalten über die Kopfzeile. Ergebnis nach
    /// Wichtigkeit sortiert (`importance`).
    static func parse(_ text: String) -> [Airport] {
        let all = NavaidCSV.rows(text)
        guard let header = all.first else { return [] }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let ident = column("ident"), let type = column("type"),
              let lat = column("latitude_deg"), let lon = column("longitude_deg") else { return [] }
        let name = column("name"), elevation = column("elevation_ft"), municipality = column("municipality")
        let scheduled = column("scheduled_service"), icaoCode = column("icao_code")
        let gpsCode = column("gps_code"), iataCode = column("iata_code")
        let airports = all.dropFirst().compactMap { row -> Airport? in
            func value(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let v = row[index].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let t = value(type), let kind = Airport.Kind(rawValue: t),
                  let id = value(ident),
                  let la = value(lat).flatMap(Double.init), la.isFinite, (-90...90).contains(la),
                  let lo = value(lon).flatMap(Double.init), lo.isFinite, (-180...180).contains(lo)
            else { return nil }
            let icao = (value(icaoCode) ?? value(gpsCode)).flatMap { $0 == id ? nil : $0 }
            // Erst Bereich prüfen, dann wandeln (wie bei den Funkfeuern).
            let elevationFt = value(elevation).flatMap(Double.init)
                .flatMap { $0.isFinite && abs($0) < 40_000 ? Int($0.rounded()) : nil }
            return Airport(ident: id, icao: icao, iata: value(iataCode), name: value(name) ?? id, kind: kind,
                           latitude: la, longitude: lo, elevationFt: elevationFt,
                           municipality: value(municipality), scheduled: value(scheduled) == "yes")
        }
        return sortedByImportance(airports)
    }

    /// Vorrang: Typ, Linienverkehr, IATA-Kennung, echte ICAO-Kennung – danach
    /// eine feste Pseudo-Zufallsfolge, damit beim Begrenzen nicht alphabetisch
    /// ganze Gegenden fehlen (alle „DE-…“ vor „ED…“).
    static func sortedByImportance(_ airports: [Airport]) -> [Airport] {
        let keyed: [(airport: Airport, key: UInt64)] = airports.map { ($0, importance($0)) }
        let sorted = keyed.sorted { (a: (airport: Airport, key: UInt64), b: (airport: Airport, key: UInt64)) -> Bool in
            if a.key != b.key { return a.key < b.key }
            return a.airport.ident < b.airport.ident
        }
        return sorted.map { $0.airport }
    }

    static func importance(_ a: Airport) -> UInt64 {
        var key = UInt64(a.kind.rank) << 60
        if !a.scheduled { key |= 1 << 59 }
        if a.iata == nil { key |= 1 << 58 }
        if !isICAO(a.code) { key |= 1 << 57 }
        return key | (fnv1a(a.ident) & ((1 << 57) - 1))
    }

    /// Vier Buchstaben/Ziffern, mit Buchstaben beginnend („EDHS“, „K00A“ nicht).
    static func isICAO(_ code: String) -> Bool {
        let s = Array(code.unicodeScalars)
        return s.count == 4 && ("A"..."Z").contains(s[0])
            && s.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
            && s.dropFirst().contains(where: { ("A"..."Z").contains($0) })
    }

    /// Feste Streuung (Swifts `Hasher` ist je Programmlauf anders).
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}

/// Auswahl der Flugplätze für einen Kartenausschnitt – rein, für Mac-Karte und
/// Fernzugriff. Die Liste ist nach Wichtigkeit sortiert; die ersten `limit`
/// Treffer im Ausschnitt genügen, ein Durchlauf ohne Sortieren.
enum AirportFilter {
    /// Höchstzahl der Flugplätze auf der Karte.
    static let defaultLimit = 150

    /// Ausschnitt in Grad. `west > east` heißt: über die Datumsgrenze.
    struct Bounds: Equatable, Sendable {
        var south: Double, west: Double, north: Double, east: Double

        /// Aus Leaflet-Grenzen (Längen können über ±180 hinausgehen).
        init?(south: Double, west: Double, north: Double, east: Double) {
            guard [south, west, north, east].allSatisfy(\.isFinite), south <= north, west <= east else { return nil }
            self.south = max(-90, south)
            self.north = min(90, north)
            if east - west >= 360 {
                self.west = -180; self.east = 180
            } else {
                self.west = Self.wrap(west)
                // Ost in (−180, 180]: 180 bliebe sonst −180 und kehrte den Ausschnitt um.
                let e = Self.wrap(east)
                self.east = e == -180 ? 180 : e
            }
        }

        /// „Süd,West,Nord,Ost“ wie `L.LatLngBounds.toBBoxString` (dort West,Süd,Ost,Nord!) –
        /// die Seite schickt ausdrücklich s,w,n,e.
        init?(query: String?) {
            guard let parts = query?.split(separator: ",").map({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  parts.count == 4, let s = parts[0], let w = parts[1], let n = parts[2], let e = parts[3] else { return nil }
            self.init(south: s, west: w, north: n, east: e)
        }

        /// Sichtbarer Ausschnitt einer MapKit-Karte.
        init?(mapRect rect: MKMapRect) {
            guard rect.width > 0, rect.height > 0 else { return nil }
            let world = MKMapSize.world
            let top = MKMapPoint(x: world.width / 2, y: min(max(rect.minY, 0), world.height)).coordinate.latitude
            let bottom = MKMapPoint(x: world.width / 2, y: min(max(rect.maxY, 0), world.height)).coordinate.latitude
            let west = rect.minX / world.width * 360 - 180
            let east = rect.maxX / world.width * 360 - 180
            self.init(south: bottom, west: west, north: top, east: east)
        }

        static func wrap(_ lon: Double) -> Double {
            let l = (lon + 180).truncatingRemainder(dividingBy: 360)
            return (l < 0 ? l + 360 : l) - 180
        }

        var latSpan: Double { north - south }

        func contains(latitude: Double, longitude: Double) -> Bool {
            guard latitude >= south, latitude <= north else { return false }
            return west <= east ? (longitude >= west && longitude <= east)
                                : (longitude >= west || longitude <= east)
        }
    }

    /// Welche Arten bei dieser Ausschnittshöhe (Grad Breite) erscheinen:
    /// Hubschrauberlandeplätze erst nah heran, kleine Plätze ab Regionsgröße.
    static func shows(_ kind: Airport.Kind, latSpan: Double) -> Bool {
        switch kind {
        case .large: true
        case .medium: latSpan <= 25
        case .small, .seaplane: latSpan <= 5
        case .heliport: latSpan <= 0.8
        }
    }

    /// Die wichtigsten Flugplätze im Ausschnitt (Eingabe nach Wichtigkeit sortiert).
    static func visible(_ airports: [Airport], in bounds: Bounds, limit: Int = defaultLimit) -> [Airport] {
        guard limit > 0 else { return [] }
        let span = bounds.latSpan
        // Die Zoomstufen sind nach Rang gestaffelt – die Liste ist nach Rang
        // sortiert, also endet die Suche beim ersten nicht erlaubten Rang.
        let maxRank = Airport.Kind.allCases.filter { shows($0, latSpan: span) }.map(\.rank).max() ?? -1
        var result: [Airport] = []
        result.reserveCapacity(min(limit, 256))
        // Über den Puffer lesen: Koordinaten prüfen, ohne jede Zeile (fünf
        // Strings) zu kopieren – nah herangezoomt sind es alle 72 000 Plätze.
        airports.withUnsafeBufferPointer { buffer in
            for i in buffer.indices {
                guard buffer[i].kind.rank <= maxRank else { break }
                guard bounds.contains(latitude: buffer[i].latitude, longitude: buffer[i].longitude) else { continue }
                result.append(buffer[i])
                if result.count >= limit { break }
            }
        }
        return result
    }
}

/// Flugplatz-Datenbank: einmal von OurAirports laden, danach offline.
@MainActor
@Observable
final class AirportDatabase {
    static let shared = AirportDatabase()

    static let sourceURL = URL(string: "https://davidmegginson.github.io/ourairports-data/airports.csv")!
    static var fileURL: URL { AppFiles.cacheFile("Flugplaetze.json") }

    private(set) var airports: [Airport] = []
    private(set) var updated: Date?
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var loaded = false

    /// Liest die verdichtete Ablage (einmal je Programmlauf, abseits des Main Actors).
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        loading = true
        Task {
            let result = await Task.detached { () -> [Airport] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return (try? JSONDecoder().decode([Airport].self, from: data)) ?? []
            }.value
            if self.airports.isEmpty { self.airports = result }
            self.updated = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            self.loading = false
        }
    }

    /// Lädt `airports.csv` (≈ 12 MB) neu, verdichtet sie und legt nur die
    /// Flugplätze ab. Gesendet wird nur die Anfrage selbst – kein Standort.
    func download() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.sourceURL)
            request.setValue(NavaidDatabase.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 120
            let (data, response) = try await URLSession.shared.limitedData(for: request, limit: 60_000_000)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let url = Self.fileURL
            let parsed = try await Task.detached { () throws -> [Airport] in
                let airports = AirportCSV.parse(String(decoding: data, as: UTF8.self))
                guard !airports.isEmpty else { throw URLError(.cannotParseResponse) }
                try JSONEncoder().encode(airports).write(to: url, options: .atomic)
                return airports
            }.value
            airports = parsed
            updated = Date()
            loaded = true
        } catch {
            self.error = String(localized: "Laden fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}
