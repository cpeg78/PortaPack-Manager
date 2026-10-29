import AppKit
import Foundation
import Testing
@testable import PortaPackManager

/// Hintergrundbetrieb, Rückfrage beim Beenden, Menüleiste, Anmeldestart
/// (29.10.2026). Nur reine Logik – kein `SMAppService.register()`, keine
/// UserDefaults der App (eigene Suite).
@Suite("Hintergrundbetrieb und Anmeldestart")
struct BackgroundModeTests {
    // MARK: Beenden

    @Test("Nichts läuft → ⌘Q beendet sofort")
    func quitWhenIdle() {
        #expect(RunningWork().quitDecision(systemQuit: false) == .quit)
        #expect(RunningWork().isEmpty)
    }

    @Test("Laufende Arbeit → Rückfrage mit allem, was läuft")
    func askWhenBusy() {
        var work = RunningWork()
        work.receiver = "Flugzeuge (ADS-B)"
        work.recordings = ["IQ-Aufnahme"]
        work.planJob = "ISS"
        work.remoteListeners = 2
        guard case .ask(let message) = work.quitDecision(systemQuit: false) else {
            Issue.record("Rückfrage erwartet"); return
        }
        for part in ["Flugzeuge (ADS-B)", "IQ-Aufnahme", "ISS", "2"] {
            #expect(message.contains(part), "fehlt: \(part)")
        }
        #expect(work.items.count == 4)
    }

    @Test("Abmelden/Ausschalten beendet ohne Rückfrage – außer während einer Installation")
    func systemQuit() {
        var work = RunningWork()
        work.receiver = "Radio"
        #expect(work.quitDecision(systemQuit: true) == .quit)
        work.installing = "Firmware wird geschrieben"
        guard case .refuse(let message) = work.quitDecision(systemQuit: true) else {
            Issue.record("Verweigern erwartet"); return
        }
        #expect(message.contains("Firmware wird geschrieben"))
        guard case .refuse = work.quitDecision(systemQuit: false) else {
            Issue.record("Verweigern erwartet"); return
        }
    }

    @Test("Gleiche Einträge erscheinen nur einmal; Fernzugriff ohne Hörer zählt nicht")
    func deduplicated() {
        var work = RunningWork()
        work.recordings = ["Flugfunk-Mitschnitt", "Flugfunk-Mitschnitt"]
        work.remoteListeners = 0
        #expect(work.items == ["Flugfunk-Mitschnitt"])
    }

    // MARK: Gedächtnis „zuletzt lief“

    @Test("Laufender Empfänger wird gemerkt, bewusster Stopp vergisst ihn")
    func memoryChanges() {
        typealias M = LastReceiverMemory
        #expect(M.change(running: .adsb, previous: nil, remoteChosen: false, planActive: false, deviceReady: true, terminating: false) == .remember(.adsb))
        // Bewusst gestoppt: Gerät da, kein Termin.
        #expect(M.change(running: nil, previous: .adsb, remoteChosen: false, planActive: false, deviceReady: true, terminating: false) == .forget)
        // Gerät weg bzw. Moduswechsel: behalten.
        #expect(M.change(running: nil, previous: .adsb, remoteChosen: false, planActive: false, deviceReady: false, terminating: false) == .keep)
        // Plan-Termin hat übernommen: behalten (er holt den Empfänger zurück).
        #expect(M.change(running: nil, previous: .adsb, remoteChosen: false, planActive: true, deviceReady: true, terminating: false) == .keep)
        // Beenden der App: behalten.
        #expect(M.change(running: nil, previous: .adsb, remoteChosen: false, planActive: false, deviceReady: true, terminating: true) == .keep)
        // Fernbetrieb wird nie gemerkt (nach dem Neustart nicht von selbst wiederherstellen).
        #expect(M.change(running: .dab, previous: nil, remoteChosen: true, planActive: false, deviceReady: true, terminating: false) == .keep)
        // Einmalige Vorgänge (Antennen-Check) ersetzen das Gedächtnis nicht.
        #expect(M.change(running: .antennaCheck, previous: .adsb, remoteChosen: false, planActive: false, deviceReady: true, terminating: false) == .keep)
        // Nichts lief vorher: nichts zu tun.
        #expect(M.change(running: nil, previous: nil, remoteChosen: false, planActive: false, deviceReady: true, terminating: false) == .keep)
    }

    @Test("Gedächtnis speichert Seite und Zeit in UserDefaults (eigene Suite)")
    func memoryStorage() throws {
        let suite = "de.christiangolz.portapackmanager.tests.background.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = LastReceiverMemory(defaults: defaults)
        #expect(memory.item == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        memory.remember(.gps, now: now)
        #expect(memory.item == .gps)
        #expect(memory.date == now)
        memory.forget()
        #expect(memory.item == nil)
        #expect(memory.date == nil)
        // Ab Werk: „Aufnahme fortsetzen“.
        #expect(LoginLaunchAction.stored(in: defaults) == .resume)
    }

    // MARK: Startaktion

    @Test("Startaktion wählt die richtige Seite")
    func launchTarget() {
        #expect(LoginLaunchAction.resume.target(remembered: .adsb, chosen: .gps) == .adsb)
        #expect(LoginLaunchAction.resume.target(remembered: nil, chosen: .gps) == nil)
        #expect(LoginLaunchAction.page.target(remembered: .adsb, chosen: .gps) == .gps)
        #expect(LoginLaunchAction.planOnly.target(remembered: .adsb, chosen: .gps) == nil)
        #expect(LoginLaunchAction.nothing.target(remembered: .adsb, chosen: .gps) == nil)
        // Nicht startbare Seiten fallen weg.
        #expect(LoginLaunchAction.page.target(remembered: nil, chosen: .firmware) == nil)
        #expect(LoginLaunchAction.resume.target(remembered: .antennaCheck, chosen: nil) == nil)
    }

    @Test("Startbare Seiten: Empfänger ja, Plan-Satelliten, Antennen-Check und Geräteseiten nein")
    func launchChoices() {
        let choices = LaunchStart.choices
        #expect(!choices.isEmpty)
        #expect(Set(choices).count == choices.count)
        for item in [SidebarItem.adsb, .ais, .dab, .radio, .gps, .ble, .sonde, .recorder, .occupancy, .spectrum] {
            #expect(choices.contains(item), "fehlt: \(item)")
        }
        for item in [SidebarItem.overview, .settings, .firmware, .planner, .meteor, .amateurSat, .antennaCheck, .console] {
            #expect(!choices.contains(item), "gehört nicht dazu: \(item)")
        }
        // Das Mac-Spektrum ist ein eigenes Model, nicht das des Fernzugriffs.
        #expect(LaunchStart.hubMode(for: .spectrum) == nil)
        // Jeder Fernzugriffs-Modus außer dem Spektrum gehört zu genau einer Seite.
        let modes = SidebarItem.allCases.compactMap(LaunchStart.hubMode(for:))
        #expect(Set(modes).count == modes.count)
        #expect(Set(modes) == Set(RemoteHub.Mode.allCases).subtracting([.spectrum]))
    }

    // MARK: Anmeldestart erkennen

    @Test("Anmeldestart nur mit registriertem Anmeldeobjekt; Ereignis oder Anmeldung vor kurzem")
    func loginLaunchRule() {
        #expect(LaunchContext.isLoginLaunch(eventSaysLoginItem: true, serviceEnabled: true, secondsSinceLogin: 9999))
        #expect(LaunchContext.isLoginLaunch(eventSaysLoginItem: false, serviceEnabled: true, secondsSinceLogin: 40))
        #expect(!LaunchContext.isLoginLaunch(eventSaysLoginItem: false, serviceEnabled: true, secondsSinceLogin: 3600))
        #expect(!LaunchContext.isLoginLaunch(eventSaysLoginItem: false, serviceEnabled: true, secondsSinceLogin: nil))
        // Ohne Anmeldeobjekt nie – auch nicht kurz nach dem Anmelden (Entwickler-Neustart).
        #expect(!LaunchContext.isLoginLaunch(eventSaysLoginItem: true, serviceEnabled: false, secondsSinceLogin: 10))
        #expect(!LaunchContext.isLoginLaunch(eventSaysLoginItem: false, serviceEnabled: false, secondsSinceLogin: 10))
    }

    private func event(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }

    @Test("Startereignis mit keyAELaunchedAsLogInItem wird erkannt")
    func loginEvent() {
        let plain = event(AEEventID(kAEOpenApplication))
        #expect(!LaunchContext.eventSaysLoginItem(plain))
        #expect(!LaunchContext.eventSaysLoginItem(nil))
        let login = event(AEEventID(kAEOpenApplication))
        login.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        #expect(LaunchContext.eventSaysLoginItem(login))
        // Anderes Ereignis mit derselben Eigenschaft zählt nicht.
        let reopen = event(AEEventID(kAEReopenApplication))
        reopen.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        #expect(!LaunchContext.eventSaysLoginItem(reopen))
    }

    @Test("Beenden durch Abmelden trägt einen Grund")
    func systemQuitEvent() {
        let quit = event(AEEventID(kAEQuitApplication))
        #expect(!LaunchContext.eventIsSystemQuit(quit))
        quit.setAttribute(NSAppleEventDescriptor(enumCode: OSType(kAELogOut)), forKeyword: AEKeyword(kAEQuitReason))
        #expect(LaunchContext.eventIsSystemQuit(quit))
        #expect(!LaunchContext.eventIsSystemQuit(event(AEEventID(kAEOpenApplication))))
    }

    @Test("Anmeldezeit aus utmpx bzw. Systemstart liegt in der Vergangenheit")
    func loginDate() {
        if let date = LaunchContext.loginDate() { #expect(date <= Date()) }
        if let boot = LaunchContext.bootDate() { #expect(boot <= Date()) }
    }

    // MARK: Menüleiste und Dock

    @Test("Symbol: Gerätefehler vor Aufnahme vor Empfang")
    func symbolPriority() {
        #expect(MenuBarSymbol.state(problem: true, recording: true, receiving: true) == .problem)
        #expect(MenuBarSymbol.state(problem: false, recording: true, receiving: true) == .recording)
        #expect(MenuBarSymbol.state(problem: false, recording: false, receiving: true) == .receiving)
        #expect(MenuBarSymbol.state(problem: false, recording: false, receiving: false) == .idle)
        for symbol in [MenuBarSymbol.idle, .receiving, .recording, .problem] {
            #expect(NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil) != nil, "Symbol fehlt: \(symbol.systemName)")
        }
    }

    @Test("Dock-Symbol nur mit offenem Fenster")
    func activationPolicy() {
        #expect(BackgroundController.policy(dockOnlyWithWindow: true, hasWindow: false) == .accessory)
        #expect(BackgroundController.policy(dockOnlyWithWindow: true, hasWindow: true) == .regular)
        #expect(BackgroundController.policy(dockOnlyWithWindow: false, hasWindow: false) == .regular)
    }

    @Test("Zeile im Statusmenü: Name, Frequenz auf 0,1 MHz, Pegel auf ganze dB")
    func receivingLine() {
        let line = MenuBarSnapshot.receivingLine(title: "Flugzeuge (ADS-B)", hz: 1_090_000_000, levelDBFS: -23.4)
        #expect(line.hasPrefix("Flugzeuge (ADS-B) · 1"))
        #expect(line.contains("090"))
        #expect(line.contains("MHz"))
        #expect(line.hasSuffix("−23 dBFS"))
        #expect(MenuBarSnapshot.receivingLine(title: "GPS", hz: nil, levelDBFS: nil) == "GPS")
        #expect(MenuBarSnapshot.receivingLine(title: "GPS", hz: nil, levelDBFS: .nan) == "GPS")
    }
}
