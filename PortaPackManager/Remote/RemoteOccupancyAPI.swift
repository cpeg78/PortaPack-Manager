import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reiter „Belegungsmonitor“ des Fernzugriffs.
///
/// `/api/occupancy` liefert Zustand, Band, Vorlagen, Aufzeichnung und die
/// aktivsten Frequenzen; Aktionen:
/// - `preset=<id>` bzw. `start=<MHz>&end=<MHz>` – Band wählen,
/// - `fresh=1` – neue Aufzeichnung,
/// - `hours=<n>` – nur Lesen: Zeitraum des Wärmebilds für die Achsenbeschriftung.
///
/// Läuft der Monitor, gilt ein neues Band erst nach einem Neustart – den
/// macht die API selbst (Stopp, Band setzen, Start auf demselben Gerät), aber
/// nur, solange der Monitor das Gerät noch besitzt. Pausiert er, weil jemand
/// anderes übernommen hat, wird nur das Band gemerkt; „Fortsetzen“ ist das
/// Umschalten über `/api/mode?m=occupancy` (Banner der Seite).
///
/// `/occupancy.png?w=&h=&hours=` rendert das Wärmebild (neueste Zeile oben)
/// abseits des Main Actors mit `OccupancyHeatmapRenderer` und hält das
/// Ergebnis 20 s vor.
@MainActor
enum RemoteOccupancyAPI {
    struct State: Encodable {
        struct Preset: Encodable {
            let id: String; let name: String; let startMHz: Double; let endMHz: Double; let binKHz: Double
        }
        struct Recording: Encodable {
            let name: String
            let startMHz: Double
            let endMHz: Double
            let binKHz: Double
            let slices: Int
            /// Beginn der ersten / Ende der letzten Zeitscheibe (ms seit 1970).
            let first: Double?
            let last: Double?
            let seconds: Double
            /// Passt zu den Einstellungen – „Start“ setzt sie fort.
            let continues: Bool
        }
        /// Ausschnitt des Wärmebilds für `hours` (Achsenbeschriftung).
        struct View: Encodable {
            let hours: Double
            let t0: Double?
            let t1: Double?
            let rows: Int
        }
        struct Active: Encodable {
            let mhz: Double
            /// Belegung in Prozent.
            let occ: Double
            let peakDB: Double
            /// Ende des jüngsten aktiven Zeitraums (ms), `nil` ohne Zeitraum.
            let last: Double?
            let slices: Int
        }
        let running: Bool
        let paused: String?
        let error: String?
        let hint: String?
        let notice: String?
        let preset: String?
        let startMHz: Double
        let endMHz: Double
        let binKHz: Double
        let bins: Int
        let sliceSeconds: Double
        let thresholdDB: Double
        let windowMHz: Double?
        let rounds: Int
        let since: Double?
        let presets: [Preset]
        let recording: Recording?
        let view: View?
        let legend: String
        let active: [Active]
        let revision: Int
    }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let monitor = hub.occupancy
        let notice = apply(query, monitor: monitor, device: hub.session?.hackRF)
        let hours = hoursParameter(query["hours"])
        return (try? JSONEncoder().encode(state(monitor, hours: hours, notice: notice))) ?? Data("{}".utf8)
    }

    // MARK: Aktionen

    /// Wendet Bandwahl und „Neue Aufzeichnung“ an; liefert eine Meldung für die Seite.
    static func apply(_ query: [String: String], monitor: OccupancyMonitor, device: HackRFDevice?) -> String? {
        var change: (() -> Void)?
        var described: String?
        if let id = query["preset"] {
            guard let preset = OccupancyPreset.all.first(where: { $0.id == id }) else { return String(localized: "Unbekannte Vorlage.") }
            change = { monitor.apply(preset) }
            described = String(localized: "Band „\(preset.name)“ gewählt.")
        } else if query["start"] != nil || query["end"] != nil {
            guard let (s, e) = range(query["start"], query["end"]) else {
                return String(localized: "Ungültiger Bereich: Start < Ende, 1–6000 MHz, höchstens 1000 MHz breit.")
            }
            change = {
                monitor.startMHz = s
                monitor.endMHz = e
                monitor.presetName = OccupancyPreset.all.first { abs($0.startMHz - s) < 1e-6 && abs($0.endMHz - e) < 1e-6 }?.id
            }
            described = String(localized: "Bereich gewählt.")
        }
        let fresh = query["fresh"] == "1"
        guard change != nil || fresh else { return nil }
        if monitor.running {
            // Neustart nur mit dem Gerät, das der Monitor noch besitzt – nie zurückholen.
            guard let device, device.isReceiving(for: monitor) else {
                return String(localized: "Der Monitor gibt das Gerät gerade ab – bitte gleich noch einmal.")
            }
            monitor.stop()
            change?()
            monitor.start(on: device, fresh: fresh)
            if let error = monitor.error { return error }
            return (described.map { $0 + " " } ?? "") + (fresh || !monitor.canContinue ? String(localized: "Neue Aufzeichnung läuft.") : String(localized: "Läuft weiter."))
        }
        change?()
        if fresh {
            monitor.closeRecording()
            return String(localized: "Der nächste Start beginnt eine neue Aufzeichnung; die bisherige bleibt gespeichert.")
        }
        return described
    }

    /// Bereich wie auf der Mac-Seite: Start < Ende, 1…6000 MHz, höchstens 1000 MHz breit.
    static func range(_ start: String?, _ end: String?) -> (Double, Double)? {
        func number(_ text: String?) -> Double? {
            text.flatMap { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        }
        guard let s = number(start), let e = number(end), s.isFinite, e.isFinite, e > s,
              (1...6000).contains(s), (1...6000).contains(e), e - s <= 1000 else { return nil }
        return (s, e)
    }

    static func hoursParameter(_ text: String?) -> Double {
        guard let h = text.flatMap(Double.init), h.isFinite else { return 6 }
        return min(max(h, 0.25), 24 * 7)
    }

    // MARK: Zustand

    static func state(_ monitor: OccupancyMonitor, hours: Double = 6, notice: String? = nil, now: Date = Date()) -> State {
        func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        func fin(_ v: Double, _ digits: Double = 1000) -> Double { v.isFinite ? (v * digits).rounded() / digits : 0 }
        let plan = monitor.plan
        var recording: State.Recording?
        var view: State.View?
        if let rec = monitor.recording {
            let first = rec.slices.first?.start, last = rec.slices.last?.start.addingTimeInterval(rec.sliceSeconds)
            recording = .init(name: rec.name, startMHz: fin(rec.plan.startMHz, 1e6), endMHz: fin(rec.plan.endMHz, 1e6),
                              binKHz: fin(rec.plan.binKHz), slices: rec.slices.count,
                              first: first.map(ms), last: last.map(ms),
                              seconds: first.flatMap { f in last.map { fin($0.timeIntervalSince(f), 1) } } ?? 0,
                              continues: monitor.canContinue)
            let window = slices(rec, hours: hours, now: now)
            view = .init(hours: hours, t0: window.first.map { ms($0.start) },
                         t1: window.last.map { ms($0.start.addingTimeInterval(rec.sliceSeconds)) },
                         rows: OccupancyTimeline(slices: window, sliceSeconds: rec.sliceSeconds).count)
        }
        return State(
            running: monitor.running, paused: monitor.pausedReason, error: monitor.error,
            hint: monitor.settingsHint, notice: notice, preset: monitor.presetName,
            startMHz: fin(plan.startMHz, 1e6), endMHz: fin(plan.endMHz, 1e6), binKHz: fin(plan.binKHz),
            bins: plan.binCount, sliceSeconds: fin(monitor.sliceSeconds, 1), thresholdDB: fin(monitor.thresholdDB, 10),
            windowMHz: monitor.currentWindowMHz.map { fin($0) }, rounds: monitor.rounds,
            since: monitor.running ? monitor.startedAt.map(ms) : nil,
            presets: OccupancyPreset.all.map {
                .init(id: $0.id, name: $0.name, startMHz: $0.startMHz, endMHz: $0.endMHz, binKHz: $0.binKHz)
            },
            recording: recording, view: view, legend: OccupancyMetric.occupancy.legend,
            active: monitor.active.prefix(25).map {
                .init(mhz: fin($0.mhz, 1e5), occ: fin($0.occupancy * 100, 100), peakDB: fin(Double($0.peakAboveFloorDB), 10),
                      last: $0.episodes.first.map { ms($0.end) }, slices: $0.activeSlices)
            },
            revision: monitor.revision)
    }

    /// Scheiben, die in die letzten `hours` Stunden reichen.
    nonisolated static func slices(_ recording: OccupancyRecording, hours: Double, now: Date) -> [OccupancySlice] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let sliceSeconds = recording.sliceSeconds.isFinite ? recording.sliceSeconds : 60
        // Mindestens eine halbe Sekunde ins Fenster: Zeitstempel kommen gerundet aus
        // der Datei, eine Scheibe, die genau an der Grenze endet, zählte sonst je
        // nach Rundung mit (wackelnder Test „Zustand: Band …“, 61 statt 60 Zeilen).
        guard let index = recording.slices.firstIndex(where: { $0.start.addingTimeInterval(sliceSeconds) > cutoff.addingTimeInterval(0.5) }) else { return [] }
        return Array(recording.slices[index...])
    }

    // MARK: Wärmebild

    private struct CacheEntry {
        let key: String
        let made: Date
        let png: Data
    }
    private static var cache: [CacheEntry] = []
    private static var inFlight: [String: Task<Data?, Never>] = [:]
    static let cacheSeconds: TimeInterval = 20
    nonisolated static let maxSide = 1600

    /// Wärmebild als PNG.
    static func image(_ query: [String: String]) async -> RemoteHTTPServer.Response {
        let monitor = OccupancyMonitor.shared
        guard let rec = monitor.recording, !rec.slices.isEmpty else { return .text(404, String(localized: "Noch keine Aufzeichnung")) }
        func side(_ key: String, _ fallback: Int) -> Int {
            min(maxSide, max(32, query[key].flatMap(Int.init) ?? fallback))
        }
        let width = side("w", 800), height = side("h", 480)
        let hours = hoursParameter(query["hours"])
        let metric = query["m"].flatMap(OccupancyMetric.init(rawValue:)) ?? .occupancy
        let key = "\(width)x\(height)|\(hours)|\(metric.rawValue)|\(monitor.recordingURL?.lastPathComponent ?? "")|\(monitor.revision)"
        let now = Date()
        cache.removeAll { now.timeIntervalSince($0.made) > cacheSeconds }
        if let hit = cache.first(where: { $0.key == key }) { return png(hit.png) }
        let task: Task<Data?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                renderPNG(recording: rec, hours: hours, width: width, height: height, metric: metric, now: now)
            }
            inFlight[key] = task
        }
        let data = await task.value
        inFlight[key] = nil
        guard let data else { return .text(404, String(localized: "Keine Messungen in diesem Zeitraum")) }
        if !cache.contains(where: { $0.key == key }) {
            cache.append(.init(key: key, made: now, png: data))
            if cache.count > 6 { cache.removeFirst(cache.count - 6) }
        }
        return png(data)
    }

    private static func png(_ data: Data) -> RemoteHTTPServer.Response {
        .data(status: 200, contentType: "image/png", body: data)
    }

    /// Rendert die letzten `hours` Stunden (ganzes Band, neueste Zeile oben) als PNG.
    nonisolated static func renderPNG(recording: OccupancyRecording, hours: Double, width: Int, height: Int,
                                      metric: OccupancyMetric, now: Date) -> Data? {
        let window = slices(recording, hours: hours, now: now)
        guard !window.isEmpty else { return nil }
        let timeline = OccupancyTimeline(slices: window, sliceSeconds: recording.sliceSeconds)
        guard let image = OccupancyHeatmapRenderer.render(
            slices: window, timeline: timeline, binCount: recording.plan.binCount, metric: metric,
            lo: 0, hi: 1, rowOffset: 0, rowsVisible: Double(timeline.count),
            width: min(maxSide, max(1, width)), height: min(maxSide, max(1, height))) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
