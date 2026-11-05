import CoreLocation
import SwiftUI

struct MeshtasticView: View {
    @StoredColumns("meshtastic.2") private var columns2: TableColumnCustomization<MeshtasticLogLine>
    @StoredColumns("meshtastic.1") private var columns: TableColumnCustomization<MeshtasticNode>
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.meshtastic
    @State private var selectedNode: MeshtasticNode.ID?
    @State private var selectedLine: MeshtasticLogLine.ID?
    @State private var nodeOrder: [ColumnSort<MeshtasticNode>] = []
    @State private var lineOrder: [ColumnSort<MeshtasticLogLine>] = []
    @State private var textOnly = false
    @State private var mapController = MapController()
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0

    private var home: CLLocationCoordinate2D? {
        (homeLat == 0 && homeLon == 0) ? nil : CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "point.3.connected.trianglepath.dotted", text: "Meshtastic-Nachrichten (LoRa-Funknetz) empfängt und entschlüsselt die App selbst. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 290, issue: model.error) {
                VSplitView {
                    HStack(spacing: 0) {
                        nodeTable.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        map.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 220)
                    HStack(spacing: 0) {
                        logTable.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
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
            .onAppear { model.configurationChanged() }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop() }
            }
            .onChange(of: selectedNode) { _, id in center(on: id) }
        }
    }

    // MARK: - Knoten

    private var nodeTable: some View {
        Table(model.nodes.sorted(by: nodeOrder), selection: $selectedNode, sortOrder: $nodeOrder, columnCustomization: $columns) {
            TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.longName ?? $0.shortName })) { node in
                HStack(spacing: 6) {
                    if let short = node.shortName {
                        Text(short).font(.caption.monospaced().weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(node.longName ?? "–").foregroundStyle(node.longName == nil ? .secondary : .primary)
                }
            }.customizationID("name")
            TableColumn("ID", sortUsing: ColumnSort("id") { $0.number }) { Text($0.idString).font(.body.monospaced()) }.width(min: 54, ideal: 90).customizationID("id")
            TableColumn("Position", sortUsing: ColumnSort("position") { $0.positionDate }) { node in
                Text(position(node)).foregroundStyle(.secondary)
            }.customizationID("position")
            TableColumn("SNR", sortUsing: ColumnSort("snr") { $0.snrDB }) { Text(String(format: "%.1f dB", $0.snrDB)).monospacedDigit() }.width(min: 36, ideal: 60).customizationID("snr")
            TableColumn("Sprünge", sortUsing: ColumnSort("hops") { $0.hops }) { Text($0.hops.map(String.init) ?? "–").monospacedDigit() }.width(min: 30, ideal: 50).customizationID("sprunge")
            TableColumn("Rahmen", sortUsing: ColumnSort("pakete") { $0.packets }) { Text("\($0.packets)").monospacedDigit() }.width(min: 30, ideal: 50).customizationID("rahmen")
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { Text($0.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(min: 54, ideal: 90).customizationID("zuletzt")
        }
        .overlay {
            if model.nodes.isEmpty {
                ContentUnavailableView("Keine Knoten", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(model.running
                                                         ? "Noch kein Paket. Knoten melden sich nur alle paar Minuten bis Stunden – hab etwas Geduld."
                                                         : "Mit „Start“ beginnt der Empfang."))
            }
        }
    }

    private func position(_ node: MeshtasticNode) -> String {
        guard let lat = node.latitude, let lon = node.longitude else { return "–" }
        var text = String(format: "%.4f, %.4f", lat, lon)
        if let home {
            let km = GeoMath.distanceKm(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
            let bearing = GeoMath.bearingDegrees(lat1: home.latitude, lon1: home.longitude, lat2: lat, lon2: lon)
            text += String(format: " · %.1f km ", km) + GeoMath.compass(bearing)
        }
        return text
    }

    // MARK: - Karte

    private var positioned: [MeshtasticNode] { model.nodes.filter(\.hasPosition) }

    private func center(on id: MeshtasticNode.ID?) {
        guard let id, let node = model.nodes.first(where: { $0.id == id }),
              let lat = node.latitude, let lon = node.longitude else { return }
        mapController.center(on: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private var mapFeatures: [MapFeature] {
        let accent = MapColor.accent
        var list: [MapFeature] = []
        if let home { list.append(.home(home)) }
        // Funkstrecken zwischen Nachbarn, die beide eine Position haben.
        let located = Dictionary(positioned.map { ($0.number, CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!)) },
                                 uniquingKeysWith: { a, _ in a })
        var linked = Set<String>()
        for node in positioned {
            for neighbor in node.neighbors {
                guard let a = located[node.number], let b = located[neighbor.number] else { continue }
                let key = [node.number, neighbor.number].sorted().map(String.init).joined(separator: "-")
                guard linked.insert(key).inserted else { continue }
                list.append(.line("link:\(key)", [a, b], color: MapColor.stale, width: 1.5))
            }
        }
        for waypoint in model.waypoints {
            guard let lat = waypoint.latitude, let lon = waypoint.longitude else { continue }
            list.append(.marker("wp:\(waypoint.id)", at: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                symbol: .pin, color: MapColor.accent, size: 16, label: waypoint.name))
        }
        for node in positioned {
            let selected = selectedNode == node.id
            let stale = Date().timeIntervalSince(node.lastSeen) > 3600
            list.append(.marker("node:\(node.id)", at: CLLocationCoordinate2D(latitude: node.latitude!, longitude: node.longitude!),
                                symbol: .antenna, color: selected ? MapColor.selected : stale ? MapColor.stale : accent,
                                size: 20, label: node.shortName ?? node.idString, selected: selected, select: String(node.id)))
        }
        return list
    }

    private var map: some View {
        LeafletMap(features: mapFeatures, controller: mapController,
                   options: MapOptions(center: home.map(MapPoint.init) ?? MapPoint(51, 10), zoom: home == nil ? 5 : 9),
                   onSelect: { key in selectedNode = key.flatMap { UInt32($0) } })
            .overlay(alignment: .topLeading) {
                if positioned.isEmpty {
                    Text(model.running ? "Noch keine Position empfangen" : "Mit „Start“ beginnt der Empfang.")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !mapController.following, !positioned.isEmpty {
                    Button("Alle Knoten zeigen", systemImage: "scope") { mapController.showAll() }
                        .buttonStyle(.mapOverlay)
                        .padding(10)
                }
            }
    }

    // MARK: - Pakete

    private var visibleLog: [MeshtasticLogLine] { textOnly ? model.log.filter(\.isText) : model.log }

    private var logTable: some View {
        Table(visibleLog.sorted(by: lineOrder), selection: $selectedLine, sortOrder: $lineOrder, columnCustomization: $columns2) {
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.id }) { Text($0.frame.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(min: 39, ideal: 65).customizationID("zeit")
            TableColumn("Von", sortUsing: ColumnSort("von", text: { $0.packet.map { name(of: $0.header.from) } })) { line in
                Text(line.packet.map { name(of: $0.header.from) } ?? "–")
            }.width(min: 80, ideal: 120).customizationID("von")
            TableColumn("An", sortUsing: ColumnSort("an", text: { $0.packet.map { name(of: $0.header.to) } })) { line in
                Text(line.packet.map { name(of: $0.header.to) } ?? "–").foregroundStyle(.secondary)
            }.width(min: 50, ideal: 80).customizationID("an")
            TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.kind })) { line in
                Text(line.kind).foregroundStyle(line.packet?.data == nil ? .secondary : .primary)
            }.width(min: 70, ideal: 100).customizationID("art")
            TableColumn("Inhalt") { line in
                Text(line.summary)
                    .foregroundStyle(line.isText ? .primary : .secondary)
                    .fontWeight(line.isText ? .medium : .regular)
                    .opacity(line.duplicate ? 0.5 : 1)
                    .lineLimit(2)
            }.customizationID("inhalt")
            TableColumn("SNR", sortUsing: ColumnSort("snr") { $0.frame.snrDB }) { Text(String(format: "%.1f", $0.frame.snrDB)).monospacedDigit() }.width(min: 28, ideal: 45).customizationID("snr")
        }
        .overlay {
            if visibleLog.isEmpty {
                ContentUnavailableView(textOnly ? "Keine Textnachrichten" : "Keine Pakete", systemImage: "list.bullet.rectangle",
                                       description: Text("Hier erscheint jedes LoRa-Paket mit gültiger Prüfsumme. Weitergeleitete Wiederholungen sind blass."))
            }
        }
    }

    private func name(of number: UInt32) -> String {
        if number == MeshtasticHeader.broadcast { return String(localized: "alle") }
        if let node = model.nodes.first(where: { $0.number == number }) {
            return node.shortName ?? node.longName ?? node.idString
        }
        return Meshtastic.nodeName(number)
    }

    // MARK: - Einzelheiten

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let line = visibleLog.first(where: { $0.id == selectedLine }) {
                    lineDetail(line)
                } else if let node = model.nodes.first(where: { $0.id == selectedNode }) {
                    nodeDetail(node)
                } else {
                    Text("Knoten oder Paket wählen, um die Einzelheiten zu sehen.").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nodeDetail(_ node: MeshtasticNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(node.displayName).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Knoten-ID", node.idString)
                if let short = node.shortName { row("Kurzname", short) }
                if let hardware = node.hardware { row("Gerät", hardware) }
                if let role = node.role { row("Rolle", role) }
                if node.hasPosition { row("Position", position(node)) }
                if let alt = node.altitude { row("Höhe", "\(alt) m") }
                if let date = node.positionDate { row("Position von", date.formatted(date: .omitted, time: .standard)) }
                row("SNR", String(format: "%.1f dB", node.snrDB))
                row("Pegel", String(format: "%.1f dBFS", node.levelDB))
                row("Rahmen", "\(node.packets)")
                if !node.neighbors.isEmpty {
                    row("Nachbarn", node.neighbors.map { n in
                        let name = model.nodes.first { $0.number == n.number }?.displayName ?? Meshtastic.nodeName(n.number)
                        return name + (n.snr.map { String(format: " (%.1f dB)", $0) } ?? "")
                    }.joined(separator: ", "))
                }
                if let route = node.lastRoute { row("Route", route) }
                row("Zuerst gesehen", node.firstSeen.formatted(date: .omitted, time: .standard))
            }
            .font(.callout)
            if !node.telemetry.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(node.telemetry, id: \.self) { Text($0).font(.callout) }
                }
                .padding(8)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func lineDetail(_ line: MeshtasticLogLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line.duplicate ? String(localized: "\(line.kind) (Wiederholung)") : line.kind).font(.headline)
            if line.isText {
                Text(line.summary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let packet = line.packet {
                    let h = packet.header
                    row("Von", Meshtastic.nodeName(h.from))
                    row("An", Meshtastic.nodeName(h.to))
                    row("Paket-ID", String(format: "0x%08X", h.id))
                    row("Sprünge", String(localized: "noch \(h.hopLimit) von \(h.hopStart)"))
                    row("Kanal-Hash", String(format: "0x%02X", h.channelHash) + (packet.channel.map { " (\($0))" } ?? ""))
                    if h.wantAck { row("Bestätigung", String(localized: "erbeten")) }
                    if h.viaMQTT { row("Herkunft", String(localized: "über MQTT")) }
                    if h.relayNode != 0 { row("Weitergeleitet", String(format: String(localized: "von …%02x"), h.relayNode)) }
                    if h.nextHop != 0 { row("Nächster Sprung", String(format: "…%02x", h.nextHop)) }
                    if let data = packet.data {
                        row("Port", "\(Meshtastic.portName(data.portnum)) (\(data.portnum))")
                        if data.wantResponse { row("Antwort", String(localized: "erbeten")) }
                        if let reply = data.replyID { row("Antwort auf", String(format: "0x%08X", reply)) }
                        if let request = data.requestID { row("Anfrage", String(format: "0x%08X", request)) }
                    } else {
                        row("Inhalt", packet.header.channelHash == 0 && packet.header.to != MeshtasticHeader.broadcast
                            ? String(localized: "Direktnachricht (verschlüsselt)") : String(localized: "fremder Kanal oder Schlüssel"))
                    }
                }
                row("Länge", String(localized: "\(line.frame.payload.count) Byte, Coderate 4/\(line.frame.codingRate + 4)"))
                row("SNR", String(format: "%.1f dB", line.frame.snrDB))
                row("Pegel", String(format: "%.1f dBFS", line.frame.levelDB))
                row("Frequenzablage", String(format: "%+.1f kHz", line.frame.frequencyOffsetHz / 1000))
                if line.frame.correctedCodewords > 0 { row("Korrigiert", String(localized: "\(line.frame.correctedCodewords) Codewörter")) }
            }
            .font(.callout)
            if let data = line.packet?.data, !data.payload.isEmpty, !line.isText {
                Text(line.summary).font(.callout).textSelection(.enabled)
            }
            Text("Rohdaten").font(.subheadline.weight(.semibold))
            Text(line.hex).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
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
            Section("Kanal") {
                Picker("Region", selection: $model.region) {
                    ForEach(MeshtasticRegion.all) { Text($0.title).tag($0) }
                }
                .onChange(of: model.region) { _, _ in model.configurationChanged() }
                Picker("Voreinstellung", selection: $model.preset) {
                    ForEach(model.region.presets) { Text($0.displayName).tag($0) }
                }
                .onChange(of: model.preset) { _, _ in model.configurationChanged() }
                Text(model.preset.summary).font(.caption).foregroundStyle(.secondary)
                TextField("Kanalname", text: $model.channelName, prompt: Text(model.preset.displayName))
                    .onSubmit { model.configurationChanged() }
                TextField("Schlüssel (Base64)", text: $model.pskBase64, prompt: Text("AQ=="))
                    .font(.body.monospaced())
                    .onSubmit { model.keysChanged() }
                if !model.pskValid {
                    Text("Kein gültiges Base64.").font(.caption).foregroundStyle(.red)
                } else if let hash = model.channelHash {
                    Text(String(format: String(localized: "Kanal-Hash 0x%02X"), hash)).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Frequenz von Hand", isOn: $model.manualFrequency)
                    .onChange(of: model.manualFrequency) { _, _ in model.configurationChanged() }
                if model.manualFrequency {
                    LabeledContent("Frequenz (MHz)") {
                        FrequencyField(mhz: model.frequencyMHz, decimals: 4) {
                            model.frequencyMHz = $0
                            model.configurationChanged()
                        }
                    }
                } else {
                    LabeledContent("Frequenz", value: String(format: "%.4f MHz", model.automaticFrequencyMHz))
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                MeshtasticStatusRows(model: model)
            }
            FrequencyMemorySection(page: .meshtastic, currentMHz: model.manualFrequency ? model.frequencyMHz : model.automaticFrequencyMHz) { entry in
                model.manualFrequency = true
                model.frequencyMHz = entry.mhz
                model.configurationChanged()
            }
            Section(PanelSection.anzeige) {
                Toggle("Nur Textnachrichten", isOn: $textOnly)
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "meshtastic-knoten", isEmpty: model.nodes.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                LegalNotice()
                Text("Die App liest den öffentlichen Standardkanal und den oben eingetragenen Kanal mit. Gesendet wird nichts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Standardschlüssel „AQ==“. Direktnachrichten und fremde Kanäle erscheinen nur mit ihrem Kopf (Absender, Ziel).")
            }
        }
        .formStyle(.grouped)
    }
}

extension MeshtasticView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["id", "nummer", "kurzname", "name", "hardware", "rolle", "breite", "laenge", "hoehe_m", "position_zeit",
                             "snr_db", "pegel_db", "spruenge", "rahmen", "erste", "letzte", "telemetrie"],
                    rows: model.nodes.map { n in
                        [.text(n.idString), .integer(Int(n.number)), .text(n.shortName), .text(n.longName), .text(n.hardware), .text(n.role),
                         .number(n.latitude, digits: 5), .number(n.longitude, digits: 5), .integer(n.altitude), .date(n.positionDate),
                         .number(n.snrDB), .number(n.levelDB), .integer(n.hops), .integer(n.packets), .date(n.firstSeen), .date(n.lastSeen),
                         .text(n.telemetry.joined(separator: " · "))]
                    })
    }
}

/// Zähler und Pegel als eigene Ansicht: sie ändern sich mehrmals je Sekunde,
/// und im Bedienfeld selbst gelesen zeichneten sie das ganze Formular neu –
/// das Scrollen ruckelte (Review 05.11.2026).
private struct MeshtasticStatusRows: View {
    let model: MeshtasticModel

    var body: some View {
        LabeledContent("Knoten", value: "\(model.nodes.count)")
        LabeledContent("Rahmen", value: "\(model.frameCount)")
        LabeledContent("Nicht entschlüsselt", value: "\(model.undecrypted)")
        LabeledContent("Prüfsummen-/Kopffehler", value: "\(model.crcErrors) / \(model.headerErrors)")
        if model.running {
            LabeledContent("Rauschen", value: String(format: "%.1f dBFS", model.noiseDB))
        }
    }
}
