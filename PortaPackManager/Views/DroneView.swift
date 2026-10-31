import CoreLocation
import SwiftUI

struct DroneView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.drones
    @State private var selection: Drone.ID?
    @State private var order: [ColumnSort<Drone>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @State private var mapController = MapController()
    @State private var showTrails = true
    @State private var showOperators = true

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "airplane.circle", text: String(localized: "Drohnen senden ihre Kennung (Remote ID) per Bluetooth und WLAN. Die App empfängt sie über den HackRF und den Mac – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    map.frame(minHeight: 240)
                    HStack(spacing: 0) {
                        table.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        detail.frame(width: 300).frame(maxHeight: .infinity)
                    }
                    .frame(minHeight: 200)
                }
                // Kein HSplitView im VSplitView: das ließ AppKit die Constraints endlos
                // neu rechnen (Absturz beim Öffnen, 30.10.2026 – wie Smart Home 28.10.).
                // Innen 340 + Trenner 1 + 300 = 641 < 660 außen.
                .frame(minWidth: 660)
            } controls: {
                controls
            }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop() }
            }
            .onChange(of: selection) { _, id in center(on: id) }
        }
    }

    private var positioned: [Drone] {
        model.drones.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private var operators: [Drone] {
        model.drones.filter { $0.system?.operatorLatitude != nil && $0.system?.operatorLongitude != nil }
    }

    private func center(on id: Drone.ID?) {
        guard let id, let drone = model.drones.first(where: { $0.id == id }),
              let lat = drone.latitude ?? drone.system?.operatorLatitude,
              let lon = drone.longitude ?? drone.system?.operatorLongitude else { return }
        mapController.center(on: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    // MARK: - Karte

    private var mapFeatures: [MapFeature] {
        let accent = MapColor.accent
        var list: [MapFeature] = []
        if let home { list.append(.home(home)) }
        if showTrails {
            for drone in positioned where drone.trail.count > 1 {
                let selected = selection == drone.id
                list.append(.line("dr:\(drone.id)/trail", drone.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                                  color: selected ? MapColor.selected : accent, width: selected ? 3 : 1.5,
                                  opacity: selected ? 1 : 0.5, selected: selected))
            }
        }
        if showOperators {
            for drone in operators {
                let pilot = CLLocationCoordinate2D(latitude: drone.system!.operatorLatitude!,
                                                   longitude: drone.system!.operatorLongitude!)
                if let lat = drone.latitude, let lon = drone.longitude {
                    list.append(.line("dr:\(drone.id)/pilotline", [pilot, CLLocationCoordinate2D(latitude: lat, longitude: lon)],
                                      color: MapColor.purple, width: 1, opacity: 0.6, dash: [4, 3]))
                }
                list.append(.badge("dr:\(drone.id)/pilot", at: pilot, symbol: .person, color: MapColor.purple,
                                   label: String(localized: "Pilot"), select: String(drone.id)))
            }
        }
        for drone in positioned {
            let selected = selection == drone.id
            let stale = Date().timeIntervalSince(drone.lastSeen) > 30
            list.append(.marker("dr:\(drone.id)", at: CLLocationCoordinate2D(latitude: drone.latitude!, longitude: drone.longitude!),
                                symbol: .planeCircle, color: selected ? MapColor.selected : stale ? MapColor.stale : accent,
                                size: 22, rotation: drone.location?.direction ?? 90, label: drone.displayName,
                                selected: selected, select: String(drone.id)))
        }
        return list
    }

    private var map: some View {
        LeafletMap(features: mapFeatures, controller: mapController,
                   options: MapOptions(fitMaxZoom: 16, center: home.map(MapPoint.init) ?? MapPoint(51, 10), zoom: home == nil ? 5 : 13),
                   onSelect: { selection = $0 })
            .overlay(alignment: .topLeading) {
                if positioned.isEmpty {
                    Text(model.running ? "Noch keine Drohnenposition empfangen" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !mapController.following, !positioned.isEmpty {
                    Button("Alle Drohnen zeigen", systemImage: "scope") { mapController.showAll() }
                        .padding(10)
                }
            }
    }

    // MARK: - Tabelle

    private var table: some View {
        Table(model.drones.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("Kennung", sortUsing: ColumnSort("kennung", text: { $0.uasID })) { drone in
                Text(drone.uasID ?? drone.address.string).font(.body.monospaced())
                    .foregroundStyle(drone.uasID == nil ? .secondary : .primary)
            }
            TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.uaType })) { Text($0.uaType ?? "–") }.width(110)
            TableColumn("Status", sortUsing: ColumnSort("status", text: { $0.location?.statusName })) { drone in
                Text(drone.location?.statusName ?? "–")
                    .foregroundStyle(drone.location?.status == 3 ? .red : .primary)
            }.width(80)
            TableColumn("Höhe", sortUsing: ColumnSort("hoehe") { $0.location?.altitudeGeo ?? $0.location?.altitudeBaro }) { drone in
                Text(meters(drone.location?.height ?? drone.location?.altitudeGeo ?? drone.location?.altitudeBaro))
            }.width(60)
            TableColumn("Tempo", sortUsing: ColumnSort("tempo") { $0.location?.speed }) { drone in
                Text(drone.location?.speed.map { String(format: "%.1f m/s", $0) } ?? "–")
            }.width(65)
            TableColumn("Entfernung", sortUsing: ColumnSort("entfernung") { distanceKm($0.latitude, $0.longitude) }) { drone in
                Text(distanceKm(drone.latitude, drone.longitude).map { String(format: "%.2f km", $0) } ?? "–")
            }.width(75)
            TableColumn("Pegel", sortUsing: ColumnSort("pegel") { $0.rssiDB }) { Text(String(format: "%.0f dB", $0.rssiDB)).monospacedDigit() }.width(50)
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { Text($0.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(90)
        }
        .overlay {
            if model.drones.isEmpty {
                ContentUnavailableView("Keine Drohnen", systemImage: "airplane.circle",
                                       description: Text(model.running
                                                         ? "Noch keine Drohnen-Kennung. Drohnen senden sie im Flug etwa einmal pro Sekunde – per Bluetooth meist nur einige hundert Meter weit, per WLAN etwas weiter."
                                                         : "Mit „Start“ beginnt der Empfang auf den gewählten Quellen."))
            }
        }
    }

    // MARK: - Einzelheiten

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let drone = model.drones.first(where: { $0.id == selection }) {
                    droneDetail(drone)
                } else {
                    Text("Drohne wählen, um alle empfangenen Angaben zu sehen.").foregroundStyle(.secondary)
                    recentMessages
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func droneDetail(_ drone: Drone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(drone.displayName).font(.headline).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(drone.basicIDs.enumerated()), id: \.offset) { _, basic in
                    row(basic.idTypeName, basic.uasID)
                }
                if let type = drone.uaType { row("Luftfahrzeug", type) }
                row("Adresse", "\(drone.address.string) (\(drone.address.random ? drone.address.kind : String(localized: "BLE öffentlich oder WLAN-BSSID")))")
                row("Nachrichten", "\(drone.messageCount)")
                row("Pegel", String(format: "%.1f dBFS", drone.rssiDB))
                row("Zuerst", drone.firstSeen.formatted(date: .omitted, time: .standard))
            }
            .font(.callout)
            if let location = drone.location {
                section("Position und Bewegung") {
                    row("Status", location.statusName)
                    if let lat = location.latitude, let lon = location.longitude {
                        row("Position", String(format: "%.6f, %.6f", lat, lon))
                    }
                    if let accuracy = location.horizontalAccuracyMeters { row("Genauigkeit", "< \(format(accuracy)) m") }
                    row("Höhe WGS-84", meters(location.altitudeGeo))
                    row("Druckhöhe", meters(location.altitudeBaro))
                    row(location.heightOverGround ? "Höhe über Grund" : "Höhe über Start", meters(location.height))
                    row("Geschwindigkeit", location.speed.map { String(format: "%.2f m/s (%.0f km/h)", $0, $0 * 3.6) } ?? "–")
                    row("Steigen", location.verticalSpeed.map { String(format: "%+.1f m/s", $0) } ?? "–")
                    row("Kurs", location.direction.map { String(format: "%.0f°", $0) } ?? "–")
                    if let time = location.timestamp {
                        row("Zeit", String(format: String(localized: "%02d:%04.1f nach der vollen Stunde"), Int(time) / 60, time.truncatingRemainder(dividingBy: 60)))
                    }
                }
            }
            if let system = drone.system {
                section("Pilot und Einsatz") {
                    if let lat = system.operatorLatitude, let lon = system.operatorLongitude {
                        row("Pilot", String(format: "%.6f, %.6f", lat, lon))
                        if let dLat = drone.latitude, let dLon = drone.longitude {
                            let km = GeoMath.distanceKm(lat1: lat, lon1: lon, lat2: dLat, lon2: dLon)
                            row("Abstand zur Drohne", String(format: "%.0f m", km * 1000))
                        }
                    }
                    row("Pilotposition", system.operatorLocationName)
                    if let alt = system.operatorAltitude { row("Pilot Höhe", meters(alt)) }
                    if let eu = system.euClassification { row("EU-Einstufung", eu) }
                    if system.areaCount > 1 { row("Schwarm", String(localized: "\(system.areaCount) Fluggeräte, Radius \(system.areaRadius) m")) }
                    if let time = system.timestamp { row("Zeitstempel", time.formatted(date: .numeric, time: .standard)) }
                }
            }
            if drone.operatorID != nil || drone.selfID != nil || drone.authType != nil {
                section("Betreiber") {
                    if let op = drone.operatorID { row("Betreiber-ID", op.id) }
                    if let selfID = drone.selfID, !selfID.text.isEmpty { row("Beschreibung", selfID.text) }
                    if let auth = drone.authType {
                        row("Authentisierung", String(localized: "\(RemoteID.Auth(authType: auth, page: 0).typeName) (nicht geprüft)"))
                    }
                }
            }
        }
    }

    private var recentMessages: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.log.isEmpty { Text("Letzte Nachrichten").font(.subheadline.weight(.semibold)) }
            ForEach(model.log.prefix(40)) { line in
                HStack {
                    Text(line.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                    Text(line.message.type.name)
                    Spacer()
                    Text(line.address.string).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(line.source).font(.caption).foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) { content() }
                .font(.callout)
        }
    }

    /// Zeile mit festem Titel (Literal → übersetzt).
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// Zeile mit Titel aus dem Dekoder (dort schon übersetzt).
    private func row<S: StringProtocol>(_ label: S, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func meters(_ value: Double?) -> String {
        value.map { String(format: "%.1f m", $0) } ?? "–"
    }

    private func format(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%g", value)
    }

    private func distanceKm(_ lat: Double?, _ lon: Double?) -> Double? {
        guard let home, let lat, let lon else { return nil }
        return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
    }

    // MARK: - Bedienung

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop() }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Quellen HackRF") {
                Toggle("Bluetooth LE 4 (Kanäle 37–39)", isOn: $model.useBLE)
                    .onChange(of: model.useBLE) { _, _ in model.sourcesChanged() }
                if model.useBLE {
                    Picker("Werbekanal", selection: $model.choice) {
                        ForEach(BLEModel.ChannelChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: model.choice) { _, _ in model.choiceChanged() }
                }
                Toggle("WLAN 2,4 GHz, Kanal 6 (NAN + Beacons)", isOn: $model.useWLAN24)
                    .onChange(of: model.useWLAN24) { _, _ in model.sourcesChanged() }
                    .help("Drohnen senden Remote ID über WLAN auf Kanal 6. Der HackRF liest die WLAN-Rahmen selbst (DSSS 1/2 Mbit/s, OFDM 6–54 Mbit/s).")
                Toggle("WLAN 5 GHz, Kanal 149", isOn: $model.useWLAN5)
                    .onChange(of: model.useWLAN5) { _, _ in model.sourcesChanged() }
                if model.plan.count > 1 {
                    LabeledContent("Wechsel alle \(Int(model.dwell)) s") {
                        Slider(value: $model.dwell, in: 1...10, step: 1)
                    }
                }
            }
            Section("Quellen Mac") {
                Toggle("WLAN-Beacons (WLAN des Mac)", isOn: $model.useWiFi)
                    .onChange(of: model.useWiFi) { _, _ in model.updateWiFi() }
                    .help("Sucht alle 3 s nach WLAN-Beacons mit Remote ID. Während einer Suche kann die WLAN-Verbindung des Mac kurz stocken.")
                Toggle("Bluetooth des Mac", isOn: $model.useMacBluetooth)
                    .onChange(of: model.useMacBluetooth) { _, _ in model.updateMacBluetooth() }
                    .help("Der Mac hört alle drei Bluetooth-Werbekanäle zugleich und ist empfindlicher als der HackRF; Bluetooth 5 Long Range empfängt er nicht.")
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Drohnen", value: "\(model.drones.count)")
                LabeledContent("Remote-ID-Nachrichten", value: "\(model.messageCount)")
                LabeledContent("BLE-Rahmen (HackRF)", value: "\(model.packetCount)")
                if model.useWLAN24 || model.useWLAN5 {
                    LabeledContent("WLAN-Rahmen (HackRF)", value: String(localized: "\(model.wlanFrames) · \(model.nanFrames) NAN · \(model.wlanRemoteID) Remote ID"))
                }
                if model.useWiFi, model.running {
                    LabeledContent("WLAN-Suchen (Mac)", value: String(localized: "\(model.wifiScans) · \(model.wifiFrames) Remote-ID-Beacons"))
                }
                if model.useMacBluetooth, model.running {
                    LabeledContent("Bluetooth (Mac)", value: String(localized: "\(model.macBluetoothFrames) Remote-ID-Rahmen"))
                }
                if let wifiError = model.wifiError {
                    Text(wifiError).font(.caption).foregroundStyle(.orange)
                }
                if let macBluetoothError = model.macBluetoothError {
                    Text(macBluetoothError).font(.caption).foregroundStyle(.orange)
                }
                if model.running {
                    LabeledContent("HackRF", value: model.step.map { "\($0.title) · \(String(format: "%.1f dBFS", model.noiseDB))" } ?? String(localized: "aus"))
                }
            }
            Section(PanelSection.anzeige) {
                Toggle("Flugspuren zeigen", isOn: $showTrails)
                Toggle("Pilotposition zeigen", isOn: $showOperators)
            }
            Section(PanelSection.hinweis) {
                Text("Mehr Quellen finden mehr Drohnen. Bluetooth 5 Long Range kann die App nicht empfangen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("HackRF: Bluetooth-LE-Werbung (4.x) auf 37–39 sowie WLAN-Kanal 6/149 – Beacons (ASTM F3411 und französische Kennung) und NAN. Mac: WLAN-Beacons (alle Kanäle) und Bluetooth-Werbung.")
                HomeLocationHint(purpose: "für die Entfernung")
            }
        }
        .formStyle(.grouped)
    }
}
