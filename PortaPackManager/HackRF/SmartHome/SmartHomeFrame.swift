import Foundation

/// Funkarten der Smart-Home-Seite.
enum SmartHomeRadio: String, CaseIterable, Identifiable, Codable, Sendable {
    case zwave = "Z-Wave"
    case homematic = "Homematic"
    case enocean = "EnOcean"
    case wmbus = "Wireless M-Bus"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .zwave: "point.3.connected.trianglepath.dotted"
        case .homematic: "house"
        case .enocean: "bolt.badge.automatic"
        case .wmbus: "gauge.with.dots.needle.33percent"
        }
    }

    /// Kanäle, die diese Funkart braucht.
    var channels: Set<SmartHomeChannel> {
        switch self {
        case .zwave: [.zwave, .zwaveR3]
        case .homematic, .enocean: [.srd868_3]
        case .wmbus: [.wmbus]
        }
    }

    var frequencies: String {
        switch self {
        case .zwave: String(localized: "868,42 MHz (R1/R2), 869,85 MHz (R3)")
        case .homematic, .enocean: String(localized: "868,30 MHz")
        case .wmbus: String(localized: "868,95 MHz (T1, C1)")
        }
    }
}

/// Ein Messwert (Name, Einheit, Zahl) – für Tabelle, Verlauf und eine
/// spätere Weitergabe (MQTT).
struct SmartHomeValue: Sendable, Equatable, Hashable, Codable {
    /// Fester deutscher Name – Schlüssel für Home Assistant (Entity-ID und
    /// Geräteklasse in `MQTTFeeds`) und für das Zusammenführen je Gerät.
    /// Wird bewusst **nicht** übersetzt; angezeigt wird `label`.
    var name: String
    var unit: String
    var value: Double
    /// Angezeigter, übersetzter Name.
    var label: String

    init(name: String, unit: String, value: Double, label: String? = nil) {
        self.name = name
        self.unit = unit
        self.value = value
        self.label = label ?? SmartHomeNames.label(name)
    }

    var formatted: String {
        let digits: Int
        let magnitude = abs(value)
        if value == value.rounded() && magnitude < 1e7 { digits = 0 }
        else if magnitude >= 1000 { digits = 1 }
        else if magnitude >= 10 { digits = 2 }
        else { digits = 3 }
        let number = value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "de_DE")))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

/// Ein dekodierter Rahmen, unabhängig von der Funkart.
struct SmartHomeFrame: Sendable, Equatable {
    struct Field: Sendable, Equatable, Hashable {
        var name: String
        var value: String
    }

    var radio: SmartHomeRadio
    /// Übertragungsart („R2 · 40 kbit/s“, „T1“, „C1 Format A“ …).
    var mode: String
    /// Kennung des Absenders, eindeutig je Funkart (Z-Wave: Home-ID + Knoten).
    var address: String
    var destination: String?
    /// Hersteller/Geräteart, soweit aus dem Rahmen ablesbar.
    var deviceType: String = ""
    /// Rahmentyp in Kurzform („Bericht“, „Bestätigung“, „SND_NR“ …).
    var kind: String
    /// Inhalt im Klartext.
    var summary: String
    var fields: [Field] = []
    var values: [SmartHomeValue] = []
    var checksumOK: Bool
    var encrypted = false
    /// Gerätetyp stammt aus einer Geräteinfo bzw. einem Anlerntelegramm – hat Vorrang.
    var deviceTypeFromInfo = false
    /// Gerätetyp ist nur angenommen (EnOcean-Vorgabeprofil) – wird überschrieben.
    var deviceTypeGuessed = false
    /// Rohbytes (ohne Präambel/Sync, Prüfsummen entfernt bei wM-Bus).
    var bytes: [UInt8]

    var deviceKey: String { "\(radio.rawValue)|\(address)" }
}

/// Ein empfangener Rahmen samt Empfangsdaten.
struct SmartHomeReception: Identifiable, Sendable, Equatable {
    let id: Int
    let date: Date
    let frequencyMHz: Double
    let rssiDB: Double
    let snrDB: Double
    var frame: SmartHomeFrame
}

/// Ein Gerät, zusammengefasst über seine Rahmen.
struct SmartHomeDevice: Identifiable, Sendable, Equatable {
    var id: String
    var radio: SmartHomeRadio
    var address: String
    var deviceType: String
    var lastSummary: String
    /// Letzter Stand je Messgröße (Name → Wert).
    var values: [SmartHomeValue]
    var encrypted: Bool
    var rssiDB: Double
    var snrDB: Double
    var firstSeen: Date
    var lastSeen: Date
    var count: Int

    var lastValueText: String {
        values.isEmpty ? lastSummary : values.prefix(3).map { "\($0.label) \($0.formatted)" }.joined(separator: " · ")
    }
}

/// Ein Messwert eines Geräts – flache Liste für eine Weitergabe (MQTT o. Ä.).
struct SmartHomeMeasurement: Sendable, Equatable, Hashable, Identifiable {
    var deviceID: String
    var radio: SmartHomeRadio
    var address: String
    var name: String
    var unit: String
    var value: Double
    var date: Date

    var id: String { "\(deviceID)|\(name)" }
}

/// Übersetzte Anzeigenamen zu den festen deutschen Messwert-Namen
/// (`SmartHomeValue.name`). Unbekannte Namen bleiben, wie sie sind; bei
/// „Wert (VIF 7C)“, „Zähler 7“ o. Ä. wird nur das erste Wort übersetzt.
enum SmartHomeNames {
    static func label(_ key: String) -> String {
        if let text = known(key) { return text }
        if let space = key.firstIndex(of: " "), let head = known(String(key[..<space])) {
            return head + key[space...]
        }
        return key
    }

    private static func known(_ key: String) -> String? {
        switch key {
        case "Abstand": String(localized: "Abstand")
        case "Aktualitätsdauer": String(localized: "Aktualitätsdauer")
        case "Allgemein": String(localized: "Allgemein")
        case "Ausgelöst": String(localized: "Ausgelöst")
        case "Außentemperatur": String(localized: "Außentemperatur")
        case "Batterie": String(localized: "Batterie")
        case "Batterierestlaufzeit": String(localized: "Batterierestlaufzeit")
        case "Betriebsdauer": String(localized: "Betriebsdauer")
        case "Bodenfeuchte": String(localized: "Bodenfeuchte")
        case "Busadresse": String(localized: "Busadresse")
        case "Datum": String(localized: "Datum")
        case "Digitaleingänge": String(localized: "Digitaleingänge")
        case "Druck": String(localized: "Druck")
        case "Durchfluss": String(localized: "Durchfluss")
        case "Einschaltdauer": String(localized: "Einschaltdauer")
        case "Energie": String(localized: "Energie")
        case "Ereignis": String(localized: "Ereignis")
        case "Erweiterte Kennung": String(localized: "Erweiterte Kennung")
        case "Fabrikationsnummer": String(localized: "Fabrikationsnummer")
        case "Fehlerflags": String(localized: "Fehlerflags")
        case "Feinstaub PM2,5": String(localized: "Feinstaub PM2,5")
        case "Firmware-Version": String(localized: "Firmware-Version")
        case "Frequenz": String(localized: "Frequenz")
        case "Gas": String(localized: "Gas")
        case "Gedrückt": String(localized: "Gedrückt")
        case "Geschwindigkeit": String(localized: "Geschwindigkeit")
        case "Gewicht": String(localized: "Gewicht")
        case "Heizkosten-Einheiten": String(localized: "Heizkosten-Einheiten")
        case "Helligkeit": String(localized: "Helligkeit")
        case "Herstellerdaten": String(localized: "Herstellerdaten")
        case "Herstellerwert": String(localized: "Herstellerwert")
        case "Hitze": String(localized: "Hitze")
        case "Impulse": String(localized: "Impulse")
        case "Kälte": String(localized: "Kälte")
        case "Kontakt offen": String(localized: "Kontakt offen")
        case "Leistung": String(localized: "Leistung")
        case "Leistungsfaktor": String(localized: "Leistungsfaktor")
        case "Luftdruck": String(localized: "Luftdruck")
        case "Luftfeuchte": String(localized: "Luftfeuchte")
        case "Luftstrom": String(localized: "Luftstrom")
        case "Masse": String(localized: "Masse")
        case "Massenstrom": String(localized: "Massenstrom")
        case "Messgröße": String(localized: "Messgröße")
        case "Mittelungsdauer": String(localized: "Mittelungsdauer")
        case "Modell": String(localized: "Modell")
        case "Netzfrequenz": String(localized: "Netzfrequenz")
        case "Notfall": String(localized: "Notfall")
        case "Parametersatz": String(localized: "Parametersatz")
        case "Pegel": String(localized: "Pegel")
        case "Rauch": String(localized: "Rauch")
        case "Regen": String(localized: "Regen")
        case "Richtung": String(localized: "Richtung")
        case "Rücklauftemperatur": String(localized: "Rücklauftemperatur")
        case "Schaltzustand": String(localized: "Schaltzustand")
        case "Scheinenergie": String(localized: "Scheinenergie")
        case "Sensorwert": String(localized: "Sensorwert")
        case "Sicherheit": String(localized: "Sicherheit")
        case "Software-Version": String(localized: "Software-Version")
        case "Sollwert": String(localized: "Sollwert")
        case "Sonneneinstrahlung": String(localized: "Sonneneinstrahlung")
        case "Spannung": String(localized: "Spannung")
        case "Strom": String(localized: "Strom")
        case "Stromversorgung": String(localized: "Stromversorgung")
        case "System": String(localized: "System")
        case "Tankinhalt": String(localized: "Tankinhalt")
        case "Taupunkt": String(localized: "Taupunkt")
        case "Temperatur": String(localized: "Temperatur")
        case "Temperaturdifferenz": String(localized: "Temperaturdifferenz")
        case "Ventil": String(localized: "Ventil")
        case "Volumen": String(localized: "Volumen")
        case "Vorlauftemperatur": String(localized: "Vorlauftemperatur")
        case "Wärme": String(localized: "Wärme")
        case "Wasser": String(localized: "Wasser")
        case "Wassertemperatur": String(localized: "Wassertemperatur")
        case "Wert": String(localized: "Wert")
        case "Wetter": String(localized: "Wetter")
        case "Zähler": String(localized: "Zähler")
        case "Zählwert": String(localized: "Zählwert")
        case "Zeitpunkt": String(localized: "Zeitpunkt")
        case "Zugang": String(localized: "Zugang")
        case "Zustand": String(localized: "Zustand")
        default: nil
        }
    }
}

enum SmartHomeHex {
    static func string(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    /// Hex-Text → Bytes; Leerzeichen, „0x“, „:“ und „-“ erlaubt.
    static func parse(_ text: String) -> [UInt8]? {
        let hex = text.lowercased().replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
        guard hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// CRC-Rechner (MSB zuerst, ohne Spiegelung) – alle hier gebrauchten
/// Varianten sind von dieser Art.
enum SmartHomeCRC {
    static func crc16<C: Collection>(_ bytes: C, poly: UInt16, initial: UInt16, xorOut: UInt16 = 0) -> UInt16 where C.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ poly : crc << 1 }
        }
        return crc ^ xorOut
    }

    static func crc8<C: Collection>(_ bytes: C, poly: UInt8, initial: UInt8 = 0) -> UInt8 where C.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ poly : crc << 1 }
        }
        return crc
    }
}
