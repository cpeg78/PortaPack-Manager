import AppKit
import SwiftUI

struct SpectrumView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.spectrum

    @State private var activePreset: String?
    @State private var channelPlan: SpectrumPresets.ChannelPlan?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "waveform.path.ecg", text: "Das Spektrum zeigt, wo gerade gesendet wird. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    SpectrumPlot(model: model)
                        .spectrumActions(model: model, device: session.hackRF)
                        .frame(minHeight: 160, idealHeight: 260)
                    waterfall
                        .spectrumActions(model: model, device: session.hackRF)
                        .frame(minHeight: 120)
                }
            } controls: {
                settings
            }
            .task { if AppNavigation.shared.takeAutoStart(.spectrum), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop(on: nil) }
            }
        }
    }

    private var waterfall: some View {
        GeometryReader { geometry in
            if let image = model.waterfall {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            } else {
                Color.black
            }
        }
        .background(.black)
        .accessibilityElement()
        .accessibilityLabel("Wasserfall")
        .accessibilityValue("Verlauf des Spektrums über die Zeit, neueste Zeile oben")
    }

    private var settings: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop(on: session.hackRF) }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Frequenz") {
                HStack {
                    FrequencyField(mhz: model.centerMHz, width: nil) { applyFrequency($0) }
                    Text("MHz").foregroundStyle(.secondary)
                }
                HStack {
                    Button("−\(stepLabel)") { step(-1) }
                    Button("+\(stepLabel)") { step(1) }
                }
                Menu {
                    ForEach(SpectrumPresets.groups) { group in
                        Menu {
                            ForEach(group.presets) { preset in
                                Button(preset.note.isEmpty
                                       ? "\(preset.name) – \(String(format: "%g", preset.mhz)) MHz"
                                       : "\(preset.name) – \(String(format: "%g", preset.mhz)) MHz (\(preset.note))") {
                                    apply(preset.mhz, bandwidth: preset.bandwidthMHz, label: preset.name)
                                    channelPlan = preset.channels
                                }
                            }
                        } label: {
                            Label(group.title, systemImage: group.symbol)
                        }
                    }
                } label: {
                    Label("Vorlagen", systemImage: "list.star")
                }
                if let channelPlan {
                    Menu {
                        ForEach(channelPlan.channels) { channel in
                            Button(channel.title) {
                                apply(channel.mhz, bandwidth: model.sampleRateMHz, label: String(localized: "\(channelPlan.name), Kanal \(channel.number)"))
                            }
                        }
                    } label: {
                        Label(channelPlan.title, systemImage: channelPlan.symbol)
                    }
                }
                if let activePreset {
                    Text(activePreset).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Bandbreite", selection: $model.sampleRateMHz) {
                    ForEach([2.0, 4.0, 8.0, 10.0, 12.5, 16.0, 20.0], id: \.self) { Text("\(String(format: "%g", $0)) MHz").tag($0) }
                }
                .onChange(of: model.sampleRateMHz) { _, _ in model.applyQuietly(to: session.hackRF) }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            if model.running || model.peak != nil {
                Section(PanelSection.status) {
                    if let peak = model.peak {
                        LabeledContent("Spitze", value: String(format: "%.4f MHz · %.0f dB", peak.mhz, peak.db))
                            .font(.callout.monospacedDigit())
                    }
                    if model.running {
                        LabeledContent("Datenrate", value: String(format: "%.1f MS/s", model.throughput / 1e6))
                            .font(.callout.monospacedDigit())
                    }
                }
            }
            markerSection
            FrequencyMemorySection(page: .spectrum, currentMHz: model.centerMHz) { entry in
                applyFrequency(entry.mhz)
            }
            Section(PanelSection.anzeige) {
                Toggle("Skala automatisch", isOn: $model.autoScale)
                    .help("Die Anzeige folgt dem Rauschboden und dem stärksten Signal. Aus: Grenzen von Hand.")
                if !model.autoScale {
                    LabeledContent("Oben \(Int(model.maxDB)) dB") { Slider(value: $model.maxDB, in: -60...0, step: 5) }
                    LabeledContent("Unten \(Int(model.minDB)) dB") { Slider(value: $model.minDB, in: -130...(-40), step: 5) }
                }
                LabeledContent("Glättung") { Slider(value: $model.averaging, in: 0...0.95) }
            }
        }
        .formStyle(.grouped)
    }

    /// Max-Hold und Marker (⌥-Klick) mit Ablesung und Abstand zu Marker 1.
    private var markerSection: some View {
        Section("Marker & Max-Hold") {
            HStack {
                Toggle("Max-Hold", isOn: $model.maxHoldEnabled)
                    .help("Hält den höchsten Pegel je Frequenz fest (gelbe Linie) – zeigt auch kurze Aussendungen.")
                Spacer()
                Button("Zurücksetzen") { model.resetMaxHold() }
                    .disabled(!model.maxHoldEnabled)
            }
            HStack {
                Button("Marker auf Spitze") { model.markerToPeak() }
                    .disabled(model.peak == nil)
                Spacer()
                Button("Alle entfernen") { model.clearMarkers() }
                    .disabled(model.markers.isEmpty)
            }
            let reference = model.markers.first { $0.id == 1 }
            let referenceLevel = reference.flatMap { model.level(at: $0.mhz) }
            ForEach(model.markers) { marker in
                let level = model.level(at: marker.mhz)
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "M\(marker.id)").font(.callout.weight(.bold)).foregroundStyle(SpectrumPlot.markerColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: FrequencyInput.format(marker.mhz, decimals: 4) + " MHz · "
                             + (level.map { "\(Int($0.rounded())) dB" } ?? String(localized: "außerhalb")))
                            .monospacedDigit()
                        if let delta = SpectrumMath.delta(of: marker, reference: reference, level: level, referenceLevel: referenceLevel) {
                            Text(verbatim: "Δ " + (delta.mhz * 1000).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " kHz"
                                 + (delta.db.map { " · " + $0.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " dB" } ?? ""))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { model.removeMarker(marker.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Marker entfernen")
                        .accessibilityLabel("Marker entfernen")
                }
            }
            Text("Klick stimmt ab, ⌥-Klick setzt einen Marker (bis zu vier), Rechtsklick: im Radio hören, merken.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stepLabel: String { "\(String(format: "%g", model.sampleRateMHz / 2)) MHz" }

    private func step(_ direction: Double) {
        model.tune(to: model.centerMHz + direction * model.sampleRateMHz / 2, device: session.hackRF)
    }

    /// Vorlage anwenden: Mitte und Bandbreite setzen, Wasserfall neu beginnen.
    private func apply(_ mhz: Double, bandwidth: Double, label: String) {
        if model.sampleRateMHz != bandwidth {
            model.sampleRateMHz = bandwidth
            model.applyQuietly(to: session.hackRF)
        }
        model.tune(to: mhz, device: session.hackRF)
        activePreset = label
    }

    private func applyFrequency(_ mhz: Double) {
        activePreset = nil
        channelPlan = nil
        model.tune(to: mhz, device: session.hackRF)
    }
}

/// Klicks in Spektrum und Wasserfall: Klick stimmt ab, ⌥-Klick setzt einen
/// Marker, Rechtsklick bietet „Im Radio hören“ und „Merken“ für die Frequenz
/// unter dem Zeiger.
private struct SpectrumActions: ViewModifier {
    let model: SpectrumModel
    let device: HackRFDevice?
    /// Frequenz unter dem Zeiger (für Kontextmenü und Anzeige).
    @State private var hoverMHz: Double?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    let mhz = frequency(at: value.location.x, width: geometry.size.width)
                    if NSEvent.modifierFlags.contains(.option) { model.placeMarker(at: mhz) }
                    else { model.tune(to: mhz, device: device) }
                })
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location): hoverMHz = frequency(at: location.x, width: geometry.size.width)
                    case .ended: hoverMHz = nil
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let hoverMHz {
                        Text(verbatim: FrequencyInput.format(hoverMHz, decimals: 4) + " MHz")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu {
                    if let mhz = hoverMHz {
                        let mode = FrequencyMemory.suggestedRadioMode(mhz: mhz)
                        Button("Im Radio hören (\(FrequencyInput.format(mhz, decimals: 4)) MHz, \(mode.title))") {
                            AppNavigation.shared.openRadio(mhz: mhz, mode: mode)
                        }
                        Button("Merken") {
                            FrequencyMemory.shared.add(FrequencyMemoryEntry(mhz: (mhz * 1e4).rounded() / 1e4, mode: mode.rawValue, page: .spectrum))
                        }
                        Divider()
                        Button("Hierher abstimmen") { model.tune(to: mhz, device: device) }
                        Button("Marker setzen") { model.placeMarker(at: mhz) }
                        Button("Marker auf Spitze") { model.markerToPeak() }
                        if !model.markers.isEmpty {
                            Button("Alle Marker entfernen") { model.clearMarkers() }
                        }
                    }
                }
        }
    }

    private func frequency(at x: Double, width: Double) -> Double {
        let fraction = width > 0 ? min(max(x / width, 0), 1) : 0.5
        return model.centerMHz + (fraction - 0.5) * model.sampleRateMHz
    }
}

private extension View {
    func spectrumActions(model: SpectrumModel, device: HackRFDevice?) -> some View {
        modifier(SpectrumActions(model: model, device: device))
    }
}

/// Spektrum als Linie mit Raster und Frequenzachse, dazu Max-Hold und Marker.
private struct SpectrumPlot: View {
    static let markerColor = Color.orange
    let model: SpectrumModel

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .background(Color.black)
        .accessibilityElement()
        .accessibilityLabel("Spektrum")
        .accessibilityValue(accessibilitySummary)
    }

    /// Kurzbeschreibung für VoiceOver: Bereich und stärkste Stelle.
    private var accessibilitySummary: String {
        let span = String(localized: "\(FrequencyInput.format(model.centerMHz - model.sampleRateMHz / 2, decimals: 3)) bis \(FrequencyInput.format(model.centerMHz + model.sampleRateMHz / 2, decimals: 3)) MHz")
        guard let peak = model.peak else { return span }
        return String(localized: "\(span), stärkstes Signal bei \(FrequencyInput.format(peak.mhz, decimals: 3)) MHz mit \(Int(peak.db.rounded())) dBFS")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plotHeight = size.height - 18
        let low = model.minDB, high = model.maxDB
        let grid = Color.white.opacity(0.12)

        // Pegelraster alle 10 dB
        var level = (low / 10).rounded(.up) * 10
        while level <= high {
            let y = plotHeight * (1 - (level - low) / (high - low))
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(grid))
            context.draw(Text("\(Int(level))").font(.caption2).foregroundStyle(.white.opacity(0.5)), at: CGPoint(x: 4, y: y), anchor: .leading)
            level += 10
        }
        // Frequenzachse: 5 Marken
        for i in 0...4 {
            let fraction = Double(i) / 4
            let x = size.width * fraction
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: plotHeight)) }, with: .color(grid))
            let mhz = model.centerMHz + (fraction - 0.5) * model.sampleRateMHz
            context.draw(Text(String(format: "%.3f", mhz)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7)),
                         at: CGPoint(x: min(max(x, 30), size.width - 30), y: size.height - 8))
        }

        let values = model.spectrum
        guard values.count > 1 else {
            context.draw(Text(model.running ? "Warte auf Daten …" : "Start drücken").foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: size.width / 2, y: plotHeight / 2))
            return
        }
        var path = Path()
        var fill = Path()
        fill.move(to: CGPoint(x: 0, y: plotHeight))
        for (i, value) in values.enumerated() {
            let x = size.width * Double(i) / Double(values.count - 1)
            let clamped = min(max(Double(value), low), high)
            let y = plotHeight * (1 - (clamped - low) / (high - low))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            fill.addLine(to: CGPoint(x: x, y: y))
        }
        fill.addLine(to: CGPoint(x: size.width, y: plotHeight))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(Gradient(colors: [.cyan.opacity(0.35), .cyan.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: plotHeight)))
        context.stroke(path, with: .color(.cyan), lineWidth: 1)

        // Max-Hold als eigene Kurve
        let held = model.maxHold
        if held.count > 1 {
            var holdPath = Path()
            for (i, value) in held.enumerated() {
                let x = size.width * Double(i) / Double(held.count - 1)
                let y = plotHeight * (1 - (min(max(Double(value), low), high) - low) / (high - low))
                if i == 0 { holdPath.move(to: CGPoint(x: x, y: y)) } else { holdPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(holdPath, with: .color(.yellow.opacity(0.8)), lineWidth: 1)
        }

        // Marker: senkrechte Linie, Dreieck auf dem Pegel, Nummer
        let lowMHz = model.centerMHz - model.sampleRateMHz / 2
        for marker in model.markers {
            let fraction = (marker.mhz - lowMHz) / model.sampleRateMHz
            guard (0...1).contains(fraction) else { continue }
            let x = size.width * fraction
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: plotHeight)) },
                           with: .color(Self.markerColor.opacity(0.5)), lineWidth: 1)
            if let level = model.level(at: marker.mhz) {
                let y = plotHeight * (1 - (min(max(Double(level), low), high) - low) / (high - low))
                context.fill(Path { p in
                    p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - 5, y: y - 9)); p.addLine(to: CGPoint(x: x + 5, y: y - 9)); p.closeSubpath()
                }, with: .color(Self.markerColor))
                context.draw(Text(verbatim: "M\(marker.id)").font(.caption2.weight(.bold)).foregroundStyle(Self.markerColor),
                             at: CGPoint(x: x, y: max(y - 16, 8)))
            }
        }

        // Mittenmarke
        let mid = size.width / 2
        context.stroke(Path { $0.move(to: CGPoint(x: mid, y: 0)); $0.addLine(to: CGPoint(x: mid, y: plotHeight)) },
                       with: .color(.red.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}
