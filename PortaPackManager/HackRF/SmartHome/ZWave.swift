import Foundation

/// Z-Wave (ITU-T G.9959) auf 868,42 MHz (R1 9,6 kbit/s Manchester, R2
/// 40 kbit/s NRZ, je FSK ±20 kHz) und 869,85 MHz (R3 100 kbit/s GFSK ±29 kHz).
///
/// Rahmen nach Präambel (0x55 …) und Startbyte 0xF0, MSB zuerst:
/// R1/R2: Home-ID (4) · Quelle (1) · Rahmensteuerung (2) · Länge (1) · Ziel (1) ·
/// Nutzdaten · XOR-Prüfsumme (1, Start 0xFF). R3: nach der Länge eine
/// Folgenummer (1), Prüfsumme CRC-16/CCITT mit Startwert 0x1D0F (2).
/// Die Länge zählt den ganzen Rahmen ab Home-ID samt Prüfsumme.
/// Multicast trägt statt des Ziels ein Steuerbyte und eine 29-Byte-Knotenmaske.
enum ZWave {
    enum Rate: String, Sendable, CaseIterable {
        case r1 = "R1 · 9,6 kbit/s"
        case r2 = "R2 · 40 kbit/s"
        case r3 = "R3 · 100 kbit/s"

        /// Bitrate auf der Luft (R1: Manchester-Chips).
        var symbolRate: Double {
            switch self {
            case .r1: 19_200
            case .r2: 40_000
            case .r3: 100_000
            }
        }
    }

    static let startOfFrame: UInt8 = 0xF0
    /// Präambelende + Startbyte als Suchmuster.
    static let syncBits = SmartHomeDemod.bits(of: [0x55, startOfFrame])

    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0xFF, ^)
    }

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        SmartHomeCRC.crc16(bytes, poly: 0x1021, initial: 0x1D0F)
    }

    // MARK: - Bitstrom → Rahmen

    /// Sucht Rahmen in demodulierten Bits (R1: Chips, sonst Datenbits).
    static func frames(inBits stream: [UInt8], rate: Rate) -> [SmartHomeFrame] {
        let candidates: [[UInt8]] = rate == .r1 ? [manchester(stream, offset: 0), manchester(stream, offset: 1)] : [stream]
        var out: [SmartHomeFrame] = []
        for bits in candidates {
            for start in SmartHomeDemod.find(syncBits, in: bits) {
                guard let header = validBytes(bits, from: start, count: 8) else { continue }
                let length = Int(header[7])
                let maxLength = rate == .r3 ? 170 : 64
                guard length >= (rate == .r3 ? 12 : 10), length <= maxLength,
                      let bytes = validBytes(bits, from: start, count: length),
                      let frame = parse(bytes, rate: rate), frame.checksumOK else { continue }
                if !out.contains(where: { $0.bytes == frame.bytes }) { out.append(frame) }
            }
            if !out.isEmpty { break }
        }
        return out
    }

    /// Manchester-Paare → Bits (10 → 1, 01 → 0, sonst 2 = ungültig).
    static func manchester(_ chips: [UInt8], offset: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(chips.count / 2)
        var n = offset
        while n + 1 < chips.count {
            switch (chips[n], chips[n + 1]) {
            case (1, 0): out.append(1)
            case (0, 1): out.append(0)
            default: out.append(2)
            }
            n += 2
        }
        return out
    }

    private static func validBytes(_ bits: [UInt8], from: Int, count: Int) -> [UInt8]? {
        guard from + count * 8 <= bits.count else { return nil }
        for k in from..<(from + count * 8) where bits[k] > 1 { return nil }
        return SmartHomeDemod.bytes(bits, from: from, count: count)
    }

    // MARK: - MAC-Rahmen

    static func headerTypeName(_ type: UInt8) -> String {
        switch type {
        case 1: String(localized: "Einzelruf")
        case 2: String(localized: "Gruppenruf")
        case 3: String(localized: "Quittung")
        case 8: String(localized: "Weitergeleitet")
        default: String(localized: "Typ \(Int(type))")
        }
    }

    /// Zerlegt einen vollständigen Rahmen (ab Home-ID, mit Prüfsumme).
    static func parse(_ bytes: [UInt8], rate: Rate) -> SmartHomeFrame? {
        let r3 = rate == .r3
        guard bytes.count >= (r3 ? 12 : 10) else { return nil }
        let homeID = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let source = bytes[4]
        let fc1 = bytes[5], fc2 = bytes[6]
        let length = Int(bytes[7])
        guard length == bytes.count else { return nil }
        let checksumOK: Bool
        let body: ArraySlice<UInt8>
        if r3 {
            let crc = UInt16(bytes[length - 2]) << 8 | UInt16(bytes[length - 1])
            checksumOK = crc16(bytes[0..<(length - 2)]) == crc
            body = bytes[0..<(length - 2)]
        } else {
            checksumOK = checksum(bytes[0..<(length - 1)]) == bytes[length - 1]
            body = bytes[0..<(length - 1)]
        }
        let headerType = fc1 & 0x0F
        let routed = !r3 && fc1 & 0x80 != 0
        let ackRequest = r3 ? fc1 & 0x80 != 0 : fc1 & 0x40 != 0
        let lowPower = r3 ? fc1 & 0x40 != 0 : fc1 & 0x20 != 0
        let sequence = r3 ? Int(bytes[8]) : Int(fc2 & 0x0F)
        var index = r3 ? 9 : 8
        var destination: String
        if headerType == 2 {
            // Multicast: Steuerbyte + 29 Byte Maske
            guard body.count >= index + 30 else { return nil }
            let control = bytes[index]
            let offset = Int(control >> 5) * 29 * 8
            var nodes: [Int] = []
            for k in 0..<29 {
                let mask = bytes[index + 1 + k]
                for b in 0..<8 where mask & (1 << b) != 0 { nodes.append(offset + k * 8 + b + 1) }
            }
            let list = nodes.prefix(12).map(String.init).joined(separator: ", ") + (nodes.count > 12 ? " …" : "")
            destination = String(localized: "Gruppe \(list)")
            index += 30
        } else {
            guard body.count > index else { return nil }
            destination = bytes[index] == 0xFF ? String(localized: "alle") : String(localized: "Knoten \(Int(bytes[index]))")
            index += 1
        }
        var fields: [SmartHomeFrame.Field] = [
            .init(name: "Home-ID", value: String(format: "%08X", homeID)),
            .init(name: String(localized: "Quelle"), value: String(localized: "Knoten \(Int(source))")),
            .init(name: String(localized: "Ziel"), value: destination),
            .init(name: String(localized: "Rahmentyp"), value: headerTypeName(headerType)),
            .init(name: String(localized: "Folgenummer"), value: "\(sequence)"),
        ]
        var flags: [String] = []
        if ackRequest { flags.append(String(localized: "Quittung erbeten")) }
        if routed { flags.append(String(localized: "geroutet")) }
        if lowPower { flags.append(String(localized: "geringe Leistung")) }
        if !r3 && fc1 & 0x10 != 0 { flags.append(String(localized: "Rate geändert")) }
        if !flags.isEmpty { fields.append(.init(name: String(localized: "Steuerung"), value: flags.joined(separator: ", "))) }
        if routed, body.count >= index + 2 {
            // Routing-Kopf: Status, (Zahl der Weiterleiter << 4 | Sprung), Weiterleiter …
            let hops = Int(bytes[index + 1] >> 4)
            if body.count >= index + 2 + hops {
                let repeaters = bytes[(index + 2)..<(index + 2 + hops)].map { String($0) }
                fields.append(.init(name: String(localized: "Weiterleiter"), value: repeaters.joined(separator: " → ")))
                index += 2 + hops
                // Erweiterter Kopf (Bit 3 im Status): Länge im oberen Halbbyte
                if bytes[index - 2 - hops] & 0x08 != 0, body.count > index {
                    index += 1 + Int(bytes[index] >> 4)
                }
            }
        }
        let payload = index < body.endIndex ? Array(body[index...]) : []
        var frame = SmartHomeFrame(radio: .zwave, mode: rate.rawValue,
                                   address: String(format: "%08X:%d", homeID, source),
                                   destination: destination,
                                   kind: headerTypeName(headerType),
                                   summary: headerType == 3 ? String(localized: "Quittung") : "",
                                   fields: fields, checksumOK: checksumOK, bytes: bytes)
        if headerType != 3, !payload.isEmpty {
            let command = describe(payload)
            frame.summary = command.summary
            frame.values = command.values
            frame.encrypted = command.encrypted
            frame.fields += command.fields
            frame.kind = command.className
            frame.deviceType = command.deviceType ?? ""
        } else if headerType != 3 {
            frame.summary = String(localized: "ohne Inhalt")
        }
        return frame
    }

    // MARK: - Kommandoklassen

    struct Command: Sendable, Equatable {
        var className: String
        var summary: String
        var values: [SmartHomeValue] = []
        var fields: [SmartHomeFrame.Field] = []
        var encrypted = false
        var deviceType: String?
    }

    static let classNames: [UInt8: String] = [
        0x00: String(localized: "Keine Operation"), 0x01: String(localized: "Z-Wave-Protokoll"), 0x20: "Basic",
        0x22: String(localized: "Anwendungsstatus"), 0x25: String(localized: "Binärschalter"),
        0x26: String(localized: "Dimmer"), 0x27: String(localized: "Alle schalten"), 0x2B: String(localized: "Szene"),
        0x30: String(localized: "Binärsensor"), 0x31: String(localized: "Messsensor"), 0x32: String(localized: "Zähler"),
        0x33: String(localized: "Farbe"), 0x35: String(localized: "Impulszähler"),
        0x40: String(localized: "Thermostat-Modus"), 0x42: String(localized: "Thermostat-Zustand"),
        0x43: String(localized: "Thermostat-Sollwert"), 0x45: String(localized: "Lüfterzustand"),
        0x55: String(localized: "Transportdienst"), 0x56: String(localized: "CRC-16-Hülle"),
        0x59: String(localized: "Gruppeninfo"), 0x5A: String(localized: "Gerät zurückgesetzt"),
        0x5B: String(localized: "Zentrale Szene"), 0x5E: "Z-Wave Plus", 0x60: String(localized: "Mehrkanal"),
        0x62: String(localized: "Türschloss"), 0x63: String(localized: "Benutzercode"),
        0x6C: String(localized: "Überwachung"), 0x70: String(localized: "Konfiguration"),
        0x71: String(localized: "Benachrichtigung"), 0x72: String(localized: "Herstellerangaben"),
        0x73: String(localized: "Sendeleistung"), 0x7A: String(localized: "Firmware-Update"),
        0x80: String(localized: "Batterie"), 0x84: String(localized: "Aufwachen"), 0x85: String(localized: "Zuordnung"),
        0x86: String(localized: "Version"), 0x87: String(localized: "Anzeige"),
        0x8E: String(localized: "Mehrkanal-Zuordnung"), 0x8F: String(localized: "Mehrfachbefehl"),
        0x98: String(localized: "Sicherheit S0"), 0x9C: String(localized: "Sensoralarm"),
        0x9F: String(localized: "Sicherheit S2"),
    ]

    static func describe(_ p: [UInt8], depth: Int = 0) -> Command {
        guard let cc = p.first else { return Command(className: String(localized: "leer"), summary: String(localized: "ohne Inhalt")) }
        let name = classNames[cc] ?? String(localized: "Klasse \(String(format: "0x%02X", cc))")
        guard p.count >= 2 else { return Command(className: name, summary: name) }
        let cmd = p[1]
        let args = Array(p.dropFirst(2))
        var c = Command(className: name, summary: String(localized: "\(name): Befehl \(String(format: "0x%02X", cmd))"))
        func onOff(_ v: UInt8) -> String {
            v == 0 ? String(localized: "aus") : (v == 0xFF || v == 0x63 ? String(localized: "ein") : "\(v) %")
        }
        switch (cc, cmd) {
        case (0x01, _):
            let names: [UInt8: String] = [
                0x01: String(localized: "Knoteninfo"), 0x02: String(localized: "Knoteninfo anfordern"),
                0x03: String(localized: "Knoten-IDs zuweisen"), 0x04: String(localized: "Nachbarsuche"),
                0x05: String(localized: "Nachbarn abfragen"), 0x06: String(localized: "Reichweiteninfo"),
                0x07: String(localized: "Befehl abgeschlossen"), 0x08: String(localized: "Leistungstest"),
                0x0C: String(localized: "Rückweg zuweisen"), 0x0D: String(localized: "Neuer Knoten registriert"),
                0x0E: String(localized: "Neuer Bereich registriert")]
            let command = names[cmd] ?? String(localized: "Befehl \(String(format: "0x%02X", cmd))")
            c.summary = String(localized: "Protokoll: \(command)")
            if cmd == 0x01, args.count >= 6 {
                let hex = { (b: UInt8) in String(format: "0x%02X", b) }
                c.fields.append(.init(name: String(localized: "Geräteklasse"),
                                      value: String(localized: "Basis \(hex(args[3])), generisch \(hex(args[4])), spezifisch \(hex(args[5]))")))
                c.deviceType = genericClass(args[4])
            }
        case (0x20, 0x01): c.summary = String(localized: "Basic: setze \(onOff(args.first ?? 0))")
        case (0x20, 0x02): c.summary = String(localized: "Basic: Abfrage")
        case (0x20, 0x03):
            c.summary = String(localized: "Basic: Zustand \(onOff(args.first ?? 0))")
            if let v = args.first { c.values.append(SmartHomeValue(name: "Zustand", unit: v <= 99 ? "%" : "", value: v == 0xFF ? 100 : Double(v))) }
        case (0x25, 0x01): c.summary = String(localized: "Schalter: setze \(onOff(args.first ?? 0))")
        case (0x25, 0x02): c.summary = String(localized: "Schalter: Abfrage")
        case (0x25, 0x03):
            c.summary = String(localized: "Schalter: \(onOff(args.first ?? 0))")
            if let v = args.first { c.values.append(SmartHomeValue(name: "Schaltzustand", unit: "", value: v == 0 ? 0 : 1)) }
            c.deviceType = String(localized: "Schaltaktor")
        case (0x26, 0x01): c.summary = String(localized: "Dimmer: setze \(onOff(args.first ?? 0))")
        case (0x26, 0x02): c.summary = String(localized: "Dimmer: Abfrage")
        case (0x26, 0x03):
            c.summary = String(localized: "Dimmer: \(onOff(args.first ?? 0))")
            if let v = args.first, v <= 99 { c.values.append(SmartHomeValue(name: "Helligkeit", unit: "%", value: Double(v))) }
            c.deviceType = String(localized: "Dimmer")
        case (0x30, 0x03):
            let v = args.first ?? 0
            c.summary = v == 0 ? String(localized: "Binärsensor: ruhig") : String(localized: "Binärsensor: ausgelöst")
            c.values.append(SmartHomeValue(name: "Ausgelöst", unit: "", value: v == 0 ? 0 : 1))
        case (0x31, 0x04): c.summary = String(localized: "Messsensor: Abfrage")
        case (0x31, 0x05):
            if args.count >= 2, let reading = sensorReading(type: args[0], Array(args.dropFirst())) {
                c.summary = "\(reading.label) \(reading.formatted)"
                c.values.append(reading)
                c.deviceType = String(localized: "Sensor")
            }
        case (0x32, 0x01): c.summary = String(localized: "Zähler: Abfrage")
        case (0x32, 0x02):
            if let reading = meterReading(args) {
                c.summary = "\(reading.label) \(reading.formatted)"
                c.values.append(reading)
                c.deviceType = String(localized: "Zähler")
            }
        case (0x40, 0x03):
            let modes = [String(localized: "aus"), String(localized: "heizen"), String(localized: "kühlen"),
                         String(localized: "automatisch"), String(localized: "Hilfsheizung"), String(localized: "Fortsetzen"),
                         String(localized: "Lüfter"), String(localized: "Umluft"), String(localized: "entfeuchten"),
                         String(localized: "Heizen/Kühlen"), String(localized: "Urlaub"), String(localized: "Eco heizen"),
                         String(localized: "Eco kühlen"), String(localized: "Abwesend"), "", String(localized: "Volle Leistung")]
            let m = Int((args.first ?? 0) & 0x1F)
            let mode = m < modes.count ? modes[m] : "\(m)"
            c.summary = String(localized: "Thermostat-Modus: \(mode)")
        case (0x43, 0x03):
            if args.count >= 2, let v = scaledValue(Array(args.dropFirst())) {
                let unit = v.scale == 1 ? "°F" : "°C"
                let value = SmartHomeValue(name: "Sollwert", unit: unit, value: v.value)
                c.summary = String(localized: "Sollwert \(value.formatted)")
                c.values.append(value)
                c.deviceType = String(localized: "Thermostat")
            }
        case (0x43, 0x01):
            if args.count >= 2, let v = scaledValue(Array(args.dropFirst())) {
                let target = SmartHomeValue(name: "", unit: v.scale == 1 ? "°F" : "°C", value: v.value).formatted
                c.summary = String(localized: "Sollwert setzen: \(target)")
            }
        case (0x71, 0x05):
            c.summary = notification(args)
            if args.count >= 6 {
                let type = notificationTypeKey(args[4])
                c.values.append(SmartHomeValue(name: "Ereignis \(type)", unit: "", value: Double(args[5]),
                                               label: String(localized: "Ereignis \(SmartHomeNames.label(type))")))
            }
        case (0x72, 0x05):
            if args.count >= 6 {
                let manufacturer = UInt16(args[0]) << 8 | UInt16(args[1])
                let hex = { (v: UInt16) in String(format: "0x%04X", v) }
                c.summary = String(localized: "Hersteller \(hex(manufacturer)), Produkt \(hex(UInt16(args[2]) << 8 | UInt16(args[3])))/\(hex(UInt16(args[4]) << 8 | UInt16(args[5])))")
                c.deviceType = manufacturerNames[manufacturer] ?? String(localized: "Hersteller \(hex(manufacturer))")
            }
        case (0x80, 0x02): c.summary = String(localized: "Batterie: Abfrage")
        case (0x80, 0x03):
            let v = args.first ?? 0
            c.summary = v == 0xFF ? String(localized: "Batterie schwach") : String(localized: "Batterie \(Int(v)) %")
            c.values.append(SmartHomeValue(name: "Batterie", unit: "%", value: v == 0xFF ? 0 : Double(v)))
        case (0x84, 0x04), (0x84, 0x06):
            if args.count >= 4 {
                let seconds = Int(args[0]) << 16 | Int(args[1]) << 8 | Int(args[2])
                let controller = Int(args[3])
                c.summary = cmd == 0x04
                    ? String(localized: "Weckintervall setzen: \(seconds) s, Steuerung Knoten \(controller)")
                    : String(localized: "Weckintervall: \(seconds) s, Steuerung Knoten \(controller)")
            }
        case (0x84, 0x05): c.summary = String(localized: "Weckintervall abfragen")
        case (0x84, 0x07): c.summary = String(localized: "Aufgewacht")
        case (0x84, 0x08): c.summary = String(localized: "Wieder schlafen")
        case (0x5B, 0x03):
            if args.count >= 3 {
                let scene = Int(args[2])
                c.summary = switch Int(args[1] & 0x07) {
                case 0: String(localized: "Szene \(scene) kurz gedrückt")
                case 1: String(localized: "Szene \(scene) losgelassen")
                case 2: String(localized: "Szene \(scene) gehalten")
                case let n where n <= 6: String(localized: "Szene \(scene) \(n - 1)× gedrückt")
                default: String(localized: "Szene \(scene)")
                }
                c.deviceType = String(localized: "Taster")
            }
        case (0x98, 0x40): c.summary = String(localized: "S0: Nonce anfordern")
        case (0x98, 0x80): c.summary = "S0: Nonce"
        case (0x98, 0x81), (0x98, 0xC1):
            c.summary = String(localized: "S0-verschlüsselt")
            c.encrypted = true
        case (0x9F, 0x01): c.summary = String(localized: "S2: Nonce anfordern")
        case (0x9F, 0x02): c.summary = "S2: Nonce"
        case (0x9F, 0x03):
            c.summary = String(localized: "S2-verschlüsselt")
            c.encrypted = true
            if args.count >= 2 { c.fields.append(.init(name: String(localized: "S2-Folgenummer"), value: "\(args[0])")) }
        case (0x9F, 0x04...0x0C):
            c.summary = String(localized: "S2: Schlüsselaustausch (Inklusion)")
        case (0x60, 0x0D):
            // Mehrkanal-Hülle: Quell- und Zielendpunkt, dann der eigentliche Befehl.
            if args.count >= 3, depth < 4 {
                var inner = describe(Array(args.dropFirst(2)), depth: depth + 1)
                let channel = Int(args[0] & 0x7F)
                inner.summary = String(localized: "Kanal \(channel): \(inner.summary)")
                inner.values = inner.values.map {
                    SmartHomeValue(name: "\($0.name) (Kanal \(channel))", unit: $0.unit, value: $0.value,
                                   label: String(localized: "\($0.label) (Kanal \(channel))"))
                }
                return inner
            }
        case (0x56, 0x01):
            if args.count >= 3, depth < 4 { return describe(Array(args.dropLast(2)), depth: depth + 1) }
        case (0x6C, 0x01):
            if args.count >= 3, depth < 4 { return describe(Array(args.dropFirst(2)), depth: depth + 1) }
        case (0x6C, 0x02):
            c.summary = args.count < 2 ? String(localized: "Überwachung: Bericht")
                : args[1] == 0xFF ? String(localized: "Überwachung: erledigt")
                : args[1] == 0x01 ? String(localized: "Überwachung: in Arbeit")
                : String(localized: "Überwachung: fehlgeschlagen")
        case (0x8F, 0x01):
            // Mehrfachbefehl: Anzahl, dann je Länge + Befehl
            if let count = args.first, depth < 4 {
                var parts: [String] = []
                var values: [SmartHomeValue] = []
                var encrypted = false
                var i = 1
                for _ in 0..<Int(count) {
                    guard i < args.count else { break }
                    let len = Int(args[i])
                    guard len > 0, i + 1 + len <= args.count else { break }
                    let inner = describe(Array(args[(i + 1)..<(i + 1 + len)]), depth: depth + 1)
                    parts.append(inner.summary)
                    values += inner.values
                    encrypted = encrypted || inner.encrypted
                    i += 1 + len
                }
                c.summary = parts.joined(separator: " · ")
                c.values = values
                c.encrypted = encrypted
            }
        case (0x5A, 0x01): c.summary = String(localized: "Gerät wurde zurückgesetzt")
        case (0x86, 0x12): c.summary = String(localized: "Version abfragen")
        case (0x86, 0x14):
            if args.count >= 5 {
                let library = Int(args[0]), protocolVersion = "\(args[1]).\(args[2])", application = "\(args[3]).\(args[4])"
                c.summary = String(localized: "Version: Bibliothek \(library), Protokoll \(protocolVersion), Anwendung \(application)")
            }
        default:
            break
        }
        return c
    }

    static func genericClass(_ value: UInt8) -> String? {
        switch value {
        case 0x01: String(localized: "Fernbedienung")
        case 0x02: String(localized: "Steuerung")
        case 0x08: String(localized: "Thermostat")
        case 0x09: String(localized: "Rollladen")
        case 0x10: String(localized: "Schaltaktor")
        case 0x11: String(localized: "Dimmer")
        case 0x12: String(localized: "Fernschalter")
        case 0x14: String(localized: "Schalter")
        case 0x16: String(localized: "Lüftung")
        case 0x17: String(localized: "Alarm")
        case 0x18: String(localized: "Wand-Controller")
        case 0x20: String(localized: "Binärsensor")
        case 0x21: String(localized: "Messsensor")
        case 0x30, 0x31: String(localized: "Zähler")
        case 0x40: String(localized: "Türschloss")
        case 0x0F: String(localized: "Weiterleiter")
        case 0xA1: String(localized: "Alarmsensor")
        default: nil
        }
    }

    static let manufacturerNames: [UInt16: String] = [
        0x010F: "Fibaro", 0x0086: "Aeotec", 0x0154: "Popp", 0x0159: "Qubino", 0x0060: "Everspring",
        0x0002: "Danfoss", 0x0148: "Eurotronic", 0x0175: "Devolo", 0x0063: "Jasco", 0x0346: "Ring",
        0x0371: "Aeotec", 0x0258: "Shenzhen Neo", 0x027A: "Zooz", 0x0099: "GreenWave", 0x0115: "Z-Wave.Me",
        0x0000: "Silicon Labs",
    ]

    /// Wert mit Präzision/Skala/Größe im ersten Byte (Messsensor, Sollwert).
    static func scaledValue(_ b: [UInt8]) -> (value: Double, scale: Int)? {
        guard let level = b.first else { return nil }
        let precision = Int(level >> 5), scale = Int((level >> 3) & 0x03), size = Int(level & 0x07)
        guard [1, 2, 4].contains(size), b.count >= 1 + size else { return nil }
        var raw: Int64 = 0
        for k in 0..<size { raw = raw << 8 | Int64(b[1 + k]) }
        let bits = Int64(size * 8)
        if raw & (1 << (bits - 1)) != 0 { raw -= 1 << bits }
        return (Double(raw) / pow(10, Double(precision)), scale)
    }

    static func sensorReading(type: UInt8, _ b: [UInt8]) -> SmartHomeValue? {
        guard let v = scaledValue(b) else { return nil }
        let table: [UInt8: (String, [String])] = [
            0x01: ("Temperatur", ["°C", "°F"]), 0x02: ("Allgemein", ["%", ""]), 0x03: ("Helligkeit", ["%", "lx"]),
            0x04: ("Leistung", ["W", "BTU/h"]), 0x05: ("Luftfeuchte", ["%", "g/m³"]), 0x06: ("Geschwindigkeit", ["m/s", "mph"]),
            0x07: ("Richtung", ["°"]), 0x08: ("Luftdruck", ["kPa", "inHg"]), 0x09: ("Luftdruck", ["kPa", "inHg"]),
            0x0A: ("Sonneneinstrahlung", ["W/m²"]), 0x0B: ("Taupunkt", ["°C", "°F"]), 0x0C: ("Regen", ["mm/h", "in/h"]),
            0x0D: ("Pegel", ["m", "ft"]), 0x0E: ("Gewicht", ["kg", "lb"]), 0x0F: ("Spannung", ["V", "mV"]),
            0x10: ("Strom", ["A", "mA"]), 0x11: ("CO₂", ["ppm"]), 0x12: ("Luftstrom", ["m³/h", "cfm"]),
            0x13: ("Tankinhalt", ["l", "cbm", "gal"]), 0x14: ("Abstand", ["m", "cm", "ft"]), 0x1B: ("UV-Index", [""]),
            0x1F: ("Bodenfeuchte", ["%"]), 0x23: ("Feinstaub PM2,5", ["µg/m³"]), 0x27: ("VOC", ["ppm"]),
            0x29: ("Wassertemperatur", ["°C", "°F"]), 0x2C: ("Frequenz", ["Hz", "kHz"]),
        ]
        let entry = table[type] ?? (String(format: "Messgröße 0x%02X", type), [])   // Schlüssel, nicht übersetzt
        let unit = v.scale < entry.1.count ? entry.1[v.scale] : ""
        return SmartHomeValue(name: entry.0, unit: unit, value: v.value)
    }

    static func meterReading(_ b: [UInt8]) -> SmartHomeValue? {
        guard b.count >= 2 else { return nil }
        let type = b[0] & 0x1F
        let scaleHigh = Int(b[0] >> 7)
        guard let v = scaledValue(Array(b.dropFirst())) else { return nil }
        let scale = scaleHigh << 2 | v.scale
        let (name, units): (String, [String]) = switch type {
        case 1: ("Strom", ["kWh", "kVAh", "W", "Impulse", "V", "A", "cos φ"])
        case 2: ("Gas", ["m³", "ft³", "", "Impulse"])
        case 3: ("Wasser", ["m³", "ft³", "gal", "Impulse"])
        case 4: ("Wärme", ["kWh"])
        case 5: ("Kälte", ["kWh"])
        default: ("Zähler \(type)", [])
        }
        let unit = scale < units.count ? units[scale] : ""
        let electric = ["Energie", "Scheinenergie", "Leistung", "Impulse", "Spannung", "Strom", "Leistungsfaktor"]
        let label = type == 1 ? electric[min(scale, electric.count - 1)] : name
        return SmartHomeValue(name: label, unit: unit, value: v.value)
    }

    /// Übersetzter Name der Benachrichtigungsart.
    static func notificationTypeName(_ t: UInt8) -> String {
        SmartHomeNames.label(notificationTypeKey(t))
    }

    /// Fester deutscher Name der Benachrichtigungsart (Schlüssel für `SmartHomeValue.name`).
    static func notificationTypeKey(_ t: UInt8) -> String {
        switch t {
        case 0x01: "Rauch"
        case 0x02: "CO"
        case 0x03: "CO₂"
        case 0x04: "Hitze"
        case 0x05: "Wasser"
        case 0x06: "Zugang"
        case 0x07: "Sicherheit"
        case 0x08: "Stromversorgung"
        case 0x09: "System"
        case 0x0A: "Notfall"
        case 0x0C: "Wetter"
        default: String(format: "0x%02X", t)
        }
    }

    static func notification(_ a: [UInt8]) -> String {
        guard a.count >= 6 else { return String(localized: "Benachrichtigung") }
        let type = a[4], event = a[5]
        let text: String = switch (type, event) {
        case (_, 0x00): String(localized: "Ruhe")
        case (0x01, 0x01), (0x01, 0x02): String(localized: "Rauch erkannt")
        case (0x05, 0x01), (0x05, 0x02): String(localized: "Wasser erkannt")
        case (0x06, 0x16): String(localized: "Tür/Fenster offen")
        case (0x06, 0x17): String(localized: "Tür/Fenster geschlossen")
        case (0x07, 0x03): String(localized: "Sabotage (Gehäuse geöffnet)")
        case (0x07, 0x07), (0x07, 0x08): String(localized: "Bewegung erkannt")
        case (0x08, 0x0A), (0x08, 0x0B): String(localized: "Batterie wechseln")
        default: String(localized: "Ereignis \(String(format: "0x%02X", event))")
        }
        return "\(notificationTypeName(type)): \(text)"
    }
}
