import AppKit
import Foundation

// Hintergrundbetrieb (Nutzerwunsch 29.10.2026): Fenster schließen beendet die App
// nicht, ⌘Q warnt bei laufender Arbeit, Statussymbol in der Menüleiste, Start beim
// Anmelden. Hier die reine, testbare Logik; die AppKit-Seite steht in
// `BackgroundController` und `LoginLaunch`.

/// Einstellungen des Hintergrundbetriebs (Schlüssel in UserDefaults).
enum BackgroundSettings {
    /// „Dock-Symbol nur mit offenem Fenster“ (ab Werk an).
    static let dockOnlyWithWindowKey = "dockIconOnlyWithWindow"
    /// „Symbol in der Menüleiste“ (ab Werk an).
    static let menuBarIconKey = "menuBarIconShown"
    /// „Beim automatischen Start“ (`LoginLaunchAction.rawValue`).
    static let launchActionKey = "loginLaunchAction"
    /// Seite für „Bestimmte Seite starten …“ (`SidebarItem.rawValue`).
    static let launchPageKey = "loginLaunchPage"
    /// „Im Hintergrund starten (ohne Fenster)“ (ab Werk an).
    static let launchHiddenKey = "loginLaunchHidden"

    nonisolated static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

/// Was beim Start als Anmeldeobjekt passiert.
enum LoginLaunchAction: String, CaseIterable, Identifiable, Sendable {
    /// Der zuletzt laufende Empfänger bzw. die zuletzt laufende Aufnahme startet wieder (Standard).
    case resume
    /// Nur der Empfangsplan (läuft ohnehin).
    case planOnly
    /// Eine fest gewählte Seite starten.
    case page
    /// Nichts starten.
    case nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resume: String(localized: "Aufnahme fortsetzen")
        case .planOnly: String(localized: "Nur Empfangsplan")
        case .page: String(localized: "Bestimmte Seite starten …")
        case .nothing: String(localized: "Nichts starten")
        }
    }

    nonisolated static func stored(in defaults: UserDefaults = .standard) -> LoginLaunchAction {
        defaults.string(forKey: BackgroundSettings.launchActionKey).flatMap(LoginLaunchAction.init(rawValue:)) ?? .resume
    }

    /// Welche Seite starten soll – `nil` = nichts außer dem Plan.
    nonisolated func target(remembered: SidebarItem?, chosen: SidebarItem?) -> SidebarItem? {
        let item: SidebarItem? = switch self {
        case .resume: remembered
        case .page: chosen
        case .planOnly, .nothing: nil
        }
        return item.flatMap { LaunchStart.canStart($0) ? $0 : nil }
    }
}

/// Welche Empfänger sich ohne Fenster starten lassen (Autostart nach der
/// Anmeldung, „Aufnahme fortsetzen“). Gleiche Wege wie nach einem Plan-Termin:
/// `RemoteHub.resumeAfterPlan` bzw. `ReceiverRestarting`; dazu Sonden und Aufnahme.
enum LaunchStart {
    /// Empfänger, die `RemoteHub` hält (Start ohne Fernbetrieb über `resumeAfterPlan`).
    /// Das Spektrum der Mac-Seite ist ein eigenes Model – nicht das des Fernzugriffs.
    nonisolated static func hubMode(for item: SidebarItem) -> RemoteHub.Mode? {
        switch item {
        case .adsb: .adsb
        case .ais: .ais
        case .dab: .dab
        case .acars: .acars
        case .zigbee: .zigbee
        case .airband: .airband
        case .radio: .radio
        case .sensors: .sensors
        case .smartHome868: .smartHome868
        case .dsc: .dsc
        case .ft8: .ft8
        case .occupancy: .occupancy
        case .aprs: .aprs
        default: nil
        }
    }

    /// Reine Mac-Empfänger mit `ReceiverRestarting`, dazu Sonden und Aufnahme.
    /// Nicht: METEOR und Amateurfunk (nur beim Überflug sinnvoll, macht der Plan),
    /// Antennen-Check (einmalig), Geräteseiten.
    nonisolated static let localItems: Set<SidebarItem> = [
        .spectrum, .tv, .pager, .flarm, .ble, .wifi, .drones, .meshtastic, .lorawan,
        .dcf77, .gps, .vor, .cells, .hydrogen, .sonde, .recorder,
    ]

    nonisolated static func canStart(_ item: SidebarItem) -> Bool {
        hubMode(for: item) != nil || localItems.contains(item)
    }

    /// Wählbare Seiten für „Bestimmte Seite starten …“ in der Reihenfolge der Seitenleiste.
    nonisolated static var choices: [SidebarItem] {
        SidebarItem.groups.flatMap(\.items).filter(canStart)
    }
}

/// Der zuletzt laufende Empfänger – für „Aufnahme fortsetzen“ beim Anmeldestart.
/// Gemerkt, sobald er läuft; vergessen, wenn der Nutzer ihn bewusst stoppt;
/// behalten, wenn die App mit laufendem Empfang beendet wird oder das Gerät
/// verschwindet.
struct LastReceiverMemory {
    static let itemKey = "lastRunningReceiver"
    static let dateKey = "lastRunningReceiverDate"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var item: SidebarItem? { defaults.string(forKey: Self.itemKey).flatMap(SidebarItem.init(rawValue:)) }
    var date: Date? { defaults.object(forKey: Self.dateKey) as? Date }

    func remember(_ item: SidebarItem, now: Date = Date()) {
        defaults.set(item.rawValue, forKey: Self.itemKey)
        defaults.set(now, forKey: Self.dateKey)
    }

    func forget() {
        defaults.removeObject(forKey: Self.itemKey)
        defaults.removeObject(forKey: Self.dateKey)
    }

    enum Change: Equatable { case keep, remember(SidebarItem), forget }

    /// Was der Takt (`ReceiverStore.track`) mit dem Gedächtnis tut.
    ///
    /// - Parameters:
    ///   - running: Seite des Empfängers, der gerade läuft (ohne den laufenden Plan-Termin)
    ///   - previous: Seite beim letzten Takt
    ///   - remoteChosen: das Handy hat gewählt – Fernbetrieb wird nie von selbst wiederhergestellt
    ///   - planActive: ein Plan-Termin läuft (er hält Empfänger an und holt sie zurück)
    ///   - deviceReady: Gerät im HackRF-Modus (sonst endete der Empfang durch Trennen/Moduswechsel)
    ///   - terminating: die App wird gerade beendet
    nonisolated static func change(running: SidebarItem?, previous: SidebarItem?, remoteChosen: Bool,
                                   planActive: Bool, deviceReady: Bool, terminating: Bool) -> Change {
        if terminating || remoteChosen { return .keep }
        if let running {
            return LaunchStart.canStart(running) ? .remember(running) : .keep
        }
        // Endete ein Empfänger bei verbundenem Gerät und ohne Plan-Termin, hat ihn
        // jemand gestoppt (Stopp-Knopf, Menüleiste, Handy) – dann nicht wieder starten.
        if previous != nil, deviceReady, !planActive { return .forget }
        return .keep
    }
}

/// Was gerade läuft und durch Beenden abbräche – Grundlage der Rückfrage bei ⌘Q.
struct RunningWork: Equatable, Sendable {
    /// Firmware-Installation o. Ä. (`DeviceSession.busy`) samt Grund.
    var installing: String?
    /// Titel des laufenden Empfängers („Flugzeuge (ADS-B)“).
    var receiver: String?
    /// Titel des laufenden Plan-Termins.
    var planJob: String?
    /// Laufende Aufnahmen in Klartext („IQ-Aufnahme“, „Ton-Aufnahme (Radio)“ …).
    var recordings: [String] = []
    /// Hörer am Fernzugriff.
    var remoteListeners = 0

    /// Alles, was laufen würde, als Liste in Alltagssprache (ohne Doppel).
    var items: [String] {
        var result: [String] = []
        if let planJob { result.append(String(localized: "Empfangsplan (\(planJob))")) }
        if let receiver { result.append(receiver) }
        result += recordings
        if remoteListeners > 0 {
            result.append(String(localized: "Fernzugriff (\(remoteListeners) Hörer)"))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    var isEmpty: Bool { items.isEmpty }

    enum QuitDecision: Equatable {
        /// Sofort beenden.
        case quit
        /// Nicht beenden, nur Hinweis zeigen.
        case refuse(String)
        /// Rückfrage: weiterlaufen im Hintergrund / beenden / abbrechen.
        case ask(String)
    }

    /// Entscheidung bei ⌘Q bzw. „Beenden“. `systemQuit`: Abmelden, Neustart oder
    /// Ausschalten – dann ohne Rückfrage, außer während einer Installation (ein
    /// halb geschriebener Flash ist schlimmer als ein verzögertes Abmelden).
    func quitDecision(systemQuit: Bool) -> QuitDecision {
        if let installing {
            return .refuse(String(localized: "Gerade läuft: \(installing). Warte, bis das fertig ist – ein Abbruch mitten im Schreiben kann das Gerät unbrauchbar machen."))
        }
        if systemQuit || isEmpty { return .quit }
        return .ask(String(localized: "Läuft gerade: \(items.formatted(.list(type: .and))). Beenden stoppt das."))
    }
}

/// Symbol in der Menüleiste.
enum MenuBarSymbol: Equatable, Sendable {
    case idle, receiving, recording, problem

    nonisolated static func state(problem: Bool, recording: Bool, receiving: Bool) -> MenuBarSymbol {
        if problem { return .problem }
        if recording { return .recording }
        if receiving { return .receiving }
        return .idle
    }

    var systemName: String {
        switch self {
        case .idle: "antenna.radiowaves.left.and.right"
        case .receiving: "antenna.radiowaves.left.and.right.circle.fill"
        case .recording: "record.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .idle: String(localized: "PortaPack Manager – bereit")
        case .receiving: String(localized: "PortaPack Manager – empfängt")
        case .recording: String(localized: "PortaPack Manager – nimmt auf")
        case .problem: String(localized: "PortaPack Manager – Problem mit dem Gerät")
        }
    }
}

/// Ob die App als Anmeldeobjekt gestartet wurde.
///
/// macOS legt dem Startereignis (`kAEOpenApplication`) bei Anmeldeobjekten die
/// Eigenschaft `keyAELaunchedAsLogInItem` bei. Ob das auch für Apps gilt, die sich
/// über `SMAppService.mainApp` anmelden, ist nicht dokumentiert – deshalb
/// zusätzlich eine Zeitregel: Anmeldeobjekt registriert und die Anmeldung an der
/// Konsole (bzw. der Systemstart) liegt höchstens `loginWindow` zurück.
/// Entwickler-Neustarts (`Scripts/run.sh`) liegen praktisch nie so nah an der Anmeldung.
enum LaunchContext {
    nonisolated static let loginWindow: TimeInterval = 180

    nonisolated static func isLoginLaunch(eventSaysLoginItem: Bool, serviceEnabled: Bool,
                                          secondsSinceLogin: TimeInterval?) -> Bool {
        guard serviceEnabled else { return false }
        if eventSaysLoginItem { return true }
        guard let secondsSinceLogin, secondsSinceLogin >= 0 else { return false }
        return secondsSinceLogin <= loginWindow
    }

    /// `kAEOpenApplication` mit `keyAEPropData = keyAELaunchedAsLogInItem`?
    nonisolated static func eventSaysLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Beenden durch Abmelden/Neustart/Ausschalten: das Beenden-Ereignis trägt einen Grund.
    nonisolated static func eventIsSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    /// Letzte Anmeldung dieses Nutzers an der Konsole (utmpx), sonst der Systemstart.
    nonisolated static func loginDate() -> Date? {
        var latest: Date?
        let user = NSUserName()
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let tv = entry.pointee.ut_tv
            let date = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest ?? bootDate()
    }

    nonisolated static func bootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }
}
