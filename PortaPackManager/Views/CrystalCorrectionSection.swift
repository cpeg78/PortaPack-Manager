import SwiftUI

/// „Quarzkorrektur (ppm)“: Anzeige, Messen und Zurücksetzen der Quarzablage
/// des HackRF (Schlüssel `frequencyCorrectionPPM`, gilt für alle Empfänger).
/// Stand bis 29.10.2026 als „Frequenzablage des HackRF“ auf der Radio-Seite.
///
/// Gemessen wird an einem starken UKW-Sender. Läuft das Radio gerade auf UKW,
/// misst die Ansicht am eingestellten Sender; sonst gleicht sie automatisch ab
/// (UKW-Suchlauf, stärkster Sender – wie die Ersteinrichtung). Ohne Gerät gibt
/// es nur einen Hinweis.
struct CrystalCorrectionSection: View {
    @Environment(DeviceSession.self) private var session
    @AppStorage("frequencyCorrectionPPM") private var ppm = 0.0
    @State private var calibrating = false
    @State private var result: String?
    private var radio: RadioModel { RemoteHub.shared.radio }

    var body: some View {
        Section("Quarzkorrektur (ppm)") {
            LabeledContent("Aktueller Wert") {
                Text(String(format: "%+.2f ppm", ppm)).monospacedDigit()
            }
            Text("Der Quarz im HackRF geht etwas ungenau – wie eine Uhr, die vorgeht. Die App misst das an einem starken UKW-Sender und gleicht es für alle Empfänger aus.")
                .font(.caption).foregroundStyle(.secondary)
            if radio.running && radio.mode == .wfm {
                measureAtStation
            } else {
                automatic
            }
            HStack {
                Spacer()
                Button("Zurücksetzen") {
                    radio.setCorrection(0)
                    result = nil
                }
                .disabled(ppm == 0 || calibrating || radio.measuring)
            }
        }
    }

    /// Das Radio spielt UKW: am eingestellten Sender messen, Ergebnis übernehmen.
    @ViewBuilder
    private var measureAtStation: some View {
        HStack {
            Button {
                radio.measureOffset()
            } label: {
                Label(radio.measuring
                      ? String(localized: "Misst …")
                      : String(localized: "Am laufenden Sender messen (\(radio.frequencyMHz.formatted(.number.precision(.fractionLength(2)))) MHz)"),
                      systemImage: "scope")
            }
            .disabled(radio.measuring || radio.signalDB < -45)
            if radio.measuring { ProgressView().controlSize(.small) }
        }
        if radio.signalDB < -45 {
            Text("Wähl für die Messung im Radio einen kräftigeren Sender (über −45 dBFS).")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let measurement = radio.measurement {
            HStack {
                Text("Sender auf \(measurement.frequencyMHz.formatted(.number.precision(.fractionLength(2)))) MHz liegt \(String(format: "%+.0f", measurement.offsetHz)) Hz daneben → Korrektur \(String(format: "%+.2f", measurement.ppm)) ppm")
                    .font(.callout.monospacedDigit())
                Spacer()
                Button("Übernehmen") { radio.applyMeasurement() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Kein UKW im Radio: automatisch abgleichen, wenn ein Gerät da ist.
    @ViewBuilder
    private var automatic: some View {
        if session.device == nil && session.hackRF == nil {
            Text("Schließ zum Messen das PortaPack an. Die App wechselt dafür kurz in den HackRF-Modus und sucht selbst einen UKW-Sender (etwa 1 Minute).")
                .font(.caption).foregroundStyle(.secondary)
        } else if radio.running {
            Text("Das Radio spielt gerade keinen UKW-Sender. Schalte auf UKW um, um am laufenden Sender zu messen – oder stopp das Radio und gleich hier automatisch ab.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                Button(calibrating ? "Gleiche ab …" : "Automatisch abgleichen", systemImage: "scope") {
                    Task {
                        calibrating = true
                        result = await Self.calibrate(session: session)
                        calibrating = false
                    }
                }
                .disabled(calibrating || session.busy)
                if calibrating { ProgressView().controlSize(.small) }
            }
            .help("Sucht im UKW-Band den stärksten Sender und misst daran die Abweichung (etwa 1 Minute). Läuft gerade ein anderer Empfänger, startet er danach wieder.")
        }
        if let result { Text(result).font(.callout) }
    }

    /// Automatischer Abgleich (Ersteinrichtung und Einstellungen): bei Bedarf
    /// in den HackRF-Modus wechseln, Gerät ausleihen, UKW-Suchlauf, am
    /// stärksten Sender messen und übernehmen. Liefert einen Satz für die Anzeige.
    static func calibrate(session: DeviceSession) async -> String {
        if let reason = DeviceArbiter.blocker(session: session) {
            return String(localized: "\(reason) Hol den Abgleich danach nach.")
        }
        if session.hackRF == nil, session.device != nil {
            await session.enterHackRFMode()
            for _ in 0..<40 where session.hackRF == nil { try? await Task.sleep(for: .milliseconds(500)) }
        }
        if Task.isCancelled { return String(localized: "Abgleich abgebrochen – nichts geändert.") }
        guard let device = session.hackRF else {
            return String(localized: "Der HackRF-Modus wurde nicht erreicht – hol den Abgleich später in den Einstellungen (Antenne & Gerät) nach.")
        }
        // Ausleihen: Fernzugriff/ADS-B laufen danach weiter, der Plan wartet.
        let text = await DeviceArbiter.borrow { () -> (result: String, takenOver: Bool) in
            let radio = RadioModel()
            radio.volume = 0          // nur messen, nicht rauschen lassen
            let text = await radio.calibrateAutomatically(on: device)
            return (text, radio.lostDevice)
        }
        // Das geteilte Radio-Model (Radio-Seite, Fernzugriff) auf den neuen Wert bringen.
        let shared = RemoteHub.shared.radio
        if shared.correctionPPM != HackRFDevice.frequencyCorrectionPPM {
            shared.setCorrection(HackRFDevice.frequencyCorrectionPPM)
        }
        return text
    }
}
