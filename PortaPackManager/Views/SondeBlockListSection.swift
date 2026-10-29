import SwiftUI

/// „Wetterballons: Dauerstörer“ in den Einstellungen (Antenne & Gerät): die
/// Frequenzbereiche, die die Sondensuche übergeht (`SondeBlockList`). Ab Werk
/// leer; anzeigen, ergänzen, löschen, zurücksetzen.
struct SondeBlockListSection: View {
    @State private var ranges = SondeBlockList.shared.current
    @State private var entry = ""
    @State private var invalid = false

    var body: some View {
        Section("Wetterballons: Dauerstörer") {
            Text("Die Sondensuche übergeht diese Frequenzen – Störer am eigenen Standort, die nie eine Sonde sind. Ab Werk ist die Liste leer. Eine Sonde, die du festhältst, empfängt die App trotzdem.")
                .font(.caption).foregroundStyle(.secondary)
            if ranges.isEmpty {
                Text("Keine Sperrbereiche").foregroundStyle(.secondary)
            }
            ForEach(ranges, id: \.lowerBound) { range in
                HStack {
                    Text(SondeBlockList.displayMHz(range)).monospacedDigit()
                    Spacer()
                    Button {
                        apply(ranges.filter { $0 != range })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Sperrbereich entfernen")
                }
            }
            HStack {
                TextField("Neuer Bereich, z. B. 403,903–403,920", text: $entry)
                    .onSubmit(add)
                Button("Hinzufügen", action: add)
                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if invalid {
                Text("Bitte in MHz eingeben, zwischen 400 und 406 – ein Bereich „von–bis“ oder eine Frequenz (dann ±5 kHz).")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Ab Werk") {
                    SondeBlockList.shared.resetToFactory()
                    ranges = SondeBlockList.shared.current
                }
                .disabled(ranges == SondeBlockList.factoryRanges)
            }
        }
    }

    private func add() {
        guard let range = SondeBlockList.parseMHz(entry) else { invalid = true; return }
        invalid = false
        entry = ""
        apply(ranges + [range])
    }

    private func apply(_ list: [ClosedRange<Double>]) {
        SondeBlockList.shared.set(list)
        ranges = SondeBlockList.shared.current
    }
}
