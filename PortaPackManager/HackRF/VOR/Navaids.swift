import Foundation
import Observation

/// Ein Funkfeuer aus der OurAirports-Datenbank (`navaids.csv`).
struct Navaid: Identifiable, Hashable, Sendable {
    var ident: String
    var name: String
    /// VOR, VOR-DME, VORTAC, DVOR, DVOR-DME, DVORTAC …
    var type: String
    var frequencyKHz: Int
    var latitude: Double
    var longitude: Double
    var country: String
    /// Ausrichtung der Station auf magnetisch Nord in Grad (Ost positiv) –
    /// `slaved_variation_deg`, ersatzweise die örtliche Missweisung.
    var declination: Double?

    var id: String { "\(ident)-\(frequencyKHz)-\(country)" }
    var mhz: Double { Double(frequencyKHz) / 1000 }
    var isDoppler: Bool { type.uppercased().hasPrefix("DVOR") }

    /// Rechtweisendes Radial zu einem missweisenden (Ost-Missweisung addieren).
    func trueRadial(_ magnetic: Double) -> Double {
        GeoNav.normalize(magnetic + (declination ?? 0))
    }
}

/// CSV der OurAirports-Funkfeuer lesen (echtes CSV: Anführungszeichen, Kommas im Feld).
enum NavaidCSV {
    /// Zerlegt CSV-Text in Zeilen und Felder.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var lookahead: Unicode.Scalar?
        while let c = lookahead ?? iterator.next() {
            lookahead = nil
            if quoted {
                if c == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.unicodeScalars.append("\"") }
                    else { quoted = false; lookahead = next }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r": break
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Nur VOR-Arten im VOR-Band 108,00–117,95 MHz. Spalten über die Kopfzeile.
    static func parse(_ text: String) -> [Navaid] {
        let all = rows(text)
        guard let header = all.first else { return [] }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let ident = column("ident"), let type = column("type"), let freq = column("frequency_khz"),
              let lat = column("latitude_deg"), let lon = column("longitude_deg") else { return [] }
        let name = column("name"), country = column("iso_country")
        let slaved = column("slaved_variation_deg"), variation = column("magnetic_variation_deg")
        return all.dropFirst().compactMap { row -> Navaid? in
            func value(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let v = row[index].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let t = value(type), t.uppercased().contains("VOR"),
                  // Erst Bereich prüfen, dann wandeln: nan/inf/1e400 brächten `Int(_:)` zum Absturz (Review Y2).
                  let khzValue = value(freq).flatMap({ Double($0) }), khzValue.isFinite,
                  (108_000...117_950).contains(khzValue.rounded()),
                  let la = value(lat).flatMap(Double.init), la.isFinite, (-90...90).contains(la),
                  let lo = value(lon).flatMap(Double.init), lo.isFinite, (-180...180).contains(lo),
                  let id = value(ident) else { return nil }
            let khz = Int(khzValue.rounded())
            let declination = (value(slaved).flatMap(Double.init) ?? value(variation).flatMap(Double.init))
                .flatMap { $0.isFinite && abs($0) <= 180 ? $0 : nil }
            return Navaid(ident: id, name: value(name) ?? "", type: t, frequencyKHz: khz,
                          latitude: la, longitude: lo, country: value(country) ?? "", declination: declination)
        }
    }

    /// Die nächsten Funkfeuer zu einem Ort, nach Entfernung.
    static func nearest(_ navaids: [Navaid], lat: Double, lon: Double, count: Int, maxKm: Double = 400) -> [(navaid: Navaid, km: Double)] {
        navaids.map { ($0, GeoMath.distanceKm(lat1: lat, lon1: lon, lat2: $0.latitude, lon2: $0.longitude)) }
            .filter { $0.1 <= maxKm }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map { (navaid: $0.0, km: $0.1) }
    }
}

/// Funkfeuer-Datenbank: einmal von OurAirports laden, danach offline.
@MainActor
@Observable
final class NavaidDatabase {
    static let shared = NavaidDatabase()

    static let sourceURL = URL(string: "https://davidmegginson.github.io/ourairports-data/navaids.csv")!
    static let userAgent = "PortaPackManager/1.0 (+https://github.com/cpeg78)"
    static let fileURL = AppFiles.cacheFile("navaids.csv")

    private(set) var navaids: [Navaid] = []
    private(set) var updated: Date?
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var loaded = false

    /// Liest die zwischengespeicherte Datei (einmal je Programmlauf).
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        loading = true
        Task {
            let result = await Task.detached { () -> [Navaid] in
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
                return NavaidCSV.parse(text)
            }.value
            self.navaids = result
            self.updated = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            self.loading = false
        }
    }

    /// Lädt `navaids.csv` (≈ 3 MB) neu. Gesendet wird nur die Anfrage selbst –
    /// kein Standort.
    func download() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.sourceURL)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.limitedData(for: request, limit: 30_000_000)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let parsed = await Task.detached { () -> [Navaid] in
                NavaidCSV.parse(String(decoding: data, as: UTF8.self))
            }.value
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            try data.write(to: Self.fileURL, options: .atomic)
            navaids = parsed
            updated = Date()
            loaded = true
        } catch {
            self.error = String(localized: "Laden fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

/// Geodätische Hilfen für Radiale und Kreuzpeilung (Kugel, R = 6371 km).
enum GeoNav {
    static let earthRadiusKm = 6371.0088

    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Kleinster Winkelabstand zweier Richtungen (0…180°).
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a - b))
        return min(d, 360 - d)
    }

    /// Punkt in `km` Entfernung unter der Peilung `bearing` (Grad, rechtweisend).
    static func destination(lat: Double, lon: Double, bearing: Double, km: Double) -> (lat: Double, lon: Double) {
        let φ1 = lat * .pi / 180, λ1 = lon * .pi / 180, θ = bearing * .pi / 180
        let δ = km / earthRadiusKm
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return (φ2 * 180 / .pi, normalize(λ2 * 180 / .pi + 540) - 180)
    }

    /// Schnittpunkt zweier Großkreise, die von zwei Punkten unter den Peilungen
    /// `bearing1`/`bearing2` ausgehen (Radiale von zwei Funkfeuern, rechtweisend).
    /// `nil`, wenn die Linien (fast) parallel laufen oder sich erst auf der
    /// Gegenseite der Erde treffen.
    static func intersection(lat1: Double, lon1: Double, bearing1: Double,
                             lat2: Double, lon2: Double, bearing2: Double) -> (lat: Double, lon: Double)? {
        let φ1 = lat1 * .pi / 180, λ1 = lon1 * .pi / 180
        let φ2 = lat2 * .pi / 180, λ2 = lon2 * .pi / 180
        let θ13 = bearing1 * .pi / 180, θ23 = bearing2 * .pi / 180
        let Δφ = φ2 - φ1, Δλ = λ2 - λ1
        let δ12 = 2 * asin((sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)).squareRoot())
        guard δ12 > 1e-9 else { return nil }
        let clamp = { (x: Double) in max(-1, min(1, x)) }
        let θa = acos(clamp((sin(φ2) - sin(φ1) * cos(δ12)) / (sin(δ12) * cos(φ1))))
        let θb = acos(clamp((sin(φ1) - sin(φ2) * cos(δ12)) / (sin(δ12) * cos(φ2))))
        let θ12 = sin(Δλ) > 0 ? θa : 2 * .pi - θa
        let θ21 = sin(Δλ) > 0 ? 2 * .pi - θb : θb
        let α1 = θ13 - θ12, α2 = θ21 - θ23
        if sin(α1) == 0 && sin(α2) == 0 { return nil }
        if sin(α1) * sin(α2) < 0 { return nil }
        let α3 = acos(clamp(-cos(α1) * cos(α2) + sin(α1) * sin(α2) * cos(δ12)))
        let δ13 = atan2(sin(δ12) * sin(α1) * sin(α2), cos(α2) + cos(α1) * cos(α3))
        let φ3 = asin(clamp(sin(φ1) * cos(δ13) + cos(φ1) * sin(δ13) * cos(θ13)))
        let Δλ13 = atan2(sin(θ13) * sin(δ13) * cos(φ1), cos(δ13) - sin(φ1) * sin(φ3))
        let λ3 = λ1 + Δλ13
        return (φ3 * 180 / .pi, normalize(λ3 * 180 / .pi + 540) - 180)
    }

    /// Schnittwinkel der beiden Standlinien am Schnittpunkt (0…90°): unter
    /// ≈ 30° wird die Kreuzpeilung ungenau – 1° Fehler verschiebt den Punkt weit.
    static func cutAngle(fixLat: Double, fixLon: Double, lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let b1 = GeoMath.bearingDegrees(lat1: fixLat, lon1: fixLon, lat2: lat1, lon2: lon1)
        let b2 = GeoMath.bearingDegrees(lat1: fixLat, lon1: fixLon, lat2: lat2, lon2: lon2)
        let d = angleDifference(b1, b2)
        return d > 90 ? 180 - d : d
    }
}
