import SwiftUI

@main
struct PortaPackManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = AppServices.session
    /// „Symbol in der Menüleiste“ (Einstellungen ▸ Allgemein, ab Werk an).
    @AppStorage(BackgroundSettings.menuBarIconKey) private var menuBarIconShown = true

    init() {
        // Dienste unabhängig vom Fenster starten: stellte macOS beim Start nur das
        // Hilfefenster wieder her, liefen vorher weder Geräteerkennung noch
        // Fernzugriff noch Empfangsplan (Fund 27.10.2026).
        AppServices.start()
    }

    var body: some Scene {
        WindowGroup("PortaPack Manager", id: AppServices.mainWindowID) {
            ContentView()
                .environment(session)
                // Mindestbreite ≥ Seitenleiste (190) + breiteste Seite (660: BLE,
                // Drohnen, Meshtastic) + Bedienfeld (240) + Trenner. Mit 960 lag das
                // Fenster unter der Summe innen – dieselbe Lage „innen > außen“, die
                // auf Seitenebene AppKit-Abstürze auslöste (Review 28.10.2026, W9).
                .frame(minWidth: 1120, minHeight: 640)
                // Unter dem SwiftUI-Lebenszyklus kommen Links hier an, nicht beim Delegate.
                .onOpenURL { AppServices.open($0) }
                .handlesExternalEvents(preferring: ["portapack"], allowing: ["portapack"])
        }
        .handlesExternalEvents(matching: ["portapack"])
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .help) { HelpMenuButton() }
            // ⌘, öffnet die Seite „Einstellungen“ im Hauptfenster (kein eigenes Fenster).
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen …") { AppNavigation.shared.page = .settings }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .toolbar) {
                Button("Status aktualisieren") {
                    Task { await session.refreshStatus() }
                }
                .keyboardShortcut("r")
            }
        }

        Window("PortaPack Manager Hilfe", id: HelpCenter.windowID) {
            HelpView()
                .environment(session)
        }
        .defaultSize(width: 980, height: 680)
        // Archiv als eigenes Fenster statt Blatt: Blätter lassen sich unter macOS
        // nicht in der Größe ändern, die Tabelle hat aber viele Spalten.
        WindowGroup("Archiv", id: "archive", for: String.self) { $kind in
            ArchiveView(archive: kind == "ais" ? .ais : .adsb, aircraft: kind != "ais")
        }
        .defaultSize(width: 1200, height: 720)
        Window("Sondenarchiv", id: "sondeArchive") {
            SondeArchiveView()
        }
        .defaultSize(width: 1250, height: 760)

        // Statussymbol: was läuft, nächster Termin, Fernzugriff – und der Weg zurück
        // ins Fenster, wenn die App im Hintergrund läuft. Stil `.menu`: echte
        // Menüeinträge, kein eigenes Fenster (zählt nicht als offenes Fenster).
        MenuBarExtra(isInserted: $menuBarIconShown) {
            MenuBarContent(session: session)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Dienste, die ohne Fenster laufen müssen (Gerät, Fernzugriff, Plan …).
@MainActor
enum AppServices {
    static let mainWindowID = "main"
    static let session = DeviceSession()
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        // Nicht im Testwirt: Geräteerkennung und Plan nähmen sonst während
        // der Tests den HackRF (die Live-Gerätetests öffnen ihn selbst).
        let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !testHost { session.startMonitoring() }
        RemoteHub.shared.bootstrap(session: session)
        guard !testHost else { return }
        // Grüner Punkt, Aufräumen, „zuletzt lief“ – unabhängig vom Fenster (Hintergrundbetrieb).
        Task { await ReceiverStore.shared.track(session: session) }
        MenuBarStatus.shared.start(session: session)
        AutoGain.shared.bootstrap(session: session)
        Notifier.shared.bootstrap(session: session)
        ReceptionPlanner.shared.bootstrap(session: session)
        MQTTBridge.shared.bootstrap()
        AppFiles.migrateCaches()
        ArchiveMaintenance.start()
        // Neue Installationen fragen erst im Schritt „Standort“ der Ersteinrichtung
        // (vorher erschien der Systemdialog ohne Zusammenhang beim Start).
        if UserDefaults.standard.bool(forKey: SetupWizard.doneKey) { Task { await locateOnce() } }
    }

    static let autoLocateTriedKey = "homeAutoLocateTried"

    /// Den Standort selbst holen (Karten, Entfernungen, Empfangsplan brauchen
    /// ihn; vorher stand er auf 0/0, bis man ihn auf der ADS-B-Seite fand).
    /// Nur ein Versuch – abgelehnt bleibt abgelehnt.
    private static func locateOnce() async {
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: "homeLat") == 0, defaults.double(forKey: "homeLon") == 0,
              !defaults.bool(forKey: autoLocateTriedKey) else { return }
        defaults.set(true, forKey: autoLocateTriedKey)
        guard let location = try? await LocationProvider.shared.currentLocation() else { return }
        defaults.set(location.coordinate.latitude, forKey: "homeLat")
        defaults.set(location.coordinate.longitude, forKey: "homeLon")
    }

    /// Links `portapack://page/<seite>`, `portapack://radio/<MHz>` und `portapack://help/<kapitel>` – zum
    /// Springen aus Notizen und Skripten (auch für die Bildschirmfotos der Doku).
    static func open(_ url: URL) {
        guard url.scheme == "portapack" else { return }
        let target = url.lastPathComponent
        switch url.host() {
        case "page":
            if let item = SidebarItem(rawValue: target) {
                AppNavigation.shared.page = item
            } else if let tab = SettingsTab(rawValue: target) {
                // Fernzugriff und Daten teilen sind seit 29.10.2026 Bereiche der Einstellungen.
                UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
                AppNavigation.shared.page = .settings
            }
        case "start":
            // Wie eine Kachel der Startseite: Seite öffnen und Empfang starten.
            if let item = SidebarItem(rawValue: target) { AppNavigation.shared.open(item, start: true) }
        case "radio":
            // `portapack://radio/145.500` – Frequenz im Radio öffnen und abspielen.
            if let mhz = Double(target.replacingOccurrences(of: ",", with: ".")), (1...6000).contains(mhz) {
                AppNavigation.shared.openRadio(mhz: mhz, mode: OccupancyPreset.radioMode(for: mhz))
            }
        case "help":
            HelpCenter.shared.show(page: target)
            HelpCenter.shared.openRequested = true
        default: break
        }
    }
}

/// Nimmt Links entgegen, ohne dass SwiftUI dafür ein neues Fenster öffnet;
/// regelt Hintergrundbetrieb, Beenden und den Anmeldestart.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var testHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LoginLaunch.shared.noteLaunchEvent(NSAppleEventManager.shared().currentAppleEvent) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Leertaste und Pfeile gehören dem Textfeld, solange es den Fokus hat.
            TextInputKeyGuard.install()
            guard !testHost else { return }
            BackgroundController.shared.install()
            // Das Startereignis liegt mitunter erst hier an (`kAEOpenApplication`).
            LoginLaunch.shared.noteLaunchEvent(NSAppleEventManager.shared().currentAppleEvent)
            LoginLaunch.shared.evaluate(session: AppServices.session)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(AppServices.open) }
    }

    /// Fenster zu heißt nicht App zu: Empfang, Plan und Fernzugriff laufen weiter.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q, „Beenden“ im Statusmenü, Abmelden: Rückfrage, wenn gerade etwas läuft.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !testHost else { return .terminateNow }
        return MainActor.assumeIsolated { QuitGuard.shouldTerminate() }
    }

    /// Klick aufs Dock-Symbol bzw. erneutes Öffnen im Finder ohne offenes Fenster:
    /// Hauptfenster öffnen, Dock-Symbol zurück. Kennt die App noch keinen Weg zum
    /// Öffnen (`openMainWindowAction`), übernimmt das SwiftUI (Rückgabe `true`).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard !flag else { return true }
            let controller = BackgroundController.shared
            guard controller.openMainWindowAction != nil else {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                return true
            }
            controller.showMainWindow()
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Aufnahmen sauber abschließen; „zuletzt lief“ bleibt für den Anmeldestart.
            QuitGuard.finishRecordings()
            // Home Assistant sofort „offline“ melden statt erst nach dem Keep-Alive-Ablauf.
            MQTTBridge.shared.shutdown()
        }
    }
}

/// Menü „Hilfe ▸ PortaPack Manager Hilfe“ (⌘?): öffnet wie das „?“ in der
/// Symbolleiste das Kapitel zur gerade sichtbaren Seite.
struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("PortaPack Manager Hilfe") {
            HelpCenter.shared.show(page: AppNavigation.shared.visiblePage.helpChapter)
            openWindow(id: HelpCenter.windowID)
        }
        .keyboardShortcut("?", modifiers: .command)
        Button("Hilfe zu den Einstellungen") {
            HelpCenter.shared.show(page: HelpCenter.settingsChapter)
            openWindow(id: HelpCenter.windowID)
        }
    }
}
