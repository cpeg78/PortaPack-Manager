import Foundation

/// Gemeinsame Regeln, wer den HackRF wann bekommt – für alles, was das Gerät
/// nur kurz braucht oder ungefragt startet (Quarzabgleich, Antennen-Check,
/// Kacheln der Startseite, Erstsuche). Vorher regelte das jede Stelle selbst;
/// Folge: Fernbetrieb kam nach dem Abgleich nie zurück, ein laufender
/// Plan-Termin wurde still „übersprungen“ (Review 27.10.2026).
@MainActor
enum DeviceArbiter {
    /// Was gerade gegen eine Übernahme spricht, in Alltagssprache; `nil` = frei.
    static func blocker(session: DeviceSession?) -> String? {
        if session?.busy == true { return String(localized: "Am Mac läuft gerade eine Installation.") }
        if let job = ReceptionPlanner.shared.active {
            return String(localized: "Der Empfangsplan nimmt gerade auf: \(job.title) bis \(job.end.formatted(date: .omitted, time: .shortened)).")
        }
        return nil
    }

    /// Was ein Neustart, Moduswechsel oder USB-Reset gerade abbräche – Plan-Termin,
    /// Fernbetrieb oder ein laufender Empfänger – als ganzer Satz für die
    /// Rückfrage „Läuft gerade: … – trotzdem?“; `nil` = nichts läuft.
    static func activeUse(session: DeviceSession?) -> String? {
        if let job = ReceptionPlanner.shared.active {
            return String(localized: "Der Empfangsplan nimmt gerade auf: \(job.title) bis \(job.end.formatted(date: .omitted, time: .shortened)).")
        }
        if let mode = RemoteHub.shared.remoteMode {
            return String(localized: "Das Handy nutzt gerade den Fernzugriff (\(mode.title)).")
        }
        if let device = session?.hackRF, let owner = device.currentOwner ?? device.burstOwner {
            return String(localized: "Gerade empfängt die App für \(title(of: owner)).")
        }
        return nil
    }

    /// Wer gerade empfängt, für die Statuszeile („… empfängt gerade für Flugzeuge“).
    static func title(of owner: AnyObject?) -> String {
        let planner = ReceptionPlanner.shared
        // Die Amateurfunk-Seite benutzt dasselbe Model wie der Plan – nur ein Termin ist „der Plan“.
        if let owner, owner === planner.amateur, !planner.amateurBusy { return String(localized: "Amateurfunk-Satelliten", comment: "Empfänger, steht nach „für“") }
        if let owner, owner === planner.meteor || owner === planner.sonde || owner === planner.amateur { return String(localized: "den Empfangsplan", comment: "Empfänger, steht nach „für“") }
        if RemoteHub.shared.remoteMode != nil, let owner, let mode = RemoteHub.Mode.allCases.first(where: { RemoteHub.shared.existingOwner(for: $0) === owner }) {
            return String(localized: "den Fernzugriff (\(mode.title))", comment: "Empfänger, steht nach „für“")
        }
        switch owner {
        case is ADSBModel: return String(localized: "Flugzeuge (ADS-B)", comment: "Empfänger, steht nach „für“")
        case is AISModel: return String(localized: "Schiffe (AIS)", comment: "Empfänger, steht nach „für“")
        case is DABModel: return String(localized: "Digitalradio", comment: "Empfänger, steht nach „für“")
        case is TVModel: return String(localized: "Fernsehen", comment: "Empfänger, steht nach „für“")
        case is RadioModel: return String(localized: "Radio", comment: "Empfänger, steht nach „für“")
        case is ACARSModel: return String(localized: "Flugzeug-Datenfunk", comment: "Empfänger, steht nach „für“")
        case is ZigbeeModel: return String(localized: "Zigbee", comment: "Empfänger, steht nach „für“")
        case is SpectrumModel: return String(localized: "das Spektrum", comment: "Empfänger, steht nach „für“")
        case is AntennaCheckModel: return String(localized: "den Antennen-Check", comment: "Empfänger, steht nach „für“")
        case is OccupancyMonitor: return String(localized: "den Belegungsmonitor", comment: "Empfänger, steht nach „für“")
        case is HydrogenModel: return String(localized: "die Wasserstofflinie", comment: "Empfänger, steht nach „für“")
        case is DSCModel: return String(localized: "Seefunk-Notruf (DSC)", comment: "Empfänger, steht nach „für“")
        case is SmartHome868Model: return String(localized: "Smart Home 868 MHz", comment: "Empfänger, steht nach „für“")
        case is AirbandModel: return String(localized: "Flugfunk", comment: "Empfänger, steht nach „für“")
        case is VORModel: return String(localized: "Funkfeuer (VOR)", comment: "Empfänger, steht nach „für“")
        case is CellModel: return String(localized: "Mobilfunkzellen", comment: "Empfänger, steht nach „für“")
        case is FT8Model: return String(localized: "Amateurfunk FT8/WSPR", comment: "Empfänger, steht nach „für“")
        case is SensorModel: return String(localized: "Funksensoren", comment: "Empfänger, steht nach „für“")
        case is BLEModel: return String(localized: "Bluetooth-Geräte", comment: "Empfänger, steht nach „für“")
        case is WiFiModel: return String(localized: "WLAN", comment: "Empfänger, steht nach „für“")
        case is LoRaWANModel: return String(localized: "LoRaWAN", comment: "Empfänger, steht nach „für“")
        case is MeshtasticModel: return String(localized: "Meshtastic", comment: "Empfänger, steht nach „für“")
        case is APRSModel: return String(localized: "Funkamateure (APRS)", comment: "Empfänger, steht nach „für“")
        case is PagerModel: return String(localized: "Funkruf (POCSAG)", comment: "Empfänger, steht nach „für“")
        case is FLARMModel: return String(localized: "FLARM/OGN", comment: "Empfänger, steht nach „für“")
        case is DroneModel: return String(localized: "Drohnen", comment: "Empfänger, steht nach „für“")
        case is GPSModel: return String(localized: "GPS-Ortung", comment: "Empfänger, steht nach „für“")
        case is DCF77Model: return String(localized: "Funkuhr (DCF77)", comment: "Empfänger, steht nach „für“")
        case is SondeModel: return String(localized: "Wetterballons", comment: "Empfänger, steht nach „für“")
        case is MeteorModel: return String(localized: "Wettersatellit (METEOR)", comment: "Empfänger, steht nach „für“")
        case is AmateurSatModel: return String(localized: "Amateurfunk-Satelliten", comment: "Empfänger, steht nach „für“")
        case is RecorderModel: return String(localized: "die Aufnahme", comment: "Empfänger, steht nach „für“")
        // Neue Empfänger hier eintragen – sonst steht in Seitenleiste und
        // Statuszeile nur dieser Notbehelf (Fund 29.10.2026: Funkuhr fehlte).
        default: return String(localized: "einen anderen Empfänger", comment: "Empfänger, steht nach „für“")
        }
    }

    /// Gerät kurz ausleihen: Plan pausiert (keine neuen Termine), laufender
    /// Empfänger von `RemoteHub` (ADS-B, AIS, DAB+, ACARS, Spektrum – aus der
    /// Ferne oder am Mac gestartet) bzw. ein Mac-Empfänger (`ReceiverRestarting`)
    /// wird angehalten und danach genauso wieder gestartet. `takenOver`: die Arbeit hat das Gerät an jemand anderen
    /// verloren – dann nichts zurückholen, der Neue hat Vorrang.
    static func borrow<T>(_ work: () async -> (result: T, takenOver: Bool)) async -> T {
        let planner = ReceptionPlanner.shared
        planner.paused = true
        defer { planner.paused = false }
        // Auch ein reiner Mac-Empfänger (TV, BLE, GPS …) kommt danach zurück –
        // wie nach einem Plan-Termin (Nutzerwunsch 29.10.2026).
        let hub = RemoteHub.shared
        let local = hub.session?.hackRF.flatMap { ReceiverStore.shared.suspendLocal(on: $0) }
        let suspended = PlanResume.choose(hub: hub.suspendForPlan(), local: local)
        let outcome = await work()
        if !outcome.takenOver, let suspended {
            switch suspended {
            case .hub(let mode, let remote):
                await hub.resumeAfterPlan(mode, remote: remote)
            case .local(let model):
                if let device = hub.session?.hackRF, PlanResume.allowed(occupant: ReceiverStore.occupant(of: device), target: model) {
                    ReceiverStore.shared.resumeLocal(model, on: device)
                }
            }
        }
        return outcome.result
    }
}
