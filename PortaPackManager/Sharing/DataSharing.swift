import Foundation
import Network
import Observation
import os

/// AIS-Weitergabe: jede dekodierte Meldung als NMEA-Satz (`!AIVDM`) per UDP
/// an die eingetragenen Ziele – so speisen AISHub, MarineTraffic und
/// VesselFinder ihre Stationen ein (Adresse und Port bekommt man dort bei der
/// Anmeldung). Wird vom Empfangsthread aus gerufen.
final class NMEAFeeder: @unchecked Sendable {
    static let shared = NMEAFeeder()
    static let enabledKey = "shareAISEnabled"
    static let targetsKey = "shareAISTargets"

    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.nmea")
    private var connections: [String: NWConnection] = [:]
    private var enabled = false
    private var sent = 0

    private init() {
        configure(enabled: UserDefaults.standard.bool(forKey: Self.enabledKey),
                  targets: UserDefaults.standard.string(forKey: Self.targetsKey) ?? "")
    }

    /// „host:port“, durch Komma, Leerzeichen oder Zeilen getrennt.
    static func parseTargets(_ text: String) -> [(host: String, port: UInt16)] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { item in
            guard let colon = item.lastIndex(of: ":"), let port = UInt16(item[item.index(after: colon)...]), port > 0
            else { return nil }
            let host = String(item[..<colon])
            return host.isEmpty ? nil : (host, port)
        }
    }

    func configure(enabled: Bool, targets: String) {
        let parsed = Self.parseTargets(targets)
        queue.async { [self] in
            self.enabled = enabled
            let wanted = Set(parsed.map { "\($0.host):\($0.port)" })
            for (key, connection) in connections where !wanted.contains(key) || !enabled {
                connection.cancel()
                connections.removeValue(forKey: key)
            }
            guard enabled else { return }
            for target in parsed where connections["\(target.host):\(target.port)"] == nil {
                let connection = NWConnection(host: .init(target.host), port: .init(rawValue: target.port)!, using: .udp)
                connection.start(queue: queue)
                connections["\(target.host):\(target.port)"] = connection
            }
        }
    }

    func send(_ sentences: [String]) {
        queue.async { [self] in
            guard enabled, !connections.isEmpty, !sentences.isEmpty else { return }
            let data = Data(sentences.map { $0 + "\r\n" }.joined().utf8)
            for connection in connections.values { connection.send(content: data, completion: .idempotent) }
            sent += sentences.count
        }
    }

    var sentCount: Int { queue.sync { sent } }
}

/// Beast-Binärformat (Mode-S Beast, wie dump1090/readsb auf Port 30005):
/// `1A`, Typ (`'2'` = Mode-S kurz, 7 Byte; `'3'` = Mode-S lang, 14 Byte),
/// 6 Byte MLAT-Zeitstempel (12-MHz-Zähler, big-endian), 1 Byte Pegel, dann die
/// Nachricht. Jedes `1A` hinter dem Kopf wird verdoppelt.
enum BeastFormat {
    /// Pegelbyte wie readsb: `round(√Leistung · 255)` = Amplitude · 255, ab
    /// einem Signal > 0 mindestens 1.
    static func signalByte(amplitude: Double) -> UInt8 {
        guard amplitude > 0 else { return 0 }
        return UInt8(max(1, min(255, (amplitude * 255).rounded())))
    }

    /// Ein Rahmen; `nil` bei anderer Länge als 7 oder 14 Byte. Ohne GPS-Takt
    /// ist der Zeitstempel 0 – so schreibt ihn auch readsb für Nachrichten
    /// ohne Zeitstempel; für MLAT taugt er dann nicht (soll er auch nicht).
    static func frame(_ message: [UInt8], timestamp: UInt64 = 0, signal: UInt8) -> [UInt8]? {
        let type: UInt8
        switch message.count {
        case 7: type = 0x32       // '2'
        case 14: type = 0x33      // '3'
        default: return nil
        }
        var out: [UInt8] = [0x1A, type]
        out.reserveCapacity(2 + 2 * (7 + message.count))
        func put(_ byte: UInt8) {
            out.append(byte)
            if byte == 0x1A { out.append(0x1A) }
        }
        for shift in stride(from: 40, through: 0, by: -8) { put(UInt8(truncatingIfNeeded: timestamp >> UInt64(shift))) }
        put(signal)
        message.forEach(put)
        return out
    }

    /// Stationskennung wie readsb (`sendUUID` in net_io.c): `1A E4` + 36 Zeichen,
    /// mit „f“ aufgefüllt. airplanes.live trennt ohne sie nach wenigen
    /// Nachrichten (live 27.10.2026), adsb.fi nimmt auch ohne an. Die folgende
    /// Ping-Anfrage `1A 'W' 'O'` von readsb lassen wir weg – wir beantworten
    /// keine Pings.
    static func uuidMessage(_ uuid: String) -> [UInt8] {
        let text = Array(uuid.lowercased().utf8.prefix(36))
        return [0x1A, 0xE4] + text + Array(repeating: UInt8(ascii: "f"), count: 36 - text.count)
    }
}

/// ADS-B-Einspeisung: CRC-gültige Mode-S-Nachrichten (DF17/18) im
/// Beast-Format per TCP an Community-Netze (adsb.fi, airplanes.live – beide
/// nehmen auf Port 30004 Beast an). Gesendet werden nur die Flugzeugnachrichten
/// und – abschaltbar – eine zufällige Stationskennung (UUID): kein Standort,
/// kein MLAT. Wird vom Empfangsthread
/// aus gerufen; Verbindungen und Wiederverbindung laufen auf eigener Warteschlange.
final class BeastFeeder: @unchecked Sendable {
    static let shared = BeastFeeder()
    static let enabledKey = "shareADSBEnabled"
    static let presetsKey = "shareADSBPresets"
    static let customKey = "shareADSBCustom"
    static let sendUUIDKey = "shareADSBSendUUID"
    static let uuidKey = "shareADSBUUID"

    /// Zufällige Kennung dieser Station, einmal erzeugt und gespeichert.
    static var stationUUID: String {
        if let stored = UserDefaults.standard.string(forKey: uuidKey) { return stored }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: uuidKey)
        return new
    }

    static var sendsUUID: Bool { UserDefaults.standard.object(forKey: sendUUIDKey) as? Bool ?? true }
    /// Pause vor einem neuen Verbindungsversuch.
    static let reconnectDelay: TimeInterval = 30
    /// Staut sich mehr als so viel ungesendet (Verbindung hängt), wird verworfen.
    static let backlogLimit = 256 * 1024
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Beast")

    struct Preset: Identifiable, Sendable {
        let id: String
        let name: String
        let host: String
        let port: UInt16
        var endpoint: String { "\(host):\(port)" }
    }

    static let presets = [
        Preset(id: "adsbfi", name: "adsb.fi", host: "feed.adsb.fi", port: 30004),
        Preset(id: "airplaneslive", name: "airplanes.live", host: "feed.airplanes.live", port: 30004),
    ]
    /// Vorauswahl der Häkchen (der Hauptschalter bleibt aus).
    static let defaultPresets = "adsbfi,airplaneslive"

    struct Status: Identifiable, Sendable {
        enum State: Sendable, Equatable {
            case connecting, connected, waiting(String)
        }
        let endpoint: String
        let state: State
        let sent: Int
        let dropped: Int
        var id: String { endpoint }
    }

    /// Nur auf `queue` benutzt.
    private final class Target: @unchecked Sendable {
        let host: String
        let port: UInt16
        var connection: NWConnection?
        var state: Status.State = .connecting
        var sent = 0
        var dropped = 0
        var backlog = 0
        var retry: DispatchWorkItem?
        init(host: String, port: UInt16) { self.host = host; self.port = port }
        var endpoint: String { "\(host):\(port)" }
    }

    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.beast")
    private var targets: [String: Target] = [:]
    private var enabled = false

    private init() {
        let defaults = UserDefaults.standard
        configure(enabled: defaults.bool(forKey: Self.enabledKey),
                  presets: defaults.string(forKey: Self.presetsKey) ?? Self.defaultPresets,
                  custom: defaults.string(forKey: Self.customKey) ?? "")
    }

    /// Ziele aus den Häkchen (IDs durch Komma) und eigenen „host:port“-Einträgen.
    static func endpoints(presets: String, custom: String) -> [(host: String, port: UInt16)] {
        let chosen = Set(presets.split(separator: ",").map(String.init))
        var list = Self.presets.filter { chosen.contains($0.id) }.map { (host: $0.host, port: $0.port) }
        for item in NMEAFeeder.parseTargets(custom) where !list.contains(where: { $0.host == item.host && $0.port == item.port }) {
            list.append(item)
        }
        return list
    }

    func configure(enabled: Bool, presets: String, custom: String) {
        let wanted = enabled ? Self.endpoints(presets: presets, custom: custom) : []
        queue.async { [self] in
            self.enabled = enabled
            let keys = Set(wanted.map { "\($0.host):\($0.port)" })
            for (key, target) in targets where !keys.contains(key) {
                target.retry?.cancel()
                target.connection?.cancel()
                targets.removeValue(forKey: key)
            }
            for item in wanted where targets["\(item.host):\(item.port)"] == nil {
                let target = Target(host: item.host, port: item.port)
                targets[target.endpoint] = target
                connect(target)
            }
        }
    }

    /// Nimmt die Nachrichten eines Empfangsblocks entgegen (vom Empfangsthread).
    func send(_ messages: [ADSBMessage]) {
        queue.async { [self] in
            guard enabled, !targets.isEmpty else { return }
            var data = Data()
            var count = 0
            for message in messages {
                guard let frame = BeastFormat.frame(message.raw, signal: BeastFormat.signalByte(amplitude: message.signal))
                else { continue }
                data.append(contentsOf: frame)
                count += 1
            }
            guard count > 0 else { return }
            for target in targets.values {
                guard target.state == .connected, let connection = target.connection else { continue }
                guard target.backlog + data.count <= Self.backlogLimit else { target.dropped += count; continue }
                target.backlog += data.count
                let size = data.count, sentNow = count
                connection.send(content: data, completion: .contentProcessed { [weak self, weak target] error in
                    // Abschluss läuft auf `queue` (dort gestartet); Altlasten einer
                    // abgelösten Verbindung zählen nicht mehr.
                    guard let self, let target, target.connection === connection else { return }
                    target.backlog -= size
                    if error == nil { target.sent += sentNow }
                    else { self.fail(target, connection, reason: error?.localizedDescription ?? String(localized: "Sendefehler")) }
                })
            }
        }
    }

    /// Zustand je Ziel für die Anzeige.
    func status() -> [Status] {
        queue.sync {
            targets.values.map { Status(endpoint: $0.endpoint, state: $0.state, sent: $0.sent, dropped: $0.dropped) }
                .sorted { $0.endpoint < $1.endpoint }
        }
    }

    // MARK: - Verbindung (nur auf `queue`)

    private func connect(_ target: Target) {
        target.retry = nil
        target.state = .connecting
        target.backlog = 0
        guard let port = NWEndpoint.Port(rawValue: target.port) else { return }
        let connection = NWConnection(host: .init(target.host), port: port, using: .tcp)
        target.connection = connection
        connection.stateUpdateHandler = { [weak self, weak target] state in
            guard let self, let target, target.connection === connection else { return }
            switch state {
            case .ready:
                target.state = .connected
                Self.log.info("Verbunden mit \(target.endpoint, privacy: .public)")
                if Self.sendsUUID {
                    connection.send(content: Data(BeastFormat.uuidMessage(Self.stationUUID)), completion: .idempotent)
                }
                self.watchForClose(target, connection)
            case .waiting(let error), .failed(let error):
                // `.waiting` wartete sonst auf einen Netzwechsel – lieber selbst neu versuchen.
                self.fail(target, connection, reason: error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Die Gegenstelle sendet nichts Nötiges; gelesen wird nur, um das Schließen zu bemerken.
    private func watchForClose(_ target: Target, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak target] _, _, complete, error in
            guard let self, let target, target.connection === connection else { return }
            if complete || error != nil {
                self.fail(target, connection, reason: error?.localizedDescription ?? String(localized: "Die Gegenstelle hat die Verbindung geschlossen"))
            } else {
                self.watchForClose(target, connection)
            }
        }
    }

    private func fail(_ target: Target, _ connection: NWConnection, reason: String) {
        guard target.connection === connection else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        target.connection = nil
        target.state = .waiting(reason)
        Self.log.error("\(target.endpoint, privacy: .public): \(reason, privacy: .public) – neuer Versuch in \(Int(Self.reconnectDelay)) s")
        let retry = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.enabled, self.targets[target.endpoint] === target else { return }
            self.connect(target)
        }
        target.retry = retry
        queue.asyncAfter(deadline: .now() + Self.reconnectDelay, execute: retry)
    }
}

/// Radiosonden an SondeHub (https://sondehub.org): dekodierte Rahmen als
/// Telemetrie, gesammelt und alle 15 s hochgeladen (PUT /sondes/telemetry).
/// Nur Rahmen mit Seriennummer, GPS-Zeit und Position; verschlüsselte nicht.
@MainActor
@Observable
final class SondeHubUploader {
    static let shared = SondeHubUploader()
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "SondeHub")
    static let endpoint = URL(string: "https://api.v2.sondehub.org/sondes/telemetry")!
    static let listenerEndpoint = URL(string: "https://api.v2.sondehub.org/listeners")!

    var enabled = UserDefaults.standard.bool(forKey: "shareSondeHub") {
        didSet { UserDefaults.standard.set(enabled, forKey: "shareSondeHub"); listenerSent = nil }
    }
    /// Frei wählbar, z. B. das eigene Amateurfunk-Rufzeichen oder ein Spitzname.
    var callsign = UserDefaults.standard.string(forKey: "sondeHubCallsign") ?? "" {
        didSet { UserDefaults.standard.set(callsign, forKey: "sondeHubCallsign"); listenerSent = nil }
    }
    /// Standort mitsenden (auf 0,01° gerundet, ≈ 1 km) – erscheint dann auf der Karte von SondeHub.
    var sharePosition = UserDefaults.standard.bool(forKey: "sondeHubSharePosition") {
        didSet { UserDefaults.standard.set(sharePosition, forKey: "sondeHubSharePosition"); listenerSent = nil }
    }
    var antenna = UserDefaults.standard.string(forKey: "sondeHubAntenna") ?? "Moonraker Skyscan + LNA" {
        didSet { UserDefaults.standard.set(antenna, forKey: "sondeHubAntenna") }
    }

    private(set) var uploaded = 0
    private(set) var lastUpload: Date?
    private(set) var error: String?

    private var pending: [[String: Any]] = []
    /// Fehlgeschlagene Versuche in Folge; nach `maxAttempts` wird der Stapel verworfen.
    private var failedAttempts = 0
    private var task: Task<Void, Never>?
    private var listenerSent: Date?

    var ready: Bool { enabled && !callsign.trimmingCharacters(in: .whitespaces).isEmpty }

    private var position: [Double]? {
        guard sharePosition, let home = TrafficArchive.home else { return nil }
        return [(home.lat * 100).rounded() / 100, (home.lon * 100).rounded() / 100, 0]
    }

    private var softwareVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func enqueue(_ reports: [SondeReport], received: Date = Date()) {
        guard ready else { return }
        for r in reports {
            guard !r.encrypted, !r.serial.isEmpty, let time = r.gpsTime, let frame = r.frame,
                  let lat = r.latitude, let lon = r.longitude, let alt = r.altitude else { continue }
            var t: [String: Any] = [
                "software_name": "PortaPack Manager", "software_version": softwareVersion,
                "uploader_callsign": callsign.trimmingCharacters(in: .whitespaces),
                "time_received": ISOTime.fractionalString(received),
                "manufacturer": r.kind == .rs41 ? "Vaisala" : "Graw",
                "type": r.kind.rawValue, "serial": r.serial, "frame": frame,
                "datetime": ISOTime.fractionalString(time),
                "lat": lat, "lon": lon, "alt": alt,
                "frequency": (r.frequency / 1e3).rounded() / 1e3,
            ]
            if r.kind == .rs41, !r.model.isEmpty { t["subtype"] = r.model }
            if let v = r.temperature { t["temp"] = v }
            if let v = r.humidity { t["humidity"] = v }
            if let v = r.groundSpeed { t["vel_h"] = v }
            if let v = r.verticalSpeed { t["vel_v"] = v }
            if let v = r.heading { t["heading"] = v }
            if let v = r.satellites { t["sats"] = v }
            if let v = r.batteryVolts { t["batt"] = v }
            if let position { t["uploader_position"] = position }
            if !antenna.isEmpty { t["uploader_antenna"] = antenna }
            pending.append(t)
        }
        if pending.count > 2000 { pending.removeFirst(pending.count - 2000) }
        if task == nil, !pending.isEmpty {
            task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.flush()
            }
        }
    }

    private func flush() async {
        task = nil
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        do {
            try await put(Self.endpoint, body: batch)
            uploaded += batch.count
            lastUpload = Date()
            error = nil
            await announceListener()
            failedAttempts = 0
        } catch {
            self.error = error.localizedDescription
            failedAttempts += 1
            if Self.shouldRetry(error), failedAttempts < Self.maxAttempts {
                pending = batch + pending          // beim nächsten Mal erneut
                if pending.count > 2000 { pending.removeFirst(pending.count - 2000) }
                Self.log.error("Hochladen fehlgeschlagen (Versuch \(self.failedAttempts)): \(error.localizedDescription, privacy: .public)")
            } else {
                // Abgelehnt (4xx) oder zu oft gescheitert: verwerfen, sonst blockiert
                // derselbe Stapel jeden weiteren Upload (Review Y8).
                failedAttempts = 0
                Self.log.error("Stapel mit \(batch.count) Meldungen verworfen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Höchstens so viele Versuche je Stapel.
    static let maxAttempts = 5

    /// Antwort von SondeHub mit Fehlerstatus.
    struct HTTPStatusError: Error, LocalizedError {
        let status: Int
        let text: String
        var errorDescription: String? { "SondeHub (\(status)): \(text)" }
    }

    /// Nur vorübergehende Fehler wiederholen: Netzfehler, 5xx, 408 und 429.
    /// Andere 4xx-Antworten lehnen genau diesen Inhalt ab – erneutes Senden hilft nicht.
    nonisolated static func shouldRetry(_ error: Error) -> Bool {
        guard let http = error as? HTTPStatusError else { return true }
        return http.status >= 500 || http.status == 408 || http.status == 429
    }

    /// Station einmal täglich anmelden – nur mit Standort sinnvoll (Karte).
    private func announceListener() async {
        guard let position, listenerSent.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        let body: [String: Any] = [
            "software_name": "PortaPack Manager", "software_version": softwareVersion,
            "uploader_callsign": callsign.trimmingCharacters(in: .whitespaces),
            "uploader_position": position, "uploader_antenna": antenna, "mobile": false,
        ]
        if (try? await put(Self.listenerEndpoint, body: body)) != nil { listenerSent = Date() }
    }

    private func put(_ url: URL, body: Any) async throws {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PortaPackManager/\(softwareVersion) (+https://github.com/cpeg78)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.limitedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode, text: String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
