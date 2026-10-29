import Darwin
import Foundation
import Synchronization

/// Fehler der seriellen Schnittstelle.
enum SerialPortError: Error, LocalizedError, Sendable {
    case openFailed(path: String, errno: Int32)
    case configurationFailed(errno: Int32)
    case notOpen
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timeout(waitingFor: String, received: Int)
    case disconnected
    case aborted

    var errorDescription: String? {
        switch self {
        case let .openFailed(path, code):
            return String(localized: "Die Verbindung zum PortaPack (\(path)) ließ sich nicht öffnen: \(String(cString: strerror(code)))")
        case let .configurationFailed(code):
            return String(localized: "Die Verbindung zum PortaPack ließ sich nicht einrichten: \(String(cString: strerror(code)))")
        case .notOpen:
            return String(localized: "Die Verbindung zum PortaPack ist nicht offen.")
        case let .writeFailed(code):
            return String(localized: "Senden an das PortaPack fehlgeschlagen: \(String(cString: strerror(code)))")
        case let .readFailed(code):
            return String(localized: "Lesen vom PortaPack fehlgeschlagen: \(String(cString: strerror(code)))")
        case let .timeout(marker, received):
            return String(localized: "Keine Antwort vom Gerät (erwartet „\(marker)“, \(received) Bytes erhalten).")
        case .disconnected:
            return String(localized: "Die Verbindung zum Gerät ist abgerissen.")
        case .aborted:
            return String(localized: "Der Vorgang wurde abgebrochen, die Verbindung wird geschlossen.")
        }
    }
}

/// Dünne POSIX-Schicht über einer seriellen Schnittstelle (`/dev/cu.*`).
///
/// Die Schnittstelle wird **nicht-blockierend** geöffnet und ausschließlich
/// über `poll(2)` mit Zeitlimit bedient (`select` mit `fd_set` wäre ab
/// Deskriptor 1024 undefiniert). Blockierende Aufrufe auf dem
/// USB-CDC-Treiber von macOS lassen sich nicht abbrechen: ein Prozess, der in
/// `write(2)` hängt, bleibt im Kernel stecken, und jeder weitere `open(2)` auf
/// dasselbe Gerät hängt ebenfalls, bis das USB-Gerät neu enumeriert wird.
/// Alle Methoden sind synchron; der Aufrufer (ein Actor) serialisiert sie.
final class SerialPort: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    /// Von jedem Thread setzbar: laufende Lese-/Schreibschleifen brechen beim
    /// nächsten Warteschritt (≤ 0,25 s) ab. Der Deskriptor selbst wird nur vom
    /// Besitzer geschlossen – ein fremdes `close` mitten im `read` könnte eine
    /// inzwischen neu vergebene Nummer treffen.
    private let abortFlag = Mutex(false)

    func abort() { abortFlag.withLock { $0 = true } }
    var isAborted: Bool { abortFlag.withLock { $0 } }

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    var isOpen: Bool { fd >= 0 }

    func open() throws {
        guard fd < 0 else { return }
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw SerialPortError.openFailed(path: path, errno: errno) }

        // Exklusiv: ein zweiter Prozess soll nicht dazwischenfunken.
        _ = ioctl(handle, TIOCEXCL)

        var options = termios()
        guard tcgetattr(handle, &options) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialPortError.configurationFailed(errno: code)
        }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        withUnsafeMutablePointer(to: &options.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(handle, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialPortError.configurationFailed(errno: code)
        }
        tcflush(handle, TCIOFLUSH)
        fd = handle
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    /// Verwirft alles, was bereits im Empfangspuffer liegt.
    func drain(for duration: TimeInterval = 0.2) {
        guard fd >= 0 else { return }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let chunk = (try? read(max: 4096, timeout: 0.05)) ?? Data()
            if chunk.isEmpty { break }
        }
    }

    // MARK: - Schreiben

    func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialPortError.notOpen }
        guard !isAborted else { throw SerialPortError.aborted }
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                guard !isAborted else { throw SerialPortError.aborted }
                guard try waitWritable(timeout: 5) else {
                    throw SerialPortError.timeout(waitingFor: "Schreibbereitschaft", received: offset)
                }
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw SerialPortError.writeFailed(errno: errno)
                }
                offset += written
            }
        }
    }

    /// Schreibt in kleinen Paketen mit Pause dazwischen. `sent` erfährt nach
    /// jedem Paket, wie viele Bytes vollständig hinaus sind.
    func writePaced(_ data: Data, packetSize: Int, pause: TimeInterval, sent: ((Int) -> Void)? = nil) throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + packetSize, data.count)
            try write(data.subdata(in: data.startIndex + offset..<data.startIndex + end))
            offset = end
            sent?(offset)
            if offset < data.count { Thread.sleep(forTimeInterval: pause) }
        }
    }

    func write(_ string: String) throws {
        try write(Data(string.utf8))
    }

    // MARK: - Lesen

    /// Liest bis zu `max` Bytes; eine leere Antwort heißt „Zeit abgelaufen“.
    func read(max: Int, timeout: TimeInterval) throws -> Data {
        guard fd >= 0 else { throw SerialPortError.notOpen }
        guard !isAborted else { throw SerialPortError.aborted }
        guard try waitReadable(timeout: timeout) else { return Data() }
        var buffer = Data(count: max)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.read(fd, base, max)
        }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return Data() }
            throw SerialPortError.readFailed(errno: errno)
        }
        if count == 0 {
            // Bei einem gelöschten Gerät meldet select „lesbar“, read liefert 0.
            throw SerialPortError.disconnected
        }
        buffer.count = count
        return buffer
    }

    /// Liest, bis `marker` im Datenstrom vorkommt, und liefert alles bis
    /// einschließlich des Markers. `maxBytes` begrenzt den Puffer.
    func readUntil(_ marker: Data, timeout: TimeInterval, maxBytes: Int = 4_000_000) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var searchStart = 0
        while true {
            if buffer.count >= marker.count {
                let from = max(0, searchStart - marker.count)
                if let range = buffer.range(of: marker, in: from..<buffer.count) {
                    return buffer.prefix(range.upperBound)
                }
                searchStart = buffer.count
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, buffer.count < maxBytes else {
                throw SerialPortError.timeout(
                    waitingFor: String(decoding: marker, as: UTF8.self)
                        .replacingOccurrences(of: "\r\n", with: "⏎"),
                    received: buffer.count)
            }
            let chunk = try read(max: 65536, timeout: min(remaining, 0.25))
            buffer.append(chunk)
        }
    }

    /// Liest, bis einer der Marker auftaucht, und liefert alles Gelesene.
    func readUntil(anyOf markers: [Data], timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while true {
            if markers.contains(where: { buffer.range(of: $0) != nil }) { return buffer }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SerialPortError.timeout(waitingFor: "Antwort", received: buffer.count)
            }
            buffer.append(try read(max: 65536, timeout: min(remaining, 0.25)))
        }
    }

    /// Liest genau `count` Bytes.
    func readExactly(_ count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SerialPortError.timeout(waitingFor: "\(count) Bytes", received: buffer.count)
            }
            let chunk = try read(max: count - buffer.count, timeout: min(remaining, 0.25))
            buffer.append(chunk)
        }
        return buffer
    }

    // MARK: - poll

    private func waitReadable(timeout: TimeInterval) throws -> Bool {
        try wait(timeout: timeout, events: Int16(POLLIN))
    }

    private func waitWritable(timeout: TimeInterval) throws -> Bool {
        try wait(timeout: timeout, events: Int16(POLLOUT))
    }

    private func wait(timeout: TimeInterval, events: Int16) throws -> Bool {
        var entry = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(max(0, min(timeout, 3600)) * 1000)
        let result = poll(&entry, 1, milliseconds)
        if result < 0 {
            if errno == EINTR { return false }
            throw SerialPortError.readFailed(errno: errno)
        }
        if result > 0, entry.revents & Int16(POLLNVAL) != 0 {
            // macOS nennt in `man 2 poll` „unterstützt keine Geräte“; für
            // tty-Geräte (auch Ptys, geprüft 27.10.2026) klappt es. Meldet ein
            // Treiber trotzdem POLLNVAL, auf select ausweichen – solange die
            // Deskriptornummer in ein fd_set passt.
            return try selectWait(timeout: timeout, forWrite: events == Int16(POLLOUT))
        }
        // POLLHUP/POLLERR (Gerät weg) als „bereit“ melden: das folgende
        // read/write liefert dann den eigentlichen Fehler.
        return result > 0
    }

    private func selectWait(timeout: TimeInterval, forWrite: Bool) throws -> Bool {
        guard fd < FD_SETSIZE else { throw SerialPortError.notOpen }
        var set = fd_set()
        fdZero(&set)
        fdSet(fd, &set)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        let result = forWrite
            ? select(fd + 1, nil, &set, nil, &tv)
            : select(fd + 1, &set, nil, nil, &tv)
        if result < 0 {
            if errno == EINTR { return false }
            throw SerialPortError.readFailed(errno: errno)
        }
        return result > 0
    }
}

// fd_set-Helfer: die C-Makros FD_ZERO/FD_SET sind in Swift nicht verfügbar.
private func fdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
    }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let bitsPerWord = MemoryLayout<Int32>.size * 8
    let index = Int(fd) / bitsPerWord
    let bit = Int32(1) << (Int32(fd) % Int32(bitsPerWord))
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / bitsPerWord) { words in
            words[index] |= bit
        }
    }
}
