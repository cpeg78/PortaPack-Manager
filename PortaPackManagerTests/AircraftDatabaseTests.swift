import Foundation
import Testing
@testable import PortaPackManager

@Suite("Flugzeugdatenbank")
struct AircraftDatabaseTests {
    /// Kopfzeile wie OpenSky, dazu alle CSV-Sonderfälle: Komma und
    /// Anführungszeichen im Feld, Zeilenumbruch im Feld, leere Zeile,
    /// ungültige Adresse, Zeile ohne Inhalt, Windows-Zeilenende.
    static let csv = #"""
    "icao24","registration","manufacturericao","manufacturername","model","typecode","serialnumber","linenumber","icaoaircrafttype","operator","operatorcallsign","operatoricao","operatoriata","owner","testreg","registered","reguntil","status","built","firstflightdate","seatconfiguration","engines","modes","adsb","acars","notes","categoryDescription"
    "","","","","","","","","","","","","","","","","","","","","","","false","false","false","",""
    "3c6444","D-AIBA","AIRBUS","Airbus","A319-112","A319","4141","","L2J","Lufthansa","LUFTHANSA","DLH","LH","","","","","","","","","","false","true","false","","Large (75000 to 300000 lbs)"
    "4ca7b6","EI-DVL","AIRBUS","Airbus","A320-214","A320","3906","","L2J","Aer Lingus","SHAMROCK","EIN","EI","","","","","","","","","","false","true","false","",""
    "a4fa61","N42MH","PIPER","Piper","PA-31-350","PA31","31-7852015","","L2P","","","","","Tvpx Aircraft Solutions Inc Trustee","","","2029-08-31","","1977-01-01","","","LYCOMING TI0-540 SER","false","false","false","",""
    "3d3191","D-ERAF","","","G-115 ""Tutor"", Zweisitzer","G115","","","L1P","","","","","Private, ""Flugschule""","","","","","","","","","false","false","false","Zeile 1
    Zeile 2",""
    "7c65b7","VH-UDL","DREAM","","","TNDR","","","L1P","","","","","","","","","","","","","","false","false","false","",""\#r
    "zzzzzz","XX-XXX","","","","","","","","","","","","","","","","","","","","","false","false","false","",""
    "abcdef","","","","","","","","","","","","","","","","","","","","","","false","false","false","",""
    """#

    @Test("CSV → kompakte Datei → Nachschlagen")
    func roundtrip() throws {
        let (tsv, count) = AircraftCSV.convert(Data(Self.csv.utf8))
        #expect(count == 5)   // Kopf, Leerzeile, ungültige Adresse und inhaltslose Zeile entfallen
        let index = AircraftIndex(tsv: tsv)
        #expect(index.count == 5)

        let dlh = try #require(index.info(for: 0x3C6444))
        #expect(dlh.registration == "D-AIBA")
        #expect(dlh.typeCode == "A319")
        #expect(dlh.manufacturer == "Airbus")
        #expect(dlh.model == "A319-112")
        #expect(dlh.operatorName == "Lufthansa")
        #expect(dlh.operatorCallsign == "LUFTHANSA")
        #expect(dlh.category == "Large (75000 to 300000 lbs)")
        #expect(dlh.typeText == "Airbus A319-112 (A319)")
        #expect(dlh.operatorText == "Lufthansa")

        // Halter statt Betreiber, Hersteller-ICAO als Rückfall ohne Namen
        let piper = try #require(index.info(for: 0xA4FA61))
        #expect(piper.operatorText == "Tvpx Aircraft Solutions Inc Trustee")
        let dream = try #require(index.info(for: 0x7C65B7))
        #expect(dream.manufacturer == "DREAM")
        #expect(dream.typeText == "DREAM (TNDR)")

        // Anführungszeichen, Komma und Zeilenumbruch im Feld
        let grob = try #require(index.info(for: 0x3D3191))
        #expect(grob.model == "G-115 \"Tutor\", Zweisitzer")
        #expect(grob.owner == "Private, \"Flugschule\"")

        #expect(index.info(for: 0xABCDEF) == nil)
        #expect(index.info(for: 0x123456) == nil)
    }

    @Test("Hersteller nicht doppeln, wenn er im Modell steckt")
    func typeText() {
        #expect(AircraftInfo(typeCode: "A20N", manufacturer: "Airbus", model: "Airbus A320 251NSL").typeText == "Airbus A320 251NSL (A20N)")
        #expect(AircraftInfo(typeCode: "B738", manufacturer: "The Boeing Company", model: "BOEING 737-8AS").typeText == "BOEING 737-8AS (B738)")
        #expect(AircraftInfo(typeCode: "ZZZZ", manufacturer: "Impulse Aircraft", model: "Impulse 100").typeText == "Impulse 100")
        #expect(AircraftInfo(typeCode: "TNDR", manufacturer: "DREAM").typeText == "DREAM (TNDR)")
        #expect(AircraftInfo().typeText == "")
    }

    @Test("hexdb.io-Antwort")
    func hexDB() throws {
        let json = #"{"ModeS": "4CA7B6", "Registration": "EI-EGA", "Manufacturer": "Boeing", "ICAOTypeCode": "B738", "Type": "737NG 8AS/W", "RegisteredOwners": "Ryanair", "OperatorFlagCode": "RYR"}"#
        let info = try #require(AircraftCSV.parseHexDBForTest(Data(json.utf8)))
        #expect(info.registration == "EI-EGA")
        #expect(info.typeText == "Boeing 737NG 8AS/W (B738)")
        #expect(info.operatorText == "Ryanair")
        #expect(AircraftCSV.parseHexDBForTest(Data(#"{"status":"404","error":"Aircraft not found."}"#.utf8)) == nil)
    }

    @Test("Adresse aus sechs Hex-Zeichen")
    func icaoParsing() {
        #expect(AircraftCSV.icao(Array("3c6444".utf8)[...]) == 0x3C6444)
        #expect(AircraftCSV.icao(Array("3C6444".utf8)[...]) == 0x3C6444)
        #expect(AircraftCSV.icao(Array("3c644".utf8)[...]) == nil)
        #expect(AircraftCSV.icao(Array("3c644g".utf8)[...]) == nil)
    }
}

@Suite("Flugstrecken") @MainActor
struct FlightRouteTests {
    static let json = #"{"response":{"flightroute":{"callsign":"SAS651","callsign_icao":"SAS651","callsign_iata":"SK651","airline":{"name":"Scandinavian Airlines System","icao":"SAS","iata":"SK","country":"Sweden","country_iso":"SE","callsign":"SCANDINAVIAN"},"origin":{"country_iso_name":"DK","country_name":"Denmark","elevation":17,"iata_code":"CPH","icao_code":"EKCH","latitude":55.6179,"longitude":12.656,"municipality":"Copenhagen","name":"Copenhagen Kastrup Airport"},"destination":{"country_iso_name":"DE","country_name":"Germany","elevation":53,"iata_code":"HAM","icao_code":"EDDH","latitude":53.6304,"longitude":9.98823,"municipality":"Hamburg","name":"Hamburg Helmut Schmidt Airport"}}}}"#

    @Test("adsbdb-Antwort zerlegen")
    func parse() throws {
        let route = try #require(FlightRoute.parseADSBDB(Data(Self.json.utf8)))
        #expect(route.airline == "Scandinavian Airlines System")
        #expect(route.origin.shortText == "Copenhagen (CPH)")
        #expect(route.destination.shortText == "Hamburg (HAM)")
        #expect(route.codesText == "CPH → HAM")
        #expect(FlightRoute.parseADSBDB(Data(#"{"response":"unknown callsign"}"#.utf8)) == nil)
    }

    @Test("Abstand zur Strecke")
    func offRoute() throws {
        let route = try #require(FlightRoute.parseADSBDB(Data(Self.json.utf8)))
        // Mitte der Strecke CPH–HAM (≈ Lolland): nahe 0
        #expect(route.offRouteKm(latitude: 54.63, longitude: 11.35) < 15)
        // Berlin liegt ≈ 230 km neben der Strecke
        let berlin = route.offRouteKm(latitude: 52.52, longitude: 13.40)
        #expect(berlin > 150 && berlin < 300)
        // hinter dem Ziel: Abstand zum Ziel (Hannover ≈ 130 km von HAM)
        let hannover = route.offRouteKm(latitude: 52.46, longitude: 9.68)
        #expect(abs(hannover - 132) < 15)
        #expect(ADSBView.routeFits(route, lat: 54.63, lon: 11.35))
        #expect(!ADSBView.routeFits(route, lat: 52.52, lon: 13.40))
    }

    @Test("planespotters-Antwort zerlegen")
    func photo() throws {
        let json = #"{"photos":[{"id":"1991068","thumbnail":{"src":"https:\/\/t.plnspttrs.net\/44567\/1991068_492567b390_t.jpg","size":{"width":200,"height":133}},"thumbnail_large":{"src":"https:\/\/t.plnspttrs.net\/44567\/1991068_492567b390_280.jpg","size":{"width":420,"height":280}},"link":"https:\/\/www.planespotters.net\/photo\/1991068\/se-roe?utm_source=api","photographer":"Kilian Fe\u00dfler"}]}"#
        let photo = try #require(AircraftPhoto.parsePlanespotters(Data(json.utf8)))
        #expect(photo.imageURL.absoluteString.hasSuffix("_280.jpg"))
        #expect(photo.pageURL.host == "www.planespotters.net")
        #expect(photo.photographer == "Kilian Feßler")
        #expect(AircraftPhoto.parsePlanespotters(Data(#"{"photos":[]}"#.utf8)) == nil)
    }

    @Test("Rufzeichen normalisieren")
    func normalize() {
        #expect(FlightRouteLookup.normalized(" sas651 ") == "SAS651")
        #expect(FlightRouteLookup.normalized("DEABC") == nil)
        #expect(FlightRouteLookup.normalized(nil) == nil)
        #expect(FlightRouteLookup.normalized("AB") == nil)
    }
}
