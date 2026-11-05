import Foundation

/// EnOcean ERP1 auf 868,30 MHz: ASK (Ein/Aus), 125 kbit/s – batterielose
/// Taster und Sensoren.
///
/// Luftrahmen wie in rtl_433 (`enocean_erp1.c`): Die Bits sind invertiert
/// (Träger aus = 1). Nach der Präambel 01010101 + 001 folgt jedes Byte
/// als 12 Bit: d7 d6 d5 ¬d5 d4 d3 d2 ¬d2 d1 d0 und zwei Folgebits – „01“,
/// wenn noch ein Byte kommt. Telegramm: RORG · Daten · Sender-ID (4) ·
/// Status · CRC-8 (Polynom 0x07, Start 0).
enum EnOcean {
    static let bitRate = 125_000.0
    /// Präambel + Startbits nach dem Invertieren.
    static let syncBits: [UInt8] = [0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1]

    static func crc8<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        SmartHomeCRC.crc8(bytes, poly: 0x07)
    }

    /// Bytes nach der Präambel (`from`: erste Bitposition) – bricht beim
    /// ersten verletzten Prüfbit ab.
    static func decode8of12(_ bits: [UInt8], from: Int) -> [UInt8] {
        var out: [UInt8] = []
        var pos = from
        while pos + 12 <= bits.count, out.count < 32 {
            let b = bits[pos..<(pos + 12)].map { $0 }
            guard b[2] != b[3], b[6] != b[7] else { break }
            let byte = b[0] << 7 | b[1] << 6 | b[2] << 5 | b[4] << 4 | b[5] << 3 | b[6] << 2 | b[8] << 1 | b[9]
            out.append(byte)
            pos += 12
            if !(b[10] == 0 && b[11] == 1) { break }
        }
        return out
    }

    /// Luftbits (bereits invertiert = logisch) für ein Telegramm – für Tests und Synthese.
    static func encode8of12(_ bytes: [UInt8]) -> [UInt8] {
        var out = syncBits
        for (n, byte) in bytes.enumerated() {
            let d = (0..<8).map { (byte >> (7 - $0)) & 1 }
            out += [d[0], d[1], d[2], d[2] ^ 1, d[3], d[4], d[5], d[5] ^ 1, d[6], d[7]]
            out += n == bytes.count - 1 ? [1, 0] : [0, 1]
        }
        return out
    }

    /// Datenlänge je RORG (ohne RORG, ID, Status, CRC).
    static func dataLength(rorg: UInt8, total: Int) -> Int? {
        switch rorg {
        case 0xF6, 0xD5: 1
        case 0xA5: 4
        case 0xD2, 0xD4, 0xD1: total - 7 > 0 ? total - 7 : nil
        default: nil
        }
    }

    static func frames(inBits stream: [UInt8]) -> [SmartHomeFrame] {
        var out: [SmartHomeFrame] = []
        for bits in [SmartHomeDemod.inverted(stream), stream] {
            for start in SmartHomeDemod.find(syncBits, in: bits) {
                let bytes = decode8of12(bits, from: start)
                guard bytes.count >= 8, let n = dataLength(rorg: bytes[0], total: bytes.count) else { continue }
                let total = 1 + n + 4 + 1 + 1
                guard bytes.count >= total else { continue }
                let telegram = Array(bytes[0..<total])
                guard crc8(telegram.dropLast()) == telegram.last else { continue }
                if let frame = parse(telegram), !out.contains(where: { $0.bytes == frame.bytes }) { out.append(frame) }
            }
            if !out.isEmpty { break }
        }
        return out
    }

    // MARK: - Telegramm

    static func rorgName(_ rorg: UInt8) -> String {
        switch rorg {
        case 0xF6: String(localized: "RPS (Taster)")
        case 0xD5: String(localized: "1BS (1 Byte)")
        case 0xA5: String(localized: "4BS (4 Byte)")
        case 0xD2: String(localized: "VLD (variabel)")
        case 0xD4: String(localized: "UTE (Anlernen)")
        case 0xD1: String(localized: "MSC (herstellerspezifisch)")
        default: String(format: "RORG 0x%02X", rorg)
        }
    }

    /// Zerlegt ein Telegramm (mit CRC). `eep`: bekanntes Geräteprofil
    /// („A5-02-05“), sonst wird ein gängiges angenommen bzw. aus einem
    /// Anlerntelegramm gelesen.
    static func parse(_ t: [UInt8], eep: String? = nil) -> SmartHomeFrame? {
        guard t.count >= 8 else { return nil }
        let rorg = t[0]
        let n = t.count - 7
        let data = Array(t[1...n])
        let id = t[(n + 1)...(n + 4)].map { String(format: "%02X", $0) }.joined()
        let status = t[n + 5]
        var frame = SmartHomeFrame(radio: .enocean, mode: "ERP1 · 125 kbit/s", address: id,
                                   kind: rorgName(rorg), summary: "", checksumOK: true, bytes: t)
        frame.fields = [
            .init(name: String(localized: "Sender-ID"), value: id),
            .init(name: "RORG", value: String(format: "0x%02X %@", rorg, rorgName(rorg))),
            .init(name: String(localized: "Daten"), value: SmartHomeHex.string(data)),
            .init(name: String(localized: "Status"),
                  value: String(localized: "\(String(format: "0x%02X", status)) (Weiterleitungen \(Int(status & 0x0F)))")),
        ]
        switch rorg {
        case 0xF6:
            // Fenstergriffe (F6-10-00) senden C0/D0/E0/F0 mit T21 = 1, NU = 0 – wie
            // „mehrere Tasten“ eines Tasters; ohne Profil nur vermutet.
            let handle = handlePosition(data[0])
            if let handle, eep == "F6-10-00" || (eep == nil && status & 0x30 == 0x20) {
                frame.summary = String(localized: "Fenstergriff: \(handle.text)")
                frame.values.append(SmartHomeValue(name: "Griff", unit: "%", value: handle.openPercent))
                frame.deviceType = eep == nil ? String(localized: "Fenstergriff (F6-10-00, vermutet)") : String(localized: "Fenstergriff (F6-10-00)")
                frame.deviceTypeGuessed = eep == nil
            } else {
                frame.summary = rocker(data[0], status: status)
                frame.deviceType = String(localized: "Taster (F6-02)")
                frame.values.append(SmartHomeValue(name: "Gedrückt", unit: "", value: data[0] & 0x10 != 0 ? 1 : 0))
            }
        case 0xD5:
            let closed = data[0] & 0x01 != 0
            if data[0] & 0x08 == 0 {
                frame.summary = String(localized: "Anlernen (1BS)")
            } else {
                frame.summary = closed ? String(localized: "Kontakt geschlossen") : String(localized: "Kontakt offen")
                frame.values.append(SmartHomeValue(name: "Kontakt offen", unit: "", value: closed ? 0 : 1))
            }
            frame.deviceType = String(localized: "Kontakt (D5-00-01)")
        case 0xA5 where data.count == 4:
            if data[3] & 0x08 == 0 {
                // Anlerntelegramm
                if let learned = teachIn(data) {
                    if let manufacturer = learned.manufacturer {
                        frame.summary = String(localized: "Anlernen: Profil \(learned.eep), Hersteller \(String(format: "0x%03X", manufacturer))")
                    } else {
                        frame.summary = String(localized: "Anlernen: Profil \(learned.eep)")
                    }
                    frame.deviceType = learned.eep
                    frame.deviceTypeFromInfo = true
                    frame.fields.append(.init(name: "EEP", value: learned.eep))
                } else {
                    frame.summary = String(localized: "Anlernen (ohne Profil)")
                }
            } else {
                let profile = eep ?? "A5-02-05"
                frame.values = fourBS(data, eep: profile)
                frame.deviceType = eep == nil ? String(localized: "\(profile) (angenommen)") : profile
                frame.deviceTypeGuessed = eep == nil
                frame.summary = frame.values.isEmpty ? String(localized: "Daten \(SmartHomeHex.string(data))")
                    : frame.values.map { "\($0.label) \($0.formatted)" }.joined(separator: ", ")
            }
        case 0xD4 where data.count == 7:
            // Universal Teach-in: DB6 Befehl, DB5 Kanäle, DB4/DB3 Hersteller, DB2 TYPE, DB1 FUNC, DB0 RORG.
            let profile = String(format: "%02X-%02X-%02X", data[6], data[5], data[4])
            let manufacturer = Int(data[3] & 0x07) << 8 | Int(data[2])
            frame.summary = String(localized: "Anlernen (UTE): Profil \(profile), Hersteller \(String(format: "0x%03X", manufacturer))")
            frame.deviceType = profile
            frame.deviceTypeFromInfo = true
            frame.fields.append(.init(name: "EEP", value: profile))
        case 0xD2:
            if let eep, eep.hasPrefix("D2-01") {
                (frame.summary, frame.values) = vldSwitch(data)
                frame.deviceType = String(localized: "Aktor (\(eep))")
            } else if let eep, eep.hasPrefix("D2-05") {
                (frame.summary, frame.values) = vldBlind(data)
                frame.deviceType = String(localized: "Rollladen (\(eep))")
            } else {
                frame.summary = String(localized: "VLD-Daten \(SmartHomeHex.string(data)) – Profil unbekannt")
            }
        default:
            frame.summary = String(localized: "Daten \(SmartHomeHex.string(data))")
        }
        return frame
    }

    /// Ein Profil, das die App deuten kann (Liste oder VLD-Familie D2-01/D2-05).
    static func isSupported(_ eep: String) -> Bool {
        supportedProfiles.contains(eep) || eep.hasPrefix("D2-01-") || eep.hasPrefix("D2-05-")
    }

    /// D2-01 (Schalt-/Dimmaktoren): Befehl im unteren Halbbyte von DB0.
    /// 0x4 Zustand: Kanal (Bits 0–4), Ausgang 0–100 % (127 = ungültig);
    /// 0x7 Messwert: Einheit (Bits 5–7: Ws, Wh, kWh, W, kW), Kanal, Wert 32 Bit.
    static func vldSwitch(_ d: [UInt8]) -> (String, [SmartHomeValue]) {
        guard let first = d.first else { return ("", []) }
        switch first & 0x0F {
        case 0x4 where d.count >= 3:
            let channel = Int(d[1] & 0x1F), output = Int(d[2] & 0x7F)
            guard output <= 100 else { return (String(localized: "Kanal \(channel): Zustand unbekannt"), []) }
            let text = output == 0 ? String(localized: "aus") : output == 100 ? String(localized: "ein") : "\(output) %"
            return (String(localized: "Kanal \(channel): \(text)"),
                    [SmartHomeValue(name: "Pegel Kanal \(channel)", unit: "%", value: Double(output), label: String(localized: "Pegel Kanal \(channel)"))])
        case 0x7 where d.count >= 6:
            let unit = Int(d[1] >> 5), channel = Int(d[1] & 0x1F)
            let raw = Double(UInt32(d[2]) << 24 | UInt32(d[3]) << 16 | UInt32(d[4]) << 8 | UInt32(d[5]))
            let value: SmartHomeValue
            switch unit {
            case 0: value = SmartHomeValue(name: "Energie", unit: "kWh", value: raw / 3_600_000)
            case 1: value = SmartHomeValue(name: "Energie", unit: "kWh", value: raw / 1000)
            case 2: value = SmartHomeValue(name: "Energie", unit: "kWh", value: raw)
            case 3: value = SmartHomeValue(name: "Leistung", unit: "W", value: raw)
            case 4: value = SmartHomeValue(name: "Leistung", unit: "W", value: raw * 1000)
            default: return (String(localized: "Kanal \(channel): Messwert"), [])
            }
            return (String(localized: "Kanal \(channel): \(value.label) \(value.formatted)"), [value])
        default:
            return (String(localized: "Befehl \(Int(first & 0x0F))"), [])
        }
    }

    /// D2-05 (Rollläden): Antwort Befehl 0x4 – Position und Lamellenwinkel 0–100 % (127 unbekannt).
    static func vldBlind(_ d: [UInt8]) -> (String, [SmartHomeValue]) {
        guard d.count >= 4, d[3] & 0x0F == 0x4 else { return (String(localized: "Rollladen-Befehl"), []) }
        let position = Int(d[0] & 0x7F), angle = Int(d[1] & 0x7F)
        guard position <= 100 else { return (String(localized: "Position unbekannt"), []) }
        var values = [SmartHomeValue(name: "Rollladen geschlossen", unit: "%", value: Double(position))]
        var text = String(localized: "\(position) % geschlossen")
        if angle <= 100 {
            values.append(SmartHomeValue(name: "Lamellenwinkel", unit: "%", value: Double(angle)))
            text += String(localized: ", Lamellen \(angle) %")
        }
        return (text, values)
    }

    /// F6-02-xx: Wippentaster.
    static func rocker(_ d: UInt8, status: UInt8) -> String {
        let buttons = ["AI", "A0", "BI", "B0"]
        let nu = status & 0x10 != 0
        let pressed = d & 0x10 != 0
        if nu {
            let button = buttons[Int(d >> 5) & 3]
            var text = pressed ? String(localized: "Taste \(button) gedrückt") : String(localized: "Taste \(button) losgelassen")
            if d & 0x01 != 0 { text += " + \(buttons[Int((d >> 1) & 0x07) & 3])" }
            return text
        }
        return pressed ? String(localized: "\(Int(d >> 5)) Tasten gedrückt") : String(localized: "Tasten losgelassen")
    }

    /// F6-10-00: Stellung des Fenstergriffs (0 = zu, 50 = gekippt, 100 = offen).
    static func handlePosition(_ d: UInt8) -> (text: String, openPercent: Double)? {
        switch d & 0xF0 {
        case 0xF0: (String(localized: "geschlossen"), 0)
        case 0xD0: (String(localized: "gekippt"), 50)
        case 0xC0, 0xE0: (String(localized: "offen"), 100)
        default: nil
        }
    }

    /// Anlerntelegramm 4BS (Variante 2): FUNC, TYPE, Hersteller.
    static func teachIn(_ d: [UInt8]) -> (eep: String, manufacturer: Int?)? {
        guard d.count == 4, d[3] & 0x80 != 0 else { return nil }
        let function = d[0] >> 2
        let type = (d[0] & 0x03) << 5 | d[1] >> 3
        let manufacturer = Int(d[1] & 0x07) << 8 | Int(d[2])
        return (String(format: "A5-%02X-%02X", function, type), manufacturer)
    }

    /// A5-12-xx Zähler (AMR): 24-Bit-Stand, DB0 Bit 2 = aktueller Wert statt Summe,
    /// Bits 0–1 = Teiler 1/10/100/1000. Einheit je Typ: Impulse, kWh/W, m³/l/s.
    static func meterValue(_ d: [UInt8], type: Int) -> SmartHomeValue {
        let raw = Double(Int(d[0]) << 16 | Int(d[1]) << 8 | Int(d[2]))
        let value = raw / [1, 10, 100, 1000][Int(d[3] & 0x03)]
        let current = d[3] & 0x04 != 0
        switch type {
        case 0x01: return current ? SmartHomeValue(name: "Leistung", unit: "W", value: value)
                                  : SmartHomeValue(name: "Energie", unit: "kWh", value: value)
        case 0x02, 0x03:
            return current ? SmartHomeValue(name: "Durchfluss", unit: "l/s", value: value)
                           : SmartHomeValue(name: type == 0x02 ? "Gas" : "Wasser", unit: "m³", value: value)
        default: return SmartHomeValue(name: "Zähler", unit: "", value: value)
        }
    }

    /// Bereiche der Temperaturfühler A5-02-01 … 0B und 10 … 1B (255 = Minimum).
    static func temperatureRange(type: Int) -> (Double, Double)? {
        switch type {
        case 0x01...0x0B: let low = -40 + Double(type - 1) * 10; return (low, low + 40)
        case 0x10...0x1B: let low = -60 + Double(type - 0x10) * 10; return (low, low + 80)
        default: return nil
        }
    }

    static let supportedProfiles = ["A5-02-01", "A5-02-02", "A5-02-03", "A5-02-04", "A5-02-05", "A5-02-06",
                                    "A5-02-07", "A5-02-08", "A5-02-09", "A5-02-0A", "A5-02-0B",
                                    "A5-02-10", "A5-02-11", "A5-02-12", "A5-02-13", "A5-02-14", "A5-02-15",
                                    "A5-02-16", "A5-02-17", "A5-02-18", "A5-02-19", "A5-02-1A", "A5-02-1B",
                                    "A5-04-01", "A5-04-02", "A5-06-01", "A5-06-02", "A5-07-01", "A5-08-01",
                                    "A5-09-04", "A5-10-01", "A5-10-02", "A5-10-03", "A5-10-04", "A5-10-05", "A5-10-06",
                                    "A5-12-00", "A5-12-01", "A5-12-02", "A5-12-03", "A5-14-01", "A5-20-01", "F6-10-00",
                                    "D2-01-00", "D2-01-12", "D2-05-00"]

    /// 4BS-Daten (DB3 … DB0) nach Profil.
    static func fourBS(_ d: [UInt8], eep: String) -> [SmartHomeValue] {
        let parts = eep.split(separator: "-")
        guard parts.count == 3, let function = Int(parts[1], radix: 16), let type = Int(parts[2], radix: 16) else { return [] }
        switch (function, type) {
        case (0x02, _):
            guard let (low, high) = temperatureRange(type: type) else { return [] }
            let t = high - Double(d[2]) * (high - low) / 255
            return [SmartHomeValue(name: "Temperatur", unit: "°C", value: (t * 10).rounded() / 10)]
        case (0x04, 0x01):
            var values = [SmartHomeValue(name: "Luftfeuchte", unit: "%", value: (Double(d[1]) * 100 / 250 * 10).rounded() / 10)]
            if d[3] & 0x02 != 0 {
                values.insert(SmartHomeValue(name: "Temperatur", unit: "°C", value: (Double(d[2]) * 40 / 250 * 10).rounded() / 10), at: 0)
            }
            return values
        case (0x04, 0x02):
            var values = [SmartHomeValue(name: "Luftfeuchte", unit: "%", value: (Double(d[1]) * 100 / 250 * 10).rounded() / 10)]
            if d[3] & 0x02 != 0 {
                values.insert(SmartHomeValue(name: "Temperatur", unit: "°C", value: ((Double(d[2]) * 80 / 250 - 20) * 10).rounded() / 10), at: 0)
            }
            return values
        case (0x06, 0x01), (0x06, 0x02):
            // Helligkeit: zwei Messbereiche, DB0 Bit 0 wählt (0 = ILL1 in DB1, 1 = ILL2 in DB2).
            let wide = type == 0x01
            let lux = d[3] & 0x01 == 0
                ? (wide ? 600 + Double(d[2]) * (60_000 - 600) / 255 : Double(d[2]) * 1020 / 255)
                : (wide ? 300 + Double(d[1]) * (30_000 - 300) / 255 : Double(d[1]) * 510 / 255)
            return [SmartHomeValue(name: "Helligkeit", unit: "lx", value: lux.rounded()),
                    SmartHomeValue(name: "Batterie", unit: "V", value: (Double(d[0]) * 5.1 / 255 * 100).rounded() / 100)]
        case (0x07, 0x01):
            var values = [SmartHomeValue(name: "Bewegung", unit: "", value: d[2] >= 128 ? 1 : 0)]
            if d[3] & 0x01 != 0, d[0] <= 250 { values.append(SmartHomeValue(name: "Batterie", unit: "V", value: Double(d[0]) / 50)) }
            return values
        case (0x08, 0x01):
            return [SmartHomeValue(name: "Helligkeit", unit: "lx", value: (Double(d[1]) * 510 / 255).rounded()),
                    SmartHomeValue(name: "Temperatur", unit: "°C", value: (Double(d[2]) * 51 / 255 * 10).rounded() / 10)]
        case (0x09, 0x04):
            var values = [SmartHomeValue(name: "CO₂", unit: "ppm", value: Double(d[1]) * 10)]
            if d[3] & 0x04 != 0 { values.append(SmartHomeValue(name: "Luftfeuchte", unit: "%", value: Double(d[0]) / 2)) }
            if d[3] & 0x02 != 0 { values.append(SmartHomeValue(name: "Temperatur", unit: "°C", value: (Double(d[2]) * 51 / 255 * 10).rounded() / 10)) }
            return values
        case (0x10, 0x01...0x06):
            // Raumbediengerät: Temperatur 0–40 °C fallend kodiert, Sollwertsteller 0–100 %.
            return [SmartHomeValue(name: "Temperatur", unit: "°C", value: ((255 - Double(d[2])) * 40 / 255 * 10).rounded() / 10),
                    SmartHomeValue(name: "Sollwertsteller", unit: "%", value: (Double(d[1]) * 100 / 255).rounded())]
        case (0x12, 0x00...0x03):
            return [meterValue(d, type: type)]
        case (0x14, 0x01):
            var values = [SmartHomeValue(name: "Kontakt offen", unit: "", value: d[3] & 0x01 == 0 ? 1 : 0)]
            if d[0] <= 250 { values.append(SmartHomeValue(name: "Batterie", unit: "V", value: Double(d[0]) / 50)) }
            return values
        case (0x20, 0x01):
            // Stellantrieb (z. B. Heizkörperventil): Ventil %, Temperatur 0–40 °C; DB2 Bit 0 = Batterie schwach.
            var values = [SmartHomeValue(name: "Ventil", unit: "%", value: Double(min(d[0], 100))),
                          SmartHomeValue(name: "Temperatur", unit: "°C", value: (Double(d[2]) * 40 / 255 * 10).rounded() / 10)]
            if d[1] & 0x10 != 0 { values.append(SmartHomeValue(name: "Batterie schwach", unit: "", value: 1)) }
            return values
        default:
            return []
        }
    }
}
