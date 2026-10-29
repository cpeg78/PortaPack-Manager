import SwiftUI

/// Aufbewahrung des ganzen Archivs (Flugzeuge, Schiffe, Radiosonden,
/// Flugfunk-Verlauf). Gilt gemeinsam; steht in den Einstellungen (Bereich
/// Archiv), die Archivfenster verweisen mit `SettingsHint` darauf.
///
/// Verkürzen löscht ältere Einträge unwiderruflich. Deshalb fragt die Auswahl
/// vorher nach und nennt die Zahl der betroffenen Einträge – ein Fehlgriff auf
/// „30 Tage“ löschte sonst sofort alles Ältere (Review 28.10.2026, W12).
struct ArchiveRetentionPicker: View {
    @AppStorage(ArchiveMaintenance.retentionKey) private var days = 0
    @State private var pending: Pending?

    struct Pending: Equatable {
        var days: Int
        var entries: Int
    }

    var body: some View {
        Picker("Aufbewahren", selection: Binding(get: { days }, set: { request($0) })) {
            ForEach(Self.choices, id: \.days) { Text($0.title).tag($0.days) }
        }
        .fixedSize()
        .help("Gilt für Flugzeuge, Schiffe, Radiosonden und den Flugfunk-Verlauf. Ältere Einträge löscht die App von selbst.")
        .confirmationDialog(pending.map { String(localized: "Aufbewahrung auf \(Self.title($0.days)) verkürzen?") } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { change in
            Button(change.entries == 1 ? String(localized: "1 Eintrag löschen") : String(localized: "\(change.entries) Einträge löschen"), role: .destructive) {
                days = change.days
                pending = nil
                ArchiveMaintenance.runNow()
            }
            Button("Abbrechen", role: .cancel) { pending = nil }
        } message: { change in
            Text(Self.message(change))
        }
    }

    static var choices: [(days: Int, title: String)] {
        [(0, String(localized: "Unbegrenzt")), (730, String(localized: "2 Jahre")), (365, String(localized: "1 Jahr")),
         (90, String(localized: "90 Tage")), (30, String(localized: "30 Tage"))]
    }

    static func title(_ days: Int) -> String { choices.first { $0.days == days }?.title ?? String(localized: "\(days) Tage") }

    static func message(_ change: Pending) -> String {
        change.entries == 1
            ? String(localized: "Ein Archiveintrag ist älter als \(title(change.days)) und wird sofort gelöscht. Das lässt sich nicht rückgängig machen.")
            : String(localized: "\(change.entries) Archiveinträge sind älter als \(title(change.days)) und werden sofort gelöscht (Flugzeuge, Schiffe, Sondenmeldungen und Flugfunk zusammen). Das lässt sich nicht rückgängig machen.")
    }

    /// Verkürzt die neue Frist die bisherige? Nur dann kann sie Einträge löschen.
    static func isShortening(from old: Int, to new: Int) -> Bool {
        new > 0 && (old == 0 || new < old)
    }

    private func request(_ value: Int) {
        guard value != days else { return }
        guard Self.isShortening(from: days, to: value) else {
            days = value
            ArchiveMaintenance.runNow()
            return
        }
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                ArchiveMaintenance.expiringCount(retentionDays: value)
            }.value
            if entries == 0 {
                days = value
                ArchiveMaintenance.runNow()
            } else {
                pending = Pending(days: value, entries: entries)
            }
        }
    }
}
