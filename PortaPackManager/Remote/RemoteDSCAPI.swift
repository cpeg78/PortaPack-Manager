import Foundation

/// Reiter „Seefunk-Notruf (DSC)“ des Fernzugriffs (`/api/dsc`): Rufliste von
/// UKW-Kanal 70 mit Absender (MMSI, Land, Name aus AIS), Ziel, Art des
/// Notfalls, Position und Folgekanal. Notrufe stehen oben.
///
/// Nur Anzeige – keine Aktionen außer `clear=1` (Liste leeren). Beantworten
/// kann und soll man von hier aus nichts.
@MainActor
enum RemoteDSCAPI {
    /// Höchstens so viele Rufe gehen an die Seite (das Protokoll hält 500).
    static let maxEntries = 200

    struct State: Encodable {
        struct Station: Encodable, Equatable {
            /// Neunstellig mit führenden Nullen (Küstenfunkstellen beginnen mit 00).
            let mmsi: String
            let name: String?
            let country: String?
            /// Art der Kennung („Küstenfunkstelle“, „EPIRB“ …), bei Schiffen leer.
            let kind: String?
        }
        struct Area: Encodable {
            let n: Double; let w: Double; let s: Double; let e: Double; let text: String
        }
        struct Entry: Encodable {
            let id: Int
            /// Zuletzt bzw. zuerst gehört (ms seit 1970).
            let t: Double
            let first: Double
            let rep: Int
            /// Kurzbezeichnung („Notruf“, „Notruf-Relais“, „Routine“ …).
            let kind: String
            let format: String
            let category: String?
            /// Betrifft einen Seenotfall (Notruf, Bestätigung, Relais) und ist kein Test.
            let distress: Bool
            let test: Bool
            let from: Station
            /// Ziel als Text („Alle“, „Gebiet“) bzw. Station bei Einzel-/Gruppenruf.
            let to: String
            let toStation: Station?
            /// Schiff in Not, falls nicht der Absender (Bestätigung, Relais).
            let inDistress: Station?
            let nature: String?
            let command: String?
            let command2: String?
            let lat: Double?
            let lon: Double?
            let pos: String?
            let posUnknown: Bool
            /// UTC-Zeit der Position („14:05 UTC“).
            let posTime: String?
            let area: Area?
            /// Folgekommunikation bzw. Kanal/Frequenz.
            let next: String?
            let freq: String?
            let ack: String?
            let corrected: Int
        }
        let running: Bool
        let remote: Bool
        let calls: Int
        let distressCount: Int
        let corrected: Int
        let signal: Double?
        let error: String?
        /// Eigener Standort [lat, lon], falls gesetzt.
        let home: [Double]?
        let entries: [Entry]
    }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let model = hub.dsc
        if query["clear"] == "1" { model.clear() }
        let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
        let s = state(entries: model.entries, running: model.running, remote: hub.remoteMode == .dsc,
                      corrected: model.correctedSymbols, signalDB: model.signalDB, error: model.error,
                      home: lat == 0 && lon == 0 ? nil : [lat, lon], name: ShipNameDirectory.name(for:))
        return (try? JSONEncoder().encode(s)) ?? Data("{}".utf8)
    }

    /// Reine Funktion (Tests): Notrufe zuerst, sonst neueste zuerst.
    static func state(entries: [DSCLogEntry], running: Bool, remote: Bool, corrected: Int, signalDB: Float,
                      error: String?, home: [Double]?, name: (Int) -> String?) -> State {
        func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        func station(_ mmsi: Int) -> State.Station {
            let classified = MaritimeIdentity.classify(mmsi)
            return .init(mmsi: String(format: "%09d", mmsi), name: name(mmsi).map { String($0.prefix(60)) },
                         country: MaritimeIdentity.country(mmsi), kind: classified.kind.title)
        }
        func urgent(_ e: DSCLogEntry) -> Bool { e.call.concernsDistress && !e.call.isTest }
        let sorted = entries.sorted { a, b in
            if urgent(a) != urgent(b) { return urgent(a) }
            return a.last > b.last
        }
        let list = sorted.prefix(maxEntries).map { e -> State.Entry in
            let c = e.call
            let position = c.position.flatMap { $0.latitude.isFinite && $0.longitude.isFinite ? $0 : nil }
            return .init(
                id: e.id, t: ms(e.last), first: ms(e.first), rep: e.repeats,
                kind: c.kindText, format: c.format.title, category: c.category?.title,
                distress: urgent(e), test: c.isTest,
                from: station(c.sender),
                to: c.address != nil ? "Einzel" : c.area != nil ? "Gebiet" : "Alle",
                toStation: c.address.map(station),
                inDistress: c.distressID.flatMap { $0 != c.sender ? station($0) : nil },
                nature: c.natureText,
                command: c.nature == nil ? c.firstCommand.flatMap(DSCCall.firstCommandText) : nil,
                command2: c.secondCommand.flatMap(DSCCall.secondCommandText),
                lat: position?.latitude, lon: position?.longitude, pos: position?.text,
                posUnknown: c.positionUnknown, posTime: c.timeText,
                area: c.area.map { .init(n: $0.north, w: $0.west, s: $0.south, e: $0.east, text: $0.text) },
                next: c.subsequentText, freq: c.frequency, ack: c.acknowledgementText,
                corrected: e.corrected)
        }
        return State(running: running, remote: remote, calls: entries.count,
                     distressCount: entries.filter(urgent).count, corrected: corrected,
                     signal: signalDB.isFinite && signalDB > -100 ? (Double(signalDB) * 10).rounded() / 10 : nil,
                     error: error, home: home, entries: Array(list))
    }
}
