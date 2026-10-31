import Foundation

/// Flugplätze für die Flugzeugkarte des Fernzugriffs:
/// `/api/airports?bbox=süd,west,nord,ost` liefert die wichtigsten Plätze im
/// Ausschnitt (höchstens `AirportFilter.defaultLimit`). Nur Lesen; ohne
/// geladene Datenbank ist die Liste leer und `available` falsch – laden lässt
/// sie sich nur am Mac (ADS-B-Seite).
@MainActor
enum RemoteAirports {
    struct Item: Encodable, Equatable {
        let code: String
        let iata: String?
        let name: String
        let kind: String
        let lat: Double
        let lon: Double
        let elevM: Int?
        let city: String?
        let sched: Bool?
    }

    struct Response: Encodable {
        let available: Bool
        let airports: [Item]
    }

    static func handle(_ query: [String: String]) async -> Data {
        let database = AirportDatabase.shared
        await database.waitUntilLoaded()
        let result = response(database.airports, bbox: query["bbox"])
        return (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
    }

    /// Rein: Auswahl für den Ausschnitt; ungültiger Ausschnitt = leere Liste.
    nonisolated static func response(_ airports: [Airport], bbox: String?, limit: Int = AirportFilter.defaultLimit) -> Response {
        guard let bounds = AirportFilter.Bounds(query: bbox) else {
            return Response(available: !airports.isEmpty, airports: [])
        }
        let items = AirportFilter.visible(airports, in: bounds, limit: limit).map { a in
            Item(code: a.code, iata: a.iata, name: a.name, kind: a.kind.short,
                 lat: (a.latitude * 1e5).rounded() / 1e5, lon: (a.longitude * 1e5).rounded() / 1e5,
                 elevM: a.elevationFt.map { Int((Double($0) * 0.3048).rounded()) },
                 city: a.municipality, sched: a.scheduled ? true : nil)
        }
        return Response(available: !airports.isEmpty, airports: items)
    }
}
