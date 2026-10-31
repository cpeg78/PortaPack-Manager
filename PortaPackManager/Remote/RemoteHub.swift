import AppKit
import Foundation
import Network
import Observation
import os

/// Fernzugriff auf ADS-B, AIS und DAB+ über eine Webseite.
///
/// Besitzt die drei Empfänger (die Seiten der App benutzen dieselben
/// Instanzen), den HTTP-Server und den AAC-Strom. Der HackRF empfängt immer
/// nur ein Band – der Browser schaltet zwischen den dreien um.
@MainActor
@Observable
final class RemoteHub {
    static let shared = RemoteHub()

    enum Mode: String, Codable, CaseIterable, Sendable {
        case adsb, ais, dab, spectrum, acars, zigbee, airband
        // Seit 28.10.2026 auch aus der Ferne: UKW/AM/NFM-Radio, Funksensoren, Smart Home 868,
        // Seefunk-DSC, FT8/WSPR, Belegungsmonitor. Rohwert = Reiter-Schlüssel der Webseite.
        case radio = "fm", sensors, smartHome868 = "smart868", dsc, ft8, occupancy
        var title: String {
            switch self {
            case .adsb: String(localized: "ADS-B (Flugzeuge)")
            case .ais: String(localized: "AIS (Schiffe)")
            case .dab: String(localized: "DAB+ (Radio)")
            case .spectrum: String(localized: "Spektrum")
            case .acars: "ACARS & VDL2"
            case .zigbee: "Zigbee"
            case .airband: String(localized: "Flugfunk")
            case .radio: String(localized: "Radio")
            case .sensors: String(localized: "Funksensoren")
            case .smartHome868: String(localized: "Smart Home 868 MHz")
            case .dsc: String(localized: "Seefunk-Notruf (DSC)")
            case .ft8: "FT8/WSPR"
            case .occupancy: String(localized: "Belegungsmonitor")
            }
        }
    }

    let adsb = ADSBModel()
    let ais = AISModel()
    /// Eigenes Spektrum für die Webseite (die Spektrum-Seite am Mac hat ihr eigenes).
    let spectrum = SpectrumModel()
    /// ACARS & VDL2 – die Seite am Mac nutzt dieselbe Instanz.
    let acars = ACARSModel()
    let dab = DABModel()
    /// Zigbee – die Seite am Mac nutzt dieselbe Instanz. Erst bei Bedarf
    /// angelegt: das Model liest beim Anlegen die Schlüssel aus dem Schlüsselbund.
    @ObservationIgnored private var zigbeeStorage: ZigbeeModel?
    var zigbee: ZigbeeModel {
        if let zigbeeStorage { return zigbeeStorage }
        let model = ZigbeeModel()
        zigbeeStorage = model
        return model
    }
    private var zigbeeRunning: Bool { zigbeeStorage?.running ?? false }
    /// Flugfunk – die Seite am Mac nutzt dieselbe Instanz (erst bei Bedarf angelegt:
    /// lädt Verlauf und Kanalliste und baut die Tonausgabe).
    @ObservationIgnored private var airbandStorage: AirbandModel?
    var airband: AirbandModel {
        if let airbandStorage { return airbandStorage }
        let model = AirbandModel()
        // Rufzeichen der gerade bekannten Flugzeuge als Hinweise für die Spracherkennung.
        model.liveCallsigns = { [weak self] in
            (self?.adsb.aircraft ?? []).compactMap { plane in
                guard let sign = plane.callsign?.trimmingCharacters(in: .whitespaces), !sign.isEmpty,
                      Date().timeIntervalSince(plane.lastSeen) < 1800 else { return nil }
                return AirbandCallsign(callsign: sign, icao: plane.icaoHex)
            }
        }
        airbandStorage = model
        applyAudioTaps()
        return model
    }
    private var airbandRunning: Bool { airbandStorage?.running ?? false }

    // Weitere Empfänger, die Mac-Seite und Fernzugriff teilen (erst bei Bedarf angelegt).
    @ObservationIgnored private var radioStorage: RadioModel?
    var radio: RadioModel {
        if let radioStorage { return radioStorage }
        let model = RadioModel()
        radioStorage = model
        applyAudioTaps()
        return model
    }
    @ObservationIgnored private var sensorsStorage: SensorModel?
    var sensors: SensorModel {
        if let sensorsStorage { return sensorsStorage }
        let model = SensorModel()
        sensorsStorage = model
        return model
    }
    @ObservationIgnored private var smartHomeStorage: SmartHome868Model?
    var smartHome: SmartHome868Model {
        if let smartHomeStorage { return smartHomeStorage }
        let model = SmartHome868Model()
        smartHomeStorage = model
        return model
    }
    @ObservationIgnored private var ft8Storage: FT8Model?
    var ft8: FT8Model {
        if let ft8Storage { return ft8Storage }
        let model = FT8Model()
        ft8Storage = model
        return model
    }
    var dsc: DSCModel { DSCModel.shared }
    var occupancy: OccupancyMonitor { OccupancyMonitor.shared }

    /// Läuft einer der weiteren Empfänger? (ohne ein Model anzulegen)
    private func extraRunning(_ mode: Mode) -> Bool {
        switch mode {
        case .radio: radioStorage?.running ?? false
        case .sensors: sensorsStorage?.running ?? false
        case .smartHome868: smartHomeStorage?.running ?? false
        case .dsc: dsc.running
        case .ft8: ft8Storage?.running ?? false
        case .occupancy: occupancy.running
        default: false
        }
    }

    private func extraStop(_ mode: Mode, _ device: HackRFDevice?) {
        switch mode {
        case .radio: radioStorage?.stop()
        case .sensors: sensorsStorage?.stop()
        case .smartHome868: smartHomeStorage?.stop()
        case .dsc: dsc.stop(on: device)
        case .ft8: ft8Storage?.stop(on: device)
        case .occupancy: if occupancy.running { occupancy.stop() }
        default: break
        }
    }

    /// Startet einen der weiteren Empfänger; liefert eine Fehlermeldung.
    @discardableResult
    private func extraStart(_ mode: Mode, _ device: HackRFDevice) -> String? {
        switch mode {
        case .radio: radio.start(on: device); return radio.error
        case .sensors: sensors.start(on: device); return sensors.error
        case .smartHome868: smartHome.start(on: device); return smartHome.error
        case .dsc: dsc.start(on: device); return dsc.error
        case .ft8: ft8.start(on: device); return ft8.error
        case .occupancy: occupancy.start(on: device); return occupancy.error
        default: return nil
        }
    }

    private func extraStorage(_ mode: Mode) -> AnyObject? {
        switch mode {
        case .radio: radioStorage
        case .sensors: sensorsStorage
        case .smartHome868: smartHomeStorage
        case .dsc: dsc
        case .ft8: ft8Storage
        case .occupancy: occupancy
        default: nil
        }
    }
    /// Netzkarte für die Webseite (Anordnung wie in der App, eigenes Nachführen).
    @ObservationIgnored private let zigbeeMap = ZigbeeMapTracker()
    /// „Signal optimieren“ aus der Ferne – ein Exemplar für alle Empfänger.

    /// Wird von der App beim Start gesetzt.
    weak var session: DeviceSession?

    /// Vom Browser gewählter Empfänger; `nil`, solange niemand aus der Ferne umgeschaltet hat.
    private(set) var remoteMode: Mode? {
        didSet { updateLocalMute() }
    }
    private(set) var running = false
    private(set) var error: String?
    private(set) var listeners = 0
    private(set) var lastRequest: Date?
    /// Laufende Umschaltungen (Zähler statt Bool: zwei Anfragen während
    /// `enterHackRFMode` setzten sonst gegenseitig „fertig“, und der Wächter
    /// startete dazwischen den alten Modus neu).
    private var switchCount = 0
    var switching: Bool { switchCount > 0 }

    static let enabledKey = "remoteEnabled"
    static let portKey = "remotePort"
    static let localOnlyKey = "remoteLocalOnly"
    static let defaultPort = 1478

    /// „Nur Heimnetz und VPN“ (ab Werk an): Gegenstellen außerhalb von Loopback,
    /// RFC 1918, Link-local, CGNAT/Tailscale und ULA weist der Server sofort ab
    /// (`RemoteAccessPolicy.isHomeOrVPN`). Der Fernzugriff läuft von unterwegs über VPN.
    var localOnly: Bool {
        get { access(keyPath: \.localOnly); return UserDefaults.standard.object(forKey: Self.localOnlyKey) as? Bool ?? true }
        set {
            withMutation(keyPath: \.localOnly) { UserDefaults.standard.set(newValue, forKey: Self.localOnlyKey) }
            server.setLocalOnly(newValue)
        }
    }

    /// Zuletzt abgewiesene Gegenstelle (außerhalb von Heimnetz und VPN) samt Zeit.
    private(set) var lastRejected: (address: String, date: Date)?

    var enabled: Bool {
        get { access(keyPath: \.enabled); return UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            withMutation(keyPath: \.enabled) { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
            applySettings()
        }
    }

    var port: Int {
        get {
            access(keyPath: \.port)
            let value = UserDefaults.standard.integer(forKey: Self.portKey)
            return value == 0 ? Self.defaultPort : value
        }
        set {
            withMutation(keyPath: \.port) { UserDefaults.standard.set(newValue, forKey: Self.portKey) }
            if running { applySettings(restart: true) }
        }
    }

    /// Konten und angemeldete Geräte (seit 30.10.2026 statt des geteilten Schlüssels).
    private(set) var accounts = RemoteAccountBook()
    /// Der Schlüsselbund war nicht lesbar: Der Fernzugriff ist ausgesetzt, bis die
    /// Konten wieder gelesen werden können. Nie mit leerer Liste weitermachen und
    /// speichern – das löschte alle Konten (wie früher beim Schlüssel, Review 29.10.2026).
    private(set) var accountsUnavailable = false
    @ObservationIgnored private var accountsRetryTask: Task<Void, Never>?
    @ObservationIgnored private var loginThrottle = LoginThrottle()

    @ObservationIgnored private let server = RemoteHTTPServer()
    @ObservationIgnored private var encoder: AACStreamEncoder?
    @ObservationIgnored private var activity: NSObjectProtocol?
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Fernzugriff")

    /// Konten im Schlüsselbund; im Testwirt nur im Speicher.
    @ObservationIgnored private let accountStore: RemoteAccountStore

    private init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // Testwirt: teilt UserDefaults und Schlüsselbund mit der echten App – hier
            // nichts lesen und nichts schreiben (Schlüsselbund-Abfragen, echte Konten).
            accountStore = .memory()
        } else {
            accountStore = .keychain
            loadAccounts()
        }
    }

    /// Konten lesen; beim ersten Start mit Konten den alten Zugangsschlüssel löschen.
    private func loadAccounts() {
        switch accountStore.load() {
        case .found(var book):
            if book.prune() { _ = accountStore.save(book) }
            accounts = book
            accountsUnavailable = false
        case .notFound:
            accounts = RemoteAccountBook()
            accountsUnavailable = false
            RemoteAccountStore.removeLegacyToken()
        case .failed(let status):
            accountsUnavailable = true
            Self.log.error("Konten im Schlüsselbund nicht lesbar (\(status)) – Fernzugriff ausgesetzt")
        }
    }

    /// Liest die Konten erneut (nach einem Schlüsselbund-Fehler) – erst nach 30 s,
    /// dann mit wachsendem Abstand bis 10 min: Fragt der Schlüsselbund dabei nach,
    /// soll nicht alle 30 s ein Dialog erscheinen.
    private func retryAccountsLoad() {
        guard accountsRetryTask == nil else { return }
        accountsRetryTask = Task { [weak self] in
            var delay = 30.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 600)
                guard let self, !Task.isCancelled else { return }
                self.loadAccounts()
                if !self.accountsUnavailable {
                    Self.log.info("Konten wieder lesbar – Fernzugriff geht weiter")
                    self.accountsRetryTask = nil
                    self.applySettings()
                    return
                }
            }
        }
    }

    // MARK: - Konten (Einstellungen am Mac)

    /// Änderung übernehmen und sichern; `nil` = gespeichert, sonst Fehlertext.
    private func commit(_ book: RemoteAccountBook) -> String? {
        guard !accountsUnavailable else { return String(localized: "Die Konten sind im Schlüsselbund gerade nicht lesbar.") }
        guard accountStore.save(book) else { return String(localized: "Die Konten ließen sich nicht im Schlüsselbund sichern.") }
        accounts = book
        return nil
    }

    static func message(_ problem: RemoteAccountBook.Problem) -> String {
        switch problem {
        case .invalidName: String(localized: "Der Benutzername darf 1–32 Zeichen lang sein: Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich.")
        case .duplicateName: String(localized: "Diesen Benutzernamen gibt es schon.")
        case .shortPassword: String(localized: "Das Passwort braucht mindestens \(RemoteAccountBook.minimumPasswordLength) Zeichen.")
        case .unknownAccount: String(localized: "Dieses Konto gibt es nicht mehr.")
        case .lastController: String(localized: "Mindestens ein Konto muss bedienen dürfen.")
        }
    }

    func addAccount(name: String, password: String, role: RemoteAccount.Role) -> String? {
        var book = accounts
        do { try book.add(name: name, password: password, role: role) } catch { return Self.message(error) }
        return commit(book)
    }

    func setPassword(_ password: String, for name: String) -> String? {
        var book = accounts
        do { try book.setPassword(password, for: name) } catch { return Self.message(error) }
        return commit(book)
    }

    func setRole(_ role: RemoteAccount.Role, for name: String) -> String? {
        var book = accounts
        do { try book.setRole(role, for: name) } catch { return Self.message(error) }
        return commit(book)
    }

    func removeAccount(_ name: String) -> String? {
        var book = accounts
        book.remove(name)
        return commit(book)
    }

    func signOutEverywhere(_ name: String) -> String? {
        var book = accounts
        book.signOut(name)
        return commit(book)
    }

    // MARK: - Server

    /// Beim Programmstart aufrufen: startet den Server, wenn er eingeschaltet war.
    func bootstrap(session: DeviceSession) {
        self.session = session
        applySettings()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var stalled = 0
            var orphaned: [Mode: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.stopOrphans(&orphaned)
                switch self.reception {
                case .fine: stalled = 0
                case .takenOver: stalled = 0; self.yieldToLocalPage()
                case .lost:
                    stalled += 1
                    if stalled >= 2 { stalled = 0; self.restartRemoteMode() }
                }
            }
        }
    }

    /// Takt, der aus der Ferne gewählten Empfang wieder anwirft (siehe `reception`).
    private var watchdog: Task<Void, Never>?

    private enum Reception { case fine, lost, takenOver }

    /// Zustand des aus der Ferne gewählten Empfangs. `lost`: der Empfänger hält
    /// sich für laufend, der HackRF liefert aber nichts (Fund 26.10.2026: kein
    /// Ton, DAB+ „lief“ ohne Pegel, weil eine andere Seite beim Schließen den
    /// Empfang beendet hatte – seither darf nur der Besitzer stoppen).
    /// `takenOver`: eine Seite am Mac hat das Gerät übernommen; das hat Vorrang.
    private var reception: Reception {
        guard !switching, let mode = remoteMode, activeMode == mode,
              let device = session?.hackRF else { return .fine }
        if device.isStalled(for: model(for: mode)) { return .lost }
        if device.isReceiving(for: model(for: mode)) { return .fine }
        if device.isReceiving { return .takenOver }
        // Ein Stoß-Empfänger (LTE) gibt den Strom zwischen seinen Aufnahmen
        // frei. „Niemand empfängt“ ist dann eine Übernahme, kein Abriss – sonst
        // startete der Wächter den Fernzugriffs-Empfänger neu, und beide
        // schaukelten sich auf (Review 28.10.2026, W3).
        if let burst = device.burstOwner as? GainTunable, burst.running, burst.receivesInBursts { return .takenOver }
        return .lost
    }

    /// Empfänger, die sich für laufend halten, deren Strom aber längst einer
    /// anderen Seite gehört (z. B. nach `resumeAfterPlan` ohne Fernbetrieb und
    /// dann Radio am Mac). Sie blieben sonst ewig „an“: Webseite und `activeMode`
    /// zeigten den falschen Empfänger, und der Schalter „Externer
    /// Vorverstärker“ oder `/api/spectrum` griffen auf den fremden Strom durch.
    private func stopOrphans(_ ticks: inout [Mode: Int]) {
        guard !switching, let device = session?.hackRF else { ticks = [:]; return }
        for mode in Mode.allCases where mode != remoteMode {
            let running: Bool = switch mode {
            case .adsb: adsb.running
            case .ais: ais.running
            case .dab: dab.running
            case .spectrum: spectrum.running
            case .acars: acars.running
            case .zigbee: zigbeeRunning
            case .airband: airbandRunning
            case .radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy: extraRunning(mode)
            }
            guard running, !device.isReceiving(for: model(for: mode)) else { ticks[mode] = 0; continue }
            ticks[mode, default: 0] += 1
            guard ticks[mode, default: 0] >= 2 else { continue }
            ticks[mode] = 0
            Self.log.notice("\(mode.rawValue, privacy: .public) lief ohne Gerät weiter – gestoppt")
            switch mode {
            case .adsb: adsb.stop(on: device)
            case .ais: ais.stop(on: device)
            case .dab: dab.stop()
            case .spectrum: spectrum.stop(on: device)
            case .acars: acars.stop()
            case .zigbee: zigbee.stop(on: device)
            case .airband: airband.stop()
            case .radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy: extraStop(mode, device)
            }
        }
    }

    /// Das Modell eines Modus (für die Statuszeile: wem gehört der Strom?).
    /// Empfänger eines Modus, ohne ihn anzulegen: Zigbee entsteht erst bei
    /// Bedarf (vier Schlüsselbundzugriffe). `DeviceArbiter.title` läuft im
    /// View-Body und legte es sonst bei jeder Auswertung an (Review 28.10.2026).
    func existingOwner(for mode: Mode) -> AnyObject? {
        if mode == .zigbee { return zigbeeStorage }
        if mode == .airband { return airbandStorage }
        if let extra = extraStorage(mode) { return extra }
        if [Mode.radio, .sensors, .smartHome868, .ft8].contains(mode) { return nil }
        return model(for: mode)
    }

    private func model(for mode: Mode) -> AnyObject {
        switch mode {
        case .adsb: adsb
        case .ais: ais
        case .dab: dab
        case .spectrum: spectrum
        case .acars: acars
        case .zigbee: zigbee
        case .airband: airband
        case .radio: radio
        case .sensors: sensors
        case .smartHome868: smartHome
        case .dsc: dsc
        case .ft8: ft8
        case .occupancy: occupancy
        }
    }

    /// Eine Seite am Mac empfängt jetzt: Fernbetrieb beenden, ohne ihr das
    /// Gerät wegzunehmen (`stop` beendet nur den eigenen Empfang).
    private func yieldToLocalPage() {
        guard let mode = remoteMode, let device = session?.hackRF else { return }
        Self.log.notice("Andere Seite hat den HackRF übernommen, Fernbetrieb \(mode.rawValue, privacy: .public) endet")
        switch mode {
        case .adsb: adsb.stop(on: device)
        case .ais: ais.stop(on: device)
        case .dab: dab.stop()
        case .spectrum: spectrum.stop(on: device)
        case .acars: acars.stop()
        case .zigbee: zigbee.stop(on: device)
        case .airband: airband.stop()
        case .radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy: extraStop(mode, device)
        }
        remoteMode = nil
    }

    private func restartRemoteMode() {
        guard let mode = remoteMode, let device = session?.hackRF, session?.busy != true else { return }
        Self.log.notice("Empfang war gestoppt, starte \(mode.rawValue, privacy: .public) neu")
        switch mode {
        case .adsb: adsb.stop(on: device); adsb.start(on: device)
        case .ais: ais.stop(on: device); ais.start(on: device)
        case .dab: dab.stop(); dab.start(on: device)
        case .spectrum: spectrum.stop(on: device); spectrum.start(on: device)
        case .acars: acars.stop(); acars.start(on: device)
        case .zigbee: zigbee.stop(on: device); zigbee.start(on: device)
        case .airband: airband.stop(); airband.start(on: device)
        case .radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy: extraStop(mode, device); extraStart(mode, device)
        }
    }

    func applySettings(restart: Bool = false) {
        // Der Testwirt teilt die UserDefaults der echten App: ohne diese Sperre
        // belegte ein Testlauf Port 1478, und die echte App kam nicht mehr an ihren
        // Server (Fund 30.10.2026, Testlauf von `release.sh`).
        if enabled, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            if accountsUnavailable {
                stopServer()
                error = String(localized: "Die Konten sind im Schlüsselbund gerade nicht lesbar. Der Fernzugriff ist ausgesetzt und startet von selbst, sobald sie wieder gelesen werden können.")
                retryAccountsLoad()
                return
            }
            if running && !restart { return }
            startServer()
        } else {
            stopServer()
        }
    }

    private func startServer() {
        server.onListenerCount = { [weak self] count in
            Task { @MainActor in self?.listenersChanged(count) }
        }
        server.onState = { [weak self] message in
            Task { @MainActor in self?.serverStateChanged(message) }
        }
        server.onRejected = { [weak self] address in
            Task { @MainActor in self?.lastRejected = (address, Date()) }
        }
        server.setLocalOnly(localOnly)
        do {
            try server.start(port: UInt16(clamping: port)) { [weak self] request in
                guard let self else { return .text(503, String(localized: "Beendet")) }
                return await self.handle(request)
            }
            running = true
            error = nil
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: "Fernzugriff auf den HackRF")
            }
            AircraftDatabase.shared.loadIfNeeded()
            Self.log.info("Fernzugriff auf Port \(self.port) gestartet")
        } catch {
            running = false
            self.error = String(localized: "Port \(port): \(error.localizedDescription)")
        }
    }

    /// Neuversuch nach einem gescheiterten Listener (siehe `serverStateChanged`).
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// Der Listener meldet Fehler erst asynchron – `start` wirft dann nicht.
    /// Fund 28.10.2026: Eine zweite App-Instanz (Neustart, während die alte
    /// noch beendet wurde) bekam „Address already in use“, die alte gab den
    /// Port Sekunden später frei, und der Fernzugriff blieb bis zum nächsten
    /// Neustart tot. Deshalb alle 5 s neu versuchen, solange eingeschaltet.
    private func serverStateChanged(_ message: String?) {
        error = message.map { String(localized: "Server: \($0)") }
        guard message != nil else {
            retryTask?.cancel(); retryTask = nil
            return
        }
        Self.log.error("Fernzugriff-Server gescheitert: \(message ?? "", privacy: .public) – neuer Versuch in 5 s")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.enabled else { return }
            self.applySettings(restart: true)
        }
    }

    private func stopServer() {
        retryTask?.cancel(); retryTask = nil
        server.stop()
        running = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        dab.setRemoteTap(nil)
        airbandStorage?.setRemoteTap(nil)
        radioStorage?.setRemoteTap(nil)
        encoder = nil
        listeners = 0
        remoteMode = nil
        updateLocalMute()
    }

    private func listenersChanged(_ count: Int) {
        listeners = count
        if count > 0 {
            if encoder == nil {
                let encoder = AACStreamEncoder()
                let server = server
                encoder?.onData = { server.broadcast($0) }
                self.encoder = encoder
            }
        } else {
            encoder = nil
        }
        applyAudioTaps()
    }

    /// Der Mac bleibt stumm, solange jemand aus der Ferne hört oder DAB+ aus
    /// der Ferne gestartet wurde – sonst spielt der Mac zu Hause laut, während
    /// man unterwegs noch auf „Anhören“ tippt (Fund 25.10.2026).
    private func updateLocalMute() {
        dab.setLocalMuted(listeners > 0 || remoteMode == .dab)
        airbandStorage?.setLocalMuted(listeners > 0 || remoteMode == .airband)
        radioStorage?.setLocalMuted(listeners > 0 || remoteMode == .radio)
    }

    /// Ein gemeinsamer Tonstrom (`/audio.aac`) für DAB+ und Flugfunk: Es spielt,
    /// wer gerade empfängt. Flugfunk ist mono und geht auf beide Kanäle.
    private func applyAudioTaps() {
        if listeners > 0, let encoder {
            dab.setRemoteTap { left, right in encoder.push(left: left, right: right) }
            airbandStorage?.setRemoteTap { mono in encoder.push(left: mono, right: mono) }
            radioStorage?.setRemoteTap { left, right in encoder.push(left: left, right: right) }
        } else {
            dab.setRemoteTap(nil)
            airbandStorage?.setRemoteTap(nil)
            radioStorage?.setRemoteTap(nil)
        }
        updateLocalMute()
    }

    // MARK: - Umschalten

    /// Vor einem Start in der App: andere Empfänger des Fernzugriffs anhalten,
    /// damit der HackRF frei ist (er empfängt nur ein Band).
    func prepareLocalStart(_ mode: Mode) {
        guard let device = session?.hackRF else { return }
        stopAll(except: mode, device: device)
        if remoteMode != mode { remoteMode = nil }
    }

    /// Für den Empfangsplan: laufenden Empfänger anhalten (aus der Ferne oder
    /// in der App gestartet) und zurückgeben, wie er lief.
    func suspendForPlan() -> (mode: Mode, remote: Bool)? {
        let mode = remoteMode ?? activeMode
        let remote = remoteMode != nil
        endRemoteMode()
        return mode.map { ($0, remote) }
    }

    /// Nach dem Termin wieder einschalten – aus der Ferne gewählt wie zuvor,
    /// sonst als Empfang der App-Seite (ohne Fernbetrieb).
    func resumeAfterPlan(_ mode: Mode, remote: Bool) async {
        if remote { _ = await activate(mode); return }
        guard let device = session?.hackRF else { return }
        switch mode {
        case .adsb: adsb.start(on: device)
        case .ais: ais.start(on: device)
        case .dab: dab.start(on: device)
        case .spectrum: spectrum.start(on: device)
        case .acars: acars.start(on: device)
        case .zigbee: zigbee.start(on: device)
        case .airband: airband.start(on: device)
        case .radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy: extraStart(mode, device)
        }
    }

    /// Fernbetrieb beenden: Empfänger aus und Gerät frei.
    func endRemoteMode() {
        if let device = session?.hackRF { stopAll(except: nil, device: device) }
        remoteMode = nil
    }

    private func stopAll(except mode: Mode?, device: HackRFDevice) {
        if mode != .adsb, adsb.running { adsb.stop(on: device) }
        if mode != .ais, ais.running { ais.stop(on: device) }
        if mode != .dab, dab.running { dab.stop() }
        if mode != .spectrum, spectrum.running { spectrum.stop(on: device) }
        if mode != .acars, acars.running { acars.stop() }
        if mode != .zigbee, zigbeeRunning { zigbee.stop(on: device) }
        if mode != .airband, airbandRunning { airband.stop() }
        for extra in [Mode.radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy] where mode != extra && extraRunning(extra) {
            extraStop(extra, device)
        }
        // Auch Seiten außerhalb des Fernzugriffs können den HackRF belegen.
        if !(mode == .adsb && adsb.running) && !(mode == .ais && ais.running) && !(mode == .dab && dab.running)
            && !(mode == .spectrum && spectrum.running) && !(mode == .acars && acars.running)
            && !(mode == .zigbee && zigbeeRunning) && !(mode == .airband && airbandRunning)
            && !(mode.map { extraRunning($0) } ?? false) {
            device.stopReceiving()
        }
    }

    func activate(_ mode: Mode?) async -> String? {
        guard let session else { return String(localized: "Keine Sitzung") }
        // Während einer Firmware-Installation nie umschalten – `hackrf` mitten in
        // `upload`/`flash` ließe die Installation scheitern.
        guard !session.busy else { return String(localized: "Am Mac läuft gerade eine Installation – bitte warten.") }
        switchCount += 1
        defer { switchCount -= 1 }
        if session.hackRF == nil {
            guard session.device != nil else { return String(localized: "Kein Gerät verbunden") }
            await session.enterHackRFMode()
            for _ in 0..<40 where session.hackRF == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Während der Wartezeit kann am Mac eine Installation (Rettungsweg über
        // den HackRF-Modus) begonnen haben – dann nicht empfangen (Review 28.10.2026, Y1).
        guard !session.busy else { return String(localized: "Am Mac läuft gerade eine Installation – bitte warten.") }
        guard let device = session.hackRF else { return String(localized: "HackRF-Modus nicht erreicht") }
        // Das Handy hat gewählt (auch „■ Stopp“): Mac-Empfänger sauber beenden statt
        // ihnen nur den Strom zu nehmen, und nach einem Plan-Termin nichts von
        // selbst zurückholen (Nutzerwunsch 29.10.2026).
        ReceptionPlanner.shared.dropResume()
        ReceiverStore.shared.stopLocalReceivers(on: device)
        stopAll(except: nil, device: device)
        remoteMode = mode
        switch mode {
        case .adsb: adsb.start(on: device); return adsb.error
        case .ais: ais.start(on: device); return ais.error
        case .dab: dab.start(on: device); return dab.error
        case .spectrum: spectrum.start(on: device); return spectrum.error
        case .acars: acars.start(on: device); return acars.error
        case .zigbee: zigbee.start(on: device); return zigbee.error
        case .airband: airband.start(on: device); return airband.error
        case .radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy: return extraStart(mode!, device)
        case nil: return nil
        }
    }

    /// Welcher der drei Empfänger gerade läuft (egal, ob aus der App oder der Ferne).
    var activeMode: Mode? {
        if adsb.running { return .adsb }
        if ais.running { return .ais }
        if dab.running { return .dab }
        if spectrum.running { return .spectrum }
        if acars.running { return .acars }
        if zigbeeRunning { return .zigbee }
        if airbandRunning { return .airband }
        for extra in [Mode.radio, .sensors, .smartHome868, .dsc, .ft8, .occupancy] where extraRunning(extra) { return extra }
        return nil
    }

    /// Schalter „Externer Vorverstärker“: die Seiten werden neu aufgebaut,
    /// diese drei Empfänger aber leben weiter – Vorgaben hier neu setzen.
    func applyGainPresets() {
        let a = GainProfile.preset(.adsb), s = GainProfile.preset(.ais), d = GainProfile.preset(.dab)
        adsb.lnaGain = a.lna; adsb.vgaGain = a.vga; adsb.amplifier = a.amplifier
        ais.lnaGain = s.lna; ais.vgaGain = s.vga; ais.amplifier = s.amplifier
        dab.lnaGain = d.lna; dab.vgaGain = d.vga; dab.amplifier = d.amplifier
        let p = GainProfile.preset(.spectrum)
        spectrum.lnaGain = p.lna; spectrum.vgaGain = p.vga; spectrum.amplifier = p.amplifier
        if spectrum.running { spectrum.applyQuietly(to: session?.hackRF) }
        let c = GainProfile.preset(.acars)
        acars.lnaGain = c.lna; acars.vgaGain = c.vga; acars.amplifier = c.amplifier
        if acars.running { acars.applyGainsQuietly() }
        if let zigbee = zigbeeStorage {
            let z = GainProfile.preset(.zigbee)
            zigbee.lnaGain = z.lna; zigbee.vgaGain = z.vga; zigbee.amplifier = z.amplifier
            // Nur den eigenen Strom verstellen (Gerätebesitz).
            if zigbee.running, let device = session?.hackRF, device.isReceiving(for: zigbee) { try? zigbee.applyGains(to: device) }
        }
        airbandStorage?.reloadStoredGains()
        if adsb.running { try? adsb.applyGains(to: session?.hackRF) }
        if ais.running { try? ais.applyGains(to: session?.hackRF) }
        if dab.running { dab.applyGainsQuietly() }
        // Auch die Modelle des Empfangsplans leben weiter: METEOR behielt sonst
        // den internen Vorverstärker, die Sonde ihre Werte der anderen Einstellung.
        let planner = ReceptionPlanner.shared, m = GainProfile.preset(.meteor)
        planner.meteor.lnaGain = m.lna; planner.meteor.vgaGain = m.vga; planner.meteor.amplifier = m.amplifier
        if let device = session?.hackRF, device.isReceiving(for: planner.meteor) { try? planner.meteor.applyGains(to: device) }
        planner.sonde.reloadGains()
    }

    // MARK: - Adressen

    struct Address: Hashable {
        let url: String
        let note: String
    }

    /// Erreichbare Adressen: Rechnername (Bonjour) und IPv4 – ohne Schlüssel, die Seite meldet an.
    var addresses: [Address] {
        var result: [Address] = []
        if let name = Host.current().localizedName {
            let host = name.replacingOccurrences(of: " ", with: "-").folding(options: .diacriticInsensitive, locale: nil)
            result.append(Address(url: "http://\(host).local:\(port)/", note: String(localized: "Heimnetz (Rechnername)")))
        }
        for ip in Self.ipv4Addresses() {
            let note = ip.hasPrefix("100.") && Self.isCGNAT(ip) ? String(localized: "Tailscale (von unterwegs)") : String(localized: "Heimnetz")
            result.append(Address(url: "http://\(ip):\(port)/", note: note))
        }
        return result
    }

    static func isCGNAT(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func ipv4Addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !ip.hasPrefix("169.254."), !result.contains(ip) { result.append(ip) }
            }
        }
        return result
    }

    // MARK: - Anfragen

    /// Eigene Namen des Macs für die `Host`-Prüfung (einmal ermittelt). `gethostname`
    /// statt `ProcessInfo.hostName` – Letzteres fragt mitunter sekundenlang das DNS.
    private static let localHostNames: [String] = {
        var buffer = [CChar](repeating: 0, count: 256)
        var names: [String] = []
        if gethostname(&buffer, buffer.count) == 0 {
            names.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        if let name = Host.current().localizedName {
            names.append(name.replacingOccurrences(of: " ", with: "-").folding(options: .diacriticInsensitive, locale: nil) + ".local")
        }
        return names
    }()

    /// Anmeldeseite in der Sprache der App.
    private static func loginPage(status: Int, message: String? = nil, name: String = "", noAccounts: Bool = false) -> RemoteHTTPServer.Response {
        .data(status: status, contentType: "text/html; charset=utf-8",
              body: Data(RemotePage.login(message: message, name: name, noAccounts: noAccounts).utf8))
    }

    /// 303 zur Startseite (nach dem Formular, damit „Neu laden“ nicht erneut sendet).
    private static func redirectHome(cookies: [String]) -> RemoteHTTPServer.Response {
        var headers = ["Location": "/"]
        // `extraHeaderLines` kennt je Name nur einen Wert – mehrere Cookies als eigene
        // `Set-Cookie`-Zeilen über eine eingefügte Zeilengrenze.
        if !cookies.isEmpty { headers["Set-Cookie"] = cookies.joined(separator: "\r\nSet-Cookie: ") }
        return .withHeaders(headers, .data(status: 303, contentType: "text/plain; charset=utf-8", body: Data()))
    }

    /// Formular `POST /login`: Name und Passwort prüfen (PBKDF2 abseits des Main Actor),
    /// Fehlversuche je Gegenstelle bremsen, bei Erfolg Sitzung und Cookie.
    private func login(_ request: RemoteHTTPServer.Request) async -> RemoteHTTPServer.Response {
        let peer = request.peer ?? "?"
        let form = request.form
        let name = String((form["name"] ?? "").prefix(32))
        let password = String((form["password"] ?? "").prefix(200))
        if accounts.accounts.isEmpty { return Self.loginPage(status: 401, noAccounts: true) }
        if let wait = loginThrottle.blocked(peer) {
            return Self.loginPage(status: 429, message: String(localized: "Zu viele Fehlversuche – versuch es in \(wait) s erneut."), name: name)
        }
        let candidates = accounts.accounts
        let account = await Task.detached(priority: .userInitiated) {
            RemoteAccountBook.verify(name: name, password: password, in: candidates)
        }.value
        // Während der Prüfung gelöscht oder Passwort geändert: gilt nicht mehr.
        guard let account, accounts.account(named: account.name)?.hash == account.hash else {
            loginThrottle.fail(peer)
            Self.log.notice("Anmeldung fehlgeschlagen von \(peer, privacy: .public)")
            return Self.loginPage(status: 401, message: String(localized: "Benutzername oder Passwort stimmt nicht."), name: name)
        }
        loginThrottle.succeed(peer)
        var book = accounts
        let token = book.createSession(for: account)
        if let problem = commit(book) { return Self.loginPage(status: 503, message: problem, name: name) }
        Self.log.notice("Angemeldet: \(account.name, privacy: .public) von \(peer, privacy: .public)")
        return Self.redirectHome(cookies: [RemoteAccessPolicy.sessionCookie(token: token)])
    }

    private func handle(_ request: RemoteHTTPServer.Request) async -> RemoteHTTPServer.Response {
        // DNS-Rebinding: ein fremder Name, der plötzlich auf den Mac zeigt, kommt nicht durch.
        guard RemoteAccessPolicy.allowsHost(request.headers["host"], localNames: Self.localHostNames) else {
            Self.log.notice("Abgewiesen (fremder Host-Kopf): \(request.headers["host"] ?? "", privacy: .public)")
            return .text(421, String(localized: "Unbekannter Hostname"))
        }
        // Symbole ohne Schlüssel: iOS lädt das Home-Bildschirm-Symbol ohne Cookie.
        switch request.path {
        case "/icon-180.png", "/apple-touch-icon.png": return Self.icon(size: 180)
        case "/icon-512.png": return Self.icon(size: 512)
        // Leaflet 1.9.4 aus dem App-Bundle (SHA-256 wie die offizielle SRI-Angabe):
        // vom CDN geladen hätte ein kompromittiertes unpkg Schlüssel und Steuerung gesehen.
        case "/leaflet.js": return Self.bundled("leaflet", "js", type: "text/javascript; charset=utf-8")
        case "/leaflet.css": return Self.bundled("leaflet", "css", type: "text/css; charset=utf-8")
        case "/favicon.ico": return .text(404, "")
        default: break
        }
        if request.path == "/manifest.webmanifest" {
            return .data(status: 200, contentType: "application/manifest+json", body: Data(RemotePage.manifest().utf8))
        }
        // CSRF: Aktionen nur aus der eigenen Seite (Review 29.10.2026, S2) – auch An-/Abmelden.
        guard RemoteAccessPolicy.allowsOrigin(path: request.path, headers: request.headers) else {
            Self.log.notice("Abgewiesen (nicht aus der eigenen Seite): \(request.path, privacy: .public)")
            return .text(403, String(localized: "Nur aus der Fernzugriffsseite"))
        }
        switch (request.method, request.path) {
        case ("POST", "/login"): return await login(request)
        case ("POST", "/logout"):
            if let token = RemoteAccessPolicy.sessionToken(cookieHeader: request.headers["cookie"]) {
                var book = accounts
                book.endSession(token)
                _ = commit(book)
            }
            return Self.redirectHome(cookies: RemoteAccessPolicy.clearedCookies)
        default: break
        }
        let token = RemoteAccessPolicy.sessionToken(cookieHeader: request.headers["cookie"])
        guard let account = accounts.account(forSession: token), let token else {
            // Nicht angemeldet: die Seite zeigt die Anmeldung, alles andere 401.
            if request.path == "/" || request.path == "/index.html" || request.path == "/login" {
                return Self.loginPage(status: 200, noAccounts: accounts.accounts.isEmpty)
            }
            return .text(401, String(localized: "Bitte anmelden."))
        }
        if request.path == "/login" { return Self.redirectHome(cookies: []) }
        // „Nur ansehen“: nur lesende Abrufe (Liste in RemoteAccessPolicy.readOnlyParameters).
        if account.role == .view, RemoteAccessPolicy.requiresControl(path: request.path, query: request.query) {
            return .text(403, String(localized: "Dieses Konto darf nur ansehen, nichts umschalten oder einstellen."))
        }
        // Erst nach der Anmeldung – sonst erschien jeder Portscan als „letzter Abruf“.
        lastRequest = Date()
        var touched = accounts
        if touched.touch(session: token) { _ = commit(touched) }
        switch request.path {
        case "/", "/index.html":
            let page = RemotePage.page(user: account.name, role: account.role)
            return .data(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8))
        case "/api/state":
            return .json(snapshotJSON(selected: request.query["sel"]))
        case "/api/mode":
            // Nur ein leerer Wert gibt frei; ein unbekannter stoppte früher still alles.
            let raw = request.query["m"] ?? ""
            let mode = Mode(rawValue: raw)
            if !raw.isEmpty, mode == nil { return .text(400, String(localized: "Unbekannter Empfänger")) }
            if let message = await activate(mode) { return .text(409, message) }
            return .json(snapshotJSON(selected: nil))
        case "/api/dab/play":
            guard let channel = request.query["ch"], let id = request.query["id"].flatMap({ UInt32($0) }),
                  let service = dab.ensembles.first(where: { $0.channel == channel })?.services.first(where: { $0.id == id })
            else { return .text(400, String(localized: "Unbekannter Sender")) }
            if !dab.running || remoteMode != .dab {
                if let message = await activate(.dab) { return .text(409, message) }
            }
            dab.play(service, on: channel)
            return .json(snapshotJSON(selected: nil))
        case "/api/dab/scan":
            if !dab.running {
                if let message = await activate(.dab) { return .text(409, message) }
            }
            dab.scan()
            return .json(snapshotJSON(selected: nil))
        case "/audio.aac":
            return .stream(contentType: "audio/aac")
        case "/api/archive":
            let archive = request.query["kind"] == "ais" ? TrafficArchive.ais : TrafficArchive.adsb
            return .json(await archiveJSON(archive, day: request.query["day"], id: request.query["id"]))
        case "/api/acars":
            return .json(acarsJSON(since: request.query["since"].flatMap { Int($0) } ?? 0))
        case "/api/spectrum":
            return .json(spectrumJSON(request.query))
        case "/api/fm":
            return .json(RemoteRadioAPI.handle(request.query, hub: self))
        case "/api/sensors":
            return .json(RemoteSensorsAPI.handle(request.query, hub: self))
        case "/api/smart868":
            return .json(RemoteSmartHomeAPI.handle(request.query, hub: self))
        case "/api/dsc":
            return .json(RemoteDSCAPI.handle(request.query, hub: self))
        case "/api/ft8":
            return .json(RemoteFT8API.handle(request.query, hub: self))
        case "/api/occupancy":
            return .json(RemoteOccupancyAPI.handle(request.query, hub: self))
        case "/occupancy.png":
            return await RemoteOccupancyAPI.image(request.query)
        case "/api/airband":
            return .json(RemoteAirband.handle(request.query, hub: self))
        case "/api/airband/search":
            return .json(await RemoteAirband.search(request.query, model: airband))
        case "/api/zigbee":
            // Kanalwahl verstellt nur den eigenen Strom (`setChannel` prüft den Besitz).
            if let channel = request.query["ch"].flatMap({ Int($0) }), IEEE802154.channels.contains(channel) {
                zigbee.setChannel(channel)
            }
            return .json(zigbeeJSON(pan: request.query["pan"]))
        case "/api/spectrum/presets":
            return .json(Self.spectrumPresetsJSON)
        case "/api/optimize":
            guard let mode = activeMode, let model = tunable(for: mode) else {
                return .text(409, String(localized: "Kein Empfänger läuft, der sich optimieren lässt."))
            }
            let optimizer = GainOptimizer.shared(for: model)
            if request.query["cancel"] == "1" {
                optimizer.cancel()
                return .json(snapshotJSON(selected: nil))
            }
            guard !optimizer.active else { return .text(409, String(localized: "Die Optimierung läuft schon.")) }
            guard let device = session?.hackRF, device.isReceiving(for: model) else {
                return .text(409, String(localized: "Der HackRF empfängt gerade nicht für \(mode.title)."))
            }
            optimizer.run(model, device: device)
            return .json(snapshotJSON(selected: nil))
        case "/api/gain":
            if let auto = request.query["auto"] { AutoGain.shared.enabled = auto == "1" }
            return .json(snapshotJSON(selected: nil))
        case "/api/sondes": return await RemoteSondes.handle(request.query)
        case "/api/airports":
            return .json(await RemoteAirports.handle(request.query))
        case "/api/plan":
            return .json(RemoteWeather.plan(request.query))
        case "/img":
            return RemoteWeather.image(name: request.query["n"], width: request.query["w"].flatMap { Int($0) })
        default:
            return .text(404, String(localized: "Nicht gefunden"))
        }
    }

    /// Empfänger, die „Signal optimieren“ kennen (das Spektrum hat keinen Dekoder).
    private func tunable(for mode: Mode) -> (any GainTunable)? {
        switch mode {
        case .adsb: adsb
        case .ais: ais
        case .dab: dab
        case .acars: acars
        case .airband: airbandStorage
        case .radio: radioStorage
        case .sensors: sensorsStorage
        case .smartHome868: smartHomeStorage
        case .dsc: dsc
        case .ft8: ft8Storage
        case .occupancy, .spectrum, .zigbee: nil
        }
    }

    // MARK: - ACARS & VDL2

    private struct ACARSPage: Encodable {
        struct Item: Encodable {
            var id: Int
            var t: Double
            var f: Double
            var reg: String
            var flight: String?
            var label: String
            var labelName: String?
            var summary: String
            var rows: [[String]]
            var text: String
            var blocks: Int
            var icao: String?
            var down: Bool
            var opaque: Bool
            var lat: Double?
            var lon: Double?
            var onMap: Bool
        }
        var running: Bool
        var band: String
        var messages: Int
        var frames: Int
        var aircraft: Int
        var items: [Item]
    }

    /// Nachrichten neuer als `since` (ID), neueste zuerst, höchstens 150 –
    /// mit fertiger Deutung, damit das Handy nichts rechnen muss.
    private func acarsJSON(since: Int) -> Data {
        let now = Date()
        let visible = adsb.aircraft.filter { now.timeIntervalSince($0.lastSeen) < MapAircraft.holdSeconds }.map(\.icao)
        let items = acars.messages.filter { $0.id > since || since == 0 }.prefix(150).map { m -> ACARSPage.Item in
            let i = m.interpretation
            return ACARSPage.Item(id: m.id, t: m.date.timeIntervalSince1970 * 1000, f: m.frequencyMHz, reg: m.registration,
                                  flight: m.flight, label: m.label, labelName: m.labelMeaning, summary: i.summary,
                                  rows: i.rows.map { [$0.name, $0.value] }, text: m.text, blocks: m.blocks,
                                  icao: m.icao.map { String(format: "%06X", $0) }, down: m.isDownlink, opaque: i.opaque,
                                  lat: i.latitude, lon: i.longitude, onMap: m.icao.map { visible.contains($0) } ?? false)
        }
        let page = ACARSPage(running: acars.running, band: acars.band == .vdl2 ? "VDL2" : "ACARS", messages: acars.messages.count,
                             frames: acars.vdl2Frames, aircraft: acars.vdl2Aircraft, items: Array(items))
        return (try? JSONEncoder().encode(page)) ?? Data("{}".utf8)
    }

    // MARK: - Zigbee

    /// Geräteliste und Netzkarte; `pan` (hex) wählt das Netz. Ohne Schlüssel.
    private func zigbeeJSON(pan: String?) -> Data {
        let model = zigbee
        let state = RemoteZigbee.state(
            nodes: model.nodes, channel: model.channel, running: model.running, remote: remoteMode == .zigbee,
            frames: model.frameCount, rate: model.frameRate, decrypted: model.decryptedCount, noiseDB: model.noiseDB,
            chosenPAN: pan.flatMap { UInt16($0, radix: 16) }, tracker: zigbeeMap, name: { model.name(of: $0) })
        return (try? JSONEncoder().encode(state)) ?? Data("{}".utf8)
    }

    // MARK: - Spektrum

    private struct SpectrumState: Encodable {
        let running: Bool
        let centerMHz: Double
        let rateMHz: Double
        let lna: Int
        let vga: Int
        let amplifier: Bool
        /// Pegel in dB je Bin (auf 512 verdichtet, Höchstwert je Paar), links = tiefste Frequenz.
        let bins: [Int]
        let error: String?
    }

    /// Stand des Spektrums; `mhz`, `bw`, `lna`, `vga`, `amp` stellen vorher um.
    private func spectrumJSON(_ query: [String: String]) -> Data {
        let model = spectrum
        var changed = false
        if let mhz = query["mhz"].flatMap(Double.init), (1...6000).contains(mhz) { model.centerMHz = mhz; changed = true }
        if let bw = query["bw"].flatMap(Double.init) { model.sampleRateMHz = min(20, max(2, bw)); changed = true }
        if let lna = query["lna"].flatMap(Int.init) { model.lnaGain = Double(min(40, max(0, lna / 8 * 8))); changed = true }
        if let vga = query["vga"].flatMap(Int.init) { model.vgaGain = Double(min(62, max(0, vga / 2 * 2))); changed = true }
        if let amp = query["amp"] { model.amplifier = amp == "1"; changed = true }
        if query["lna"] != nil || query["vga"] != nil || query["amp"] != nil { AutoGain.shared.manualChange(model) }
        if changed, model.running { model.applyQuietly(to: session?.hackRF) }
        let raw = model.spectrum
        var bins: [Int] = []
        if raw.count >= 2 {
            let step = max(1, raw.count / 512)
            bins.reserveCapacity(raw.count / step)
            var i = 0
            while i + step <= raw.count {
                bins.append(Int(raw[i..<(i + step)].max()!.rounded()))
                i += step
            }
        }
        let state = SpectrumState(running: model.running, centerMHz: model.centerMHz, rateMHz: model.sampleRateMHz,
                                  lna: Int(model.lnaGain), vga: Int(model.vgaGain), amplifier: model.amplifier,
                                  bins: bins, error: model.error)
        return (try? JSONEncoder().encode(state)) ?? Data("{}".utf8)
    }

    private struct PresetGroupJSON: Encodable {
        struct Preset: Encodable { let name: String; let mhz: Double; let bw: Double; let note: String? }
        let title: String
        let presets: [Preset]
    }

    private static let spectrumPresetsJSON: Data = {
        let groups = SpectrumPresets.groups.map { group in
            PresetGroupJSON(title: group.title, presets: group.presets.map {
                .init(name: $0.name, mhz: $0.mhz, bw: min(20, max(2, $0.bandwidthMHz)), note: $0.note.isEmpty ? nil : $0.note)
            })
        }
        return (try? JSONEncoder().encode(groups)) ?? Data("[]".utf8)
    }()

    // MARK: - Archiv

    private struct ArchivePage: Encodable {
        struct Item: Encodable {
            let id: String, key: String
            let name: String?, registration: String?, type: String?, route: String?
            let first: Double, last: Double
            let messages: Int
            let maxAltitudeM: Int?, maxSpeed: Double?, minDistanceKm: Double?
            let points: Int
        }
        let days: [String]
        let day: String
        let items: [Item]
        let track: [[Double]]?
    }

    /// Tagesliste ohne Spuren; die Spur nur für `id` (hält die Antwort klein).
    /// Tage und Sichtungen kommen asynchron aus der Datenbank (indizierte Abfrage je
    /// Tag) – ein Zwischenspeicher wie zu Zeiten der gepackten Tagesdateien entfällt.
    private func archiveJSON(_ archive: TrafficArchive, day: String?, id: String?) async -> Data {
        let days = await archive.loadDays()
        let chosen = day.flatMap { days.contains($0) ? $0 : nil } ?? days.first ?? TrafficArchive.dayStamp(Date())
        let sightings = await archive.sightings(days: [chosen])
        let page = ArchivePage(
            days: days, day: chosen,
            items: sightings.map {
                .init(id: $0.id, key: $0.key, name: $0.name, registration: $0.registration, type: $0.type, route: $0.route,
                      first: $0.first.timeIntervalSince1970 * 1000, last: $0.last.timeIntervalSince1970 * 1000,
                      messages: $0.messages, maxAltitudeM: $0.maxAltitudeM, maxSpeed: $0.maxSpeed,
                      minDistanceKm: $0.minDistanceKm, points: $0.track.count)
            },
            track: id.flatMap { id in sightings.first { $0.id == id }?.track })
        return (try? JSONEncoder().encode(page)) ?? Data("{}".utf8)
    }

    // MARK: - Symbol

    private static var iconCache: [Int: Data] = [:]

    /// App-Symbol als PNG auf deckendem Grund (iOS rundet selbst ab und
    /// zeigt Transparenz schwarz).
    private static func bundled(_ name: String, _ ext: String, type: String) -> RemoteHTTPServer.Response {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext), let data = try? Data(contentsOf: url) else {
            return .text(404, "")
        }
        return .data(status: 200, contentType: type, body: data)
    }

    private static func icon(size: Int) -> RemoteHTTPServer.Response {
        if let cached = iconCache[size] { return .data(status: 200, contentType: "image/png", body: cached) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return .text(500, "")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
        rect.fill()
        // macOS-Symbole haben ≈ 10 % Rand; leicht vergrößert füllt das Motiv die Kachel.
        NSApp.applicationIconImage.draw(in: rect.insetBy(dx: -CGFloat(size) * 0.06, dy: -CGFloat(size) * 0.06))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return .text(500, "") }
        iconCache[size] = png
        return .data(status: 200, contentType: "image/png", body: png)
    }

    // MARK: - Zustand als JSON

    struct Snapshot: Encodable {
        var mode: String?
        var hackrf: Bool
        var switching: Bool
        var home: [Double]?
        var adsb: ADSB
        var ais: AIS
        var dab: DAB
        /// Pegel am Wandler, solange der HackRF empfängt.
        var level: Level?
        /// Laufender Termin des Empfangsplans („Läuft: METEOR-M2-4 … bis 15:20“).
        var plan: String?
        /// „Signal optimieren“ und Verstärkungsautomatik.
        var gain: Gain

        struct Gain: Encodable {
            /// Der laufende Empfänger lässt sich optimieren.
            var tunable: Bool
            var active: Bool
            var status: String?
            /// Ergebnis der letzten Optimierung – nur, wenn sie dem laufenden Empfänger galt.
            var result: String?
            var autoGain: Bool
            /// Letzter Eingriff der Automatik am laufenden Empfänger.
            var autoNote: String?
        }
        struct Level: Encodable { var rms: Double; var peak: Double; var clipped: Double }
        struct Photo: Encodable { var url: String; var page: String; var credit: String }
        struct ADSB: Encodable {
            var running: Bool
            var messagesPerSecond: Double
            var aircraft: [Plane]
        }
        struct Plane: Encodable {
            var id: String
            var callsign: String?
            var lat: Double?
            var lon: Double?
            var altitudeM: Int?
            var speedKmh: Int?
            var track: Double?
            var climbMs: Double?
            var age: Int
            var messages: Int
            var registration: String?
            var type: String?
            var operatorName: String?
            var from: String?
            var to: String?
            var airline: String?
            var photo: Photo?
            var trail: [[Double]]?
        }
        struct AIS: Encodable {
            var running: Bool
            var messages: Int
            var vessels: [Vessel]
        }
        struct Vessel: Encodable {
            var id: Int
            var name: String?
            var callsign: String?
            var type: String?
            var status: String?
            var lat: Double?
            var lon: Double?
            var speedKn: Double?
            var course: Double?
            var heading: Double?
            /// Feste Station: "base" (Basisstation) oder "aton" (Seezeichen) – Kartensymbol wie am Mac.
            var fixed: String?
            var destination: String?
            var eta: String?
            var length: Int?
            var beam: Int?
            var draught: Double?
            var imo: Int?
            var age: Int
            var photo: Photo?
            var trail: [[Double]]?
        }
        struct DAB: Encodable {
            var running: Bool
            var channel: String
            var synchronized: Bool
            var snr: Double
            var playingID: UInt32?
            var playing: String?
            var dynamicLabel: String
            var scanning: Bool
            var scanProgress: Double
            var listeners: Int
            var ensembles: [Ensemble]
        }
        struct Ensemble: Encodable {
            var channel: String
            var label: String
            var services: [Service]
        }
        struct Service: Encodable {
            var id: UInt32
            var label: String
            var bitrate: Int
        }
    }

    private func snapshotJSON(selected: String?) -> Data {
        let encoder = JSONEncoder()
        return (try? encoder.encode(snapshot(selected: selected))) ?? Data("{}".utf8)
    }

    /// `selected` = „adsb:3C6444“ bzw. „ais:211234560“: dafür werden Foto
    /// (und Spur) mitgeliefert, die Fotosuche startet beim ersten Abruf.
    func snapshot(selected: String?) -> Snapshot {
        let now = Date()
        let parts = selected?.split(separator: ":").map(String.init) ?? []
        let selectedPlane = parts.count == 2 && parts[0] == "adsb" ? UInt32(parts[1], radix: 16) : nil
        let selectedVessel = parts.count == 2 && parts[0] == "ais" ? Int(parts[1]) : nil
        let homeLat = UserDefaults.standard.double(forKey: "homeLat")
        let homeLon = UserDefaults.standard.double(forKey: "homeLon")

        let planes = adsb.aircraft.filter { now.timeIntervalSince($0.lastSeen) < MapAircraft.holdSeconds }.map { plane in
            let info = AircraftDatabase.shared.info(for: plane.icao)
            let route = FlightRouteLookup.shared.route(for: plane.callsign)
            let isSelected = plane.icao == selectedPlane
            let photo = isSelected ? AircraftPhotoLookup.shared.photo(for: plane.icao) : nil
            return Snapshot.Plane(
                id: plane.icaoHex, callsign: plane.callsign, lat: plane.latitude, lon: plane.longitude,
                altitudeM: plane.altitude.map { Int((Double($0) * 0.3048).rounded()) },
                speedKmh: plane.groundSpeed.map { Int(($0 * 1.852).rounded()) },
                track: plane.track, climbMs: plane.verticalRate.map { Double($0) * 0.00508 },
                age: Int(now.timeIntervalSince(plane.lastSeen)), messages: plane.messages,
                registration: info?.registration.nilIfEmpty, type: info?.typeText.nilIfEmpty,
                operatorName: info?.operatorText.nilIfEmpty,
                from: route?.origin.shortText, to: route?.destination.shortText, airline: route?.airline.nilIfEmpty,
                photo: photo.map { .init(url: $0.imageURL.absoluteString, page: $0.pageURL.absoluteString,
                                         credit: String(localized: "Foto: \($0.photographer) · planespotters.net")) },
                trail: isSelected ? plane.trail.map { [$0.lat, $0.lon] } : nil)
        }

        let vessels = ais.vessels.map { vessel in
            let isSelected = vessel.mmsi == selectedVessel
            let photo = isSelected && UserDefaults.standard.object(forKey: ShipPhotoLookup.enabledKey) as? Bool ?? true
                ? ShipPhotoLookup.shared.photo(imo: vessel.imo) : nil
            let kind = vessel.isBaseStation ? String(localized: "Basisstation") : vessel.isAidToNavigation ? String(localized: "Seezeichen")
                : AISMessage.shipTypeText(vessel.shipType)
            return Snapshot.Vessel(
                id: vessel.mmsi, name: vessel.name, callsign: vessel.callsign, type: kind,
                status: AISMessage.statusText(vessel.status), lat: vessel.latitude, lon: vessel.longitude,
                speedKn: vessel.speedKnots, course: vessel.courseDegrees, heading: vessel.displayHeading,
                fixed: vessel.isBaseStation ? "base" : vessel.isAidToNavigation ? "aton" : nil,
                destination: vessel.destination?.nilIfEmpty, eta: vessel.eta?.text,
                length: vessel.lengthMeters, beam: vessel.beamMeters, draught: vessel.draughtMeters, imo: vessel.imo,
                age: Int(now.timeIntervalSince(vessel.lastSeen)),
                photo: photo.map { .init(url: $0.imageURL.absoluteString, page: $0.pageURL.absoluteString, credit: $0.credit) },
                trail: isSelected ? vessel.trail.map { [$0.lat, $0.lon] } : nil)
        }

        let ensembles = dab.stationList.map { entry in
            Snapshot.Ensemble(channel: entry.ensemble.channel, label: entry.ensemble.label,
                              services: entry.services.map { .init(id: $0.id, label: $0.label, bitrate: $0.bitrate) })
        }

        return Snapshot(
            mode: activeMode?.rawValue, hackrf: session?.hackRF != nil, switching: switching,
            home: homeLat == 0 && homeLon == 0 ? nil : [homeLat, homeLon],
            adsb: .init(running: adsb.running, messagesPerSecond: adsb.messagesPerSecond, aircraft: planes),
            ais: .init(running: ais.running, messages: ais.messageCount, vessels: vessels),
            dab: .init(running: dab.running, channel: dab.channel.name, synchronized: dab.status.synchronized,
                       snr: dab.status.snr, playingID: dab.playingServiceID, playing: dab.playingLabel,
                       dynamicLabel: dab.status.dynamicLabel, scanning: dab.scanning, scanProgress: dab.scanProgress,
                       listeners: listeners, ensembles: ensembles),
            level: session?.hackRF.flatMap { device in
                device.isReceiving ? device.inputLevels.map { .init(rms: $0.rmsDBFS, peak: $0.peakDBFS, clipped: $0.clipped) } : nil
            },
            plan: ReceptionPlanner.shared.status,
            gain: gainSnapshot())
    }

    private func gainSnapshot() -> Snapshot.Gain {
        let mode = activeMode
        let model = mode.flatMap { tunable(for: $0) }
        let optimizer = model.map { GainOptimizer.shared(for: $0) }
        return Snapshot.Gain(
            tunable: model != nil, active: optimizer?.active ?? false,
            status: optimizer?.status.nilIfEmpty,
            result: optimizer?.result,
            autoGain: AutoGain.shared.enabled,
            autoNote: model.flatMap { AutoGain.shared.note(for: $0) })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
