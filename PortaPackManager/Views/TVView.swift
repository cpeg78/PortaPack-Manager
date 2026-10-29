import AVFoundation
import SwiftUI

struct TVView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.tv
    @State private var pendingDelete: DeleteConfirmation?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "tv", text: "Antennenfernsehen (DVB-T2 HD) zeigt die App selbst auf dem Mac an. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 340, issue: model.error) {
                HSplitView {
                    serviceList
                        .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
                    video
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } controls: {
                controls
            }
            .task {
                let wanted = AppNavigation.shared.takeAutoStart(.tv)
                // Beim allerersten Öffnen ohne Senderliste selbst suchen.
                if model.muxes.isEmpty, model.services.isEmpty, !autoScanDone, !model.scanning,
                   DeviceArbiter.blocker(session: session) == nil {
                    autoScanDone = true
                    startScan()
                } else if wanted, !model.running {
                    ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
                }
            }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    // MARK: - Senderliste

    @AppStorage("tvAutoScanDone") private var autoScanDone = false

    private func startScan() {
        if model.running { model.scan(); return }
        ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device); model.scan() }
    }

    private var serviceList: some View {
        List {
            if model.muxes.isEmpty && model.services.isEmpty {
                // Der Suchknopf steht rechts oben im Bedienfeld – einmal reicht.
                Text(model.scanning
                     ? "Suchlauf läuft – gefundene Sender erscheinen hier."
                     : "Noch keine Sender bekannt. Klicke rechts auf „Kanäle durchsuchen“ (dauert etwa 1–2 Minuten).")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.muxes) { mux in
                Section {
                    // Überschrift als Zeile statt Abschnittskopf: macOS heftet Köpfe
                    // oben an, und der erste Kanal scrollte nicht mit (27.10.2026).
                    ListGroupHeader {
                        Text("K\(mux.channel) · \(306 + 8 * mux.channel) MHz")
                        Spacer()
                        Text(verbatim: mux.snrKnown ? mux.snr.formatted(.number.precision(.fractionLength(1))) + " dB" : "–").monospacedDigit()
                            .foregroundStyle(snrColor(mux))
                    }
                    if mux.services.isEmpty {
                        Text(weakText(mux)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(mux.services) { service in
                        Button {
                            if model.running { model.play(serviceID: service.id, on: mux.channel) } else {
                                ReceiverStore.shared.requestStart(model, session: session) { device in
                                    model.start(on: device); model.play(serviceID: service.id, on: mux.channel)
                                }
                            }
                        } label: {
                            ServiceRow(name: service.name, detail: detail(service),
                                       playing: model.playingServiceID == service.id && model.channel.number == mux.channel)
                        }
                        .buttonStyle(.plain)
                        .disabled(service.scrambled)
                    }
                }
            }
            // Dienste des laufenden Multiplex, falls noch nicht gemerkt.
            let stored = Set(model.muxes.first { $0.channel == model.channel.number }?.services.map(\.id) ?? [])
            let live = model.services.filter { !$0.name.isEmpty && !stored.contains($0.id) }
            if !live.isEmpty {
                Section("Aktueller Kanal \(model.channel.name)") {
                    ForEach(live) { service in
                        Button { model.play(serviceID: service.id, on: model.channel.number) } label: {
                            ServiceRow(name: service.name, detail: service.typeName, playing: model.playingServiceID == service.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func detail(_ service: TVStoredMux.Service) -> String {
        var parts = [service.radio ? "Radio" : "TV"]
        if !service.provider.isEmpty { parts.append(service.provider) }
        if service.scrambled { parts.append(String(localized: "verschlüsselt")) }
        return parts.joined(separator: " · ")
    }

    /// Grün nur, wenn der Störabstand bekannt ist und reicht; ohne Messwert grau.
    private func snrColor(_ mux: TVStoredMux) -> Color {
        guard mux.snrKnown else { return .secondary }
        guard let required = mux.requiredSNR else { return .secondary }
        return mux.snr >= required ? .green : .orange
    }

    private func weakText(_ mux: TVStoredMux) -> String {
        guard !mux.mode.isEmpty else {
            return String(localized: "Signal nur kurz erkannt – zu schwach, um die Sender zu lesen.")
        }
        guard let required = mux.requiredSNR else { return String(localized: "\(mux.mode) – Sender nicht lesbar") }
        let needed = required.formatted(.number.precision(.fractionLength(0)))
        guard mux.snrKnown else {
            return String(localized: "\(mux.mode) – Sender nicht lesbar: Störabstand nicht messbar, nötig etwa \(needed) dB")
        }
        let snr = mux.snr.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(mux.mode) – Sender nicht lesbar: Störabstand \(snr) dB, nötig etwa \(needed) dB")
    }

    // MARK: - Bild

    private var video: some View {
        ZStack {
            Color.black
            VideoLayerView(layer: model.player.displayLayer)
            if !model.statistics.playing || model.statistics.videoFrames == 0 {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        let status = model.status
        Group {
            if !model.running {
                ContentUnavailableView("Fernsehen", systemImage: "tv", description: Text("Wähle links einen Sender oder klicke auf „Start“."))
            } else if !status.locked {
                ContentUnavailableView(status.stage, systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text(status.message ?? String(localized: "Kanal \(model.channel.name) (\(model.channel.megahertz) MHz)")))
            } else if status.blocksGood == 0 && status.blocksBad > 0 {
                ContentUnavailableView("Signal zu schwach", systemImage: "cellularbars",
                                       description: Text(weakDescription(status)))
            } else if model.statistics.playing && model.statistics.videoFrames == 0 && !model.statistics.audioCodec.isEmpty {
                ContentUnavailableView(model.playingName ?? "Radio", systemImage: "radio", description: Text("Nur Ton"))
            } else {
                ProgressView(model.playingServiceID == nil ? "Senderliste wird gelesen …" : "Wird geladen …")
                    .foregroundStyle(.white)
            }
        }
        .foregroundStyle(.white)
    }

    private func weakDescription(_ status: T2Receiver.Status) -> String {
        let snr = status.snr.formatted(.number.precision(.fractionLength(1)))
        let measured: String
        if let plp = status.post?.plps.first(where: { $0.id == status.plpID }),
           let required = T2Threshold.requiredSNR(modulation: plp.modulation, codeRate: plp.codeRate) {
            let needed = required.formatted(.number.precision(.fractionLength(0)))
            measured = String(localized: "Störabstand \(snr) dB, nötig etwa \(needed) dB")
        } else {
            measured = String(localized: "Störabstand \(snr) dB")
        }
        return String(localized: "Das Signal ist da, aber zu schwach für ein Bild (\(measured)). Eine Fernsehantenne auf dem Dach oder am Fenster hilft am meisten.")
    }

    // MARK: - Bedienfeld

    private var controls: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if let name = model.playingName { Text(name) } else { Text("Kein Sender gewählt") }
                    }
                    .font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        if model.running { model.stop() } else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                    } label: {
                        Label(model.running ? "Stopp" : "Start", systemImage: model.running ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Picker("Kanal", selection: Binding(get: { model.channel }, set: { model.tune($0) })) {
                        ForEach(TVChannel.uhf) { channel in
                            Text("\(channel.name) · \(channel.megahertz) MHz").tag(channel)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.scanning)
                }
                // Suchlauf oben, wo man ihn ohne Sender sucht; eine Zeile fester
                // Höhe (Knopf bzw. Fortschritt), damit die Regler darunter nicht springen.
                HStack {
                    if model.scanning {
                        ProgressView(value: model.scanProgress)
                        Button("Abbrechen") { model.cancelScan() }
                    } else {
                        Button(action: startScan) {
                            Label(model.muxes.isEmpty ? "Kanäle durchsuchen" : "Kanäle neu durchsuchen",
                                  systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(session.hackRF == nil)
                    }
                    // Kein „Leeren“: das leert sonst überall nur die Live-Liste, hier wäre
                    // die gespeicherte Senderliste weg (Bedienungs-Review 29.10.2026).
                    Button("Senderliste löschen …", role: .destructive) {
                        pendingDelete = DeleteConfirmation(
                            title: String(localized: "Gespeicherte Senderliste löschen (\(model.muxes.count) Kanäle)?"),
                            message: String(localized: "Danach braucht es einen neuen Suchlauf (1–2 Minuten).")) { model.forgetMuxes() }
                    }
                    .disabled(model.muxes.isEmpty || model.scanning)
                    .help("Vergisst alle gefundenen Sender.")
                }
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Slider(value: $model.volume, in: 0...1)
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
                LabeledContent("Zustand") {
                    Text(model.running ? model.status.stage : "–")
                        .foregroundStyle(model.status.locked ? .green : .secondary)
                }
                LabeledContent("Störabstand") {
                    Text(model.status.locked ? snrText : "–").monospacedDigit()
                }
                LabeledContent("Datenblöcke") {
                    let total = model.status.blocksGood + model.status.blocksBad
                    Text(total > 0 ? "\(model.status.blocksGood) von \(total) fehlerfrei" : "–").monospacedDigit()
                }
                DisclosureGroup("Technische Details") {
                    LabeledContent("BCH") {
                        let s = model.status
                        Group {
                            if s.blocksGood + s.blocksBad == 0 {
                                Text(verbatim: "–")
                            } else if s.ldpcFalseBlocks > 0 {
                                Text("\(s.bchCorrectedBits) Bits korrigiert · \(s.bchRescuedBlocks) Blöcke gerettet · \(s.ldpcFalseBlocks) falsche LDPC-Wörter")
                            } else {
                                Text("\(s.bchCorrectedBits) Bits korrigiert · \(s.bchRescuedBlocks) Blöcke gerettet")
                            }
                        }.monospacedDigit()
                    }
                    LabeledContent("TS-Pakete") { Text("\(model.status.packets)").monospacedDigit() }
                    LabeledContent("Frequenzablage") {
                        Text(verbatim: model.status.locked ? model.status.frequencyOffsetHz.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + " Hz" : "–").monospacedDigit()
                    }
                    LabeledContent("Abtastratenablage") {
                        // Über ±5 ppm stört die Trägerstauchung – dann die Quarzkorrektur einstellen.
                        Text(verbatim: model.status.locked ? model.status.sampleRateOffsetPPM.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always())) + " ppm" : "–").monospacedDigit()
                            .foregroundStyle(abs(model.status.sampleRateOffsetPPM) > 5 ? .orange : .primary)
                    }
                    .help("Über ±5 ppm stellst du besser die Quarzkorrektur ein (Einstellungen › Antenne & Gerät).")
                }
                if model.statistics.videoFrames > 0 || model.statistics.audioFrames > 0 {
                    LabeledContent("Bild") {
                        Text(model.statistics.width > 0 ? "\(model.statistics.width)×\(model.statistics.height) \(model.statistics.codec)" : model.statistics.codec)
                    }
                    LabeledContent("Ton", value: model.statistics.audioCodec)
                }
            }

            if model.status.locked, let pre = model.status.pre {
                Section("Betriebsart") {
                    LabeledContent("OFDM") {
                        Text(verbatim: "\(model.status.fft?.name ?? "?")\(model.status.extended ? " " + String(localized: "erweitert") : "") · GI \(model.status.guardInterval?.name ?? "?") · \(model.status.pattern?.name ?? "?")")
                    }
                    if let plp = model.status.post?.plps.first(where: { $0.id == model.status.plpID }) {
                        LabeledContent("PLP \(plp.id)") {
                            Text(verbatim: "\(plp.constellation?.name ?? "?") · \(T2CodeRate(rawValue: plp.codeRate)?.name ?? "?") · \(plp.fecType == 1 ? "64K" : "16K")-LDPC")
                        }
                        LabeledContent("Datenrate") { Text(rateText(plp, pre: pre)).monospacedDigit() }
                    }
                    LabeledContent("Netz / Zelle") {
                        Text(String(format: "0x%04X / 0x%04X", pre.networkID, pre.cellID)).monospacedDigit()
                    }
                }
            }

            Section(PanelSection.hinweis) {
                if !model.scanStatus.isEmpty {
                    Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Frei empfangbar sind die öffentlich-rechtlichen Programme; Privatsender (freenet TV) sind verschlüsselt. Der Suchlauf prüft die Kanäle K21–K48 und dauert etwa 1–2 Minuten.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Für ein stabiles Bild braucht es meist 12–15 dB Störabstand. Mehr Verstärkung hilft nur bis zu einem Punkt – danach nur eine bessere Antenne.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("DVB-T2 HD sendet meist 64-QAM mit Coderate 1/2 bis 2/3. Mehr Verstärkung hilft nur, solange das Eigenrauschen des HackRF überwiegt.")
            }

        }
        .deleteConfirmation($pendingDelete)
        .formStyle(.grouped)
    }

    private var snrText: String {
        let snr = model.status.snr.formatted(.number.precision(.fractionLength(1)))
        if let plp = model.status.post?.plps.first(where: { $0.id == model.status.plpID }),
           let required = T2Threshold.requiredSNR(modulation: plp.modulation, codeRate: plp.codeRate) {
            return String(localized: "\(snr) dB (nötig ≈ \(required.formatted(.number.precision(.fractionLength(0)))) dB)")
        }
        return "\(snr) dB"
    }

    private func rateText(_ plp: T2PLP, pre: T2L1Pre) -> String {
        guard let fec = plp.fec, let fft = model.status.fft, let gi = model.status.guardInterval else { return "–" }
        let symbols = Double(fft.p2Symbols + pre.dataSymbols)
        let frameSeconds = (2048 + symbols * Double(fft.size + gi.samples(fft))) / T2FrontEnd.outputRate
        let bits = Double(plp.blocks) * Double(fec.kbch - 80)
        return (bits / frameSeconds / 1e6).formatted(.number.precision(.fractionLength(1))) + " Mbit/s"
    }

    private var subtitle: String {
        var parts = [String(localized: "Kanal \(model.channel.name)"), "\(model.channel.megahertz) MHz"]
        if let id = model.playingServiceID, let service = model.services.first(where: { $0.id == id }), !service.provider.isEmpty {
            parts.append(service.provider)
        }
        return parts.joined(separator: " · ")
    }
}

private struct ServiceRow: View {
    let name: String
    let detail: String
    let playing: Bool

    var body: some View {
        HStack {
            Image(systemName: playing ? "play.tv.fill" : "tv")
                .foregroundStyle(playing ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(playing ? .semibold : .regular)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// Zeigt den `AVSampleBufferDisplayLayer` des Players.
private struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = .black
        view.layer?.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class LayerHostView: NSView {
        var hosted: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
