import Foundation
import Testing
@testable import PortaPackManager

@Suite("CSV-Export der Live-Listen")
struct CSVDocumentTests {
    @Test("Kopf, Semikolon, Zeilenende und BOM")
    func layout() {
        let doc = CSVDocument(header: ["zeit", "name", "pegel_db"],
                              rows: [[.date(Date(timeIntervalSince1970: 0)), .text("Möwe"), .number(-42.25, digits: 1)]])
        #expect(doc.text() == "\"zeit\";\"name\";\"pegel_db\"\r\n1970-01-01T00:00:00Z;\"Möwe\";-42.2\r\n"
                || doc.text() == "\"zeit\";\"name\";\"pegel_db\"\r\n1970-01-01T00:00:00Z;\"Möwe\";-42.3\r\n")
        let data = doc.data()
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(data: data.dropFirst(3), encoding: .utf8) == doc.text())
    }

    @Test("Formelschutz für Text, nicht für Zahlen")
    func formulas() {
        #expect(CSVValue.text("=HYPERLINK(\"x\")").field == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(CSVValue.text("+49 123").field == "\"'+49 123\"")
        #expect(CSVValue.text("-1").field == "\"'-1\"")
        #expect(CSVValue.text("@SUM(A1)").field == "\"'@SUM(A1)\"")
        #expect(CSVValue.text("\tx").field == "\"'\tx\"")
        // Eigene Zahlen stehen unverändert und ohne Anführungszeichen da.
        #expect(CSVValue.number(-87.5, digits: 1).field == "-87.5")
        #expect(CSVValue.integer(-3).field == "-3")
    }

    @Test("Trennzeichen, Anführungszeichen und Zeilenumbrüche bleiben im Feld")
    func embedded() {
        let doc = CSVDocument(header: ["a", "b"], rows: [[.text("x;y"), .text("Zeile 1\nZeile 2 \"zitiert\"\r\nEnde")]])
        let line = doc.text().components(separatedBy: "\r\n")[1...].joined(separator: "\r\n")
        #expect(line.hasPrefix("\"x;y\";\"Zeile 1\nZeile 2 \"\"zitiert\"\"\r\nEnde\""))
        // Ein einfacher Leser, der Anführungszeichen beachtet, sieht genau zwei Felder.
        #expect(Self.parse(doc.text()) == [["a", "b"], ["x;y", "Zeile 1\nZeile 2 \"zitiert\"\r\nEnde"]])
    }

    @Test("Leere Werte, NaN, Wahrheitswerte und Spaltenzahl")
    func values() {
        #expect(CSVValue.text(nil).field == "\"\"")
        #expect(CSVValue.number(nil).field == "")
        #expect(CSVValue.number(.nan).field == "")
        #expect(CSVValue.number(.infinity).field == "")
        #expect(CSVValue.number(1234.5678, digits: 2).field == "1234.57")
        #expect(CSVValue.number(3, digits: 0).field == "3")
        #expect(CSVValue.integer(nil).field == "")
        #expect(CSVValue.date(nil).field == "")
        #expect(CSVValue.flag(true).field == "1" && CSVValue.flag(false).field == "0" && CSVValue.flag(nil).field == "")
        let doc = CSVDocument(header: ["a", "b", "c"], rows: [[.integer(1)], [.integer(1), .integer(2), .integer(3), .integer(4)]])
        #expect(doc.text() == "\"a\";\"b\";\"c\"\r\n1;;\r\n1;2;3\r\n")
    }

    @Test("Dezimalpunkt unabhängig von der Spracheinstellung")
    func decimalPoint() {
        // `String(format:)` ohne Locale wäre hier sicher, mit `de_DE` aber nicht – deshalb POSIX fest.
        #expect(CSVValue.number(0.5, digits: 3).field == "0.500")
    }

    @Test("Dateiname mit Zeitstempel")
    func fileName() {
        let name = CSVDocument.fileName("acars", date: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("acars-19") && name.hasSuffix(".csv"))
        #expect(CSVDocument.hex([0x0A, 0xFF]) == "0A FF")
    }

    /// Minimaler CSV-Leser (RFC 4180 mit `;`) für die Rundlaufprobe.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == ";" { row.append(field); field = "" }
            else if c == "\r\n" || c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        return rows
    }
}
