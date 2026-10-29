import Foundation

/// ISO-8601-Zeitstempel lesen und schreiben, ohne `ISO8601DateFormatter`.
///
/// `ISO8601DateFormatter.date(from:)` lädt bei jedem Aufruf die ICU-Symboltabellen
/// neu (≈ 40–60 µs, in der App mit `de_DE` bis ≈ 350 µs je Aufruf); ein neu
/// angelegter Formatter kostet zusätzlich ≈ 70 µs. Das Sondenarchiv (12 552
/// Zeilen) brauchte so 4,6 s CPU (Review L1, 29.10.2026). `Date.ISO8601FormatStyle`
/// liest in ≈ 0,3–0,8 µs und schreibt in ≈ 0,1 µs.
///
/// Formate wie bisher: `2026-10-27T10:45:00Z` (UTC, ohne Bruchteile) bzw. mit
/// Millisekunden `2026-10-27T10:45:00.123Z`. Unterschied beim Schreiben: Bruchteile
/// werden abgeschnitten statt gerundet (höchstens 1 ms Abweichung). Beim Lesen
/// werden Zeitzonen-Versätze (`+02:00`) wie bisher angenommen, zusätzlich auch
/// Bruchteile in Zeilen ohne Bruchteil-Format – alles, was der alte Formatter
/// las, liest auch dieser (`ISOTimeTests`).
enum ISOTime {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// `2026-10-27T10:45:00Z`
    static func string(_ date: Date) -> String { plain.format(date) }

    /// `2026-10-27T10:45:00.123Z`
    static func fractionalString(_ date: Date) -> String { fractional.format(date) }

    /// Liest mit und ohne Bruchteile, `Z` oder Versatz. Führende Leerzeichen wie
    /// beim alten Formatter überlesen.
    static func date<S: StringProtocol>(_ text: S) -> Date? {
        var s = Substring(text)
        while s.first == " " { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let string = String(s)
        if let date = try? plain.parse(string) { return date }
        return try? fractional.parse(string)
    }
}
