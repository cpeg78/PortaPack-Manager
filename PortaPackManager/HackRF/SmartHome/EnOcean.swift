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
            frame.summary = rocker(data[0], status: status)
            frame.deviceType = String(localized: "Taster (F6-02)")
            frame.values.append(SmartHomeValue(name: "Gedrückt", unit: "", value: data[0] & 0x10 != 0 ? 1 : 0))
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
        default:
            frame.summary = String(localized: "Daten \(SmartHomeHex.string(data))")
        }
        return frame
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

    /// Anlerntelegramm 4BS (Variante 2): FUNC, TYPE, Hersteller.
    static func teachIn(_ d: [UInt8]) -> (eep: String, manufacturer: Int?)? {
        guard d.count == 4, d[3] & 0x80 != 0 else { return nil }
        let function = d[0] >> 2
        let type = (d[0] & 0x03) << 5 | d[1] >> 3
        let manufacturer = Int(d[1] & 0x07) << 8 | Int(d[2])
        return (String(format: "A5-%02X-%02X", function, type), manufacturer)
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
                                    "A5-04-01", "A5-04-02"]

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
        default:
            return []
        }
    }
}
