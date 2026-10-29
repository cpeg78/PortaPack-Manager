import Foundation

/// Betriebsart eines Satellitenkanals.
enum AmateurMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case sstv
    case afsk1200
    case g3ruh9600

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sstv: "SSTV (FM)"
        case .afsk1200: "AX.25 1200 Bd AFSK"
        case .g3ruh9600: "AX.25 9600 Bd G3RUH"
        }
    }

    /// Kanalfilter (Hz, einseitig) hinter der Doppler-Korrektur.
    var channelCutoff: Double {
        switch self {
        case .sstv, .afsk1200: 8_000
        case .g3ruh9600: 12_000
        }
    }
}

struct AmateurChannel: Hashable, Sendable, Codable, Identifiable {
    var frequency: Double   // Hz
    var mode: AmateurMode
    var label: String
    var id: String { "\(Int(frequency))-\(mode.rawValue)" }
}

/// Ein Amateurfunksatellit mit seinen Empfangskanälen.
struct AmateurSatellite: Hashable, Sendable, Codable, Identifiable {
    let id: Int             // NORAD-Katalognummer
    var name: String
    var channels: [AmateurChannel]
    var note: String = ""

    static let issID = 25544
    static let customID = -1

    /// Kleine, belegte Auswahl (Stand Oktober 2026). Katalognummern gegen die
    /// CelesTrak-Gruppe „amateur“ geprüft (28.10.2026); Frequenzen und
    /// Betriebsarten: ARISS (ISS), APRS-Spezifikation/Betreiber (NO-44),
    /// gr-satellites/SatNOGS (GRBBeta).
    static let catalog: [AmateurSatellite] = [
        AmateurSatellite(id: issID, name: "ISS", channels: [
            AmateurChannel(frequency: 145_800_000, mode: .sstv, label: String(localized: "SSTV (ARISS-Aktionen)")),
            AmateurChannel(frequency: 145_825_000, mode: .afsk1200, label: String(localized: "APRS-Digipeater")),
        ], note: String(localized: "Bilder (SSTV) nur an angekündigten Tagen; der APRS-Digipeater ist meist an.")),
        AmateurSatellite(id: 26931, name: "PCSAT (NO-44)", channels: [
            AmateurChannel(frequency: 145_827_000, mode: .afsk1200, label: String(localized: "APRS-Digipeater")),
        ], note: String(localized: "Sendet nur zeitweise, meist nur im Sonnenlicht.")),
        AmateurSatellite(id: 60237, name: "GRBBeta", channels: [
            AmateurChannel(frequency: 436_785_000, mode: .g3ruh9600, label: String(localized: "Telemetrie")),
        ], note: String(localized: "Sendet im 70-cm-Band – du brauchst eine Antenne für 435 MHz.")),
    ]

    static func lookup(_ id: Int) -> AmateurSatellite? {
        if let sat = catalog.first(where: { $0.id == id }) { return sat }
        let own = custom
        return own.id == id && !own.channels.isEmpty ? own : nil
    }

    /// Eigener Eintrag (Katalognummer, Frequenz, Betriebsart), Bahndaten aus der
    /// CelesTrak-Gruppe „amateur“.
    static var custom: AmateurSatellite {
        get {
            guard let data = UserDefaults.standard.data(forKey: "amateurCustomSatellite"),
                  let sat = try? JSONDecoder().decode(AmateurSatellite.self, from: data) else {
                return AmateurSatellite(id: customID, name: "Eigener Satellit", channels: [])
            }
            return sat
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "amateurCustomSatellite") }
    }

    /// Mittenfrequenz für den HackRF: Mitte aller Kanäle.
    var centerFrequency: Double {
        guard let lo = channels.map(\.frequency).min(), let hi = channels.map(\.frequency).max() else { return 0 }
        return (lo + hi) / 2
    }

    /// Für die Überflugrechnung (`PassPredictor` nimmt `WeatherSatellite`).
    var passTarget: WeatherSatellite {
        WeatherSatellite(id: id, name: name, frequency: channels.first?.frequency ?? 0)
    }
}

/// Doppler-Rechnung aus SGP4.
enum Doppler {
    static let speedOfLight = 299_792.458   // km/s

    struct Geometry: Sendable {
        let elevation: Double
        let azimuth: Double
        let rangeKm: Double
        /// Entfernungsänderung (km/s), positiv = entfernt sich.
        let rangeRate: Double
        /// Relative Frequenzverschiebung: Empfangsfrequenz = f · (1 + factor).
        var factor: Double { -rangeRate / Doppler.speedOfLight }
    }

    static func geometry(tle: TLE, station: GroundStation, at date: Date) -> Geometry? {
        guard let sgp4 = try? SGP4(tle),
              let now = try? sgp4.propagate(to: date),
              let later = try? sgp4.propagate(to: date.addingTimeInterval(1)) else { return nil }
        let a = station.lookAngles(teme: now.position, date: date)
        let b = station.lookAngles(teme: later.position, date: date.addingTimeInterval(1))
        return Geometry(elevation: a.elevation, azimuth: a.azimuth, rangeKm: a.rangeKm, rangeRate: b.rangeKm - a.rangeKm)
    }
}

extension TLEStore {
    static var amateurFileURL: URL {
        AppFiles.cacheFile("Amateursatelliten.tle")
    }

    static func loadAmateur() -> (tles: [Int: TLE], fetched: Date?) {
        guard let text = try? String(contentsOf: amateurFileURL, encoding: .utf8) else { return ([:], nil) }
        let date = (try? amateurFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (Dictionary(TLE.parse(text).map { ($0.catalogNumber, $0) }, uniquingKeysWith: { $1 }), date)
    }

    /// Holt die CelesTrak-Gruppe „amateur“ (eine Anfrage, ≈ 15 KB; es geht
    /// nichts über den Nutzer hinaus).
    static func fetchAmateur() async throws -> [Int: TLE] {
        let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=TLE")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("PortaPackManager/1.0 (+https://github.com/cpeg78)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.limitedData(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let text = String(decoding: data, as: UTF8.self)
        let tles = TLE.parse(text)
        guard !tles.isEmpty else { throw URLError(.cannotParseResponse) }
        try text.write(to: amateurFileURL, atomically: true, encoding: .utf8)
        return Dictionary(tles.map { ($0.catalogNumber, $0) }, uniquingKeysWith: { $1 })
    }
}
