import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reiter „Wetter“ des Fernzugriffs: Empfangsplan lesen und schalten,
/// empfangene METEOR-Bilder auflisten und ausliefern.
@MainActor
enum RemoteWeather {
    struct Plan: Encodable {
        struct Pass: Encodable {
            let satellite: String
            let start: Double, end: Double   // ms seit 1970 (JavaScript-Zeit)
            let maxElevation: Int
            let daylight: Bool
            let planned: Bool
            let from: String, to: String
        }
        struct Window: Encodable { let start: Double, end: Double }
        struct Forecast: Encodable {
            let site: String; let frequency: Double?; let launch: Double
            let closestKm: Int; let closestAt: Double; let closestAltitude: Int; let landingKm: Int
            let from: Double?; let to: Double?
        }
        struct SondeGain: Encodable {
            let lna: Int; let vga: Int; let auto: Bool; let note: String?
            let rms: Double?; let clipped: Double?
        }
        struct Entry: Encodable { let date: Double; let title: String; let result: String }
        /// Gerade gehörte Sonde (live).
        struct Balloon: Encodable {
            let serial: String; let type: String; let frequency: Double
            let altitude: Int?; let verticalSpeed: Double?; let temperature: Double?; let humidity: Double?
            let distanceKm: Double?; let direction: String?; let burst: Bool; let age: Int
        }
        /// Abgeschlossener oder laufender Flug aus dem Archiv.
        struct Flight: Encodable {
            let serial: String; let type: String; let start: Double; let end: Double
            let peak: Int?; let burst: Bool; let distanceKm: Int?; let minTemperature: Double?; let samples: Int
        }
        struct Image: Encodable { let name: String; let date: Double; let pass: String; let composite: String }

        let autoMeteor: Bool
        let autoSonde: Bool
        let autoAmateur: Bool
        let minElevation: Int
        let status: String?
        let homeSet: Bool
        let tleError: String?
        let passes: [Pass]
        let sondeWindows: [Window]
        let sondeForecast: [Forecast]
        let sondeGain: SondeGain
        let history: [Entry]
        let images: [Image]
        let sondeFiles: Int
        let balloons: [Balloon]
        let flights: [Flight]
    }

    /// Archiv-Zusammenfassung, höchstens jede Minute neu gelesen (die Seite fragt
    /// den Plan alle paar Sekunden ab; gelesen werden nur die jüngsten 20 Flüge).
    private static var flightCache: (date: Date, flights: [Plan.Flight], windows: Int)?
    private static var flightLoading = false

    private static func cachedFlights() -> [Plan.Flight] {
        if (flightCache.map { Date().timeIntervalSince($0.date) > 60 } ?? true), !flightLoading {
            flightLoading = true
            Task {
                let (flights, windows) = await Task.detached(priority: .utility) {
                    (SondeArchive.recent(limit: 20), SondeArchive.windowCount())
                }.value
                func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
                flightCache = (Date(), flights.prefix(20).map {
                    Plan.Flight(serial: $0.serial, type: $0.type, start: ms($0.first), end: ms($0.last),
                                peak: $0.peak?.altitude.map { Int($0) }, burst: $0.burst,
                                distanceKm: $0.distanceKm.map { Int($0.rounded()) }, minTemperature: $0.minTemperature,
                                samples: $0.samples.count)
                }, windows)
                flightLoading = false
            }
        }
        return flightCache?.flights ?? []
    }

    /// Zahl aus einem Abfrageparameter – nur endliche Werte. `Double("nan")` ist NaN,
    /// und `min(max(NaN, 10), 70)` bleibt NaN: gespeichert, ließ das die App bei jedem
    /// `Int(minElevation)` abstürzen (Review 28.10.2026, W1).
    nonisolated static func finite(_ text: String?) -> Double? {
        text.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }

    /// Wendet `meteor=0|1`, `sonde=0|1`, `minel=<Grad>` und die Sondenverstärkung
    /// `slna=` (0–40, Schritt 8), `svga=` (0–62, gerade), `sauto=0|1` an und liefert den Plan.
    static func plan(_ query: [String: String]) -> Data {
        let planner = ReceptionPlanner.shared
        // Laufende Aufnahme überspringen (der Plan beendet sie im Hintergrund).
        if query["skip"] == "1" { Task { await planner.skipActive() } }
        if let value = query["meteor"] { planner.autoMeteor = value == "1" }
        if let value = query["sonde"] { planner.autoSonde = value == "1" }
        if let value = query["amateur"] { planner.autoAmateur = value == "1" }
        if let value = finite(query["minel"]) { planner.minElevation = min(max(value, 10), 70) }
        let sonde = planner.sonde
        if let value = finite(query["slna"]) { sonde.lnaGain = min(max((value / 8).rounded() * 8, 0), 40) }
        if let value = finite(query["svga"]) { sonde.vgaGain = min(max((value / 2).rounded() * 2, 0), 62) }
        if let value = query["sauto"] { sonde.autoBackoff = value == "1" }
        let levels = sonde.inputLevels
        func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        let plan = Plan(
            autoMeteor: planner.autoMeteor, autoSonde: planner.autoSonde, autoAmateur: planner.autoAmateur,
            minElevation: Int(planner.minElevation), status: planner.status,
            homeSet: ReceptionPlanner.home != nil, tleError: planner.tleError,
            passes: planner.passes.map {
                .init(satellite: $0.satellite.name, start: ms($0.start), end: ms($0.end),
                      maxElevation: Int($0.maxElevation.rounded()), daylight: $0.daylight,
                      planned: planner.isPlanned($0) && !planner.isSkipped(ReceptionPlanner.jobID(pass: $0)),
                      from: GeoMath.compass($0.startAzimuth), to: GeoMath.compass($0.endAzimuth))
            },
            sondeWindows: planner.sondeWindows.map { .init(start: ms($0.start), end: ms($0.end)) },
            sondeForecast: planner.sondeForecast.map {
                .init(site: $0.site, frequency: $0.frequencyMHz, launch: ms($0.launch), closestKm: Int($0.closestKm),
                      closestAt: ms($0.closestAt), closestAltitude: Int($0.closestAltitude), landingKm: Int($0.landingKm),
                      from: $0.inRange.map { ms($0.lowerBound) }, to: $0.inRange.map { ms($0.upperBound) })
            },
            sondeGain: .init(lna: Int(sonde.lnaGain), vga: Int(sonde.vgaGain), auto: sonde.autoBackoff, note: sonde.gainNote,
                             rms: levels.map { ($0.rmsDBFS * 10).rounded() / 10 }, clipped: levels.map(\.clipped)),
            history: planner.history.prefix(30).map { .init(date: ms($0.date), title: $0.title, result: $0.result) },
            images: images().map { .init(name: $0.name, date: ms($0.date), pass: $0.pass, composite: $0.composite) },
            sondeFiles: flightCache?.windows ?? 0,
            balloons: sonde.sondes.sorted { $0.lastSeen > $1.lastSeen }.map { b in
                let home = ReceptionPlanner.home
                var km: Double?, dir: String?
                if let home, let lat = b.latitude, let lon = b.longitude {
                    km = (GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon) * 10).rounded() / 10
                    dir = GeoMath.compass(GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon))
                }
                return .init(serial: b.serial, type: b.latest.model, frequency: b.latest.frequency / 1e6,
                             altitude: b.latest.altitude.map { Int($0) }, verticalSpeed: b.latest.verticalSpeed,
                             temperature: b.latest.temperature, humidity: b.latest.humidity,
                             distanceKm: km, direction: dir, burst: b.burst, age: Int(Date().timeIntervalSince(b.lastSeen)))
            },
            flights: cachedFlights())
        return (try? JSONEncoder().encode(plan)) ?? Data("{}".utf8)
    }

    /// Ordner eines Bildes: SSTV-Bilder (ISS, Amateurfunksatelliten) liegen
    /// getrennt von den METEOR-Bildern.
    static func folder(for name: String) -> URL {
        name.hasPrefix("SSTV_") ? SSTVStore.folder : MeteorPNG.folder
    }

    /// PNGs beider Bilderordner, neueste zuerst. Namen `METEOR_<datum>_<zeit>_<komposit>.png`
    /// bzw. `SSTV_<datum>_<zeit>_<modus>[_teilweise].png`.
    static func images(limit: Int = 120) -> [(name: String, date: Date, pass: String, composite: String)] {
        let names = [MeteorPNG.folder, SSTVStore.folder].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { (folder, $0) }
        }
        return names.filter { $0.1.hasSuffix(".png") }.compactMap { folder, name in
            let url = folder.appendingPathComponent(name)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            let parts = name.dropLast(4).split(separator: "_")
            let pass = parts.count >= 3 ? parts[0..<3].joined(separator: "_") : String(name.dropLast(4))
            var raw = parts.count > 3 ? parts[3...].joined(separator: "_") : ""
            if name.hasPrefix("SSTV_") {
                raw = "SSTV " + raw.replacingOccurrences(of: "_teilweise", with: " " + String(localized: "(teilweise)", comment: "SSTV-Bild unvollständig"))
                return (name, date, pass, raw)
            }
            let composite = MeteorComposite(rawValue: raw)?.title ?? raw
            return (name, date, pass, composite)
        }
        .sorted { $0.date > $1.date }
        .prefix(limit).map { $0 }
    }

    private static var thumbnails: [String: Data] = [:]

    /// Ein Bild aus dem Bilderordner; mit `w` als verkleinertes JPEG.
    static func image(name: String?, width: Int?) -> RemoteHTTPServer.Response {
        guard let name, name.hasSuffix(".png"), !name.contains("/"), !name.contains(".."),
              name.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return .text(400, String(localized: "Ungültiger Name")) }
        let url = folder(for: name).appendingPathComponent(name)
        guard let width else {
            guard let data = try? Data(contentsOf: url) else { return .text(404, String(localized: "Nicht gefunden")) }
            return .data(status: 200, contentType: "image/png", body: data)
        }
        // Nur drei Stufen: je Bild höchstens drei Verkleinerungen (auf dem Main
        // Actor) – beliebige `w` hätten den Zwischenspeicher immer neu gefüllt.
        let size = [360, 800, 1600].first { $0 >= width } ?? 1600
        let key = "\(name)@\(size)"
        if let cached = thumbnails[key] { return .data(status: 200, contentType: "image/jpeg", body: cached) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
              ] as CFDictionary) else { return .text(404, String(localized: "Nicht gefunden")) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return .text(500, "")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return .text(500, "") }
        if thumbnails.count > 300 { thumbnails.removeAll() }
        thumbnails[key] = data as Data
        return .data(status: 200, contentType: "image/jpeg", body: data as Data)
    }
}
