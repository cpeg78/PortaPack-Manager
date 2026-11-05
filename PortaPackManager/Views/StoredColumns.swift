import SwiftUI

/// Spaltenanordnung einer Tabelle – ein-/ausgeblendete, verschobene und
/// verbreiterte Spalten (Rechtsklick auf den Spaltenkopf) –, je Tabelle in
/// den UserDefaults gespeichert, damit sie einen Neustart übersteht.
///
/// ```swift
/// @StoredColumns("adsb") private var columns: TableColumnCustomization<Aircraft>
/// Table(rows, columnCustomization: $columns) { TableColumn(…).customizationID("hoehe") }
/// ```
/// Jede Spalte braucht eine feste `customizationID`, sonst lässt sie sich
/// nicht ausblenden.
///
/// Die Anordnung wird nur einmal je Ansicht aus den UserDefaults gelesen und
/// dann im Speicher gehalten – vorher dekodierte jedes Neuzeichnen der Seite
/// das JSON neu (in der Messung beim Scrollen sichtbar, 04.11.2026).
@propertyWrapper
struct StoredColumns<RowValue: Identifiable>: DynamicProperty {
    @State private var store: Store

    init(_ key: String) {
        _store = State(wrappedValue: Store(key: "tableColumns." + key))
    }

    var wrappedValue: TableColumnCustomization<RowValue> {
        get { store.value }
        nonmutating set { store.value = newValue }
    }

    var projectedValue: Binding<TableColumnCustomization<RowValue>> {
        Binding(get: { store.value }, set: { store.value = $0 })
    }

    /// Hält den dekodierten Wert; liest erst beim ersten Zugriff, schreibt bei jeder Änderung.
    @Observable
    final class Store {
        @ObservationIgnored private let key: String
        @ObservationIgnored private var loaded = false
        /// Schreiben gebündelt: beim Ziehen einer Spaltenbreite setzt `Table` das
        /// Binding je Mausbewegung – jedes Mal JSON zu kodieren und in die
        /// UserDefaults zu schreiben wäre unnötig (Review 05.11.2026).
        @ObservationIgnored private var saveTask: Task<Void, Never>?
        private var cached = TableColumnCustomization<RowValue>()

        init(key: String) { self.key = key }

        var value: TableColumnCustomization<RowValue> {
            get {
                if !loaded {
                    loaded = true
                    if let data = UserDefaults.standard.data(forKey: key),
                       let decoded = try? JSONDecoder().decode(TableColumnCustomization<RowValue>.self, from: data) {
                        _cached = decoded
                    }
                }
                return cached
            }
            set {
                loaded = true
                cached = newValue
                saveTask?.cancel()
                let key = key
                saveTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
                }
            }
        }
    }
}
