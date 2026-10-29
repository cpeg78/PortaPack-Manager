import Charts
import SwiftUI

struct WiFiView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.wifi
    @State private var order: [ColumnSort<WiFiNetwork>] = []
    @State private var stationOrder: [ColumnSort<WLANStation>] = []
    @State private var showZigbee = true
    @State private var showFrames = false

    var body: some View {
        ControlsSplit(width: 290, issue: model.error) {
            VStack(spacing: 0) {
                if showFrames {
                    if hasHackRF {
                        stationTable.frame(minHeight: 200)
                        Divider()
                        clientTable.frame(minHeight: 140)
                    } else {
                        hackRFRequired
                    }
                } else {
                    occupancy.frame(minHeight: 240).padding(12)
                    Divider()
                    networkTable
                }
            }
            .frame(minWidth: 560)
        } controls: {
            controls
        }
        .onAppear { if model.networks.isEmpty { model.scanNetworks() } }
        .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop(on: nil) } }
    }

    private var hasHackRF: Bool { session.mode == .hackRF && session.hackRF != nil }

    /// Einheitliche Sperre; die Netzliste des Mac bleibt darunter nutzbar.
    private var hackRFRequired: some View {
        HackRFRequiredView(systemImage: "wifi",
                           text: "Belegung und Rahmen misst der HackRF – dafür muss das PortaPack im HackRF-Modus laufen. Die Netzliste kommt vom WLAN des Mac und klappt auch ohne.")
    }

    // MARK: Belegung

    private var visibleNetworks: [WiFiNetwork] {
        model.networks.filter { model.sweep.rangeMHz.contains($0.centerMHz) && ($0.band == .ghz2) == (model.sweep == .ghz2) }
    }

    private var occupancy: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kanalbelegung \(model.sweep.title)").font(.headline)
                Spacer()
                if model.running { Text("Durchlauf \(model.sweeps)").font(.caption).foregroundStyle(.secondary) }
            }
            if model.bins.isEmpty, !hasHackRF {
                hackRFRequired
            } else if model.bins.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Messung", systemImage: "chart.bar")
                } description: {
                    Text("Wähle „Belegung“ und drück „Start“: Die App tastet das Band ab und zeigt, wie oft jeder Abschnitt belegt ist – auch durch Bluetooth, Zigbee und andere Störer.")
                }
            } else {
                Chart {
                    ForEach(visibleNetworks) { network in
                        RectangleMark(xStart: .value("von", network.centerMHz - Double(network.widthMHz) / 2),
                                      xEnd: .value("bis", network.centerMHz + Double(network.widthMHz) / 2),
                                      yStart: .value("", 0), yEnd: .value("", 100))
                            .foregroundStyle(.blue.opacity(0.06))
                    }
                    ForEach(model.bins) { bin in
                        BarMark(x: .value("MHz", bin.mhz), y: .value("Belegt", bin.busy * 100), width: .ratio(0.9))
                            .foregroundStyle(color(bin.busy))
                    }
                    if showZigbee, model.sweep == .ghz2 {
                        ForEach(IEEE802154.channels, id: \.self) { ch in
                            RuleMark(x: .value("Zigbee", IEEE802154.frequencyMHz(channel: ch)))
                                .foregroundStyle(.purple.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, spacing: 0) {
                                    Text("\(ch)").font(.system(size: 8)).foregroundStyle(.purple)
                                }
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: model.sweep.rangeMHz)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0) %") }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: model.sweep == .ghz2 ? [2412, 2437, 2462, 2472] : Array(stride(from: 5180.0, through: 5825, by: 80))) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let mhz = value.as(Double.self) {
                                Text(model.sweep == .ghz2 ? String(localized: "Kanal \(Int((mhz - 2407) / 5))") : String(format: "%.0f", mhz))
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    legend(.green, "selten belegt"); legend(.orange, "oft"); legend(.red, "dauernd")
                    if showZigbee, model.sweep == .ghz2 { legend(.purple, "Zigbee-Kanäle") }
                    legend(.blue.opacity(0.3), "WLANs laut Mac")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ busy: Double) -> Color {
        busy < 0.1 ? .green : busy < 0.4 ? .orange : .red
    }

    private func legend(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10); Text(text) }
    }

    // MARK: Netze

    private var networkTable: some View {
        Table(model.networks.sorted(by: order), sortOrder: $order) {
            TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.ssid })) { network in
                HStack(spacing: 4) {
                    if network.bssid != nil, network.bssid == model.current?.bssid {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Verbunden")
                    }
                    Text(network.ssid ?? String(localized: "(verborgen)")).foregroundStyle(network.ssid == nil ? .secondary : .primary)
                }
            }
            TableColumn("Band", sortUsing: ColumnSort("band", text: { $0.band.rawValue })) { Text($0.band.title) }.width(55)
            TableColumn("Kanal", sortUsing: ColumnSort("kanal") { $0.channel }) { n in
                Text(n.widthMHz > 20 ? "\(n.channel) (\(n.widthMHz) MHz)" : "\(n.channel)").monospacedDigit()
            }.width(90)
            TableColumn("Signal", sortUsing: ColumnSort("signal") { $0.rssi }) { n in
                Text("\(n.rssi) dBm").monospacedDigit().foregroundStyle(n.rssi > -60 ? .green : n.rssi > -75 ? .orange : .red)
            }.width(70)
            TableColumn("Abstand", sortUsing: ColumnSort("abstand") { $0.rssi - $0.noise }) { n in
                Text(n.noise == 0 ? "–" : "\(n.rssi - n.noise) dB").monospacedDigit()
            }.width(60)
            TableColumn("Schutz", sortUsing: ColumnSort("schutz", text: { $0.security })) { Text($0.security) }.width(55)
            TableColumn("BSSID") { Text($0.bssid ?? "–").font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .overlay {
            if model.networks.isEmpty, !model.scanningNetworks {
                ContentUnavailableView("Keine Netze", systemImage: "wifi.slash",
                                       description: Text(model.networkError ?? String(localized: "„Netze suchen“ fragt das WLAN des Mac ab.")))
            }
        }
    }

    private func exportPCAP() {
        Task {
            guard let url = await SaveSheet.url(name: "wlan.pcap",
                                                message: String(localized: "Mitgeschnittene WLAN-Rahmen (802.11, mit Radiotap) – in Wireshark lesbar")) else { return }
            try? model.pcap().write(to: url)
        }
    }

    // MARK: Rahmen (HackRF)

    private static let byBeacons = ColumnSort<WLANStation>("beacons") { (s: WLANStation) -> Int? in s.beacons }
    private static let byStationLevel = ColumnSort<WLANStation>("pegel") { (s: WLANStation) -> Double? in s.rssiDB }
    private static let byStationChannel = ColumnSort<WLANStation>("kanal") { (s: WLANStation) -> Int? in s.dsChannel ?? s.channel }
    private static let byStationName = ColumnSort<WLANStation>("name", text: { (s: WLANStation) -> String? in s.displayName })

    private var stationTable: some View {
        Table(model.stations.sorted(by: stationOrder), sortOrder: $stationOrder) {
            TableColumn("Netz", sortUsing: Self.byStationName) { (s: WLANStation) in
                Text(s.displayName).foregroundStyle(s.ssid?.isEmpty == false ? Color.primary : Color.secondary)
            }
            TableColumn("Kanal", sortUsing: Self.byStationChannel) { (s: WLANStation) in
                Text(s.dsChannel.map { $0 == s.channel ? "\($0)" : String(localized: "\($0) (gehört auf \(s.channel))") } ?? "\(s.channel)").monospacedDigit()
            }.width(min: 50, ideal: 70)
            TableColumn("Pegel", sortUsing: Self.byStationLevel) { (s: WLANStation) in
                Text(String(format: "%.0f dBFS", s.rssiDB)).monospacedDigit()
            }.width(70)
            TableColumn("Beacons", sortUsing: Self.byBeacons) { (s: WLANStation) in
                Text("\(s.beacons)").monospacedDigit()
            }.width(60)
            TableColumn("Rate") { (s: WLANStation) in Text(String(format: "%.0f Mbit/s", s.rateMbps)).foregroundStyle(.secondary) }.width(70)
            TableColumn("Schutz") { (s: WLANStation) in Text(s.security) }.width(100)
            TableColumn("BSSID") { (s: WLANStation) in Text(s.bssid).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(130)
            TableColumn("Gehört") { (s: WLANStation) in Text(s.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(70)
        }
        .overlay {
            if model.stations.isEmpty {
                ContentUnavailableView("Keine Rahmen", systemImage: "wifi",
                                       description: Text(model.running ? "Höre auf Kanal \(model.frameChannel) …" : "Wähle „Rahmen“ und drück „Start“: Der HackRF liest Beacons und Probe-Anfragen direkt mit – auch verborgene Netze und 5 GHz."))
            }
        }
    }

    private var clientTable: some View {
        Table(model.clients) {
            TableColumn("Gerät (sucht)") { (c: WLANClient) in
                HStack(spacing: 4) {
                    Text(c.mac).font(.caption.monospaced())
                    if c.randomized { Text("zufällig").font(.caption2).foregroundStyle(.secondary) }
                }
            }.width(160)
            TableColumn("Gesuchte Netze") { (c: WLANClient) in Text(c.ssids.sorted().joined(separator: ", ")).lineLimit(1) }
            TableColumn("Anfragen") { (c: WLANClient) in Text("\(c.probes)").monospacedDigit() }.width(60)
            TableColumn("Pegel") { (c: WLANClient) in Text(String(format: "%.0f dBFS", c.rssiDB)).monospacedDigit() }.width(70)
            TableColumn("Kanal") { (c: WLANClient) in Text("\(c.channel)").monospacedDigit() }.width(45)
            TableColumn("Gehört") { (c: WLANClient) in Text(c.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(70)
        }
        .overlay {
            if model.clients.isEmpty {
                Text("Hier erscheinen Geräte, die nach bekannten Netzen suchen (Probe-Anfragen), mit den gesuchten Netznamen.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }

    // MARK: Bedienung

    private var controls: some View {
        Form {
            Section {
                Picker("Modus", selection: $model.hackRFMode) {
                    Text("Belegung").tag(WiFiModel.HackRFMode.occupancy)
                    Text("Rahmen").tag(WiFiModel.HackRFMode.frames)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.running)
                .onChange(of: model.hackRFMode) { _, mode in showFrames = mode == .frames }
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        guard let device = session.hackRF else { return }
                        if model.running { model.stop(on: device) } else {
                            ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    .disabled(!hasHackRF)
                    Spacer()
                    if model.hackRFMode == .frames {
                        Button("Leeren") { model.clearFrames() }
                    }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if model.hackRFMode == .frames {
                Section("Kanal") {
                    Picker("Kanäle", selection: $model.frameChannels) {
                        ForEach(WiFiModel.FrameChannels.allCases) { Text($0.title).tag($0) }
                    }
                    if model.frameChannels == .single {
                        Stepper("Kanal \(model.fixedChannel)", value: $model.fixedChannel, in: 1...177)
                    }
                    LabeledContent("Je Kanal \(String(format: "%.0f", model.frameDwell)) s") {
                        Slider(value: $model.frameDwell, in: 1...10, step: 1)
                    }
                }
            } else {
                Section("Band") {
                    Picker("Band", selection: Binding(get: { model.sweep }, set: { model.changeSweep($0) })) {
                        ForEach(WiFiModel.Sweep.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                if model.hackRFMode == .frames {
                    if model.running { LabeledContent("Aktuell", value: String(localized: "Kanal \(model.frameChannel) · Rauschen \(String(format: "%.0f", model.frameNoiseDB)) dBFS")) }
                    let c = model.frameCounts
                    LabeledContent("Rahmen", value: "\(c.total) · \(c.dsss) DSSS / \(c.ofdm) OFDM")
                    LabeledContent("Davon", value: String(localized: "\(c.beacons) Beacons · \(c.probeRequests) Probe · \(c.data) Daten · \(c.control) Steuer · \(c.nan) NAN"))
                    LabeledContent("Netze / Geräte", value: "\(model.stations.count) / \(model.clients.count)")
                } else {
                    LabeledContent("Durchläufe", value: "\(model.sweeps)")
                }
            }
            if !model.wifiRanking.isEmpty {
                Section("Empfehlung") {
                    let wifi = model.wifiRanking.filter { [1, 6, 11].contains($0.channel) }
                    if let best = wifi.first {
                        LabeledContent("WLAN (1/6/11)", value: String(localized: "Kanal \(best.channel) · \(Int(best.busy * 100)) % belegt"))
                    }
                    let zigbee = model.zigbeeRanking.prefix(3)
                    LabeledContent("Zigbee", value: zigbee.map { "\($0.channel) (\(Int($0.busy * 100)) %)" }.joined(separator: ", "))
                    Text("Zigbee und WLAN teilen sich das 2,4-GHz-Band. Ein Zigbee-Kanalwechsel heißt oft: viele Geräte neu anlernen.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Zigbee-Kanal 25/26 liegt oberhalb von WLAN-Kanal 11, Kanal 15 und 20 zwischen WLAN 1/6/11.")
                }
            }
            if model.hackRFMode == .occupancy {
                Section(PanelSection.anzeige) {
                    Toggle("Zigbee-Kanäle einzeichnen", isOn: $showZigbee)
                }
            } else {
                Section(PanelSection.daten) {
                    CSVExportButton(title: "Stationen als CSV sichern …", fileName: "wlan-stationen", isEmpty: model.stations.isEmpty) { csvDocument() }
                    Toggle("Rahmen mitschneiden (PCAP)", isOn: $model.captureFrames)
                        .help("Zeichnet die empfangenen Rahmen auf. „PCAP sichern …“ schreibt sie mit Kanal und Pegel in eine Datei, die Wireshark lesen kann.")
                    HStack {
                        Button("PCAP sichern …", action: exportPCAP)
                            .disabled(model.capturedCount == 0)
                        Spacer()
                        if model.captureFrames { Text("\(model.capturedCount) Rahmen").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            // Der Mac-WLAN-Scan ist unabhängig vom HackRF und geht auch ohne ihn.
            Section("Netze (WLAN des Mac)") {
                HStack {
                    Button("Netze suchen") { model.scanNetworks() }.disabled(model.scanningNetworks)
                    if model.scanningNetworks { ProgressView().controlSize(.small) }
                }
                LabeledContent("Gefunden", value: "\(model.networks.count)")
                if let current = model.current {
                    LabeledContent("Verbunden", value: String(localized: "\(current.ssid ?? "?") · Kanal \(current.channel)"))
                    LabeledContent("Signal / Rauschen", value: "\(current.rssi) / \(current.noise) dBm")
                }
                if let error = model.networkError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section(PanelSection.hinweis) {
                Text("Du siehst nur, was jedes WLAN ohnehin offen aussendet: Netznamen, Kanäle, Signalstärken und Rahmenarten – keine Inhalte.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Der HackRF liest Beacons (DSSS 1/2 Mbit/s, OFDM 6–54 Mbit/s) und Probe-Anfragen; 802.11n/ac-Daten dekodiert er nicht.")
            }
        }
        .formStyle(.grouped)
    }
}

extension WiFiView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["bssid", "ssid", "kanal", "ds_kanal", "schutz", "pegel_db", "beacons", "rate_mbps", "nan", "zuletzt"],
                    rows: model.stations.map { s in
                        [.text(s.bssid), .text(s.ssid), .integer(s.channel), .integer(s.dsChannel), .text(s.security), .number(s.rssiDB),
                         .integer(s.beacons), .number(s.rateMbps, digits: 0), .flag(s.nan), .date(s.lastSeen)]
                    })
    }
}
