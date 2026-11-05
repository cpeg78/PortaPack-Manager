import Foundation
import Testing
@testable import PortaPackManager

@Suite("ACARS-Deutung")
struct ACARSInterpreterTests {
    private func message(label: String, text: String, registration: String = "D-AIZZ", number: String? = "M12A",
                         block: Character = "3", continued: Bool = false) -> ACARSMessage {
        ACARSMessage(mode: "2", registration: registration, acknowledge: "!", label: label, blockID: block,
                     messageNumber: number, flight: "LH0034", text: text, continued: continued)
    }

    @Test("Media Advisory: Verbindung, Zeit, verfügbare Links")
    func mediaAdvisory() {
        let i = message(label: "SA", text: "0EV205802VS").interpretation
        #expect(i.summary == "Datenlink VDL2 hergestellt um 20:58:02 UTC")
        #expect(i.rows.contains { $0.name == "Verfügbar" && $0.value == "VDL2, Satcom" })
        let lost = message(label: "SA", text: "0LS1234567").interpretation
        #expect(lost.summary.contains("Satcom verloren"))
    }

    @Test("Squitter der Bodenstation: Station, Netz, Lage, Frequenz; weitere OOOI-Labels")
    func squitterAndOOOI() {
        let i = message(label: "SQ", text: "02XSEDDHAHDL15333N00959E136975V").interpretation
        #expect(i.summary == "Squitter der Bodenstation")
        #expect(i.rows.contains { $0.name == "Station" && $0.value == "EDDH" })
        #expect(i.rows.contains { $0.name == "Netz" && $0.value == "SITA" })
        #expect(i.rows.contains { $0.name == "Lage der Station" })
        #expect(i.rows.contains { $0.name == "Frequenz" && $0.value == "136.975 MHz" })
        // Ohne Lage/Frequenz bleibt es bei der Station.
        #expect(message(label: "SQ", text: "02XAEGLL").interpretation.rows.count == 2)
        #expect(message(label: "QK", text: "EDDHEDDF1412").interpretation.summary == "Landemeldung")
        #expect(message(label: "QS", text: "EDDF1430").interpretation.summary == "Am Gate (IN)")
    }

    @Test("Wetter: METAR in Felder zerlegt, TAF-Kopf")
    func weather() {
        let i = message(label: "51", text: "METAR EDDH 041320Z 25012G25KT 9999 FEW030 BKN045 M02/M05 Q1013=").interpretation
        #expect(i.summary == "Wetter EDDH: Wind 22 km/h aus 250°, Böen 46 km/h, -2 °C, QNH 1013")
        #expect(i.rows.contains { $0.name == "Sicht" && $0.value == "über 10 km" })
        #expect(i.rows.contains { $0.name == "Wolken" && $0.value == "durchbrochen 1372 m" })
        #expect(i.rows.contains { $0.name == "Temperatur" && $0.value == "-2 °C, Taupunkt -5 °C" })
        let us = message(label: "51", text: "METAR KJFK 041351Z VRB03KT 10SM CLR 08/M01 A3012").interpretation
        #expect(us.rows.contains { $0.name == "QNH" && $0.value == "1020 hPa" })
        let taf = message(label: "52", text: "TAF EDDF 041100Z 0412/0518 24010KT CAVOK").interpretation
        #expect(taf.summary == "Vorhersage EDDF vom 04. 12 Uhr bis 05. 18 Uhr UTC")
    }

    @Test("FMS-Fortschrittsmeldung: Ziel, Flugnummer, Zeitstempel")
    func fmsProgress() {
        let i = message(label: "H1", text: "#M1BPRG/DTEDDH,15O,71,205301,042/FNMBU7AE/TS204237,261026AEC").interpretation
        #expect(i.summary == "Fortschrittsmeldung")
        #expect(i.rows.contains { $0.name == "Ziel" && $0.value == "EDDH · 20:53:01" })
        #expect(i.rows.contains { $0.name == "Flugnummer" && $0.value == "MBU7AE" })
        #expect(i.rows.contains { $0.name == "Zeitstempel" && $0.value == "20:42:37 am 26.10.2026" })
        #expect(i.rows.first?.value.hasPrefix("M1 –") == true)
    }

    @Test("ACMS-Bericht: Strecke und Zeit aus dem CC-Block")
    func acms() {
        let i = message(label: "H1", text: "#DFBA321,111415,1,1,TB000000/REP001,84,01,1/CCTC-LSC,OCT26,192957,LTFM,EDDH,0006/C0TWP030").interpretation
        #expect(i.summary == "ACMS-Bericht REP001 · LTFM → EDDH")
        #expect(i.rows.contains { $0.name == "Zeit" && $0.value == "OCT26 19:29:57 UTC" })
    }

    @Test("Positionen in verschiedenen Schreibweisen")
    func positions() {
        let a = ACARSInterpreter.position(in: "POS N53.80015 E009.850396 FL350")
        #expect(a.map { abs($0.lat - 53.80015) < 1e-5 && abs($0.lon - 9.850396) < 1e-5 } == true)
        let b = ACARSInterpreter.position(in: "N5348.0W00951.0")
        #expect(b.map { abs($0.lat - 53.8) < 1e-3 && abs($0.lon + 9.85) < 1e-3 } == true)
        let c = ACARSInterpreter.position(in: "/PSN53480E009510")
        #expect(c.map { abs($0.lat - 53.8) < 1e-3 && abs($0.lon - 9.85) < 1e-3 } == true)
        #expect(ACARSInterpreter.position(in: "N99.5E200.1") == nil)
        let i = message(label: "15", text: "POS N53.80015 E009.850396 FL350").interpretation
        #expect(i.latitude != nil && i.altitudeFt == 35000)
        #expect(i.summary.contains("53.800° N 9.850° O"))
    }

    @Test("Base64-Blöcke gelten als Binärdaten, Freitext nicht")
    func opaque() {
        #expect(message(label: "H1", text: "#T1BzUnQWhE/X1MFSika7DXYRW7PQZYJ/4Qu/FI6SSYXsieYsDv1+uq3DYHqeR9+1by/XLv9c8Z3D+BdN20ls=").interpretation.opaque)
        #expect(!message(label: "5Z", text: "PLEASE CALL OPS AFTER LANDING").interpretation.opaque)
        #expect(message(label: "83", text: "V09CA032/ETA-30/2127/").interpretation.summary == "ETA 21:27 UTC")
    }

    @Test("Zusammensetzen: Folgeblöcke hängen an, der erste Teil wird ersetzt")
    func reassembly() {
        var r = ACARSReassembler()
        let a = message(label: "H1", text: "#DFBA321,", number: "D34A", block: "3", continued: true)
        let b = message(label: "H1", text: "REP001/CC", number: "D34B", block: "4", continued: true)
        let c = message(label: "H1", text: "ENDE", number: "D34C", block: "5", continued: false)
        let other = message(label: "Q0", text: "", registration: "G-TTNS", number: "S99A", block: "2")
        var first = r.add(a).message; first.id = 1
        var r2 = ACARSReassembler()
        var fa = a; fa.id = 1
        _ = r2.add(fa)
        _ = first
        let second = r2.add(b)
        #expect(second.replaces == 1)
        #expect(second.message.text == "#DFBA321,REP001/CC" && second.message.blocks == 2 && second.message.continued)
        let foreign = r2.add(other)
        #expect(foreign.replaces == nil)
        let third = r2.add(c)
        #expect(third.replaces == 1)
        #expect(third.message.text == "#DFBA321,REP001/CCENDE" && third.message.blocks == 3 && !third.message.continued)
        // Danach beginnt eine neue Nachricht mit derselben Nummer von vorn.
        #expect(r2.add(b).replaces == nil)
    }

    @Test("XID: Position und Zielflughafen aus den VDL-Parametern")
    func xid() throws {
        // Breite 53,7° = 537 → 0x219, Länge 9,9° = 99 → 0x063, Höhe 35 (×1000 ft)
        let loc: [UInt8] = [0x21, 0x90, 0x63, 35]
        let dest = Array("EDDH".utf8)
        let group: [UInt8] = [0x84, 4] + loc + [0x83, 4] + dest
        let bytes: [UInt8] = [0x82, 0xF0, 0, UInt8(group.count)] + group
        let parsed = try #require(VDL2Coding.parseXID(bytes))
        #expect(parsed.destination == "EDDH")
        #expect(parsed.location.map { abs($0.latitude - 53.7) < 1e-6 && abs($0.longitude - 9.9) < 1e-6 && $0.altitudeFt == 35000 } == true)
        // Negative Länge (West): −9,9° → −99 = 0xF9D
        let west: [UInt8] = [0x82, 0xF0, 0, 6, 0x84, 4, 0x21, 0x9F, 0x9D, 1]
        #expect(VDL2Coding.parseXID(west)?.location.map { abs($0.longitude + 9.9) < 1e-6 } == true)
    }

    @Test("Wichtige zuerst: Lotsenverkehr oben, Netzverwaltung unten")
    func relevance() {
        #expect(message(label: "CPDLC", text: "↓ Pilot: WILCO").relevance == 0)
        #expect(message(label: "ATN", text: "Routing (IDRP Keepalive)").relevance == 3)
        #expect(message(label: "_d", text: "").relevance == 3)
        #expect(message(label: "SA", text: "0EV205802VS").relevance == 1)
        #expect(message(label: "ATN", text: "x").relevance > message(label: "H1", text: "#M1BPRG/DTEDDH").relevance)
    }

    @Test("Deutung einmal gerechnet und gemerkt; der Zwischenspeicher zählt beim Vergleich nicht (Review 05.11.2026, U1)")
    func interpretationCache() {
        var cached = message(label: "15", text: "POS N53.80015 E009.850396 FL350")
        let fresh = cached
        cached.interpret()
        #expect(cached == fresh)
        #expect(cached.interpretation == fresh.interpretation)
        #expect(cached.interpretation.latitude != nil && cached.relevance == 0)
        var reassembler = ACARSReassembler()
        _ = reassembler.add(message(label: "15", text: "POS N53.80015 ", number: "M12A", continued: true))
        var merged = reassembler.add(message(label: "15", text: "E009.850396", number: "M12B")).message
        merged.interpret()
        #expect(merged.blocks == 2 && merged.interpretation.latitude != nil)
    }
}
