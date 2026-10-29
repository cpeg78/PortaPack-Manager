import AppKit
import Observation
import SwiftUI

/// Inhalt des Statusmenüs als Momentaufnahme. Wird alle 2 s neu gerechnet, aber
/// nur bei einer Änderung übernommen – das Menü baut sich also nicht im
/// Sekundentakt neu auf (Pegel auf ganze dB, Frequenz auf 0,1 MHz gerundet).
struct MenuBarSnapshot: Equatable {
    var symbol: MenuBarSymbol = .idle
    var device = ""
    var receiving: String?
    var recordings: String?
    var plan = ""
    var planPaused = false
    var remote = ""
    var note: String?
    var canStop = false

    /// „Flugzeuge (ADS-B) · 1090,0 MHz · −23 dBFS“
    nonisolated static func receivingLine(title: String, hz: UInt64?, levelDBFS: Double?) -> String {
        var parts = [title]
        if let hz {
            parts.append(String(localized: "\((Double(hz) / 1e6).formatted(.number.precision(.fractionLength(1)))) MHz"))
        }
        if let levelDBFS, levelDBFS.isFinite {
            parts.append(String(localized: "\(Int(levelDBFS.rounded())) dBFS").replacingOccurrences(of: "-", with: "−"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Hält die Momentaufnahme fürs Statusmenü (Takt 2 s, ab dem Start der App).
@MainActor
@Observable
final class MenuBarStatus {
    static let shared = MenuBarStatus()
    private(set) var snapshot = MenuBarSnapshot()
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {}

    func start(session: DeviceSession) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh(session: session)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh(session: DeviceSession) {
        let next = Self.make(session: session)
        if next != snapshot { snapshot = next }
    }

    private static func make(session: DeviceSession) -> MenuBarSnapshot {
        var s = MenuBarSnapshot()
        let planner = ReceptionPlanner.shared
        let hub = RemoteHub.shared
        let work = RunningWork.current(session: session)

        s.device = session.busy && !session.busyReason.isEmpty
            ? String(localized: "Gerät: \(session.busyReason)")
            : String(localized: "Gerät: \(session.mode.title)")

        let device = session.mode == .hackRF ? session.hackRF : nil
        if let device, device.isReceiving {
            let owner = ReceiverStore.occupant(of: device)
            let title = work.planJob.map { String(localized: "Empfangsplan: \($0)") }
                ?? ReceiverStore.item(of: owner)?.title ?? DeviceArbiter.title(of: owner)
            s.receiving = MenuBarSnapshot.receivingLine(title: title, hz: device.tunedFrequencyHz,
                                                        levelDBFS: device.inputLevels?.rmsDBFS)
        } else if let receiver = work.receiver {
            s.receiving = receiver
        }
        if !work.recordings.isEmpty {
            s.recordings = String(localized: "Nimmt auf: \(work.recordings.formatted(.list(type: .and)))")
        }

        s.planPaused = planner.userPaused
        if let job = planner.active {
            s.plan = String(localized: "Plan: \(job.title) bis \(job.end.formatted(date: .omitted, time: .shortened))")
        } else if planner.userPaused {
            s.plan = String(localized: "Empfangsplan pausiert")
        } else if let next = planner.upcoming.first(where: { !planner.isSkipped($0.id) }) {
            s.plan = String(localized: "Nächster Termin: \(next.title), \(next.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        } else {
            s.plan = String(localized: "Kein Termin geplant")
        }

        if hub.running {
            s.remote = hub.listeners > 0
                ? String(localized: "Fernzugriff an · \(hub.listeners) Hörer")
                : String(localized: "Fernzugriff an")
        } else {
            s.remote = String(localized: "Fernzugriff aus")
        }

        s.note = LoginLaunch.shared.note
        s.canStop = s.receiving != nil || planner.active != nil || hub.remoteMode != nil
        let problem = session.connectionError != nil || LoginLaunch.shared.failed
        s.symbol = MenuBarSymbol.state(problem: problem,
                                       recording: !work.recordings.isEmpty || planner.active != nil,
                                       receiving: s.receiving != nil)
        return s
    }
}

/// Symbol in der Menüleiste: Zustand auf einen Blick, rot bei Aufnahme.
struct MenuBarLabel: View {
    private var status: MenuBarStatus { .shared }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let symbol = status.snapshot.symbol
        Image(nsImage: Self.image(symbol))
            .accessibilityLabel(Text(symbol.accessibilityTitle))
            // Das Hauptfenster muss sich auch aus AppKit (Dock, Wiederöffnen) öffnen lassen.
            .onAppear {
                let open = openWindow
                BackgroundController.shared.openMainWindowAction = { open(id: AppServices.mainWindowID) }
            }
    }

    static func image(_ symbol: MenuBarSymbol) -> NSImage {
        let base = NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: symbol.accessibilityTitle)
            ?? NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
            ?? NSImage()
        switch symbol {
        case .recording, .problem:
            // Farbig: keine Vorlage, sonst färbt macOS das Symbol einfarbig um.
            let color: NSColor = symbol == .recording ? .systemRed : .systemOrange
            let image = base.withSymbolConfiguration(.init(paletteColors: [color])) ?? base
            image.isTemplate = false
            return image
        case .idle, .receiving:
            base.isTemplate = true
            return base
        }
    }
}

/// Inhalt des Statusmenüs (Stil `.menu`: echte Menüeinträge).
struct MenuBarContent: View {
    let session: DeviceSession
    private var status: MenuBarStatus { .shared }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = status.snapshot
        Text(s.receiving ?? String(localized: "Kein Empfang"))
        if let recordings = s.recordings { Text(recordings) }
        Text(s.plan)
        Text(s.remote)
        Text(s.device)
        if let note = s.note { Text(note) }
        Divider()
        Button("PortaPack Manager öffnen") { open() }
        Button("Empfang stoppen") {
            Task {
                await ReceiverStore.shared.stopEverything(session: session)
                MenuBarStatus.shared.refresh(session: session)
            }
        }
        .disabled(!s.canStop)
        Button {
            Task {
                await ReceptionPlanner.shared.setUserPaused(!s.planPaused)
                MenuBarStatus.shared.refresh(session: session)
            }
        } label: {
            if s.planPaused { Text("Empfangsplan fortsetzen") } else { Text("Empfangsplan pausieren") }
        }
        Button("Einstellungen …") {
            AppNavigation.shared.page = .settings
            open()
        }
        Divider()
        // Geht durch `applicationShouldTerminate` – mit Rückfrage, wenn etwas läuft.
        Button("Beenden") { NSApp.terminate(nil) }
    }

    private func open() {
        BackgroundController.shared.openMainWindowAction = { openWindow(id: AppServices.mainWindowID) }
        BackgroundController.shared.showMainWindow()
    }
}
