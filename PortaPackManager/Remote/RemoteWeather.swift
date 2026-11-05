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
            /// Termin-Kennung (`Job.id`) für `skipid=`; `wanted`: erfüllt die Bedingungen
            /// (Mindesthöhe), `skipped`: von Hand ausgelassen, `active`: läuft gerade.
            let id: String
            let wanted: Bool
            let skipped: Bool
            let active: Bool
        }
        struct Window: Encodable {
            let start: Double, end: Double
            let id: String
            let skipped: Bool
            let active: Bool
            /// Fenster offen, aber der Plan wartet (keine Sonde in Reichweite bzw. Probepause).
            let waiting: Bool
        }
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
            /// Nur wenn die Sonde sie sendet: Wind (m/s, aus Richtung), Druck (hPa),
            /// GPS-Satelliten, Abschalt-Countdown (s), Zusatzinstrument (Kennung,
            /// Zellstrom µA, Pumpe °C).
            var wind: Double?; var windFrom: String?
            var pressure: Double?; var sats: Int?; var countdown: Int?
            var instrument: Int?; var ozone: Double?; var pumpTemp: Double?
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
        /// ISS und Amateurfunksatelliten (gewählte Satelliten), mit eigener Mindesthöhe.
        let amateurPasses: [Pass]
        let amateurMinElevation: Int
        let sondeWindows: [Window]
        let sondeForecast: [Forecast]
        /// Beginn des Sondenfensters, für das `sondeForecast` gerechnet wurde.
        let sondeForecastFor: Double?
        /// Fenster starten nur, wenn SondeHub eine Sonde im Umkreis meldet.
        let sondeOnlyInRange: Bool
        let sondeRangeKm: Int
        /// Warum ein offenes Sondenfenster gerade nicht empfängt (`ReceptionPlanner.waitingNote`).
        let waiting: String?
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

    /// Wendet `skipid=<Termin>&on=1|0` (einzelnen Termin auslassen bzw. wieder
    /// einplanen, wie der Schalter in der Planliste am Mac), `meteor=0|1`, `sonde=0|1`, `minel=<Grad>` und die Sondenverstärkung
    /// `slna=` (0–40, Schritt 8), `svga=` (0–62, gerade), `sauto=0|1` an und liefert den Plan.
    static func plan(_ query: [String: String]) -> Data {
        let planner = ReceptionPlanner.shared
        // Laufende Aufnahme überspringen (der Plan beendet sie im Hintergrund).
        if query["skip"] == "1" { Task { await planner.skipActive() } }
        if let id = query["skipid"] {
            // Auch ISS-/Amateurfunk-Termine („amateur-…“, Nutzerentscheid 02.11.2026).
            let end = planner.sondeWindows.first { ReceptionPlanner.jobID(window: $0) == id }?.end
                ?? planner.passes.first { ReceptionPlanner.jobID(pass: $0) == id }?.end
                ?? planner.amateurPasses.first { ReceptionPlanner.jobID(amateur: $0) == id }?.end
            if let end { planner.setSkipped(id, end: end, query["on"] != "0") }
        }
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
                pass($0, id: ReceptionPlanner.jobID(pass: $0), wanted: planner.isPlanned($0), planner: planner)
            },
            amateurPasses: planner.amateurPasses.map {
                pass($0, id: ReceptionPlanner.jobID(amateur: $0), wanted: planner.isPlannedAmateur($0), planner: planner)
            },
            amateurMinElevation: Int(planner.amateurMinElevation),
            sondeWindows: planner.sondeWindows.map {
                let id = ReceptionPlanner.jobID(window: $0)
                let open = $0.start <= Date() && Date() < $0.end
                return .init(start: ms($0.start), end: ms($0.end), id: id,
                             skipped: planner.isSkipped(id), active: planner.isActive(id),
                             waiting: open && planner.waitingNote != nil && !planner.isSkipped(id) && !planner.isActive(id))
            },
            sondeForecast: planner.sondeForecast.map {
                .init(site: $0.site, frequency: $0.frequencyMHz, launch: ms($0.launch), closestKm: Int($0.closestKm),
                      closestAt: ms($0.closestAt), closestAltitude: Int($0.closestAltitude), landingKm: Int($0.landingKm),
                      from: $0.inRange.map { ms($0.lowerBound) }, to: $0.inRange.map { ms($0.upperBound) })
            },
            sondeForecastFor: planner.sondeForecastWindow.map(ms),
            sondeOnlyInRange: planner.sondeOnlyInRange, sondeRangeKm: Int(planner.sondeRangeKm),
            waiting: planner.waitingNote,
            sondeGain: .init(lna: Int(sonde.lnaGain), vga: Int(sonde.vgaGain), auto: sonde.autoBackoff, note: sonde.gainNote,
                             rms: levels.map { ($0.rmsDBFS * 10).rounded() / 10 }, clipped: levels.map(\.clipped)),
            history: planner.history.prefix(30).map { .init(date: ms($0.date), title: $0.title, result: $0.result) },
            images: cachedImages().map { .init(name: $0.name, date: ms($0.date), pass: $0.pass, composite: $0.composite) },
            sondeFiles: flightCache?.windows ?? 0,
            balloons: sonde.sondes.sorted { $0.lastSeen > $1.lastSeen }.map { b in
                let home = ReceptionPlanner.home
                var km: Double?, dir: String?
                if let home, let lat = b.latitude, let lon = b.longitude {
                    km = (GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon) * 10).rounded() / 10
                    dir = GeoMath.compass(GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon))
                }
                let r = b.latest, instrument = r.instruments.first
                return .init(serial: b.serial, type: r.configuration.subtype ?? r.model, frequency: r.frequency / 1e6,
                             altitude: r.altitude.map { Int($0) }, verticalSpeed: r.verticalSpeed,
                             temperature: r.temperature, humidity: r.humidity,
                             distanceKm: km, direction: dir, burst: b.burst, age: Int(Date().timeIntervalSince(b.lastSeen)),
                             wind: r.groundSpeed,
                             windFrom: r.groundSpeed.flatMap { $0 >= 1 ? r.heading.map { GeoMath.compass(SondeSample.windFrom(heading: $0)) } : nil },
                             pressure: r.pressure, sats: r.satellites, countdown: r.configuration.activeCountdown,
                             instrument: instrument?.id, ozone: instrument?.cellCurrent, pumpTemp: instrument?.pumpTemperature)
            },
            flights: cachedFlights())
        return (try? JSONEncoder().encode(plan)) ?? Data("{}".utf8)
    }

    private static func pass(_ pass: SatellitePass, id: String, wanted: Bool, planner: ReceptionPlanner) -> Plan.Pass {
        func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        return .init(satellite: pass.satellite.name, start: ms(pass.start), end: ms(pass.end),
                     maxElevation: Int(pass.maxElevation.rounded()), daylight: pass.daylight,
                     planned: wanted && !planner.isSkipped(id),
                     from: GeoMath.compass(pass.startAzimuth), to: GeoMath.compass(pass.endAzimuth),
                     id: id, wanted: wanted, skipped: planner.isSkipped(id), active: planner.isActive(id))
    }

    /// Ordner eines Bildes: SSTV-Bilder (ISS, Amateurfunksatelliten) liegen
    /// getrennt von den METEOR-Bildern.
    static func folder(for name: String) -> URL {
        name.hasPrefix("SSTV_") ? SSTVStore.folder : MeteorPNG.folder
    }

    private static var imageCache: (date: Date, images: [(name: String, date: Date, pass: String, composite: String)])?
    private static var imageLoading = false

    /// `images()` höchstens einmal je Minute, abseits des Main Actors – zwei
    /// Ordner listen und je PNG `stat` je `/api/plan` hingen sonst an ihm (Review 05.11.2026).
    private static func cachedImages() -> [(name: String, date: Date, pass: String, composite: String)] {
        if (imageCache.map { Date().timeIntervalSince($0.date) > 60 } ?? true), !imageLoading {
            imageLoading = true
            Task {
                let list = await Task.detached(priority: .utility) { images() }.value
                imageCache = (Date(), list)
                imageLoading = false
            }
        }
        return imageCache?.images ?? []
    }

    /// PNGs beider Bilderordner, neueste zuerst. Namen `METEOR_<datum>_<zeit>_<komposit>.png`
    /// bzw. `SSTV_<datum>_<zeit>_<modus>[_teilweise].png`.
    nonisolated static func images(limit: Int = 120) -> [(name: String, date: Date, pass: String, composite: String)] {
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
    /// Einfügereihenfolge für die Byte-Grenze (älteste zuerst hinaus).
    private static var thumbnailOrder: [String] = []
    private static var thumbnailBytes = 0
    static let thumbnailLimitBytes = 32 * 1024 * 1024

    /// Ein Bild aus dem Bilderordner; mit `w` als verkleinertes JPEG. Lesen und
    /// Verkleinern laufen in einer abgelösten Aufgabe wie bei `/occupancy.png` –
    /// METEOR-Bilder sind mehrere MB groß, auf dem Main Actor stockte dabei die
    /// Oberfläche (Review 01.11.2026).
    static func image(name: String?, width: Int?) async -> RemoteHTTPServer.Response {
        guard let name, name.hasSuffix(".png"), !name.contains("/"), !name.contains(".."),
              name.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return .text(400, String(localized: "Ungültiger Name")) }
        let url = folder(for: name).appendingPathComponent(name)
        let notFound = String(localized: "Nicht gefunden")
        guard let width else {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let data else { return .text(404, notFound) }
            return .data(status: 200, contentType: "image/png", body: data)
        }
        // Nur drei Stufen: je Bild höchstens drei Verkleinerungen – beliebige `w`
        // hätten den Zwischenspeicher immer neu gefüllt.
        let size = [360, 800, 1600].first { $0 >= width } ?? 1600
        let key = "\(name)@\(size)"
        if let cached = thumbnails[key] { return .data(status: 200, contentType: "image/jpeg", body: cached) }
        let data = await Task.detached(priority: .utility) { thumbnail(of: url, size: size) }.value
        guard let data else { return .text(404, notFound) }
        // Nach Bytes begrenzen, nicht nach Anzahl: 300 Komposite à 1600 px wären
        // einige hundert MB (Review 05.11.2026).
        thumbnails[key] = data
        thumbnailOrder.append(key)
        thumbnailBytes += data.count
        while thumbnailBytes > Self.thumbnailLimitBytes, let oldest = thumbnailOrder.first {
            thumbnailOrder.removeFirst()
            thumbnailBytes -= thumbnails.removeValue(forKey: oldest)?.count ?? 0
        }
        return .data(status: 200, contentType: "image/jpeg", body: data)
    }

    /// Verkleinertes JPEG (längste Seite `size`); `nil`, wenn die Datei fehlt oder nicht lesbar ist.
    nonisolated static func thumbnail(of url: URL, size: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
