import Foundation

/// Eine Zeile im Konsolenprotokoll der App.
struct ConsoleLine: Identifiable, Sendable {
    enum Direction: Sendable { case sent, received, note }
    let id = UUID()
    let date = Date()
    let direction: Direction
    let text: String
}

/// Das Befehl/Antwort-Protokoll der Mayhem-USB-Konsole (ChibiOS-Shell).
///
/// Der Ablauf je Befehl: Befehl + `\r` senden (nie `\r\n` – ein folgendes
/// `\n` läse `fwb` als erstes Datenbyte), das Gerät wiederholt den Befehl als Echo, sendet die Antwort und zum Schluss die Eingabeaufforderung
/// `ch> `. Antworten enden nicht einheitlich auf `ok`, deshalb gilt die
/// Eingabeaufforderung als Abschluss. Für Antworten mit Pixeldaten
/// (`screenframeshort`) wird stattdessen eine feste Byteanzahl gelesen, weil
/// `ch> ` dort zufällig im Nutzinhalt vorkommen kann.
///
/// Gelesen wird über einen dauerhaften Empfangspuffer: was hinter einer
/// Marke im selben USB-Stück ankam (etwa Pixeldaten direkt nach dem Echo von
/// `screenframeshort`), bleibt für den nächsten Leseschritt liegen.
///
/// Die Klasse ist nicht threadsicher; sie wird ausschließlich vom Actor
/// `MayhemDevice` benutzt, der alle Aufrufe serialisiert. Nur `abort()` darf
/// von außen kommen.
final class MayhemShell: @unchecked Sendable {
    static let prompt = "ch> "

    /// Paketgröße und Pause beim Schreiben von Binärdaten (`fwb`).
    nonisolated(unsafe) static var binaryPacketSize = 64
    nonisolated(unsafe) static var binaryPause: TimeInterval = 0.002
    private static let promptMarker = Data("\r\nch> ".utf8)

    let port: SerialPort
    private let logHandler: (@Sendable (ConsoleLine) -> Void)?
    private var closed = false
    /// Gelesen, aber noch keinem Befehl zugeordnet.
    private(set) var pending = Data()

    init(path: String, log: (@Sendable (ConsoleLine) -> Void)? = nil) throws {
        port = SerialPort(path: path)
        logHandler = log
        try port.open()
    }

    /// Für Tests: eine schon geöffnete Schnittstelle.
    init(port: SerialPort, log: (@Sendable (ConsoleLine) -> Void)? = nil) {
        self.port = port
        logHandler = log
    }

    func close() {
        closed = true
        pending = Data()
        port.close()
    }

    /// Bricht laufende Lese-/Schreibschleifen ab – von jedem Thread aus.
    func abort() {
        port.abort()
    }

    /// Synchronisiert auf die Eingabeaufforderung: leert Altlasten und
    /// wartet, bis das Gerät `ch> ` sendet.
    func synchronize() throws {
        discardPending(for: 0.1)
        try port.write("\r")
        _ = try readUntil(Self.promptMarker, timeout: 3)
        discardPending(for: 0.05)
    }

    /// Verwirft Gepuffertes und alles, was in `duration` noch ankommt.
    private func discardPending(for duration: TimeInterval) {
        pending = Data()
        port.drain(for: duration)
    }

    /// Führt einen Textbefehl aus und liefert die Antwort ohne Echo und ohne
    /// Eingabeaufforderung.
    @discardableResult
    func run(_ command: String, timeout: TimeInterval = 5) throws -> String {
        guard !closed else { throw SerialPortError.notOpen }
        log(.sent, command)
        try port.write(command + "\r")
        let raw = try readUntil(Self.promptMarker, timeout: timeout)
        let text = Self.stripEnvelope(raw, command: command)
        log(.received, text)
        return text
    }

    /// Führt einen Befehl aus, dessen Antwort eine bekannte Länge hat. Nach
    /// dem Echo werden `byteCount` Bytes gelesen, danach `trailer` erwartet.
    func runFixedLength(_ command: String, byteCount: Int, trailer: String, timeout: TimeInterval) throws -> Data {
        guard !closed else { throw SerialPortError.notOpen }
        log(.sent, command)
        try port.write(command + "\r")
        do {
            _ = try readUntil(Data((command + "\r\n").utf8), timeout: timeout)
            let payload = try readExactly(byteCount, timeout: timeout)
            _ = try readUntil(Data(trailer.utf8), timeout: timeout)
            log(.received, "(\(byteCount) Bytes)")
            return payload
        } catch {
            // Rest eines halben Bildes nicht in die nächste Antwort tragen.
            discardPending(for: 0.1)
            throw error
        }
    }

    /// Sendet einen Befehl und wartet nur auf `marker` – für Befehle, nach
    /// denen das Gerät neu startet und keine Eingabeaufforderung mehr kommt.
    func runUntil(_ command: String, markers: [String], timeout: TimeInterval) throws -> String {
        guard !closed else { throw SerialPortError.notOpen }
        log(.sent, command)
        try port.write(command + "\r")
        let raw = try readUntil(anyOf: markers.map { Data($0.utf8) }, timeout: timeout)
        let text = Self.stripEnvelope(raw, command: command)
        log(.received, text)
        return text
    }

    /// Sendet einen Befehl, ohne auf eine Antwort zu warten.
    func send(_ command: String) throws {
        guard !closed else { throw SerialPortError.notOpen }
        log(.sent, command)
        try port.write(command + "\r")
    }

    /// `fwb <n>`: Das Gerät antwortet mit `send <n> bytes`, dann folgen die
    /// Rohdaten, dann `ok` und die Eingabeaufforderung.
    func writeBinaryChunk(_ chunk: Data, timeout: TimeInterval = 20) throws {
        guard !closed else { throw SerialPortError.notOpen }
        let command = "fwb \(chunk.count)"
        try port.write(command + "\r")
        _ = try readUntil(Data("bytes\r\n".utf8), timeout: timeout)
        // macOS: große Schreibvorgänge auf den CDC-Treiber verklemmen ihn
        // (Prozess hängt im Kernel, Gerät verschwindet). Wie MayhemHub in
        // 64-Byte-Paketen mit kurzer Pause schreiben.
        var sent = 0
        do {
            try port.writePaced(chunk, packetSize: Self.binaryPacketSize, pause: Self.binaryPause) { sent = $0 }
        } catch {
            // Das Gerät wartet noch auf den Rest und läse jeden folgenden
            // Befehl (auch `fclose`) als Daten. Mit Nullen auffüllen, bis die
            // Shell wieder auf Befehle hört – die Datei ist danach ohnehin
            // unbrauchbar, der Aufrufer prüft per CRC bzw. wirft.
            completeAbortedChunk(remaining: chunk.count - sent)
            throw error
        }
        let raw = try readUntil(Self.promptMarker, timeout: timeout)
        let text = String(decoding: raw, as: UTF8.self)
        guard text.contains("ok") else {
            throw MayhemError.commandFailed(command: command, response: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Füllt ein abgebrochenes `fwb` auf (bestmöglich, kurzes Zeitlimit).
    private func completeAbortedChunk(remaining: Int) {
        guard remaining > 0, !closed, !port.isAborted else { return }
        let filler = Data(count: remaining)
        guard (try? port.writePaced(filler, packetSize: Self.binaryPacketSize, pause: Self.binaryPause)) != nil else { return }
        _ = try? readUntil(Self.promptMarker, timeout: 3)
    }

    // MARK: - Lesen über den Empfangspuffer

    /// Liest bis einschließlich `marker`; was danach kam, bleibt in `pending`.
    func readUntil(_ marker: Data, timeout: TimeInterval, maxBytes: Int = 4_000_000) throws -> Data {
        try readUntil(anyOf: [marker], timeout: timeout, maxBytes: maxBytes)
    }

    /// Liest bis zur frühesten der Marken (einschließlich).
    func readUntil(anyOf markers: [Data], timeout: TimeInterval, maxBytes: Int = 4_000_000) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let longest = markers.map(\.count).max() ?? 0
        var searchStart = 0
        while true {
            if pending.count >= 1 {
                let from = max(0, searchStart - longest + 1)
                let hits = markers.compactMap { marker -> Range<Int>? in
                    guard !marker.isEmpty, pending.count >= marker.count else { return nil }
                    return pending.range(of: marker, in: from..<pending.count)
                }
                if let first = hits.min(by: { $0.lowerBound < $1.lowerBound }) {
                    let result = Data(pending[..<first.upperBound])
                    pending = Data(pending[first.upperBound...])
                    return result
                }
                searchStart = pending.count
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, pending.count < maxBytes else {
                let wanted = markers.count == 1 ? String(decoding: markers[0], as: UTF8.self) : "Antwort"
                throw SerialPortError.timeout(waitingFor: wanted.replacingOccurrences(of: "\r\n", with: "⏎"),
                                              received: pending.count)
            }
            pending.append(try port.read(max: 65536, timeout: min(remaining, 0.25)))
        }
    }

    /// Liest genau `count` Bytes (zuerst aus dem Puffer).
    func readExactly(_ count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SerialPortError.timeout(waitingFor: "\(count) Bytes", received: pending.count)
            }
            pending.append(try port.read(max: 65536, timeout: min(remaining, 0.25)))
        }
        let result = Data(pending.prefix(count))
        pending = Data(pending.dropFirst(count))
        return result
    }

    // MARK: - Hilfen

    /// Entfernt Echo-Zeile und Eingabeaufforderung aus einer Rohantwort.
    static func stripEnvelope(_ raw: Data, command: String) -> String {
        var text = String(decoding: raw, as: UTF8.self)
        if text.hasSuffix("\r\n" + prompt) {
            text.removeLast(("\r\n" + prompt).count)
        } else if text.hasSuffix(prompt) {
            text.removeLast(prompt.count)
        }
        let echo = command + "\r\n"
        if text.hasPrefix(echo) {
            text.removeFirst(echo.count)
        } else if let range = text.range(of: echo) {
            // Vor dem Echo stand noch Rest einer früheren Antwort.
            text = String(text[range.upperBound...])
        }
        return text
    }

    private func log(_ direction: ConsoleLine.Direction, _ text: String) {
        guard let logHandler else { return }
        let shortened = text.count > 2000 ? String(text.prefix(2000)) + "…" : text
        logHandler(ConsoleLine(direction: direction, text: shortened))
    }
}

/// Fehler auf Protokollebene.
enum MayhemError: Error, LocalizedError, Sendable {
    case commandFailed(command: String, response: String)
    case unexpectedResponse(String)
    case fileNotFound(String)
    case pathNotReachable(path: String, reason: String)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case notConnected
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, response):
            return response.isEmpty
                ? String(localized: "Befehl „\(command)“ fehlgeschlagen: keine Antwort")
                : String(localized: "Befehl „\(command)“ fehlgeschlagen: \(response)")
        case let .unexpectedResponse(text):
            return String(localized: "Unerwartete Antwort vom Gerät: \(text)")
        case let .fileNotFound(path):
            return String(localized: "Datei nicht gefunden: \(path)")
        case let .pathNotReachable(path, reason):
            return String(localized: "„\(path)“ ist über die USB-Verbindung nicht erreichbar: \(reason). Benenne die Datei am Gerät um oder öffne die SD-Karte als Laufwerk am Mac.")
        case let .checksumMismatch(expected, actual):
            return String(localized: "Die Datei kam beschädigt an (Prüfsumme erwartet \(String(format: "%08X", expected)), auf dem Gerät \(String(format: "%08X", actual))).")
        case .notConnected:
            return String(localized: "Kein PortaPack verbunden.")
        case .cancelled:
            return String(localized: "Abgebrochen.")
        }
    }
}
