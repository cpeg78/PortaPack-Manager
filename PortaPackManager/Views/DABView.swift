import SwiftUI

struct DABView: View {
    @Environment(DeviceSession.self) private var session
    /// Gehört dem Fernzugriff, damit App und Browser denselben Empfänger bedienen.
    @Bindable private var model = RemoteHub.shared.dab
    @State private var pendingDelete: DeleteConfirmation?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "dot.radiowaves.left.and.right", text: "Digitalradio (DAB+) spielt die App über die Lautsprecher des Mac ab. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            HSplitView {
                stationList
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
                controls
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
            .task {
                let wanted = AppNavigation.shared.takeAutoStart(.dab)
                // Beim allerersten Öffnen ohne Senderliste selbst suchen – sonst
                // stand der Einsteiger vor einer leeren Liste.
                if model.ensembles.isEmpty, !autoScanDone, !model.scanning, DeviceArbiter.blocker(session: session) == nil {
                    autoScanDone = true
                    startScan()
                } else if wanted, !model.running {
                    ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.dab); model.start(on: device) }
                }
            }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    // MARK: - Senderliste

    @AppStorage("dabAutoScanDone") private var autoScanDone = false
    /// Senderliste A–Z über alle Ensembles statt nach Ensemble gruppiert.
    @AppStorage("dabSortByName") private var sortByName = false

    private func startScan() {
        if model.running { model.scan(); return }
        ReceiverStore.shared.requestStart(model, session: session) { device in
            RemoteHub.shared.prepareLocalStart(.dab); model.start(on: device); model.scan()
        }
    }

    private var stationList: some View {
        List {
            if model.ensembles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Noch keine Sender bekannt.").foregroundStyle(.secondary)
                    Button("Sender suchen (etwa 1–2 Minuten)", systemImage: "magnifyingglass", action: startScan)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scanning || session.hackRF == nil)
                }
            }
            if !model.ensembles.isEmpty {
                Picker("Sortierung", selection: $sortByName) {
                    Text("Nach Ensemble").tag(false)
                    Text("Nach Name").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if sortByName {
                let all = model.stationList
                    .flatMap { ensemble, services in services.map { (ensemble: ensemble, service: $0) } }
                    .sorted { $0.service.label.localizedStandardCompare($1.service.label) == .orderedAscending }
                Section {
                    ListGroupHeader { Text("Alle Sender (\(all.count))") }
                    ForEach(all, id: \.service.id) { entry in
                        serviceButton(entry.service, in: entry.ensemble, showEnsemble: true)
                    }
                }
            } else {
                ForEach(model.stationList, id: \.ensemble.id) { ensemble, services in
                    Section {
                        ListGroupHeader {
                            Text(ensemble.label)
                            Spacer()
                            Text(ensemble.channel).monospacedDigit()
                        }
                        ForEach(services) { service in serviceButton(service, in: ensemble) }
                    }
                }
            }
        }
    }

    private func serviceButton(_ service: DABStoredEnsemble.Service, in ensemble: DABStoredEnsemble,
                               showEnsemble: Bool = false) -> some View {
        Button {
            if model.running { model.play(service, on: ensemble.channel) } else {
                ReceiverStore.shared.requestStart(model, session: session) { device in
                    RemoteHub.shared.prepareLocalStart(.dab); model.start(on: device); model.play(service, on: ensemble.channel)
                }
            }
        } label: {
            // Kennung ist eindeutig – auch auf einem anderen Kanal gehört, gilt er als laufend.
            ServiceRow(service: service, playing: model.playingServiceID == service.id,
                       alsoOn: model.otherChannels(of: service.id, besides: ensemble.channel),
                       ensemble: showEnsemble ? "\(ensemble.label) \(ensemble.channel)" : nil)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bedienfeld

    private var controls: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            if let label = model.playingLabel { Text(label) } else { Text("Kein Sender gewählt") }
                        }
                        .font(.title2.weight(.semibold))
                        Text(subtitle)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                // Radiotext mit fester Höhe (drei Zeilen): er wechselt alle paar
                // Sekunden seine Länge, und alles darunter sprang mit.
                if model.running || !model.status.dynamicLabel.isEmpty {
                    Text(model.status.dynamicLabel.isEmpty ? " " : model.status.dynamicLabel)
                        .font(.body)
                        .lineLimit(3, reservesSpace: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button {
                        if model.running { model.stop() } else { ReceiverStore.shared.requestStart(model, session: session) { device in RemoteHub.shared.prepareLocalStart(.dab); model.start(on: device) } }
                    } label: {
                        Label(model.running ? "Stopp" : "Abspielen", systemImage: model.running ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Picker("Kanal", selection: Binding(get: { model.channel }, set: { model.tune($0) })) {
                        ForEach(DABChannel.bandIII) { channel in
                            Text(verbatim: "\(channel.name) · \(channel.megahertz.formatted(.number.precision(.fractionLength(3)))) MHz").tag(channel)
                        }
                    }
                    .frame(maxWidth: 240)
                    .disabled(model.scanning)
                    Spacer()
                    Image(systemName: model.localMuted ? "speaker.slash" : "speaker.wave.2")
                    Slider(value: $model.volume, in: 0...1).frame(width: 130)
                        .disabled(model.localMuted)
                }
                if model.localMuted {
                    Text("Der Mac ist stumm – der Ton läuft im Browser (Fernzugriff).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            // Direkt unter der Kanalwahl: darunter wechseln Zeilen und Abschnitte
            // („Betriebsart“, „Format“) ihre Höhe – weiter unten sprangen die Regler.
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Synchronisation") {
                    Text(model.status.synchronized ? "eingerastet" : (model.running ? "wird gesucht …" : "–"))
                        .foregroundStyle(model.status.synchronized ? .green : .secondary)
                }
                LabeledContent("Störabstand") { Text(verbatim: model.status.synchronized ? model.status.snr.formatted(.number.precision(.fractionLength(1))) + " dB" : "–").monospacedDigit() }
                LabeledContent("Audiorahmen") {
                    Text("\(model.status.accessUnitsGood) gut · \(model.status.accessUnitsBad) fehlerhaft").monospacedDigit()
                }
                if !model.status.format.isEmpty {
                    LabeledContent("Format", value: model.status.format)
                }
                DisclosureGroup("Technische Details") {
                    LabeledContent("FIC fehlerfrei") { Text(verbatim: model.status.synchronized ? "\(Int(model.status.ficQuality * 100)) %" : "–").monospacedDigit() }
                        .help("Anteil fehlerfrei empfangener Senderinformationen (Fast Information Channel)")
                    LabeledContent("Frequenzablage") { Text(verbatim: model.status.frequencyOffset.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + " Hz").monospacedDigit() }
                    LabeledContent("Audiopuffer") { Text(verbatim: model.bufferFill.formatted(.number.precision(.fractionLength(2))) + " s").monospacedDigit() }
                }
            }

            Section("Suchlauf") {
                HStack {
                    // Bei leerer Liste steht der große Suchknopf links in der Senderliste.
                    if model.scanning {
                        Button("Abbrechen") { model.cancelScan() }
                    } else if !model.ensembles.isEmpty {
                        Button(action: startScan) {
                            Label("Alle Kanäle durchsuchen", systemImage: "magnifyingglass")
                        }
                    }
                    Spacer()
                    // Kein „Leeren“: das leert sonst überall nur die Live-Liste, hier wäre
                    // die gespeicherte Senderliste weg (Bedienungs-Review 29.10.2026).
                    Button("Senderliste löschen …", role: .destructive) {
                        pendingDelete = DeleteConfirmation(
                            title: String(localized: "Gespeicherte Senderliste löschen (\(model.ensembles.count) Ensembles)?"),
                            message: String(localized: "Danach braucht es einen neuen Suchlauf (1–2 Minuten).")) { model.forgetEnsembles() }
                    }
                    .disabled(model.ensembles.isEmpty || model.scanning)
                    .help("Vergisst alle gefundenen Sender.")
                }
                if model.scanning {
                    ProgressView(value: model.scanProgress)
                }
                if !model.scanStatus.isEmpty {
                    Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Durchsucht alle DAB-Kanäle (5A–13F) und merkt sich die Sender – dauert etwa 1–2 Minuten.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Bundesweit senden in Deutschland die Kanäle 5C (DR Deutschland) und 5D (Antenne Deutschland); dazu kommen landesweite und regionale Ensembles.")
            }
            AudioRecordingSection(host: model, source: AudioRecordingStore.dabPrefix)
            Section(PanelSection.hinweis) {
                Text("Setzt der Ton aus, ist das Signal zu schwach (Störabstand unter etwa 8 dB). Eine DAB-Antenne (Stab um 40 cm) hilft deutlich mehr als die Teleskopantenne.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .deleteConfirmation($pendingDelete)
        .formStyle(.grouped)
    }

    private var subtitle: String {
        var parts: [String] = []
        let ensemble = model.status.ensemble.label.isEmpty
            ? (model.ensembles.first { $0.channel == model.channel.name }?.label ?? "")
            : model.status.ensemble.label
        if !ensemble.isEmpty { parts.append(ensemble) }
        parts.append(String(localized: "Kanal \(model.channel.name)"))
        if let id = model.playingServiceID, let service = model.status.ensemble.services[id],
           let subchannel = model.status.ensemble.subchannel(for: service) {
            parts.append("\(subchannel.bitrate) kbit/s")
            if !service.programmeTypeName.isEmpty { parts.append(service.programmeTypeName) }
        }
        return parts.joined(separator: " · ")
    }
}

private struct ServiceRow: View {
    let service: DABStoredEnsemble.Service
    let playing: Bool
    var alsoOn: [String] = []
    /// In der A–Z-Liste: aus welchem Ensemble der Sender kommt.
    var ensemble: String?

    var body: some View {
        HStack {
            Image(systemName: playing ? "speaker.wave.2.fill" : "radio")
                .foregroundStyle(playing ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.label).fontWeight(playing ? .semibold : .regular)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        var parts = ensemble.map { [$0] } ?? []
        parts.append(service.kind.title)
        if service.bitrate > 0 { parts.append("\(service.bitrate) kbit/s") }
        let type = DABProgrammeType.name(service.programmeType)
        if !type.isEmpty { parts.append(type) }
        if !alsoOn.isEmpty { parts.append(String(localized: "auch \(alsoOn.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }
}
