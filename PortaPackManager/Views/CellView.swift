import Charts
import SwiftUI

/// Mobilfunkzellen (LTE): Suchlauf, Zellenliste, Beobachten einer Zelle.
struct CellView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.cells
    @State private var selection: LTECell.ID?
    @State private var order: [ColumnSort<LTECell>] = []
    @State private var frequencyText = ""
    @State private var shownBand: Int?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "cellularbars", text: "Die App liest die öffentlichen Kennungen der LTE-Basisstationen (Zellnummer, Bandbreite, Netzbetreiber) selbst. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 320, issue: model.error) {
                VSplitView {
                    VStack(spacing: 0) {
                        header.padding(10)
                        Divider()
                        table
                    }
                    // Volle Breite: Leer schrumpfte der Bereich sonst auf die Breite
                    // des Platzhaltertexts und stand schmal in der Mitte (28.10.2026).
                    .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 420)
                    detail.frame(maxWidth: .infinity, minHeight: 160, idealHeight: 260)
                }
                .frame(minWidth: 560)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.cells), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    // MARK: Kopf mit Fortschritt und Bandübersicht

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.cells.isEmpty ? "Mobilfunkzellen" : "\(model.cells.count) Zellen").font(.headline)
                Spacer()
                if model.running { ProgressView(value: model.progress).frame(width: 160) }
            }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let spectrum = currentSpectrum {
                bandChart(spectrum).frame(height: 90)
            }
        }
    }

    private var currentSpectrum: LTEBandSpectrum? {
        if let shownBand, let s = model.spectra[shownBand] { return s }
        return model.spectra.values.sorted { $0.band < $1.band }.first
    }

    private func bandChart(_ spectrum: LTEBandSpectrum) -> some View {
        let floor = spectrum.points.map(\.db).sorted().first ?? -100
        let carriers = model.cells.filter { $0.band == spectrum.band }
        return Chart {
            ForEach(carriers) { cell in
                RectangleMark(xStart: .value("von", cell.frequencyMHz - cell.bandwidthMHz * 0.45),
                              xEnd: .value("bis", cell.frequencyMHz + cell.bandwidthMHz * 0.45))
                    .foregroundStyle(.blue.opacity(0.08))
            }
            ForEach(spectrum.points) { p in
                LineMark(x: .value("MHz", p.mhz), y: .value("dB", p.db - floor))
                    .interpolationMethod(.linear)
            }
        }
        .chartXScale(domain: (spectrum.points.first?.mhz ?? 0)...(spectrum.points.last?.mhz ?? 1))
        .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
        .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Double.self) ?? 0, format: .number.precision(.fractionLength(0)))") } } }
        .overlay(alignment: .topTrailing) {
            Text("Band \(spectrum.band) – Pegel über Grund (dB)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Tabelle

    private static let byBand = ColumnSort<LTECell>("band") { (c: LTECell) -> Int? in c.band }
    private static let byEARFCN = ColumnSort<LTECell>("earfcn") { (c: LTECell) -> Int? in c.earfcn }
    private static let byPCI = ColumnSort<LTECell>("pci") { (c: LTECell) -> Int? in c.pci }
    private static let byBandwidth = ColumnSort<LTECell>("bw") { (c: LTECell) -> Double? in c.bandwidthMHz }
    private static let byRSRP = ColumnSort<LTECell>("rsrp") { (c: LTECell) -> Double? in c.measurement?.rsrpDBFS }
    private static let bySINR = ColumnSort<LTECell>("sinr") { (c: LTECell) -> Double? in c.measurement?.sinrDB }
    private static let byOperator = ColumnSort<LTECell>("op", text: { (c: LTECell) -> String? in c.sib1?.operatorName ?? c.sib1?.plmns.first?.text })
    private static let byTAC = ColumnSort<LTECell>("tac") { (c: LTECell) -> Int? in c.sib1?.tac }

    private var table: some View {
        Table(model.cells.sorted(by: order), selection: $selection, sortOrder: $order) {
            Group {
            TableColumn("Band", sortUsing: Self.byBand) { (c: LTECell) in Text("B\(c.band)").monospacedDigit() }.width(44)
            TableColumn("EARFCN", sortUsing: Self.byEARFCN) { (c: LTECell) in Text("\(c.earfcn)").monospacedDigit() }.width(58)
            TableColumn("MHz") { (c: LTECell) in Text(String(format: "%.1f", c.frequencyMHz)).monospacedDigit() }.width(58)
            TableColumn("PCI", sortUsing: Self.byPCI) { (c: LTECell) in Text("\(c.pci)").monospacedDigit() }.width(40)
            TableColumn("Bandbreite", sortUsing: Self.byBandwidth) { (c: LTECell) in
                Text("\(c.bandwidthMHz, format: .number.precision(.fractionLength(0...1))) MHz").monospacedDigit()
            }.width(62)
            TableColumn("Ant.") { (c: LTECell) in Text("\(c.mib.ports)").monospacedDigit() }.width(32)
            TableColumn("RSRP", sortUsing: Self.byRSRP) { (c: LTECell) in
                Text(c.measurement.map { String(format: "%.0f dBFS", $0.rsrpDBFS) } ?? "–").monospacedDigit()
            }.width(70)
            TableColumn("Qualität", sortUsing: Self.bySINR) { (c: LTECell) in quality(c) }.width(min: 90, ideal: 110)
            }
            Group {
            TableColumn("Betreiber", sortUsing: Self.byOperator) { (c: LTECell) in
                if let sib1 = c.sib1 {
                    Text(sib1.operatorName ?? sib1.plmns.first?.text ?? "?")
                } else {
                    Text("–").foregroundStyle(.secondary).help(c.sib1Note ?? "")
                }
            }.width(min: 70, ideal: 110)
            TableColumn("TAC", sortUsing: Self.byTAC) { (c: LTECell) in Text(c.sib1.map { "\($0.tac)" } ?? "–").monospacedDigit() }.width(54)
            TableColumn("Zell-ID") { (c: LTECell) in
                Text(c.sib1.map { "\($0.enbID) / \($0.localCellID)" } ?? "–").monospacedDigit()
                    .help(c.sib1.map { String(localized: "Cell Identity \($0.cellIdentity): eNB \($0.enbID), Sektor \($0.localCellID)") } ?? "")
            }.width(min: 80, ideal: 100)
            TableColumn("Gesehen") { (c: LTECell) in Text(c.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(70)
            }
        }
        .overlay {
            if model.cells.isEmpty {
                ContentUnavailableView {
                    Label(model.running ? "Suche läuft …" : "Noch keine Zellen", systemImage: "cellularbars")
                } description: {
                    Text(model.running
                         ? "Die App prüft Band für Band – das dauert je Band einige Sekunden."
                         : "„Suchlauf starten“ sucht Mobilfunk-Basisstationen in deiner Nähe. Du brauchst dafür eine Antenne für 700–2700 MHz.")
                } actions: {
                    if !model.running, session.hackRF != nil {
                        Button("Suchlauf starten") {
                            ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func quality(_ c: LTECell) -> some View {
        let sinr = c.measurement?.sinrDB
        let color: Color = sinr.map { $0 >= 13 ? .green : $0 >= 3 ? .orange : .red } ?? .secondary
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(c.measurement.map { String(format: "%.0f dB · %.0f dB", $0.sinrDB, $0.rsrqDB) } ?? "–").monospacedDigit()
        }
        .help("Störabstand (SINR, aus den Referenzsignalen) · RSRQ")
    }

    // MARK: Einzelheiten und Beobachten

    @ViewBuilder private var detail: some View {
        if let id = selection, let cell = model.cells.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("PCI \(cell.pci) · B\(cell.band) · \(String(format: "%.1f", cell.frequencyMHz)) MHz").font(.headline)
                        Spacer()
                        if model.observing == cell.id {
                            Button("Beobachten beenden") { model.stop() }
                        } else if let device = session.hackRF {
                            Button("Zelle beobachten") { model.observe(cell, on: device) }
                                .help("Misst die Zelle laufend – praktisch zum Ausrichten der Antenne.")
                        }
                    }
                    facts(cell)
                    if model.observing == cell.id || !model.history.isEmpty {
                        historyChart.frame(height: 160)
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView("Keine Zelle gewählt", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("Wähle eine Zelle in der Liste. Hier stehen dann ihre Kennungen; „Zelle beobachten“ zeigt den Pegel über die Zeit."))
        }
    }

    private func facts(_ cell: LTECell) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Zellkennung (PCI)", "\(cell.pci) = 3 · \(cell.pci / 3) + \(cell.pci % 3)")
            row("Bandbreite", String(localized: "\(cell.mib.nRB) Ressourcenblöcke (\(String(format: "%g", cell.bandwidthMHz)) MHz)"))
            row("Antennen", cell.mib.ports == 1 ? String(localized: "1 Sendeport") : String(localized: "\(cell.mib.ports) Sendeports"))
            row("Betriebsart", cell.extendedCP
                ? String(localized: "\(cell.tdd ? "TDD" : "FDD"), erweitertes Schutzintervall")
                : String(localized: "\(cell.tdd ? "TDD" : "FDD"), normales Schutzintervall"))
            row("PHICH", cell.mib.phichExtended
                ? String(localized: "erweitert, Ng = \(cell.mib.phichResource.text)")
                : String(localized: "normal, Ng = \(cell.mib.phichResource.text)"))
            if let m = cell.measurement {
                row("RSRP", String(format: String(localized: "%.1f dBFS je Unterträger"), m.rsrpDBFS))
                row("RSRQ / SINR", String(format: "%.1f dB / %.1f dB", m.rsrqDB, m.sinrDB))
            }
            row("Frequenzablage", String(format: "%+.0f Hz (%+.2f ppm)", cell.cfoHz, cell.cfoHz / cell.frequencyMHz))
            if let sib1 = cell.sib1 {
                row("Netz", sib1.plmns.map { "\($0.text)\($0.operatorName.map { " (\($0))" } ?? "")" }.joined(separator: ", "))
                row("Tracking Area", "\(sib1.tac)")
                row("Cell Identity", String(localized: "\(sib1.cellIdentity) → eNB \(sib1.enbID), Zelle \(sib1.localCellID)"))
                row("Band laut SIB1", "\(sib1.freqBandIndicator)")
                row("Zugang", sib1.cellBarred ? String(localized: "gesperrt") : String(localized: "offen"))
            } else {
                row("SIB1", cell.sib1Note ?? "–")
            }
        }
        .font(.callout)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var historyChart: some View {
        Chart {
            ForEach(model.history) { s in
                if let v = s.rsrpDBFS {
                    LineMark(x: .value("Zeit", s.date), y: .value("dB", v), series: .value("Größe", "RSRP (dBFS)"))
                        .foregroundStyle(by: .value("Größe", "RSRP (dBFS)"))
                }
                if let v = s.sinrDB {
                    LineMark(x: .value("Zeit", s.date), y: .value("dB", v), series: .value("Größe", "SINR (dB)"))
                        .foregroundStyle(by: .value("Größe", "SINR (dB)"))
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .overlay {
            if model.history.isEmpty { Text("Warte auf die erste Messung …").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Bedienfeld

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop() } else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    .help("Startet den Suchlauf über die gewählten Bänder.")
                    Spacer()
                    Button("Leeren") { model.clear(); selection = nil }.disabled(model.running)
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Bänder") {
                ForEach(LTEBand.germany) { band in
                    Toggle(isOn: Binding(get: { model.bands.contains(band.number) },
                                         set: { on in if on { model.bands.insert(band.number) } else { model.bands.remove(band.number) } })) {
                        if band.number == 28 {
                            Text("B\(band.number) · \(band.name) (selten genutzt)")
                        } else {
                            Text(verbatim: "B\(band.number) · \(band.name)")
                        }
                    }
                    .disabled(model.running)
                }
                Toggle("Netzbetreiber lesen (SIB1)", isOn: $model.readSIB1)
                    .help("Liest nach dem Suchlauf je Zelle Netzbetreiber, Tracking Area und Zellkennung. Dauert je Zelle etwa eine Sekunde.")
            }
            Section("Einzelne Frequenz") {
                HStack {
                    TextField("MHz oder EARFCN", text: $frequencyText)
                        .onSubmit(checkFrequency)
                    Button("Prüfen", action: checkFrequency).disabled(model.running || parsedFrequency == nil)
                }
                Text("Zum Beispiel 806 (MHz) oder 6300 (EARFCN). Hilft, wenn der Suchlauf eine Zelle übersieht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Zellen", value: "\(model.cells.count)")
                LabeledContent("Mit Netzbetreiber", value: "\(model.cells.filter { $0.sib1 != nil }.count)")
                if model.clipped >= 0.005 {
                    Text(String(format: String(localized: "Übersteuert (%.1f %% am Anschlag) – senk die Verstärkung."), model.clipped * 100))
                        .font(.caption).foregroundStyle(.orange)
                }
                if let ppm = model.ppm {
                    // Ablage = −ε·f: läuft der Quarz zu schnell (ε > 0), erscheint die Zelle zu tief.
                    LabeledContent("Quarz-Restfehler", value: String(format: "%+.2f ppm", -ppm))
                        .help("Gemessen an den gefundenen Zellen, deren Takt GPS-genau ist. Ab etwa 1 ppm lohnt es, den Wert in den Einstellungen (Quarzkorrektur) nachzutragen.")
                }
            }
            if model.spectra.count > 1 {
                Section(PanelSection.anzeige) {
                    Picker("Bandübersicht", selection: Binding(get: { shownBand ?? currentSpectrum?.band ?? 0 }, set: { shownBand = $0 })) {
                        ForEach(model.spectra.keys.sorted(), id: \.self) { Text("B\($0)").tag($0) }
                    }
                }
            }
            Section(PanelSection.hinweis) {
                Text("Die Teleskopantenne reicht für 800/900 MHz; für 1800–2600 MHz ist eine kurze Mobilfunkantenne besser. Am Fenster findest du deutlich mehr Zellen.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Gelesen werden nur die öffentlichen Kennungen der Basisstationen – keine Nutzerdaten, keine Telefone.")
                    .help("Synchronisation, MIB und SIB1: Zellkennung, Bandbreite, Netzbetreiber, Tracking Area.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// MHz (mit Komma/Punkt) oder EARFCN (ganze Zahl ab 100 außerhalb der Bandgrenzen).
    private var parsedFrequency: Double? {
        let text = frequencyText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(text) else { return nil }
        if LTEBand.locate(mhz: value) != nil { return value }
        if value == value.rounded(), let band = LTEBand.germany.first(where: { $0.contains(earfcn: Int(value)) }) {
            return band.frequencyMHz(earfcn: Int(value))
        }
        return nil
    }

    private func checkFrequency() {
        guard let mhz = parsedFrequency, !model.running, let device = session.hackRF else { return }
        model.check(frequencyMHz: mhz, on: device)
    }
}
