import SwiftUI

/// Eigener Standort (gemeinsam für alle Kartenseiten): von Hand, über die
/// Ortungsdienste des Mac oder von der GPS-Seite übernommen.
struct HomeLocationSection: View {
    var note: LocalizedStringKey?
    /// Ersteinrichtung: einmal von selbst orten, solange kein Standort gesetzt ist.
    var autoLocate = false
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var locating = false
    @State private var message: String?

    var body: some View {
        Section("Standort") {
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Breite") {
                TextField("", value: $homeLat, format: .number.precision(.fractionLength(4)))
                    .multilineTextAlignment(.trailing).frame(width: 90)
            }
            LabeledContent("Länge") {
                TextField("", value: $homeLon, format: .number.precision(.fractionLength(4)))
                    .multilineTextAlignment(.trailing).frame(width: 90)
            }
            HStack {
                Button("Meinen Standort übernehmen", systemImage: "location") { locate() }
                    .disabled(locating)
                if locating { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            // Ein Versuch je Installation – abgelehnt bleibt abgelehnt (`AppServices.autoLocateTriedKey`).
            let defaults = UserDefaults.standard
            guard autoLocate, homeLat == 0, homeLon == 0,
                  !defaults.bool(forKey: AppServices.autoLocateTriedKey) else { return }
            defaults.set(true, forKey: AppServices.autoLocateTriedKey)
            locate()
        }
    }

    private func locate() {
        locating = true
        message = nil
        Task {
            defer { locating = false }
            do {
                let location = try await LocationProvider.shared.currentLocation()
                homeLat = (location.coordinate.latitude * 10_000).rounded() / 10_000
                homeLon = (location.coordinate.longitude * 10_000).rounded() / 10_000
                message = String(localized: "Übernommen, Genauigkeit ± \(Int(location.horizontalAccuracy.rounded())) m.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
