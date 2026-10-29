import SwiftUI

struct DCF77View: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.dcf77

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "clock", text: "Die Zeit der Funkuhren (DCF77, 77,5 kHz) empfängt die App selbst. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 320, issue: model.error) {
                display.frame(minWidth: 480)
            } controls: {
                controls
            }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    // MARK: - Anzeige

    private var display: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                clock
                GroupBox("Sekunden der laufenden Minute") { bitStrip.padding(.vertical, 4) }
                GroupBox("Hüllkurve (letzte 20 s)") { envelope.frame(height: 90) }
                if let time = model.status.time { fields(time) }
            }
            .padding()
        }
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let time = model.status.time {
                Text(String(format: "%02d:%02d", time.hour, time.minute))
                    .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                Text("\(time.weekdayName), \(String(format: "%02d.%02d.20%02d", time.day, time.month, time.year)) · \(time.zoneName)")
                    .font(.title3)
                if let offset = model.status.clockOffset {
                    Text(Self.clockText(offset))
                        .font(.callout).foregroundStyle(abs(offset) < 0.5 ? Color.secondary : Color.orange)
                }
                if let date = model.status.timeDate {
                    Text("Empfangen um \(date, format: .dateTime.hour().minute().second())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("--:--")
                    .font(.system(size: 64, weight: .light, design: .rounded)).foregroundStyle(.secondary)
                Text(statusText).font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard model.running else { return String(localized: "Klicke auf „Start“, um die Funkuhr-Zeit zu empfangen.") }
        if !model.status.locked {
            let snr = model.status.snrDB.formatted(.number.precision(.fractionLength(0)))
            return String(localized: "Suche den Sekundentakt … (Signal \(snr) dB über dem Rauschen)")
        }
        return String(localized: "Sekundentakt gefunden – warte auf eine ganze Minute (\(model.status.bits.count) von 59 Bits)")
    }

    static func clockText(_ offset: TimeInterval) -> String {
        let ms = Int((abs(offset) * 1000).rounded())
        if ms < 20 { return String(localized: "Die Uhr des Mac stimmt (Abweichung unter 20 ms).") }
        let amount = ms < 2000 ? "\(ms) ms" : abs(offset).formatted(.number.precision(.fractionLength(1))) + " s"
        return offset > 0 ? String(localized: "Die Uhr des Mac geht \(amount) vor.")
                          : String(localized: "Die Uhr des Mac geht \(amount) nach.")
    }

    private var bitStrip: some View {
        let seconds = model.status.seconds
        let lastMarker = seconds.lastIndex { $0.kind == .marker }
        let minute = lastMarker.map { Array(seconds[($0 + 1)...]) } ?? seconds.suffix(60).map { $0 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<60, id: \.self) { k in
                    let second = k < minute.count ? minute[k] : nil
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(second?.kind))
                        .frame(height: 18)
                        .overlay {
                            if k % 10 == 0 { Text("\(k)").font(.system(size: 8)).foregroundStyle(.secondary).offset(y: 16) }
                        }
                        .help(second.map { String(localized: "Sekunde \(k): \($0.lowMS) ms abgesenkt") } ?? String(localized: "Sekunde \(k)"))
                }
            }
            .padding(.bottom, 10)
            HStack(spacing: 14) {
                legend(.zero, "0 (100 ms)"); legend(.one, "1 (200 ms)"); legend(.marker, "Minutenmarke"); legend(.unknown, "unlesbar")
            }
            .font(.caption2)
        }
    }

    private func legend(_ kind: DCF77Decoder.Second.Kind, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color(kind)).frame(width: 10, height: 10); Text(text) }
    }

    private func color(_ kind: DCF77Decoder.Second.Kind?) -> Color {
        switch kind {
        case .zero: .gray
        case .one: .blue
        case .marker: .green
        case .unknown: .red
        case nil: Color.gray.opacity(0.15)
        }
    }

    private var envelope: some View {
        envelopeCanvas
            .accessibilityElement()
            .accessibilityLabel("Hüllkurve des DCF77-Signals")
    }

    private var envelopeCanvas: some View {
        Canvas { context, size in
            let values = model.status.envelope
            guard values.count > 1 else { return }
            // Maßstab nach dem 95-%-Wert statt der Spitze: einzelne Störspitzen
            // stauchen sonst die ganze Kurve, und sie springt bei jedem Update.
            let sorted = values.sorted()
            let peak = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            guard peak > 0 else { return }
            let span = CGFloat(DCF77Decoder.displaySeconds * DCF77Decoder.displayRate - 1)
            let offset = span - CGFloat(values.count - 1)   // neueste Werte rechts, auch wenn der Verlauf noch kürzer ist
            // Sekundenraster
            var grid = Path()
            for second in 1..<DCF77Decoder.displaySeconds {
                let x = size.width * CGFloat(second) / CGFloat(DCF77Decoder.displaySeconds)
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
            var path = Path()
            for (n, v) in values.enumerated() {
                let x = size.width * (offset + CGFloat(n)) / span
                let y = size.height * (1 - CGFloat(min(v / peak, 1.08)) * 0.85) - 2
                if n == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            let threshold = size.height * (1 - 0.55 * 0.85) - 2
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: threshold)); $0.addLine(to: CGPoint(x: size.width, y: threshold)) },
                           with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    private func fields(_ time: DCF77Code.Time) -> some View {
        GroupBox("Inhalt des Telegramms") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Bits 21–28", String(localized: "Minute \(time.minute)"))
                row("Bits 29–35", String(localized: "Stunde \(time.hour)"))
                row("Bits 36–41", String(localized: "Tag \(time.day)"))
                row("Bits 42–44", String(localized: "Wochentag \(time.weekday) (\(time.weekdayName))"))
                row("Bits 45–49", String(localized: "Monat \(time.month)"))
                row("Bits 50–57", String(localized: "Jahr \(String(2000 + time.year))"))
                row("Bits 17/18", time.cest ? String(localized: "MESZ (Sommerzeit)") : String(localized: "MEZ (Normalzeit)"))
                row("Bit 16", time.summerTimeChange ? String(localized: "Zeitumstellung in der kommenden Stunde")
                                                     : String(localized: "keine Zeitumstellung angekündigt"))
                row("Bit 19", time.leapSecondAnnounced ? String(localized: "Schaltsekunde zum Stundenende")
                                                        : String(localized: "keine Schaltsekunde angekündigt"))
                row("Bit 15", time.callBit ? String(localized: "Rufbit gesetzt") : String(localized: "Rufbit nicht gesetzt"))
                row("Bits 1–14", String(localized: "Wetterdaten (verschlüsselt): \(Self.binary(time.civil))"))
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.callout.monospaced())
            Text(value)
        }
    }

    static func binary(_ value: UInt16) -> String {
        (0..<14).map { (value >> $0) & 1 == 1 ? "1" : "0" }.joined()
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
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section("Träger 77,5 kHz") {
                LabeledContent("Rauschabstand", value: "\((model.status.snrDB).formatted(.number.precision(.fractionLength(0)))) dB")
                LabeledContent("Ablage", value: "\((model.status.carrierOffsetHz).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) Hz")
                LabeledContent("Pegel", value: "\((model.status.levelDBFS).formatted(.number.precision(.fractionLength(0)))) dBFS")
            }
            Section("Sekundentakt") {
                LabeledContent("Zustand", value: model.status.locked ? String(localized: "gefunden") : String(localized: "wird gesucht"))
                LabeledContent("Tiefe der Marke", value: "\((model.status.contrast * 100).formatted(.number.precision(.fractionLength(0)))) %")
                LabeledContent("Minuten", value: String(localized: "\(model.status.minutesDecoded) gültig · \(model.status.minutesFailed) verworfen"))
                if let error = model.status.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section(PanelSection.hinweis) {
                Text("DCF77 ist der Zeitsender in Mainflingen bei Frankfurt. Du brauchst eine lange Drahtantenne oder eine aktive Rahmenantenne – die Ferritantenne einer Funkuhr passt nicht.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Zu jeder Sekunde sinkt der Träger für 100 ms (0) oder 200 ms (1), in Sekunde 59 nicht (Minutenmarke). Die 59 Bits tragen die Zeit der folgenden Minute. Unter 1 MHz arbeitet der HackRF außerhalb seiner Spezifikation. Die angezeigte Abweichung der Mac-Uhr enthält die USB-Verzögerung (einige 10 ms).")
            }
        }
        .formStyle(.grouped)
    }
}
