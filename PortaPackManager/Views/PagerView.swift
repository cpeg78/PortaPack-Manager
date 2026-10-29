import SwiftUI

struct PagerView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.pager
    @State private var selection: PagerMessage.ID?
    @State private var order: [ColumnSort<PagerMessage>] = []
    @State private var ricFilter = ""
    @AppStorage("pagerFrequencyMHz") private var frequencyMHz = PagerModel.dapnetMHz
    @AppStorage("pagerGermanCharset") private var germanCharset = true

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "antenna.radiowaves.left.and.right", text: String(localized: "Die App empfängt Funkrufe (POCSAG, z. B. DAPNET auf 439,9875 MHz) selbst – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    table.frame(minHeight: 120)
                    detail.frame(minHeight: 70, idealHeight: 120)
                }
                .frame(minWidth: 520)
            } controls: {
                controls
            }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
        }
    }

    private var filtered: [PagerMessage] {
        let rics = ricFilter.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { UInt32($0) }
        guard !rics.isEmpty else { return model.messages }
        return model.messages.filter { rics.contains($0.ric) }
    }

    private var table: some View {
        Table(filtered.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.date }) {
                Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit()
            }.width(70)
            TableColumn("RIC", sortUsing: ColumnSort("ric") { Int($0.ric) }) {
                Text(String($0.ric)).font(.body.monospaced())
            }.width(min: 60, ideal: 75)
            TableColumn("Fkt.", sortUsing: ColumnSort("funktion", text: { $0.functionLetter })) { Text($0.functionLetter) }.width(32)
            TableColumn("Bd", sortUsing: ColumnSort("baud") { $0.bitRate }) { Text("\($0.bitRate)").monospacedDigit() }.width(42)
            TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.kind.title })) { Text($0.kind.title) }.width(60)
            TableColumn("Inhalt") { message in
                HStack(spacing: 4) {
                    if message.incomplete {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            .help("Ein Kodewort war nicht zu korrigieren – der Rest fehlt.")
                    }
                    if message.uncertain {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                            .help("Die Adresse brauchte zwei Korrekturen – RIC womöglich falsch.")
                    }
                    Text(message.text(german: germanCharset).replacingOccurrences(of: "\n", with: " ⏎ "))
                        .lineLimit(1)
                }
            }
            TableColumn("Korr.", sortUsing: ColumnSort("korrektur") { $0.correctedBits }) {
                Text($0.correctedBits == 0 ? "–" : "\($0.correctedBits)").monospacedDigit().foregroundStyle(.secondary)
            }.width(40)
        }
        .contextMenu(forSelectionType: PagerMessage.ID.self) { ids in
            if let message = model.messages.first(where: { ids.contains($0.id) }) {
                Button("Inhalt kopieren") { copy(message.text(german: germanCharset)) }
                Button("Nur diese RIC zeigen") { ricFilter = String(message.ric) }
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("Keine Nachrichten", systemImage: "message",
                                       description: Text(model.running
                                                         ? "Noch kein Funkruf. DAPNET sendet je nach Sender nur alle paar Minuten – eine 70-cm-Antenne hilft."
                                                         : "Mit „Start“ beginnt der Empfang auf \(frequencyMHz.formatted(.number.precision(.fractionLength(4)))) MHz."))
            }
        }
    }

    private var detail: some View {
        ScrollView {
            if let id = selection, let message = model.messages.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RIC \(message.ric) · Funktion \(message.functionLetter) · \(message.bitRate) Bd · \(message.kind.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(message.kind == .tone ? String(localized: "(Nur-Ton-Ruf ohne Inhalt)") : message.text(german: germanCharset))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else {
                Text("Nachricht auswählen").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
    }

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop(on: session.hackRF) }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device, frequencyMHz: frequencyMHz) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Leeren") { model.clear() }
                }
                // DAPNET ist der Normalfall – die Frequenz von Hand nur für Fortgeschrittene.
                LabeledContent("Frequenz", value: abs(frequencyMHz - PagerModel.dapnetMHz) < 0.0001
                               ? String(localized: "DAPNET (439,9875 MHz)") : String(format: "%.4f MHz", frequencyMHz))
                DisclosureGroup("Andere Frequenz") {
                    LabeledContent("MHz") {
                        FrequencyField(mhz: frequencyMHz, decimals: 4) {
                            frequencyMHz = $0
                            model.retune(on: session.hackRF, frequencyMHz: $0)
                        }
                    }
                    Button("Zurück zu DAPNET") {
                        frequencyMHz = PagerModel.dapnetMHz
                        model.retune(on: session.hackRF, frequencyMHz: frequencyMHz)
                    }
                }
                Toggle("Kanal mithören", isOn: Binding(get: { model.monitorAudio }, set: { model.setMonitoring($0) }))
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Nachrichten", value: "\(model.messageCount)")
                LabeledContent("Synchron", value: model.lockedRates.isEmpty ? "–" : model.lockedRates.map { "\($0) Bd" }.joined(separator: ", "))
                    .help("Übertragungsgeschwindigkeit (Baud), auf die der Empfänger gerade eingerastet ist.")
                LabeledContent("Kanalpegel", value: String(format: "%.0f dBFS", model.signalDB))
            }
            FrequencyMemorySection(page: .pager, currentMHz: frequencyMHz) { entry in
                frequencyMHz = entry.mhz
                model.retune(on: session.hackRF, frequencyMHz: entry.mhz)
            }
            Section(PanelSection.anzeige) {
                TextField("Nur RIC (z. B. 2504, 8)", text: $ricFilter)
                Toggle("Deutscher Zeichensatz", isOn: $germanCharset)
                    .help("Zeigt [\\]{|}~ als ÄÖÜäöüß, wie Skyper- und DAPNET-Pager.")
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "funkruf", isEmpty: model.messages.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                LegalNotice(text: "Empfang nur Funkrufe, die für alle oder für dich bestimmt sind – etwa DAPNET oder deinen eigenen Pager. Alarmierungen von Feuerwehr, Rettungsdienst und Polizei abzuhören oder weiterzugeben ist verboten (§ 5 TDDDG).",
                            help: "Empfangene Nachrichten bleiben nur im Arbeitsspeicher und werden nicht gespeichert.")
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension PagerView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["zeit", "ric", "funktion", "baud", "art", "inhalt", "korrigierte_bits", "unvollstaendig", "ric_unsicher"],
                    rows: model.messages.map { m in
                        [.date(m.date), .integer(Int(m.ric)), .text(m.functionLetter), .integer(m.bitRate), .text(m.kind.title),
                         .text(m.text(german: germanCharset)), .integer(m.correctedBits), .flag(m.incomplete), .flag(m.uncertain)]
                    })
    }
}
