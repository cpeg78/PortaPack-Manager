import Foundation

/// Reiter „APRS“ des Fernzugriffs (`/api/aprs`): Stationen mit Position,
/// Symbol, Kommentar und Entfernung, dazu die letzten Pakete. Die Spur geht nur
/// für die gewählte Station mit (`sel`) – sonst würde jede Abfrage groß.
///
/// Aktionen (nur mit Steuerrecht): `ch=<Kennung>` wechselt den Kanal, `clear=1`
/// leert die Liste.
@MainActor
enum RemoteAPRSAPI {
    /// Höchstens so viele Stationen bzw. Pakete gehen an die Seite.
    static let maxStations = 300
    static let maxPackets = 60

    struct State: Encodable {
        struct Channel: Encodable { let id: String; let mhz: Double; let title: String }
        struct Station: Encodable {
            let id: String
            /// Absender (bei Objekten der sendende Funkamateur).
            let source: String
            /// Kartensymbol (`MapSymbol`) – nur feste Namen, nie Funkdaten.
            let symbol: String
            let kind: String
            let lat: Double?
            let lon: Double?
            let km: Double?
            let course: Int?
            let speedKmh: Int?
            let altitude: Int?
            /// Kommentar, Mic-E-Nachricht bzw. Wetterdaten.
            let text: String?
            let path: String
            let packets: Int
            /// Zuletzt gehört (ms seit 1970).
            let t: Double
            let object: Bool
            let raw: String
            /// Spur [[lat, lon], …] – nur für die gewählte Station.
            let trail: [[Double]]?
        }
        struct Packet: Encodable { let source: String; let kind: String; let text: String }
        let running: Bool
        let remote: Bool
        /// Kennung des Kanals (`APRSModel.Channel`) und seine Frequenz.
        let channel: String
        let mhz: Double
        let channels: [Channel]
        let packets: Int
        let signal: Double?
        let error: String?
        let home: [Double]?
        let stations: [Station]
        let log: [Packet]
    }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let model = hub.aprs
        if query["clear"] == "1" { model.clear() }
        if let channel = query["ch"].flatMap(APRSModel.Channel.init(rawValue:)), channel != model.channel {
            model.channel = channel
            model.retune(on: hub.session?.hackRF)
        }
        let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
        let s = state(model: model, remote: hub.remoteMode == .aprs, home: lat == 0 && lon == 0 ? nil : [lat, lon], selected: query["sel"])
        return (try? JSONEncoder().encode(s)) ?? Data("{}".utf8)
    }

    static func state(model: APRSModel, remote: Bool, home: [Double]?, selected: String?) -> State {
        let signal = model.signalDB
        return State(running: model.running, remote: remote, channel: model.channel.rawValue, mhz: model.channel.mhz,
                     channels: APRSModel.Channel.allCases.map { .init(id: $0.rawValue, mhz: $0.mhz, title: $0.title) },
                     packets: model.packetCount,
                     signal: model.running && signal.isFinite && signal > -100 ? (Double(signal) * 10).rounded() / 10 : nil,
                     error: model.error, home: home,
                     stations: stations(model.stations, home: home, selected: selected),
                     log: model.log.prefix(maxPackets).map { .init(source: $0.stationID, kind: $0.kind.title, text: text(of: $0) ?? "") })
    }

    /// Reine Funktion (Tests): neueste zuerst, Spur nur für `selected`.
    static func stations(_ list: [APRSStation], home: [Double]?, selected: String?) -> [State.Station] {
        list.sorted { $0.lastHeard > $1.lastHeard }.prefix(maxStations).map { s in
            let p = s.last
            var km: Double?
            if let home, let lat = s.latitude, let lon = s.longitude {
                km = (GeoMath.distanceKm(lat1: home[0], lon1: home[1], lat2: lat, lon2: lon) * 10).rounded() / 10
            }
            return .init(id: s.id, source: p.source, symbol: MapSymbol(sfSymbol: p.systemImage).rawValue, kind: p.kind.title,
                         lat: s.latitude, lon: s.longitude, km: km,
                         course: p.courseDegrees.map { Int($0.rounded()) },
                         speedKmh: p.speedKnots.map { Int(($0 * 1.852).rounded()) },
                         altitude: p.altitudeMeters.map { Int($0.rounded()) },
                         text: text(of: p), path: p.path, packets: s.packets,
                         t: (s.lastHeard.timeIntervalSince1970 * 1000).rounded(), object: p.objectName != nil,
                         raw: String(p.raw.prefix(300)),
                         trail: s.id == selected && s.trail.count > 1 ? s.trail.suffix(500).map { [$0.lat, $0.lon] } : nil)
        }
    }

    private static func text(of p: APRSPacket) -> String? {
        let parts = [p.weather, p.micEMessage, p.comment.trimmingCharacters(in: .whitespaces)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : String(parts.joined(separator: " · ").prefix(200))
    }
}
