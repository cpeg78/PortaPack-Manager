import Foundation
import Observation

/// Ein Flughafen aus der Streckenauskunft.
struct RouteAirport: Equatable, Sendable, Codable {
    var icao = ""
    var iata = ""
    var name = ""
    var city = ""
    var countryISO = ""
    var latitude = 0.0
    var longitude = 0.0

    /// „Hamburg (HAM)“ – Stadt, sonst Name; Kürzel IATA, sonst ICAO.
    var shortText: String {
        let place = city.isEmpty ? name : city
        let code = iata.isEmpty ? icao : iata
        if place.isEmpty { return code }
        return code.isEmpty ? place : "\(place) (\(code))"
    }
}

/// Start und Ziel zu einem Rufzeichen.
struct FlightRoute: Equatable, Sendable, Codable {
    var callsign = ""
    var airline = ""
    var origin = RouteAirport()
    var destination = RouteAirport()

    /// „CPH → HAM“
    var codesText: String {
        let a = origin.iata.isEmpty ? origin.icao : origin.iata
        let b = destination.iata.isEmpty ? destination.icao : destination.iata
        return "\(a) → \(b)"
    }

    /// Abstand (km) einer Position von der Großkreisstrecke Start–Ziel, auf
    /// den Abschnitt zwischen beiden begrenzt (vor dem Start/nach dem Ziel:
    /// Abstand zum Flughafen).
    func offRouteKm(latitude: Double, longitude: Double) -> Double {
        let r = 6371.0
        let d13 = GeoMath.distanceKm(lat1: origin.latitude, lon1: origin.longitude, lat2: latitude, lon2: longitude) / r
        let d12 = GeoMath.distanceKm(lat1: origin.latitude, lon1: origin.longitude,
                                     lat2: destination.latitude, lon2: destination.longitude) / r
        guard d12 > 1e-6 else { return d13 * r }
        let rad = Double.pi / 180
        let b13 = GeoMath.bearingDegrees(lat1: origin.latitude, lon1: origin.longitude, lat2: latitude, lon2: longitude) * rad
        let b12 = GeoMath.bearingDegrees(lat1: origin.latitude, lon1: origin.longitude,
                                         lat2: destination.latitude, lon2: destination.longitude) * rad
        let crossTrack = asin(sin(d13) * sin(b13 - b12))
        let alongTrack = acos(max(-1, min(1, cos(d13) / cos(crossTrack))))
        if cos(b13 - b12) < 0 { return d13 * r }   // hinter dem Start
        if alongTrack > d12 {                      // hinter dem Ziel
            return GeoMath.distanceKm(lat1: destination.latitude, lon1: destination.longitude,
                                      lat2: latitude, lon2: longitude)
        }
        return abs(crossTrack) * r
    }

    /// Antwort von adsbdb.com (`/v0/callsign/<rufzeichen>`).
    static func parseADSBDB(_ data: Data) -> FlightRoute? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let route = response["flightroute"] as? [String: Any],
              let origin = route["origin"] as? [String: Any],
              let destination = route["destination"] as? [String: Any] else { return nil }
        func airport(_ o: [String: Any]) -> RouteAirport {
            RouteAirport(icao: o["icao_code"] as? String ?? "", iata: o["iata_code"] as? String ?? "",
                         name: o["name"] as? String ?? "", city: o["municipality"] as? String ?? "",
                         countryISO: o["country_iso_name"] as? String ?? "",
                         latitude: (o["latitude"] as? NSNumber)?.doubleValue ?? 0,
                         longitude: (o["longitude"] as? NSNumber)?.doubleValue ?? 0)
        }
        let airline = (route["airline"] as? [String: Any])?["name"] as? String ?? ""
        let result = FlightRoute(callsign: route["callsign"] as? String ?? "", airline: airline,
                                 origin: airport(origin), destination: airport(destination))
        guard !result.origin.icao.isEmpty || !result.origin.iata.isEmpty,
              !result.destination.icao.isEmpty || !result.destination.iata.isEmpty else { return nil }
        return result
    }
}

/// Streckenauskunft je Rufzeichen über adsbdb.com – nur, wenn die
/// Online-Abfrage der Flugzeugdatenbank erlaubt ist (dieselbe Zustimmung).
/// Nacheinander, 250 ms Abstand; Funde gelten eine Woche, Fehlanzeigen einen Tag.
@MainActor
@Observable
final class FlightRouteLookup {
    static let shared = FlightRouteLookup()

    static let baseURL = URL(string: "https://api.adsbdb.com/v0/callsign/")!
    static let storeURL = AppFiles.cacheFile("Flugstrecken.json")
    private static let hitLifetime: TimeInterval = 7 * 24 * 3600
    private static let missLifetime: TimeInterval = 24 * 3600

    private(set) var routes: [String: FlightRoute] = [:]
    private(set) var error: String?

    @ObservationIgnored private var fetched: [String: Date] = [:]
    @ObservationIgnored private var misses: [String: Date] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var storeLoaded = false

    /// Strecke zum Rufzeichen; fragt bei Bedarf nach (Ergebnis beim nächsten Aufruf).
    func route(for callsign: String?) -> FlightRoute? {
        guard let key = Self.normalized(callsign) else { return nil }
        loadStoreIfNeeded()
        if let route = routes[key] {
            if let date = fetched[key], Date().timeIntervalSince(date) > Self.hitLifetime { enqueue(key) }
            return route
        }
        enqueue(key)
        return nil
    }

    /// Großbuchstaben ohne Leerzeichen; Rufzeichen ohne Ziffer (Kennzeichen
    /// wie „DEABC“ bei Privatfliegern) haben keine Strecke.
    nonisolated static func normalized(_ callsign: String?) -> String? {
        guard let raw = callsign?.trimmingCharacters(in: .whitespaces).uppercased(),
              raw.count >= 3, raw.count <= 8, raw.contains(where: \.isNumber),
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return raw
    }

    private func enqueue(_ key: String) {
        guard AircraftDatabase.shared.onlineLookup, !queue.contains(key) else { return }
        if let missed = misses[key], Date().timeIntervalSince(missed) < Self.missLifetime { return }
        if let date = fetched[key], Date().timeIntervalSince(date) < Self.hitLifetime { return }
        queue.append(key)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            defer { self?.worker = nil }
            guard let self else { return }
            while !Task.isCancelled, AircraftDatabase.shared.onlineLookup, !self.queue.isEmpty {
                let key = self.queue.removeFirst()
                await self.fetch(key)
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.saveStore()
        }
    }

    private func fetch(_ key: String) async {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(key))
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.limitedData(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 { misses[key] = Date(); return }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard let route = FlightRoute.parseADSBDB(data) else { misses[key] = Date(); return }
            routes[key] = route
            fetched[key] = Date()
            misses[key] = nil
            error = nil
        } catch {
            // Netz weg: in zwei Minuten wieder versuchen.
            misses[key] = Date().addingTimeInterval(-Self.missLifetime + 120)
            self.error = error.localizedDescription
        }
    }

    private struct Store: Codable {
        var routes: [String: FlightRoute] = [:]
        var fetched: [String: Date] = [:]
        var misses: [String: Date] = [:]
    }

    private func loadStoreIfNeeded() {
        guard !storeLoaded else { return }
        storeLoaded = true
        guard let data = try? Data(contentsOf: Self.storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        routes = store.routes
        fetched = store.fetched
        let cutoff = Date().addingTimeInterval(-Self.missLifetime)
        misses = store.misses.filter { $0.value > cutoff }
    }

    private func saveStore() {
        let cutoff = Date().addingTimeInterval(-Self.missLifetime)
        let store = Store(routes: routes, fetched: fetched, misses: misses.filter { $0.value > cutoff })
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: Self.storeURL, options: .atomic) }
    }
}

/// Vorschaubild eines Flugzeugs von planespotters.net.
extension URL {
    /// Nur HTTPS und nur die erwarteten Hosts (samt Unterdomänen): Links aus
    /// Fremd-APIs landen in `NSWorkspace.open` und als `href` auf der
    /// Fernzugriffsseite – `javascript:` oder `file:` dürfen da nicht durch.
    func isSafeWebLink(hosts: [String]) -> Bool {
        guard scheme?.lowercased() == "https", let host = host()?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

struct AircraftPhoto: Equatable, Sendable {
    let imageURL: URL
    let pageURL: URL
    let photographer: String

    /// Antwort von `api.planespotters.net/pub/photos/hex/<hex>`.
    static func parsePlanespotters(_ data: Data) -> AircraftPhoto? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["photos"] as? [[String: Any]])?.first,
              let large = (first["thumbnail_large"] as? [String: Any])?["src"] as? String
                ?? (first["thumbnail"] as? [String: Any])?["src"] as? String,
              let image = URL(string: large), image.isSafeWebLink(hosts: ["plnspttrs.net", "planespotters.net"]),
              let link = first["link"] as? String, let page = URL(string: link),
              page.isSafeWebLink(hosts: ["planespotters.net"]) else { return nil }
        return AircraftPhoto(imageURL: image, pageURL: page, photographer: first["photographer"] as? String ?? "")
    }
}

/// Fotos je ICAO-Adresse von planespotters.net. Deren Bedingungen: Fotograf
/// nennen und auf die Fotoseite verlinken, User-Agent mit Kontaktadresse.
/// Nur im Speicher (nichts auf Platte); gleicher Online-Schalter wie die
/// Flugzeugdatenbank.
@MainActor
@Observable
final class AircraftPhotoLookup {
    static let shared = AircraftPhotoLookup()

    static let baseURL = URL(string: "https://api.planespotters.net/pub/photos/hex/")!
    /// planespotters lehnt Anfragen ohne Kontakt-URL im User-Agent ab (403).
    static let userAgent = "PortaPackManager/1.0 (+https://github.com/cpeg78)"

    private(set) var photos: [UInt32: AircraftPhoto] = [:]
    /// Adressen, für die die Antwort da ist (mit oder ohne Foto) – damit die
    /// Anzeige „sucht …“ von „kein Foto“ unterscheiden kann.
    private(set) var answered: Set<UInt32> = []
    @ObservationIgnored private var asked: Set<UInt32> = []
    @ObservationIgnored private var queue: [UInt32] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// Foto zur Adresse; fragt beim ersten Mal nach (Ergebnis beim nächsten Aufruf).
    func photo(for icao: UInt32) -> AircraftPhoto? {
        if let photo = photos[icao] { return photo }
        guard AircraftDatabase.shared.onlineLookup, !asked.contains(icao) else { return nil }
        asked.insert(icao)
        queue.append(icao)
        if worker == nil {
            worker = Task { [weak self] in
                defer { self?.worker = nil }
                guard let self else { return }
                while !Task.isCancelled, !self.queue.isEmpty {
                    let icao = self.queue.removeFirst()
                    await self.fetch(icao)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        return nil
    }

    private func fetch(_ icao: UInt32) async {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(String(format: "%06x", icao)))
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.limitedData(for: request) else {
            asked.remove(icao)   // Netz weg: beim nächsten Anklicken erneut
            return
        }
        answered.insert(icao)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let photo = AircraftPhoto.parsePlanespotters(data) else { return }
        photos[icao] = photo
    }
}
