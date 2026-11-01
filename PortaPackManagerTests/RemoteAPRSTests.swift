import Foundation
import Testing
@testable import PortaPackManager

/// `/api/aprs` des Fernzugriffs: Reihenfolge, Entfernung, Symbol, Spur nur für die Auswahl.
@Suite("Fernzugriff: APRS")
@MainActor
struct RemoteAPRSTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func station(_ call: String, age: TimeInterval, lat: Double?, lon: Double?, symbol: Character, trail: Int = 0) -> APRSStation {
        var packet = APRSPacket(source: call, destination: "APRS", path: "WIDE1-1", raw: "\(call)>APRS:!test")
        packet.kind = .position
        packet.latitude = lat
        packet.longitude = lon
        packet.symbolCode = symbol
        packet.comment = "  Hallo  "
        var s = APRSStation(id: call, last: packet, latitude: lat, longitude: lon)
        s.trail = (0..<trail).map { .init(lat: 53.5 + Double($0) * 0.01, lon: 9.8) }
        s.packets = 3
        s.lastHeard = now.addingTimeInterval(-age)
        return s
    }

    @Test("Neueste zuerst, Entfernung vom Standort, Kartensymbol, Spur nur für die gewählte Station")
    func stationList() {
        let list = [Self.station("DB0WOT", age: 600, lat: 53.6, lon: 9.7, symbol: "#", trail: 3),
                    Self.station("DL1ABC-9", age: 5, lat: 53.55, lon: 9.95, symbol: ">", trail: 4),
                    Self.station("DL2XYZ", age: 60, lat: nil, lon: nil, symbol: "-")]
        let out = RemoteAPRSAPI.stations(list, home: [53.55, 9.95], selected: "DB0WOT")
        #expect(out.map(\.id) == ["DL1ABC-9", "DL2XYZ", "DB0WOT"])
        #expect(out[0].km == 0)
        #expect(out[0].symbol == "car")
        #expect(out[2].symbol == "antenna")
        #expect(out[1].km == nil)
        #expect(out[0].trail == nil)
        #expect(out[2].trail?.count == 3)
        #expect(out[0].text == "Hallo")
    }
}
