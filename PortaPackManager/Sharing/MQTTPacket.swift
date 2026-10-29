import Foundation

/// MQTT 3.1.1 (OASIS-Standard, 2014) – nur das, was die Home-Assistant-Weitergabe
/// braucht: CONNECT mit Benutzer/Passwort und Last Will, PUBLISH mit QoS 0,
/// SUBSCRIBE mit QoS 0 (für `homeassistant/status`), PINGREQ, DISCONNECT.
/// Reine Kodierung ohne Netz – die Tests prüfen sie Byte für Byte.
enum MQTTPacket {
    enum Kind: UInt8, Sendable {
        case connect = 1, connack, publish, puback, pubrec, pubrel, pubcomp
        case subscribe, suback, unsubscribe, unsuback, pingreq, pingresp, disconnect
    }

    struct Will: Sendable, Equatable {
        var topic: String
        var payload: [UInt8]
        var retain: Bool
    }

    /// Ein empfangenes Paket: Typ, die vier Flag-Bits des Kopfbytes, Rumpf.
    struct Frame: Sendable, Equatable {
        var kind: Kind
        var flags: UInt8
        var body: [UInt8]
    }

    /// Größte in 4 Byte kodierbare Restlänge (Abschnitt 2.2.3).
    static let maxRemainingLength = 268_435_455

    // MARK: - Restlänge (variable Länge, 7 Bit je Byte, niedrigstwertig zuerst)

    static func encodeRemainingLength(_ length: Int) -> [UInt8] {
        precondition(length >= 0 && length <= maxRemainingLength, "MQTT-Restlänge außerhalb des Bereichs")
        var value = length
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    enum LengthResult: Equatable {
        case value(Int, consumed: Int)
        case needMore
        case malformed
    }

    /// Liest die Restlänge ab `offset`. Mehr als 4 Byte sind ein Formfehler.
    static func decodeRemainingLength(_ bytes: [UInt8], from offset: Int) -> LengthResult {
        var value = 0
        var multiplier = 1
        var index = offset
        for count in 1...4 {
            guard index < bytes.count else { return .needMore }
            let byte = bytes[index]
            value += Int(byte & 0x7F) * multiplier
            index += 1
            if byte & 0x80 == 0 { return .value(value, consumed: count) }
            multiplier *= 128
        }
        return .malformed
    }

    // MARK: - Bausteine

    /// UTF-8-Zeichenkette mit 2 Byte Länge (big-endian) davor.
    static func string(_ text: String) -> [UInt8] {
        data(Array(text.utf8))
    }

    static func data(_ bytes: [UInt8]) -> [UInt8] {
        let count = min(bytes.count, 65_535)
        return [UInt8(count >> 8), UInt8(count & 0xFF)] + bytes.prefix(count)
    }

    private static func packet(_ kind: Kind, flags: UInt8 = 0, _ body: [UInt8]) -> [UInt8] {
        [kind.rawValue << 4 | flags & 0x0F] + encodeRemainingLength(body.count) + body
    }

    // MARK: - Pakete

    /// CONNECT (3.1). `cleanSession` immer an – die Brücke braucht keinen
    /// Sitzungszustand beim Broker, QoS 0 kennt keine Nachlieferung.
    static func connect(clientID: String, username: String?, password: String?,
                        keepAlive: UInt16, will: Will?, cleanSession: Bool = true) -> [UInt8] {
        var flags: UInt8 = cleanSession ? 0x02 : 0
        if let will {
            flags |= 0x04                       // Will-Flag, Will-QoS 0
            if will.retain { flags |= 0x20 }
        }
        let user = username.flatMap { $0.isEmpty ? nil : $0 }
        // Passwort nur zusammen mit Benutzer (3.1.2.9: ohne Benutzer-Flag kein Passwort-Flag).
        let pass = user == nil ? nil : password.flatMap { $0.isEmpty ? nil : $0 }
        if user != nil { flags |= 0x80 }
        if pass != nil { flags |= 0x40 }
        var body = string("MQTT") + [0x04, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]
        body += string(clientID)
        if let will { body += string(will.topic) + data(will.payload) }
        if let user { body += string(user) }
        if let pass { body += data(Array(pass.utf8)) }
        return packet(.connect, body)
    }

    /// PUBLISH mit QoS 0 (ohne Paketkennung).
    static func publish(topic: String, payload: [UInt8], retain: Bool) -> [UInt8] {
        packet(.publish, flags: retain ? 0x01 : 0, string(topic) + payload)
    }

    /// SUBSCRIBE (Flags fest 0b0010) mit einem Filter, gewünschte QoS 0.
    static func subscribe(packetID: UInt16, topic: String) -> [UInt8] {
        packet(.subscribe, flags: 0x02, [UInt8(packetID >> 8), UInt8(packetID & 0xFF)] + string(topic) + [0x00])
    }

    static let pingreq: [UInt8] = [0xC0, 0x00]
    static let pingresp: [UInt8] = [0xD0, 0x00]
    static let disconnect: [UInt8] = [0xE0, 0x00]

    /// CONNACK: Sitzung vorhanden, Rückgabewert (0 = angenommen).
    static func connack(returnCode: UInt8, sessionPresent: Bool = false) -> [UInt8] {
        [0x20, 0x02, sessionPresent ? 1 : 0, returnCode]
    }

    // MARK: - Deuten

    /// Rückgabewert eines CONNACK-Rumpfs, `nil` bei Formfehler.
    static func connackCode(_ body: [UInt8]) -> UInt8? {
        body.count == 2 ? body[1] : nil
    }

    /// Klartext zu CONNACK-Rückgabewerten (Tabelle 3.1).
    static func connackText(_ code: UInt8) -> String {
        switch code {
        case 0: String(localized: "angenommen")
        case 1: String(localized: "Broker kennt MQTT 3.1.1 nicht")
        case 2: String(localized: "Client-Kennung abgelehnt")
        case 3: String(localized: "Broker nicht verfügbar")
        case 4: String(localized: "Benutzer oder Passwort falsch")
        case 5: String(localized: "nicht berechtigt")
        default: String(localized: "unbekannter Rückgabewert \(code)")
        }
    }

    /// Thema und Nutzlast eines PUBLISH-Rumpfs (QoS aus den Flags; bei QoS > 0
    /// steht hinter dem Thema eine Paketkennung).
    static func parsePublish(flags: UInt8, body: [UInt8]) -> (topic: String, payload: [UInt8], retain: Bool)? {
        guard body.count >= 2 else { return nil }
        let length = Int(body[0]) << 8 | Int(body[1])
        guard body.count >= 2 + length else { return nil }
        let topic = String(decoding: body[2..<(2 + length)], as: UTF8.self)
        let qos = (flags >> 1) & 0x03
        let start = 2 + length + (qos > 0 ? 2 : 0)
        guard qos < 3, body.count >= start else { return nil }
        return (topic, Array(body[start...]), flags & 0x01 != 0)
    }
}

/// Sammelt Bytes aus dem Datenstrom und gibt vollständige Pakete heraus.
/// Gelesen wird über einen Lese-Offset; verbrauchte Bytes werden erst beim
/// nächsten `append` einmal entfernt – nicht je Paket (`removeFirst` je Paket
/// wäre bei vielen kleinen Paketen quadratisch, Review Y17).
struct MQTTPacketReader: Sendable {
    private var buffer: [UInt8] = []
    private var offset = 0
    /// Grenze gegen Unsinn aus dem Netz: größere Pakete gelten als Formfehler.
    var maxPacket = 1 << 20

    enum ReadError: Error, Equatable { case malformed, tooLarge, unknownType(UInt8) }

    /// Noch nicht gelesene Bytes.
    var pendingCount: Int { buffer.count - offset }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        if offset > 0 {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// Nächstes vollständiges Paket oder `nil`, wenn noch Bytes fehlen.
    mutating func next() throws(ReadError) -> MQTTPacket.Frame? {
        guard offset < buffer.count else { return nil }
        let first = buffer[offset]
        switch MQTTPacket.decodeRemainingLength(buffer, from: offset + 1) {
        case .needMore:
            return nil
        case .malformed:
            throw .malformed
        case let .value(length, consumed):
            guard length <= maxPacket else { throw .tooLarge }
            let total = 1 + consumed + length
            guard buffer.count - offset >= total else { return nil }
            guard let kind = MQTTPacket.Kind(rawValue: first >> 4) else { throw .unknownType(first >> 4) }
            let body = Array(buffer[(offset + 1 + consumed)..<(offset + total)])
            offset += total
            if offset == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                offset = 0
            }
            return MQTTPacket.Frame(kind: kind, flags: first & 0x0F, body: body)
        }
    }
}
