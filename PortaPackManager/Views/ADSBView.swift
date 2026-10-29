import MapKit
import SwiftUI

struct ADSBView: View {
    @AppStorage("adsbLogExpanded") private var logExpanded = false
    @Environment(DeviceSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    /// Gehört dem Fernzugriff, damit App und Browser denselben Empfänger bedienen.
    @Bindable private var model = RemoteHub.shared.adsb
    @State private var selection: Aircraft.ID?
    @State private var order: [ColumnSort<Aircraft>] = []
    @AppStorage("adsbMetric") private var metric = true
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var showTrails = true
    @AppStorage("adsbShowAirports") private var showAirports = true
    private var database: AircraftDatabase { .shared }
    private var airportDatabase: AirportDatabase { .shared }
    private var routes: FlightRouteLookup { .shared }

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "airplane", text: String(localized: "Die App empfängt ADS-B selbst auf 1090 MHz – dafür muss das PortaPack im HackRF-Modus laufen. Ohne Mac zeigt die Mayhem-App „ADS-B“ die Flugzeuge direkt auf dem Gerät."))
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
            .task { if AppNavigation.shared.takeAutoStart(.adsb), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.adsb); model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
            .onAppear {
                model.setReceiver(home); database.loadIfNeeded(); takeRequestedAircraft()
                if showAirports { airportDatabase.loadIfNeeded() }
            }
            .onChange(of: showAirports) { _, on in if on { airportDatabase.loadIfNeeded() } }
            .onChange(of: AppNavigation.shared.aircraft) { _, _ in takeRequestedAircraft() }
            .onChange(of: homeLat) { _, _ in model.setReceiver(home) }
            .onChange(of: homeLon) { _, _ in model.setReceiver(home) }
        }
    }

    /// Von einer anderen Seite angefordertes Flugzeug auswählen (ACARS & VDL2).
    private func takeRequestedAircraft() {
        guard let icao = AppNavigation.shared.aircraft else { return }
        AppNavigation.shared.aircraft = nil
        if model.aircraft.contains(where: { $0.icao == icao }) { selection = icao }
    }

    private var positioned: [Aircraft] {
        model.aircraft.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private var map: some View {
        ADSBMapView(planes: model.mapAircraft, home: home, showTrails: showTrails, showAirports: showAirports,
                    running: model.running, selected: selectedInfo, selection: $selection)
            .equatable()
    }

    /// Steckbrief des ausgewählten Flugzeugs für die Karte.
    private var selectedInfo: SelectedAircraftInfo? {
        guard let selection, let plane = model.aircraft.first(where: { $0.id == selection }),
              let lat = plane.latitude, let lon = plane.longitude else { return nil }
        var rows: [SelectedAircraftInfo.Row] = []
        if let info = database.info(for: plane.icao) {
            if !info.registration.isEmpty { rows.append(.init(String(localized: "Kennzeichen"), info.registration)) }
            if !info.typeText.isEmpty { rows.append(.init(String(localized: "Typ"), info.typeText)) }
            if !info.operatorText.isEmpty { rows.append(.init(String(localized: "Betreiber"), info.operatorText)) }
            if !info.category.isEmpty, info.category != "No ADS-B Emitter Category Information" {
                rows.append(.init(String(localized: "Kategorie"), info.category))
            }
        }
        if let route = routes.route(for: plane.callsign) {
            if !route.airline.isEmpty { rows.append(.init(String(localized: "Gesellschaft"), route.airline)) }
            rows.append(.init(String(localized: "Von"), route.origin.shortText))
            rows.append(.init(String(localized: "Nach"), route.destination.shortText))
            if !Self.routeFits(route, lat: lat, lon: lon) {
                rows.append(.init(String(localized: "Strecke"), String(localized: "⚠︎ passt nicht zur Position")))
            }
        }
        rows.append(.init(String(localized: "Höhe"), altitude(plane.altitude)))
        rows.append(.init(String(localized: "Tempo"), speed(plane.groundSpeed)))
        rows.append(.init(String(localized: "Kurs"), plane.track.map { String(format: "%.0f° %@", $0, GeoMath.compass($0)) } ?? "–"))
        rows.append(.init(String(localized: "Steigen"), climb(plane.verticalRate)))
        if home != nil { rows.append(.init(String(localized: "Entfernung"), distanceString(plane))) }
        rows.append(.init(String(localized: "Position"), String(format: "%.4f, %.4f", lat, lon)))
        rows.append(.init(String(localized: "Nachrichten"), "\(plane.messages)"))
        return SelectedAircraftInfo(id: plane.id, callsign: plane.callsign, icaoHex: plane.icaoHex,
                                    latitude: lat, longitude: lon, rows: rows, lastSeen: plane.lastSeen,
                                    photo: AircraftPhotoLookup.shared.photo(for: plane.icao))
    }

    // Vergleicher als Konstanten und Zellen mit Typangabe – sonst sprengt die
    // Tabelle mit zwei Spaltengruppen die Typprüfung (siehe ZigbeeView).
    private static let byICAO = ColumnSort<Aircraft>("icao", text: { (p: Aircraft) -> String? in p.icaoHex })
    private static let byCallsign = ColumnSort<Aircraft>("kennung", text: { (p: Aircraft) -> String? in p.callsign })
    private static let byRegistration = ColumnSort<Aircraft>("kennzeichen", text: { (p: Aircraft) -> String? in
        MainActor.assumeIsolated { AircraftDatabase.shared.info(for: p.icao)?.registration } })
    private static let byType = ColumnSort<Aircraft>("typ", text: { (p: Aircraft) -> String? in
        MainActor.assumeIsolated { AircraftDatabase.shared.info(for: p.icao)?.typeText } })
    private static let byOperator = ColumnSort<Aircraft>("betreiber", text: { (p: Aircraft) -> String? in
        MainActor.assumeIsolated { AircraftDatabase.shared.info(for: p.icao)?.operatorText } })
    private static let byAltitude = ColumnSort<Aircraft>("hoehe") { (p: Aircraft) -> Int? in p.altitude }
    private static let bySpeed = ColumnSort<Aircraft>("tempo") { (p: Aircraft) -> Double? in p.groundSpeed }
    private static let byTrack = ColumnSort<Aircraft>("kurs") { (p: Aircraft) -> Double? in p.track }
    private static let byClimb = ColumnSort<Aircraft>("steigen") { (p: Aircraft) -> Int? in p.verticalRate }
    private static let byMessages = ColumnSort<Aircraft>("msg") { (p: Aircraft) -> Int? in p.messages }
    private static let byLastSeen = ColumnSort<Aircraft>("zuletzt") { (p: Aircraft) -> Date? in p.lastSeen }

    private var byDistance: ColumnSort<Aircraft> {
        let home = home
        return ColumnSort<Aircraft>("entfernung") { (p: Aircraft) -> Double? in
            guard let home, let lat = p.latitude, let lon = p.longitude else { return nil }
            return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        }
    }

    private func info(_ plane: Aircraft) -> AircraftInfo? { database.info(for: plane.icao) }

    /// Die Streckenauskunft kennt nur das Rufzeichen und ist oft veraltet.
    /// Liegt das Flugzeug weit neben der Großkreisstrecke (mehr als 150 km
    /// bzw. 15 % der Streckenlänge), ist die Strecke vermutlich falsch.
    static func routeFits(_ route: FlightRoute, lat: Double, lon: Double) -> Bool {
        let length = GeoMath.distanceKm(lat1: route.origin.latitude, lon1: route.origin.longitude,
                                        lat2: route.destination.latitude, lon2: route.destination.longitude)
        return route.offRouteKm(latitude: lat, longitude: lon) <= max(150, length * 0.15)
    }

    private func routeText(_ plane: Aircraft) -> String {
        guard let route = routes.route(for: plane.callsign) else { return "–" }
        if let lat = plane.latitude, let lon = plane.longitude, !Self.routeFits(route, lat: lat, lon: lon) {
            return route.codesText + " ?"
        }
        return route.codesText
    }

    private static let byRoute = ColumnSort<Aircraft>("strecke", text: { (p: Aircraft) -> String? in
        MainActor.assumeIsolated { FlightRouteLookup.shared.route(for: p.callsign)?.codesText } })

    private var table: some View {
        Table(model.aircraft.sorted(by: order), selection: $selection, sortOrder: $order) {
            Group {
                TableColumn("ICAO", sortUsing: Self.byICAO) { (p: Aircraft) in Text(p.icaoHex).font(.body.monospaced()) }.width(70)
                TableColumn("Kennung", sortUsing: Self.byCallsign) { (p: Aircraft) in Text(p.callsign ?? "–").font(.body.monospaced()) }.width(80)
                TableColumn("Kennzeichen", sortUsing: Self.byRegistration) { (p: Aircraft) in
                    Text(info(p)?.registration ?? "–").font(.body.monospaced())
                }.width(80)
                TableColumn("Typ", sortUsing: Self.byType) { (p: Aircraft) in
                    Text(info(p)?.typeText ?? "–").help(info(p)?.typeText ?? "")
                }.width(min: 80, ideal: 160)
                TableColumn("Betreiber", sortUsing: Self.byOperator) { (p: Aircraft) in
                    Text(info(p)?.operatorText ?? "–").help(info(p)?.operatorText ?? "")
                }.width(min: 80, ideal: 140)
                TableColumn("Strecke", sortUsing: Self.byRoute) { (p: Aircraft) in
                    let route = routes.route(for: p.callsign)
                    Text(routeText(p)).font(.body.monospaced())
                        .help(route.map { "\($0.origin.shortText) → \($0.destination.shortText)" } ?? "")
                }.width(90)
            }
            Group {
                TableColumn("Höhe", sortUsing: Self.byAltitude) { (p: Aircraft) in Text(altitude(p.altitude)) }.width(80)
                TableColumn("Tempo", sortUsing: Self.bySpeed) { (p: Aircraft) in Text(speed(p.groundSpeed)) }.width(80)
                TableColumn("Kurs", sortUsing: Self.byTrack) { (p: Aircraft) in Text(p.track.map { String(format: "%.0f°", $0) } ?? "–") }.width(50)
                TableColumn("Steigen", sortUsing: Self.byClimb) { (p: Aircraft) in Text(climb(p.verticalRate)) }.width(80)
                TableColumn("Position") { (p: Aircraft) in
                    if let lat = p.latitude, let lon = p.longitude {
                        Text(String(format: "%.4f, %.4f", lat, lon)).font(.caption.monospacedDigit())
                    } else { Text("–") }
                }
                TableColumn("Entfernung", sortUsing: byDistance) { (p: Aircraft) in Text(distanceString(p)) }.width(100)
                TableColumn("Nachr.", sortUsing: Self.byMessages) { (p: Aircraft) in Text("\(p.messages)").monospacedDigit() }.width(45)
                TableColumn("Letzter Kontakt", sortUsing: Self.byLastSeen) { (p: Aircraft) in Text(p.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(100)
            }
        }
        .contextMenu(forSelectionType: Aircraft.ID.self) { ids in
            if let plane = model.aircraft.first(where: { ids.contains($0.id) }) {
                Button("Auf Flightradar24 öffnen") {
                    let target = plane.callsign ?? plane.icaoHex
                    if let url = URL(string: "https://www.flightradar24.com/\(target)") { NSWorkspace.shared.open(url) }
                }
                Button("ICAO kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plane.icaoHex, forType: .string)
                }
            }
        }
        .overlay {
            if model.aircraft.isEmpty {
                ContentUnavailableView("Keine Flugzeuge", systemImage: "airplane",
                                       description: Text(model.running
                                                         ? "Noch keine gültige Nachricht. Am meisten hilft eine 1090-MHz-Antenne am Fenster oder im Freien."
                                                         : "Mit „Start“ beginnt der Empfang auf 1090 MHz."))
            }
        }
    }

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop(on: session.hackRF) }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.adsb); model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Archiv …") { openWindow(id: "archive", value: "adsb") }
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
                LabeledContent("Flugzeuge", value: "\(model.aircraft.count)")
                LabeledContent("Mit Position", value: "\(positioned.count)")
                if let maxRange = maxRangeKm {
                    LabeledContent("Weitestes Flugzeug", value: metric ? String(format: "%.1f km", maxRange)
                                   : String(format: "%.1f NM", maxRange / 1.852))
                }
                LabeledContent("Gültige Nachrichten", value: "\(model.framesValid)")
                LabeledContent("Nachrichten/s", value: String(format: "%.1f", model.messagesPerSecond))
                LabeledContent("Präambel-Treffer", value: "\(model.framesSeen)")
                    .help("Signale, die wie der Anfang einer Nachricht aussehen (Mode-S-Präambel). Ohne gültige Prüfsumme sind es Rauschen oder Störungen.")
            }
            Section {
                if model.log.isEmpty {
                    Text("–").foregroundStyle(.secondary)
                }
                // Eingeklappt nur fünf Rohmeldungen – 30 Zeilen schoben die übrigen
                // Einstellungen weit nach unten.
                ForEach(Array(model.log.prefix(logExpanded ? 30 : 5).enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(message.icaoHex) · TC \(message.typeCode)").font(.caption.weight(.medium))
                        Text(message.rawHex).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } header: {
                CollapsibleHeader(title: String(localized: "Letzte Nachrichten"), count: min(model.log.count, 30), shown: 5, expanded: $logExpanded)
            }
            Section(PanelSection.anzeige) {
                Toggle("Metrische Einheiten", isOn: $metric)
                Toggle("Flugspuren zeigen", isOn: $showTrails)
                Toggle("Flugplätze zeigen", isOn: $showAirports)
                    .help("Flughäfen und Flugplätze im sichtbaren Ausschnitt; Hubschrauberlandeplätze erst bei größerem Zoom.")
                if showAirports, airportDatabase.airports.isEmpty, !airportDatabase.loading {
                    Text("Noch keine Flugplatzdaten – einmal laden (OurAirports, 12 MB).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Flugplätze laden", systemImage: "arrow.down.circle") {
                        Task { await airportDatabase.download() }
                    }
                }
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "adsb-flugzeuge", isEmpty: model.aircraft.isEmpty) { csvDocument() }
                LabeledContent("Flugzeugdatenbank") {
                    if database.isLoaded {
                        Text("\(database.count.formatted()) Flugzeuge")
                    } else if database.loading {
                        Text("wird gelesen …")
                    } else {
                        Text("nicht geladen")
                    }
                }
                if let updated = database.updated, database.isLoaded {
                    LabeledContent("Geladen am", value: updated.formatted(date: .numeric, time: .shortened))
                }
                if !database.isLoaded, !database.loading {
                    Text("Ohne sie fehlen Kennzeichen, Typ und Betreiber.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if database.downloading {
                    if let progress = database.progress {
                        HStack(alignment: .bottom) {
                            ProgressView(value: progress) { Text("Lädt von OpenSky (95 MB) …") }
                            Button("Abbrechen") { database.cancelDownload() }
                        }
                    } else {
                        ProgressView { Text("Wandelt um …") }
                    }
                } else {
                    Button("Aktualisieren", systemImage: "arrow.down.circle") {
                        Task { await database.download() }
                    }
                    .help("Lädt die Flugzeugdatenbank von OpenSky (95 MB).")
                }
                if let error = database.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Quelle: OpenSky Network (Stand November 2024). Einmal geladen, liegt sie danach auf dem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Datei aircraftDatabase.csv von opensky-network.org")
                if let error = routes.error {
                    Text("Strecken: \(error)").font(.caption).foregroundStyle(.red)
                }
                if !database.onlineEntries.isEmpty || database.onlineQueued > 0 {
                    LabeledContent("Online gefunden", value: database.onlineQueued > 0
                                   ? String(localized: "\(database.onlineEntries.count) · \(database.onlineQueued) offen")
                                   : database.onlineEntries.count.formatted())
                }
                if let error = database.onlineError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Flugplätze") {
                    if airportDatabase.loading {
                        Text("wird geladen …")
                    } else if airportDatabase.airports.isEmpty {
                        Text("nicht geladen")
                    } else {
                        Text(airportDatabase.airports.count.formatted())
                    }
                }
                if let updated = airportDatabase.updated, !airportDatabase.airports.isEmpty {
                    LabeledContent("Flugplätze geladen am", value: updated.formatted(date: .numeric, time: .shortened))
                }
                Button(airportDatabase.airports.isEmpty ? "Flugplätze laden" : "Flugplätze aktualisieren",
                       systemImage: "arrow.down.circle") {
                    Task { await airportDatabase.download() }
                }
                .disabled(airportDatabase.loading)
                .help("Lädt die Flugplatzliste von OurAirports (12 MB). Dein Standort geht dabei nicht hinaus.")
                if let error = airportDatabase.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.hinweis) {
                HomeLocationHint(purpose: "für Entfernung und Peilung")
                SettingsHint(.online, database.onlineLookup
                             ? String(localized: "Online nachschlagen (Typ, Strecke, Foto): an")
                             : String(localized: "Online nachschlagen (Typ, Strecke, Foto): aus"))
            }
        }
        .formStyle(.grouped)
    }

    /// Entfernung (Großkreis) des derzeit weitesten Flugzeugs mit Position.
    private var maxRangeKm: Double? {
        guard let home else { return nil }
        let ranges = positioned.compactMap { plane -> Double? in
            guard let lat = plane.latitude, let lon = plane.longitude else { return nil }
            return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        }
        return ranges.max()
    }

    private func distanceKm(_ lat: Double?, _ lon: Double?) -> Double? {
        guard let home, let lat, let lon else { return nil }
        return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
    }

    private func distanceString(_ plane: Aircraft) -> String {
        guard let home, let lat = plane.latitude, let lon = plane.longitude else { return "–" }
        let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        let dist = metric ? String(format: "%.1f km", km) : String(format: "%.1f NM", km / 1.852)
        return "\(dist) \(GeoMath.compass(bearing))"
    }

    private func altitude(_ feet: Int?) -> String {
        guard let feet else { return "–" }
        return metric ? "\(Int((Double(feet) * 0.3048).rounded())) m" : "\(feet) ft"
    }

    private func speed(_ knots: Double?) -> String {
        guard let knots else { return "–" }
        return metric ? String(format: "%.0f km/h", knots * 1.852) : String(format: "%.0f kt", knots)
    }

    private func climb(_ fpm: Int?) -> String {
        guard let fpm else { return "–" }
        return metric ? String(format: "%+.1f m/s", Double(fpm) * 0.00508) : "\(fpm) ft/min"
    }
}

/// Die Karte der ADS-B-Seite. Flugzeuge und Spuren zeichnet sie selbst in
/// einem `Canvas` über der Karte – mit je einer `Annotation` und `MapPolyline`
/// pro Flugzeug baute MapKit bei jeder Aktualisierung (2× je Sekunde) alle
/// Symbole und Überlagerungen neu und blockierte den Hauptthread bei 150
/// Flugzeugen ≈ 75 ms, egal wie lang die Spuren waren (gemessen 25.10.2026);
/// mit dem Canvas sind es ≈ 20 ms, und davon entfällt das meiste auf die
/// Tabelle. Die Umrechnung Koordinate → Punkt ist die Mercator-Projektion
/// von `MKMapPoint` über den sichtbaren `MKMapRect` – deckungsgleich mit
/// MapKit, auch mitten im Ziehen (gegen Referenz-Annotationen geprüft).
/// Drehen der Karte ist deshalb abgeschaltet (die Projektion setzt Norden
/// oben voraus).
///
/// `Equatable`: das Elternview rendert alle 500 ms neu – die Karte nur, wenn
/// sich an den gezeichneten Daten etwas geändert hat.
struct ADSBMapView: View, Equatable {
    let planes: [MapAircraft]
    let home: CLLocationCoordinate2D?
    let showTrails: Bool
    let showAirports: Bool
    let running: Bool
    let selected: SelectedAircraftInfo?
    @Binding var selection: Aircraft.ID?
    /// Angeklickter Flugplatz (Infokarte); schließt sich mit einer Flugzeugauswahl.
    @State private var airport: Airport?

    @State private var camera: MapCameraPosition = .automatic
    @State private var viewport = MapViewport()
    @State private var scrollZoom = MapScrollZoom()
    @State private var pendingCenter: Aircraft.ID?
    /// Bis der Nutzer die Karte bewegt oder etwas auswählt, folgt der
    /// Ausschnitt allen Flugzeugen (wie `.automatic` bei MapKit-Annotationen).
    @State private var followAll = true

    nonisolated static func == (a: ADSBMapView, b: ADSBMapView) -> Bool {
        a.planes == b.planes && a.showTrails == b.showTrails && a.showAirports == b.showAirports && a.running == b.running
            && a.selected == b.selected
            && a.home?.latitude == b.home?.latitude && a.home?.longitude == b.home?.longitude
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if let home {
                    Marker("Standort", systemImage: "house.fill", coordinate: home)
                        .tint(.brown)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapZoomStepper(); MapScaleView() }
            .onMapCameraChange(frequency: .continuous) { context in
                scrollZoom.region = context.region
                viewport.rect = context.rect
            }
            .overlay {
                // Unter den Flugzeugen; hängt nicht an `planes` – neu gezeichnet wird
                // nur beim Verschieben/Zoomen, nicht bei jeder Flugzeugmeldung.
                if showAirports {
                    AirportCanvas(viewport: viewport, selected: airport?.id).equatable()
                }
            }
            .overlay {
                TargetCanvas(planes: planes, showTrails: showTrails, selection: selection, viewport: viewport)
            }
            .overlay {
                if let selected {
                    AircraftInfoCard(info: selected, viewport: viewport) { selection = nil }
                } else if showAirports, let airport {
                    AirportInfoCard(airport: airport, viewport: viewport) { self.airport = nil }
                }
            }
            .onTapGesture { point in select(at: point, proxy: proxy) }
            .scrollWheelZoom(scrollZoom) { region in followAll = false; camera = .region(region) }
            .onChange(of: camera.positionedByUser) { _, byUser in if byUser { followAll = false } }
            .onChange(of: planeIDsKey) { _, _ in if followAll { fitAll(animated: true) } }
            .onChange(of: selection) { _, id in
                if id != nil { airport = nil }
                centerOnSelection(id)
            }
            .onChange(of: pendingCoordinateKey) { _, _ in
                // Position kam erst nach dem Anklicken an → jetzt nachholen.
                if let pendingCenter, center(on: pendingCenter) { self.pendingCenter = nil }
            }
            .overlay(alignment: .topLeading) {
                if planes.isEmpty {
                    Text(running ? "Noch keine Position empfangen" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !followAll, !planes.isEmpty {
                    Button("Alle Flugzeuge zeigen", systemImage: "scope") {
                        followAll = true
                        fitAll(animated: true)
                    }
                    .padding(10)
                }
            }
        }
    }

    /// Wechselt, sobald ein Flugzeug hinzukommt oder verschwindet.
    private var planeIDsKey: Int {
        var hasher = Hasher()
        for plane in planes { hasher.combine(plane.id) }
        return hasher.finalize()
    }

    /// Position des vorgemerkten Flugzeugs als vergleichbarer Schlüssel –
    /// wechselt von "" auf Koordinaten, sobald die Position eintrifft.
    private var pendingCoordinateKey: String {
        guard let pendingCenter, let plane = planes.first(where: { $0.id == pendingCenter }) else { return "" }
        return "\(plane.coordinate.latitude),\(plane.coordinate.longitude)"
    }

    /// Klick auf die Karte: nächstes Flugzeug im Umkreis von 14 Punkten
    /// auswählen, sonst den nächsten sichtbaren Flugplatz (10 Punkte), sonst
    /// Auswahl aufheben.
    private func select(at point: CGPoint, proxy: MapProxy) {
        var best: (id: Aircraft.ID, distance: CGFloat)?
        for plane in planes {
            guard let p = proxy.convert(plane.coordinate, to: .local) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= 14, best == nil || d < best!.distance { best = (plane.id, d) }
        }
        selection = best?.id
        guard best == nil, showAirports, let bounds = AirportFilter.Bounds(mapRect: viewport.rect) else {
            airport = nil
            return
        }
        var nearest: (airport: Airport, distance: CGFloat)?
        for candidate in AirportFilter.visible(AirportDatabase.shared.airports, in: bounds) {
            guard let p = proxy.convert(candidate.coordinate, to: .local) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= 10, nearest == nil || d < nearest!.distance { nearest = (candidate, d) }
        }
        airport = nearest?.airport
    }

    /// Ausschnitt um alle Flugzeuge (und den Standort) mit etwas Rand.
    private func fitAll(animated: Bool) {
        var coordinates = planes.map(\.coordinate)
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
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.2),
                                   longitudeDelta: max((maxLon - minLon) * 1.3, 0.2)))
        scrollZoom.region = region
        if animated { withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) } }
        else { camera = .region(region) }
    }

    /// Reaktion auf eine Auswahl: sofort hinspringen, sonst vormerken.
    private func centerOnSelection(_ id: Aircraft.ID?) {
        pendingCenter = id
        if center(on: id) { pendingCenter = nil }
    }

    /// Zentriert die Karte auf das Flugzeug (behält den aktuellen Zoom).
    /// Liefert `false`, wenn noch keine Position bekannt ist.
    @discardableResult
    private func center(on id: Aircraft.ID?) -> Bool {
        guard let id, let plane = planes.first(where: { $0.id == id }) else { return false }
        followAll = false
        let span = scrollZoom.region?.span
            ?? MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5)
        let region = MKCoordinateRegion(center: plane.coordinate, span: span)
        scrollZoom.region = region
        withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) }
        return true
    }
}

/// Sichtbarer Kartenausschnitt in Kartenpunkten – eigenes Objekt, damit beim
/// Ziehen nur der Canvas neu zeichnet und nicht die ganze Kartenansicht.
@MainActor @Observable
final class MapViewport {
    var rect = MKMapRect()

    /// Koordinate → Punkt in der Ansicht (Mercator, Norden oben).
    nonisolated static func point(_ c: CLLocationCoordinate2D, rect: MKMapRect, size: CGSize) -> CGPoint {
        let p = MKMapPoint(c)
        return CGPoint(x: (p.x - rect.minX) * size.width / rect.width,
                       y: (p.y - rect.minY) * size.height / rect.height)
    }
}

/// Ein Ziel, das `TargetCanvas` über der Karte zeichnet (Flugzeug, Schiff …).
protocol MapTarget: Identifiable, Equatable {
    var label: String { get }
    var coordinate: CLLocationCoordinate2D { get }
    /// Kurs in Grad (0 = Norden); nil = Symbol nicht drehen.
    var heading: Double? { get }
    var stale: Bool { get }
    var trail: [CLLocationCoordinate2D] { get }
    /// SF-Symbol und dessen eigene Richtung (Grad, 0 = zeigt nach Norden).
    var symbolName: String { get }
    var symbolDirection: Double { get }
    /// Kantenlänge des Symbols in Punkten (ausgewählt +4).
    var symbolSize: CGFloat { get }
}

/// Spuren, Symbole und Kennungen über der Karte – für ADS-B und AIS.
struct TargetCanvas<Target: MapTarget>: View {
    let planes: [Target]
    let showTrails: Bool
    let selection: Target.ID?
    let viewport: MapViewport

    var body: some View {
        let rect = viewport.rect
        Canvas(rendersAsynchronously: false) { context, size in
            guard rect.width > 0, rect.height > 0 else { return }
            func point(_ c: CLLocationCoordinate2D) -> CGPoint { MapViewport.point(c, rect: rect, size: size) }
            let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)

            if showTrails {
                for plane in planes where plane.trail.count > 1 {
                    var path = Path()
                    var last = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
                    var anyVisible = false
                    for (i, c) in plane.trail.enumerated() {
                        let p = point(c)
                        // Punkte unter 1,5 Pt Abstand bringen nichts, kosten aber Zeichenzeit.
                        if i > 0, i < plane.trail.count - 1, abs(p.x - last.x) + abs(p.y - last.y) < 1.5 { continue }
                        if visible.contains(p) { anyVisible = true }
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        last = p
                    }
                    guard anyVisible else { continue }
                    let selected = plane.id == selection
                    context.stroke(path, with: .color(selected ? .orange : .accentColor.opacity(0.5)),
                                   lineWidth: selected ? 3 : 1.5)
                }
            }

            var symbols: [String: GraphicsContext.ResolvedImage] = [:]
            var labelBoxes: [CGRect] = []
            var selectedPlane: (Target, CGPoint)?
            func draw(_ plane: Target, at p: CGPoint, selected: Bool) {
                let color: Color = selected ? .orange : plane.stale ? .secondary : .accentColor
                let side: CGFloat = plane.symbolSize + (selected ? 4 : 0)
                var image = symbols[plane.symbolName]
                    ?? context.resolve(Image(systemName: plane.symbolName).renderingMode(.template))
                symbols[plane.symbolName] = image
                image.shading = .color(color)
                context.drawLayer { layer in
                    layer.translateBy(x: p.x, y: p.y)
                    if let heading = plane.heading { layer.rotate(by: .degrees(heading - plane.symbolDirection)) }
                    layer.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                }
                // Kennung darunter – nur, wo sie keine andere überdeckt.
                var text = context.resolve(Text(plane.label).font(.caption2.weight(selected ? .semibold : .regular)))
                text.shading = .color(plane.stale && !selected ? .secondary : .primary)
                let measured = text.measure(in: CGSize(width: 200, height: 40))
                let box = CGRect(x: p.x - measured.width / 2 - 2, y: p.y + 10,
                                 width: measured.width + 4, height: measured.height + 1)
                guard selected || !labelBoxes.contains(where: { $0.intersects(box) }) else { return }
                labelBoxes.append(box)
                context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.labelBackground))
                context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
            }
            for plane in planes {
                let p = point(plane.coordinate)
                guard visible.contains(p) else { continue }
                if plane.id == selection { selectedPlane = (plane, p); continue }
                draw(plane, at: p, selected: false)
            }
            if let (plane, p) = selectedPlane { draw(plane, at: p, selected: true) }
        }
        .allowsHitTesting(false)
    }
}

/// Flugplätze über der Karte, dezent unter den Flugzeugen. Je Art ein eigenes
/// Zeichen (Anklang an Luftfahrtkarten: Kreis = Flugplatz, „H“ = Hubschrauber);
/// Kennungen nur, wo Platz ist – große Plätze zuerst, kleine erst nah heran.
/// Höchstens `AirportFilter.defaultLimit` Plätze, nach Wichtigkeit.
struct AirportCanvas: View, Equatable {
    let viewport: MapViewport
    let selected: Airport.ID?

    nonisolated static func == (a: AirportCanvas, b: AirportCanvas) -> Bool {
        a.viewport === b.viewport && a.selected == b.selected
    }

    var body: some View {
        let rect = viewport.rect
        let airports = AirportDatabase.shared.airports
        let selected = selected
        Canvas(rendersAsynchronously: false) { context, size in
            guard !airports.isEmpty, let bounds = AirportFilter.Bounds(mapRect: rect) else { return }
            let visible = AirportFilter.visible(airports, in: bounds)
            let labelSmall = bounds.latSpan <= 1.5
            let tint = Color.indigo
            var labelBoxes: [CGRect] = []
            var heli = context.resolve(Text(verbatim: "H").font(.system(size: 7, weight: .bold)))
            heli.shading = .color(tint)
            let points = visible.map { ($0, MapViewport.point($0.coordinate, rect: rect, size: size)) }
            // Rückwärts zeichnen: die wichtigsten liegen oben.
            for (airport, p) in points.reversed() {
                let isSelected = airport.id == selected
                let color: Color = isSelected ? .orange : tint
                switch airport.kind {
                case .large, .medium:
                    let d: CGFloat = airport.kind == .large ? 10 : 7
                    let circle = Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
                    context.fill(circle, with: .color(color.opacity(0.85)))
                    context.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                case .small, .seaplane:
                    let d: CGFloat = 6
                    let ring: Color = airport.kind == .seaplane && !isSelected ? .teal : color
                    let circle = Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
                    context.fill(circle, with: .color(.white.opacity(0.6)))
                    context.stroke(circle, with: .color(ring.opacity(0.8)), lineWidth: 1.5)
                case .heliport:
                    let d: CGFloat = 10
                    let circle = Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
                    context.fill(circle, with: .color(.white.opacity(0.7)))
                    context.stroke(circle, with: .color(color.opacity(0.7)), lineWidth: 1)
                    context.draw(heli, at: p)
                }
            }
            // Kennungen rechts neben dem Zeichen (unter den Flugzeugen stehen deren Kennungen).
            for (airport, p) in points {
                let isSelected = airport.id == selected
                guard isSelected || airport.kind == .large || airport.kind == .medium || labelSmall else { continue }
                var text = context.resolve(Text(verbatim: airport.code)
                    .font(.system(size: 9, weight: airport.kind == .large ? .semibold : .regular)))
                text.shading = .color(isSelected ? .primary : .secondary)
                let measured = text.measure(in: CGSize(width: 120, height: 30))
                let box = CGRect(x: p.x + 7, y: p.y - measured.height / 2 - 0.5,
                                 width: measured.width + 4, height: measured.height + 1)
                guard isSelected || !labelBoxes.contains(where: { $0.intersects(box) }) else { continue }
                labelBoxes.append(box)
                context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.labelBackground))
                context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Kleine Infokarte zum angeklickten Flugplatz (Name, Art, Kennungen, Höhe).
struct AirportInfoCard: View {
    let airport: Airport
    let viewport: MapViewport
    let onClose: () -> Void

    private let width: CGFloat = 220
    @State private var height: CGFloat = 100

    var body: some View {
        let rect = viewport.rect
        GeometryReader { geo in
            let size = geo.size
            if rect.width > 0 {
                let p = MapViewport.point(airport.coordinate, rect: rect, size: size)
                let gap: CGFloat = 14, margin: CGFloat = 8
                let x = p.x + gap + width + 20 + margin <= size.width ? p.x + gap : max(margin, p.x - gap - width - 20)
                let y = min(max(p.y - gap, margin), max(margin, size.height - height - margin))
                card
                    .frame(width: width, alignment: .leading)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.indigo.opacity(0.5)))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .offset(x: x, y: y)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: airport.code).font(.headline.monospaced())
                if let iata = airport.iata { Text(verbatim: iata).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Auswahl aufheben")
                    .accessibilityLabel("Auswahl aufheben")
            }
            Text(verbatim: airport.name).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: Self.details(airport)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// „Flugplatz · Stade · Höhe 19 m“ – OurAirports gibt die Höhe in Fuß an.
    static func details(_ airport: Airport) -> String {
        var parts = [airport.kind.title]
        if let place = airport.municipality { parts.append(place) }
        if let feet = airport.elevationFt {
            parts.append(String(localized: "Höhe \(Int((Double(feet) * 0.3048).rounded())) m"))
        }
        if airport.scheduled { parts.append(String(localized: "Linienverkehr")) }
        return parts.joined(separator: " · ")
    }
}

extension Color {
    /// Halbdurchsichtiger Hintergrund hinter den Kennungen, hell wie dunkel.
    static let labelBackground = Color(nsColor: .windowBackgroundColor).opacity(0.75)
}


/// Steckbrief des ausgewählten Flugzeugs – vergleichbar, damit die Karte
/// nur bei Änderungen neu baut.
struct SelectedAircraftInfo: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }
    let id: Aircraft.ID
    let callsign: String?
    let icaoHex: String
    let latitude: Double
    let longitude: Double
    let rows: [Row]
    let lastSeen: Date
    let photo: AircraftPhoto?
}

/// Infokarte neben dem ausgewählten Flugzeug; wandert beim Ziehen mit und
/// weicht an den Rändern auf die andere Seite aus.
struct AircraftInfoCard: View {
    let info: SelectedAircraftInfo
    let viewport: MapViewport
    let onClose: () -> Void

    private let width: CGFloat = 230
    @State private var height: CGFloat = 200

    var body: some View {
        let rect = viewport.rect
        GeometryReader { geo in
            let size = geo.size
            if rect.width > 0 {
                let p = MapViewport.point(CLLocationCoordinate2D(latitude: info.latitude, longitude: info.longitude),
                                          rect: rect, size: size)
                let gap: CGFloat = 18, margin: CGFloat = 8
                let x = p.x + gap + width + margin <= size.width ? p.x + gap
                    : max(margin, p.x - gap - width)
                let y = min(max(p.y - gap, margin), max(margin, size.height - height - margin))
                card
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.6)))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .offset(x: x, y: y)
            }
        }
        .allowsHitTesting(true)
    }

    private var card: some View {
        InfoCardContent(
            title: info.callsign ?? info.icaoHex,
            subtitle: info.callsign != nil ? "ICAO \(info.icaoHex)" : nil,
            photo: info.photo.map {
                InfoCardPhoto(imageURL: $0.imageURL, pageURL: $0.pageURL,
                              credit: String(localized: "Foto: \($0.photographer.isEmpty ? String(localized: "unbekannt") : $0.photographer) · planespotters.net"),
                              help: String(localized: "Foto auf planespotters.net öffnen"))
            },
            rows: info.rows.map { InfoCardContent.Row($0.label, $0.value) },
            lastSeen: info.lastSeen,
            linkTitle: String(localized: "Auf Flightradar24 öffnen"),
            linkURL: URL(string: "https://www.flightradar24.com/\(info.callsign ?? info.icaoHex)"),
            width: width,
            onClose: onClose)
    }
}

extension View {
    /// Mausrad zoomt die Karte (siehe `MapScrollZoom`). Auf eine `Map` mit
    /// Kamera-Bindung anwenden; `apply` setzt die neue Region. Der Monitor hängt an
    /// einer unsichtbaren Ansicht hinter der Karte (`ScrollWheelArea`): nur Ereignisse
    /// aus diesem Fenster und über der Karte zählen, und er verschwindet mit ihr.
    func scrollWheelZoom(_ zoom: MapScrollZoom, apply: @escaping (MKCoordinateRegion) -> Void) -> some View {
        MapReader { proxy in
            self
                .onMapCameraChange(frequency: .continuous) { zoom.region = $0.region }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { zoom.cursor = point } else { zoom.cursor = nil }
                }
                .background(ScrollWheelArea(onRemove: { zoom.reset() }) { event in
                    zoom.handle(event, convert: { proxy.convert($0, from: .local) }, apply: apply)
                })
                .onDisappear { zoom.reset() }
        }
    }
}

/// Zoomt die Karte mit dem Mausrad, und zwar um den Punkt unter dem Zeiger –
/// MapKit verschiebt bei Mausrad sonst nur die Karte.
@MainActor
final class MapScrollZoom {
    var region: MKCoordinateRegion?
    /// Hover-Zustand über der Karte; `nil`, sobald der Zeiger sie verlässt oder sie verschwindet.
    var cursor: CGPoint?

    /// Hover zurücksetzen – beim Entfernen der Karte, sonst bliebe er stehen.
    func reset() { cursor = nil }

    /// Magic Mouse und Trackpad liefern beim Wischen fast immer auch einen
    /// seitlichen Anteil. Der ging früher an MapKit, und die Karte schob hin und
    /// her statt zu zoomen (Fund 28.10.2026). Über der Karte wird jedes
    /// Scroll-Ereignis verbraucht; gezoomt wird nur mit dem senkrechten Anteil,
    /// verschoben wird durch Ziehen. Liefert `true`, wenn das Ereignis verbraucht wurde.
    func handle(_ event: ScrollWheelArea.Event, convert: (CGPoint) -> CLLocationCoordinate2D?,
                apply: (MKCoordinateRegion) -> Void) -> Bool {
        guard cursor != nil, let region else { return false }
        guard let next = Self.zoomed(region, dx: event.dx, dy: event.dy, precise: event.precise,
                                     anchor: convert(event.location) ?? region.center)
        else { return true }
        self.region = next
        apply(next)
        return true
    }

    /// Neue Region nach einem Mausrad-Schritt; `nil`, wenn sich nichts ändert.
    nonisolated static func zoomed(_ region: MKCoordinateRegion, dx: Double, dy: Double, precise: Bool,
                                   anchor: CLLocationCoordinate2D) -> MKCoordinateRegion? {
        // Überwiegend seitlich: verbrauchen, aber nicht zoomen.
        guard dy != 0, abs(dy) >= abs(dx) else { return nil }
        let delta = dy
        // Rastendes Mausrad liefert Zeilen, Trackpad/Magic Mouse Punkte.
        let factor = exp(-delta * (precise ? 0.01 : 0.15))
        let latDelta = min(max(region.span.latitudeDelta * factor, 0.002), 120)
        let applied = latDelta / region.span.latitudeDelta
        guard applied != 1 else { return nil }
        let lonDelta = min(region.span.longitudeDelta * applied, 300)
        // Punkt unter dem Zeiger bleibt stehen.
        let center = CLLocationCoordinate2D(
            latitude: anchor.latitude + (region.center.latitude - anchor.latitude) * applied,
            longitude: anchor.longitude + (region.center.longitude - anchor.longitude) * applied)
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}


/// Verweis auf den eigenen Standort in den Einstellungen – ersetzt die
/// Standortfelder, die früher auf mehreren Seiten standen.
struct HomeLocationHint: View {
    /// Wozu die Seite den Standort braucht, z. B. „für Entfernung und Peilung“.
    /// `LocalizedStringResource`, damit die Literale der Aufrufer übersetzt werden.
    var purpose: LocalizedStringResource?
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0

    var body: some View {
        SettingsHint(.location, text)
    }

    private var text: String {
        let position = homeLat != 0 || homeLon != 0
            ? Self.format(homeLat, homeLon) : String(localized: "nicht gesetzt")
        guard let purpose else { return String(localized: "Standort: \(position)") }
        return String(localized: "Standort: \(position) – \(String(localized: purpose))")
    }

    static func format(_ lat: Double, _ lon: Double) -> String {
        let latText = String(format: "%.4f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lonText = String(format: "%.4f° %@", abs(lon), lon >= 0 ? "O" : "W")
        return (latText + ", " + lonText).replacingOccurrences(of: ".", with: ",")
    }
}

extension ADSBView {
    /// Live-Liste in Fuß/Knoten (Rohwerte von ADS-B), unabhängig von der Anzeige-Einheit.
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["icao", "kennung", "kennzeichen", "typ", "betreiber", "strecke", "hoehe_ft", "tempo_kn", "kurs_grad",
                             "steigen_ft_min", "breite", "laenge", "position_zeit", "nachrichten", "zuletzt"],
                    rows: model.aircraft.map { p in
                        let i = info(p)
                        let route = routes.route(for: p.callsign) == nil ? nil : routeText(p)
                        return [.text(p.icaoHex), .text(p.callsign), .text(i?.registration), .text(i?.typeText), .text(i?.operatorText),
                                .text(route), .integer(p.altitude), .number(p.groundSpeed, digits: 0), .number(p.track, digits: 0),
                                .integer(p.verticalRate), .number(p.latitude, digits: 5), .number(p.longitude, digits: 5),
                                .date(p.positionDate), .integer(p.messages), .date(p.lastSeen)]
                    })
    }
}
