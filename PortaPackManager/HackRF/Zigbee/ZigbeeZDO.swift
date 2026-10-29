import Foundation

/// Zigbee Device Objects (Profil 0x0000): Gerätemeldung, Adress-, Knoten- und
/// Endpunktbeschreibungen, Nachbartabellen – das, woraus sich Gerätetyp,
/// Versorgung und Netzaufbau ablesen lassen (Zigbee-Spezifikation 2.4).
struct ZDOMessage: Sendable, Equatable {
    struct Announce: Sendable, Equatable {
        var nwk: UInt16
        var ieee: UInt64
        var capability: UInt8
        /// Bit 1: vollwertiges Gerät (Router), Bit 2: Netzversorgung, Bit 3: Empfänger immer an.
        var router: Bool { capability & 0x02 != 0 }
        var mainsPowered: Bool { capability & 0x04 != 0 }
        var rxOnWhenIdle: Bool { capability & 0x08 != 0 }
    }

    struct SimpleDescriptor: Sendable, Equatable {
        var nwk: UInt16
        var endpoint: UInt8
        var profile: UInt16
        var deviceID: UInt16
        var inputClusters: [UInt16]
        var outputClusters: [UInt16]
        var deviceName: String { ZDO.deviceName(profile: profile, id: deviceID) }
    }

    struct NodeDescriptor: Sendable, Equatable {
        var nwk: UInt16
        /// 0 Koordinator, 1 Router, 2 Endgerät.
        var logicalType: Int
        var mainsPowered: Bool
        var rxOnWhenIdle: Bool
        var manufacturerCode: UInt16
        var typeName: String { [String(localized: "Koordinator"), String(localized: "Router"), String(localized: "Endgerät")][min(logicalType, 2)] }
    }

    struct Neighbor: Sendable, Equatable {
        var extendedPAN: UInt64
        var ieee: UInt64
        var nwk: UInt16
        /// 0 Koordinator, 1 Router, 2 Endgerät, 3 unbekannt.
        var deviceType: Int
        var rxOnWhenIdle: Int
        /// 0 Elternteil, 1 Kind, 2 Geschwister, 3 keine, 4 ehemaliges Kind.
        var relationship: Int
        var depth: Int
        var lqi: Int
    }

    var cluster: UInt16
    var sequence: UInt8
    var status: UInt8?
    var summary: String
    var announce: Announce?
    var simpleDescriptor: SimpleDescriptor?
    var nodeDescriptor: NodeDescriptor?
    var activeEndpoints: (nwk: UInt16, endpoints: [UInt8])?
    var addressMapping: (nwk: UInt16, ieee: UInt64)?
    /// Nachbartabelle (Mgmt_Lqi_rsp) des sendenden Geräts.
    var neighbors: [Neighbor] = []

    static func == (a: ZDOMessage, b: ZDOMessage) -> Bool {
        a.cluster == b.cluster && a.sequence == b.sequence && a.summary == b.summary
    }

    static func parse(cluster: UInt16, _ b: [UInt8]) -> ZDOMessage? {
        guard let sequence = b.first else { return nil }
        var message = ZDOMessage(cluster: cluster, sequence: sequence, summary: ZDO.name(cluster))
        let p = Array(b.dropFirst())
        func u16(_ i: Int) -> UInt16? { i + 2 <= p.count ? UInt16(p[i]) | UInt16(p[i + 1]) << 8 : nil }
        func u64(_ i: Int) -> UInt64? { i + 8 <= p.count ? ZigbeeFormat.le64(p, i) : nil }
        let isResponse = cluster & 0x8000 != 0
        if isResponse {
            guard let status = p.first else { return message }
            message.status = status
            if status != 0 {
                message.summary = String(localized: "\(message.summary): \(ZDO.statusName(status))")
                return message
            }
        }
        switch cluster {
        case 0x0013:
            guard let nwk = u16(0), let ieee = u64(2), p.count >= 11 else { break }
            let announce = Announce(nwk: nwk, ieee: ieee, capability: p[10])
            message.announce = announce
            let role = announce.router ? String(localized: "Router") : String(localized: "Endgerät")
            let power = announce.mainsPowered ? String(localized: "Netzstrom") : String(localized: "Batterie")
            message.summary = String(format: String(localized: "Gerätemeldung 0x%04X · %@ · %@, %@"), nwk, ZigbeeFormat.ieee(ieee), role, power)
        case 0x0000, 0x0001:
            if cluster == 0x0000, let ieee = u64(0) { message.summary = String(localized: "\(message.summary) für \(ZigbeeFormat.ieee(ieee))") }
            if cluster == 0x0001, let nwk = u16(0) { message.summary = String(format: String(localized: "%@ für 0x%04X"), message.summary, nwk) }
        case 0x8000, 0x8001:
            guard let ieee = u64(1), let nwk = u16(9) else { break }
            message.addressMapping = (nwk, ieee)
            message.summary += String(format: ": 0x%04X = %@", nwk, ZigbeeFormat.ieee(ieee))
        case 0x0004, 0x0002, 0x0005:
            if let nwk = u16(0) { message.summary += String(format: " 0x%04X", nwk) }
            if cluster == 0x0004, p.count >= 3 { message.summary = String(localized: "\(message.summary), Endpunkt \(Int(p[2]))") }
        case 0x8004:
            guard let nwk = u16(1), p.count >= 4 else { break }
            let length = Int(p[3])
            // p[10] (Zahl der Eingangscluster) wird gelesen – also 11 Byte verlangen.
            guard length >= 8, let profile = u16(5), let deviceID = u16(7), p.count >= 11 else { break }
            let endpoint = p[4]
            var i = 10
            let inCount = Int(p[i]); i += 1
            var input: [UInt16] = []
            for _ in 0..<inCount { if let c = u16(i) { input.append(c) }; i += 2 }
            var output: [UInt16] = []
            if i < p.count {
                let outCount = Int(p[i]); i += 1
                for _ in 0..<outCount { if let c = u16(i) { output.append(c) }; i += 2 }
            }
            let descriptor = SimpleDescriptor(nwk: nwk, endpoint: endpoint, profile: profile, deviceID: deviceID,
                                              inputClusters: input, outputClusters: output)
            message.simpleDescriptor = descriptor
            message.summary = String(format: String(localized: "Endpunkt %d von 0x%04X: %@"), endpoint, nwk, descriptor.deviceName)
                + (input.isEmpty ? "" : " · " + input.prefix(6).map(ZCL.clusterName).joined(separator: ", "))
        case 0x8002:
            guard let nwk = u16(1), p.count >= 6, let manufacturer = u16(6) else { break }
            let descriptor = NodeDescriptor(nwk: nwk, logicalType: Int(p[3] & 7), mainsPowered: p[5] & 0x04 != 0,
                                            rxOnWhenIdle: p[5] & 0x08 != 0, manufacturerCode: manufacturer)
            message.nodeDescriptor = descriptor
            message.summary = String(format: String(localized: "Knoten 0x%04X: %@, %@, Hersteller 0x%04X"), nwk, descriptor.typeName,
                                     descriptor.mainsPowered ? String(localized: "Netzstrom") : String(localized: "Batterie"), manufacturer)
        case 0x8005:
            guard let nwk = u16(1), p.count >= 4 else { break }
            let endpoints = Array(p[4..<min(p.count, 4 + Int(p[3]))])
            message.activeEndpoints = (nwk, endpoints)
            message.summary = String(format: String(localized: "Endpunkte von 0x%04X: %@"), nwk, endpoints.map(String.init).joined(separator: ", "))
        case 0x0006:
            guard let nwk = u16(0), let profile = u16(2), p.count >= 5 else { break }
            var clusters: [UInt16] = []
            var i = 5
            for _ in 0..<Int(p[4]) { if let c = u16(i) { clusters.append(c) }; i += 2 }
            message.summary = String(format: String(localized: "Dienstsuche 0x%04X, Profil 0x%04X"), nwk, profile)
                + (clusters.isEmpty ? "" : ": " + clusters.map(ZCL.clusterName).joined(separator: ", "))
        case 0x0021, 0x0022:
            guard let source = u64(0), p.count >= 11, let clusterID = u16(9) else { break }
            let ieee = ZigbeeFormat.ieee(source), endpoint = Int(p[8]), clusterName = ZCL.clusterName(clusterID)
            message.summary = cluster == 0x0021
                ? String(localized: "Bindung: \(ieee) Endpunkt \(endpoint) · \(clusterName)")
                : String(localized: "Bindung lösen: \(ieee) Endpunkt \(endpoint) · \(clusterName)")
        case 0x0034:
            if let ieee = u64(0) { message.summary += " " + ZigbeeFormat.ieee(ieee) }
        case 0x0036:
            if let duration = p.first { message.summary = duration == 0 ? String(localized: "\(message.summary): schließen") : String(localized: "\(message.summary) für \(Int(duration)) s") }
        case 0x8031:
            guard p.count >= 4 else { break }
            let count = Int(p[3])
            var i = 4
            for _ in 0..<count {
                guard i + 22 <= p.count else { break }
                let neighbor = Neighbor(extendedPAN: ZigbeeFormat.le64(p, i), ieee: ZigbeeFormat.le64(p, i + 8),
                                        nwk: UInt16(p[i + 16]) | UInt16(p[i + 17]) << 8,
                                        deviceType: Int(p[i + 18] & 3), rxOnWhenIdle: Int(p[i + 18] >> 2 & 3),
                                        relationship: Int(p[i + 18] >> 4 & 7), depth: Int(p[i + 20]), lqi: Int(p[i + 21]))
                message.neighbors.append(neighbor)
                i += 22
            }
            message.summary = String(localized: "Nachbartabelle: \(message.neighbors.count) von \(Int(p[1])) Einträgen")
                + (message.neighbors.isEmpty ? "" : " · " + message.neighbors.prefix(4).map { String(format: "0x%04X (LQI %d)", $0.nwk, $0.lqi) }.joined(separator: ", "))
        case 0x8032:
            guard p.count >= 4 else { break }
            message.summary = String(localized: "Routingtabelle: \(Int(p[3])) von \(Int(p[1])) Einträgen")
        default:
            break
        }
        return message
    }
}

enum ZDO {
    static let names: [UInt16: String] = [
        0x0000: String(localized: "Kurzadresse anfragen"), 0x0001: String(localized: "IEEE-Adresse anfragen"), 0x0002: String(localized: "Knotenbeschreibung anfragen"),
        0x0003: String(localized: "Leistungsbeschreibung anfragen"), 0x0004: String(localized: "Endpunktbeschreibung anfragen"), 0x0005: String(localized: "Endpunkte anfragen"),
        0x0006: String(localized: "Dienstsuche"), 0x0013: String(localized: "Gerätemeldung"), 0x0021: String(localized: "Bindung"), 0x0022: String(localized: "Bindung lösen"),
        0x0031: String(localized: "Nachbartabelle anfragen"), 0x0032: String(localized: "Routingtabelle anfragen"), 0x0033: String(localized: "Bindungstabelle anfragen"),
        0x0034: String(localized: "Gerät entfernen"), 0x0036: String(localized: "Beitritt erlauben"), 0x0038: String(localized: "Kanalwechsel/Netzaktualisierung"),
        0x8000: String(localized: "Kurzadresse"), 0x8001: String(localized: "IEEE-Adresse"), 0x8002: String(localized: "Knotenbeschreibung"), 0x8003: String(localized: "Leistungsbeschreibung"),
        0x8004: String(localized: "Endpunktbeschreibung"), 0x8005: String(localized: "Endpunkte"), 0x8006: String(localized: "Dienstsuche (Antwort)"),
        0x8021: String(localized: "Bindung (Antwort)"), 0x8022: String(localized: "Bindung lösen (Antwort)"), 0x8031: String(localized: "Nachbartabelle"),
        0x8032: String(localized: "Routingtabelle"), 0x8033: String(localized: "Bindungstabelle"), 0x8034: String(localized: "Gerät entfernt"),
        0x8036: String(localized: "Beitritt erlauben (Antwort)"), 0x8038: String(localized: "Netzaktualisierung (Antwort)"),
    ]

    static func name(_ cluster: UInt16) -> String {
        names[cluster] ?? String(format: "ZDO 0x%04X", cluster)
    }

    static func statusName(_ status: UInt8) -> String {
        switch status {
        case 0x80: String(localized: "ungültige Anfrage")
        case 0x81: String(localized: "Gerät nicht gefunden")
        case 0x82: String(localized: "ungültiger Endpunkt")
        case 0x83: String(localized: "Endpunkt nicht aktiv")
        case 0x84: String(localized: "nicht unterstützt")
        case 0x85: String(localized: "Zeitüberschreitung")
        case 0x86: String(localized: "keine Übereinstimmung")
        case 0x88: String(localized: "kein Eintrag")
        case 0x89: String(localized: "keine Beschreibung")
        case 0x8A: String(localized: "kein Platz")
        case 0x8B: String(localized: "nicht erlaubt")
        case 0x8C: String(localized: "nicht autorisiert")
        default: String(format: "Status 0x%02X", status)
        }
    }

    /// Gerätetypen des Home-Automation-Profils (0x0104) und von ZLL (0xC05E).
    static let deviceNames: [UInt16: String] = [
        0x0000: String(localized: "Ein/Aus-Schalter"), 0x0001: String(localized: "Dimmschalter"), 0x0002: String(localized: "Ein/Aus-Ausgang"), 0x0003: String(localized: "Dimmausgang"),
        0x0004: String(localized: "Szenenwähler"), 0x0005: String(localized: "Konfigurationswerkzeug"), 0x0006: String(localized: "Fernbedienung"), 0x0007: String(localized: "Kombigerät"),
        0x0008: String(localized: "Reichweitenverlängerer"), 0x0009: String(localized: "Steckdose"), 0x000A: String(localized: "Türschloss"), 0x000B: String(localized: "Türschloss-Steuerung"),
        0x000C: String(localized: "Einfacher Sensor"), 0x000D: String(localized: "Verbrauchsanzeige"), 0x0050: String(localized: "Gateway"), 0x0051: String(localized: "Smarte Steckdose"),
        0x0052: String(localized: "Haushaltsgerät"), 0x0053: String(localized: "Zählerschnittstelle"), 0x0100: String(localized: "Lampe (Ein/Aus)"), 0x0101: String(localized: "Lampe (dimmbar)"),
        0x0102: String(localized: "Lampe (Farbe, dimmbar)"), 0x0103: String(localized: "Lichtschalter"), 0x0104: String(localized: "Dimmer"), 0x0105: String(localized: "Farbdimmer"),
        0x0106: String(localized: "Lichtsensor"), 0x0107: String(localized: "Bewegungsmelder"), 0x0108: String(localized: "Ein/Aus-Ballast"), 0x0109: String(localized: "Dimmballast"),
        0x010A: String(localized: "Zwischenstecker (Ein/Aus)"), 0x010B: String(localized: "Zwischenstecker (dimmbar)"), 0x010C: String(localized: "Lampe (Farbtemperatur)"),
        0x010D: String(localized: "Lampe (erweiterte Farbe)"), 0x0200: String(localized: "Jalousie"), 0x0201: String(localized: "Jalousiesteuerung"), 0x0202: String(localized: "Rollladen"),
        0x0203: String(localized: "Rollladensteuerung"), 0x0300: String(localized: "Heiz-/Kühlgerät"), 0x0301: String(localized: "Thermostat"), 0x0302: String(localized: "Temperatursensor"),
        0x0303: String(localized: "Pumpe"), 0x0304: String(localized: "Pumpensteuerung"), 0x0305: String(localized: "Drucksensor"), 0x0306: String(localized: "Durchflusssensor"),
        0x0307: String(localized: "Klimagerät"), 0x0400: String(localized: "Alarmzentrale (IAS CIE)"), 0x0401: String(localized: "Alarmbedienteil"), 0x0402: String(localized: "Alarmzone (IAS)"),
        0x0403: String(localized: "Warngerät (IAS)"),
    ]

    static func deviceName(profile: UInt16, id: UInt16) -> String {
        switch profile {
        case 0x0104, 0xC05E: deviceNames[id] ?? String(format: String(localized: "Gerätetyp 0x%04X"), id)
        case 0x0109: String(localized: "Smart-Energy-Gerät")
        case 0xA1E0: String(localized: "Green-Power-Gerät")
        default: String(format: String(localized: "Profil 0x%04X, Typ 0x%04X"), profile, id)
        }
    }
}

// MARK: - Namen und Geräteinfos aus Zigbee2MQTT

/// Bekannte Geräte eines Netzes: Name, Modell, Hersteller – von Hand vergeben
/// oder aus Zigbee2MQTT (`configuration.yaml`/`devices.yaml`: `friendly_name`,
/// `database.db`: `modelId`, `manufName`). Gespeichert in den Einstellungen,
/// Schlüssel = IEEE-Adresse.
struct ZigbeeDeviceInfo: Codable, Sendable, Equatable {
    var name: String?
    var model: String?
    var manufacturer: String?
    var type: String?
}

enum ZigbeeDirectory {
    static let defaultsKey = "zigbeeDevices"

    static func load() -> [UInt64: ZigbeeDeviceInfo] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ZigbeeDeviceInfo].self, from: data) else { return [:] }
        return Dictionary(decoded.compactMap { key, value in UInt64(key, radix: 16).map { ($0, value) } }, uniquingKeysWith: { _, new in new })
    }

    static func save(_ devices: [UInt64: ZigbeeDeviceInfo]) {
        let encoded = Dictionary(uniqueKeysWithValues: devices.map { (String($0.key, radix: 16), $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    struct Import: Sendable, Equatable {
        var devices: [UInt64: ZigbeeDeviceInfo] = [:]
        var panID: UInt16?
        var channel: Int?
        var networkKeyText: String?
    }

    /// Liest `configuration.yaml`, `devices.yaml` oder `database.db` (JSON je Zeile).
    static func parse(_ text: String) -> Import {
        var result = Import()
        var current: UInt64?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let address = object["ieeeAddr"] as? String, let ieee = parseIEEE(address) {
                var info = result.devices[ieee] ?? ZigbeeDeviceInfo()
                info.model = (object["modelId"] as? String) ?? info.model
                info.manufacturer = (object["manufName"] as? String) ?? info.manufacturer
                info.type = (object["type"] as? String).map(typeName) ?? info.type
                result.devices[ieee] = info
                continue
            }
            // YAML: `'0x00158d0001a2b3c4':` leitet ein Gerät ein, `friendly_name:` darunter.
            if trimmed.hasSuffix(":"), let ieee = parseIEEE(String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))) {
                current = ieee
                if result.devices[ieee] == nil { result.devices[ieee] = ZigbeeDeviceInfo() }
                continue
            }
            if let value = yamlValue(trimmed, key: "friendly_name"), let ieee = current {
                result.devices[ieee, default: ZigbeeDeviceInfo()].name = value
            } else if let value = yamlValue(trimmed, key: "pan_id") {
                result.panID = value.lowercased().hasPrefix("0x") ? UInt16(value.dropFirst(2), radix: 16) : UInt16(value)
            } else if let value = yamlValue(trimmed, key: "channel"), !value.isEmpty {
                result.channel = Int(value)
            } else if trimmed.hasPrefix("network_key:") {
                current = nil
                if let range = text.range(of: "network_key:") {
                    let rest = String(text[range.lowerBound...])
                    if ZigbeeSecurity.parseKey(rest) != nil { result.networkKeyText = rest }
                }
            } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                current = nil                                   // neuer Abschnitt auf oberster Ebene
            }
        }
        return result
    }

    private static func yamlValue(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
    }

    static func parseIEEE(_ text: String) -> UInt64? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        hex = hex.replacingOccurrences(of: ":", with: "")
        guard hex.count == 16 else { return nil }
        return UInt64(hex, radix: 16)
    }

    private static func typeName(_ type: String) -> String {
        switch type {
        case "Coordinator": String(localized: "Koordinator")
        case "Router": String(localized: "Router")
        case "EndDevice": String(localized: "Endgerät")
        default: type
        }
    }
}

// MARK: - PCAP

enum ZigbeePCAP {
    /// Linktyp 195: IEEE 802.15.4 mit FCS – Wireshark zeigt die Rahmen mit
    /// hinterlegtem Netzwerkschlüssel entschlüsselt.
    static func data(_ frames: [ZigbeeRadioFrame]) -> Data {
        PCAPWriter.data(linktype: 195, frames: frames.map {
            PCAPWriter.Frame(bytes: IEEE802154.withFCS($0.mpdu), date: $0.date)
        })
    }
}


// MARK: - Verlauf und Messwerte

/// Ein Punkt der Zeitreihe eines Geräts.
struct ZigbeeHistorySample: Sendable, Equatable {
    var date: Date
    var rssiDB: Double?
    var metrics: [String: Double]
}

/// Zerlegt einen Messwert-Text in (Beschriftung, Zahl): „21.50 °C“ → („°C“, 21.5),
/// „Batterie 87 %“ → („Batterie %“, 87). Die Zahl wird aus dem Text gezogen,
/// die Beschriftung ist der Rest – so entstehen stabile Schlüssel für den Verlauf.
enum ZigbeeReading {
    static func parse(_ text: String) -> (label: String, value: Double)? {
        var numberStart: String.Index?
        var numberEnd: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c.isNumber || c == "-" || (c == "." && numberStart != nil) {
                if numberStart == nil { numberStart = index }
                numberEnd = text.index(after: index)
            } else if numberStart != nil, numberEnd != nil {
                break
            }
            index = text.index(after: index)
        }
        guard let start = numberStart, let end = numberEnd,
              let value = Double(text[start..<end]) else { return nil }
        let label = (text[text.startIndex..<start] + text[end...])
            .trimmingCharacters(in: .whitespaces)
        return (label.isEmpty ? "Wert" : label, value)  // „Wert“ ist Schlüssel für MQTT-Messgrößen – nicht lokalisieren
    }
}
