import CoreLocation
import SwiftUI

struct AISView: View {
    @StoredColumns("ais.1") private var columns: TableColumnCustomization<AISVessel>
    @Environment(DeviceSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    /// Gehört dem Fernzugriff, damit App und Browser denselben Empfänger bedienen.
    @Bindable private var model = RemoteHub.shared.ais
    @State private var selection: AISVessel.ID?
    @State private var order: [ColumnSort<AISVessel>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var showTrails = true
    /// Infokarte zugeklappt – das Schiff bleibt ausgewählt (Spur, Mitte).
    @State private var cardHidden = false
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
                   showTrails: showTrails, running: model.running, selected: selection, selection: $selection,
                   onPick: { cardHidden = false })
            .equatable()
            .onChange(of: selection) { _, _ in cardHidden = false }
            .overlay {
                if !cardHidden, let vessel = model.vessels.first(where: { $0.id == selection }) {
                    MapInfoCardFrame(width: 250) { infoCard(vessel) }
                }
            }
    }

    private var table: some View {
        Table(model.vessels.sorted(by: order, current: [byDistance]), selection: $selection, sortOrder: $order, columnCustomization: $columns) {
            TableColumn("MMSI", sortUsing: ColumnSort("mmsi") { $0.mmsi }) { Text(String($0.mmsi)).font(.body.monospaced()) }.width(min: 54, ideal: 90).customizationID("mmsi")
            TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.name })) { Text($0.name ?? "–") }.width(min: 90, ideal: 140).customizationID("name")
            TableColumn("Rufz.", sortUsing: ColumnSort("rufzeichen", text: { $0.callsign })) { Text($0.callsign ?? "–").font(.body.monospaced()) }.width(min: 36, ideal: 60).customizationID("rufz")
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { $0.kindText })) { vessel in
                Text(vessel.kindText ?? "–")
                    .foregroundStyle(vessel.beaconActive ? Color.red : Color.primary)
                    .fontWeight(vessel.beaconActive ? .bold : .regular)
            }.width(min: 80, ideal: 110).customizationID("typ")
            TableColumn("Fahrt", sortUsing: ColumnSort("fahrt") { $0.speedKnots }) { vessel in
                Text([vessel.speedKnots.map { String(format: "%.1f kn", $0) },
                      vessel.courseDegrees.map { String(format: "%.0f°", $0) }].compactMap { $0 }.joined(separator: " · "))
            }.width(min: 60, ideal: 90).customizationID("fahrt")
            TableColumn("Status", sortUsing: ColumnSort("status", text: { AISMessage.statusText($0.status) })) { Text(AISMessage.statusText($0.status) ?? "–").foregroundStyle(.secondary) }.width(min: 70, ideal: 100).customizationID("status")
            TableColumn("Ziel", sortUsing: ColumnSort("ziel", text: { $0.destination })) { Text($0.destination ?? "–") }.width(min: 60, ideal: 100).customizationID("ziel")
            TableColumn("Entfernung", sortUsing: byDistance) { Text(distanceString($0)) }.width(min: 54, ideal: 90).customizationID("entfernung")
            TableColumn("Nachr.", sortUsing: ColumnSort("msg") { $0.messages }) { Text("\($0.messages)").monospacedDigit() }.width(min: 28, ideal: 40).customizationID("nachr")
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { Text($0.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(min: 54, ideal: 90).customizationID("zuletzt")
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
                AISStatusRows(model: model, positioned: positioned.count)
            }
            if !model.safetyMessages.isEmpty {
                Section("Sicherheitsmeldungen") {
                    ForEach(model.safetyMessages.prefix(20)) { message in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.text).textSelection(.enabled)
                            Text(safetyCaption(message)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
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

    /// Absender (Name oder MMSI), Empfänger und Uhrzeit einer Sicherheitsmeldung.
    private func safetyCaption(_ message: AISSafetyMessage) -> String {
        let sender = model.vessels.first { $0.mmsi == message.mmsi }?.name ?? String(message.mmsi)
        let target = message.destination.map { String(localized: " an \(String($0))") } ?? ""
        return "\(sender)\(target) · " + message.date.formatted(date: .omitted, time: .shortened)
    }

    /// Steckbrief des ausgewählten Schiffs – fast alles sendet das Schiff
    /// selbst (Meldung 5 bzw. 24); nur das Foto kommt aus dem Netz.
    private func infoCard(_ vessel: AISVessel) -> some View {
        var rows: [InfoCardContent.Row] = []
        if let kind = vessel.kindText { rows.append(.init(String(localized: "Typ"), kind)) }
        if let text = vessel.safetyText { rows.append(.init(String(localized: "Meldung"), text)) }
        if let altitude = vessel.altitudeMeters { rows.append(.init(String(localized: "Höhe"), "\(altitude) m")) }
        if let weather = vessel.weather {
            rows.append(.init(String(localized: "Wetter"), weather.summary))
            if let time = weather.time { rows.append(.init(String(localized: "Gemessen"), time)) }
        }
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
            onClose: { cardHidden = true })
    }

    /// Entfernung zum Standort – frisch je Neuzeichnen (siehe `sorted(by:current:)`).
    private var byDistance: ColumnSort<AISVessel> {
        ColumnSort("entfernung") { distanceKm($0.latitude, $0.longitude) }
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
        let fixed = vessel.isBaseStation || vessel.isAidToNavigation || vessel.beacon != nil || vessel.weather != nil
        heading = fixed ? nil : vessel.displayHeading
        stale = now.timeIntervalSince(vessel.lastSeen) > Self.staleSeconds
        trail = vessel.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        symbol = vessel.beacon != nil ? .sos
            : vessel.weather != nil && vessel.shipType == nil ? .weather
            : vessel.isSARAircraft ? .plane
            : vessel.isBaseStation ? .antenna
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
    /// Klick auf ein Schiff – öffnet die zugeklappte Infokarte wieder.
    var onPick: () -> Void = {}

    @State private var map = MapController()
    /// Die Karte führt dem ausgewählten Schiff nach, bis der Nutzer sie
    /// verschiebt oder „Alle Schiffe zeigen“ wählt.
    @State private var tracking = false

    nonisolated static func == (a: AISMapView, b: AISMapView) -> Bool {
        a.ships == b.ships && a.showTrails == b.showTrails && a.running == b.running
            && a.selected == b.selected && a.home?.latitude == b.home?.latitude && a.home?.longitude == b.home?.longitude
    }

    var body: some View {
        LeafletMap(features: features, controller: map,
                   options: MapOptions(fitMaxZoom: 13, center: home.map(MapPoint.init) ?? MapPoint(54, 9), zoom: home == nil ? 5 : 9),
                   onSelect: { key in
                       let id = key.flatMap { $0.hasPrefix("sh:") ? Int($0.dropFirst(3)) : nil }
                       if id != nil, id == selection { tracking = true; center(on: id) }   // erneuter Klick
                       selection = id
                       if selection != nil { onPick() }
                   })
            .onChange(of: selection) { _, id in
                tracking = id != nil
                center(on: id)
            }
            .onChange(of: selectedCoordinateKey) { _, _ in if tracking { center(on: selection) } }
            .onChange(of: map.userPans) { _, _ in tracking = false }
            .onChange(of: map.following) { _, following in if following { tracking = false } }
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
                        .buttonStyle(.mapOverlay)
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

    private var selectedCoordinateKey: String {
        guard let selection, let ship = ships.first(where: { $0.id == selection }) else { return "" }
        return "\(ship.coordinate.latitude),\(ship.coordinate.longitude)"
    }

    /// Zentriert auf das ausgewählte Schiff (behält den Zoom).
    private func center(on id: Int?) {
        guard let id, let ship = ships.first(where: { $0.id == id }) else { return }
        map.center(on: ship.coordinate, pin: tracking)
    }
}

extension AISView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["mmsi", "name", "rufzeichen", "imo", "typ", "status", "fahrt_kn", "kurs_grad", "steuerkurs_grad",
                             "breite", "laenge", "ziel", "eta", "laenge_m", "breite_m", "tiefgang_m", "nachrichten", "zuletzt", "kanal"],
                    rows: model.vessels.map { v in
                        [.integer(v.mmsi), .text(v.name), .text(v.callsign), .integer(v.imo), .text(v.kindText),
                         .text(AISMessage.statusText(v.status)), .number(v.speedKnots), .number(v.courseDegrees, digits: 0),
                         .integer(v.heading), .number(v.latitude, digits: 5), .number(v.longitude, digits: 5), .text(v.destination),
                         .text(v.eta?.text), .integer(v.lengthMeters), .integer(v.beamMeters), .number(v.draughtMeters),
                         .integer(v.messages), .date(v.lastSeen), .text(v.lastChannel)]
                    })
    }
}

/// Zähler und Pegel als eigene Ansicht: sie ändern sich mehrmals je Sekunde,
/// und im Bedienfeld selbst gelesen zeichneten sie das ganze Formular neu –
/// das Scrollen ruckelte (Review 05.11.2026).
private struct AISStatusRows: View {
    let model: AISModel
    let positioned: Int

    var body: some View {
        LabeledContent("Schiffe", value: "\(model.vessels.count)")
        LabeledContent("Mit Position", value: "\(positioned)")
        LabeledContent("Meldungen", value: "\(model.messageCount)")
        ForEach(Array(AISModel.channels.enumerated()), id: \.offset) { index, channel in
            LabeledContent("Kanal \(channel.name)", value: String(format: "%.0f dBFS", model.channelDB[index]))
        }
    }
}
