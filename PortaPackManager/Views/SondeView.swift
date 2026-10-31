import CoreLocation
import SwiftUI

struct SondeView: View {
    @Environment(DeviceSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    /// Gehört dem Empfangsplan, damit geplante Aufstiege auch ohne offene Seite laufen.
    @Bindable private var model = ReceptionPlanner.shared.sonde
    @State private var selection: Sonde.ID?
    @State private var order: [ColumnSort<Sonde>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @AppStorage("sondeGroundAltitude") private var groundAltitude = 100.0
    @State private var mapController = MapController()
    @State private var manualMHz = 403.0
    /// Verlauf der gewählten (sonst der zuletzt gehörten) Sonde aus dem Meldungsprotokoll.
    @State private var history: SondeFlight?
    /// Verlauf stammt aus dem Archiv (keine Sonde zu hören).
    @State private var historyIsArchive = false
    /// Seriennummer, deren Verlauf gezeigt wird. Bleibt stehen, bis der Nutzer eine
    /// Sonde wählt oder diese verstummt – bei zwei Sonden sprang sie sonst mit jedem
    /// Rahmen hin und her, und jedes Mal begann das Lesen von vorn (Review W10).
    @State private var historySerial: String?

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "balloon", text: "Wetterballons (Radiosonden) funken im Band 400–406 MHz. Zum Empfang muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    // Volle Breite: Leer schrumpften die Bereiche sonst auf die Breite
                    // ihres Platzhaltertexts und standen schmal in der Mitte (28.10.2026).
                    map.frame(maxWidth: .infinity, minHeight: 160, idealHeight: 380)
                    table.frame(maxWidth: .infinity, minHeight: 100, idealHeight: 160)
                    historyPane.frame(maxWidth: .infinity, minHeight: 180, idealHeight: 280)
                }
                .frame(minWidth: 520)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.sonde), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
            .onChange(of: selection) { _, id in center(on: id); updateHistorySerial() }
            .onChange(of: model.sondes) { _, _ in updateHistorySerial() }
            .onAppear { updateHistorySerial() }
            .task(id: historySerial) { await followHistory() }
        }
    }

    // MARK: - Verlauf

    private func updateHistorySerial() {
        let next = Self.followedSerial(current: historySerial,
                                       selected: model.sondes.first { $0.id == selection }?.latest.serial,
                                       heard: model.sondes.map { ($0.latest.serial, $0.lastSeen) }, now: Date())
        if next != historySerial { historySerial = next }
    }

    /// Welche Sonde der Verlauf zeigt: die gewählte; sonst die bisherige, solange sie
    /// in den letzten `silence` Sekunden zu hören war; sonst die zuletzt gehörte.
    static func followedSerial(current: String?, selected: String?, heard: [(serial: String, lastSeen: Date)],
                               now: Date, silence: TimeInterval = 120) -> String? {
        if let selected, !selected.isEmpty { return selected }
        let valid = heard.filter { !$0.serial.isEmpty }
        if let current, let entry = valid.first(where: { $0.serial == current }),
           now.timeIntervalSince(entry.lastSeen) <= silence {
            return current
        }
        return valid.max { $0.lastSeen < $1.lastSeen }?.serial
    }

    /// Liest den Verlauf alle 10 s neu – nur Meldungen der letzten 24 h aus der
    /// Datenbank, solange die Seite offen ist. Ohne gehörte Sonde: der letzte
    /// Flug aus dem Archiv. Die Leseläufe hängen am Abbruch dieser Aufgabe, damit
    /// sich abgebrochene Läufe nicht stapeln.
    private func followHistory() async {
        guard let serial = historySerial else {
            // Den letzten richtigen Flug, nicht eine kurz angeschnittene Sonde.
            let work = Task.detached(priority: .utility) { () -> SondeFlight? in
                let flights = SondeArchive.recent(limit: 10)
                return flights.first { $0.positioned.count >= 20 } ?? flights.first
            }
            let latest = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled { history = latest; historyIsArchive = latest != nil }
            return
        }
        historyIsArchive = false
        while !Task.isCancelled {
            let work = Task.detached(priority: .utility) {
                SondeArchive.loadCurrent(serial: serial, isCancelled: { Task.isCancelled })
            }
            let flight = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled, flight != history { history = flight }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    @ViewBuilder private var historyPane: some View {
        if let history {
            VStack(alignment: .leading, spacing: 0) {
                if historyIsArchive {
                    Label("Letzter Flug aus dem Archiv", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
                        .padding([.horizontal, .top], 10)
                }
                SondeHistoryView(flight: history)
            }
        } else {
            ContentUnavailableView("Kein Verlauf", systemImage: "chart.xyaxis.line",
                                   description: Text("Sobald eine Sonde zu hören ist, siehst du hier Höhe, Steigen, Temperatur und Feuchte im Verlauf."))
        }
    }

    private var positioned: [Sonde] {
        model.sondes.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private func center(on id: Sonde.ID?) {
        guard let id, let sonde = model.sondes.first(where: { $0.id == id }),
              let lat = sonde.latitude, let lon = sonde.longitude else { return }
        mapController.center(on: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    // MARK: - Karte

    private var mapFeatures: [MapFeature] {
        let accent = MapColor.accent
        var list: [MapFeature] = []
        if let home {
            list.append(.home(home))
            // Unsichtbarer Kreis der typischen Reichweite (Sonden sind bis ~150 km zu hören): Ohne Ziele
            // zoomte die Karte sonst bis auf die eigene Straße.
            list.append(.extent("range", center: home, radius: 150_000))
        }
        for sonde in positioned {
            let selected = selection == sonde.id
            let key = "so:\(sonde.id)"
            if sonde.trail.count > 1 {
                let trail = sonde.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                list.append(.line("\(key)/trail", trail, color: selected ? MapColor.selected : accent,
                                  width: selected ? 3 : 2, opacity: selected ? 1 : 0.7, arrows: true, selected: selected))
            }
            if let landing = sonde.landing(groundAltitude: groundAltitude) {
                let here = CLLocationCoordinate2D(latitude: sonde.latitude!, longitude: sonde.longitude!)
                let there = CLLocationCoordinate2D(latitude: landing.lat, longitude: landing.lon)
                list.append(.line("\(key)/landingline", [here, there], color: MapColor.red, width: 1.5, opacity: 0.7, dash: [5, 4]))
                list.append(.badge("\(key)/landing", at: there, symbol: .scope, color: MapColor.red,
                                   label: String(localized: "Landung ≈"), select: sonde.id))
            }
            let stale = Date().timeIntervalSince(sonde.lastSeen) > 60
            list.append(.marker(key, at: CLLocationCoordinate2D(latitude: sonde.latitude!, longitude: sonde.longitude!),
                                symbol: sonde.burst ? .descent : .balloon,
                                color: selected ? MapColor.selected : stale ? MapColor.stale : accent,
                                size: 22, label: sonde.serial, selected: selected, select: sonde.id))
        }
        return list
    }

    private var map: some View {
        LeafletMap(features: mapFeatures, controller: mapController,
                   options: MapOptions(center: home.map(MapPoint.init) ?? MapPoint(51, 10), zoom: home == nil ? 5 : 8),
                   onSelect: { selection = $0 })
            .overlay(alignment: .topLeading) {
                if positioned.isEmpty {
                    Text(model.running ? "Noch keine Position empfangen" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !mapController.following, !positioned.isEmpty {
                    Button("Alle Sonden zeigen", systemImage: "scope") { mapController.showAll() }
                        .padding(10)
                }
            }
    }

    // MARK: - Tabelle

    private var table: some View {
        Table(model.sondes.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("Seriennr.", sortUsing: ColumnSort("serie", text: { $0.serial })) { Text($0.serial).font(.body.monospaced()) }.width(90)
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { $0.latest.model })) { Text($0.latest.model) }.width(75)
            TableColumn("Frequenz", sortUsing: ColumnSort("frequenz") { $0.latest.frequency }) { Text(verbatim: "\(($0.latest.frequency / 1e6).formatted(.number.precision(.fractionLength(3)))) MHz").monospacedDigit() }.width(90)
            TableColumn("Höhe", sortUsing: ColumnSort("hoehe") { $0.latest.altitude }) { sonde in Text(sonde.latest.altitude.map { "\(($0).formatted(.number.precision(.fractionLength(0)))) m" } ?? "–").monospacedDigit() }.width(70)
            TableColumn("Steigen", sortUsing: ColumnSort("steigen") { $0.latest.verticalSpeed }) { sonde in
                Text(sonde.latest.verticalSpeed.map { "\(($0).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) m/s" } ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(sonde.burst ? .red : .primary)
            }.width(75)
            TableColumn("Drift", sortUsing: ColumnSort("drift") { $0.latest.groundSpeed }) { sonde in Text(drift(sonde.latest)) }.width(95)
            TableColumn("Temp./Feuchte", sortUsing: ColumnSort("temperatur") { $0.latest.temperature }) { sonde in Text(weather(sonde.latest)) }.width(105)
            TableColumn("Entfernung", sortUsing: ColumnSort("entfernung") { distanceKm($0.latitude, $0.longitude) }) { sonde in Text(distance(sonde)) }.width(95)
            TableColumn("Rahmen", sortUsing: ColumnSort("rahmen") { $0.frames }) { Text("\($0.frames)").monospacedDigit() }.width(55)
            TableColumn("Letzter Kontakt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { Text($0.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(100)
        }
        .contextMenu(forSelectionType: Sonde.ID.self) { ids in
            if let sonde = model.sondes.first(where: { ids.contains($0.id) }) {
                Button("Auf SondeHub öffnen") {
                    if let url = URL(string: "https://sondehub.org/\(sonde.latest.serial)") { NSWorkspace.shared.open(url) }
                }
                .disabled(sonde.latest.serial.isEmpty)
                Button("Seriennummer kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sonde.latest.serial, forType: .string)
                }
            }
        }
        .overlay {
            if model.sondes.isEmpty {
                ContentUnavailableView("Keine Sonden", systemImage: "balloon",
                                       description: Text(model.running
                                                         ? "Noch nichts empfangen. Sonden senden nur kurz vor und während des Flugs (rund zwei Stunden)."
                                                         : "Klicke auf „Start“, um nach Sonden zu suchen."))
            }
        }
    }

    // MARK: - Bedienfeld

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
                    Button("Archiv …") { openWindow(id: "sondeArchive") }
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Kanäle") {
                if model.channels.isEmpty {
                    Text(model.running ? "Gerade sendet keine Sonde." : "–").foregroundStyle(.secondary)
                }
                ForEach(model.channels) { channel in
                    HStack {
                        Image(systemName: channel.lastDecoded.map { Date().timeIntervalSince($0) < 10 } == true
                              ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(channel.lastDecoded != nil ? .green : .secondary)
                        Text(verbatim: "\((channel.frequency / 1e6).formatted(.number.precision(.fractionLength(3)))) MHz").monospacedDigit()
                        Spacer()
                        Text(verbatim: "\((channel.levelDB).formatted(.number.precision(.fractionLength(0)))) dB").font(.caption).foregroundStyle(.secondary)
                        if channel.pinned {
                            Button { model.unpin(channel) } label: { Image(systemName: "pin.slash") }
                                .buttonStyle(.borderless)
                                .help("Nicht mehr festhalten")
                                .accessibilityLabel("Nicht mehr festhalten")
                        }
                    }
                }
                HStack {
                    FrequencyField(value: $manualMHz, range: 400...406, width: nil) { model.pin(mhz: $0) }
                    Button("Festhalten") { model.pin(mhz: manualMHz) }
                        .disabled(!(400...406).contains(manualMHz))
                }
                Text("Die App sucht das ganze Band selbst ab und hört bis zu vier Sonden gleichzeitig. Findet sie eine bekannte Sonde nicht, trag deren Frequenz ein und klicke auf „Festhalten“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Sonden", value: "\(model.sondes.count)")
                LabeledContent("Gültige Rahmen", value: "\(model.reportCount)")
                if let note = model.gainNote {
                    LabeledContent("Verstärkung zuletzt", value: note)
                        .help("Zuletzt hat die App die Verstärkung zurückgenommen, weil das Signal zu stark war.")
                }
            }
            FrequencyMemorySection(page: .sonde, currentMHz: manualMHz, range: 400...406) { entry in
                manualMHz = entry.mhz
                model.pin(mhz: entry.mhz)
            }
            Section("Landeschätzung") {
                LabeledContent("Bodenhöhe") {
                    TextField("", value: $groundAltitude, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing).frame(width: 70)
                        // Auf −500…9000 m begrenzen (siehe `Sonde.groundAltitudeRange`).
                        .onChange(of: groundAltitude) { _, value in
                            let clamped = Sonde.clampedGroundAltitude(value)
                            if clamped != value { groundAltitude = clamped }
                        }
                    Text("m")
                }
                Text("Sinkt eine Sonde, zeigt die Karte grob, wo sie landet. Für die Suche vor Ort ist die Vorhersage auf SondeHub genauer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Die Schätzung nimmt an, dass die Sinkrate zum Boden hin abnimmt, und rechnet mit dem Wind in der aktuellen Höhe weiter.")
            }
            Section(PanelSection.hinweis) {
                Text("Wetterstationen lassen meist um 00 und 12 Uhr UTC Sonden steigen, manche auch um 06 und 18 Uhr. Ein Flug dauert 1,5–2 Stunden, bis der Ballon in 25–35 km Höhe platzt.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Üblich sind Vaisala RS41 (Deutscher Wetterdienst); DFM-Sonden nutzt vor allem die Bundeswehr. Die Zeiten weichen je nach Station ab.")
                Text("Temperatur und Feuchte erscheinen erst nach etwa einer Minute Empfang.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Die Kalibrierdaten kommen über 51 Rahmen verteilt; die Feuchte ist eine Näherung. RS41-Höhen beziehen sich auf das Ellipsoid (in Deutschland etwa 45–50 m über Meereshöhe).")
                HomeLocationHint(purpose: "für Entfernung und Karte")
            }
        }
        .formStyle(.grouped)
    }

    private func weather(_ report: SondeReport) -> String {
        guard let t = report.temperature else { return "–" }
        let humidity = report.humidity.map { " · \(($0).formatted(.number.precision(.fractionLength(0)))) %" } ?? ""
        return "\((t).formatted(.number.precision(.fractionLength(1)))) °C" + humidity
    }

    private func drift(_ report: SondeReport) -> String {
        guard let speed = report.groundSpeed else { return "–" }
        let direction = report.heading.map { " \(GeoMath.compass($0))" } ?? ""
        return "\((speed * 3.6).formatted(.number.precision(.fractionLength(0)))) km/h" + direction
    }

    private func distanceKm(_ lat: Double?, _ lon: Double?) -> Double? {
        guard let home, let lat, let lon else { return nil }
        return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
    }

    private func distance(_ sonde: Sonde) -> String {
        guard let home, let lat = sonde.latitude, let lon = sonde.longitude else { return "–" }
        let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
        return "\((km).formatted(.number.precision(.fractionLength(1)))) km " + GeoMath.compass(bearing)
    }
}
