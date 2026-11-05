import Foundation

/// MSC-Datengruppe (EN 300 401 §5.3.3): Kopf mit Typ, Folge- und
/// Wiederholungszähler, Sitzungskopf (Segmentnummer, letztes Segment),
/// Nutzerzugriff (Übertragungskennung), Daten, CRC.
struct DABDataGroup: Equatable {
    var type: Int
    var segment: Int
    var last: Bool
    var transportID: Int?
    /// Nutzdaten ohne den 2-Byte-Segmentkopf (Wiederholungen, Segmentgröße).
    var payload: [UInt8]

    init?(_ g: [UInt8]) {
        guard g.count >= 2 else { return nil }
        let hasExtension = g[0] & 0x80 != 0, hasCRC = g[0] & 0x40 != 0
        let hasSegment = g[0] & 0x20 != 0, hasUserAccess = g[0] & 0x10 != 0
        type = Int(g[0] & 0x0F)
        var end = g.count
        if hasCRC {
            guard g.count >= 4 else { return nil }
            end -= 2
            guard DABCRC.ccitt(g[0..<end]) == UInt16(g[end]) << 8 | UInt16(g[end + 1]) else { return nil }
        }
        var i = 2 + (hasExtension ? 2 : 0)
        segment = 0
        last = true
        if hasSegment {
            guard i + 2 <= end else { return nil }
            last = g[i] & 0x80 != 0
            segment = Int(g[i] & 0x7F) << 8 | Int(g[i + 1])
            i += 2
        }
        if hasUserAccess {
            guard i < end else { return nil }
            let hasTransportID = g[i] & 0x10 != 0
            let length = Int(g[i] & 0x0F)
            guard i + 1 + length <= end else { return nil }
            if hasTransportID, length >= 2 { transportID = Int(g[i + 1]) << 8 | Int(g[i + 2]) }
            i += 1 + length
        }
        // MOT-Segmente beginnen mit Wiederholungszähler (3) und Segmentgröße (13).
        guard type == 3 || type == 4 || type == 6 || type == 7 else { payload = Array(g[i..<end]); return }
        guard i + 2 <= end else { return nil }
        let size = Int(g[i] & 0x1F) << 8 | Int(g[i + 1])
        i += 2
        guard i + size <= end else { return nil }
        payload = Array(g[i..<(i + size)])
    }
}

/// Ein fertiges MOT-Objekt (Bild der Diashow, Datei des Programmführers).
struct DABMOTObject: Sendable, Equatable {
    var transportID: Int
    var contentType: Int
    var contentSubtype: Int
    var name: String?
    var body: [UInt8]

    var isImage: Bool { contentType == 2 }
    /// Bildformat laut Untertyp (1 JPEG, 3 PNG), sonst nach den ersten Bytes.
    var imageKind: String? {
        guard isImage else { return nil }
        if contentSubtype == 1 || body.starts(with: [0xFF, 0xD8]) { return "jpeg" }
        if contentSubtype == 3 || body.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        return nil
    }
}

/// Setzt MOT-Objekte aus Kopf- (Typ 3) und Rumpfsegmenten (Typ 4) je
/// Übertragungskennung zusammen (EN 301 234, Header-Modus wie bei der
/// Diashow nach TS 101 499). Höchstens einige Objekte gleichzeitig im Bau.
struct DABMOTAssembler {
    private struct Building {
        var header: [Int: [UInt8]] = [:]
        var headerLast: Int?
        var body: [Int: [UInt8]] = [:]
        var bodyLast: Int?
        var touched = 0
        /// Gesammelte Bytes (Kopf + Rumpf) – Grenze schon beim Sammeln (Review 05.11.2026).
        var bytes = 0
    }

    private var building: [Int: Building] = [:]
    private var counter = 0
    /// Höchstgröße eines Objekts (Diashow-Bilder sind ≤ 50 KB, Programmführer-Dateien größer).
    static let maxBody = 512 * 1024

    /// Nimmt eine Datengruppe; liefert ein Objekt, sobald es vollständig ist.
    mutating func add(_ group: DABDataGroup) -> DABMOTObject? {
        guard let id = group.transportID, group.type == 3 || group.type == 4, group.segment <= DABMOTCarousel.maxSegment else { return nil }
        counter += 1
        var b = building[id] ?? Building()
        b.touched = counter
        if group.type == 3 {
            if b.header[group.segment] == nil { b.bytes += group.payload.count }
            b.header[group.segment] = group.payload
            if group.last { b.headerLast = group.segment }
        } else {
            if b.body[group.segment] == nil { b.bytes += group.payload.count }
            b.body[group.segment] = group.payload
            if group.last { b.bodyLast = group.segment }
        }
        guard b.bytes <= Self.maxBody + DABMOTCarousel.maxDirectoryBytes else { building[id] = nil; return nil }
        building[id] = b
        // Ältestes unfertiges Objekt verwerfen, wenn zu viele offen sind.
        if building.count > 8, let oldest = building.min(by: { $0.value.touched < $1.value.touched })?.key {
            building[oldest] = nil
        }
        guard let headerLast = b.headerLast, let bodyLast = b.bodyLast,
              (0...headerLast).allSatisfy({ b.header[$0] != nil }), (0...bodyLast).allSatisfy({ b.body[$0] != nil }) else { return nil }
        let header = (0...headerLast).flatMap { b.header[$0]! }
        let body = (0...bodyLast).flatMap { b.body[$0]! }
        building[id] = nil
        guard var object = Self.parseHeader(header, transportID: id), body.count <= Self.maxBody else { return nil }
        object.body = body
        return object
    }

    /// MOT-Kopf: Rumpfgröße (28 Bit), Kopfgröße (13), Inhaltstyp (6), Untertyp (9),
    /// dann Parameter (PLI 2 Bit + Kennung 6 Bit; Länge 0, 1, 4 oder per Längenangabe).
    static func parseHeader(_ h: [UInt8], transportID: Int) -> DABMOTObject? {
        guard h.count >= 7 else { return nil }
        let contentType = Int(h[5] >> 1) & 0x3F
        let subtype = Int(h[5] & 0x01) << 8 | Int(h[6])
        var object = DABMOTObject(transportID: transportID, contentType: contentType, contentSubtype: subtype, body: [])
        var i = 7
        while i < h.count {
            let pli = h[i] >> 6, id = h[i] & 0x3F
            i += 1
            var length: Int
            switch pli {
            case 0: length = 0
            case 1: length = 1
            case 2: length = 4
            default:
                guard i < h.count else { return object }
                if h[i] & 0x80 != 0 {
                    guard i + 1 < h.count else { return object }
                    length = Int(h[i] & 0x7F) << 8 | Int(h[i + 1])
                    i += 2
                } else {
                    length = Int(h[i] & 0x7F)
                    i += 1
                }
            }
            guard i + length <= h.count else { return object }
            if id == 0x0C, length >= 2 {
                // ContentName: Zeichensatz (oberes Halbbyte), dann der Name.
                object.name = DABCharset.decode(Array(h[(i + 1)..<(i + length)]), charset: Int(h[i] >> 4))
            }
            i += length
        }
        return object
    }
}
