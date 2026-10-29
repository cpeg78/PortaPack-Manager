import MapKit
import SwiftUI

struct APRSView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.aprs
    @State private var selection: APRSStation.ID?
    @State private var order: [ColumnSort<APRSStation>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var camera: MapCameraPosition = .automatic
    @State private var scrollZoom = MapScrollZoom()
    @State private var showTrails = true

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "antenna.radiowaves.left.and.right", text: String(localized: "Die App empfängt APRS selbst auf 144,800 MHz – dafür muss das PortaPack im HackRF-Modus laufen. Ohne Mac zeigt die Mayhem-App „APRS RX“ die Pakete direkt auf dem Gerät."))
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    map.frame(minHeight: 160, idealHeight: 420)
                    table.frame(minHeight: 100)
                }
                .frame(minWidth: 520)
            } controls: {
                controls
            }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
            .onChange(of: selection) { _, id in center(on: id) }
        }
    }

    private var positioned: [APRSStation] {
        model.stations.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private func center(on id: APRSStation.ID?) {
        guard let id, let station = model.stations.first(where: { $0.id == id }),
              let lat = station.latitude, let lon = station.longitude else { return }
        let span = scrollZoom.region?.span ?? MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), span: span)
        scrollZoom.region = region
        withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, selection: $selection) {
                if let home {
                    Marker("Standort", systemImage: "house.fill", coordinate: home).tint(.brown)
                }
                if showTrails {
                    ForEach(positioned) { station in
                        if station.trail.count > 1 {
                            MapPolyline(coordinates: station.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                                .stroke(selection == station.id ? Color.orange : Color.accentColor.opacity(0.5),
                                        lineWidth: selection == station.id ? 3 : 1.5)
                        }
                    }
                }
                ForEach(positioned) { station in
                    Annotation(station.id, coordinate: CLLocationCoordinate2D(latitude: station.latitude!, longitude: station.longitude!)) {
                        Image(systemName: station.last.systemImage)
                            .foregroundStyle(selection == station.id ? Color.orange
                                             : Date().timeIntervalSince(station.lastHeard) > 1800 ? Color.secondary : Color.accentColor)
                            .font(.title3)
                    }
                    .tag(station.id)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
            .scrollWheelZoom(scrollZoom) { camera = .region($0) }
            .overlay(alignment: .topLeading) {
                if positioned.isEmpty {
                    Text(model.running ? "Noch keine Position empfangen" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if camera.positionedByUser || camera.region != nil, !positioned.isEmpty {
                    Button("Alle Stationen zeigen", systemImage: "scope") { camera = .automatic }
                        .padding(10)
                }
            }
        }
    }

    private var table: some View {
        Table(model.stations.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("Rufzeichen", sortUsing: ColumnSort("rufzeichen", text: { $0.id })) { Text($0.id).font(.body.monospaced()) }.width(min: 80, ideal: 100)
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { $0.last.kind.title })) { station in
                Label(station.last.kind.title, systemImage: station.last.systemImage)
            }.width(min: 80, ideal: 110)
            TableColumn("Entfernung", sortUsing: ColumnSort("entfernung") { distanceKm($0.latitude, $0.longitude) }) { Text(distanceString($0)) }.width(90)
            TableColumn("Tempo", sortUsing: ColumnSort("tempo") { $0.last.speedKnots }) { station in
                Text(station.last.speedKnots.map { String(format: "%.0f km/h", $0 * 1.852) } ?? "–")
            }.width(70)
            TableColumn("Höhe", sortUsing: ColumnSort("hoehe") { $0.last.altitudeMeters }) { station in
                Text(station.last.altitudeMeters.map { String(format: "%.0f m", $0) } ?? "–")
            }.width(60)
            TableColumn("Kommentar") { station in
                Text(detail(station.last)).foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn("Pfad") { Text($0.last.path).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(min: 60, ideal: 120)
            TableColumn("Rahmen", sortUsing: ColumnSort("pakete") { $0.packets }) { Text("\($0.packets)").monospacedDigit() }.width(50)
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastHeard }) { Text($0.lastHeard, style: .relative).foregroundStyle(.secondary) }.width(90)
        }
        .contextMenu(forSelectionType: APRSStation.ID.self) { ids in
            if let station = model.stations.first(where: { ids.contains($0.id) }) {
                Button("Auf aprs.fi öffnen") {
                    if let url = URL(string: "https://aprs.fi/#!call=a%2F\(station.last.source)") { NSWorkspace.shared.open(url) }
                }
                Button("Rohpaket kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(station.last.raw, forType: .string)
                }
            }
        }
        .overlay {
            if model.stations.isEmpty {
                ContentUnavailableView("Keine Stationen", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text(model.running
                                                         ? "Noch kein fehlerfreies Paket. Jede Station meldet sich nur alle paar Minuten – hab etwas Geduld oder bring eine 2-m-Antenne höher an."
                                                         : "Mit „Start“ beginnt der Empfang auf \(model.channel.title)."))
            }
        }
    }

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
                    Button("Leeren") { model.clear() }
                }
                Picker("Frequenz", selection: $model.channel) {
                    ForEach(APRSModel.Channel.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: model.channel) { _, _ in model.retune(on: session.hackRF) }
                Toggle("Kanal mithören", isOn: Binding(get: { model.monitorAudio }, set: { model.setMonitoring($0) }))
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Stationen", value: "\(model.stations.count)")
                LabeledContent("Mit Position", value: "\(positioned.count)")
                LabeledContent("Rahmen", value: "\(model.packetCount)")
                LabeledContent("Kanalpegel", value: String(format: "%.0f dBFS", model.signalDB))
            }
            Section(PanelSection.anzeige) {
                Toggle("Spuren zeigen", isOn: $showTrails)
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "aprs-stationen", isEmpty: model.stations.isEmpty) { csvDocument() }
            }
            Section("Letzte Rahmen") {
                if model.log.isEmpty {
                    Text("–").foregroundStyle(.secondary)
                }
                ForEach(Array(model.log.prefix(40).enumerated()), id: \.offset) { _, packet in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(packet.stationID) · \(packet.kind.title)").font(.caption.weight(.medium))
                        Text(packet.raw).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(3)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func detail(_ packet: APRSPacket) -> String {
        var parts: [String] = []
        if let message = packet.micEMessage { parts.append(message) }
        if let weather = packet.weather { parts.append(weather) }
        if packet.objectKilled { parts.append(String(localized: "gelöscht")) }
        if !packet.comment.isEmpty { parts.append(packet.comment) }
        if packet.objectName != nil { parts.append(String(localized: "von \(packet.source)")) }
        return parts.joined(separator: " · ")
    }

    private func distanceKm(_ lat: Double?, _ lon: Double?) -> Double? {
        guard let home, let lat, let lon else { return nil }
        return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
    }

    private func distanceString(_ station: APRSStation) -> String {
        guard let home, let lat = station.latitude, let lon = station.longitude else { return "–" }
        let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        return String(format: "%.1f km ", km) + GeoMath.compass(bearing)
    }
}

extension APRSView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["rufzeichen", "typ", "breite", "laenge", "tempo_kmh", "kurs_grad", "hoehe_m", "kommentar",
                             "pfad", "symbol", "rahmen", "zuletzt", "rohdaten"],
                    rows: model.stations.map { s in
                        [.text(s.id), .text(s.last.kind.title), .number(s.latitude, digits: 5), .number(s.longitude, digits: 5),
                         .number(s.last.speedKnots.map { $0 * 1.852 }, digits: 0), .number(s.last.courseDegrees, digits: 0),
                         .number(s.last.altitudeMeters, digits: 0), .text(detail(s.last)), .text(s.last.path),
                         .text("\(s.last.symbolTable)\(s.last.symbolCode)"), .integer(s.packets), .date(s.lastHeard), .text(s.last.raw)]
                    })
    }
}
