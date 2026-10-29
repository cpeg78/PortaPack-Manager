import SwiftUI

/// Platzhalter der Mayhem-Seiten (SD-Karte, Bildschirm & Steuerung) – das
/// Gegenstück zu `HackRFRequiredView`. Steht das Gerät im HackRF-Modus, zeigt
/// die Seite nicht mehr „Kein Mayhem-Gerät“, sondern bietet den Weg zurück an
/// und geht ihn von selbst (Schalter `autoHackRFMode`) – aber nur, wenn
/// gerade nichts empfängt: kein Empfänger, kein Plan-Termin, kein Fernbetrieb
/// (Bedienungs-Review 29.10.2026, „Pingpong“ zwischen den Modi).
struct MayhemRequiredView: View {
    @Environment(DeviceSession.self) private var session
    @AppStorage(HackRFRequiredView.autoSwitchKey) private var autoSwitch = true
    @State private var switching = false
    let systemImage: String
    let text: Text

    /// Literale werden übersetzt (wie bei `Text`).
    init(systemImage: String, text: LocalizedStringKey) {
        self.systemImage = systemImage
        self.text = Text(text)
    }

    var body: some View {
        ContentUnavailableView {
            if switching {
                Label { Text("Wechsle zurück in den Mayhem-Modus …") } icon: { ProgressView() }
            } else if session.mode == .hackRF {
                Label("Gerät ist im HackRF-Modus", systemImage: systemImage)
            } else if session.mode == .disconnected {
                Label("PortaPack anschließen", systemImage: "cable.connector")
            } else {
                Label("Mayhem-Modus nötig", systemImage: systemImage)
            }
        } description: {
            if session.mode == .disconnected, !switching {
                Text("Schließ das PortaPack per USB an und schalte es ein.")
                    + Text(verbatim: "\n\n") + text
            } else {
                text
            }
        } actions: {
            if session.mode == .hackRF, !switching {
                MayhemReturnButton(switching: $switching)
                    .frame(maxWidth: 420)
            }
        }
        .task(id: session.mode == .hackRF && session.hackRF != nil) {
            guard autoSwitch, session.mode == .hackRF, session.hackRF != nil, !session.busy,
                  DeviceArbiter.activeUse(session: session) == nil else { return }
            await MayhemReturnButton.switchBack(session: session, switching: $switching)
        }
    }
}

/// „Zurück in den Mayhem-Modus“ samt Hinweis, was gerade läuft. Läuft etwas,
/// heißt der Knopf „Trotzdem …“ und der Hinweis sagt, dass es endet.
struct MayhemReturnButton: View {
    @Environment(DeviceSession.self) private var session
    @Binding var switching: Bool
    /// Was gerade empfängt; der Besitz des Geräts ist nicht beobachtbar, daher im Sekundentakt.
    @State private var running: String?

    var body: some View {
        VStack(spacing: 8) {
            Button(running == nil ? "Zurück in den Mayhem-Modus" : "Trotzdem zurück in den Mayhem-Modus") {
                Task { await Self.switchBack(session: session, switching: $switching) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.busy || switching)
            .help("Startet das PortaPack neu – es meldet sich danach wieder mit Mayhem.")
            if let running {
                Text("Läuft gerade: \(running) Der Wechsel beendet das.")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .task {
            while !Task.isCancelled {
                let now = DeviceArbiter.activeUse(session: session)
                if now != running { running = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Neustart in Mayhem; zeigt Fortschritt, bis sich das Gerät zurückmeldet (höchstens 15 s).
    static func switchBack(session: DeviceSession, switching: Binding<Bool>) async {
        guard !switching.wrappedValue, !session.busy else { return }
        switching.wrappedValue = true
        defer { switching.wrappedValue = false }
        await session.rebootDevice()
        for _ in 0..<30 where session.device == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
