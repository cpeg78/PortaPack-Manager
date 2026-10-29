import Foundation

/// Geräteadresse (6 Bytes, im Paket niederwertiges Byte zuerst).
struct BLEAddress: Hashable, Sendable {
    let bytes: [UInt8]
    let random: Bool

    var string: String { bytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":") }

    /// Art der Adresse: öffentlich (vom Hersteller) oder zufällig – die
    /// beiden obersten Bits sagen, ob sie fest ist oder wechselt.
    var kind: String {
        guard random else { return String(localized: "öffentlich") }
        switch bytes[5] >> 6 {
        case 0b11: return String(localized: "zufällig, fest")
        case 0b01: return String(localized: "zufällig, wechselt")
        case 0b00: return String(localized: "zufällig, anonym")
        default: return String(localized: "zufällig")
        }
    }

    /// Wechselnde Adressen (Datenschutz): dasselbe Gerät taucht neu auf.
    var rotates: Bool { random && bytes[5] >> 6 != 0b11 }
}

/// Ein AD-Eintrag (Länge, Typ, Daten) aus den Werbedaten.
struct BLEADField: Sendable, Equatable {
    let type: UInt8
    let data: [UInt8]

    var typeName: String {
        switch type {
        case 0x01: "Flags"
        case 0x02, 0x03: String(localized: "16-Bit-Dienste")
        case 0x04, 0x05: String(localized: "32-Bit-Dienste")
        case 0x06, 0x07: String(localized: "128-Bit-Dienste")
        case 0x08: String(localized: "Name (kurz)")
        case 0x09: String(localized: "Name")
        case 0x0A: String(localized: "Sendeleistung")
        case 0x0D: String(localized: "Geräteklasse")
        case 0x10: String(localized: "Geräte-ID")
        case 0x12: String(localized: "Verbindungsintervall")
        case 0x14, 0x15, 0x1F: String(localized: "Dienstanfrage")
        case 0x16: String(localized: "Dienstdaten (16 Bit)")
        case 0x20: String(localized: "Dienstdaten (32 Bit)")
        case 0x21: String(localized: "Dienstdaten (128 Bit)")
        case 0x19: String(localized: "Erscheinungsbild")
        case 0x1B: String(localized: "Geräteadresse")
        case 0x24: "URI"
        case 0x2A: String(localized: "Mesh-Nachricht")
        case 0x2B: "Mesh-Beacon"
        case 0x30: "Broadcast-Name"
        case 0xFF: String(localized: "Herstellerdaten")
        default: String(format: String(localized: "Typ 0x%02X"), type)
        }
    }

    var hex: String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Ein Werbepaket, zerlegt nach PDU-Typ.
struct BLEAdvertisement: Sendable, Equatable {
    enum PDUType: UInt8, Sendable {
        case advInd = 0, advDirectInd, advNonconnInd, scanReq, scanRsp, connectInd, advScanInd, advExtInd

        var name: String {
            switch self {
            case .advInd: "ADV_IND"
            case .advDirectInd: "ADV_DIRECT_IND"
            case .advNonconnInd: "ADV_NONCONN_IND"
            case .scanReq: "SCAN_REQ"
            case .scanRsp: "SCAN_RSP"
            case .connectInd: "CONNECT_IND"
            case .advScanInd: "ADV_SCAN_IND"
            case .advExtInd: "ADV_EXT_IND"
            }
        }

        var meaning: String {
            switch self {
            case .advInd: String(localized: "Werbung, verbindbar")
            case .advDirectInd: String(localized: "Gezielte Werbung")
            case .advNonconnInd: String(localized: "Werbung, nicht verbindbar")
            case .scanReq: String(localized: "Scan-Anfrage")
            case .scanRsp: String(localized: "Scan-Antwort")
            case .connectInd: String(localized: "Verbindungsaufbau")
            case .advScanInd: String(localized: "Werbung, abfragbar")
            case .advExtInd: String(localized: "Erweiterte Werbung")
            }
        }
    }

    let type: PDUType
    /// Absender des Pakets (bei SCAN_REQ der Scanner, bei CONNECT_IND der Initiator).
    let address: BLEAddress?
    /// Angesprochenes Gerät (gezielte Werbung, Scan-Anfrage, Verbindungsaufbau).
    let target: BLEAddress?
    let fields: [BLEADField]

    static func parse(_ pdu: [UInt8]) -> BLEAdvertisement? {
        guard pdu.count >= 2, let type = PDUType(rawValue: pdu[0] & 0x0F) else { return nil }
        let txRandom = pdu[0] & 0x40 != 0, rxRandom = pdu[0] & 0x80 != 0
        let payload = Array(pdu.dropFirst(2))
        func address(_ offset: Int, random: Bool) -> BLEAddress? {
            payload.count >= offset + 6 ? BLEAddress(bytes: Array(payload[offset..<offset + 6]), random: random) : nil
        }
        switch type {
        case .advInd, .advNonconnInd, .advScanInd, .scanRsp:
            guard payload.count >= 6 else { return nil }
            return BLEAdvertisement(type: type, address: address(0, random: txRandom), target: nil,
                                    fields: fields(Array(payload.dropFirst(6))))
        case .advDirectInd, .scanReq, .connectInd:
            guard payload.count >= 12 else { return nil }
            return BLEAdvertisement(type: type, address: address(0, random: txRandom),
                                    target: address(6, random: rxRandom), fields: [])
        case .advExtInd:
            // Erweiterter Kopf: Länge (6 Bit) + Modus, dann Flags; die
            // Werbedaten selbst liegen meist auf einem Sekundärkanal.
            guard let first = payload.first else { return nil }
            let headerLength = Int(first & 0x3F)
            guard headerLength >= 1, payload.count >= 1 + headerLength else {
                return BLEAdvertisement(type: type, address: nil, target: nil, fields: [])
            }
            let flags = payload[1]
            var offset = 2
            var advertiser: BLEAddress?
            if flags & 0x01 != 0, offset + 6 <= 1 + headerLength {
                advertiser = address(offset, random: txRandom)
                offset += 6
            }
            let data = Array(payload.dropFirst(1 + headerLength))
            return BLEAdvertisement(type: type, address: advertiser, target: nil, fields: fields(data))
        }
    }

    /// Zerlegt AD-Strukturen; bricht bei kaputter Länge ab.
    static func fields(_ data: [UInt8]) -> [BLEADField] {
        var result: [BLEADField] = []
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            guard length > 0, index + 1 + length <= data.count else { break }
            result.append(BLEADField(type: data[index + 1], data: Array(data[(index + 2)..<(index + 1 + length)])))
            index += 1 + length
        }
        return result
    }

    // MARK: - Einzelne Felder

    var name: String? {
        let field = fields.first { $0.type == 0x09 } ?? fields.first { $0.type == 0x08 } ?? fields.first { $0.type == 0x30 }
        return field.flatMap { String(bytes: $0.data, encoding: .utf8) }?.trimmingCharacters(in: .controlCharacters)
    }

    var txPower: Int? { fields.first { $0.type == 0x0A }?.data.first.map { Int(Int8(bitPattern: $0)) } }

    var manufacturer: (company: UInt16, data: [UInt8])? {
        guard let field = fields.first(where: { $0.type == 0xFF }), field.data.count >= 2 else { return nil }
        return (UInt16(field.data[0]) | UInt16(field.data[1]) << 8, Array(field.data.dropFirst(2)))
    }

    var serviceUUIDs: [UInt16] {
        fields.filter { $0.type == 0x02 || $0.type == 0x03 }.flatMap { field in
            stride(from: 0, to: field.data.count - 1, by: 2).map { UInt16(field.data[$0]) | UInt16(field.data[$0 + 1]) << 8 }
        }
    }

    var serviceData: [(uuid: UInt16, data: [UInt8])] {
        fields.filter { $0.type == 0x16 && $0.data.count >= 2 }.map {
            (UInt16($0.data[0]) | UInt16($0.data[1]) << 8, Array($0.data.dropFirst(2)))
        }
    }
}

/// Ein ausgelesener Wert (Temperatur, Batterie, Beacon-Kennung …).
struct BLEReading: Sendable, Equatable, Hashable {
    let label: String
    let value: String
}

/// Ordnet Werbedaten bekannten Geräten zu und liest Sensorwerte aus
/// (RuuviTag, Govee, Xiaomi mit ATC/pvvx-Firmware, BTHome, Eddystone, iBeacon).
enum BLEInterpreter {
    struct Result: Sendable, Equatable {
        var kind: String?
        var readings: [BLEReading] = []
    }

    static func interpret(_ ad: BLEAdvertisement) -> Result {
        var result = Result()
        for (uuid, data) in ad.serviceData {
            if let found = serviceData(uuid, data) {
                result.kind = result.kind ?? found.kind
                result.readings += found.readings
            }
        }
        if let (company, data) = ad.manufacturer, let found = manufacturer(company, data) {
            if result.kind == nil || !found.readings.isEmpty { result.kind = found.kind ?? result.kind }
            result.readings += found.readings
        }
        if result.kind == nil {
            for uuid in ad.serviceUUIDs {
                if let name = serviceNames[uuid] { result.kind = name; break }
            }
        }
        if let power = ad.txPower { result.readings.append(BLEReading(label: String(localized: "Sendeleistung"), value: "\(power) dBm")) }
        return result
    }

    // MARK: Herstellerdaten

    static func manufacturer(_ company: UInt16, _ data: [UInt8]) -> Result? {
        switch company {
        case 0x004C: return apple(data)
        case 0x0499: return ruuvi(data)
        case 0xEC88: return govee(data)
        case 0x0006: return Result(kind: String(localized: "Microsoft (Swift Pair/Geräte-Erkennung)"))
        default:
            return companyNames[company].map { Result(kind: $0) }
        }
    }

    private static func apple(_ data: [UInt8]) -> Result {
        guard let type = data.first else { return Result(kind: "Apple") }
        switch type {
        case 0x02 where data.count >= 23:
            // iBeacon: UUID, Major, Minor, Leistung in 1 m.
            let uuid = data[2..<18].map { String(format: "%02X", $0) }.joined()
            let formatted = [uuid.prefix(8), uuid.dropFirst(8).prefix(4), uuid.dropFirst(12).prefix(4),
                             uuid.dropFirst(16).prefix(4), uuid.dropFirst(20)].joined(separator: "-")
            let major = Int(data[18]) << 8 | Int(data[19]), minor = Int(data[20]) << 8 | Int(data[21])
            return Result(kind: "iBeacon", readings: [
                BLEReading(label: "UUID", value: formatted),
                BLEReading(label: "Major/Minor", value: "\(major) / \(minor)"),
                BLEReading(label: String(localized: "Pegel in 1 m"), value: "\(Int8(bitPattern: data[22])) dBm"),
            ])
        case 0x05: return Result(kind: "Apple AirDrop")
        case 0x07: return Result(kind: "Apple AirPods/Beats")
        case 0x09: return Result(kind: String(localized: "Apple AirPlay-Ziel"))
        case 0x0A: return Result(kind: String(localized: "Apple AirPlay-Quelle"))
        case 0x0C: return Result(kind: "Apple Handoff")
        case 0x0D, 0x0E: return Result(kind: "Apple Hotspot")
        case 0x0F: return Result(kind: "Apple Nearby Action")
        case 0x10: return Result(kind: String(localized: "Apple-Gerät (Nearby Info)"))
        case 0x12: return Result(kind: String(localized: "Apple „Wo ist?“ (AirTag o. ä.)"))
        default: return Result(kind: "Apple")
        }
    }

    /// RuuviTag, Datenformat 5 (RAWv2) und 3 (RAWv1).
    private static func ruuvi(_ d: [UInt8]) -> Result {
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(d[i]) << 8 | UInt16(d[i + 1]))) }
        func u16(_ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
        guard let format = d.first else { return Result(kind: "RuuviTag") }
        var readings: [BLEReading] = []
        if format == 5, d.count >= 24 {
            if d[1] != 0x80 || d[2] != 0 { readings.append(temperature(Double(s16(1)) * 0.005)) }
            if u16(3) != 0xFFFF { readings.append(humidity(Double(u16(3)) * 0.0025)) }
            if u16(5) != 0xFFFF { readings.append(pressure(Double(u16(5) + 50_000) / 100)) }
            let power = u16(13)
            readings.append(voltage(Double((power >> 5) + 1600) / 1000))
            readings.append(BLEReading(label: String(localized: "Beschleunigung"),
                                       value: String(format: "%.3f / %.3f / %.3f g", Double(s16(7)) / 1000, Double(s16(9)) / 1000, Double(s16(11)) / 1000)))
            readings.append(BLEReading(label: String(localized: "Bewegungen"), value: "\(d[15])"))
        } else if format == 3, d.count >= 14 {
            let sign: Double = d[2] & 0x80 != 0 ? -1 : 1
            readings.append(temperature(sign * (Double(d[2] & 0x7F) + Double(d[3]) / 100)))
            readings.append(humidity(Double(d[1]) * 0.5))
            readings.append(pressure(Double(u16(4) + 50_000) / 100))
            readings.append(voltage(Double(u16(12)) / 1000))
        }
        return Result(kind: "RuuviTag", readings: readings)
    }

    /// Govee H5072/H5075/H5101 …: drei Bytes Temperatur·10000 + Feuchte·10.
    private static func govee(_ d: [UInt8]) -> Result {
        guard d.count >= 5 else { return Result(kind: "Govee") }
        let raw = Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3])
        let negative = raw & 0x80_0000 != 0
        let value = raw & 0x7F_FFFF
        let celsius = Double(value / 1000) / 10 * (negative ? -1 : 1)
        return Result(kind: String(localized: "Govee-Thermometer"), readings: [
            temperature(celsius), humidity(Double(value % 1000) / 10), battery(Int(d[4])),
        ])
    }

    // MARK: Dienstdaten

    static func serviceData(_ uuid: UInt16, _ d: [UInt8]) -> Result? {
        switch uuid {
        case 0x181A: return environmental(d)
        case 0xFCD2: return bthome(d)
        case 0xFEAA: return eddystone(d)
        case 0x180F where d.count == 1: return Result(kind: nil, readings: [battery(Int(d[0]))])
        default: return serviceNames[uuid].map { Result(kind: $0) }
        }
    }

    /// Xiaomi LYWSD03MMC u. a. mit eigener Firmware (ATC1441 bzw. pvvx).
    private static func environmental(_ d: [UInt8]) -> Result? {
        if d.count == 13 {
            let celsius = Double(Int16(bitPattern: UInt16(d[6]) << 8 | UInt16(d[7]))) / 10
            return Result(kind: String(localized: "Thermometer (ATC-Firmware)"), readings: [
                temperature(celsius), humidity(Double(d[8])), battery(Int(d[9])),
                voltage(Double(Int(d[10]) << 8 | Int(d[11])) / 1000),
            ])
        }
        if d.count >= 15 {
            let celsius = Double(Int16(bitPattern: UInt16(d[6]) | UInt16(d[7]) << 8)) / 100
            let percent = Double(Int(d[8]) | Int(d[9]) << 8) / 100
            return Result(kind: String(localized: "Thermometer (pvvx-Firmware)"), readings: [
                temperature(celsius), humidity(percent), battery(Int(d[12])),
                voltage(Double(Int(d[10]) | Int(d[11]) << 8) / 1000),
            ])
        }
        return Result(kind: String(localized: "Umweltsensor"))
    }

    /// BTHome v2 (unverschlüsselt): Objekt-ID, dann Wert fester Länge.
    static func bthome(_ d: [UInt8]) -> Result {
        guard let info = d.first else { return Result(kind: "BTHome") }
        if info & 0x01 != 0 { return Result(kind: String(localized: "BTHome (verschlüsselt)")) }
        var readings: [BLEReading] = []
        var index = 1
        while index < d.count {
            let id = d[index]
            guard let object = bthomeObjects[id] else { break }
            guard index + 1 + object.size <= d.count else { break }
            var raw = 0
            for k in 0..<object.size { raw |= Int(d[index + 1 + k]) << (8 * k) }
            if object.signed, raw & (1 << (8 * object.size - 1)) != 0 { raw -= 1 << (8 * object.size) }
            index += 1 + object.size
            guard !object.label.isEmpty else { continue }
            let value: String
            if object.binary {
                value = raw != 0 ? String(localized: "ja") : String(localized: "nein")
            } else {
                let scaled = Double(raw) * object.factor
                let digits = object.factor >= 1 ? 0 : max(0, Int((-log10(object.factor)).rounded()))
                value = String(format: "%.\(digits)f", scaled) + (object.unit.isEmpty ? "" : " " + object.unit)
            }
            readings.append(BLEReading(label: object.label, value: value))
        }
        return Result(kind: String(localized: "BTHome-Sensor"), readings: readings)
    }

    private struct BTHomeObject {
        var size: Int
        var factor: Double = 1
        var label: String
        var unit: String = ""
        var signed = false
        var binary = false
    }

    private static let bthomeObjects: [UInt8: BTHomeObject] = {
        var table: [UInt8: BTHomeObject] = [
            0x00: BTHomeObject(size: 1, label: ""),   // Paketnummer
            0x01: BTHomeObject(size: 1, label: String(localized: "Batterie"), unit: "%"),
            0x02: BTHomeObject(size: 2, factor: 0.01, label: String(localized: "Temperatur"), unit: "°C", signed: true),
            0x03: BTHomeObject(size: 2, factor: 0.01, label: String(localized: "Feuchte"), unit: "%"),
            0x04: BTHomeObject(size: 3, factor: 0.01, label: String(localized: "Luftdruck"), unit: "hPa"),
            0x05: BTHomeObject(size: 3, factor: 0.01, label: String(localized: "Helligkeit"), unit: "lx"),
            0x06: BTHomeObject(size: 2, factor: 0.01, label: String(localized: "Gewicht"), unit: "kg"),
            0x08: BTHomeObject(size: 2, factor: 0.01, label: String(localized: "Taupunkt"), unit: "°C", signed: true),
            0x09: BTHomeObject(size: 1, label: String(localized: "Zähler")),
            0x0A: BTHomeObject(size: 3, factor: 0.001, label: String(localized: "Energie"), unit: "kWh"),
            0x0B: BTHomeObject(size: 3, factor: 0.01, label: String(localized: "Leistung"), unit: "W"),
            0x0C: BTHomeObject(size: 2, factor: 0.001, label: String(localized: "Spannung"), unit: "V"),
            0x0D: BTHomeObject(size: 2, label: "PM2,5", unit: "µg/m³"),
            0x0E: BTHomeObject(size: 2, label: "PM10", unit: "µg/m³"),
            0x12: BTHomeObject(size: 2, label: "CO₂", unit: "ppm"),
            0x13: BTHomeObject(size: 2, label: "VOC", unit: "µg/m³"),
            0x14: BTHomeObject(size: 2, factor: 0.01, label: String(localized: "Bodenfeuchte"), unit: "%"),
            0x2E: BTHomeObject(size: 1, label: String(localized: "Feuchte"), unit: "%"),
            0x2F: BTHomeObject(size: 1, label: String(localized: "Bodenfeuchte"), unit: "%"),
            0x3A: BTHomeObject(size: 1, label: String(localized: "Taste")),
            0x3D: BTHomeObject(size: 2, label: String(localized: "Zähler")),
            0x3E: BTHomeObject(size: 4, label: String(localized: "Zähler")),
            0x3F: BTHomeObject(size: 2, factor: 0.1, label: String(localized: "Drehung"), unit: "°", signed: true),
            0x40: BTHomeObject(size: 2, label: String(localized: "Abstand"), unit: "mm"),
            0x41: BTHomeObject(size: 2, factor: 0.1, label: String(localized: "Abstand"), unit: "m"),
            0x42: BTHomeObject(size: 3, factor: 0.001, label: String(localized: "Dauer"), unit: "s"),
            0x43: BTHomeObject(size: 2, factor: 0.001, label: String(localized: "Strom"), unit: "A"),
            0x44: BTHomeObject(size: 2, factor: 0.01, label: String(localized: "Geschwindigkeit"), unit: "m/s"),
            0x45: BTHomeObject(size: 2, factor: 0.1, label: String(localized: "Temperatur"), unit: "°C", signed: true),
            0x46: BTHomeObject(size: 1, factor: 0.1, label: String(localized: "UV-Index")),
            0x47: BTHomeObject(size: 2, factor: 0.1, label: String(localized: "Volumen"), unit: "l"),
            0x48: BTHomeObject(size: 2, label: String(localized: "Volumen"), unit: "ml"),
            0x49: BTHomeObject(size: 2, factor: 0.001, label: String(localized: "Durchfluss"), unit: "m³/h"),
            0x4A: BTHomeObject(size: 2, factor: 0.1, label: String(localized: "Spannung"), unit: "V"),
        ]
        // Binärsensoren (je ein Byte).
        let binary: [UInt8: String] = [
            0x0F: String(localized: "Schalter"), 0x10: String(localized: "Eingeschaltet"), 0x11: String(localized: "Geöffnet"), 0x15: String(localized: "Batterie schwach"),
            0x16: String(localized: "Lädt"), 0x17: String(localized: "Kohlenmonoxid"), 0x18: String(localized: "Kälte"), 0x19: String(localized: "Verbunden"), 0x1A: String(localized: "Tür offen"),
            0x1B: String(localized: "Garagentor offen"), 0x1C: String(localized: "Gas"), 0x1D: String(localized: "Hitze"), 0x1E: String(localized: "Licht"), 0x1F: String(localized: "Entriegelt"),
            0x20: String(localized: "Nass"), 0x21: String(localized: "Bewegung"), 0x22: String(localized: "In Bewegung"), 0x23: String(localized: "Belegt"), 0x24: String(localized: "Steckdose an"),
            0x25: String(localized: "Anwesend"), 0x26: String(localized: "Störung"), 0x27: String(localized: "Läuft"), 0x28: String(localized: "Sicher"), 0x29: String(localized: "Rauch"),
            0x2A: String(localized: "Geräusch"), 0x2B: String(localized: "Manipulation"), 0x2C: String(localized: "Vibration"), 0x2D: String(localized: "Fenster offen"),
        ]
        for (id, label) in binary { table[id] = BTHomeObject(size: 1, label: label, binary: true) }
        return table
    }()

    /// Eddystone (Google): UID, URL, Telemetrie.
    private static func eddystone(_ d: [UInt8]) -> Result {
        guard let frame = d.first else { return Result(kind: "Eddystone") }
        switch frame {
        case 0x00 where d.count >= 18:
            let namespace = d[2..<12].map { String(format: "%02X", $0) }.joined()
            let instance = d[12..<18].map { String(format: "%02X", $0) }.joined()
            return Result(kind: "Eddystone-UID", readings: [BLEReading(label: String(localized: "Kennung"), value: "\(namespace) / \(instance)")])
        case 0x10 where d.count >= 3:
            let schemes = ["http://www.", "https://www.", "http://", "https://"]
            let expansions = [".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/",
                              ".com", ".org", ".edu", ".net", ".info", ".biz", ".gov"]
            var url = Int(d[2]) < schemes.count ? schemes[Int(d[2])] : ""
            for byte in d.dropFirst(3) {
                if Int(byte) < expansions.count { url += expansions[Int(byte)] }
                else if (0x21...0x7E).contains(byte) { url.append(Character(UnicodeScalar(byte))) }
            }
            return Result(kind: "Eddystone-URL", readings: [BLEReading(label: "URL", value: url)])
        case 0x20 where d.count >= 14:
            let millivolts = Int(d[2]) << 8 | Int(d[3])
            var readings: [BLEReading] = []
            if millivolts != 0 { readings.append(voltage(Double(millivolts) / 1000)) }
            if !(d[4] == 0x80 && d[5] == 0) {
                readings.append(temperature(Double(Int8(bitPattern: d[4])) + Double(d[5]) / 256))
            }
            let seconds = (Int(d[10]) << 24 | Int(d[11]) << 16 | Int(d[12]) << 8 | Int(d[13])) / 10
            readings.append(BLEReading(label: String(localized: "Laufzeit"), value: Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow))))
            return Result(kind: String(localized: "Eddystone-Telemetrie"), readings: readings)
        default:
            return Result(kind: "Eddystone")
        }
    }

    // MARK: Formatierung

    private static func temperature(_ celsius: Double) -> BLEReading {
        BLEReading(label: String(localized: "Temperatur"), value: String(format: "%.2f °C", celsius))
    }
    private static func humidity(_ percent: Double) -> BLEReading {
        BLEReading(label: String(localized: "Feuchte"), value: String(format: "%.1f %%", percent))
    }
    private static func pressure(_ hPa: Double) -> BLEReading {
        BLEReading(label: String(localized: "Luftdruck"), value: String(format: "%.2f hPa", hPa))
    }
    private static func voltage(_ volts: Double) -> BLEReading {
        BLEReading(label: String(localized: "Batteriespannung"), value: String(format: "%.3f V", volts))
    }
    private static func battery(_ percent: Int) -> BLEReading {
        BLEReading(label: String(localized: "Batterie"), value: "\(percent) %")
    }

    // MARK: Namen

    /// Häufige Firmenkennungen (Bluetooth SIG „Assigned Numbers“).
    static let companyNames: [UInt16: String] = [
        0x0002: "Intel", 0x0006: "Microsoft", 0x000F: "Broadcom", 0x001D: "Qualcomm",
        0x004C: "Apple", 0x0059: "Nordic Semiconductor", 0x0075: "Samsung", 0x0087: "Garmin",
        0x009E: "Bose", 0x00E0: "Google", 0x012D: "Sony", 0x0131: "Cypress", 0x0157: "Huami (Amazfit)",
        0x0171: "Amazon", 0x01DA: "Logitech", 0x0225: "Nest", 0x027D: "Huawei", 0x02E5: "Espressif",
        0x0310: "SGL Italia", 0x038F: "Xiaomi", 0x0499: "Ruuvi Innovations", 0x0590: "Polar",
        0x05A7: "Sonos", 0x0600: "iRobot", 0x0822: "Shelly", 0x0969: "SwitchBot", 0xEC88: "Govee",
    ]

    /// Bekannte 16-Bit-Dienste (Dienstdaten oder Dienstliste).
    static let serviceNames: [UInt16: String] = [
        0x180D: String(localized: "Herzfrequenz-Sensor"), 0x1816: String(localized: "Fahrrad-Sensor (Tempo/Trittfrequenz)"),
        0x1818: String(localized: "Leistungsmesser (Rad)"), 0x1826: String(localized: "Fitnessgerät"), 0x1810: String(localized: "Blutdruckmessgerät"),
        0x181D: String(localized: "Waage"), 0x1812: String(localized: "Eingabegerät (HID)"), 0x180F: String(localized: "Batteriedienst"),
        0xFD6F: "Corona-Warn/Exposure Notification", 0xFE95: "Xiaomi MiBeacon", 0xFEAA: "Eddystone",
        0xFEED: "Tile", 0xFEEC: "Tile", 0xFD5A: "Samsung SmartTag", 0xFE2C: "Google Fast Pair",
        0xFCD2: String(localized: "BTHome-Sensor"), 0xFD3D: "SwitchBot", 0xFE9F: "Google", 0xFEF3: "Google",
        0xFE07: "Sonos", 0xFDF0: "Google", 0xFEBE: "Bose", 0xFE03: "Amazon",
        0xFD69: "Samsung", 0xFE78: "HP", 0x181A: String(localized: "Umweltsensor"),
    ]
}
