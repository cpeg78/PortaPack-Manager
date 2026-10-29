import AppKit
import SwiftUI

struct MeteorView: View {
    @Environment(DeviceSession.self) private var session
    /// Gehört dem Empfangsplan, damit geplante Überflüge auch ohne offene Seite laufen.
    @Bindable private var model = ReceptionPlanner.shared.meteor
    @Bindable private var planner = ReceptionPlanner.shared
    @State private var zoom = false

    var body: some View {
        ControlsSplit(width: 300, issue: model.error) {
            imagePane
                .frame(minWidth: 480)
        } controls: {
            controls
        }
        // Nur die Wiedergabe endet beim Verlassen – der Empfang läuft weiter.
        .onDisappear { model.stopPlayback() }
        .onChange(of: session.mode) { _, mode in
            if mode != .hackRF { model.stop(on: nil) }
        }
    }

    private var hackRFReady: Bool { session.mode == .hackRF && session.hackRF != nil }

    // MARK: - Bild

    private var imagePane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Darstellung", selection: $model.composite) {
                    ForEach(MeteorComposite.allCases) { composite in
                        Text(composite.title).tag(composite)
                            .foregroundStyle(composite.available(in: model.channels) ? .primary : .secondary)
                    }
                }
                .frame(maxWidth: 260)
                .onChange(of: model.composite) { _, _ in model.compositeChanged() }
                Toggle("Volle Größe", isOn: $zoom)
                Spacer()
                Text(model.snapshot.lines > 0 ? "\(model.snapshot.lines) Zeilen" : "")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            Group {
                if let image = model.image {
                    if zoom {
                        ScrollView([.horizontal, .vertical]) {
                            Image(decorative: image, scale: 1).interpolation(.none)
                        }
                    } else {
                        ScrollView(.vertical) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Noch kein Bild", systemImage: "cloud.sun")
                    } description: {
                        Text(model.busy
                             ? "Das Bild baut sich Zeile für Zeile auf, sobald Daten ankommen."
                             : "Die Wettersatelliten METEOR-M senden bei jedem Überflug Bilder. Klicke auf „Start“, wenn einer über dem Horizont steht – die nächsten Überflüge stehen rechts im Bedienfeld.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(model.image == nil ? 0 : 1))
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
                        .disabled(model.playing)
                        Spacer()
                        Button("Leeren") { model.clear() }
                            .disabled(model.busy)
                    }
                } else {
                    Text("Für den Empfang muss das PortaPack im HackRF-Modus laufen. Aufnahmen kannst du auch ohne auswerten.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("In HackRF-Modus wechseln") { Task { await session.enterHackRFMode() } }
                        .disabled(session.device == nil || session.busy)
                }
                Picker("Frequenz", selection: $model.frequency) {
                    ForEach(MeteorReceiver.frequencies, id: \.self) { f in
                        Text(verbatim: "\((f / 1e6).formatted(.number.precision(.fractionLength(1)))) MHz").tag(f)
                    }
                }
                .onChange(of: model.frequency) { _, _ in model.retune() }
                Picker("Verfahren", selection: $model.signal) {
                    ForEach(MeteorSignal.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: model.signal) { _, _ in model.retune() }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }

            Section(PanelSection.status) {
                HStack(alignment: .top) {
                    ConstellationView(points: model.snapshot.constellation, locked: model.snapshot.locked)
                        .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 4) {
                        status("Signal", model.snapshot.locked)
                            .help("Die App hat den Träger des Satelliten gefunden.")
                        status("Entschlüsselt", model.snapshot.frame.viterbiLocked)
                            .help("Der Fehlerschutz (Viterbi) ist eingerastet.")
                        status("Rahmen", model.snapshot.frame.framesOK > 0 && model.busy)
                        Text("Ablage \(model.snapshot.frequencyOffset, format: .number.precision(.fractionLength(0)).sign(strategy: .always())) Hz")
                        Text("Pegel \(model.snapshot.levelDB, format: .number.precision(.fractionLength(0))) dBFS")
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
                LabeledContent("Rahmen", value: "\(model.snapshot.frame.framesOK)")
                LabeledContent("Prüfsummenfehler", value: "\(model.snapshot.frame.framesFailed)")
                LabeledContent("Pakete", value: "\(model.snapshot.packets)")
                DisclosureGroup("Technische Details") {
                    LabeledContent("Viterbi-BER", value: (model.snapshot.frame.bitErrorRate * 100).formatted(.number.precision(.fractionLength(1))) + " %")
                    LabeledContent("Phasenlage", value: model.snapshot.frame.hypothesis)
                    LabeledContent("RS-korrigierte Bytes", value: "\(model.snapshot.frame.rsCorrectedBytes)")
                    if !model.snapshot.segments.isEmpty {
                        LabeledContent("Kanäle", value: model.snapshot.segments.keys.sorted()
                            .map { "\($0): \(model.snapshot.segments[$0]!)" }.joined(separator: " · "))
                    }
                }
            }

            Section("Überflüge") {
                if let status = planner.status, planner.meteorBusy {
                    Label(status, systemImage: "record.circle").foregroundStyle(.red).font(.caption)
                }
                if planner.passes.isEmpty {
                    Group {
                        if let tleError = planner.tleError {
                            Text(tleError)
                        } else if ReceptionPlanner.home == nil {
                            Text("Für die Vorhersage fehlt dein Standort (Einstellungen).")
                        } else {
                            Text("Bahndaten werden geladen …")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(planner.passes.prefix(5)) { pass in
                    PassRow(pass: pass, planned: planner.isPlanned(pass)).font(.callout)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(planner.autoMeteor
                         ? "Überflüge ab \(Int(planner.minElevation))° empfängt der Empfangsplan automatisch."
                         : "Automatisch empfangen ist im Empfangsplan aus.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Empfangsplan …") { AppNavigation.shared.open(.planner, start: false) }
                        .controlSize(.small)
                }
            }
            Section("Aufnahmen auswerten") {
                if model.playing {
                    ProgressView(value: model.progress)
                    Button("Abbrechen") { model.stopPlayback() }
                }
                if model.recordings.isEmpty {
                    Text("Noch keine passende Aufnahme. Nimm auf der Seite „Aufnahme“ mit Mitte 137,5 MHz und 2–3 MS/s auf.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.recordings) { rec in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rec.name).font(.caption.monospaced())
                            Text(String(format: "%.3f MHz · %.2f MS/s · %.0f s", rec.centerMHz, rec.sampleRateMHz, rec.duration))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dekodieren") { model.play(rec) }
                            .disabled(model.busy)
                    }
                }
                Button("Aktualisieren") { model.refreshRecordings() }
            }

            Section(PanelSection.daten) {
                HStack {
                    Button("Speichern") { model.save() }
                        .disabled(model.channels.isEmpty)
                    Button("Im Finder zeigen", systemImage: "folder") { NSWorkspace.shared.open(MeteorPNG.folder) }
                }
                if !model.savedFiles.isEmpty {
                    Text("\(model.savedFiles.count) PNG gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Nach dem Stopp speichert die App alle Bilder automatisch als PNG. Fehlende Stellen bleiben schwarz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.hinweis) {
                Text("Am besten mit einer V-Antenne: zwei Stäbe à 53 cm, 120° gespreizt, waagerecht in Nord-Süd-Richtung. Nachts zeigt nur Kanal 4 (Infrarot) etwas.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Noch besser ist eine QFH-Antenne (Wendelantenne). Frequenz 137,9 MHz, Ersatz 137,1 MHz.")
            }
        }
        .formStyle(.grouped)
    }

    private func status(_ title: LocalizedStringKey, _ ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? .green : .secondary)
    }
}

/// Streudiagramm der Symbole (vier Wolken auf den Diagonalen bei Rasterung).
struct ConstellationView: View {
    let points: [(Float, Float)]
    let locked: Bool

    var body: some View {
        canvas
            .accessibilityElement()
            .accessibilityLabel("Konstellationsdiagramm")
            .accessibilityValue(locked ? "eingerastet" : "nicht eingerastet")
    }

    private var canvas: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var axes = Path()
            axes.move(to: CGPoint(x: w / 2, y: 0)); axes.addLine(to: CGPoint(x: w / 2, y: h))
            axes.move(to: CGPoint(x: 0, y: h / 2)); axes.addLine(to: CGPoint(x: w, y: h / 2))
            context.stroke(axes, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            let scale = w / 4.5
            let color: Color = locked ? .green : .orange
            for (i, q) in points {
                let x = w / 2 + CGFloat(i) * scale, y = h / 2 - CGFloat(q) * scale
                guard x >= 0, x <= w, y >= 0, y <= h else { continue }
                context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(color.opacity(0.7)))
            }
        }
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }
}
