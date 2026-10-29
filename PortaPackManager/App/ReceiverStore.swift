import Foundation
import Observation
import os

/// Hält die Empfänger-Models aller Seiten über den Seitenwechsel hinweg und
/// regelt, wann ein Start einen anderen Empfänger beendet.
///
/// Vorher hielt jede Seite ihr Model selbst (`@State`) und stoppte es in
/// `.onDisappear` – ein Seitenwechsel beendete den Empfang und verwarf alle
/// Daten. Wunsch 29.10.2026: Der Empfang läuft weiter, bis auf einer anderen
/// Seite ein neuer startet, und dann erst nach kurzer Rückfrage.
///
/// - Wo `RemoteHub` oder der Empfangsplan schon ein Model für denselben
///   Empfänger halten, reicht der Halter genau dieses durch – nie zwei
///   Instanzen je Empfänger.
/// - Die übrigen legt er erst beim ersten Zugriff an (teure `init`s laufen
///   genau einmal).
@MainActor
@Observable
final class ReceiverStore {
    static let shared = ReceiverStore()

    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Empfänger")

    // MARK: - Models

    @ObservationIgnored private var storage: [ObjectIdentifier: AnyObject] = [:]

    private func lazy<M: AnyObject>(_ make: () -> M) -> M {
        let key = ObjectIdentifier(M.self)
        if let model = storage[key] as? M { return model }
        let model = make()
        storage[key] = model
        return model
    }

    /// Schon angelegte Models, die nur dieser Halter besitzt (für Tests und
    /// Aufräumarbeiten; legt nichts an).
    var createdModels: [AnyObject] { Array(storage.values) }

    // Eigene Models (nur von der jeweiligen Mac-Seite benutzt).
    /// Spektrum der Mac-Seite – der Fernzugriff hat bewusst ein eigenes (`RemoteHub.spectrum`).
    var spectrum: SpectrumModel { lazy { SpectrumModel() } }
    var tv: TVModel { lazy { TVModel() } }
    var aprs: APRSModel { lazy { APRSModel() } }
    var pager: PagerModel { lazy { PagerModel() } }
    var flarm: FLARMModel { lazy { FLARMModel() } }
    var ble: BLEModel { lazy { BLEModel() } }
    var wifi: WiFiModel { lazy { WiFiModel() } }
    var drones: DroneModel { lazy { DroneModel() } }
    var meshtastic: MeshtasticModel { lazy { MeshtasticModel() } }
    var lorawan: LoRaWANModel { lazy { LoRaWANModel() } }
    var dcf77: DCF77Model { lazy { DCF77Model() } }
    var gps: GPSModel { lazy { GPSModel() } }
    var recorder: RecorderModel { lazy { RecorderModel() } }
    var antennaCheck: AntennaCheckModel { lazy { AntennaCheckModel() } }
    var vor: VORModel { lazy { VORModel() } }
    var cells: CellModel { lazy { CellModel() } }

    // Geteilte Models: dieselbe Instanz wie Fernzugriff bzw. Empfangsplan.
    var adsb: ADSBModel { RemoteHub.shared.adsb }
    var ais: AISModel { RemoteHub.shared.ais }
    var dab: DABModel { RemoteHub.shared.dab }
    var acars: ACARSModel { RemoteHub.shared.acars }
    var zigbee: ZigbeeModel { RemoteHub.shared.zigbee }
    var airband: AirbandModel { RemoteHub.shared.airband }
    var radio: RadioModel { RemoteHub.shared.radio }
    var sensors: SensorModel { RemoteHub.shared.sensors }
    var smartHome: SmartHome868Model { RemoteHub.shared.smartHome }
    var ft8: FT8Model { RemoteHub.shared.ft8 }
    var dsc: DSCModel { RemoteHub.shared.dsc }
    var occupancy: OccupancyMonitor { RemoteHub.shared.occupancy }
    var hydrogen: HydrogenModel { HydrogenModel.shared }
    var sonde: SondeModel { ReceptionPlanner.shared.sonde }
    var meteor: MeteorModel { ReceptionPlanner.shared.meteor }
    var amateur: AmateurSatModel { ReceptionPlanner.shared.amateur }

    /// Seite eines Empfängers – für Rückfrage und den grünen Punkt in der
    /// Seitenleiste. Nach Typ, damit nichts angelegt werden muss.
    nonisolated static func item(of owner: AnyObject?) -> SidebarItem? {
        switch owner {
        case is ADSBModel: .adsb
        case is AISModel: .ais
        case is DABModel: .dab
        case is TVModel: .tv
        case is RadioModel: .radio
        case is ACARSModel: .acars
        case is ZigbeeModel: .zigbee
        case is SpectrumModel: .spectrum
        case is AntennaCheckModel: .antennaCheck
        case is OccupancyMonitor: .occupancy
        case is HydrogenModel: .hydrogen
        case is DSCModel: .dsc
        case is SmartHome868Model: .smartHome868
        case is AirbandModel: .airband
        case is VORModel: .vor
        case is CellModel: .cells
        case is FT8Model: .ft8
        case is SensorModel: .sensors
        case is BLEModel: .ble
        case is WiFiModel: .wifi
        case is LoRaWANModel: .lorawan
        case is MeshtasticModel: .meshtastic
        case is APRSModel: .aprs
        case is PagerModel: .pager
        case is FLARMModel: .flarm
        case is DroneModel: .drones
        case is GPSModel: .gps
        case is DCF77Model: .dcf77
        case is SondeModel: .sonde
        case is MeteorModel: .meteor
        case is AmateurSatModel: .amateurSat
        case is RecorderModel: .recorder
        default: nil
        }
    }

    // MARK: - Was läuft gerade (Seitenleiste)

    /// Seite des Empfängers, für den der HackRF gerade empfängt (grüner Punkt).
    private(set) var activeItem: SidebarItem?

    /// Wer das Gerät gerade belegt: der laufende Strom oder – zwischen den
    /// Aufnahmen eines Stoß-Empfängers (LTE) – dessen Reservierung.
    static func occupant(of device: HackRFDevice) -> AnyObject? {
        if let owner = device.currentOwner { return owner }
        if let burst = device.burstOwner as? GainTunable, burst.running { return burst }
        return nil
    }

    /// Seite des Empfängers, der läuft – auch wenn er das Gerät gerade kurz
    /// freigibt (Wechselschleifen, Stoß-Empfänger). Ohne den laufenden Plan-Termin.
    private(set) var runningItem: SidebarItem?

    /// Die App wird beendet: das Gedächtnis „zuletzt lief“ nicht mehr ändern
    /// (Beenden stoppt Aufnahmen, das ist kein bewusster Stopp).
    @ObservationIgnored var terminating = false
    @ObservationIgnored private let lastReceiver = LastReceiverMemory()

    /// Takt für Seitenleiste, Aufräumen und das Gedächtnis „zuletzt lief“. Läuft
    /// ab dem Start der App (`AppServices.start`) – seit dem Hintergrundbetrieb
    /// (29.10.2026) auch ohne Fenster; vorher hing er am Hauptfenster.
    func track(session: DeviceSession) async {
        var orphanTicks: [ObjectIdentifier: Int] = [:]
        var lastMode = session.mode
        while !Task.isCancelled {
            // Verlässt das Gerät den HackRF-Modus, gelten alle Empfänger als beendet
            // (vorher `.onChange(of: session.mode)` am Hauptfenster).
            if session.mode != lastMode {
                lastMode = session.mode
                if session.mode != .hackRF { stopAllAfterModeChange() }
            }
            let device = session.mode == .hackRF ? session.hackRF : nil
            let item = device.flatMap { Self.item(of: Self.occupant(of: $0)) }
            if item != activeItem { activeItem = item }
            if let device { stopOrphans(device, ticks: &orphanTicks) } else { orphanTicks = [:] }
            updateRunning(deviceReady: device != nil)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Laufenden Empfänger bestimmen und „zuletzt lief“ fortschreiben.
    private func updateRunning(deviceReady: Bool) {
        let planModel = ReceptionPlanner.shared.active.map(Self.planModel(of:))
        let running = runningModels(excluding: planModel).first.flatMap(Self.item(of:))
        let previous = runningItem
        if running != runningItem { runningItem = running }
        let change = LastReceiverMemory.change(running: running, previous: previous,
                                               remoteChosen: RemoteHub.shared.remoteMode != nil,
                                               planActive: planModel != nil, deviceReady: deviceReady,
                                               terminating: terminating)
        switch change {
        case .keep: break
        case .remember(let item):
            if lastReceiver.item != item {
                Self.log.info("Zuletzt läuft: \(item.rawValue, privacy: .public)")
                lastReceiver.remember(item)
            }
        case .forget:
            // Erst nach ein paar Takten: Beim Abziehen bricht der Strom oft ab, bevor
            // die Geräteerkennung den Modus umstellt – das ist kein bewusster Stopp.
            if lastReceiver.item != nil { pendingForget = (5, previous) }
        }
        guard let pending = pendingForget else { return }
        if running != nil || !deviceReady || planModel != nil || terminating {
            pendingForget = nil
        } else if pending.ticks > 1 {
            pendingForget = (pending.ticks - 1, pending.item)
        } else {
            pendingForget = nil
            Self.log.info("Empfang bewusst beendet – Autostart vergisst \(pending.item?.rawValue ?? "", privacy: .public)")
            lastReceiver.forget()
        }
    }
    @ObservationIgnored private var pendingForget: (ticks: Int, item: SidebarItem?)?

    /// Alle bekannten Empfänger, die sich für laufend halten – der Gerätebesitzer
    /// zuerst. Legt nichts an.
    func runningModels(excluding excluded: AnyObject? = nil) -> [AnyObject] {
        var all: [AnyObject] = []
        if let device = AppServices.session.hackRF, let occupant = Self.occupant(of: device) { all.append(occupant) }
        all += Array(storage.values) + Array(started.values)
        all += RemoteHub.Mode.allCases.compactMap { RemoteHub.shared.existingOwner(for: $0) }
        var seen = Set<ObjectIdentifier>()
        return all.filter { model in
            guard model !== excluded, seen.insert(ObjectIdentifier(model)).inserted,
                  let receiver = model as? ReceiverStopping else { return false }
            return receiver.receiverRunning
        }
    }

    /// Model eines eigenen Empfängers, ohne es anzulegen.
    func existing<M: AnyObject>(_ type: M.Type) -> M? { storage[ObjectIdentifier(type)] as? M }

    /// „Empfang stoppen“ (Menüleiste): Plan-Termin überspringen, Fernbetrieb
    /// beenden, alle Mac-Empfänger aus. Ein bewusster Stopp – der Autostart
    /// vergisst den zuletzt laufenden Empfänger.
    func stopEverything(session: DeviceSession) async {
        let planner = ReceptionPlanner.shared
        if planner.active != nil { await planner.skipActive(resumePrevious: false) }
        planner.dropResume()
        if RemoteHub.shared.remoteMode != nil { RemoteHub.shared.endRemoteMode() }
        let device = session.hackRF
        for model in runningModels() {
            (model as? ReceiverStopping)?.stopReceiver(on: device)
        }
        lastReceiver.forget()
        Self.log.notice("Empfang über die Menüleiste beendet")
    }

    /// Eigene Models, die sich für laufend halten, deren Gerät aber seit zwei
    /// Takten eindeutig ein anderer Empfänger nutzt (Empfangsplan, Fernzugriff,
    /// Kalibrierung). Früher stoppte das die Seite beim Verlassen; jetzt liefen
    /// sie sonst ewig als „an“ weiter. Nur bei einem *anderen* Besitzer –
    /// Wechselschleifen und Stoß-Empfänger geben das Gerät zwischendurch kurz frei.
    private func stopOrphans(_ device: HackRFDevice, ticks: inout [ObjectIdentifier: Int]) {
        let occupant = Self.occupant(of: device)
        for model in storage.values {
            let id = ObjectIdentifier(model)
            guard let receiver = model as? ReceiverStopping, receiver.receiverRunning,
                  let occupant, occupant !== model else { ticks[id] = 0; continue }
            ticks[id, default: 0] += 1
            guard ticks[id, default: 0] >= 2 else { continue }
            ticks[id] = 0
            Self.log.notice("\(DeviceArbiter.title(of: model), privacy: .public) lief ohne Gerät weiter – gestoppt")
            receiver.stopReceiver(on: device)
        }
    }

    /// Gerät hat den HackRF-Modus verlassen: alle Empfänger auf „aus“. Vorher
    /// tat das die sichtbare Seite – jetzt laufen Models auch unsichtbar weiter.
    func stopAllAfterModeChange() {
        var all = Array(storage.values) + Array(started.values)
        all += RemoteHub.Mode.allCases.compactMap { RemoteHub.shared.existingOwner(for: $0) }
        var seen = Set<ObjectIdentifier>()
        for model in all where seen.insert(ObjectIdentifier(model)).inserted {
            guard let receiver = model as? ReceiverStopping, receiver.receiverRunning else { continue }
            receiver.stopReceiver(on: nil)
        }
    }

    /// Alle, die je über `requestStart` gestartet wurden (auch geteilte Models wie
    /// Sonde oder Wasserstofflinie) – für `stopAllAfterModeChange`.
    @ObservationIgnored private var started: [ObjectIdentifier: AnyObject] = [:]

    /// Schalter „Externer LNA“: Seiten werden neu aufgebaut, die Models hier
    /// leben aber weiter – Vorgaben der ruhenden Models neu setzen (wie
    /// `RemoteHub.applyGainPresets`). Laufende behalten ihre Werte bis zum nächsten Start.
    func applyGainPresets() {
        func apply(_ model: GainTunable, _ receiver: GainProfile.Receiver) {
            guard !model.running else { return }
            let preset = GainProfile.preset(receiver)
            model.lnaGain = preset.lna; model.vgaGain = preset.vga; model.amplifier = preset.amplifier
        }
        for model in storage.values {
            switch model {
            case let m as SpectrumModel: apply(m, .spectrum)
            case let m as TVModel: apply(m, .tv)
            case let m as APRSModel: apply(m, .aprs)
            case let m as PagerModel: apply(m, .pager)
            case let m as FLARMModel: apply(m, .meshtastic)
            case let m as BLEModel: apply(m, .ble)
            case let m as WiFiModel: apply(m, .wifi)
            case let m as DroneModel: apply(m, .drones)
            case let m as MeshtasticModel: apply(m, .meshtastic)
            case let m as LoRaWANModel: apply(m, .meshtastic)
            case let m as DCF77Model: apply(m, .dcf77)
            case let m as GPSModel: apply(m, .gps)
            case let m as RecorderModel: apply(m, .recorder)
            case let m as VORModel: apply(m, .acars)
            case let m as CellModel: apply(m, .cells)
            default: break
            }
        }
    }

    // MARK: - Plan-Termin, Ausleihe, Fernzugriff

    /// Empfänger von `RemoteHub` (dort angehalten und zurückgeholt).
    private func isHubModel(_ model: AnyObject) -> Bool {
        RemoteHub.Mode.allCases.contains { RemoteHub.shared.existingOwner(for: $0) === model }
    }

    /// Empfänger des Empfangsplans (Sonde, METEOR, Amateurfunk).
    private func isPlanModel(_ model: AnyObject) -> Bool {
        let planner = ReceptionPlanner.shared
        return model === planner.sonde || model === planner.meteor || model === planner.amateur
    }

    /// Vor einem Plan-Termin oder einer Ausleihe (`DeviceArbiter.borrow`): den
    /// Mac-Empfänger, der das Gerät gerade belegt (TV, BLE, GPS, Wasserstofflinie …),
    /// sauber beenden. Liefert ihn, wenn er sich danach neu starten lässt
    /// (`ReceiverRestarting`). Empfänger von `RemoteHub` und des Plans regeln die selbst.
    /// Vorher verlor er nur das Gerät, `stopOrphans` stoppte ihn, und nach dem
    /// Termin blieb er aus (Nutzerwunsch 29.10.2026: er soll zurückkommen).
    func suspendLocal(on device: HackRFDevice) -> AnyObject? {
        guard let occupant = Self.occupant(of: device), !isHubModel(occupant), !isPlanModel(occupant),
              let receiver = occupant as? ReceiverStopping, receiver.receiverRunning else { return nil }
        Self.log.notice("\(DeviceArbiter.title(of: occupant), privacy: .public) angehalten – kommt danach zurück")
        receiver.stopReceiver(on: device)
        return occupant is ReceiverRestarting ? occupant : nil
    }

    /// Nach dem Termin bzw. der Ausleihe den gemerkten Mac-Empfänger wieder starten.
    /// Ob das Gerät frei ist, prüft der Aufrufer (`PlanResume.allowed`).
    func resumeLocal(_ model: AnyObject, on device: HackRFDevice) {
        guard let receiver = model as? ReceiverRestarting, !receiver.receiverRunning else { return }
        Self.log.notice("Weiter mit \(DeviceArbiter.title(of: model), privacy: .public)")
        receiver.restartReceiver(on: device)
    }

    /// Das Handy hat umgeschaltet oder „Stopp“ getippt (`RemoteHub.activate`): alle
    /// Mac-Empfänger sauber beenden. `device.stopReceiving()` nahm ihnen vorher nur
    /// den Strom, und sie blieben als „läuft“ ohne Daten stehen – `stopOrphans`
    /// greift nur, wenn ein *anderer* das Gerät hält (Review 29.10.2026).
    /// Ausgenommen: Empfänger von `RemoteHub` (die stoppt er selbst) und der
    /// laufende Plan-Termin (den beendet der Plan, wenn er das Gerät verliert).
    func stopLocalReceivers(on device: HackRFDevice?) {
        let planModel = ReceptionPlanner.shared.active.map(Self.planModel(of:))
        var seen = Set<ObjectIdentifier>()
        for model in Array(storage.values) + Array(started.values) where seen.insert(ObjectIdentifier(model)).inserted {
            guard model !== planModel, !isHubModel(model),
                  let receiver = model as? ReceiverStopping, receiver.receiverRunning else { continue }
            Self.log.notice("\(DeviceArbiter.title(of: model), privacy: .public) vom Fernzugriff beendet")
            receiver.stopReceiver(on: device)
        }
    }

    // MARK: - Start mit Rückfrage

    /// Eine offene Rückfrage („Gerade läuft … Umschalten?“), angezeigt von `ContentView`.
    struct SwitchRequest: Identifiable {
        let id = UUID()
        let prompt: SwitchPrompt
        fileprivate let conflict: ReceiverConflict
        fileprivate let requester: AnyObject
        fileprivate let newTitle: String
        fileprivate let start: @MainActor (HackRFDevice) -> Void
    }

    var pendingSwitch: SwitchRequest?
    @ObservationIgnored private weak var pendingSession: DeviceSession?

    /// Einziger Weg, auf dem eine Seite am Mac einen Empfang startet (Knöpfe,
    /// großer Startknopf, Autostart der Kacheln). Belegt ein *anderer*
    /// Empfänger das Gerät, fragt die App erst nach; sonst startet `start` sofort.
    /// Fernzugriff und Empfangsplan rufen das nicht – sie haben eigene Regeln.
    func requestStart(_ owner: AnyObject, session: DeviceSession, start: @escaping @MainActor (HackRFDevice) -> Void) {
        guard let device = session.hackRF else { return }
        started[ObjectIdentifier(owner)] = owner
        guard let conflict = conflict(for: owner, device: device) else { launch(owner, start, on: device); return }
        let newTitle = Self.item(of: owner)?.title ?? String(localized: "diesen Empfänger")
        pendingSession = session
        pendingSwitch = SwitchRequest(prompt: SwitchPrompt(conflict: conflict, newTitle: newTitle),
                                      conflict: conflict, requester: owner, newTitle: newTitle, start: start)
    }

    /// Wer dem Start von `requester` jetzt im Weg steht.
    private func conflict(for requester: AnyObject, device: HackRFDevice) -> ReceiverConflict? {
        let hub = RemoteHub.shared
        return ReceiverConflict.classify(
            requester: requester,
            occupant: Self.occupant(of: device),
            plan: ReceptionPlanner.shared.active.map { ($0.title, Self.planModel(of: $0)) },
            remote: hub.remoteMode.map { ($0, hub.existingOwner(for: $0)) })
    }

    /// Start durch den Nutzer: Was der Plan nach einem Termin zurückholen wollte,
    /// gilt nicht mehr – der Nutzer hat inzwischen selbst gewählt. Ausnahme: das
    /// Model des laufenden Termins (Sondenseite während eines Sondenfensters).
    private func launch(_ owner: AnyObject, _ start: @MainActor (HackRFDevice) -> Void, on device: HackRFDevice) {
        let planner = ReceptionPlanner.shared
        if planner.active.map(Self.planModel(of:)) !== owner { planner.dropResume() }
        start(device)
    }

    /// „Umschalten“ in der Rückfrage: bisherigen Empfänger sauber beenden, dann starten.
    ///
    /// Der Konflikt wird beim Klick neu bestimmt: Während die Rückfrage offen
    /// stand, kann ein Plan-Termin begonnen oder der alte Empfänger geendet haben
    /// (Review 29.10.2026). Ist die Lage eine andere, kommt die passende Rückfrage.
    func confirmSwitch(_ request: SwitchRequest) {
        if pendingSwitch?.id == request.id { pendingSwitch = nil }
        let session = pendingSession
        Task {
            guard let device = session?.hackRF else { return }
            let current = conflict(for: request.requester, device: device)
            if let current, !current.sameSituation(as: request.conflict) {
                // Erst nach dem Schließen der alten Rückfrage zeigen – ihr Schließen
                // setzt `pendingSwitch` sonst gleich wieder auf nil.
                try? await Task.sleep(for: .milliseconds(350))
                Self.log.info("Lage hat sich während der Rückfrage geändert – neu gefragt")
                pendingSwitch = SwitchRequest(prompt: SwitchPrompt(conflict: current, newTitle: request.newTitle),
                                              conflict: current, requester: request.requester,
                                              newTitle: request.newTitle, start: request.start)
                return
            }
            switch current {
            case .plan?:
                // Die Rückkehr zum vorherigen Empfänger verwerfen: Der Plan holte ihn
                // sonst im nächsten Takt (≤ 10 s) zurück und warf den gerade
                // bestätigten hinaus (Review 29.10.2026).
                await ReceptionPlanner.shared.skipActive(resumePrevious: false)
            case .remote?:
                RemoteHub.shared.endRemoteMode()
            case .local(let owner, _)?:
                if let receiver = owner as? ReceiverStopping {
                    receiver.stopReceiver(on: device)
                } else {
                    device.stopReceiving(owner: owner)
                }
            case nil:
                break
            }
            guard let device = session?.hackRF else { return }
            Self.log.info("Umgeschaltet: \(request.prompt.message, privacy: .public)")
            launch(request.requester, request.start, on: device)
        }
    }

    func cancelSwitch() { pendingSwitch = nil }

    // MARK: - Start ohne Fenster (Anmeldestart)

    enum LaunchOutcome: Equatable {
        case started
        /// Ein Plan-Termin läuft – der Empfänger startet danach (wie nach einem Termin).
        case afterPlan
        /// Ein anderer Empfänger belegt das Gerät (Titel) – nichts übernommen.
        case occupied(String)
        case failed(String)
    }

    /// Model einer Seite für den Start ohne Fenster (legt eigene Models bei Bedarf an).
    private func launchModel(for item: SidebarItem) -> AnyObject? {
        if let mode = LaunchStart.hubMode(for: item) {
            // Über den Halter: legt Zigbee, Flugfunk, Radio … bei Bedarf an.
            switch mode {
            case .adsb: return adsb
            case .ais: return ais
            case .dab: return dab
            case .acars: return acars
            case .zigbee: return zigbee
            case .airband: return airband
            case .radio: return radio
            case .sensors: return sensors
            case .smartHome868: return smartHome
            case .dsc: return dsc
            case .ft8: return ft8
            case .occupancy: return occupancy
            case .spectrum: return nil
            }
        }
        switch item {
        case .spectrum: return spectrum
        case .tv: return tv
        case .aprs: return aprs
        case .pager: return pager
        case .flarm: return flarm
        case .ble: return ble
        case .wifi: return wifi
        case .drones: return drones
        case .meshtastic: return meshtastic
        case .lorawan: return lorawan
        case .dcf77: return dcf77
        case .gps: return gps
        case .vor: return vor
        case .cells: return cells
        case .hydrogen: return hydrogen
        case .sonde: return sonde
        case .recorder: return recorder
        default: return nil
        }
    }

    /// Empfänger einer Seite ohne Fenster starten (Anmeldestart). Nimmt nie
    /// jemandem das Gerät weg: Läuft ein Plan-Termin, startet er danach; belegt
    /// ein anderer Empfänger das Gerät, bleibt es dabei.
    func startForLaunch(_ item: SidebarItem, on device: HackRFDevice) async -> LaunchOutcome {
        guard LaunchStart.canStart(item), let model = launchModel(for: item) else {
            return .failed(String(localized: "Diese Seite lässt sich nicht von selbst starten."))
        }
        if (model as? ReceiverStopping)?.receiverRunning == true { return .started }
        let planner = ReceptionPlanner.shared
        if planner.active != nil {
            if let mode = LaunchStart.hubMode(for: item) {
                planner.resumeLater(.hub(mode, remote: false))
                return .afterPlan
            }
            if model is ReceiverRestarting {
                planner.resumeLater(.local(model))
                return .afterPlan
            }
            return .occupied(planner.active?.title ?? "")
        }
        if let occupant = Self.occupant(of: device), occupant !== model {
            return .occupied(Self.item(of: occupant)?.title ?? DeviceArbiter.title(of: occupant))
        }
        started[ObjectIdentifier(model)] = model
        Self.log.notice("Anmeldestart: \(item.rawValue, privacy: .public)")
        if let mode = LaunchStart.hubMode(for: item) {
            await RemoteHub.shared.resumeAfterPlan(mode, remote: false)
        } else if let sonde = model as? SondeModel {
            sonde.start(on: device)
        } else if let recorder = model as? RecorderModel {
            recorder.startRecording(on: device)
        } else if let receiver = model as? ReceiverRestarting {
            receiver.restartReceiver(on: device)
        }
        // Manche Empfänger melden „läuft“ erst nach dem asynchronen Anlauf.
        for _ in 0..<15 where (model as? ReceiverStopping)?.receiverRunning != true {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if (model as? ReceiverStopping)?.receiverRunning == true { return .started }
        return .failed(String(localized: "Start fehlgeschlagen – Einzelheiten zeigt die Seite."))
    }

    static func planModel(of job: ReceptionPlanner.Job) -> AnyObject {
        let planner = ReceptionPlanner.shared
        if job.isSonde { return planner.sonde }
        if job.isAmateur { return planner.amateur }
        return planner.meteor
    }
}

// MARK: - Rückfrage (reine Logik, testbar)

/// Wer dem neuen Start im Weg steht.
enum ReceiverConflict {
    /// Ein Termin des Empfangsplans nimmt auf (Titel des Termins).
    case plan(title: String)
    /// Das Handy hat diesen Empfänger gewählt (Fernbetrieb).
    case remote(RemoteHub.Mode)
    /// Eine andere Seite am Mac empfängt.
    case local(owner: AnyObject, name: String)

    /// - Parameters:
    ///   - occupant: wer das Gerät gerade belegt (`HackRFDevice.currentOwner` bzw. Stoß-Reservierung)
    ///   - plan: laufender Termin samt Model, das ihn aufnimmt
    ///   - remote: aus der Ferne gewählter Modus samt Model
    @MainActor
    static func classify(requester: AnyObject, occupant: AnyObject?,
                         plan: (title: String, model: AnyObject)?,
                         remote: (mode: RemoteHub.Mode, model: AnyObject?)?) -> ReceiverConflict? {
        // Ein Termin hat Vorrang, auch wenn er gerade zwischen zwei Starts steht.
        if let plan, plan.model !== requester { return .plan(title: plan.title) }
        guard let occupant, occupant !== requester else { return nil }
        if let remote, let model = remote.model, model === occupant { return .remote(remote.mode) }
        return .local(owner: occupant, name: ReceiverStore.item(of: occupant)?.title ?? String(localized: "ein anderer Empfänger"))
    }

    /// Dieselbe Lage wie bei der Rückfrage? Gleicher Fall und derselbe Termin,
    /// Fernzugriffs-Modus bzw. Empfänger – sonst muss neu gefragt werden.
    nonisolated func sameSituation(as other: ReceiverConflict) -> Bool {
        switch (self, other) {
        case let (.plan(a), .plan(b)): a == b
        case let (.remote(a), .remote(b)): a == b
        case let (.local(a, _), .local(b, _)): a === b
        default: false
        }
    }
}

/// Was ein Plan-Termin bzw. eine Ausleihe angehalten hat und danach wieder startet.
enum PlanResume {
    /// Empfänger von `RemoteHub` (ADS-B, AIS, DAB+ …) – aus der Ferne gewählt oder am Mac gestartet.
    case hub(RemoteHub.Mode, remote: Bool)
    /// Reiner Mac-Empfänger aus `ReceiverStore` (TV, BLE, GPS, Wasserstofflinie …).
    case local(AnyObject)

    /// Wen zurückholen: Ein Empfänger von `RemoteHub` hat Vorrang – läuft einer,
    /// belegt er das Gerät, und ein Mac-Empfänger daneben gibt es nicht.
    nonisolated static func choose(hub: (mode: RemoteHub.Mode, remote: Bool)?, local: AnyObject?) -> PlanResume? {
        if let hub { return .hub(hub.mode, remote: hub.remote) }
        return local.map { .local($0) }
    }

    /// Ob die Rückkehr noch gilt: Das Gerät ist frei oder gehört schon dem
    /// gemerkten Empfänger. Hat der Nutzer inzwischen etwas anderes gestartet,
    /// bleibt es dabei.
    nonisolated static func allowed(occupant: AnyObject?, target: AnyObject?) -> Bool {
        guard let occupant else { return true }
        return target.map { $0 === occupant } ?? false
    }
}

/// Texte der Rückfrage.
struct SwitchPrompt: Equatable {
    let title: String
    let message: String

    init(conflict: ReceiverConflict, newTitle: String) {
        switch conflict {
        case .plan(let job):
            title = String(localized: "Aufnahme des Empfangsplans überspringen?")
            message = String(localized: "Der Empfangsplan nimmt gerade \(job) auf. Überspringen und \(newTitle) starten?")
        case .remote(let mode):
            title = String(localized: "Fernbetrieb beenden?")
            message = String(localized: "Das Handy nutzt gerade \(mode.title). Fernbetrieb beenden und \(newTitle) starten?")
        case .local(_, let name):
            title = String(localized: "Empfänger umschalten?")
            message = String(localized: "Gerade läuft \(name). Beenden und \(newTitle) starten?")
        }
    }
}

// MARK: - Neustart nach Plan-Termin oder Ausleihe

/// Ein Mac-Empfänger, den Empfangsplan und `DeviceArbiter.borrow` nach ihrem Ende
/// wieder starten – mit dem, was er zuletzt eingestellt hatte. Nicht dabei: Aufnahme
/// und Antennen-Check (einmalige Vorgänge) sowie die Empfänger von `RemoteHub`
/// und des Plans (eigene Wege).
@MainActor
protocol ReceiverRestarting: ReceiverStopping {
    func restartReceiver(on device: HackRFDevice)
}

extension SpectrumModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension TVModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension APRSModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension FLARMModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension BLEModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension WiFiModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension DroneModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension MeshtasticModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension LoRaWANModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension DCF77Model: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension GPSModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension VORModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
extension CellModel: ReceiverRestarting { func restartReceiver(on device: HackRFDevice) { start(on: device) } }
/// Funkruf: Frequenz wie auf der Seite (`@AppStorage("pagerFrequencyMHz")`).
extension PagerModel: ReceiverRestarting {
    func restartReceiver(on device: HackRFDevice) {
        let stored = UserDefaults.standard.object(forKey: "pagerFrequencyMHz") as? Double
        start(on: device, frequencyMHz: stored.flatMap { $0.isFinite ? $0 : nil } ?? PagerModel.dapnetMHz)
    }
}
/// Wasserstofflinie: setzt die Integration fort (nicht `fresh`), dieselbe Messart.
extension HydrogenModel: ReceiverRestarting {
    func restartReceiver(on device: HackRFDevice) { start(on: device, capture: capture) }
}

// MARK: - Einheitliches Stoppen

/// Ein Empfänger, den die Rückfrage beim Umschalten sauber beendet – jedes
/// Model mit seinen eigenen Aufräumarbeiten (`running = false`, Tasks, Ton …).
@MainActor
protocol ReceiverStopping: AnyObject {
    /// Hält sich das Model für laufend?
    var receiverRunning: Bool { get }
    func stopReceiver(on device: HackRFDevice?)
}

extension ADSBModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension AISModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension SpectrumModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension APRSModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension PagerModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension SondeModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension DSCModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension WiFiModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension AmateurSatModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension MeteorModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension FT8Model: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension ZigbeeModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop(on: device) }
}
extension DABModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension RadioModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension ACARSModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension AirbandModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension SensorModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension SmartHome868Model: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension BLEModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension FLARMModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension MeshtasticModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension LoRaWANModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension DCF77Model: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension GPSModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension DroneModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension CellModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension VORModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension TVModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension HydrogenModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { stop() }
}
extension OccupancyMonitor: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { if running { stop() } }
}
extension AntennaCheckModel: ReceiverStopping {
    var receiverRunning: Bool { running }
    func stopReceiver(on device: HackRFDevice?) { cancel() }
}
/// Die Aufnahme: nur das Aufnehmen belegt den HackRF, die Wiedergabe nicht.
extension RecorderModel: ReceiverStopping {
    var receiverRunning: Bool { recording }
    func stopReceiver(on device: HackRFDevice?) { if recording { stopRecording() } }
}
