import Charts
import SwiftUI
import simd
import os

struct ZigbeeView: View {
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Zigbee")
    /// Rohwerte sind in `zigbeeLeftTab` gespeichert – nicht ändern; angezeigt wird `title`.
    enum LeftTab: String, CaseIterable, Identifiable {
        case devices = "Geräte", map = "Karte", history = "Verlauf"
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .devices: "Geräte"
            case .map: "Karte"
            case .history: "Verlauf"
            }
        }
    }
    @Environment(DeviceSession.self) private var session
    /// Dieselbe Instanz wie der Fernzugriff (`RemoteHub.Mode.zigbee`).
    @Bindable private var model = RemoteHub.shared.zigbee
    @State private var nodeSelection: ZigbeeNode.ID?
    @State private var packetSelection: ZigbeePacket.ID?
    @State private var nodeOrder: [ColumnSort<ZigbeeNode>] = []
    @State private var keyText = ""
    @State private var pendingDelete: DeleteConfirmation?
    @State private var keyMessage: String?
    @State private var importMessage: String?
    @State private var search = ""
    @State private var onlyOwnNetwork = false
    @State private var onlySelectedNode = false
    @State private var renaming: ZigbeeNode?
    @State private var renameText = ""
    @State private var threadKeyText = ""
    @State private var threadKeyMessage: String?
    @State private var linkKeyText = ""
    @State private var linkKeyMessage: String?
    @AppStorage("zigbeeLeftTab") private var leftTab: LeftTab = .devices

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "point.3.filled.connected.trianglepath.dotted", text: "Zigbee (IEEE 802.15.4, 2,4 GHz) empfängt die App selbst. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 300, issue: model.error) {
                VSplitView {
                    VStack(spacing: 0) {
                        if !model.channelActivity.isEmpty { activity.padding(10) ; Divider() }
                        Picker("Ansicht", selection: $leftTab) {
                            ForEach(LeftTab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().padding(8)
                        Divider()
                        switch leftTab {
                        case .devices: nodeTable
                        case .map: ZigbeeMapView(nodes: model.nodes, channel: model.channel, name: { model.name(of: $0) })
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Netzkarte: \(model.nodes.count) Zigbee-Geräte")
                        case .history: historyPane
                        }
                    }
                    .frame(minHeight: 200, idealHeight: 380)
                    VStack(spacing: 0) {
                        filterBar
                        Divider()
                        packetTable
                    }
                    .frame(minHeight: 140)
                }
                .frame(minWidth: 560)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.zigbee), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.zigbee); model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop(on: nil) } }
        }
    }

    // MARK: Kanalsuche

    private var activity: some View {
        let peak = max(1, model.channelActivity.values.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Rahmen je Kanal").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(IEEE802154.channels, id: \.self) { channel in
                    let count = model.channelActivity[channel] ?? 0
                    VStack(spacing: 2) {
                        Text(count > 0 ? "\(count)" : "").font(.system(size: 9)).monospacedDigit()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(channel == model.channel ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(height: max(2, 40 * CGFloat(count) / CGFloat(peak)))
                        Text("\(channel)").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 64)
        }
    }

    // MARK: Tabellen

    // Vergleicher außerhalb des Tabellenausdrucks – zehn generische
    // Initialisierer in einem Ausdruck sprengen die Typprüfung.
    private static let byAddress = ColumnSort<ZigbeeNode>("adresse") { (n: ZigbeeNode) -> Int? in Int(n.key.address) }
    private static let byPAN = ColumnSort<ZigbeeNode>("pan") { (n: ZigbeeNode) -> Int? in Int(n.key.pan) }
    private static let byRole = ColumnSort<ZigbeeNode>("rolle", text: { (n: ZigbeeNode) -> String? in n.role })
    private static let byPower = ColumnSort<ZigbeeNode>("versorgung", text: { (n: ZigbeeNode) -> String? in n.power })
    private static let byLevel = ColumnSort<ZigbeeNode>("pegel") { (n: ZigbeeNode) -> Double? in n.rssiDB }
    private static let bySent = ColumnSort<ZigbeeNode>("gesendet") { (n: ZigbeeNode) -> Int? in n.heard + n.originated }
    private static let byLastSeen = ColumnSort<ZigbeeNode>("zuletzt") { (n: ZigbeeNode) -> Date? in n.lastSeen }

    private var nodeTable: some View {
        Table(model.nodes.sorted(by: nodeOrder), selection: $nodeSelection, sortOrder: $nodeOrder) {
            Group {
            TableColumn("Adresse", sortUsing: Self.byAddress) { node in
                Text(String(format: "0x%04X", node.key.address)).font(.body.monospaced())
            }.width(70)
            TableColumn("PAN", sortUsing: Self.byPAN) {
                Text(String(format: "0x%04X", $0.key.pan)).font(.caption.monospaced())
            }.width(60)
            TableColumn("Name") { (node: ZigbeeNode) in
                nameCell(node)
            }.width(min: 90, ideal: 140)
            TableColumn("Typ", sortUsing: Self.byRole) { node in
                typeCell(node)
            }.width(min: 90, ideal: 130)
            TableColumn("Versorgung", sortUsing: Self.byPower) { node in
                powerCell(node)
            }.width(70)
            TableColumn("IEEE") { (node: ZigbeeNode) in
                Text(node.ieee.map(ZigbeeFormat.ieee) ?? "–").font(.caption.monospaced()).foregroundStyle(.secondary)
            }.width(min: 120, ideal: 150)
            }
            Group {
            TableColumn("Pegel", sortUsing: Self.byLevel) { node in
                levelCell(node)
            }.width(70)
            TableColumn("Gesendet", sortUsing: Self.bySent) { node in
                Text("\(node.heard) / \(node.originated)").monospacedDigit()
                    .help("Selbst gefunkt / ausgelöst (auch über Router weitergeleitet)")
            }.width(70)
            TableColumn("Zustand") { (node: ZigbeeNode) in stateCell(node) }
            TableColumn("Gehört", sortUsing: Self.byLastSeen) {
                Text($0.lastSeen, style: .relative).foregroundStyle(.secondary)
            }.width(80)
            }
        }
        .overlay {
            if model.nodes.isEmpty {
                ContentUnavailableView("Keine Geräte", systemImage: "point.3.filled.connected.trianglepath.dotted",
                                       description: Text(model.running
                                                         ? "Auf Kanal \(model.channel) noch nichts gehört. „Kanalsuche“ findet den Kanal deines Netzes (in Zigbee2MQTT unter „Einstellungen ▸ Erweitert“)."
                                                         : "Mit „Start“ beginnt der Empfang auf Kanal \(model.channel)."))
            }
        }
        .contextMenu(forSelectionType: ZigbeeNode.ID.self) { ids in
            if let node = model.nodes.first(where: { ids.contains($0.id) }) {
                Button("Name vergeben …") {
                    renameText = model.name(of: node) ?? ""
                    renaming = node
                }
                .disabled(node.ieee == nil)
                Button("Nur dieses Gerät im Protokoll") {
                    nodeSelection = node.id
                    onlySelectedNode = true
                }
                if !node.endpoints.isEmpty {
                    Text("Endpunkte: \(node.endpoints.sorted().map(String.init).joined(separator: ", "))")
                }
                if !node.neighbors.isEmpty {
                    Section("Nachbarn (Kosten ein/aus, 1 = beste)") {
                        ForEach(node.neighbors.keys.sorted(), id: \.self) { neighbor in
                            let cost = node.neighbors[neighbor]!
                            Text(String(format: "%@: %d / %d", label(neighbor, pan: node.key.pan), cost.incoming, cost.outgoing))
                        }
                    }
                }
                if !node.lqiNeighbors.isEmpty {
                    Section("Nachbartabelle (LQI, 255 = beste)") {
                        ForEach(node.lqiNeighbors.keys.sorted(), id: \.self) { neighbor in
                            Text(String(format: "%@: %d", label(neighbor, pan: node.key.pan), node.lqiNeighbors[neighbor]!))
                        }
                    }
                }
            }
        }
    }

    private func nameCell(_ node: ZigbeeNode) -> some View {
        let name: String = model.name(of: node) ?? "–"
        return Text(name).lineLimit(1)
    }

    private func powerCell(_ node: ZigbeeNode) -> some View {
        let power: String = node.power ?? "–"
        return Text(power).foregroundStyle(Color.secondary)
    }

    private func levelCell(_ node: ZigbeeNode) -> some View {
        let level: String = node.rssiDB.map { String(format: "%.0f dBFS", $0) } ?? String(localized: "über Router")
        return Text(level).monospacedDigit()
    }

    private func stateCell(_ node: ZigbeeNode) -> some View {
        let hasState = !node.state.isEmpty
        let text: String = hasState ? node.stateLine : node.lastSummary
        return Text(text)
            .lineLimit(1)
            .foregroundStyle(hasState ? Color.primary : Color.secondary)
            .help(hasState ? text : "")
    }

    /// Rolle bzw. Gerätetyp, darunter Hersteller und Modell.
    /// Schlüsselfeld: Beschriftung in normaler Schrift darüber, Eingabe in Festbreite.
    private func keyField<Field: View>(_ title: LocalizedStringKey, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            field()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
    }

    private func typeCell(_ node: ZigbeeNode) -> some View {
        let info = model.info(of: node)
        let manufacturer: String? = info?.manufacturer ?? node.manufacturer
        let modelName: String? = info?.model ?? node.model
        let detail = [manufacturer, modelName].compactMap { $0 }.joined(separator: " ")
        // Eine Zeile: Tabellenzeilen sind einzeilig hoch, eine zweite Zeile mit
        // Hersteller/Modell wurde gequetscht und überlappte die nächste (27.10.2026).
        return (Text(node.role) + Text(detail.isEmpty ? "" : " · \(detail)").foregroundStyle(.secondary))
            .lineLimit(1)
            .help(detail.isEmpty ? node.role : "\(node.role) · \(detail)")
    }

    /// Kurzadresse mit Namen, falls bekannt.
    private func label(_ address: UInt16, pan: UInt16) -> String {
        let hex = String(format: "0x%04X", address)
        guard let node = model.nodes.first(where: { $0.key.pan == pan && $0.key.address == address }),
              let name = model.name(of: node) else { return hex }
        return "\(name) (\(hex))"
    }

    /// Protokoll nach Suchtext, eigenem Netz und ausgewähltem Gerät.
    private var filteredLog: [ZigbeePacket] {
        let own = model.ownPANs
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let selected = onlySelectedNode ? nodeSelection : nil
        return model.log.filter { packet in
            if onlyOwnNetwork, !own.isEmpty, let pan = packet.mac?.pan, !own.contains(pan) { return false }
            if let selected {
                let addresses: [UInt16?] = [packet.nwk?.source, packet.nwk?.destination,
                                            macShort(packet.mac?.source), macShort(packet.mac?.destination)]
                guard packet.mac?.pan == selected.pan, addresses.contains(selected.address) else { return false }
            }
            guard !needle.isEmpty else { return true }
            let haystack = [packet.summary, address(packet.nwk?.source, mac: packet.mac?.source),
                            address(packet.nwk?.destination, mac: packet.mac?.destination),
                            packet.nwk.flatMap { nwk in model.nodes.first { $0.key.address == nwk.source }.flatMap(model.name) } ?? ""]
                .joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    private func macShort(_ address: MACAddress?) -> UInt16? {
        if case let .short(a)? = address { return a }
        return nil
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("Suchen (Adresse, Name, Inhalt)", text: $search)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Toggle("Nur eigenes Netz", isOn: $onlyOwnNetwork).toggleStyle(.checkbox)
                .disabled(model.ownPANs.isEmpty)
                .help("PAN aus der Zigbee2MQTT-Konfiguration oder alle Netze, die ein Schlüssel entschlüsselt hat.")
            // Nicht abschalten, solange nichts gewählt ist – das Kästchen wirkte
            // „immer inaktiv“, wenn die Auswahl in der Tabelle verloren ging (27.10.2026).
            Toggle("Nur ausgewähltes Gerät", isOn: $onlySelectedNode).toggleStyle(.checkbox)
                .help("Zeigt nur Rahmen von und an das in der Gerätetabelle gewählte Gerät.")
            if onlySelectedNode, nodeSelection == nil {
                Text("Oben ein Gerät anklicken.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(filteredLog.count) von \(model.log.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var packetTable: some View {
        Table(filteredLog, selection: $packetSelection) {
            TableColumn("Zeit") { Text($0.radio.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(64)
            TableColumn("Kanal") { Text("\($0.radio.channel)").monospacedDigit() }.width(40)
            TableColumn("Pegel") { Text(String(format: "%.0f", $0.radio.rssiDB)).monospacedDigit() }.width(40)
            TableColumn("Von") { packet in
                addressCell(packet.nwk?.source, mac: packet.mac?.source)
            }.width(min: 60, ideal: 130)
            TableColumn("An") { packet in
                addressCell(packet.nwk?.destination, mac: packet.mac?.destination)
            }.width(min: 60, ideal: 130)
            TableColumn("Inhalt") { packet in
                HStack(spacing: 4) {
                    if packet.encrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    Text(packet.summary).lineLimit(1)
                }
            }
        }
        .contextMenu(forSelectionType: ZigbeePacket.ID.self) { ids in
            if let packet = model.log.first(where: { ids.contains($0.id) }) {
                Button("Rahmen als Hex kopieren") { copy(hex(packet.radio.mpdu)) }
            }
        }
    }

    /// Name des Geräts, falls bekannt (Zigbee2MQTT-Import), sonst die Adresse;
    /// die Adresse steht dann im Hilfetext.
    @ViewBuilder
    private func addressCell(_ nwk: UInt16?, mac: MACAddress?) -> some View {
        let raw = address(nwk, mac: mac)
        let short: UInt16? = nwk ?? { if case let .short(a) = mac { return a } else { return nil } }()
        let ieee: UInt64? = { if case let .extended(a) = mac { return a } else { return nil } }()
        if let name = short.flatMap({ model.shortNames[$0] }) ?? ieee.flatMap({ model.directory[$0]?.name }) {
            Text(name).lineLimit(1).help(raw)
        } else {
            Text(raw).font(.caption.monospaced())
        }
    }

    private func address(_ nwk: UInt16?, mac: MACAddress?) -> String {
        if let nwk { return nwk == 0xFFFC || nwk == 0xFFFD || nwk == 0xFFFF ? String(localized: "alle") : String(format: "0x%04X", nwk) }
        return mac.map { $0 == .short(0xFFFF) ? String(localized: "alle") : $0.description } ?? "–"
    }

    // MARK: Bedienung

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop(on: session.hackRF) }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.zigbee); model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Leeren") { model.clear() }
                }
                Picker("Kanal", selection: Binding(get: { model.channel }, set: { model.setChannel($0) })) {
                    ForEach(IEEE802154.channels, id: \.self) { channel in
                        Text(String(format: "%d (%.0f MHz)", channel, IEEE802154.frequencyMHz(channel: channel))).tag(channel)
                    }
                }
                .disabled(model.scanning)
                if model.scanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Suche … Kanal \(model.channel)").font(.caption)
                        Spacer()
                        Button("Abbrechen") { model.cancelScan() }
                    }
                } else {
                    Button("Kanalsuche") {
                        // Startet den Empfang selbst – vorher war der Knopf ohne Erklärung grau.
                        if model.running { model.scanChannels() } else {
                            ReceiverStore.shared.requestStart(model, session: session) { device in
                                RemoteHub.shared.prepareLocalStart(.zigbee); model.start(on: device); model.scanChannels()
                            }
                        }
                    }
                    .disabled(session.hackRF == nil)
                    .help("Hört jeden Kanal von 11 bis 26 drei Sekunden lang ab und bleibt dann auf dem aktivsten.")
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Rahmen", value: model.frameRate > 0 ? String(format: "%d · %.1f/s", model.frameCount, model.frameRate) : "\(model.frameCount)")
                LabeledContent("Prüfsummenfehler (FCS)", value: "\(model.crcErrors)")
                // Leistung der auf ±128 normierten Abtastwerte im Kanal – also dBFS.
                LabeledContent("Rauschen", value: String(format: "%.0f dBFS", model.noiseDB))
            }
            Section("Netzwerkschlüssel") {
                ForEach(model.keys) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.short).font(.body.monospaced())
                            Text(keyStatus(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { copy(entry.hex) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Schlüssel als Hex kopieren")
                            .accessibilityLabel("Schlüssel als Hex kopieren")
                        Button(role: .destructive) {
                            pendingDelete = DeleteConfirmation(
                                title: String(localized: "Netzwerkschlüssel „\(entry.short)“ entfernen?"),
                                message: String(localized: "Er wird aus dem Schlüsselbund dieses Mac gelöscht. Hast du ihn nirgends sonst, lässt er sich nicht wiederherstellen."),
                                confirmLabel: String(localized: "Entfernen")) { model.removeKey(entry) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Schlüssel entfernen")
                            .accessibilityLabel("Schlüssel entfernen")
                    }
                }
                // Beschriftung getrennt: `.font(.monospaced)` am Feld galt auch für
                // die Beschriftung, die im schmalen Bedienfeld umbrach.
                keyField("Schlüssel hinzufügen") {
                    TextField("Schlüssel", text: $keyText, prompt: Text("[1, 3, 5, …] oder 32 Hex-Zeichen"), axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(addKey)
                }
                HStack {
                    Button("Hinzufügen", action: addKey)
                        .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.hasKey { LabeledContent("Entschlüsselt", value: "\(model.decryptedCount)") }
                ForEach(model.recoveredKeys, id: \.self) { key in
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Beim Anlernen mitgelesen – unbestätigt").font(.caption)
                                .help("Mit dem öffentlichen Standard-Link-Key kann jeder so einen Schlüssel fälschen. Übernimm ihn nur, wenn du gerade ein eigenes Gerät angelernt hast.")
                            Text(key.map { String(format: "%02X", $0) }.joined()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Übernehmen") { model.adoptRecoveredKey(key) }.controlSize(.small)
                    }
                }
                if let keyMessage {
                    Text(keyMessage).font(.caption).foregroundStyle(.red)
                } else if !model.hasKey {
                    Text("Ohne Schlüssel bleiben die Inhalte verschlüsselt.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Den Schlüssel findest du in Zigbee2MQTT in `configuration.yaml` unter `advanced:` → `network_key`. Je Netz ein Schlüssel; er liegt im Schlüsselbund dieses Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Kein Schlüssel zur Hand? Lerne ein Gerät neu an – die App liest den Schlüssel dabei mit und zeigt ihn oben zum Übernehmen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Das Trust Center überträgt den Netzwerkschlüssel beim Anlernen, verschlüsselt mit dem Standard-Link-Key. Geräte mit eigenem Install-Code brauchen diesen als Link-Key.")
                keyField("Install-Code-Link-Key (optional)") {
                    TextField("Install-Code-Link-Key", text: $linkKeyText, prompt: Text("32 Hex-Zeichen"))
                        .onSubmit(addLinkKey)
                }
                if !linkKeyText.isEmpty { Button("Link-Key hinzufügen", action: addLinkKey).controlSize(.small) }
                if let linkKeyMessage { Text(linkKeyMessage).font(.caption).foregroundStyle(.red) }
            }
            Section("Thread / Matter") {
                ForEach(model.threadKeys) { entry in
                    HStack {
                        Text(entry.short).font(.body.monospaced())
                        Spacer()
                        Button { copy(entry.hex) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Schlüssel als Hex kopieren")
                            .accessibilityLabel("Schlüssel als Hex kopieren")
                        Button(role: .destructive) {
                            pendingDelete = DeleteConfirmation(
                                title: String(localized: "Thread-Schlüssel „\(entry.short)“ entfernen?"),
                                message: String(localized: "Er wird aus dem Schlüsselbund dieses Mac gelöscht. Hast du ihn nirgends sonst, lässt er sich nicht wiederherstellen."),
                                confirmLabel: String(localized: "Entfernen")) { model.removeThreadKey(entry) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Schlüssel entfernen")
                            .accessibilityLabel("Schlüssel entfernen")
                    }
                }
                keyField("Netzwerkschlüssel") {
                    TextField("Netzwerkschlüssel", text: $threadKeyText, prompt: Text("32 Hex-Zeichen (OpenThread „networkkey“)"))
                        .onSubmit(addThreadKey)
                }
                HStack {
                    Button("Hinzufügen", action: addThreadKey)
                        .disabled(threadKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                LabeledContent("Thread-Rahmen", value: String(localized: "\(model.threadFrames) · \(model.threadDecrypted) lesbar"))
                if let threadKeyMessage {
                    Text(threadKeyMessage).font(.caption).foregroundStyle(.red)
                }
                Text("Thread-Netze (auch Matter) erscheinen im Protokoll als „Thread“. Den Schlüssel liefert dein Border-Router (OpenThread: `ot-ctl networkkey`).")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Bei Apple und Google steht er im Thread-Dataset, Feld 0005. Aus ihm leitet die App die MAC- und MLE-Schlüssel ab.")
            }
            Section("Zigbee2MQTT") {
                Button("Konfiguration importieren …", action: importConfiguration)
                    .help("configuration.yaml (Namen, PAN, Kanal, Schlüssel), devices.yaml oder database.db (Modelle).")
                if let ownPAN = model.ownPAN {
                    LabeledContent("Eigenes Netz", value: String(format: "PAN 0x%04X", ownPAN))
                }
                LabeledContent("Bekannte Geräte", value: "\(model.directory.count)")
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(PanelSection.daten) {
                CSVExportButton(title: "Geräteliste als CSV sichern …", fileName: "zigbee-geraete", isEmpty: model.nodes.isEmpty) { csvDocument() }
                Button("PCAP sichern …", action: exportPCAP)
                    .disabled(model.frameCount == 0)
                    .help("Das Protokoll als 802.15.4 mit FCS – in Wireshark mit hinterlegtem Netzwerkschlüssel entschlüsselt lesbar.")
            }
            Section(PanelSection.hinweis) {
                LegalNotice()
                Text("Du siehst alle Zigbee-Netze in Reichweite, aber nur Adressen und Pegel. Inhalte deines Netzes erscheinen erst mit dem Netzwerkschlüssel. Ein Rechtsklick auf ein Gerät zeigt seine Nachbarn und schwache Funkstrecken.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .deleteConfirmation($pendingDelete)
        .formStyle(.grouped)
        .alert(renameTitle, isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Sichern") {
                if let node = renaming { model.setName(renameText, for: node) }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        } message: {
            Text("Der Name wird der IEEE-Adresse zugeordnet und bleibt über Neustarts erhalten.")
        }
    }

    private var renameTitle: String {
        guard let renaming else { return String(localized: "Name für Gerät") }
        return String(localized: "Name für \(String(format: "0x%04X", renaming.key.address))")
    }

    private func importConfiguration() {
        Task {
            guard let url = await SaveSheet.open(message: String(localized: "Wähle configuration.yaml, devices.yaml oder database.db aus Zigbee2MQTT.")).first
            else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                importMessage = model.importZigbee2MQTT(text)
            } catch {
                importMessage = String(localized: "Datei nicht lesbar: \(error.localizedDescription)")
            }
        }
    }

    private func exportPCAP() {
        Task {
            guard let url = await SaveSheet.url(name: "zigbee-kanal\(model.channel).pcap",
                                                message: String(localized: "Alle gepufferten Rahmen (bis 2000) als PCAP")) else { return }
            do { try model.pcap().write(to: url) } catch { importMessage = String(localized: "PCAP nicht gesichert: \(error.localizedDescription)") }
        }
    }

    private func addKey() {
        keyMessage = model.addKey(keyText)
        if keyMessage == nil { keyText = "" }
    }

    private func addThreadKey() {
        threadKeyMessage = model.addThreadKey(threadKeyText)
        if threadKeyMessage == nil { threadKeyText = "" }
    }

    private func addLinkKey() {
        linkKeyMessage = model.addLinkKey(linkKeyText)
        if linkKeyMessage == nil { linkKeyText = "" }
    }

    private func keyStatus(_ entry: ZigbeeKeyEntry) -> String {
        guard entry.decrypted > 0 else { return String(localized: "noch nichts entschlüsselt") }
        let pans = entry.pans.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", ")
        return String(localized: "\(entry.decrypted) Rahmen · PAN \(pans)")
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ZigbeeView {
    /// Messwert- und Pegelverlauf des ausgewählten Geräts.
    @ViewBuilder var historyPane: some View {
        if let id = nodeSelection, let node = model.nodes.first(where: { $0.id == id }) {
            let samples = model.history(for: id)
            let metricKeys = Set(samples.flatMap { $0.metrics.keys }).sorted()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.name(of: node) ?? String(format: "0x%04X", node.key.address)).font(.headline)
                    if samples.count < 2 {
                        Text("Noch zu wenig Daten. Der Verlauf wächst, während das Gerät sendet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if samples.contains(where: { $0.rssiDB != nil }) {
                        historyChart(String(localized: "Pegel (dBFS)"), samples: samples) { $0.rssiDB }
                    }
                    ForEach(metricKeys, id: \.self) { keyName in
                        historyChart(keyName, samples: samples) { $0.metrics[keyName] }
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView("Kein Gerät gewählt", systemImage: "chart.xyaxis.line",
                                   description: Text("Wähle ein Gerät in der Geräteliste – hier erscheinen Pegel und Messwerte über die Zeit."))
        }
    }

    private func historyChart(_ title: String, samples: [ZigbeeHistorySample], value: @escaping (ZigbeeHistorySample) -> Double?) -> some View {
        let points = samples.compactMap { sample in value(sample).map { (sample.date, $0) } }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Zeit", point.0), y: .value(title, point.1))
                    .interpolationMethod(.monotone)
            }
            .frame(height: 90)
        }
    }
}

/// Netzkarte: Kräftemodell (`ZigbeeMapLayout`) mit dem Koordinator in der
/// Mitte, wahlweise flach (Canvas) oder im Raum (`ZigbeeMap3DView`). Kanten
/// nach Verbindungsgüte gefärbt, standardmäßig nur die besten je Gerät. Das
/// Netz folgt dem Kanal (zuletzt gehörtes PAN auf dem aktuellen Kanal) und
/// lässt sich oben umschalten. 2D: Mausrad/Pinch zoomt, Ziehen verschiebt,
/// Doppelklick setzt zurück; unter der Maus wird ein Gerät hervorgehoben.
struct ZigbeeMapView: View {
    let nodes: [ZigbeeNode]
    let channel: Int
    let name: (ZigbeeNode) -> String?

    @AppStorage("zigbeeMapAllLinks") private var allLinks = false
    @AppStorage("zigbeeMap3D") private var threeD = true
    @State private var cache = LayoutCache()
    @State private var hovered: UInt16?
    @State private var selected: UInt16?
    @State private var chosenPAN: UInt16?
    /// Kanten, nach denen die Anordnung gerechnet wird: rein kommt, was einmal
    /// zu den drei besten eines Geräts gehörte, raus nur, was ganz verschwindet.
    /// Eine Hysterese (rein ab Rang 3, raus ab Rang 5) reichte nicht – LQI-Ränge
    /// schwanken dauernd, die Karte wurde jede Sekunde neu gerechnet und kroch
    /// (28.10.2026). So steht sie still, sobald das Netz bekannt ist.
    @State private var layoutSet: Set<ZigbeeMapLayout.Edge> = []
    /// Zählt Bildschirm-Aufwachen: SceneKit bekommt keinen Display-Link, solange
    /// der Bildschirm schläft (Fehler -6661), und die 3D-Ansicht bliebe danach
    /// leer – sie wird deshalb nach dem Aufwachen neu angelegt (28.10.2026).
    @State private var sceneGeneration = 0
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    /// Gerechnete Anordnung; nachgeführt, wenn Geräte oder Kanten dazukommen.
    struct LayoutCache {
        var signature = 0
        var positions: [UInt16: CGPoint] = [:]
        var positions3D: [UInt16: SIMD3<Double>] = [:]
    }

    /// Netze, gezeigte Geräte und Kanten – nur neu gerechnet, wenn sich Geräte,
    /// Kanal, Netzwahl oder Kantenauswahl ändern. Vorher lief das bei jeder
    /// Mausbewegung (Hover) komplett neu (Review 28.10.2026, Y19).
    @State private var memo = DerivedMemo()

    final class DerivedMemo {
        struct Key: Equatable {
            var nodes: [ZigbeeNode]
            var channel: Int
            var chosenPAN: UInt16?
            var allLinks: Bool
            var layoutSet: Set<ZigbeeMapLayout.Edge>
        }

        struct Derived {
            var networks: [ZigbeeMapLayout.Network]
            var pan: UInt16?
            var shown: [ZigbeeNode]
            var allEdges: [ZigbeeMapLayout.Edge]
            var edges: [ZigbeeMapLayout.Edge]
            var byAddress: [UInt16: ZigbeeNode]
            var degree: [UInt16: Int]
            var layoutEdges: [ZigbeeMapLayout.Edge]
        }

        private var key: Key?
        private var value: Derived?
        private(set) var computations = 0

        func derived(_ key: Key) -> Derived {
            if let value, key == self.key { return value }
            computations += 1
            let networks = ZigbeeMapLayout.networks(key.nodes, channel: key.channel)
            let pan = ZigbeeMapLayout.chosenPAN(key.chosenPAN, nodes: key.nodes, networks: networks)
            let shown = key.nodes.filter { $0.key.pan == pan }
            let allEdges = ZigbeeMapLayout.edges(shown)
            let next = Derived(
                networks: networks, pan: pan, shown: shown, allEdges: allEdges,
                edges: key.allLinks ? allEdges : ZigbeeMapLayout.strongest(allEdges, perNode: 2),
                byAddress: Dictionary(shown.map { ($0.key.address, $0) }, uniquingKeysWith: { a, _ in a }),
                degree: allEdges.reduce(into: [UInt16: Int]()) { $0[$1.a, default: 0] += 1; $0[$1.b, default: 0] += 1 },
                // Anordnung nach den besten Verbindungen je Gerät (`layoutSet`): das
                // Router-Netz ist fast vollständig vermascht (16–26 Nachbarn) und zog
                // sich mit allen Kanten zu einem Knäuel zusammen.
                layoutEdges: ZigbeeMapLayout.layoutEdges(allEdges, sticky: key.layoutSet))
            self.key = key
            value = next
            return next
        }
    }

    private var derived: DerivedMemo.Derived {
        memo.derived(.init(nodes: nodes, channel: channel, chosenPAN: chosenPAN, allLinks: allLinks, layoutSet: layoutSet))
    }

    /// Netze: siehe `ZigbeeMapLayout.networks` (gemeinsam mit dem Fernzugriff).
    private var networks: [ZigbeeMapLayout.Network] { derived.networks }

    private var pan: UInt16? { derived.pan }

    var body: some View {
        let derived = self.derived
        let shown = derived.shown
        let allEdges = derived.allEdges
        let edges = derived.edges
        let byAddress = derived.byAddress
        let degree = derived.degree
        let layoutEdges = derived.layoutEdges
        Group {
            if threeD {
                ZigbeeMap3DView(
                    devices: shown.map { ZigbeeMap3DView.Device(address: $0.key.address, label: label($0), role: role($0), connections: degree[$0.key.address] ?? 0) },
                    edges: edges, positions: cache.positions3D, selected: $selected)
                .id(sceneGeneration)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
                    sceneGeneration += 1
                }
                .overlay(alignment: .bottomLeading) {
                    if let selected, let node = byAddress[selected] { detail(node, edges: allEdges) }
                }
            } else {
                flat(shown: shown, edges: edges, allEdges: allEdges, byAddress: byAddress, degree: degree)
            }
        }
        .onChange(of: edgeKey(allEdges), initial: true) { _, _ in
            let next = ZigbeeMapLayout.stickyEdges(layoutSet, all: allEdges)
            if next != layoutSet { layoutSet = next }
        }
        .task(id: signature(shown, layoutEdges)) {
            let addresses = shown.map(\.key.address)
            let coordinator: UInt16? = addresses.contains(0) ? 0 : nil
            // Bekannte Plätze werden nachgeführt.
            let previous = cache
            let (flat, spatial) = await Task.detached(priority: .userInitiated) {
                (ZigbeeMapLayout.layout(addresses, edges: layoutEdges, pinned: coordinator, previous: previous.positions),
                 ZigbeeMapLayout.layout3D(addresses, edges: layoutEdges, pinned: coordinator, previous: previous.positions3D))
            }.value
            let moved = spatial.compactMap { id, p in previous.positions3D[id].map { simd_length(p - $0) } }.max() ?? 0
            ZigbeeView.log.info("Netzkarte: \(addresses.count) Geräte, \(layoutEdges.count) Kanten, \(previous.positions3D.isEmpty ? "neu" : "nachgeführt"), größte Bewegung \(moved, format: .fixed(precision: 2))")
            cache = LayoutCache(signature: signature(shown, layoutEdges), positions: flat, positions3D: spatial)
        }
        .onChange(of: pan) { _, _ in
            // Anderes Netz: nicht nachführen, sondern neu anordnen.
            cache = LayoutCache()
            layoutSet = []
            selected = nil
            hovered = nil
        }
        .onChange(of: channel) { _, _ in chosenPAN = nil }
        .overlay(alignment: .topLeading) {
            if shown.isEmpty {
                Text("Noch keine Geräte. Die Karte braucht Nachbartabellen – rufe dazu in Zigbee2MQTT die „Karte“ auf.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            } else {
                legend
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            if networks.count > 1 {
                Picker("Netz", selection: Binding(get: { pan ?? 0 }, set: { chosenPAN = $0 })) {
                    ForEach(networks, id: \.pan) { network in
                        Text(network.onChannel
                             ? String(format: String(localized: "0x%04X · %d Geräte"), network.pan, network.count)
                             : String(format: String(localized: "0x%04X · %d Geräte · anderer Kanal"), network.pan, network.count))
                            .tag(network.pan)
                    }
                }
                .fixedSize()
                Divider().frame(height: 12)
            }
            Picker("Darstellung", selection: $threeD) {
                Text("2D").tag(false)
                Text("3D").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Divider().frame(height: 12)
            Label("Koordinator", systemImage: "circle.fill").foregroundStyle(.orange)
            Label("Router", systemImage: "circle.fill").foregroundStyle(.blue)
            Label("Endgerät", systemImage: "circle.fill").foregroundStyle(.green)
            Divider().frame(height: 12)
            Text("Linie: grün = gut, rot = schlecht").foregroundStyle(.secondary)
            Divider().frame(height: 12)
            Toggle("Alle Verbindungen", isOn: $allLinks).toggleStyle(.checkbox)
                .help("Aus: je Gerät nur die zwei besten Verbindungen – das Gerüst des Netzes. An: jede gemeldete Verbindung.")
            if !threeD {
                Divider().frame(height: 12)
                Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Verkleinern").accessibilityLabel("Verkleinern")
                Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Vergrößern").accessibilityLabel("Vergrößern")
                if zoom != 1 || offset != .zero {
                    Button("Zurücksetzen") { withAnimation(.snappy) { zoom = 1; offset = .zero } }
                }
            } else {
                Text("Ziehen dreht, Mausrad zoomt, Klick wählt").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption2).padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy) { zoom = min(8, max(0.4, value)) }
    }

    // MARK: 2D

    private func flat(shown: [ZigbeeNode], edges: [ZigbeeMapLayout.Edge], allEdges: [ZigbeeMapLayout.Edge],
                      byAddress: [UInt16: ZigbeeNode], degree: [UInt16: Int]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = cache.positions
            // Breite und Höhe nutzen (der Außenring liegt bei 1,12), aber nicht
            // stärker als 1,6 : 1 verzerren; dazu Zoom und Verschiebung.
            let baseY = max(30, (size.height / 2 - 40) / 1.15)
            let baseX = min(max(30, (size.width / 2 - 70) / 1.15), baseY * 1.6)
            let scaleX = baseX * zoom, scaleY = baseY * zoom
            let origin = CGPoint(x: size.width / 2, y: size.height / 2 + 12)
            let center = CGPoint(x: origin.x + offset.width, y: origin.y + offset.height)
            let point: (UInt16) -> CGPoint? = { address in
                unit[address].map { CGPoint(x: center.x + $0.x * scaleX, y: center.y + $0.y * scaleY) }
            }
            Canvas { context, _ in
                // Außenring als Orientierung: dort stehen Geräte ohne bekannte Verbindung.
                let ring = ZigbeeMapLayout.outerRing
                let ringRect = CGRect(x: center.x - ring * scaleX, y: center.y - ring * scaleY, width: 2 * ring * scaleX, height: 2 * ring * scaleY)
                context.stroke(Path(ellipseIn: ringRect), with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                // Kanten: schwache dünn und blass, gute kräftig; die des Geräts
                // unter der Maus hervorgehoben, die übrigen dann zurückgenommen.
                for edge in edges.sorted(by: { $0.quality < $1.quality }) {
                    guard let a = point(edge.a), let b = point(edge.b) else { continue }
                    let touches = hovered == edge.a || hovered == edge.b
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    let color = Color(hue: edge.quality * 0.33, saturation: 0.75, brightness: 0.85)
                    let opacity = hovered == nil ? 0.3 + 0.5 * edge.quality : (touches ? 0.95 : 0.08)
                    context.stroke(path, with: .color(color.opacity(opacity)),
                                   lineWidth: touches ? 2.5 : 0.8 + 2 * edge.quality)
                }
                // Knoten: Größe nach Zahl der Verbindungen.
                var labels: [(id: UInt16, rect: CGRect)] = []
                let order = shown.sorted { importance($0, degree) > importance($1, degree) }
                for node in order {
                    guard let p = point(node.key.address) else { continue }
                    let r = radius(node, degree) * max(1, sqrt(zoom))
                    let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    let dimmed = hovered != nil && hovered != node.key.address
                        && !edges.contains { ($0.a == hovered && $0.b == node.key.address) || ($0.b == hovered && $0.a == node.key.address) }
                    context.fill(circle, with: .color(color(node).opacity(dimmed ? 0.35 : 1)))
                    context.stroke(circle, with: .color(.black.opacity(0.5)), lineWidth: 1)
                    let text = label(node)
                    let width = CGFloat(text.count) * 6.6 + 12
                    labels.append((node.key.address, CGRect(x: p.x - width / 2, y: p.y + r + 3, width: width, height: 16)))
                }
                // Beschriftungen: wichtige zuerst, überlappende entfallen; das
                // Gerät unter der Maus immer.
                if let hovered, let index = labels.firstIndex(where: { $0.id == hovered }) {
                    labels.insert(labels.remove(at: index), at: 0)
                }
                let visible = ZigbeeMapLayout.placeLabels(labels)
                for entry in labels where visible.contains(entry.id) {
                    guard let node = byAddress[entry.id] else { continue }
                    let highlighted = entry.id == hovered
                    context.fill(Path(roundedRect: entry.rect, cornerRadius: 4),
                                 with: .color(Color(nsColor: .textBackgroundColor).opacity(highlighted ? 0.95 : 0.75)))
                    context.draw(Text(label(node)).font(.caption.weight(highlighted ? .bold : .regular)),
                                 at: CGPoint(x: entry.rect.midX, y: entry.rect.midY))
                }
            }
            .contentShape(Rectangle())
            .background(ScrollWheelCatcher { delta, location in
                // Um den Mauszeiger zoomen: der Punkt darunter bleibt stehen.
                let next = min(8, max(0.4, zoom * (1 + delta * 0.12)))
                let factor = next / zoom
                offset = CGSize(width: location.x - origin.x - (location.x - center.x) * factor,
                                height: location.y - origin.y - (location.y - center.y) * factor)
                zoom = next
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let nearest = shown.compactMap { node -> (UInt16, CGFloat)? in
                        guard let p = point(node.key.address) else { return nil }
                        return (node.key.address, hypot(p.x - location.x, p.y - location.y))
                    }.min { $0.1 < $1.1 }
                    let next = nearest.flatMap { $0.1 < 18 ? $0.0 : nil }
                    if next != hovered { hovered = next }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let start = dragStart ?? offset
                        dragStart = start
                        offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? zoom
                        zoomStart = start
                        zoom = min(8, max(0.4, start * value.magnification))
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = 1; offset = .zero } }
            .overlay(alignment: .bottomLeading) {
                if let hovered, let node = byAddress[hovered] {
                    detail(node, edges: allEdges)
                }
            }
        }
    }

    // MARK: Gemeinsames

    /// Kantenpaare (ohne Güte) für die Hysterese-Prüfung.
    private func edgeKey(_ edges: [ZigbeeMapLayout.Edge]) -> Int {
        var hasher = Hasher()
        for edge in edges { hasher.combine(edge.a); hasher.combine(edge.b); hasher.combine(Int(edge.quality * 50)) }
        return hasher.finalize()
    }

    private func signature(_ nodes: [ZigbeeNode], _ edges: [ZigbeeMapLayout.Edge]) -> Int {
        ZigbeeMapLayout.signature(nodes, edges)
    }

    private func isRouter(_ node: ZigbeeNode) -> Bool { ZigbeeMapLayout.isRouter(node) }

    private func role(_ node: ZigbeeNode) -> ZigbeeMap3DView.Role {
        node.key.address == 0 ? .coordinator : isRouter(node) ? .router : .endDevice
    }

    private func color(_ node: ZigbeeNode) -> Color {
        node.key.address == 0 ? .orange : isRouter(node) ? .blue : .green
    }

    private func radius(_ node: ZigbeeNode, _ degree: [UInt16: Int]) -> CGFloat {
        if node.key.address == 0 { return 12 }
        let base: CGFloat = isRouter(node) ? 6 : 4.5
        return base + min(5, CGFloat(degree[node.key.address] ?? 0) * 0.35)
    }

    private func importance(_ node: ZigbeeNode, _ degree: [UInt16: Int]) -> Int {
        (node.key.address == 0 ? 10_000 : 0) + (name(node) != nil ? 1_000 : 0) + (isRouter(node) ? 500 : 0) + (degree[node.key.address] ?? 0)
    }

    private func label(_ node: ZigbeeNode) -> String {
        name(node) ?? (node.key.address == 0 ? String(localized: "Koordinator") : String(format: "%04X", node.key.address))
    }

    /// Kärtchen zum gewählten Gerät: Rolle und die besten Verbindungen.
    private func detail(_ node: ZigbeeNode, edges: [ZigbeeMapLayout.Edge]) -> some View {
        let links = edges.filter { $0.a == node.key.address || $0.b == node.key.address }
            .sorted { $0.quality > $1.quality }
        let names = Dictionary(derived.shown.map { ($0.key.address, label($0)) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 2) {
            Text(label(node)).font(.callout.weight(.semibold))
            let role = node.key.address == 0 ? String(localized: "Koordinator") : isRouter(node) ? String(localized: "Router") : String(localized: "Endgerät")
            let level = node.rssiDB.map { String(format: " · %.0f dBFS", $0) } ?? ""
            Text("\(role) · \(links.count) Verbindungen\(level)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(links.prefix(5), id: \.self) { edge in
                let other = edge.a == node.key.address ? edge.b : edge.a
                Text("\(names[other] ?? String(format: "%04X", other)) – \(Int(edge.quality * 100)) %")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .allowsHitTesting(false)
    }
}

extension ZigbeeView {
    /// Geräteliste ohne Netzwerkschlüssel.
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["adresse", "pan", "ieee", "name", "rolle", "hersteller", "modell", "versorgung", "kanal", "pegel_dbfs",
                             "gesendet", "ausgeloest", "zustand", "letzte_meldung", "thread", "zuletzt"],
                    rows: model.nodes.map { n in
                        let i = model.info(of: n)
                        let state = n.state.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                        return [.text(String(format: "0x%04X", n.key.address)), .text(String(format: "0x%04X", n.key.pan)),
                                .text(n.ieee.map(ZigbeeFormat.ieee)), .text(model.name(of: n)), .text(n.role),
                                .text(i?.manufacturer ?? n.manufacturer), .text(i?.model ?? n.model), .text(n.power), .integer(n.channel),
                                .number(n.rssiDB, digits: 0), .integer(n.heard), .integer(n.originated), .text(state), .text(n.lastSummary),
                                .flag(n.thread), .date(n.lastSeen)]
                    })
    }
}
