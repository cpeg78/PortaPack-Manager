import AVFoundation
import AppKit
import SwiftUI

/// Flugfunk-Scanner: Kanalliste mit Pegeln, Funde des Suchlaufs, Verlauf.
/// Das Model gehört dem Fernzugriff (`RemoteHub.airband`), damit Mac und Handy
/// denselben Empfang, dieselbe Kanalliste und denselben Verlauf sehen.
struct AirbandView: View {
    var body: some View { AirbandPage(model: RemoteHub.shared.airband) }
}

private struct AirbandPage: View {
    @Environment(DeviceSession.self) private var session
    @Bindable var model: AirbandModel
    @State private var player = AirbandPlayer()
    @State private var newChannel = ""
    @State private var newName = ""
    @AppStorage("airbandFindMinutes") private var findMinutes = 15.0
    /// Verweildauer je Fenster: Flugfunk ist stoßweise, ein Kanal schweigt oft
    /// eine Minute und länger – 10 s verpassten viel (Wunsch 28.10.2026).
    @AppStorage("airbandFindDwell") private var findDwell = 30.0
    @State private var confirmClear = false
    @State private var historySelection: AirbandTransmission.ID?
    @State private var pendingDelete: DeleteConfirmation?
    /// Suche in den Abschriften (Volltext über die ganze Datenbank).
    @State private var searchText = ""
    @State private var searchResults: [AirbandTransmission]?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "headphones", text: String(localized: "Die App hört alle Kanäle eines Ausschnitts des Flugfunkbands gleichzeitig ab – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 300, issue: model.error) {
                VSplitView {
                    // Drei feste Bereiche: Erschien die Fundliste erst beim Start der Suche,
                    // bekam sie von der schon verteilten Teilung nur ihre Mindesthöhe (28.10.2026).
                    channelTable.frame(minHeight: 110, idealHeight: 200)
                    AirbandFindingsSection(model: model).frame(minHeight: 180, idealHeight: 300)
                    historyTable.frame(minHeight: 110, idealHeight: 200)
                }
                .frame(minWidth: 480)
            } controls: {
                controls
            }
            // Nur die Wiedergabe des Verlaufs endet beim Verlassen – der Empfang läuft weiter.
            .onDisappear { player.stop() }
            .task { if AppNavigation.shared.takeAutoStart(.airband), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    // MARK: - Kanalliste

    private var channelTable: some View {
        Table(model.channels) {
            TableColumn("") { channel in
                Image(systemName: model.audible == channel.index ? "speaker.wave.2.fill" : (model.channelOpen.contains(channel.index) ? "waveform" : "circle"))
                    .foregroundStyle(model.audible == channel.index ? .green : (model.channelOpen.contains(channel.index) ? .orange : .secondary.opacity(0.4)))
            }.width(22)
            TableColumn("Kanal") { channel in
                Text(channel.channelName).monospacedDigit()
                    .foregroundStyle(model.window.covers(channel.index) ? .primary : .secondary)
                    .help(String(format: "%.5f MHz", channel.mhz))
            }.width(64)
            TableColumn("Name") { channel in
                ChannelNameField(name: channel.name) { model.rename(channel.index, to: $0) }
            }
            TableColumn("Pegel") { channel in
                if let excess = model.channelExcess[channel.index] {
                    ExcessBar(db: excess, open: model.channelOpen.contains(channel.index))
                } else {
                    Text(model.running ? "außerhalb" : "–").font(.caption).foregroundStyle(.secondary)
                }
            }.width(min: 80, ideal: 110)
            TableColumn("") { channel in
                HStack(spacing: 6) {
                    Button { model.togglePriority(channel.index) } label: {
                        Image(systemName: channel.priority ? "star.fill" : "star")
                            .foregroundStyle(channel.priority ? .yellow : .secondary)
                    }
                    .help("Vorrang: unterbricht jeden anderen Kanal")
                    .accessibilityLabel(channel.priority ? "Vorrang aus" : "Vorrang ein")
                    Button { model.toggleLocked(channel.index) } label: {
                        Image(systemName: channel.locked ? "lock.fill" : "lock.open")
                            .foregroundStyle(channel.locked ? .red : .secondary)
                    }
                    .help("Sperren: Kanal nie hörbar machen")
                    .accessibilityLabel(channel.locked ? "Entsperren" : "Sperren")
                    Button { model.setHold(model.hold == channel.index ? nil : channel.index) } label: {
                        Image(systemName: model.hold == channel.index ? "pause.circle.fill" : "pause.circle")
                            .foregroundStyle(model.hold == channel.index ? .blue : .secondary)
                    }
                    .help("Halten: nur diesen Kanal hören")
                    .accessibilityLabel(model.hold == channel.index ? "Halten lösen" : "Halten")
                    .disabled(channel.locked)
                    Button { model.removeChannel(channel.index) } label: { Image(systemName: "trash") }
                        .help("Aus der Liste entfernen")
                        .accessibilityLabel("Aus der Liste entfernen")
                }
                .buttonStyle(.borderless)
            }.width(100)
        }
        .overlay {
            if model.channels.isEmpty {
                ContentUnavailableView("Keine Kanäle", systemImage: "headphones",
                                       description: Text("Trag rechts eine Frequenz ein oder starte „Aktive Kanäle finden“."))
            }
        }
    }

    // MARK: - Verlauf

    /// Angezeigte Einträge: Treffer der Suche oder der Verlauf.
    private var shownHistory: [AirbandTransmission] { searchResults ?? model.history }

    private var historyTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Verlauf").font(.headline)
                if let searchResults {
                    Text("\(searchResults.count) Treffer").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(model.history.count) Übertragungen").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("In Abschriften suchen", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 120, idealWidth: 220, maxWidth: 260)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Suche leeren")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .help("Durchsucht die Abschriften aller gespeicherten Sprüche, auch älterer. Mehrere Wörter müssen alle vorkommen; ein Rufzeichen wie DLH4AB findet auch die Sprüche, in denen es erkannt wurde.")
            }
            .padding([.horizontal, .top], 8)
            .task(id: searchText) {
                let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { searchResults = nil; return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let found = await model.search(text)
                guard !Task.isCancelled else { return }
                searchResults = found
            }
            Table(shownHistory, selection: $historySelection) {
                TableColumn("Zeit") { item in
                    Text(item.start, format: .dateTime.day().month().hour().minute().second()).monospacedDigit()
                }.width(min: 100, ideal: 120)
                TableColumn("Kanal") { item in Text(AirbandGrid.channelName(item.index)).monospacedDigit() }.width(64)
                TableColumn("Name") { item in Text(item.name) }.width(min: 50, ideal: 80)
                TableColumn("Text") { item in
                    AirbandTranscriptCell(item: item, pending: model.transcription.isPending(item.id))
                }.width(min: 120, ideal: 320)
                TableColumn("Dauer") { item in Text(String(format: "%.1f s", item.duration)).monospacedDigit() }.width(56)
                TableColumn("Pegel") { item in Text(String(format: "+%.0f dB", item.peakDB)).monospacedDigit() }.width(56)
                TableColumn("Mitschnitt") { item in
                    if let url = model.recordingURL(item) {
                        Button {
                            player.toggle(item.id, url: url)
                        } label: {
                            Image(systemName: player.playing == item.id ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(player.playing == item.id ? "Wiedergabe stoppen" : "Mitschnitt abspielen")
                        .accessibilityLabel(player.playing == item.id ? "Wiedergabe stoppen" : "Mitschnitt abspielen")
                    }
                }.width(70)
            }
            .contextMenu(forSelectionType: AirbandTransmission.ID.self) { ids in
                if let id = ids.first, let item = shownHistory.first(where: { $0.id == id }) {
                    if let raw = item.transcript {
                        Button("Text kopieren") { copy(AirbandTranscriptFormatter.format(raw)) }
                        Button("Rohtext kopieren") { copy(raw) }
                    }
                    if let sign = item.callsign, let icao = item.aircraftICAO.flatMap({ UInt32($0, radix: 16) }) {
                        Button("Flugzeug \(sign) zeigen") { AppNavigation.shared.showAircraft(icao) }
                    }
                    if let url = model.recordingURL(item) {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Kanal zur Liste hinzufügen") { model.addChannel(index: item.index, name: item.name) }
                    Button("Löschen …", role: .destructive) { confirmDelete(item) }
                }
            }
            .onDeleteCommand {
                if let item = shownHistory.first(where: { $0.id == historySelection }) { confirmDelete(item) }
            }
            .overlay {
                if let searchResults, searchResults.isEmpty {
                    ContentUnavailableView("Nichts gefunden", systemImage: "magnifyingglass",
                                           description: Text(model.transcription.enabled
                                                             ? "Keine Abschrift enthält „\(searchText)“."
                                                             : "Gesucht wird in den Abschriften – schalte rechts unter „Erkennung“ „Sprüche in Text umwandeln“ ein."))
                } else if searchResults == nil, model.history.isEmpty {
                    ContentUnavailableView("Noch keine Sprüche", systemImage: "text.bubble",
                                           description: Text("Jede Übertragung auf einem Listenkanal erscheint hier – mit „Sprüche in Text umwandeln“ auch als Text."))
                }
            }
            .deleteConfirmation($pendingDelete)
        }
    }

    private func confirmDelete(_ item: AirbandTransmission) {
        let time = item.start.formatted(.dateTime.hour().minute().second())
        pendingDelete = DeleteConfirmation(
            title: String(localized: "Übertragung von \(time) auf \(AirbandGrid.channelName(item.index)) löschen?"),
            message: model.recordingURL(item) != nil
                ? String(localized: "Der Eintrag und sein Mitschnitt werden gelöscht.")
                : String(localized: "Der Eintrag wird aus dem Verlauf gelöscht.")) {
            if historySelection == item.id { historySelection = nil }
            model.delete(item)
            searchResults?.removeAll { $0.id == item.id }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                    Button(model.hold == nil ? "Halten" : "Weiter") { model.toggleHold() }
                        .disabled(model.hold == nil && model.audible == nil)
                        .help("Hält den gerade hörbaren Kanal fest bzw. löst das Halten")
                    Button("Leeren …", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                        .help("Löscht den Verlauf samt aller Mitschnitte")
                        .confirmationDialog("Verlauf und alle Mitschnitte löschen?", isPresented: $confirmClear) {
                            Button("Löschen", role: .destructive) { player.stop(); model.deleteHistory() }
                        }
                }
                LabeledContent("Lautstärke") {
                    Slider(value: $model.volume, in: 0...1)
                }
                LabeledContent("Rauschsperre \(Int(model.squelchDB)) dB") {
                    Slider(value: $model.squelchDB, in: 3...20, step: 1)
                }
                .help("So weit muss ein Signal über dem Rauschen liegen, damit der Kanal aufgeht. Kleiner = empfindlicher, aber mehr Fehlalarme. Den Rauschboden jedes Kanals lernt die App selbst.")
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Kanal hinzufügen") {
                TextField("Kanal oder MHz, z. B. 118.005", text: $newChannel)
                TextField("Name (z. B. Turm)", text: $newName)
                HStack {
                    if !newChannel.isEmpty, AirbandGrid.index(parsing: newChannel) == nil {
                        Text("Kein Flugfunkkanal (118–137 MHz)").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Hinzufügen") {
                        if let index = AirbandGrid.index(parsing: newChannel) {
                            model.addChannel(index: index, name: newName)
                            newChannel = ""
                            newName = ""
                        }
                    }
                    .disabled(AirbandGrid.index(parsing: newChannel) == nil)
                }
                Text("Gefundene Kanäle und Einträge im Verlauf übernimmst du per Rechtsklick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Aktive Kanäle finden") {
                Picker("Dauer", selection: $findMinutes) {
                    Text("1 min").tag(1.0)
                    Text("5 min").tag(5.0)
                    Text("15 min").tag(15.0)
                    Text("60 min").tag(60.0)
                    Text("2 h").tag(120.0)
                }
                Picker("Je Abschnitt lauschen", selection: $findDwell) {
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("2 min").tag(120.0)
                    Text("5 min").tag(300.0)
                }
                HStack {
                    if model.finding {
                        ProgressView(value: model.findProgress)
                        Button("Abbrechen") { model.cancelFind() }
                    } else {
                        Button("Suche starten") { model.findActiveChannels(minutes: findMinutes, dwell: findDwell) }
                            .disabled(!model.running)
                    }
                }
                if model.finding, !model.findStatus.isEmpty {
                    Text(model.findStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Hört nacheinander das ganze Flugfunkband ab. Funde erscheinen links – per Rechtsklick übernimmst du sie in die Liste. Je länger, desto mehr seltene Kanäle.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Bei 8 MHz Ausschnitt sind es vier Abschnitte; auf jedem lauscht die App die eingestellte Zeit.")
            }
            Section("Ausschnitt") {
                Toggle("Breiter Ausschnitt (16 MHz)", isOn: $model.wide)
                    .disabled(model.running)
                    .help("Doppelt so viele Kanäle gleichzeitig, aber doppelte Rechenlast. Nur umschaltbar, solange der Empfang gestoppt ist.")
                if !model.uncovered.isEmpty {
                    Text("Nicht im Ausschnitt: \(model.uncovered.map(\.channelName).joined(separator: ", ")). Die Mitte richtet sich nach der Liste; Kanäle mit Stern haben Vorrang.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                if let audible = model.audible {
                    let channel = model.channels.first { $0.index == audible }
                    Label("\(AirbandGrid.channelName(audible)) \(channel?.name ?? "")", systemImage: "speaker.wave.2.fill")
                        .foregroundStyle(.green)
                } else if model.running {
                    Label("Stille – höre \(model.channels.filter { model.window.covers($0.index) && !$0.locked }.count) Kanäle ab", systemImage: "ear")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Mitte", value: String(format: "%.3f MHz", model.window.centerHz / 1e6))
                LabeledContent("Hörbar", value: String(format: "%.1f–%.1f MHz",
                                                        AirbandGrid.mhz(model.window.center - model.window.halfWidth),
                                                        AirbandGrid.mhz(model.window.center + model.window.halfWidth)))
                LabeledContent("Verlauf", value: "\(model.history.count) Übertragungen")
            }
            Section("Erkennung") {
                Toggle("Nur Sprache zählen", isOn: $model.speechOnly)
                Text("Zählt nur Sprüche ab 1 s, die wie Sprache klingen – Knackser und Störungen fallen dann weg.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Getastete Träger und Rauschspitzen erscheinen dann weder im Verlauf noch bei den gefundenen Kanälen.")
                AirbandTranscriptionControls(transcription: model.transcription)
            }
            Section(PanelSection.daten) {
                Toggle("Sprüche aufzeichnen", isOn: $model.recordAudio)
                Text("Speichert jeden Spruch als Audiodatei auf diesem Mac. Flugfunk-Inhalte darfst du nicht weitergeben.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Im Finder zeigen", systemImage: "folder") { NSWorkspace.shared.open(model.recordingsFolder) }
            }
            Section(PanelSection.hinweis) {
                LegalNotice()
            }
        }
        .formStyle(.grouped)
    }
}

/// Schalter und Zustand der Spracherkennung im Abschnitt „Erkennung“.
private struct AirbandTranscriptionControls: View {
    @Bindable var transcription: AirbandTranscription

    var body: some View {
        content.onAppear { transcription.refreshInstalledModels() }
    }

    @ViewBuilder private var content: some View {
        Toggle("Sprüche in Text umwandeln", isOn: $transcription.enabled)
        Picker("Sprache", selection: $transcription.language) {
            ForEach(AirbandSpeechLanguage.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!transcription.enabled)
        .help("Englisch für den Sprechfunk nach ICAO (fast überall), Deutsch für Sichtflug an kleinen Plätzen. „Automatisch“ erkennt jeden Spruch in beiden Sprachen und nimmt das sicherere Ergebnis – doppelte Rechenzeit.")
        Picker("Spracherkennung", selection: $transcription.engine) {
            ForEach(AirbandTranscription.Engine.allCases) { Text($0.title).tag($0) }
        }
        .help("Apple: schnell, im System enthalten. Whisper: meist genauer bei Rauschen und Funkkürzeln; das Modell lädt die App einmalig herunter (whisper.cpp, rechnet auf dem Mac).")
        if transcription.engine == .whisper {
            Picker("Modell", selection: $transcription.whisperModel) {
                ForEach(WhisperModel.allCases) { model in
                    Text(verbatim: "\(model.title) · \(model.sizeText)" + (transcription.installedWhisperModels.contains(model) ? " ✓" : ""))
                        .tag(model)
                }
            }
            let others = WhisperModel.allCases.filter { $0 != transcription.whisperModel && transcription.installedWhisperModels.contains($0) }
            if !others.isEmpty {
                Menu("Geladene Modelle löschen") {
                    ForEach(others) { model in
                        Button("\(model.title) (\(model.sizeText))") { transcription.deleteWhisperModel(model) }
                    }
                }
                .fixedSize()
            }
        }
        Text("Läuft nur auf dem Mac, nichts verlässt den Rechner. Der Ton bleibt dafür nur kurz im Speicher; gespeichert wird er nur mit „Sprüche aufzeichnen“.")
            .font(.caption).foregroundStyle(.secondary)
        if transcription.enabled {
            if case .downloading(let fraction) = transcription.status {
                ProgressView(value: fraction) {
                    Text("Sprachmodell wird geladen …").font(.caption)
                }
                Text(transcription.engine == .whisper
                     ? "Einmalig von Hugging Face (\(transcription.whisperModel.sizeText)), danach arbeitet die Erkennung ohne Internet."
                     : "Einmalig vom System, danach arbeitet die Erkennung ohne Internet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let text = transcription.statusText {
                Label(text, systemImage: transcription.statusIsProblem ? "exclamationmark.triangle" : "hourglass")
                    .font(.caption)
                    .foregroundStyle(transcription.statusIsProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if transcription.status == .ready {
                let stats = transcription.stats
                LabeledContent("Erkannt", value: "\(stats.done)")
                if stats.pending > 0 || stats.busy {
                    LabeledContent("Warteschlange", value: "\(stats.pending + (stats.busy ? 1 : 0))")
                }
                if stats.dropped > 0 {
                    LabeledContent("Verworfen (Überlast)", value: "\(stats.dropped)")
                        .help("Kamen mehr Sprüche, als der Mac erkennen konnte, fallen die ältesten wartenden weg.")
                }
                if stats.skipped + stats.empty > 0 {
                    LabeledContent("Ohne Text", value: "\(stats.skipped + stats.empty)")
                        .help("Zu kurz (unter 0,8 s), nur Rauschen oder unverständlich.")
                }
                if let error = stats.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Abschrift in der Verlaufstabelle: aufbereiteter Text, Zuversicht als
/// dezente Färbung, Rohtext im Tooltip, erkanntes Rufzeichen vorne.
private struct AirbandTranscriptCell: View {
    let item: AirbandTransmission
    let pending: Bool

    var body: some View {
        if let raw = item.transcript {
            HStack(spacing: 4) {
                if let sign = item.callsign {
                    Text(sign)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 4)
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .help("Rufzeichen eines Flugzeugs aus ADS-B – Rechtsklick ▸ „Flugzeug zeigen“")
                }
                // Einzeilig: Tabellenzeilen haben eine feste Höhe, eine zweite Zeile
                // würde abgeschnitten. Der volle Text steht im Tooltip.
                Text(AirbandTranscriptFormatter.format(raw))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(style)
            }
            .help(AirbandTranscriptFormatter.format(raw) + "\n" + tooltip(raw))
        } else if pending {
            Text("wird erkannt …").font(.caption).italic().foregroundStyle(.secondary)
        }
    }

    /// Hohe Zuversicht normal, mittlere grau, niedrige blass.
    private var style: HierarchicalShapeStyle {
        guard let confidence = item.transcriptConfidence else { return .primary }
        if confidence >= 0.7 { return .primary }
        return confidence >= 0.45 ? .secondary : .tertiary
    }

    private func tooltip(_ raw: String) -> String {
        var parts = [String(localized: "Rohtext: \(raw)")]
        if let confidence = item.transcriptConfidence {
            parts.append(String(localized: "Zuversicht \(Int((confidence * 100).rounded())) %"))
        }
        if let language = item.transcriptLanguage { parts.append(AirbandSpeechText.languageName(language)) }
        return parts.joined(separator: " · ")
    }
}
/// Namensfeld, das erst beim Bestätigen speichert.
private struct ChannelNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .onAppear { text = name }
            .onChange(of: name) { _, new in text = new }
            .onSubmit { commit(text) }
    }
}

/// Abstand zum Rauschboden als Balken (0–40 dB).
private struct ExcessBar: View {
    let db: Float
    let open: Bool

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, db / 40)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(open ? Color.green : Color.secondary).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .help(String(format: String(localized: "%+.0f dB über dem Rauschen"), db))
    }
}

/// Spielt Mitschnitte ab.
@MainActor
@Observable
final class AirbandPlayer {
    private(set) var playing: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var watch: Task<Void, Never>?

    func toggle(_ id: UUID, url: URL) {
        if playing == id { stop(); return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
        playing = id
        watch = Task { [weak self] in
            while !Task.isCancelled, player.isPlaying { try? await Task.sleep(for: .milliseconds(200)) }
            if self?.playing == id { self?.playing = nil }
        }
    }

    func stop() {
        watch?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

/// Funde des Suchlaufs als eigene Ansicht: Sie beobachtet nur Funde und
/// Kanalliste, nicht die Pegel, die die Seite mehrmals pro Sekunde neu zeichnen.
private struct AirbandFindingsSection: View {
    let model: AirbandModel
    /// Sortierung per Spaltenkopf (Vorgabe: meiste Sprüche zuerst).
    @State private var findingsOrder: [ColumnSort<AirbandFinding>] = {
        var byCount = ColumnSort<AirbandFinding>("sprueche") { $0.activity.transmissions }
        byCount.order = .reverse
        return [byCount]
    }()
    /// Funde mit weniger Sprüchen ausblenden (einzelne Knackser, Störungen).
    @AppStorage("airbandMinTransmissions") private var minTransmissions = 1
    @State private var shown: [AirbandFinding] = []
    @State private var findingsSelection = Set<AirbandFinding.ID>()
    @State private var hiddenFindings = 0
    @State private var lastRefresh = Date.distantPast
    @State private var refreshPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Gefundene Kanäle").font(.headline)
                if !model.finding {
                    Text(model.findStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hiddenFindings > 0 {
                    Text("\(hiddenFindings) ausgeblendet").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Mindestens", selection: $minTransmissions) {
                    ForEach([1, 2, 3, 5, 10, 20], id: \.self) { Text($0 == 1 ? "1 Spruch" : "\($0) Sprüche").tag($0) }
                }
                .fixedSize()
                .help("Kanäle mit weniger Sprüchen ausblenden")
            }
            .padding([.horizontal, .top], 8)
            Table(shown, selection: $findingsSelection, sortOrder: $findingsOrder) {
                TableColumn("Kanal", sortUsing: ColumnSort("kanal") { $0.index }) { item in Text(AirbandGrid.channelName(item.index)).monospacedDigit() }.width(64)
                TableColumn("Sprüche", sortUsing: ColumnSort("sprueche") { $0.activity.transmissions }) { item in Text("\(item.activity.transmissions)").monospacedDigit() }.width(56)
                TableColumn("Belegt", sortUsing: ColumnSort("belegt") { $0.activity.openSeconds }) { item in Text(String(format: "%.0f s", item.activity.openSeconds)).monospacedDigit() }.width(56)
                TableColumn("Pegel", sortUsing: ColumnSort("pegel") { $0.activity.peakDB }) { item in Text(String(format: "+%.0f dB", item.activity.peakDB)).monospacedDigit() }.width(56)
                TableColumn("Hinweis", sortUsing: ColumnSort("hinweis", text: { findingHint($0) })) { item in
                    if item.activity.looksContinuous {
                        Text("Dauerträger (ATIS?) oder Störung").font(.caption).foregroundStyle(.orange)
                    } else if AirbandGrid.possiblySpur(item.index) {
                        Text("glatte MHz – evtl. Störlinie").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("In Liste", sortUsing: ColumnSort("liste") { item in model.channels.contains { $0.index == item.index } ? 0 : 1 }) { item in
                    if model.channels.contains(where: { $0.index == item.index }) {
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                    }
                }.width(60)
            }
            .contextMenu(forSelectionType: AirbandFinding.ID.self) { ids in
                let missing = shown.filter { item in ids.contains(item.id) && !model.channels.contains { $0.index == item.index } }
                if !missing.isEmpty {
                    Button("Kanal zur Liste hinzufügen") {
                        for item in missing { model.addChannel(index: item.index, name: "") }
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(model.finding ? "Suche läuft …" : "Noch nichts gefunden",
                                           systemImage: "magnifyingglass",
                                           description: Text(model.finding
                                                             ? "Kanäle mit Funkverkehr erscheinen hier, sobald die Rauschsperre aufgeht."
                                                             : hiddenFindings > 0 ? "\(hiddenFindings) Kanäle sind ausgeblendet – stell „Mindestens“ kleiner."
                                                             : "Starte rechts „Aktive Kanäle finden“. Funde übernimmst du per Rechtsklick in die Liste."))
                }
            }
        }
        .onAppear { refresh(throttled: false) }
        .onChange(of: model.findings) { _, _ in refresh(throttled: true) }
        .onChange(of: findingsOrder) { _, _ in refresh(throttled: false) }
        .onChange(of: minTransmissions) { _, _ in refresh(throttled: false) }
    }

    /// Neu filtern und sortieren. Bei neuen Funden (das Model setzt sie während
    /// der Suche fünfmal pro Sekunde) höchstens einmal pro Sekunde – sonst
    /// sortierte die Tabelle laufend um und verschob Hunderte Zeilen, die App
    /// hing (Fund 28.10.2026).
    private func refresh(throttled: Bool) {
        let now = Date()
        if throttled, now.timeIntervalSince(lastRefresh) < 1 {
            if !refreshPending {
                refreshPending = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    refreshPending = false
                    refresh(throttled: false)
                }
            }
            return
        }
        lastRefresh = now
        let visible = model.findings.filter { $0.activity.transmissions >= minTransmissions }
        let sorted = visible.sorted(using: findingsOrder)
        if sorted != shown { shown = sorted }
        hiddenFindings = model.findings.count - visible.count
    }

    private func findingHint(_ item: AirbandFinding) -> String? {
        if item.activity.looksContinuous { return String(localized: "Dauerträger") }
        return AirbandGrid.possiblySpur(item.index) ? String(localized: "glatte MHz") : nil
    }

}
