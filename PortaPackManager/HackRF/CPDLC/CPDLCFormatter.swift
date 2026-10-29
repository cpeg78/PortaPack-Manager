import Foundation

/// Klartext für dekodierte CPDLC-/CM-Nachrichten. Die Standardtexte der
/// Nachrichtenelemente („CLIMB TO [level]“) stammen aus den ICAO-/FANS-
/// Tabellen (CPDLC-Labels.json); Parameter werden nach Typ formatiert.
enum CPDLCFormatter {
    nonisolated(unsafe) private static var labelCache: [String: [String: String]]?
    private static let lock = NSLock()

    static var labels: [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        if let labelCache { return labelCache }
        var loaded: [String: [String: String]] = [:]
        if let url = Bundle(for: ASN1Schema.self).url(forResource: "CPDLC-Labels", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONDecoder().decode([String: [String: String]].self, from: data) { loaded = json }
        labelCache = loaded
        return loaded
    }

    struct Message: Equatable {
        /// Kurzform („↑ CLIMB TO FL350“).
        var summary: String
        var rows: [ACARSInterpretation.Row]
        var uplink: Bool
    }

    // MARK: ATN (ICAO Doc 9880)

    /// ATCUplinkMessage/ATCDownlinkMessage (ATN) in Klartext.
    static func atn(_ value: ASN1Value, uplink: Bool, schema: ASN1Schema) -> Message {
        var rows: [ACARSInterpretation.Row] = []
        if let header = value["header"] {
            if let id = header["messageIdNumber"]?.intValue { rows.append(.init(String(localized: "Nachricht Nr."), "\(id)")) }
            if let ref = header["messageRefNumber"]?.intValue { rows.append(.init(String(localized: "Bezug auf Nr."), "\(ref)")) }
            if let dt = header["dateTime"] { rows.append(.init(String(localized: "Zeit"), format(dt, type: "DateTimeGroup", schema: schema))) }
            if let ack = header["logicalAck"], case .enumerated(let s) = ack { rows.append(.init(String(localized: "Quittung"), s == "required" ? String(localized: "angefordert") : String(localized: "nicht nötig"))) }
        }
        var texts: [String] = []
        let elementType = uplink ? "ATCUplinkMsgElementId" : "ATCDownlinkMsgElementId"
        if let data = value["messageData"], let list = data["elementIds"], case .list(let elements) = list {
            for element in elements {
                texts.append(elementText(element, labelTable: elementType, schema: schema))
            }
            if let constrained = data["constrainedData"] {
                rows.append(.init(String(localized: "Streckenfreigabe"), format(constrained, type: uplink ? "ATCUplinkRouteClearanceConstrainedData" : "ATCDownlinkRouteClearanceConstrainedData", schema: schema)))
            }
        }
        for (i, t) in texts.enumerated() { rows.insert(.init(texts.count > 1 ? String(localized: "Element \(i + 1)") : String(localized: "Nachricht"), t), at: min(i, rows.count)) }
        let summary = summaryText(texts, uplink: uplink)
        return Message(summary: summary, rows: rows, uplink: uplink)
    }

    /// Kurzform „↑ Lotse: …“ bzw. „↓ Pilot: …“ für die Tabelle.
    private static func summaryText(_ texts: [String], uplink: Bool) -> String {
        let body = texts.isEmpty ? String(localized: "(leer)") : texts.joined(separator: " · ")
        return uplink ? String(localized: "↑ Lotse: \(body)") : String(localized: "↓ Pilot: \(body)")
    }

    // MARK: FANS-1/A

    static func fans(_ value: ASN1Value, uplink: Bool, schema: ASN1Schema) -> Message {
        var rows: [ACARSInterpretation.Row] = []
        if let header = value["aTCMessageheader"] {
            if let id = header["msgIdentificationNumber"]?.intValue { rows.append(.init(String(localized: "Nachricht Nr."), "\(id)")) }
            if let ref = header["msgReferenceNumber"]?.intValue { rows.append(.init(String(localized: "Bezug auf Nr."), "\(ref)")) }
            if let ts = header["timestamp"] { rows.append(.init(String(localized: "Zeit"), format(ts, type: "FANSTimestamp", schema: schema))) }
        }
        let table = uplink ? "FANSATCUplinkMsgElementId" : "FANSATCDownlinkMsgElementId"
        var elements: [ASN1Value] = []
        if let first = value[uplink ? "aTCuplinkmsgelementId" : "aTCdownlinkmsgelementId"] { elements.append(first) }
        if let more = value[uplink ? "aTCuplinkmsgelementid-seqOf" : "aTCdownlinkmsgelementid-seqOf"], case .list(let list) = more { elements += list }
        let texts = elements.map { elementText($0, labelTable: table, schema: schema) }
        for (i, t) in texts.enumerated() { rows.insert(.init(texts.count > 1 ? String(localized: "Element \(i + 1)") : String(localized: "Nachricht"), t), at: min(i, rows.count)) }
        let summary = summaryText(texts, uplink: uplink)
        return Message(summary: summary, rows: rows, uplink: uplink)
    }

    // MARK: Elemente

    /// „CLIMB TO [level]“ + Parameter → „CLIMB TO FL350“.
    static func elementText(_ element: ASN1Value, labelTable: String, schema: ASN1Schema) -> String {
        guard case .choice(let name, let value) = element else { return format(element, type: "", schema: schema) }
        let label = labels[labelTable]?[name] ?? name
        // Parametertyp aus dem Schema holen (für Einheiten).
        let memberType = schema.types[labelTable]?.members?.first { $0.name == name }?.type ?? ""
        let params = parameters(value, type: memberType, schema: schema)
        var text = label
        var remaining = params
        while let open = text.range(of: "["), let close = text.range(of: "]", range: open.upperBound..<text.endIndex) {
            let replacement = remaining.isEmpty ? "?" : remaining.removeFirst()
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: replacement)
        }
        if !remaining.isEmpty { text += " (" + remaining.joined(separator: ", ") + ")" }
        return text
    }

    /// Parameterliste eines Elements: eine SEQUENCE liefert je Feld einen Eintrag.
    private static func parameters(_ value: ASN1Value, type: String, schema: ASN1Schema) -> [String] {
        if case .null = value { return [] }
        if let (name, t) = schema.resolve(type), t.kind == "sequence", case .sequence(let members) = value, !isAtomic(name) {
            return members.map { m in
                let mt = t.members?.first { $0.name == m.0 }?.type ?? ""
                return format(m.1, type: mt, schema: schema)
            }
        }
        return [format(value, type: type, schema: schema)]
    }

    /// Sequenzen, die als ein Wert gelesen werden (Zeit, Position …).
    private static func isAtomic(_ name: String) -> Bool {
        let atomic = ["Time", "Timehhmmss", "DateTimeGroup", "Date", "LatitudeLongitude", "Latitude", "Longitude", "PlaceBearingDistance",
                      "FANSTime", "FANSTimestamp", "FANSLatitudeLongitude", "FANSLatitude", "FANSLongitude", "FANSPlaceBearingDistance",
                      "PlaceBearing", "FANSPlaceBearing", "DegreesMinutes", "LatitudeDegreesMinutes", "LongitudeDegreesMinutes",
                      "LatitudeDegreesMinutesSeconds", "LongitudeDegreesMinutesSeconds", "FANSLatitudeDegreesMinutes", "FANSLongitudeDegreesMinutes"]
        return atomic.contains(name)
    }

    // MARK: Werte

    static func format(_ value: ASN1Value, type typeName: String, schema: ASN1Schema) -> String {
        let resolved = schema.resolve(typeName)
        let name = resolved?.name ?? typeName
        switch value {
        case .null: return ""
        case .bool(let b): return b ? String(localized: "ja") : String(localized: "nein")
        case .int(let v): return unit(v, type: name)
        case .enumerated(let s): return enumText(s)
        case .string(let s): return s
        case .octets(let b): return b.map { String(format: "%02X", $0) }.joined()
        case .bits(let b, let n): return "\(n) Bit " + b.prefix(8).map { String(format: "%02X", $0) }.joined()
        case .oid(let b): return "OID " + b.map { String(format: "%02X", $0) }.joined()
        case .open(let b): return "\(b.count) Byte"
        case .list(let items):
            let et = resolved?.type.element ?? ""
            return items.map { format($0, type: et, schema: schema) }.joined(separator: ", ")
        case .choice(let chosen, let inner):
            let mt = resolved?.type.members?.first { $0.name == chosen }?.type ?? ""
            let text = format(inner, type: mt, schema: schema)
            if case .null = inner { return enumText(chosen) }
            return text
        case .sequence(let members):
            if let special = sequenceText(name, members, schema: schema) { return special }
            return members.map { m -> String in
                let mt = resolved?.type.members?.first { $0.name == m.0 }?.type ?? ""
                let text = format(m.1, type: mt, schema: schema)
                return text.isEmpty ? enumText(m.0) : "\(enumText(m.0)) \(text)"
            }.joined(separator: ", ")
        }
    }

    private static func field(_ members: [(String, ASN1Value)], _ name: String) -> ASN1Value? { members.first { $0.0 == name }?.1 }

    /// Bekannte Sequenzen kompakt: Zeit, Datum, Position.
    private static func sequenceText(_ name: String, _ members: [(String, ASN1Value)], schema: ASN1Schema) -> String? {
        switch name {
        case "Time", "FANSTime":
            if let h = field(members, "hours")?.intValue, let m = field(members, "minutes")?.intValue { return String(format: "%02d:%02d", h, m) }
        case "Timehhmmss", "FANSTimestamp":
            if let hm = field(members, "hoursminutes") ?? field(members, "time"), let h = hm["hours"]?.intValue, let m = hm["minutes"]?.intValue {
                let s = field(members, "seconds")?.intValue ?? 0
                return String(format: "%02d:%02d:%02d", h, m, s)
            }
            if let h = field(members, "hours")?.intValue, let m = field(members, "minutes")?.intValue {
                let s = field(members, "seconds")?.intValue ?? 0
                return String(format: "%02d:%02d:%02d", h, m, s)
            }
        case "Date":
            if let y = field(members, "year")?.intValue, let mo = field(members, "month")?.intValue, let d = field(members, "day")?.intValue {
                return String(format: "%02d.%02d.%04d", d, mo, y)
            }
        case "DateTimeGroup":
            if let d = field(members, "date"), let t = field(members, "timehhmmss") {
                let time = format(t, type: "Timehhmmss", schema: schema), day = format(d, type: "Date", schema: schema)
                return String(localized: "\(time) am \(day)")
            }
        case "LatitudeLongitude", "FANSLatitudeLongitude":
            let lat = field(members, "latitude").map { format($0, type: name.hasPrefix("FANS") ? "FANSLatitude" : "Latitude", schema: schema) } ?? "?"
            let lon = field(members, "longitude").map { format($0, type: name.hasPrefix("FANS") ? "FANSLongitude" : "Longitude", schema: schema) } ?? "?"
            return "\(lat) \(lon)"
        case "Latitude", "Longitude", "FANSLatitude", "FANSLongitude":
            let dir = field(members, "direction").flatMap { v -> String? in if case .enumerated(let s) = v { return s } else { return nil } } ?? ""
            let letter = ["north": "N", "south": "S", "east": "O", "west": "W"][dir] ?? dir
            if let t = field(members, "type") ?? field(members, "latitudeType") ?? field(members, "longitudeType") {
                return "\(angle(t, schema: schema)) \(letter)"
            }
            // FANS: Grad + Minuten direkt
            let deg = field(members, "latitudeDegrees")?.intValue ?? field(members, "longitudeDegrees")?.intValue
            let min = field(members, "minutesLatLon")?.intValue
            if let deg { return String(format: "%d°%@ %@", deg, min.map { String(format: "%04.1f'", Double($0) / 10) } ?? "", letter) }
        default: break
        }
        return nil
    }

    /// ATN-Winkel: degrees (×0,001°), degreesMinutes, degreesMinutesSeconds.
    private static func angle(_ value: ASN1Value, schema: ASN1Schema) -> String {
        guard case .choice(let kind, let inner) = value else { return format(value, type: "", schema: schema) }
        switch kind {
        case "latitudeDegrees", "longitudeDegrees":
            if let v = inner.intValue { return String(format: "%.3f°", Double(v) / 1000) }
        case "latitudeDegreesMinutes", "longitudeDegreesMinutes":
            let deg = inner["latitudeWholeDegrees"]?.intValue ?? inner["longitudeWholeDegrees"]?.intValue ?? 0
            let min = inner["minutesLatLon"]?.intValue ?? 0
            return String(format: "%d°%05.2f'", deg, Double(min) / 100)
        case "latitudeDMS", "longitudeDMS", "latitudeDegreesMinutesSeconds", "longitudeDegreesMinutesSeconds":
            let deg = inner["latitudeWholeDegrees"]?.intValue ?? inner["longitudeWholeDegrees"]?.intValue ?? 0
            let min = inner["latlonWholeMinutes"]?.intValue ?? inner["minutesLatLon"]?.intValue ?? 0
            let sec = inner["secondsLatLon"]?.intValue ?? 0
            return String(format: "%d°%02d'%02d\"", deg, min, sec)
        default: break
        }
        return format(value, type: "", schema: schema)
    }

    /// Einheiten nach Typname (Wertebereiche aus ICAO Doc 9880 / FANS-1/A).
    static func unit(_ v: Int, type: String) -> String {
        // Erweiterte Ganzzahlen können bis 2⁶³ reichen (Funkdaten) – Skalieren ohne Überlauf.
        func times(_ factor: Int) -> String {
            let (product, overflow) = v.multipliedReportingOverflow(by: factor)
            return overflow ? "\(v)×\(factor)" : "\(product)"
        }
        switch type {
        case "LevelFlightLevel", "FANSAltitudeFlightLevel": return "FL\(v)"
        case "LevelFeet", "FANSAltitudeQNH", "FANSAltitudeQFE": return "\(times(10)) ft"
        case "FANSAltitudeGNSSFeet": return "\(v) ft"
        case "LevelMeters", "FANSAltitudeQNHMeters", "FANSAltitudeQFEMeters", "FANSAltitudeGNSSMeters": return "\(v) m"
        case "LevelFlightLevelMetric", "FANSAltitudeFlightLevelMetric": return String(localized: "\(times(10)) m (metrisch)")
        case "Frequencyvhf": return String(format: "%.3f MHz", Double(v) * 0.005)
        case "FANSFrequencyvhf": return String(format: "%.3f MHz", Double(v) / 1000)
        case "Frequencyhf", "FANSFrequencyhf": return "\(v) kHz"
        case "Frequencyuhf": return String(format: "%.3f MHz", Double(v) * 0.025)
        case "FANSFrequencyuhf": return String(format: "%.3f MHz", Double(v) / 1000)
        case "SpeedIndicated", "SpeedGround", "SpeedTrue", "FANSSpeedTrue": return "\(v) kn"
        case "FANSSpeedIndicated", "FANSSpeedGround": return "\(times(10)) kn"
        case "SpeedIndicatedMetric", "SpeedGroundMetric", "SpeedTrueMetric": return "\(v) km/h"
        case "FANSSpeedIndicatedMetric", "FANSSpeedGroundMetric", "FANSSpeedTrueMetric": return "\(times(10)) km/h"
        case "SpeedMach": return String(format: "Mach %.3f", Double(v) / 1000)
        case "FANSSpeedMach": return String(format: "Mach %.2f", Double(v) / 100)
        case "DistanceNm", "FANSDistanceNm", "DistanceOffsetNm", "FANSDistanceOffsetNm": return "\(v) NM"
        case "DistanceKm", "FANSDistanceKm", "DistanceOffsetKm": return "\(v) km"
        case "DegreesMagnetic", "DegreesTrue", "FANSDegreesMagnetic", "FANSDegreesTrue": return "\(v)°"
        case "Temperature", "FANSTemperature": return "\(v) °C"
        case "VerticalRateEnglish", "FANSVerticalRateEnglish": return "\(times(100)) ft/min"
        case "VerticalRateMetric", "FANSVerticalRateMetric": return "\(times(10)) m/min"
        case "WindSpeedEnglish", "FANSWindSpeedEnglish": return "\(v) kn"
        case "WindSpeedMetric", "FANSWindSpeedMetric": return "\(v) km/h"
        case "LatitudeDegrees", "LongitudeDegrees": return String(format: "%.3f°", Double(v) / 1000)
        default: return "\(v)"
        }
    }

    /// camelCase-Bezeichner lesbarer machen („flightLevel“ → „flight level“).
    static func enumText(_ s: String) -> String {
        var out = ""
        for c in s {
            if c.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(c)
        }
        return out.lowercased()
    }
}
