import CoreLocation
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
    let symbol: MapSymbol
    let symbolSize: Double

    init(_ vessel: AISVessel, now: Date) {
        id = vessel.id
        label = vessel.name ?? String(vessel.mmsi)
        coordinate = CLLocationCoordinate2D(latitude: vessel.latitude ?? 0, longitude: vessel.longitude ?? 0)
        let fixed = vessel.isBaseStation || vessel.isAidToNavigation
        heading = fixed ? nil : vessel.displayHeading
        stale = now.timeIntervalSince(vessel.lastSeen) > Self.staleSeconds
        trail = vessel.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        symbol = vessel.isBaseStation ? .antenna
            : vessel.isAidToNavigation ? .beacon
            : heading == nil ? .dot : .hull
        // Größer als Flugzeuge und dunkel umrandet: Pfeile in der Akzentfarbe gingen
        // auf Wasser und Uferland unter (30.10.2026).
        symbolSize = fixed ? 16 : heading == nil ? 11 : 22
    }

    static func == (a: MapShip, b: MapShip) -> Bool {
        a.id == b.id && a.label == b.label && a.heading == b.heading && a.stale == b.stale
            && a.symbol == b.symbol
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.trail.count == b.trail.count
            && a.trail.last?.latitude == b.trail.last?.latitude
            && a.trail.last?.longitude == b.trail.last?.longitude
    }
}

/// Karte der AIS-Seite – wie `ADSBMapView` über `LeafletMap`; an die Seite geht
/// je Meldung nur, was sich an Schiffen und Spuren geändert hat.
/// `Equatable`: neu gerechnet wird nur, wenn sich Schiffe geändert haben.
struct AISMapView: View, Equatable {
    let ships: [MapShip]
    let home: CLLocationCoordinate2D?
    let showTrails: Bool
    let running: Bool
    /// Wert der Auswahl für den Vergleich – die Bindung allein löst kein Neuzeichnen aus.
    let selected: AISVessel.ID?
    @Binding var selection: AISVessel.ID?

    @State private var map = MapController()

    nonisolated static func == (a: AISMapView, b: AISMapView) -> Bool {
        a.ships == b.ships && a.showTrails == b.showTrails && a.running == b.running
            && a.selected == b.selected && a.home?.latitude == b.home?.latitude && a.home?.longitude == b.home?.longitude
    }

    var body: some View {
        LeafletMap(features: features, controller: map,
                   options: MapOptions(fitMaxZoom: 13, center: home.map(MapPoint.init) ?? MapPoint(54, 9), zoom: home == nil ? 5 : 9),
                   onSelect: { key in selection = key.flatMap { $0.hasPrefix("sh:") ? Int($0.dropFirst(3)) : nil } })
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
                if !map.following, !ships.isEmpty {
                    Button("Alle Schiffe zeigen", systemImage: "scope") { map.showAll() }
                        .padding(10)
                }
            }
    }

    private var features: [MapFeature] {
        var list: [MapFeature] = []
        if let home { list.append(.home(home)) }
        list += MapFeature.targets(ships, showTrails: showTrails, selection: selection, prefix: "sh:")
        return list
    }

    /// Zentriert auf das ausgewählte Schiff (behält den Zoom).
    private func center(on id: Int?) {
        guard let id, let ship = ships.first(where: { $0.id == id }) else { return }
        map.center(on: ship.coordinate)
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
