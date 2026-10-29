import Foundation

/// Eine dekodierte Mode-S-Extended-Squitter-Nachricht (DF17/18).
struct ADSBMessage: Sendable {
    enum Content: Sendable {
        case identification(callsign: String, category: Int)
        case airbornePosition(altitude: Int?, oddFormat: Bool, latCPR: Int, lonCPR: Int)
        case velocity(groundSpeed: Double, track: Double, verticalRate: Int?)
        case other(typeCode: Int)
    }

    let icao: UInt32
    let downlinkFormat: Int
    let typeCode: Int
    let content: Content
    let raw: [UInt8]
    let date: Date
    /// Amplitude der Präambelimpulse, 0…1 (1 = Vollaussteuerung einer Achse) –
    /// für den Pegel im Beast-Format.
    var signal: Double = 0

    var icaoHex: String { String(format: "%06X", icao) }
    var rawHex: String { raw.map { String(format: "%02X", $0) }.joined() }
}

/// Mode-S-Demodulator für 2 MS/s (wie dump1090 im 2-MHz-Betrieb).
///
/// Erwartet vorzeichenbehaftete 8-Bit-IQ-Paare. Jede Mode-S-Hälfte eines Bits
/// dauert 0,5 µs = 1 Abtastwert. Nur DF17/18 mit gültiger CRC-24 werden
/// ausgegeben.
///
/// Seit 29.10.2026 (Review L3) wie dump1090:
/// - **Phasenkorrektur**: Liegt die Abtastung zwischen zwei Halbbits (Energie
///   der Präambelimpulse in den Nachbarwerten), wird ein Rahmen mit falscher
///   Prüfsumme ein zweites Mal entschieden, mit dump1090s Korrektur (Folgewert
///   nach einer 1 × 5/4, nach einer 0 × 4/5).
/// - **Ein-Bit-Fehlerkorrektur** über eine Syndromtabelle (CRC-24 ist linear:
///   Rest einer Nachricht mit einem gekippten Bit = Rest des Einzelbitfehlers),
///   nur DF17/18 und nicht im DF-Feld. Zusätzlich vorsichtiger als dump1090:
///   korrigierte Rahmen nur für Adressen, die in den letzten 5 min fehlerfrei
///   empfangen wurden – sonst würde aus Rauschen hin und wieder ein Phantom.
/// - Innenschleife ohne Allokation: Betrag in einen vorab angelegten Puffer,
///   Bits in einen festen Arbeitsbereich, ein Array erst nach gültiger CRC.
final class ADSBDemodulator: @unchecked Sendable {
    /// Betragspuffer: vorne der Rest des letzten Blocks, dahinter der neue Block.
    private var buffer: UnsafeMutablePointer<UInt16>
    private var capacity: Int
    private var carryCount = 0
    /// Erste Suchposition im Rest (ein Rahmen am Blockende wurde schon gelesen).
    private var carrySkip = 0
    /// Arbeitsbereich für die Bits: Rahmen ohne und mit Phasenkorrektur.
    private let plainBits = UnsafeMutablePointer<UInt8>.allocate(capacity: 14)
    private let phaseBits = UnsafeMutablePointer<UInt8>.allocate(capacity: 14)
    /// Adressen fehlerfrei empfangener Rahmen → Zeitpunkt (für die Ein-Bit-Korrektur).
    private var knownAddresses: [UInt32: Date] = [:]
    private(set) var framesSeen = 0
    private(set) var framesValid = 0
    /// Davon per Ein-Bit-Korrektur gerettet.
    private(set) var framesCorrected = 0
    /// Davon erst mit Phasenkorrektur gültig.
    private(set) var framesPhaseCorrected = 0

    static let sampleRate: UInt32 = 2_000_000
    static let frequency: UInt64 = 1_090_000_000
    private static let longFrameSamples = (8 + 112) * 2
    /// Wie lange eine fehlerfrei gehörte Adresse Korrekturen erlaubt.
    static let knownAddressSeconds: TimeInterval = 300

    init() {
        capacity = 1 << 18
        buffer = .allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
        plainBits.deallocate()
        phaseBits.deallocate()
    }

    /// Betragstabelle: |I + jQ| für alle 256×256 Kombinationen.
    private static let magnitudeTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 65536)
        for i in 0..<256 {
            for q in 0..<256 {
                let fi = Double(Int8(bitPattern: UInt8(i))), fq = Double(Int8(bitPattern: UInt8(q)))
                table[i << 8 | q] = UInt16(min(65535, (fi * fi + fq * fq).squareRoot() * 360))
            }
        }
        return table
    }()

    func process(_ iq: Data, now: Date = Date()) -> [ADSBMessage] {
        let count = iq.count / 2
        let total = carryCount + count
        if total > capacity {
            let grown = UnsafeMutablePointer<UInt16>.allocate(capacity: total)
            grown.update(from: buffer, count: carryCount)
            buffer.deallocate()
            buffer = grown
            capacity = total
        }
        let m = buffer
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            Self.magnitudeTable.withUnsafeBufferPointer { table in
                let out = m + carryCount
                for n in 0..<count {
                    out[n] = table[Int(bytes[2 * n]) << 8 | Int(bytes[2 * n + 1])]
                }
            }
        }

        var results: [ADSBMessage] = []
        let limit = total - Self.longFrameSamples
        var seen = 0
        var j = carrySkip
        while j < limit {
            // Vorfilter: Impulse bei 0 und 2 – verwirft fast alle Positionen mit zwei Vergleichen.
            guard m[j] > m[j + 1], m[j + 2] > m[j + 3] else { j += 1; continue }
            guard Self.preamble(m, at: j) else { j += 1; continue }
            seen += 1
            if var message = decodeCandidate(m, at: j, now: now) {
                let pulses = Int(m[j]) + Int(m[j + 2]) + Int(m[j + 7]) + Int(m[j + 9])
                message.signal = min(1, Double(pulses) / (4 * 128 * 360))
                results.append(message)
                j += message.raw.count * 16 + 16
                continue
            }
            j += 1
        }
        framesSeen += seen
        framesValid += results.count

        // Rest für Rahmen über die Blockgrenze nach vorn holen.
        let keep = min(total, Self.longFrameSamples)
        memmove(m, m + (total - keep), keep * MemoryLayout<UInt16>.stride)
        carrySkip = max(0, j - (total - keep))
        carryCount = keep
        if knownAddresses.count > 4000 {
            knownAddresses = knownAddresses.filter { now.timeIntervalSince($0.value) < Self.knownAddressSeconds }
        }
        return results
    }

    /// Präambel: Impulse bei 0, 2, 7, 9 (je 0,5 µs), Pausen dazwischen und danach.
    @inline(__always)
    private static func preamble(_ m: UnsafeMutablePointer<UInt16>, at j: Int) -> Bool {
        guard m[j] > m[j + 1], m[j + 1] < m[j + 2], m[j + 2] > m[j + 3], m[j + 3] < m[j],
              m[j + 4] < m[j], m[j + 5] < m[j], m[j + 6] < m[j],
              m[j + 7] > m[j + 8], m[j + 8] < m[j + 9], m[j + 9] > m[j + 6] else { return false }
        let high = (Int(m[j]) + Int(m[j + 2]) + Int(m[j + 7]) + Int(m[j + 9])) / 6
        guard Int(m[j + 4]) < high, Int(m[j + 5]) < high else { return false }
        for k in 11...14 where Int(m[j + k]) >= high { return false }
        return true
    }

    /// dump1090 `detectOutOfPhase`: Energie eines Präambelimpulses im Nachbarwert.
    @inline(__always)
    private static func outOfPhase(_ m: UnsafeMutablePointer<UInt16>, at j: Int) -> Bool {
        m[j + 3] > m[j + 2] / 3 || m[j + 10] > m[j + 9] / 3 || m[j + 6] > m[j + 7] / 3
            || (j > 0 && m[j - 1] > m[j + 1] / 3)
    }

    /// Entscheidet die Bits ab `j + 16` nach `out`; liefert das Downlink-Format.
    /// Nur bei DF17/18 werden alle 112 Bits gelesen, sonst nur die ersten fünf.
    /// `phaseCorrection`: dump1090 `applyPhaseCorrection` – der erste Wert des
    /// Folgebits wird nach einer 1 um 5/4 angehoben, nach einer 0 um 4/5 gesenkt.
    @inline(__always)
    private static func demodulate(_ m: UnsafeMutablePointer<UInt16>, at j: Int,
                                   into out: UnsafeMutablePointer<UInt8>, phaseCorrection: Bool) -> Int {
        let p = m + (j + 16)
        var df = 0
        var bits = 5
        var a = Int(p[0])
        var byte: UInt8 = 0
        var i = 0
        while i < bits {
            let b = Int(p[2 * i + 1])
            let one = a > b
            byte = byte << 1 | (one ? 1 : 0)
            if i & 7 == 7 { out[i >> 3] = byte; byte = 0 }
            if i == 4 {
                df = Int(byte)
                if df == 17 || df == 18 { bits = 112 }
            }
            let next = Int(p[2 * i + 2])
            a = phaseCorrection ? (one ? next * 5 / 4 : next * 4 / 5) : next
            i += 1
        }
        return df
    }

    /// Ein Kandidat: ohne Korrektur, mit Phasenkorrektur, dann Ein-Bit-Korrektur.
    private func decodeCandidate(_ m: UnsafeMutablePointer<UInt16>, at j: Int, now: Date) -> ADSBMessage? {
        let plainDF = Self.demodulate(m, at: j, into: plainBits, phaseCorrection: false)
        let plainLong = plainDF == 17 || plainDF == 18
        var plainSyndrome: UInt32 = 1
        if plainLong {
            plainSyndrome = Self.crc24(plainBits, count: 14)
            if plainSyndrome == 0, let message = accept(plainBits, now: now, corrected: false) { return message }
        }
        var phaseSyndrome: UInt32 = 1
        var phaseLong = false
        if Self.outOfPhase(m, at: j) {
            let df = Self.demodulate(m, at: j, into: phaseBits, phaseCorrection: true)
            phaseLong = df == 17 || df == 18
            if phaseLong {
                phaseSyndrome = Self.crc24(phaseBits, count: 14)
                if phaseSyndrome == 0, let message = accept(phaseBits, now: now, corrected: false) {
                    framesPhaseCorrected += 1
                    return message
                }
            }
        }
        if plainLong, let message = correctAndAccept(plainBits, syndrome: plainSyndrome, now: now) { return message }
        if phaseLong, let message = correctAndAccept(phaseBits, syndrome: phaseSyndrome, now: now) {
            framesPhaseCorrected += 1
            return message
        }
        return nil
    }

    private func correctAndAccept(_ bits: UnsafeMutablePointer<UInt8>, syndrome: UInt32, now: Date) -> ADSBMessage? {
        guard let bit = Self.singleBitSyndromes[syndrome] else { return nil }
        bits[bit >> 3] ^= 0x80 >> UInt8(bit & 7)
        let icao = UInt32(bits[1]) << 16 | UInt32(bits[2]) << 8 | UInt32(bits[3])
        guard let heard = knownAddresses[icao], now.timeIntervalSince(heard) < Self.knownAddressSeconds,
              let message = accept(bits, now: now, corrected: true) else {
            bits[bit >> 3] ^= 0x80 >> UInt8(bit & 7)
            return nil
        }
        framesCorrected += 1
        return message
    }

    private func accept(_ bits: UnsafeMutablePointer<UInt8>, now: Date, corrected: Bool) -> ADSBMessage? {
        guard let message = Self.decode(Array(UnsafeBufferPointer(start: bits, count: 14)), now: now) else { return nil }
        if !corrected { knownAddresses[message.icao] = now }
        return message
    }

    /// Syndrom eines einzelnen gekippten Bits → Bitposition (5…111; das DF-Feld
    /// wird nicht korrigiert). Für 112 Bit sind alle Syndrome verschieden.
    static let singleBitSyndromes: [UInt32: Int] = {
        var table: [UInt32: Int] = [:]
        for bit in 5..<112 {
            var bytes = [UInt8](repeating: 0, count: 14)
            bytes[bit >> 3] = 0x80 >> UInt8(bit & 7)
            table[crc24(bytes)] = bit
        }
        return table
    }()

    /// Korrigiert höchstens ein gekipptes Bit eines DF17/18-Rahmens (ohne
    /// Adressprüfung). Liefert den korrigierten Rahmen und die Bitposition, `nil`
    /// wenn er schon stimmt oder nicht mit einem Bit zu retten ist.
    static func correctSingleBit(_ bytes: [UInt8]) -> (bytes: [UInt8], bit: Int)? {
        guard bytes.count == 14, case let df = Int(bytes[0] >> 3), df == 17 || df == 18 else { return nil }
        let syndrome = crc24(bytes)
        guard syndrome != 0, let bit = singleBitSyndromes[syndrome] else { return nil }
        var fixed = bytes
        fixed[bit >> 3] ^= 0x80 >> UInt8(bit & 7)
        return (fixed, bit)
    }

    // MARK: - Dekodieren

    static func decode(_ bytes: [UInt8], now: Date = Date()) -> ADSBMessage? {
        guard bytes.count == 14 else { return nil }
        let df = Int(bytes[0] >> 3)
        guard df == 17 || df == 18 else { return nil }
        guard crc24(bytes) == 0 else { return nil }
        let icao = UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let me = Array(bytes[4..<11])
        let tc = Int(me[0] >> 3)
        let content: ADSBMessage.Content
        switch tc {
        case 1...4:
            content = .identification(callsign: callsign(me), category: Int(me[0] & 7))
        case 9...18, 20...22:
            let alt12 = Int(me[1]) << 4 | Int(me[2]) >> 4
            content = .airbornePosition(
                altitude: tc <= 18 ? altitude(alt12) : nil,
                oddFormat: (me[2] >> 2) & 1 == 1,
                latCPR: Int(me[2] & 3) << 15 | Int(me[3]) << 7 | Int(me[4]) >> 1,
                lonCPR: Int(me[4] & 1) << 16 | Int(me[5]) << 8 | Int(me[6]))
        case 19:
            let subtype = Int(me[0] & 7)
            guard subtype == 1 || subtype == 2 else { content = .other(typeCode: tc); break }
            let ewSign = (me[1] & 4) != 0, nsSign = (me[3] & 0x80) != 0
            let ewRaw = Int(me[1] & 3) << 8 | Int(me[2]), nsRaw = Int(me[3] & 0x7F) << 3 | Int(me[4]) >> 5
            guard ewRaw > 0, nsRaw > 0 else { content = .other(typeCode: tc); break }
            let factor = subtype == 2 ? 4.0 : 1.0
            let ew = Double(ewRaw - 1) * factor * (ewSign ? -1 : 1)
            let ns = Double(nsRaw - 1) * factor * (nsSign ? -1 : 1)
            var track = atan2(ew, ns) * 180 / .pi
            if track < 0 { track += 360 }
            let vrRaw = Int(me[4] & 7) << 6 | Int(me[5]) >> 2
            let vr = vrRaw == 0 ? nil : (vrRaw - 1) * 64 * ((me[4] & 8) != 0 ? -1 : 1)
            content = .velocity(groundSpeed: (ew * ew + ns * ns).squareRoot(), track: track, verticalRate: vr)
        default:
            content = .other(typeCode: tc)
        }
        return ADSBMessage(icao: icao, downlinkFormat: df, typeCode: tc, content: content, raw: bytes, date: now)
    }

    private static let charset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######")

    static func callsign(_ me: [UInt8]) -> String {
        var bits: UInt64 = 0
        for k in 1...6 { bits = bits << 8 | UInt64(me[k]) }
        var text = ""
        for k in 0..<8 {
            let index = Int((bits >> UInt64(42 - 6 * k)) & 0x3F)
            text.append(charset[index])
        }
        return text.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// 12-Bit-Höhencode (AC-Feld ohne M-Bit): mit Q-Bit 25-ft-Schritte, ohne Q-Bit
    /// Gillham-Code in 100-ft-Schritten (ältere Transponder und Höhen über
    /// 50 175 ft) – wie dump1090 `decodeAC12Field`. 0 = keine Höhe.
    static func altitude(_ alt12: Int) -> Int? {
        guard alt12 != 0 else { return nil }
        if alt12 & 0x10 != 0 {
            let n = (alt12 & 0xFE0) >> 1 | (alt12 & 0x0F)
            return n * 25 - 1000
        }
        // 13-Bit-Feld herstellen (M = 0 an Bit 6), Gillham → Mode-A-Ordnung → Höhe.
        let id13 = (alt12 & 0xFC0) << 1 | (alt12 & 0x3F)
        guard let hundreds = gillhamHundreds(modeA: modeAOrder(id13)) else { return nil }
        return hundreds * 100
    }

    /// Bits des 13-Bit-Feldes (C1 A1 C2 A2 C4 A4 M B1 D1 B2 D2 B4 D4) in die
    /// Mode-A-Hex-Ordnung (A: 0x7000, B: 0x0700, C: 0x0070, D: 0x0007).
    static func modeAOrder(_ id13: Int) -> Int {
        let map: [(Int, Int)] = [(0x1000, 0x0010), (0x0800, 0x1000), (0x0400, 0x0020), (0x0200, 0x2000),
                                 (0x0100, 0x0040), (0x0080, 0x4000), (0x0020, 0x0100), (0x0010, 0x0001),
                                 (0x0008, 0x0200), (0x0004, 0x0002), (0x0002, 0x0400), (0x0001, 0x0004)]
        var out = 0
        for (from, to) in map where id13 & from != 0 { out |= to }
        return out
    }

    /// Gillham-Code (Mode-A-Ordnung) → Höhe in 100 ft (dump1090 `modeAToModeC`):
    /// D2…B4 sind ein Gray-Code der 500-ft-Stufe, C1 C2 C4 ein Fünferzyklus der
    /// 100-ft-Stufe, rückwärts bei ungerader 500-ft-Stufe. `nil` bei ungültigem Code.
    static func gillhamHundreds(modeA: Int) -> Int? {
        guard modeA & 0xFFFF_8889 == 0, modeA & 0x00F0 != 0 else { return nil }
        var oneHundreds = 0
        if modeA & 0x0010 != 0 { oneHundreds ^= 0x007 }   // C1
        if modeA & 0x0020 != 0 { oneHundreds ^= 0x003 }   // C2
        if modeA & 0x0040 != 0 { oneHundreds ^= 0x001 }   // C4
        if oneHundreds & 5 == 5 { oneHundreds ^= 2 }       // 7 ↔ 5
        guard oneHundreds <= 5 else { return nil }
        var fiveHundreds = 0
        if modeA & 0x0002 != 0 { fiveHundreds ^= 0x0FF }  // D2
        if modeA & 0x0004 != 0 { fiveHundreds ^= 0x07F }  // D4
        if modeA & 0x1000 != 0 { fiveHundreds ^= 0x03F }  // A1
        if modeA & 0x2000 != 0 { fiveHundreds ^= 0x01F }  // A2
        if modeA & 0x4000 != 0 { fiveHundreds ^= 0x00F }  // A4
        if modeA & 0x0100 != 0 { fiveHundreds ^= 0x007 }  // B1
        if modeA & 0x0200 != 0 { fiveHundreds ^= 0x003 }  // B2
        if modeA & 0x0400 != 0 { fiveHundreds ^= 0x001 }  // B4
        if fiveHundreds & 1 != 0 { oneHundreds = 6 - oneHundreds }
        let hundreds = fiveHundreds * 5 + oneHundreds - 13
        return hundreds < -12 ? nil : hundreds
    }

    // MARK: - CRC-24 (Polynom 0xFFF409)

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var c = UInt32(byte) << 16
        for _ in 0..<8 { c = (c & 0x80_0000) != 0 ? (c << 1) ^ 0xFF_F409 : c << 1 }
        return c & 0xFF_FFFF
    }

    /// Rest über die ganze Nachricht inklusive Prüfteil – 0 heißt gültig.
    static func crc24(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { crc24($0.baseAddress!, count: $0.count) }
    }

    /// Wie `crc24(_:)`, auf einem Zeiger (ohne Array, für die Innenschleife).
    static func crc24(_ bytes: UnsafePointer<UInt8>, count: Int) -> UInt32 {
        crcTable.withUnsafeBufferPointer { table in
            var crc: UInt32 = 0
            for k in 0..<(count - 3) {
                crc = ((crc << 8) & 0xFF_FFFF) ^ table[Int(((crc >> 16) ^ UInt32(bytes[k])) & 0xFF)]
            }
            let parity = UInt32(bytes[count - 3]) << 16 | UInt32(bytes[count - 2]) << 8 | UInt32(bytes[count - 1])
            return crc ^ parity
        }
    }
}

/// Ein Flugzeug mit allem, was bisher über es bekannt ist.
struct Aircraft: Identifiable, Sendable {
    let icao: UInt32
    var callsign: String?
    var altitude: Int?
    var groundSpeed: Double?
    var track: Double?
    var verticalRate: Int?
    var latitude: Double?
    var longitude: Double?
    var messages = 0
    var lastSeen: Date
    var evenCPR: (lat: Int, lon: Int, date: Date)?
    var oddCPR: (lat: Int, lon: Int, date: Date)?
    /// Zeitpunkt der letzten Position – Bezug für die örtliche Dekodierung.
    var positionDate: Date?
    /// Bisher empfangene Positionen (für die Flugspur auf der Karte).
    var trail: [(lat: Double, lon: Double)] = []

    var id: UInt32 { icao }
    var icaoHex: String { String(format: "%06X", icao) }
}

/// Sammelt Nachrichten zu Flugzeugen und rechnet Positionen aus CPR-Meldungen.
///
/// Reihenfolge wie in dump1090: ein Gerade/Ungerade-Paar (< 10 s) ist
/// eindeutig und hat Vorrang. Sonst genügt eine einzelne Meldung – örtlich
/// dekodiert relativ zur letzten Position des Flugzeugs (jünger als 60 s,
/// Sprung höchstens so weit, wie ein Flugzeug fliegen kann) oder, beim
/// ersten Kontakt, relativ zum eigenen Standort. Eindeutig ist das nur
/// innerhalb einer halben CPR-Zone (3° Breite ≈ 333 km); ein Flugzeug in
/// 400 km Entfernung erschiene 267 km auf der anderen Seite. Deshalb nur bis
/// `receiverRangeKm`, und das nächste Paar korrigiert notfalls.
struct AircraftTracker: Sendable {
    private(set) var aircraft: [UInt32: Aircraft] = [:]
    /// Eigener Standort; ohne ihn nur Paar-Dekodierung.
    var receiver: (lat: Double, lon: Double)?
    static let receiverRangeKm = 300.0
    /// Schneller fliegt kein Verkehrsflugzeug (≈ 1300 km/h), dazu Rundung.
    static let maximumSpeedKmPerSecond = 0.36

    /// Flugzeuge ohne Meldung seit `date` vergessen. Im Fernbetrieb rund um
    /// die Uhr sammelten sich sonst Tausende an, und Sortieren und Kartenbau
    /// alle 500 ms wurden immer teurer. Das Archiv hat sie ja schon.
    mutating func prune(before date: Date) {
        aircraft = aircraft.filter { $0.value.lastSeen >= date }
    }

    mutating func ingest(_ message: ADSBMessage) {
        var plane = aircraft[message.icao] ?? Aircraft(icao: message.icao, lastSeen: message.date)
        plane.messages += 1
        plane.lastSeen = message.date
        switch message.content {
        case let .identification(callsign, _):
            if !callsign.isEmpty { plane.callsign = callsign }
        case let .airbornePosition(altitude, odd, lat, lon):
            if let altitude { plane.altitude = altitude }
            if odd { plane.oddCPR = (lat, lon, message.date) } else { plane.evenCPR = (lat, lon, message.date) }
            if let position = position(of: plane, cpr: (lat, lon), odd: odd, at: message.date) {
                if let oldLat = plane.latitude, let oldLon = plane.longitude,
                   GeoMath.distanceKm(lat1: oldLat, lon1: oldLon, lat2: position.lat, lon2: position.lon) > 50 {
                    plane.trail.removeAll()   // frühere Position war falsch (Zonen-Mehrdeutigkeit)
                }
                plane.latitude = position.lat
                plane.longitude = position.lon
                plane.positionDate = message.date
                // Nur merken, wenn die Position sich merklich geändert hat (Spur begrenzen).
                if let last = plane.trail.last {
                    if GeoMath.distanceKm(lat1: last.lat, lon1: last.lon, lat2: position.lat, lon2: position.lon) > 0.05 {
                        plane.trail.append((position.lat, position.lon))
                    }
                } else {
                    plane.trail.append((position.lat, position.lon))
                }
                if plane.trail.count > 200 { plane.trail.removeFirst(plane.trail.count - 200) }
            }
        case let .velocity(speed, track, vr):
            plane.groundSpeed = speed
            plane.track = track
            plane.verticalRate = vr
        case .other:
            break
        }
        aircraft[message.icao] = plane
    }

    /// Position aus der neuen CPR-Meldung: Paar, sonst örtlich (siehe oben).
    private func position(of plane: Aircraft, cpr: (Int, Int), odd: Bool, at date: Date) -> (lat: Double, lon: Double)? {
        if let even = plane.evenCPR, let oddFrame = plane.oddCPR,
           abs(even.date.timeIntervalSince(oddFrame.date)) < 10,
           let global = Self.globalPosition(even: (even.lat, even.lon), odd: (oddFrame.lat, oddFrame.lon), newestIsOdd: odd) {
            // Ein Paar aus zwei Flugzeugen gleicher Kennung o. Ä. wäre weit weg.
            if let receiver, GeoMath.distanceKm(lat1: receiver.lat, lon1: receiver.lon, lat2: global.lat, lon2: global.lon) > 700 {
                return nil
            }
            return global
        }
        if let lat = plane.latitude, let lon = plane.longitude, let last = plane.positionDate {
            let seconds = date.timeIntervalSince(last)
            if seconds < 60, let local = Self.localPosition(cpr: cpr, odd: odd, reference: (lat, lon)) {
                let jump = GeoMath.distanceKm(lat1: lat, lon1: lon, lat2: local.lat, lon2: local.lon)
                return jump <= Self.maximumSpeedKmPerSecond * max(seconds, 0) + 2 ? local : nil
            }
        }
        guard plane.latitude == nil || plane.positionDate.map({ date.timeIntervalSince($0) >= 60 }) == true,
              let receiver, let local = Self.localPosition(cpr: cpr, odd: odd, reference: receiver) else { return nil }
        let range = GeoMath.distanceKm(lat1: receiver.lat, lon1: receiver.lon, lat2: local.lat, lon2: local.lon)
        return range <= Self.receiverRangeKm ? local : nil
    }

    mutating func prune(olderThan seconds: TimeInterval, now: Date = Date()) {
        aircraft = aircraft.filter { now.timeIntervalSince($0.value.lastSeen) < seconds }
    }

    var sorted: [Aircraft] {
        aircraft.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: CPR (globale Dekodierung aus einem Gerade/Ungerade-Paar)

    static func nl(_ lat: Double) -> Int {
        let a = abs(lat)
        if a < 1e-9 { return 59 }
        if abs(a - 87) < 1e-9 { return 2 }
        if a > 87 { return 1 }
        let numerator = 1 - cos(Double.pi / 30)
        let denominator = pow(cos(Double.pi / 180 * a), 2)
        return Int(floor(2 * Double.pi / acos(1 - numerator / denominator)))
    }

    private static func mod(_ a: Double, _ b: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + b : r
    }

    /// Örtliche Dekodierung einer einzelnen Meldung relativ zu einem Bezugspunkt
    /// innerhalb einer halben Zone („The 1090 MHz Riddle“, Kap. „Locally
    /// unambiguous position“).
    static func localPosition(cpr: (Int, Int), odd: Bool, reference: (lat: Double, lon: Double)) -> (lat: Double, lon: Double)? {
        let scale = 131072.0
        let i = odd ? 1.0 : 0.0
        let dLat = 360 / (60 - i)
        let latCPR = Double(cpr.0) / scale, lonCPR = Double(cpr.1) / scale
        let j = floor(reference.lat / dLat) + floor(0.5 + mod(reference.lat, dLat) / dLat - latCPR)
        let lat = dLat * (j + latCPR)
        guard abs(lat) <= 90 else { return nil }
        let dLon = 360 / Double(max(nl(lat) - Int(i), 1))
        let m = floor(reference.lon / dLon) + floor(0.5 + mod(reference.lon, dLon) / dLon - lonCPR)
        var lon = dLon * (m + lonCPR)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return (lat, lon)
    }

    static func globalPosition(even: (Int, Int), odd: (Int, Int), newestIsOdd: Bool) -> (lat: Double, lon: Double)? {
        let scale = 131072.0
        let lat0 = Double(even.0), lat1 = Double(odd.0), lon0 = Double(even.1), lon1 = Double(odd.1)
        let j = floor((59 * lat0 - 60 * lat1) / scale + 0.5)
        var rlat0 = 360.0 / 60 * (mod(j, 60) + lat0 / scale)
        var rlat1 = 360.0 / 59 * (mod(j, 59) + lat1 / scale)
        if rlat0 >= 270 { rlat0 -= 360 }
        if rlat1 >= 270 { rlat1 -= 360 }
        guard nl(rlat0) == nl(rlat1) else { return nil }
        let lat: Double, lon: Double
        if newestIsOdd {
            let nl1 = nl(rlat1)
            let ni = Double(max(nl1 - 1, 1))
            let m = floor((lon0 * Double(nl1 - 1) - lon1 * Double(nl1)) / scale + 0.5)
            lon = 360 / ni * (mod(m, ni) + lon1 / scale)
            lat = rlat1
        } else {
            let nl0 = nl(rlat0)
            let ni = Double(max(nl0, 1))
            let m = floor((lon0 * Double(nl0 - 1) - lon1 * Double(nl0)) / scale + 0.5)
            lon = 360 / ni * (mod(m, ni) + lon0 / scale)
            lat = rlat0
        }
        return (lat, lon > 180 ? lon - 360 : lon)
    }
}
