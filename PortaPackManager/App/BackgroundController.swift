import AppKit
import Observation
import os
import ServiceManagement

private let backgroundLog = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Hintergrund")

// MARK: - Was läuft gerade

extension RunningWork {
    /// Momentaufnahme der App – legt keine Models an.
    @MainActor
    static func current(session: DeviceSession) -> RunningWork {
        var work = RunningWork()
        if session.busy {
            work.installing = session.busyReason.isEmpty ? String(localized: "eine Installation") : session.busyReason
        }
        let planner = ReceptionPlanner.shared
        work.planJob = planner.active?.title
        let store = ReceiverStore.shared
        let hub = RemoteHub.shared
        // Aufnahmen
        if let recorder = store.existing(RecorderModel.self), recorder.recording {
            work.recordings.append(String(localized: "IQ-Aufnahme"))
        }
        if let radio = hub.existingOwner(for: .radio) as? RadioModel, radio.audioRecording != nil {
            work.recordings.append(String(localized: "Ton-Aufnahme (Radio)"))
        }
        if hub.dab.audioRecording != nil {
            work.recordings.append(String(localized: "Ton-Aufnahme (DAB+)"))
        }
        if let airband = hub.existingOwner(for: .airband) as? AirbandModel, airband.running, airband.recordAudio {
            work.recordings.append(String(localized: "Flugfunk-Mitschnitt"))
        }
        if let occupancy = hub.existingOwner(for: .occupancy) as? OccupancyMonitor, occupancy.running, occupancy.recording != nil {
            work.recordings.append(String(localized: "Belegungsaufzeichnung"))
        }
        if planner.meteor.running, planner.meteor.recordIQ {
            work.recordings.append(String(localized: "METEOR-IQ-Aufnahme"))
        }
        // Empfänger (ohne den Plan-Termin und ohne die schon genannten Aufnahmen)
        let planModel = planner.active.map(ReceiverStore.planModel(of:))
        if let model = store.runningModels(excluding: planModel).first, let item = ReceiverStore.item(of: model),
           !(item == .recorder) && !(item == .occupancy && work.recordings.contains(String(localized: "Belegungsaufzeichnung"))) {
            work.receiver = item.title
        }
        if hub.running { work.remoteListeners = hub.listeners }
        return work
    }
}

// MARK: - Beenden

/// Rückfrage bei ⌘Q, „Beenden“ in der Menüleiste und beim Abmelden.
@MainActor
enum QuitGuard {
    /// Neustart nach dem Sprachwechsel: Die Einstellungsseite hat schon gefragt.
    static var bypass = false
    /// Abmelden/Ausschalten angekündigt (`NSWorkspace.willPowerOffNotification`).
    static var systemPoweringOff = false

    static func shouldTerminate() -> NSApplication.TerminateReply {
        if bypass { return terminateNow() }
        let systemQuit = systemPoweringOff
            || LaunchContext.eventIsSystemQuit(NSAppleEventManager.shared().currentAppleEvent)
        let work = RunningWork.current(session: AppServices.session)
        switch work.quitDecision(systemQuit: systemQuit) {
        case .quit:
            return terminateNow()
        case .refuse(let message):
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "PortaPack Manager kann gerade nicht beendet werden")
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return .terminateCancel
        case .ask(let message):
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "PortaPack Manager beenden?")
            alert.informativeText = message
            // Erster Knopf = Standard (Eingabetaste): weiterlaufen lassen.
            alert.addButton(withTitle: String(localized: "Im Hintergrund weiterlaufen"))
            alert.addButton(withTitle: String(localized: "Beenden")).hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Abbrechen")).keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                backgroundLog.notice("Beenden abgelehnt – läuft im Hintergrund weiter")
                BackgroundController.shared.enterBackground()
                return .terminateCancel
            case .alertSecondButtonReturn:
                backgroundLog.notice("Beendet trotz laufender Arbeit: \(message, privacy: .public)")
                return terminateNow()
            default:
                return .terminateCancel
            }
        }
    }

    private static func terminateNow() -> NSApplication.TerminateReply {
        // Ab hier ist jedes Ende eines Empfängers Folge des Beendens, kein bewusster
        // Stopp – der Anmeldestart soll ihn wieder aufnehmen.
        ReceiverStore.shared.terminating = true
        return .terminateNow
    }

    /// Kurz vor dem Ende: Dateien sauber abschließen (Kopf der IQ-Aufnahme,
    /// AAC-Container der Ton-Aufnahme).
    static func finishRecordings() {
        ReceiverStore.shared.terminating = true
        if let recorder = ReceiverStore.shared.existing(RecorderModel.self), recorder.recording { recorder.stopRecording() }
        if let radio = RemoteHub.shared.existingOwner(for: .radio) as? RadioModel, radio.audioRecording != nil { radio.stopAudioRecording() }
        if RemoteHub.shared.dab.audioRecording != nil { RemoteHub.shared.dab.stopAudioRecording() }
    }
}

// MARK: - Fenster, Dock, Wiederöffnen

/// Hintergrundbetrieb: ohne Fenster läuft die App weiter; das Dock-Symbol
/// verschwindet dann (Einstellung „Dock-Symbol nur mit offenem Fenster“).
@MainActor
@Observable
final class BackgroundController {
    static let shared = BackgroundController()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Öffnet das Hauptfenster (SwiftUI `openWindow`) – gesetzt von einer Ansicht,
    /// die die Umgebung kennt (Menüleiste, Hauptfenster).
    @ObservationIgnored var openMainWindowAction: (() -> Void)?

    private init() {}

    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Das Fenster zählt beim Schließen noch mit – erst danach zählen.
            Task { @MainActor in BackgroundController.shared.updateActivationPolicy() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in BackgroundController.shared.updateActivationPolicy() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in QuitGuard.systemPoweringOff = true }
        })
    }

    /// Fenster, die für „die App ist offen“ zählen: echte Fenster mit Titelleiste,
    /// keine Menüs, Rückfragen oder das Fenster der Menüleiste.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    var hasOpenWindow: Bool { NSApp.windows.contains(where: Self.isAppWindow) }

    /// Dock-Symbol ein-/ausblenden.
    nonisolated static func policy(dockOnlyWithWindow: Bool, hasWindow: Bool) -> NSApplication.ActivationPolicy {
        dockOnlyWithWindow && !hasWindow ? .accessory : .regular
    }

    func updateActivationPolicy() {
        let dockOnly = BackgroundSettings.bool(BackgroundSettings.dockOnlyWithWindowKey, default: true)
        let wanted = Self.policy(dockOnlyWithWindow: dockOnly, hasWindow: hasOpenWindow)
        guard NSApp.activationPolicy() != wanted else { return }
        backgroundLog.info("Dock-Symbol \(wanted == .regular ? "ein" : "aus", privacy: .public)")
        NSApp.setActivationPolicy(wanted)
        // Zurück als normale App: Menüleiste der App erst nach erneutem Aktivieren.
        if wanted == .regular { NSApp.activate() }
    }

    func windowAppeared() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular); NSApp.activate() }
    }

    /// „Im Hintergrund weiterlaufen“: alle Fenster schließen, Empfang läuft weiter.
    func enterBackground() {
        for window in NSApp.windows where Self.isAppWindow(window) { window.close() }
        Task { @MainActor in self.updateActivationPolicy() }
    }

    /// Hauptfenster nach vorn – oder neu öffnen, wenn keins mehr da ist.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { Self.isAppWindow($0) && Self.isMainWindow($0) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    /// SwiftUI vergibt Fensterkennungen nach dem Muster „<Szenen-ID>-AppWindow-<n>“.
    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(AppServices.mainWindowID + "-") == true
    }

    /// Anmeldestart im Hintergrund: Fenster, die SwiftUI (oder die
    /// Fensterwiederherstellung) beim Start öffnet, gleich wieder schließen.
    func hideWindowsAfterLaunch() {
        Task { @MainActor in
            for _ in 0..<30 {
                let windows = NSApp.windows.filter(Self.isAppWindow)
                if !windows.isEmpty {
                    windows.forEach { $0.close() }
                    backgroundLog.notice("Anmeldestart im Hintergrund – Fenster geschlossen")
                }
                updateActivationPolicy()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - Anmeldeobjekt

/// „Beim Anmelden starten“ über `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var error: String?

    private init() { refresh() }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// Nur auf ausdrücklichen Klick in den Einstellungen – ändert die Anmeldeobjekte des Nutzers.
    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
            backgroundLog.error("Anmeldeobjekt: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    var statusText: String {
        switch status {
        case .enabled: String(localized: "Startet beim Anmelden.")
        case .requiresApproval: String(localized: "Wartet auf deine Freigabe in den Systemeinstellungen (Allgemein ▸ Anmeldeobjekte).")
        case .notFound: String(localized: "macOS findet die App nicht als Anmeldeobjekt – liegt sie im Ordner „Programme“?")
        default: String(localized: "Startet nicht von selbst.")
        }
    }
}

/// Start nach der Anmeldung: was „Beim automatischen Start“ verlangt.
@MainActor
@Observable
final class LoginLaunch {
    static let shared = LoginLaunch()
    /// Gilt dieser Programmlauf als Anmeldestart?
    private(set) var isLoginLaunch = false
    /// Hinweis für die Menüleiste („Warte auf den HackRF …“).
    private(set) var note: String?
    /// Der Hinweis meldet einen Fehlschlag.
    private(set) var failed = false

    @ObservationIgnored private var eventSaysLoginItem = false
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {}

    /// In `applicationWillFinishLaunching` und `…DidFinishLaunching`: Startereignis prüfen.
    func noteLaunchEvent(_ event: NSAppleEventDescriptor?) {
        if LaunchContext.eventSaysLoginItem(event) { eventSaysLoginItem = true }
    }

    /// Einmal nach dem Start: als Anmeldeobjekt gestartet? Dann Fenster schließen
    /// (Einstellung) und die gewählte Startaktion ausführen.
    func evaluate(session: DeviceSession) {
        let since = LaunchContext.loginDate().map { Date().timeIntervalSince($0) }
        isLoginLaunch = LaunchContext.isLoginLaunch(eventSaysLoginItem: eventSaysLoginItem,
                                                    serviceEnabled: SMAppService.mainApp.status == .enabled,
                                                    secondsSinceLogin: since)
        backgroundLog.notice("Start: \(self.isLoginLaunch ? "als Anmeldeobjekt" : "normal", privacy: .public) (Ereignis \(self.eventSaysLoginItem, privacy: .public), seit Anmeldung \(Int(since ?? -1)) s)")
        guard isLoginLaunch else { return }
        if BackgroundSettings.bool(BackgroundSettings.launchHiddenKey, default: true) {
            BackgroundController.shared.hideWindowsAfterLaunch()
        }
        let defaults = UserDefaults.standard
        let action = LoginLaunchAction.stored(in: defaults)
        let chosen = defaults.string(forKey: BackgroundSettings.launchPageKey).flatMap(SidebarItem.init(rawValue:))
        guard let target = action.target(remembered: LastReceiverMemory().item, chosen: chosen) else {
            backgroundLog.notice("Anmeldestart: nichts zu starten (\(action.rawValue, privacy: .public))")
            return
        }
        task = Task { await self.start(target, session: session) }
    }

    /// Auf das Gerät warten (bis 3 min, bei Bedarf in den HackRF-Modus) und starten.
    private func start(_ item: SidebarItem, session: DeviceSession) async {
        note = String(localized: "Warte auf den HackRF, um \(item.title) zu starten …")
        let deadline = Date().addingTimeInterval(180)
        while session.hackRF == nil, Date() < deadline, !Task.isCancelled {
            if session.device != nil, !session.busy, session.mode != .hackRF {
                await session.enterHackRFMode()
                for _ in 0..<40 where session.hackRF == nil { try? await Task.sleep(for: .milliseconds(500)) }
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let noDevice = String(localized: "\(item.title) nicht gestartet: kein HackRF gefunden.")
        guard session.hackRF != nil else { finish(noDevice, failed: true); return }
        // Dem Empfangsplan einen Takt Vorsprung lassen: Ist gerade ein Termin
        // fällig, beginnt er zuerst, und der Empfänger kommt danach.
        try? await Task.sleep(for: .seconds(12))
        guard let device = session.hackRF, !session.busy else { finish(noDevice, failed: true); return }
        switch await ReceiverStore.shared.startForLaunch(item, on: device) {
        case .started:
            finish(String(localized: "\(item.title) beim Anmelden gestartet."), failed: false)
        case .afterPlan:
            finish(String(localized: "\(item.title) startet nach dem laufenden Plan-Termin."), failed: false)
        case .occupied(let other):
            finish(String(localized: "\(item.title) nicht gestartet: \(other) belegt das Gerät."), failed: false)
        case .failed(let reason):
            finish(String(localized: "\(item.title) nicht gestartet: \(reason)"), failed: true)
        }
    }

    private func finish(_ text: String, failed: Bool) {
        backgroundLog.notice("Anmeldestart: \(text, privacy: .public)")
        note = text
        self.failed = failed
        // Der Hinweis gilt nur eine Weile.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard let self, self.note == text else { return }
            self.note = nil
            self.failed = false
        }
    }
}
