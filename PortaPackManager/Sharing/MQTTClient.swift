import Foundation
import Network
import os

/// Schlanker MQTT-3.1.1-Client über Network.framework (TCP, optional TLS):
/// CONNECT mit Benutzer/Passwort und Last Will, PUBLISH QoS 0, SUBSCRIBE QoS 0,
/// Keep-Alive per PINGREQ und Wiederverbinden mit wachsender Pause.
/// Alles läuft auf einer eigenen Warteschlange; die Rückrufe ebenfalls.
final class MQTTClient: @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        var host: String
        var port: UInt16
        var tls = false
        var username = ""
        var password = ""
        var clientID: String
        var keepAlive: UInt16 = 60
        var will: MQTTPacket.Will?
        /// Nach jeder Verbindung abonniert (QoS 0).
        var subscriptions: [String] = []
        /// Nach Abbruch selbst neu verbinden (aus für „Verbindung testen“).
        var reconnect = true
        var initialBackoff: TimeInterval = 2
        var maxBackoff: TimeInterval = 120
        /// So lange darf Verbindungsaufbau samt CONNACK dauern.
        var connectTimeout: TimeInterval = 10
    }

    enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        /// Abgebrochen; neuer Versuch in `retry` Sekunden.
        case waiting(reason: String, retry: TimeInterval)
        /// Endgültig (nur ohne Wiederverbinden).
        case failed(String)
    }

    struct Handlers: Sendable {
        var state: (@Sendable (State) -> Void)?
        /// Nach angenommenem CONNACK (Abos sind dann schon verschickt).
        var connected: (@Sendable () -> Void)?
        var message: (@Sendable (_ topic: String, _ payload: [UInt8]) -> Void)?
    }

    /// Staut sich mehr als so viel ungesendet, werden neue Nachrichten verworfen.
    static let backlogLimit = 1 << 20
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "MQTT")

    let configuration: Configuration
    private let handlers: Handlers
    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.mqtt")

    // Nur auf `queue`:
    private var connection: NWConnection?
    private var reader = MQTTPacketReader()
    private var state: State = .idle
    private var running = false
    private var backoff: TimeInterval
    private var retry: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var keepAliveTimer: DispatchSourceTimer?
    private var lastReceived = Date()
    private var backlog = 0
    private var nextPacketID: UInt16 = 1
    private var sent = 0
    private var dropped = 0

    init(configuration: Configuration, handlers: Handlers = Handlers()) {
        self.configuration = configuration
        self.handlers = handlers
        self.backoff = configuration.initialBackoff
    }

    // MARK: - Steuerung

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            backoff = configuration.initialBackoff
            connect()
        }
    }

    /// Beendet die Verbindung. `farewell` geht vorher noch hinaus (z. B. die
    /// Verfügbarkeit „offline“ – ein sauberes DISCONNECT löst den Last Will
    /// beim Broker **nicht** aus). `completion` läuft auf der Warteschlange.
    func stop(farewell: (topic: String, payload: [UInt8], retain: Bool)? = nil,
              completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            running = false
            retry?.cancel(); retry = nil
            timeout?.cancel(); timeout = nil
            keepAliveTimer?.cancel(); keepAliveTimer = nil
            guard let connection else {
                setState(.idle)
                completion?()
                return
            }
            self.connection = nil
            connection.stateUpdateHandler = nil
            var bytes: [UInt8] = []
            if state == .connected, let farewell {
                bytes += MQTTPacket.publish(topic: farewell.topic, payload: farewell.payload, retain: farewell.retain)
            }
            if state == .connected { bytes += MQTTPacket.disconnect }
            setState(.idle)
            guard !bytes.isEmpty else {
                connection.cancel()
                completion?()
                return
            }
            connection.send(content: Data(bytes), completion: .contentProcessed { _ in
                connection.cancel()
                completion?()
            })
        }
    }

    /// PUBLISH mit QoS 0. Ohne Verbindung wird verworfen (QoS 0 kennt keine
    /// Nachlieferung; die Brücke sendet nach dem Verbinden ohnehin alles neu).
    func publish(topic: String, payload: [UInt8], retain: Bool = false) {
        queue.async { [self] in
            guard state == .connected, let connection else { dropped += 1; return }
            let packet = MQTTPacket.publish(topic: topic, payload: payload, retain: retain)
            guard backlog + packet.count <= Self.backlogLimit else { dropped += 1; return }
            backlog += packet.count
            connection.send(content: Data(packet), completion: .contentProcessed { [weak self] error in
                guard let self, self.connection === connection else { return }
                self.backlog -= packet.count
                if let error { self.fail(connection, reason: error.localizedDescription) } else { self.sent += 1 }
            })
        }
    }

    var currentState: State { queue.sync { state } }
    var counts: (sent: Int, dropped: Int) { queue.sync { (sent, dropped) } }

    // MARK: - Verbindung (nur auf `queue`)

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        handlers.state?(new)
    }

    private func connect() {
        retry = nil
        guard running, let port = NWEndpoint.Port(rawValue: configuration.port), !configuration.host.isEmpty else {
            setState(.failed(String(localized: "Broker-Adresse fehlt")))
            return
        }
        setState(.connecting)
        reader = MQTTPacketReader()
        backlog = 0
        let parameters: NWParameters = configuration.tls ? NWParameters(tls: NWProtocolTLS.Options()) : .tcp
        let connection = NWConnection(host: .init(configuration.host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.lastReceived = Date()
                let packet = MQTTPacket.connect(clientID: self.configuration.clientID,
                                                username: self.configuration.username,
                                                password: self.configuration.password,
                                                keepAlive: self.configuration.keepAlive,
                                                will: self.configuration.will)
                connection.send(content: Data(packet), completion: .idempotent)
                self.receive(connection)
            case .waiting(let error), .failed(let error):
                // `.waiting` wartete sonst still auf einen Netzwechsel – lieber selbst neu versuchen.
                self.fail(connection, reason: Self.describe(error))
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connection === connection, self.state != .connected else { return }
            self.fail(connection, reason: String(localized: "Keine Antwort vom Broker"))
        }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + configuration.connectTimeout, execute: timeout)
        connection.start(queue: queue)
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED): String(localized: "Verbindung abgelehnt (läuft der Broker, stimmt der Port?)")
        case .dns: String(localized: "Broker-Name nicht gefunden")
        case .tls: String(localized: "Verschlüsselung (TLS) gescheitert – stimmt das Zertifikat? \(error.localizedDescription)")
        default: error.localizedDescription
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.reader.append(data)
                do {
                    while let frame = try self.reader.next() {
                        self.handle(frame, connection)
                        guard self.connection === connection else { return }
                    }
                } catch {
                    self.fail(connection, reason: String(localized: "Ungültiges Paket vom Broker"))
                    return
                }
            }
            if complete || error != nil {
                self.fail(connection, reason: error.map(Self.describe) ?? String(localized: "Der Broker hat die Verbindung geschlossen"))
            } else {
                self.receive(connection)
            }
        }
    }

    private func handle(_ frame: MQTTPacket.Frame, _ connection: NWConnection) {
        switch frame.kind {
        case .connack:
            guard let code = MQTTPacket.connackCode(frame.body) else {
                fail(connection, reason: String(localized: "Ungültige Antwort des Brokers"))
                return
            }
            guard code == 0 else {
                fail(connection, reason: String(localized: "Broker lehnt ab: \(MQTTPacket.connackText(code))"))
                return
            }
            timeout?.cancel(); timeout = nil
            backoff = configuration.initialBackoff
            setState(.connected)
            Self.log.info("Verbunden mit \(self.configuration.host, privacy: .public):\(self.configuration.port)")
            for topic in configuration.subscriptions {
                connection.send(content: Data(MQTTPacket.subscribe(packetID: nextPacketID, topic: topic)), completion: .idempotent)
                nextPacketID = nextPacketID == .max ? 1 : nextPacketID + 1
            }
            startKeepAlive(connection)
            handlers.connected?()
        case .publish:
            // Vor dem CONNACK darf der Broker nichts zustellen – solche Pakete ignorieren.
            guard state == .connected else { break }
            if let message = MQTTPacket.parsePublish(flags: frame.flags, body: frame.body) {
                handlers.message?(message.topic, message.payload)
            }
        default:
            break                                   // PINGRESP, SUBACK: nur Lebenszeichen
        }
    }

    private func startKeepAlive(_ connection: NWConnection) {
        keepAliveTimer?.cancel()
        let interval = max(1, Double(configuration.keepAlive) / 2)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.connection === connection else { return }
            // Der Broker trennt nach 1,5 × Keep-Alive ohne Paket; wir auch.
            if Date().timeIntervalSince(self.lastReceived) > Double(self.configuration.keepAlive) * 1.5 {
                self.fail(connection, reason: String(localized: "Der Broker antwortet nicht mehr"))
                return
            }
            connection.send(content: Data(MQTTPacket.pingreq), completion: .idempotent)
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private func fail(_ connection: NWConnection, reason: String) {
        guard self.connection === connection else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        timeout?.cancel(); timeout = nil
        keepAliveTimer?.cancel(); keepAliveTimer = nil
        guard running, configuration.reconnect else {
            running = false
            setState(.failed(reason))
            return
        }
        let delay = backoff
        backoff = min(configuration.maxBackoff, backoff * 2)
        setState(.waiting(reason: reason, retry: delay))
        Self.log.error("\(reason, privacy: .public) – neuer Versuch in \(Int(delay)) s")
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.connection == nil else { return }
            self.connect()
        }
        self.retry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    // MARK: - Einmalige Probe

    /// „Verbindung testen“: verbinden, CONNACK abwarten, sauber trennen.
    /// Liefert `nil` bei Erfolg, sonst den Grund.
    static func probe(_ configuration: Configuration) async -> String? {
        var config = configuration
        config.reconnect = false
        config.will = nil
        config.subscriptions = []
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let box = ClientBox()
            let client = MQTTClient(configuration: config, handlers: Handlers(
                state: { state in
                    guard case let .failed(reason) = state else { return }
                    box.client = nil                    // Kreis Client ↔ Rückruf lösen
                    if once.claim() { continuation.resume(returning: reason) }
                },
                connected: {
                    let client = box.client
                    box.client = nil
                    client?.stop {
                        if once.claim() { continuation.resume(returning: nil) }
                    }
                }))
            box.client = client
            client.start()
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    private final class ClientBox: @unchecked Sendable {
        var client: MQTTClient?
    }
}
