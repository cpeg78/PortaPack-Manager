import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecorderView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.recorder
    @State private var selection: IQRecording.ID?
    @State private var order: [ColumnSort<IQRecording>] = []
    @State private var adsbOrder: [ColumnSort<Aircraft>] = []
    @State private var tvOrder: [ColumnSort<TSService>] = []
    @State private var dabOrder: [ColumnSort<DABStoredEnsemble.Service>] = []
    @State private var pendingDelete: DeleteConfirmation?

    var body: some View {
        ControlsSplit(width: 300, issue: model.error) {
            if !hasHackRF, model.recordings.isEmpty {
                // Ohne Gerät und ohne Aufnahmen die einheitliche Sperre; mit
                // Aufnahmen bleibt die Seite für die Offline-Auswertung offen.
                HackRFRequiredView(systemImage: "waveform.badge.plus",
                                   text: "Zum Aufnehmen muss das PortaPack im HackRF-Modus laufen. Vorhandene Aufnahmen wertest du auch ohne Gerät aus.")
            } else {
                VSplitView {
                    fileList.frame(minHeight: 120)
                    playback.frame(minHeight: 100)
                }
                .frame(minWidth: 460)
            }
        } controls: {
            controls
        }
        .onAppear { model.refresh() }
        // Nur die Wiedergabe endet beim Verlassen – eine laufende Aufnahme läuft weiter.
        .onDisappear { model.stopPlayback() }
    }

    private var fileList: some View {
        Table(model.recordings.sorted(by: order), selection: $selection, sortOrder: $order) {
            TableColumn("Aufnahme", sortUsing: ColumnSort("datum") { $0.date }) { rec in
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.name).font(.body)
                    HStack(spacing: 4) {
                        Text(rec.date, style: .date)
                        if rec.sigmf == true { Text(verbatim: "· SigMF") }
                        if let source = rec.importedFrom { Text("· importiert aus \(source)").lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            TableColumn("Mitte", sortUsing: ColumnSort("mitte") { $0.centerMHz }) { rec in Text(String(format: "%.3f MHz", rec.centerMHz)).monospacedDigit() }.width(100)
            TableColumn("Rate", sortUsing: ColumnSort("rate") { $0.sampleRateMHz }) { rec in Text(String(format: "%.1f MS/s", rec.sampleRateMHz)).monospacedDigit() }.width(80)
            TableColumn("Dauer", sortUsing: ColumnSort("dauer") { $0.duration }) { rec in Text(String(format: "%.1f s", rec.duration)).monospacedDigit() }.width(70)
            TableColumn("Größe", sortUsing: ColumnSort("groesse") { $0.byteCount }) { rec in Text(ByteCountFormatter.string(fromByteCount: Int64(rec.byteCount), countStyle: .file)) }.width(90)
        }
        .contextMenu(forSelectionType: IQRecording.ID.self) { ids in
            if let rec = model.recordings.first(where: { ids.contains($0.id) }) {
                Button("Abspielen & auswerten") { model.play(rec) }
                Button("Als SigMF exportieren …") { exportSigMF(rec) }
                    .disabled(model.transferTitle != nil)
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([IQStore.dataURL(for: rec)])
                }
                Button("Löschen …", role: .destructive) { confirmDelete(rec) }
            }
        }
        .onDeleteCommand {
            if let rec = model.recordings.first(where: { $0.id == selection }) { confirmDelete(rec) }
        }
        .deleteConfirmation($pendingDelete)
        .overlay {
            if model.recordings.isEmpty {
                ContentUnavailableView("Keine Aufnahmen", systemImage: "waveform.badge.plus",
                    description: Text("Nimm rechts ein Signal auf. Hier wertest du die Aufnahme später beliebig oft aus – auch ohne Gerät."))
            }
        }
    }

    private static let sigmfMetaType = UTType(filenameExtension: SigMF.metaExtension) ?? .json
    private static let sigmfDataType = UTType(filenameExtension: SigMF.dataExtension) ?? .data

    private func exportSigMF(_ rec: IQRecording) {
        Task {
            guard let url = await SaveSheet.url(name: rec.name + "." + SigMF.metaExtension, types: [Self.sigmfMetaType],
                                                message: String(localized: "Daneben entsteht die Datei mit den Abtastwerten (.sigmf-data).")) else { return }
            model.exportSigMF(rec, to: url)
        }
    }

    private func importSigMF() {
        Task {
            guard let url = await SaveSheet.open(types: [Self.sigmfMetaType, Self.sigmfDataType],
                                                 message: String(localized: "Wähle die .sigmf-meta-Datei einer SigMF-Aufnahme. Die .sigmf-data-Datei muss daneben liegen.")).first
            else { return }
            model.importSigMF(from: url)
        }
    }

    private func confirmDelete(_ rec: IQRecording) {
        pendingDelete = DeleteConfirmation(
            title: String(localized: "Aufnahme „\(rec.name)“ löschen?"),
            message: String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(rec.byteCount), countStyle: .file)) werden von diesem Mac gelöscht.")) {
            if selection == rec.id { selection = nil }
            model.delete(rec)
        }
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Wiedergabe & Auswertung").font(.headline)
                Spacer()
                if model.playing {
                    ProgressView(value: model.progress).frame(width: 120)
                    Button("Stopp") { model.stopPlayback() }
                }
            }
            if let warning = model.playbackWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            switch model.analysis {
            case .spectrum:
                if model.playbackSpectrum.isEmpty {
                    placeholder("Spiel eine Aufnahme ab – hier erscheint ihr gemitteltes Spektrum.")
                } else {
                    SpectrumCurve(data: model.playbackSpectrum).frame(minHeight: 160)
                }
            case .adsb:
                if model.adsbResults.isEmpty {
                    placeholder("Nimm mit der Vorlage „ADS-B“ auf und spiel die Aufnahme ab: Die Flugzeuge erscheinen hier.")
                } else {
                    Table(model.adsbResults.sorted(by: adsbOrder), sortOrder: $adsbOrder) {
                        TableColumn("ICAO", sortUsing: ColumnSort("icao", text: { $0.icaoHex })) { Text($0.icaoHex).monospaced() }
                        TableColumn("Kennung", sortUsing: ColumnSort("kennung", text: { $0.callsign })) { Text($0.callsign ?? "–") }
                        TableColumn("Position") { p in
                            Text(p.latitude != nil ? String(format: "%.3f, %.3f", p.latitude!, p.longitude!) : "–")
                                .font(.caption.monospacedDigit())
                        }
                        TableColumn("Nachrichten", sortUsing: ColumnSort("msg") { $0.messages }) { Text("\($0.messages)") }
                    }
                }
            case .gps:
                if model.gpsStatus?.channels.isEmpty ?? true {
                    placeholder("Nimm mit der Vorlage „GPS“ mindestens 40 Sekunden auf und spiel die Aufnahme ab: Satelliten und Position erscheinen hier.")
                } else {
                    if let status = model.gpsStatus {
                        if let sol = status.solution {
                            Text(String(format: String(localized: "Position %.6f°, %.6f°, Höhe %.0f m · ± %.0f m · %d Satelliten"),
                                        sol.latitude, sol.longitude, sol.height, sol.horizontalAccuracy, sol.satellites.count))
                                .font(.callout.monospacedDigit()).textSelection(.enabled)
                            if let utc = status.utc {
                                Text("Zeit (UTC): \(utc.formatted(.dateTime.day().month().year().hour().minute().second()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Noch keine Position: Bahndaten von \(status.ephemerisCount) Satelliten, nötig sind mindestens 4. Nimm dafür mindestens 40 Sekunden auf.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Table(model.gpsStatus?.channels ?? []) {
                        TableColumn("PRN") { Text("\($0.prn)") }
                        TableColumn("Zustand") { Text($0.state.title) }
                        TableColumn("C/N₀") { Text(String(format: "%.0f dB-Hz", $0.cn0)).monospacedDigit() }
                        TableColumn("Doppler") { Text(String(format: "%+.0f Hz", $0.dopplerHz)).monospacedDigit() }
                    }
                }
            case .tv:
                if let result = model.tvResult {
                    tvResult(result)
                } else {
                    placeholder("Nimm mit der Vorlage „DVB-T2-Kanal“ auf und spiel die Aufnahme ab: Sender und Empfangsqualität erscheinen hier.")
                }
            case .dab:
                if let result = model.dabResult {
                    dabResult(result)
                } else {
                    placeholder("Nimm mit der Vorlage „DAB-Block“ auf und spiel die Aufnahme ab: Ensemble und Sender erscheinen hier.")
                }
            case .zigbee:
                if let result = model.zigbeeResult {
                    zigbeeResult(result)
                } else {
                    placeholder("Nimm mit der Vorlage „Zigbee-Kanal“ auf und spiel die Aufnahme ab: Rahmen und Geräte erscheinen hier, mit hinterlegtem Schlüssel auch entschlüsselt.")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Ergebnis Zigbee/Thread

    private func zigbeeResult(_ r: ZigbeeOfflineResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kanal \(r.channel ?? 0) · \(r.frames) Rahmen (\(r.crcErrors) Prüfsummenfehler) · \(r.decrypted) entschlüsselt · \(r.threadFrames) Thread · \(r.nodes.count) Geräte")
                .font(.callout.monospacedDigit())
            Table(r.lines) {
                TableColumn("Zeit") { (l: ZigbeeOfflineResult.Line) in Text(String(format: "%.3f s", l.time)).monospacedDigit() }.width(70)
                TableColumn("Von") { (l: ZigbeeOfflineResult.Line) in Text(l.from).font(.caption.monospaced()) }.width(70)
                TableColumn("An") { (l: ZigbeeOfflineResult.Line) in Text(l.to).font(.caption.monospaced()) }.width(70)
                TableColumn("Inhalt") { (l: ZigbeeOfflineResult.Line) in
                    HStack(spacing: 4) {
                        if l.encrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        Text(l.summary).lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 200)
        }
    }

    // MARK: Ergebnisse Fernsehen und DAB

    private func tvResult(_ r: TVOfflineResult) -> some View {
        let s = r.status
        return VStack(alignment: .leading, spacing: 8) {
            if !s.locked && s.frames == 0 {
                Label(s.message ?? s.stage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                resultRow("Kanal", r.channel.map { "\($0.name) (\($0.megahertz) MHz)" } ?? "–")
                resultRow("Betriebsart", r.modeDescription.isEmpty ? "–" : r.modeDescription)
                resultRow("Daten", r.plpDescription ?? "–")
                resultRow("Störabstand", s.frames == 0 ? "–" : String(format: "%.1f dB", s.snr)
                          + (r.requiredSNR.map { String(format: String(localized: " (nötig ≈ %.1f dB)"), $0) } ?? ""))
                resultRow("Ablagen", String(format: "%+.0f Hz · %+.2f ppm", s.frequencyOffsetHz, s.sampleRateOffsetPPM))
                resultRow("T2-Rahmen", "\(s.frames)")
                resultRow("FEC-Blöcke", blockText(good: s.blocksGood, bad: s.blocksBad))
                resultRow("BBFRAMEs / TS-Pakete", "\(s.bbFramesGood) / \(s.packets)")
                if let pre = s.pre {
                    resultRow("Netz", (r.networkName.isEmpty ? "" : r.networkName + " · ")
                              + String(format: String(localized: "Netz-ID 0x%04X · Zelle 0x%04X"), pre.networkID, pre.cellID))
                }
            }
            .font(.callout)
            if !r.services.isEmpty {
                Table(r.services.sorted(by: tvOrder), sortOrder: $tvOrder) {
                    TableColumn("Dienst", sortUsing: ColumnSort("dienst", text: { $0.name })) { Text($0.name.isEmpty ? "Dienst \($0.id)" : $0.name) }
                    TableColumn("Anbieter", sortUsing: ColumnSort("anbieter", text: { $0.provider })) { Text($0.provider) }
                    TableColumn("Art") { Text($0.typeName) }
                    TableColumn("Verschlüsselt") { Text($0.scrambled ? "ja" : "nein") }.width(90)
                }
            } else if s.blocksGood == 0 && s.frames > 0 {
                Text("Kein FEC-Block fehlerfrei – zu wenig Störabstand für diese Betriebsart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func dabResult(_ r: DABOfflineResult) -> some View {
        let s = r.status
        return VStack(alignment: .leading, spacing: 8) {
            if s.framesDecoded == 0 {
                Label("Kein DAB-Signal gefunden.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                resultRow("Block", r.channel.map { String(format: "%@ (%.3f MHz)", $0.name, $0.megahertz) } ?? "–")
                resultRow("Ensemble", s.ensemble.label.isEmpty ? "–" : s.ensemble.label)
                resultRow("Störabstand", s.framesDecoded == 0 ? "–" : String(format: "%.1f dB", s.snr))
                resultRow("FIC", String(format: String(localized: "%.0f %% gültige FIBs · %d Rahmen"), s.ficQuality * 100, s.framesDecoded))
                resultRow("Frequenzablage", String(format: "%+.0f Hz", s.frequencyOffset))
            }
            .font(.callout)
            if !r.services.isEmpty {
                Table(r.services.sorted(by: dabOrder), sortOrder: $dabOrder) {
                    TableColumn("Dienst", sortUsing: ColumnSort("dienst", text: { $0.label })) { Text($0.label.isEmpty ? String(format: "0x%04X", $0.id) : $0.label) }
                    TableColumn("Art") { Text($0.kind.title) }.width(60)
                    TableColumn("Bitrate", sortUsing: ColumnSort("bitrate") { $0.bitrate }) { Text("\($0.bitrate) kbit/s").monospacedDigit() }.width(80)
                }
            }
        }
    }

    private func resultRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func blockText(good: Int, bad: Int) -> String {
        let total = good + bad
        guard total > 0 else { return "–" }
        return String(format: String(localized: "%d gültig, %d fehlerhaft (%.0f %%)"), good, bad, 100 * Double(good) / Double(total))
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasHackRF: Bool { session.mode == .hackRF && session.hackRF != nil }

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.recording ? "Aufnahme stoppen" : "Aufnahme starten") {
                        if model.recording { model.stopRecording() }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in model.startRecording(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    .tint(model.recording ? .red : .accentColor)
                    .disabled(!hasHackRF)
                }
                if !hasHackRF {
                    Text("Aufnehmen braucht den HackRF-Modus; vorhandene Aufnahmen kannst du auch so auswerten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Frequenz") {
                HStack {
                    Button("ADS-B") { model.centerMHz = 1090; model.sampleRateMHz = 2; model.analysis = .adsb }
                    Button("GPS") { model.centerMHz = 1575.42; model.sampleRateMHz = 4.096; model.analysis = .gps }
                }.controlSize(.small)
                LabeledContent("DVB-T2-Kanal") {
                    Picker("DVB-T2-Kanal", selection: $model.tvChannel) {
                        ForEach(TVChannel.uhf) { Text("\($0.name) · \($0.megahertz) MHz").tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button("Vorlage") { model.applyTVPreset() }.controlSize(.small)
                }
                LabeledContent("DAB-Block") {
                    Picker("DAB-Block", selection: $model.dabChannel) {
                        ForEach(DABChannel.bandIII) { Text(String(format: "%@ · %.3f MHz", $0.name, $0.megahertz)).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button("Vorlage") { model.applyDABPreset() }.controlSize(.small)
                }
                LabeledContent("Zigbee-Kanal") {
                    Picker("Zigbee-Kanal", selection: $model.zigbeeChannel) {
                        ForEach(IEEE802154.channels, id: \.self) { Text(String(format: "%d · %.0f MHz", $0, IEEE802154.frequencyMHz(channel: $0))).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button("Vorlage") { model.applyZigbeePreset() }.controlSize(.small)
                }
                LabeledContent("Mitte") {
                    FrequencyField(value: $model.centerMHz)
                    Text("MHz").foregroundStyle(.secondary)
                }
                LabeledContent("Abtastrate") {
                    TextField("", value: $model.sampleRateMHz, format: .number.precision(.fractionLength(3)))
                        .multilineTextAlignment(.trailing).frame(width: 100)
                    Text("MS/s").foregroundStyle(.secondary)
                }
                if model.basebandFilterHz != nil {
                    Text("DVB-T2 braucht rund 37 MB pro Sekunde – wenige Sekunden Aufnahme genügen.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Wie auf der Fernsehseite: 4,571 MHz über der Kanalmitte, 2·64/7 MS/s, Basisbandfilter 20 MHz.")
                }
            }
            .disabled(model.recording)
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                if model.recording {
                    LabeledContent("Aufgenommen", value: ByteCountFormatter.string(fromByteCount: Int64(model.recordedBytes), countStyle: .file))
                    LabeledContent("Pegel") { LevelBar(value: model.level) }
                }
                LabeledContent("Datenrate", value: ByteCountFormatter.string(fromByteCount: Int64(model.bytesPerSecond), countStyle: .file) + "/s")
                if let seconds = model.maxRecordingSeconds {
                    let remaining = model.recording ? max(0, seconds - Double(model.recordedBytes) / model.bytesPerSecond) : seconds
                    LabeledContent(model.recording ? "Noch möglich" : "Platz für") {
                        Text(Self.durationText(remaining))
                            .foregroundStyle(remaining < 60 ? Color.red : (remaining < 300 ? Color.orange : Color.primary))
                    }
                    if remaining < 300 {
                        Text("Wenig Platz: Die Aufnahme stoppt, bevor weniger als 2 GB frei sind.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            FrequencyMemorySection(page: .recorder, currentMHz: model.centerMHz) { model.centerMHz = $0.mhz }
            Section("Auswertung") {
                Picker("Modus", selection: $model.analysis) {
                    ForEach(RecorderModel.Analysis.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Gilt beim nächsten Abspielen. Für ADS-B, GPS, Fernsehen, DAB+ und Zigbee mit der passenden Vorlage aufnehmen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.daten) {
                Toggle("Als SigMF aufnehmen", isOn: $model.recordAsSigMF)
                    .disabled(model.recording)
                    .help("Schreibt die Aufnahme als .sigmf-data mit .sigmf-meta daneben – lesbar für GNU Radio, inspectrum, SigDigger und andere. Ohne Standort.")
                HStack {
                    Button("SigMF öffnen …") { importSigMF() }
                        .disabled(model.transferTitle != nil || model.recording)
                    Button("Als SigMF exportieren …") {
                        if let rec = model.recordings.first(where: { $0.id == selection }) { exportSigMF(rec) }
                    }
                    .disabled(selection == nil || model.transferTitle != nil)
                }
                if let title = model.transferTitle {
                    HStack {
                        ProgressView(value: model.transferProgress) { Text(title).font(.caption) }
                        Button("Abbrechen") { model.cancelTransfer() }.controlSize(.small)
                    }
                }
                if let notice = model.transferNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("SigMF öffnet ci8, cu8 (rtl_sdr), ci16 und cf32 und legt eine 8-Bit-Kopie in deine Aufnahmen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.hinweis) {
                Text("Tipp: Nimm Signale einmal bei gutem Empfang auf und werte sie beliebig oft offline aus – unabhängig von Antenne und Standort.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension RecorderView {
    /// „2 h 05 min“, „12 min 30 s“, „45 s“.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d h %02d min", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "%d min %02d s", total / 60, total % 60) }
        return "\(total) s"
    }
}

/// Einfache Spektrumskurve.
private struct SpectrumCurve: View {
    let data: [Float]
    var body: some View {
        canvas
            .accessibilityElement()
            .accessibilityLabel("Spektrum der Aufnahme")
    }

    private var canvas: some View {
        Canvas { ctx, size in
            guard data.count > 1 else { return }
            let lo: Float = -100, hi: Float = -10
            var path = Path()
            for (i, v) in data.enumerated() {
                let x = size.width * Double(i) / Double(data.count - 1)
                let n = Double(max(0, min(1, (v - lo) / (hi - lo))))
                let y = size.height * (1 - n)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct LevelBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(value > 0.95 ? Color.red : value > 0.7 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * value)
            }
        }
        .frame(width: 120, height: 10)
    }
}
