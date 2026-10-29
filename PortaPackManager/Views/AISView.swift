import MapKit
import SwiftUI

struct AISView: View {
    @Environment(DeviceSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    /// Gehört dem Fernzugriff, damit App und Browser denselben Empfänger bedienen.
    @Bindable private var model = RemoteHub.shared.ais
    @State private var selection: AISVessel.ID?
    @State private var order: [ColumnSort<AISVessel>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var showTrails = true
    @AppStorage(ShipPhotoLookup.enabledKey) private var onlinePhotos = true

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "ferry", text: String(localized: "Die App empfängt AIS selbst auf 161,975 und 162,025 MHz – dafür muss das PortaPack im HackRF-Modus laufen. Ohne Mac zeigt die Mayhem-App „AIS“ die Schiffe direkt auf dem Gerät."))
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
            .task { if AppNavigation.shared.takeAutoStart(.ais), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.ais); model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
        }
    }

    private var positioned: [AISVessel] {
        model.vessels.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private var map: some View {
        AISMapView(ships: positioned.map { MapShip($0, now: Date()) }, home: home,
                   showTrails: showTrails, running: model.running, selected: selection, selection: $selection)
            .equatable()
            .overlay(alignment: .topTrailing) {
                if let vessel = model.vessels.first(where: { $0.id == selection }) {
                    infoCard(vessel)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.6)))
                        .padding(10)
                }
            }
    }

    private var table: some View {
        Table(model.vessels.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("MMSI", sortUsing: ColumnSort("mmsi") { $0.mmsi }) { Text(String($0.mmsi)).font(.body.monospaced()) }.width(90)
            TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.name })) { Text($0.name ?? "–") }.width(min: 90, ideal: 140)
            TableColumn("Rufz.", sortUsing: ColumnSort("rufzeichen", text: { $0.callsign })) { Text($0.callsign ?? "–").font(.body.monospaced()) }.width(60)
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { Self.kindText($0) })) { vessel in
                Text(Self.kindText(vessel) ?? "–")
            }.width(min: 80, ideal: 110)
            TableColumn("Fahrt", sortUsing: ColumnSort("fahrt") { $0.speedKnots }) { vessel in
                Text([vessel.speedKnots.map { String(format: "%.1f kn", $0) },
                      vessel.courseDegrees.map { String(format: "%.0f°", $0) }].compactMap { $0 }.joined(separator: " · "))
            }.width(min: 60, ideal: 90)
            TableColumn("Status", sortUsing: ColumnSort("status", text: { AISMessage.statusText($0.status) })) { Text(AISMessage.statusText($0.status) ?? "–").foregroundStyle(.secondary) }.width(min: 70, ideal: 100)
            TableColumn("Ziel", sortUsing: ColumnSort("ziel", text: { $0.destination })) { Text($0.destination ?? "–") }.width(min: 60, ideal: 100)
            TableColumn("Entfernung", sortUsing: ColumnSort("entfernung") { distanceKm($0.latitude, $0.longitude) }) { Text(distanceString($0)) }.width(90)
            TableColumn("Nachr.", sortUsing: ColumnSort("msg") { $0.messages }) { Text("\($0.messages)").monospacedDigit() }.width(40)
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { Text($0.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(90)
        }
        .contextMenu(forSelectionType: AISVessel.ID.self) { ids in
            if let vessel = model.vessels.first(where: { ids.contains($0.id) }) {
                Button("Auf MarineTraffic öffnen") {
                    if let url = URL(string: "https://www.marinetraffic.com/en/ais/details/ships/mmsi:\(vessel.mmsi)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("MMSI kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(vessel.mmsi), forType: .string)
                }
            }
        }
        .overlay {
            if model.vessels.isEmpty {
                ContentUnavailableView("Keine Schiffe", systemImage: "ferry",
                                       description: Text(model.running
                                                         ? "Noch keine gültige Meldung. AIS reicht nur 20–40 km weit – am besten klappt es nahe an Küste oder Fluss mit einer Antenne für 162 MHz."
                                                         : "Mit „Start“ beginnt der Empfang auf beiden AIS-Kanälen."))
            }
        }
    }

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop(on: session.hackRF) }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.ais); model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Archiv …") { openWindow(id: "archive", value: "ais") }
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Schiffe", value: "\(model.vessels.count)")
                LabeledContent("Mit Position", value: "\(positioned.count)")
                LabeledContent("Meldungen", value: "\(model.messageCount)")
                ForEach(Array(AISModel.channels.enumerated()), id: \.offset) { index, channel in
                    LabeledContent("Kanal \(channel.name)", value: String(format: "%.0f dBFS", model.channelDB[index]))
                }
            }
            Section("Letzte Meldungen (NMEA)") {
                if model.log.isEmpty {
                    Text("–").foregroundStyle(.secondary)
                }
                ForEach(model.log.prefix(40)) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(String(line.mmsi)) · Typ \(line.type)").font(.caption.weight(.medium))
                        ForEach(line.nmea, id: \.self) { sentence in
                            Text(sentence).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            Section(PanelSection.anzeige) {
                Toggle("Spuren zeigen", isOn: $showTrails)
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "ais-schiffe", isEmpty: model.vessels.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                HomeLocationHint(purpose: "für Entfernung und Peilung")
                SettingsHint(.online, onlinePhotos ? String(localized: "Schiffsfotos (Wikimedia Commons): an")
                                                   : String(localized: "Schiffsfotos (Wikimedia Commons): aus"))
            }
        }
        .formStyle(.grouped)
    }

    /// Steckbrief des ausgewählten Schiffs – fast alles sendet das Schiff
    /// selbst (Meldung 5 bzw. 24); nur das Foto kommt aus dem Netz.
    /// Art des Senders für Tabelle und Infokarte.
    private static func kindText(_ vessel: AISVessel) -> String? {
        vessel.isBaseStation ? String(localized: "Basisstation")
            : vessel.isAidToNavigation ? String(localized: "Seezeichen")
            : AISMessage.shipTypeText(vessel.shipType)
    }

    private func infoCard(_ vessel: AISVessel) -> some View {
        var rows: [InfoCardContent.Row] = []
        if let kind = Self.kindText(vessel) { rows.append(.init(String(localized: "Typ"), kind)) }
        if let status = AISMessage.statusText(vessel.status) { rows.append(.init(String(localized: "Status"), status)) }
        if let speed = vessel.speedKnots {
            let course = vessel.courseDegrees.map { String(format: " · %.0f° %@", $0, GeoMath.compass($0)) } ?? ""
            rows.append(.init(String(localized: "Fahrt"), String(format: "%.1f kn (%.0f km/h)", speed, speed * 1.852) + course))
        }
        if let destination = vessel.destination, !destination.isEmpty { rows.append(.init(String(localized: "Ziel"), destination)) }
        if let eta = vessel.eta { rows.append(.init(String(localized: "Ankunft"), eta.text)) }
        if let length = vessel.lengthMeters, let beam = vessel.beamMeters, length > 0 {
            rows.append(.init(String(localized: "Größe"), "\(length) × \(beam) m"))
        }
        if let draught = vessel.draughtMeters { rows.append(.init(String(localized: "Tiefgang"), String(format: "%.1f m", draught))) }
        if let callsign = vessel.callsign, !callsign.isEmpty { rows.append(.init(String(localized: "Rufzeichen"), callsign)) }
        if let imo = vessel.imo { rows.append(.init("IMO", String(imo))) }
        if home != nil, vessel.latitude != nil { rows.append(.init(String(localized: "Entfernung"), distanceString(vessel))) }
        if let lat = vessel.latitude, let lon = vessel.longitude {
            rows.append(.init(String(localized: "Position"), String(format: "%.4f, %.4f", lat, lon)))
        }
        rows.append(.init(String(localized: "Meldungen"), String(localized: "\(vessel.messages) · Kanal \(vessel.lastChannel)")))
        let photo = onlinePhotos ? ShipPhotoLookup.shared.photo(imo: vessel.imo) : nil
        return InfoCardContent(
            title: vessel.name ?? String(vessel.mmsi),
            subtitle: vessel.name != nil ? "MMSI \(vessel.mmsi)" : nil,
            photo: photo, rows: rows, lastSeen: vessel.lastSeen,
            linkTitle: String(localized: "Auf MarineTraffic öffnen"),
            linkURL: URL(string: "https://www.marinetraffic.com/en/ais/details/ships/mmsi:\(vessel.mmsi)"),
            width: 250,
            onClose: { selection = nil })
    }

    private func distanceKm(_ lat: Double?, _ lon: Double?) -> Double? {
        guard let home, let lat, let lon else { return nil }
        return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
    }

    private func distanceString(_ vessel: AISVessel) -> String {
        guard let home, let lat = vessel.latitude, let lon = vessel.longitude else { return "–" }
        let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        return String(format: "%.1f km ", km) + GeoMath.compass(bearing)
    }
}

/// Schiff als Kartenziel (Schnappschuss je Aktualisierung, vergleichbar).
struct MapShip: MapTarget {
    /// Ohne Meldung so lange wird ein Schiff grau gezeichnet.
    static let staleSeconds = 600.0

    let id: Int
    let label: String
    let coordinate: CLLocationCoordinate2D
    let heading: Double?
    let stale: Bool
    let trail: [CLLocationCoordinate2D]
    let symbolName: String
    var symbolDirection: Double { 0 }
    let symbolSize: CGFloat

    init(_ vessel: AISVessel, now: Date) {
        id = vessel.id
        label = vessel.name ?? String(vessel.mmsi)
        coordinate = CLLocationCoordinate2D(latitude: vessel.latitude ?? 0, longitude: vessel.longitude ?? 0)
        let fixed = vessel.isBaseStation || vessel.isAidToNavigation
        heading = fixed ? nil : vessel.displayHeading
        stale = now.timeIntervalSince(vessel.lastSeen) > Self.staleSeconds
        trail = vessel.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        symbolName = vessel.isBaseStation ? "antenna.radiowaves.left.and.right"
            : vessel.isAidToNavigation ? "light.beacon.max.fill"
            : heading == nil ? "circle.fill" : "location.north.fill"
        symbolSize = heading == nil && !fixed ? 9 : 16
    }

    static func == (a: MapShip, b: MapShip) -> Bool {
        a.id == b.id && a.label == b.label && a.heading == b.heading && a.stale == b.stale
            && a.symbolName == b.symbolName
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.trail.count == b.trail.count
            && a.trail.last?.latitude == b.trail.last?.latitude
            && a.trail.last?.longitude == b.trail.last?.longitude
    }
}

/// Karte der AIS-Seite – zeichnet wie `ADSBMapView` selbst in einem
/// `TargetCanvas`; vorher kostete je Schiff eine `Annotation` plus
/// `MapPolyline` bei jeder Meldung den Neuaufbau aller MapKit-Überlagerungen.
/// `Equatable`: neu gezeichnet wird nur, wenn sich Schiffe geändert haben.
struct AISMapView: View, Equatable {
    let ships: [MapShip]
    let home: CLLocationCoordinate2D?
    let showTrails: Bool
    let running: Bool
    /// Wert der Auswahl für den Vergleich – die Bindung allein löst kein Neuzeichnen aus.
    let selected: AISVessel.ID?
    @Binding var selection: AISVessel.ID?

    @State private var camera: MapCameraPosition = .automatic
    @State private var viewport = MapViewport()
    @State private var scrollZoom = MapScrollZoom()
    /// Bis der Nutzer die Karte bewegt oder etwas auswählt, folgt der
    /// Ausschnitt allen Schiffen.
    @State private var followAll = true

    nonisolated static func == (a: AISMapView, b: AISMapView) -> Bool {
        a.ships == b.ships && a.showTrails == b.showTrails && a.running == b.running
            && a.selected == b.selected && a.home?.latitude == b.home?.latitude && a.home?.longitude == b.home?.longitude
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if let home {
                    Marker("Standort", systemImage: "house.fill", coordinate: home).tint(.brown)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapZoomStepper(); MapScaleView() }
            .onMapCameraChange(frequency: .continuous) { context in
                scrollZoom.region = context.region
                viewport.rect = context.rect
            }
            .overlay {
                TargetCanvas(planes: ships, showTrails: showTrails, selection: selection, viewport: viewport)
            }
            .onTapGesture { point in select(at: point, proxy: proxy) }
            .scrollWheelZoom(scrollZoom) { region in followAll = false; camera = .region(region) }
            .onAppear {
                fitAll(animated: false)
            }
            .onChange(of: camera.positionedByUser) { _, byUser in if byUser { followAll = false } }
            .onChange(of: shipIDsKey) { _, _ in if followAll { fitAll(animated: true) } }
            .onChange(of: selection) { _, id in center(on: id) }
            .overlay(alignment: .topLeading) {
                if ships.isEmpty {
                    Text(running ? "Noch keine Position empfangen" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !followAll, !ships.isEmpty {
                    Button("Alle Schiffe zeigen", systemImage: "scope") {
                        followAll = true
                        fitAll(animated: true)
                    }
                    .padding(10)
                }
            }
        }
    }

    /// Wechselt, sobald ein Schiff hinzukommt oder verschwindet.
    private var shipIDsKey: Int {
        var hasher = Hasher()
        for ship in ships { hasher.combine(ship.id) }
        return hasher.finalize()
    }

    /// Klick: nächstes Schiff im Umkreis von 14 Punkten, sonst Auswahl aufheben.
    private func select(at point: CGPoint, proxy: MapProxy) {
        var best: (id: Int, distance: CGFloat)?
        for ship in ships {
            guard let p = proxy.convert(ship.coordinate, to: .local) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= 14, best == nil || d < best!.distance { best = (ship.id, d) }
        }
        selection = best?.id
    }

    /// Ausschnitt um alle Schiffe (und den Standort) mit etwas Rand.
    private func fitAll(animated: Bool) {
        var coordinates = ships.map(\.coordinate)
        if let home { coordinates.append(home) }
        guard let first = coordinates.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.05),
                                   longitudeDelta: max((maxLon - minLon) * 1.3, 0.05)))
        scrollZoom.region = region
        if animated { withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) } }
        else { camera = .region(region) }
    }

    /// Zentriert auf das ausgewählte Schiff (behält den Zoom).
    private func center(on id: Int?) {
        guard let id, let ship = ships.first(where: { $0.id == id }) else { return }
        followAll = false
        let span = scrollZoom.region?.span ?? MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
        let region = MKCoordinateRegion(center: ship.coordinate, span: span)
        scrollZoom.region = region
        withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) }
    }
}

extension AISView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["mmsi", "name", "rufzeichen", "imo", "typ", "status", "fahrt_kn", "kurs_grad", "steuerkurs_grad",
                             "breite", "laenge", "ziel", "eta", "laenge_m", "breite_m", "tiefgang_m", "nachrichten", "zuletzt", "kanal"],
                    rows: model.vessels.map { v in
                        [.integer(v.mmsi), .text(v.name), .text(v.callsign), .integer(v.imo), .text(Self.kindText(v)),
                         .text(AISMessage.statusText(v.status)), .number(v.speedKnots), .number(v.courseDegrees, digits: 0),
                         .integer(v.heading), .number(v.latitude, digits: 5), .number(v.longitude, digits: 5), .text(v.destination),
                         .text(v.eta?.text), .integer(v.lengthMeters), .integer(v.beamMeters), .number(v.draughtMeters),
                         .integer(v.messages), .date(v.lastSeen), .text(v.lastChannel)]
                    })
    }
}
