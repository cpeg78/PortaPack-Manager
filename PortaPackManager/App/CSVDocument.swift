import Foundation

/// Ein Feld einer CSV-Tabelle. Text geht durch `TrafficArchive.csvField`
/// (Anführungszeichen, Formelschutz), Zahlen und Zeiten stehen ohne
/// Anführungszeichen – sonst würde ein negativer Pegel („-42“) vom
/// Formelschutz zu „'-42“ und wäre in der Tabellenkalkulation keine Zahl mehr.
enum CSVValue: Sendable, Equatable {
    case text(String?)
    /// Dezimalzahl mit Punkt (wie das Archiv), `digits` Nachkommastellen.
    case number(Double?, digits: Int = 1)
    case integer(Int?)
    /// ISO-8601 in UTC (`ISOTime`).
    case date(Date?)
    /// 1 / 0, leer = unbekannt.
    case flag(Bool?)

    var field: String {
        switch self {
        case .text(let s): return TrafficArchive.csvField(s ?? "")
        case .number(let v, let digits):
            guard let v, v.isFinite else { return "" }
            return String(format: "%.\(max(0, min(digits, 9)))f", locale: Locale(identifier: "en_US_POSIX"), v)
        case .integer(let v): return v.map(String.init) ?? ""
        case .date(let d): return d.map(ISOTime.string) ?? ""
        case .flag(let b): return b.map { $0 ? "1" : "0" } ?? ""
        }
    }
}

/// Gemeinsamer CSV-Export der Live-Listen: Spaltenkopf, `;` getrennt,
/// UTF-8 mit BOM (sonst liest Excel Umlaute als Latin-1), Zeilenende `\r\n`.
/// Felder mit `;`, Anführungszeichen oder Zeilenumbruch sind durch die
/// Anführungszeichen von `csvField` geschützt.
struct CSVDocument: Sendable, Equatable {
    var header: [String]
    var rows: [[CSVValue]]

    init(header: [String], rows: [[CSVValue]] = []) {
        self.header = header
        self.rows = rows
    }

    /// Der Text ohne BOM. Fehlende Felder einer Zeile werden leer aufgefüllt,
    /// überzählige abgeschnitten – jede Zeile hat so viele Spalten wie der Kopf.
    func text() -> String {
        var out = header.map { TrafficArchive.csvField($0) }.joined(separator: ";") + "\r\n"
        for row in rows {
            var fields = row.prefix(header.count).map(\.field)
            if fields.count < header.count { fields += Array(repeating: "", count: header.count - fields.count) }
            out += fields.joined(separator: ";")
            out += "\r\n"
        }
        return out
    }

    /// Dateiinhalt: BOM + UTF-8.
    func data() -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text().utf8))
        return data
    }

    /// Dateiname mit Zeitstempel, z. B. `acars-2026-10-29_14-05.csv`.
    static func fileName(_ base: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return "\(base)-\(f.string(from: date)).csv"
    }

    /// Bytes als Hex („0A 1F …“) – für Rohdatenspalten.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
