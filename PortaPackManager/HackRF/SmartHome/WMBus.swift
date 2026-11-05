import CommonCrypto
import Foundation

/// Wireless M-Bus (EN 13757-4) auf 868,95 MHz – Funkzähler für Wasser,
/// Wärme, Strom, Gas, Heizkostenverteiler.
///
/// - T1: 100 kchip/s FSK, jedes Byte als zwei 3-aus-6-Gruppen (12 Chips,
///   oberes Halbbyte zuerst), Format A.
/// - C1: 100 kbit/s NRZ-FSK, Format A oder B; nach dem Sync 0x543D folgt
///   0x54 und dann 0xCD (A) bzw. 0x3D (B).
/// Beide beginnen mit Präambel …0101 und Sync 0x543D (wie rtl_433 `m_bus.c`).
///
/// Format A: Block 1 = 10 Byte (L C M A) + CRC, dann Blöcke zu 16 Byte + CRC.
/// Format B: L zählt alles samt CRCs; bis 128 Byte ein CRC am Ende, sonst
/// zwei (nach Byte 126 und am Schluss). CRC-16 Polynom 0x3D65, Ergebnis invertiert.
///
/// Anwendungsschicht: CI 0x7A (kurzer Kopf), 0x72 (langer Kopf), 0x78
/// (ohne Kopf); Verschlüsselung Modus 5 (AES-128-CBC, IV = M · A · 8 × ACC)
/// mit hinterlegtem Schlüssel; ELL 0x8D (AES-CTR, Kamstrup u. a.).
enum WMBus {
    static let chipRate = 100_000.0
    static let syncBits = SmartHomeDemod.bits(of: [0x54, 0x3D])

    // MARK: - CRC und Kodierung

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        SmartHomeCRC.crc16(bytes, poly: 0x3D65, initial: 0, xorOut: 0xFFFF)
    }

    /// 3-aus-6-Kodes für die Halbbytes 0 … F.
    static let threeOfSix: [UInt8] = [0x16, 0x0D, 0x0E, 0x0B, 0x1C, 0x19, 0x1A, 0x13,
                                      0x2C, 0x25, 0x26, 0x23, 0x34, 0x31, 0x32, 0x29]
    static let threeOfSixDecode: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (nibble, code) in threeOfSix.enumerated() { table[code] = UInt8(nibble) }
        return table
    }()

    static func encode3of6(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for byte in bytes {
            for code in [threeOfSix[Int(byte >> 4)], threeOfSix[Int(byte & 0x0F)]] {
                for k in 0..<6 { out.append((code >> (5 - k)) & 1) }
            }
        }
        return out
    }

    static func decode3of6(_ bits: [UInt8], from: Int, count: Int) -> [UInt8]? {
        guard from + count * 12 <= bits.count else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        for n in 0..<count {
            var nibbles: [UInt8] = []
            for half in 0..<2 {
                var code: UInt8 = 0
                for k in 0..<6 { code = code << 1 | bits[from + n * 12 + half * 6 + k] }
                guard let nibble = threeOfSixDecode[code] else { return nil }
                nibbles.append(nibble)
            }
            out[n] = nibbles[0] << 4 | nibbles[1]
        }
        return out
    }

    /// Länge auf der Luft (Byte) eines Format-A-Rahmens mit L-Feld `l`.
    static func formatALength(_ l: Int) -> Int {
        let rest = max(0, l - 9)
        return 12 + rest + 2 * ((rest + 15) / 16)
    }

    /// Format A: CRCs prüfen und entfernen.
    static func stripFormatA(_ raw: [UInt8]) -> (data: [UInt8], crcOK: Bool)? {
        guard let l = raw.first, raw.count >= formatALength(Int(l)), l >= 9 else { return nil }
        var data: [UInt8] = []
        var ok = true
        var pos = 0
        var remaining = Int(l) + 1
        var blockSize = 10
        while remaining > 0 {
            let n = min(blockSize, remaining)
            let block = raw[pos..<(pos + n)]
            let crc = UInt16(raw[pos + n]) << 8 | UInt16(raw[pos + n + 1])
            if crc16(block) != crc { ok = false }
            data += block
            pos += n + 2
            remaining -= n
            blockSize = 16
        }
        return (data, ok)
    }

    /// Format B: CRCs prüfen und entfernen.
    static func stripFormatB(_ raw: [UInt8]) -> (data: [UInt8], crcOK: Bool)? {
        guard let l = raw.first, l >= 12, raw.count >= Int(l) + 1 else { return nil }
        let total = Int(l) + 1
        if total <= 128 {
            let body = raw[0..<(total - 2)]
            let crc = UInt16(raw[total - 2]) << 8 | UInt16(raw[total - 1])
            return (Array(body), crc16(body) == crc)
        }
        // Zweiter Block braucht mindestens ein Datenbyte plus CRC – L = 0x80/0x81
        // ergäbe sonst einen Bereich mit umgekehrten Grenzen (Absturz, Review K1).
        guard total >= 131 else { return nil }
        let first = raw[0..<126]
        let crc1 = UInt16(raw[126]) << 8 | UInt16(raw[127])
        let second = raw[128..<(total - 2)]
        let crc2 = UInt16(raw[total - 2]) << 8 | UInt16(raw[total - 1])
        return (Array(first) + Array(second), crc16(first) == crc1 && crc16(second) == crc2)
    }

    // MARK: - Bitstrom → Rahmen

    /// `keys`: Ident-Nummer (8 Ziffern) → AES-Schlüssel.
    /// `formats`: gelernte Datensatzköpfe je Formatsignatur – für Kompaktrahmen (CI 0x79).
    static func frames(inBits stream: [UInt8], keys: [String: [UInt8]], formats: [UInt16: [UInt8]] = [:]) -> [SmartHomeFrame] {
        var out: [SmartHomeFrame] = []
        for bits in [stream, SmartHomeDemod.inverted(stream)] {
            for start in SmartHomeDemod.find(syncBits, in: bits) {
                if let frame = decodeAt(bits, start: start, keys: keys, formats: formats), !out.contains(where: { $0.bytes == frame.bytes }) {
                    out.append(frame)
                }
            }
            if !out.isEmpty { break }
        }
        return out
    }

    private static func decodeAt(_ bits: [UInt8], start: Int, keys: [String: [UInt8]], formats: [UInt16: [UInt8]]) -> SmartHomeFrame? {
        // C1: 0x54 und Formatkennung
        if let mark = SmartHomeDemod.bytes(bits, from: start, count: 2), mark[0] == 0x54, mark[1] == 0xCD || mark[1] == 0x3D {
            let dataStart = start + 16
            guard let lField = SmartHomeDemod.bytes(bits, from: dataStart, count: 1)?.first else { return nil }
            if mark[1] == 0xCD {
                guard lField >= 9, let raw = SmartHomeDemod.bytes(bits, from: dataStart, count: formatALength(Int(lField))),
                      let stripped = stripFormatA(raw), stripped.crcOK else { return nil }
                return parse(stripped.data, mode: "C1 · Format A", keys: keys, formats: formats)
            } else {
                guard lField >= 12, let raw = SmartHomeDemod.bytes(bits, from: dataStart, count: Int(lField) + 1),
                      let stripped = stripFormatB(raw), stripped.crcOK else { return nil }
                return parse(stripped.data, mode: "C1 · Format B", keys: keys, formats: formats)
            }
        }
        // T1: 3-aus-6
        guard let lField = decode3of6(bits, from: start, count: 1)?.first, lField >= 9 else { return nil }
        guard let raw = decode3of6(bits, from: start, count: formatALength(Int(lField))),
              let stripped = stripFormatA(raw), stripped.crcOK else { return nil }
        return parse(stripped.data, mode: "T1", keys: keys, formats: formats)
    }

    // MARK: - Sicherungsschicht

    static func manufacturer(_ code: UInt16) -> String {
        let letters = [(code >> 10) & 0x1F, (code >> 5) & 0x1F, code & 0x1F]
        return String(letters.map { Character(UnicodeScalar(UInt8($0) + 0x40)) })
    }

    static let manufacturerNames: [String: String] = [
        "KAM": "Kamstrup", "ELS": "Elster", "SEN": "Sensus", "DME": "Diehl Metering", "ITW": "Itron",
        "QDS": "Qundis", "TCH": "Techem", "ZRI": "Zenner", "EFE": "Engelmann", "APA": "Apator",
        "LUG": "Landis+Gyr", "LSE": "Siemens", "IST": "ista", "HYD": "Diehl (Hydrometer)", "SON": "Sontex",
        "ESY": "EasyMeter", "EMH": "EMH Metering", "NZR": "NZR", "LAS": "Lansen", "WEP": "Weptech",
        "MAD": "Maddalena", "BMT": "BMETERS", "GWF": "GWF", "ABB": "ABB", "AMT": "Aquametro",
        "BRA": "Brunata", "SPX": "Sensus (Spanner-Pollux)", "EIE": "Electronic Instrumentation",
        "BMP": "Bmeters", "INE": "Ineo", "AMB": "Amber", "EMT": "Elster (EMT)", "SAP": "Sappel",
    ]

    static func deviceType(_ t: UInt8) -> String {
        switch t {
        case 0x00: String(localized: "Sonstiges")
        case 0x01: String(localized: "Öl")
        case 0x02: String(localized: "Strom")
        case 0x03: String(localized: "Gas")
        case 0x04, 0x0C: String(localized: "Wärme")
        case 0x05: String(localized: "Dampf")
        case 0x06, 0x15: String(localized: "Warmwasser")
        case 0x07: String(localized: "Wasser")
        case 0x08: String(localized: "Heizkostenverteiler")
        case 0x09: String(localized: "Druckluft")
        case 0x0A, 0x0B: String(localized: "Kälte")
        case 0x0D: String(localized: "Wärme/Kälte")
        case 0x0E: String(localized: "Buskomponente")
        case 0x16: String(localized: "Kaltwasser")
        case 0x17: String(localized: "Warm-/Kaltwasser")
        case 0x18: String(localized: "Druck")
        case 0x19: String(localized: "A/D-Wandler")
        case 0x1A: String(localized: "Rauchmelder")
        case 0x1B: String(localized: "Raumsensor")
        case 0x1C: String(localized: "Gasmelder")
        case 0x20: String(localized: "Schalter")
        case 0x21: String(localized: "Ventil")
        case 0x25: String(localized: "Anzeige")
        case 0x28: String(localized: "Abwasser")
        case 0x31: String(localized: "Kommunikationsgerät")
        case 0x32, 0x33: String(localized: "Funkverstärker")
        case 0x36, 0x37: String(localized: "Funkumsetzer")
        default: String(localized: "Art \(String(format: "0x%02X", t))")
        }
    }

    static func controlName(_ c: UInt8) -> String {
        switch c {
        case 0x44: String(localized: "SND_NR (Meldung)")
        case 0x46: String(localized: "SND_IR (Installation)")
        case 0x47: "ACC_NR"
        case 0x48: "ACC_DMD"
        case 0x08: String(localized: "RSP_UD (Antwort)")
        case 0x40: "SND_NKE"
        case 0x53, 0x73: String(localized: "SND_UD (Befehl)")
        case 0x00: "ACK"
        default: String(format: "C 0x%02X", c)
        }
    }

    /// Ident-Nummer aus den vier BCD-Bytes (niedrigstes zuerst).
    static func ident<C: Collection>(_ b: C) -> String where C.Element == UInt8 {
        b.reversed().map { String(format: "%02X", $0) }.joined()
    }

    /// `data`: Rahmen ohne CRCs, ab dem L-Feld.
    static func parse(_ data: [UInt8], mode: String, keys: [String: [UInt8]], formats: [UInt16: [UInt8]] = [:]) -> SmartHomeFrame? {
        guard data.count >= 10 else { return nil }
        let c = data[1]
        let mCode = UInt16(data[3]) << 8 | UInt16(data[2])
        let id = ident(data[4...7])
        let version = data[8], type = data[9]
        let m = manufacturer(mCode)
        // Techem meldet seine Heizkostenverteiler mit dem herstellereigenen Typ 0x80.
        let typeName = m == "TCH" && type == 0x80 ? String(localized: "Heizkostenverteiler") : deviceType(type)
        var frame = SmartHomeFrame(radio: .wmbus, mode: mode, address: "\(m) \(id)",
                                   deviceType: "\(manufacturerNames[m] ?? m) · \(typeName)",
                                   kind: controlName(c), summary: "", checksumOK: true, bytes: data)
        frame.fields = [
            .init(name: String(localized: "Steuerfeld"), value: controlName(c)),
            .init(name: String(localized: "Hersteller"), value: "\(m)" + (manufacturerNames[m].map { " (\($0))" } ?? "")),
            .init(name: String(localized: "Ident-Nummer"), value: id),
            .init(name: String(localized: "Version"), value: "\(version)"),
            .init(name: String(localized: "Gerätetyp"), value: String(format: "0x%02X %@", type, typeName)),
        ]
        guard data.count > 10 else {
            frame.summary = String(localized: "ohne Anwendungsdaten")
            return frame
        }
        var app = ApplicationContext(manufacturer: Array(data[2...3]), address: Array(data[4...9]), id: id, formats: formats)
        application(Array(data[10...]), context: &app, keys: keys, frame: &frame, depth: 0)
        return frame
    }

    struct ApplicationContext {
        var manufacturer: [UInt8]
        /// A-Feld: Ident (4), Version, Gerätetyp.
        var address: [UInt8]
        var id: String
        /// Aus der Authentifizierungsschicht (CI 0x90): Nachrichtenzähler
        /// (4 Byte, niedrigstes zuerst), MCL und MAC – für Sicherheitsmodus 7.
        var aflCounter: [UInt8]?
        var aflControl: UInt8 = 0
        var aflMAC: [UInt8] = []
        /// Gelernte Datensatzköpfe (Formatsignatur → DIF/VIF-Folge).
        var formats: [UInt16: [UInt8]] = [:]
    }

    static func ciName(_ ci: UInt8) -> String {
        switch ci {
        case 0x72: String(localized: "Anwendungsdaten, langer Kopf")
        case 0x7A: String(localized: "Anwendungsdaten, kurzer Kopf")
        case 0x78: String(localized: "Anwendungsdaten ohne Kopf")
        case 0x79: String(localized: "Kompaktrahmen")
        case 0x8C...0x8F: String(localized: "Erweiterte Sicherungsschicht")
        case 0x90: String(localized: "Authentifizierungsschicht (AFL)")
        case 0x70: String(localized: "Anwendungsfehler")
        case 0x71: String(localized: "Alarm")
        case 0xA0...0xB7: String(localized: "herstellerspezifisch")
        default: String(format: "CI 0x%02X", ci)
        }
    }

    private static func application(_ a: [UInt8], context: inout ApplicationContext, keys: [String: [UInt8]],
                                    frame: inout SmartHomeFrame, depth: Int) {
        guard let ci = a.first, depth < 3 else { return }
        frame.fields.append(.init(name: "CI", value: String(format: "0x%02X %@", ci, ciName(ci))))
        switch ci {
        case 0x8C where a.count >= 3:
            // ELL kurz: CC, ACC, dann der nächste CI
            application(Array(a[3...]), context: &context, keys: keys, frame: &frame, depth: depth + 1)
        case 0x8D where a.count >= 9:
            // ELL mit Sitzungsnummer: verschlüsselt mit AES-CTR, wenn SN ≠ 0
            let cc = a[1], acc = a[2], sn = Array(a[3...6])
            let encryptionBits = (UInt32(sn[3]) >> 5) & 0x07
            let rest = Array(a[7...])
            if encryptionBits == 0 {
                guard rest.count > 2 else { return }
                application(Array(rest[2...]), context: &context, keys: keys, frame: &frame, depth: depth + 1)
                return
            }
            guard let key = keys[context.id] else {
                frame.encrypted = true
                frame.summary = String(localized: "verschlüsselt (ELL, AES-CTR) – Schlüssel fehlt")
                return
            }
            let iv = context.manufacturer + context.address + [cc] + sn + [0, 0, 0]
            let plain = aesCTR(key: key, iv: iv, rest)
            guard plain.count > 2, crc16(plain[2...]) == UInt16(plain[1]) << 8 | UInt16(plain[0])
                    || crc16(plain[2...]) == UInt16(plain[0]) << 8 | UInt16(plain[1]) else {
                frame.encrypted = true
                frame.summary = String(localized: "verschlüsselt (ELL) – Schlüssel passt nicht")
                return
            }
            frame.fields.append(.init(name: String(localized: "Entschlüsselt"), value: String(localized: "ja (ELL, AES-CTR, ACC \(Int(acc)))")))
            application(Array(plain[2...]), context: &context, keys: keys, frame: &frame, depth: depth + 1)
        case 0x90 where a.count >= 4:
            // AFL (EN 13757-7): AFLL, FCL (2), dann je nach FCL-Bits MCL, KI (2),
            // Zähler (4), MAC (Länge aus dem Authentifizierungstyp in MCL), ML (2).
            let length = Int(a[1])
            guard a.count >= 2 + length else { return }
            let fcl = UInt16(a[3]) << 8 | UInt16(a[2])
            var i = 4
            if fcl & 0x2000 != 0, i < a.count { context.aflControl = a[i]; i += 1 }
            if fcl & 0x0200 != 0 { i += 2 }
            if fcl & 0x0800 != 0, i + 4 <= a.count {
                context.aflCounter = Array(a[i..<i + 4])
                let counter = UInt32(a[i]) | UInt32(a[i + 1]) << 8 | UInt32(a[i + 2]) << 16 | UInt32(a[i + 3]) << 24
                frame.fields.append(.init(name: String(localized: "Nachrichtenzähler"), value: "\(counter)"))
                i += 4
            }
            if fcl & 0x0400 != 0 {
                // Authentifizierungstyp: 3–7 = AES-CMAC auf 2/4/8/12/16 Byte gekürzt, 8 = GMAC 12.
                let macLength: Int = switch context.aflControl & 0x0F {
                case 3: 2
                case 4: 4
                case 5: 8
                case 6, 8: 12
                case 7: 16
                default: 0
                }
                guard i + macLength <= a.count else { return }
                context.aflMAC = Array(a[i..<i + macLength])
                frame.fields.append(.init(name: "MAC", value: SmartHomeHex.string(context.aflMAC)))
                i += macLength
            }
            application(Array(a[(2 + length)...]), context: &context, keys: keys, frame: &frame, depth: depth + 1)
        case 0x72, 0x7A:
            var index = 1
            if ci == 0x72 {
                guard a.count >= 13 else { return }
                context.id = ident(a[1...4])
                context.manufacturer = Array(a[5...6])
                context.address = Array(a[1...4]) + [a[7], a[8]]
                let m = manufacturer(UInt16(a[6]) << 8 | UInt16(a[5]))
                frame.fields.append(.init(name: String(localized: "Zähler"), value: "\(m) \(context.id), \(deviceType(a[8]))"))
                if frame.address != "\(m) \(context.id)" {
                    frame.address = "\(m) \(context.id)"
                    frame.deviceType = "\(manufacturerNames[m] ?? m) · \(deviceType(a[8]))"
                }
                index = 9
            }
            guard a.count >= index + 4 else { return }
            let acc = a[index], status = a[index + 1]
            let config = UInt16(a[index + 3]) << 8 | UInt16(a[index + 2])
            index += 4
            let securityMode = Int(config >> 8) & 0x1F
            frame.fields.append(.init(name: String(localized: "Zugriffsnummer"), value: "\(acc)"))
            if status != 0 { frame.fields.append(.init(name: String(localized: "Status"), value: statusText(status))) }
            frame.fields.append(.init(name: String(localized: "Sicherheitsmodus"),
                                      value: securityMode == 0 ? String(localized: "unverschlüsselt") : String(localized: "Modus \(securityMode)")))
            var payload = Array(a[index...])
            switch securityMode {
            case 0:
                break
            case 5:
                let blocks = Int(config >> 4) & 0x0F
                let length = min(blocks * 16, payload.count - payload.count % 16)
                guard let key = keys[context.id] else {
                    frame.encrypted = true
                    frame.summary = String(localized: "verschlüsselt (Modus 5) – Schlüssel fehlt")
                    return
                }
                let iv = context.manufacturer + context.address + [UInt8](repeating: acc, count: 8)
                let plain = aesCBCDecrypt(key: key, iv: iv, Array(payload[0..<length]))
                guard plain.count >= 2, plain[0] == 0x2F, plain[1] == 0x2F else {
                    frame.encrypted = true
                    frame.summary = String(localized: "verschlüsselt (Modus 5) – Schlüssel passt nicht")
                    return
                }
                payload = plain + payload[length...]
                frame.fields.append(.init(name: String(localized: "Entschlüsselt"), value: String(localized: "ja (AES-128-CBC)")))
            case 7:
                // Modus 7 (OMS-Sicherheitsprofil B): nach dem Konfigurationswort ein
                // Erweiterungsbyte (Bits 4–5 = Schlüsselableitung), dann AES-128-CBC
                // ohne IV mit einem je Nachricht abgeleiteten Schlüssel:
                // Kenc = CMAC(K, 00 · Zähler · Ident · 7 × 07), Kmac mit 01 statt 00.
                // Zähler und MAC stammen aus der AFL (CI 0x90) davor; der MAC läuft
                // über MCL · Zähler · TPL (ab CI 0x7A/0x72 bis zum Ende).
                guard a.count > index else { return }
                let kdf = (a[index] >> 4) & 0x03
                index += 1
                payload = Array(a[index...])
                let blocks = Int(config >> 4) & 0x0F
                let length = min(blocks * 16, payload.count - payload.count % 16)
                guard let key = keys[context.id] else {
                    frame.encrypted = true
                    frame.summary = String(localized: "verschlüsselt (Modus 7) – Schlüssel fehlt")
                    return
                }
                guard let counter = context.aflCounter, kdf == 1 || kdf == 0 else {
                    frame.encrypted = true
                    frame.summary = String(localized: "verschlüsselt (Modus 7) – ohne Nachrichtenzähler")
                    return
                }
                let base = counter + Array(context.address.prefix(4)) + [UInt8](repeating: 0x07, count: 7)
                let encryptionKey = kdf == 1 ? LoRaWANCrypto.cmac(key: key, [0x00] + base) : key
                let plain = aesCBCDecrypt(key: encryptionKey, iv: [UInt8](repeating: 0, count: 16), Array(payload[0..<length]))
                guard plain.count >= 2, plain[0] == 0x2F, plain[1] == 0x2F else {
                    frame.encrypted = true
                    frame.summary = String(localized: "verschlüsselt (Modus 7) – Schlüssel passt nicht")
                    return
                }
                var macText = ""
                if !context.aflMAC.isEmpty {
                    let macKey = kdf == 1 ? LoRaWANCrypto.cmac(key: key, [0x01] + base) : key
                    let mac = LoRaWANCrypto.cmac(key: macKey, [context.aflControl] + counter + a)
                    macText = Array(mac.prefix(context.aflMAC.count)) == context.aflMAC
                        ? String(localized: ", MAC geprüft") : String(localized: ", MAC falsch")
                }
                payload = plain + payload[length...]
                frame.fields.append(.init(name: String(localized: "Entschlüsselt"), value: String(localized: "ja (Modus 7, AES-128-CBC\(macText))")))
            default:
                frame.encrypted = true
                frame.summary = String(localized: "verschlüsselt (Modus \(securityMode), nicht unterstützt)")
                return
            }
            learningRecords(payload, into: &frame)
        case 0x78:
            learningRecords(Array(a[1...]), into: &frame)
        case 0x79:
            compact(Array(a[1...]), formats: context.formats, into: &frame)
        case 0x70, 0x71:
            // Anwendungsfehler bzw. Alarm (EN 13757-3): Kennbyte des Geräts, Rest herstellerabhängig.
            let code = a.count >= 2 ? Int(a[1]) : nil
            let name = ci == 0x70 ? String(localized: "Anwendungsfehler") : String(localized: "Alarm")
            frame.summary = code.map { String(format: "%@ 0x%02X", name, $0) } ?? name
            if let code { frame.values.append(SmartHomeValue(name: ci == 0x70 ? "Fehlercode" : "Alarm", unit: "", value: Double(code))) }
        case 0xA0, 0xA2:
            if context.manufacturer == [0x68, 0x50], context.address.last == 0x80,
               techemHeatCostAllocator(Array(a[1...]), into: &frame) { return }
            frame.summary = ciName(ci) + " – " + SmartHomeHex.string(Array(a.dropFirst().prefix(16)))
        default:
            frame.summary = ciName(ci) + " – " + SmartHomeHex.string(Array(a.dropFirst().prefix(16)))
        }
    }

    /// Techem-Heizkostenverteiler (FHKV data II/III, Typ 0x80, Version 0x69/0x94):
    /// unverschlüsselt, aber herstellerspezifisch hinter CI 0xA0/0xA2. Aufbau wie
    /// wmbusmeters `fhkvdataiii`: Kennbyte 0x01/0x11/0x0F, Datum und Einheiten
    /// der Vorperiode, Datum und Einheiten der laufenden Periode (bei 0x0F ein
    /// Byte dazwischen), Raum- und Heizkörpertemperatur in 1/100 °C.
    /// Gibt `false` zurück, wenn der Inhalt nicht zu diesem Aufbau passt.
    static func techemHeatCostAllocator(_ p: [UInt8], into frame: inout SmartHomeFrame) -> Bool {
        guard let marker = p.first, [0x01, 0x11, 0x0F].contains(marker) else { return false }
        let gap = marker == 0x0F ? 1 : 0
        guard p.count >= 13 + gap else { return false }
        func word(_ i: Int) -> Int { Int(p[i + 1]) << 8 | Int(p[i]) }
        let previousUnits = word(3), currentUnits = word(7)
        let room = Double(word(9 + gap)) / 100, radiator = Double(word(11 + gap)) / 100
        guard room > -40, room < 100, radiator > -40, radiator < 150 else { return false }
        // Ende der Vorperiode: Tag (5 Bit), Monat (4 Bit), Jahr ab 2000 (7 Bit).
        let previousRaw = word(1)
        let previousDay = previousRaw & 0x1F, previousMonth = (previousRaw >> 5) & 0x0F, previousYear = 2000 + (previousRaw >> 9)
        // Stand der laufenden Periode ohne Jahr: Tag ab Bit 4, Monat ab Bit 9; das
        // Jahr folgt aus der Vorperiode – eins weiter, sobald Monat/Tag nicht nach
        // deren Ende liegen.
        let currentRaw = word(5)
        var currentDay = (currentRaw >> 4) & 0x1F, currentMonth = (currentRaw >> 9) & 0x0F
        if currentDay == 0 { currentDay = 1 }
        if currentMonth == 0 { currentMonth = 12 }
        let currentYear = previousYear + ((currentMonth, currentDay) <= (previousMonth, previousDay) ? 1 : 0)
        func date(_ year: Int, _ month: Int, _ day: Int) -> String {
            guard (1...12).contains(month), (1...31).contains(day),
                  let d = DateComponents(calendar: .current, year: year, month: month, day: day).date else {
                return String(format: "%02d.%02d.%04d", day, month, year)
            }
            return d.formatted(.dateTime.day().month().year())
        }
        let units = SmartHomeValue(name: "Heizkosten-Einheiten", unit: "", value: Double(currentUnits))
        let roomValue = SmartHomeValue(name: "Raumtemperatur", unit: "°C", value: room)
        let radiatorValue = SmartHomeValue(name: "Heizkörpertemperatur", unit: "°C", value: radiator)
        frame.fields.append(.init(name: String(localized: "Verbrauch laufende Periode"), value: units.formatted))
        frame.fields.append(.init(name: String(localized: "Stand vom"), value: date(currentYear, currentMonth, currentDay)))
        frame.fields.append(.init(name: String(localized: "Verbrauch Vorperiode"), value: "\(previousUnits)"))
        frame.fields.append(.init(name: String(localized: "Vorperiode bis"), value: date(previousYear, previousMonth, previousDay)))
        frame.fields.append(.init(name: roomValue.label, value: roomValue.formatted))
        frame.fields.append(.init(name: radiatorValue.label, value: radiatorValue.formatted))
        frame.values = [units, roomValue, radiatorValue]
        frame.summary = String(localized: "\(units.formatted) Einheiten seit \(date(previousYear, previousMonth, previousDay)), Raum \(roomValue.formatted), Heizkörper \(radiatorValue.formatted)")
        return true
    }

    static func statusText(_ s: UInt8) -> String {
        var parts: [String] = []
        switch s & 0x03 {
        case 1: parts.append(String(localized: "beschäftigt"))
        case 2: parts.append(String(localized: "Anwendungsfehler"))
        case 3: parts.append(String(localized: "Alarm"))
        default: break
        }
        if s & 0x04 != 0 { parts.append(String(localized: "Batterie schwach")) }
        if s & 0x08 != 0 { parts.append(String(localized: "Dauerfehler")) }
        if s & 0x10 != 0 { parts.append(String(localized: "vorübergehender Fehler")) }
        return String(format: "0x%02X", s) + (parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")")
    }

    // MARK: - Krypto

    static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        guard key.count == 16, iv.count == 16, !data.isEmpty, data.count % 16 == 0 else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        return status == kCCSuccess ? Array(out[0..<moved]) : []
    }

    static func aesCBCEncrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        guard key.count == 16, iv.count == 16, data.count % 16 == 0 else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        return status == kCCSuccess ? Array(out[0..<moved]) : []
    }

    /// AES-CTR (ELL): Zähler im letzten Byte des IV.
    static func aesCTR(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        guard key.count == 16, iv.count == 16 else { return [] }
        var counter = iv
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for start in stride(from: 0, to: data.count, by: 16) {
            let stream = CCMStar.aes(key, counter)
            for k in start..<min(start + 16, data.count) { out.append(data[k] ^ stream[k - start]) }
            counter[15] &+= 1
        }
        return out
    }

    // MARK: - Datensätze (DIF/VIF)

    struct Record: Sendable, Equatable {
        var name: String
        var unit: String
        var value: Double?
        var text: String?
        var storage: Int
        var tariff: Int
        var function: Int
    }

    /// Datensätze auswerten und den Satzkopf merken (für spätere Kompaktrahmen).
    private static func learningRecords(_ payload: [UInt8], into frame: inout SmartHomeFrame) {
        records(payload, into: &frame)
        frame.wmbusFormat = formatHeaders(payload)
    }

    /// Kompaktrahmen (EN 13757-3, CI 0x79): Formatsignatur (2), Prüfsumme über
    /// die vollen Daten (2), dann nur die Werte. Die Köpfe (DIF/VIF) stammen aus
    /// einem früheren vollständigen Rahmen mit derselben Signatur (CRC-16 über
    /// die Kopfbytes, wie wmbusmeters) – ohne ihn bleibt der Rahmen ungedeutet.
    static func compact(_ p: [UInt8], formats: [UInt16: [UInt8]], into frame: inout SmartHomeFrame) {
        guard p.count >= 4 else { frame.summary = ciName(0x79); return }
        let little = UInt16(p[1]) << 8 | UInt16(p[0]), big = UInt16(p[0]) << 8 | UInt16(p[1])
        frame.fields.append(.init(name: String(localized: "Formatsignatur"), value: String(format: "0x%04X", little)))
        guard let headers = formats[little] ?? formats[big], let full = expand(headers: headers, data: Array(p[4...])) else {
            frame.summary = String(localized: "Kompaktrahmen – Aufbau noch unbekannt (kommt mit dem nächsten vollständigen Rahmen)")
            return
        }
        records(full, into: &frame)
    }

    /// Kopfbytes (DIF/DIFE/VIF/VIFE) aller Datensätze ohne die Werte; `nil`, wenn
    /// der Aufbau nicht fest ist (Text variabler Länge, Herstellerdaten).
    static func formatHeaders(_ p: [UInt8]) -> [UInt8]? {
        var headers: [UInt8] = []
        var i = 0
        while i < p.count {
            guard let (header, length) = recordHeader(p, at: i) else { return nil }
            if header == [0x2F] { i += 1; continue }
            headers += header
            i += header.count + length
            guard i <= p.count else { return nil }
        }
        return headers.isEmpty ? nil : headers
    }

    /// Volle Datensätze aus gelernten Köpfen und den Werten eines Kompaktrahmens.
    static func expand(headers: [UInt8], data: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var h = 0, d = 0
        while h < headers.count {
            guard let (header, length) = recordHeader(headers, at: h), d + length <= data.count else { return nil }
            out += header + data[d..<(d + length)]
            h += header.count
            d += length
        }
        return out
    }

    /// Kopf eines Datensatzes ab `i` und die Länge seines Werts (fest, sonst `nil`).
    private static func recordHeader(_ p: [UInt8], at start: Int) -> (header: [UInt8], length: Int)? {
        var i = start
        guard i < p.count else { return nil }
        let dif = p[i]
        if dif == 0x2F { return ([0x2F], 0) }
        guard dif != 0x0F, dif != 0x1F else { return nil }
        i += 1
        var ext = dif & 0x80 != 0
        while ext, i < p.count { ext = p[i] & 0x80 != 0; i += 1 }
        guard i < p.count else { return nil }
        let vif = p[i]
        i += 1
        if vif & 0x7F == 0x7C {
            guard i < p.count else { return nil }
            i += 1 + Int(p[i])
        }
        var vifExt = vif & 0x80 != 0
        while vifExt, i < p.count { vifExt = p[i] & 0x80 != 0; i += 1 }
        let lengths = [0, 1, 2, 3, 4, 4, 6, 8, 0, 1, 2, 3, 4, -1, 6, 0]
        let length = lengths[Int(dif & 0x0F)]
        guard length >= 0, i <= p.count else { return nil }
        return (Array(p[start..<i]), length)
    }

    static func records(_ payload: [UInt8], into frame: inout SmartHomeFrame) {
        let list = parseRecords(payload)
        for record in list {
            // `key` bleibt deutsch (Schlüssel für MQTT), `label` wird angezeigt.
            var key = record.name
            var label = SmartHomeNames.label(record.name)
            if record.function == 1 { key += " (max.)"; label = String(localized: "\(label) (max.)") }
            if record.function == 2 { key += " (min.)"; label = String(localized: "\(label) (min.)") }
            if record.function == 3 { key += " (Fehlerwert)"; label = String(localized: "\(label) (Fehlerwert)") }
            if record.tariff > 0 { key += " (Tarif \(record.tariff))"; label = String(localized: "\(label) (Tarif \(record.tariff))") }
            if record.storage > 0 { key += " (Speicher \(record.storage))"; label = String(localized: "\(label) (Speicher \(record.storage))") }
            if let value = record.value {
                let v = SmartHomeValue(name: key, unit: record.unit, value: value, label: label)
                frame.fields.append(.init(name: label, value: v.formatted))
                if record.storage == 0 && record.function == 0 && !frame.values.contains(where: { $0.name == key }) {
                    frame.values.append(v)
                }
            } else if let text = record.text {
                frame.fields.append(.init(name: label, value: text))
            }
        }
        if frame.summary.isEmpty {
            frame.summary = frame.values.prefix(3).map { "\($0.label) \($0.formatted)" }.joined(separator: ", ")
            if frame.summary.isEmpty {
                frame.summary = list.isEmpty ? String(localized: "ohne Datensätze") : String(localized: "\(list.count) Datensätze")
            }
        }
    }

    static func parseRecords(_ p: [UInt8]) -> [Record] {
        var out: [Record] = []
        var i = 0
        while i < p.count, out.count < 64 {
            let dif = p[i]
            i += 1
            if dif == 0x2F { continue }                     // Füllbyte
            if dif == 0x0F || dif == 0x1F {                  // Herstellerdaten bis zum Ende
                if i < p.count {
                    out.append(Record(name: "Herstellerdaten", unit: "", value: nil,
                                      text: SmartHomeHex.string(Array(p[i...].prefix(32))), storage: 0, tariff: 0, function: 0))
                }
                break
            }
            var storage = Int(dif >> 6) & 1
            var tariff = 0
            let function = Int(dif >> 4) & 0x03
            var ext = dif & 0x80 != 0
            var shift = 1
            var tariffShift = 0
            while ext, i < p.count {
                let dife = p[i]
                i += 1
                storage |= Int(dife & 0x0F) << shift
                tariff |= Int((dife >> 4) & 0x03) << tariffShift
                shift += 4
                tariffShift += 2
                ext = dife & 0x80 != 0
            }
            guard i < p.count else { break }
            var vifs: [UInt8] = [p[i]]
            i += 1
            var plainUnit: String?
            if vifs[0] & 0x7F == 0x7C, i < p.count {
                // Klartext-Einheit: Länge + Zeichen (rückwärts)
                let n = Int(p[i])
                i += 1
                guard i + n <= p.count else { break }
                plainUnit = String(bytes: p[i..<(i + n)].reversed(), encoding: .ascii)
                i += n
            }
            while let last = vifs.last, last & 0x80 != 0, i < p.count {
                vifs.append(p[i])
                i += 1
            }
            // Datenfeld
            let coding = Int(dif & 0x0F)
            var length: Int
            switch coding {
            case 0, 8: length = 0
            case 1, 9: length = 1
            case 2, 10: length = 2
            case 3, 11: length = 3
            case 4, 5, 12: length = 4
            case 6, 14: length = 6
            case 7: length = 8
            case 13:
                guard i < p.count else { return out }
                // LVAR bis 0xBF: Text dieser Länge; BCD-/Binärvarianten nicht unterstützt
                guard p[i] <= 0xBF else { return out }
                length = Int(p[i])
                i += 1
            default: length = 0
            }
            guard i + length <= p.count else { break }
            let raw = Array(p[i..<(i + length)])
            i += length
            let meaning = vifMeaning(vifs)
            var name = meaning.0, unit = meaning.1
            let exponent = meaning.2, kind = meaning.3
            if let plainUnit { name = "Wert"; unit = plainUnit }
            var record = Record(name: name, unit: unit, value: nil, text: nil, storage: storage, tariff: tariff, function: function)
            switch kind {
            case .dateG where raw.count == 2:
                record.text = dateText(raw)
            case .dateTimeF where raw.count == 4:
                record.text = dateText(raw)
            default:
                if let value = number(raw, coding: coding) {
                    record.value = value * pow(10, Double(exponent))
                    // Gerundet auf die Auflösung (keine 0,30000000000000004).
                    if exponent < 0 { record.value = (record.value! * pow(10, Double(-exponent))).rounded() / pow(10, Double(-exponent)) }
                } else if coding == 13 {
                    record.text = String(bytes: raw.reversed().filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii)
                }
            }
            if record.value != nil || record.text != nil { out.append(record) }
        }
        return out
    }

    enum VIFKind { case number, dateG, dateTimeF }

    /// Name, Einheit, Zehnerpotenz.
    static func vifMeaning(_ vifs: [UInt8]) -> (String, String, Int, VIFKind) {
        let v = vifs[0] & 0x7F
        if vifs[0] == 0xFD, vifs.count > 1 {
            let e = vifs[1] & 0x7F
            switch e {
            case 0x40...0x4F: return ("Spannung", "V", Int(e & 0x0F) - 9, .number)
            case 0x50...0x5F: return ("Strom", "A", Int(e & 0x0F) - 12, .number)
            case 0x17: return ("Fehlerflags", "", 0, .number)
            case 0x0E: return ("Firmware-Version", "", 0, .number)
            case 0x0F: return ("Software-Version", "", 0, .number)
            case 0x3A: return ("Zählwert", "", 0, .number)
            case 0x74: return ("Batterierestlaufzeit", "Tage", 0, .number)
            case 0x0B: return ("Parametersatz", "", 0, .number)
            case 0x0C: return ("Modell", "", 0, .number)
            case 0x1A: return ("Digitaleingänge", "", 0, .number)
            default: return (String(format: "Wert (FD %02X)", e), "", 0, .number)
            }
        }
        if vifs[0] == 0xFB, vifs.count > 1 {
            let e = vifs[1] & 0x7F
            switch e {
            case 0x00...0x01: return ("Energie", "kWh", Int(e & 0x01) - 1 + 3, .number)   // MWh·10^(n−1) → kWh
            case 0x1A...0x1B: return ("Luftfeuchte", "%", Int(e & 0x01) - 1, .number)
            case 0x58...0x5B: return ("Vorlauftemperatur", "°F", Int(e & 0x03) - 3, .number)
            default: return (String(format: "Wert (FB %02X)", e), "", 0, .number)
            }
        }
        let n = Int(v & 0x07)
        switch v {
        case 0x00...0x07: return ("Energie", "kWh", n - 3 - 3, .number)
        case 0x08...0x0F: return ("Energie", "kJ", n - 3, .number)
        case 0x10...0x17: return ("Volumen", "m³", n - 6, .number)
        case 0x18...0x1F: return ("Masse", "kg", n - 3, .number)
        case 0x20...0x23: return ("Einschaltdauer", ["s", "min", "h", "Tage"][Int(v & 3)], 0, .number)
        case 0x24...0x27: return ("Betriebsdauer", ["s", "min", "h", "Tage"][Int(v & 3)], 0, .number)
        case 0x28...0x2F: return ("Leistung", "W", n - 3, .number)
        case 0x30...0x37: return ("Leistung", "kJ/h", n - 3, .number)
        case 0x38...0x3F: return ("Durchfluss", "m³/h", n - 6, .number)
        case 0x40...0x47: return ("Durchfluss", "m³/min", n - 7, .number)
        case 0x48...0x4F: return ("Durchfluss", "m³/s", n - 9, .number)
        case 0x50...0x57: return ("Massenstrom", "kg/h", n - 3, .number)
        case 0x58...0x5B: return ("Vorlauftemperatur", "°C", Int(v & 3) - 3, .number)
        case 0x5C...0x5F: return ("Rücklauftemperatur", "°C", Int(v & 3) - 3, .number)
        case 0x60...0x63: return ("Temperaturdifferenz", "K", Int(v & 3) - 3, .number)
        case 0x64...0x67: return ("Außentemperatur", "°C", Int(v & 3) - 3, .number)
        case 0x68...0x6B: return ("Druck", "bar", Int(v & 3) - 3, .number)
        case 0x6C: return ("Datum", "", 0, .dateG)
        case 0x6D: return ("Zeitpunkt", "", 0, .dateTimeF)
        case 0x6E: return ("Heizkosten-Einheiten", "", 0, .number)
        case 0x70...0x73: return ("Mittelungsdauer", ["s", "min", "h", "Tage"][Int(v & 3)], 0, .number)
        case 0x74...0x77: return ("Aktualitätsdauer", ["s", "min", "h", "Tage"][Int(v & 3)], 0, .number)
        case 0x78: return ("Fabrikationsnummer", "", 0, .number)
        case 0x79: return ("Erweiterte Kennung", "", 0, .number)
        case 0x7A: return ("Busadresse", "", 0, .number)
        case 0x7F: return ("Herstellerwert", "", 0, .number)
        default: return (String(format: "Wert (VIF %02X)", v), "", 0, .number)
        }
    }

    /// Zahl nach DIF-Kodierung (Ganzzahl LE mit Vorzeichen, BCD, Gleitkomma).
    static func number(_ raw: [UInt8], coding: Int) -> Double? {
        switch coding {
        case 1, 2, 3, 4, 6, 7:
            guard !raw.isEmpty else { return nil }
            var value: Int64 = 0
            for (k, byte) in raw.enumerated() { value |= Int64(byte) << (8 * k) }
            let bits = Int64(raw.count * 8)
            if bits < 64, value & (1 << (bits - 1)) != 0 { value -= 1 << bits }
            return Double(value)
        case 5:
            guard raw.count == 4 else { return nil }
            let bits = UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
            let f = Double(Float(bitPattern: bits))
            return f.isFinite ? f : nil
        case 9, 10, 11, 12, 14:
            var value: Double = 0
            var negative = false
            for (k, byte) in raw.enumerated().reversed() {
                var high = Int(byte >> 4)
                let low = Int(byte & 0x0F)
                if k == raw.count - 1, high == 0x0F { negative = true; high = 0 }
                guard high <= 9, low <= 9 else { return nil }
                value = value * 100 + Double(high * 10 + low)
            }
            return negative ? -value : value
        default:
            return nil
        }
    }

    /// Datum (Typ G, 2 Byte) bzw. Datum + Uhrzeit (Typ F, 4 Byte).
    static func dateText(_ b: [UInt8]) -> String {
        if b.count == 2 {
            let day = Int(b[0] & 0x1F), month = Int(b[1] & 0x0F)
            let year = Int((b[0] & 0xE0) >> 5) | Int((b[1] & 0xF0) >> 1)
            return String(format: "%02d.%02d.%04d", day, month, 2000 + year)
        }
        let minute = Int(b[0] & 0x3F), hour = Int(b[1] & 0x1F)
        let day = Int(b[2] & 0x1F), month = Int(b[3] & 0x0F)
        let year = Int((b[2] & 0xE0) >> 5) | Int((b[3] & 0xF0) >> 1)
        return String(format: "%02d.%02d.%04d %02d:%02d", day, month, 2000 + year, hour, minute)
    }
}

/// wM-Bus-Schlüssel je Zähler (Ident-Nummer), im Anmelde-Schlüsselbund.
struct WMBusKey: Codable, Sendable, Equatable, Identifiable {
    var meterID: String
    var key: [UInt8]
    var label: String

    var id: String { meterID }
}

enum WMBusKeyStore {
    private static let service = "de.christiangolz.portapackmanager.wmbus"
    private static let account = "meterKeys"

    static func load() -> [WMBusKey] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let list = try? JSONDecoder().decode([WMBusKey].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    static func save(_ keys: [WMBusKey]) -> OSStatus {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard !keys.isEmpty else { SecItemDelete(base as CFDictionary); return errSecSuccess }
        guard let data = try? JSONEncoder().encode(keys) else { return errSecParam }
        return KeychainBlob.save(data, query: base)
    }

    /// Ident-Nummer: 8 Ziffern (führende Nullen ergänzt).
    static func parseMeterID(_ text: String) -> String? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 8 else { return nil }
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    static func parseKey(_ text: String) -> [UInt8]? {
        guard let bytes = SmartHomeHex.parse(text), bytes.count == 16 else { return nil }
        return bytes
    }
}
