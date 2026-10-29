import Foundation

/// Homematic (BidCoS) auf 868,30 MHz: 2-FSK 10 kBaud, ±19 kHz (CC1101).
///
/// Luftrahmen wie beim CC1101 mit den Einstellungen aus culfw
/// (`rf_asksin.c`): Präambel 0xAA…, Sync-Wort 0xE9CA zweimal, dann Länge,
/// Daten und CRC-16 (Polynom 0x8005, Start 0xFFFF über Länge + Daten),
/// alles ab der Länge mit PN9 „geweißt“ (Start 0x1FF, erstes Byte 0xFF).
/// Die Daten selbst sind zusätzlich mit der BidCoS-Verwürfelung belegt
/// (Byte 1 = ¬x ⊕ 0x89, dann (vorheriges + 0xDC) ⊕ x, letztes ⊕ Flags).
///
/// Nach dem Entwürfeln: Länge · Zähler · Flags · Typ · Absender (3) · Empfänger (3) · Nutzdaten.
/// Homematic IP nutzt dieselbe Funkschicht, aber ohne BidCoS-Verwürfelung und
/// mit AES-gesicherten Inhalten – davon zeigt die App nur den Kopf.
enum Homematic {
    static let syncBits = SmartHomeDemod.bits(of: [0xE9, 0xCA, 0xE9, 0xCA])
    static let bitRate = 10_000.0

    /// PN9-Folge des CC1101 (x⁹ + x⁵ + 1, Start 0x1FF).
    static func whitening(count: Int) -> [UInt8] {
        var key: UInt16 = 0x1FF
        var out = [UInt8](repeating: 0, count: count)
        for n in 0..<count {
            out[n] = UInt8(key & 0xFF)
            for _ in 0..<8 { key = (key >> 1) | (((key ^ (key >> 5)) & 1) << 8) }
        }
        return out
    }

    static func whiten(_ bytes: [UInt8]) -> [UInt8] {
        zip(bytes, whitening(count: bytes.count)).map { $0 ^ $1 }
    }

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        SmartHomeCRC.crc16(bytes, poly: 0x8005, initial: 0xFFFF)
    }

    /// BidCoS-Entwürfelung; `enc[0]` ist die Länge.
    static func descramble(_ enc: [UInt8]) -> [UInt8] {
        guard enc.count >= 3 else { return enc }
        var dec = enc
        let length = min(Int(enc[0]), enc.count - 1)
        dec[1] = ~enc[1] ^ 0x89
        var l = 2
        while l < length {
            dec[l] = (enc[l - 1] &+ 0xDC) ^ enc[l]
            l += 1
        }
        if length >= 2 { dec[length] = enc[length] ^ dec[2] }
        return dec
    }

    /// Gegenstück (für Tests und Synthese).
    static func scramble(_ dec: [UInt8]) -> [UInt8] {
        guard dec.count >= 3 else { return dec }
        var enc = dec
        let length = min(Int(dec[0]), dec.count - 1)
        enc[1] = ~dec[1] ^ 0x89
        var l = 2
        while l < length {
            enc[l] = (enc[l - 1] &+ 0xDC) ^ dec[l]
            l += 1
        }
        if length >= 2 { enc[length] = dec[length] ^ dec[2] }
        return enc
    }

    /// Luftbytes ab der Länge (noch geweißt) für einen entwürfelten Rahmen.
    static func airBytes(message dec: [UInt8]) -> [UInt8] {
        let enc = scramble(dec)
        let crc = crc16(enc)
        return whiten(enc + [UInt8(crc >> 8), UInt8(crc & 0xFF)])
    }

    // MARK: - Bitstrom → Rahmen

    static func frames(inBits bits: [UInt8]) -> [SmartHomeFrame] {
        var out: [SmartHomeFrame] = []
        for start in SmartHomeDemod.find(syncBits, in: bits) {
            guard let first = SmartHomeDemod.bytes(bits, from: start, count: 1) else { continue }
            let length = Int(first[0] ^ 0xFF)
            guard length >= 9, length <= 60,
                  let raw = SmartHomeDemod.bytes(bits, from: start, count: length + 3) else { continue }
            let plain = whiten(raw)
            let enc = Array(plain[0...length])
            let crc = UInt16(plain[length + 1]) << 8 | UInt16(plain[length + 2])
            guard crc16(enc) == crc else { continue }
            guard let frame = parse(enc: enc) else { continue }
            if !out.contains(where: { $0.bytes == frame.bytes }) { out.append(frame) }
        }
        return out
    }

    // MARK: - Nachrichten

    static let typeNames: [UInt8: String] = [
        0x00: String(localized: "Geräteinfo"), 0x01: String(localized: "Konfiguration"),
        0x02: String(localized: "Bestätigung"), 0x03: String(localized: "AES-Antwort"),
        0x04: String(localized: "AES-Schlüssel"), 0x10: String(localized: "Information"),
        0x11: String(localized: "Steuerbefehl"), 0x12: String(localized: "Daten vorhanden"),
        0x3E: String(localized: "Schalten"), 0x3F: String(localized: "Zeitstempel"),
        0x40: String(localized: "Tastendruck"), 0x41: String(localized: "Sensorereignis"),
        0x53: String(localized: "Wassermelder"), 0x58: String(localized: "Klimaereignis"),
        0x59: String(localized: "Thermostat-Gruppe"), 0x5A: String(localized: "Thermostat"),
        0x5E: String(localized: "Leistungsmesser"), 0x5F: String(localized: "Leistungsmesser"),
        0x70: String(localized: "Wetterdaten"),
    ]

    static let modelNames: [UInt16: String] = [
        0x0039: "HM-CC-TC", 0x003D: "HM-WDS10-TH-O", 0x003F: "HM-WDS40-TH-I", 0x0042: "HM-Sec-SD",
        0x0057: "HM-LC-Dim1T-Pl", 0x0069: "HM-LC-Sw1PBU-FM", 0x0075: "HM-OU-CFM-Pl", 0x0095: "HM-CC-RT-DN",
        0x00AD: "HM-TC-IT-WM-W-EU", 0x00C7: "HM-Sec-SCo", 0x00D8: "HM-LC-Sw1-Pl-DN-R1", 0x00F4: "HM-RC-4-2",
        0x0011: "HM-LC-Sw1-Pl", 0x002F: "HM-Sec-SC", 0x004A: "HM-Sec-MDIR", 0x00AC: "HM-ES-PMSw1-Pl",
        0x00BD: "HM-CC-RT-DN-BoM", 0x00DB: "HM-Sen-MDIR-WM55", 0x00C1: "HM-Sec-SC-2", 0x00A9: "HM-PB-6-WM55",
    ]

    static func address(_ b: ArraySlice<UInt8>) -> String {
        b.map { String(format: "%02X", $0) }.joined()
    }

    /// Wertet einen Rahmen aus (`enc`: Länge + verwürfelte Daten, CRC geprüft).
    static func parse(enc: [UInt8]) -> SmartHomeFrame? {
        guard enc.count >= 10 else { return nil }
        let dec = descramble(enc)
        let type = dec[3]
        if typeNames[type] == nil {
            // Unbekannter Typ: vermutlich Homematic IP – Kopf ohne Entwürfelung.
            return parseIP(enc)
        }
        let counter = dec[1], flags = dec[2]
        let source = address(dec[4...6]), target = address(dec[7...9])
        let p = Array(dec.dropFirst(10))
        var frame = SmartHomeFrame(radio: .homematic, mode: "BidCoS · 10 kBaud", address: source,
                                   destination: target == "000000" ? String(localized: "alle") : target,
                                   kind: typeNames[type] ?? typeText(type),
                                   summary: typeNames[type] ?? "", checksumOK: true, bytes: dec)
        frame.deviceTypeFromInfo = type == 0x00
        frame.fields = [
            .init(name: String(localized: "Zähler"), value: "\(counter)"),
            .init(name: "Flags", value: flagText(flags)),
            .init(name: String(localized: "Typ"), value: String(format: "0x%02X %@", type, typeNames[type] ?? "")),
            .init(name: String(localized: "Absender"), value: source),
            .init(name: String(localized: "Empfänger"), value: target),
        ]
        describe(type: type, p, into: &frame)
        return frame
    }

    static func typeText(_ type: UInt8) -> String {
        String(localized: "Typ \(String(format: "0x%02X", type))")
    }

    /// „, Batterie schwach“ – wird an eine Zusammenfassung gehängt.
    static var batteryLowSuffix: String { String(localized: ", Batterie schwach") }

    static func flagText(_ f: UInt8) -> String {
        var parts: [String] = []
        if f & 0x01 != 0 { parts.append(String(localized: "wach")) }
        if f & 0x02 != 0 { parts.append(String(localized: "weckt")) }
        if f & 0x04 != 0 { parts.append(String(localized: "Rundruf")) }
        if f & 0x10 != 0 { parts.append(String(localized: "Weckfolge")) }
        if f & 0x20 != 0 { parts.append(String(localized: "Antwort erwartet")) }
        if f & 0x40 != 0 { parts.append(String(localized: "weitergeleitet")) }
        if f & 0x80 != 0 { parts.append(String(localized: "weiterleiten erlaubt")) }
        return String(format: "0x%02X", f) + (parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")")
    }

    private static func level(_ v: UInt8) -> String {
        v == 0 ? String(localized: "aus") : v >= 0xC8 ? String(localized: "ein") : String(format: "%.0f %%", Double(v) / 2)
    }

    static func describe(type: UInt8, _ p: [UInt8], into f: inout SmartHomeFrame) {
        switch type {
        case 0x00 where p.count >= 13:
            let model = UInt16(p[1]) << 8 | UInt16(p[2])
            let serial = String(bytes: p[3..<13].filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
            f.deviceType = modelNames[model] ?? String(localized: "Modell \(String(format: "0x%04X", model))")
            f.summary = String(localized: "Gerät \(f.deviceType), Seriennummer \(serial), Firmware \(Int(p[0] >> 4)).\(Int(p[0] & 0x0F))")
            f.fields.append(.init(name: String(localized: "Seriennummer"), value: serial))
        case 0x02:
            switch p.first {
            case 0x00?: f.summary = String(localized: "Bestätigung")
            case 0x01? where p.count >= 3:
                f.summary = String(localized: "Bestätigung, Kanal \(Int(p[1] & 0x3F)): \(level(p[2]))")
                f.values.append(channelLevel(p[1], p[2]))
            case 0x04?: f.summary = String(localized: "Bestätigung mit AES-Signaturanforderung"); f.encrypted = true
            case 0x80?: f.summary = String(localized: "Ablehnung")
            default: f.summary = String(localized: "Bestätigung")
            }
        case 0x03:
            f.summary = String(localized: "AES-Signatur")
            f.encrypted = true
        case 0x10:
            switch p.first {
            case 0x00? where p.count >= 11:
                f.summary = String(localized: "Seriennummer \(String(bytes: p[1..<11], encoding: .ascii) ?? "")")
            case 0x06? where p.count >= 3:
                f.summary = String(localized: "Status Kanal \(Int(p[1] & 0x3F)): \(level(p[2]))")
                f.values.append(channelLevel(p[1], p[2]))
                if p.count >= 4, p[3] & 0x80 != 0 { f.summary += batteryLowSuffix }
                f.deviceType = f.deviceType.isEmpty ? String(localized: "Aktor") : f.deviceType
            default:
                f.summary = String(localized: "Information") + (p.first.map { String(format: " 0x%02X", $0) } ?? "")
            }
        case 0x11 where p.count >= 3 && p[0] == 0x02:
            f.summary = String(localized: "Setze Kanal \(Int(p[1])) auf \(level(p[2]))")
        case 0x40 where p.count >= 2:
            let key = Int(p[0] & 0x3F), number = Int(p[1])
            f.summary = p[0] & 0x40 != 0
                ? String(localized: "Taste \(key) lang gedrückt (Nr. \(number))")
                : String(localized: "Taste \(key) kurz gedrückt (Nr. \(number))")
            if p[0] & 0x80 != 0 { f.summary += batteryLowSuffix }
            f.deviceType = f.deviceType.isEmpty ? String(localized: "Taster") : f.deviceType
        case 0x41 where p.count >= 3:
            let value = p[2]
            let state: String = switch value {
            case 0x00: String(localized: "geschlossen")
            case 0x64: String(localized: "gekippt")
            case 0xC8: String(localized: "offen")
            default: String(localized: "Wert \(Int(value))")
            }
            f.summary = String(localized: "Kanal \(Int(p[0] & 0x3F)): \(state)")
            if p[0] & 0x80 != 0 { f.summary += batteryLowSuffix }
            if [0x00, 0x64, 0xC8].contains(value) {
                f.values.append(SmartHomeValue(name: "Kontakt offen", unit: "%", value: Double(value) / 2))
                f.deviceType = f.deviceType.isEmpty ? String(localized: "Fensterkontakt") : f.deviceType
            } else {
                f.values.append(SmartHomeValue(name: "Sensorwert", unit: "", value: Double(value)))
                f.deviceType = f.deviceType.isEmpty ? String(localized: "Sensor") : f.deviceType
            }
        case 0x58 where p.count >= 2:
            let valve = (Double(p[1]) / 2.56).rounded()
            f.summary = String(localized: "Ventil \(Int(valve)) %")
            f.values.append(SmartHomeValue(name: "Ventil", unit: "%", value: valve))
            f.deviceType = f.deviceType.isEmpty ? String(localized: "Heizungsventil") : f.deviceType
        case 0x5A where p.count >= 2:
            let raw = Int(p[0]) << 8 | Int(p[1])
            let set = Double(raw >> 10) / 2
            var actual = raw & 0x3FF
            if actual & 0x200 != 0 { actual -= 0x400 }
            f.values.append(SmartHomeValue(name: "Temperatur", unit: "°C", value: Double(actual) / 10))
            f.values.append(SmartHomeValue(name: "Sollwert", unit: "°C", value: set))
            f.summary = String(localized: "\(String(format: "%.1f", Double(actual) / 10)) °C, Soll \(String(format: "%.1f", set)) °C")
            if p.count >= 3 {
                f.values.append(SmartHomeValue(name: "Luftfeuchte", unit: "%", value: Double(p[2])))
                f.summary += ", \(p[2]) %"
            }
            f.deviceType = f.deviceType.isEmpty ? String(localized: "Wandthermostat") : f.deviceType
        case 0x5E, 0x5F:
            guard p.count >= 10 else { break }
            let energy = Double((Int(p[0] & 0x7F) << 16) | Int(p[1]) << 8 | Int(p[2])) / 10 / 1000
            let power = Double(Int(p[3]) << 16 | Int(p[4]) << 8 | Int(p[5])) / 100
            let current = Double(Int(p[6]) << 8 | Int(p[7]))
            let voltage = Double(Int(p[8]) << 8 | Int(p[9])) / 10
            f.values += [SmartHomeValue(name: "Energie", unit: "kWh", value: energy),
                         SmartHomeValue(name: "Leistung", unit: "W", value: power),
                         SmartHomeValue(name: "Strom", unit: "mA", value: current),
                         SmartHomeValue(name: "Spannung", unit: "V", value: voltage)]
            if p.count >= 11 {
                f.values.append(SmartHomeValue(name: "Netzfrequenz", unit: "Hz", value: 50 + Double(Int8(bitPattern: p[10])) / 100))
            }
            f.summary = String(format: "%.2f W, %.1f V, %.3f kWh", power, voltage, energy)
            f.deviceType = f.deviceType.isEmpty ? String(localized: "Schaltsteckdose mit Messung") : f.deviceType
        case 0x70 where p.count >= 2:
            let raw = Int(p[0]) << 8 | Int(p[1])
            var t = raw & 0x7FFF
            if t & 0x4000 != 0 { t -= 0x8000 }
            let temperature = Double(t) / 10
            f.values.append(SmartHomeValue(name: "Temperatur", unit: "°C", value: temperature))
            f.summary = String(format: "%.1f °C", temperature)
            if p.count >= 3 {
                f.values.append(SmartHomeValue(name: "Luftfeuchte", unit: "%", value: Double(p[2])))
                f.summary += ", \(p[2]) %"
            }
            if raw & 0x8000 != 0 { f.summary += batteryLowSuffix }
            f.deviceType = f.deviceType.isEmpty ? String(localized: "Temperatur-/Feuchtesensor") : f.deviceType
        default:
            break
        }
    }

    /// Pegel eines Aktorkanals (Schlüssel „Pegel Kanal n“ bleibt für MQTT fest).
    private static func channelLevel(_ channelByte: UInt8, _ raw: UInt8) -> SmartHomeValue {
        let channel = Int(channelByte & 0x3F)
        return SmartHomeValue(name: "Pegel Kanal \(channel)", unit: "%", value: min(100, Double(raw) / 2),
                              label: String(localized: "Pegel Kanal \(channel)"))
    }

    /// Homematic IP: Kopf (Länge, Zähler, Flags, Typ, Absender, Empfänger) –
    /// der Inhalt ist AES-gesichert.
    static func parseIP(_ enc: [UInt8]) -> SmartHomeFrame {
        let source = address(enc[4...6]), target = address(enc[7...9])
        var frame = SmartHomeFrame(radio: .homematic, mode: String(localized: "Homematic IP (vermutet)"), address: source,
                                   destination: target, deviceType: "Homematic IP",
                                   kind: typeText(enc[3]),
                                   summary: String(localized: "Inhalt AES-verschlüsselt"), checksumOK: true, encrypted: true, bytes: enc)
        frame.fields = [
            .init(name: String(localized: "Zähler"), value: "\(enc[1])"),
            .init(name: "Flags", value: String(format: "0x%02X", enc[2])),
            .init(name: String(localized: "Typ"), value: String(format: "0x%02X", enc[3])),
            .init(name: String(localized: "Absender"), value: source),
            .init(name: String(localized: "Empfänger"), value: target),
        ]
        return frame
    }
}
