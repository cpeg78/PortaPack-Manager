import AppKit
import SwiftUI

struct OverviewView: View {
    @Environment(DeviceSession.self) private var session
    @State private var hackRFInfo: HackRFInfo?
    @State private var detailsExpanded = false
    @State private var clockNote: String?
    @State private var showSetup = false
    @State private var troubleshootingExpanded = false
    @State private var pendingAction: DeviceAction?
    /// Was beim Klick lief – für den Text der Rückfrage festgehalten.
    @State private var pendingRunning: String?
    @AppStorage(SetupWizard.doneKey) private var setupDone = false
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0

    var body: some View {
        Form {
            Section("Was möchtest du sehen?") {
                StartTiles()
            }
            Section("Verbindung") {
                LabeledContent("Modus", value: session.mode.title)
                if case let .mayhem(path) = session.mode {
                    LabeledContent("Schnittstelle", value: path)
                }
                if let error = session.connectionError {
                    LabeledContent("Letzter Fehler") {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if session.mode == .disconnected {
                    Text("Schließ das PortaPack per USB an und schalte es ein. Wird es nicht erkannt, hilft „USB neu anmelden“ oder Ab- und wieder Anstecken.")
                        .foregroundStyle(.secondary)
                }
                if session.mode == .sdCard {
                    LabeledContent("Laufwerk") {
                        if let volume = session.sdVolume {
                            Button(volume.path) { NSWorkspace.shared.open(volume) }
                                .buttonStyle(.link)
                        } else {
                            Text("wird eingehängt …").foregroundStyle(.secondary)
                        }
                    }
                    Text("Die SD-Karte ist als Laufwerk am Mac. Zum Beenden drück „Auswerfen & zurück zu Mayhem“ – das Gerät startet dann neu.")
                        .foregroundStyle(.secondary)
                }
                if session.mode == .dfu {
                    Text("Das Gerät ist im DFU-Modus (Notfall-Startmodus). Nach dem Aus- und Einschalten startet es normal wieder mit Mayhem.")
                        .foregroundStyle(.secondary)
                }
            }

            if session.info != nil || hackRFInfo != nil {
                Section {
                    DisclosureGroup("Technische Details", isExpanded: $detailsExpanded) { details }
                }
            }

            Section("Standort") {
                SettingsHint(.location, Self.locationText(lat: homeLat, lon: homeLon))
            }

            Section("Gerät steuern") {
                HStack {
                    Button("Status aktualisieren") { Task { await session.refreshStatus() } }
                        .disabled(session.device == nil)
                    Button("Uhr stellen") {
                        Task {
                            do {
                                try await session.device?.setClock()
                                clockNote = String(localized: "Uhr gestellt ✓")
                            } catch {
                                clockNote = error.localizedDescription
                            }
                            await session.refreshStatus()
                        }
                    }
                    .disabled(session.device == nil)
                    if let clockNote { Text(clockNote).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                HStack {
                    Button("In HackRF-Modus wechseln") { request(.hackRF) }
                        .disabled(session.device == nil || session.busy)
                        .help("Nötig für alle Empfängerseiten dieser App und für andere SDR-Programme. Die Seiten wechseln auch von selbst.")
                    Button("Zurück zu Mayhem (Neustart)") { request(.reboot) }
                        .disabled((session.device == nil && session.hackRF == nil) || session.busy)
                        .help("Startet das PortaPack neu – es meldet sich danach wieder mit Mayhem.")
                    Spacer()
                }
                // Eigene Zeile: in zwei Zeilen waren die Knöpfe bei normaler Fensterbreite abgeschnitten.
                HStack {
                    if session.mode == .sdCard {
                        Button("Auswerfen & zurück zu Mayhem") { Task { await session.ejectSDCard() } }
                            .disabled(session.busy)
                    } else {
                        Button("SD-Karte als Laufwerk") { request(.sdCard) }
                            .disabled(session.device == nil || session.busy)
                            .help("Startet „SD over USB“: die Karte erscheint im Finder, ohne sie auszubauen.")
                    }
                    Button("Ersteinrichtung …") { showSetup = true }
                        .help("Antenne, Standort und Frequenzabgleich noch einmal durchgehen.")
                    Spacer()
                }
            }

            // Notfallwerkzeuge eingeklappt – im Alltag braucht sie niemand (Review 29.10.2026).
            Section {
                DisclosureGroup("Fehlerbehebung", isExpanded: $troubleshootingExpanded) {
                    HStack {
                        Button("USB neu anmelden") { request(.usbReset) }
                            .disabled(session.busy)
                            .help("Wirkt wie Ab- und Anstecken. Hilft, wenn die Verbindung zum Gerät hängt.")
                        Button("DFU-Modus …") { request(.dfu) }
                            .disabled(session.device == nil || session.busy)
                            .help("Startet das Gerät im Notfall-Startmodus des Prozessors – nur nötig, wenn sich die Firmware auf keinem anderen Weg erneuern lässt. Aus- und Einschalten führt zurück zu Mayhem.")
                        Spacer()
                    }
                    Text("„USB neu anmelden“ hilft, wenn das Gerät nicht mehr antwortet. Den DFU-Modus brauchst du nur, wenn das Gerät gar nicht mehr startet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSetup) { SetupWizard() }
        .confirmationDialog(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            presenting: pendingAction) { action in
            Button(action.confirmLabel, role: action == .dfu ? .destructive : nil) { perform(action) }
            Button("Abbrechen", role: .cancel) {}
        } message: { action in
            Text(action.message(running: pendingRunning))
        }
        .task {
            // Bestehende Einrichtungen (Standort schon gesetzt) nicht noch einmal fragen.
            if !setupDone, UserDefaults.standard.double(forKey: "homeLat") != 0 { setupDone = true }
            if !setupDone { showSetup = true }
        }
        .task(id: session.mode) {
            if session.mode == .hackRF, let hackRF = session.hackRF {
                hackRFInfo = try? hackRF.readInfo()
            } else {
                hackRFInfo = nil
            }
        }
    }

    /// Gerätebefehle, die laufenden Empfang, Plan-Termine oder den Fernbetrieb
    /// abbrechen würden.
    enum DeviceAction: Identifiable, Equatable {
        case hackRF, reboot, sdCard, usbReset, dfu
        var id: Self { self }

        var title: String {
            switch self {
            case .hackRF: String(localized: "Trotzdem in den HackRF-Modus wechseln?")
            case .reboot: String(localized: "Gerät trotzdem neu starten?")
            case .sdCard: String(localized: "SD-Karte trotzdem als Laufwerk öffnen?")
            case .usbReset: String(localized: "USB trotzdem neu anmelden?")
            case .dfu: String(localized: "Gerät im DFU-Modus starten?")
            }
        }

        var confirmLabel: String {
            switch self {
            case .hackRF: String(localized: "Wechseln")
            case .reboot: String(localized: "Neu starten")
            case .sdCard: String(localized: "Als Laufwerk öffnen")
            case .usbReset: String(localized: "Neu anmelden")
            case .dfu: String(localized: "DFU-Modus starten")
            }
        }

        /// Text der Rückfrage: was gerade läuft, dann was passiert.
        func message(running: String?) -> String {
            let effect = switch self {
            case .dfu: String(localized: "Der DFU-Modus ist nur für Notfälle, etwa wenn sich die Firmware nicht mehr installieren lässt. Das Gerät ist danach für diese App nicht erreichbar; Aus- und Einschalten führt zurück zu Mayhem.")
            default: String(localized: "Das Gerät startet dabei neu bzw. meldet sich neu an – das beendet den laufenden Empfang.")
            }
            guard let running else { return effect }
            return String(localized: "Läuft gerade: \(running)") + "\n\n" + effect
        }
    }

    /// Fragt nach, wenn gerade etwas läuft (bei DFU immer), sonst sofort.
    private func request(_ action: DeviceAction) {
        let running = DeviceArbiter.activeUse(session: session)
        if running == nil, action != .dfu {
            perform(action)
        } else {
            pendingRunning = running
            pendingAction = action
        }
    }

    private func perform(_ action: DeviceAction) {
        Task {
            switch action {
            case .hackRF: await session.enterHackRFMode()
            case .reboot: await session.rebootDevice()
            case .sdCard: await session.shareSDCard()
            case .usbReset: await session.reenumerateUSB()
            case .dfu: await session.rebootToDFU()
            }
        }
    }

    /// Gerätedaten für Fortgeschrittene – standardmäßig eingeklappt.
    @ViewBuilder
    private var details: some View {
        if let info = session.info {
            Text("Mayhem").font(.headline)
            LabeledContent("Version") {
                HStack {
                    Text(info.mayhemVersion).textSelection(.enabled)
                    if let url = info.version.releaseURL {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    }
                }
            }
            LabeledContent("Build", value: info.buildTime)
            LabeledContent("Gerät", value: info.deviceName.isEmpty ? String(localized: "\(info.deviceType.displayName) (angenommen)") : info.deviceName)
            LabeledContent("HackRF-Platine", value: info.hackRFBoardRevision)
            LabeledContent("Referenztakt", value: "\(info.referenceSource), \(info.referenceFrequency)")
            LabeledContent("Uhrzeit (Gerät)", value: session.clock)
            LabeledContent("Kernel", value: info.kernel)
            if !session.radioInfo.isEmpty {
                Text("Funkmodul").font(.headline)
                ForEach(Array(session.radioInfo.enumerated()), id: \.offset) { _, pair in
                    LabeledContent(Self.radioLabel(pair.0), value: Self.radioValue(pair.0, pair.1))
                }
            }
            if !session.systemInfo.isEmpty {
                Text("System").font(.headline)
                ForEach(Array(session.systemInfo.enumerated()), id: \.offset) { _, pair in
                    LabeledContent(pair.0, value: pair.1)
                }
            }
        }
        if let hackRFInfo {
            Text("HackRF").font(.headline)
            LabeledContent("Platine", value: hackRFInfo.boardName)
            LabeledContent("Firmware", value: hackRFInfo.firmwareVersion)
            LabeledContent("Seriennummer", value: hackRFInfo.serialNumber)
            LabeledContent("Part-ID", value: hackRFInfo.partID)
            if let rev = hackRFInfo.boardRevision {
                LabeledContent("Revision", value: "\(rev)")
            }
        }
    }

    /// „Standort: 53,5500° N, 10,0000° O“ bzw. Hinweis, dass er fehlt.
    static func locationText(lat: Double, lon: Double) -> String {
        guard lat != 0 || lon != 0 else {
            return String(localized: "Noch kein Standort – Karten, Entfernungen und der Empfangsplan brauchen ihn.")
        }
        let f = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(4))
        let ns = lat >= 0 ? String(localized: "N", comment: "Himmelsrichtung Nord") : String(localized: "S", comment: "Himmelsrichtung Süd")
        let ew = lon >= 0 ? String(localized: "O", comment: "Himmelsrichtung Ost") : String(localized: "W", comment: "Himmelsrichtung West")
        return String(localized: "Standort: \(abs(lat).formatted(f))° \(ns), \(abs(lon).formatted(f))° \(ew)")
    }

    private static func radioLabel(_ key: String) -> String {
        let map = [
            "receiver_model.target_frequency": String(localized: "Empfänger: Frequenz"),
            "receiver_model.baseband_bandwidth": String(localized: "Empfänger: Bandbreite"),
            "receiver_model.sampling_rate": String(localized: "Empfänger: Abtastrate"),
            "receiver_model.modulation": String(localized: "Empfänger: Modulation"),
            "transmitter_model.target_frequency": String(localized: "Sender: Frequenz"),
            "transmitter_model.baseband_bandwidth": String(localized: "Sender: Bandbreite"),
            "transmitter_model.sampling_rate": String(localized: "Sender: Abtastrate"),
        ]
        return map[key] ?? key
    }

    private static func radioValue(_ key: String, _ value: String) -> String {
        guard key.contains("frequency") || key.contains("bandwidth") || key.contains("sampling_rate"),
              let hz = Double(value) else { return value }
        return FrequencyFormatter.string(hz)
    }
}

enum FrequencyFormatter {
    static func string(_ hz: Double) -> String {
        switch abs(hz) {
        case 1e9...: String(format: "%.6f GHz", hz / 1e9)
        case 1e6...: String(format: "%.4f MHz", hz / 1e6)
        case 1e3...: String(format: "%.2f kHz", hz / 1e3)
        default: String(format: "%.0f Hz", hz)
        }
    }
}
