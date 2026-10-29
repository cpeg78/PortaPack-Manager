import Foundation

/// Vorhersage der Sondenaufstiege rund um den eigenen Standort: Startplätze
/// aus SondeHub (`/sites`), Flugbahn je Start aus dem SondeHub-Bahnrechner
/// (Tawhiri, Windmodell GFS). Gefragt werden nur Startplatz und Startzeit –
/// der eigene Standort geht nicht hinaus, die Entfernungen rechnet die App.
enum SondeForecast {
    struct Site: Sendable, Hashable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let burstAltitude: Double
        let frequencyMHz: Double?
        /// `Tag:HH:MM` UTC – Tag 0 = täglich, 1–7 = Montag–Sonntag.
        let times: [String]
    }

    struct Flight: Sendable, Hashable, Identifiable {
        let site: String
        let frequencyMHz: Double?
        let launch: Date
        let closestKm: Double
        let closestAt: Date
        let closestAltitude: Double
        let landingKm: Double
        /// Zeitraum, in dem die Sonde innerhalb der Reichweite und über dem
        /// Funkhorizont fliegt; nil = nie.
        let inRange: ClosedRange<Date>?
        var id: String { site + "\(launch.timeIntervalSince1970)" }
    }

    private static let userAgent = "PortaPackManager/1.0 (+https://github.com/cpeg78)"

    static func fetchSites() async throws -> [Site] {
        var request = URLRequest(url: URL(string: "https://api.v2.sondehub.org/sites")!)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.limitedData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try parseSites(data)
    }

    static func parseSites(_ data: Data) throws -> [Site] {
        guard let all = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return all.compactMap { id, entry -> Site? in
            guard let position = entry["position"] as? [NSNumber], position.count >= 2,
                  let times = entry["times"] as? [String], !times.isEmpty else { return nil }
            // rs_types: ["41", "13"] oder [["41", "402.5"]] – Frequenz nur in der zweiten Form.
            let frequency = (entry["rs_types"] as? [Any])?.lazy
                .compactMap { ($0 as? [Any])?.last as? String }.compactMap(Double.init).first
            return Site(id: id, name: (entry["station_name"] as? String ?? id).replacingOccurrences(of: " (Germany)", with: ""),
                        latitude: position[1].doubleValue, longitude: position[0].doubleValue,
                        altitude: (entry["alt"] as? NSNumber)?.doubleValue ?? 0,
                        burstAltitude: (entry["burst_altitude"] as? NSNumber)?.doubleValue ?? 33_000,
                        frequencyMHz: frequency, times: times)
        }
    }

    /// Starts eines Platzes, deren Aufstieg ins Fenster fällt. Der Termin
    /// (z. B. 12:00) ist die Messzeit; der DWD startet ≈ 75 min vorher –
    /// geschätzt wird deshalb Termin − 75 min, frühestens der Fensterbeginn.
    static func launches(of site: Site, from start: Date, to end: Date) -> [Date] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var result: [Date] = []
        for day in [utc.startOfDay(for: start), utc.startOfDay(for: start).addingTimeInterval(86_400)] {
            let weekday = (utc.component(.weekday, from: day) + 5) % 7 + 1     // Montag = 1
            for entry in site.times {
                let parts = entry.split(separator: ":").compactMap { Int($0) }
                // Werte aus der Antwort erst auf Wochentag 0…7, Stunde 0…23, Minute 0…59
                // prüfen – `parts[1] * 3600` liefe sonst über (Review Y4).
                guard parts.count >= 3, (0...7).contains(parts[0]), (0...23).contains(parts[1]), (0...59).contains(parts[2]),
                      parts[0] == 0 || parts[0] == weekday else { continue }
                let nominal = day.addingTimeInterval(Double(parts[1] * 3600 + parts[2] * 60))
                let launch = max(nominal.addingTimeInterval(-75 * 60), start)
                if nominal > start, launch < end, !result.contains(launch) { result.append(launch) }
            }
        }
        return result
    }

    static func predict(site: Site, launch: Date, home: GroundStation, rangeKm: Double) async throws -> Flight {
        var components = URLComponents(string: "https://api.v2.sondehub.org/tawhiri")!
        var longitude = site.longitude.truncatingRemainder(dividingBy: 360)
        if longitude < 0 { longitude += 360 }
        components.queryItems = [
            .init(name: "launch_latitude", value: String(site.latitude)),
            .init(name: "launch_longitude", value: String(longitude)),
            .init(name: "launch_altitude", value: String(site.altitude)),
            .init(name: "launch_datetime", value: ISOTime.string(launch)),
            .init(name: "ascent_rate", value: "5"),
            .init(name: "burst_altitude", value: String(site.burstAltitude)),
            .init(name: "descent_rate", value: "5"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.limitedData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try flight(from: data, site: site, launch: launch, home: home, rangeKm: rangeKm)
    }

    static func flight(from data: Data, site: Site, launch: Date, home: GroundStation, rangeKm: Double) throws -> Flight {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stages = root["prediction"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var points: [(date: Date, km: Double, altitude: Double, visible: Bool)] = []
        for stage in stages {
            for point in stage["trajectory"] as? [[String: Any]] ?? [] {
                guard let lat = (point["latitude"] as? NSNumber)?.doubleValue,
                      var lon = (point["longitude"] as? NSNumber)?.doubleValue,
                      let alt = (point["altitude"] as? NSNumber)?.doubleValue,
                      let text = point["datetime"] as? String,
                      let date = ISOTime.date(text) else { continue }
                if lon > 180 { lon -= 360 }
                let km = SondeHubTraffic.haversineKm(home.latitude, home.longitude, lat, lon)
                let horizon = 3.57 * (max(alt, 0).squareRoot() + 10.0.squareRoot())
                points.append((date, km, alt, km <= min(rangeKm, horizon)))
            }
        }
        guard let closest = points.min(by: { $0.km < $1.km }), let last = points.last else { throw URLError(.cannotParseResponse) }
        let visible = points.filter(\.visible)
        return Flight(site: site.name, frequencyMHz: site.frequencyMHz, launch: launch,
                      closestKm: closest.km, closestAt: closest.date, closestAltitude: closest.altitude,
                      landingKm: last.km,
                      inRange: visible.first.flatMap { first in visible.last.map { first.date...$0.date } })
    }
}
