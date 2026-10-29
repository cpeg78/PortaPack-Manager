import Foundation
import Testing
@testable import PortaPackManager

/// `/api/dsc` des Fernzugriffs: Form der Antwort, Notrufe zuerst, Grenzen.
@Suite("Fernzugriff: Seefunk-Notruf")
@MainActor
struct RemoteDSCTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func entry(_ id: Int, age: TimeInterval, _ call: DSCCall) -> DSCLogEntry {
        DSCLogEntry(id: id, call: call, first: now.addingTimeInterval(-age - 30), last: now.addingTimeInterval(-age), repeats: 2, corrected: 1)
    }

    /// Notruf (älter), Routineruf an eine Küstenfunkstelle, Testruf, Gebietsruf.
    private static var entries: [DSCLogEntry] {
        [entry(4, age: 10, DSCCall(format: .individual, category: .routine, sender: 211_000_010, address: 2_111_240,
                                   firstCommand: 100, secondCommand: 126, frequency: "Kanal 16", endOfSequence: 117, symbols: [])),
         entry(3, age: 20, DSCCall(format: .individual, category: .safety, sender: 244_000_020, address: 2_111_240,
                                   firstCommand: 118, secondCommand: 126, endOfSequence: 117, symbols: [])),
         entry(2, age: 30, DSCCall(format: .area, category: .urgency, sender: 2_111_240,
                                   area: DSCArea(north: 55, west: 7, heightDegrees: 2, widthDegrees: 3),
                                   firstCommand: 100, secondCommand: 126, endOfSequence: 127, symbols: [])),
         entry(1, age: 600, DSCCall(format: .distress, category: .distress, sender: 211_234_560, distressID: 211_234_560,
                                    nature: 110, position: DSCPosition(latitude: 54.5, longitude: 10.25), hour: 14, minute: 5,
                                    subsequent: 100, endOfSequence: 127, symbols: []))]
    }

    private func state(_ entries: [DSCLogEntry] = entries, home: [Double]? = [53.5, 10]) -> RemoteDSCAPI.State {
        RemoteDSCAPI.state(entries: entries, running: true, remote: true, corrected: 3, signalDB: -54.37, error: nil,
                           home: home, name: { $0 == 211_234_560 ? "SEA <b>STAR</b>" : nil })
    }

    @Test("JSON: vorgesehene Felder, leere Optionale fehlen")
    func jsonShape() throws {
        let data = try JSONEncoder().encode(state(home: nil))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["running", "remote", "calls", "distressCount", "corrected", "signal", "entries"])
        #expect(object["signal"] as? Double == -54.4)
        let entries = try #require(object["entries"] as? [[String: Any]])
        let allowed: Set<String> = ["id", "t", "first", "rep", "kind", "format", "category", "distress", "test", "from", "to",
                                    "toStation", "inDistress", "nature", "command", "command2", "lat", "lon", "pos",
                                    "posUnknown", "posTime", "area", "next", "freq", "ack", "corrected"]
        for entry in entries { #expect(Set(entry.keys).isSubset(of: allowed)) }
        let from = try #require(entries.first?["from"] as? [String: Any])
        #expect(Set(from.keys).isSubset(of: ["mmsi", "name", "country", "kind"]))
    }

    @Test("Notrufe stehen oben, sonst neueste zuerst; Testrufe zählen nicht als Notfall")
    func order() {
        let s = state()
        #expect(s.entries.map(\.id) == [1, 4, 3, 2])
        #expect(s.distressCount == 1 && s.calls == 4)
        let distress = s.entries[0]
        #expect(distress.distress && distress.kind == "Notruf")
        #expect(distress.nature == "Mensch über Bord")
        #expect(distress.lat == 54.5 && distress.lon == 10.25 && distress.posTime == "14:05 UTC")
        #expect(distress.next == "Sprechfunk (FM)")
        #expect(distress.from.name == "SEA <b>STAR</b>")   // Escapen macht die Seite (esc)
        #expect(distress.inDistress == nil)                // Absender selbst
        #expect(s.entries[2].test && !s.entries[2].distress)
        #expect(s.entries[0].t == (Self.now.timeIntervalSince1970 - 600) * 1000)
    }

    @Test("Stationen: MMSI neunstellig, Küstenfunkstelle, Land, Ziel und Gebiet")
    func stations() throws {
        let s = state()
        let routine = try #require(s.entries.first { $0.id == 4 })
        #expect(routine.to == "Einzel")
        #expect(routine.toStation?.mmsi == "002111240")
        #expect(routine.toStation?.kind == "Küstenfunkstelle")
        #expect(routine.freq == "Kanal 16" && routine.command == "Sprechfunk (FM)" && routine.ack == "Quittung erbeten")
        #expect(routine.from.country != nil)
        let area = try #require(s.entries.first { $0.id == 2 })
        #expect(area.to == "Gebiet" && area.toStation == nil)
        #expect(area.area?.n == 55 && area.area?.s == 53 && area.area?.e == 10)
    }

    @Test("Grenzen: höchstens 200 Rufe, Namen gekürzt, kein Pegel ohne Empfang")
    func limits() {
        let many = (1...250).map { i in
            Self.entry(i, age: Double(i), DSCCall(format: .allShips, category: .routine, sender: 211_000_000 + i,
                                                  firstCommand: 100, secondCommand: 126, endOfSequence: 127, symbols: []))
        }
        let s = RemoteDSCAPI.state(entries: many, running: false, remote: false, corrected: 0, signalDB: -100, error: "x",
                                   home: nil, name: { _ in String(repeating: "A", count: 500) })
        #expect(s.entries.count == RemoteDSCAPI.maxEntries)
        #expect(s.calls == 250)
        #expect(s.entries.allSatisfy { ($0.from.name?.count ?? 0) <= 60 })
        #expect(s.signal == nil)
        #expect(s.entries.first?.to == "Alle")
    }
}

/// `/api/ft8` des Fernzugriffs: Aktionen (Band, Betriebsart), Filter, Form, Grenzen.
/// Schreibt nichts in UserDefaults – `band`/`mode` des Models werden hier nicht gesetzt.
@Suite("Fernzugriff: FT8/WSPR")
@MainActor
struct RemoteFT8Tests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func spot(_ message: String, mode: FT8Spot.Mode = .ft8, call: String? = "DL1ABC", grid: String? = "JO62",
                             cq: Bool = false, age: TimeInterval = 0) -> FT8Spot {
        FT8Spot(cycle: now.addingTimeInterval(-age), mode: mode, band: .m2, snr: -12.4, dt: 0.34, frequency: 1234.6,
                drift: mode == .wspr ? 0.5 : nil, message: message, call: call, grid: grid, gridFromMessage: grid != nil,
                isCQ: cq, viaOSD: false, powerDBm: mode == .wspr ? 37 : nil)
    }

    @Test("Aktionen: Band und Betriebsart werden geprüft gelesen")
    func actions() {
        #expect(RemoteFT8API.band("2m") == .m2)
        #expect(RemoteFT8API.band("2 m") == .m2)
        #expect(RemoteFT8API.band("6M") == .m6)
        #expect(RemoteFT8API.band("70cm") == .cm70)
        for bad in [nil, "", "10m", "2mm", "70", "<script>"] { #expect(RemoteFT8API.band(bad) == nil) }
        #expect(RemoteFT8API.modes("ft8") == .ft8)
        #expect(RemoteFT8API.modes("WSPR") == .wspr)
        #expect(RemoteFT8API.modes("both") == .both)
        for bad in [nil, "", "ft4", "1"] { #expect(RemoteFT8API.modes(bad) == nil) }
        for mode in FT8Model.Mode.allCases { #expect(RemoteFT8API.modes(RemoteFT8API.key(mode)) == mode) }
    }

    @Test("Spots: Filter „nur CQ“ behält CQ und WSPR, Entfernung und Richtung zum Standort")
    func spots() throws {
        let spots = [Self.spot("CQ DL1ABC JO62", cq: true), Self.spot("DK2XY DL1ABC -10", grid: nil),
                     Self.spot("DL1ABC JO62 37", mode: .wspr), Self.spot("CQ XX1XX ZZ99", call: "XX1XX", grid: "ZZ99", cq: true)]
        let (all, total) = RemoteFT8API.spotList(spots, home: (53.5, 10), cqOnly: false)
        #expect(total == 4 && all.count == 4)
        let (cq, cqTotal) = RemoteFT8API.spotList(spots, home: (53.5, 10), cqOnly: true)
        #expect(cqTotal == 3 && cq.map(\.msg) == ["CQ DL1ABC JO62", "DL1ABC JO62 37", "CQ XX1XX ZZ99"])
        let first = all[0]
        #expect(first.snr == -12 && first.dt == 0.3 && first.hz == 1235 && first.cq)
        #expect(first.lat == 52.5 && first.lon == 13)   // Mitte von JO62
        let km = try #require(first.km)
        #expect(km > 200 && km < 300)
        #expect(first.dir == "SO" || first.dir == "O")
        #expect(all[1].km == nil && all[1].lat == nil)
        #expect(all[2].dbm == 37 && all[2].drift == 0.5 && all[2].mode == "WSPR")
        #expect(all[3].lat == nil && all[3].km == nil)   // ungültiger Locator
        let (noHome, _) = RemoteFT8API.spotList(spots, home: nil, cqOnly: false)
        #expect(noHome[0].km == nil && noHome[0].lat == 52.5)
    }

    @Test("Grenzen: höchstens 300 Spots und 500 Stationen, Nachricht gekürzt")
    func limits() {
        let spots = (0..<400).map { Self.spot(String(repeating: "X", count: $0 == 0 ? 200 : 10), age: Double($0)) }
        let (list, total) = RemoteFT8API.spotList(spots, home: nil, cqOnly: false)
        #expect(list.count == RemoteFT8API.maxSpots && total == 400)
        #expect(list[0].msg.count == 80)
        let stations = (0..<700).map {
            FT8Station(call: "DL\($0)", grid: "JO62", latitude: 52.5, longitude: 13, lastHeard: Self.now.addingTimeInterval(Double(-$0)),
                       lastMode: .ft8, bestSNR: -.infinity, spots: 1)
        }
        let out = RemoteFT8API.stationList(stations)
        #expect(out.count == RemoteFT8API.maxStations && out[0].call == "DL0" && out[0].snr == 0)
    }

    @Test("JSON: vorgesehene Felder, Zyklen passend zur Betriebsart")
    func jsonShape() throws {
        let model = FT8Model()
        let s = RemoteFT8API.state(model, remote: false, home: (53.5, 10), cqOnly: true, now: Self.now)
        let data = try JSONEncoder().encode(s)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["running", "remote", "band", "modes", "bands", "ft8MHz", "wsprMHz", "decodes", "cycles",
                                     "now", "calibrated", "home", "homeGrid", "cqOnly", "total", "spots", "stations"])
        #expect(s.bands == ["2 m", "6 m", "70 cm"])
        #expect(s.now == 1_800_000_000_000)
        #expect(s.homeGrid?.hasPrefix("JO53") == true)
        #expect(s.cycles.map(\.mode) == (model.mode == .both ? ["FT8", "WSPR"] : model.mode == .ft8 ? ["FT8"] : ["WSPR"]))
        #expect(s.spots.isEmpty && s.total == 0 && s.signal == nil)
    }
}
