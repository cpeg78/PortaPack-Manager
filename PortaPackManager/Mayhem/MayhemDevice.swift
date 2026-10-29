import CoreGraphics
import Foundation

/// Angaben aus `info`.
struct MayhemInfo: Sendable, Equatable {
    var mayhemVersion: String = ""
    var hackRFBoardRevision: String = ""
    var deviceName: String = ""      // „HackRF One“, „HackRF Pro“, … (nur neuere Firmware)
    var buildTime: String = ""
    var referenceSource: String = ""
    var referenceFrequency: String = ""
    var kernel: String = ""
    var board: String = ""
    var raw: [String: String] = [:]

    /// Gerätetyp im Sinne der Release-Assets: `hackrf`, `hpro` oder `portarf`.
    /// Fehlt die `Device:`-Zeile (ältere Firmware), ist das nur eine Annahme –
    /// für Firmware-Entscheidungen `reportedDeviceType` nehmen.
    var deviceType: DeviceType {
        DeviceType(deviceName: deviceName)
    }

    /// Gerätetyp nur, wenn das Gerät ihn selbst meldet; sonst `nil`.
    var reportedDeviceType: DeviceType? {
        deviceName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : DeviceType(deviceName: deviceName)
    }

    var version: FirmwareVersion { FirmwareVersion(string: mayhemVersion) }

    static func parse(_ text: String) -> MayhemInfo {
        var info = MayhemInfo()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            info.raw[key] = value
            switch key {
            case "Mayhem Version": info.mayhemVersion = value
            case "HackRF Board Rev": info.hackRFBoardRevision = value
            case "Device": info.deviceName = value
            case "Build time": info.buildTime = value
            case "Reference Source": info.referenceSource = value
            case "Reference Freq": info.referenceFrequency = value
            case "Kernel": info.kernel = value
            case "Board": info.board = value
            default: break
            }
        }
        return info
    }
}

/// Die drei Hardware-Varianten, für die Mayhem Firmware baut.
enum DeviceType: String, CaseIterable, Sendable, Identifiable {
    case hackrf, hpro, portarf

    var id: String { rawValue }

    init(deviceName: String) {
        let name = deviceName.lowercased()
        if name.contains("pro") { self = .hpro }
        else if name.contains("portarf") { self = .portarf }
        else { self = .hackrf }
    }

    var displayName: String {
        switch self {
        case .hackrf: "HackRF One"
        case .hpro: "HackRF Pro"
        case .portarf: "PortaRF"
        }
    }

    /// Größe des SPI-Flashs, soweit belegt: HackRF One W25Q80 = 1 MiB (das
    /// Mayhem-Abbild hat genau 1 MiB), Pro-Abbilder haben 4 MiB. PortaRF
    /// unbekannt.
    var flashCapacity: Int? {
        switch self {
        case .hackrf: 0x10_0000
        case .hpro: 0x40_0000
        case .portarf: nil
        }
    }
}

/// Eintrag auf der SD-Karte.
struct SDEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
}

/// Die acht Tasten, die `button <n>` auslöst.
enum DeviceButton: Int, CaseIterable, Sendable {
    case right = 1, left = 2, down = 3, up = 4, select = 5, dfu = 6, encoderLeft = 7, encoderRight = 8

    var label: String {
        switch self {
        case .right: String(localized: "Rechts")
        case .left: String(localized: "Links")
        case .down: String(localized: "Runter")
        case .up: String(localized: "Hoch")
        case .select: String(localized: "OK")
        case .dfu: "DFU"
        case .encoderLeft: String(localized: "Drehrad −")
        case .encoderRight: String(localized: "Drehrad +")
        }
    }
}

/// Ein Bildschirminhalt (RGBA, 8 Bit je Kanal).
struct ScreenFrame: Sendable {
    let width: Int
    let height: Int
    let rgba: Data

    static let portaPackWidth = 240
    static let portaPackHeight = 320

    /// Dekodiert die Antwort von `screenframeshort`: je Pixel ein druckbares
    /// Zeichen, Wert − 32 = `rr gg bb` mit zwei Bit je Kanal; je Zeile `\r\n`.
    static func decodeShort(_ payload: Data, width: Int, height: Int) -> ScreenFrame? {
        let stride = width + 2
        guard payload.count >= stride * height else { return nil }
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var o = 0
                for y in 0..<height {
                    let rowStart = y * stride
                    for x in 0..<width {
                        let value = Int(input[rowStart + x]) - 32
                        let r = (value >> 4) & 0x3
                        let g = (value >> 2) & 0x3
                        let b = value & 0x3
                        out[o] = UInt8(r * 85)
                        out[o + 1] = UInt8(g * 85)
                        out[o + 2] = UInt8(b * 85)
                        out[o + 3] = 255
                        o += 4
                    }
                }
            }
        }
        return ScreenFrame(width: width, height: height, rgba: rgba)
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Ergebnis von `flash`: angenommen oder Verbindung dabei abgerissen.
enum FlashStart: Sendable, Equatable {
    /// „Flashing started“ kam an.
    case started
    /// Die Schnittstelle verschwand, bevor eine Antwort kam – das Gerät
    /// entpackt/flasht vermutlich schon (wie beim Umschalten auf SD over USB).
    case connectionLost
}

/// Hochsprachliche Sicht auf ein PortaPack im Mayhem-Modus.
///
/// Läuft auf einer eigenen seriellen Warteschlange statt im Concurrency-Pool:
/// ein Upload über `fwb` blockiert minutenlang synchron (64-Byte-Pakete mit
/// Pause) und belegte sonst einen der wenigen Pool-Threads.
actor MayhemDevice {
    let path: String
    private let shell: MayhemShell
    private let queue = DispatchSerialQueue(label: "de.christiangolz.portapackmanager.mayhem", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(path: String, log: (@Sendable (ConsoleLine) -> Void)? = nil) throws {
        self.path = path
        shell = try MayhemShell(path: path, log: log)
    }

    /// Öffnet die Schnittstelle abseits des Aufrufers mit Zeitlimit – ein
    /// verklemmter CDC-Treiber lässt `open` sonst unbegrenzt hängen.
    static func open(path: String, log: (@Sendable (ConsoleLine) -> Void)? = nil,
                     timeout: TimeInterval = 5) async throws -> MayhemDevice {
        try await BlockingCall.run(String(localized: "Die USB-Verbindung zum PortaPack"), timeout: timeout,
                                   lateResult: { device in Task { await device.close() } }) {
            try MayhemDevice(path: path, log: log)
        }
    }

    func connect() throws {
        try shell.synchronize()
    }

    func close() {
        shell.close()
    }

    /// Bricht einen laufenden Befehl (etwa einen langen Upload) ab, ohne auf
    /// den Actor zu warten; danach `close()`.
    nonisolated func interrupt() {
        shell.abort()
    }

    /// Freier Befehl für die Konsole.
    func raw(_ command: String, timeout: TimeInterval = 10) throws -> String {
        try shell.run(command, timeout: timeout)
    }

    // MARK: - Information

    func info() throws -> MayhemInfo {
        MayhemInfo.parse(try shell.run("info"))
    }

    func systemInfo() throws -> [(String, String)] {
        Self.keyValues(try shell.run("sysinfo"))
    }

    func radioInfo() throws -> [(String, String)] {
        Self.keyValues(try shell.run("radioinfo"))
    }

    func clock() throws -> String {
        let text = try shell.run("rtcget")
        return text.replacingOccurrences(of: "Current time:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setClock(_ date: Date = Date()) throws {
        let parts = Calendar.current.dateComponents(in: .current, from: date.addingTimeInterval(1))
        let command = String(format: "rtcset %04d %02d %02d %02d %02d %02d",
                             parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1,
                             parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        try expectOK(command)
    }

    func screenResolution() throws -> (width: Int, height: Int) {
        let text = try shell.run("getres")
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return (ScreenFrame.portaPackWidth, ScreenFrame.portaPackHeight) }
        return (numbers[0], numbers[1])
    }

    // MARK: - Bildschirm und Bedienung

    func screenFrame(width: Int = ScreenFrame.portaPackWidth, height: Int = ScreenFrame.portaPackHeight) throws -> ScreenFrame {
        let payload = try shell.runFixedLength(
            "screenframeshort", byteCount: (width + 2) * height, trailer: "ok\r\nch> ", timeout: 15)
        guard let frame = ScreenFrame.decodeShort(payload, width: width, height: height) else {
            throw MayhemError.unexpectedResponse(String(localized: "Bildschirmdaten unvollständig"))
        }
        return frame
    }

    func press(_ button: DeviceButton) throws {
        try expectOK("button \(button.rawValue)")
    }

    func touch(x: Int, y: Int) throws {
        try expectOK("touch \(x) \(y)")
    }

    func type(_ text: String) throws {
        let hex = text.unicodeScalars.compactMap { scalar -> String? in
            guard scalar.isASCII else { return nil }
            return String(format: "%02X", scalar.value)
        }.joined()
        guard !hex.isEmpty else { return }
        try expectOK("keyboard \(hex)")
    }

    func appList() throws -> [(id: String, name: String)] {
        try shell.run("applist").split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    func startApp(_ id: String) throws {
        try expectOK("appstart \(id)")
    }

    func setFrequency(_ hz: UInt64) throws {
        try expectOK("setfreq \(hz)")
    }

    // MARK: - Dateisystem

    /// Grenzen der Mayhem-Shell (`firmware/application/shell.hpp`): Zeilen
    /// bis 63 Zeichen – der Rest wird stillschweigend verworfen – und
    /// höchstens 6 Argumente. Die Dateibefehle fügen die Argumente mit genau
    /// einem Leerzeichen wieder zum Pfad zusammen; mehrfache Leerzeichen und
    /// Tabulatoren gehen dabei verloren.
    nonisolated static let maximumLineLength = 63
    nonisolated static let maximumArguments = 6

    /// Grund, warum `command path` die Shell nicht unversehrt erreicht, sonst `nil`.
    nonisolated static func shellProblem(command: String, path: String) -> String? {
        let length = command.utf8.count + 1 + path.utf8.count
        if length > maximumLineLength {
            return String(localized: "Pfad zu lang (\(length) von höchstens \(maximumLineLength) Zeichen samt Befehl)")
        }
        if path.contains("\t") || path.contains("  ") || path.hasPrefix(" ") || path.hasSuffix(" ") || path.contains("/ ") || path.contains(" /") {
            return String(localized: "Tabulator oder mehrere Leerzeichen hintereinander im Namen")
        }
        let words = path.split(separator: " ").count
        if words > maximumArguments {
            return String(localized: "zu viele Leerzeichen im Pfad (\(words - 1), höchstens \(maximumArguments - 1))")
        }
        return nil
    }

    /// Befehlszeile mit Pfad, vorher gegen die Grenzen der Shell geprüft.
    private func pathCommand(_ command: String, _ path: String) throws -> String {
        if let reason = Self.shellProblem(command: command, path: path) {
            throw MayhemError.pathNotReachable(path: path, reason: reason)
        }
        return "\(command) \(path)"
    }

    func list(_ directory: String) throws -> [SDEntry] {
        let text = try shell.run(pathCommand("ls", directory), timeout: 20)
        let base = directory == "/" ? "" : directory
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("usage"), !raw.hasPrefix("Error") else { return nil }
            if raw.hasSuffix("/") {
                let name = String(raw.dropLast())
                return SDEntry(name: name, path: base + "/" + name, isDirectory: true)
            }
            let name = raw.hasSuffix(" *") ? String(raw.dropLast(2)) : raw
            return SDEntry(name: name, path: base + "/" + name, isDirectory: false)
        }
    }

    func fileSize(_ path: String) throws -> Int {
        let text = try shell.run(pathCommand("filesize", path))
        guard let line = text.split(whereSeparator: \.isNewline).first, let size = Int(line.trimmingCharacters(in: .whitespaces)) else {
            throw MayhemError.fileNotFound(path)
        }
        return size
    }

    func makeDirectory(_ path: String) throws {
        let text = try shell.run(pathCommand("mkdir", path))
        guard text.contains("ok") || text.contains("already exists") else {
            throw MayhemError.commandFailed(command: "mkdir \(path)", response: text)
        }
    }

    func remove(_ path: String) throws {
        let command = try pathCommand("unlink", path)
        // Eine offene Datei zu löschen verklemmt den Dateizugriff bis zum
        // Neustart („insanity detected“) – vorsorglich schließen.
        _ = try? shell.run("fclose", timeout: 3)
        try expectOK(command)
    }

    /// CRC-32 der Datei, wie das Gerät sie berechnet (MSB-first, Polynom
    /// 0x04C11DB7, Start- und Endwert 0xFFFFFFFF – also CRC-32/BZIP2).
    func crc32(_ path: String) throws -> UInt32 {
        let text = try shell.run(pathCommand("crc32", path), timeout: 120)
        guard let range = text.range(of: "CRC32: 0x") else {
            throw MayhemError.commandFailed(command: "crc32", response: text)
        }
        let hex = text[range.upperBound...].prefix(8)
        guard let value = UInt32(hex, radix: 16) else { throw MayhemError.unexpectedResponse(text) }
        return value
    }

    /// Lädt eine Datei auf die SD-Karte. `chunkSize` Bytes je `fwb`-Aufruf.
    func upload(_ data: Data, to path: String, chunkSize: Int = 4096,
                progress: @Sendable (Int, Int) -> Void) throws {
        let open = try pathCommand("fopen", path)
        _ = try? shell.run("fclose", timeout: 3)
        try expectOK(open)
        do {
            try expectOK("fseek 0")
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.count)
                try shell.writeBinaryChunk(data[offset..<end])
                offset = end
                progress(offset, data.count)
            }
            try expectOK("fclose")
        } catch {
            _ = try? shell.run("fclose", timeout: 3)
            throw error
        }
    }

    /// Liest eine Datei von der SD-Karte (hexkodiert über `fread`).
    func download(_ path: String, progress: @Sendable (Int, Int) -> Void) throws -> Data {
        let size = try fileSize(path)
        _ = try? shell.run("fclose", timeout: 3)
        try expectOK(pathCommand("fopen", path))
        defer { _ = try? shell.run("fclose", timeout: 3) }
        try expectOK("fseek 0")
        var result = Data()
        result.reserveCapacity(size)
        let chunk = 62 * 16
        while result.count < size {
            try Task.checkCancellation()
            let want = min(chunk, size - result.count)
            let text = try shell.run("fread \(want)", timeout: 20)
            let hex = text.split(whereSeparator: \.isNewline).filter { $0 != "ok" }.joined()
            guard let bytes = Data(hexString: hex), !bytes.isEmpty else {
                throw MayhemError.unexpectedResponse(String(localized: "Die Datei lieferte keine Daten."))
            }
            result.append(bytes)
            progress(result.count, size)
        }
        return result
    }

    // MARK: - Firmware und Betriebsmodus

    /// Startet das Flashen einer Datei auf der SD-Karte (`.bin` oder
    /// `.ppfw.tar`). Das Gerät entpackt, prüft, flasht und startet neu – die
    /// serielle Verbindung bricht dabei ab.
    func flash(_ path: String) throws -> FlashStart {
        // Nach „Flashing started“ kommt keine Eingabeaufforderung mehr: das
        // Gerät entpackt, flasht und startet neu. Fehlschläge („file not
        // found", Aufrufhinweis) enden dagegen mit der Eingabeaufforderung.
        let command = try pathCommand("flash", path)
        let text: String
        do {
            text = try shell.runUntil(command, markers: ["Flashing started", MayhemShell.prompt], timeout: 15)
        } catch SerialPortError.readFailed, SerialPortError.disconnected {
            // Wie bei SD over USB: die Schnittstelle kann verschwinden, bevor
            // die Meldung ankommt. Kein Fehler melden – das Gerät flasht
            // womöglich gerade, und Abstecken wäre jetzt das Schlimmste.
            shell.close()
            return .connectionLost
        }
        if text.contains("file not found") { throw MayhemError.fileNotFound(path) }
        guard text.contains("Flashing started") else {
            throw MayhemError.commandFailed(command: "flash \(path)", response: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .started
    }

    /// Wechselt in den HackRF-Modus (das Gerät meldet sich neu als HackRF One).
    /// Startet „SD over USB“: Mayhem öffnet die App `sdusb.ppma` und löst sie
    /// aus; danach meldet sich das Gerät als Kartenleser neu an.
    func startSDOverUSB() throws {
        let text: String
        do {
            text = try shell.runUntil("sd_over_usb", markers: ["ok\r\n", "Failed", MayhemShell.prompt], timeout: 15)
        } catch SerialPortError.readFailed, SerialPortError.disconnected {
            // Das Gerät schaltet so schnell um, dass die Schnittstelle oft
            // verschwindet, bevor „ok“ ankommt – das ist der Erfolgsfall.
            shell.close()
            return
        }
        guard text.contains("ok") else {
            throw MayhemError.commandFailed(
                command: "sd_over_usb",
                response: text.contains("Failed")
                    ? String(localized: "Die App „SD over USB“ (APPS/sdusb.ppma) fehlt oder startet nicht. Aktualisiere zuerst die Firmware.")
                    : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        shell.close()
    }

    func switchToHackRFMode() {
        try? shell.send("hackrf")
        shell.close()
    }

    func reboot() {
        try? shell.send("reboot")
        shell.close()
    }

    func rebootToDFU() {
        try? shell.send("dfu")
        shell.close()
    }

    // MARK: - Hilfen

    private func expectOK(_ command: String, timeout: TimeInterval = 10) throws {
        let text = try shell.run(command, timeout: timeout)
        // Bleibt eine Datei offen und wird gelöscht, verklemmt der Datei-
        // zugriff der Konsole („insanity detected“, „file already open“) –
        // das löst nur ein Neustart des Geräts.
        if text.contains("insanity") || (command.hasPrefix("fopen") && text.contains("already open")) {
            throw MayhemError.commandFailed(command: command,
                response: String(localized: "Der Dateizugriff des PortaPack hängt. Schalte das Gerät aus und wieder ein."))
        }
        guard text.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "ok" }) else {
            throw MayhemError.commandFailed(command: command, response: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    nonisolated static func keyValues(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].trimmingCharacters(in: .whitespaces),
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        self = data
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }
}
