import Foundation

/// Programmbegleitende Daten (PAD, EN 300 401 §7): hier nur das Dynamic
/// Label (Lauftext, X-PAD-Anwendungstypen 2 und 3). Aufbau wie in DABlin.
final class DABPADDecoder: @unchecked Sendable {
    /// Längen der X-PAD-Unterfelder je Längenindex.
    private static let subfieldLengths = [4, 6, 8, 12, 16, 24, 32, 48]

    private(set) var dynamicLabel = ""

    /// Zuletzt benutztes Unterfeld (für Fortsetzungen ohne CI-Liste).
    private var lastType: Int?
    private var group: [UInt8] = []
    private var groupNeeded = 4
    private var segments: [Int: (toggle: Bool, last: Bool, charset: Int, chars: [UInt8])] = [:]

    func reset() {
        dynamicLabel = ""
        lastType = nil
        group = []
        groupNeeded = 4
        segments = [:]
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
            default:
                continued = nil
            }
            offset += subfield.length
        }
        lastType = continued
        return changed
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
        let fieldLength = command ? 0 : Int(group[0] & 0x0F) + 1
        if command && group[0] & 0x0F != 0x01 {
            group = []
            return false
        }
        let realLength = 2 + fieldLength
        groupNeeded = realLength + 2
        guard group.count >= groupNeeded else { return false }
        let crc = UInt16(group[realLength]) << 8 | UInt16(group[realLength + 1])
        defer { group = [] }
        guard DABCRC.ccitt(group[0..<realLength]) == crc else { return false }

        if command {
            // „Lauftext löschen“
            segments = [:]
            let changed = !dynamicLabel.isEmpty
            dynamicLabel = ""
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
                return true
            }
        }
        return false
    }
}
