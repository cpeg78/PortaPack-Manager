import CommonCrypto
import Foundation

// MARK: - Funkparameter

/// Modem-Voreinstellungen der Meshtastic-Firmware (`MeshRadio.h`,
/// `modemPresetToParams`, ohne „wide LoRa“ für 2,4 GHz).
enum MeshtasticPreset: String, CaseIterable, Identifiable, Sendable {
    case longFast, longSlow, longModerate, longTurbo
    case mediumSlow, mediumFast, mediumTurbo
    case shortSlow, shortFast, shortTurbo

    var id: Self { self }

    /// Anzeigename wie `DisplayFormatters::getModemPresetDisplayName` – zugleich
    /// der Kanalname des Standardkanals (bestimmt Frequenz und Kanal-Hash).
    var displayName: String {
        switch self {
        case .longFast: "LongFast"
        case .longSlow: "LongSlow"
        case .longModerate: "LongMod"
        case .longTurbo: "LongTurbo"
        case .mediumSlow: "MediumSlow"
        case .mediumFast: "MediumFast"
        case .mediumTurbo: "MediumTurbo"
        case .shortSlow: "ShortSlow"
        case .shortFast: "ShortFast"
        case .shortTurbo: "ShortTurbo"
        }
    }

    var spreadingFactor: Int {
        switch self {
        case .shortTurbo, .shortFast: 7
        case .shortSlow: 8
        case .mediumFast, .mediumTurbo: 9
        case .mediumSlow: 10
        case .longFast, .longModerate, .longTurbo: 11
        case .longSlow: 12
        }
    }

    var bandwidthKHz: Double {
        switch self {
        case .shortTurbo, .mediumTurbo, .longTurbo: 500
        case .longModerate, .longSlow: 125
        default: 250
        }
    }

    /// Nenner der Koderate (5 = 4/5 … 8 = 4/8).
    var codingRateDenominator: Int {
        switch self {
        case .longTurbo, .longModerate, .longSlow: 8
        default: 5
        }
    }

    var parameters: LoRaParameters {
        LoRaParameters(spreadingFactor: spreadingFactor, bandwidth: bandwidthKHz * 1000, syncWord: MeshtasticRegion.syncWord)
    }

    var summary: String {
        String(format: "SF%d · %@ kHz · 4/%d", spreadingFactor,
               bandwidthKHz.formatted(.number.precision(.fractionLength(0...1))), codingRateDenominator)
    }
}

/// Frequenzbereiche der Firmware (`RadioInterface.cpp`, `RDEF`).
struct MeshtasticRegion: Identifiable, Hashable, Sendable {
    let code: String
    let title: String
    let startMHz: Double
    let endMHz: Double
    let spacingMHz: Double
    let paddingMHz: Double
    let presets: [MeshtasticPreset]

    var id: String { code }

    static let syncWord: UInt8 = 0x2B
    static let preambleLength = 16

    static let eu868 = MeshtasticRegion(code: "EU_868", title: "EU 868 MHz", startMHz: 869.4, endMHz: 869.65,
                                        spacingMHz: 0, paddingMHz: 0,
                                        presets: [.longFast, .longSlow, .mediumSlow, .mediumFast, .shortSlow, .shortFast, .longModerate])
    static let eu433 = MeshtasticRegion(code: "EU_433", title: "EU 433 MHz", startMHz: 433.0, endMHz: 434.0,
                                        spacingMHz: 0, paddingMHz: 0,
                                        presets: [.longFast, .longSlow, .mediumSlow, .mediumFast, .shortSlow, .shortFast,
                                                  .longModerate, .shortTurbo, .longTurbo, .mediumTurbo])
    static let all = [eu868, eu433]

    /// Zahl der Frequenzplätze für eine Bandbreite.
    func slotCount(bandwidthKHz: Double) -> Int {
        let width = spacingMHz + 2 * paddingMHz + bandwidthKHz / 1000
        return Int(((endMHz - startMHz + spacingMHz) / width).rounded())
    }

    /// Frequenz des Kanals: djb2-Hash des Kanalnamens modulo Platzzahl
    /// (`RadioInterface::applyModemConfig`). EU 868 hat bei 250 kHz nur
    /// einen Platz – LongFast liegt auf 869,525 MHz.
    func frequencyMHz(preset: MeshtasticPreset, channelName: String) -> Double {
        let bandwidth = preset.bandwidthKHz / 1000
        let width = spacingMHz + 2 * paddingMHz + bandwidth
        let slots = slotCount(bandwidthKHz: preset.bandwidthKHz)
        let slot = slots > 0 ? Int(Meshtastic.djb2(channelName) % UInt32(slots)) : 0
        return startMHz + bandwidth / 2 + paddingMHz + Double(slot) * width
    }
}

// MARK: - Kanal und Schlüssel

/// Ein Kanal mit Namen und Schlüssel (PSK).
struct MeshtasticChannel: Hashable, Sendable {
    let name: String
    /// Ausgeschriebener Schlüssel (16 oder 32 Bytes); leer = unverschlüsselt.
    let key: [UInt8]

    var hash: UInt8 { Meshtastic.xorHash(Array(name.utf8)) ^ Meshtastic.xorHash(key) }

    /// Aus der Base64-Kurzform, wie sie die Apps zeigen (Standard „AQ==“).
    init?(name: String, pskBase64: String) {
        let trimmed = pskBase64.trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: trimmed.isEmpty ? "" : trimmed) else { return nil }
        self.init(name: name, psk: [UInt8](data))
    }

    init(name: String, psk: [UInt8]) {
        self.name = name
        key = Meshtastic.expandKey(psk)
    }
}

// MARK: - Paket

/// Der unverschlüsselte 16-Byte-Kopf jedes Meshtastic-Funkpakets
/// (`PacketHeader` in `RadioInterface.h`, alle Zahlen little-endian).
struct MeshtasticHeader: Sendable, Equatable {
    var to: UInt32
    var from: UInt32
    var id: UInt32
    var flags: UInt8
    var channelHash: UInt8
    var nextHop: UInt8
    var relayNode: UInt8

    static let broadcast: UInt32 = 0xFFFF_FFFF

    var hopLimit: Int { Int(flags & 0x07) }
    var wantAck: Bool { flags & 0x08 != 0 }
    var viaMQTT: Bool { flags & 0x10 != 0 }
    var hopStart: Int { Int(flags >> 5) }
    /// Bisherige Sprünge (0 = direkt vom Absender gehört).
    var hopsTaken: Int? { hopStart >= hopLimit && hopStart > 0 ? hopStart - hopLimit : nil }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 16 else { return nil }
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        to = u32(0)
        from = u32(4)
        id = u32(8)
        flags = bytes[12]
        channelHash = bytes[13]
        nextHop = bytes[14]
        relayNode = bytes[15]
    }
}

/// Ein dekodiertes Funkpaket.
struct MeshtasticPacket: Sendable {
    var header: MeshtasticHeader
    /// Verschlüsselte (bzw. unverschlüsselte) Nutzdaten hinter dem Kopf.
    var encrypted: [UInt8]
    /// Passender Kanal, falls die Entschlüsselung gelang.
    var channel: String?
    var data: MeshtasticData?
}

/// Die `Data`-Nachricht (mesh.proto).
struct MeshtasticData: Sendable, Equatable {
    var portnum: Int
    var payload: [UInt8]
    var wantResponse = false
    var dest: UInt32?
    var source: UInt32?
    var requestID: UInt32?
    var replyID: UInt32?
    var emoji: UInt32?
    var bitfield: UInt64?

    init?(_ bytes: [UInt8]) {
        guard let message = ProtobufMessage(bytes), let port = message.varint(1),
              (1...511).contains(port) else { return nil }
        // Zufällige Bytes (falscher Schlüssel) ergeben fast nie eine gültige
        // Nachricht nur aus bekannten Feldern.
        guard message.fields.allSatisfy({ (1...10).contains($0.number) }) else { return nil }
        portnum = Int(port)
        payload = message.bytes(2) ?? []
        wantResponse = message.varint(3).map { $0 != 0 } ?? false
        dest = message.fixed32(4)
        source = message.fixed32(5)
        requestID = message.fixed32(6)
        replyID = message.fixed32(7)
        emoji = message.fixed32(8)
        bitfield = message.varint(9)
    }

    var content: MeshtasticContent { MeshtasticContent(portnum: portnum, payload: payload) }
}

// MARK: - Inhalte

struct MeshtasticPosition: Sendable, Equatable {
    var latitude: Double?
    var longitude: Double?
    var altitude: Int?
    var time: Date?
    var satellites: Int?
    var groundSpeed: Int?
    var precisionBits: Int?

    init(_ bytes: [UInt8]) {
        let m = ProtobufMessage(bytes)
        latitude = m?.fixed32(1).map { Double(Int32(bitPattern: $0)) * 1e-7 }
        longitude = m?.fixed32(2).map { Double(Int32(bitPattern: $0)) * 1e-7 }
        altitude = m?.varint(3).map { Int(Int32(truncatingIfNeeded: $0)) }
        time = m?.fixed32(4).flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil }
        groundSpeed = m?.varint(15).map { Int(clamping: $0) }
        satellites = m?.varint(19).map { Int(clamping: $0) }
        precisionBits = m?.varint(23).map { Int(clamping: $0) }
        if latitude == 0, longitude == 0 { latitude = nil; longitude = nil }
    }

    var hasFix: Bool { latitude != nil && longitude != nil }
}

struct MeshtasticUser: Sendable, Equatable {
    var id: String?
    var longName: String?
    var shortName: String?
    var hardware: Int?
    var role: Int?
    var hasPublicKey = false

    init(_ bytes: [UInt8]) {
        let m = ProtobufMessage(bytes)
        id = m?.string(1)
        longName = m?.string(2)
        shortName = m?.string(3)
        hardware = m?.varint(5).map { Int(clamping: $0) }
        role = m?.varint(7).map { Int(clamping: $0) }
        hasPublicKey = (m?.bytes(8)?.count ?? 0) > 0
    }

    var hardwareName: String? { hardware.map { Meshtastic.hardwareNames[$0] ?? String(localized: "Modell \($0)") } }
    var roleName: String? { role.map { Meshtastic.roleNames[$0] ?? String(localized: "Rolle \($0)") } }
}

/// Messwerte aus TELEMETRY_APP (telemetry.proto), soweit einfach darstellbar.
struct MeshtasticTelemetry: Sendable, Equatable {
    var kind: String
    var batteryLevel: Int?
    var voltage: Double?
    var channelUtilization: Double?
    var airUtilTx: Double?
    var uptime: Int?
    var temperature: Double?
    var humidity: Double?
    var pressure: Double?
    var readings: [String] = []

    init(_ bytes: [UInt8]) {
        let m = ProtobufMessage(bytes)
        if let device = m?.bytes(2).flatMap(ProtobufMessage.init) {
            kind = String(localized: "Gerät")
            batteryLevel = device.varint(1).map { Int(clamping: $0) }
            voltage = device.float(2).map(Double.init)
            channelUtilization = device.float(3).map(Double.init)
            airUtilTx = device.float(4).map(Double.init)
            uptime = device.varint(5).map { Int(clamping: $0) }
        } else if let environment = m?.bytes(3).flatMap(ProtobufMessage.init) {
            kind = String(localized: "Umwelt")
            temperature = environment.float(1).map(Double.init)
            humidity = environment.float(2).map(Double.init)
            pressure = environment.float(3).map(Double.init)
            voltage = environment.float(5).map(Double.init)
            if let gas = environment.float(4) { readings.append(String(format: String(localized: "Gas %.0f kΩ"), gas)) }
            if let current = environment.float(6) { readings.append(String(format: "%.0f mA", current)) }
            if let iaq = environment.varint(7) { readings.append("IAQ \(iaq)") }
            if let lux = environment.float(9) { readings.append(String(format: "%.0f lx", lux)) }
            if let wind = environment.float(14) { readings.append(String(format: String(localized: "Wind %.1f m/s"), wind)) }
        } else if m?.bytes(4) != nil {
            kind = String(localized: "Luftqualität")
        } else if m?.bytes(5) != nil {
            kind = String(localized: "Strom")
        } else if m?.bytes(6) != nil {
            kind = String(localized: "Lokale Statistik")
        } else if m?.bytes(7) != nil {
            kind = String(localized: "Gesundheit")
        } else if m?.bytes(8) != nil {
            kind = "Host"
        } else {
            kind = String(localized: "Telemetrie")
        }
        if let level = batteryLevel { readings.append(level > 100 ? String(localized: "Netzbetrieb") : String(localized: "Akku \(level) %")) }
        if let voltage { readings.append(String(format: "%.2f V", voltage)) }
        if let temperature { readings.append(String(format: "%.1f °C", temperature)) }
        if let humidity { readings.append(String(format: String(localized: "%.0f %% rF"), humidity)) }
        if let pressure { readings.append(String(format: "%.0f hPa", pressure)) }
        if let channelUtilization { readings.append(String(format: String(localized: "Kanal belegt %.1f %%"), channelUtilization)) }
        if let airUtilTx { readings.append(String(format: String(localized: "Sendezeit %.1f %%"), airUtilTx)) }
        if let uptime { readings.append(String(localized: "läuft seit \(Meshtastic.duration(uptime))")) }
    }
}

enum MeshtasticContent: Sendable, Equatable {
    case text(String)
    case position(MeshtasticPosition)
    case nodeInfo(MeshtasticUser)
    case telemetry(MeshtasticTelemetry)
    case other(portnum: Int, bytes: Int)

    init(portnum: Int, payload: [UInt8]) {
        switch portnum {
        case 1: self = .text(String(decoding: payload, as: UTF8.self))
        case 3: self = .position(MeshtasticPosition(payload))
        case 4: self = .nodeInfo(MeshtasticUser(payload))
        case 67: self = .telemetry(MeshtasticTelemetry(payload))
        default: self = .other(portnum: portnum, bytes: payload.count)
        }
    }

    var summary: String {
        switch self {
        case .text(let text): return text
        case .position(let p):
            guard let lat = p.latitude, let lon = p.longitude else { return String(localized: "Position ohne GPS-Fix") }
            var text = String(format: "%.5f, %.5f", lat, lon)
            if let alt = p.altitude { text += " · \(alt) m" }
            if let sats = p.satellites { text += String(localized: " · \(sats) Satelliten") }
            return text
        case .nodeInfo(let u):
            return [u.longName, u.shortName.map { "(\($0))" }, u.hardwareName].compactMap { $0 }.joined(separator: " ")
        case .telemetry(let t):
            return ([t.kind] + t.readings).joined(separator: " · ")
        case .other(_, let bytes):
            return String(localized: "\(bytes) Byte")
        }
    }
}

// MARK: - Hilfsfunktionen

enum Meshtastic {
    /// Der öffentlich bekannte Standardschlüssel (`defaultpsk` in `Channels.h`),
    /// Kurzform „AQ==“ (Index 1).
    static let defaultKey: [UInt8] = [0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
                                      0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01]

    /// djb2 (Dan Bernstein) wie `hash()` in `RadioInterface.cpp`.
    static func djb2(_ text: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in text.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return hash
    }

    static func xorHash(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0, ^) }

    /// Kurzschlüssel wie `Channels::getKey`: 1 Byte = Index in die Familie
    /// des Standardschlüssels (0 = aus), kurze Schlüssel mit Nullen auf 16
    /// bzw. 32 Bytes aufgefüllt.
    static func expandKey(_ psk: [UInt8]) -> [UInt8] {
        switch psk.count {
        case 0: return []
        case 1:
            guard psk[0] != 0 else { return [] }
            var key = defaultKey
            key[15] = key[15] &+ psk[0] &- 1
            return key
        case 2..<16: return psk + Array(repeating: 0, count: 16 - psk.count)
        case 16: return psk
        case 17..<32: return psk + Array(repeating: 0, count: 32 - psk.count)
        default: return Array(psk.prefix(32))
        }
    }

    /// Nonce aus `CryptoEngine::initNonce`: Paket-ID als 64 Bit LE, Absender
    /// als 32 Bit LE, Rest 0. Die letzten 4 Bytes dienen als Blockzähler.
    static func nonce(packetID: UInt32, from: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 16)
        for k in 0..<4 {
            nonce[k] = UInt8(packetID >> UInt32(8 * k) & 0xFF)
            nonce[8 + k] = UInt8(from >> UInt32(8 * k) & 0xFF)
        }
        return nonce
    }

    /// AES-CTR mit CommonCrypto: Zählerblöcke im ECB-Modus verschlüsseln und
    /// mit den Daten verknüpfen. Der Zähler läuft wie bei rweather `CTR`
    /// (`setCounterSize(4)`) big-endian in den letzten 4 Bytes.
    static func aesCTR(key: [UInt8], counter initial: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard [16, 24, 32].contains(key.count), initial.count == 16 else { return nil }
        guard !data.isEmpty else { return [] }
        let blocks = (data.count + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        var counter = initial
        for b in 0..<blocks {
            counters.replaceSubrange((b * 16)..<(b * 16 + 16), with: counter)
            var k = 15
            while k >= 12 {
                counter[k] &+= 1
                if counter[k] != 0 { break }
                k -= 1
            }
        }
        var stream = [UInt8](repeating: 0, count: counters.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, counters, counters.count, &stream, stream.count, &moved)
        guard status == kCCSuccess, moved == counters.count else { return nil }
        return zip(data, stream).map { $0 ^ $1 }
    }

    /// Paket aus einem LoRa-Rahmen; versucht alle Kanäle mit passendem Hash.
    static func decode(_ frame: [UInt8], channels: [MeshtasticChannel]) -> MeshtasticPacket? {
        guard let header = MeshtasticHeader(frame) else { return nil }
        let body = Array(frame.dropFirst(16))
        var packet = MeshtasticPacket(header: header, encrypted: body)
        for channel in channels where channel.hash == header.channelHash {
            let plain = channel.key.isEmpty ? body
                : aesCTR(key: channel.key, counter: nonce(packetID: header.id, from: header.from), data: body)
            if let plain, let data = MeshtasticData(plain) {
                packet.channel = channel.name
                packet.data = data
                break
            }
        }
        return packet
    }

    static func nodeName(_ number: UInt32) -> String {
        number == MeshtasticHeader.broadcast ? String(localized: "alle") : String(format: "!%08x", number)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400) d \(seconds % 86_400 / 3600) h" }
        if seconds >= 3600 { return "\(seconds / 3600) h \(seconds % 3600 / 60) min" }
        return "\(seconds / 60) min"
    }

    /// Portnummern (portnums.proto).
    static let portNames: [Int: String] = [
        1: String(localized: "Text"), 2: String(localized: "Fernsteuerung GPIO"), 3: "Position", 4: String(localized: "Knoteninfo"), 5: String(localized: "Routing/Bestätigung"),
        6: String(localized: "Verwaltung"), 7: String(localized: "Text (komprimiert)"), 8: String(localized: "Wegpunkt"), 9: "Audio", 10: String(localized: "Melder"), 11: String(localized: "Alarm"),
        12: String(localized: "Schlüsselprüfung"), 32: String(localized: "Antwort"), 33: String(localized: "IP-Tunnel"), 34: "Paxcounter", 35: "Store & Forward++",
        36: String(localized: "Knotenstatus"), 37: String(localized: "Mesh-Bake"), 64: String(localized: "Seriell"), 65: "Store & Forward", 66: String(localized: "Reichweitentest"),
        67: String(localized: "Telemetrie"), 68: "ZPS", 69: "Simulator", 70: "Traceroute", 71: String(localized: "Nachbarn"), 72: "ATAK",
        73: String(localized: "Kartenbericht"), 74: String(localized: "Leistungstest"), 76: "Reticulum", 77: "Cayenne", 78: "ATAK v2",
        112: String(localized: "Gruppenalarm"), 256: String(localized: "Privat"), 257: String(localized: "ATAK-Weiterleitung"),
    ]

    static func portName(_ port: Int) -> String { portNames[port] ?? String(localized: "Port \(port)") }

    static let roleNames: [Int: String] = [
        0: "Client", 1: String(localized: "Client stumm"), 2: "Router", 3: "Router-Client", 4: "Repeater", 5: "Tracker",
        6: "Sensor", 7: "TAK", 8: String(localized: "Client versteckt"), 9: "Lost & Found", 10: "TAK-Tracker",
        11: String(localized: "Router spät"), 12: String(localized: "Client-Basis"),
    ]

    /// Häufige Geräte aus `HardwareModel` (mesh.proto).
    static let hardwareNames: [Int: String] = [
        0: String(localized: "Unbekannt"), 1: "T-LoRa V2", 2: "T-LoRa V1", 3: "T-LoRa V2.1-1.6", 4: "T-Beam", 5: "Heltec V2.0",
        6: "T-Beam 0.7", 7: "T-Echo", 8: "T-LoRa V1.3", 9: "RAK4631", 10: "Heltec V2.1", 11: "Heltec V1",
        12: "T-Beam S3 Core", 13: "RAK11200", 14: "Nano G1", 15: "T-LoRa V2.1-1.8", 16: "T-LoRa T3-S3",
        17: "Nano G1 Explorer", 18: "Nano G2 Ultra", 25: "Station G1", 26: "RAK11310", 31: "Station G2",
        37: "Portduino (Linux)", 39: "DIY V1", 42: "M5Stack", 43: "Heltec V3", 44: "Heltec Wireless Stick Lite V3",
        47: "Raspberry Pi Pico", 48: "Heltec Wireless Tracker", 49: "Heltec Wireless Paper", 50: "T-Deck",
        51: "T-Watch S3", 53: "Heltec HT62", 58: "Heltec Wireless Tracker 1.0", 64: "RadioMaster Bandit Nano",
        66: "Heltec Vision Master T190", 67: "Heltec Vision Master E213", 68: "Heltec Vision Master E290",
        69: "Heltec Mesh Node T114", 70: "SenseCAP Indicator", 71: "Seeed Tracker T1000-E", 72: "RAK3172",
        73: "Wio-E5", 81: "Seeed XIAO S3", 84: "WisMesh Tap", 88: "XIAO nRF52 Kit", 89: "ThinkNode M1",
        90: "ThinkNode M2", 94: "Heltec Mesh Pocket", 95: "Seeed Solar Node", 107: "ThinkNode M5",
        109: "T-Echo Lite", 110: "Heltec V4", 255: String(localized: "Privat/DIY"),
    ]
}

// MARK: - Protobuf (minimal)

/// Liest eine Protobuf-Nachricht flach ein: Feldnummer und Wert, keine Schemata.
struct ProtobufMessage: Sendable {
    enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    struct Field: Sendable {
        let number: Int
        let value: Value
    }

    let fields: [Field]

    /// `nil` bei abgeschnittenen Daten oder unbekanntem Leitungstyp.
    init?(_ bytes: [UInt8]) {
        var fields: [Field] = []
        var index = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = readVarint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let value = readVarint() else { return nil }
                fields.append(Field(number: number, value: .varint(value)))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                var value: UInt64 = 0
                for k in 0..<8 { value |= UInt64(bytes[index + k]) << UInt64(8 * k) }
                index += 8
                fields.append(Field(number: number, value: .fixed64(value)))
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return nil }
                fields.append(Field(number: number, value: .bytes(Array(bytes[index..<(index + Int(length))]))))
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                var value: UInt32 = 0
                for k in 0..<4 { value |= UInt32(bytes[index + k]) << UInt32(8 * k) }
                index += 4
                fields.append(Field(number: number, value: .fixed32(value)))
            default:
                return nil
            }
        }
        self.fields = fields
    }

    private func last(_ number: Int) -> Value? { fields.last { $0.number == number }?.value }

    func varint(_ number: Int) -> UInt64? {
        if case .varint(let v)? = last(number) { return v }
        return nil
    }

    func fixed32(_ number: Int) -> UInt32? {
        if case .fixed32(let v)? = last(number) { return v }
        return nil
    }

    func float(_ number: Int) -> Float? { fixed32(number).map(Float.init(bitPattern:)) }

    func bytes(_ number: Int) -> [UInt8]? {
        if case .bytes(let v)? = last(number) { return v }
        return nil
    }

    func string(_ number: Int) -> String? { bytes(number).map { String(decoding: $0, as: UTF8.self) } }
}
