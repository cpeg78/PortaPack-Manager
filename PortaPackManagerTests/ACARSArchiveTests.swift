import Foundation
import Testing
@testable import PortaPackManager

@Suite("ACARS/VDL2: Archiv")
struct ACARSArchiveTests {
    private func message(_ id: Int, registration: String, label: String, text: String, at time: TimeInterval,
                         continued: Bool = false, icao: UInt32? = nil) -> ACARSMessage {
        var m = ACARSMessage(frequencyMHz: 136.975, levelDB: -42.5, mode: "2", registration: registration, acknowledge: " ",
                             label: label, blockID: "3", text: text, continued: continued, icao: icao)
        m.id = id
        m.date = Date(timeIntervalSince1970: time)
        m.flight = "LH1234"
        m.messageNumber = "M12A"
        return m
    }

    @Test("Gesichert wird erst, was fertig ist – offene Meldungen nach zwei Minuten")
    func finished() {
        let now = Date(timeIntervalSince1970: 10_000)
        let done = message(1, registration: "D-AIBL", label: "H1", text: "A", at: 9_990)
        let open = message(2, registration: "D-AIBL", label: "H1", text: "B", at: 9_990, continued: true)
        let stale = message(3, registration: "D-AIBL", label: "H1", text: "C", at: 9_800, continued: true)
        #expect(ACARSLog.finished([done, open, stale], stored: [], now: now).map(\.id) == [1, 3])
        #expect(ACARSLog.finished([done, open, stale], stored: [1, 3], now: now).isEmpty)
    }

    @Test("Schreiben, Lesen samt Deutungsfeldern, Volltext- und Kennzeichensuche")
    func storeAndSearch() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        var cpdlc = message(1, registration: "D-AIBL", label: "CPDLC", text: "CLIMB TO FL350", at: 1_000, icao: 0x3C6444)
        cpdlc.details = [["Freigabe", "FL350"]]
        let weather = message(2, registration: "OE-LBA", label: "H1", text: "METAR EDDH 041320Z 25012KT", at: 2_000)
        try db.database.sync { try $0.insertACARS([cpdlc, weather, cpdlc]) }   // doppelt → einmal
        let recent = try db.database.sync { try $0.recentACARS(limit: 10) }
        #expect(recent.map(\.text) == ["METAR EDDH 041320Z 25012KT", "CLIMB TO FL350"])
        let stored = try #require(recent.last)
        #expect(stored.id < 0)
        #expect(stored.icao == 0x3C6444)
        #expect(stored.details == [["Freigabe", "FL350"]])
        #expect(stored.blockID == "3" && stored.isDownlink)
        #expect(stored.messageNumber == "M12A" && stored.flight == "LH1234")
        #expect(stored.levelDB == -42.5)
        #expect(try db.database.sync { try $0.query("SELECT source FROM acars_messages ORDER BY time") { $0.text(0) } } == ["VDL2", "ACARS"])

        let log = ACARSLog(database: db.database)
        #expect(await log.search(userInput: "metar eddh").map(\.registration) == ["OE-LBA"])
        #expect(await log.search(userInput: "fl35").map(\.registration) == ["D-AIBL"])     // Wortanfang
        #expect(await log.search(userInput: "D-AIBL").map(\.label) == ["CPDLC"])           // Kennzeichen
        #expect(await log.search(userInput: "LH1234").count == 2)                          // Flug
        #expect(await log.search(userInput: "x").isEmpty)

        let summary = try db.database.sync { try $0.acarsSummary() }
        #expect(summary.entries == 2 && summary.distinct == 2)
    }
}
