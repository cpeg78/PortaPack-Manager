import Foundation

/// Sortierung einer Tabellenspalte per Klick auf die Kopfzeile. Der Schlüssel
/// kommt aus einer Closure, damit auch berechnete Werte (Entfernung) und
/// optionale Felder gehen; fehlende Werte stehen in beiden Richtungen am Ende.
struct ColumnSort<Row>: SortComparator, @unchecked Sendable {
    let id: String
    var order: SortOrder = .forward
    private let isMissing: (Row) -> Bool
    private let compareValues: (Row, Row) -> ComparisonResult

    /// Vergleichbarer Schlüssel; `nil` = kein Wert.
    init<Key: Comparable>(_ id: String, _ key: @escaping (Row) -> Key?) {
        self.id = id
        isMissing = { key($0) == nil }
        compareValues = { a, b in
            guard let x = key(a), let y = key(b) else { return .orderedSame }
            return x < y ? .orderedAscending : y < x ? .orderedDescending : .orderedSame
        }
    }

    /// Text wie im Finder (Zahlen numerisch, ohne Groß/klein); leer = kein Wert.
    init(_ id: String, text: @escaping (Row) -> String?) {
        self.id = id
        isMissing = { text($0)?.isEmpty ?? true }
        compareValues = { a, b in (text(a) ?? "").localizedStandardCompare(text(b) ?? "") }
    }

    func compare(_ a: Row, _ b: Row) -> ComparisonResult {
        switch (isMissing(a), isMissing(b)) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        let result = compareValues(a, b)
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.order == rhs.order }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(order)
    }
}

extension Array {
    /// Ohne gewählte Spalte bleibt die Reihenfolge des Modells (meist „zuletzt
    /// gehört zuerst“).
    func sorted(by order: [ColumnSort<Element>]) -> [Element] {
        order.isEmpty ? self : sorted(using: order)
    }
}
