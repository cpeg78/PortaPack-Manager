import SwiftUI

/// Einheitliche Rückfrage vor dem Löschen (Bedienungs-Review 29.10.2026):
/// Titel nennt Name bzw. Anzahl, der Knopf hat die destruktive Rolle, die
/// Nachricht sagt, was verloren geht. Vorher löschten Schlüssel, Aufnahmen und
/// Messungen sofort, SD-Karte und Sondenarchiv fragten – uneinheitlich.
///
/// Wie alle Dialoge nicht an `HSplitView`/`ControlsSplit` hängen, sondern an
/// eine Ansicht darin (Formular des Bedienfelds, Tabelle).
struct DeleteConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var confirmLabel: String = String(localized: "Löschen")
    let action: () -> Void
}

extension View {
    func deleteConfirmation(_ item: Binding<DeleteConfirmation?>) -> some View {
        confirmationDialog(item.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { item.wrappedValue != nil },
                                                set: { if !$0 { item.wrappedValue = nil } }),
                           presenting: item.wrappedValue) { request in
            Button(request.confirmLabel, role: .destructive) { request.action() }
            Button("Abbrechen", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}
