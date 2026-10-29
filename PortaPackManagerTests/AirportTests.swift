import Foundation
import MapKit
import Testing
@testable import PortaPackManager

/// Flugplätze auf der Flugzeugkarte: OurAirports-CSV, Ausschnitt, Fernzugriff.
@Suite("Flugplätze")
struct AirportTests {
    static let header = #""id","ident","type","name","latitude_deg","longitude_deg","elevation_ft","continent","iso_country","iso_region","municipality","scheduled_service","icao_code","iata_code","gps_code","local_code","home_link","wikipedia_link","keywords""#

    static let csv = [
        header,
        #"2212,"EDDH","large_airport","Hamburg Helmut Schmidt Airport",53.630402,9.98823,53,"EU","DE","DE-HH","Hamburg","yes","EDDH","HAM","EDDH",,"https://www.hamburg-airport.de/",,"Hamburg-Fuhlsbüttel""#,
        #"28735,"EDHS","small_airport","Stade Airfield",53.561111,9.499167,63,"EU","DE","DE-NI","Stade","no","EDHS",,"EDHS",,"https://www.lsvstade.de/",,"ZQD, Flugplatz Stade""#,
        // Anführungszeichen und Komma im Namen.
        #"999,"DE-0042","small_airport","Ultraleicht ""Am Deich"", Nord",53.7,9.6,,"EU","DE","DE-NI",,"no",,,,,,,"#,
        #"1000,"DE-0099","heliport","Klinikum Nord Heliport",53.66,10.0,30,"EU","DE","DE-HH","Hamburg","no",,,"EDHX",,,,"#,
        #"1001,"EDXX","closed","Alter Platz",53.5,9.5,10,"EU","DE","DE-NI","Irgendwo","no","EDXX",,"EDXX",,,,"#,
        #"1002,"DE-0100","balloonport","Ballonstartplatz",53.5,9.5,10,"EU","DE","DE-NI",,"no",,,,,,,"#,
        #"1003,"BAD","small_airport","Kaputt",nan,9.5,10,"EU","DE","DE-NI",,"no",,,,,,,"#,
        #"1004,"EDHL","medium_airport","Lübeck Airport",53.805367,10.719547,53,"EU","DE","DE-SH","Lübeck","yes","EDHL","LBC","EDHL",,,,"#,
        #"1005,"PALQ","seaplane_base","Lake Seaplane",61.0,-150.0,,"NA","US","US-AK",,"no",,,,,,,"#,
    ].joined(separator: "\n") + "\n"

    @Test("CSV: Typfilter, closed/balloonport/kaputt fallen weg, Anführungszeichen im Feld")
    func parse() throws {
        let airports = AirportCSV.parse(Self.csv)
        #expect(Set(airports.map(\.ident)) == ["EDDH", "EDHS", "DE-0042", "DE-0099", "EDHL", "PALQ"])
        let deich = try #require(airports.first { $0.ident == "DE-0042" })
        #expect(deich.name == #"Ultraleicht "Am Deich", Nord"#)
        #expect(deich.elevationFt == nil && deich.municipality == nil && deich.icao == nil)
        let ham = try #require(airports.first { $0.ident == "EDDH" })
        #expect(ham.kind == .large && ham.iata == "HAM" && ham.scheduled && ham.elevationFt == 53)
        #expect(ham.icao == nil && ham.code == "EDDH")   // icao_code = ident → nicht doppelt
        // gps_code ersetzt die fehlende ICAO-Kennung.
        #expect(airports.first { $0.ident == "DE-0099" }?.code == "EDHX")
    }

    @Test("Sortierung nach Wichtigkeit: Typ, Linienverkehr, IATA")
    func importance() {
        let order = AirportCSV.parse(Self.csv).map(\.ident)
        #expect(order.first == "EDDH")
        #expect(order[1] == "EDHL")
        #expect(order.last == "DE-0099")   // Hubschrauber zuletzt
        // Echte ICAO-Kennung vor „DE-…“ unter den kleinen Plätzen.
        #expect(order.firstIndex(of: "EDHS")! < order.firstIndex(of: "DE-0042")!)
        #expect(AirportCSV.isICAO("EDHS") && !AirportCSV.isICAO("DE-0042") && !AirportCSV.isICAO("0042"))
    }

    @Test("Kompakte Ablage: JSON hin und zurück")
    func roundTrip() throws {
        let airports = AirportCSV.parse(Self.csv)
        let data = try JSONEncoder().encode(airports)
        #expect(try JSONDecoder().decode([Airport].self, from: data) == airports)
        let first = try #require(try JSONSerialization.jsonObject(with: data) as? [[Any]]).first
        #expect(first?.count == 10)
    }

    @Test("Ausschnitt: nur Sichtbares, Hubschrauber erst nah heran, kleine Plätze ab Regionsgröße")
    func visible() throws {
        let airports = AirportCSV.parse(Self.csv)
        let near = try #require(AirportFilter.Bounds(south: 53.4, west: 9.3, north: 53.9, east: 10.8))
        #expect(Set(AirportFilter.visible(airports, in: near).map(\.ident)) == ["EDDH", "EDHS", "DE-0042", "DE-0099", "EDHL"])
        let region = try #require(AirportFilter.Bounds(south: 52, west: 8, north: 55, east: 12))
        #expect(!AirportFilter.visible(airports, in: region).contains { $0.kind == .heliport })
        #expect(AirportFilter.visible(airports, in: region).contains { $0.ident == "EDHS" })
        let europe = try #require(AirportFilter.Bounds(south: 35, west: -10, north: 60, east: 30))
        #expect(AirportFilter.visible(airports, in: europe).map(\.ident) == ["EDDH", "EDHL"])
        let continent = try #require(AirportFilter.Bounds(south: 20, west: -20, north: 70, east: 40))
        #expect(AirportFilter.visible(airports, in: continent).map(\.ident) == ["EDDH"])
    }

    @Test("Begrenzung: die wichtigsten zuerst")
    func limit() throws {
        let airports = AirportCSV.parse(Self.csv)
        let near = try #require(AirportFilter.Bounds(south: 53.4, west: 9.3, north: 53.9, east: 10.8))
        #expect(AirportFilter.visible(airports, in: near, limit: 2).map(\.ident) == ["EDDH", "EDHL"])
        #expect(AirportFilter.visible(airports, in: near, limit: 0).isEmpty)
        let many = (0..<1000).map { i in
            Airport(ident: "X\(i)", icao: nil, iata: nil, name: "", kind: .small, latitude: 50 + Double(i) / 1000,
                    longitude: 10, elevationFt: nil, municipality: nil, scheduled: false)
        }
        let box = try #require(AirportFilter.Bounds(south: 49, west: 9, north: 52, east: 11))
        #expect(AirportFilter.visible(many, in: box).count == AirportFilter.defaultLimit)
    }

    @Test("Datumsgrenze und Leaflet-Längen über ±180")
    func antimeridian() throws {
        let fiji = Airport(ident: "NFFN", icao: nil, iata: "NAN", name: "Nadi", kind: .large, latitude: -17.75,
                           longitude: 177.44, elevationFt: 59, municipality: nil, scheduled: true)
        let samoa = Airport(ident: "NSFA", icao: nil, iata: "APW", name: "Faleolo", kind: .large, latitude: -13.83,
                            longitude: -172.0, elevationFt: 58, municipality: nil, scheduled: true)
        let bounds = try #require(AirportFilter.Bounds(south: -25, west: 170, north: -10, east: 190))
        #expect(bounds.west == 170 && bounds.east == -170)
        #expect(Set(AirportFilter.visible([fiji, samoa], in: bounds).map(\.ident)) == ["NFFN", "NSFA"])
        let whole = try #require(AirportFilter.Bounds(south: -80, west: -400, north: 80, east: 400))
        #expect(whole.west == -180 && whole.east == 180)
        let east180 = try #require(AirportFilter.Bounds(south: -30, west: 0, north: 0, east: 180))
        #expect(east180.east == 180)
        #expect(AirportFilter.Bounds(query: "1,2,3") == nil)
        #expect(AirportFilter.Bounds(query: "a,b,c,d") == nil)
        #expect(AirportFilter.Bounds(query: "54,9,53,10") == nil)   // Süd > Nord
        #expect(AirportFilter.Bounds(query: "nan,9,53,10") == nil)
    }

    @Test("MapKit-Ausschnitt → Grenzen")
    func mapRect() throws {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: 54, longitude: 9))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: 53, longitude: 11))
        let bounds = try #require(AirportFilter.Bounds(mapRect: MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)))
        #expect(abs(bounds.north - 54) < 1e-6 && abs(bounds.south - 53) < 1e-6)
        #expect(abs(bounds.west - 9) < 1e-6 && abs(bounds.east - 11) < 1e-6)
    }

    @Test("Fernzugriff /api/airports: Felder, Höhe in Metern, leere Optionale fehlen")
    func api() throws {
        let airports = AirportCSV.parse(Self.csv)
        let response = RemoteAirports.response(airports, bbox: "53.4,9.3,53.9,10.8")
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(object["available"] as? Bool == true)
        let items = try #require(object["airports"] as? [[String: Any]])
        #expect(items.count == 5)
        let ham = try #require(items.first)
        #expect(Set(ham.keys) == ["code", "iata", "name", "kind", "lat", "lon", "elevM", "city", "sched"])
        #expect(ham["code"] as? String == "EDDH" && ham["kind"] as? String == "large" && ham["elevM"] as? Int == 16)
        let deich = try #require(items.first { $0["code"] as? String == "DE-0042" })
        #expect(Set(deich.keys) == ["code", "name", "kind", "lat", "lon"])
        // Ungültiger Ausschnitt: leer, aber verfügbar; ohne Daten: nicht verfügbar.
        #expect(RemoteAirports.response(airports, bbox: nil).airports.isEmpty)
        #expect(RemoteAirports.response(airports, bbox: "x").available)
        #expect(!RemoteAirports.response([], bbox: "53,9,54,10").available)
        #expect(RemoteAirports.response(airports, bbox: "53.4,9.3,53.9,10.8", limit: 1).airports.map(\.code) == ["EDDH"])
    }
}
