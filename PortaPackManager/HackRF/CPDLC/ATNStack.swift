import Foundation

/// Die ATN-Schichten über X.25 (VDL2): CLNP (ISO 8473, meist mit
/// komprimiertem Kopf nach ICAO Doc 9705 SNDCF), COTP (ISO 8073, Klasse 4,
/// nur die Nutzdaten der DT-TPDUs werden gebraucht), darüber die ULCS
/// (X.225-Kurzform-SPDU, X.226 Fully-encoded-data, X.227 ACSE) und am Ende
/// die Anwendungen CPDLC (ProtectedAircraft/GroundPDUs → ATCDownlink/Uplink-
/// Message) und CM (Logon). Alles ab der ULCS ist ASN.1 PER nach Schema.
struct ATNMessage: Equatable {
    enum Kind: Equatable { case cpdlc, cm, acse, other }
    var kind: Kind
    /// Kurzform für Tabelle/Handy.
    var summary: String
    var rows: [ACARSInterpretation.Row]
    /// Schichten zur Fehlersuche („X.25 → CLNP → COTP DT → ACSE AARQ → CPDLC“).
    var layers: String

    /// Reine Transportquittung (COTP AK) – die Oberfläche blendet sie aus.
    /// Über die Schichten statt über den (übersetzten) Text erkannt.
    var isTransportAck: Bool { layers.hasSuffix("COTP AK") }
}

/// Teilstücke je Verbindung (Quelle, Ziel, Kanal). Die Schlüssel kommen aus
/// der Luft – ohne Ablauf und Obergrenze wüchse der Speicher mit jeder
/// erfundenen Adresse (Hunderte MB je Stunde möglich).
struct ATNFragmentStore {
    static let maxAge: TimeInterval = 60
    static let maxKeys = 256
    static let maxBytes = 65_536
    private var entries: [String: (data: [UInt8], time: Date)] = [:]

    var count: Int { entries.count }

    /// Hängt `data` an; `nil`, solange `more` gilt, sonst der ganze Puffer.
    mutating func append(_ data: [UInt8], more: Bool, key: String, now: Date = Date()) -> [UInt8]? {
        var buffer: [UInt8] = []
        if let entry = entries[key], now.timeIntervalSince(entry.time) <= Self.maxAge { buffer = entry.data }
        buffer += data
        guard more else { entries[key] = nil; return buffer }
        guard buffer.count < Self.maxBytes else { entries[key] = nil; return nil }
        if entries[key] == nil, entries.count >= Self.maxKeys { prune(now: now) }
        entries[key] = (buffer, now)
        return nil
    }

    /// Verfallene Einträge weg; reicht das nicht, die ältesten.
    private mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.time) <= Self.maxAge }
        guard entries.count >= Self.maxKeys else { return }
        let oldest = entries.sorted { $0.value.time < $1.value.time }.prefix(entries.count - Self.maxKeys / 2)
        for (key, _) in oldest { entries[key] = nil }
    }
}

final class ATNDecoder {
    private var x25Fragments = ATNFragmentStore()
    private var cotpFragments = ATNFragmentStore()
    private let schema = ASN1Schema.atn

    /// Zahl offener Teilstücke (für Tests).
    var pendingFragments: Int { x25Fragments.count + cotpFragments.count }

    /// X.25-Nutzdaten eines Datenpakets. `more`: M-Bit (Fortsetzung folgt);
    /// `key` kennzeichnet die Verbindung (Quelle, Ziel, Kanal).
    func handle(x25Data data: [UInt8], more: Bool, key: String, fromAircraft: Bool) -> ATNMessage? {
        guard let buffer = x25Fragments.append(data, more: more, key: key) else { return nil }
        return decodeNetwork(buffer, key: key, fromAircraft: fromAircraft)
    }

    // MARK: CLNP

    private func decodeNetwork(_ b: [UInt8], key: String, fromAircraft: Bool) -> ATNMessage? {
        guard let first = b.first else { return nil }
        var layers = "X.25"
        var payload: [UInt8]
        if first == 0x81 {
            // Unkomprimiert: Kopflänge in Byte 1, Typ in Byte 4 (unten 5 Bit: 0x1C = DT).
            guard b.count > 5 else { return nil }
            let headerLength = Int(b[1])
            guard headerLength <= b.count, b[4] & 0x1F == 0x1C else { return nil }
            payload = Array(b[headerLength...])
            layers += " → CLNP"
        } else if first == 0x82 || first == 0xE0 {
            return nil                                           // ES-IS / Fehlermeldung
        } else {
            // Komprimierter Kopf (SNDCF): Typ oben, Priorität unten; Lebensdauer; Flags; EXP|LRef.
            let type = Int(first >> 4)
            guard [1, 2, 3, 6, 7, 9, 0xA].contains(type) || type == 0, b.count >= 4 else { return nil }
            var length = 4
            if b[3] & 0x80 != 0 { length += 1 }
            let derived = [6, 7, 9, 0xA].contains(type)
            let segmentation = type == 1 || type == 3 || derived
            if segmentation { length += 2 }
            if derived { length += 4 }
            guard b.count > length else { return nil }
            if derived {
                // Fragment: Versatz und Gesamtlänge – nur das erste, vollständige Stück verwenden.
                let offset = Int(b[length - 4]) << 8 | Int(b[length - 3])
                let total = Int(b[length - 2]) << 8 | Int(b[length - 1])
                let more = type == 7 || type == 0xA
                if offset != 0 || more || total != b.count - length { return nil }
            }
            payload = Array(b[length...])
            layers += " → CLNP (komprimiert)"
        }
        return decodeTransport(payload, key: key, fromAircraft: fromAircraft, layers: layers)
    }

    // MARK: COTP

    private func decodeTransport(_ b: [UInt8], key: String, fromAircraft: Bool, layers: String) -> ATNMessage? {
        guard b.count >= 2 else { return nil }
        if b[0] == 0x85 {
            // IDRP (ISO 10747): Routing zwischen Bord- und Bodenrouter – NLPID, Länge, Typ.
            let names: [UInt8: String] = [1: "Open", 2: "Update", 3: "Error", 4: "Keepalive", 5: "Cease"]
            let type = b.count > 3 ? b[3] : 0
            return ATNMessage(kind: .other, summary: String(localized: "Routing (IDRP \(names[type] ?? String(localized: "Typ \(Int(type))")))"), rows: [], layers: layers + " → IDRP")
        }
        let li = Int(b[0])
        guard li > 0, li < 255, b.count > li else { return nil }
        let code = b[1]
        var layers = layers
        switch code & 0xF0 {
        case 0xF0:
            // DT: DST-REF (2), dann Folgenummer mit EOT-Bit (normal 1 Byte, erweitert 4).
            guard li >= 4 else { return nil }
            let eot = b[4] & 0x80 != 0
            let user = Array(b[(1 + li)...])
            guard let buffer = cotpFragments.append(user, more: !eot, key: key) else { return nil }
            layers += " → COTP DT"
            return decodeSession(buffer, fromAircraft: fromAircraft, layers: layers)
        case 0xE0, 0xD0:
            // CR/CC: DST-REF, SRC-REF, Klasse/Optionen, Parameter – die Nutzdaten
            // dahinter tragen beim ATN schon die Sitzung samt ACSE/CM-Anmeldung.
            let name = code & 0xF0 == 0xE0 ? "COTP CR" : "COTP CC"
            layers += " → \(name)"
            let user = Array(b[(1 + li)...])
            if !user.isEmpty, let message = decodeSession(user, fromAircraft: fromAircraft, layers: layers) { return message }
            return ATNMessage(kind: .other, summary: code & 0xF0 == 0xE0 ? String(localized: "Transportverbindung angefordert") : String(localized: "Transportverbindung bestätigt"), rows: [], layers: layers)
        case 0x80:
            layers += " → COTP DR"
            let user = li < b.count - 1 ? Array(b[(1 + li)...]) : []
            if !user.isEmpty, let message = decodeSession(user, fromAircraft: fromAircraft, layers: layers) { return message }
            return ATNMessage(kind: .other, summary: String(localized: "Transportverbindung beendet"), rows: [], layers: layers)
        case 0x60: return ATNMessage(kind: .other, summary: String(localized: "Transportquittung (COTP AK)"), rows: [], layers: layers + " → COTP AK")
        case 0x70: return ATNMessage(kind: .other, summary: String(localized: "Transportfehler (COTP ER)"), rows: [], layers: layers + " → COTP ER")
        case 0xC0: return ATNMessage(kind: .other, summary: String(localized: "Transportabbau bestätigt (COTP DC)"), rows: [], layers: layers + " → COTP DC")
        default: return nil
        }
    }

    // MARK: ULCS

    private func decodeSession(_ b: [UInt8], fromAircraft: Bool, layers: String) -> ATNMessage? {
        guard let first = b.first, let schema else { return nil }
        var layers = layers
        if first & 0x80 != 0 {
            // X.225-Kurzform: SCN/SAC/SACC/SRF/SRFC, dann ein Byte Darstellungsschicht, dann ACSE.
            let names: [UInt8: String] = [0xE8: String(localized: "Sitzung: Verbindung"), 0xF0: String(localized: "Sitzung: angenommen"), 0xD8: String(localized: "Sitzung: angenommen (Fortsetzung)"),
                                          0xE0: String(localized: "Sitzung: abgelehnt"), 0xA0: String(localized: "Sitzung: abgelehnt (Fortsetzung)")]
            guard let name = names[first & 0xF8] else { return nil }
            layers += " → \(name)"
            guard b.count > 2, b[1] & 3 == 2 else {
                return ATNMessage(kind: .other, summary: name, rows: [], layers: layers)
            }
            return decodeACSE(Array(b[2...]), fromAircraft: fromAircraft, layers: layers, schema: schema)
                ?? ATNMessage(kind: .other, summary: name, rows: [], layers: layers)
        }
        // Fully-encoded-data (X.226): Präsentationskontext 1 = ACSE, 3 = Anwendungsdaten direkt.
        if let fed = try? PERDecoder(schema: schema).decode("Fully_encoded_data", bytes: b),
           let pdv = fed["data"], let values = pdv["presentation-data-values"],
           case .choice("arbitrary", .bits(let bytes, let count)) = values {
            let context = pdv["presentation-context-identifier"]?.intValue ?? 0
            layers += " → Fully-encoded-data"
            if context == 1 {
                return decodeACSE(bytes, bitCount: count, fromAircraft: fromAircraft, layers: layers, schema: schema)
            }
            return decodeApplication(bytes, bitCount: count, app: nil, fromAircraft: fromAircraft, layers: layers, schema: schema)
        }
        return decodeACSE(b, fromAircraft: fromAircraft, layers: layers, schema: schema)
    }

    private func decodeACSE(_ b: [UInt8], bitCount: Int? = nil, fromAircraft: Bool, layers: String, schema: ASN1Schema) -> ATNMessage? {
        guard let apdu = try? PERDecoder(schema: schema).decode("ACSE_apdu", bytes: b, bitCount: bitCount),
              case .choice(let kind, let body) = apdu else { return nil }
        let names = ["aarq": String(localized: "Verbindungsaufbau (AARQ)"), "aare": String(localized: "Verbindung angenommen (AARE)"), "rlrq": String(localized: "Verbindungsabbau (RLRQ)"),
                     "rlre": String(localized: "Abbau bestätigt (RLRE)"), "abrt": String(localized: "Abbruch (ABRT)")]
        let layers = layers + " → ACSE \(kind.uppercased())"
        var app: Int?
        if kind == "aarq", let q = body["calling-AE-qualifier"], case .choice("ae-qualifier-form2", let v) = q { app = v.intValue }
        var rows: [ACARSInterpretation.Row] = []
        if kind == "aare", let result = body["result"], case .enumerated(let r) = result { rows.append(.init(String(localized: "Ergebnis"), r)) }
        if kind == "abrt", let source = body["abort-source"], case .enumerated(let s) = source { rows.append(.init(String(localized: "Quelle"), s)) }
        if let info = body["user-information"], let data = info["data"], let enc = data["encoding"],
           case .choice("arbitrary", .bits(let bytes, let count)) = enc,
           let message = decodeApplication(bytes, bitCount: count, app: app, fromAircraft: fromAircraft, layers: layers, schema: schema) {
            var m = message
            m.rows = rows + m.rows
            if kind == "aarq" || kind == "aare" { m.rows.insert(.init(String(localized: "Verbindung"), names[kind] ?? kind), at: 0) }
            return m
        }
        return ATNMessage(kind: .acse, summary: names[kind] ?? "ACSE \(kind)", rows: rows, layers: layers)
    }

    /// AE-Qualifier: 0 = ADS, 1 = CM, 22 = CPDLC.
    private func decodeApplication(_ b: [UInt8], bitCount: Int, app: Int?, fromAircraft: Bool, layers: String, schema: ASN1Schema) -> ATNMessage? {
        let decoder = PERDecoder(schema: schema)
        if app == nil || app == 22 {
            let pduType = fromAircraft ? "ProtectedAircraftPDUs" : "ProtectedGroundPDUs"
            if let pdus = try? decoder.decode(pduType, bytes: b, bitCount: bitCount), case .choice(let which, let inner) = pdus {
                let layers = layers + " → CPDLC \(which)"
                switch which {
                case "abortUser", "abortProvider":
                    return ATNMessage(kind: .cpdlc, summary: which == "abortUser"
                                          ? String(localized: "CPDLC-Abbruch (Anwender): \(CPDLCFormatter.format(inner, type: "", schema: schema))")
                                          : String(localized: "CPDLC-Abbruch (Dienst): \(CPDLCFormatter.format(inner, type: "", schema: schema))"),
                                      rows: [], layers: layers)
                case "startup", "startdown", "send":
                    let protected = which == "startdown" ? inner["startDownlinkMessage"] ?? inner : inner
                    guard let message = protected["protectedMessage"] else {
                        return ATNMessage(kind: .cpdlc, summary: which == "send" ? String(localized: "CPDLC: leere Nachricht") : String(localized: "CPDLC-Verbindungsstart ohne Nachricht"), rows: [], layers: layers)
                    }
                    guard case .bits(let bytes, let count) = message,
                          let decoded = try? decoder.decode(fromAircraft ? "ATCDownlinkMessage" : "ATCUplinkMessage", bytes: bytes, bitCount: count)
                    else { return ATNMessage(kind: .cpdlc, summary: String(localized: "CPDLC: Nachricht nicht lesbar"), rows: [], layers: layers) }
                    let formatted = CPDLCFormatter.atn(decoded, uplink: !fromAircraft, schema: schema)
                    var summary = formatted.summary
                    if which != "send" { summary = String(localized: "CPDLC-Start · \(summary)") }
                    return ATNMessage(kind: .cpdlc, summary: summary, rows: formatted.rows, layers: layers)
                default:
                    return ATNMessage(kind: .cpdlc, summary: "CPDLC \(which): \(CPDLCFormatter.format(inner, type: "", schema: schema))", rows: [], layers: layers)
                }
            }
        }
        if app == nil || app == 1 {
            let type = fromAircraft ? "CMAircraftMessage" : "CMGroundMessage"
            if let cm = try? decoder.decode(type, bytes: b, bitCount: bitCount), case .choice(let which, let inner) = cm {
                let names = ["cmLogonRequest": String(localized: "CM-Anmeldung (Logon)"), "cmLogonResponse": String(localized: "CM-Anmeldung bestätigt"), "cmContactRequest": String(localized: "CM-Kontaktaufforderung"),
                             "cmContactResponse": String(localized: "CM-Kontaktantwort"), "cmUpdate": String(localized: "CM-Aktualisierung"), "cmForwardRequest": String(localized: "CM-Weiterleitung"),
                             "cmForwardResponse": String(localized: "CM-Weiterleitung bestätigt"), "cmAbortReason": String(localized: "CM-Abbruch"), "cmServerFacilityQueryRequest": String(localized: "CM-Serveranfrage"),
                             "cmServerFacilityQueryResponse": String(localized: "CM-Serverantwort"), "cmServerFacilityNotification": String(localized: "CM-Serverhinweis")]
                var rows: [ACARSInterpretation.Row] = []
                if case .sequence(let members) = inner {
                    let t = schema.resolve(schema.types[type]?.members?.first { $0.name == which }?.type ?? "")
                    for m in members {
                        let mt = t?.type.members?.first { $0.name == m.0 }?.type ?? ""
                        let text = CPDLCFormatter.format(m.1, type: mt, schema: schema)
                        if !text.isEmpty { rows.append(.init(CPDLCFormatter.enumText(m.0), text)) }
                    }
                } else {
                    let text = CPDLCFormatter.format(inner, type: "", schema: schema)
                    if !text.isEmpty { rows.append(.init(String(localized: "Inhalt"), text)) }
                }
                let flight = rows.first { $0.name.contains("flight") }?.value
                return ATNMessage(kind: .cm, summary: flight.map { String(localized: "\(names[which] ?? "CM \(which)") · Flug \($0)") } ?? names[which] ?? "CM \(which)", rows: rows, layers: layers + " → CM")
            }
        }
        return nil
    }
}
