import Foundation

/// ADS-C (FANS-1/A, ARINC 745/622) über ACARS: Label A6/AA (zum Flugzeug) und
/// B6/BA (vom Flugzeug), Text „/<Bodenstation>.ADS<Kennzeichen 7 Zeichen><Hex>“.
/// Der Hexteil ist eine Folge von Tags (1 Byte) mit festem Inhalt, am Ende ein
/// CRC-16 (2 Byte). Bitlayout nach ARINC 745 (wie libacars): Koordinaten 21 Bit
/// (MSB 90°), Höhe 16 Bit × 4 ft, Zeit 15 Bit × ⅛ s seit der vollen Stunde,
/// Kurs 12 Bit (MSB 90°), Geschwindigkeit 13 Bit × ½ kn, Steigrate 12 Bit × 16
/// ft/min, Wind 9 Bit × ½ kn / 9 Bit Richtung, Temperatur 12 Bit (MSB 256 °C).
enum ADSC {
    struct Report: Equatable, Sendable {
        var title: String
        var rows: [ACARSInterpretation.Row] = []
        var latitude: Double?
        var longitude: Double?
        var altitudeFt: Int?
        var groundStation: String?
        var registration: String?
    }

    /// Versucht, den Text als ARINC-622-Nachricht zu lesen. Ergebnis `nil`,
    /// wenn kein IMI gefunden wird. CPDLC (AT1/CR1/CC1/DR1) wird nur benannt.
    static func parse(_ text: String, isDownlink: Bool) -> Report? {
        let imis = [".ADS", ".DIS", ".AT1", ".CR1", ".CC1", ".DR1"]
        guard let (imi, range) = imis.lazy.compactMap({ imi in text.range(of: imi).map { (imi, $0) } }).first else { return nil }
        let head = text[..<range.lowerBound]
        let station = head.hasPrefix("/") ? String(head.dropFirst()) : (head.isEmpty ? nil : String(head))
        let after = text[range.upperBound...]
        guard after.count >= 7 else { return nil }
        let registration = String(after.prefix(7)).replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        let hex = String(after.dropFirst(7)).filter { !$0.isWhitespace }
        var bytes = Self.bytes(fromHex: hex)
        if bytes.count >= 2 { bytes.removeLast(2) }                       // CRC-16 (ARINC 622)
        var report = Report(title: "", groundStation: station, registration: registration)
        if let station { report.rows.append(.init(String(localized: "Bodenstation"), station)) }
        switch imi {
        case ".ADS":
            report.title = isDownlink ? String(localized: "ADS-C-Bericht") : String(localized: "ADS-C-Vertrag")
            if isDownlink { downlink(bytes, into: &report) } else { uplink(bytes, into: &report) }
        case ".DIS":
            report.title = String(localized: "ADS-C: Verbindung beendet")
            if let reason = bytes.first { report.rows.append(.init(String(localized: "Grund"), String(localized: "Code \(Int(reason))"))) }
        default:
            // FANS-1/A CPDLC: AT1 = Lotsenmeldung, CR1/CC1 = Verbindungsauf-/-abbau, DR1 = Abbau.
            if let schema = ASN1Schema.fans,
               let decoded = try? PERDecoder(schema: schema).decode(isDownlink ? "FANSATCDownlinkMessage" : "FANSATCUplinkMessage", bytes: bytes) {
                let message = CPDLCFormatter.fans(decoded, uplink: !isDownlink, schema: schema)
                report.title = "CPDLC (FANS, \(imi.dropFirst())) " + message.summary
                report.rows += message.rows
            } else {
                report.title = String(localized: "CPDLC (FANS-1/A, \(String(imi.dropFirst()))) – nicht lesbar")
                report.rows.append(.init(String(localized: "Umfang"), String(localized: "\(bytes.count) Byte")))
            }
        }
        return report
    }

    // MARK: Downlink-Tags

    private static func downlink(_ bytes: [UInt8], into r: inout Report) {
        var i = 0
        var parts: [String] = []
        while i < bytes.count {
            let tag = bytes[i]; i += 1
            let rest = Array(bytes[i...])
            var used = 0
            switch tag {
            case 3: parts.append(String(localized: "Bestätigung")); if let v = rest.first { r.rows.append(.init(String(localized: "Bestätigt"), String(localized: "Vertrag \(Int(v))"))); used = 1 }
            case 4: parts.append(String(localized: "Ablehnung")); used = min(2, rest.count); if used > 0 { r.rows.append(.init(String(localized: "Abgelehnt"), String(localized: "Vertrag \(Int(rest[0])), Grund \(Int(used > 1 ? rest[1] >> 4 : 0))"))) }
            case 5: parts.append(String(localized: "Nichterfüllung")); used = min(rest.count, 2)
            case 6: parts.append(String(localized: "Notfallmodus beendet"))
            case 7, 9, 10, 18, 19, 20:
                let names: [UInt8: String] = [7: String(localized: "Positionsbericht"), 9: String(localized: "NOTFALL-Positionsbericht"), 10: String(localized: "Seitliche Abweichung"),
                                              18: String(localized: "Änderung der Steigrate"), 19: String(localized: "Höhenbereich verlassen"), 20: String(localized: "Wegpunktwechsel")]
                parts.append(names[tag]!)
                guard rest.count >= 10 else { return }
                var bits = BitReader(Array(rest[0..<10]))
                let lat = coordinate(bits.read(21)), lon = coordinate(bits.read(21))
                let alt = altitude(bits.read(16)), t = Double(bits.read(15)) * 0.125
                let fom = bits.read(7)
                r.latitude = lat; r.longitude = lon; r.altitudeFt = alt
                r.rows.append(.init(String(localized: "Position"), ACARSInterpreter.coordinates(lat, lon)))
                r.rows.append(.init(String(localized: "Höhe"), "\(alt) ft (≈ \(Int(Double(alt) * 0.3048)) m)"))
                r.rows.append(.init(String(localized: "Zeit"), String(format: String(localized: "%02d:%02d,%03d nach der vollen Stunde"), Int(t) / 60, Int(t) % 60, Int(t.truncatingRemainder(dividingBy: 1) * 1000))))
                r.rows.append(.init(String(localized: "Güte"), String(localized: "Genauigkeit \(Int((fom >> 1) & 7)), TCAS \(fom & 0x10 != 0 ? String(localized: "ok") : String(localized: "gestört")), \(fom & 1 != 0 ? String(localized: "redundant") : String(localized: "einfach"))")))
                used = 10
            case 12:
                guard rest.count >= 6 else { return }
                var bits = BitReader(Array(rest[0..<6]))
                let id = String((0..<8).map { _ -> Character in
                    let v = bits.read(6)
                    return Character(Unicode.Scalar(UInt8(v < 0x20 ? v | 0x40 : v)))
                }).trimmingCharacters(in: .whitespaces)
                r.rows.append(.init(String(localized: "Flugnummer"), id)); parts.append(String(localized: "Flug \(id)"))
                used = 6
            case 13:
                guard rest.count >= 17 else { return }
                var bits = BitReader(Array(rest[0..<17]))
                let lat1 = coordinate(bits.read(21)), lon1 = coordinate(bits.read(21)), alt1 = altitude(bits.read(16)), eta = bits.read(14)
                let lat2 = coordinate(bits.read(21)), lon2 = coordinate(bits.read(21)), alt2 = altitude(bits.read(16))
                r.rows.append(.init(String(localized: "Nächster Wegpunkt"), String(localized: "\(ACARSInterpreter.coordinates(lat1, lon1)), \(alt1) ft, in \(eta / 60) min \(eta % 60) s")))
                r.rows.append(.init(String(localized: "Übernächster"), "\(ACARSInterpreter.coordinates(lat2, lon2)), \(alt2) ft"))
                parts.append(String(localized: "Vorhersage"))
                used = 17
            case 14, 15:
                guard rest.count >= 5 else { return }
                var bits = BitReader(Array(rest[0..<5]))
                let invalid = bits.read(1) == 1
                let hdg = heading(bits.read(12)), spd = Double(bits.read(13)) / 2, vs = verticalSpeed(bits.read(12))
                let what = tag == 14 ? String(localized: "Über Grund") : String(localized: "In der Luft")
                r.rows.append(.init(what, String(format: String(localized: "%@ %.0f°, %.0f kn, %+d ft/min"), tag == 14 ? String(localized: "Kurs") : String(localized: "Steuerkurs"), hdg, spd, vs) + (invalid ? String(localized: " (Kurs ungültig)") : "")))
                used = 5
            case 16:
                guard rest.count >= 4 else { return }
                var bits = BitReader(Array(rest[0..<4]))
                let ws = Double(bits.read(9)) / 2
                let invalid = bits.read(1) == 1
                let wd = windDirection(bits.read(9)), temp = temperature(bits.read(12))
                r.rows.append(.init(String(localized: "Wetter"), String(format: String(localized: "Wind %.0f° / %.0f kn%@, Temperatur %.1f °C"), wd, ws, invalid ? String(localized: " (Richtung ungültig)") : "", temp)))
                used = 4
            case 17:
                guard rest.count >= 3 else { return }
                r.rows.append(.init(String(localized: "ICAO-Adresse"), String(format: "%02X%02X%02X", rest[0], rest[1], rest[2])))
                used = 3
            case 22:
                guard rest.count >= 8 else { return }
                var bits = BitReader(Array(rest[0..<8]))
                let dist = Double(bits.read(16)) / 8
                _ = bits.read(1)
                let trk = heading(bits.read(12)), alt = altitude(bits.read(16)), eta = bits.read(14)
                r.rows.append(.init(String(localized: "Projektion"), String(format: String(localized: "in %.1f NM: Kurs %.0f°, %d ft, in %d min"), dist, trk, alt, eta / 60)))
                used = 8
            case 23:
                guard rest.count >= 9 else { return }
                var bits = BitReader(Array(rest[0..<9]))
                let lat = coordinate(bits.read(21)), lon = coordinate(bits.read(21)), alt = altitude(bits.read(16)), eta = bits.read(14)
                r.rows.append(.init(String(localized: "Feste Projektion"), String(localized: "\(ACARSInterpreter.coordinates(lat, lon)), \(alt) ft, in \(eta / 60) min")))
                used = 9
            default:
                r.rows.append(.init(String(localized: "Unbekanntes Tag"), String(localized: "\(Int(tag)), \(rest.count) Byte")))
                return
            }
            i += used
        }
        if !parts.isEmpty { r.title += ": " + parts.joined(separator: ", ") }
    }

    private static func uplink(_ bytes: [UInt8], into r: inout Report) {
        var i = 0
        var parts: [String] = []
        while i < bytes.count {
            let tag = bytes[i]; i += 1
            switch tag {
            case 1: parts.append(String(localized: "alle Verträge kündigen"))
            case 2: parts.append(String(localized: "Vertrag kündigen")); i += 1
            case 6: parts.append(String(localized: "Notfallmodus beenden"))
            case 7, 9:
                parts.append(tag == 7 ? String(localized: "periodischer Vertrag") : String(localized: "Notfall-Periodenvertrag"))
                guard i + 1 < bytes.count else { break }
                let number = bytes[i], interval = bytes[i + 1]
                r.rows.append(.init(String(localized: "Vertrag"), String(localized: "Nr. \(Int(number)), alle \(Int(interval) * 64 / 64 == 0 ? 1 : Int(interval)) × 64 s")))
                i += 2
                // Angeforderte Gruppen folgen als weitere Tags mit Modifikatoren – nur zählen.
                parts.append(String(localized: "\(bytes.count - i) Byte Anforderungen"))
                i = bytes.count
            case 8:
                parts.append(String(localized: "Ereignisvertrag"))
                i = bytes.count
            default:
                parts.append("Tag \(tag)")
                i = bytes.count
            }
        }
        if !parts.isEmpty { r.title += ": " + parts.joined(separator: ", ") }
    }

    // MARK: Umrechnung

    struct BitReader {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                let byte = position / 8
                let bit = byte < bytes.count ? (bytes[byte] >> (7 - UInt8(position % 8))) & 1 : 0
                value = value << 1 | Int(bit)
                position += 1
            }
            return value
        }
    }

    static func signed(_ value: Int, bits: Int) -> Int {
        value & (1 << (bits - 1)) != 0 ? value - (1 << bits) : value
    }
    static func coordinate(_ v: Int) -> Double { Double(signed(v, bits: 21)) * (180 - 90 / 524_288) / 1_048_575 }
    static func altitude(_ v: Int) -> Int { signed(v, bits: 16) * 4 }
    static func verticalSpeed(_ v: Int) -> Int { signed(v, bits: 12) * 16 }
    static func heading(_ v: Int) -> Double {
        let r = Double(signed(v, bits: 12)) * (180 - 90 / 1024) / 2047
        return r < 0 ? r + 360 : r
    }
    static func windDirection(_ v: Int) -> Double {
        let r = Double(signed(v, bits: 9)) * (180 - 90 / 128) / 255
        return r < 0 ? r + 360 : r
    }
    static func temperature(_ v: Int) -> Double { Double(signed(v, bits: 12)) * (512 - 256 / 1024) / 2047 }

    static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var pending: UInt8?
        for c in hex.uppercased() {
            guard let v = c.hexDigitValue else { break }
            if let high = pending { out.append(high << 4 | UInt8(v)); pending = nil } else { pending = UInt8(v) }
        }
        return out
    }
}
