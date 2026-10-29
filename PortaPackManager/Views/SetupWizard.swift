import SwiftUI

/// Ersteinrichtung in vier kurzen Schritten (einmalig, ≈ 1 min): Antenne,
/// Standort, Quarzabgleich, fertig. Setzt daraus die Vorgaben – vorher musste
/// man „Externer Vorverstärker“ in der Seitenleiste und den Abgleich unter
/// „Frequenzablage des HackRF“ auf der Radio-Seite selbst finden. Seit
/// 29.10.2026 steht beides in den Einstellungen (Antenne & Gerät).
struct SetupWizard: View {
    static let doneKey = "setupDone"

    enum Antenna: String, CaseIterable, Identifiable {
        case telescope, outdoor, amplified
        var id: Self { self }
        var title: String {
            switch self {
            case .telescope: String(localized: "Beiliegende Teleskopantenne")
            case .outdoor: String(localized: "Außenantenne (Dach, Fenster, Balkon)")
            case .amplified: String(localized: "Außenantenne mit Vorverstärker")
            }
        }
        var expectation: String {
            switch self {
            case .telescope: String(localized: "Gut für Radio, DAB+ und nahe Flugzeuge. Schiffe, Wetterballons und Satelliten brauchen meist mehr – am besten draußen.")
            case .outdoor: String(localized: "Gut für Flugzeuge, Schiffe, Radio und Fernsehen. Wetterballons bis etwa 100 km.")
            case .amplified: String(localized: "Die App senkt die Verstärkung überall und lässt den eingebauten Verstärker aus – sonst übersteuert der Empfang.")
            }
        }
    }

    @Environment(DeviceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SetupWizard.doneKey) private var done = false
    @AppStorage(GainProfile.externalAmplifierKey) private var externalAmplifier = false
    @State private var step = 0
    @State private var antenna: Antenna = .telescope
    @State private var calibrating = false
    @State private var calibration: String?
    @State private var calibrationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                switch step {
                case 0: welcome
                case 1: antennaStep
                // Erst hier fragt macOS nach dem Standort – nicht schon beim Programmstart.
                case 2: HomeLocationSection(note: "Für Karten, Entfernungen und den Empfangsplan. Er bleibt auf diesem Mac.",
                                            autoLocate: true)
                default: calibrationStep
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Überspringen") { finish() }
                    .disabled(calibrating)
                Spacer()
                if step > 0 { Button("Zurück") { step -= 1 }.disabled(calibrating) }
                Button(step == 3 ? "Los geht’s" : "Weiter") {
                    if step == 1 { externalAmplifier = antenna == .amplified }
                    if step == 3 { finish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(calibrating)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
        .onAppear { antenna = externalAmplifier ? .amplified : .telescope }
    }

    private var welcome: some View {
        Section {
            Label("Willkommen beim PortaPack Manager", systemImage: "antenna.radiowaves.left.and.right").font(.title2)
            Text("Mit deinem HackRF siehst du Flugzeuge und Schiffe auf der Karte, hörst Radio, empfängst Wetterballons und Satellitenbilder – ohne Fachwissen. Drei kurze Fragen, dann geht es los.")
            LabeledContent("Gerät", value: session.mode == .disconnected ? String(localized: "nicht verbunden – bitte per USB anschließen") : session.mode.title)
        }
    }

    private var antennaStep: some View {
        Section("Welche Antenne hängt am HackRF?") {
            Picker("Antenne", selection: $antenna) {
                ForEach(Antenna.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(antenna.expectation).font(.callout).foregroundStyle(.secondary)
            Text("Später änderbar in den Einstellungen (⌘,) unter Antenne & Gerät: „Externer LNA“.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var calibrationStep: some View {
        Section("Frequenz abgleichen") {
            Text("Der Quarz im HackRF geht etwas ungenau – wie eine Uhr, die vorgeht. Die App misst das an einem UKW-Sender (etwa 1 Minute) und gleicht es für alle Empfänger aus. Das Gerät wechselt dafür in den HackRF-Modus.")
            HStack {
                Button(calibrating ? "Gleiche ab …" : "Jetzt abgleichen", systemImage: "scope", action: calibrate)
                    .disabled(calibrating || (session.device == nil && session.hackRF == nil))
                if calibrating {
                    ProgressView().controlSize(.small)
                    Button("Abbrechen") { calibrationTask?.cancel() }
                }
            }
            if let calibration { Text(calibration).font(.callout) }
            Text("Kein Muss – ohne Abgleich funktioniert fast alles; er hilft vor allem bei schmalen Signalen. Später in den Einstellungen (⌘,) unter Antenne & Gerät, „Quarzkorrektur (ppm)“.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func calibrate() {
        calibrating = true
        calibration = nil
        calibrationTask = Task {
            calibration = await CrystalCorrectionSection.calibrate(session: session)
            calibrating = false
            calibrationTask = nil
        }
    }

    private func finish() {
        done = true
        dismiss()
    }
}
