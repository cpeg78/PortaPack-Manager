import Foundation

/// Reiter „Flugfunk“ des Fernzugriffs (`/api/airband`): Kanalliste mit Pegeln,
/// letzte Sprüche, Funde des Suchlaufs und Bedienung. Der Ton kommt über den
/// gemeinsamen Strom `/audio.aac`.
@MainActor
enum RemoteAirband {
    struct State: Encodable {
        struct Channel: Encodable {
            let i: Int; let ch: String; let mhz: Double; let name: String
            let prio: Bool; let locked: Bool; let excess: Double?; let open: Bool; let inWindow: Bool
        }
        struct Transmission: Encodable {
            let t: Double; let ch: String; let name: String; let dur: Double; let peak: Double
            /// Abschrift (aufbereitet), Rohtext, Zuversicht 0…1, erkanntes Rufzeichen.
            /// Die Seite zeigt alles nur über `esc()` – Funktext ist fremder Inhalt.
            var text: String? = nil; var raw: String? = nil; var conf: Double? = nil; var cs: String? = nil
        }
        struct Finding: Encodable {
            let i: Int; let ch: String; let tx: Int; let openSec: Int; let peak: Double; let inList: Bool; let cont: Bool
        }
        let running: Bool
        let remote: Bool
        let centerMHz: Double
        let squelch: Double
        let audible: Int?
        let hold: Int?
        let transmissions: Int
        let channels: [Channel]
        let history: [Transmission]
        let finding: Bool
        let findProgress: Double
        let findStatus: String
        let findings: [Finding]
        let error: String?
    }

    /// Wendet Aktionen an und liefert den Zustand.
    /// `add=<Kanal/MHz>&name=…`, `remove=<i>`, `hold=<i>|0`, `prio=<i>`, `lock=<i>`,
    /// `squelch=<dB>`, `find=start|stop` (`min=`, `dwell=`), `addfound=<i>`.
    /// Wie `handle`, schaltet aber für den Suchlauf selbst auf Flugfunk um, wenn er
    /// nicht läuft (ein Tipp genügt, wie beim Radio).
    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let model = hub.airband
        if query["find"] == "start", !model.running {
            var rest = query
            rest["find"] = nil
            let minutes = query["min"], dwell = query["dwell"]
            Task {
                guard await hub.activate(.airband) == nil else { return }
                _ = handle(["find": "start", "min": minutes ?? "15", "dwell": dwell ?? "30"], model: model, remote: true)
            }
            return handle(rest, model: model, remote: true)
        }
        return handle(query, model: model, remote: hub.remoteMode == .airband)
    }

    /// `hold=`: leer oder negativ löst das Halten, ein Rasterindex hält diesen Kanal –
    /// auch 0 (118,000 MHz), das früher „lösen“ hieß. Alles andere wird ignoriert (`nil`).
    struct HoldAction: Equatable { var index: Int? }
    nonisolated static func holdAction(_ raw: String) -> HoldAction? {
        if raw.isEmpty { return HoldAction(index: nil) }
        guard let value = Int(raw) else { return nil }
        if value < 0 { return HoldAction(index: nil) }
        return AirbandGrid.range.contains(value) ? HoldAction(index: value) : nil
    }

    static func handle(_ query: [String: String], model: AirbandModel, remote: Bool) -> Data {
        func index(_ key: String) -> Int? { query[key].flatMap(Int.init) }
        if let text = query["add"], let i = AirbandGrid.index(parsing: text) {
            model.addChannel(index: i, name: String((query["name"] ?? "").prefix(40)))
        }
        if let i = index("addfound") { model.addChannel(index: i, name: "") }
        if let i = index("remove") { model.removeChannel(i) }
        if let i = index("prio") { model.togglePriority(i) }
        if let i = index("lock") { model.toggleLocked(i) }
        if let raw = query["hold"], let hold = holdAction(raw) { model.setHold(hold.index) }
        if let value = query["squelch"].flatMap(Double.init), value.isFinite {
            model.squelchDB = min(max(value.rounded(), 3), 20)
        }
        switch query["find"] {
        case "start":
            let minutes = query["min"].flatMap(Double.init).flatMap { $0.isFinite ? min(max($0, 1), 120) : nil } ?? 15
            let dwell = query["dwell"].flatMap(Double.init).flatMap { $0.isFinite ? min(max($0, 10), 300) : nil } ?? 30
            model.findActiveChannels(minutes: minutes, dwell: dwell)
        case "stop": model.cancelFind()
        default: break
        }
        return (try? JSONEncoder().encode(state(model, remote: remote))) ?? Data("{}".utf8)
    }

    static func state(_ model: AirbandModel, remote: Bool) -> State {
        func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        func finite(_ value: Float?) -> Double? { value.flatMap { $0.isFinite ? (Double($0) * 10).rounded() / 10 : nil } }
        let listed = Set(model.channels.map(\.index))
        let names = Dictionary(model.channels.map { ($0.index, $0.name) }, uniquingKeysWith: { a, _ in a })
        return State(
            running: model.running, remote: remote,
            centerMHz: AirbandGrid.mhz(model.window.center), squelch: model.squelchDB,
            audible: model.audible, hold: model.hold, transmissions: model.transmissionCount,
            channels: model.channels.map {
                .init(i: $0.index, ch: $0.channelName, mhz: $0.mhz, name: $0.name, prio: $0.priority, locked: $0.locked,
                      excess: finite(model.channelExcess[$0.index]), open: model.channelOpen.contains($0.index),
                      inWindow: model.window.covers($0.index))
            },
            history: model.history.prefix(60).map { transmission($0, name: names[$0.index] ?? $0.name) },
            finding: model.finding, findProgress: model.findProgress, findStatus: model.findStatus,
            findings: model.findings.sorted { $0.activity.transmissions > $1.activity.transmissions }.prefix(40).map {
                .init(i: $0.index, ch: AirbandGrid.channelName($0.index), tx: $0.activity.transmissions,
                      openSec: Int($0.activity.openSeconds.isFinite ? $0.activity.openSeconds : 0),
                      peak: finite($0.activity.peakDB) ?? 0, inList: listed.contains($0.index),
                      cont: $0.activity.looksContinuous)
            },
            error: model.error)
    }

    nonisolated static func transmission(_ item: AirbandTransmission, name: String) -> State.Transmission {
        let confidence = item.transcriptConfidence.flatMap { $0.isFinite ? ($0 * 100).rounded() / 100 : nil }
        return State.Transmission(
            t: (item.start.timeIntervalSince1970 * 1000).rounded(), ch: AirbandGrid.channelName(item.index), name: name,
            dur: item.duration.isFinite ? (item.duration * 10).rounded() / 10 : 0,
            peak: item.peakDB.isFinite ? (Double(item.peakDB) * 10).rounded() / 10 : 0,
            text: item.transcript.map { AirbandTranscriptFormatter.format($0) }, raw: item.transcript,
            conf: confidence, cs: item.callsign)
    }

    struct SearchResult: Encodable {
        let q: String
        let results: [State.Transmission]
    }

    /// `/api/airband/search?q=…`: Volltextsuche in den Abschriften (höchstens 100 Treffer).
    static func search(_ query: [String: String], model: AirbandModel) async -> Data {
        let text = String((query["q"] ?? "").prefix(100))
        let found = text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : await model.search(text)
        let result = SearchResult(q: text, results: found.prefix(100).map { transmission($0, name: $0.name) })
        return (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
    }
}
