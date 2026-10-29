import Foundation
import OSLog

/// Reiter „Radio“ des Fernzugriffs (`/api/fm`): UKW/NFM/AM/USB/LSB/CW mit
/// Frequenz, Betriebsart, Filterbreite, Rauschsperre, RDS, Frequenzspeicher und
/// dem letzten Suchlauf. Der Ton kommt über den gemeinsamen Strom `/audio.aac`.
///
/// Aktionen: `f=<MHz>`, `mode=wfm|nfm|am|usb|lsb|cw`, `bw=<Hz>` (nur eine der
/// Breiten der Betriebsart, `bandwidths` im Zustand), `step=+1|-1`, `squelch=<dB>`,
/// `fav=<id>` (Eintrag des Frequenzspeichers mit Betriebsart und Breite abspielen),
/// `addfav=1` (aktuelle Frequenz merken), `delfav=<id>`. Die Liste zeigt die
/// Einträge fürs Radio (Seite Radio oder ohne Seite); bearbeitet wird am Mac.
/// Abgestimmt wird nur, solange der HackRF dem Radio gehört (`ownsDevice`) –
/// sonst verstellte das Handy den Strom eines anderen Empfängers.
@MainActor
enum RemoteRadioAPI {
    struct State: Encodable {
        struct Favorite: Encodable {
            /// UUID des Eintrags im Frequenzspeicher.
            let id: String; let mhz: Double; let mode: String; let kind: String?; let name: String?
        }
        struct Band: Encodable {
            let i: Int; let name: String; let range: String; let mode: String
        }
        struct Station: Encodable {
            let mhz: Double; let db: Double; let name: String?; let spur: Bool
        }
        let running: Bool
        /// Aus der Ferne eingeschaltet.
        let remote: Bool
        /// Der HackRF empfängt gerade für das Radio (Abstimmen möglich).
        let owned: Bool
        let mhz: Double
        let mode: String
        let stepKHz: Double
        /// Filterbreite in Hz (`nil` bei UKW: fest).
        let bandwidth: Double?
        /// Wählbare Filterbreiten der Betriebsart (Hz).
        let bandwidths: [Double]
        let squelch: Double
        let squelchOpen: Bool
        let aboveFloor: Double?
        let signalDB: Double?
        let rdsName: String?
        let rdsText: String?
        let programType: String?
        let stereo: Bool
        let localMuted: Bool
        let favorites: [Favorite]
        let scanning: Bool
        let scanProgress: Double
        let scanStatus: String
        let scanBand: String?
        /// Betriebsart der Suchlauf-Ergebnisse (zum Abspielen einer Fundstelle).
        let scanMode: String?
        let stations: [Station]
        /// Bänder für den Suchlauf (wie „Schnellwahl mit Suchlauf“ am Mac).
        let bands: [Band]
        /// Antwort auf die gerade ausgeführte Aktion (z. B. „Radio läuft nicht“).
        let notice: String?
        let error: String?
    }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let memory = FrequencyMemory.shared
        let model = hub.radio
        var notice: String?
        if query["scancancel"] == "1" { model.cancelScan() }
        let band = query["scan"].flatMap(Int.init).flatMap { ScanBands.all.indices.contains($0) ? ScanBands.all[$0] : nil }
        let wantsTune = query["f"] != nil || query["step"] != nil || query["fav"] != nil
        if (band != nil || wantsTune) && !model.ownsDevice {
            // Ein Tippen genügt: erst auf Radio umschalten (wie das Banner), dann
            // abstimmen bzw. suchen – im Hintergrund, die Seite fragt ohnehin nach.
            notice = String(localized: "Schalte auf Radio um …")
            var tuneQuery = query
            tuneQuery["scan"] = nil; tuneQuery["scancancel"] = nil
            if let band { model.mode = band.mode }
            Task {
                if let error = await hub.activate(.radio) { RemoteRadioAPI.log.error("\(error, privacy: .public)"); return }
                if let band { model.scan(band) } else { apply(tuneQuery, model: model, memory: memory) }
            }
            // Nur Betriebsart/Rauschsperre/Favoriten-Pflege jetzt anwenden.
            var rest = query
            for key in ["f", "step", "fav", "scan", "scancancel"] { rest[key] = nil }
            apply(rest, model: model, memory: memory)
        } else {
            if let band {
                if model.scanning { notice = String(localized: "Ein Suchlauf läuft schon.") } else { model.scan(band) }
            }
            notice = apply(query, model: model, memory: memory) ?? notice
        }
        return encode(state(model, remote: hub.remoteMode == .radio, notice: notice, memory: memory))
    }

    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Fernzugriff")

    static func encode(_ state: State) -> Data {
        (try? JSONEncoder().encode(state)) ?? Data("{}".utf8)
    }

    // MARK: - Aktionen

    /// Führt die Aktionen aus; liefert einen Hinweis, wenn etwas nicht ging.
    @discardableResult
    static func apply(_ query: [String: String], model: RadioModel, memory: FrequencyMemory) -> String? {
        var notice: String?
        // Betriebsart und Rauschsperre betreffen nur den Demodulator – auch ohne Empfang erlaubt.
        if let mode = query["mode"].flatMap(mode(fromKey:)), mode != model.mode {
            model.mode = mode
            model.stepKHz = mode.defaultStepKHz
        }
        // Filterbreite: nur genau eine der Breiten der (neuen) Betriebsart.
        if let raw = query["bw"] {
            if let hz = bandwidth(raw, for: model.mode) {
                model.bandwidthHz = hz
            } else {
                notice = String(localized: "Diese Filterbreite gibt es für \(model.mode.shortTitle) nicht.")
            }
        }
        if let value = number(query["squelch"]) {
            model.squelchDB = clampedSquelch(value)
        }
        if let id = query["delfav"].flatMap(UUID.init(uuidString:)) {
            memory.remove(ids: [id])
        }
        if query["addfav"] == "1", memory.entry(atMHz: model.frequencyMHz, page: .radio) == nil {
            let mhz = RadioFavorite.rounded(model.frequencyMHz)
            memory.add(memoryEntry(mhz, mode: model.mode, stepKHz: model.stepKHz, scannedBand: model.scannedBand, bandwidthHz: model.bandwidthHz,
                                   stationName: model.mode == .wfm ? model.stationName(at: mhz) : nil))
        }
        // Abstimmen: nur mit Gerätebesitz und nicht während des Suchlaufs.
        let wantsTune = query["f"] != nil || query["step"] != nil || query["fav"] != nil
        if wantsTune {
            if !model.ownsDevice {
                notice = String(localized: "Das Radio empfängt gerade nicht – erst auf Radio umschalten.")
            } else if model.scanning {
                notice = String(localized: "Der Suchlauf läuft noch – danach abstimmen.")
            } else if let raw = query["fav"] {
                if let favorite = UUID(uuidString: raw).flatMap(memory.entry(id:)) {
                    let mode = favorite.radioMode ?? FrequencyMemory.suggestedRadioMode(mhz: favorite.mhz)
                    model.select(mode: mode, bandwidthHz: favorite.bandwidthHz.map(Double.init))
                    model.stepKHz = favorite.stepKHz ?? mode.defaultStepKHz
                    model.tune(to: clampedMHz(favorite.mhz))
                } else {
                    notice = String(localized: "Diesen Favoriten gibt es nicht mehr.")
                }
            } else if let mhz = number(query["f"]) {
                model.tune(to: clampedMHz(mhz))
            } else if let step = number(query["step"]) {
                let direction = min(max(step.rounded(), -10), 10)
                if direction != 0 { model.step(direction) }
            } else {
                notice = String(localized: "Ungültige Frequenz.")
            }
        }
        return notice
    }

    /// Endliche Zahl aus dem Parameter (Komma wie Punkt), sonst `nil`.
    nonisolated static func number(_ text: String?) -> Double? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        return value
    }

    nonisolated static func rangeText(_ band: ScanBand) -> String {
        func f(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...3)).locale(RemotePage.locale)) }
        return "\(f(band.startMHz))–\(f(band.endMHz)) MHz"
    }

    nonisolated static func clampedMHz(_ mhz: Double) -> Double { min(max(mhz, 1.24), 6000) }
    nonisolated static func clampedSquelch(_ db: Double) -> Double { min(max(db.rounded(), 0), 20) }

    nonisolated static func mode(fromKey key: String) -> RadioMode? {
        switch key.lowercased() {
        case "wfm": .wfm
        case "nfm": .nfm
        case "am": .am
        case "usb": .usb
        case "lsb": .lsb
        case "cw": .cw
        default: nil
        }
    }

    /// Filterbreite aus dem Parameter, wenn sie zur Betriebsart gehört (sonst `nil`).
    nonisolated static func bandwidth(_ text: String, for mode: RadioMode) -> Double? {
        guard let hz = number(text), mode.bandwidthOptionsHz.contains(hz) else { return nil }
        return hz
    }

    nonisolated static func key(_ mode: RadioMode) -> String {
        switch mode {
        case .wfm: "wfm"
        case .nfm: "nfm"
        case .am: "am"
        case .usb: "usb"
        case .lsb: "lsb"
        case .cw: "cw"
        }
    }

    /// Neuer Eintrag fürs Radio (Stern am Mac, „☆ Merken“ auf dem Handy): Betriebsart,
    /// Schritt und Funkart – der rohe Bandname, nicht übersetzt.
    nonisolated static func memoryEntry(_ mhz: Double, mode: RadioMode, stepKHz: Double, scannedBand: ScanBand?,
                                        bandwidthHz: Double = 0, stationName: String? = nil) -> FrequencyMemoryEntry {
        let current = RadioFavorite.rounded(mhz)
        let kind = scannedBand.flatMap { $0.startMHz <= current && current <= $0.endMHz ? $0.name : nil }
            ?? RadioFavorite.kind(at: current)
        var entry = FrequencyMemoryEntry(mhz: current, name: stationName ?? "", mode: mode.rawValue, page: .radio)
        entry.stepKHz = stepKHz
        entry.kind = kind
        // Nur eine von der Vorgabe abweichende Filterbreite merken.
        if let width = mode.validBandwidth(bandwidthHz), width != mode.defaultBandwidthHz { entry.bandwidthHz = Int(width) }
        return entry
    }

    // MARK: - Zustand

    static func state(_ model: RadioModel, remote: Bool, notice: String? = nil, memory: FrequencyMemory) -> State {
        func finite(_ value: Float) -> Double? { value.isFinite ? (Double(value) * 10).rounded() / 10 : nil }
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        let live = model.running && model.mode == .wfm
        let favorites = memory.entries(for: .radio).sorted { $0.frequencyHz < $1.frequencyHz }
        return State(
            running: model.running, remote: remote, owned: model.ownsDevice,
            mhz: (model.frequencyMHz * 100_000).rounded() / 100_000, mode: key(model.mode), stepKHz: model.stepKHz,
            bandwidth: model.mode.validBandwidth(model.bandwidthHz), bandwidths: model.mode.bandwidthOptionsHz,
            squelch: model.squelchDB, squelchOpen: model.squelchOpen,
            aboveFloor: model.running && model.mode.usesSquelch ? finite(model.channelAboveFloorDB) : nil,
            signalDB: model.running ? finite(model.signalDB) : nil,
            // Vollständiger RDS-Name, sonst der gelernte, sonst die ersten Zeichen.
            rdsName: model.mode != .wfm ? nil
                : (live ? StationNames.complete(model.rds) : nil) ?? model.stationName(at: model.frequencyMHz)
                    ?? (live ? text(model.rds.programServiceText) : nil),
            rdsText: live ? text(model.rds.radioTextString) : nil,
            programType: live ? model.rds.programTypeName : nil,
            stereo: live && model.stereo && model.pilotLocked,
            localMuted: model.localMuted,
            favorites: favorites.prefix(300).map { entry in
                let mode = entry.radioMode ?? FrequencyMemory.suggestedRadioMode(mhz: entry.mhz)
                return .init(id: entry.id.uuidString, mhz: (entry.mhz * 10000).rounded() / 10000, mode: key(mode),
                             kind: entry.group.isEmpty ? entry.kind : entry.group,
                             name: entry.name.isEmpty ? (mode == .wfm ? model.stationName(at: entry.mhz) : nil) : entry.name)
            },
            scanning: model.scanning, scanProgress: model.scanProgress.isFinite ? model.scanProgress : 0,
            scanStatus: model.scanStatus, scanBand: model.scannedBand?.name, scanMode: model.scannedBand.map { key($0.mode) },
            stations: model.stations.prefix(80).map {
                .init(mhz: $0.mhz, db: finite($0.levelDB) ?? -100,
                      name: model.scannedBand?.mode == .wfm ? model.stationName(at: $0.mhz) : nil, spur: $0.possiblySpur)
            },
            bands: ScanBands.all.enumerated().map { i, b in
                .init(i: i, name: b.name, range: rangeText(b), mode: key(b.mode))
            },
            notice: notice, error: model.error)
    }
}
