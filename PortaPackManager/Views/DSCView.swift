import MapKit
import SwiftUI

/// Seefunk-Notruf (DSC) auf UKW-Kanal 70: Rufliste, Detailkarte, Karte für
/// Rufe mit Position bzw. Gebiet.
struct DSCView: View {
    @Environment(DeviceSession.self) private var session
    @Bindable private var model = DSCModel.shared
    private var notifier: Notifier { .shared }
    @State private var selection: DSCLogEntry.ID?
    @State private var order: [ColumnSort<DSCLogEntry>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var camera: MapCameraPosition = .automatic
    @State private var scrollZoom = MapScrollZoom()

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "sos", text: String(localized: "Die App empfängt Seefunk-Rufe und -Notrufe (DSC) selbst auf UKW-Kanal 70 (156,525 MHz) – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 290, issue: model.error) {
                VSplitView {
                    map.frame(minHeight: 160, idealHeight: 380)
                    table.frame(minHeight: 100)
                }
                .frame(minWidth: 520)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.dsc), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
            .onChange(of: selection) { _, id in center(on: id) }
        }
    }

    private var positioned: [DSCLogEntry] { model.entries.filter { $0.call.position != nil } }
    private var areas: [DSCLogEntry] { model.entries.filter { $0.call.area != nil } }

    // MARK: Karte

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, selection: $selection) {
                if let home {
                    Marker("Standort", systemImage: "house.fill", coordinate: home).tint(.brown)
                    // Unsichtbarer Kreis der typischen Reichweite (UKW-Seefunk reicht ~40 km): Ohne Ziele
                    // zoomte die automatische Kamera sonst bis auf die eigene Straße.
                    MapCircle(center: home, radius: 40_000).foregroundStyle(.clear)
                }
                ForEach(areas) { entry in
                    let area = entry.call.area!
                    MapPolygon(coordinates: [
                        CLLocationCoordinate2D(latitude: area.north, longitude: area.west),
                        CLLocationCoordinate2D(latitude: area.north, longitude: area.east),
                        CLLocationCoordinate2D(latitude: area.south, longitude: area.east),
                        CLLocationCoordinate2D(latitude: area.south, longitude: area.west),
                    ])
                    .foregroundStyle(Self.color(entry.call).opacity(selection == entry.id ? 0.25 : 0.1))
                    .stroke(Self.color(entry.call), lineWidth: selection == entry.id ? 2 : 1)
                }
                ForEach(positioned) { entry in
                    let position = entry.call.position!
                    Annotation(label(entry), coordinate: CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)) {
                        Image(systemName: entry.call.concernsDistress ? "sos.circle.fill" : "ferry.fill")
                            .font(.title2)
                            .foregroundStyle(selection == entry.id ? Color.orange : Self.color(entry.call))
                            .background(Circle().fill(.background).padding(2))
                    }
                    .tag(entry.id)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapZoomStepper(); MapScaleView() }
            .scrollWheelZoom(scrollZoom) { camera = .region($0) }
            .overlay(alignment: .topLeading) {
                if positioned.isEmpty, areas.isEmpty {
                    Text(model.running ? "Noch kein Ruf mit Position" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let entry = model.entries.first(where: { $0.id == selection }) {
                    DSCDetailCard(entry: entry, home: home) { selection = nil }
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if camera.positionedByUser || camera.region != nil, !(positioned.isEmpty && areas.isEmpty) {
                    Button("Alle Rufe zeigen", systemImage: "scope") { camera = .automatic }
                        .padding(10)
                }
            }
        }
    }

    private func center(on id: DSCLogEntry.ID?) {
        guard let id, let entry = model.entries.first(where: { $0.id == id }) else { return }
        let target: CLLocationCoordinate2D
        if let p = entry.call.position {
            target = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        } else if let a = entry.call.area {
            target = CLLocationCoordinate2D(latitude: (a.north + a.south) / 2, longitude: (a.west + a.east) / 2)
        } else {
            return
        }
        let span = scrollZoom.region?.span ?? MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        let region = MKCoordinateRegion(center: target, span: span)
        scrollZoom.region = region
        withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) }
    }

    // MARK: Liste

    private var table: some View {
        Table(model.entries.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.last }) { entry in
                Text(entry.last.formatted(date: .omitted, time: .standard)).monospacedDigit()
            }.width(70)
            TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.call.kindText })) { entry in
                Label(entry.call.kindText, systemImage: entry.call.concernsDistress ? "sos" : "phone.arrow.up.right")
                    .foregroundStyle(Self.color(entry.call))
                    .fontWeight(entry.call.concernsDistress ? .bold : .regular)
            }.width(min: 110, ideal: 140)
            TableColumn("Von", sortUsing: ColumnSort("von", text: { label($0) })) { entry in
                Text(label(entry))
            }.width(min: 100, ideal: 160)
            TableColumn("An", sortUsing: ColumnSort("an", text: { recipient($0.call) })) { entry in
                Text(recipient(entry.call)).foregroundStyle(.secondary)
            }.width(min: 80, ideal: 130)
            TableColumn("Inhalt", sortUsing: ColumnSort("inhalt", text: { summary($0.call) })) { entry in
                Text(summary(entry.call))
            }.width(min: 100, ideal: 200)
            TableColumn("Position", sortUsing: ColumnSort("position", text: { $0.call.position?.text })) { entry in
                Text(entry.call.position?.text ?? (entry.call.positionUnknown ? String(localized: "unbekannt") : "–")).font(.callout.monospacedDigit())
            }.width(min: 80, ideal: 150)
            TableColumn("Wdh.", sortUsing: ColumnSort("wdh") { $0.repeats }) { entry in
                Text("\(entry.repeats)").monospacedDigit()
            }.width(40)
        }
        .contextMenu(forSelectionType: DSCLogEntry.ID.self) { ids in
            if let entry = model.entries.first(where: { ids.contains($0.id) }) {
                Button("MMSI des Absenders kopieren") { copy(String(format: "%09d", entry.call.sender)) }
                Button("Zeichenfolge kopieren") { copy(entry.call.symbols.map(String.init).joined(separator: " ")) }
            }
        }
        .overlay {
            if model.entries.isEmpty {
                ContentUnavailableView("Keine Rufe", systemImage: "sos",
                                       description: Text(model.running
                                                         ? "Noch kein Ruf auf Kanal 70. Solche Rufe sind selten – nahe an Küste oder Fluss einige pro Stunde, meist Tests und Routinerufe."
                                                         : "Mit „Start“ beginnt der Empfang auf UKW-Kanal 70 (156,525 MHz)."))
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Bedienfeld

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop(on: session.hackRF) }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Leeren") { model.clear(); selection = nil }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Rufe", value: "\(model.entries.count)")
                LabeledContent("Davon Notfall", value: "\(model.distressCount)")
                LabeledContent("Korrigierte Zeichen", value: "\(model.correctedSymbols)")
                    .help("Zeichen, die erst über die zweite Kopie (Zeitdiversität) oder das Prüfzeichen stimmten.")
                LabeledContent("Kanal 70", value: String(format: "%.0f dBFS", model.signalDB))
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "dsc-rufe", isEmpty: model.entries.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                LegalNotice()
                SettingsHint(.notifications, notifier.notifyDSC && notifier.anyEnabled
                             ? String(localized: "Bei Notruf benachrichtigen: an")
                             : String(localized: "Bei Notruf benachrichtigen: aus"))
                Label("Beantworte oder bestätige Notrufe nie selbst – das ist Sache der Küstenfunkstellen und Schiffe mit Funkzeugnis. Gib Gehörtes nicht weiter.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Texte

    private func label(_ entry: DSCLogEntry) -> String {
        Self.stationText(entry.call.sender)
    }

    private func recipient(_ call: DSCCall) -> String {
        if let address = call.address { return Self.stationText(address) }
        if call.area != nil { return String(localized: "Gebiet") }
        return String(localized: "Alle")
    }

    private func summary(_ call: DSCCall) -> String {
        var parts: [String] = []
        if let distress = call.distressID, distress != call.sender { parts.append(String(localized: "Schiff in Not: \(Self.stationText(distress))")) }
        if let nature = call.natureText { parts.append(nature) }
        if call.nature == nil, let first = call.firstCommand.flatMap(DSCCall.firstCommandText) { parts.append(first) }
        if let frequency = call.frequency { parts.append(frequency) }
        if let ack = call.acknowledgementText { parts.append(ack) }
        return parts.joined(separator: " · ")
    }

    /// Name aus AIS, sonst MMSI; mit Land.
    @MainActor
    static func stationText(_ mmsi: Int) -> String {
        let id = String(format: "%09d", mmsi)
        let name = ShipNameDirectory.name(for: mmsi)
        let kind = MaritimeIdentity.classify(mmsi).kind.title
        let country = MaritimeIdentity.country(mmsi)
        var text = name.map { "\($0) (\(id))" } ?? id
        let extra = [kind, country].compactMap { $0 }.joined(separator: ", ")
        if !extra.isEmpty { text += " · " + extra }
        return text
    }

    static func color(_ call: DSCCall) -> Color {
        if call.isTest { return .secondary }
        if call.concernsDistress { return .red }
        switch call.category {
        case .urgency: return .orange
        case .safety: return .yellow
        default: return .primary
        }
    }
}

/// Detailansicht eines Rufs (oben rechts auf der Karte).
struct DSCDetailCard: View {
    let entry: DSCLogEntry
    let home: CLLocationCoordinate2D?
    let onClose: () -> Void

    var body: some View {
        let call = entry.call
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(call.kindText, systemImage: call.concernsDistress ? "sos" : "phone.arrow.up.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DSCView.color(call))
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Auswahl aufheben")
                    .accessibilityLabel("Auswahl aufheben")
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            Text(call.symbols.map(String.init).joined(separator: " "))
                .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DSCView.color(entry.call).opacity(0.6)))
    }

    private var rows: [(String, String)] {
        let call = entry.call
        var rows: [(String, String)] = [(String(localized: "Format"), call.format.title)]
        if let category = call.category { rows.append((String(localized: "Kategorie"), category.title)) }
        rows.append((String(localized: "Absender"), DSCView.stationText(call.sender)))
        if let address = call.address { rows.append((call.format == .group ? String(localized: "Gruppe") : String(localized: "Empfänger"), DSCView.stationText(address))) }
        if let area = call.area { rows.append((String(localized: "Gebiet"), area.text)) }
        if let distress = call.distressID, distress != call.sender { rows.append((String(localized: "Schiff in Not"), DSCView.stationText(distress))) }
        if let nature = call.natureText { rows.append((String(localized: "Notfall"), nature)) }
        if let position = call.position {
            rows.append((String(localized: "Position"), position.text))
            if let home {
                let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: position.latitude, lon2: position.longitude)
                let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: position.latitude, lon2: position.longitude)
                rows.append((String(localized: "Entfernung"), String(format: "%.0f km %@", km, GeoMath.compass(bearing))))
            }
        } else if call.positionUnknown {
            rows.append((String(localized: "Position"), String(localized: "unbekannt")))
        }
        if let time = call.timeText { rows.append((String(localized: "Zeit"), time)) }
        if let next = call.subsequentText { rows.append((String(localized: "Weiter per"), call.subsequent == 100 ? String(localized: "\(next) auf Kanal 16") : next)) }
        if call.nature == nil, let first = call.firstCommand.flatMap(DSCCall.firstCommandText) { rows.append((String(localized: "Befehl"), first)) }
        if let second = call.secondCommand.flatMap(DSCCall.secondCommandText), call.secondCommand != 126 { rows.append((String(localized: "Zusatz"), second)) }
        if let frequency = call.frequency { rows.append((String(localized: "Arbeitskanal"), frequency)) }
        if let ack = call.acknowledgementText { rows.append((String(localized: "Ende"), ack)) }
        rows.append((String(localized: "Empfangen"), entry.repeats > 1
                     ? String(localized: "\(entry.first.formatted(date: .abbreviated, time: .standard)) · \(entry.repeats)×, zuletzt \(entry.last.formatted(date: .omitted, time: .standard))")
                     : entry.first.formatted(date: .abbreviated, time: .standard)))
        if entry.corrected > 0 { rows.append((String(localized: "Korrigiert"), String(localized: "\(entry.corrected) Zeichen"))) }
        return rows
    }
}

extension DSCView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["erste", "letzte", "art", "von_mmsi", "von", "an", "inhalt", "position", "wiederholungen",
                             "korrigiert", "test"],
                    rows: model.entries.map { e in
                        [.date(e.first), .date(e.last), .text(e.call.kindText), .text(String(format: "%09d", e.call.sender)),
                         .text(label(e)), .text(recipient(e.call)), .text(summary(e.call)),
                         .text(e.call.position?.text ?? (e.call.positionUnknown ? String(localized: "unbekannt") : nil)),
                         .integer(e.repeats), .integer(e.corrected), .flag(e.call.isTest)]
                    })
    }
}
