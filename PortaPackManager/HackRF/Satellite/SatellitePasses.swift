import Foundation

/// Wettersatelliten, für die der Empfangsplan Überflüge rechnet.
struct WeatherSatellite: Identifiable, Sendable, Hashable {
    let id: Int            // NORAD-Katalognummer
    let name: String
    let frequency: Double  // Hz

    /// Stand Oktober 2026 senden nur METEOR-M2-3 und M2-4 LRPT, beide auf
    /// 137,9 MHz. Die NOAA-APT-Satelliten sind seit 2025 abgeschaltet.
    static let all = [
        WeatherSatellite(id: 57166, name: "METEOR-M2-3", frequency: 137_900_000),
        WeatherSatellite(id: 59051, name: "METEOR-M2-4", frequency: 137_900_000),
    ]
}

/// Ein Überflug über dem Beobachtungsort.
struct SatellitePass: Identifiable, Sendable, Hashable {
    let satellite: WeatherSatellite
    let start: Date          // Aufgang (0°)
    let end: Date            // Untergang (0°)
    let culmination: Date
    let maxElevation: Double // Grad
    let startAzimuth: Double
    let endAzimuth: Double
    /// Sonnenhöhe am Ort zur Kulmination – darüber gibt es sichtbare Kanäle.
    let sunElevation: Double

    var id: String { "\(satellite.id)-\(Int(start.timeIntervalSince1970))" }
    var daylight: Bool { sunElevation > -3 }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum PassPredictor {
    /// Überflüge im Zeitraum, deren Gipfel mindestens `minElevation` erreicht.
    /// Grob in 30-s-Schritten, Auf-/Untergang per Bisektion auf 1 s genau.
    static func passes(_ satellite: WeatherSatellite, tle: TLE, station: GroundStation,
                       from start: Date, hours: Double, minElevation: Double = 0) -> [SatellitePass] {
        guard let sgp4 = try? SGP4(tle) else { return [] }
        func elevation(_ date: Date) -> Double {
            guard let state = try? sgp4.propagate(to: date) else { return -90 }
            return station.lookAngles(teme: state.position, date: date).elevation
        }
        func azimuth(_ date: Date) -> Double {
            guard let state = try? sgp4.propagate(to: date) else { return 0 }
            return station.lookAngles(teme: state.position, date: date).azimuth
        }
        func crossing(_ below: Date, _ above: Date) -> Date {
            var lo = below, hi = above
            while hi.timeIntervalSince(lo) > 1 {
                let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                if elevation(mid) > 0 { hi = mid } else { lo = mid }
            }
            return hi
        }
        var result: [SatellitePass] = []
        let step: TimeInterval = 30
        let stop = start.addingTimeInterval(hours * 3600)
        var t = start
        var previous = elevation(t)
        // Läuft schon ein Überflug, den Aufgang rückwärts suchen.
        var rise: Date? = nil
        if previous > 0 {
            var back = t
            while elevation(back) > 0, start.timeIntervalSince(back) < 1200 { back.addTimeInterval(-step) }
            rise = crossing(back, back.addingTimeInterval(step))
        }
        while t < stop {
            let next = t.addingTimeInterval(step)
            let e = elevation(next)
            if previous <= 0, e > 0 { rise = crossing(t, next) }
            if previous > 0, e <= 0, let r = rise {
                // Untergang: Bisektion umgekehrt (oben → unten).
                var lo = t, hi = next
                while hi.timeIntervalSince(lo) > 1 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    if elevation(mid) > 0 { lo = mid } else { hi = mid }
                }
                let set = lo
                var best = (elevation: -90.0, date: r)
                var s = r
                while s <= set {
                    let el = elevation(s)
                    if el > best.elevation { best = (el, s) }
                    s.addTimeInterval(5)
                }
                if best.elevation >= minElevation {
                    result.append(SatellitePass(satellite: satellite, start: r, end: set, culmination: best.date,
                                                maxElevation: best.elevation, startAzimuth: azimuth(r), endAzimuth: azimuth(set),
                                                sunElevation: station.sunElevation(at: best.date)))
                }
                rise = nil
            }
            previous = e
            t = next
        }
        return result
    }
}

/// Bahndaten (TLE) von CelesTrak, zwischengespeichert im Cache-Ordner (`AppFiles`).
enum TLEStore {
    static var fileURL: URL {
        AppFiles.cacheFile("Bahndaten.tle")
    }

    /// Gespeicherte Bahndaten und ihr Abrufzeitpunkt.
    static func load() -> (tles: [Int: TLE], fetched: Date?) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return ([:], nil) }
        let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (Dictionary(TLE.parse(text).map { ($0.catalogNumber, $0) }, uniquingKeysWith: { $1 }), date)
    }

    /// Holt aktuelle Bahndaten (nur die Katalognummern gehen an CelesTrak).
    static func fetch(_ satellites: [WeatherSatellite]) async throws -> [Int: TLE] {
        var text = ""
        for satellite in satellites {
            let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(satellite.id)&FORMAT=TLE")!
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("PortaPackManager (+https://github.com/cpeg78)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.limitedData(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            text += String(decoding: data, as: UTF8.self) + "\n"
        }
        let tles = TLE.parse(text)
        guard !tles.isEmpty else { throw URLError(.cannotParseResponse) }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return Dictionary(tles.map { ($0.catalogNumber, $0) }, uniquingKeysWith: { $1 })
    }
}
