import Foundation

/// CRC-32 der 802.11-Rahmenprüfung (FCS): reflektiert, Polynom 0x04C11DB7,
/// Start und Ausgabe ⊕ 0xFFFFFFFF – die zlib-Variante, nicht die der
/// Mayhem-Firmware (`MayhemCRC32`, MSB-first).
enum WLANCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Die vier FCS-Bytes, wie sie am Rahmenende stehen (LSB zuerst).
    static func fcs(_ bytes: [UInt8]) -> [UInt8] {
        let v = checksum(bytes[...])
        return (0..<4).map { UInt8(v >> (8 * UInt32($0)) & 0xFF) }
    }

    /// Prüft einen MPDU samt angehängter FCS.
    static func verify(_ mpdu: [UInt8]) -> Bool {
        guard mpdu.count > 4 else { return false }
        return Array(mpdu.suffix(4)) == fcs(Array(mpdu.dropLast(4)))
    }
}

/// Ein 802.11-MAC-Rahmen (ohne FCS), so weit wie für Beacons und
/// NAN-Aktionsrahmen nötig.
struct WLANFrame: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case beacon, probeRequest, probeResponse, action, data, control, other
    }

    var type: Int
    var subtype: Int
    var kind: Kind
    /// Empfänger, Sender, BSSID (Verwaltungsrahmen).
    var address1: [UInt8]
    var address2: [UInt8]
    var address3: [UInt8]
    var sequence: Int
    /// Rahmenrumpf nach dem MAC-Kopf (ohne FCS).
    var body: [UInt8]

    /// NAN-Cluster-Adresse: Service-Discovery-Rahmen gehen an 51:6F:9A:01:00:00.
    static let nanCluster: [UInt8] = [0x51, 0x6F, 0x9A, 0x01, 0x00, 0x00]
    /// Wi-Fi-Alliance-OUI, in NAN-Rahmen gefolgt vom Typ 0x13.
    static let wfaOUI: [UInt8] = [0x50, 0x6F, 0x9A]

    /// Zerlegt einen MPDU (ohne FCS); Datenrahmen mit vier Adressen und
    /// QoS-Kopf werden nur grob erfasst.
    static func parse(_ mpdu: [UInt8]) -> WLANFrame? {
        guard mpdu.count >= 10 else { return nil }
        let fc = mpdu[0]
        guard fc & 0x03 == 0 else { return nil }      // Protokollversion 0
        let type = Int(fc >> 2 & 0x03), subtype = Int(fc >> 4 & 0x0F)
        if type == 1 {
            // Steuerrahmen: nur Empfänger (ACK, CTS) bzw. Empfänger + Sender (RTS, BlockAck).
            let a1 = Array(mpdu[4..<10])
            let a2 = mpdu.count >= 16 ? Array(mpdu[10..<16]) : []
            return WLANFrame(type: type, subtype: subtype, kind: .control, address1: a1, address2: a2, address3: [],
                             sequence: 0, body: Array(mpdu.dropFirst(min(mpdu.count, 16))))
        }
        guard mpdu.count >= 24 else { return nil }
        let kind: Kind
        switch (type, subtype) {
        case (0, 8): kind = .beacon
        case (0, 4): kind = .probeRequest
        case (0, 5): kind = .probeResponse
        case (0, 13): kind = .action
        case (2, _): kind = .data
        default: kind = .other
        }
        let a1 = Array(mpdu[4..<10]), a2 = Array(mpdu[10..<16]), a3 = Array(mpdu[16..<22])
        let sequence = Int(mpdu[22]) >> 4 | Int(mpdu[23]) << 4
        var headerLength = 24
        if type == 2 {
            if mpdu[1] & 0x03 == 0x03 { headerLength += 6 }
            if subtype & 0x08 != 0 { headerLength += 2 }
            if mpdu[1] & 0x80 != 0 { headerLength += 4 }
        }
        guard mpdu.count >= headerLength else { return nil }
        return WLANFrame(type: type, subtype: subtype, kind: kind, address1: a1, address2: a2, address3: a3,
                         sequence: sequence, body: Array(mpdu[headerLength...]))
    }

    /// Informationselemente eines Beacons oder einer Probe-Antwort (nach
    /// Zeitstempel, Intervall und Fähigkeiten); bei Probe-Anfragen direkt.
    var informationElements: [UInt8]? {
        switch kind {
        case .beacon, .probeResponse: body.count >= 12 ? Array(body[12...]) : nil
        case .probeRequest: body
        default: nil
        }
    }

    /// Fähigkeiten (Beacon/Probe-Antwort): Bit 4 = Verschlüsselung (Privacy).
    var capability: UInt16? {
        guard kind == .beacon || kind == .probeResponse, body.count >= 12 else { return nil }
        return UInt16(body[10]) | UInt16(body[11]) << 8
    }

    /// Alle Elemente als (Kennung, Inhalt).
    var elements: [(id: UInt8, body: [UInt8])] {
        guard let ies = informationElements else { return [] }
        var out: [(UInt8, [UInt8])] = []
        var i = 0
        while i + 2 <= ies.count {
            let id = ies[i], length = Int(ies[i + 1])
            guard i + 2 + length <= ies.count else { break }
            out.append((id, Array(ies[(i + 2)..<(i + 2 + length)])))
            i += 2 + length
        }
        return out
    }

    /// SSID aus den Elementen (Element 0), leer bei verborgenen Netzen.
    var ssid: String? {
        guard let element = elements.first(where: { $0.id == 0 }) else { return nil }
        return String(decoding: element.body, as: UTF8.self)
    }

    /// Kanal laut DS-Parameter-Element (3), falls vorhanden.
    var dsChannel: Int? {
        elements.first(where: { $0.id == 3 && $0.body.count == 1 }).map { Int($0.body[0]) }
    }

    /// Schutz aus RSN-Element (48: WPA2/WPA3 nach AKM), WPA-Herstellerelement
    /// (0xDD 00:50:F2:01) oder Privacy-Bit (WEP).
    var security: String? {
        guard let capability else { return nil }
        if let rsn = elements.first(where: { $0.id == 48 })?.body {
            // Version(2), Gruppenchiffre(4), Paarzahl(2), Paare, AKM-Zahl(2), AKMs.
            var i = 2 + 4
            guard rsn.count >= i + 2 else { return "WPA2" }
            let pairwise = Int(rsn[i]) | Int(rsn[i + 1]) << 8
            i += 2 + 4 * pairwise
            guard rsn.count >= i + 2 else { return "WPA2" }
            let akmCount = Int(rsn[i]) | Int(rsn[i + 1]) << 8
            i += 2
            var akms: [UInt8] = []
            for _ in 0..<akmCount where rsn.count >= i + 4 {
                akms.append(rsn[i + 3])
                i += 4
            }
            if akms.contains(8) || akms.contains(9) { return akms.contains(2) ? "WPA2/WPA3" : "WPA3" }
            if akms.contains(1) || akms.contains(5) { return "WPA2 Enterprise" }
            return "WPA2"
        }
        if elements.contains(where: { $0.id == 0xDD && $0.body.count >= 4 && Array($0.body[0..<4]) == [0x00, 0x50, 0xF2, 0x01] }) {
            return "WPA"
        }
        return capability & 0x10 != 0 ? "WEP" : String(localized: "offen")
    }

    /// NAN-Service-Discovery-Rahmen: öffentlicher Aktionsrahmen (Kategorie 4,
    /// Aktion 9, herstellerspezifisch) mit OUI 50:6F:9A und Typ 0x13, danach
    /// NAN-Attribute (Kennung, Länge 16 Bit LE, Inhalt).
    var nanAttributes: [(id: UInt8, body: [UInt8])]? {
        guard kind == .action, body.count >= 6, body[0] == 4, body[1] == 9,
              Array(body[2..<5]) == Self.wfaOUI, body[5] == 0x13 else { return nil }
        var attributes: [(UInt8, [UInt8])] = []
        var i = 6
        while i + 3 <= body.count {
            let id = body[i], length = Int(body[i + 1]) | Int(body[i + 2]) << 8
            guard i + 3 + length <= body.count else { break }
            attributes.append((id, Array(body[(i + 3)..<(i + 3 + length)])))
            i += 3 + length
        }
        return attributes
    }

    /// Dienstbeschreibungen (Attribut 3) eines NAN-Rahmens: Service-ID (6 Byte)
    /// und die Service-Info, sofern vorhanden.
    var nanServices: [(serviceID: [UInt8], info: [UInt8]?)] {
        guard let attributes = nanAttributes else { return [] }
        return attributes.compactMap { attribute in
            guard attribute.id == 0x03, attribute.body.count >= 9 else { return nil }
            let a = attribute.body
            let control = a[8]
            var i = 9
            // Reihenfolge laut Wi-Fi Aware: Matching Filter, Service Response
            // Filter, Service Info – jeweils mit 1-Byte-Länge, falls im
            // Steuerbyte angekündigt (Bits 2, 3, 4).
            for bit: UInt8 in [0x04, 0x08] where control & bit != 0 {
                guard i < a.count else { return nil }
                i += 1 + Int(a[i])
            }
            var info: [UInt8]?
            if control & 0x10 != 0, i < a.count {
                let length = Int(a[i])
                guard i + 1 + length <= a.count else { return nil }
                info = Array(a[(i + 1)..<(i + 1 + length)])
            }
            return (Array(a[0..<6]), info)
        }
    }

    static func mac(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Remote ID über WLAN

extension RemoteID {
    /// NAN-Service-ID von Remote ID: die ersten sechs Bytes von
    /// SHA-256("org.opendroneid.remoteid").
    static let nanServiceID: [UInt8] = [0x88, 0x69, 0x19, 0x9D, 0x92, 0x09]

    /// Service-Info eines NAN-Rahmens: Zähler, dann das Message Pack. Manche
    /// Sender stellen den App-Code 0x0D voran – wird ebenfalls angenommen.
    static func parseNANServiceInfo(_ info: [UInt8]) -> Frame? {
        guard info.count >= 1 + messageSize else { return nil }
        if info[0] == appCode, info.count >= 2 + messageSize,
           MessageType(rawValue: info[2] >> 4) != nil, let frame = parseServiceData(info) {
            return frame
        }
        let messages = decode(Array(info[1...]))
        return messages.isEmpty ? nil : Frame(counter: info[0], messages: messages)
    }

    /// Remote-ID-Inhalt eines 802.11-Rahmens: Beacon/Probe-Antwort mit
    /// ASTM-Element oder französischer Kennung, oder NAN-Dienstbeschreibung.
    static func parse(_ frame: WLANFrame) -> (frame: Frame, transport: WLANTransport)? {
        if let ies = frame.informationElements {
            if let rid = parseBeaconElements(ies) { return (rid, .beacon) }
            if let french = FrenchDroneID.parse(elements: ies) { return (french.frame, .frenchBeacon) }
            return nil
        }
        for service in frame.nanServices where service.serviceID == nanServiceID {
            if let info = service.info, let rid = parseNANServiceInfo(info) { return (rid, .nan) }
        }
        return nil
    }

    enum WLANTransport: String, Sendable {
        case beacon = "Beacon"
        case frenchBeacon = "Beacon (FR)"
        case nan = "NAN"
    }
}

/// Französische elektronische Kennung („signalement électronique“, Arrêté
/// vom 27.12.2019): herstellerspezifisches Element 0xDD mit OUI 6A:5C:35,
/// Typ 0x01, danach TLVs (Typ 1 Byte, Länge 1 Byte), Zahlen big-endian.
/// Wird in Remote-ID-Nachrichten übersetzt, damit Liste und Karte sie wie
/// ASTM-Kennungen führen.
struct FrenchDroneID: Sendable, Equatable {
    static let oui: [UInt8] = [0x6A, 0x5C, 0x35]

    var version: UInt8?
    /// 30 Zeichen: Hersteller (3), Modell (3), Seriennummer (24).
    var id: String?
    var ansiID: String?
    var latitude: Double?
    var longitude: Double?
    /// Höhe über dem Meer in m.
    var altitude: Double?
    /// Höhe über dem Startpunkt in m.
    var height: Double?
    var homeLatitude: Double?
    var homeLongitude: Double?
    /// Geschwindigkeit über Grund in m/s.
    var speed: Double?
    /// Kurs in Grad.
    var heading: Double?

    static func parse(elements ies: [UInt8]) -> FrenchDroneID? {
        var i = 0
        while i + 2 <= ies.count {
            let id = ies[i], length = Int(ies[i + 1])
            let start = i + 2
            guard start + length <= ies.count else { return nil }
            if id == 0xDD, length >= 4, Array(ies[start..<start + 3]) == oui, ies[start + 3] == 0x01,
               let parsed = parse(tlv: Array(ies[(start + 4)..<(start + length)])) {
                return parsed
            }
            i = start + length
        }
        return nil
    }

    static func parse(tlv: [UInt8]) -> FrenchDroneID? {
        var result = FrenchDroneID()
        var i = 0
        func int32(_ b: ArraySlice<UInt8>) -> Int32 {
            Int32(bitPattern: b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        func int16(_ b: ArraySlice<UInt8>) -> Int16 {
            Int16(bitPattern: b.reduce(UInt16(0)) { $0 << 8 | UInt16($1) })
        }
        while i + 2 <= tlv.count {
            let type = tlv[i], length = Int(tlv[i + 1])
            let value = tlv[(i + 2)..<min(tlv.count, i + 2 + length)]
            guard value.count == length else { return nil }
            switch (type, length) {
            case (1, 1): result.version = value.first
            case (2, _): result.id = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            case (3, _): result.ansiID = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            case (4, 4): result.latitude = Double(int32(value)) / 1e5
            case (5, 4): result.longitude = Double(int32(value)) / 1e5
            case (6, 2): result.altitude = Double(int16(value))
            case (7, 2): result.height = Double(int16(value))
            case (8, 4): result.homeLatitude = Double(int32(value)) / 1e5
            case (9, 4): result.homeLongitude = Double(int32(value)) / 1e5
            case (10, 1): result.speed = Double(value.first ?? 0)
            case (11, 2): result.heading = Double(UInt16(bitPattern: int16(value)))
            default: break
            }
            i += 2 + length
        }
        guard result.id != nil || result.latitude != nil else { return nil }
        return result
    }

    /// Übersetzung in Remote-ID-Nachrichten (Basic ID, Position, System mit
    /// Startpunkt als Pilotposition).
    var frame: RemoteID.Frame {
        var messages: [RemoteID.Message] = []
        if let id {
            messages.append(.basicID(.init(idType: 1, uaType: 0, uasID: id, rawID: Array(id.utf8))))
        }
        if let ansiID {
            messages.append(.basicID(.init(idType: 2, uaType: 0, uasID: ansiID, rawID: Array(ansiID.utf8))))
        }
        if latitude != nil || longitude != nil {
            messages.append(.location(.init(
                status: 0, heightOverGround: false, direction: heading, speed: speed, verticalSpeed: nil,
                latitude: latitude, longitude: longitude, altitudeBaro: nil, altitudeGeo: altitude, height: height,
                horizontalAccuracy: 0, verticalAccuracy: 0, baroAccuracy: 0, speedAccuracy: 0, timestampAccuracy: 0,
                timestamp: nil)))
        }
        if let homeLatitude, let homeLongitude {
            messages.append(.system(.init(
                operatorLocationType: 0, classificationType: 0, operatorLatitude: homeLatitude,
                operatorLongitude: homeLongitude, areaCount: 1, areaRadius: 0, areaCeiling: nil, areaFloor: nil,
                categoryEU: 0, classEU: 0, operatorAltitude: nil, timestamp: nil)))
        }
        return RemoteID.Frame(counter: 0, messages: messages)
    }
}
