import CoreLocation
import SwiftUI

/// Amateurfunk FT8/WSPR: Dekodierliste, Karte der Locatoren, Wasserfall des
/// Audiobands mit Markierungen. Nur Empfang – nichts wird gesendet oder gemeldet.
struct FT8View: View {
    @Environment(DeviceSession.self) private var session
    /// Geteilt mit dem Fernzugriff (`RemoteHub.ft8`).
    @Bindable private var model = RemoteHub.shared.ft8
    @State private var selection: FT8Spot.ID?
    @State private var order: [ColumnSort<FT8Spot>] = []
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @AppStorage("ft8OnlyCQ") private var onlyCQ = false
    @AppStorage("ft8WaterfallWSPR") private var showWSPRWaterfall = false
    @State private var mapController = MapController()

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "globe.europe.africa",
                               text: "FT8 und WSPR empfängt die App selbst – auf 2 m, 6 m oder 70 cm. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 300, issue: model.error) {
                VSplitView {
                    FT8WaterfallPane(model: model, showWSPR: $showWSPRWaterfall)
                        .frame(minHeight: 110, idealHeight: 190)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Wasserfall des Amateurfunk-Kanals")
                    FT8MapPane(model: model, selection: $selection, home: home, controller: mapController)
                        .frame(minHeight: 140, idealHeight: 280)
                    FT8SpotTable(model: model, selection: $selection, order: $order, onlyCQ: onlyCQ, home: home)
                        .frame(minHeight: 120)
                }
                .frame(minWidth: 520)
            } controls: {
                controls
            }
            .task {
                if AppNavigation.shared.takeAutoStart(.ft8), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
            }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
            .onChange(of: selection) { _, id in center(on: id) }
        }
    }

    // MARK: - Karte

    private func center(on id: FT8Spot.ID?) {
        guard let id, let spot = model.spots.first(where: { $0.id == id }), let grid = spot.grid,
              let pos = FT8Locator.coordinate(grid) else { return }
        mapController.center(on: CLLocationCoordinate2D(latitude: pos.lat, longitude: pos.lon))
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
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Band") {
                Picker("Band", selection: $model.band) {
                    ForEach(FT8Model.Band.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: model.band) { _, _ in model.retune(on: session.hackRF) }
                Picker("Betriebsart", selection: $model.mode) {
                    ForEach(FT8Model.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: model.mode) { _, _ in model.retune(on: session.hackRF) }
                if model.mode.hasFT8 {
                    LabeledContent("FT8", value: Self.mhz(model.band.ft8Dial))
                }
                if model.mode.hasWSPR {
                    LabeledContent("WSPR", value: Self.mhz(model.band.wsprDial))
                }
                Toggle("Tiefe Dekodierung (OSD)", isOn: $model.deepDecoding)
                    .help("Findet zusätzlich schwache FT8-Signale (Ordered Statistics Decoding). Solche Zeilen tragen ein * hinter „FT8“.")
                Toggle("Quarzdrift nachführen", isOn: $model.driftTracking)
                    .help("Schätzt aus Stationen, die mehrmals gehört werden, wie weit der HackRF seit dem Start weggelaufen ist, und schiebt das Audioband zurück. Braucht mindestens drei wiederholt gehörte Stationen.")
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("UTC \(Self.utcLong.string(from: context.date))").font(.callout.monospacedDigit())
                        if model.running { cycleInfo(context.date) }
                    }
                }
                LabeledContent("Dekodierungen", value: "\(model.decodeCount)")
                LabeledContent("Stationen auf der Karte", value: "\(model.stations.count)")
                clockStatus
                crystalStatus
                driftStatus
                LabeledContent("Eigener Locator", value: home.map { FT8Locator.locator(lat: $0.latitude, lon: $0.longitude) } ?? "–")
                    .help("Aus dem Heimatstandort berechnet – nur für Entfernung und Richtung, wird nirgends hin gesendet.")
            }
            Section(PanelSection.anzeige) {
                Toggle("Nur CQ-Rufe zeigen", isOn: $onlyCQ)
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "ft8-wspr-spots", isEmpty: model.spots.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                Text("Nur Empfang: Die App sendet nichts und meldet keine Spots an PSK Reporter oder WSPRnet.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Ein HackRF ohne TCXO driftet in den ersten 15–20 Minuten nach dem Einschalten. Lass ihn vorher warmlaufen – oder nutze einen TCXO bzw. einen externen 10-MHz-Takt an CLKIN.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.crystalCalibrated {
                    SettingsHint(.device, "Den Quarzabgleich findest du unter „Antenne & Gerät“ – miss ihn am besten nach dem Aufwärmen.")
                }
                if model.clockInputDetected == true {
                    Label("Externer Takt an CLKIN erkannt.", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.clockInputDetected == false {
                    Label("Kein externer Takt an CLKIN – der HackRF läuft mit seinem eigenen Quarz.", systemImage: "waveform.path")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingsHint(.location, home == nil
                             ? "Kein Heimatstandort – ohne ihn fehlen Entfernung und Richtung."
                             : "Entfernung und Richtung gelten ab deinem Heimatstandort.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func cycleInfo(_ now: Date) -> some View {
        let t = now.timeIntervalSince1970
        if model.mode.hasFT8 {
            let into = t.truncatingRemainder(dividingBy: 15)
            let busy = model.decoding.contains(.ft8)
            Text(Self.cycleText("FT8", into: Int(into), period: 15, busy: busy, last: model.lastCycleCount[.ft8]))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if model.mode.hasWSPR {
            let into = t.truncatingRemainder(dividingBy: 120)
            let busy = model.decoding.contains(.wspr)
            Text(Self.cycleText("WSPR", into: Int(into), period: 120, busy: busy, last: model.lastCycleCount[.wspr]))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private static func cycleText(_ mode: String, into: Int, period: Int, busy: Bool, last: Int?) -> String {
        if busy { return String(localized: "\(mode): Zyklus \(into) / \(period) s · rechnet …") }
        if let last { return String(localized: "\(mode): Zyklus \(into) / \(period) s · zuletzt \(last)") }
        return String(localized: "\(mode): Zyklus \(into) / \(period) s")
    }

    @ViewBuilder
    private var clockStatus: some View {
        if let offset = model.clockOffset {
            let verdict = FT8Model.clockVerdict(median: offset.median, count: offset.count)
            Label(verdict.text, systemImage: verdict.ok ? "clock.badge.checkmark" : "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(verdict.ok ? Color.secondary : Color.orange)
        } else {
            Label("Die Uhr wird nach den ersten Dekodierungen geprüft.", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var crystalStatus: some View {
        if model.crystalCalibrated {
            Label(String(format: String(localized: "Quarzkorrektur %+.2f ppm aktiv."), model.crystalPPM), systemImage: "tuningfork")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Quarz nicht abgeglichen – die App sucht deshalb in einem breiteren Bereich.", systemImage: "exclamationmark.triangle")
                .help("Ohne Quarzkorrektur können Signale einige 100 Hz bis kHz daneben liegen.")
                .font(.caption).foregroundStyle(.orange)
            SettingsHint(.device, "Die Quarzkorrektur steht unter „Antenne & Gerät“.")
        }
    }

    @ViewBuilder
    private var driftStatus: some View {
        if let rate = model.driftRate, let offset = model.driftOffset {
            Label(Self.driftText(rate: rate, offset: offset, tracking: model.driftTracking), systemImage: "thermometer.medium")
                .help(String(localized: "Aus \(model.driftStations) wiederholt gehörten Stationen geschätzt."))
                .font(.caption).foregroundStyle(abs(rate * 60) >= 10 ? Color.orange : Color.secondary)
        } else if model.running {
            Label("Drift: noch zu wenige wiederholt gehörte Stationen (mindestens drei).", systemImage: "thermometer.medium")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func driftText(rate: Double, offset: Double, tracking: Bool) -> String {
        let perMinute = String(format: "%+.1f", rate * 60).replacingOccurrences(of: ".", with: ",")
        let hz = String(format: "%+.0f", offset)
        return tracking
            ? String(localized: "Drift: \(perMinute) Hz/min · Abweichung seit Start: \(hz) Hz (nachgeführt)")
            : String(localized: "Drift: \(perMinute) Hz/min · Abweichung seit Start: \(hz) Hz")
    }

    // MARK: - Hilfen

    private static let utcLong: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func mhz(_ hz: Int) -> String {
        String(format: "%.3f MHz", Double(hz) / 1e6).replacingOccurrences(of: ".", with: ",")
    }
}

/// Wasserfall des Audiobands mit Markierungen. Eigene Ansicht: Sie wertet nur aus,
/// wenn ein neues Bild oder neue Markierungen kommen – nicht bei jeder Änderung der
/// Seite (Review 28.10.2026, Y14).
struct FT8WaterfallPane: View {
    let model: FT8Model
    @Binding var showWSPR: Bool

    private var waterfallIsWSPR: Bool {
        switch model.mode {
        case .ft8: false
        case .wspr: true
        case .both: showWSPR
        }
    }

    var body: some View {
        let wspr = waterfallIsWSPR
        let image = wspr ? model.wsprWaterfall : model.ft8Waterfall
        let range = wspr ? model.wsprWaterfallRange : model.ft8WaterfallRange
        let times = wspr ? model.wsprWaterfallTimes : model.ft8WaterfallTimes
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Color.black
                    Text(model.running ? "Wasserfall läuft an …" : "Wasserfall erscheint nach dem Start")
                        .font(.callout).foregroundStyle(.secondary).padding(8)
                }
                Canvas { ctx, size in
                    let span = range.upperBound - range.lowerBound
                    func x(_ f: Double) -> CGFloat { CGFloat((f - range.lowerBound) / span) * size.width }
                    // Frequenzraster
                    let step: Double = wspr ? 100 : 500
                    var f = (range.lowerBound / step).rounded(.up) * step
                    while f <= range.upperBound {
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x(f), y: size.height - 8)); $0.addLine(to: CGPoint(x: x(f), y: size.height)) },
                                   with: .color(.white.opacity(0.7)))
                        ctx.draw(Text("\(Int(f))").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)),
                                 at: CGPoint(x: x(f), y: size.height - 14))
                        f += step
                    }
                    // Markierungen der Dekodierungen (neueste Zeile oben).
                    guard let times, times.upperBound > times.lowerBound else { return }
                    let tspan = times.upperBound - times.lowerBound
                    func y(_ t: Double) -> CGFloat { CGFloat((times.upperBound - t) / tspan) * size.height }
                    for mark in model.marks where (mark.duration > 60) == wspr {
                        let t0 = mark.start.timeIntervalSince1970, t1 = t0 + mark.duration
                        guard t1 > times.lowerBound, t0 < times.upperBound else { continue }
                        let rect = CGRect(x: x(mark.frequency), y: y(min(t1, times.upperBound)),
                                          width: max(2, x(mark.frequency + mark.bandwidth) - x(mark.frequency)),
                                          height: max(4, y(max(t0, times.lowerBound)) - y(min(t1, times.upperBound))))
                        ctx.stroke(Path(rect), with: .color(.green), lineWidth: 1)
                        ctx.draw(Text(mark.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.green),
                                 at: CGPoint(x: rect.minX + 2, y: rect.minY + 7), anchor: .leading)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .background(.black)
        .overlay(alignment: .topTrailing) {
            if model.mode == .both {
                Picker("Wasserfall", selection: $showWSPR) {
                    Text("FT8").tag(false)
                    Text("WSPR").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .padding(6)
            }
        }
    }
}

/// Karte der Locatoren (eigene Ansicht, siehe `FT8WaterfallPane`).
struct FT8MapPane: View {
    let model: FT8Model
    @Binding var selection: FT8Spot.ID?
    let home: CLLocationCoordinate2D?
    let controller: MapController

    private var selectedCall: String? {
        selection.flatMap { id in model.spots.first { $0.id == id }?.call }
    }

    private var features: [MapFeature] {
        let accent = MapColor.accent
        let selectedCall = selectedCall
        var list: [MapFeature] = []
        if let home {
            list.append(.home(home))
            // Unsichtbarer Kreis der typischen Reichweite (FT8 auf 2 m/6 m reicht oft über 1000 km): Ohne Ziele
            // zoomte die Karte sonst bis auf die eigene Straße.
            list.append(.extent("range", center: home, radius: 1_500_000))
        }
        for station in model.stations {
            let coordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
            let selected = station.call == selectedCall
            if let home, selected {
                list.append(.line("path:\(station.call)", [home, coordinate], color: MapColor.selected, width: 2, selected: true))
            }
            let wspr = station.lastMode == .wspr
            let color = selected ? MapColor.selected
                : Date().timeIntervalSince(station.lastHeard) > 900 ? MapColor.stale
                : wspr ? MapColor.purple : accent
            // Antippen wählt den neuesten Spot der Station (Nutzer 31.10.2026: Stationen
            // ließen sich nicht anwählen und waren zu klein).
            list.append(.marker("st:\(station.call)", at: coordinate, symbol: wspr ? .signal : .antenna, color: color,
                                size: 22, label: station.call, selected: selected, select: station.call))
        }
        return list
    }

    var body: some View {
        LeafletMap(features: features, controller: controller,
                   options: MapOptions(fitMaxZoom: 8, center: home.map(MapPoint.init) ?? MapPoint(51, 10), zoom: 4),
                   onSelect: { call in
                       // Spots stehen neueste zuerst.
                       selection = call.flatMap { call in model.spots.first { $0.call == call }?.id }
                   })
            .overlay(alignment: .topLeading) {
                if model.stations.isEmpty {
                    Text(model.running ? "Noch keine Station mit Locator" : "Empfang starten")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !controller.following, !model.stations.isEmpty {
                    Button("Alle Stationen zeigen", systemImage: "scope") { controller.showAll() }
                        .padding(10)
                }
            }
    }
}

/// Liste der Dekodierungen (eigene Ansicht, siehe `FT8WaterfallPane`). Filtern und
/// Sortieren laufen nur, wenn sich Spots, Filter oder Sortierung ändern.
struct FT8SpotTable: View {
    let model: FT8Model
    @Binding var selection: FT8Spot.ID?
    @Binding var order: [ColumnSort<FT8Spot>]
    let onlyCQ: Bool
    let home: CLLocationCoordinate2D?

    private var rows: [FT8Spot] {
        let list = onlyCQ ? model.spots.filter { $0.isCQ || $0.mode == .wspr } : model.spots
        return list.sorted(by: order)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("UTC", sortUsing: ColumnSort("utc") { $0.cycle }) { spot in
                Text(Self.utc.string(from: spot.cycle)).font(.body.monospacedDigit())
            }.width(min: 56, ideal: 62)
            TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.mode.rawValue })) { spot in
                Text(spot.mode.rawValue + (spot.viaOSD ? "*" : "")).foregroundStyle(spot.mode == .wspr ? .purple : .primary)
            }.width(min: 38, ideal: 44)
            TableColumn("SNR", sortUsing: ColumnSort("snr") { $0.snr }) { spot in
                Text(String(format: "%+.0f", spot.snr)).monospacedDigit()
            }.width(min: 34, ideal: 40)
            TableColumn("Δt", sortUsing: ColumnSort("dt") { $0.dt }) { spot in
                Text(String(format: "%+.1f", spot.dt)).monospacedDigit()
            }.width(min: 34, ideal: 40)
            TableColumn("Hz", sortUsing: ColumnSort("hz") { $0.frequency }) { spot in
                Text(String(format: "%.0f", spot.frequency)).monospacedDigit()
            }.width(min: 40, ideal: 48)
            TableColumn("Nachricht", sortUsing: ColumnSort("nachricht", text: { $0.message })) { spot in
                Text(spot.message).font(.body.monospaced())
                    .fontWeight(spot.isCQ ? .semibold : .regular)
                    .foregroundStyle(spot.isCQ ? Color.green : Color.primary)
            }.width(min: 160, ideal: 220)
            TableColumn("Locator", sortUsing: ColumnSort("locator", text: { $0.grid })) { spot in
                Text(spot.grid ?? "–").font(.body.monospaced()).foregroundStyle(spot.gridFromMessage ? .primary : .secondary)
            }.width(min: 50, ideal: 60)
            TableColumn("Entfernung", sortUsing: ColumnSort("entfernung") { distanceKm($0) }) { spot in
                Text(distanceString(spot))
            }.width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: FT8Spot.ID.self) { ids in
            if let spot = model.spots.first(where: { ids.contains($0.id) }) {
                Button("Nachricht kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(spot.message, forType: .string)
                }
                if let call = spot.call, !call.contains(".") {
                    Button("Rufzeichen auf QRZ.com öffnen") {
                        if let url = URL(string: "https://www.qrz.com/db/\(call.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? call)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.spots.isEmpty {
                ContentUnavailableView("Noch keine Dekodierung", systemImage: "waveform.badge.magnifyingglass",
                                       description: Text(model.running
                                                         ? "FT8 wird alle 15 s ausgewertet, WSPR alle 2 min. Kurz nach jedem Zyklus erscheinen hier die Stationen."
                                                         : "Wähl Band und Betriebsart, dann „Start“."))
            }
        }
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func distanceKm(_ spot: FT8Spot) -> Double? {
        guard let home, let grid = spot.grid, let pos = FT8Locator.coordinate(grid) else { return nil }
        return GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: pos.lat, lon2: pos.lon)
    }

    private func distanceString(_ spot: FT8Spot) -> String {
        guard let home, let grid = spot.grid, let pos = FT8Locator.coordinate(grid) else { return "–" }
        let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: pos.lat, lon2: pos.lon)
        let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: pos.lat, lon2: pos.lon)
        return String(format: "%.0f km %@ %.0f°", km, GeoMath.compass(bearing), bearing)
    }
}

extension FT8View {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["zyklus_utc", "art", "band", "snr_db", "dt_s", "frequenz_hz", "drift_hz", "nachricht", "rufzeichen", "locator",
                             "locator_aus_nachricht", "cq", "osd", "leistung_dbm"],
                    rows: model.spots.map { s in
                        [.date(s.cycle), .text(s.mode.rawValue), .text(s.band.rawValue), .number(s.snr, digits: 0), .number(s.dt),
                         .number(s.frequency, digits: 0), .number(s.drift), .text(s.message), .text(s.call), .text(s.grid),
                         .flag(s.gridFromMessage), .flag(s.isCQ), .flag(s.viaOSD), .integer(s.powerDBm)]
                    })
    }
}
