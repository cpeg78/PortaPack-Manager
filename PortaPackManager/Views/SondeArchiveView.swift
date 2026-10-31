import AppKit
import CoreLocation
import SwiftUI

/// Sondenarchiv: alle bisher empfangenen Flüge aus den Meldungsprotokollen,
/// mit Bahn auf der Karte und Verlauf.
struct SondeArchiveView: View {
    @AppStorage(ArchiveMaintenance.retentionKey) private var retention = 0
    @State private var flights: [SondeFlight] = []
    @State private var loading = true
    @State private var selection: SondeFlight.ID?
    @State private var order: [ColumnSort<SondeFlight>] = []
    @State private var search = ""
    @State private var deleting: SondeFlight?
    @State private var mapController = MapController()

    private var filtered: [SondeFlight] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = term.isEmpty ? flights : flights.filter { $0.serial.lowercased().contains(term) || $0.type.lowercased().contains(term) }
        return list.sorted(by: order)
    }

    private var selected: SondeFlight? { flights.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sondenarchiv").font(.headline)
                TextField("Seriennummer suchen", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Text(loading ? "Lade …" : "\(filtered.count) Flüge").foregroundStyle(.secondary)
                Spacer()
                SettingsHint(.archive, "Aufbewahren: \(ArchiveRetentionPicker.title(retention))")
                    .fixedSize()
                Button("Aktualisieren") { Task { await reload() } }
                Button("CSV sichern …") { if let selected { export(selected) } }.disabled(selected == nil)
                Button("Auf SondeHub") {
                    if let selected, let url = URL(string: "https://sondehub.org/\(selected.serial)") { NSWorkspace.shared.open(url) }
                }
                .disabled(selected == nil)
                Button("Löschen …", role: .destructive) { deleting = selected }
                    .disabled(selected.map(Self.isLive) ?? true)
                    .help("Den gewählten Flug samt Messdaten aus dem Archiv entfernen")
            }
            .padding(10)
            Divider()
            // HStack statt HSplitView (siehe ArchiveView). Eigenes Fenster, daher kein „Schließen“.
            HStack(spacing: 0) {
                table.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    if let flight = selected {
                        trackMap(flight).frame(minHeight: 220, maxHeight: .infinity)
                        Divider()
                        SondeHistoryView(flight: flight).frame(minHeight: 260, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Einen Flug wählen", systemImage: "balloon",
                                               description: Text("Bahn und Verlauf erscheinen hier."))
                    }
                }
                .frame(minWidth: 460, idealWidth: 620, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 940, minHeight: 560)
        .confirmationDialog(deleting.map { String(localized: "Flug \($0.serial) löschen?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let flight = deleting { Task { await delete(flight) } }
                deleting = nil
            }
        } message: {
            Text("Alle \(deleting?.samples.count ?? 0) Meldungen werden aus dem Archiv entfernt. Das lässt sich nicht rückgängig machen.")
        }
        .onDeleteCommand { if let selected, !Self.isLive(selected) { deleting = selected } }
        .task { await reload() }
        .onChange(of: selection) { _, _ in mapController.showAll(animated: false) }
    }

    /// Noch empfangene Flüge nicht löschen – das Protokoll wird gerade geschrieben.
    static func isLive(_ flight: SondeFlight) -> Bool { Date().timeIntervalSince(flight.last) < 15 * 60 }

    private func delete(_ flight: SondeFlight) async {
        let serial = flight.serial
        await Task.detached(priority: .userInitiated) { SondeArchive.delete(serial: serial) }.value
        selection = nil
        await reload()
    }

    private func reload() async {
        loading = true
        let result = await Task.detached(priority: .userInitiated) { SondeArchive.load() }.value
        flights = result
        if selection == nil || !result.contains(where: { $0.id == selection }) { selection = result.first?.id }
        loading = false
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $order) {
            TableColumn("Datum", sortUsing: ColumnSort("datum") { $0.first }) { f in
                Text(f.first.formatted(.dateTime.day().month().year().hour().minute())).monospacedDigit()
            }.width(min: 110, ideal: 130)
            TableColumn("Seriennr.", sortUsing: ColumnSort("serie", text: { $0.serial })) { f in
                Text(f.serial).font(.body.monospaced())
            }.width(min: 80, ideal: 95)
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { $0.type })) { Text($0.type) }.width(50)
            TableColumn("Gipfel", sortUsing: ColumnSort("gipfel") { $0.peak?.altitude }) { f in
                Text(f.peak?.altitude.map { "\(($0 / 1000).formatted(.number.precision(.fractionLength(1)))) km" } ?? "–").monospacedDigit()
                    .foregroundStyle(f.burst ? .primary : .secondary)
                    .help(f.burst ? "Geplatzt und im Sinkflug gehört" : "Nur im Aufstieg gehört")
            }.width(60)
            TableColumn("Dauer", sortUsing: ColumnSort("dauer") { $0.duration }) { f in
                Text(Self.duration(f.duration)).monospacedDigit()
            }.width(55)
            TableColumn("Strecke", sortUsing: ColumnSort("strecke") { $0.distanceKm }) { f in
                Text(f.distanceKm.map { "\(($0).formatted(.number.precision(.fractionLength(0)))) km" } ?? "–").monospacedDigit()
            }.width(60)
            TableColumn("Tiefst", sortUsing: ColumnSort("temp") { $0.minTemperature }) { f in
                Text(f.minTemperature.map { "\(($0).formatted(.number.precision(.fractionLength(0)))) °C" } ?? "–").monospacedDigit()
            }.width(55)
            TableColumn("MHz", sortUsing: ColumnSort("mhz") { $0.frequencyMHz }) { f in
                Text(f.frequencyMHz.map { "\(($0).formatted(.number.precision(.fractionLength(3))))" } ?? "–").monospacedDigit()
            }.width(60)
            TableColumn("Meldungen", sortUsing: ColumnSort("meldungen") { $0.samples.count }) { f in
                Text("\(f.samples.count)").monospacedDigit()
            }.width(70)
        }
        .contextMenu(forSelectionType: SondeFlight.ID.self) { ids in
            if let id = ids.first, let flight = flights.first(where: { $0.id == id }) {
                Button("Löschen …", role: .destructive) { deleting = flight }
                    .disabled(Self.isLive(flight))
            }
        }
        .overlay {
            if !loading && flights.isEmpty {
                ContentUnavailableView("Noch keine Sonden", systemImage: "balloon",
                                       description: Text("Hier landet jeder Sondenflug, den du empfangen hast – auch aus dem Empfangsplan."))
            }
        }
    }

    private func trackMap(_ flight: SondeFlight) -> some View {
        let track = flight.positioned.map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) }
        var features: [MapFeature] = []
        if track.count > 1 {
            var line = MapFeature.line("track", track, color: MapColor.selected, width: 3, arrows: true)
            line.fit = true
            features.append(line)
        }
        if let start = track.first {
            features.append(.badge("start", at: start, symbol: .ascent, color: MapColor.green,
                                   label: String(localized: "Erste Position")))
        }
        if let peak = flight.peak, let lat = peak.latitude, let lon = peak.longitude {
            features.append(.badge("peak", at: CLLocationCoordinate2D(latitude: lat, longitude: lon), symbol: .balloon,
                                   color: MapColor.blue,
                                   label: String(localized: "Gipfel \(((peak.altitude ?? 0) / 1000).formatted(.number.precision(.fractionLength(1)))) km")))
        }
        if let end = track.last, track.count > 1 {
            features.append(.badge("end", at: end, symbol: .scope, color: MapColor.red,
                                   label: flight.burst ? String(localized: "Letzte Position (Sinkflug)") : String(localized: "Letzte Position")))
        }
        return LeafletMap(features: features, controller: mapController,
                          options: MapOptions(fitMaxZoom: 12, center: track.last.map(MapPoint.init) ?? MapPoint(51, 10),
                                              zoom: track.isEmpty ? 5 : 9))
            .overlay {
                if track.isEmpty {
                    Text("Keine Position empfangen").padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? String(format: "%d:%02d h", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    private func export(_ flight: SondeFlight) {
        Task {
            let name = "Sonde_\(flight.serial)_\(flight.first.formatted(.iso8601.year().month().day())).csv"
            guard let url = await SaveSheet.url(name: name, types: [.commaSeparatedText]) else { return }
            try? SondeArchive.csv(flight).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
