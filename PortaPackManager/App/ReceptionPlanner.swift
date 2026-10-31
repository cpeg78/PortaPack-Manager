import Foundation
import Observation
import os

/// Empfangsplan: nimmt Wettersatelliten-Überflüge und Radiosonden-Aufstiege
/// selbsttätig auf. Besitzt die Modelle der METEOR- und der Sondenseite, damit
/// ein geplanter Empfang unabhängig von der offenen Seite läuft.
///
/// Ein Takt alle 10 s entscheidet, was gerade dran ist (Überflug vor
/// Sondenfenster), startet bzw. beendet es. Vor dem Start wechselt das Gerät
/// bei Bedarf in den HackRF-Modus, der laufende Empfänger (Fernzugriff, App-Seite)
/// wird beendet und danach wieder eingeschaltet. Nimmt jemand dem Plan das Gerät
/// ab (andere Seite, Fernzugriff), gilt der Termin als unterbrochen und wird
/// nicht erneut gestartet.
@MainActor
@Observable
final class ReceptionPlanner {
    static let shared = ReceptionPlanner()
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Empfangsplan")

    let meteor = MeteorModel()
    let sonde = SondeModel()
    let amateur = AmateurSatModel()

    struct SondeWindow: Identifiable, Hashable, Sendable {
        let start: Date
        let end: Date
        var id: Date { start }
    }

    enum Kind: Hashable, Sendable {
        case pass(SatellitePass)
        case sonde(SondeWindow)
        /// Überflug eines Amateurfunksatelliten (ISS u. a.).
        case amateur(SatellitePass)
    }

    struct Job: Identifiable, Hashable, Sendable {
        let kind: Kind
        /// Läuft eine Minute vor dem Aufgang bis 30 s nach dem Untergang.
        var start: Date {
            switch kind {
            case .pass(let p), .amateur(let p): p.start.addingTimeInterval(-60)
            case .sonde(let w): w.start
            }
        }
        var end: Date {
            switch kind {
            case .pass(let p), .amateur(let p): p.end.addingTimeInterval(30)
            case .sonde(let w): w.end
            }
        }
        var id: String {
            switch kind {
            case .pass(let p): "pass-" + p.id
            case .amateur(let p): "amsat-" + p.id
            case .sonde(let w): "sonde-\(Int(w.start.timeIntervalSince1970))"
            }
        }
        var title: String {
            switch kind {
            case .pass(let p), .amateur(let p): String(format: "%@ (%.0f°)", p.satellite.name, p.maxElevation)
            case .sonde: String(localized: "Radiosonden")
            }
        }
        /// Überflug eines Wettersatelliten (METEOR).
        var isPass: Bool { if case .pass = kind { true } else { false } }
        var isAmateur: Bool { if case .amateur = kind { true } else { false } }
        var isSonde: Bool { if case .sonde = kind { true } else { false } }
        /// Vorrang bei Überschneidung: METEOR vor Amateurfunksatelliten vor
        /// Sondenfenstern (kleiner = wichtiger).
        var priority: Int {
            switch kind {
            case .pass: 0
            case .amateur: 1
            case .sonde: 2
            }
        }

        /// Derselbe Termin, auch wenn die Vorhersage neu gerechnet wurde
        /// (Fund 26.10.2026: alle 30 min neue Vorhersage → Aufnahme wurde
        /// mitten im Überflug beendet und neu gestartet, das Bild geleert).
        func same(as other: Job?) -> Bool {
            guard let other else { return false }
            switch (kind, other.kind) {
            case let (.pass(a), .pass(b)):
                return a.satellite == b.satellite && abs(a.culmination.timeIntervalSince(b.culmination)) < 120
            case let (.amateur(a), .amateur(b)):
                return a.satellite.id == b.satellite.id && abs(a.culmination.timeIntervalSince(b.culmination)) < 120
            case let (.sonde(a), .sonde(b)):
                return a.start == b.start
            default:
                return false
            }
        }
    }

    struct LogEntry: Identifiable, Codable, Hashable {
        var id = UUID()
        let date: Date
        let title: String
        let result: String
    }

    // MARK: Einstellungen

    var autoMeteor = UserDefaults.standard.bool(forKey: "plannerAutoMeteor") {
        didSet { UserDefaults.standard.set(autoMeteor, forKey: "plannerAutoMeteor"); settingsChanged() }
    }
    /// Nur Überflüge mit mindestens dieser Gipfelhöhe aufnehmen (Grad).
    // Nur endliche Werte übernehmen – ein gespeichertes NaN stürzte sonst bei jedem Öffnen ab.
    var minElevation = (UserDefaults.standard.object(forKey: "plannerMinElevation") as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 25 {
        didSet { UserDefaults.standard.set(minElevation, forKey: "plannerMinElevation") }
    }
    var autoSonde = UserDefaults.standard.bool(forKey: "plannerAutoSonde") {
        didSet { UserDefaults.standard.set(autoSonde, forKey: "plannerAutoSonde"); settingsChanged() }
    }
    /// Startzeiten der Sondenfenster in Minuten nach Mitternacht UTC. Der DWD
    /// lässt rund 45 min vor den Hauptterminen 00 und 12 UTC aufsteigen
    /// (manche Stationen auch vor 06 und 18 UTC); ein Flug dauert ≈ 2 h.
    var sondeSlots: Set<Int> = Set(UserDefaults.standard.array(forKey: "plannerSondeSlots") as? [Int] ?? [645, 1365]) {
        didSet { UserDefaults.standard.set(Array(sondeSlots).sorted(), forKey: "plannerSondeSlots"); recomputeSondeWindows() }
    }
    static let sondeSlotChoices = [285, 645, 1005, 1365]   // 04:45, 10:45, 16:45, 22:45 UTC
    /// Rohdaten (IQ) des nächsten Überflugs mitschneiden – zur Fehlersuche,
    /// ≈ 5 GB; schaltet sich nach dem Überflug wieder ab (Plattenplatz).
    var recordMeteorIQ = UserDefaults.standard.bool(forKey: "plannerRecordIQ") {
        didSet { UserDefaults.standard.set(recordMeteorIQ, forKey: "plannerRecordIQ") }
    }
    /// Überflüge der gewählten Amateurfunksatelliten aufnehmen.
    var autoAmateur = UserDefaults.standard.bool(forKey: "plannerAutoAmateur") {
        didSet { UserDefaults.standard.set(autoAmateur, forKey: "plannerAutoAmateur"); settingsChanged() }
    }
    /// Katalognummern der Amateurfunksatelliten im Plan (Vorgabe: ISS).
    var amateurSelection: Set<Int> = Set(UserDefaults.standard.array(forKey: "plannerAmateurSatellites") as? [Int] ?? [AmateurSatellite.issID]) {
        didSet { UserDefaults.standard.set(Array(amateurSelection).sorted(), forKey: "plannerAmateurSatellites"); predict() }
    }
    var amateurMinElevation = UserDefaults.standard.object(forKey: "plannerAmateurMinElevation") as? Double ?? 20 {
        didSet { UserDefaults.standard.set(amateurMinElevation, forKey: "plannerAmateurMinElevation") }
    }
    var sondeMinutes = UserDefaults.standard.object(forKey: "plannerSondeMinutes") as? Double ?? 120 {
        didSet { UserDefaults.standard.set(sondeMinutes, forKey: "plannerSondeMinutes"); recomputeSondeWindows() }
    }
    /// Sondenfenster nur belegen, solange SondeHub eine Sonde in Reichweite
    /// meldet – sonst bleibt ADS-B/AIS an (Fund 26.10.2026: das Fenster
    /// 16:45 UTC lief zwei Stunden, die einzige Sonde flog 370 km entfernt).
    var sondeOnlyInRange = UserDefaults.standard.object(forKey: "plannerSondeOnlyInRange") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sondeOnlyInRange, forKey: "plannerSondeOnlyInRange") }
    }
    /// Bis zur ersten Sondenmeldung abwechseln (Nutzerwunsch 30.10.2026): so viele
    /// Minuten zurück zum vorherigen Empfänger (ADS-B, AIS …), dann
    /// `sondeProbeListen` lang nach Sonden horchen. 0 = durchgehend auf der Sonde.
    var sondeProbeMinutes = UserDefaults.standard.object(forKey: "plannerSondeProbeMinutes") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(sondeProbeMinutes, forKey: "plannerSondeProbeMinutes") }
    }
    /// So lange horcht jeder Versuch – eine RS41 sendet jede Sekunde, die Kanäle
    /// brauchen nach dem Start einige Sekunden zum Einrasten.
    nonisolated static let sondeProbeListen: TimeInterval = 90

    /// Vorgabe 110 km: live 26./27.10.2026 dekodierte die Skyscan RS41 bis
    /// ≈ 100 km gut, bis 115 km vereinzelt, ab 140 km gar nicht.
    var sondeRangeKm = ReceptionPlanner.storedRange {
        didSet { UserDefaults.standard.set(sondeRangeKm, forKey: "plannerSondeRangeKm") }
    }

    private static var storedRange: Double {
        let defaults = UserDefaults.standard
        // Einmalig: die alte Vorgabe 250 km auf 110 km umstellen.
        if !defaults.bool(forKey: "plannerSondeRange110"), defaults.double(forKey: "plannerSondeRangeKm") == 250 {
            defaults.set(110.0, forKey: "plannerSondeRangeKm")
        }
        defaults.set(true, forKey: "plannerSondeRange110")
        return defaults.object(forKey: "plannerSondeRangeKm") as? Double ?? 110
    }

    // MARK: Zustand

    private(set) var passes: [SatellitePass] = []
    /// Überflüge der gewählten Amateurfunksatelliten (nächste 48 h).
    private(set) var amateurPasses: [SatellitePass] = []
    private(set) var amateurTLEDate: Date?
    /// Fehler beim Laden der Amateurfunk-Bahndaten (ohne Internet) – vorher stand
    /// dann ewig „Bahndaten werden geladen …“ (Bedienungs-Review 29.10.2026).
    private(set) var amateurTLEError: String?
    private(set) var sondeWindows: [SondeWindow] = []
    private(set) var tleDate: Date?
    private(set) var tleError: String?
    private(set) var active: Job?
    /// Gesetzt, solange `DeviceArbiter.borrow` das Gerät kurz ausleiht
    /// (Quarzabgleich, Antennen-Check): keine neuen Termine, kein Fortsetzen.
    var paused = false
    /// Vom Nutzer pausiert (Menüleiste „Empfangsplan pausieren“): keine neuen
    /// Termine, bis er fortsetzt. Nur für diesen Programmlauf – nach einem
    /// Neustart plant die App wieder. Getrennt von `paused`, das `DeviceArbiter.borrow`
    /// nach der Ausleihe selbst zurücksetzt.
    private(set) var userPaused = false
    private(set) var status: String?
    /// Sondenfenster offen, aber keine Sonde in Reichweite (nur Hinweis, kein Termin).
    private(set) var waitingNote: String?
    private(set) var history: [LogEntry] = []
    /// Sonden in Reichweite laut SondeHub (nur während eines Sondenfensters abgefragt).
    private(set) var sondesInRange: [SondeHubTraffic.Sighting] = []
    /// Letzte gemeldete Frequenz je Seriennummer – SondeHub liefert sie nicht in
    /// jeder Meldung (27.10.2026: Bergen-Hohne ab 20 km Höhe ohne `frequency`,
    /// der feste Kanal fiel weg).
    private var knownFrequencies: [String: Double] = [:]
    private(set) var sondeHubChecked: Date?
    /// Bahnvorhersage der Aufstiege des nächsten (oder laufenden) Fensters.
    private(set) var sondeForecast: [SondeForecast.Flight] = []
    private(set) var sondeForecastWindow: Date?
    private(set) var sondeForecastError: String?
    private var sondeForecastDate = Date.distantPast
    private var forecastRunning = false
    private var sondeSites: (sites: [SondeForecast.Site], fetched: Date)?

    private weak var session: DeviceSession?
    private var loop: Task<Void, Never>?
    private var tles: [Int: TLE] = [:]
    private var amateurTLEs: [Int: TLE] = [:]
    private var lastAmateurTLEAttempt = Date.distantPast
    private var station: GroundStation?
    private var lastPrediction = Date.distantPast
    private var lastTLEAttempt = Date.distantPast
    /// Termine, die unterbrochen, übersprungen oder gescheitert sind – nicht
    /// erneut starten. Gespeichert (2 Tage): Nach einem Neustart der App lief ein
    /// schon beendetes Sondenfenster sonst wieder an (Fund 28.10.2026).
    /// Mit dem Zeitpunkt des Überspringens auch im Speicher: vorher verfielen
    /// die Kennungen in einer langen Sitzung nie, weil jedes Speichern den
    /// Zeitstempel erneuerte (Review 28.10.2026).
    private var skipped: [String: Date] = ReceptionPlanner.loadSkipped() {
        didSet { if skipped != oldValue { Self.storeSkipped(skipped) } }
    }
    private static let skippedKey = "plannerSkipped"
    nonisolated static let skippedLifetime: TimeInterval = 2 * 86_400

    private static func loadSkipped() -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: skippedKey) as? [String: Double] ?? [:]
        return pruneSkipped(stored.mapValues { Date(timeIntervalSince1970: $0) }, now: Date())
    }

    private static func storeSkipped(_ ids: [String: Date]) {
        UserDefaults.standard.set(ids.mapValues(\.timeIntervalSince1970), forKey: skippedKey)
    }

    /// Übersprungene Termine, die jünger als `skippedLifetime` sind.
    nonisolated static func pruneSkipped(_ ids: [String: Date], now: Date) -> [String: Date] {
        ids.filter { now.timeIntervalSince($0.value) < skippedLifetime }
    }

    /// Termin überspringen; ein schon übersprungener behält seinen Zeitpunkt.
    private func skip(_ id: String) {
        if skipped[id] == nil { skipped[id] = Date() }
    }

    /// Kennungen der Termine – dieselben wie `Job.id`.
    nonisolated static func jobID(pass: SatellitePass) -> String { Job(kind: .pass(pass)).id }
    nonisolated static func jobID(amateur: SatellitePass) -> String { Job(kind: .amateur(amateur)).id }
    nonisolated static func jobID(window: SondeWindow) -> String { Job(kind: .sonde(window)).id }

    func isSkipped(_ id: String) -> Bool { skipped[id] != nil }
    func isActive(_ id: String) -> Bool { active?.id == id }

    /// Einzelnen Termin aus- bzw. wieder einschalten (Schalter rechts in der
    /// Planliste). Läuft er gerade, beendet Ausschalten ihn wie „Überspringen“.
    /// Gemerkt wird das Ende des Termins, damit die Marke bis dahin hält
    /// (`pruneSkipped` rechnet ab diesem Zeitpunkt).
    func setSkipped(_ id: String, end: Date, _ on: Bool) {
        if on {
            if active?.id == id { Task { await skipActive() }; return }
            skipped[id] = max(Date(), end)
        } else {
            skipped[id] = nil
        }
    }

    /// Laufenden Termin von Hand beenden und nicht wieder aufnehmen. Was vorher
    /// lief (ADS-B, AIS, DAB+, TV …), kommt im nächsten Takt zurück – außer mit
    /// `resumePrevious: false`: Die Umschalt-Rückfrage startet gleich danach einen
    /// anderen Empfänger, den der Plan sonst ≤ 10 s später wieder hinauswarf
    /// (Review 29.10.2026).
    func skipActive(resumePrevious: Bool = true) async {
        guard let job = active else { return }
        if !resumePrevious { resume = nil }
        skip(job.id)
        await finish(job, note: String(localized: "übersprungen"))
        status = nil
    }
    private var lostTicks = 0
    /// Was vor dem ersten Termin lief und wie – danach wieder an: Empfänger von
    /// `RemoteHub` (ADS-B, AIS, DAB+ …) und seit 29.10.2026 auch reine
    /// Mac-Empfänger (TV, BLE, GPS, Wasserstofflinie …).
    private var resume: PlanResume?

    /// Empfangsplan pausieren bzw. fortsetzen (Menüleiste, Planseite). Pausieren
    /// beendet einen laufenden Termin wie „Überspringen“ – was vorher lief, kommt zurück.
    func setUserPaused(_ on: Bool) async {
        guard on != userPaused else { return }
        userPaused = on
        Self.log.notice("Empfangsplan \(on ? "pausiert" : "fortgesetzt", privacy: .public)")
        if on, active != nil { await skipActive() }
    }

    /// Beim automatischen Start nach der Anmeldung: Ein Termin läuft schon –
    /// den gewünschten Empfänger danach starten wie einen, den der Termin
    /// verdrängt hat. Eine schon gemerkte Rückkehr bleibt unangetastet.
    func resumeLater(_ target: PlanResume) {
        guard active != nil, resume == nil else { return }
        resume = target
    }

    /// Die gemerkte Rückkehr verwerfen: Der Nutzer hat selbst etwas gestartet
    /// (am Mac oder vom Handy, auch „Stopp“) – das gilt.
    func dropResume() {
        guard resume != nil else { return }
        resume = nil
        Self.log.notice("Rückkehr nach dem Termin verworfen – Nutzer hat umgeschaltet")
    }
    private var activity: NSObjectProtocol?
    private var lastSondeHubAttempt = Date.distantPast
    /// Zuletzt eine Sonde in Reichweite gesehen (online oder selbst empfangen).
    private var lastSondeNearby = Date.distantPast
    /// Letzte Sondenmeldung im laufenden Sondenfenster (für Verlängern und
    /// vorzeitiges Ende, Nutzer 29.10.2026).
    private var sondeHeard: Date?
    /// Beginn der laufenden Sondenaufnahme. Die Frist „30 min ohne Sonde“ zählt
    /// ab hier, nicht ab dem geplanten Fensterbeginn – sonst endete ein Fenster,
    /// das spät begann (erst bei Sonde in Reichweite, nach einem Neustart der App
    /// oder nach einer Trennung), schon im ersten Takt (Review 29.10.2026).
    private var sondeBegan: Date?
    /// Beginn des laufenden Horch-Versuchs (bei jedem Start neu, anders als `sondeBegan`).
    private var sondeListenStart: Date?
    /// Pause zwischen zwei Horch-Versuchen: Fenster und Ende der Pause. Solange
    /// beginnt das Fenster nicht neu, der vorherige Empfänger läuft.
    private(set) var sondeProbePause: (id: String, until: Date)?
    /// Fenster, dessen Warten auf eine Sonde im Umkreis schon im Protokoll steht –
    /// eine Zeile je Fenster statt einer je Takt.
    private var sondeWaitLogged: String?
    /// Empfangsfenster, in das zuletzt Sondenmeldungen gingen.
    private var lastSondeWindow: String?
    /// Nach Fensterende weiter, solange eine Sonde zu hören ist – Ende erst nach
    /// so langer Stille.
    nonisolated static let sondeTailSilence: TimeInterval = 5 * 60
    /// Vor dem Fensterende: war eine Sonde zu hören und ist so lange still, endet
    /// das Fenster vorzeitig (gelandet oder außer Reichweite) – ADS-B/AIS kommt zurück.
    nonisolated static let sondeEarlySilence: TimeInterval = 10 * 60
    /// Kommt nach Fensterbeginn so lange gar keine Sonde, endet das Fenster ebenfalls
    /// (eine Sonde braucht nach dem Start etwas, bis sie über den Horizont steigt).
    nonisolated static let sondeNoShow: TimeInterval = 30 * 60
    private var lastChannelLog = Date.distantPast
    private var amateurStartCounters = (images: 0, frames: 0)

    private init() {
        if let data = UserDefaults.standard.data(forKey: "plannerHistory"),
           let entries = try? JSONDecoder().decode([LogEntry].self, from: data) {
            history = entries
        }
        let stored = TLEStore.load()
        tles = stored.tles
        tleDate = stored.fetched
        let amateurStored = TLEStore.loadAmateur()
        amateurTLEs = amateurStored.tles
        amateurTLEDate = amateurStored.fetched
    }

    /// Bahndaten eines Amateurfunksatelliten (CelesTrak-Gruppe „amateur“).
    func amateurTLE(for id: Int) -> TLE? { amateurTLEs[id] }

    func bootstrap(session: DeviceSession) {
        self.session = session
        settingsChanged()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Geplante Termine der nächsten Zeit (nach Start sortiert).
    var upcoming: [Job] {
        Self.schedule(meteor: autoMeteor ? passes : [], minElevation: minElevation,
                      amateur: autoAmateur ? amateurPasses.filter { amateurSelection.contains($0.satellite.id) } : [],
                      amateurMinElevation: amateurMinElevation,
                      sonde: autoSonde ? sondeWindows : [], now: Date())
    }

    /// Termine aus Überflügen und Sondenfenstern, nach Beginn sortiert (testbar).
    nonisolated static func schedule(meteor: [SatellitePass], minElevation: Double, amateur: [SatellitePass],
                         amateurMinElevation: Double, sonde: [SondeWindow], now: Date) -> [Job] {
        var jobs = meteor.filter { $0.maxElevation >= minElevation }.map { Job(kind: .pass($0)) }
        jobs += amateur.filter { $0.maxElevation >= amateurMinElevation }.map { Job(kind: .amateur($0)) }
        jobs += sonde.map { Job(kind: .sonde($0)) }
        return jobs.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    /// Welcher der jetzt laufenden Termine dran ist: der mit dem höchsten
    /// Vorrang (METEOR, dann Amateurfunk, dann Sonden), bei Gleichstand der
    /// früher begonnene.
    nonisolated static func due(_ jobs: [Job], now: Date, skipped: Set<String>) -> Job? {
        jobs.filter { $0.start <= now && now < $0.end && !skipped.contains($0.id) }
            .min { ($0.priority, $0.start) < ($1.priority, $1.start) }
    }

    func isPlanned(_ pass: SatellitePass) -> Bool { autoMeteor && pass.maxElevation >= minElevation }
    func isPlannedAmateur(_ pass: SatellitePass) -> Bool {
        autoAmateur && amateurSelection.contains(pass.satellite.id) && pass.maxElevation >= amateurMinElevation
    }

    /// Ob die Seite ihr Modell beim Verlassen stoppen darf.
    var meteorBusy: Bool { active?.isPass == true }
    var sondeBusy: Bool { active?.isSonde == true }
    var amateurBusy: Bool { active?.isAmateur == true }

    private func owner(of job: Job) -> AnyObject {
        switch job.kind {
        case .pass: meteor
        case .amateur: amateur
        case .sonde: sonde
        }
    }

    func refreshOrbits() {
        lastTLEAttempt = .distantPast
        lastAmateurTLEAttempt = .distantPast
        Task { await updateTLEsIfNeeded(force: true); predict() }
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: Takt

    private func tick() async {
        await updateTLEsIfNeeded(force: false)
        let home = Self.home
        if home != station || Date().timeIntervalSince(lastPrediction) > 1800 || passes.isEmpty {
            station = home
            predict()
        }
        recomputeSondeWindows()
        // Nebenher: 10–15 Tawhiri-Abfragen nacheinander (je bis 30 s) hielten
        // sonst den Takt an – fällige Überflüge begannen verspätet, Abrisse
        // blieben unbemerkt (Review 27.10.2026). Das Ergebnis rechnet die
        // Fenster am Ende selbst neu (`recomputeSondeWindows`).
        if !forecastRunning { Task { await updateSondeForecastIfNeeded() } }

        let now = Date()
        // Läuft der aktive Termin noch für uns?
        if let job = active {
            let jobOwner = owner(of: job)
            if let device = session?.hackRF, device.isReceiving(for: jobOwner) {
                lostTicks = 0
            } else {
                lostTicks += 1
            }
            if let device = session?.hackRF, device.isStalled(for: jobOwner, seconds: 5) {
                // USB-Strom liefert nichts mehr: neu beginnen (nächster Takt).
                lostTicks = 0
                await finish(job, note: String(localized: "Empfang abgerissen, wird neu gestartet"))
            } else if lostTicks >= 3, session?.hackRF == nil {
                // Gerät abgezogen oder neu gestartet: kein bewusstes Umschalten.
                // Termin beenden, aber nicht überspringen – nach dem Wiederverbinden
                // beginnt er neu, und danach kommt ADS-B/AIS wie geplant zurück.
                await finish(job, note: String(localized: "Gerät getrennt"))
            } else if lostTicks >= 3 {
                // Jemand hat bewusst umgeschaltet – das gilt, nichts zurückholen.
                resume = nil
                skip(job.id)
                await finish(job, note: String(localized: "unterbrochen (ein anderer Empfänger hat den HackRF übernommen)"))
            }
        }
        // Sondenfenster: an der Empfangslage ausrichten.
        if let job = active, case .sonde(let window) = job.kind {
            let heard = sonde.sondes.map(\.lastSeen).filter { $0 >= window.start }.max()
            if let heard, heard > (sondeHeard ?? .distantPast) {
                sondeHeard = heard
                recomputeSondeWindows()            // ggf. über das Fensterende hinaus
            }
            let counted = Self.noShowStart(window: window.start, began: sondeBegan)
            let onlineNearby = !sondesInRange.isEmpty && sondeHubChecked.map { now.timeIntervalSince($0) < 600 } == true
            if Self.endSondeEarly(heard: sondeHeard, now: now, start: counted, end: job.end, onlineNearby: onlineNearby) {
                skip(job.id)
                await finish(job, note: sondeHeard == nil
                             ? String(localized: "30 Minuten keine Sonde gehört – vorzeitig beendet")
                             : String(localized: "Sonde seit 10 Minuten nicht mehr gehört – vorzeitig beendet"))
            } else if Self.pauseSondeProbe(heard: sondeHeard, listenStart: sondeListenStart, now: now,
                                           probeMinutes: sondeProbeMinutes, canReturn: resume != nil) {
                // Noch keine Sonde gehört: Gerät für ein paar Minuten zurückgeben.
                // Kein Eintrag im Verlauf und keine Mitteilung – das wäre alle paar Minuten einer.
                sondeProbePause = (job.id, now.addingTimeInterval(sondeProbeMinutes * 60))
                sonde.stop(on: session?.hackRF)
                active = nil
                Self.log.notice("Noch keine Sonde – \(Int(self.sondeProbeMinutes)) min zurück zum vorherigen Empfänger")
            }
        }
        // Überflüge haben Vorrang vor einem (früher begonnenen) Sondenfenster,
        // METEOR vor Amateurfunksatelliten.
        let pruned = Self.pruneSkipped(skipped, now: now)
        if pruned.count != skipped.count { skipped = pruned }
        var due = Self.due(upcoming, now: now, skipped: Set(skipped.keys))
        var waiting: String?
        if let job = due, job.isSonde, let pause = sondeProbePause, pause.id == job.id, now < pause.until {
            waiting = String(localized: "Radiosonden: noch keine Sonde gehört – nächster Versuch um \(pause.until.formatted(date: .omitted, time: .shortened))")
            // SondeHub trotzdem weiter abfragen (Kanäle für den nächsten Versuch, „in Reichweite“).
            _ = await sondeNearby(now: now, running: false)
            due = nil
        } else if let job = due, job.isSonde, sondeOnlyInRange, !(await sondeNearby(now: now, running: active?.same(as: job) == true)) {
            waiting = String(localized: "Radiosonden bis \(job.end.formatted(date: .omitted, time: .shortened)): wartet – laut SondeHub keine Sonde im Umkreis von \(Int(sondeRangeKm)) km")
            due = nil
            if sondeWaitLogged != job.id {
                sondeWaitLogged = job.id
                // Sonst steht im Protokoll gar nichts – das Fenster scheint einfach nie zu beginnen.
                let nearest = sondeHubChecked == nil ? "SondeHub noch nicht abgefragt" : "keine Sonde gemeldet"
                Self.log.notice("Radiosonden wartet: \(nearest, privacy: .public) im Umkreis von \(Int(self.sondeRangeKm)) km (bis \(job.end.formatted(date: .omitted, time: .shortened), privacy: .public))")
            }
        }
        if let job = active, let due, job.same(as: due) {
            active = due                       // neu gerechnete Zeiten übernehmen
        } else if let job = active {
            // Der Sondenhinweis gilt nur für ein Sondenfenster; ein Überflug, der
            // gerade endet, während ein Fenster wartet, ist einfach vorbei (Fund
            // 29.10.2026: „ISS … – keine Sonde mehr in Reichweite“).
            let reason: String? = job.isSonde && waiting != nil ? String(localized: "keine Sonde mehr in Reichweite")
                : due.map { String(localized: "vorzeitig beendet für \($0.title)") }
            await finish(job, note: now < job.end ? reason : nil)
        }
        // Nicht während einer Installation oder einer Ausleihe – sonst schaltete der
        // Plan mitten in ein Firmware-Update in den HackRF-Modus (Review 27.10.2026).
        let blocked = paused || session?.busy == true
        // Erneut prüfen: Während `sondeNearby` gewartet wurde, kann der Nutzer
        // genau diesen Termin übersprungen haben (Review 28.10.2026, Y11).
        // Vom Nutzer pausiert: keine neuen Termine – die Rückkehr zum vorherigen
        // Empfänger aber schon (sonst bliebe nach „Pausieren“ alles aus).
        if let due, active == nil, !blocked, !userPaused, skipped[due.id] == nil {
            await begin(due)
        }
        if active == nil, !blocked, let previous = resume,
           // Nur künftige Termine halten die Rückkehr auf. Ein schon laufendes,
           // aber wartendes Sondenfenster (keine Sonde in Reichweite) hielt
           // ADS-B/AIS sonst bis zu seinem Ende – mit Verlängerung bis 5 h.
           !upcoming.contains(where: { $0.start > now && $0.start.timeIntervalSince(now) < 120 && skipped[$0.id] == nil }) {
            resume = nil
            await resumeAfterPlan(previous)
        }
        if let job = active, job.isSonde {
            for received in sonde.sondes { Notifier.shared.sondeReceived(received.id) }
            sonde.follow(mhz: sondesInRange.compactMap { $0.frequencyMHz ?? knownFrequencies[$0.serial] })
            if now.timeIntervalSince(lastChannelLog) >= 60 {
                lastChannelLog = now
                let text = sonde.channels.map { c in
                    let age = c.lastDecoded.map { "\(Int(now.timeIntervalSince($0))) s" } ?? "nie"
                    return String(format: "%.3f", c.frequency / 1e6) + (c.pinned ? "*" : "") + " \(Int(c.levelDB)) dB, dekodiert vor \(age)"
                }.joined(separator: " | ")
                Self.log.notice("Sondenkanäle: \(text, privacy: .public)")
            }
        }
        status = active.map { String(localized: "Läuft: \($0.title) bis \($0.end.formatted(date: .omitted, time: .shortened))") }
        waitingNote = active == nil ? waiting : nil
    }

    /// Ob sich das Sondenfenster lohnt: SondeHub (alle 2 min) meldet eine Sonde
    /// in Reichweite. Läuft der Empfang schon, hält ihn jede eigene Meldung und
    /// jede Sichtung der letzten 10 min offen. Ist SondeHub nicht erreichbar,
    /// wird wie früher einfach empfangen.
    private func sondeNearby(now: Date, running: Bool) async -> Bool {
        guard let home = Self.home else { return true }
        if now.timeIntervalSince(lastSondeHubAttempt) >= 120 {
            lastSondeHubAttempt = now
            do {
                sondesInRange = try await SondeHubTraffic.fetch(home: home, rangeKm: sondeRangeKm)
                Notifier.shared.sondesInRange(sondesInRange)
                for sighting in sondesInRange { if let mhz = sighting.frequencyMHz { knownFrequencies[sighting.serial] = mhz } }
                sondeHubChecked = now
            } catch {
                Self.log.error("SondeHub nicht erreichbar: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let checked = sondeHubChecked, now.timeIntervalSince(checked) < 600 else { return true }
        if !sondesInRange.isEmpty { lastSondeNearby = now }
        if running, let last = sonde.sondes.first?.lastSeen, last > lastSondeNearby { lastSondeNearby = last }
        return now.timeIntervalSince(lastSondeNearby) < (running ? 600 : 1)
    }

    /// Fensterende mit Nachlauf: bis `sondeTailSilence` nach der letzten Meldung.
    nonisolated static func sondeWindowEnd(planned: Date, start: Date, heard: Date?) -> Date {
        guard let heard else { return planned }
        return max(planned, min(heard.addingTimeInterval(sondeTailSilence), start.addingTimeInterval(5 * 3600)))
    }

    /// Horch-Versuch beenden und das Gerät zurückgeben? Nur solange keine Sonde
    /// gehört wurde, der Versuch `sondeProbeListen` lang lief, Abwechseln an ist
    /// und es einen vorherigen Empfänger gibt (sonst bliebe der HackRF einfach frei).
    nonisolated static func pauseSondeProbe(heard: Date?, listenStart: Date?, now: Date,
                                            probeMinutes: Double, canReturn: Bool) -> Bool {
        guard heard == nil, probeMinutes > 0, canReturn, let listenStart else { return false }
        return now.timeIntervalSince(listenStart) >= sondeProbeListen
    }

    /// Ab wann `sondeNoShow` zählt: Beginn der Aufnahme, frühestens der
    /// geplante Fensterbeginn.
    nonisolated static func noShowStart(window: Date, began: Date?) -> Date {
        max(window, began ?? window)
    }

    /// Vorzeitig beenden (geplantes Ende noch nicht erreicht): eine gehörte Sonde
    /// ist seit `sondeEarlySilence` still, oder seit `start` (Beginn der Aufnahme,
    /// siehe `noShowStart`) kam `sondeNoShow` lang gar keine – außer SondeHub meldet
    /// gerade eine im Umkreis (`onlineNearby`): Dann ist sie nur noch zu weit oder zu
    /// niedrig und kommt meist näher (Fund 30.10.2026: Schleswig in 73 km auf 8 km
    /// Höhe, das Fenster wäre nach 30 min abgebrochen und übersprungen worden).
    nonisolated static func endSondeEarly(heard: Date?, now: Date, start: Date, end: Date, onlineNearby: Bool = false) -> Bool {
        guard now < end else { return false }
        guard let heard else { return !onlineNearby && now.timeIntervalSince(start) >= sondeNoShow }
        return now.timeIntervalSince(heard) >= sondeEarlySilence
    }

    /// Was vor dem Termin lief, wieder starten – nur, wenn das Gerät frei ist
    /// (oder schon diesem Empfänger gehört).
    private func resumeAfterPlan(_ previous: PlanResume) async {
        let hub = RemoteHub.shared
        if let device = session?.hackRF {
            let target: AnyObject? = switch previous {
            case .hub(let mode, _): hub.existingOwner(for: mode)
            case .local(let model): model
            }
            let occupant = ReceiverStore.occupant(of: device)
            guard PlanResume.allowed(occupant: occupant, target: target) else {
                Self.log.notice("Nicht zurückgeholt – das Gerät empfängt schon für \(DeviceArbiter.title(of: occupant), privacy: .public)")
                return
            }
        }
        switch previous {
        case .hub(let mode, let remote):
            Self.log.notice("Weiter mit \(mode.rawValue, privacy: .public)")
            await hub.resumeAfterPlan(mode, remote: remote)
        case .local(let model):
            guard let device = session?.hackRF else { return }
            ReceiverStore.shared.resumeLocal(model, on: device)
        }
    }

    private func begin(_ job: Job) async {
        // Weiterer Horch-Versuch im selben Fenster: die Frist „30 min ohne Sonde“
        // zählt weiter ab dem ersten Start, nicht ab jedem Versuch.
        let probing = sondeProbePause?.id == job.id
        if job.isSonde, !probing { sondeHeard = nil; sondeBegan = nil }
        if job.isSonde { sondeProbePause = nil }
        guard let session, !session.busy else { return }
        if session.hackRF == nil {
            guard session.device != nil else {
                status = String(localized: "\(job.title): kein Gerät verbunden")
                return
            }
            await session.enterHackRFMode()
            for _ in 0..<40 where session.hackRF == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Während der Wartezeit kann eine Installation (Rettungsweg über den
        // HackRF-Modus) begonnen oder der Nutzer den Termin übersprungen haben
        // (Review 28.10.2026, Y1/Y11).
        guard !session.busy, skipped[job.id] == nil, !paused, !userPaused else { return }
        guard let device = session.hackRF else {
            skip(job.id)
            record(job, String(localized: "nicht gestartet: HackRF-Modus nicht erreicht"))
            return
        }
        // Was gerade läuft, danach dort weitermachen: Empfänger von `RemoteHub`
        // (Fernzugriff oder App) und – Nutzerwunsch 29.10.2026 – auch reine
        // Mac-Empfänger (TV, BLE, GPS, Wasserstofflinie …). Den Mac-Empfänger
        // zuerst merken und sauber beenden: `suspendForPlan` gibt das Gerät ganz frei.
        // Läuft derselbe Amateurfunksatellit schon von Hand, bleibt alles, wie es
        // ist – `suspendForPlan` gäbe sonst das Gerät frei, und ein angefangenes
        // SSTV-Bild bräche ab.
        let keepsAmateur: Bool = {
            guard case .amateur(let pass) = job.kind else { return false }
            return amateur.running && amateur.receiving?.id == pass.satellite.id && device.isReceiving(for: amateur)
        }()
        if !keepsAmateur {
            let local = ReceiverStore.shared.suspendLocal(on: device)
            let previous = RemoteHub.shared.suspendForPlan()
            if resume == nil { resume = PlanResume.choose(hub: previous, local: local) }
        }
        lostTicks = 0
        switch job.kind {
        case .pass(let pass):
            meteor.stop(on: device)
            meteor.clear()
            meteor.signal = .oqpsk72
            meteor.frequency = pass.satellite.frequency
            meteor.recordIQ = recordMeteorIQ
            meteor.start(on: device)
            if let error = meteor.error {
                skip(job.id)
                record(job, String(localized: "nicht gestartet: \(error)"))
                return
            }
        case .amateur(let pass):
            guard let satellite = AmateurSatellite.lookup(pass.satellite.id) else {
                skip(job.id)
                record(job, String(localized: "nicht gestartet: Satellit nicht mehr in der Liste"))
                return
            }
            amateurStartCounters = amateur.counters
            if !keepsAmateur {
                amateur.stop(on: device)
                amateur.start(on: device, satellite: satellite)
            }
            if !amateur.running {
                skip(job.id)
                record(job, String(localized: "nicht gestartet: \(amateur.error ?? String(localized: "unbekannter Fehler"))"))
                return
            }
        case .sonde(let window):
            sonde.stop(on: device)
            // Neues Fenster: Liste leeren. Dasselbe Fenster nach „Überspringen“/Neustart
            // des Termins setzt fort (früher: Protokolldatei schon vorhanden).
            let stamp = Self.fileStamp(window.start)
            if lastSondeWindow != stamp { sonde.clear() }
            lastSondeWindow = stamp
            sonde.logWindow = stamp
            sonde.start(on: device)
            if let error = sonde.error {
                skip(job.id)
                sonde.logWindow = nil
                record(job, String(localized: "nicht gestartet: \(error)"))
                return
            }
        }
        if job.isSonde {
            if sondeBegan == nil { sondeBegan = Date() }
            sondeListenStart = Date()
        }
        active = job
        Self.log.notice("Start: \(job.title, privacy: .public)")
    }

    private func finish(_ job: Job, note: String?) async {
        let device = session?.hackRF
        var result: String
        switch job.kind {
        case .pass:
            meteor.stop(on: device)    // speichert ab 16 Zeilen die PNGs
            if meteor.recordIQ { recordMeteorIQ = false; meteor.recordIQ = false }
            let s = meteor.snapshot
            result = s.lines >= 16
                ? String(localized: "\(s.lines) Zeilen, \(meteor.savedFiles.count) Bilder gespeichert")
                : String(localized: "kein Bild (\(s.frame.framesOK) gültige Rahmen, Pegel \(Int(s.levelDB)) dBFS)")
        case .amateur:
            amateur.stop(on: device)    // speichert ein angefangenes SSTV-Bild
            let images = amateur.counters.images - amateurStartCounters.images
            let frames = amateur.counters.frames - amateurStartCounters.frames
            result = images == 0 && frames == 0
                ? String(localized: "nichts empfangen")
                : String(localized: "\(images) SSTV-Bilder, \(frames) Pakete")
        case .sonde:
            sonde.stop(on: device)
            sonde.follow(mhz: [])
            knownFrequencies = [:]
            sonde.logWindow = nil
            result = sonde.reportCount > 0
                ? String(localized: "\(sonde.sondes.count) Sonden, \(sonde.reportCount) Meldungen")
                : String(localized: "keine Sonde empfangen")
        }
        if let note { result += " – " + note }
        record(job, result)
        active = nil
        Self.log.notice("Ende: \(job.title, privacy: .public): \(result, privacy: .public)")
    }

    private func record(_ job: Job, _ result: String) {
        Notifier.shared.planFinished(job.title, result: result)
        history.insert(LogEntry(date: job.start, title: job.title, result: result), at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "plannerHistory") }
    }

    // MARK: Vorhersage

    static var home: GroundStation? {
        let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
        return lat == 0 && lon == 0 ? nil : GroundStation(latitude: lat, longitude: lon)
    }

    private func updateTLEsIfNeeded(force: Bool) async {
        await updateAmateurTLEsIfNeeded(force: force)
        let stale = tleDate.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        guard force || stale, Date().timeIntervalSince(lastTLEAttempt) > 3600 else { return }
        lastTLEAttempt = Date()
        do {
            tles = try await TLEStore.fetch(WeatherSatellite.all)
            tleDate = Date()
            tleError = nil
            predict()
        } catch {
            tleError = String(localized: "Bahndaten nicht geladen: \(error.localizedDescription)")
        }
    }

    /// Gruppe „amateur“ einmal täglich (auch ohne Plan – die Seite braucht
    /// die Bahndaten für die Doppler-Korrektur).
    private func updateAmateurTLEsIfNeeded(force: Bool) async {
        let stale = amateurTLEDate.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        guard force || stale, Date().timeIntervalSince(lastAmateurTLEAttempt) > 3600 else { return }
        lastAmateurTLEAttempt = Date()
        do {
            amateurTLEs = try await TLEStore.fetchAmateur()
            amateurTLEDate = Date()
            amateurTLEError = nil
            predict()
        } catch {
            amateurTLEError = String(localized: "Bahndaten nicht geladen: \(error.localizedDescription) Ohne Internet geht es nicht; die App versucht es stündlich neu.")
            Self.log.error("Bahndaten Amateurfunk: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func predict() {
        lastPrediction = Date()
        guard let station = Self.home else { passes = []; amateurPasses = []; return }
        let from = Date().addingTimeInterval(-1800)
        passes = WeatherSatellite.all.flatMap { satellite in
            tles[satellite.id].map { PassPredictor.passes(satellite, tle: $0, station: station, from: from, hours: 48.5, minElevation: 10) } ?? []
        }
        .filter { $0.end > Date() }
        .sorted { $0.start < $1.start }
        amateurPasses = amateurSelection.compactMap(AmateurSatellite.lookup).flatMap { satellite in
            amateurTLEs[satellite.id].map {
                PassPredictor.passes(satellite.passTarget, tle: $0, station: station, from: from, hours: 48.5, minElevation: 10)
            } ?? []
        }
        .filter { $0.end > Date() }
        .sorted { $0.start < $1.start }
    }

    /// Rechnet die Flugbahnen für das nächste Sondenfenster, sobald es in
    /// weniger als 3 h beginnt (oder läuft); danach stündlich neu.
    private func updateSondeForecastIfNeeded() async {
        guard autoSonde, !forecastRunning, let home = Self.home else { return }
        let now = Date()
        guard let window = sondeWindows.first(where: { $0.end > now && $0.start.timeIntervalSince(now) < 3 * 3600 }) else { return }
        guard window.start != sondeForecastWindow || now.timeIntervalSince(sondeForecastDate) > 3600 else { return }
        forecastRunning = true
        defer { forecastRunning = false }
        do {
            if sondeSites == nil || now.timeIntervalSince(sondeSites!.fetched) > 86_400 {
                sondeSites = (try await SondeForecast.fetchSites(), now)
            }
            // Sonden treiben bis ≈ 200 km weit – Plätze bis Reichweite + 250 km.
            let sites = sondeSites!.sites.filter {
                SondeHubTraffic.haversineKm(home.latitude, home.longitude, $0.latitude, $0.longitude) <= sondeRangeKm + 250
            }
            let baseEnd = window.start.addingTimeInterval(sondeMinutes * 60)
            var flights: [SondeForecast.Flight] = []
            for site in sites {
                for launch in SondeForecast.launches(of: site, from: window.start, to: baseEnd) {
                    if let flight = try? await SondeForecast.predict(site: site, launch: launch, home: home, rangeKm: sondeRangeKm) {
                        flights.append(flight)
                    }
                }
            }
            sondeForecast = flights.sorted { $0.closestKm < $1.closestKm }
            sondeForecastWindow = window.start
            sondeForecastDate = now
            sondeForecastError = nil
            let text = sondeForecast.map { f in
                f.site + " " + (f.inRange.map { "\($0.lowerBound.formatted(date: .omitted, time: .shortened))–\($0.upperBound.formatted(date: .omitted, time: .shortened))" } ?? "nie")
                    + " (min. \(Int(f.closestKm)) km)"
            }.joined(separator: " | ")
            Self.log.notice("Sondenvorhersage: \(text, privacy: .public)")
            recomputeSondeWindows()
        } catch {
            sondeForecastError = error.localizedDescription
            sondeForecastDate = now.addingTimeInterval(-3000)       // in 10 min erneut
            Self.log.error("Sondenvorhersage gescheitert: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recomputeSondeWindows() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: Date())
        let now = Date()
        var windows: [SondeWindow] = []
        for day in -1...2 {
            for slot in sondeSlots {
                let start = today.addingTimeInterval(Double(day) * 86_400 + Double(slot) * 60)
                var end = start.addingTimeInterval(sondeMinutes * 60)
                // Fliegt laut Vorhersage noch eine Sonde in Reichweite, länger offen
                // halten (bis 10 min danach, höchstens 5 h ab Fensterbeginn).
                if start == sondeForecastWindow, let last = sondeForecast.compactMap(\.inRange?.upperBound).max() {
                    end = max(end, min(last.addingTimeInterval(600), start.addingTimeInterval(5 * 3600)))
                }
                // Wird im laufenden Fenster noch eine Sonde gehört, offen halten, bis
                // sie 5 Minuten still ist (höchstens 5 h ab Fensterbeginn).
                if let heard = sondeHeard, let job = active, case .sonde(let running) = job.kind, running.start == start {
                    end = Self.sondeWindowEnd(planned: end, start: start, heard: heard)
                }
                if end > now, start < now.addingTimeInterval(48 * 3600) { windows.append(SondeWindow(start: start, end: end)) }
            }
        }
        let sorted = windows.sorted { $0.start < $1.start }
        if sorted != sondeWindows { sondeWindows = sorted }
    }

    private func settingsChanged() {
        recomputeSondeWindows()
        if autoMeteor || autoSonde || autoAmateur {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: "Empfangsplan (Satelliten/Sonden)")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }
}

/// Fliegende Radiosonden laut SondeHub. Abgefragt wird die weltweite Liste der
/// letzten 30 min (≈ 30 KB) und hier gefiltert – der eigene Standort geht
/// dabei nicht hinaus.
enum SondeHubTraffic {
    struct Sighting: Hashable, Sendable {
        let serial: String
        let type: String?
        let frequencyMHz: Double?
        let distanceKm: Double
        let altitude: Double
    }

    static func fetch(home: GroundStation, rangeKm: Double) async throws -> [Sighting] {
        var request = URLRequest(url: URL(string: "https://api.v2.sondehub.org/sondes?last=1800")!)
        request.timeoutInterval = 20
        request.setValue("PortaPackManager/1.0 (+https://github.com/cpeg78)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.limitedData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try inRange(data, latitude: home.latitude, longitude: home.longitude, rangeKm: rangeKm)
    }

    /// Sonden innerhalb `rangeKm` und über dem Funkhorizont
    /// (3,57 km·√h je Seite, Antenne mit 10 m angesetzt), nächste zuerst.
    static func inRange(_ data: Data, latitude: Double, longitude: Double, rangeKm: Double) throws -> [Sighting] {
        guard let all = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return all.compactMap { serial, entry -> Sighting? in
            guard let lat = (entry["lat"] as? NSNumber)?.doubleValue,
                  let lon = (entry["lon"] as? NSNumber)?.doubleValue else { return nil }
            let alt = max(0, (entry["alt"] as? NSNumber)?.doubleValue ?? 0)
            let distance = haversineKm(latitude, longitude, lat, lon)
            let horizon = 3.57 * (alt.squareRoot() + 10.0.squareRoot())
            guard distance <= min(rangeKm, horizon) else { return nil }
            return Sighting(serial: serial, type: entry["type"] as? String,
                            frequencyMHz: (entry["frequency"] as? NSNumber)?.doubleValue,
                            distanceKm: distance, altitude: alt)
        }
        .sorted { $0.distanceKm < $1.distanceKm }
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let a = pow(sin((lat2 - lat1) * r / 2), 2) + cos(lat1 * r) * cos(lat2 * r) * pow(sin((lon2 - lon1) * r / 2), 2)
        return 2 * 6371 * asin(min(1, a.squareRoot()))
    }
}
