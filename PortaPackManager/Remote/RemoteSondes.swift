import Foundation

/// Wetterballons im Fernzugriff (Reiter „Wetter & Satelliten“, Kasten „Wetterballons“):
/// `/api/sondes` liefert die gerade gehörten Sonden samt Flugbahn und Landeschätzung,
/// `/api/sondes?serial=…` einen Flug aus dem Archiv (ausgedünnt) für Karte und Diagramm.
@MainActor
enum RemoteSondes {
    /// Höchstzahl der Punkte je Bahn – genug für Karte und Diagramm, klein genug fürs Handy.
    nonisolated static let maxPoints = 600

    struct Home: Encodable { let lat: Double; let lon: Double }
    struct Landing: Encodable { let lat: Double; let lon: Double; let minutes: Int }
    /// Gerade gehörte Sonde. `track` = [Breite, Länge, Höhe in m].
    struct Live: Encodable {
        let serial: String; let type: String; let frequency: Double
        let lat: Double?; let lon: Double?; let altitude: Int?; let verticalSpeed: Double?
        let temperature: Double?; let humidity: Double?
        let burst: Bool; let age: Int
        let landing: Landing?
        let track: [[Double]]
    }
    struct List: Encodable {
        let home: Home?
        let groundAltitude: Int
        let live: [Live]
    }
    /// Ein Messpunkt eines Archivflugs (`t` in ms seit 1970).
    struct Sample: Encodable {
        let t: Double
        let lat: Double?; let lon: Double?; let alt: Int?
        let temp: Double?; let hum: Int?
    }
    struct Track: Encodable {
        let serial: String; let type: String
        let start: Double; let end: Double
        let peak: Int?; let burst: Bool; let total: Int
        let points: [Sample]
    }

    /// Seriennummern kommen aus dem Archiv bzw. der Luft – nur `[A-Z0-9]`, 1…16 Zeichen.
    nonisolated static func isValidSerial(_ text: String) -> Bool {
        (1...16).contains(text.unicodeScalars.count)
            && text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Gleichmäßig auf höchstens `limit` Punkte ausdünnen; erster und letzter bleiben.
    nonisolated static func thin<T>(_ items: [T], limit: Int = maxPoints) -> [T] {
        guard items.count > limit, limit > 1 else { return items }
        let step = Double(items.count - 1) / Double(limit - 1)
        return (0..<limit).map { items[Int((Double($0) * step).rounded())] }
    }

    nonisolated private static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
    nonisolated private static func round(_ value: Double?, _ scale: Double) -> Double? {
        value.flatMap { $0.isFinite ? ($0 * scale).rounded() / scale : nil }
    }
    nonisolated private static func int(_ value: Double?) -> Int? {
        value.flatMap { $0.isFinite && abs($0) < 1e7 ? Int($0.rounded()) : nil }
    }

    /// Antwort für `/api/sondes` aus den übergebenen Sonden (rein, prüfbar).
    /// Landeschätzung wie am Mac (`Sonde.landing(groundAltitude:)`, nur im Sinkflug).
    nonisolated static func list(_ sondes: [Sonde], home: GroundStation?, groundAltitude: Double, now: Date = Date()) -> List {
        let groundAltitude = Sonde.clampedGroundAltitude(groundAltitude)
        return List(home: home.map { Home(lat: $0.latitude, lon: $0.longitude) },
             groundAltitude: Int(groundAltitude.rounded()),
             live: sondes.sorted { $0.lastSeen > $1.lastSeen }.map { s in
                 let r = s.latest
                 let landing = s.landing(groundAltitude: groundAltitude).flatMap { l -> Landing? in
                     // Wie `int(_:)` begrenzt: `isFinite` allein ließ Werte über `Int.max` durch.
                     guard let lat = round(l.lat, 1e5), let lon = round(l.lon, 1e5), let minutes = int(l.seconds / 60) else { return nil }
                     return Landing(lat: lat, lon: lon, minutes: minutes)
                 }
                 let track: [[Double]] = thin(s.trail).compactMap { p in
                     guard let lat = round(p.lat, 1e5), let lon = round(p.lon, 1e5), p.alt.isFinite else { return nil }
                     return [lat, lon, p.alt.rounded()]
                 }
                 return Live(serial: s.serial, type: r.model, frequency: (r.frequency / 1e3).rounded() / 1e3,
                             lat: round(r.latitude, 1e5), lon: round(r.longitude, 1e5), altitude: int(r.altitude),
                             verticalSpeed: round(r.verticalSpeed, 10), temperature: round(r.temperature, 10),
                             humidity: round(r.humidity, 1), burst: s.burst,
                             age: max(0, Int(now.timeIntervalSince(s.lastSeen))), landing: landing, track: track)
             })
    }

    /// Bahn eines Archivflugs, ausgedünnt (rein, prüfbar).
    nonisolated static func track(_ flight: SondeFlight) -> Track {
        Track(serial: flight.serial, type: flight.type, start: ms(flight.first), end: ms(flight.last),
              peak: int(flight.peak?.altitude), burst: flight.burst, total: flight.samples.count,
              points: thin(flight.samples).map {
                  Sample(t: ms($0.date), lat: round($0.latitude, 1e5), lon: round($0.longitude, 1e5), alt: int($0.altitude),
                         temp: round($0.temperature, 10), hum: int($0.humidity))
              })
    }

    /// Kürzlich geladene Archivflüge (das Handy fragt die Bahn wiederholt ab).
    private static var trackCache: [String: (date: Date, data: Data)] = [:]

    static func handle(_ query: [String: String]) async -> RemoteHTTPServer.Response {
        guard let serial = query["serial"] else {
            let stored = UserDefaults.standard.object(forKey: "sondeGroundAltitude") as? Double ?? 100
            let list = list(ReceptionPlanner.shared.sonde.sondes, home: ReceptionPlanner.home,
                            groundAltitude: Sonde.clampedGroundAltitude(stored))
            return .json((try? JSONEncoder().encode(list)) ?? Data("{}".utf8))
        }
        guard isValidSerial(serial) else { return .text(400, String(localized: "Ungültige Seriennummer")) }
        if let cached = trackCache[serial], Date().timeIntervalSince(cached.date) < 30 { return .json(cached.data) }
        // Abseits des Main Actor laden: liest alle Protokolle, die die Nummer enthalten.
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let flight = SondeArchive.load(serial: serial) else { return nil }
            return try? JSONEncoder().encode(track(flight))
        }.value
        guard let data else { return .text(404, String(localized: "Flug nicht gefunden")) }
        if trackCache.count > 20 { trackCache.removeAll() }
        trackCache[serial] = (Date(), data)
        return .json(data)
    }
}
