import CoreLocation
import SwiftUI

/// Funkfeuer (VOR): Radial messen, Kennung lesen, Kreuzpeilung auf der Karte.
struct VORView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.vor
    @State private var database = NavaidDatabase.shared
    @State private var selection: Navaid.ID?
    @State private var mapController = MapController()
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    /// Die 40 nächsten Funkfeuer – zwischengespeichert. Früher rechnete `body` sie
    /// viermal je Auswertung über rund 11 000 Funkfeuer neu (Review 28.10.2026, Y19).
    @State private var nearby: [(navaid: Navaid, km: Double)] = []

    private struct NearbyKey: Equatable {
        var count: Int
        var updated: Date?
        var lat: Double
        var lon: Double
    }

    private var nearbyKey: NearbyKey {
        NearbyKey(count: database.navaids.count, updated: database.updated, lat: homeLat, lon: homeLon)
    }

    private func updateNearby() {
        guard let home else { nearby = []; return }
        nearby = NavaidCSV.nearest(database.navaids, lat: home.latitude, lon: home.longitude, count: 40)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "location.north.line", text: String(localized: "Die App wertet Funkfeuer (VOR) selbst aus und zeigt dir, in welcher Richtung du davon stehst – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 310, issue: model.error) {
                VSplitView {
                    map.frame(minHeight: 180, idealHeight: 380)
                    stationTable.frame(minHeight: 120)
                }
                .frame(minWidth: 480)
            } controls: {
                controls
            }
            .onAppear { database.loadIfNeeded() }
            .onChange(of: nearbyKey, initial: true) { _, _ in updateNearby() }
            .task { if AppNavigation.shared.takeAutoStart(.vor), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    // MARK: - Karte

    private func mapFeatures(fix: VORFix?) -> [MapFeature] {
        var list: [MapFeature] = []
        if let home { list.append(.home(home, color: MapColor.blue)) }
        for item in nearby {
            let current = model.station?.id == item.navaid.id
            var f = MapFeature.marker("nav:\(item.navaid.id)",
                                      at: CLLocationCoordinate2D(latitude: item.navaid.latitude, longitude: item.navaid.longitude),
                                      symbol: .hexagon, color: current ? MapColor.selected : MapColor.indigo,
                                      size: current ? 20 : 12, label: item.navaid.ident, select: "nav:\(item.navaid.id)")
            if current { f.emphasis = true; f.z = 1000 }
            list.append(f)
        }
        for (k, bearing) in model.bearings.prefix(2).enumerated() {
            list.append(.line("radial:\(k)", radialLine(bearing.navaid, trueRadial: bearing.trueRadial),
                              color: k == 0 ? MapColor.selected : MapColor.purple, width: 2.5))
        }
        if let station = model.station, let radial = model.radial,
           !model.bearings.contains(where: { $0.id == station.id }) {
            list.append(.line("radial:live", radialLine(station, trueRadial: station.trueRadial(radial)),
                              color: MapColor.selected, width: 2, opacity: 0.5, dash: [6, 4]))
        }
        if let fix {
            list.append(.marker("fix", at: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
                                symbol: .scope, color: MapColor.red, size: 24, label: String(localized: "Kreuzpeilung"), layer: .top))
        }
        return list
    }

    private var map: some View {
        let fix = model.fix(homeLat: home?.latitude, homeLon: home?.longitude)
        return LeafletMap(features: mapFeatures(fix: fix), controller: mapController,
                          options: MapOptions(fitMaxZoom: 11, center: home.map(MapPoint.init) ?? MapPoint(51, 10), zoom: home == nil ? 5 : 8),
                          onSelect: { key in
                              guard let key, key.hasPrefix("nav:") else { return }
                              if let navaid = nearby.first(where: { "nav:\($0.navaid.id)" == key })?.navaid { select(navaid) }
                          })
        .overlay(alignment: .topLeading) {
            if let fix {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kreuzpeilung").font(.headline)
                    Text(String(format: "%.4f° N  %.4f° O", fix.latitude, fix.longitude)).monospacedDigit()
                    Text(fix.cutAngle < 30 ? "Schnittwinkel \(Int(fix.cutAngle.rounded()))° – ungenau" : "Schnittwinkel \(Int(fix.cutAngle.rounded()))°")
                        .foregroundStyle(fix.cutAngle < 30 ? .orange : .secondary)
                    if let km = fix.distanceToHomeKm {
                        Text(String(format: String(localized: "%.1f km vom eingetragenen Standort"), km)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !mapController.following, !nearby.isEmpty {
                Button("Alle Funkfeuer zeigen", systemImage: "scope") { mapController.showAll() }
                    .padding(10)
            }
        }
    }

    /// Großkreis vom Funkfeuer unter dem Radial, 250 km lang.
    private func radialLine(_ navaid: Navaid, trueRadial: Double) -> [CLLocationCoordinate2D] {
        stride(from: 0.0, through: 250, by: 10).map { km in
            let p = GeoNav.destination(lat: navaid.latitude, lon: navaid.longitude, bearing: trueRadial, km: km)
            return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        }
    }

    // MARK: - Liste

    private var stationTable: some View {
        Table(nearby.map(NearbyRow.init), selection: $selection) {
            TableColumn("Kennung") { row in Text(row.navaid.ident).bold() }.width(60)
            TableColumn("Name") { row in Text(row.navaid.name) }
            TableColumn("Art") { row in Text(row.navaid.type).foregroundStyle(.secondary) }.width(80)
            TableColumn("MHz") { row in Text(String(format: "%.2f", row.navaid.mhz)).monospacedDigit() }.width(56)
            TableColumn("Entfernung") { row in
                Text(String(format: "%.0f km %@", row.km, GeoMath.compass(row.bearing))).monospacedDigit()
            }.width(90)
        }
        .onChange(of: selection) { _, id in
            if let id, let navaid = nearby.first(where: { $0.navaid.id == id })?.navaid { select(navaid) }
        }
        .overlay {
            if database.navaids.isEmpty {
                ContentUnavailableView {
                    Label("Keine Funkfeuer-Datenbank", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Einmal von OurAirports laden (≈ 3 MB). Dein Standort wird dabei nicht gesendet.")
                } actions: {
                    Button(database.loading ? "Lädt …" : "Datenbank laden") { Task { await database.download() } }
                        .disabled(database.loading)
                }
            } else if home == nil {
                ContentUnavailableView {
                    Label("Standort fehlt", systemImage: "location.slash")
                } description: {
                    Text("Trag deinen Standort in den Einstellungen ein – dann stehen hier die nächsten Funkfeuer.")
                } actions: {
                    HomeLocationHint().frame(maxWidth: 320)
                }
            } else if nearby.isEmpty {
                ContentUnavailableView("Kein VOR in 400 km", systemImage: "location.north.line")
            }
        }
    }

    private struct NearbyRow: Identifiable {
        var navaid: Navaid
        var km: Double
        var bearing: Double
        var id: String { navaid.id }

        init(_ item: (navaid: Navaid, km: Double)) {
            navaid = item.navaid
            km = item.km
            let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
            bearing = GeoMath.bearingDegrees(lat1: lat, lon1: lon, lat2: item.navaid.latitude, lon2: item.navaid.longitude)
        }
    }

    private func select(_ navaid: Navaid) {
        model.select(navaid)
        selection = navaid.id
    }

    // MARK: - Bedienfeld

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
                    FrequencyField(mhz: model.frequencyMHz, range: 108...117.95, decimals: 2, width: 70) {
                        model.tune(to: $0)
                    }
                    Text("MHz").foregroundStyle(.secondary)
                }
                if let station = model.station {
                    Text("\(station.ident) – \(station.name) (\(station.type))").font(.callout)
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                radialDisplay
                LabeledContent("Güte", value: model.signalQuality.text)
                if let reading = model.reading, reading.carrierFraction < VORQuality.minCarrierFraction {
                    // Kein Träger: Modulationswerte wären nur Rauschen – stattdessen erklären.
                    Text("Hier ist kein Funkfeuer zu hören. Am Boden reichen sie oft nur 20–40 km – wähle ein näheres oder bring die Antenne höher und waagerecht an.")
                        .help("Funkfeuer sind für Flugzeuge in der Höhe gebaut, brauchen freie Sicht und sind horizontal polarisiert. Manche sind abgeschaltet, obwohl sie noch in der Liste stehen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let reading = model.reading {
                    LabeledContent("30 Hz AM", value: String(format: "%.0f %%", reading.amDepth * 100))
                    LabeledContent("Hilfsträger 9960 Hz", value: String(format: "%.0f %%", reading.subcarrierDepth * 100))
                    LabeledContent("FM-Hub", value: String(format: "%.0f Hz", reading.deviationHz))
                }
                if let spread = model.spread {
                    LabeledContent("Streuung (10 s)", value: String(format: "± %.1f°", spread))
                }
            }
            FrequencyMemorySection(page: .vor, currentMHz: model.frequencyMHz,
                                   suggestedName: model.station.map { "\($0.ident) \($0.name)" } ?? "", range: 108...117.95) { model.tune(to: $0.mhz) }
            Section("Kennung") {
                HStack {
                    Image(systemName: model.identKeyed ? "dot.radiowaves.left.and.right" : "circle.dotted")
                        .foregroundStyle(model.identKeyed ? .green : .secondary)
                    Text(model.ident ?? "–").font(.title3.monospaced().bold())
                    Spacer()
                    if let matches = model.identMatches {
                        Label(matches ? "passt" : "passt nicht", systemImage: matches ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(matches ? .green : .orange)
                    }
                }
                if let ident = model.ident, model.station == nil, let match = candidates(for: ident).first {
                    Button("Funkfeuer \(match.ident) (\(match.name)) wählen") { select(match) }
                }
                Toggle("Ton hören", isOn: $model.listen)
                if model.listen {
                    LabeledContent("Lautstärke") { Slider(value: $model.volume, in: 0...1) }
                }
            }
            Section("Kreuzpeilung") {
                if model.bearings.isEmpty {
                    Text("Wähl ein Funkfeuer und warte, bis die Güte „gut“ zeigt – die App merkt sich die Richtung. Dann ein zweites: Wo sich beide Linien schneiden, bist du.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.bearings) { bearing in
                    HStack {
                        Text(bearing.navaid.ident).bold()
                        Text(String(format: "%03.0f° mw · %03.0f° rw", bearing.magnetic, bearing.trueRadial)).monospacedDigit()
                        Spacer()
                        Button { model.removeBearing(bearing) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Peilung entfernen")
                            .accessibilityLabel("Peilung entfernen")
                    }
                    .font(.callout)
                }
                if model.bearings.count > 2 {
                    Text("Die Karte nutzt die beiden jüngsten.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(PanelSection.daten) {
                LabeledContent("Funkfeuer-Datenbank", value: "\(database.navaids.count) VOR")
                if let updated = database.updated {
                    LabeledContent("Stand", value: updated.formatted(date: .abbreviated, time: .omitted))
                }
                Button(database.loading ? "Lädt …" : "Aktualisieren", systemImage: "arrow.down.circle") {
                    Task { await database.download() }
                }
                .disabled(database.loading)
                if let error = database.error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Quelle: OurAirports (gemeinfrei), einmal geladen und auf dem Mac gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.hinweis) {
                HomeLocationHint(purpose: "für die nächsten Funkfeuer")
            }
        }
        .formStyle(.grouped)
    }

    private var radialDisplay: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.radial.map { String(format: "%03.0f°", $0) } ?? "–––°")
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                Text("Radial").foregroundStyle(.secondary)
                Spacer()
                if let radial = model.radial {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(radial))
                        .font(.title)
                        .foregroundStyle(.orange)
                }
            }
            if let radial = model.radial {
                if let station = model.station, let declination = station.declination {
                    Text(String(format: declination >= 0
                                ? String(localized: "Missweisend (Station auf %.1f° Ost ausgerichtet) – rechtweisend %03.0f°. Vom Funkfeuer aus liegst du Richtung %@.")
                                : String(localized: "Missweisend (Station auf %.1f° West ausgerichtet) – rechtweisend %03.0f°. Vom Funkfeuer aus liegst du Richtung %@."),
                                abs(declination), station.trueRadial(radial),
                                GeoMath.compass(station.trueRadial(radial))))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Vom Funkfeuer aus liegst du etwa Richtung \(GeoMath.compass(radial)). Für die Karte wähl das Funkfeuer aus der Liste.")
                        .help("Das Radial ist missweisend, also auf magnetisch Nord bezogen. Die Missweisung der Station steht in der Funkfeuer-Liste.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.station?.isDoppler == true {
                    Text("Doppler-VOR: wird genauso ausgewertet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func candidates(for ident: String) -> [Navaid] {
        database.navaids.filter { $0.ident.uppercased() == ident && abs($0.mhz - model.frequencyMHz) < 0.03 }
            .sorted { a, b in
                guard let home else { return true }
                return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: a.latitude, lon2: a.longitude)
                    < GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: b.latitude, lon2: b.longitude)
            }
    }

}
