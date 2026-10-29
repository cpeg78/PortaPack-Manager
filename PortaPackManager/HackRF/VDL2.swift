import Accelerate
import Foundation

// VDL Mode 2 (ICAO Doc 9776): D8PSK mit 10,5 kSym/s auf 136,725–136,975 MHz.
// In Europa läuft der größte Teil des Flugzeug-Datenfunks hierüber (ACARS
// über AVLC, „AOA“), auf 131 MHz nur noch der Rest. Verfahren nach dumpvdl2
// (Tomasz Lemiech) nachgebaut, dort GPL – hier eigene Umsetzung:
// Präambelsuche über die Phasenfolge mit linearer Regression (Frequenzablage),
// Gray-Code, Verwürfler x¹⁵ + x + 1, Kopf mit (25,20)-Blockcode,
// Reed-Solomon (255,249) über GF(2⁸)/0x187 mit erster Nullstelle 120,
// spaltenweise verschachtelt, AVLC-Rahmen mit Bitstopfen und CRC-16.

/// Eine empfangene VDL2-Rahmeneinheit (AVLC).
struct VDL2Frame: Identifiable, Sendable, Equatable {
    enum AddressType: Int, Sendable {
        case aircraft = 1, groundAdministrative = 4, groundDelegated = 5, all = 7, reserved = 0
        var isGround: Bool { self == .groundAdministrative || self == .groundDelegated }
    }
    enum Kind: Sendable, Equatable {
        case acars, information, supervisory, xid, unnumbered(UInt8)
    }
    var id = 0
    var date = Date()
    var frequencyMHz: Double = 0
    var levelDB: Double = 0
    var source: UInt32
    var sourceType: AddressType
    var destination: UInt32
    var destinationType: AddressType
    /// Flugzeug in der Luft (A/G-Bit der Zieladresse, 0 = in der Luft).
    var airborne: Bool
    var kind: Kind
    var acars: ACARSMessage?
    /// Aus dem Verbindungsaufbau (XID, Parameter „Aircraft location“): Position
    /// auf 0,1° und Höhe in 1000 ft.
    var location: (latitude: Double, longitude: Double, altitudeFt: Int)?
    /// XID-Parameter „Destination airport“ (ICAO-Code).
    var destinationAirport: String?
    /// Einordnung eines X.25-Pakets (ATN): Pakettyp, Kanal, Protokoll darüber.
    var x25: String?
    /// Dekodierte ATN-Anwendung (CPDLC, CM), falls das X.25-Paket eine trägt.
    var atn: ATNMessage?
    /// Rohe X.25-Nutzdaten (Fehlersuche).
    var x25User: [UInt8]?

    static func == (a: VDL2Frame, b: VDL2Frame) -> Bool {
        a.id == b.id && a.source == b.source && a.destination == b.destination && a.kind == b.kind && a.acars == b.acars
            && a.destinationAirport == b.destinationAirport && a.location?.latitude == b.location?.latitude
    }
    /// Korrigierte Bytes (Reed-Solomon) bzw. Bits im Kopf.
    var corrected = 0

    var aircraftAddress: UInt32? {
        sourceType == .aircraft ? source : destinationType == .aircraft ? destination : nil
    }
    var kindText: String {
        switch kind {
        case .acars: "ACARS"
        case .information: String(localized: "Daten (X.25/ATN)")
        case .supervisory: String(localized: "Quittung", comment: "VDL2-Rahmenart (Supervisory)")
        case .xid: String(localized: "Verbindungsaufbau (XID)")
        case .unnumbered(let f): String(format: String(localized: "Steuerrahmen 0x%02X"), f)
        }
    }
}

enum VDL2Coding {
    static let symbolRate = 10_500.0
    static let samplesPerSymbol = 10
    static let preambleSymbols = 16
    /// Phasenlage nach jedem Präambelsymbol (Vielfache von π/4).
    static let preamblePhases: [Int] = [0, 3, -3, 1, 1, 2, 0, 4, -3, 4, -2, 3, 1, -2, -3, 0]
    /// Symbolindex (Phasensprung in π/4) → 3 Bit (Gray).
    static let gray: [UInt8] = [0, 1, 3, 2, 6, 7, 5, 4]
    static let scramblerSeed: UInt16 = 0x6959
    static let headerBits = 25
    static let lengthBits = 17
    static let fecBits = 5
    static let rsN = 255, rsK = 249

    // MARK: Verwürfler

    /// x¹⁵ + x + 1, je Bit ein Schritt (gilt zum Ver- und Entwürfeln).
    static func scramble(_ bits: inout [UInt8], from start: Int = 0, state: inout UInt16) {
        for i in start..<bits.count {
            let bit = UInt8((state ^ (state >> 14)) & 1)
            state = (state >> 1) | (UInt16(bit) << 14)
            bits[i] ^= bit
        }
    }

    // MARK: Kopf (3 reservierte Bits, 17 Bit Länge, 5 Bit Prüfung)

    /// Prüfmatrix, Spalten = Bits des 25-Bit-Worts (MSB = erstes Bit).
    static let parityCheck: [UInt32] = [
        0b0000000011111111111110000,
        0b0011111100001111111101000,
        0b1100011100110000111100100,
        0b1101101101010011001100010,
        0b0110100111100101010100001,
    ]

    static func syndrome(_ word: UInt32) -> Int {
        var s = 0
        for (i, row) in parityCheck.enumerated() where (word & row).nonzeroBitCount % 2 == 1 {
            s |= 1 << (fecBits - 1 - i)
        }
        return s
    }

    /// Fehlermuster je Syndrom: erst Einzelfehler, dann Doppelfehler (nur in
    /// den 22 genutzten Bits – die reservierten sind immer 0).
    static let syndromeTable: [UInt32?] = {
        var table = [UInt32?](repeating: nil, count: 32)
        table[0] = 0
        for i in 0..<22 where table[syndrome(1 << i)] == nil { table[syndrome(1 << i)] = 1 << i }
        for i in 0..<22 { for j in (i + 1)..<22 {
            let e: UInt32 = (1 << i) | (1 << j)
            if table[syndrome(e)] == nil { table[syndrome(e)] = e }
        } }
        return table
    }()

    /// Länge in Bit aus dem Kopf; `nil`, wenn nicht korrigierbar.
    static func decodeHeader(_ raw: UInt32) -> (lengthBits: Int, corrected: Int)? {
        var word = raw & ((1 << 22) - 1)            // reservierte Bits erzwingen 0
        let s = syndrome(word)
        guard let error = syndromeTable[s] else { return nil }
        word ^= error
        let field = (word >> UInt32(fecBits)) & ((1 << UInt32(lengthBits)) - 1)
        return (Int(reverse(field, bits: lengthBits)), error.nonzeroBitCount)
    }

    static func encodeHeader(lengthBits length: Int) -> UInt32 {
        let field = reverse(UInt32(length), bits: lengthBits) << UInt32(fecBits)
        var word = field
        for (i, row) in parityCheck.enumerated() where (field & row).nonzeroBitCount % 2 == 1 {
            word |= 1 << UInt32(fecBits - 1 - i)
        }
        return word
    }

    static func reverse(_ value: UInt32, bits: Int) -> UInt32 {
        var r: UInt32 = 0
        for i in 0..<bits where value & (1 << UInt32(i)) != 0 { r |= 1 << UInt32(bits - 1 - i) }
        return r
    }

    // MARK: Blockaufteilung

    /// Prüfbytes des letzten (kurzen) Blocks.
    static func fecCount(lastBlock length: Int) -> Int {
        length < 3 ? 0 : length < 31 ? 2 : length < 68 ? 4 : 6
    }

    struct Layout: Equatable {
        let dataOctets: Int
        let blocks: Int
        let lastBlockOctets: Int
        let fecOctets: Int
    }

    static func layout(lengthBits: Int) -> Layout? {
        let dataOctets = (lengthBits + 7) / 8
        var blocks = dataOctets / rsK
        var fec = blocks * (rsN - rsK)
        var last = dataOctets % rsK
        if last != 0 { blocks += 1 }
        fec += fecCount(lastBlock: last)
        if last == 0 { last = rsK }
        guard fec > 0 else { return nil }
        return Layout(dataOctets: dataOctets, blocks: blocks, lastBlockOctets: last, fecOctets: fec)
    }

    /// Schreibt `input` spaltenweise in die Zeilen ab Spalte `offset`; die
    /// letzte Zeile ist nur `count % width` lang (wie dumpvdl2 `deinterleave`).
    static func deinterleave(_ input: [UInt8], rows: Int, width: Int, offset: Int, into table: inout [[UInt8]]) -> Bool {
        guard rows > 0, width > 0, input.count <= rows * width else { return false }
        var lastRow = input.count % width
        if lastRow == 0 { lastRow = width }
        if rows > 1, input.count - lastRow < (rows - 1) * width { return false }
        var row = 0, column = offset
        let lastEnd = lastRow + offset
        for byte in input {
            if row == rows - 1, column >= lastEnd {
                table[row][column] = 0
                row = 0
                column += 1
            }
            table[row][column] = byte
            row += 1
            if row == rows { row = 0; column += 1 }
        }
        return true
    }

    /// Gegenstück für den Sender (Tests).
    static func interleave(_ table: [[UInt8]], count: Int, width: Int, offset: Int) -> [UInt8] {
        let rows = table.count
        var lastRow = count % width
        if lastRow == 0 { lastRow = width }
        var out: [UInt8] = []
        var row = 0, column = offset
        let lastEnd = lastRow + offset
        while out.count < count {
            if row == rows - 1, column >= lastEnd { row = 0; column += 1 }
            out.append(table[row][column])
            row += 1
            if row == rows { row = 0; column += 1 }
        }
        return out
    }

    // MARK: AVLC

    /// CRC-16/X.25 (bitweise gespiegelt, Polynom 0x8408), Rest 0xF0B8 bei gültigem Rahmen.
    static func crc16(_ bytes: [UInt8], initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    /// Rahmen zwischen 0x7E-Flags, Stopfbits entfernt. Bits in Sendefolge.
    static func unstuffFrames(_ bits: [UInt8]) -> [[UInt8]]? {
        var frames: [[UInt8]] = []
        var current: [UInt8] = []
        var ones = 0
        for bit in bits {
            if bit == 0, ones == 5 { ones = 0; continue }       // Stopfbit
            if bit == 1 {
                ones += 1
                if ones > 6 { return frames.isEmpty ? nil : frames }
            }
            current.append(bit)
            if bit == 0 {
                if ones == 6 {                                   // Flag 01111110
                    // Beginnt der Burst mitten im Flag, ist es kürzer als 8 Bit.
                    current.removeLast(min(8, current.count))
                    if !current.isEmpty {
                        guard current.count % 8 == 0 else { return frames.isEmpty ? nil : frames }
                        frames.append(current)
                    }
                    current = []
                }
                ones = 0
            }
        }
        return frames
    }

    static func bytesLSBFirst(_ bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count - bits.count % 8, by: 8).map { start in
            (0..<8).reduce(UInt8(0)) { $0 | (bits[start + $1] << UInt8($1)) }
        }
    }

    static func bitsLSBFirst(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { byte in (0..<8).map { (byte >> UInt8($0)) & 1 } }
    }

    /// Adressfeld (4 Byte, je Byte das unterste Bit als Erweiterungsbit).
    static func address(_ b: ArraySlice<UInt8>) -> (address: UInt32, type: VDL2Frame.AddressType, status: Bool) {
        let i = b.startIndex
        let raw = UInt32(b[i] >> 1) | UInt32(b[i + 1]) << 6 | UInt32(b[i + 2]) << 13 | UInt32(b[i + 3] & 0xFE) << 20
        let value = reverse(raw, bits: 28)
        return (value & 0xFFFFFF, VDL2Frame.AddressType(rawValue: Int((value >> 24) & 7)) ?? .reserved, (value >> 27) & 1 == 1)
    }

    static func encodeAddress(_ address: UInt32, type: VDL2Frame.AddressType, status: Bool) -> [UInt8] {
        let value = address & 0xFFFFFF | UInt32(type.rawValue) << 24 | (status ? 1 << 27 : 0)
        let raw = reverse(value, bits: 28)
        return [UInt8((raw << 1) & 0xFE), UInt8((raw >> 6) & 0xFE), UInt8((raw >> 13) & 0xFE), UInt8((raw >> 20) & 0xFE)]
    }

    /// AVLC-Rahmen (mit FCS) auswerten; `nil` bei falscher Prüfsumme.
    static func parseAVLC(_ frame: [UInt8]) -> VDL2Frame? {
        guard frame.count >= 11, crc16(frame) == 0xF0B8 else { return nil }
        let body = Array(frame.dropLast(2))
        let dst = address(body[0..<4]), src = address(body[4..<8])
        let control = body[8]
        let info = Array(body[9...])
        var kind: VDL2Frame.Kind
        var acars: ACARSMessage?
        if control & 1 == 0 {
            if info.count > 3, info[0] == 0xFF, info[1] == 0xFF, info[2] == 0x01 {
                kind = .acars
                acars = parseACARS(Array(info[3...]))
            } else {
                kind = .information
            }
        } else if control & 3 == 1 {
            kind = .supervisory
        } else {
            let function = (control >> 2) & 0x3B
            kind = function == 0x2B ? .xid : .unnumbered(function)
        }
        var frame = VDL2Frame(source: src.address, sourceType: src.type, destination: dst.address, destinationType: dst.type,
                              airborne: !dst.status, kind: kind, acars: acars)
        if kind == .xid, let xid = parseXID(info) {
            frame.location = xid.location
            frame.destinationAirport = xid.destination
        }
        if kind == .information { frame.x25 = describeX25(info) }
        return frame
    }

    struct X25Packet {
        var lcn: Int
        var type: UInt8
        var isData: Bool
        var sequence: Int
        var more: Bool
        var user: [UInt8]
    }

    static func parseX25(_ b: [UInt8]) -> X25Packet? {
        guard b.count >= 3, b[0] >> 4 == 1 else { return nil }
        let lcn = Int(b[0] & 0x0F) << 8 | Int(b[1])
        let type = b[2]
        let isData = type & 1 == 0
        return X25Packet(lcn: lcn, type: type, isData: isData, sequence: Int((type >> 1) & 7), more: type & 0x10 != 0, user: Array(b[3...]))
    }

    /// X.25 (ISO 8208) über AVLC: GFI/LCGN, LCN, Pakettyp; Daten tragen CLNP
    /// (0x81), ES-IS (0x82) oder komprimiertes CLNP (ATN-SNDCF). Darüber liegt
    /// ATN mit COTP und den Anwendungen CM (Logon) und CPDLC – ASN.1 PER nach
    /// ICAO Doc 9880, hier nicht entschlüsselt.
    static func describeX25(_ b: [UInt8]) -> String? {
        guard b.count >= 3, b[0] >> 4 == 1 else { return nil }
        let lcn = Int(b[0] & 0x0F) << 8 | Int(b[1])
        let type = b[2]
        func user(_ data: ArraySlice<UInt8>) -> String {
            guard let first = data.first else { return String(localized: "ohne Daten") }
            let proto: String
            switch first {
            case 0x81: proto = "CLNP"
            case 0x82: proto = "ES-IS"
            case 0xE0: proto = String(localized: "SNDCF-Fehlermeldung")
            default:
                let t = first >> 4
                proto = (t < 4 || t == 6 || t == 7 || t == 9 || t == 0xA) ? String(localized: "komprimiertes CLNP") : String(localized: "Protokoll 0x\(String(first, radix: 16))")
            }
            return String(localized: "\(proto), \(data.count) Byte")
        }
        if type & 1 == 0 {
            let ps = (type >> 1) & 7, more = type & 0x10 != 0
            let number = "\(ps)\(more ? "+" : "")"
            return String(localized: "ATN-Daten Nr. \(number) (Kanal \(lcn)): \(user(b[3...])) – CPDLC/CM, nicht entschlüsselt")
        }
        switch type & 0x1F {
        case 0x0B, 0x0F:
            // Adressblock: Längen-Nibbles (gerufen, rufend), dann BCD-Ziffern.
            var text = type & 0x1F == 0x0B ? String(localized: "X.25 Verbindungsaufruf") : String(localized: "X.25 Verbindung angenommen")
            if b.count > 3 {
                let calledLen = Int(b[3] & 0x0F), callingLen = Int(b[3] >> 4)
                let digits = b[4...].flatMap { [$0 >> 4, $0 & 0x0F] }.map { String($0, radix: 16) }
                if digits.count >= calledLen + callingLen {
                    let called = digits[0..<calledLen].joined(), calling = digits[calledLen..<(calledLen + callingLen)].joined()
                    if !called.isEmpty { text += " " + String(localized: "an \(called)", comment: "X.25: gerufene Adresse") }
                    if !calling.isEmpty { text += " " + String(localized: "von \(calling)", comment: "X.25: rufende Adresse") }
                }
            }
            return text + " " + String(localized: "(Kanal \(lcn)) – CM-Logon/CPDLC-Aufbau")
        case 0x13: return String(localized: "X.25 Verbindung beendet (Kanal \(lcn))")
        case 0x17: return String(localized: "X.25 Beendigung bestätigt (Kanal \(lcn))")
        case 0x01: return String(localized: "X.25 Empfangsbereit (Kanal \(lcn))")
        case 0x09: return String(localized: "X.25 Wiederholung angefordert (Kanal \(lcn))")
        case 0x1B: return String(localized: "X.25 Rücksetzen (Kanal \(lcn))")
        default: return String(format: String(localized: "X.25 Steuerpaket 0x%02X (Kanal %d)"), type, lcn)
        }
    }

    /// XID (ISO 8885): Format 0x82, dann Gruppen (Kennung, Länge 16 Bit, Parameter
    /// je Kennung/Länge 8 Bit). In der VDL-Gruppe 0xF0: 0x83 Zielflughafen
    /// (ASCII), 0x84 Position – Breite 12 Bit, Länge 12 Bit (Zweierkomplement,
    /// Zehntelgrad), Höhe in 1000 ft.
    static func parseXID(_ bytes: [UInt8]) -> (location: (latitude: Double, longitude: Double, altitudeFt: Int)?, destination: String?)? {
        guard bytes.count >= 4, bytes[0] == 0x82 else { return nil }
        var i = 1
        var location: (Double, Double, Int)?
        var destination: String?
        while i + 3 <= bytes.count {
            let group = bytes[i]
            let length = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            i += 3
            let end = min(bytes.count, i + length)
            if group == 0xF0 {
                var p = i
                while p + 2 <= end {
                    let id = bytes[p], n = Int(bytes[p + 1])
                    let value = bytes[(p + 2)..<min(end, p + 2 + n)]
                    p += 2 + n
                    switch id {
                    case 0x83:
                        destination = String(bytes: value.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii)
                    case 0x84 where value.count >= 4:
                        let v = Array(value)
                        var lat = Int(v[0]) << 4 | Int(v[1]) >> 4
                        var lon = (Int(v[1]) & 0x0F) << 8 | Int(v[2])
                        if lat & 0x800 != 0 { lat -= 0x1000 }
                        if lon & 0x800 != 0 { lon -= 0x1000 }
                        location = (Double(lat) / 10, Double(lon) / 10, Int(v[3]) * 1000)
                    default: break
                    }
                }
            }
            i = end
        }
        return (location, destination)
    }

    /// ACARS-Block nach SOH: Parität abstreifen, bis ETX/ETB kürzen (dahinter
    /// folgen Prüfsumme und DEL – geprüft ist schon die AVLC-FCS).
    static func parseACARS(_ bytes: [UInt8]) -> ACARSMessage? {
        var text = bytes.map { $0 & 0x7F }
        if let end = text.lastIndex(where: { $0 == 0x03 || $0 == 0x17 }), end >= 12 {
            text = Array(text[...end])
        } else {
            text.append(0x03)
        }
        return ACARSFrame.parse(text)
    }
}

/// Reed-Solomon (255,249), GF(2⁸) mit 0x187, Nullstellen α^120 … α^125,
/// mit Auslöschungen (der letzte Block hat nur 0/2/4 Prüfbytes).
enum VDL2ReedSolomon {
    static let n = 255, roots = 6, firstRoot = 120
    private static let exp = MeteorReedSolomon.exp
    private static let log = MeteorReedSolomon.log
    @inline(__always) private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 { MeteorReedSolomon.mul(a, b) }
    @inline(__always) private static func alpha(_ e: Int) -> UInt8 { MeteorReedSolomon.alpha(e) }

    static let generator: [UInt8] = {
        var g: [UInt8] = [1]
        for j in 0..<roots {
            let root = alpha(firstRoot + j)
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (i, c) in g.enumerated() { next[i] ^= c; next[i + 1] ^= mul(c, root) }
            g = next
        }
        return g
    }()

    /// 249 Datenbytes → 6 Prüfbytes.
    static func parity(_ data: [UInt8]) -> [UInt8] {
        var remainder = [UInt8](repeating: 0, count: roots)
        for byte in data {
            let feedback = byte ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            if feedback != 0 { for i in 0..<roots { remainder[i] ^= mul(feedback, generator[i + 1]) } }
        }
        return remainder
    }

    /// Korrigiert an Ort und Stelle (Fehler und Auslöschungen, Byte 0 = höchster
    /// Grad). Ergebnis: Zahl der geänderten Stellen oder `nil`.
    static func decode(_ word: inout [UInt8], erasures: [Int] = []) -> Int? {
        var s = [UInt8](repeating: 0, count: roots)
        for j in 0..<roots {
            let root = alpha(firstRoot + j)
            var v: UInt8 = 0
            for byte in word { v = mul(v, root) ^ byte }
            s[j] = v
        }
        if s.allSatisfy({ $0 == 0 }) { return 0 }

        // Λ mit den Auslöschungen vorbelegen: Π (1 − X_k x), X_k = α^(254 − pos).
        var lambda = [UInt8](repeating: 0, count: roots + 1)
        lambda[0] = 1
        for (i, pos) in erasures.enumerated() {
            let x = alpha(n - 1 - pos)
            for j in stride(from: i + 1, to: 0, by: -1) { lambda[j] ^= mul(x, lambda[j - 1]) }
        }
        var b = lambda
        var el = erasures.count
        var r = erasures.count
        while r < roots {
            r += 1
            var discrepancy: UInt8 = 0
            for i in 0..<r where lambda[i] != 0 { discrepancy ^= mul(lambda[i], s[r - i - 1]) }
            if discrepancy == 0 {
                b = [0] + b.dropLast()
                continue
            }
            var t = lambda
            for i in 0..<roots { t[i + 1] ^= mul(discrepancy, b[i]) }
            if 2 * el <= r + erasures.count - 1 {
                el = r + erasures.count - el
                let inverse = alpha(255 - log[Int(discrepancy)])
                b = lambda.map { mul($0, inverse) }
            } else {
                b = [0] + b.dropLast()
            }
            lambda = t
        }
        let degree = lambda.lastIndex(where: { $0 != 0 }) ?? 0
        guard degree > 0 else { return nil }

        // Chien: Λ(α^i) = 0 ⇒ Fehler an Byte i − 1 (X⁻¹ = α^i).
        var found: [(root: Int, position: Int)] = []
        for i in 1...n {
            var q: UInt8 = 0
            for j in 0...degree where lambda[j] != 0 { q ^= mul(lambda[j], alpha(j * i)) }
            if q == 0 { found.append((i, i - 1)) }
        }
        guard found.count == degree else { return nil }

        // Ω = S·Λ mod x^roots; Forney.
        var omega = [UInt8](repeating: 0, count: roots)
        for i in 0..<roots {
            var v: UInt8 = 0
            for j in 0...min(i, degree) { v ^= mul(lambda[j], s[i - j]) }
            omega[i] = v
        }
        for (root, position) in found {
            var numerator: UInt8 = 0
            for i in 0..<roots where omega[i] != 0 { numerator ^= mul(omega[i], alpha(i * root)) }
            var denominator: UInt8 = 0
            var i = 1
            while i <= degree {
                if lambda[i] != 0 { denominator ^= mul(lambda[i], alpha((i - 1) * root)) }
                i += 2
            }
            guard denominator != 0 else { return nil }
            let value = mul(mul(numerator, alpha(root * (firstRoot - 1))), alpha(255 - log[Int(denominator)]))
            word[position] ^= value
        }
        return found.count
    }
}

/// Burst-Dekoder eines Kanals bei 105 kS/s (10 Werte je Symbol).
///
/// Die Werte einer Übertragung werden ab dem Synchronpunkt gepuffert. Scheitert
/// die Fehlerkorrektur mit der Abtastung genau am Synchronpunkt, wird mit ±1
/// und ±2 Werten Versatz erneut demoduliert – wie beim BLE-Empfänger rettet
/// das Übertragungen, deren Synchronpunkt knapp daneben lag.
final class VDL2ChannelDecoder {
    struct Decoded {
        var frames: [[UInt8]]
        var corrected: Int
        var power: Float
        var lengthBits: Int
        /// Versatz der Abtastung, mit dem es gelang (0 = Synchronpunkt).
        var offset: Int
    }

    private enum State { case search, collect }
    private static let sps = VDL2Coding.samplesPerSymbol
    private static let syncSkip = 3
    private static let syncThreshold: Float = 4
    private static let bufferLength = VDL2Coding.preambleSymbols * sps
    private static let margin = 3
    private static let offsets = [0, 1, -1, 2, -2]

    private var phases = [Float](repeating: 0, count: bufferLength)
    private var ringRe = [Float](repeating: 0, count: bufferLength)
    private var ringIm = [Float](repeating: 0, count: bufferLength)
    private var index = 0
    private var skip = 0
    private var errors: [Float] = [1000, 1000, 1000]   // jüngster zuerst
    /// Steigung (Frequenzablage je Symbol) der vorigen Auswertung = am Minimum.
    private var lastSlope: Float = 0
    private var syncSlope: Float = 0
    private var state = State.search
    private var slope: Float = 0
    private var burstRe: [Float] = []
    private var burstIm: [Float] = []
    /// Index des Synchronpunkts im Burst-Puffer.
    private var burstStart = 0
    private var neededSymbols: Int?
    private var headerOffset = 0
    private var headerFixes = 0
    private var layout: VDL2Coding.Layout?
    private var lengthBits = 0

    private let regressionX: [Float]
    private let regressionDenominator: Float
    private let target: [Float]

    private(set) var syncs = 0
    private(set) var headerErrors = 0
    private(set) var bursts = 0
    private(set) var badBursts = 0
    /// Übertragungen, die erst mit versetzter Abtastung gelangen.
    private(set) var rescued = 0
    /// Zur Fehlersuche: jede Übertragung mit Länge, Ergebnis und Pegel.
    private(set) var burstLog: [(lengthBits: Int, ok: Bool, powerDB: Float)] = []

    init() {
        let count = VDL2Coding.preambleSymbols
        let mean = Float(count - 1) / 2
        regressionX = (0..<count).map { Float($0) - mean }
        regressionDenominator = regressionX.reduce(0) { $0 + $1 * $1 }
        target = VDL2Coding.preamblePhases.map { Float($0) * .pi / 4 }
    }

    /// Verarbeitet komplexe Werte; liefert die AVLC-Rahmen fertiger Übertragungen.
    func process(_ re: [Float], _ im: [Float]) -> [Decoded] {
        var done: [Decoded] = []
        for n in re.indices {
            let i = re[n], q = im[n]
            switch state {
            case .search:
                index = (index + 1) % Self.bufferLength
                phases[index] = atan2f(q, i)
                ringRe[index] = i; ringIm[index] = q
                skip += 1
                guard skip >= Self.syncSkip else { continue }
                skip = 0
                if let offset = checkSync() {
                    syncs += 1
                    // Synchronpunkt liegt `offset` Werte zurück (≤ 0); mit Rand davor kopieren.
                    let back = -offset + Self.margin
                    burstRe.removeAll(keepingCapacity: true); burstIm.removeAll(keepingCapacity: true)
                    for k in stride(from: back, through: 0, by: -1) {
                        let at = ((index - k) % Self.bufferLength + Self.bufferLength) % Self.bufferLength
                        burstRe.append(ringRe[at]); burstIm.append(ringIm[at])
                    }
                    burstStart = Self.margin
                    slope = syncSlope
                    neededSymbols = nil
                    state = .collect
                }
            case .collect:
                burstRe.append(i); burstIm.append(q)
                let symbols = (burstRe.count - burstStart - 1 - Self.margin) / Self.sps
                if neededSymbols == nil {
                    guard symbols >= 9 else { continue }
                    if !readHeader() { headerErrors += 1; reset() }
                } else if let needed = neededSymbols, symbols >= needed {
                    bursts += 1
                    let power = symbolPower(offset: 0, symbols: needed)
                    if let decoded = decodeBurst(symbols: needed, power: power) {
                        done.append(decoded)
                    } else {
                        badBursts += 1
                    }
                    if burstLog.count < 2000 { burstLog.append((lengthBits, done.last?.lengthBits == lengthBits, 10 * log10(max(power, 1e-12)))) }
                    reset()
                }
            }
        }
        return done
    }

    /// Symbole ab dem Synchronpunkt (+ Versatz) differentiell demodulieren → Bits.
    private func demodulate(offset: Int, symbols: Int) -> [UInt8] {
        var bits: [UInt8] = []
        bits.reserveCapacity(symbols * 3)
        var at = burstStart + offset
        guard at >= 0, at < burstRe.count else { return bits }
        var last = atan2f(burstIm[at], burstRe[at])
        for _ in 0..<symbols {
            at += Self.sps
            guard at < burstRe.count else { break }
            let phase = atan2f(burstIm[at], burstRe[at])
            var delta = (phase - last - slope).truncatingRemainder(dividingBy: 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            last = phase
            let value = VDL2Coding.gray[Int((delta / (.pi / 4)).rounded()) % 8]
            bits.append((value >> 2) & 1); bits.append((value >> 1) & 1); bits.append(value & 1)
        }
        return bits
    }

    private func symbolPower(offset: Int, symbols: Int) -> Float {
        var sum: Float = 0
        var at = burstStart + offset + Self.sps
        var count = 0
        while at < burstRe.count, count < symbols {
            sum += burstRe[at] * burstRe[at] + burstIm[at] * burstIm[at]
            at += Self.sps; count += 1
        }
        return count > 0 ? sum / Float(count) : 0
    }

    /// Kopf (25 Bit) lesen – mit den Versätzen der Reihe nach, bis einer passt.
    private func readHeader() -> Bool {
        for offset in Self.offsets {
            var bits = demodulate(offset: offset, symbols: 9)
            guard bits.count >= VDL2Coding.headerBits else { continue }
            var state = VDL2Coding.scramblerSeed
            VDL2Coding.scramble(&bits, state: &state)
            let raw = bits[0..<VDL2Coding.headerBits].reduce(UInt32(0)) { $0 << 1 | UInt32($1) }
            guard let header = VDL2Coding.decodeHeader(raw),
                  header.lengthBits <= (header.corrected > 0 ? 0x1FFF : 0x3FFF),
                  let layout = VDL2Coding.layout(lengthBits: header.lengthBits) else { continue }
            self.layout = layout
            lengthBits = header.lengthBits
            headerOffset = offset
            headerFixes = header.corrected
            neededSymbols = (VDL2Coding.headerBits + 8 * (layout.dataOctets + layout.fecOctets) + 2) / 3
            return true
        }
        return false
    }

    private func decodeBurst(symbols: Int, power: Float) -> Decoded? {
        guard let layout else { return nil }
        let needed = 8 * (layout.dataOctets + layout.fecOctets)
        let order = [headerOffset] + Self.offsets.filter { $0 != headerOffset }
        for (attempt, offset) in order.enumerated() {
            var bits = demodulate(offset: offset, symbols: symbols)
            guard bits.count >= VDL2Coding.headerBits + needed else { continue }
            var state = VDL2Coding.scramblerSeed
            VDL2Coding.scramble(&bits, state: &state)
            // Kopf mit diesem Versatz erneut prüfen – sonst passt die Länge nicht.
            let raw = bits[0..<VDL2Coding.headerBits].reduce(UInt32(0)) { $0 << 1 | UInt32($1) }
            guard let header = VDL2Coding.decodeHeader(raw), header.lengthBits == lengthBits else { continue }
            let payload = Array(bits[VDL2Coding.headerBits..<(VDL2Coding.headerBits + needed)])
            guard let (frames, corrected) = Self.frames(bits: payload, layout: layout, lengthBits: lengthBits) else { continue }
            if attempt > 0 { rescued += 1 }
            return Decoded(frames: frames, corrected: corrected + header.corrected, power: power, lengthBits: lengthBits, offset: offset)
        }
        return nil
    }

    private func reset() {
        state = .search
        neededSymbols = nil
        layout = nil
        errors = [1000, 1000, 1000]
    }

    /// Phasenfehler der letzten 16 Symbolzeitpunkte gegen die Präambel; nach
    /// Durchlaufen eines Minimums unter der Schwelle: Versatz des Synchronpunkts.
    private func checkSync() -> Int? {
        let count = VDL2Coding.preambleSymbols
        var err = [Float](repeating: 0, count: count)
        var unwrap: Float = 0
        var previous: Float = 0
        var mean: Float = 0
        for k in 0..<count {
            let value = phases[(index + (k + 1) * Self.sps) % Self.bufferLength] - target[k]
            if k > 0 {
                let diff = value - previous
                if diff > .pi { unwrap -= 2 * .pi } else if diff < -.pi { unwrap += 2 * .pi }
            }
            previous = value
            err[k] = value + unwrap
            mean += err[k]
        }
        mean /= Float(count)
        var slopeSum: Float = 0
        for k in 0..<count {
            err[k] -= mean
            slopeSum += regressionX[k] * err[k]
        }
        let slopeNow = slopeSum / regressionDenominator
        var total: Float = 0
        for k in 0..<count {
            let e = err[k] - slopeNow * regressionX[k]
            total += e * e
        }
        errors = [total, errors[0], errors[1]]
        if errors[1] < Self.syncThreshold, errors[0] > errors[1] {
            // Parabel durch (−2d, e2), (−d, e1), (0, e0): Scheitel.
            let d = Float(Self.syncSkip)
            let a = errors[2], b = errors[1], c = errors[0]
            let curvature = a - 2 * b + c
            let vertex = -d + (curvature != 0 ? d * (a - c) / (2 * curvature) : 0)
            errors = [1000, 1000, 1000]
            // Fast flache Parabel: Scheitel beliebig weit weg oder NaN – vor Int() klemmen.
            let limit = Float(Self.bufferLength)
            let offset = vertex.isFinite ? Int(max(-limit, min(limit, vertex)).rounded()) : 0
            // Steigung gehört zum Minimum (vorige Auswertung).
            syncSlope = lastSlope
            return max(-(Self.bufferLength - 1), min(0, offset))
        }
        lastSlope = slopeNow
        return nil
    }

    /// Bits nach dem Kopf → AVLC-Rahmen. `nil`, wenn der Reed-Solomon scheitert.
    static func frames(bits: [UInt8], layout: VDL2Coding.Layout, lengthBits: Int) -> (frames: [[UInt8]], corrected: Int)? {
        let data = VDL2Coding.bytesLSBFirst(Array(bits[0..<(8 * layout.dataOctets)]))
        let fec = VDL2Coding.bytesLSBFirst(Array(bits[(8 * layout.dataOctets)..<(8 * (layout.dataOctets + layout.fecOctets))]))
        var table = [[UInt8]](repeating: [UInt8](repeating: 0, count: VDL2Coding.rsN), count: layout.blocks)
        guard VDL2Coding.deinterleave(data, rows: layout.blocks, width: VDL2Coding.rsK, offset: 0, into: &table) else { return nil }
        let lastFEC = VDL2Coding.fecCount(lastBlock: layout.lastBlockOctets)
        let fecRows = lastFEC == 0 ? layout.blocks - 1 : layout.blocks
        if fecRows > 0 {
            guard VDL2Coding.deinterleave(fec, rows: fecRows, width: VDL2Coding.rsN - VDL2Coding.rsK,
                                          offset: VDL2Coding.rsK, into: &table) else { return nil }
        }
        var corrected = 0
        var payload: [UInt8] = []
        for r in 0..<layout.blocks {
            let isLast = r == layout.blocks - 1
            let parity = isLast ? lastFEC : VDL2Coding.rsN - VDL2Coding.rsK
            if parity > 0 {
                let erasures = Array((VDL2Coding.rsK + parity)..<VDL2Coding.rsN)
                guard let fixes = VDL2ReedSolomon.decode(&table[r], erasures: erasures) else { return nil }
                corrected += max(0, fixes - erasures.count)
            }
            payload += table[r][0..<(isLast ? layout.lastBlockOctets : VDL2Coding.rsK)]
        }
        var stream = VDL2Coding.bitsLSBFirst(payload)
        if lengthBits < stream.count { stream.removeLast(stream.count - lengthBits) }
        guard let frames = VDL2Coding.unstuffFrames(stream) else { return nil }
        return (frames.map(VDL2Coding.bytesLSBFirst), corrected)
    }
}

/// Teilt 2,1 MS/s in die VDL2-Kanäle zu je 105 kS/s auf.
final class VDL2Channelizer {
    static let inputRate = 2_100_000.0
    static let outputRate = 105_000.0
    private static let period = 84          // 2,1 MHz / 25 kHz

    let channelOffsets: [Double]
    private(set) var channelPowerDB: [Float]
    private let filter1: [Float]
    private let filter2: [Float]
    private var states: [State]

    private struct State {
        var oscRe: [Float]
        var oscIm: [Float]
        var oscIndex = 0
        var h1Re: [Float] = [], h1Im: [Float] = []
        var h2Re: [Float] = [], h2Im: [Float] = []
    }

    init(channelOffsets: [Double]) {
        self.channelOffsets = channelOffsets
        channelPowerDB = channelOffsets.map { _ in -100 }
        filter1 = RadioDemodulator.lowpass(taps: 63, cutoff: 50_000, rate: Self.inputRate)
        filter2 = RadioDemodulator.lowpass(taps: 95, cutoff: 9_500, rate: Self.inputRate / 4)
        states = channelOffsets.map { offset in
            State(oscRe: (0..<Self.period).map { Float(cos(-2 * Double.pi * offset * Double($0) / Self.inputRate)) },
                  oscIm: (0..<Self.period).map { Float(sin(-2 * Double.pi * offset * Double($0) / Self.inputRate)) })
        }
    }

    func process(_ iq: Data) -> [(re: [Float], im: [Float])] {
        let count = iq.count / 2
        guard count > 0 else { return channelOffsets.map { _ in ([], []) } }
        var inRe = [Float](repeating: 0, count: count)
        var inIm = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var sumI = 0, sumQ = 0
            for n in 0..<count { sumI += Int(p[2 * n]); sumQ += Int(p[2 * n + 1]) }
            // Gleichanteil weg (DC-Spitze des HackRF).
            let dcI = Float(sumI) / Float(count), dcQ = Float(sumQ) / Float(count)
            for n in 0..<count {
                inRe[n] = (Float(p[2 * n]) - dcI) / 128
                inIm[n] = (Float(p[2 * n + 1]) - dcQ) / 128
            }
        }
        var outputs: [(re: [Float], im: [Float])] = []
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        for index in states.indices {
            var s = states[index]
            var k = s.oscIndex
            for n in 0..<count {
                let i = inRe[n], q = inIm[n], c = s.oscRe[k], d = s.oscIm[k]
                re[n] = i * c - q * d
                im[n] = i * d + q * c
                k += 1
                if k == Self.period { k = 0 }
            }
            s.oscIndex = k
            let (aRe, aIm) = RadioDemodulator.decimateComplex(re, im, history: &s.h1Re, &s.h1Im, filter: filter1, factor: 4)
            let (bRe, bIm) = RadioDemodulator.decimateComplex(aRe, aIm, history: &s.h2Re, &s.h2Im, filter: filter2, factor: 5)
            if !bRe.isEmpty {
                var a: Float = 0, b: Float = 0
                vDSP_measqv(bRe, 1, &a, vDSP_Length(bRe.count))
                vDSP_measqv(bIm, 1, &b, vDSP_Length(bIm.count))
                channelPowerDB[index] = 10 * log10(max(a + b, 1e-12))
            }
            states[index] = s
            outputs.append((bRe, bIm))
        }
        return outputs
    }
}

/// VDL2-Empfang: vier europäische Kanäle in einem Fenster um 136,85 MHz.
final class VDL2Receiver {
    static let channelsMHz = [136.725, 136.775, 136.875, 136.975]
    static let centerHz = 136_850_000.0

    let channelizer: VDL2Channelizer
    private let decoders: [VDL2ChannelDecoder]
    private(set) var badFrames = 0
    /// ATN-Schichten über X.25 (zustandsbehaftet: Fragmente je Verbindung).
    let atn = ATNDecoder()

    init() {
        channelizer = VDL2Channelizer(channelOffsets: Self.channelsMHz.map { $0 * 1e6 - Self.centerHz })
        decoders = Self.channelsMHz.map { _ in VDL2ChannelDecoder() }
    }

    var syncs: Int { decoders.reduce(0) { $0 + $1.syncs } }
    var bursts: Int { decoders.reduce(0) { $0 + $1.bursts } }
    var badBursts: Int { decoders.reduce(0) { $0 + $1.badBursts } }
    var rescued: Int { decoders.reduce(0) { $0 + $1.rescued } }
    var burstLog: [(lengthBits: Int, ok: Bool, powerDB: Float)] { decoders.flatMap(\.burstLog) }

    func process(_ iq: Data) -> [VDL2Frame] {
        var result: [VDL2Frame] = []
        for (index, channel) in channelizer.process(iq).enumerated() {
            for burst in decoders[index].process(channel.re, channel.im) {
                for bytes in burst.frames {
                    guard var frame = VDL2Coding.parseAVLC(bytes) else { badFrames += 1; continue }
                    frame.frequencyMHz = Self.channelsMHz[index]
                    frame.levelDB = Double(10 * log10(max(burst.power, 1e-12)))
                    frame.corrected = burst.corrected
                    frame.acars?.frequencyMHz = frame.frequencyMHz
                    frame.acars?.levelDB = frame.levelDB
                    if frame.kind == .information, bytes.count > 11, let packet = VDL2Coding.parseX25(Array(bytes[9..<(bytes.count - 2)])), packet.isData {
                        let key = String(format: "%06X-%06X-%d", frame.source, frame.destination, packet.lcn)
                        frame.atn = atn.handle(x25Data: packet.user, more: packet.more, key: key, fromAircraft: frame.sourceType == .aircraft)
                        frame.x25User = packet.user
                    }
                    result.append(frame)
                }
            }
        }
        return result
    }
}
