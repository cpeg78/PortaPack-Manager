import AppKit
import CoreLocation
import SwiftUI

/// Archiv der Sichtungen (Flugzeuge oder Schiffe) je Tag: Tabelle, Spur der
/// Auswahl, CSV-Export.
struct ArchiveView: View {
    let archive: TrafficArchive
    let aircraft: Bool

    @State private var mapController = MapController()
    @State private var days: [String] = []
    @State private var day = ""
    @State private var items: [ArchiveSighting] = []
    @State private var selection: ArchiveSighting.ID?
    @State private var search = ""
    @State private var order: [ColumnSort<ArchiveSighting>] = []
    /// Gefiltert und sortiert – zwischengespeichert, nicht bei jeder Auswertung von
    /// `body` neu (jeder Tastendruck filterte und sortierte sonst alle Sichtungen).
    @State private var rows: [ArchiveSighting] = []
    /// Sichtungen je Kennung in der geladenen Auswahl (Tag bzw. alle Tage).
    @State private var seenCounts: [String: Int] = [:]
    @State private var loading = false
    @AppStorage(ArchiveMaintenance.retentionKey) private var retention = 0
    /// Hochgezählt von „Neu laden“: lädt Tage und Sichtungen neu.
    @State private var reloads = 0
    /// Auswahl „Alle Tage“ im Tagesmenü.
    private static let allDays = "alle"

    static func filter(_ items: [ArchiveSighting], search: String) -> [ArchiveSighting] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return items }
        return items.filter { s in
            [s.key, s.name, s.registration, s.type, s.operatorName, s.route].compactMap { $0?.lowercased() }
                .contains { $0.contains(term) }
        }
    }

    /// Ohne Klick auf einen Spaltenkopf: zuletzt gesehen oben, bei gleicher Zeit
    /// der zuerst gesehene – vorher galt die Reihenfolge der Archivdatei, und die
    /// Zeiten sprangen (21:28, 21:29, 21:28 …).
    static func sort(_ items: [ArchiveSighting], order: [ColumnSort<ArchiveSighting>]) -> [ArchiveSighting] {
        guard order.isEmpty else { return items.sorted(by: order) }
        return items.sorted { ($0.last, $0.first) > ($1.last, $1.first) }
    }

    private func updateRows() {
        rows = Self.sort(Self.filter(items, search: search), order: order)
        seenCounts = Dictionary(grouping: items, by: \.key).mapValues(\.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(aircraft ? "Archiv: Flugzeuge" : "Archiv: Schiffe").font(.headline)
                Picker("Tag", selection: $day) {
                    if days.count > 1 { Text("Alle Tage").tag(Self.allDays) }
                    ForEach(days, id: \.self) { Text(Self.dayTitle($0)).tag($0) }
                }
                .frame(maxWidth: 220)
                TextField("Suchen", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                if loading { ProgressView().controlSize(.small) }
                Text("\(rows.count) Sichtungen").foregroundStyle(.secondary)
                Spacer()
                SettingsHint(.archive, "Aufbewahren: \(ArchiveRetentionPicker.title(retention))")
                    .fixedSize()
                Button("Neu laden") { reload() }
                Button("CSV sichern …") { exportCSV() }.disabled(items.isEmpty)
            }
            .padding(10)
            Divider()
            // HStack statt HSplitView: Das Archiv war anfangs ein Blatt, dort verteilte die
            // Split-Ansicht die Höhe falsch (Tabelle unten eingequetscht, darüber leer).
            // Im eigenen Fenster bleibt es dabei – HStack mit fester Kartenbreite ist stabil.
            HStack(spacing: 0) {
                table.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    if aircraft, let s = items.first(where: { $0.id == selection }) {
                        photoPanel(s)
                        Divider()
                    }
                    trackMap.frame(maxHeight: .infinity)
                }
                .frame(width: 340).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 420)
        // Tage und Sichtungen kommen asynchron aus der Datenbank (abseits des Main Actors).
        .task {
            days = await archive.loadDays()
            if day.isEmpty { day = days.first ?? TrafficArchive.dayStamp(Date()) }
        }
        .task(id: LoadKey(day: day, reloads: reloads)) {
            guard !day.isEmpty else { return }
            selection = nil
            loading = true
            let loaded = await archive.sightings(days: day == Self.allDays ? nil : [day])
            guard !Task.isCancelled else { return }
            items = loaded
            loading = false
        }
        .onChange(of: items) { _, _ in updateRows() }
        .onChange(of: search) { _, _ in updateRows() }
        .onChange(of: order) { _, _ in updateRows() }
    }

    private struct LoadKey: Equatable {
        var day: String
        var reloads: Int
    }

    /// Laufenden Tag sichern, Tagesliste neu lesen und die Sichtungen neu laden.
    private func reload() {
        Task {
            days = await archive.loadDays()
            if day != Self.allDays, !days.contains(day) { day = days.first ?? TrafficArchive.dayStamp(Date()) }
            reloads += 1
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn(aircraft ? "Rufzeichen" : "Name", sortUsing: ColumnSort("name", text: { $0.name ?? $0.key })) { s in
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.name ?? s.key).fontWeight(.medium)
                    Text(aircraft ? "ICAO \(s.key)" : "MMSI \(s.key)").font(.caption).foregroundStyle(.secondary)
                }
            }.width(min: 90, ideal: 120)
            TableColumn(aircraft ? "Kennz." : "Rufz.", sortUsing: ColumnSort("kennzeichen", text: { $0.registration })) { s in Text(s.registration ?? "–") }.width(70)
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { $0.type })) { s in Text(s.type ?? "–") }.width(min: 80, ideal: 150)
            TableColumn(aircraft ? "Strecke" : "Ziel", sortUsing: ColumnSort("strecke", text: { $0.route })) { s in Text(s.route ?? "–") }.width(min: 80, ideal: 170)
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.last }) { s in
                Text((day == Self.allDays ? s.first.formatted(.dateTime.day().month(.twoDigits)) + " " : "")
                     + s.first.formatted(date: .omitted, time: .shortened) + "–" + s.last.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
            }.width(day == Self.allDays ? 135 : 95)
            TableColumn(aircraft ? "Max. Höhe" : "Max. Fahrt", sortUsing: ColumnSort("max") { aircraft ? $0.maxAltitudeM.map(Double.init) : $0.maxSpeed }) { s in
                Text(aircraft ? (s.maxAltitudeM.map { "\($0) m" } ?? "–") : (s.maxSpeed.map { String(format: "%.1f kn", $0) } ?? "–"))
                    .monospacedDigit()
            }.width(75)
            TableColumn("Nächste", sortUsing: ColumnSort("naechste") { $0.minDistanceKm }) { s in Text(s.minDistanceKm.map { String(format: "%.0f km", $0) } ?? "–").monospacedDigit() }.width(60)
            TableColumn("Gesehen", sortUsing: ColumnSort("gesehen") { Double(seenCounts[$0.key] ?? 1) }) { s in
                let n = seenCounts[s.key] ?? 1
                Text(verbatim: "\(n)×").monospacedDigit().foregroundStyle(n > 1 ? .primary : .secondary)
                    .help(day == Self.allDays ? "Sichtungen dieser Kennung über alle Tage" : "Sichtungen dieser Kennung an diesem Tag – eine neue beginnt nach über 30 Minuten Pause")
            }.width(58)
            if aircraft {
                TableColumn("Anflüge", sortUsing: ColumnSort("anfluege") { Double($0.approaches) }) { s in
                    let n = s.approaches
                    Text(n > 0 ? "\(n)" : "–").monospacedDigit()
                        .help("Wie oft die Maschine in dieser Sichtung in Bodennähe kam und wieder stieg – Platzrunden, Touch-and-go. Aus der Höhe der Spur (seit 29.10.2026 aufgezeichnet).")
                }.width(55)
            }
            TableColumn("Msg", sortUsing: ColumnSort("msg") { $0.messages }) { s in Text("\(s.messages)").monospacedDigit() }.width(45)
        }
    }

    /// Foto der gewählten Maschine (planespotters.net, wie auf der Karte). Nur mit
    /// eingeschaltetem Online-Nachschlagen – sonst geht keine Anfrage hinaus.
    @ViewBuilder private func photoPanel(_ s: ArchiveSighting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let icao = UInt32(s.key, radix: 16) {
                if let photo = AircraftPhotoLookup.shared.photo(for: icao) {
                    AsyncImage(url: photo.imageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
                    }
                    .frame(width: 320, height: 213)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { NSWorkspace.shared.open(photo.pageURL) }
                    .help("Foto auf planespotters.net öffnen")
                    Link(destination: photo.pageURL) {
                        Text("Foto: \(photo.photographer.isEmpty ? String(localized: "unbekannt") : photo.photographer) · planespotters.net")
                    }
                    .font(.caption2)
                } else if AircraftDatabase.shared.onlineLookup {
                    if AircraftPhotoLookup.shared.answered.contains(icao) {
                        Label("Kein Foto gefunden", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Foto wird gesucht …", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    SettingsHint(.online, "Fotos gibt es mit „Online nachschlagen“.")
                }
            }
            if let operatorName = s.operatorName, !operatorName.isEmpty {
                Text(operatorName).font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var trackMap: some View {
        if let s = items.first(where: { $0.id == selection }), s.track.count > 0 {
            let coordinates = s.track.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            LeafletMap(features: trackFeatures(s, coordinates), controller: mapController,
                       options: MapOptions(fitMaxZoom: 12, center: MapPoint(coordinates.last!), zoom: 8))
                .onChange(of: s.id, initial: true) { _, _ in mapController.showAll(animated: false) }
        } else {
            ContentUnavailableView(selection == nil ? "Eine Sichtung wählen" : "Keine Position gemeldet",
                                   systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
    }

    private func trackFeatures(_ s: ArchiveSighting, _ coordinates: [CLLocationCoordinate2D]) -> [MapFeature] {
        var list: [MapFeature] = []
        if coordinates.count > 1 {
            var line = MapFeature.line("track", coordinates, color: MapColor.selected, width: 3, arrows: true)
            line.fit = true
            list.append(line)
        }
        list.append(.badge("last", at: coordinates.last!, symbol: aircraft ? .plane : .ship, color: MapColor.red,
                           label: s.name ?? s.key))
        return list
    }

    /// Exportiert die geladenen Sichtungen (bei „Alle Tage“ alle Tage, älteste zuerst);
    /// die CSV entsteht abseits des Main Actors.
    private func exportCSV() {
        let unit = aircraft ? "kmh" : "kn"
        let name = "\(aircraft ? "Flugzeuge" : "Schiffe")_\(day).csv"
        let sightings = items
        Task {
            guard let url = await SaveSheet.url(name: name, types: [.commaSeparatedText]) else { return }
            let text = await Task.detached(priority: .userInitiated) {
                TrafficArchive.csv(sightings, speedUnit: unit)
            }.value
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
        }
    }

    static func dayTitle(_ stamp: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: stamp) else { return stamp }
        if Calendar.current.isDateInToday(date) { return String(localized: "Heute") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Gestern") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }
}
