import Foundation

/// Drohnen-Kennung (Remote ID) nach ASTM F3411 / ASD-STAN prEN 4709-002,
/// wie sie Drohnen per Bluetooth-Werbepaket aussenden: AD-Typ 0x16
/// (Dienstdaten), UUID 0xFFFA, App-Code 0x0D, Nachrichtenzähler, dann eine
/// Open-Drone-ID-Nachricht von 25 Byte (Legacy-Werbung) oder ein Message
/// Pack (erweiterte Werbung). Felder und Skalierungen wie in der
/// Referenz opendroneid-core-c (`opendroneid.c`): Bitfelder mit dem
/// niederwertigen Bit zuerst, Mehrbytewerte Little Endian.
enum RemoteID {
    static let serviceUUID: UInt16 = 0xFFFA
    static let appCode: UInt8 = 0x0D
    static let messageSize = 25
    /// Zeitstempel in System- und Auth-Nachricht: Sekunden seit 1.1.2019 00:00 UTC.
    static let epoch = Date(timeIntervalSince1970: 1_546_300_800)

    enum MessageType: UInt8, Sendable {
        case basicID = 0, location = 1, auth = 2, selfID = 3, system = 4, operatorID = 5, pack = 0xF

        var name: String {
            switch self {
            case .basicID: String(localized: "Basic ID")
            case .location: String(localized: "Position/Vektor")
            case .auth: String(localized: "Authentisierung")
            case .selfID: String(localized: "Self-ID")
            case .system: String(localized: "System")
            case .operatorID: String(localized: "Betreiber-ID")
            case .pack: String(localized: "Message Pack")
            }
        }
    }

    // MARK: - Nachrichten

    struct BasicID: Sendable, Equatable {
        var idType: UInt8
        var uaType: UInt8
        var uasID: String
        var rawID: [UInt8]

        var idTypeName: String {
            switch idType {
            case 0: String(localized: "keine")
            case 1: String(localized: "Seriennummer (ANSI/CTA-2063-A)")
            case 2: String(localized: "Registrierung (Luftfahrtbehörde)")
            case 3: "UTM-UUID"
            case 4: String(localized: "Sitzungs-ID")
            default: String(localized: "Typ \(Int(idType))")
            }
        }

        var uaTypeName: String { RemoteID.uaTypeName(uaType) }
    }

    struct Location: Sendable, Equatable {
        var status: UInt8
        var heightOverGround: Bool
        /// Kurs über Grund in Grad (0–359), nil = unbekannt.
        var direction: Double?
        /// Horizontale Geschwindigkeit in m/s, nil = unbekannt.
        var speed: Double?
        /// Steigrate in m/s (positiv = steigend), nil = unbekannt.
        var verticalSpeed: Double?
        var latitude: Double?
        var longitude: Double?
        /// Barometrische Höhe (Druckhöhe) in m, nil = unbekannt.
        var altitudeBaro: Double?
        /// Geometrische Höhe (WGS-84) in m, nil = unbekannt.
        var altitudeGeo: Double?
        /// Höhe über Startpunkt bzw. Grund in m, nil = unbekannt.
        var height: Double?
        var horizontalAccuracy: UInt8
        var verticalAccuracy: UInt8
        var baroAccuracy: UInt8
        var speedAccuracy: UInt8
        var timestampAccuracy: UInt8
        /// Zehntelsekunden seit der vollen Stunde als Sekunden, nil = unbekannt.
        var timestamp: Double?

        var statusName: String {
            switch status {
            case 0: String(localized: "nicht angegeben")
            case 1: String(localized: "am Boden")
            case 2: String(localized: "in der Luft")
            case 3: String(localized: "Notfall")
            case 4: String(localized: "Remote-ID-Störung")
            default: String(localized: "Status \(Int(status))")
            }
        }

        /// Horizontale Genauigkeit in Metern (nil = unbekannt). Die Stufen
        /// folgen der Norm (Seemeilen bis 1 m); opendroneid-core-c gibt für
        /// 4 NM 7808 m an, richtig sind 7408 m.
        var horizontalAccuracyMeters: Double? {
            let table: [Double] = [0, 18_520, 7_408, 3_704, 1_852, 926, 555.6, 185.2, 92.6, 30, 10, 3, 1]
            return (1..<table.count).contains(Int(horizontalAccuracy)) ? table[Int(horizontalAccuracy)] : nil
        }

        var verticalAccuracyMeters: Double? { Self.verticalMeters(verticalAccuracy) }
        var baroAccuracyMeters: Double? { Self.verticalMeters(baroAccuracy) }

        var speedAccuracyMeters: Double? {
            let table: [Double] = [0, 10, 3, 1, 0.3]
            return (1..<table.count).contains(Int(speedAccuracy)) ? table[Int(speedAccuracy)] : nil
        }

        static func verticalMeters(_ value: UInt8) -> Double? {
            let table: [Double] = [0, 150, 45, 25, 10, 3, 1]
            return (1..<table.count).contains(Int(value)) ? table[Int(value)] : nil
        }
    }

    struct SelfID: Sendable, Equatable {
        var descriptionType: UInt8
        var text: String
    }

    struct System: Sendable, Equatable {
        var operatorLocationType: UInt8
        var classificationType: UInt8
        var operatorLatitude: Double?
        var operatorLongitude: Double?
        var areaCount: Int
        var areaRadius: Int
        var areaCeiling: Double?
        var areaFloor: Double?
        var categoryEU: UInt8
        var classEU: UInt8
        var operatorAltitude: Double?
        var timestamp: Date?

        var operatorLocationName: String {
            switch operatorLocationType {
            case 0: String(localized: "Startpunkt")
            case 1: String(localized: "live (GNSS)")
            case 2: String(localized: "fest")
            default: String(localized: "Typ \(Int(operatorLocationType))")
            }
        }

        /// EU-Kategorie und -Klasse, sofern die Einstufung „EU“ ist.
        var euClassification: String? {
            guard classificationType == 1 else { return nil }
            let category = [String(localized: "nicht angegeben"), String(localized: "offen"),
                            String(localized: "speziell"), String(localized: "zulassungspflichtig")]
            let cat = Int(categoryEU) < category.count ? category[Int(categoryEU)] : "\(categoryEU)"
            let cls = classEU == 0 ? String(localized: "Klasse nicht angegeben") : classEU <= 7 ? "C\(classEU - 1)"
                : String(localized: "Klasse \(Int(classEU))")
            return String(localized: "Kategorie \(cat), \(cls)")
        }
    }

    struct OperatorID: Sendable, Equatable {
        var idType: UInt8
        var id: String
    }

    struct Auth: Sendable, Equatable {
        var authType: UInt8
        var page: Int
        var lastPageIndex: Int?
        var length: Int?

        var typeName: String {
            switch authType {
            case 0: String(localized: "keine")
            case 1: String(localized: "Signatur der UAS-ID")
            case 2: String(localized: "Signatur der Betreiber-ID")
            case 3: String(localized: "Signatur des Nachrichtensatzes")
            case 4: String(localized: "Network Remote ID")
            case 5: String(localized: "eigenes Verfahren")
            default: String(localized: "Typ \(Int(authType))")
            }
        }
    }

    enum Message: Sendable, Equatable {
        case basicID(BasicID)
        case location(Location)
        case auth(Auth)
        case selfID(SelfID)
        case system(System)
        case operatorID(OperatorID)

        var type: MessageType {
            switch self {
            case .basicID: .basicID
            case .location: .location
            case .auth: .auth
            case .selfID: .selfID
            case .system: .system
            case .operatorID: .operatorID
            }
        }
    }

    /// Inhalt eines Werbepakets: Zähler und eine oder mehrere Nachrichten.
    struct Frame: Sendable, Equatable {
        var counter: UInt8
        var messages: [Message]
    }

    static func uaTypeName(_ type: UInt8) -> String {
        switch type {
        case 0: String(localized: "nicht angegeben")
        case 1: String(localized: "Flächenflugzeug")
        case 2: String(localized: "Hubschrauber/Multikopter")
        case 3: String(localized: "Tragschrauber")
        case 4: String(localized: "Senkrechtstarter (hybrid)")
        case 5: String(localized: "Schwingenflugzeug")
        case 6: String(localized: "Segelflugzeug")
        case 7: String(localized: "Drachen")
        case 8: String(localized: "Freiballon")
        case 9: String(localized: "Fesselballon")
        case 10: String(localized: "Luftschiff")
        case 11: String(localized: "Fallschirm")
        case 12: String(localized: "Rakete")
        case 13: String(localized: "gefesseltes Fluggerät")
        case 14: String(localized: "Bodenhindernis")
        default: String(localized: "sonstiges")
        }
    }

    // MARK: - Dekodieren

    /// Sucht in einem Werbepaket die Remote-ID-Dienstdaten.
    static func parse(_ ad: BLEAdvertisement) -> Frame? {
        for (uuid, data) in ad.serviceData where uuid == serviceUUID {
            if let frame = parseServiceData(data) { return frame }
        }
        return nil
    }

    /// Dienstdaten nach der UUID: App-Code, Zähler, Nachricht oder Pack.
    /// Wi-Fi-Beacon (ASTM F3411 / ASD-STAN): herstellerspezifisches Element
    /// 0xDD mit OUI FA:0B:BC, Typ 0x0D, dann Zähler und Message Pack.
    static func parseBeaconElements(_ ies: [UInt8]) -> Frame? {
        var i = 0
        while i + 2 <= ies.count {
            let id = ies[i], length = Int(ies[i + 1])
            let start = i + 2
            guard start + length <= ies.count else { return nil }
            if id == 0xDD, length >= 5 + messageSize,
               Array(ies[start..<start + 4]) == [0xFA, 0x0B, 0xBC, appCode] {
                let messages = decode(Array(ies[(start + 5)..<(start + length)]))
                if !messages.isEmpty { return Frame(counter: ies[start + 4], messages: messages) }
            }
            i = start + length
        }
        return nil
    }

    static func parseServiceData(_ data: [UInt8]) -> Frame? {
        guard data.count >= 2 + messageSize, data[0] == appCode else { return nil }
        let messages = decode(Array(data[2...]))
        return messages.isEmpty ? nil : Frame(counter: data[1], messages: messages)
    }

    /// Eine Nachricht (25 Byte) oder ein Message Pack.
    static func decode(_ bytes: [UInt8]) -> [Message] {
        guard bytes.count >= messageSize, let type = MessageType(rawValue: bytes[0] >> 4) else { return [] }
        if type == .pack {
            guard bytes.count >= 3, bytes[1] == UInt8(messageSize) else { return [] }
            let count = Int(bytes[2])
            guard (1...9).contains(count), bytes.count >= 3 + count * messageSize else { return [] }
            return (0..<count).compactMap { index in
                let start = 3 + index * messageSize
                let message = Array(bytes[start..<start + messageSize])
                // Ein Pack darf keine Packs enthalten.
                guard message[0] >> 4 != MessageType.pack.rawValue else { return nil }
                return decodeSingle(message)
            }
        }
        return decodeSingle(Array(bytes.prefix(messageSize))).map { [$0] } ?? []
    }

    static func decodeSingle(_ m: [UInt8]) -> Message? {
        guard m.count >= messageSize, let type = MessageType(rawValue: m[0] >> 4) else { return nil }
        switch type {
        case .basicID:
            let raw = Array(m[2..<22])
            let idType = m[1] >> 4
            // Seriennummer und Registrierung sind Text, die übrigen Kennungen binär.
            let text = (idType == 1 || idType == 2) ? string(raw) : raw.map { String(format: "%02X", $0) }.joined()
            return .basicID(BasicID(idType: idType, uaType: m[1] & 0x0F, uasID: text, rawID: raw))
        case .location:
            let flags = m[1]
            let ew = flags & 0x02 != 0
            let directionRaw = Double(m[2]) + (ew ? 180 : 0)
            let mult = flags & 0x01 != 0
            let speedRaw = mult ? Double(m[3]) * 0.75 + 255 * 0.25 : Double(m[3]) * 0.25
            let vertical = Double(Int8(bitPattern: m[4])) * 0.5
            let lat = Double(int32(m, 5)) / 1e7, lon = Double(int32(m, 9)) / 1e7
            let time = uint16(m, 21)
            let validPosition = !(lat == 0 && lon == 0) && abs(lat) <= 90 && abs(lon) <= 180
            return .location(Location(
                status: flags >> 4,
                heightOverGround: flags & 0x04 != 0,
                direction: directionRaw <= 360 ? directionRaw.truncatingRemainder(dividingBy: 360) : nil,
                speed: speedRaw < 254.5 ? speedRaw : nil,
                verticalSpeed: abs(vertical) <= 62 ? vertical : nil,
                latitude: validPosition ? lat : nil,
                longitude: validPosition ? lon : nil,
                altitudeBaro: altitude(uint16(m, 13)),
                altitudeGeo: altitude(uint16(m, 15)),
                height: altitude(uint16(m, 17)),
                horizontalAccuracy: m[19] & 0x0F,
                verticalAccuracy: m[19] >> 4,
                baroAccuracy: m[20] >> 4,
                speedAccuracy: m[20] & 0x0F,
                timestampAccuracy: m[23] & 0x0F,
                timestamp: time == 0xFFFF ? nil : Double(time) / 10))
        case .auth:
            let page = Int(m[1] & 0x0F)
            return .auth(Auth(authType: m[1] >> 4, page: page,
                              lastPageIndex: page == 0 ? Int(m[2]) : nil,
                              length: page == 0 ? Int(m[3]) : nil))
        case .selfID:
            return .selfID(SelfID(descriptionType: m[1], text: string(Array(m[2..<25]))))
        case .system:
            let lat = Double(int32(m, 2)) / 1e7, lon = Double(int32(m, 6)) / 1e7
            let validPosition = !(lat == 0 && lon == 0) && abs(lat) <= 90 && abs(lon) <= 180
            let seconds = UInt32(m[20]) | UInt32(m[21]) << 8 | UInt32(m[22]) << 16 | UInt32(m[23]) << 24
            return .system(System(
                operatorLocationType: m[1] & 0x03,
                classificationType: (m[1] >> 2) & 0x07,
                operatorLatitude: validPosition ? lat : nil,
                operatorLongitude: validPosition ? lon : nil,
                areaCount: Int(uint16(m, 10)),
                areaRadius: Int(m[12]) * 10,
                areaCeiling: altitude(uint16(m, 13)),
                areaFloor: altitude(uint16(m, 15)),
                categoryEU: m[17] >> 4,
                classEU: m[17] & 0x0F,
                operatorAltitude: altitude(uint16(m, 18)),
                timestamp: seconds == 0 ? nil : epoch.addingTimeInterval(TimeInterval(seconds))))
        case .operatorID:
            return .operatorID(OperatorID(idType: m[1], id: string(Array(m[2..<22]))))
        case .pack:
            return nil
        }
    }

    /// Höhe: Wert · 0,5 − 1000 m; 0 (= −1000 m) heißt unbekannt.
    static func altitude(_ raw: UInt16) -> Double? {
        raw == 0 ? nil : Double(raw) * 0.5 - 1000
    }

    private static func uint16(_ m: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(m[offset]) | UInt16(m[offset + 1]) << 8
    }

    private static func int32(_ m: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: UInt32(m[offset]) | UInt32(m[offset + 1]) << 8 | UInt32(m[offset + 2]) << 16 | UInt32(m[offset + 3]) << 24)
    }

    /// Text bis zur ersten Null, nur druckbare Zeichen.
    private static func string(_ bytes: [UInt8]) -> String {
        let text = bytes.prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}

// MARK: - Kodieren (für Tests und Vorführung)

/// Gegenstück zum Dekoder, Rundung wie in opendroneid-core-c (`round`,
/// also kaufmännisch weg von null).
enum RemoteIDEncoder {
    static func header(_ type: RemoteID.MessageType) -> UInt8 { type.rawValue << 4 | 0x02 }   // Protokollversion 2

    static func basicID(idType: UInt8, uaType: UInt8, id: String) -> [UInt8] {
        var m = [header(.basicID), idType << 4 | (uaType & 0x0F)]
        m += padded(Array(id.utf8), 20)
        return m + [0, 0, 0]
    }

    static func location(status: UInt8, direction: Double, speed: Double, verticalSpeed: Double,
                         latitude: Double, longitude: Double, altitudeBaro: Double, altitudeGeo: Double,
                         heightOverGround: Bool, height: Double, horizontalAccuracy: UInt8 = 0,
                         verticalAccuracy: UInt8 = 0, baroAccuracy: UInt8 = 0, speedAccuracy: UInt8 = 0,
                         timestampAccuracy: UInt8 = 0, timestamp: Double) -> [UInt8] {
        var directionInt = Int(direction.rounded())
        if directionInt == 360 { directionInt = 0 }
        let ew = directionInt >= 180
        if ew { directionInt -= 180 }
        let mult = speed > 255 * 0.25
        let speedRaw = mult ? clamp(Int(((speed - 63.75) / 0.75).rounded()), 0, 255) : Int((speed / 0.25).rounded())
        var flags = status << 4
        if heightOverGround { flags |= 0x04 }
        if ew { flags |= 0x02 }
        if mult { flags |= 0x01 }
        var m: [UInt8] = [header(.location), flags, UInt8(clamp(directionInt, 0, 255)), UInt8(speedRaw),
                          UInt8(bitPattern: Int8(clamp(Int((verticalSpeed / 0.5).rounded()), -128, 127)))]
        m += le32(latLon(latitude)) + le32(latLon(longitude))
        m += le16(alt(altitudeBaro)) + le16(alt(altitudeGeo)) + le16(alt(height))
        m.append(verticalAccuracy << 4 | (horizontalAccuracy & 0x0F))
        m.append(baroAccuracy << 4 | (speedAccuracy & 0x0F))
        m += le16(UInt16(clamp(Int((timestamp * 10).rounded()), 0, 36_000)))
        m += [timestampAccuracy & 0x0F, 0]
        return m
    }

    static func selfID(type: UInt8 = 0, text: String) -> [UInt8] {
        [header(.selfID), type] + padded(Array(text.utf8), 23)
    }

    static func system(locationType: UInt8, classificationType: UInt8, latitude: Double, longitude: Double,
                       areaCount: UInt16, areaRadius: Int, areaCeiling: Double, areaFloor: Double,
                       categoryEU: UInt8, classEU: UInt8, operatorAltitude: Double, timestamp: UInt32) -> [UInt8] {
        var m: [UInt8] = [header(.system), (classificationType & 0x07) << 2 | (locationType & 0x03)]
        m += le32(latLon(latitude)) + le32(latLon(longitude))
        m += le16(areaCount)
        m.append(UInt8(clamp(areaRadius / 10, 0, 255)))
        m += le16(alt(areaCeiling)) + le16(alt(areaFloor))
        m.append(categoryEU << 4 | (classEU & 0x0F))
        m += le16(alt(operatorAltitude))
        m += le32(Int32(bitPattern: timestamp))
        return m + [0]
    }

    static func operatorID(type: UInt8 = 0, id: String) -> [UInt8] {
        [header(.operatorID), type] + padded(Array(id.utf8), 20) + [0, 0, 0]
    }

    static func pack(_ messages: [[UInt8]]) -> [UInt8] {
        [header(.pack), UInt8(RemoteID.messageSize), UInt8(messages.count)] + messages.flatMap { $0 }
    }

    /// Dienstdaten-AD-Struktur (Länge, 0x16, UUID, App-Code, Zähler, Nachricht).
    static func adStructure(_ message: [UInt8], counter: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x16, 0xFA, 0xFF, RemoteID.appCode, counter] + message
        return [UInt8(body.count)] + body
    }

    private static func latLon(_ value: Double) -> Int32 { Int32(clamp(Int((value * 1e7).rounded()), -1_800_000_000, 1_800_000_000)) }
    private static func alt(_ value: Double) -> UInt16 { UInt16(clamp(Int(((value + 1000) / 0.5).rounded()), 0, 65_535)) }
    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: Int32) -> [UInt8] { (0..<4).map { UInt8((UInt32(bitPattern: v) >> (8 * $0)) & 0xFF) } }
    private static func padded(_ bytes: [UInt8], _ count: Int) -> [UInt8] {
        Array(bytes.prefix(count)) + Array(repeating: 0, count: max(0, count - bytes.count))
    }
}

// MARK: - Drohnen sammeln

/// Eine Drohne, zusammengefasst aus allen Nachrichten eines Senders.
struct Drone: Identifiable, Sendable, Equatable {
    var address: BLEAddress
    var basicIDs: [RemoteID.BasicID] = []
    var location: RemoteID.Location?
    var selfID: RemoteID.SelfID?
    var system: RemoteID.System?
    var operatorID: RemoteID.OperatorID?
    var authType: UInt8?
    var trail: [GeoPoint] = []
    var messageCount = 0
    var rssiDB: Double = -100
    var firstSeen: Date
    var lastSeen: Date

    struct GeoPoint: Sendable, Equatable {
        let lat: Double
        let lon: Double
    }

    var id: String { address.string }

    var uasID: String? { basicIDs.first(where: { !$0.uasID.isEmpty })?.uasID }
    var uaType: String? { basicIDs.first.map(\.uaTypeName) }
    var latitude: Double? { location?.latitude }
    var longitude: Double? { location?.longitude }

    var displayName: String { uasID ?? operatorID?.id ?? address.string }
}

/// Führt Remote-ID-Nachrichten je Absenderadresse zusammen.
struct DroneTracker: Sendable {
    private(set) var drones: [String: Drone] = [:]

    var sorted: [Drone] { drones.values.sorted { $0.lastSeen > $1.lastSeen } }

    mutating func ingest(_ frame: RemoteID.Frame, address: BLEAddress, rssiDB: Double, date: Date) {
        let key = address.string
        var drone = drones[key] ?? Drone(address: address, firstSeen: date, lastSeen: date)
        for message in frame.messages {
            switch message {
            case .basicID(let basic):
                if let index = drone.basicIDs.firstIndex(where: { $0.idType == basic.idType }) {
                    drone.basicIDs[index] = basic
                } else {
                    drone.basicIDs.append(basic)
                }
            case .location(let location):
                drone.location = location
                if let lat = location.latitude, let lon = location.longitude {
                    let point = Drone.GeoPoint(lat: lat, lon: lon)
                    if drone.trail.last != point { drone.trail.append(point) }
                    if drone.trail.count > 500 { drone.trail.removeFirst(drone.trail.count - 500) }
                }
            case .auth(let auth): drone.authType = auth.authType
            case .selfID(let selfID): drone.selfID = selfID
            case .system(let system): drone.system = system
            case .operatorID(let op): drone.operatorID = op
            }
        }
        drone.messageCount += frame.messages.count
        drone.rssiDB = drone.messageCount == frame.messages.count ? rssiDB : 0.7 * drone.rssiDB + 0.3 * rssiDB
        drone.lastSeen = date
        drones[key] = drone
        // BLE-Adressen sind meist zufällig – Tabelle begrenzen.
        DevicePruning.prune(&drones, limit: 2000, maxAge: 1800, now: date) { $0.lastSeen }
    }
}
