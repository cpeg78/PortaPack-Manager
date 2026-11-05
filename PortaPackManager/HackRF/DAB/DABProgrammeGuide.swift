import Foundation

// Programmführer (SPI/EPG) im DAB: Paketmodus → MSC-Datengruppen → MOT-Karussell
// im Verzeichnismodus → binär kodiertes XML (ETSI TS 102 371) → Sendungen.

/// Setzt aus den Logikrahmen eines Paketmodus-Unterkanals die MSC-Datengruppen
/// einer Paketadresse zusammen (EN 300 401 §5.3.2). Paketkopf: Länge (2:
/// 24/48/72/96 Byte) · Folgezähler (2) · Erstes (1) · Letztes (1) · Adresse (10)
/// · Befehl (1) · Nutzlänge (7); am Ende CRC-16 über Kopf und Datenfeld.
/// Jeder Logikrahmen beginnt mit einem Paket (die Kapazität ist ein Vielfaches
/// von 24 Byte) – ausgewertet wird je Rahmen, ein Rest wird verworfen; so
/// findet der Zerleger nach einem Fehler beim nächsten Rahmen wieder Tritt.
struct DABPacketAssembler {
    let address: Int
    private var group: [UInt8] = []
    private var collecting = false
    private var lastContinuity: Int?
    /// Pakete mit falscher Prüfsumme (zur Anzeige).
    private(set) var crcErrors = 0
    /// Größte Datengruppe (MOT-Segmente sind ≤ 8 KB, mit Kopf etwas mehr).
    static let maxGroup = 16 * 1024

    init(address: Int) { self.address = address }

    /// Ein Logikrahmen hinein, fertige Datengruppen heraus.
    mutating func process(_ buffer: [UInt8]) -> [[UInt8]] {
        var groups: [[UInt8]] = []
        var i = 0
        while i < buffer.count {
            let length = [24, 48, 72, 96][Int(buffer[i] >> 6)]
            guard i + length <= buffer.count else { break }
            let packet = buffer[i..<(i + length)]
            i += length
            guard DABCRC.ccitt(packet.dropLast(2)) == UInt16(packet[packet.endIndex - 2]) << 8 | UInt16(packet[packet.endIndex - 1]) else {
                crcErrors += 1
                collecting = false
                continue
            }
            let b0 = packet[packet.startIndex], b2 = packet[packet.startIndex + 2]
            let packetAddress = Int(b0 & 0x03) << 8 | Int(packet[packet.startIndex + 1])
            guard packetAddress == address, packetAddress != 0 else { continue }
            // Kommandopakete (§5.3.2.1) gehören nicht zur Datengruppe.
            guard b2 & 0x80 == 0 else { continue }
            let continuity = Int(b0 >> 4) & 0x03
            let first = b0 & 0x08 != 0, last = b0 & 0x04 != 0
            let useful = min(Int(b2 & 0x7F), length - 5)
            let data = packet[(packet.startIndex + 3)..<(packet.startIndex + 3 + useful)]
            // Lücke im Folgezähler: die angefangene Gruppe ist verloren.
            if !first, let lastContinuity, continuity != (lastContinuity + 1) & 0x03 { collecting = false }
            lastContinuity = continuity
            if first { group = []; collecting = true }
            guard collecting else { continue }
            group += data
            if group.count > Self.maxGroup { collecting = false; continue }
            if last {
                groups.append(group)
                collecting = false
            }
        }
        return groups
    }
}

/// MOT-Karussell im Verzeichnismodus (EN 301 234 §7): ein Verzeichnis
/// (Datengruppe Typ 6) beschreibt alle Objekte samt Kopf, die Rümpfe kommen
/// als Typ 4. Objekte im Kopfmodus (Typ 3) werden ebenfalls angenommen.
/// Liefert jedes Objekt einmal je Verzeichnisstand.
struct DABMOTCarousel {
    private var directoryID: Int?
    private var directorySegments: [Int: [UInt8]] = [:]
    private var directoryLast: Int?
    private(set) var entries: [Int: DABMOTObject] = [:]
    private var bodies: [Int: [Int: [UInt8]]] = [:]
    private var bodyLast: [Int: Int] = [:]
    /// Gesammelte Bytes je Rumpf – die Grenze gilt schon beim Sammeln, nicht
    /// erst nach dem Zusammensetzen (Review 05.11.2026).
    private var bodyBytes: [Int: Int] = [:]
    private var directoryBytes = 0
    private var delivered: Set<Int> = []
    private var headerMode = DABMOTAssembler()
    /// Höchstzahl gleichzeitig gesammelter Rümpfe und Objekte im Verzeichnis.
    static let maxPending = 64
    static let maxEntries = 512
    /// Segmentnummern darüber sind unplausibel (512 KB ÷ 8 KB Mindestsegment = 64).
    static let maxSegment = 1024
    static let maxDirectoryBytes = 64 * 1024

    mutating func add(_ group: DABDataGroup) -> [DABMOTObject] {
        guard let id = group.transportID, group.segment <= Self.maxSegment else { return [] }
        switch group.type {
        case 6:
            if directoryID != id {
                directoryID = id
                directorySegments = [:]
                directoryLast = nil
                directoryBytes = 0
            }
            if directorySegments[group.segment] == nil {
                directoryBytes += group.payload.count
                guard directoryBytes <= Self.maxDirectoryBytes else {
                    directorySegments = [:]; directoryLast = nil; directoryBytes = 0
                    return []
                }
            }
            directorySegments[group.segment] = group.payload
            if group.last { directoryLast = group.segment }
            guard let last = directoryLast, (0...last).allSatisfy({ directorySegments[$0] != nil }),
                  let parsed = Self.parseDirectory((0...last).flatMap { directorySegments[$0]! }) else { return [] }
            directorySegments = [:]
            directoryLast = nil
            directoryBytes = 0
            // Dasselbe Verzeichnis kommt jeden Umlauf wieder: dann nichts erneut
            // liefern – sonst wurden alle Dateien je Umlauf neu zusammengesetzt und
            // geparst, unter dem Lock, auf dem der Main Actor wartet (Review 05.11.2026).
            guard parsed != entries else { return [] }
            entries = parsed
            delivered = []
            bodies = bodies.filter { parsed[$0.key] != nil }
            bodyLast = bodyLast.filter { parsed[$0.key] != nil }
            bodyBytes = bodyBytes.filter { parsed[$0.key] != nil }
            // Rümpfe, die schon vor dem Verzeichnis vollständig waren, sofort liefern.
            return bodies.keys.sorted().compactMap { completeBody($0) }
        case 3:
            return headerMode.add(group).map { [$0] } ?? []
        case 4:
            if let object = headerMode.add(group) { return [object] }
            guard entries.isEmpty || entries[id] != nil, !delivered.contains(id) else { return [] }
            if bodies[id] == nil, bodies.count >= Self.maxPending { return [] }
            if bodies[id]?[group.segment] == nil {
                bodyBytes[id, default: 0] += group.payload.count
                guard bodyBytes[id]! <= DABMOTAssembler.maxBody else {
                    bodies[id] = nil; bodyLast[id] = nil; bodyBytes[id] = nil
                    return []
                }
            }
            bodies[id, default: [:]][group.segment] = group.payload
            if group.last { bodyLast[id] = group.segment }
            return completeBody(id).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// Liefert das Objekt, sobald Verzeichniseintrag und alle Rumpfsegmente da sind.
    private mutating func completeBody(_ id: Int) -> DABMOTObject? {
        guard let entry = entries[id], let last = bodyLast[id],
              (0...last).allSatisfy({ bodies[id]?[$0] != nil }) else { return nil }
        let body = (0...last).flatMap { bodies[id]![$0]! }
        bodies[id] = nil
        bodyLast[id] = nil
        bodyBytes[id] = nil
        delivered.insert(id)
        guard body.count <= DABMOTAssembler.maxBody else { return nil }
        var object = entry
        object.body = body
        return object
    }

    /// Verzeichnis: CF (1) · Rfu (1) · Größe (30) · Objektzahl (16) ·
    /// Karussellperiode (24) · Rfu (1) · Rfa (2) · Segmentgröße (13) ·
    /// Erweiterungslänge (16) · Erweiterung · je Objekt Kennung (16) + MOT-Kopf.
    static func parseDirectory(_ d: [UInt8]) -> [Int: DABMOTObject]? {
        guard d.count >= 13 else { return nil }
        let count = min(Int(d[4]) << 8 | Int(d[5]), maxEntries)
        var i = 13 + (Int(d[11]) << 8 | Int(d[12]))
        var entries: [Int: DABMOTObject] = [:]
        for _ in 0..<count {
            guard i + 2 + 7 <= d.count else { break }
            let id = Int(d[i]) << 8 | Int(d[i + 1])
            let h = i + 2
            let headerSize = Int(d[h + 3] & 0x0F) << 9 | Int(d[h + 4]) << 1 | Int(d[h + 5] >> 7)
            guard headerSize >= 7, h + headerSize <= d.count else { break }
            if let object = DABMOTAssembler.parseHeader(Array(d[h..<(h + headerSize)]), transportID: id) {
                entries[id] = object
            }
            i = h + headerSize
        }
        return entries
    }
}

/// Eine Sendung aus dem Programmführer.
struct DABProgramme: Sendable, Equatable, Identifiable, Hashable {
    var serviceID: UInt32
    var start: Date
    var duration: TimeInterval
    var name: String
    var detail: String?

    var id: String { "\(serviceID)-\(start.timeIntervalSince1970)" }
    var end: Date { start.addingTimeInterval(duration) }
}

/// Binär kodiertes SPI-XML (ETSI TS 102 371): Element = Kennung (1 Byte) ·
/// Länge (1 Byte, 0xFE + 16 Bit, 0xFF + 24 Bit) · Inhalt aus Attributen
/// (0x80–0x87), Kindelementen und Text (0x01). Kennungen nach der
/// Referenzumsetzung python-hybridspi.
enum SPIBinary {
    struct Element {
        var tag: UInt8
        var attributes: [UInt8: [UInt8]] = [:]
        var children: [Element] = []
        var text: String?
        /// Zeichenkettenersetzung (Token-Tabelle, 0x04): Steuerzeichen → Text.
        var tokens: [UInt8: String] = [:]
        /// `defaultContentId` (0x05): Dienst für Sendungen ohne eigenen `bearer`.
        var defaultService: UInt32?

        func children(_ tag: UInt8) -> [Element] { children.filter { $0.tag == tag } }
        func child(_ tag: UInt8) -> Element? { children.first { $0.tag == tag } }
    }

    static let maxDepth = 16

    /// Liest das Wurzelelement (0x02 Programmführer, 0x03 Dienstinformation).
    static func parse(_ bytes: [UInt8]) -> Element? {
        var i = 0
        guard let element = element(bytes, &i, depth: 0), i == bytes.count else { return nil }
        return element
    }

    private static func length(_ b: [UInt8], _ i: inout Int) -> Int? {
        guard i < b.count else { return nil }
        let first = b[i]
        i += 1
        switch first {
        case 0xFE:
            guard i + 2 <= b.count else { return nil }
            defer { i += 2 }
            return Int(b[i]) << 8 | Int(b[i + 1])
        case 0xFF:
            guard i + 3 <= b.count else { return nil }
            defer { i += 3 }
            return Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2])
        default:
            return Int(first)
        }
    }

    private static func element(_ b: [UInt8], _ i: inout Int, depth: Int) -> Element? {
        guard depth < maxDepth, i < b.count else { return nil }
        let tag = b[i]
        i += 1
        guard let length = length(b, &i), i + length <= b.count else { return nil }
        let end = i + length
        var element = Element(tag: tag)
        while i < end {
            let child = b[i]
            if child >= 0x80 || child == 0x01 || child == 0x04 || child == 0x05 || child == 0x06 {
                i += 1
                guard let n = Self.length(b, &i), i + n <= end else { return nil }
                let value = Array(b[i..<(i + n)])
                i += n
                switch child {
                case 0x01: element.text = String(decoding: value, as: UTF8.self)
                case 0x04: element.tokens = tokenTable(value)
                case 0x05: element.defaultService = serviceID(value)
                case 0x06: break
                default: element.attributes[child] = value
                }
            } else {
                guard let sub = Self.element(b, &i, depth: depth + 1), i <= end else { return nil }
                element.children.append(sub)
            }
        }
        return element
    }

    /// Token-Tabelle: wiederholt Kennung (1) · Länge (1) · UTF-8-Text.
    private static func tokenTable(_ v: [UInt8]) -> [UInt8: String] {
        var tokens: [UInt8: String] = [:]
        var i = 0
        while i + 2 <= v.count {
            let id = v[i], n = Int(v[i + 1])
            guard i + 2 + n <= v.count else { break }
            tokens[id] = String(decoding: v[(i + 2)..<(i + 2 + n)], as: UTF8.self)
            i += 2 + n
        }
        return tokens
    }

    /// Zeitpunkt: Rfa (1) · MJD (17) · Rfa (1) · LTO (1) · UTC-Langform (1) ·
    /// Stunde (5) · Minute (6) [· Sekunde (6) · Millisekunde (10)] [· LTO-Byte].
    /// Die Stunde ist UTC, das LTO-Byte nur der Versatz für die Anzeige.
    static func time(_ v: [UInt8]) -> Date? {
        guard v.count >= 4 else { return nil }
        let w = UInt32(v[0]) << 24 | UInt32(v[1]) << 16 | UInt32(v[2]) << 8 | UInt32(v[3])
        let mjd = Int(w >> 14 & 0x1FFFF)
        let long = w >> 11 & 1 != 0
        let hour = Int(w >> 6 & 0x1F), minute = Int(w & 0x3F)
        guard mjd > 40587, hour < 24, minute < 60 else { return nil }
        var seconds = 0
        if long {
            guard v.count >= 6 else { return nil }
            seconds = Int(v[4] >> 2)
        }
        return Date(timeIntervalSince1970: TimeInterval((mjd - 40587) * 86400 + hour * 3600 + minute * 60 + seconds))
    }

    /// SId aus einer ContentId (Rfa · Ensemble · X-PAD · SId-Länge · SCIdS
    /// [· ECC · EId] · SId 16/32 Bit). Nur für `bearer`/`serviceScope`/`serviceID`
    /// – dort steht immer eine ContentId, nie eine EnsembleId.
    static func serviceID(_ v: [UInt8]) -> UInt32? {
        guard v.count >= 3 else { return nil }
        var i = 1
        if v[0] & 0x40 != 0 { i += 3 }
        let n = v[0] & 0x10 != 0 ? 4 : 2
        guard i + n <= v.count else { return nil }
        return v[i..<(i + n)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func number(_ v: [UInt8]?) -> Int? {
        guard let v, !v.isEmpty, v.count <= 4 else { return nil }
        return v.reduce(0) { $0 << 8 | Int($1) }
    }

    /// Text eines Namens/einer Beschreibung, Tokens der Vorfahren ersetzt.
    private static func text(_ e: Element?, tokens: [UInt8: String]) -> String? {
        guard var text = e?.text else { return nil }
        if !tokens.isEmpty {
            text = String(text.unicodeScalars.map { scalar -> String in
                if scalar.value < 0x20, let token = tokens[UInt8(scalar.value)] { return token }
                return String(scalar)
            }.joined())
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sendungen eines Programmführers (`epg` → `schedule` → `programme`).
    /// Dienst aus dem Ort der Sendung (`location`/`bearer`), sonst aus dem
    /// Geltungsbereich des Plans (`scope`/`serviceScope`), sonst `fallbackService`.
    static func programmes(_ root: Element, fallbackService: UInt32? = nil) -> [DABProgramme] {
        guard root.tag == 0x02 else { return [] }
        var result: [DABProgramme] = []
        for schedule in root.children(0x21) {
            let tokens = root.tokens.merging(schedule.tokens) { _, new in new }
            let fallbackService = schedule.defaultService ?? root.defaultService ?? fallbackService
            let scoped = schedule.child(0x24)?.children(0x25).compactMap { $0.attributes[0x80].flatMap(serviceID) }.first
            for programme in schedule.children(0x1C) {
                let local = tokens.merging(programme.tokens) { _, new in new }
                let names = [0x12, 0x11, 0x10].compactMap { text(programme.child($0), tokens: local) }
                guard let name = names.first(where: { $0.count <= 80 }) ?? names.last else { continue }
                let media = programme.children(0x13)
                let detail = media.lazy.compactMap { text($0.child(0x1A), tokens: local) }.first
                    ?? media.lazy.compactMap { text($0.child(0x1B), tokens: local) }.first
                for location in programme.children(0x19) {
                    let bearer = location.children(0x2D).compactMap { $0.attributes[0x80].flatMap(serviceID) }.first
                    guard let service = bearer ?? scoped ?? fallbackService else { continue }
                    for time in location.children(0x2C) {
                        guard let start = time.attributes[0x82].flatMap(Self.time) ?? time.attributes[0x80].flatMap(Self.time),
                              let duration = number(time.attributes[0x83]) ?? number(time.attributes[0x81]) else { continue }
                        result.append(DABProgramme(serviceID: service, start: start, duration: TimeInterval(duration),
                                                   name: name, detail: detail))
                    }
                }
            }
        }
        return result
    }
}

/// Sammelt die Sendungen je Dienst aus den Dateien des Karussells.
struct DABProgrammeGuide {
    private var packets: DABPacketAssembler?
    private var carousel = DABMOTCarousel()
    private(set) var programmes: [UInt32: [DABProgramme]] = [:]
    /// Zählt bei jeder Änderung der Sendungen weiter.
    private(set) var version = 0
    /// Höchstzahl je Dienst (eine Woche Stundensendungen).
    static let maxPerService = 200

    var address: Int? { packets?.address }

    mutating func reset(address: Int?) {
        packets = address.map(DABPacketAssembler.init)
        carousel = DABMOTCarousel()
        if !programmes.isEmpty { programmes = [:]; version += 1 }
    }

    /// Ein Logikrahmen des Programmführer-Unterkanals.
    mutating func process(_ frame: [UInt8], now: Date = Date()) {
        guard var assembler = packets else { return }
        let groups = assembler.process(frame)
        packets = assembler
        for raw in groups {
            guard let group = DABDataGroup(raw) else { continue }
            for object in carousel.add(group) { add(object, now: now) }
        }
    }

    /// `now` nur für Tests – Sendungen, die länger als sechs Stunden vorbei sind,
    /// fliegen hinaus.
    mutating func add(_ object: DABMOTObject, now: Date = Date()) {
        guard let root = SPIBinary.parse(object.body) else { return }
        let found = SPIBinary.programmes(root)
        guard !found.isEmpty else { return }
        for (service, items) in Dictionary(grouping: found, by: \.serviceID) {
            var merged = Dictionary((programmes[service] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for item in items { merged[item.id] = item }
            let cutoff = now.addingTimeInterval(-6 * 3600)
            programmes[service] = Array(merged.values.filter { $0.end > cutoff }.sorted { $0.start < $1.start }
                .prefix(Self.maxPerService))
        }
        version += 1
    }

    /// Laufende und kommende Sendungen eines Dienstes.
    func upcoming(for service: UInt32, now: Date = Date(), limit: Int = 12) -> [DABProgramme] {
        Array((programmes[service] ?? []).filter { $0.end > now }.prefix(limit))
    }
}
