import Foundation
import Testing
@testable import PortaPackManager

/// Spaltensortierung der Tabellen (`ColumnSort`, ≈ 40 Tabellen).
@Suite("Spaltensortierung")
struct ColumnSortTests {
    struct Row: Equatable {
        var name: String
        var value: Int?
    }

    static let rows = [Row(name: "b", value: 2), Row(name: "a", value: nil), Row(name: "c", value: 1)]

    @Test("Zahlen auf- und absteigend, fehlende Werte stehen in beiden Richtungen am Ende")
    func zahlen() {
        var sort = ColumnSort<Row>("wert") { $0.value }
        #expect(Self.rows.sorted(by: [sort]).map(\.name) == ["c", "b", "a"])
        sort.order = .reverse
        #expect(Self.rows.sorted(by: [sort]).map(\.name) == ["b", "c", "a"])
    }

    @Test("Text wie im Finder: Zahlen numerisch, ohne Groß/klein, leer zählt als fehlend")
    func text() {
        let rows = [Row(name: "Datei 10"), Row(name: ""), Row(name: "datei 2"), Row(name: "Datei 1")]
        var sort = ColumnSort<Row>("name", text: { $0.name })
        #expect(rows.sorted(by: [sort]).map(\.name) == ["Datei 1", "datei 2", "Datei 10", ""])
        sort.order = .reverse
        #expect(rows.sorted(by: [sort]).map(\.name) == ["Datei 10", "datei 2", "Datei 1", ""])
    }

    @Test("Ohne gewählte Spalte bleibt die Reihenfolge des Modells; zweite Spalte entscheidet Gleichstand")
    func reihenfolge() {
        #expect(Self.rows.sorted(by: [ColumnSort<Row>]()) == Self.rows)
        let rows = [Row(name: "x", value: 1), Row(name: "a", value: 2), Row(name: "b", value: 1)]
        let byValue = ColumnSort<Row>("wert") { $0.value }
        let byName = ColumnSort<Row>("name", text: { $0.name })
        #expect(rows.sorted(by: [byValue, byName]).map(\.name) == ["b", "x", "a"])
    }

    @Test("Gleichheit nur über Kennung und Richtung (SwiftUI vergleicht so die gewählte Spalte)")
    func gleichheit() {
        let a = ColumnSort<Row>("wert") { $0.value }
        let b = ColumnSort<Row>("wert") { -($0.value ?? 0) }
        var c = a
        c.order = .reverse
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Frischer Vergleicher: Entfernung zum neuen Standort, Richtung aus der Tabelle")
    func frischerVergleicher() {
        let rows = [Row(name: "nah-alt", value: 10), Row(name: "nah-neu", value: 90)]
        // Die Tabelle hält den Vergleicher aus dem Moment des Klicks (Standort bei 0).
        var stale = ColumnSort<Row>("entfernung") { abs(($0.value ?? 0) - 0) }
        stale.order = .forward
        let fresh = ColumnSort<Row>("entfernung") { abs(($0.value ?? 0) - 100) }
        #expect(rows.sorted(by: [stale]).map(\.name) == ["nah-alt", "nah-neu"])
        #expect(rows.sorted(by: [stale], current: [fresh]).map(\.name) == ["nah-neu", "nah-alt"])
        stale.order = .reverse
        #expect(rows.sorted(by: [stale], current: [fresh]).map(\.name) == ["nah-alt", "nah-neu"])
        // Andere Spalten bleiben unberührt; ohne Auswahl bleibt die Reihenfolge.
        let byName = ColumnSort<Row>("name", text: { $0.name })
        #expect(rows.reversed().sorted(by: [byName], current: [fresh]).map(\.name) == ["nah-alt", "nah-neu"])
        #expect(rows.sorted(by: [], current: [fresh]) == rows)
    }
}

extension ColumnSortTests.Row {
    init(name: String) { self.init(name: name, value: nil) }
}
