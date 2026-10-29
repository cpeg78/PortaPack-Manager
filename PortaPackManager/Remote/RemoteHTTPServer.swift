import Foundation
import Network
import os

/// Kleiner HTTP/1.1-Server (nur GET/POST ohne Körper) für den Fernzugriff.
/// Normale Antworten mit Länge und `Connection: close`; Audio-Abrufe bleiben
/// offen und bekommen jeden ADTS-Rahmen über `broadcast` (wie Icecast).
final class RemoteHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
    }

    enum Response: Sendable {
        case data(status: Int, contentType: String, body: Data)
        /// Offener Strom (Audio), Daten kommen über `broadcast`.
        case stream(contentType: String)
        /// Antwort mit zusätzlichen Kopfzeilen (z. B. `Set-Cookie`).
        indirect case withHeaders([String: String], Response)

        static func json(_ data: Data) -> Response { .data(status: 200, contentType: "application/json; charset=utf-8", body: data) }
        static func text(_ status: Int, _ text: String) -> Response {
            .data(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.remote-http")
    private var listener: NWListener?
    private var handler: Handler?
    /// Offene Audio-Verbindungen mit Zahl noch nicht bestätigter Sendungen.
    private var streams: [ObjectIdentifier: (connection: NWConnection, pending: Int)] = [:]
    /// Gewöhnliche Anfragen bis zur Antwort, mit „Kopf vollständig“. Ohne
    /// Zeitgrenze und Obergrenze konnte jeder im Netz – auch ohne Schlüssel –
    /// beliebig viele Verbindungen offen halten (Slowloris, Review 27.10.2026).
    private var open: [ObjectIdentifier: (connection: NWConnection, headerDone: Bool, peer: String?)] = [:]
    static let maximumOpen = 64
    /// Höchstens so viele offene Anfragen je Gegenstelle (IP-Adresse, bei IPv6 das
    /// /64-Netz – `RemoteAccessPolicy.peerKey`). Sonst konnte ein einzelnes Gerät alle
    /// 64 Plätze belegen und das Handy aussperren (Review 28.10.2026, Y22). Ein
    /// Browser öffnet je Seite höchstens sechs.
    static let maximumOpenPerPeer = 16
    static let headerTimeout: TimeInterval = 10
    /// Gesamtfrist einer gewöhnlichen Verbindung ab dem Annehmen – auch für das
    /// Senden der Antwort. Vorher galt nur die Kopf-Frist: Wer nach dem Kopf nicht
    /// mehr las (Slow-Read), hielt seinen Platz für immer (Review 29.10.2026, S1).
    /// Audioströme sind ausgenommen, sie trennt der Rückstau in `broadcast`.
    static let connectionTimeout: TimeInterval = 30
    /// Höchstens so viele gleichzeitige Audioströme (jeder kostet Sendepuffer).
    static let maximumStreams = 8
    /// Nur Gegenstellen aus Heimnetz und VPN annehmen (`RemoteAccessPolicy.isHomeOrVPN`).
    private var localOnly = true
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Fernzugriff")
    /// Meldet die Zahl der Hörer (auf `queue`) – gezählt werden Geräte, nicht
    /// Verbindungen: iOS öffnet für ein `<audio>` gern eine zweite Verbindung.
    var onListenerCount: (@Sendable (Int) -> Void)?
    var onState: (@Sendable (String?) -> Void)?
    /// Meldet eine abgewiesene Gegenstelle (außerhalb von Heimnetz und VPN).
    var onRejected: (@Sendable (String) -> Void)?

    /// „Nur Heimnetz und VPN“ – gilt für jede neue Verbindung.
    func setLocalOnly(_ on: Bool) {
        queue.async { self.localOnly = on }
    }

    func start(port: UInt16, handler: @escaping Handler) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.onState?(error.localizedDescription)
            case .ready: self?.onState?(nil)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for entry in streams.values { entry.connection.cancel() }
            streams.removeAll()
            for entry in open.values { entry.connection.cancel() }
            open.removeAll()
        }
        onListenerCount?(0)
    }

    /// Schickt Audiodaten an alle offenen Audio-Verbindungen. Wer 256 Sendungen
    /// im Rückstand ist (≈ 5 s), wird getrennt – sonst bliebe eine verwaiste
    /// Verbindung (Handy weg, ohne Abbau) für immer als Hörer stehen.
    func broadcast(_ data: Data) {
        queue.async { [self] in
            for (key, entry) in streams where entry.pending >= 256 { dropStream(key) }
            for (key, entry) in streams {
                streams[key]?.pending += 1
                entry.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        self.streams[key]?.pending -= 1
                        if error != nil { self.dropStream(key) }
                    }
                })
            }
        }
    }

    var hasListeners: Bool { queue.sync { !streams.isEmpty } }

    // MARK: - Verbindung

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let host = Self.peerHost(connection.endpoint)
        if localOnly, !(host.map {
            RemoteAccessPolicy.isHomeOrVPN($0) || RemoteAccessPolicy.isOnLink($0, subnets: RemoteAccessPolicy.localSubnets())
        } ?? false) {
            // Sofort trennen, noch bevor ein Byte gelesen wird.
            Self.log.notice("Abgewiesen (nicht Heimnetz/VPN): \(host ?? "?", privacy: .public)")
            connection.cancel()
            onRejected?(host ?? "?")
            return
        }
        let peer = host.map(RemoteAccessPolicy.peerKey)
        guard Self.admits(peer: peer, openPeers: open.values.map(\.peer)) else { connection.cancel(); return }
        open[key] = (connection, false, peer)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.open.removeValue(forKey: key)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.headerTimeout) { [weak self] in
            guard let self, let entry = self.open[key], !entry.headerDone else { return }
            entry.connection.cancel()
            self.open.removeValue(forKey: key)
        }
        // Gesamtfrist: wer bis dahin nicht fertig ist (auch beim Senden), fliegt.
        // Ein Audiostrom steht dann schon in `streams`, nicht mehr in `open`.
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak self] in
            guard let self, let entry = self.open.removeValue(forKey: key) else { return }
            entry.connection.cancel()
        }
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.open[ObjectIdentifier(connection)]?.headerDone = true
                let request = Self.parse(buffer[..<end.lowerBound])
                self.respond(to: request, on: connection)
            } else if error != nil || complete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    /// IP-Adresse einer Gegenstelle (ohne Port).
    static func peerHost(_ endpoint: NWEndpoint) -> String? {
        if case let .hostPort(host, _) = endpoint { return "\(host)" }
        return nil
    }

    /// Darf eine neue Verbindung von `peer` angenommen werden? Gesamtgrenze und
    /// Grenze je Gegenstelle (unbekannte Gegenstellen zählen nur zur Gesamtzahl).
    static func admits(peer: String?, openPeers: [String?], total: Int = maximumOpen,
                       perPeer: Int = maximumOpenPerPeer) -> Bool {
        guard openPeers.count < total else { return false }
        guard let peer else { return true }
        return openPeers.lazy.filter { $0 == peer }.count < perPeer
    }

    static func parse(_ head: Data) -> Request {
        var request = Request()
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        if parts.count >= 2 {
            request.method = String(parts[0])
            let target = String(parts[1])
            let components = URLComponents(string: target)
            request.path = components?.path ?? target
            for item in components?.queryItems ?? [] { request.query[item.name] = item.value ?? "" }
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            request.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return request
    }

    private func respond(to request: Request, on connection: NWConnection) {
        guard let handler else { connection.cancel(); return }
        Task {
            let response = await handler(request)
            self.queue.async { self.send(response, on: connection, head: request.method == "HEAD") }
        }
    }

    /// Sicherheitsköpfe jeder Antwort plus eigene (`withHeaders`), als Kopfzeilen.
    static func extraHeaderLines(_ extra: [String: String]) -> String {
        (RemoteAccessPolicy.securityHeaders + extra.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            .map { "\($0.0): \($0.1)\r\n" }.joined()
    }

    private func send(_ response: Response, on connection: NWConnection, head: Bool, extra: [String: String] = [:]) {
        switch response {
        case let .withHeaders(headers, inner):
            send(inner, on: connection, head: head, extra: extra.merging(headers) { $1 })
        case let .data(status, contentType, body):
            var header = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            header += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            header += Self.extraHeaderLines(extra)
            header += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            var out = Data(header.utf8)
            if !head { out.append(body) }
            connection.send(content: out, completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                self?.open.removeValue(forKey: ObjectIdentifier(connection))
            })
        case let .stream(contentType):
            // Obergrenze der Ströme; `Access-Control-Allow-Origin: *` ist weg – die
            // eigene Seite braucht es nicht, fremde Seiten sollen den Ton nicht lesen.
            guard streams.count < Self.maximumStreams else {
                send(.text(503, String(localized: "Zu viele Hörer")), on: connection, head: head)
                return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-store\r\n"
                + Self.extraHeaderLines(extra) + "Connection: close\r\n\r\n"
            let key = ObjectIdentifier(connection)
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.open.removeValue(forKey: key)
                if error != nil { connection.cancel(); return }
                self.streams[key] = (connection, 0)
                self.onListenerCount?(self.listenerCount)
                self.watchClose(connection, key: key)
            })
        }
    }

    /// Erkennt das Schließen einer Audio-Verbindung (Browser stoppt).
    private func watchClose(_ connection: NWConnection, key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil { self.dropStream(key) } else { self.watchClose(connection, key: key) }
        }
    }

    private func dropStream(_ key: ObjectIdentifier) {
        guard let entry = streams.removeValue(forKey: key) else { return }
        entry.connection.cancel()
        onListenerCount?(listenerCount)
    }

    /// Zahl verschiedener Gegenstellen (IP-Adressen) mit offenem Audiostrom.
    private var listenerCount: Int {
        Set(streams.values.map { entry -> String in
            if case let .hostPort(host, _) = entry.connection.endpoint { return "\(host)" }
            return "\(ObjectIdentifier(entry.connection))"
        }).count
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 421: "Misdirected Request"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
