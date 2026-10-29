import CommonCrypto
import Foundation
import os

// MARK: - MAC (IEEE 802.15.4-2006)

enum MACAddress: Sendable, Hashable, CustomStringConvertible {
    case short(UInt16)
    case extended(UInt64)

    var description: String {
        switch self {
        case let .short(a): String(format: "0x%04X", a)
        case let .extended(a): ZigbeeFormat.ieee(a)
        }
    }
}

struct MACFrame: Sendable, Equatable {
    enum Kind: Int, Sendable {
        case beacon = 0, data = 1, ack = 2, command = 3
        var title: String {
            switch self {
            case .beacon: String(localized: "Beacon")
            case .data: String(localized: "Daten")
            case .ack: String(localized: "Quittung")
            case .command: String(localized: "MAC-Befehl")
            }
        }
    }

    var kind: Kind
    var security: Bool
    var framePending: Bool
    var ackRequest: Bool
    var sequence: UInt8
    var destinationPAN: UInt16?
    var destination: MACAddress?
    var sourcePAN: UInt16?
    var source: MACAddress?
    /// Zusatzkopf der MAC-Sicherheit (Thread, nicht Zigbee).
    var securityHeader: MACSecurityHeader?
    /// Länge des MAC-Kopfs samt Zusatzkopf (authentisierte Daten).
    var headerLength = 0
    var payload: [UInt8]

    var pan: UInt16? { sourcePAN ?? destinationPAN }

    static func parse(_ b: [UInt8]) -> MACFrame? {
        guard b.count >= 3 else { return nil }
        let fcf = UInt16(b[0]) | UInt16(b[1]) << 8
        guard let kind = Kind(rawValue: Int(fcf & 7)) else { return nil }
        let panCompression = fcf & 0x40 != 0
        let dstMode = Int(fcf >> 10 & 3), srcMode = Int(fcf >> 14 & 3)
        var i = 3
        var frame = MACFrame(kind: kind, security: fcf & 0x08 != 0, framePending: fcf & 0x10 != 0,
                             ackRequest: fcf & 0x20 != 0, sequence: b[2], payload: [])
        func u16() -> UInt16? {
            guard i + 2 <= b.count else { return nil }
            defer { i += 2 }
            return UInt16(b[i]) | UInt16(b[i + 1]) << 8
        }
        func address(_ mode: Int) -> MACAddress?? {
            switch mode {
            case 0: return .some(nil)
            case 2: return u16().map { .short($0) }
            case 3:
                guard i + 8 <= b.count else { return nil }
                defer { i += 8 }
                return .some(.extended(ZigbeeFormat.le64(b, i)))
            default: return nil
            }
        }
        if dstMode != 0 {
            guard let pan = u16(), let dst = address(dstMode) else { return nil }
            frame.destinationPAN = pan
            frame.destination = dst
        }
        if srcMode != 0 {
            if !panCompression || dstMode == 0 {
                guard let pan = u16() else { return nil }
                frame.sourcePAN = pan
            }
            guard let src = address(srcMode) else { return nil }
            frame.source = src
        }
        if frame.security {
            guard let header = MACSecurityHeader.parse(b, at: i) else { return nil }
            frame.securityHeader = header
            i += header.length
        }
        guard i <= b.count else { return nil }
        frame.headerLength = i
        frame.payload = Array(b[i...])
        return frame
    }

    static let commandNames: [UInt8: String] = [
        0x01: String(localized: "Beitrittsanfrage"), 0x02: String(localized: "Beitrittsantwort"), 0x03: String(localized: "Abmeldung"),
        0x04: String(localized: "Datenanfrage"), 0x05: String(localized: "PAN-ID-Konflikt"), 0x06: String(localized: "Waise"), 0x07: String(localized: "Beacon-Anfrage"),
        0x08: String(localized: "Koordinator-Neuausrichtung"), 0x09: String(localized: "GTS-Anfrage"),
    ]
}

/// Zusatzkopf der 802.15.4-Sicherheit (7.4): Steuerbyte (Stufe, Schlüsselkennungsmodus),
/// Rahmenzähler, Schlüsselkennung je Modus (0: keine, 1: Index, 2: 4 Byte + Index,
/// 3: 8 Byte + Index). Zigbee nutzt sie nicht, Thread schon.
struct MACSecurityHeader: Sendable, Equatable {
    var control: UInt8
    var frameCounter: UInt32
    var keySource: [UInt8]
    var keyIndex: UInt8?
    var length: Int

    var level: Int { Int(control & 7) }
    var keyIdentifierMode: Int { Int(control >> 3 & 3) }
    /// MIC-Länge je Stufe: 0/4 keine, 1/5 → 4, 2/6 → 8, 3/7 → 16.
    var micLength: Int { [0, 4, 8, 16][level & 3] }
    var encrypted: Bool { level >= 4 }

    static func parse(_ b: [UInt8], at start: Int) -> MACSecurityHeader? {
        guard start + 5 <= b.count else { return nil }
        let control = b[start]
        let counter = UInt32(b[start + 1]) | UInt32(b[start + 2]) << 8 | UInt32(b[start + 3]) << 16 | UInt32(b[start + 4]) << 24
        var i = start + 5
        let sourceLength = [0, 0, 4, 8][Int(control >> 3 & 3)]
        guard i + sourceLength <= b.count else { return nil }
        let source = Array(b[i..<(i + sourceLength)])
        i += sourceLength
        var index: UInt8?
        if control >> 3 & 3 != 0 {
            guard i < b.count else { return nil }
            index = b[i]
            i += 1
        }
        return MACSecurityHeader(control: control, frameCounter: counter, keySource: source, keyIndex: index, length: i - start)
    }
}

/// Zigbee-Beacon-Inhalt (Superframe-Angaben + Zigbee-Nutzlast).
struct ZigbeeBeacon: Sendable, Equatable {
    var permitJoining: Bool
    var panCoordinator: Bool
    var stackProfile: Int
    var protocolVersion: Int
    var routerCapacity: Bool
    var endDeviceCapacity: Bool
    var depth: Int
    var extendedPAN: UInt64

    static func parse(_ p: [UInt8]) -> ZigbeeBeacon? {
        guard p.count >= 4 else { return nil }
        let superframe = UInt16(p[0]) | UInt16(p[1]) << 8
        var i = 2
        let gtsCount = Int(p[i] & 7); i += 1
        if gtsCount > 0 { i += 1 + 3 * gtsCount }
        guard i < p.count else { return nil }
        let pending = p[i]; i += 1
        i += 2 * Int(pending & 7) + 8 * Int(pending >> 4 & 7)
        guard i + 11 <= p.count, p[i] == 0 else { return nil }   // Protokoll-ID 0 = Zigbee
        return ZigbeeBeacon(permitJoining: superframe & 0x8000 != 0, panCoordinator: superframe & 0x4000 != 0,
                            stackProfile: Int(p[i + 1] & 0x0F), protocolVersion: Int(p[i + 1] >> 4),
                            routerCapacity: p[i + 2] & 0x04 != 0, endDeviceCapacity: p[i + 2] & 0x80 != 0,
                            depth: Int(p[i + 2] >> 3 & 0x0F), extendedPAN: ZigbeeFormat.le64(p, i + 3))
    }
}

// MARK: - NWK

struct NWKFrame: Sendable, Equatable {
    enum Kind: Int, Sendable { case data = 0, command = 1, interPAN = 3 }

    var kind: Kind
    var version: Int
    var security: Bool
    var destination: UInt16
    var source: UInt16
    var radius: UInt8
    var sequence: UInt8
    var destinationIEEE: UInt64?
    var sourceIEEE: UInt64?
    /// Kopf bis zum Ende (für die Authentisierung), Länge in Bytes.
    var headerLength: Int
    var securityHeader: NWKSecurityHeader?
    /// Nutzdaten – verschlüsselt, solange `security` gesetzt ist und kein Schlüssel passte.
    var payload: [UInt8]

    static func parse(_ b: [UInt8]) -> NWKFrame? {
        guard b.count >= 8 else { return nil }
        let fc = UInt16(b[0]) | UInt16(b[1]) << 8
        guard let kind = Kind(rawValue: Int(fc & 3)), kind != .interPAN else { return nil }
        let version = Int(fc >> 2 & 0x0F)
        guard (1...3).contains(version) else { return nil }
        var frame = NWKFrame(kind: kind, version: version, security: fc & 0x0200 != 0,
                             destination: UInt16(b[2]) | UInt16(b[3]) << 8, source: UInt16(b[4]) | UInt16(b[5]) << 8,
                             radius: b[6], sequence: b[7], headerLength: 0, payload: [])
        var i = 8
        if fc & 0x0800 != 0 {
            guard i + 8 <= b.count else { return nil }
            frame.destinationIEEE = ZigbeeFormat.le64(b, i); i += 8
        }
        if fc & 0x1000 != 0 {
            guard i + 8 <= b.count else { return nil }
            frame.sourceIEEE = ZigbeeFormat.le64(b, i); i += 8
        }
        if fc & 0x0100 != 0 { i += 1 }                     // Multicast-Steuerung
        if fc & 0x0400 != 0 {                              // Quellroute
            guard i < b.count else { return nil }
            i += 2 + 2 * Int(b[i])
        }
        if frame.security {
            guard let header = NWKSecurityHeader.parse(b, at: i) else { return nil }
            frame.securityHeader = header
            i += header.length
        }
        guard i <= b.count else { return nil }
        frame.headerLength = i
        frame.payload = Array(b[i...])
        return frame
    }
}

/// Zusatzkopf der NWK-Sicherheit (Zigbee-Spezifikation 4.5.1).
struct NWKSecurityHeader: Sendable, Equatable {
    var control: UInt8
    var frameCounter: UInt32
    var source: UInt64?
    var keySequence: UInt8?
    var length: Int

    var keyIdentifier: Int { Int(control >> 3 & 3) }

    static func parse(_ b: [UInt8], at start: Int) -> NWKSecurityHeader? {
        var i = start
        guard i + 5 <= b.count else { return nil }
        let control = b[i]; i += 1
        let counter = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        i += 4
        var header = NWKSecurityHeader(control: control, frameCounter: counter, length: 0)
        if control & 0x20 != 0 {
            guard i + 8 <= b.count else { return nil }
            header.source = ZigbeeFormat.le64(b, i); i += 8
        }
        if control >> 3 & 3 == 1 {
            guard i < b.count else { return nil }
            header.keySequence = b[i]; i += 1
        }
        header.length = i - start
        return header
    }
}

// MARK: - Sicherheit (AES-128-CCM*)

enum ZigbeeSecurity {
    /// Zigbee überträgt die Sicherheitsstufe als 0; gerechnet wird mit 5
    /// (ENC-MIC-32) – im Nonce und in den authentisierten Kopfdaten.
    static let level: UInt8 = 5

    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Zigbee")
    /// Treffer mit der Nonce-Variante „Adresse big-endian“ (nur Diagnose).
    private static let bigEndianHits = OSAllocatedUnfairLock(initialState: 0)

    /// Entschlüsselt die Nutzdaten eines NWK-Rahmens. `frame` ist der
    /// komplette NWK-Rahmen (Kopf + Zusatzkopf + Chiffrat + MIC).
    /// Nonce zuerst nach Norm (Adresse little-endian); zur Absicherung wird
    /// die big-endian-Variante versucht und ein Treffer protokolliert.
    static func decrypt(nwk raw: [UInt8], header: NWKFrame, key: [UInt8]) -> [UInt8]? {
        guard let security = header.securityHeader, let source = security.source ?? header.sourceIEEE,
              raw.count >= header.headerLength + 4 else { return nil }
        let controlOffset = header.headerLength - security.length
        var authenticated = Array(raw[..<header.headerLength])
        authenticated[controlOffset] = (authenticated[controlOffset] & ~7) | level
        let body = Array(raw[header.headerLength...])
        let ciphertext = Array(body.dropLast(4)), mic = Array(body.suffix(4))
        for bigEndian in [false, true] {
            let nonce = self.nonce(source: source, counter: security.frameCounter,
                                   control: authenticated[controlOffset], bigEndianAddress: bigEndian)
            guard let clear = CCMStar.decrypt(key: key, nonce: nonce, authenticated: authenticated,
                                              ciphertext: ciphertext, mic: mic) else { continue }
            if bigEndian {
                let hits = bigEndianHits.withLock { $0 += 1; return $0 }
                if hits == 1 || hits % 100 == 0 { log.notice("Nonce mit big-endian-Adresse passte (\(hits)×) – Norm wäre little-endian") }
            }
            return clear
        }
        return nil
    }

    /// Nonce (Zigbee 4.5.2.2): Quelladresse, Rahmenzähler, Sicherheitssteuerung –
    /// alle Felder in Funkreihenfolge, also **little-endian** (so bauen es
    /// Z-Stack `SSP_BuildNonce`, zigpy und Wiresharks `zbee_sec_make_nonce`;
    /// big-endian ist der 802.15.4-MAC-Nonce, nicht der von Zigbee). Beispiel:
    /// Adresse AC:DE:48:00:00:00:00:01 → Nonce beginnt 01 00 00 00 00 48 DE AC.
    static func nonce(source: UInt64, counter: UInt32, control: UInt8, bigEndianAddress: Bool = false) -> [UInt8] {
        let address = (0..<8).map { UInt8(source >> UInt64(bigEndianAddress ? 56 - 8 * $0 : 8 * $0) & 0xFF) }
        return address + (0..<4).map { UInt8(counter >> UInt32(8 * $0) & 0xFF) } + [control]
    }

    /// Schlüssel aus Zigbee2MQTT: als Liste `[1, 3, 5, …]`, als YAML-Block
    /// (`- 242` je Zeile, auch samt `network_key:` davor und weiteren
    /// Einstellungen danach), als Hex mit oder ohne Trennzeichen.
    static func parseKey(_ text: String) -> [UInt8]? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromYAML = trimmed.range(of: "network_key:")
        if let fromYAML { trimmed = String(trimmed[fromYAML.upperBound...]) }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = hexKey(trimmed) { return hex }
        // Zahlen (dezimal oder 0x…) aus Liste oder YAML-Block; nach einem
        // `network_key:` dürfen weitere Zeilen (`pan_id: …`) folgen.
        let tokens = trimmed.split(whereSeparator: { ",[]- \n\r\t".contains($0) })
        let values = tokens.map { part -> UInt8? in
            let s = String(part)
            if s.lowercased().hasPrefix("0x") { return UInt8(s.dropFirst(2), radix: 16) }
            return UInt8(s)
        }
        let key = values.prefix(while: { $0 != nil }).compactMap { $0 }
        guard key.count == 16, values.count == 16 || fromYAML != nil else { return nil }
        return key
    }

    /// 32 Hex-Zeichen, wahlweise mit „:“, „-“ oder Leerzeichen getrennt.
    private static func hexKey(_ trimmed: String) -> [UInt8]? {
        let hex = trimmed.filter { $0.isHexDigit }
        guard hex.count == 32, trimmed.allSatisfy({ $0.isHexDigit || ":- ".contains($0) }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// AES-CCM mit 2 Längenbytes (L = 2, Nonce 13 Bytes), MIC beliebiger Länge.
enum CCMStar {
    static func aes(_ key: [UInt8], _ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    key, key.count, nil, block, 16, &out, 16, &moved)
        return out
    }

    private static func counterBlock(_ nonce: [UInt8], _ i: Int) -> [UInt8] {
        [0x01] + nonce + [UInt8(i >> 8 & 0xFF), UInt8(i & 0xFF)]
    }

    private static func ctr(key: [UInt8], nonce: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for (blockIndex, start) in stride(from: 0, to: data.count, by: 16).enumerated() {
            let s = aes(key, counterBlock(nonce, blockIndex + 1))
            for k in start..<min(start + 16, data.count) { out.append(data[k] ^ s[k - start]) }
        }
        return out
    }

    static func mac(key: [UInt8], nonce: [UInt8], authenticated a: [UInt8], message m: [UInt8], micLength: Int) -> [UInt8] {
        // M' = (M − 2)/2, bei M = 0 (Stufe 4, nur Verschlüsselung) 0 – sonst UInt8(−1) → Absturz.
        let flags = UInt8(a.isEmpty ? 0 : 0x40) | UInt8(max(0, (micLength - 2) / 2) & 7) << 3 | 1
        var blocks: [UInt8] = [flags] + nonce + [UInt8(m.count >> 8 & 0xFF), UInt8(m.count & 0xFF)]
        if !a.isEmpty {
            var encoded = [UInt8(a.count >> 8 & 0xFF), UInt8(a.count & 0xFF)] + a
            while encoded.count % 16 != 0 { encoded.append(0) }
            blocks += encoded
        }
        var padded = m
        while padded.count % 16 != 0 { padded.append(0) }
        blocks += padded
        var x = [UInt8](repeating: 0, count: 16)
        for start in stride(from: 0, to: blocks.count, by: 16) {
            for k in 0..<16 { x[k] ^= blocks[start + k] }
            x = aes(key, x)
        }
        return Array(x.prefix(micLength))
    }

    static func encrypt(key: [UInt8], nonce: [UInt8], authenticated: [UInt8], plaintext: [UInt8], micLength: Int) -> (ciphertext: [UInt8], mic: [UInt8]) {
        let tag = mac(key: key, nonce: nonce, authenticated: authenticated, message: plaintext, micLength: micLength)
        let s0 = aes(key, counterBlock(nonce, 0))
        let mic = (0..<micLength).map { tag[$0] ^ s0[$0] }
        return (ctr(key: key, nonce: nonce, plaintext), mic)
    }

    static func decrypt(key: [UInt8], nonce: [UInt8], authenticated: [UInt8], ciphertext: [UInt8], mic: [UInt8]) -> [UInt8]? {
        // Ohne MIC (Sicherheitsstufe 4 aus dem Rahmenkopf) wäre jeder Schlüssel „richtig“ –
        // solche Rahmen nicht als entschlüsselt ausgeben.
        guard key.count == 16, nonce.count == 13, [4, 8, 16].contains(mic.count) else { return nil }
        let plaintext = ctr(key: key, nonce: nonce, ciphertext)
        let s0 = aes(key, counterBlock(nonce, 0))
        let tag = (0..<mic.count).map { mic[$0] ^ s0[$0] }
        let expected = mac(key: key, nonce: nonce, authenticated: authenticated, message: plaintext, micLength: mic.count)
        return tag == expected ? plaintext : nil
    }
}

// MARK: - APS und ZCL

struct APSFrame: Sendable, Equatable {
    enum Kind: Int, Sendable { case data = 0, command = 1, ack = 2, interPAN = 3 }

    var kind: Kind
    var security: Bool
    var destinationEndpoint: UInt8?
    var group: UInt16?
    var cluster: UInt16?
    var profile: UInt16?
    var sourceEndpoint: UInt8?
    var counter: UInt8
    /// Länge des APS-Kopfs vor dem Sicherheits-Zusatzkopf.
    var headerLength = 0
    var securityHeader: NWKSecurityHeader?
    var payload: [UInt8]

    static func parse(_ b: [UInt8]) -> APSFrame? {
        guard let first = b.first, let kind = Kind(rawValue: Int(first & 3)) else { return nil }
        let delivery = Int(first >> 2 & 3)
        let ackFormat = first & 0x10 != 0
        var frame = APSFrame(kind: kind, security: first & 0x20 != 0, counter: 0, payload: [])
        var i = 1
        func u8() -> UInt8? { guard i < b.count else { return nil }; defer { i += 1 }; return b[i] }
        func u16() -> UInt16? {
            guard i + 2 <= b.count else { return nil }
            defer { i += 2 }
            return UInt16(b[i]) | UInt16(b[i + 1]) << 8
        }
        let addressed = kind == .data || (kind == .ack && !ackFormat)
        if addressed {
            if delivery == 3 { frame.group = u16() } else { frame.destinationEndpoint = u8() }
            frame.cluster = u16()
            frame.profile = u16()
            frame.sourceEndpoint = u8()
        }
        guard let counter = u8() else { return nil }
        frame.counter = counter
        if first & 0x80 != 0, let ext = u8() {               // erweiterter Kopf (Fragmentierung)
            if ext & 3 != 0 { i += 1 }
        }
        guard i <= b.count else { return nil }
        frame.headerLength = i
        if frame.security, let header = NWKSecurityHeader.parse(b, at: i) {
            frame.securityHeader = header
        }
        frame.payload = Array(b[i...])
        return frame
    }
}

/// Ausgewertete ZCL-Nachricht: Befehl und erkannte Messwerte.
struct ZCLMessage: Sendable, Equatable {
    var clusterSpecific: Bool
    var manufacturer: UInt16?
    var command: UInt8
    var summary: String
    var readings: [String]

    static func parse(_ b: [UInt8], cluster: UInt16) -> ZCLMessage? {
        guard b.count >= 3 else { return nil }
        let fc = b[0]
        var i = 1
        var manufacturer: UInt16?
        if fc & 0x04 != 0 {
            guard b.count >= 5 else { return nil }
            manufacturer = UInt16(b[1]) | UInt16(b[2]) << 8
            i = 3
        }
        let command = b[i + 1]
        let payload = Array(b[(i + 2)...])
        let specific = fc & 3 == 1
        var message = ZCLMessage(clusterSpecific: specific, manufacturer: manufacturer, command: command, summary: "", readings: [])
        if specific {
            message.summary = ZCL.clusterCommand(cluster: cluster, command: command, payload: payload)
            if cluster == 0xEF00, [0x01, 0x02, 0x05, 0x06].contains(command) {
                message.readings = Tuya.dataPoints(payload)
            }
        } else {
            switch command {
            case 0x0A:
                message.summary = String(localized: "Attributbericht")
                message.readings = ZCL.records(payload, withStatus: false).compactMap { ZCL.describe(cluster: cluster, $0) }
            case 0x01:
                message.summary = String(localized: "Leseantwort")
                message.readings = ZCL.records(payload, withStatus: true).compactMap { ZCL.describe(cluster: cluster, $0) }
            case 0x00: message.summary = String(localized: "Attribute lesen")
            case 0x02: message.summary = String(localized: "Attribute schreiben")
            case 0x06: message.summary = String(localized: "Berichte einrichten")
            case 0x07: message.summary = String(localized: "Berichtseinrichtung bestätigt")
            case 0x0B: message.summary = String(localized: "Standardantwort")
            default: message.summary = String(format: String(localized: "ZCL-Befehl 0x%02X"), command)
            }
        }
        return message
    }
}

enum ZCL {
    enum Value: Sendable, Equatable {
        case int(Int64)
        case float(Double)
        case text(String)
        case raw([UInt8])
    }

    static let clusterNames: [UInt16: String] = [
        0x0000: "Basis", 0x0001: "Stromversorgung", 0x0003: "Identifizieren", 0x0004: "Gruppen",
        0x0005: "Szenen", 0x0006: "Ein/Aus", 0x0008: "Helligkeit", 0x000A: "Zeit",
        0x0012: "Mehrstufig", 0x0019: "OTA-Update", 0x0020: "Abfragesteuerung", 0x0101: "Türschloss",
        0x0102: "Rollladen", 0x0201: "Thermostat", 0x0202: "Lüfter", 0x0300: "Farbe",
        0x0400: "Helligkeitsmessung", 0x0402: "Temperatur", 0x0403: "Luftdruck", 0x0405: "Luftfeuchte",
        0x0406: "Anwesenheit", 0x040D: "CO₂", 0x042A: "Feinstaub", 0x0500: "Alarmzone (IAS)",
        0x0702: "Zähler", 0x0B04: "Elektrische Messung", 0x0B05: "Diagnose", 0x1000: "Touchlink",
        0xEF00: "Tuya",
    ]

    static func clusterName(_ id: UInt16) -> String {
        clusterNames[id] ?? String(format: "Cluster 0x%04X", id)
    }

    /// Attributsätze (Kennung, Typ, Wert); bei Leseantworten mit Status.
    static func records(_ b: [UInt8], withStatus: Bool) -> [(UInt16, Value)] {
        var out: [(UInt16, Value)] = []
        var i = 0
        while i + 3 <= b.count {
            let id = UInt16(b[i]) | UInt16(b[i + 1]) << 8
            i += 2
            if withStatus {
                let status = b[i]; i += 1
                if status != 0 { continue }
            }
            guard i < b.count else { break }
            let type = b[i]; i += 1
            guard let (value, size) = decode(type: type, b, at: i) else { break }
            out.append((id, value))
            i += size
        }
        return out
    }

    static func decode(type: UInt8, _ b: [UInt8], at i: Int) -> (Value, Int)? {
        func unsigned(_ n: Int) -> UInt64? {
            guard i + n <= b.count else { return nil }
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(b[i + k]) << UInt64(8 * k) }
            return v
        }
        switch type {
        case 0x10, 0x18, 0x20, 0x30, 0x08: return unsigned(1).map { (.int(Int64($0)), 1) }
        case 0x19, 0x21, 0x31, 0x09: return unsigned(2).map { (.int(Int64($0)), 2) }
        case 0x22, 0x1A: return unsigned(3).map { (.int(Int64($0)), 3) }
        case 0x23, 0x1B: return unsigned(4).map { (.int(Int64($0)), 4) }
        case 0x25: return unsigned(6).map { (.int(Int64($0)), 6) }
        case 0x28: return unsigned(1).map { (.int(Int64(Int8(truncatingIfNeeded: $0))), 1) }
        case 0x29: return unsigned(2).map { (.int(Int64(Int16(truncatingIfNeeded: $0))), 2) }
        case 0x2A: return unsigned(3).map { v in (.int(Int64(v) - (v & 0x80_0000 != 0 ? 0x100_0000 : 0)), 3) }
        case 0x2B: return unsigned(4).map { (.int(Int64(Int32(truncatingIfNeeded: $0))), 4) }
        case 0x39: return unsigned(4).map { (.float(Double(Float(bitPattern: UInt32($0)))), 4) }
        case 0x41, 0x42:
            guard i < b.count else { return nil }
            let n = Int(b[i])
            guard i + 1 + n <= b.count else { return nil }
            let bytes = Array(b[(i + 1)..<(i + 1 + n)])
            if type == 0x41 || bytes.contains(where: { $0 < 0x20 && $0 != 0x09 }) { return (.raw(bytes), 1 + n) }
            return (.text(String(decoding: bytes, as: UTF8.self)), 1 + n)
        case 0x4C:                                                  // Struktur (Xiaomi 0xFF02): Rest als Rohdaten
            return (.raw(Array(b[i...])), b.count - i)
        default: return nil
        }
    }

    /// Ganzzahl aus einem ZCL-Wert. Typ 0x39 (Float) kann NaN/∞ tragen – dann
    /// stürzte `Int(v)` ab (Funkrahmen aus der Luft – sonst Absturz).
    static func integer(_ v: Double) -> Int? {
        guard v.isFinite else { return nil }
        return Int(max(-1e15, min(1e15, v)))
    }

    /// Bekannte Messwerte in Klartext, sonst Kennung = Wert.
    static func describe(cluster: UInt16, _ record: (UInt16, Value)) -> String? {
        let (id, value) = record
        // Xiaomi/Aqara: Attribut 0xFF01 (Zeichenkette) bzw. 0xFF02 (Struktur) im
        // Basis-Cluster trägt einen TLV-Block mit Batterie, Temperatur usw.
        if cluster == 0x0000, id == 0xFF01 || id == 0xFF02, case let .raw(bytes) = value {
            let parts = Xiaomi.readings(bytes)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        let number: Double? = {
            switch value {
            case let .int(v): Double(v)
            case let .float(v): v
            default: nil
            }
        }()
        if case let .int(v) = value, v == -32768 || v == 0xFFFF && cluster != 0x0000 { return nil }   // ungültig
        switch (cluster, id, number) {
        case (0x0402, 0, let v?): return String(format: "%.2f °C", v / 100)
        case (0x0405, 0, let v?): return String(format: "%.1f %% rF", v / 100)
        case (0x0403, 0, let v?): return String(format: "%.0f hPa", v)
        case (0x0400, 0, let v?): return String(format: "%.0f lx", v > 0 ? pow(10, (v - 1) / 10_000) : 0)
        case (0x0406, 0, let v?): return v != 0 ? "Bewegung erkannt" : "keine Bewegung"
        case (0x0006, 0, let v?): return v != 0 ? "Ein" : "Aus"
        case (0x0008, 0, let v?): return String(format: "Helligkeit %.0f %%", v / 2.54)
        case (0x0001, 0x20, let v?): return String(format: "Batterie %.1f V", v / 10)
        case (0x0001, 0x21, let v?): return String(format: "Batterie %.0f %%", v / 2)
        case (0x040D, 0, let v?): return String(format: "CO₂ %.0f ppm", v * 1_000_000)
        case (0x0B04, 0x050B, let v?): return String(format: "%.0f W", v)
        case (0x0B04, 0x0505, let v?): return String(format: "%.0f V", v)
        case (0x0702, 0x0400, let v?): return String(format: "%.0f W", v)
        case (0x0000, 0x0005, _): if case let .text(t) = value { return "Modell \(t)" }
        case (0x0000, 0x0004, _): if case let .text(t) = value { return "Hersteller \(t)" }
        case (0x0001, 0x003E, let v?): return v == 0 ? nil : "Batteriealarm"
        case (0x0402, 0x0000, _), (0x0405, 0x0000, _), (0x0403, 0x0000, _): return nil   // ungültig (0x8000)
        case (0x0406, 0x0010, let v?): return String(format: "Verzögerung %.0f s", v)
        case (0x0500, 0x0002, let v?):
            guard let bits = integer(v) else { return nil }
            var parts: [String] = []
            if bits & 1 != 0 { parts.append("Alarm 1") }
            if bits & 2 != 0 { parts.append("Alarm 2") }
            if bits & 4 != 0 { parts.append("Sabotage") }
            if bits & 8 != 0 { parts.append("Batterie schwach") }
            return "Zonenstatus: " + (parts.isEmpty ? "ruhig" : parts.joined(separator: ", "))
        case (0x0702, 0x0000, let v?): return String(format: "Zähler %.3f kWh", v / 1000)
        case (0x0B04, 0x0508, let v?): return String(format: "%.3f A", v / 1000)
        case (0x0B04, 0x0300, let v?): return String(format: "%.0f Hz", v)
        case (0x0300, 0x0007, let v?): return v > 0 ? String(format: "%.0f K Farbtemperatur", 1_000_000 / v) : nil
        case (0x0300, 0x0003, let v?): return String(format: "x %.3f", v / 65_536)
        case (0x0300, 0x0004, let v?): return String(format: "y %.3f", v / 65_536)
        case (0x0300, 0x0000, let v?): return String(format: "Farbton %.0f°", v / 254 * 360)
        case (0x0300, 0x0001, let v?): return String(format: "Sättigung %.0f %%", v / 2.54)
        case (0x0102, 0x0008, let v?): return String(format: "Rollladen %.0f %% zu", v)
        case (0x0201, 0x0000, let v?): return String(format: "Raum %.2f °C", v / 100)
        case (0x0201, 0x0012, let v?): return String(format: "Soll %.2f °C", v / 100)
        case (0x0201, 0x0008, let v?): return String(format: "Heizen %.0f %%", v)
        case (0x0101, 0x0000, let v?):
            // int8 0xFF ergäbe Index −1, Float-NaN ließe Int(v) abstürzen – klemmen.
            guard let state = integer(v) else { return nil }
            return ["nicht voll verriegelt", "verriegelt", "entriegelt"][max(0, min(state, 2))]
        case (0x0020, 0x0000, let v?): return String(format: "Abfrage alle %.1f s", v / 4)
        case (0x0012, 0x0055, let v?): return integer(v).map { "Mehrstufig \($0)" }
        case (0x042A, 0x0000, let v?): return String(format: "PM2,5 %.0f µg/m³", v)
        case (0x0B05, 0x011D, let v?): return String(format: "letzter Pegel %.0f dBm", v > 127 ? v - 256 : v)
        case (0x0B05, 0x011C, let v?): return String(format: "letzte LQI %.0f", v)
        default: break
        }
        switch value {
        case let .int(v): return String(format: "%@ 0x%04X = %lld", clusterName(cluster), id, v)
        case let .float(v): return String(format: "%@ 0x%04X = %.3f", clusterName(cluster), id, v)
        case let .text(t): return String(format: "%@ 0x%04X = „%@“", clusterName(cluster), id, t)
        case .raw: return nil
        }
    }

    static func clusterCommand(cluster: UInt16, command: UInt8, payload: [UInt8]) -> String {
        switch (cluster, command) {
        case (0x0006, 0x00): return "Aus"
        case (0x0006, 0x01): return "Ein"
        case (0x0006, 0x02): return "Umschalten"
        case (0x0008, 0x00), (0x0008, 0x04):
            return payload.first.map { String(format: String(localized: "Helligkeit auf %.0f %%"), Double($0) / 2.54) } ?? String(localized: "Helligkeit setzen")
        case (0x0008, 0x01), (0x0008, 0x05): return String(localized: "Heller/dunkler regeln")
        case (0x0008, 0x02), (0x0008, 0x06): return String(localized: "Helligkeitsschritt")
        case (0x0008, 0x03), (0x0008, 0x07): return String(localized: "Regeln stoppen")
        case (0x0500, 0x00):
            guard payload.count >= 2 else { return "Zonenstatus" }
            let status = UInt16(payload[0]) | UInt16(payload[1]) << 8
            var parts: [String] = []
            if status & 1 != 0 { parts.append("Alarm 1") }
            if status & 2 != 0 { parts.append("Alarm 2") }
            if status & 4 != 0 { parts.append("Sabotage") }
            if status & 8 != 0 { parts.append("Batterie schwach") }
            return "Zonenstatus: " + (parts.isEmpty ? "ruhig" : parts.joined(separator: ", "))
        case (0x0019, _): return String(localized: "OTA-Update (Befehl \(Int(command)))")
        case (0x0300, 0x0A):
            guard payload.count >= 2 else { return String(localized: "Farbtemperatur setzen") }
            let mired = Double(UInt16(payload[0]) | UInt16(payload[1]) << 8)
            return mired > 0 ? String(format: String(localized: "Farbtemperatur %.0f K"), 1_000_000 / mired) : String(localized: "Farbtemperatur setzen")
        case (0x0300, 0x06): return payload.count >= 2 ? String(format: String(localized: "Farbton %.0f°, Sättigung %.0f %%"), Double(payload[0]) / 254 * 360, Double(payload[1]) / 2.54) : String(localized: "Farbe setzen")
        case (0x0300, 0x07): return payload.count >= 4 ? String(format: String(localized: "Farbe x %.3f, y %.3f"), Double(UInt16(payload[0]) | UInt16(payload[1]) << 8) / 65_536, Double(UInt16(payload[2]) | UInt16(payload[3]) << 8) / 65_536) : String(localized: "Farbe setzen")
        case (0x0300, 0x4B): return String(localized: "Farbtemperatur regeln")
        case (0x0300, 0x47): return String(localized: "Farbregelung stoppen")
        case (0x0102, 0x00): return String(localized: "Rollladen öffnen")
        case (0x0102, 0x01): return String(localized: "Rollladen schließen")
        case (0x0102, 0x02): return String(localized: "Rollladen stoppen")
        case (0x0102, 0x05): return payload.first.map { String(localized: "Rollladen auf \(Int($0)) % zu") } ?? String(localized: "Rollladen positionieren")
        case (0x0005, 0x05): return payload.count >= 3 ? String(localized: "Szene \(Int(payload[2])) aufrufen") : String(localized: "Szene aufrufen")
        case (0x0005, 0x04): return payload.count >= 3 ? String(localized: "Szene \(Int(payload[2])) speichern") : String(localized: "Szene speichern")
        case (0x0004, 0x00): return payload.count >= 2 ? String(format: String(localized: "Gruppe 0x%04X beitreten"), UInt16(payload[0]) | UInt16(payload[1]) << 8) : String(localized: "Gruppe beitreten")
        case (0x0003, 0x00): return String(localized: "Identifizieren")
        case (0x0003, 0x40): return String(localized: "Identifizieren (Effekt)")
        case (0x0101, 0x00): return String(localized: "Verriegeln")
        case (0x0101, 0x01): return String(localized: "Entriegeln")
        case (0x0020, 0x00): return String(localized: "Abfrage-Check-in")
        case (0x0020, 0x01): return String(localized: "Check-in-Antwort")
        case (0x0500, 0x01): return "Zone anmelden"
        case (0x0500, 0x00): return "Zonenstatus"
        case (0x0502, 0x00): return String(localized: "Warnung auslösen")
        case (0x0502, 0x01): return String(localized: "Blinkzeichen")
        case (0xEF00, 0x00): return String(localized: "Tuya: Daten setzen")
        case (0xEF00, 0x01), (0xEF00, 0x02): return String(localized: "Tuya: Datenpunkte")
        case (0xEF00, 0x05), (0xEF00, 0x06): return String(localized: "Tuya: Datenpunkte (Status)")
        case (0xEF00, 0x24): return String(localized: "Tuya: Zeit")
        case (0xFC7C, _), (0xFC80, _): return String(localized: "Philips Hue: Befehl \(Int(command))")
        default: return String(format: String(localized: "%@: Befehl 0x%02X"), clusterName(cluster), command)
        }
    }
}

/// Tuya-Cluster 0xEF00: nach Folgenummer (2 Byte) Datenpunkte aus Kennung,
/// Typ (0 Rohdaten, 1 Bool, 2 Wert 32 Bit BE, 3 Text, 4 Aufzählung, 5 Bitmap)
/// und Länge (2 Byte BE). Die Bedeutung der Kennung ist je Gerät verschieden;
/// die üblichsten (Zigbee2MQTT-Konverter) sind benannt.
enum Tuya {
    static func dataPoints(_ payload: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 2
        while i + 4 <= payload.count {
            let dp = payload[i], type = payload[i + 1]
            let length = Int(payload[i + 2]) << 8 | Int(payload[i + 3])
            i += 4
            guard i + length <= payload.count else { break }
            let data = Array(payload[i..<(i + length)])
            i += length
            let value: String
            switch type {
            case 1: value = data.first == 1 ? "ein" : "aus"
            case 2 where data.count == 4:
                let v = Int32(bitPattern: UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3]))
                value = describe(dp: dp, value: Double(v))
            case 3: value = "„" + String(decoding: data, as: UTF8.self) + "“"
            case 4: value = "Stufe \(data.first ?? 0)"
            case 5: value = "Bits " + data.map { String(format: "%02X", $0) }.joined()
            default: value = data.map { String(format: "%02X", $0) }.joined()
            }
            out.append("DP\(dp) \(value)")
        }
        return out
    }

    /// Häufige Datenpunkte mit Skalierung (Tuya-Thermostate, Sensoren).
    private static func describe(dp: UInt8, value: Double) -> String {
        switch dp {
        case 1 where value < 1000: return String(format: "%.1f °C", value / 10)
        case 2: return String(format: "%.1f", value / 10)
        case 3: return String(format: "%.0f %%", value)
        case 4, 15: return String(format: "Batterie %.0f %%", value)
        default: return String(format: "%.0f", value)
        }
    }
}

/// Xiaomi/Aqara-Herstellerattribut: TLV mit ZCL-Typen, Kennungen laut
/// Zigbee2MQTT (`xiaomi.ts`): 1 Batterie mV, 3 Gerätetemperatur, 5 Neustarts,
/// 100–102 je nach Gerät (Temperatur/Feuchte/Druck ·100 bzw. Status),
/// 149 Energie, 150 Spannung, 152 Leistung, 11 Beleuchtung.
enum Xiaomi {
    static func readings(_ bytes: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 0
        while i + 2 <= bytes.count {
            let tag = bytes[i], type = bytes[i + 1]
            i += 2
            guard let (value, size) = ZCL.decode(type: type, bytes, at: i) else { break }
            i += size
            let number: Double? = {
                switch value {
                case let .int(v): Double(v)
                case let .float(v): v
                default: nil
                }
            }()
            guard let v = number else { continue }
            switch tag {
            case 1: out.append(String(format: "Batterie %.2f V", v / 1000))
            case 3: out.append(String(format: "Gerät %.0f °C", v))
            case 5: out.append(String(format: "%.0f Neustarts", v))
            case 11: out.append(String(format: "%.0f lx", v))
            case 100 where type == 0x29: out.append(String(format: "%.2f °C", v / 100))
            case 100: out.append(v == 0 || v == 1 ? (v == 1 ? "ein" : "aus") : String(format: "Wert %.0f", v))
            case 101 where type == 0x21: out.append(String(format: "%.1f %% rF", v / 100))
            case 102 where type == 0x2B || type == 0x29: out.append(String(format: "%.0f hPa", v / 100))
            case 149: out.append(String(format: "%.3f kWh", v / 1000))
            case 150: out.append(String(format: "%.1f V", v / 10))
            case 152: out.append(String(format: "%.1f W", v))
            default: break
            }
        }
        return out
    }
}

// MARK: - NWK-Befehle

enum NWKCommand {
    static let names: [UInt8: String] = [
        0x01: String(localized: "Routenanfrage"), 0x02: String(localized: "Routenantwort"), 0x03: String(localized: "Netzstatus"), 0x04: String(localized: "Abmeldung"),
        0x05: String(localized: "Routenaufzeichnung"), 0x06: String(localized: "Wiederbeitritt (Anfrage)"), 0x07: String(localized: "Wiederbeitritt (Antwort)"),
        0x08: String(localized: "Verbindungsstatus"), 0x09: String(localized: "Netzbericht"), 0x0A: String(localized: "Netzaktualisierung"),
        0x0B: String(localized: "Zeitlimit-Anfrage"), 0x0C: String(localized: "Zeitlimit-Antwort"),
    ]

    /// Verbindungsstatus: Nachbarn mit Ein- und Ausgangskosten (1 = beste Verbindung, 7 = schlechteste).
    static func linkStatus(_ payload: [UInt8]) -> [(neighbor: UInt16, incoming: Int, outgoing: Int)] {
        guard payload.count >= 2, payload[0] == 0x08 else { return [] }
        let count = Int(payload[1] & 0x1F)
        var out: [(UInt16, Int, Int)] = []
        for k in 0..<count {
            let i = 2 + 3 * k
            guard i + 3 <= payload.count else { break }
            out.append((UInt16(payload[i]) | UInt16(payload[i + 1]) << 8, Int(payload[i + 2] & 7), Int(payload[i + 2] >> 4 & 7)))
        }
        return out
    }
}

enum ZigbeeFormat {
    static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
        return v
    }

    static func ieee(_ v: UInt64) -> String {
        (0..<8).map { String(format: "%02X", UInt8(v >> UInt64(56 - 8 * $0) & 0xFF)) }.joined(separator: ":")
    }
}
