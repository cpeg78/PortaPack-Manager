import AppKit
import SwiftUI

/// Wasserstofflinie (21 cm): Radioastronomie mit dem HackRF.
///
/// Wie der Belegungsmonitor zeigt die Seite gespeicherte Messungen auch ohne
/// Gerät; nur das Messen braucht den HackRF-Modus.
struct HydrogenView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.hydrogen
    @State private var saveName = ""
    @State private var pendingDelete: DeleteConfirmation?
    @State private var now = Date()

    var body: some View {
        ControlsSplit(width: 320, issue: model.error) {
            if session.hackRF == nil, model.current == nil, model.visible.isEmpty {
                // Ohne Gerät und ohne gezeigte Messung die einheitliche Sperre;
                // gespeicherte Messreihen lassen sich im Bedienfeld trotzdem einblenden.
                HackRFRequiredView(systemImage: "sparkles",
                                   text: "Zum Messen muss das PortaPack im HackRF-Modus laufen. Gespeicherte Messreihen blendest du auch so ein – im Bedienfeld unter „Daten & Export“.")
            } else {
                VStack(spacing: 0) {
                    readout
                    HydrogenPlot(model: model)
                }
            }
        } controls: {
            controls
        }
        .task(id: session.hackRF != nil) { autoStart() }
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func autoStart() {
        guard AppNavigation.shared.autoStart == .hydrogen else { return }
        if session.hackRF != nil {
            if AppNavigation.shared.takeAutoStart(.hydrogen), !model.running {
                ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
            }
        } else if session.device != nil, !session.busy {
            Task { await session.enterHackRFMode() }
        }
    }

    // MARK: Kopfzeile

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let current = model.current {
                let curve = model.curve(for: current, lsr: model.currentLSRCorrection)
                if let peak = curve.peak(limit: model.rangeKmS) {
                    let center = curve.centroid(limit: model.rangeKmS) ?? peak.velocity
                    Text(String(format: String(localized: "Linie bei %+.1f km/s (LSR) · Höhe %.2f %% · %.4f MHz"), center, peak.value * 100, peak.mhz))
                        .font(.callout.monospacedDigit())
                        .help("Schwerpunkt über der halben Höhe des höchsten Buckels; die Höhe ist relativ zum Systemrauschen.")
                }
                if let noise = curve.noise(exclude: -model.excludeKmS...model.excludeKmS), noise > 0,
                   let peak = curve.peak(limit: model.rangeKmS) {
                    Text(String(format: String(localized: "Störabstand %.1f"), peak.value / noise))
                        .font(.callout.monospacedDigit()).foregroundStyle(peak.value / noise >= 5 ? .green : .secondary)
                        .help("Linienhöhe geteilt durch das Rauschen außerhalb der Linie. Ab etwa 5 ist die Linie sicher.")
                }
            } else {
                Text("Noch keine Messung – richte die Antenne aus und drück „Start“.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.showVelocity) {
                Text("km/s").tag(true)
                Text("MHz").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Bedienfeld

    private var controls: some View {
        Form {
            startSection
            pointingSection
            Section("Messung") {
                Picker("Verfahren", selection: $model.method) {
                    ForEach(HydrogenMethod.allCases) { Text($0.title).tag($0) }
                }
                .help("Frequenzumschaltung misst abwechselnd neben der Linie und gleicht so den Empfänger aus. Referenzmessung: erst „kalten Himmel“ aufnehmen, dann die Quelle.")
                LabeledContent("Dauer \(Int(model.integrationMinutes)) min") {
                    Slider(value: $model.integrationMinutes, in: 1...120, step: 1)
                }
                if model.method == .frequencySwitching {
                    Picker("Versatz", selection: $model.offsetMHz) {
                        ForEach([0.6, 0.8, 1.0, 1.2], id: \.self) { Text("± \(OccupancyFormat.number($0)) MHz").tag($0) }
                    }
                    .help("Abstand der beiden Empfangsfrequenzen von der Linie. Nutzbar bleibt die Mitte ± (2 MHz − Versatz).")
                    LabeledContent("Umschalten alle \(OccupancyFormat.number(model.switchSeconds)) s") {
                        Slider(value: $model.switchSeconds, in: 0.5...5, step: 0.5)
                    }
                }
                Picker("Auflösung", selection: $model.fftSize) {
                    ForEach([2048, 4096, 8192], id: \.self) { n in
                        Text(String(format: "%d Bins · %.2f km/s", n, HydrogenModel.sampleRate / Double(n) / HydrogenAstronomy.restFrequencyHz * HydrogenAstronomy.speedOfLight)).tag(n)
                    }
                }
            }
            .disabled(model.running)
            gainSection
            statusSection
            Section(PanelSection.anzeige) {
                LabeledContent("Glättung \(OccupancyFormat.number(model.smoothingKHz)) kHz") {
                    Slider(value: $model.smoothingKHz, in: 0...50, step: 1)
                }
                Picker("Grundlinie", selection: $model.baselineOrder) {
                    Text("aus").tag(-1)
                    Text("Versatz").tag(0)
                    Text("Gerade").tag(1)
                    Text("Polynom 2. Grades").tag(2)
                    Text("Polynom 3. Grades").tag(3)
                }
                LabeledContent("Linienbereich ± \(Int(model.excludeKmS)) km/s") {
                    Slider(value: $model.excludeKmS, in: 50...250, step: 10)
                }
                .help("Die Grundlinie wird nur außerhalb dieses Bereichs angepasst.")
                Picker("Anzeigebereich", selection: $model.rangeKmS) {
                    ForEach([100.0, 150, 200, 250, 400], id: \.self) { Text("± \(Int($0)) km/s").tag($0) }
                }
            }
            measurementsSection
            Section(PanelSection.hinweis) {
                Text("Was du brauchst").font(.subheadline.weight(.semibold))
                Text("Eine Schüssel (ab etwa 1 m) oder Hornantenne für 1420 MHz mit rauscharmem Vorverstärker („H-Line“-LNA). Richte sie auf die Milchstraße – mehr Minuten bedeuten weniger Rauschen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Die Linie ist ein winziger Buckel im Rauschen, oft unter 1 % des Systemrauschens. Den LNA versorgst du über die Antennenspeisung (Bias-Tee).")
            }
        }
        .deleteConfirmation($pendingDelete)
        .formStyle(.grouped)
    }

    private var startSection: some View {
        Section {
            if model.method == .reference {
                HStack {
                    Button(model.running && model.capture == .reference ? "Stopp" : "Referenz aufnehmen") {
                        if model.running { model.stop() } else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device, capture: .reference) } }
                    }
                    .disabled(session.hackRF == nil || (model.running && model.capture != .reference))
                    if model.hasReference {
                        Text(String(format: String(localized: "Referenz %.0f s"), model.referenceSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .help("Antenne auf ein Himmelsstück ohne Milchstraße richten (oder statt der Antenne einen 50-Ω-Abschluss anschließen) und aufnehmen.")
            }
            HStack {
                if model.running && model.capture == .signal {
                    Button("Stopp") { model.stop() }.buttonStyle(.borderedProminent).startStopShortcut()
                } else {
                    Button(model.canContinue ? "Fortsetzen" : "Start") {
                        ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    .disabled(session.hackRF == nil || model.running || (model.method == .reference && !model.hasReference))
                    if model.canContinue {
                        Button("Neu beginnen") {
                            ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device, fresh: true) }
                        }
                        .disabled(session.hackRF == nil || model.running)
                    }
                }
            }
            if session.hackRF == nil {
                Text("Zum Messen muss das PortaPack im HackRF-Modus laufen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reason = model.pausedReason {
                Label(reason, systemImage: "pause.circle.fill").font(.callout).foregroundStyle(.orange)
            }
            if let saved = model.lastSaved {
                Text(saved).font(.caption).foregroundStyle(.green)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var pointingSection: some View {
        Section("Ausrichtung") {
            LabeledContent("Azimut (°)") {
                TextField("", value: $model.azimuth, format: .number.precision(.fractionLength(1)))
                    .multilineTextAlignment(.trailing).frame(width: 80)
            }
            .help("Himmelsrichtung, in die die Antenne zeigt: 0° Nord, 90° Ost, 180° Süd, 270° West.")
            LabeledContent("Elevation (°)") {
                TextField("", value: $model.elevation, format: .number.precision(.fractionLength(1)))
                    .multilineTextAlignment(.trailing).frame(width: 80)
            }
            if let home = model.home, let p = model.pointing(at: now) {
                LabeledContent("Galaktisch", value: String(format: "l = %.1f°, b = %+.1f°", p.galactic.l, p.galactic.b))
                LabeledContent("Äquator (J2000)", value: String(format: "α = %.2f h, δ = %+.1f°", p.j2000.ra / 15, p.j2000.dec))
                LabeledContent("LSR-Korrektur", value: String(format: "%+.2f km/s", p.lsr.total))
                    .help(String(format: String(localized: "Erddrehung %+.2f, Erdbahn %+.2f, Sonnenbewegung %+.2f km/s"), p.lsr.rotation, p.lsr.orbit, p.lsr.solar))
                let plane = HydrogenAstronomy.highestGalacticPlanePoint(latitude: home.latitude, longitude: home.longitude, date: now)
                if plane.horizontal.elevation > 0 {
                    Button(String(format: String(localized: "Milchstraße am höchsten: Az %.0f°, El %.0f° (l = %.0f°)"), plane.horizontal.azimuth, plane.horizontal.elevation, plane.l)) {
                        model.azimuth = (plane.horizontal.azimuth * 10).rounded() / 10
                        model.elevation = (plane.horizontal.elevation * 10).rounded() / 10
                    }
                    .buttonStyle(.link)
                    .help("Übernimmt diese Richtung – dort ist die Linie meist am kräftigsten.")
                }
            } else {
                SettingsHint(.location, "Für galaktische Koordinaten und die LSR-Korrektur braucht die App deinen Standort. Er bleibt auf dem Mac.")
            }
        }
    }

    /// Fortschritt der Integration und Eingangspegel – nur Anzeigen.
    @ViewBuilder
    private var statusSection: some View {
        if model.running || model.signalSeconds > 0 {
            Section(PanelSection.status) {
                ProgressView(value: min(1, model.signalSeconds / max(1, model.targetSeconds))) {
                    Text(model.capture == .reference && model.running
                         ? String(format: String(localized: "Referenz %.0f von %.0f s"), model.referenceSeconds, model.targetSeconds)
                         : String(format: String(localized: "Gemessen %.0f von %.0f s"), model.signalSeconds, model.targetSeconds))
                        .font(.caption.monospacedDigit())
                }
                if model.running, let device = session.hackRF, device.isReceiving(for: model), let levels = device.inputLevels {
                    Text(String(format: String(localized: "Pegel %.0f dBFS · Anschlag %.2f %%"), levels.rmsDBFS, levels.clipped * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(levels.clipped >= 0.001 ? .orange : .secondary)
                }
            }
        }
    }

    /// Eigene Regler statt `ReceiverControls`: bewusst ohne Automatik.
    private var gainSection: some View {
        Section(PanelSection.empfang) {
            LabeledContent("LNA \(Int(model.lnaGain)) dB") {
                Slider(value: $model.lnaGain, in: 0...40, step: 8) { _ in model.applyFromControls(session.hackRF) }
            }
            .help(GainHelp.lna)
            LabeledContent("VGA \(Int(model.vgaGain)) dB") {
                Slider(value: $model.vgaGain, in: 0...62, step: 2) { _ in model.applyFromControls(session.hackRF) }
            }
            .help(GainHelp.vga)
            Toggle("Eingebauter Verstärker (+14 dB)", isOn: $model.amplifier)
                .onChange(of: model.amplifier) { _, _ in model.applyFromControls(session.hackRF) }
                .help(GainHelp.amplifier)
            Toggle("Antennenspeisung (Bias-Tee)", isOn: $model.antennaPower)
                .onChange(of: model.antennaPower) { _, _ in model.applyFromControls(session.hackRF) }
                .help(String(localized: "Versorgt den rauscharmen Vorverstärker (LNA) an der Antenne.") + " " + GainHelp.biasTee)
            Text("Keine Automatik: Die Verstärkung muss während der Messung gleich bleiben. Ideal ist ein Pegel um −30 dBFS ohne Anschlag.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var measurementsSection: some View {
        Section(PanelSection.daten) {
            Text("Messreihen").font(.subheadline.weight(.semibold))
            HStack {
                TextField("Name (optional)", text: $saveName)
                Button("Speichern") {
                    model.saveMeasurement(name: saveName)
                    saveName = ""
                }
                .disabled(model.current == nil)
            }
            ForEach(Array(model.measurements.enumerated()), id: \.element.id) { index, m in
                HStack {
                    Toggle(isOn: Binding(get: { model.visible.contains(m.id) },
                                         set: { if $0 { model.visible.insert(m.id) } else { model.visible.remove(m.id) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).lineLimit(1)
                            Text(String(format: "%.0f min · LSR %+.1f km/s", m.seconds / 60, m.lsrCorrection))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Circle().fill(HydrogenPlot.color(index)).frame(width: 8, height: 8)
                    Button(role: .destructive) {
                        pendingDelete = DeleteConfirmation(
                            title: String(localized: "Messung „\(m.name)“ löschen?"),
                            message: String(localized: "Die Messreihe wird von diesem Mac gelöscht.")) { model.delete(m) }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Messung löschen")
                        .accessibilityLabel("Messung löschen")
                }
            }
            Button("Als CSV exportieren …") { exportCSV() }
                .disabled(model.current == nil && model.visible.isEmpty)
        }
    }

    private func exportCSV() {
        Task {
            guard let url = await SaveSheet.url(name: "wasserstofflinie.csv", types: [.commaSeparatedText]) else { return }
            do { try Data(model.csv().utf8).write(to: url) } catch { NSSound.beep() }
        }
    }
}

/// Spektrum über Geschwindigkeit (LSR) oder Frequenz, mehrere Messungen überlagert.
struct HydrogenPlot: View {
    let model: HydrogenModel

    static let palette: [Color] = [.orange, .green, .pink, .yellow, .purple, .mint, .red, .teal]
    static func color(_ index: Int) -> Color { palette[index % palette.count] }

    private struct Series {
        var curve: HydrogenProcessing.Curve
        var color: Color
        var width: CGFloat
    }

    var body: some View {
        Canvas { context, size in draw(&context, size: size) }
            .background(Color.black)
            .accessibilityElement()
            .accessibilityLabel("Diagramm der Wasserstofflinie")
            .accessibilityValue("Leistung über der Radialgeschwindigkeit, je Messreihe eine Kurve")
    }

    private var series: [Series] {
        var list: [Series] = []
        for (i, m) in model.measurements.enumerated() where model.visible.contains(m.id) {
            list.append(Series(curve: model.curve(for: m.spectrum, lsr: m.lsrCorrection), color: Self.color(i), width: 1))
        }
        if let current = model.current {
            list.append(Series(curve: model.curve(for: current, lsr: model.currentLSRCorrection), color: .cyan, width: 1.5))
        }
        return list
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 56, y: 10, width: max(1, size.width - 66), height: max(1, size.height - 34))
        let all = series
        guard !all.isEmpty else {
            context.draw(Text(model.running ? "Messe … das erste Spektrum erscheint nach wenigen Sekunden." : "Kein Spektrum").foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let velocity = model.showVelocity
        let rest = HydrogenAstronomy.restFrequencyHz / 1e6
        let range = model.rangeKmS
        // x-Bereich: Geschwindigkeit fest, Frequenz entsprechend um die Ruhefrequenz.
        let xLo = velocity ? -range : rest - range / HydrogenAstronomy.speedOfLight * rest
        let xHi = velocity ? range : rest + range / HydrogenAstronomy.speedOfLight * rest
        func xValue(_ c: HydrogenProcessing.Curve, _ i: Int) -> Double { velocity ? c.velocity[i] : c.mhz[i] }
        var yLo = Double.infinity, yHi = -Double.infinity
        for s in all {
            for i in s.curve.values.indices where s.curve.values[i].isFinite {
                let x = xValue(s.curve, i)
                guard x >= min(xLo, xHi), x <= max(xLo, xHi) else { continue }
                yLo = min(yLo, s.curve.values[i]); yHi = max(yHi, s.curve.values[i])
            }
        }
        guard yLo.isFinite, yHi > yLo else { return }
        let pad = (yHi - yLo) * 0.08
        yLo -= pad; yHi += pad
        func px(_ x: Double) -> Double { plot.minX + (x - xLo) / (xHi - xLo) * plot.width }
        func py(_ y: Double) -> Double { plot.maxY - (y - yLo) / (yHi - yLo) * plot.height }
        let grid = Color.white.opacity(0.12), label = Color.white.opacity(0.7)
        // y-Raster in Prozent
        let yStep = OccupancyAxes.niceStep((yHi - yLo) * 100 / 5) / 100
        var y = (yLo / yStep).rounded(.up) * yStep
        while y <= yHi {
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: py(y))); $0.addLine(to: CGPoint(x: plot.maxX, y: py(y))) },
                           with: .color(abs(y) < yStep / 2 ? .white.opacity(0.3) : grid))
            context.draw(Text(String(format: "%.2f %%", y * 100)).font(.caption2.monospacedDigit()).foregroundStyle(label),
                         at: CGPoint(x: plot.minX - 4, y: py(y)), anchor: .trailing)
            y += yStep
        }
        // x-Raster
        let xStep = OccupancyAxes.niceStep((xHi - xLo) / 8)
        var x = (xLo / xStep).rounded(.up) * xStep
        while x <= xHi {
            context.stroke(Path { $0.move(to: CGPoint(x: px(x), y: plot.minY)); $0.addLine(to: CGPoint(x: px(x), y: plot.maxY)) },
                           with: .color(abs(x) < xStep / 2 && velocity ? .white.opacity(0.3) : grid))
            context.draw(Text(velocity ? String(format: "%.0f", x) : String(format: "%.3f", x)).font(.caption2.monospacedDigit()).foregroundStyle(label),
                         at: CGPoint(x: px(x), y: plot.maxY + 9))
            x += xStep
        }
        context.draw(Text(velocity ? "Radialgeschwindigkeit (LSR), km/s – positiv: entfernt sich" : "Himmelsfrequenz, MHz")
            .font(.caption2).foregroundStyle(label), at: CGPoint(x: plot.midX, y: plot.maxY + 20))
        if !velocity {
            let r = px(rest)
            context.stroke(Path { $0.move(to: CGPoint(x: r, y: plot.minY)); $0.addLine(to: CGPoint(x: r, y: plot.maxY)) },
                           with: .color(.red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        // Kurven
        context.clip(to: Path(plot))
        for s in all {
            var path = Path()
            var pen = false
            for i in s.curve.values.indices {
                let v = s.curve.values[i]
                guard v.isFinite else { pen = false; continue }
                let p = CGPoint(x: px(xValue(s.curve, i)), y: py(v))
                if pen { path.addLine(to: p) } else { path.move(to: p); pen = true }
            }
            context.stroke(path, with: .color(s.color), lineWidth: s.width)
        }
    }
}
