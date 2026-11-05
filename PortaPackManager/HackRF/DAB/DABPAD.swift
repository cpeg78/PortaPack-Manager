import Foundation

/// Programmbegleitende Daten (PAD, EN 300 401 §7): Dynamic Label (Lauftext,
/// X-PAD-Anwendungstypen 2 und 3) samt DL Plus (Titel, Interpret …, ETSI
/// TS 102 980) und die MOT-Diashow (Typ 1 Längenangabe, 12 Beginn, 13
/// Fortsetzung einer MSC-Datengruppe; ETSI TS 101 499). Aufbau wie in DABlin.
final class DABPADDecoder: @unchecked Sendable {
    /// Längen der X-PAD-Unterfelder je Längenindex.
    private static let subfieldLengths = [4, 6, 8, 12, 16, 24, 32, 48]

    private(set) var dynamicLabel = ""
    /// DL-Plus-Markierungen des aktuellen Lauftexts.
    private(set) var dlPlusTags: [RadioTextTag] = []
    /// DL Plus: Läuft das markierte Stück gerade („Item running“)? Sonst gelten
    /// Titel und Interpret nicht mehr (Wortbeitrag, Nachrichten).
    private(set) var itemRunning = false
    /// Umschaltbit des aktuellen Lauftexts – ein DL-Plus-Befehl gilt nur für den
    /// Text mit demselben Bit (Link-Bit).
    private var labelToggle: Bool?
    private var pendingDLPlus: (link: Bool, running: Bool, markers: [RadioTextPlus.Marker])?

    /// Letztes vollständiges Bild der Diashow (JPEG/PNG) und seine Laufnummer.
    private(set) var slide: DABMOTObject?
    private(set) var slideNumber = 0
    /// Länge der nächsten MOT-Datengruppe (aus X-PAD-Typ 1), die laufende Gruppe.
    private var motLength: Int?
    private var motGroup: [UInt8] = []
    private var motNeeded = 0
    private var mot = DABMOTAssembler()

    /// Zuletzt benutztes Unterfeld (für Fortsetzungen ohne CI-Liste).
    private var lastType: Int?
    private var group: [UInt8] = []
    private var groupNeeded = 4
    private var segments: [Int: (toggle: Bool, last: Bool, charset: Int, chars: [UInt8])] = [:]

    func reset() {
        dynamicLabel = ""
        dlPlusTags = []
        itemRunning = false
        labelToggle = nil
        pendingDLPlus = nil
        lastType = nil
        group = []
        groupNeeded = 4
        segments = [:]
        // Zähler weiterdrehen, damit die Anzeige das alte Bild verwirft.
        if slide != nil { slideNumber += 1 }
        slide = nil
        motLength = nil
        motGroup = []
        motNeeded = 0
        mot = DABMOTAssembler()
    }

    /// Verarbeitet das PAD eines Rahmens/einer AU. `pad` endet mit den zwei
    /// F-PAD-Bytes; davor steht das X-PAD (in umgekehrter Bytefolge).
    /// Liefert `true`, wenn sich der Lauftext geändert hat.
    @discardableResult
    func process(pad: [UInt8], exactLength: Bool) -> Bool {
        guard pad.count >= 2 else { return false }
        let fpad = pad.suffix(2).map { $0 }
        let xpad = Array(pad.dropLast(2).reversed())
        let fpadType = fpad[0] >> 6
        let indicator = (fpad[0] >> 4) & 0x03
        let ciFlag = fpad[1] & 0x02 != 0
        guard fpadType == 0 else { return false }

        var subfields: [(length: Int, type: Int)] = []
        var ciLength = 0
        let previous = lastType
        lastType = nil
        if ciFlag {
            switch indicator {
            case 1:   // kurzes X-PAD: 1 CI-Byte + 3 Datenbytes
                guard xpad.count >= 1 else { return false }
                let type = Int(xpad[0] & 0x1F)
                if type != 0 { subfields = [(3, type)] }
                ciLength = 1
            case 2:   // variables X-PAD: bis zu 4 CIs
                for i in 0..<4 {
                    guard xpad.count > i else { return false }
                    ciLength += 1
                    let ci = xpad[i]
                    if ci & 0x1F == 0 { break }
                    subfields.append((Self.subfieldLengths[Int(ci >> 5)], Int(ci & 0x1F)))
                }
            default: return false
            }
        } else if indicator == 1 || indicator == 2, let previous {
            // Fortsetzung des letzten Unterfelds ohne CI-Liste.
            let available = indicator == 1 ? min(4, xpad.count) : xpad.count
            subfields = [(available, previous)]
        }
        guard !subfields.isEmpty else { return false }
        let announced = ciLength + subfields.reduce(0) { $0 + $1.length }
        guard announced <= xpad.count else { return false }
        if exactLength && ciFlag && indicator == 2 && announced < xpad.count { return false }

        var changed = false
        var offset = ciLength
        var continued: Int?
        for subfield in subfields {
            let data = Array(xpad[offset..<min(offset + subfield.length, xpad.count)])
            switch subfield.type {
            case 2, 3:
                if feedDynamicLabel(start: subfield.type == 2, data) { changed = true }
                continued = 3
            case 1:
                // Längenangabe der folgenden MOT-Datengruppe: 14 Bit + CRC.
                if data.count >= 4, DABCRC.ccitt(data[0..<2]) == UInt16(data[2]) << 8 | UInt16(data[3]) {
                    motLength = Int(data[0] & 0x3F) << 8 | Int(data[1])
                }
                continued = nil
            case 12, 13:
                if feedMOT(start: subfield.type == 12, data) { changed = true }
                continued = 13
            default:
                continued = nil
            }
            offset += subfield.length
        }
        lastType = continued
        return changed
    }

    // MARK: - MOT-Diashow

    private func feedMOT(start: Bool, _ data: [UInt8]) -> Bool {
        if start {
            guard let length = motLength else { motGroup = []; return false }
            motLength = nil
            motGroup = []
            motNeeded = length
        } else if motGroup.isEmpty && motNeeded == 0 {
            return false
        }
        motGroup += data
        guard motGroup.count >= motNeeded else { return false }
        defer { motGroup = []; motNeeded = 0 }
        guard let group = DABDataGroup(Array(motGroup.prefix(motNeeded))), let object = mot.add(group),
              object.imageKind != nil else { return false }
        slide = object
        slideNumber += 1
        return true
    }

    // MARK: - Datengruppe des Dynamic Label

    private func feedDynamicLabel(start: Bool, _ data: [UInt8]) -> Bool {
        if start {
            group = []
            groupNeeded = 4
        } else if group.isEmpty {
            return false
        }
        guard group.count < groupNeeded else { return false }
        group += data
        guard group.count >= groupNeeded else { return false }

        let command = group[0] & 0x10 != 0
        let commandCode = group[0] & 0x0F
        // Befehle: 0x01 Lauftext löschen (ohne Feld), 0x02 DL Plus (Länge in Byte 1).
        let fieldLength = command ? (commandCode == 0x02 ? Int(group[1] & 0x0F) + 1 : 0) : Int(group[0] & 0x0F) + 1
        if command && commandCode != 0x01 && commandCode != 0x02 {
            group = []
            return false
        }
        let realLength = 2 + fieldLength
        groupNeeded = realLength + 2
        guard group.count >= groupNeeded else { return false }
        let crc = UInt16(group[realLength]) << 8 | UInt16(group[realLength + 1])
        defer { group = [] }
        guard DABCRC.ccitt(group[0..<realLength]) == crc else { return false }

        if command && commandCode == 0x02 {
            return dlPlus(link: group[1] & 0x80 != 0, Array(group[2..<realLength]))
        }
        if command {
            // „Lauftext löschen“
            segments = [:]
            let changed = !dynamicLabel.isEmpty || !dlPlusTags.isEmpty
            dynamicLabel = ""
            dlPlusTags = []
            labelToggle = nil
            return changed
        }
        let toggle = group[0] & 0x80 != 0
        let first = group[0] & 0x40 != 0
        let last = group[0] & 0x20 != 0
        let number = first ? 0 : Int(group[1] >> 4 & 0x07)
        let charset = first ? Int(group[1] >> 4) : 0
        if let any = segments.values.first, any.toggle != toggle { segments = [:] }
        guard segments[number] == nil else { return false }
        segments[number] = (toggle, last, charset, Array(group[2..<realLength]))
        return assemble()
    }

    private func assemble() -> Bool {
        var raw: [UInt8] = []
        var charset = 0
        for i in 0..<8 {
            guard let segment = segments[i] else { return false }
            if i == 0 { charset = segment.charset }
            raw += segment.chars
            if segment.last {
                let text = DABCharset.decode(raw, charset: charset)
                guard text != dynamicLabel else { return false }
                dynamicLabel = text
                labelToggle = segment.toggle
                dlPlusTags = []
                applyDLPlus()
                return true
            }
        }
        return false
    }

    // MARK: - DL Plus

    /// DL-Plus-Befehl (TS 102 980 §7): CId 0 = Markierungen. Byte 0: CId (4),
    /// Item-Toggle, Item-Running, Anzahl − 1 (2); dann je 3 Byte Inhaltsart (7),
    /// Anfang (7), Länge − 1 (6).
    private func dlPlus(link: Bool, _ field: [UInt8]) -> Bool {
        guard let head = field.first, head >> 4 == 0 else { return false }
        let count = Int(head & 0x03) + 1
        guard field.count >= 1 + 3 * count else { return false }
        let markers = (0..<count).map { k -> RadioTextPlus.Marker in
            let i = 1 + 3 * k
            return .init(type: Int(field[i] & 0x7F), start: Int(field[i + 1] & 0x7F), length: Int(field[i + 2] & 0x3F) + 1)
        }
        pendingDLPlus = (link, head & 0x04 != 0, markers)
        let before = (dlPlusTags, itemRunning)
        applyDLPlus()
        return before != (dlPlusTags, itemRunning)
    }

    /// Den letzten Befehl auf den Text anwenden, zu dem er gehört.
    private func applyDLPlus() {
        guard let pending = pendingDLPlus, let labelToggle, pending.link == labelToggle else { return }
        dlPlusTags = RadioTextPlus.tags(in: dynamicLabel, markers: pending.markers)
        itemRunning = pending.running
    }
}
