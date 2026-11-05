import Foundation

/// Deutung einer ACARS-Nachricht in Klartext: Was ist es, und welche Felder
/// lassen sich lesen? Vieles ist airline-eigen und undokumentiert; dann
/// bleibt nur der Rohtext. Sicher sind die Standardformate (Media Advisory,
/// OOOI, FMS-Meldungen mit Schlüssel/Wert, ACMS-Kopf mit Abflug/Ziel) und
/// erkennbare Muster (Positionen, Flugflächen, Zeiten).
struct ACARSInterpretation: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let name: String
        let value: String
        init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }
    /// Kurzform für die Tabelle („Positionsmeldung 53,8° N 9,9° O FL350“).
    var summary: String
    var rows: [Row] = []
    var latitude: Double?
    var longitude: Double?
    var altitudeFt: Int?
    /// Der Rohtext ist Airline-Binärkram (Base64 o. Ä.), eine Deutung nicht möglich.
    var opaque = false
}

extension ACARSMessage {
    /// Rang für „Wichtige zuerst“ (kleiner = weiter oben): 0 Lotsenverkehr und
    /// Positionen, 1 lesbare Inhalte, 2 Airline-Binärkram, 3 Netzverwaltung
    /// (ATN-Routing/Transport, Verbindungstest, Squitter, leere Quittungen) –
    /// live 27.10.2026 machten IDRP-Keepalives drei Viertel der VDL2-Zeilen aus.
    var relevance: Int {
        switch label {
        case "CPDLC", "CM", "B6": return 0
        case "ATN", "Q0", "SQ", "_d": return 3
        default: break
        }
        let interpretation = self.interpretation      // aus dem Zwischenspeicher, wenn `interpret()` lief
        if interpretation.latitude != nil { return 0 }
        if text.isEmpty && interpretation.summary.isEmpty { return 3 }
        return interpretation.opaque ? 2 : 1
    }
}

/// METAR/TAF aus dem Freitext von Wettermeldungen (WMO FM 15/51, nur die
/// Grundgruppen): Station, Zeit, Wind, Sicht, Wolken, Temperatur/Taupunkt, QNH.
enum ACARSWeather {
    struct Report: Equatable {
        var summary: String
        var rows: [ACARSInterpretation.Row]
    }

    static func metar(in text: String) -> Report? {
        guard let match = text.firstMatch(of: /(?:METAR|SPECI)\s+(?:COR\s+)?([A-Z]{4})\s+(\d{2})(\d{2})(\d{2})Z\s+([^=\n]*)/) else { return nil }
        let station = String(match.1)
        let groups = match.5.split(separator: " ").map(String.init)
        var rows: [ACARSInterpretation.Row] = [.init(String(localized: "Wetter von"), station),
                                               .init(String(localized: "Beobachtet"), "\(match.2). \(match.3):\(match.4) UTC")]
        var parts: [String] = []
        for g in groups {
            if let w = g.wholeMatch(of: /(\d{3}|VRB)(\d{2,3})(?:G(\d{2,3}))?(KT|MPS)/) {
                let factor = w.4 == "MPS" ? 3.6 : 1.852
                let speed = (Double(w.2) ?? 0) * factor
                var text = w.1 == "VRB" ? String(format: String(localized: "Wind %.0f km/h wechselnd"), speed)
                    : String(format: String(localized: "Wind %.0f km/h aus %@°"), speed, String(w.1))
                if let gust = w.3.flatMap({ Double($0) }) { text += String(format: String(localized: ", Böen %.0f km/h"), gust * factor) }
                rows.append(.init(String(localized: "Wind"), text)); parts.append(text)
            } else if g == "CAVOK" {
                rows.append(.init(String(localized: "Sicht"), String(localized: "über 10 km, keine Wolken unter 1500 m")))
                parts.append("CAVOK")
            } else if let v = g.wholeMatch(of: /(\d{4})/), let meters = Int(v.1) {
                let text = meters >= 9999 ? String(localized: "über 10 km") : "\(meters) m"
                rows.append(.init(String(localized: "Sicht"), text))
            } else if let c = g.wholeMatch(of: /(FEW|SCT|BKN|OVC|VV)(\d{3})(CB|TCU)?/), let hundreds = Int(c.2) {
                let names = ["FEW": String(localized: "wenige"), "SCT": String(localized: "aufgelockert"), "BKN": String(localized: "durchbrochen"),
                             "OVC": String(localized: "bedeckt"), "VV": String(localized: "Vertikalsicht")]
                let text = "\(names[String(c.1)] ?? String(c.1)) \(Int((Double(hundreds) * 30.48).rounded())) m" + (c.3.map { " \($0)" } ?? "")
                rows.append(.init(String(localized: "Wolken"), text))
            } else if let t = g.wholeMatch(of: /(M?)(\d{2})\/(M?)(\d{2})/), let temp = Int(t.2), let dew = Int(t.4) {
                let celsius = t.1 == "M" ? -temp : temp, dewPoint = t.3 == "M" ? -dew : dew
                rows.append(.init(String(localized: "Temperatur"), String(localized: "\(celsius) °C, Taupunkt \(dewPoint) °C")))
                parts.append("\(celsius) °C")
            } else if let q = g.wholeMatch(of: /Q(\d{4})/), let hPa = Int(q.1) {
                rows.append(.init("QNH", "\(hPa) hPa")); parts.append("QNH \(hPa)")
            } else if let a = g.wholeMatch(of: /A(\d{4})/), let inches = Double(a.1) {
                let hPa = Int((inches / 100 * 33.8639).rounded())
                rows.append(.init("QNH", "\(hPa) hPa")); parts.append("QNH \(hPa)")
            }
        }
        return Report(summary: String(localized: "Wetter \(station): ") + parts.joined(separator: ", "), rows: rows)
    }

    /// TAF-Kopf: Station und Gültigkeit („TAF EDDH 041100Z 0412/0518 …“).
    static func taf(in text: String) -> String? {
        guard let match = text.firstMatch(of: /TAF\s+(?:AMD\s+|COR\s+)?([A-Z]{4})\s+\d{6}Z\s+(\d{2})(\d{2})\/(\d{2})(\d{2})/) else { return nil }
        return String(localized: "Vorhersage \(String(match.1)) vom \(String(match.2)). \(String(match.3)) Uhr bis \(String(match.4)). \(String(match.5)) Uhr UTC")
    }
}

enum ACARSInterpreter {
    static func interpret(_ m: ACARSMessage) -> ACARSInterpretation {
        var r = ACARSInterpretation(summary: "")
        let text = m.text
        switch m.label {
        case "SA": mediaAdvisory(text, into: &r)
        case "Q0": r.summary = String(localized: "Verbindungstest")
        case "_d": r.summary = String(localized: "Quittung ohne Inhalt")
        case "SQ": squitter(text, into: &r)
        case "QA", "QB", "QC", "QD", "QE", "QF", "QG", "QH", "QK", "QL", "QM", "QN", "QP", "QQ", "QR", "QS", "QT":
            oooi(m, into: &r)
        case "XID": r.summary = text
        case "H1": h1(m, into: &r)
        case "A6", "AA", "B6", "BA": arinc622(m, into: &r)
        case "ATN": atn(text, into: &r)
        case "CPDLC", "CM":
            r.summary = text
            r.rows = m.details.filter { $0.count == 2 }.map { .init($0[0], $0[1]) }
        default: break
        }
        if r.summary.isEmpty, m.label == "H1", m.text.contains(".ADS") || m.text.contains(".AT1") || m.text.contains(".CR1")
            || m.text.contains(".CC1") || m.text.contains(".DR1") || m.text.contains(".DIS") {
            arinc622(m, into: &r)
        }
        // Wetter (Labels 30/51/52/54 und Antworten auf Wetteranfragen): METAR/TAF im Text.
        if r.summary.isEmpty, let weather = ACARSWeather.metar(in: text) {
            r.summary = weather.summary
            r.rows += weather.rows
        }
        if r.summary.isEmpty, let taf = ACARSWeather.taf(in: text) {
            r.summary = taf
        }
        if r.summary.isEmpty { generic(m, into: &r) }
        // Der Squitter nennt die Lage der Bodenstation – keine Flugzeugposition.
        if r.latitude == nil, m.label != "SQ", let pos = position(in: text) {
            r.latitude = pos.lat; r.longitude = pos.lon
            r.rows.append(.init(String(localized: "Position"), Self.coordinates(pos.lat, pos.lon)))
        }
        if r.altitudeFt == nil, let fl = flightLevel(in: text) {
            r.altitudeFt = fl * 100
            r.rows.append(.init(String(localized: "Flugfläche"), "FL\(fl) (≈ \(Int(Double(fl) * 30.48)) m)"))
        }
        if let lat = r.latitude, let lon = r.longitude, !r.summary.contains("°") {
            r.summary += " · " + Self.coordinates(lat, lon)
        }
        if r.summary.hasPrefix(" · ") { r.summary.removeFirst(3) }
        return r
    }

    // MARK: Standardformate

    /// „0EV205802V/…“: Version 0, E = hergestellt / L = verloren, Verbindung
    /// (V = VDL2, S = Satcom, H = HF, G = Boden/Gatelink, C = Cellular …),
    /// Uhrzeit, danach die verfügbaren Verbindungen.
    private static func mediaAdvisory(_ text: String, into r: inout ACARSInterpretation) {
        let links: [Character: String] = ["V": "VDL2", "S": String(localized: "Satcom"), "H": String(localized: "Kurzwelle"), "G": String(localized: "Gatelink"), "C": String(localized: "Mobilfunk"),
                                          "2": String(localized: "VDL2 (alt)"), "X": String(localized: "Inmarsat"), "I": String(localized: "Iridium")]
        let t = Array(text)
        guard t.count >= 10, t[0] == "0", t[1] == "E" || t[1] == "L", let link = links[t[2]],
              t[3...8].allSatisfy(\.isNumber) else { r.summary = String(localized: "Datenlink-Status"); return }
        let time = "\(String(t[3...4])):\(String(t[5...6])):\(String(t[7...8])) UTC"
        let state = t[1] == "E" ? String(localized: "hergestellt") : String(localized: "verloren")
        var available: [String] = []
        var i = 9
        while i < t.count, t[i] != "/" { if let l = links[t[i]] { available.append(l) }; i += 1 }
        r.summary = String(localized: "Datenlink \(link) \(state) um \(time)")
        r.rows = [.init(String(localized: "Verbindung"), "\(link) \(state)"), .init(String(localized: "Zeit"), time)]
        if !available.isEmpty { r.rows.append(.init(String(localized: "Verfügbar"), available.joined(separator: ", "))) }
        if i + 1 < t.count { r.rows.append(.init(String(localized: "Zusatz"), String(t[(i + 1)...]))) }
    }

    /// ARINC 622 (FANS-1/A): ADS-C wird gelesen, CPDLC nur benannt.
    private static func arinc622(_ m: ACARSMessage, into r: inout ACARSInterpretation) {
        guard let report = ADSC.parse(m.text, isDownlink: m.isDownlink) else {
            r.summary = m.labelMeaning ?? String(localized: "ATS-Nachricht"); r.opaque = true; return
        }
        r.summary = report.title
        r.rows = report.rows
        r.latitude = report.latitude; r.longitude = report.longitude; r.altitudeFt = report.altitudeFt
        r.opaque = report.title.contains("nicht entschlüsselt")
    }

    /// Zeilen „ATN“ (X.25 über VDL2): der Text ist schon die Einordnung.
    private static func atn(_ text: String, into r: inout ACARSInterpretation) {
        r.summary = text
        r.opaque = text.contains("nicht entschlüsselt")
    }

    /// Bodenstations-Squitter „02XSEDDHAHDL…“: Version, Dienst (S = SITA,
    /// A = ARINC), Station (ICAO-Code); danach meist die Lage der Station
    /// („5333N00959E“, Grad und Minuten) und die Frequenz („136975“).
    private static func squitter(_ text: String, into r: inout ACARSInterpretation) {
        r.summary = String(localized: "Squitter der Bodenstation")
        guard text.count >= 8 else { return }
        let t = Array(text)
        r.rows.append(.init(String(localized: "Station"), String(t[4...7])))
        switch t[3] {
        case "S": r.rows.append(.init(String(localized: "Netz"), "SITA"))
        case "A": r.rows.append(.init(String(localized: "Netz"), "ARINC"))
        default: break
        }
        if let match = text.firstMatch(of: /(\d{2})(\d{2})([NS])(\d{3})(\d{2})([EW])/),
           let latD = Double(match.1), let latM = Double(match.2), let lonD = Double(match.4), let lonM = Double(match.5),
           latM < 60, lonM < 60 {
            let lat = (latD + latM / 60) * (match.3 == "S" ? -1 : 1)
            let lon = (lonD + lonM / 60) * (match.6 == "W" ? -1 : 1)
            if abs(lat) <= 90, abs(lon) <= 180 {
                r.rows.append(.init(String(localized: "Lage der Station"), Self.coordinates(lat, lon)))
            }
        }
        if let match = text.firstMatch(of: /1(1[89]|2\d|3[0-6])(\d{3})/), let khz = Double(match.0) {
            r.rows.append(.init(String(localized: "Frequenz"), String(format: "%.3f MHz", khz / 1000)))
        }
    }

    /// OOOI (Out/Off/On/In) – Formate sind airline-eigen; Zeiten und Flughäfen
    /// sind meist erkennbar.
    private static func oooi(_ m: ACARSMessage, into r: inout ACARSInterpretation) {
        let names = ["QA": String(localized: "Gate verlassen (OUT)"), "QB": String(localized: "Abgehoben (OFF)"), "QC": String(localized: "Gelandet (ON)"),
                     "QD": String(localized: "Am Gate (IN)"), "QE": String(localized: "OUT mit Kraftstoff"), "QF": String(localized: "OFF mit Kraftstoff"),
                     "QG": String(localized: "OUT und Rückkehr zum Gate"), "QH": String(localized: "Gate verlassen (OUT)"),
                     "QK": String(localized: "Landemeldung"), "QL": String(localized: "Ankunftsmeldung"), "QM": String(localized: "Ankunftsinformation"),
                     "QN": String(localized: "Ausweichflughafen"), "QP": String(localized: "Gate verlassen (OUT)"), "QQ": String(localized: "Abgehoben (OFF)"),
                     "QR": String(localized: "Gelandet (ON)"), "QS": String(localized: "Am Gate (IN)"), "QT": String(localized: "OUT und Rückkehr zum Gate")]
        r.summary = names[m.label] ?? "OOOI"
        let airports = icaoAirports(in: m.text)
        if !airports.isEmpty { r.rows.append(.init(String(localized: "Flughäfen"), airports.joined(separator: " → "))) }
        if let t = times(in: m.text).first { r.rows.append(.init(String(localized: "Zeit"), t)) }
    }

    /// Label H1: Unterkennung, dann meist Felder mit „/“ und Zwei-Buchstaben-Schlüsseln.
    private static func h1(_ m: ACARSMessage, into r: inout ACARSInterpretation) {
        guard let sub = m.sublabel else { generic(m, into: &r); return }
        let subName = ACARSMessage.sublabelNames[sub] ?? String(localized: "Unterkennung \(sub)")
        var body = m.isDownlink ? String(m.text.dropFirst(4)) : String(m.text.dropFirst(5))
        if body.count >= 4, body.first == "/", Array(body)[3] == " " { body.removeFirst(4) }   // MFI
        if body.hasPrefix("/") { body.removeFirst() }
        let fields = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch sub {
        case "M1", "MD":
            fms(fields, into: &r)
            if r.summary.isEmpty { r.summary = subName }
        case "DF":
            acms(fields, into: &r)
            r.summary = r.summary.isEmpty ? String(localized: "ACMS-Bericht") : r.summary
        case "CF":
            r.summary = String(localized: "Wartungsrechner (CMC)")
            cmc(fields, into: &r)
        case "T1", "T2":
            r.summary = String(localized: "Wartung/Technik (Binärdaten)")
            r.opaque = looksOpaque(body)
        default:
            r.summary = subName
            r.opaque = looksOpaque(body)
        }
        r.rows.insert(.init(String(localized: "Unterkennung"), "\(sub) – \(subName)"), at: 0)
    }

    /// FMS-Meldungen (Honeywell/Airbus-Stil): erster Block = Art, danach
    /// Felder „XXwert“. Bekannte Schlüssel übersetzt, Rest als Rohfeld.
    private static func fms(_ fields: [String], into r: inout ACARSInterpretation) {
        let kinds = ["PRG": String(localized: "Fortschrittsmeldung"), "POS": String(localized: "Positionsmeldung"), "FPN": String(localized: "Flugplan/Route"),
                     "PWI": String(localized: "Windvorhersage-Anforderung"), "FTX": String(localized: "Freitext"), "RTE": String(localized: "Route"), "WX": String(localized: "Wetteranforderung"),
                     "TOD": String(localized: "Startdaten"), "LDG": String(localized: "Landedaten"), "PER": String(localized: "Leistungsdaten"), "REQ": String(localized: "Anforderung"),
                     "INI": String(localized: "Initialisierung"), "ACK": String(localized: "Bestätigung")]
        let keys = ["DT": String(localized: "Ziel"), "FN": String(localized: "Flugnummer"), "TS": String(localized: "Zeitstempel"), "PS": String(localized: "Position"), "DP": String(localized: "Abflug"),
                    "DS": String(localized: "Ziel"), "AC": String(localized: "Flugzeug"), "ET": String(localized: "Ankunft (geschätzt)"), "FL": String(localized: "Flugfläche"), "WX": String(localized: "Wetter"),
                    "WD": String(localized: "Wind"), "WS": String(localized: "Wind"), "SA": String(localized: "Außentemperatur"), "SP": String(localized: "Geschwindigkeit"), "TA": String(localized: "Lufttemperatur"),
                    "RP": String(localized: "Route"), "ID": String(localized: "Kennung"), "AT": String(localized: "Zeit"), "FB": String(localized: "Kraftstoff"), "FR": String(localized: "Restkraftstoff"),
                    "VS": String(localized: "Steig-/Sinkrate"), "HD": String(localized: "Steuerkurs"), "GS": String(localized: "Grundgeschwindigkeit"), "MA": String(localized: "Mach")]
        var first = true
        for field in fields where !field.isEmpty {
            if first {
                first = false
                let kind = String(field.prefix(3))
                if let name = kinds[kind] {
                    r.summary = name
                    let rest = String(field.dropFirst(3))
                    if !rest.isEmpty { r.rows.append(.init(String(localized: "Angabe"), rest)) }
                    continue
                }
            }
            let key = String(field.prefix(2)), value = String(field.dropFirst(2))
            guard key.count == 2, key.allSatisfy({ $0.isUppercase || $0.isNumber }), !value.isEmpty else {
                r.rows.append(.init(String(localized: "Feld"), field)); continue
            }
            switch key {
            case "DT", "DS", "DP":
                let parts = value.split(separator: ",").map(String.init)
                var shown = parts.first ?? value
                if parts.count > 3, parts[3].count == 6, parts[3].allSatisfy(\.isNumber) { shown += " · \(hhmmss(parts[3]))" }
                r.rows.append(.init(keys[key]!, shown))
            case "TS":
                let parts = value.split(separator: ",").map(String.init)
                var shown = parts.first.map(hhmmss) ?? value
                if parts.count > 1, parts[1].count >= 6 { shown += " am \(ddmmyy(String(parts[1].prefix(6))))" }
                r.rows.append(.init(String(localized: "Zeitstempel"), shown))
            case "PS":
                if let pos = position(in: value) {
                    r.latitude = pos.lat; r.longitude = pos.lon
                    r.rows.append(.init(String(localized: "Position"), coordinates(pos.lat, pos.lon)))
                } else { r.rows.append(.init(String(localized: "Position"), value)) }
            default:
                r.rows.append(.init(keys[key] ?? String(localized: "Feld \(key)"), value))
            }
        }
    }

    /// ACMS-Berichte („#DFB…“): „REPnnn“ und ein Block
    /// „CC<Kennzeichen>,<Datum>,<Zeit>,<Abflug>,<Ziel>“ sind verbreitet.
    private static func acms(_ fields: [String], into r: inout ACARSInterpretation) {
        for field in fields {
            if field.hasPrefix("REP"), field.count >= 6 {
                r.summary = String(localized: "ACMS-Bericht \(String(field.prefix(6)))")
            } else if field.hasPrefix("CC") {
                let parts = field.dropFirst(2).split(separator: ",").map(String.init)
                if parts.count >= 5 {
                    r.rows.append(.init(String(localized: "Flugzeug"), parts[0]))
                    r.rows.append(.init(String(localized: "Zeit"), "\(parts[1]) \(hhmmss(parts[2])) UTC"))
                    r.rows.append(.init(String(localized: "Strecke"), "\(parts[3]) → \(parts[4])"))
                    r.summary += " · \(parts[3]) → \(parts[4])"
                }
            } else if let first = field.first, first.isUppercase, field.count > 2,
                      field.dropFirst().first?.isNumber == true || field.hasPrefix("A3") {
                // Flugzeugtyp wie „A321,111415,1,1,TB000000“ zu Beginn
                let parts = field.split(separator: ",").map(String.init)
                if parts.count >= 2, parts[0].count <= 4, r.rows.isEmpty { r.rows.append(.init("Typ", parts[0])) }
            }
        }
        if r.summary.isEmpty { r.summary = String(localized: "ACMS-Bericht") }
        r.rows.append(.init(String(localized: "Inhalt"), String(localized: "Messwerte der Flugdatenerfassung (eigenes Format der Fluggesellschaft)")))
    }

    private static func cmc(_ fields: [String], into r: inout ACARSInterpretation) {
        for field in fields.prefix(3) where !field.isEmpty { r.rows.append(.init(String(localized: "Feld"), field)) }
    }

    /// Alles ohne bekanntes Format: Freitext, wenn lesbar; sonst „Binärdaten“.
    private static func generic(_ m: ACARSMessage, into r: inout ACARSInterpretation) {
        if m.text.isEmpty { r.summary = m.labelMeaning ?? String(localized: "ohne Text"); return }
        if looksOpaque(m.text) { r.summary = String(localized: "Binärdaten (airline-eigen)"); r.opaque = true; return }
        if let eta = etaTime(in: m.text) { r.summary = "ETA \(eta)"; r.rows.append(.init(String(localized: "Ankunft (geschätzt)"), eta)) }
        else { r.summary = m.labelMeaning ?? String(localized: "Freitext") }
        let airports = icaoAirports(in: m.text)
        if airports.count >= 2 { r.rows.append(.init(String(localized: "Flughäfen"), airports.joined(separator: " → "))) }
        // Positionsmeldungen „214459,38000,2250, 113,N 54.376 E 10.330“: Zeit, Höhe in Fuß.
        if ["10", "15", "16", "20", "21", "22", "23"].contains(m.label) {
            let fields = m.text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let t = fields.first, t.count == 6, t.allSatisfy(\.isNumber) { r.rows.append(.init(String(localized: "Zeit"), hhmmss(t) + " UTC")) }
            if let alt = fields.dropFirst().first(where: { $0.count == 5 && $0.allSatisfy(\.isNumber) }).flatMap({ Int($0) }), (1000...50000).contains(alt) {
                r.altitudeFt = alt
                r.rows.append(.init(String(localized: "Höhe"), "\(alt) ft (≈ \(Int(Double(alt) * 0.3048)) m)"))
            }
        }
    }

    // MARK: Muster

    /// Base64-/Binärfolgen: lange Wörter ohne Leerzeichen mit Klein- und
    /// Großbuchstaben, Ziffern, „+“ und „/“ gemischt.
    static func looksOpaque(_ text: String) -> Bool {
        let body = text.filter { !$0.isWhitespace }
        guard body.count >= 24 else { return false }
        let lower = body.filter(\.isLowercase).count, upper = body.filter(\.isUppercase).count
        let digits = body.filter(\.isNumber).count
        return lower > body.count / 6 && upper > body.count / 6 && digits > body.count / 10 && !text.contains(" ")
    }

    /// Positionen: „N53.80015 E009.850396“, „N5348.0E00951.0“, „53.80N 9.85E“,
    /// „N53123E009456“ (Grad + Minuten·10), auch mit Komma oder Leerzeichen.
    /// Muster einmal übersetzt (Review 05.11.2026, U1: vorher je Aufruf neu).
    private static let positionPatterns: [NSRegularExpression] = [
        #"([NS])\s?(\d{1,2}\.\d+)[,\s]?([EW])\s?(\d{1,3}\.\d+)"#,                   // dezimal
        #"([NS])(\d{2})(\d{2}\.\d+)[,\s]?([EW])(\d{3})(\d{2}\.\d+)"#,              // Grad + Minuten dezimal
        #"([NS])(\d{2})(\d{3})[,\s]?([EW])(\d{3})(\d{3})"#,                        // Grad + Minuten·10
        #"(\d{1,2}\.\d+)([NS])[,\s]?(\d{1,3}\.\d+)([EW])"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let flightLevelPattern = try? NSRegularExpression(pattern: #"\bFL(\d{3})\b"#)
    private static let airportPattern = try? NSRegularExpression(pattern: #"\b([EL][A-Z]{3}|K[A-Z]{3}|[BCDFGHMNOPRSTUVWYZ][A-Z]{3})\b"#)
    private static let timePattern = try? NSRegularExpression(pattern: #"\b([01]\d|2[0-3])([0-5]\d)([0-5]\d)?\b"#)
    private static let etaPattern = try? NSRegularExpression(pattern: #"ETA.{0,8}?(\d{4})(?!\d)"#)

    static func position(in text: String) -> (lat: Double, lon: Double)? {
        for (index, re) in positionPatterns.enumerated() {
            guard let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func g(_ i: Int) -> String { Range(match.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            var lat = 0.0, lon = 0.0, hemiLat = "N", hemiLon = "E"
            switch index {
            case 0: hemiLat = g(1); lat = Double(g(2)) ?? 0; hemiLon = g(3); lon = Double(g(4)) ?? 0
            case 1: hemiLat = g(1); lat = (Double(g(2)) ?? 0) + (Double(g(3)) ?? 0) / 60; hemiLon = g(4); lon = (Double(g(5)) ?? 0) + (Double(g(6)) ?? 0) / 60
            case 2: hemiLat = g(1); lat = (Double(g(2)) ?? 0) + (Double(g(3)) ?? 0) / 600; hemiLon = g(4); lon = (Double(g(5)) ?? 0) + (Double(g(6)) ?? 0) / 600
            default: lat = Double(g(1)) ?? 0; hemiLat = g(2); lon = Double(g(3)) ?? 0; hemiLon = g(4)
            }
            guard lat <= 90, lon <= 180 else { continue }
            return (hemiLat == "S" ? -lat : lat, hemiLon == "W" ? -lon : lon)
        }
        return nil
    }

    static func flightLevel(in text: String) -> Int? {
        guard let re = flightLevelPattern,
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// ICAO-Flughafencodes (vier Großbuchstaben, erster Buchstabe einer Region).
    static func icaoAirports(in text: String) -> [String] {
        guard let re = airportPattern else { return [] }
        var found: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) {
                let code = String(text[r])
                // Nur Codes, die wie Flughäfen aussehen (Region E/L/K/U… + Buchstaben, keine Wörter).
                if "ELKUOVWZRSNFGHMBDPTYC".contains(code.first!), !["NAK", "ETX", "ETB", "FROM", "DATA", "NONE"].contains(code),
                   !found.contains(code) { found.append(code) }
            }
        }
        return Array(found.prefix(4))
    }

    static func times(in text: String) -> [String] {
        guard let re = timePattern else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range, in: text).map { String(text[$0]) }
        }.prefix(3).map { $0.count == 6 ? hhmmss($0) + " UTC" : "\($0.prefix(2)):\($0.suffix(2)) UTC" }
    }

    static func etaTime(in text: String) -> String? {
        // „ETA 2127“, „ETA-30/2127“ (in 30 min / um 21:27): die letzte 4er-Gruppe nach ETA.
        guard let re = etaPattern,
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let t = text[r]
        return "\(t.prefix(2)):\(t.suffix(2)) UTC"
    }

    static func hhmmss(_ s: String) -> String {
        guard s.count >= 4, s.allSatisfy(\.isNumber) else { return s }
        let a = Array(s)
        return s.count >= 6 ? "\(String(a[0...1])):\(String(a[2...3])):\(String(a[4...5]))" : "\(String(a[0...1])):\(String(a[2...3]))"
    }

    static func ddmmyy(_ s: String) -> String {
        guard s.count == 6, s.allSatisfy(\.isNumber) else { return s }
        let a = Array(s)
        return "\(String(a[0...1])).\(String(a[2...3])).20\(String(a[4...5]))"
    }

    static func coordinates(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.3f° %@ %.3f° %@", abs(lat), lat < 0 ? "S" : "N", abs(lon), lon < 0 ? "W" : "O")
    }
}

/// Setzt mehrteilige ACARS-Nachrichten zusammen: Blöcke mit ETB sind
/// Fortsetzungen; der nächste Block desselben Flugzeugs mit derselben
/// Nachrichtennummer (Folgebuchstabe +1) bzw. – beim Uplink – mit Block-ID +1
/// wird angehängt. Offene Teile verfallen nach 10 Minuten.
struct ACARSReassembler {
    private struct Pending { var message: ACARSMessage; var date: Date }
    private var pending: [String: Pending] = [:]

    private static func key(_ m: ACARSMessage) -> String {
        m.isDownlink ? "D|\(m.registration)|\(m.messageNumberBase ?? "")" : "U|\(m.registration)|\(m.label)"
    }

    /// Ergebnis: die (ggf. zusammengesetzte) Nachricht und die ID eines
    /// bereits gemeldeten Teils, den sie ersetzt.
    mutating func add(_ message: ACARSMessage, now: Date = Date()) -> (message: ACARSMessage, replaces: Int?) {
        pending = pending.filter { now.timeIntervalSince($0.value.date) < 600 }
        let key = Self.key(message)
        if let open = pending[key] {
            let previous = open.message
            let follows: Bool
            if message.isDownlink {
                follows = previous.messageSequence.flatMap { p in message.messageSequence.map { $0.asciiValue == (p.asciiValue ?? 0) + 1 } } ?? false
            } else {
                follows = previous.blockID.flatMap { p in message.blockID.map { $0.asciiValue == (p.asciiValue ?? 0) + 1 } } ?? false
            }
            if follows {
                var merged = previous
                merged.text += message.text
                merged.continued = message.continued
                merged.blocks += 1
                merged.blockID = message.blockID
                merged.messageNumber = message.messageNumber      // Folgebuchstabe für den nächsten Block
                merged.levelDB = message.levelDB
                merged.corrected += message.corrected
                if merged.continued { pending[key] = Pending(message: merged, date: now) } else { pending[key] = nil }
                return (merged, previous.id)
            }
            pending[key] = nil
        }
        if message.continued { pending[key] = Pending(message: message, date: now) }
        return (message, nil)
    }
}
