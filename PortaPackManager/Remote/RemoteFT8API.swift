import Foundation

/// Reiter „FT8/WSPR“ des Fernzugriffs (`/api/ft8`): Dekodierliste, Stationen
/// mit Locator für die Karte, Zyklusstand, Band und Betriebsart.
///
/// Aktionen: `band=2m|6m|70cm`, `modes=ft8|wspr|both` – über dieselben
/// Model-Eigenschaften wie die Mac-Seite und danach `retune`, das nur neu
/// aufsetzt, wenn der FT8-Empfang den HackRF gerade besitzt. Filter `cq=1`
/// (nur CQ-Rufe und WSPR-Baken), wirkt nur auf die Antwort.
@MainActor
enum RemoteFT8API {
    static let maxSpots = 300
    static let maxStations = 500

    struct State: Encodable {
        struct Spot: Encodable {
            let id: String
            /// Zyklusbeginn (ms seit 1970, UTC).
            let t: Double
            let mode: String
            let band: String
            let snr: Double
            let dt: Double
            let hz: Double
            let drift: Double?
            let msg: String
            let call: String?
            let grid: String?
            /// Locator stand in der Nachricht selbst (sonst zuletzt gesehener).
            let gridMsg: Bool
            let cq: Bool
            let osd: Bool
            let dbm: Int?
            let lat: Double?
            let lon: Double?
            let km: Double?
            let brg: Double?
            let dir: String?
        }
        struct Station: Encodable {
            let call: String
            let grid: String
            let lat: Double
            let lon: Double
            let t: Double
            let mode: String
            let snr: Double
            let spots: Int
        }
        struct Cycle: Encodable {
            let mode: String
            /// Anzahl der Dekodierungen im letzten ausgewerteten Zyklus.
            let last: Int?
            /// Rechenzeit des letzten Zyklus (s).
            let secs: Double?
            /// Wird gerade dekodiert.
            let busy: Bool
        }
        let running: Bool
        let remote: Bool
        let band: String
        /// Betriebsart als Schlüssel („ft8“, „wspr“, „both“).
        let modes: String
        let bands: [String]
        let ft8MHz: Double
        let wsprMHz: Double
        let decodes: Int
        let cycles: [Cycle]
        /// Serverzeit (ms) – die Seite rechnet den Zyklusstand gegen die Mac-Uhr.
        let now: Double
        let clock: String?
        let clockOK: Bool?
        let calibrated: Bool
        let signal: Double?
        let error: String?
        let home: [Double]?
        let homeGrid: String?
        let cqOnly: Bool
        let total: Int
        let spots: [Spot]
        let stations: [Station]
    }

    // MARK: Aktionen

    /// Band aus `2m`, `2 m`, `6m`, `70cm` … (Groß/Klein, Leerzeichen egal).
    nonisolated static func band(_ text: String?) -> FT8Model.Band? {
        guard let text else { return nil }
        let key = text.lowercased().replacingOccurrences(of: " ", with: "")
        return FT8Model.Band.allCases.first { $0.rawValue.replacingOccurrences(of: " ", with: "") == key }
    }

    nonisolated static func modes(_ text: String?) -> FT8Model.Mode? {
        switch text?.lowercased() {
        case "ft8": .ft8
        case "wspr": .wspr
        case "both", "beide", "ft8+wspr": .both
        default: nil
        }
    }

    nonisolated static func key(_ mode: FT8Model.Mode) -> String {
        switch mode {
        case .ft8: "ft8"
        case .wspr: "wspr"
        case .both: "both"
        }
    }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let model = hub.ft8
        var changed = false
        // Nur bei echter Änderung setzen: die Eigenschaften schreiben UserDefaults.
        if let band = band(query["band"]), band != model.band { model.band = band; changed = true }
        if let mode = modes(query["modes"]), mode != model.mode { model.mode = mode; changed = true }
        // `retune` setzt nur neu auf, solange der FT8-Empfang das Gerät besitzt –
        // ein fremder Strom (anderer Empfänger, Plan-Termin) bleibt unberührt.
        if changed { model.retune(on: hub.session?.hackRF) }
        let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
        let s = state(model, remote: hub.remoteMode == .ft8, home: lat == 0 && lon == 0 ? nil : (lat, lon),
                      cqOnly: query["cq"] == "1", now: Date())
        return (try? JSONEncoder().encode(s)) ?? Data("{}".utf8)
    }

    // MARK: Zustand

    static func state(_ model: FT8Model, remote: Bool, home: (lat: Double, lon: Double)?, cqOnly: Bool, now: Date) -> State {
        let clock = model.clockOffset.map { FT8Model.clockVerdict(median: $0.median, count: $0.count) }
        var cycles: [State.Cycle] = []
        for mode in [FT8Spot.Mode.ft8, .wspr] where mode == .ft8 ? model.mode.hasFT8 : model.mode.hasWSPR {
            cycles.append(.init(mode: mode.rawValue, last: model.lastCycleCount[mode],
                                secs: model.lastDecodeDuration[mode].map { ($0 * 100).rounded() / 100 },
                                busy: model.decoding.contains(mode)))
        }
        let (spots, total) = spotList(model.spots, home: home, cqOnly: cqOnly)
        return State(
            running: model.running, remote: remote, band: model.band.rawValue, modes: key(model.mode),
            bands: FT8Model.Band.allCases.map(\.rawValue),
            ft8MHz: Double(model.band.ft8Dial) / 1e6, wsprMHz: Double(model.band.wsprDial) / 1e6,
            decodes: model.decodeCount, cycles: cycles, now: (now.timeIntervalSince1970 * 1000).rounded(),
            clock: clock?.text, clockOK: clock?.ok, calibrated: model.crystalCalibrated,
            signal: model.running && model.signalDB.isFinite && model.signalDB > -100 ? (Double(model.signalDB) * 10).rounded() / 10 : nil,
            error: model.error, home: home.map { [$0.lat, $0.lon] },
            homeGrid: home.map { FT8Locator.locator(lat: $0.lat, lon: $0.lon) },
            cqOnly: cqOnly, total: total, spots: spots,
            stations: stationList(model.stations))
    }

    /// Neueste zuerst, höchstens `maxSpots`; `total` zählt nach dem Filter.
    static func spotList(_ spots: [FT8Spot], home: (lat: Double, lon: Double)?, cqOnly: Bool) -> ([State.Spot], Int) {
        func r1(_ v: Double) -> Double { v.isFinite ? (v * 10).rounded() / 10 : 0 }
        let filtered = cqOnly ? spots.filter { $0.isCQ || $0.mode == .wspr } : spots
        let list = filtered.prefix(maxSpots).map { s -> State.Spot in
            let pos = s.grid.flatMap(FT8Locator.coordinate)
            var km: Double?, brg: Double?
            if let home, let pos {
                km = GeoMath.distanceKm(lat1: home.lat, lon1: home.lon, lat2: pos.lat, lon2: pos.lon).rounded()
                brg = GeoMath.bearingDegrees(lat1: home.lat, lon1: home.lon, lat2: pos.lat, lon2: pos.lon).rounded()
            }
            return .init(id: s.id.uuidString, t: (s.cycle.timeIntervalSince1970 * 1000).rounded(), mode: s.mode.rawValue,
                         band: s.band.rawValue, snr: s.snr.isFinite ? s.snr.rounded() : 0, dt: r1(s.dt), hz: s.frequency.isFinite ? s.frequency.rounded() : 0,
                         drift: s.drift.map(r1), msg: String(s.message.prefix(80)), call: s.call, grid: s.grid,
                         gridMsg: s.gridFromMessage, cq: s.isCQ, osd: s.viaOSD, dbm: s.powerDBm,
                         lat: pos?.lat, lon: pos?.lon, km: km, brg: brg, dir: brg.map(GeoMath.compass))
        }
        return (Array(list), filtered.count)
    }

    static func stationList(_ stations: [FT8Station]) -> [State.Station] {
        stations.sorted { $0.lastHeard > $1.lastHeard }.prefix(maxStations).map {
            .init(call: $0.call, grid: $0.grid, lat: $0.latitude, lon: $0.longitude,
                  t: ($0.lastHeard.timeIntervalSince1970 * 1000).rounded(), mode: $0.lastMode.rawValue,
                  snr: $0.bestSNR.isFinite ? $0.bestSNR.rounded() : 0, spots: $0.spots)
        }
    }
}
