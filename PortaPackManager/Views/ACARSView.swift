import SwiftUI

struct ACARSView: View {
    @Environment(DeviceSession.self) private var session
    /// Gehört dem Fernzugriff – App und Browser bedienen denselben Empfänger.
    @Bindable private var model = RemoteHub.shared.acars
    @State private var selection: ACARSMessage.ID?
    @State private var order: [ColumnSort<ACARSMessage>] = []
    @State private var search = ""
    @State private var channelFilter: Double?
    @State private var hideEmpty = true
    @AppStorage("acarsHideATN") private var hideATN = false
    @State private var direction = Direction.all
    @AppStorage("acarsArrangement") private var arrangement = Arrangement.newest
    private var database: AircraftDatabase { .shared }

    enum Direction: Hashable, CaseIterable, Identifiable {
        case all, downlink, uplink
        var id: Self { self }
        var title: String {
            switch self {
            case .all: String(localized: "Alle")
            case .downlink: String(localized: "Vom Flugzeug")
            case .uplink: String(localized: "Zum Flugzeug")
            }
        }
    }

    /// Grundordnung der Tabelle; ein Klick auf einen Spaltenkopf geht vor.
    enum Arrangement: String, CaseIterable, Identifiable {
        case newest, important, aircraft
        var id: Self { self }
        var title: String {
            switch self {
            case .newest: String(localized: "Neueste zuerst")
            case .important: String(localized: "Wichtige zuerst")
            case .aircraft: String(localized: "Nach Flugzeug")
            }
        }
    }

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "text.bubble", text: String(localized: "Die App empfängt den Datenfunk der Flugzeuge (ACARS und VDL2) selbst, mehrere Kanäle gleichzeitig – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 290, issue: model.error) {
                VSplitView {
                    table.frame(minHeight: 220)
                    detail.frame(minHeight: 140)
                }
                .frame(minWidth: 560)
            } controls: {
                controls
            }
            .onAppear { database.loadIfNeeded() }
            .task { if AppNavigation.shared.takeAutoStart(.acars), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.acars); model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop() }
            }
        }
    }

    // MARK: - Nachrichten

    private var filtered: [ACARSMessage] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return model.messages.filter { message in
            if hideEmpty, message.text.isEmpty, message.label == "_d" || message.label == "SQ" { return false }
            if hideATN, message.label == "ATN" { return false }
            if let channelFilter, message.frequencyMHz != channelFilter { return false }
            switch direction {
            case .all: break
            case .downlink: if !message.isDownlink { return false }
            case .uplink: if message.isDownlink { return false }
            }
            guard !needle.isEmpty else { return true }
            return [message.registration, message.flight ?? "", message.label, message.text]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var arranged: [ACARSMessage] {
        let rows = filtered
        if !order.isEmpty { return rows.sorted(by: order) }
        switch arrangement {
        case .newest:
            return rows.sorted { $0.id > $1.id }
        case .important:
            let rank = Dictionary(rows.map { ($0.id, $0.relevance) }, uniquingKeysWith: { a, _ in a })
            return rows.sorted { (rank[$0.id] ?? 9, -$0.id) < (rank[$1.id] ?? 9, -$1.id) }
        case .aircraft:
            // Flugzeug mit der jüngsten Meldung oben, darin neueste zuerst.
            let latest = Dictionary(rows.map { ($0.registration, $0.id) }, uniquingKeysWith: max)
            return rows.sorted {
                let a = latest[$0.registration] ?? 0, b = latest[$1.registration] ?? 0
                return a != b ? a > b : ($0.registration != $1.registration ? $0.registration < $1.registration : $0.id > $1.id)
            }
        }
    }

    private var table: some View {
        Table(arranged, selection: $selection, sortOrder: $order) {
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.id }) { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(65)
            TableColumn("Kanal", sortUsing: ColumnSort("kanal") { $0.frequencyMHz }) { Text(String(format: "%.3f", $0.frequencyMHz)).monospacedDigit() }.width(60)
            TableColumn("Kennzeichen", sortUsing: ColumnSort("kennzeichen", text: { $0.registration })) { Text($0.registration).font(.body.monospaced()) }.width(80)
            TableColumn("Flug", sortUsing: ColumnSort("flug", text: { $0.flight })) { Text($0.flight ?? "–").font(.body.monospaced()) }.width(65)
            TableColumn("Label", sortUsing: ColumnSort("label", text: { $0.label })) { message in
                Text(message.label).font(.body.monospaced()).help(message.labelMeaning ?? "")
            }.width(40)
            TableColumn("Deutung") { message in
                let i = message.interpretation
                Text(i.summary).foregroundStyle(i.opaque ? .secondary : .primary).help(i.summary)
            }.width(min: 120, ideal: 200)
            TableColumn("Mode/Block") { message in
                Text("\(String(message.mode)) / \(message.blockID.map(String.init) ?? "–")").font(.caption.monospaced())
            }.width(65)
            TableColumn("Text") { message in
                Text(message.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                    .lineLimit(1).foregroundStyle(message.text.isEmpty ? .secondary : .primary)
            }
        }
        .contextMenu(forSelectionType: ACARSMessage.ID.self) { ids in
            if let message = model.messages.first(where: { ids.contains($0.id) }) {
                Button("Text kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
                Button("Nach Kennzeichen filtern") { search = message.registration }
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("Keine Nachrichten", systemImage: "text.bubble",
                                       description: Text(model.running
                                                         ? "Noch keine fehlerfreie Nachricht. Flugzeuge senden in Schüben – nahe am Flughafen meist mehrere pro Minute, sonst seltener."
                                                         : "Mit „Start“ beginnt der Empfang auf den gewählten Kanälen."))
            }
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.messages.first(where: { $0.id == selection }) {
                    Text("\(message.registration)\(message.flight.map { " · \($0)" } ?? "") · Label \(message.label)")
                        .font(.headline).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        row("Richtung", message.isDownlink ? String(localized: "vom Flugzeug") : String(localized: "zum Flugzeug"))
                        if let meaning = message.labelMeaning { row("Label", meaning) }
                        row("Mode", String(message.mode))
                        row("Block-ID", message.blockID.map(String.init) ?? "–")
                        row("Quittung", message.acknowledge == "!" ? "NAK" : String(message.acknowledge))
                        if let number = message.messageNumber { row("Nachrichtennummer", number) }
                        row("Kanal", String(format: "%.3f MHz", message.frequencyMHz))
                        row("Pegel", String(format: "%.1f dB", message.levelDB))
                        if message.corrected > 0 { row("Korrigiert", String(localized: "\(message.corrected) Fehler")) }
                        if message.blocks > 1 { row("Blöcke", String(localized: "\(message.blocks) zusammengesetzt")) }
                        if message.continued { row("Fortsetzung", String(localized: "weitere Blöcke folgen")) }
                        if let icao = message.icao {
                            row("ICAO-Adresse", String(format: "%06X", icao))
                            if let info = database.info(for: icao) {
                                if !info.typeText.isEmpty { row("Typ", info.typeText) }
                                if !info.operatorText.isEmpty { row("Betreiber", info.operatorText) }
                            }
                        }
                    }
                    .font(.callout)
                    if let icao = message.icao {
                        let onMap = RemoteHub.shared.adsb.aircraft.contains { $0.icao == icao }
                        Button("Auf der ADS-B-Karte zeigen", systemImage: "airplane") { AppNavigation.shared.showAircraft(icao) }
                            .disabled(!onMap)
                            .help(onMap ? "Wechselt zur ADS-B-Seite und wählt das Flugzeug aus."
                                        : "Dieses Flugzeug wird gerade nicht per ADS-B empfangen (ADS-B muss dafür laufen).")
                    }
                    let interpretation = message.interpretation
                    GroupBox("Deutung") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(interpretation.summary).bold()
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                                ForEach(Array(interpretation.rows.enumerated()), id: \.offset) { _, r in row(r.name, r.value) }
                            }
                            if interpretation.opaque {
                                Text("Die Fluggesellschaft hat den Inhalt in einem eigenen Format verschlüsselt – lesbaren Text gibt es daraus nicht.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if interpretation.rows.isEmpty, message.label != "XID" {
                                Text("Kein bekanntes Format – der Rohtext steht unten.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(message.text.isEmpty ? String(localized: "(kein Text)") : message.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("Nachricht wählen, um den vollständigen Text zu sehen.").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Zeile mit festem Titel (Literal → übersetzt).
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// Zeile mit Titel aus der Deutung (schon übersetzt bzw. Protokollfeld).
    private func row<S: StringProtocol>(_ label: S, _ value: String) -> some View {
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
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.acars); model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    .disabled(!model.running && model.band == .acars && model.plan == nil)
                    Spacer()
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Kanäle") {
                // Beschriftung in eigener Zeile: neben „Verfahren“ ragte der
                // Umschalter im schmalen Bedienfeld links hinaus.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Verfahren")
                    Picker("Verfahren", selection: $model.band) {
                        ForEach(ACARSModel.Band.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                if model.band == .vdl2 {
                    ForEach(VDL2Receiver.channelsMHz, id: \.self) { mhz in
                        HStack {
                            Text(String(format: "%.3f MHz", mhz)).monospacedDigit()
                            Spacer()
                            channelStatus(mhz)
                        }
                    }
                    Text("In Europa läuft der Datenfunk meist über VDL2. Die App hört alle vier Kanäle gleichzeitig.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("VDL Mode 2 (D8PSK, 31,5 kbit/s); 136,975 MHz ist der gemeinsame Anmeldekanal. Quittungen und ATN-Daten zählen nur mit.")
                } else {
                    ForEach(ACARSPlan.europeanMHz, id: \.self) { mhz in
                        Toggle(isOn: Binding(
                            get: { model.selectedMHz.contains(mhz) },
                            set: { on in
                                if on { model.selectedMHz.insert(mhz) } else { model.selectedMHz.remove(mhz) }
                                model.selectionChanged()
                            })) {
                            HStack {
                                Text(String(format: "%.3f MHz", mhz)).monospacedDigit()
                                Spacer()
                                channelStatus(mhz)
                            }
                        }
                    }
                    Text("Wähle die Kanäle – in Europa sind 131,525, 131,725 und 131,825 MHz am meisten los.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Gleichzeitig gehen nur Kanäle, die höchstens 1,6 MHz auseinanderliegen (Fenster von 2 MS/s).")
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("ACARS-Nachrichten", value: "\(model.messages.count)")
                if model.band == .vdl2 {
                    LabeledContent("VDL2-Rahmen", value: "\(model.vdl2Frames)")
                    LabeledContent("Flugzeuge", value: "\(model.vdl2Aircraft)")
                    LabeledContent("Nicht korrigierbar", value: "\(model.vdl2FECErrors)")
                } else {
                    LabeledContent("Blöcke", value: "\(model.blocksSeen)")
                    LabeledContent("Prüfsummenfehler", value: "\(model.crcErrors)")
                    if let plan = model.activePlan ?? model.plan {
                        LabeledContent("Mitte", value: String(format: "%.4f MHz", plan.centerHz / 1e6))
                    }
                }
            }
            Section(PanelSection.anzeige) {
                Picker("Sortierung", selection: Binding(get: { arrangement }, set: { arrangement = $0; order = [] })) {
                    ForEach(Arrangement.allCases) { Text($0.title).tag($0) }
                }
                .help("„Wichtige zuerst“: Lotsenmeldungen (CPDLC) und Positionen oben, Quittungen des Netzes unten. Ein Klick auf einen Spaltenkopf sortiert nach dieser Spalte.")
                TextField("Kennzeichen, Flug, Label, Text", text: $search)
                Picker("Richtung", selection: $direction) {
                    ForEach(Direction.allCases) { Text($0.title).tag($0) }
                }
                Picker("Kanal", selection: $channelFilter) {
                    Text("Alle").tag(Double?.none)
                    ForEach(model.band == .vdl2 ? VDL2Receiver.channelsMHz : ACARSPlan.europeanMHz, id: \.self) {
                        Text(String(format: "%.3f", $0)).tag(Double?.some($0))
                    }
                }
                Toggle("Leere Quittungen ausblenden", isOn: $hideEmpty)
                if model.band == .vdl2 {
                    Toggle("ATN-Verkehr (X.25) ausblenden", isOn: $hideATN)
                        .help("Routing (IDRP), Transportquittungen und Verbindungsaufbau des ATN; die Lotsenmeldungen selbst erscheinen als CPDLC- und CM-Zeilen.")
                }
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "acars-vdl2", isEmpty: model.messages.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                LegalNotice()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func channelStatus(_ mhz: Double) -> some View {
        if let power = model.channelPowerDB[mhz], model.running {
            Text(String(format: "%.0f dB", power)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else if model.selectedMHz.contains(mhz), let plan = model.plan, plan.outside.contains(mhz) {
            Text("außerhalb").font(.caption).foregroundStyle(.orange)
                .help("Zu weit von den anderen Kanälen entfernt – gleichzeitig gehen nur Kanäle bis 1,6 MHz Abstand.")
        }
    }
}

extension ACARSView {
    /// Alle Meldungen der Live-Liste (ACARS und VDL2), ungefiltert.
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["zeit", "kanal_mhz", "pegel_db", "kennzeichen", "flug", "icao", "label", "label_bedeutung",
                             "deutung", "mode", "block", "nachricht_nr", "korrigiert", "bloecke", "text"],
                    rows: model.messages.map { m in
                        [.date(m.date), .number(m.frequencyMHz, digits: 3), .number(m.levelDB), .text(m.registration), .text(m.flight),
                         .text(m.icao.map { String(format: "%06X", $0) }), .text(m.label), .text(m.labelMeaning),
                         .text(m.interpretation.summary), .text(String(m.mode)), .text(m.blockID.map(String.init)),
                         .text(m.messageNumber), .integer(m.corrected), .integer(m.blocks), .text(m.text)]
                    })
    }
}
