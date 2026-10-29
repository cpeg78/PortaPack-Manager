import AppKit
import SwiftUI

/// Belegungsmonitor: Langzeitbeobachtung eines Bandes mit Wärmebild
/// (Zeit × Frequenz), Belegung je Frequenz und den aktivsten Frequenzen.
///
/// Die Seite zeigt Aufzeichnungen auch ohne Gerät; nur „Start“ braucht den
/// HackRF-Modus. Der Monitor (`OccupancyMonitor.shared`) läuft weiter, wenn
/// man die Seite verlässt, und pausiert, wenn eine andere Seite den HackRF nimmt.
struct OccupancyView: View {
    @Environment(DeviceSession.self) private var session
    @Bindable private var monitor = ReceiverStore.shared.occupancy
    @State private var heat = OccupancyHeatmapState()
    @AppStorage("occupancyMetric") private var metric = OccupancyMetric.occupancy
    @State private var startText = ""
    @State private var endText = ""
    @State private var tableSelection: Int?
    @State private var confirmDelete: OccupancyStore.Entry?

    var body: some View {
        ControlsSplit(width: 310, issue: monitor.error) {
            if session.hackRF == nil, monitor.recording?.slices.isEmpty != false {
                // Ohne Gerät und ohne geladene Aufzeichnung die einheitliche Sperre;
                // gespeicherte Aufzeichnungen lassen sich im Bedienfeld trotzdem öffnen.
                HackRFRequiredView(systemImage: "chart.bar.xaxis",
                                   text: "Zum Messen muss das PortaPack im HackRF-Modus laufen. Gespeicherte Aufzeichnungen öffnest du auch so – im Bedienfeld unter „Daten & Export“.")
            } else {
                VSplitView {
                    OccupancyHeatmap(monitor: monitor, state: heat, metric: metric)
                        .frame(minHeight: 200, idealHeight: 380)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Belegungs-Wärmebild: Frequenz waagerecht, Zeit senkrecht")
                    OccupancyChart(monitor: monitor, state: heat)
                        .frame(minHeight: 110, idealHeight: 150)
                    activeList
                        .frame(minHeight: 110, idealHeight: 190)
                }
            }
        } controls: {
            controls
        }
        .task(id: session.hackRF != nil) { autoStart() }
        .onAppear { syncTexts() }
    }

    private func autoStart() {
        guard AppNavigation.shared.autoStart == .occupancy else { return }
        if session.hackRF != nil {
            if AppNavigation.shared.takeAutoStart(.occupancy), !monitor.running {
                ReceiverStore.shared.requestStart(monitor, session: session) { device in monitor.start(on: device) }
            }
        } else if session.device != nil, !session.busy {
            Task { await session.enterHackRFMode() }
        }
    }

    private func syncTexts() {
        startText = String(format: "%.4f", monitor.startMHz)
        endText = String(format: "%.4f", monitor.endMHz)
    }

    // MARK: Liste der aktivsten Frequenzen

    private var activeList: some View {
        Table(monitor.active, selection: $tableSelection) {
            TableColumn("Frequenz") { (a: OccupancyAnalysis.ActiveFrequency) in
                Text(String(format: "%.4f MHz", a.mhz)).monospacedDigit()
            }.width(min: 90, ideal: 110)
            TableColumn("Belegung") { (a: OccupancyAnalysis.ActiveFrequency) in
                Text(OccupancyFormat.percent(a.occupancy)).monospacedDigit()
            }.width(min: 60, ideal: 70)
            TableColumn("Spitze") { (a: OccupancyAnalysis.ActiveFrequency) in
                Text(String(format: "+%.0f dB", a.peakAboveFloorDB)).monospacedDigit()
            }.width(min: 50, ideal: 60)
            TableColumn("Zuletzt aktiv") { (a: OccupancyAnalysis.ActiveFrequency) in
                Text(OccupancyFormat.episodes(a.episodes)).lineLimit(1).help(OccupancyFormat.episodes(a.episodes, all: true))
            }
            TableColumn("") { (a: OccupancyAnalysis.ActiveFrequency) in
                Button {
                    openRadio(a.mhz)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Im Radio anhören (pausiert den Monitor)")
                .accessibilityLabel("Im Radio anhören")
            }.width(24)
        }
        .contextMenu(forSelectionType: Int.self) { items in
            if let bin = items.first, let a = monitor.active.first(where: { $0.bin == bin }) {
                Button("Im Radio anhören") { openRadio(a.mhz) }
            }
        } primaryAction: { items in
            if let bin = items.first, let a = monitor.active.first(where: { $0.bin == bin }) { openRadio(a.mhz) }
        }
        .onChange(of: tableSelection) { _, bin in
            if let bin, let a = monitor.active.first(where: { $0.bin == bin }) { heat.selectedMHz = a.mhz }
        }
        .overlay {
            if monitor.active.isEmpty {
                Text(monitor.recording?.slices.isEmpty == false
                     ? "Noch keine Frequenz über der Schwelle."
                     : "Die aktivsten Frequenzen erscheinen nach der ersten Zeitscheibe.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openRadio(_ mhz: Double) {
        AppNavigation.shared.openRadio(mhz: mhz, mode: monitor.radioMode(for: mhz))
    }

    // MARK: Bedienfeld

    private var controls: some View {
        Form {
            Section {
                HStack {
                    if monitor.running {
                        Button("Stopp") { monitor.stop() }
                            .buttonStyle(.borderedProminent)
                            .startStopShortcut()
                    } else {
                        Button(monitor.canContinue && monitor.recording?.slices.isEmpty == false ? "Fortsetzen" : "Start") {
                            ReceiverStore.shared.requestStart(monitor, session: session) { device in monitor.start(on: device) }
                        }
                        .buttonStyle(.borderedProminent)
                        .startStopShortcut()
                        .disabled(session.hackRF == nil)
                        if monitor.canContinue, monitor.recording?.slices.isEmpty == false {
                            Button("Neu beginnen") {
                                ReceiverStore.shared.requestStart(monitor, session: session) { device in monitor.start(on: device, fresh: true) }
                            }
                            .disabled(session.hackRF == nil)
                        }
                    }
                }
                if session.hackRF == nil {
                    Text("Zum Messen muss das PortaPack im HackRF-Modus laufen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = monitor.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            bandSection
            Section("Auswertung") {
                Picker("Zeitscheibe", selection: $monitor.sliceSeconds) {
                    ForEach([10.0, 30, 60, 300, 900], id: \.self) { s in
                        Text(s < 60 ? "\(Int(s)) s" : "\(Int(s / 60)) min").tag(s)
                    }
                }
                .disabled(monitor.running)
                LabeledContent("Schwelle +\(displayInt(monitor.thresholdDB)) dB") {
                    Slider(value: $monitor.thresholdDB, in: 3...30, step: 1)
                }
                .help("Ein Kanal gilt als belegt, wenn er so weit über dem Rauschboden liegt. Wirkt ab dem nächsten Start.")
                .disabled(monitor.running)
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: monitor, device: session.hackRF)
            }
            statusSection
            // Die Belegung misst ein Band – ein Klick spielt den Eintrag im Radio.
            FrequencyMemorySection(page: .occupancy, currentMHz: nil) { FrequencyMemoryActions.listen($0) }
            Section(PanelSection.anzeige) {
                Picker("Wärmebild zeigt", selection: $metric) {
                    ForEach(OccupancyMetric.allCases) { Text($0.title).tag($0) }
                }
            }
            dataSection
            Section(PanelSection.hinweis) {
                Text("Der Monitor läuft weiter, wenn du die Seite verlässt. Braucht ein anderer Empfänger den HackRF, pausiert er – „Fortsetzen“ macht weiter.")
                    .help("Auch der Fernzugriff und der Empfangsplan können ihn pausieren. Die Aufzeichnung bleibt über einen Neustart der App erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Aufzeichnung löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { entry in
            Button("„\(entry.name)“ löschen", role: .destructive) { monitor.delete(entry) }
        }
    }

    @ViewBuilder private var statusText: some View {
        if monitor.running {
            let since = monitor.startedAt?.formatted(date: .omitted, time: .shortened) ?? "–"
            Group {
                if let window = monitor.currentWindowMHz {
                    Text("Läuft seit \(since) · \(monitor.visits) Messungen · Fenster \(window, format: .number.precision(.fractionLength(1))) MHz")
                } else {
                    Text("Läuft seit \(since) · \(monitor.visits) Messungen")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else if let reason = monitor.pausedReason {
            Label(reason, systemImage: "pause.circle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
        if let hint = monitor.settingsHint, !monitor.running {
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bandSection: some View {
        Section("Band") {
            Menu {
                ForEach(OccupancyPreset.all) { preset in
                    Button("\(preset.name) – \(OccupancyFormat.mhz(preset.startMHz))…\(OccupancyFormat.mhz(preset.endMHz)) MHz") {
                        monitor.apply(preset)
                        syncTexts()
                        heat.resetZoom()
                    }
                }
            } label: {
                Label(monitor.presetTitle ?? String(localized: "Eigener Bereich"), systemImage: "list.star")
            }
            LabeledContent("Von (MHz)") {
                TextField("", text: $startText).multilineTextAlignment(.trailing).frame(width: 100)
                    .onSubmit(applyRange)
            }
            LabeledContent("Bis (MHz)") {
                TextField("", text: $endText).multilineTextAlignment(.trailing).frame(width: 100)
                    .onSubmit(applyRange)
            }
            Picker("Raster", selection: $monitor.binKHz) {
                ForEach([2.5, 3.125, 5, 6.25, 8.33, 10, 12.5, 25, 50, 100, 200, 500], id: \.self) { k in
                    Text("\(OccupancyFormat.number(k)) kHz").tag(k)
                }
            }
            let plan = monitor.plan
            Text(planDescription(plan)).font(.caption).foregroundStyle(.secondary)
        }
        .disabled(monitor.running)
    }

    private func planDescription(_ plan: OccupancyPlan) -> String {
        let windows = plan.centers(round: 0).count
        let mbPerDay = Double(OccupancyRecording.recordSize(binCount: plan.binCount)) * 86_400 / monitor.sliceSeconds / 1e6
        let mb = OccupancyFormat.number((mbPerDay * 10).rounded() / 10)
        return plan.isNarrow
            ? String(localized: "\(plan.binCount) Frequenzen in einem festen Fenster. Etwa \(mb) MB am Tag.")
            : String(localized: "\(plan.binCount) Frequenzen in \(windows) Fenstern je Runde. Etwa \(mb) MB am Tag.")
    }

    private func applyRange() {
        let s = FrequencyInput.parseMHz(startText), e = FrequencyInput.parseMHz(endText)
        guard let s, let e, e > s, (1...6000).contains(s), (1...6000).contains(e), e - s <= 1000 else {
            syncTexts()
            return
        }
        monitor.startMHz = s
        monitor.endMHz = e
        monitor.presetName = OccupancyPreset.all.first { abs($0.startMHz - s) < 1e-6 && abs($0.endMHz - e) < 1e-6 }?.id
        heat.resetZoom()
    }

    /// Laufzeit, Pause und die geladene Aufzeichnung – nur Anzeigen.
    private var statusSection: some View {
        Section(PanelSection.status) {
            statusText
            if let rec = monitor.recording {
                LabeledContent("Aufzeichnung", value: rec.name)
                if let first = rec.slices.first, let last = rec.slices.last {
                    LabeledContent("Zeitraum") {
                        Text("\(first.start.formatted(date: .abbreviated, time: .shortened)) – \(last.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                    }
                    LabeledContent("Zeitscheiben", value: "\(rec.slices.count)")
                }
            } else if !monitor.running {
                Text("Keine Aufzeichnung geladen.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Gespeicherte Aufzeichnungen, Speichergrenze und Export.
    private var dataSection: some View {
        Section(PanelSection.daten) {
            if monitor.recording != nil, !monitor.canContinue, !monitor.running {
                Button("Einstellungen dieser Aufzeichnung übernehmen") {
                    monitor.adoptSettingsOfRecording()
                    syncTexts()
                }
            }
            Menu("Gespeicherte Aufzeichnungen") {
                ForEach(monitor.entries) { entry in
                    Button("\(entry.name) · \(entry.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))") {
                        monitor.open(entry.url)
                        heat.resetZoom()
                    }
                }
                if !monitor.entries.isEmpty {
                    Divider()
                    Menu("Löschen") {
                        ForEach(monitor.entries) { entry in
                            Button(entry.name + " · " + entry.modified.formatted(date: .abbreviated, time: .shortened)) { confirmDelete = entry }
                                .disabled(monitor.running && entry.url == monitor.recordingURL)
                        }
                    }
                }
            }
            .disabled(monitor.running)
            .onAppear { monitor.refreshEntries() }
            Picker("Größte Dateigröße", selection: $monitor.maxMB) {
                ForEach([50.0, 200, 500, 1000, 2000], id: \.self) { mb in
                    Text(mb >= 1000 ? "\(Int(mb / 1000)) GB" : "\(Int(mb)) MB").tag(mb)
                }
            }
            .help("Wird die Aufzeichnung größer, fallen die ältesten Zeitscheiben heraus.")
            Group {
                Button("Belegung je Frequenz (CSV) …") { export(monitor.summaryCSV(), name: "belegung.csv") }
                Button("Alle Zeitscheiben (CSV) …") { exportSlices() }
                Button("Wärmebild (PNG) …") { exportPNG() }
            }
            .disabled(monitor.recording?.slices.isEmpty != false)
        }
    }

    // MARK: Export

    /// Alle Zeitscheiben: ein Tag mit 4000 Bins sind Millionen Zeilen. Gebaut wird
    /// abseits des Main Actors, schon während der Sicherungsdialog offen ist.
    private func exportSlices() {
        guard let recording = monitor.recording else { return }
        let text = Task.detached(priority: .userInitiated) { OccupancyMonitor.slicesCSV(recording) }
        Task {
            guard let url = await SaveSheet.url(name: "belegung-zeitscheiben.csv", types: [.commaSeparatedText]) else {
                text.cancel()
                return
            }
            let csv = await text.value
            let written = await Task.detached(priority: .userInitiated) { (try? Data(csv.utf8).write(to: url)) != nil }.value
            if !written { NSSound.beep() }
        }
    }

    private func export(_ text: String, name: String) {
        Task {
            guard let url = await SaveSheet.url(name: name, types: [.commaSeparatedText]) else { return }
            do { try Data(text.utf8).write(to: url) } catch { NSSound.beep() }
        }
    }

    /// Erst fragen, dann im Hintergrund rendern und packen – ein großes Wärmebild
    /// hielt die Oberfläche sonst sekundenlang an (Review 28.10.2026, Y18).
    private func exportPNG() {
        guard let rec = monitor.recording, let summary = monitor.summary else { return }
        let metric = metric
        Task {
            guard let url = await SaveSheet.url(name: "belegung.png", types: [.png]) else { return }
            guard let png = await OccupancyExport.png(recording: rec, summary: summary, metric: metric) else {
                NSSound.beep()
                return
            }
            do { try png.write(to: url) } catch { NSSound.beep() }
        }
    }
}

// MARK: - Darstellung

enum OccupancyMetric: String, CaseIterable, Identifiable {
    case occupancy, peak, mean
    var id: Self { self }
    var title: String {
        switch self {
        case .occupancy: String(localized: "Belegung")
        case .peak: String(localized: "Spitze über Rauschboden")
        case .mean: String(localized: "Mittel über Rauschboden")
        }
    }
    var legend: String {
        switch self {
        case .occupancy: String(localized: "Belegung 0 … 1 … 10 … 100 %")
        case .peak: String(localized: "Spitze 0 … 40 dB über Rauschboden")
        case .mean: String(localized: "Mittel 0 … 30 dB über Rauschboden")
        }
    }
}

enum OccupancyFormat {
    static func number(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 3
        f.minimumFractionDigits = 0
        return f.string(from: v as NSNumber) ?? "\(v)"
    }

    static func mhz(_ v: Double) -> String { number(v) }

    static func percent(_ v: Double) -> String {
        v >= 0.1 ? String(format: "%.0f %%", v * 100) : String(format: "%.1f %%", v * 100).replacingOccurrences(of: ".", with: ",")
    }

    static func episodes(_ list: [OccupancyAnalysis.Episode], all: Bool = false) -> String {
        guard !list.isEmpty else { return "–" }
        let shown = all ? list : Array(list.prefix(3))
        return shown.map { e in
            let sameDay = Calendar.current.isDateInToday(e.start)
            let day = sameDay ? "" : e.start.formatted(.dateTime.day().month()) + " "
            return day + e.start.formatted(date: .omitted, time: .shortened) + "–" + e.end.formatted(date: .omitted, time: .shortened)
        }.joined(separator: ", ")
    }
}

/// Sichtbarer Ausschnitt und Auswahl – gemeinsam für Wärmebild und Diagramm.
@MainActor
@Observable
final class OccupancyHeatmapState {
    /// Sichtbarer Frequenzbereich als Anteil des Bandes (0…1).
    var lo = 0.0
    var hi = 1.0
    /// Zeilen ab der neuesten (oben) und Anzahl sichtbarer Zeilen.
    var rowOffset = 0.0
    var rowsVisible = 180.0
    var selectedMHz: Double?
    var selectedRow: Int?
    var hovering = false
    /// Zeilen des Wärmebilds (für das Mausrad).
    var totalRows = 0

    func resetZoom() {
        lo = 0; hi = 1; rowOffset = 0
    }

    func zoomFrequency(_ factor: Double, around anchor: Double? = nil) {
        let span = hi - lo
        let newSpan = max(0.002, min(1, span / factor))
        let a = anchor ?? (lo + span / 2)
        let t = (a - lo) / max(span, 1e-9)
        lo = a - t * newSpan
        hi = lo + newSpan
        clampFrequency()
    }

    func panFrequency(_ delta: Double) {
        lo += delta; hi += delta
        clampFrequency()
    }

    func clampFrequency() {
        let span = hi - lo
        if lo < 0 { lo = 0; hi = span }
        if hi > 1 { hi = 1; lo = max(0, 1 - span) }
    }

    func zoomTime(_ factor: Double, totalRows: Int) {
        rowsVisible = max(10, min(Double(max(totalRows, 10)) * 1.2, rowsVisible / factor))
        clampTime(totalRows: totalRows)
    }

    func clampTime(totalRows: Int) {
        rowOffset = max(0, min(rowOffset, Double(totalRows) - min(rowsVisible, Double(totalRows))))
    }
}

/// Rendert den sichtbaren Ausschnitt (abseits des Main Actors).
enum OccupancyHeatmapRenderer {
    struct Request: Sendable, Equatable {
        var revision: Int
        var metric: String
        var lo: Double, hi: Double
        var rowOffset: Double, rowsVisible: Double
        var width: Int, height: Int
    }

    struct Picture: @unchecked Sendable {
        var image: CGImage?
    }

    /// Wert einer Zelle 0…1 (`nil` = keine Messung).
    static func value(_ slice: OccupancySlice, bin: Int, metric: OccupancyMetric) -> Float? {
        switch metric {
        case .occupancy:
            guard let o = slice.occupancyFraction(bin) else { return nil }
            return Float(log10(1 + 99 * o) / 2)
        case .peak:
            guard let p = slice.peakDB(bin) else { return nil }
            return max(0, min(1, (p - slice.floorDB) / 40))
        case .mean:
            guard let m = slice.meanDB(bin) else { return nil }
            return max(0, min(1, (m - slice.floorDB) / 30))
        }
    }

    /// Neueste Zeile oben. Je Pixel der höchste Wert der überdeckten Zellen.
    static func render(slices: [OccupancySlice], timeline: OccupancyTimeline, binCount: Int, metric: OccupancyMetric,
                       lo: Double, hi: Double, rowOffset: Double, rowsVisible: Double, width: Int, height: Int,
                       isCancelled: () -> Bool = { false }) -> CGImage? {
        guard width > 0, height > 0, timeline.count > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let binLo = lo * Double(binCount), binSpan = max(1e-9, (hi - lo) * Double(binCount))
        let total = timeline.count
        var column = [Float](repeating: -1, count: width)
        for y in 0..<height {
            // Abgebrochen (neuer Ausschnitt angefordert): nichts mehr rechnen.
            if y % 16 == 0, isCancelled() { return nil }
            // Zeilen ab der neuesten, die dieses Pixel abdeckt.
            let r0 = rowOffset + Double(y) / Double(height) * rowsVisible
            let r1 = rowOffset + Double(y + 1) / Double(height) * rowsVisible
            var first = Int(r0.rounded(.down)), last = max(first, Int(r1.rounded(.up)) - 1)
            first = max(0, first); last = min(total - 1, last)
            for x in 0..<width { column[x] = -2 }    // −2 = außerhalb, −1 = Lücke
            if first <= last {
                for x in 0..<width { column[x] = -1 }
                for fromNewest in first...last {
                    guard let index = timeline.rows[total - 1 - fromNewest] else { continue }
                    let slice = slices[index]
                    guard slice.mean.count == binCount else { continue }
                    for x in 0..<width {
                        let b0 = Int((binLo + Double(x) / Double(width) * binSpan).rounded(.down))
                        let b1 = max(b0, Int((binLo + Double(x + 1) / Double(width) * binSpan).rounded(.up)) - 1)
                        var best: Float = column[x]
                        for b in max(0, b0)...min(binCount - 1, max(0, b1)) {
                            if let v = value(slice, bin: b, metric: metric), v > best { best = v }
                        }
                        column[x] = best
                    }
                }
            }
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = column[x]
                let c: (UInt8, UInt8, UInt8) = v <= -2 ? (12, 12, 12) : v < 0 ? (45, 45, 50) : OccupancyPalette.color(v)
                pixels[o] = c.0; pixels[o + 1] = c.1; pixels[o + 2] = c.2; pixels[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Schwarz → Blau → Cyan → Gelb → Rot → Weiß (wie der Wasserfall des Spektrums).
enum OccupancyPalette {
    static let table: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
        let t = Float(i) / 255
        let stops: [(Float, Float, Float)] = [(0, 0, 0), (0, 0, 0.6), (0, 0.7, 0.9), (0.95, 0.9, 0.1), (0.95, 0.15, 0.1), (1, 1, 1)]
        let scaled = t * Float(stops.count - 1)
        let k = min(Int(scaled), stops.count - 2)
        let f = scaled - Float(k)
        let a = stops[k], b = stops[k + 1]
        return (UInt8((a.0 + (b.0 - a.0) * f) * 255), UInt8((a.1 + (b.1 - a.1) * f) * 255), UInt8((a.2 + (b.2 - a.2) * f) * 255))
    }

    static func color(_ v: Float) -> (UInt8, UInt8, UInt8) { table[Int(max(0, min(1, v)) * 255)] }
}

/// Achsen des Wärmebilds (für Ansicht und PNG-Export).
enum OccupancyAxes {
    static let left: CGFloat = 52
    static let bottom: CGFloat = 18

    static func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: left, y: 0, width: max(1, size.width - left), height: max(1, size.height - bottom))
    }

    /// Frequenz- und Zeitachse. `dates`: Beginn je Zeile (alt → neu).
    static func draw(in context: inout GraphicsContext, size: CGSize, plan: OccupancyPlan, lo: Double, hi: Double,
                     dates: [Date], rowOffset: Double, rowsVisible: Double) {
        let plot = plotRect(size)
        let label = Color.white.opacity(0.75), grid = Color.white.opacity(0.15)
        // Frequenzachse
        let fLo = plan.startMHz + lo * plan.widthMHz, fHi = plan.startMHz + hi * plan.widthMHz
        let step = niceStep((fHi - fLo) / 6)
        var f = (fLo / step).rounded(.up) * step
        while f <= fHi {
            let x = plot.minX + (f - fLo) / (fHi - fLo) * plot.width
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.maxY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY + 4)) }, with: .color(grid))
            context.draw(Text(OccupancyFormat.number((f * 10_000).rounded() / 10_000)).font(.caption2.monospacedDigit()).foregroundStyle(label),
                         at: CGPoint(x: min(max(x, plot.minX + 24), plot.maxX - 24), y: plot.maxY + 10))
            f += step
        }
        // Zeitachse: Uhrzeit an runden Zeitpunkten
        guard dates.count > 1 else { return }
        let total = dates.count
        let rowHeight = plot.height / rowsVisible
        let secondsPerRow = max(1, dates[total - 1].timeIntervalSince(dates[0]) / Double(total - 1))
        let minSpacingRows = max(1, 28 / max(rowHeight, 0.01))
        let interval = [60.0, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800]
            .first { $0 / secondsPerRow >= minSpacingRows } ?? 604800
        var lastLabelRow = -Double.infinity
        let firstRow = max(0, Int(rowOffset)), lastRow = min(total - 1, Int(rowOffset + rowsVisible) + 1)
        guard firstRow <= lastRow else { return }
        for fromNewest in firstRow...lastRow {
            let index = total - 1 - fromNewest
            guard index > 0 else { continue }
            let t = dates[index].timeIntervalSince1970, prev = dates[index - 1].timeIntervalSince1970
            let offset = Double(TimeZone.current.secondsFromGMT(for: dates[index]))
            guard ((t + offset) / interval).rounded(.down) != ((prev + offset) / interval).rounded(.down),
                  Double(fromNewest) - lastLabelRow >= minSpacingRows else { continue }
            lastLabelRow = Double(fromNewest)
            let y = plot.minY + (Double(fromNewest) - rowOffset + 1) * rowHeight
            guard y >= plot.minY, y <= plot.maxY else { continue }
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX - 4, y: y)); $0.addLine(to: CGPoint(x: plot.minX, y: y)) }, with: .color(grid))
            let text = interval >= 86400 || Calendar.current.component(.hour, from: dates[index]) == 0 && Calendar.current.component(.minute, from: dates[index]) < Int(secondsPerRow / 60 + 1)
                ? dates[index].formatted(.dateTime.day().month()) + " " + dates[index].formatted(date: .omitted, time: .shortened)
                : dates[index].formatted(date: .omitted, time: .shortened)
            context.draw(Text(text).font(.caption2.monospacedDigit()).foregroundStyle(label),
                         at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
        }
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let p = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 2.5, 5, 10] where raw <= m * p { return m * p }
        return 10 * p
    }
}

/// Zeit × Frequenz-Wärmebild mit Ziehen, Zoomen (Pinch, ⌘-Mausrad), Mausrad-Bildlauf.
struct OccupancyHeatmap: View {
    let monitor: OccupancyMonitor
    @Bindable var state: OccupancyHeatmapState
    let metric: OccupancyMetric
    @State private var picture = OccupancyHeatmapRenderer.Picture()
    @State private var size = CGSize.zero
    @State private var dragStart: (lo: Double, row: Double)?
    @State private var zoomStart: (lo: Double, hi: Double)?

    private var timeline: OccupancyTimeline {
        OccupancyTimeline(slices: monitor.recording?.slices ?? [], sliceSeconds: monitor.recording?.sliceSeconds ?? 60)
    }

    var body: some View {
        let timeline = timeline
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    let plot = OccupancyAxes.plotRect(size)
                    if let image = picture.image {
                        context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: plot)
                    }
                    if let plan = monitor.recording?.plan {
                        OccupancyAxes.draw(in: &context, size: size, plan: plan, lo: state.lo, hi: state.hi,
                                         dates: timeline.dates, rowOffset: state.rowOffset, rowsVisible: state.rowsVisible)
                        if let mhz = state.selectedMHz {
                            let x = plot.minX + ((mhz - plan.startMHz) / plan.widthMHz - state.lo) / (state.hi - state.lo) * plot.width
                            if x >= plot.minX, x <= plot.maxX {
                                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                                               with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                    }
                    if timeline.count == 0 {
                        context.draw(Text(monitor.running ? "Die erste Zeitscheibe erscheint nach \(displayInt(monitor.sliceSeconds)) s …" : "Noch keine Aufzeichnung – drück „Start“.")
                            .foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: size.width / 2, y: size.height / 2))
                    }
                }
                .background(Color.black)
                .contentShape(Rectangle())
                .gesture(dragGesture(timeline: timeline))
                .simultaneousGesture(magnifyGesture)
                .simultaneousGesture(SpatialTapGesture().onEnded { select(at: $0.location, timeline: timeline) })
                .onContinuousHover { phase in
                    if case .active = phase { state.hovering = true } else { state.hovering = false }
                }
                .background(ScrollWheelArea(onRemove: { [state] in state.hovering = false }) { [state] event in
                    Self.scroll(event, state: state)
                })
                zoomButtons(timeline: timeline)
                    .padding(6)
            }
            .onAppear { size = geometry.size }
            .onChange(of: geometry.size) { _, s in size = s }
        }
        .overlay(alignment: .bottomLeading) {
            Text(metric.legend).font(.caption2).foregroundStyle(.white.opacity(0.6)).padding(.leading, OccupancyAxes.left + 4).padding(.bottom, 20)
        }
        .task(id: request(timeline: timeline)) { await render(timeline: timeline) }
        .onDisappear { state.hovering = false }
    }

    private func request(timeline: OccupancyTimeline) -> OccupancyHeatmapRenderer.Request {
        let plot = OccupancyAxes.plotRect(size)
        return .init(revision: monitor.revision, metric: metric.rawValue, lo: state.lo, hi: state.hi,
                     rowOffset: state.rowOffset, rowsVisible: state.rowsVisible,
                     width: Int(plot.width), height: Int(plot.height))
    }

    private func render(timeline: OccupancyTimeline) async {
        guard let rec = monitor.recording, size.width > OccupancyAxes.left + 4 else {
            picture = .init()
            return
        }
        state.totalRows = timeline.count
        let r = request(timeline: timeline)
        let slices = rec.slices, bins = rec.plan.binCount, metric = metric
        // Der abgelöste Renderlauf erbt den Abbruch von `.task(id:)` nicht von selbst:
        // beim Ziehen und Zoomen liefen früher alle veralteten Läufe zu Ende (Y18).
        let work = Task.detached(priority: .userInitiated) {
            OccupancyHeatmapRenderer.Picture(image: OccupancyHeatmapRenderer.render(
                slices: slices, timeline: timeline, binCount: bins, metric: metric, lo: r.lo, hi: r.hi,
                rowOffset: r.rowOffset, rowsVisible: r.rowsVisible, width: r.width, height: r.height,
                isCancelled: { Task.isCancelled }))
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if !Task.isCancelled { picture = result }
    }

    private func dragGesture(timeline: OccupancyTimeline) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let plot = OccupancyAxes.plotRect(size)
                if dragStart == nil { dragStart = (state.lo, state.rowOffset) }
                guard let start = dragStart else { return }
                let span = state.hi - state.lo
                let newLo = start.lo - value.translation.width / plot.width * span
                state.lo = newLo; state.hi = newLo + span
                state.clampFrequency()
                state.rowOffset = start.row - value.translation.height / plot.height * state.rowsVisible
                state.clampTime(totalRows: timeline.count)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = (state.lo, state.hi) }
                guard let start = zoomStart else { return }
                let plot = OccupancyAxes.plotRect(size)
                let anchor = start.lo + (value.startLocation.x - plot.minX) / plot.width * (start.hi - start.lo)
                state.lo = start.lo; state.hi = start.hi
                state.zoomFrequency(value.magnification, around: anchor)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func zoomButtons(timeline: OccupancyTimeline) -> some View {
        HStack(spacing: 4) {
            Group {
                Button { state.zoomFrequency(0.5) } label: { Image(systemName: "arrow.left.and.right.square") }
                    .help("Frequenz verkleinern")
                    .accessibilityLabel("Frequenz verkleinern")
                Button { state.zoomFrequency(2) } label: { Image(systemName: "arrow.right.and.line.vertical.and.arrow.left") }
                    .help("Frequenz vergrößern (auch Pinch oder ⌘ + Mausrad)")
                    .accessibilityLabel("Frequenz vergrößern (auch Pinch oder ⌘ + Mausrad)")
                Button { state.zoomTime(0.5, totalRows: timeline.count) } label: { Image(systemName: "arrow.up.and.down.square") }
                    .help("Mehr Zeit zeigen (⌥ + Mausrad)")
                    .accessibilityLabel("Mehr Zeit zeigen (⌥ + Mausrad)")
                Button { state.zoomTime(2, totalRows: timeline.count) } label: { Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up") }
                    .help("Weniger Zeit zeigen, größer")
                    .accessibilityLabel("Weniger Zeit zeigen, größer")
                Button { state.resetZoom(); state.rowsVisible = Double(max(60, timeline.count)) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Alles zeigen")
                    .accessibilityLabel("Alles zeigen")
                Button { state.rowOffset = 0 } label: { Image(systemName: "arrow.up.to.line") }
                    .help("Zur neuesten Zeitscheibe")
                    .accessibilityLabel("Zur neuesten Zeitscheibe")
            }
            .buttonStyle(.borderless)
            .padding(4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.white)
        }
    }

    private func select(at point: CGPoint, timeline: OccupancyTimeline) {
        guard let plan = monitor.recording?.plan else { return }
        let plot = OccupancyAxes.plotRect(size)
        guard plot.contains(point) else { return }
        let fraction = state.lo + (point.x - plot.minX) / plot.width * (state.hi - state.lo)
        if let bin = plan.binIndex(forMHz: plan.startMHz + fraction * plan.widthMHz) {
            state.selectedMHz = plan.binCenterMHz(bin)
        }
        let fromNewest = Int(state.rowOffset + (point.y - plot.minY) / plot.height * state.rowsVisible)
        state.selectedRow = (0..<timeline.count).contains(fromNewest) ? timeline.count - 1 - fromNewest : nil
    }

    /// Mausrad: senkrecht = durch die Zeit, waagerecht = durch die Frequenz,
    /// mit ⌘ Frequenz-Zoom, mit ⌥ Zeit-Zoom. Der Monitor (`ScrollWheelArea`) nimmt nur
    /// Ereignisse aus diesem Fenster und über dem Wärmebild an.
    private static func scroll(_ event: ScrollWheelArea.Event, state: OccupancyHeatmapState) -> Bool {
        guard state.hovering else { return false }
        let dy = event.dy * (event.precise ? 1 : 8)
        let dx = event.dx * (event.precise ? 1 : 8)
        let total = state.totalRows
        if event.modifiers.contains(.command) {
            state.zoomFrequency(pow(1.01, dy))
        } else if event.modifiers.contains(.option) {
            state.zoomTime(pow(1.01, dy), totalRows: total)
        } else {
            state.rowOffset -= dy / 10 * max(1, state.rowsVisible / 100)
            state.clampTime(totalRows: total)
            state.panFrequency(-dx / 600 * (state.hi - state.lo))
        }
        return true
    }
}

/// „Belegung je Frequenz“ über den sichtbaren Frequenzbereich, mit Auswahl.
struct OccupancyChart: View {
    let monitor: OccupancyMonitor
    @Bindable var state: OccupancyHeatmapState

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                Canvas { context, size in draw(&context, size: size) }
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap(at: $0.location, width: geometry.size.width) })
                    .accessibilityElement()
                    .accessibilityLabel("Belegung je Frequenz")
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Belegung je Frequenz").font(.caption.weight(.semibold))
            Spacer()
            if let mhz = state.selectedMHz, let rec = monitor.recording, let bin = rec.plan.binIndex(forMHz: mhz) {
                let occ = monitor.summary?.occupancy[safeIndex: bin] ?? nil
                let peak = monitor.summary?.peakAboveFloor[safeIndex: bin] ?? nil
                let parts = [String(format: "%.4f MHz", mhz),
                             String(localized: "Belegung \(occ.map(OccupancyFormat.percent) ?? "–")"),
                             peak.map { String(format: String(localized: "Spitze +%.0f dB"), $0) },
                             rowText(rec, bin: bin)].compactMap { $0 }
                Text(parts.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                Button("Im Radio anhören", systemImage: "play.circle") {
                    AppNavigation.shared.openRadio(mhz: mhz, mode: monitor.radioMode(for: mhz))
                }
                .controlSize(.small)
                .help("Öffnet die Frequenz im Radio – der Monitor pausiert dabei.")
            } else {
                Text("Klick ins Wärmebild, um eine Frequenz zu wählen.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func rowText(_ rec: OccupancyRecording, bin: Int) -> String? {
        let timeline = OccupancyTimeline(slices: rec.slices, sliceSeconds: rec.sliceSeconds)
        guard let row = state.selectedRow, timeline.rows.indices.contains(row), let index = timeline.rows[row] else { return nil }
        let slice = rec.slices[index]
        let time = slice.start.formatted(date: .omitted, time: .shortened)
        let occ = slice.occupancyFraction(bin).map(OccupancyFormat.percent) ?? "–"
        return String(localized: "um \(time): \(occ)")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard let rec = monitor.recording, let summary = monitor.summary else { return }
        let plot = CGRect(x: OccupancyAxes.left, y: 4, width: max(1, size.width - OccupancyAxes.left), height: max(1, size.height - 8))
        let bins = rec.plan.binCount
        let binLo = state.lo * Double(bins), span = (state.hi - state.lo) * Double(bins)
        let width = Int(plot.width)
        var values = [Double](repeating: 0, count: max(width, 1))
        var maxValue = 0.0
        for x in 0..<width {
            let b0 = Int((binLo + Double(x) / Double(width) * span).rounded(.down))
            let b1 = max(b0, Int((binLo + Double(x + 1) / Double(width) * span).rounded(.up)) - 1)
            var best = 0.0
            for b in max(0, b0)...min(bins - 1, max(0, b1)) { best = max(best, summary.occupancy[b] ?? 0) }
            values[x] = best
            maxValue = max(maxValue, best)
        }
        let top = max(0.05, OccupancyAxes.niceStep(maxValue * 1.1))
        // Raster und Beschriftung
        for i in 0...2 {
            let v = top * Double(i) / 2
            let y = plot.maxY - v / top * plot.height
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) }, with: .color(.white.opacity(0.12)))
            context.draw(Text(OccupancyFormat.percent(v)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
        }
        var path = Path()
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for x in 0..<width {
            let y = plot.maxY - values[x] / top * plot.height
            path.addLine(to: CGPoint(x: plot.minX + Double(x), y: y))
            path.addLine(to: CGPoint(x: plot.minX + Double(x + 1), y: y))
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.closeSubpath()
        context.fill(path, with: .color(.orange.opacity(0.75)))
        if let mhz = state.selectedMHz {
            let x = plot.minX + ((mhz - rec.plan.startMHz) / rec.plan.widthMHz - state.lo) / (state.hi - state.lo) * plot.width
            if x >= plot.minX, x <= plot.maxX {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                               with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    private func tap(at point: CGPoint, width: CGFloat) {
        guard let plan = monitor.recording?.plan, point.x >= OccupancyAxes.left else { return }
        let fraction = state.lo + (point.x - OccupancyAxes.left) / max(1, width - OccupancyAxes.left) * (state.hi - state.lo)
        if let bin = plan.binIndex(forMHz: plan.startMHz + fraction * plan.widthMHz) {
            state.selectedMHz = plan.binCenterMHz(bin)
        }
    }
}

fileprivate extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// PNG-Export: ganzes Wärmebild mit Achsen, Titel und Belegungskurve.
/// Wärmebild und PNG-Kodierung laufen abseits des Main Actors; nur das Setzen
/// von Achsen und Titel (`ImageRenderer`) braucht ihn.
@MainActor
enum OccupancyExport {
    static func png(recording: OccupancyRecording, summary: OccupancyAnalysis.Summary, metric: OccupancyMetric) async -> Data? {
        let timeline = OccupancyTimeline(slices: recording.slices, sliceSeconds: recording.sliceSeconds)
        let width = min(3000, max(800, recording.plan.binCount))
        let heatHeight = min(4000, max(300, timeline.count * 2))
        let slices = recording.slices, bins = recording.plan.binCount
        let heat = await Task.detached(priority: .userInitiated) {
            OccupancyHeatmapRenderer.Picture(image: OccupancyHeatmapRenderer.render(
                slices: slices, timeline: timeline, binCount: bins, metric: metric, lo: 0, hi: 1, rowOffset: 0,
                rowsVisible: Double(timeline.count), width: width, height: heatHeight))
        }.value
        guard let image = heat.image else { return nil }
        let first = recording.slices.first?.start.formatted(date: .abbreviated, time: .shortened) ?? ""
        let last = recording.slices.last?.start.formatted(date: .abbreviated, time: .shortened) ?? ""
        let view = VStack(alignment: .leading, spacing: 4) {
            Text("Belegungsmonitor – \(recording.name)").font(.title3.bold())
            Text("\(String(format: "%.4f–%.4f MHz", recording.plan.startMHz, recording.plan.endMHz)) · \(first) – \(last) · \(metric.legend) · Schwelle +\(displayInt(recording.thresholdDB)) dB")
                .font(.caption)
            Canvas { context, size in
                context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: OccupancyAxes.plotRect(size))
                OccupancyAxes.draw(in: &context, size: size, plan: recording.plan, lo: 0, hi: 1, dates: timeline.dates,
                                 rowOffset: 0, rowsVisible: Double(timeline.count))
            }
            .frame(width: CGFloat(width) + OccupancyAxes.left, height: CGFloat(heatHeight) + OccupancyAxes.bottom)
            .background(Color.black)
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let page = OccupancyHeatmapRenderer.Picture(image: renderer.cgImage)
        return await Task.detached(priority: .userInitiated) {
            page.image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }.value
    }
}
