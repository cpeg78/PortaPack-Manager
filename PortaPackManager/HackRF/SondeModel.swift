import Foundation
import Observation
import os

/// Eine verfolgte Radiosonde mit Flugbahn.
struct Sonde: Identifiable, Sendable, Equatable {
    struct Point: Sendable, Equatable {
        var lat: Double
        var lon: Double
        var alt: Double
        var date: Date
    }

    var id: String
    var latest: SondeReport
    var trail: [Point] = []
    var frames = 0
    var firstSeen: Date
    var lastSeen: Date
    var maxAltitude: Double = 0

    var serial: String { latest.serial.isEmpty ? "unbekannt" : latest.serial }
    var latitude: Double? { latest.latitude }
    var longitude: Double? { latest.longitude }

    /// Geplatzt: deutlich unter der Gipfelhöhe und am Sinken.
    var burst: Bool {
        guard let alt = latest.altitude, let v = latest.verticalSpeed else { return false }
        return maxAltitude > 5000 && alt < maxAltitude - 300 && v < -2
    }

    /// Erlaubte Bodenhöhe (m): vom Toten Meer bis über den Himalaya. Das Feld
    /// auf der Sondenseite ist frei – eine Eingabe wie −1 000 000 lief sonst durch.
    static let groundAltitudeRange = -500.0...9000.0

    static func clampedGroundAltitude(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value, groundAltitudeRange.lowerBound), groundAltitudeRange.upperBound)
    }

    /// Grobe Landeschätzung im Sinkflug. Die Sinkrate am Fallschirm wächst
    /// mit 1/√Luftdichte; mit Skalenhöhe H ≈ 7,6 km ergibt sich die Restzeit
    /// t = 2H/v·(e^((h−h₀)/2H) − 1). Die Abdrift rechnet mit dem aktuellen
    /// Wind weiter – Wind in Bodennähe kennt die Sonde noch nicht.
    func landing(groundAltitude: Double) -> (lat: Double, lon: Double, seconds: Double)? {
        let groundAltitude = Self.clampedGroundAltitude(groundAltitude)
        guard let lat = latest.latitude, let lon = latest.longitude, let alt = latest.altitude,
              let v = latest.verticalSpeed, v < -2, alt > groundAltitude + 50 else { return nil }
        let scaleHeight = 7600.0
        let sink = -v
        let seconds = 2 * scaleHeight / sink * (exp((alt - groundAltitude) / (2 * scaleHeight)) - 1)
        // Unsinnige Höhen (Fehleingabe, verstümmelter Rahmen) ergaben Restzeiten
        // jenseits von `Int.max` – `/api/sondes` stürzte dann ab (Review 29.10.2026).
        // Kein Sinkflug dauert einen Tag.
        guard seconds.isFinite, seconds < 86_400 else { return nil }
        guard let speed = latest.groundSpeed, let heading = latest.heading else {
            return (lat, lon, seconds)
        }
        // Mittlere Höhe des restlichen Fluges ist niedriger, der Wind dort
        // meist schwächer; ohne bessere Daten bleibt es beim aktuellen Wert.
        let distance = speed * seconds
        let north = distance * cos(heading * .pi / 180)
        let east = distance * sin(heading * .pi / 180)
        let dLat = north / 111_320
        let dLon = east / (111_320 * cos(lat * .pi / 180))
        return (lat + dLat, lon + dLon, seconds)
    }
}

/// Sammelt Meldungen zu Sonden (nach Seriennummer, sonst nach Frequenz).
struct SondeTracker {
    private(set) var sondes: [String: Sonde] = [:]

    mutating func ingest(_ report: SondeReport, at date: Date = Date()) {
        let key = report.serial.isEmpty
            ? "\(report.kind.rawValue) \(String(format: "%.3f", report.frequency / 1e6))"
            : "\(report.kind.rawValue) \(report.serial)"
        var sonde = sondes[key] ?? Sonde(id: key, latest: report, firstSeen: date, lastSeen: date)
        // Fehlende Felder aus der vorigen Meldung übernehmen.
        var merged = report
        let old = sonde.latest
        if merged.temperature == nil { merged.temperature = old.temperature }
        if merged.humidity == nil { merged.humidity = old.humidity }
        if merged.gpsTime == nil { merged.gpsTime = old.gpsTime }
        if merged.latitude == nil {
            merged.latitude = old.latitude; merged.longitude = old.longitude; merged.altitude = old.altitude
            merged.groundSpeed = old.groundSpeed; merged.heading = old.heading; merged.verticalSpeed = old.verticalSpeed
        }
        sonde.latest = merged
        sonde.frames += 1
        sonde.lastSeen = date
        if let lat = report.latitude, let lon = report.longitude, let alt = report.altitude {
            sonde.maxAltitude = max(sonde.maxAltitude, alt)
            let point = Sonde.Point(lat: lat, lon: lon, alt: alt, date: date)
            if sonde.trail.last.map({ $0.lat != lat || $0.lon != lon || $0.alt != alt }) ?? true {
                sonde.trail.append(point)
                if sonde.trail.count > 20_000 { sonde.trail.removeFirst(sonde.trail.count - 20_000) }
            }
        }
        sondes[key] = sonde
        // Seriennummern kommen aus der Luft; Spuren sind groß (bis 20 000 Punkte) – begrenzen.
        DevicePruning.prune(&sondes, limit: 200, maxAge: 6 * 3600, now: date) { $0.lastSeen }
    }

    var sorted: [Sonde] { sondes.values.sorted { $0.lastSeen > $1.lastSeen } }
}

/// Radiosonden-Empfang im HackRF-Modus: ganzes Band 400–406 MHz.
@MainActor
@Observable
final class SondeModel {
    // Verstärkung bleibt gespeichert (je mit/ohne externen Vorverstärker) und
    // wirkt sofort – auch aus der Ferne (`/api/plan?slna=&svga=`).
    var lnaGain = SondeModel.storedGain("lna") ?? GainProfile.preset(.sonde).lna { didSet { gainsChanged("lna", lnaGain) } }
    var vgaGain = SondeModel.storedGain("vga") ?? GainProfile.preset(.sonde).vga { didSet { gainsChanged("vga", vgaGain) } }
    var amplifier = GainProfile.preset(.sonde).amplifier
    var antennaPower = false
    /// Nimmt die Verstärkung bei Übersteuerung von selbst zurück (nie hoch).
    /// Folgt seit dem Bedienungs-Umbau (29.10.2026) dem einen Schalter
    /// „Verstärkung automatisch nachregeln“ (`AutoGain.enabled`) – vorher gab
    /// es einen eigenen Sondenschalter. Die Regelung selbst bleibt hier
    /// (`backOffIfClipping`), `AutoGain` nimmt Sonden weiter aus.
    var autoBackoff: Bool {
        get { AutoGain.shared.enabled }
        set { AutoGain.shared.enabled = newValue }
    }
    /// Letzte automatische Rücknahme, z. B. „LNA 32 → 24 (0,4 % am Anschlag, 12:34)“.
    private(set) var gainNote: String?

    private(set) var running = false
    private(set) var sondes: [Sonde] = []
    private(set) var channels: [SondeReceiver.Channel] = []
    private(set) var reportCount = 0
    private(set) var error: String?
    /// Solange gesetzt, landet jede Meldung im Sondenarchiv, vermerkt mit diesem
    /// Empfangsfenster (Empfangsplan, z. B. „2026-10-28_1145“).
    var logWindow: String?

    private let shared = Shared()
    private var updateTask: Task<Void, Never>?
    private weak var device: HackRFDevice?
    private var lastGainChange = Date.distantPast
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Radiosonden")
    /// Ab hier gilt der Wandler als übersteuert (wie die Warnung der Pegelanzeige).
    static let clipLimit = 0.001
    /// Fest beobachtete Frequenzen in Hz – überdauern Stopp und Start.
    private var pinned: Set<Double> = []
    /// Frequenzen, die SondeHub für Sonden in Reichweite meldet (Empfangsplan).
    private var hinted: Set<Double> = []

    private final class Shared: @unchecked Sendable {
        let receiver = SondeReceiver()
        var tracker = SondeTracker()
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            shared.receiver.reset()
            for frequency in pinned.union(hinted) { shared.receiver.pin(frequency) }
            try device.setSampleRate(SondeReceiver.sampleRate)
            try device.setFrequency(SondeReceiver.centerFrequency)
            try applyGains(to: device)
            let receiver = shared.receiver
            try device.startReceiving(owner: self) { block in receiver.process(block) }
            self.device = device
            lastGainChange = Date()
            running = true
            error = nil
            updateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let reports = self.shared.receiver.takeReports()
                    for report in reports { self.shared.tracker.ingest(report) }
                    if let window = self.logWindow, !reports.isEmpty { SondeLog.append(reports, window: window) }
                    if !reports.isEmpty { SondeHubUploader.shared.enqueue(reports) }
                    self.reportCount += reports.count
                    if !reports.isEmpty {
                        self.sondes = self.shared.tracker.sorted
                        Self.reportToMQTT(self.sondes, reports: reports)
                    }
                    self.channels = self.shared.receiver.activeChannels
                    self.backOffIfClipping()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sonden mit neuen Rahmen an Home Assistant (nur wenn dort eingeschaltet).
    private static func reportToMQTT(_ sondes: [Sonde], reports: [SondeReport]) {
        let bridge = MQTTBridge.shared
        guard bridge.isEnabled(.sondes) else { return }
        let serials = Set(reports.map(\.serial))
        for sonde in sondes where serials.contains(sonde.latest.serial) && !sonde.latest.encrypted {
            bridge.report(source: .sondes, deviceID: MQTTFeeds.deviceID(of: sonde), name: "Radiosonde \(sonde.serial)",
                          model: MQTTFeeds.model(of: sonde), manufacturer: MQTTFeeds.manufacturer(of: sonde),
                          values: MQTTFeeds.values(of: sonde), seen: sonde.lastSeen)
        }
    }

    func stop(on device: HackRFDevice?) {
        updateTask?.cancel()
        updateTask = nil
        device?.stopReceiving(owner: self)
        self.device = nil
        running = false
    }

    /// Pegel am Wandler, solange dieser Empfang läuft.
    var inputLevels: HackRFDevice.InputLevels? {
        guard running, let device, device.isReceiving(for: self) else { return nil }
        return device.inputLevels
    }

    /// Schalter „Externer Vorverstärker“ umgelegt: die gespeicherten Werte der
    /// neuen Einstellung laden (sonst schrieb die nächste Änderung die alten
    /// Werte unter dem neuen Schlüssel fest).
    func reloadGains() {
        let preset = GainProfile.preset(.sonde)
        lnaGain = Self.storedGain("lna") ?? preset.lna
        vgaGain = Self.storedGain("vga") ?? preset.vga
        amplifier = preset.amplifier
        if running, let device, device.isReceiving(for: self) { try? applyGains(to: device) }
    }

    private static func gainKey(_ name: String) -> String {
        "sondeGain.\(GainProfile.externalAmplifier ? "ext" : "std").\(name)"
    }

    private static func storedGain(_ name: String) -> Double? {
        // Nur endliche Werte – NaN trappt bei `Int(lnaGain)`.
        (UserDefaults.standard.object(forKey: gainKey(name)) as? Double).flatMap { $0.isFinite ? $0 : nil }
    }

    private func gainsChanged(_ name: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: Self.gainKey(name))
        lastGainChange = Date()
        guard running, let device, device.isReceiving(for: self) else { return }
        try? applyGains(to: device)
    }

    /// Übersteuert der Wandler (geglättet, ≥ 10 s nach der letzten Änderung),
    /// erst den internen Vorverstärker, dann LNA, zuletzt VGA zurücknehmen.
    /// Mischprodukte starker Sender kosten mehr als die fehlende Verstärkung.
    private func backOffIfClipping() {
        guard autoBackoff, running, let device, device.isReceiving(for: self),
              Date().timeIntervalSince(lastGainChange) >= 10 else { return }
        let clipped = device.clippedFraction
        guard clipped > Self.clipLimit else { return }
        let before = "LNA \(Int(lnaGain))/VGA \(Int(vgaGain))"
        if amplifier {
            amplifier = false
            try? applyGains(to: device)
            lastGainChange = Date()
        } else if lnaGain > 8 {
            lnaGain -= 8
        } else if vgaGain > 10 {
            vgaGain -= 6
        } else {
            return
        }
        let percent = (clipped * 100).formatted(.number.precision(.fractionLength(1)))
        gainNote = "\(before) → LNA \(Int(lnaGain))/VGA \(Int(vgaGain)) (\(percent) % am Anschlag, \(Date().formatted(date: .omitted, time: .shortened)))"
        Self.log.notice("Übersteuert, zurückgenommen: \(self.gainNote ?? "", privacy: .public)")
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    /// Frequenz in MHz fest beobachten (z. B. aus einer Sondenliste im Netz).
    func pin(mhz: Double) {
        let hz = (mhz * 1000).rounded() * 1000
        pinned.insert(hz)
        shared.receiver.pin(hz)
        channels = shared.receiver.activeChannels
    }

    /// Hält Kanäle auf den gemeldeten Frequenzen (MHz) fest – auch unter der
    /// Erkennungsschwelle und ohne Verdrängung. Live 26.10.2026: zwei RS41 in
    /// 80–115 km kamen nur abwechselnd und zu 5–27 % der Rahmen an.
    func follow(mhz: [Double]) {
        // SondeHub meldet je Empfänger leicht andere Frequenzen (404,50025 /
        // 404,503) – ein Wechsel um wenige kHz darf den Kanal nicht neu
        // anlegen, sonst verliert er alle 2 min Takt und Kalibrierung.
        let wanted = Set(mhz.map { value -> Double in
            let hz = (value * 1000).rounded() * 1000
            return hinted.first { abs($0 - hz) <= 5000 } ?? hz
        })
        guard wanted != hinted else { return }
        for hz in hinted.subtracting(wanted) where !pinned.contains(hz) { shared.receiver.unpin(hz) }
        for hz in wanted.subtracting(hinted) { shared.receiver.pin(hz) }
        hinted = wanted
        channels = shared.receiver.activeChannels
    }

    func unpin(_ channel: SondeReceiver.Channel) {
        pinned.remove(channel.frequency)
        shared.receiver.unpin(channel.frequency)
        channels = shared.receiver.activeChannels
    }

    func clear() {
        shared.tracker = SondeTracker()
        sondes = []
        reportCount = 0
    }
}

/// Meldungsprotokoll: jede dekodierte Meldung als Zeile in der Archiv-Datenbank
/// (`sonde_samples`). Bis 29.10.2026 eine CSV-Datei je Empfangsfenster im Ordner
/// „Radiosonden“; das CSV-Format (`header`, `line`) bleibt für den Export.
enum SondeLog {
    static let header = "empfangen;typ;seriennummer;rahmen;frequenz_mhz;breite;laenge;hoehe_m;steigen_ms;wind_ms;kurs;temperatur;feuchte;batterie_v\n"

    static func line(_ r: SondeReport, received: Date) -> String {
        func f(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "" }
        return [ISOTime.string(received), r.kind.rawValue, r.serial, r.frame.map(String.init) ?? "",
                String(format: "%.3f", r.frequency / 1e6), f(r.latitude, "%.5f"), f(r.longitude, "%.5f"),
                f(r.altitude, "%.0f"), f(r.verticalSpeed, "%.1f"), f(r.groundSpeed, "%.1f"), f(r.heading, "%.0f"),
                f(r.temperature, "%.1f"), f(r.humidity, "%.0f"), f(r.batteryVolts, "%.1f")]
            .joined(separator: ";") + "\n"
    }

    /// Eine Meldung als Archivzeile – mit denselben Rundungen wie die CSV-Zeile,
    /// damit alte Protokolle und neue Meldungen gleich aussehen.
    static func row(_ r: SondeReport, received: Date) -> SondeArchive.Row {
        func rounded(_ value: Double?, _ digits: Double) -> Double? { value.map { ($0 * digits).rounded() / digits } }
        return SondeArchive.Row(serial: r.serial, type: r.kind.rawValue, frame: r.frame, sample: SondeSample(
            date: Date(timeIntervalSince1970: received.timeIntervalSince1970.rounded(.down)),
            frequencyMHz: rounded(r.frequency / 1e6, 1000), latitude: rounded(r.latitude, 1e5), longitude: rounded(r.longitude, 1e5),
            altitude: rounded(r.altitude, 1), verticalSpeed: rounded(r.verticalSpeed, 10), windSpeed: rounded(r.groundSpeed, 10),
            heading: rounded(r.heading, 1), temperature: rounded(r.temperature, 10), humidity: rounded(r.humidity, 1),
            battery: rounded(r.batteryVolts, 10)))
    }

    /// Hängt Meldungen an (Schreiben abseits des Main Actors, eine Transaktion).
    static func append(_ reports: [SondeReport], window: String, received: Date = Date(),
                       database: ArchiveDatabase = .shared) {
        let rows = reports.filter { !$0.serial.isEmpty }.map { row($0, received: received) }
        guard !rows.isEmpty else { return }
        database.write("Sondenmeldungen sichern") { try $0.insertSondeRows(rows, window: window) }
    }
}
