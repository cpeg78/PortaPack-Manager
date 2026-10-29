import AppKit
import SwiftUI

/// Seite „Amateurfunk-Satelliten & ISS“: SSTV-Bilder der ISS (live und als
/// Galerie) und AX.25-Pakete kleiner Satelliten, mit Doppler-Korrektur.
struct AmateurSatView: View {
    @Environment(DeviceSession.self) private var session
    /// Gehört dem Empfangsplan, damit geplante Überflüge auch ohne offene Seite laufen.
    @Bindable private var model = ReceptionPlanner.shared.amateur
    @Bindable private var planner = ReceptionPlanner.shared
    @AppStorage("amateurSatTab") private var tab = Tab.packets
    @State private var zoom = false
    @State private var pendingDelete: DeleteConfirmation?

    enum Tab: String { case packets, gallery }

    private var hackRFReady: Bool { session.mode == .hackRF && session.hackRF != nil }

    var body: some View {
        ControlsSplit(width: 300, issue: model.error) {
            VSplitView {
                topPane.frame(minHeight: 200, idealHeight: 380)
                bottomPane.frame(minHeight: 140, idealHeight: 260)
            }
            .frame(minWidth: 520)
        } controls: {
            controls
        }
        // Erst im HackRF-Modus abholen – die Seite ist auch vorher sichtbar (Galerie).
        .task(id: hackRFReady) {
            if hackRFReady, AppNavigation.shared.takeAutoStart(.amateurSat), !model.running {
                ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
            }
        }
        .onAppear { model.refreshGallery(); model.updateDoppler() }
        .onChange(of: session.mode) { _, mode in
            if mode != .hackRF { model.stop(on: nil) }
        }
    }

    // MARK: - SSTV live

    @ViewBuilder
    private var topPane: some View {
        if !hackRFReady && !model.running {
            HackRFRequiredView(systemImage: "photo.on.rectangle",
                               text: "Bilder der ISS (SSTV) und Datenpakete kleiner Satelliten empfängt die App selbst – dafür muss das PortaPack im HackRF-Modus laufen. Die Galerie unten geht auch ohne.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    if let mode = model.liveStatus.mode {
                        Label("SSTV \(mode.title)", systemImage: "record.circle").foregroundStyle(.red)
                        Text("\(model.liveStatus.rows)/\(mode.height) Zeilen").monospacedDigit().foregroundStyle(.secondary)
                    } else if model.liveImage != nil {
                        Text("Letztes Bild").foregroundStyle(.secondary)
                    } else {
                        Text("SSTV").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.liveImage != nil {
                        Text("Takt \(model.liveClockPPM, format: .number.precision(.fractionLength(0)).sign(strategy: .always())) ppm").font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Abweichung des Sendertakts – die App richtet schräge Bilder damit gerade.")
                        Toggle("Volle Größe", isOn: $zoom)
                    }
                }
                .padding(8)
                Divider()
                Group {
                    if let image = model.liveImage {
                        if zoom {
                            ScrollView([.horizontal, .vertical]) {
                                Image(decorative: image, scale: 1).interpolation(.none)
                            }
                        } else {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Noch kein SSTV-Bild", systemImage: "photo.on.rectangle")
                        } description: {
                            Text(model.running
                                 ? "Das Bild baut sich Zeile für Zeile auf, sobald eine Übertragung beginnt. Die ISS sendet Bilder nur an angekündigten Tagen (ARISS)."
                                 : "Klicke auf „Start“, dann hört die App auf den Kanälen des gewählten Satelliten mit.")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(model.liveImage == nil ? 0 : 1))
            }
        }
    }

    // MARK: - Pakete / Galerie

    private var bottomPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Ansicht", selection: $tab) {
                    Text("Rahmen (\(model.frames.count))").tag(Tab.packets)
                    Text("Galerie (\(model.gallery.count))").tag(Tab.gallery)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
            }
            .padding(8)
            Divider()
            switch tab {
            case .packets: packets
            case .gallery: gallery
            }
        }
    }

    private var packets: some View {
        Table(model.frames) {
            TableColumn("Zeit") { Text($0.date.formatted(date: .omitted, time: .standard)).monospacedDigit() }.width(70)
            TableColumn("Quelle") { Text($0.source).font(.body.monospaced()) }.width(min: 70, ideal: 90)
            TableColumn("Ziel") { Text($0.destination).font(.body.monospaced()) }.width(min: 60, ideal: 80)
            TableColumn("Pfad") { Text($0.path).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(min: 50, ideal: 100)
            TableColumn("Inhalt") { frame in
                Text(frame.text ?? frame.hex)
                    .font(frame.text == nil ? .caption.monospaced() : .body)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(frame.hex)
            }
            TableColumn("Kanal") { Text($0.channel).font(.caption).foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: AmateurFrame.ID.self) { ids in
            if let frame = model.frames.first(where: { ids.contains($0.id) }) {
                Button("Inhalt kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(frame.source)>\(frame.destination)\(frame.path.isEmpty ? "" : "," + frame.path): \(frame.text ?? frame.hex)", forType: .string)
                }
                Button("Hex kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(frame.hex, forType: .string)
                }
            }
        }
        .overlay {
            if model.frames.isEmpty {
                ContentUnavailableView("Keine Rahmen", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Empfangene Datenpakete (AX.25) erscheinen hier mit Rufzeichen und Inhalt."))
            }
        }
    }

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(model.gallery, id: \.self) { url in
                    GalleryTile(url: url)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .contextMenu {
                            Button("Öffnen") { NSWorkspace.shared.open(url) }
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("Löschen …", role: .destructive) {
                                pendingDelete = DeleteConfirmation(
                                    title: String(localized: "Bild „\(url.lastPathComponent)“ löschen?"),
                                    message: String(localized: "Das Bild wird aus dem Ordner „SSTV“ gelöscht.")) { model.delete(url) }
                            }
                        }
                }
            }
            .padding(10)
        }
        .deleteConfirmation($pendingDelete)
        .overlay {
            if model.gallery.isEmpty {
                ContentUnavailableView("Noch keine Bilder", systemImage: "photo.stack",
                                       description: Text("Empfangene Bilder erscheinen hier und liegen als PNG im Ordner „SSTV“."))
            }
        }
    }

    // MARK: - Bedienfeld

    private var controls: some View {
        Form {
            Section {
                if hackRFReady {
                    HStack {
                        Button(model.running ? "Stopp" : "Start") {
                            if model.running { model.stop(on: session.hackRF) }
                            else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                        }
                        .buttonStyle(.borderedProminent)
                        .startStopShortcut()
                        Spacer()
                        Button("Leeren") { model.clearFrames() }.disabled(model.frames.isEmpty)
                            .help("Leert die Liste der Rahmen; die SSTV-Bilder der Galerie bleiben.")
                    }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Satellit") {
                Picker("Satellit", selection: $model.satelliteID) {
                    ForEach(AmateurSatellite.catalog) { Text($0.name).tag($0.id) }
                    let own = AmateurSatellite.custom
                    if !own.channels.isEmpty, AmateurSatellite.catalog.allSatisfy({ $0.id != own.id }) {
                        Text(own.name).tag(own.id)
                    }
                }
                .disabled(model.running)
                .onChange(of: model.satelliteID) { _, _ in model.updateDoppler() }
                let sat = model.receiving ?? model.satellite
                ForEach(sat.channels) { channel in
                    LabeledContent(channel.label) {
                        Text("\((channel.frequency / 1e6).formatted(.number.precision(.fractionLength(3)))) MHz · " + channel.mode.title)
                            .font(.caption).monospacedDigit()
                    }
                }
                if !sat.note.isEmpty {
                    Text(sat.note).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Doppler-Korrektur", isOn: $model.dopplerCorrection)
                    .onChange(of: model.dopplerCorrection) { _, _ in model.updateDoppler() }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                if let g = model.geometry {
                    LabeledContent("Position", value: String(localized: "\(g.elevation.formatted(.number.precision(.fractionLength(0))))° hoch · \(GeoMath.compass(g.azimuth)) · \(g.rangeKm.formatted(.number.precision(.fractionLength(0)))) km"))
                    if let hz = model.dopplerHz {
                        LabeledContent("Doppler", value: (hz / 1000).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " kHz")
                    }
                    if g.elevation < 0 {
                        Text("Der Satellit steht gerade unter dem Horizont.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(ReceptionPlanner.home == nil
                         ? "Für die Doppler-Korrektur fehlt dein Standort (Einstellungen)."
                         : "Bahndaten werden geladen …").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Rahmen", value: "\(model.frameCount)")
                LabeledContent("SSTV-Bilder", value: "\(model.imageCount)")
                if !model.levels.isEmpty {
                    LabeledContent("Kanalpegel", value: model.levels.map { "\(($0).formatted(.number.precision(.fractionLength(0))))" }.joined(separator: " / ") + " dBFS")
                }
            }
            Section("Überflüge") {
                let passes = planner.amateurPasses.filter { $0.satellite.id == model.satellite.id }
                if passes.isEmpty {
                    Text(ReceptionPlanner.home == nil ? "Für die Vorhersage fehlt dein Standort (Einstellungen)."
                         : planner.amateurSelection.contains(model.satellite.id) ? "Bahndaten werden geladen …"
                         : "Dieser Satellit ist nicht im Empfangsplan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(passes.prefix(5)) { pass in
                    PassRow(pass: pass, planned: planner.isPlannedAmateur(pass)).font(.callout)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(planner.autoAmateur && planner.amateurSelection.contains(model.satellite.id)
                         ? "Der Empfangsplan empfängt die Überflüge automatisch."
                         : "Automatisch empfangen stellst du im Empfangsplan ein.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Empfangsplan …") { AppNavigation.shared.open(.planner, start: false) }
                        .controlSize(.small)
                }
            }
            CustomSatelliteSection()
            Section(PanelSection.daten) {
                Button("Im Finder zeigen", systemImage: "folder") { NSWorkspace.shared.open(SSTVStore.folder) }
                    .help("Ordner mit den SSTV-Bildern")
            }
        }
        .formStyle(.grouped)
    }
}

/// Einstellungen des Empfangsplans für Amateurfunksatelliten (auch auf der Planseite).
struct AmateurPlanSection: View {
    @Bindable private var planner = ReceptionPlanner.shared

    var body: some View {
        Section("Amateurfunk-Satelliten & ISS") {
            Toggle("Überflüge automatisch empfangen", isOn: $planner.autoAmateur)
            ForEach(satellites) { sat in
                Toggle("\(sat.name) im Empfangsplan", isOn: Binding(
                    get: { planner.amateurSelection.contains(sat.id) },
                    set: { on in if on { planner.amateurSelection.insert(sat.id) } else { planner.amateurSelection.remove(sat.id) } }))
            }
            LabeledContent("Mindesthöhe \(Int(planner.amateurMinElevation))°") {
                Slider(value: $planner.amateurMinElevation, in: 10...60, step: 5)
            }
            Text("Hört von einer Minute vor dem Aufgang bis zum Untergang auf allen Kanälen mit und speichert Bilder als PNG. Bei Überschneidungen hat METEOR Vorrang, dann Amateurfunk, dann Radiosonden.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var satellites: [AmateurSatellite] {
        let own = AmateurSatellite.custom
        let extra = !own.channels.isEmpty && AmateurSatellite.catalog.allSatisfy { $0.id != own.id } ? [own] : []
        return AmateurSatellite.catalog + extra
    }
}

/// Eigener Satellit: Katalognummer (aus der CelesTrak-Gruppe „amateur“),
/// Frequenz und Betriebsart.
private struct CustomSatelliteSection: View {
    @State private var norad = ""
    @State private var mhz = ""
    @State private var mode = AmateurMode.afsk1200
    @State private var note: String?
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup("Eigener Satellit", isExpanded: $expanded) {
                TextField("NORAD-Nummer", text: $norad)
                TextField("Frequenz (MHz)", text: $mhz)
                Picker("Betriebsart", selection: $mode) {
                    ForEach(AmateurMode.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Button("Übernehmen") { save() }
                    Button("Entfernen") {
                        AmateurSatellite.custom = AmateurSatellite(id: AmateurSatellite.customID, name: "Eigener Satellit", channels: [])
                        note = String(localized: "Entfernt.")
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("Für Satelliten, die nicht in der Liste stehen. Frequenz und Betriebsart findest du beim Betreiber oder bei SatNOGS; die Bahndaten holt die App selbst (CelesTrak).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            let own = AmateurSatellite.custom
            if let channel = own.channels.first {
                norad = String(own.id)
                mhz = String(format: "%.4f", channel.frequency / 1e6)
                mode = channel.mode
            }
        }
    }

    private func save() {
        guard let id = Int(norad.trimmingCharacters(in: .whitespaces)), id > 0,
              let f = FrequencyInput.parseMHz(mhz), (30...1_000).contains(f) else {
            note = String(localized: "Bitte eine gültige NORAD-Nummer und eine Frequenz zwischen 30 und 1000 MHz eingeben.")
            return
        }
        let name = ReceptionPlanner.shared.amateurTLE(for: id)?.name.trimmingCharacters(in: .whitespaces)
        AmateurSatellite.custom = AmateurSatellite(
            id: id, name: (name?.isEmpty == false ? name! : "Satellit \(id)"),
            channels: [AmateurChannel(frequency: f * 1e6, mode: mode, label: "Eigener Kanal")])
        note = name == nil ? String(localized: "Gespeichert. Für \(id) gibt es noch keine Bahndaten – steht der Satellit in der CelesTrak-Gruppe „amateur“?") : String(localized: "Gespeichert als \(name!).")
    }
}

/// Vorschaubild der Galerie (lädt das PNG abseits des Main Actors).
private struct GalleryTile: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 115)
            Text(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "SSTV_", with: ""))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: url) {
            let url = url
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
