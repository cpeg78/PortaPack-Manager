import SwiftUI

struct RadioView: View {
    @Environment(DeviceSession.self) private var session
    /// Geteilt mit dem Fernzugriff (`RemoteHub.radio`).
    @Bindable private var model = RemoteHub.shared.radio
    /// Gemerkte Frequenzen (gemeinsamer Frequenzspeicher, löst die Radio-Favoriten ab).
    private var memory: FrequencyMemory { FrequencyMemory.shared }
    @AppStorage("frequencyMemoryShowAll") private var showAllMemory = false
    @State private var deletingMemory: DeleteConfirmation?
    @State private var editingMemory: FrequencyMemoryEntry?
    @AppStorage("radioStationOrder") private var stationOrder = StationOrder.level

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "radio", text: "Die App spielt das Radio über die Lautsprecher des Mac ab. Dafür muss das PortaPack im HackRF-Modus laufen. Ohne HackRF-Modus hörst du über den Kopfhörerausgang des PortaPack (App „Audio“).")
        } else {
            // Links (Hauptbereich) Abstimmung, Senderdaten und Senderliste, rechts das
            // Bedienfeld wie auf allen Seiten. Keine Split-Ansicht im Hauptbereich –
            // verschachtelte Splits stürzten anderswo ab (Bedienung.md).
            ControlsSplit(width: 320, issue: model.error) {
                VStack(spacing: 0) {
                    tuningHeader
                    Divider()
                    stationList
                }
                .frame(minWidth: 380)
            } controls: {
                controls
            }
            .task {
                if takeRadioRequest() { return }
                if AppNavigation.shared.takeAutoStart(.radio), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
            }
            .onChange(of: AppNavigation.shared.radioRequest) { _, request in if request != nil { _ = takeRadioRequest() } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    /// Große Frequenzanzeige mit Schrittknöpfen, Pegel und – bei UKW – den RDS-Daten.
    private var tuningHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                FrequencyDial(mhz: model.frequencyMHz, decimals: dialDecimals, stepMHz: model.stepKHz / 1000) { mhz in
                    model.tune(to: mhz)
                }
                Text("MHz").font(.title2).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    SignalMeter(db: model.signalDB)
                        .frame(width: 160, height: 10)
                    Text("\(model.signalDB, format: .number.precision(.fractionLength(0))) dBFS").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button { model.step(-1) } label: { Image(systemName: "backward.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Einen Schritt tiefer (←)")
                    .accessibilityLabel("Einen Schritt tiefer (←)")
                Button { model.step(1) } label: { Image(systemName: "forward.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Einen Schritt höher (→)")
                    .accessibilityLabel("Einen Schritt höher (→)")
                Button { model.step(-10) } label: { EmptyView() }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .frame(width: 0).opacity(0)
                Button { model.step(10) } label: { EmptyView() }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .frame(width: 0).opacity(0)
                Button { toggleFavorite() } label: {
                    Image(systemName: memory.entry(atMHz: model.frequencyMHz, page: .radio) != nil ? "star.fill" : "star")
                }
                .help("Im Frequenzspeicher merken")
                .accessibilityLabel("Im Frequenzspeicher merken")
                Spacer()
                Image(systemName: "speaker.wave.2")
                Slider(value: $model.volume, in: 0...1).frame(width: 140)
            }
            Text("Ziffern mit Mausrad oder Klick verstellen · ← → ein Schritt · ↑ ↓ zehn Schritte · Leertaste: Abspielen/Stopp")
                .font(.caption).foregroundStyle(.secondary)
            if model.running && model.mode == .wfm {
                Divider()
                RDSPanel(rds: model.rds, synced: model.rdsSynced, stereo: model.pilotLocked && model.stereo)
            }
        }
        .padding()
    }

    /// Bedienfeld nach dem Seitenschema: Abspielen/Stopp → Frequenz, Betriebsart,
    /// Schritt → Empfang → Status → Suchlauf → Hinweis.
    private var controls: some View {
        Form {
            Section {
                Button {
                    if model.running { model.stop() }
                    else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                } label: {
                    Label(model.running ? "Stopp" : "Abspielen", systemImage: model.running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .startStopShortcut()
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Frequenz") {
                LabeledContent("MHz") {
                    FrequencyField(mhz: model.frequencyMHz, range: 1.24...6000, decimals: fieldDecimals, width: 110) {
                        model.tune(to: $0)
                    }
                }
                Picker("Betriebsart", selection: $model.mode) {
                    ForEach(RadioMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: model.mode) { _, mode in model.stepKHz = mode.defaultStepKHz }
                if !model.mode.bandwidthOptionsHz.isEmpty {
                    Picker("Filter", selection: $model.bandwidthHz) {
                        ForEach(model.mode.bandwidthOptionsHz, id: \.self) { Text(RadioUnits.hertz($0)).tag($0) }
                    }
                    .help(model.mode == .nfm ? String(localized: "Kanalraster des Funkdienstes: 12,5 kHz für PMR446, Freenet und Amateurfunk, 25 kHz für Seefunk. Schmaler dämpft Nachbarkanäle besser.")
                                             : String(localized: "Breite des Empfangsfilters. Schmaler dämpft Nachbarn und Rauschen, breiter klingt voller."))
                }
                Picker("Schritt", selection: $model.stepKHz) {
                    ForEach(stepOptions, id: \.self) { Text(RadioUnits.hertz($0 * 1000)).tag($0) }
                }
                if model.mode == .wfm {
                    Toggle("Stereo", isOn: $model.stereo)
                        .help("Bei schwachen Sendern ist Mono rauschärmer.")
                } else if model.mode.usesSquelch {
                    LabeledContent(model.squelchDB > 0 ? "Rauschsperre \(Int(model.squelchDB)) dB" : "Rauschsperre aus") {
                        Slider(value: $model.squelchDB, in: 0...20, step: 1)
                    }
                } else {
                    if model.mode == .cw {
                        LabeledContent("Tonhöhe \(Int(model.cwPitchHz)) Hz") {
                            Slider(value: $model.cwPitchHz, in: RadioModel.cwPitchRange, step: 10)
                        }
                        .help("Ein genau abgestimmter Morsesender klingt in dieser Tonhöhe (Überlagerungston, BFO).")
                    }
                    Text("Die Lautstärke regelt sich selbst (AGC). Feinabstimmung: kleinste Ziffern der Frequenz mit dem Mausrad.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Menu("Amateurfunk-Vorlagen") {
                    ForEach(RadioPresets.amateur) { preset in
                        Button(presetTitle(preset)) { apply(preset) }
                    }
                }
                if model.frequencyMHz < RadioPresets.shortwaveLimitMHz {
                    Label("Kurzwelle: Der HackRF empfängt erst ab 1 MHz und unter 30 MHz nur schwach. Deutlich besser geht es mit einem Upconverter (z. B. Ham It Up) oder einer langen Drahtantenne statt der Teleskopantenne.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Signal", value: model.signalDB.formatted(.number.precision(.fractionLength(0))) + " dBFS")
                    .monospacedDigit()
                if model.running, model.mode.usesSquelch, model.squelchDB > 0 {
                    Label(model.squelchOpen ? "Rauschsperre offen – Signal \(Int(model.channelAboveFloorDB.rounded())) dB über dem Rauschen"
                                            : "Rauschsperre zu – Kanal \(Int(model.channelAboveFloorDB.rounded())) dB über dem Rauschen",
                          systemImage: model.squelchOpen ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.caption).foregroundStyle(model.squelchOpen ? .green : .secondary)
                }
                if model.running && model.mode == .wfm {
                    LabeledContent("RDS", value: model.rdsSynced ? String(localized: "empfangen") : String(localized: "noch nichts"))
                    LabeledContent("Stereo", value: model.pilotLocked && model.stereo ? String(localized: "ja") : String(localized: "nein"))
                }
            }
            Section("Schnellwahl mit Suchlauf") {
                ForEach(ScanBands.all) { band in
                    Button {
                        startScan(band)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(band.title)
                            Text(verbatim: "\(band.startMHz.formatted())–\(band.endMHz.formatted()) MHz · \(band.mode.shortTitle)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.scannedBand == band ? .accentColor : nil)
                    .disabled(model.scanning)
                }
                if model.scanning {
                    ProgressView(value: model.scanProgress)
                    HStack {
                        Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Abbrechen") { model.cancelScan() }
                    }
                } else if !model.scanStatus.isEmpty {
                    HStack {
                        Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let band = model.scannedBand {
                            Button("Erneut suchen") { startScan(band) }
                        }
                    }
                }
            }
            AudioRecordingSection(host: model, source: AudioRecordingStore.radioPrefix)
            Section(PanelSection.hinweis) {
                SettingsHint(.device, String(localized: "Quarzkorrektur: \(model.correctionPPM.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))) ppm"))
                Text("Für starke UKW-Sender reicht die mitgelieferte Teleskopantenne.")
                    .font(.caption).foregroundStyle(.secondary)
                LegalNotice(text: "Hören darfst du Rundfunk, Amateur- und Jedermannfunk. Zufällig Mitgehörtes aus anderen Funkdiensten darfst du weder aufzeichnen noch weitergeben (§ 5 TDDDG).")
            }
        }
        .formStyle(.grouped)
    }

    enum StationOrder: String, CaseIterable, Identifiable {
        case level, name, frequency
        var id: Self { self }
        var title: String {
            switch self {
            case .level: String(localized: "Stärke")
            case .name: String(localized: "Name")
            case .frequency: String(localized: "Frequenz")
            }
        }
    }

    /// Senderliste links wie bei DAB+: Favoriten und Ergebnis des letzten Suchlaufs.
    private var stationList: some View {
        let named = model.scannedBand?.mode == .wfm
        let found = model.stations.sorted { a, b in
            switch stationOrder {
            case .level: return a.levelDB > b.levelDB
            case .frequency: return a.mhz < b.mhz
            case .name:
                // Ohne RDS-Namen ans Ende, dort nach Frequenz.
                let x = named ? model.stationName(at: a.mhz) : nil, y = named ? model.stationName(at: b.mhz) : nil
                switch (x, y) {
                case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.mhz < b.mhz
                }
            }
        }
        return List {
            if model.stations.isEmpty && favorites.isEmpty && !showAllMemory {
                Text("Noch keine Sender – klicke rechts unter „Schnellwahl mit Suchlauf“ auf ein Band.").foregroundStyle(.secondary)
            }
            if !favorites.isEmpty || showAllMemory {
                Section {
                    ListGroupHeader {
                        HStack {
                            Text("Frequenzspeicher")
                            Spacer()
                            Picker("Anzeigen", selection: $showAllMemory) {
                                Text("Radio").tag(false)
                                Text("Alle").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    ForEach(favorites) { favorite in
                        let mode = favorite.radioMode ?? FrequencyMemory.suggestedRadioMode(mhz: favorite.mhz)
                        stationRow(mhz: favorite.mhz,
                                   detail: "\(format(favorite.mhz)) MHz · " + (favorite.modeTitle == nil
                                                                      ? [favorite.detail(withFrequency: false), mode.title].filter { !$0.isEmpty }.joined(separator: " · ")
                                                                      : favorite.detail(withFrequency: false)),
                                   named: mode == .wfm, favorite: favorite)
                            .contextMenu {
                                Button("Bearbeiten …") { editingMemory = favorite }
                                Button("Löschen …", role: .destructive) { deletingMemory = FrequencyMemoryActions.confirmDelete([favorite]) }
                            }
                    }
                }
            }
            if !found.isEmpty {
                Section {
                    ListGroupHeader {
                        Text(model.scannedBand.map { "\($0.title) (\(found.count))" } ?? String(localized: "Gefunden (\(found.count))"))
                    }
                    Picker("Sortierung", selection: $stationOrder) {
                        ForEach(StationOrder.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ForEach(found, id: \.mhz) { station in
                        stationRow(mhz: station.mhz,
                                   detail: "\(format(station.mhz)) MHz · +" + station.levelDB.formatted(.number.precision(.fractionLength(0))) + " dB"
                                       + (station.possiblySpur ? " · " + String(localized: "Störlinie?") : ""),
                                   named: named)
                    }
                }
            }
        }
        .sheet(item: $editingMemory) { entry in FrequencyMemoryEditor(entry: entry) { editingMemory = nil } }
        .deleteConfirmation($deletingMemory)
    }

    private func stationRow(mhz: Double, detail: String, named: Bool, favorite: FrequencyMemoryEntry? = nil) -> some View {
        let playing = model.running && abs(mhz - model.frequencyMHz) < 0.0005
        let name = favorite.flatMap { $0.name.isEmpty ? nil : $0.name } ?? (named ? model.stationName(at: mhz) : nil)
        return Button {
            if let favorite {
                let mode = favorite.radioMode ?? FrequencyMemory.suggestedRadioMode(mhz: favorite.mhz)
                model.select(mode: mode, bandwidthHz: favorite.bandwidthHz.map(Double.init))
                model.stepKHz = favorite.stepKHz ?? mode.defaultStepKHz
            }
            model.tune(to: mhz)
            if !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
        } label: {
            HStack {
                Image(systemName: playing ? "speaker.wave.2.fill" : "radio")
                    .foregroundStyle(playing ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name ?? "\(format(mhz)) MHz").fontWeight(playing ? .semibold : .regular)
                    Text(name == nil ? detail.replacingOccurrences(of: "\(format(mhz)) MHz · ", with: "") : detail)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func startScan(_ band: ScanBand) {
        if model.running { model.scan(band); return }
        ReceiverStore.shared.requestStart(model, session: session) { device in
            model.mode = band.mode
            model.start(on: device)
            model.scan(band)
        }
    }

    /// Einträge fürs Radio (bzw. alle), nach Frequenz.
    private var favorites: [FrequencyMemoryEntry] {
        memory.entries(for: .radio, all: showAllMemory).sorted { $0.frequencyHz < $1.frequencyHz }
    }

    /// Stern: merkt die Frequenz bzw. fragt vor dem Löschen des Eintrags.
    private func toggleFavorite() {
        if let existing = memory.entry(atMHz: model.frequencyMHz, page: .radio) {
            deletingMemory = FrequencyMemoryActions.confirmDelete([existing])
            return
        }
        let current = RadioFavorite.rounded(model.frequencyMHz)
        memory.add(RemoteRadioAPI.memoryEntry(current, mode: model.mode, stepKHz: model.stepKHz, scannedBand: model.scannedBand, bandwidthHz: model.bandwidthHz,
                                              stationName: model.mode == .wfm ? model.stationName(at: current) : nil))
    }

    /// Frequenz aus einer anderen Seite (Belegungsmonitor) oder einem Link
    /// übernehmen und abspielen.
    private func takeRadioRequest() -> Bool {
        guard let request = AppNavigation.shared.takeRadioRequest() else { return false }
        if model.mode != request.mode {
            model.mode = request.mode
            model.stepKHz = request.mode.defaultStepKHz
        }
        model.tune(to: request.mhz)
        if !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
        return true
    }

    private func format(_ mhz: Double) -> String {
        model.mode == .wfm ? String(format: "%.2f", mhz) : String(format: model.mode.isSingleSideband ? "%.5f" : "%.4f", mhz)
    }

    /// Nachkommastellen (MHz): UKW 1 kHz, SSB/CW 10 Hz (Feinabstimmung mit dem Mausrad), sonst 100 Hz.
    private var dialDecimals: Int { model.mode == .wfm ? 3 : model.mode.isSingleSideband ? 5 : 4 }
    private var fieldDecimals: Int { model.mode == .wfm ? 2 : model.mode.isSingleSideband ? 5 : 4 }

    /// Schritte der Betriebsart, dazu der eingestellte (etwa aus einem Favoriten).
    private var stepOptions: [Double] {
        let options = model.mode.stepOptionsKHz
        return options.contains(model.stepKHz) ? options : (options + [model.stepKHz]).sorted()
    }

    private func presetTitle(_ preset: RadioPreset) -> String {
        let mhz = preset.mhz.formatted(.number.precision(.fractionLength(3)))
        return preset.calling
            ? String(localized: "\(preset.band) \(preset.mode.shortTitle) – \(mhz) MHz (Anruf)")
            : "\(preset.band) \(preset.mode.shortTitle) – \(mhz) MHz"
    }

    private func apply(_ preset: RadioPreset) {
        model.select(mode: preset.mode)
        model.tune(to: preset.mhz)
        if !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
    }
}

/// Sendername, Radiotext und weitere RDS-Angaben.
private struct RDSPanel: View {
    let rds: RDSInfo
    let synced: Bool
    let stereo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(rds.programServiceText.isEmpty ? "—" : rds.programServiceText)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                Spacer()
                badge("STEREO", active: stereo)
                badge("RDS", active: synced)
                badge("TP", active: rds.trafficProgram)
                badge("TA", active: rds.trafficAnnouncement)
            }
            // Jede Zeile ist immer da und einzeilig: sonst wächst und schrumpft der
            // Kopf, sobald RDS neu gelesen wird, und die Senderliste darunter springt.
            Group {
                if !rds.radioTextString.isEmpty {
                    Text(rds.radioTextString).textSelection(.enabled).help(rds.radioTextString)
                } else if !synced && rds.groups == 0 {
                    Text("Noch keine Senderdaten (RDS) – bei schwachem Empfang dauert es länger oder klappt gar nicht.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: " ")
                }
            }
            .lineLimit(1).truncationMode(.tail)
            HStack(spacing: 14) {
                Text(verbatim: " ").frame(width: 0)
                if let name = rds.programTypeName { Text(name) }
                if let pi = rds.pi { Text(String(format: "PI %04X", pi)).monospacedDigit() }
                if let clock = rds.clock {
                    Text("Senderzeit \(clock.formatted(date: .omitted, time: .shortened))")
                }
                if rds.blocksGood + rds.blocksBad > 0 {
                    Text("Blöcke \(rds.blockQuality.formatted(.percent.precision(.fractionLength(0)))) fehlerfrei").monospacedDigit()
                }
            }
            .lineLimit(1)
            .font(.caption).foregroundStyle(.secondary)
            Group {
                if rds.alternativeFrequencies.isEmpty {
                    Text(verbatim: " ")
                } else {
                    let list = rds.alternativeFrequencies.sorted().map { $0.formatted(.number.precision(.fractionLength(1))) }.joined(separator: " · ")
                    Text("Auch auf: \(list)").help(list)
                }
            }
            .lineLimit(1).truncationMode(.tail)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(active ? .primary : .tertiary)
    }
}

/// Balkenanzeige für die Signalstärke (−80 … −10 dBFS).
private struct SignalMeter: View {
    let db: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, (db + 80) / 70)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * fraction)
            }
        }
    }
}
