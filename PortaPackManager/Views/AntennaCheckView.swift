import SwiftUI

/// Werkzeugseite „Antennen-Check“: ein Knopf misst die wichtigen Bänder und
/// sagt in Alltagssprache, wofür die Antenne taugt.
struct AntennaCheckView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.antennaCheck

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "antenna.radiowaves.left.and.right",
                               text: "Der Antennen-Check misst nacheinander die wichtigsten Bänder – von UKW-Radio bis GPS – und sagt dir, wofür deine Antenne taugt. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if model.running { runningBox }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    results
                }
                .padding()
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onDisappear { model.cancel() }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.cancel() } }
        }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Antennen-Check").font(.largeTitle.weight(.semibold))
            Text("Misst nacheinander die wichtigsten Bänder und sagt dir, wofür deine Antenne taugt. Während des Checks ist der HackRF belegt; was vorher lief, startet danach wieder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button {
                    ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) }
                } label: {
                    Label("Start (ca. \(Int((AntennaBand.totalSeconds / 60).rounded(.up))) min)",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.running)
                Toggle("Antennenspeisung (Bias-Tee)", isOn: $model.antennaPower)
                    .toggleStyle(.checkbox)
                    .disabled(model.running)
                    .help(GainHelp.biasTee)
            }
            Group {
                if GainProfile.externalAmplifier {
                    SettingsHint(.device, "Gemessen wird mit externem LNA.")
                } else {
                    SettingsHint(.device, "Gemessen wird ohne externen LNA.")
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            if ReceptionPlanner.shared.active != nil {
                Label("Gerade läuft eine geplante Aufnahme – der Check würde sie unterbrechen.", systemImage: "calendar.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var runningBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.step).font(.callout)
                    Spacer()
                    Button("Stopp", role: .cancel) { model.cancel() }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Ergebnis

    @ViewBuilder
    private var results: some View {
        let measurements = model.running ? model.partial : (model.result?.measurements ?? [])
        if measurements.isEmpty {
            if !model.running {
                ContentUnavailableView("Noch kein Check", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Schließ deine Antenne an und drück „Start“."))
            }
        } else {
            if !model.running, let result = model.result {
                HStack(spacing: 6) {
                    Text("Gemessen \(result.date, format: .dateTime.day().month().year().hour().minute())")
                    if result.externalAmplifier { Text("· mit externem LNA") }
                    if result.antennaPower { Text("· Antennenspeisung an") }
                    if !result.complete { Text("· abgebrochen, unvollständig").foregroundStyle(.orange) }
                }
                .font(.callout).foregroundStyle(.secondary)
                summary(AntennaCheck.summary(measurements))
            }
            GroupBox("Bänder") {
                VStack(spacing: 0) {
                    ForEach(Array(measurements.enumerated()), id: \.offset) { index, m in
                        if index > 0 { Divider() }
                        bandRow(m)
                    }
                }
            }
        }
    }

    private func summary(_ s: AntennaCheck.Summary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                line("Gut für", s.good, .green)
                line("Knapp für", s.marginal, .orange)
                line("Zu schwach für", s.weak, .red)
                line("Übersteuert bei", s.overloaded, .purple)
                line("Keine Aussage (nichts gesendet)", s.noInformation, .gray)
                if !s.advice.isEmpty {
                    Divider()
                    Text("Empfehlungen").font(.headline)
                    ForEach(s.advice, id: \.self) { advice in
                        Label { Text(advice).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb") }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Zusammenfassung").font(.headline)
        }
    }

    @ViewBuilder
    private func line(_ title: LocalizedStringKey, _ items: [String], _ color: Color) -> some View {
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).bold() + Text(verbatim: ": ").bold() + Text(items.joined(separator: ", "))
            }
        }
    }

    private func bandRow(_ m: AntennaBandMeasurement) -> some View {
        let verdict = AntennaCheck.verdict(for: m)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: m.band.symbol).frame(width: 24).font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(m.band.title).font(.headline)
                    Text(m.band.frequencyText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(verdict.rating.title)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(color(verdict.rating).opacity(0.2), in: Capsule())
                        .foregroundStyle(color(verdict.rating))
                }
                Text(verdict.text).fixedSize(horizontal: false, vertical: true)
                Text(details(m)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 8)
    }

    private func details(_ m: AntennaBandMeasurement) -> String {
        let percent = (m.clipped * 100).formatted(.number.precision(.fractionLength(2)))
        var parts = [String(localized: "Rauschboden \(Int(m.floorDBFS.rounded())) dBFS"),
                     String(localized: "Pegel \(Int(m.rmsDBFS.rounded())) dBFS"),
                     String(localized: "\(percent) % am Anschlag")]
        if let peak = m.burstPeakDB {
            parts.append(String(localized: "Signale bis \(Int(peak.rounded())) dB, \(Int((m.burstsPerSecond ?? 0).rounded()))/s"))
        }
        if m.band != .adsb, m.band != .gps {
            parts.append(String(localized: "\(m.countOver10) Signale > 10 dB"))
            let top = m.signals.prefix(3).map {
                ($0.label.map { "\($0) " } ?? "") + String(format: "%.3f MHz +%.0f dB", $0.mhz, $0.levelDB)
            }
            if !top.isEmpty { parts.append(String(localized: "stärkste: \(top.joined(separator: ", "))")) }
        }
        return parts.joined(separator: " · ")
    }

    private func color(_ rating: AntennaCheck.Rating) -> Color {
        switch rating {
        case .good: .green
        case .marginal: .orange
        case .weak: .red
        case .overloaded: .purple
        case .noInformation: .gray
        }
    }
}
