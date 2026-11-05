import Foundation

/// Eine dekodierte Mode-S-Nachricht: Extended Squitter (DF17/18, ADS-B) oder
/// Mode S ohne ADS-B (DF4/5/11/20/21, `typeCode` 0).
struct ADSBMessage: Sendable {
    enum Content: Sendable {
        case identification(callsign: String, category: Int)
        case airbornePosition(altitude: Int?, oddFormat: Bool, latCPR: Int, lonCPR: Int)
        /// TC 5–8: am Boden, mit Rollgeschwindigkeit (kn) und Kurs.
        case surfacePosition(groundSpeed: Double?, track: Double?, oddFormat: Bool, latCPR: Int, lonCPR: Int)
        case velocity(groundSpeed: Double, track: Double, verticalRate: Int?)
        case other(typeCode: Int)
        /// Mode S ohne ADS-B: nur Kennung, bei DF4/20 die Höhe, bei DF5/21 der
        /// Squawk (keine Position); DF20/21 tragen dazu 56 Bit Comm-B (`mb`).
        case surveillance(altitude: Int?, squawk: Int?, mb: [UInt8]? = nil)
        /// TC 28/1: Notfall- bzw. Vorrangstatus samt Squawk.
        case emergency(Emergency, squawk: Int?)
        /// TC 29/1 (ADS-B v2): Zielzustand aus Autopilot bzw. FMS.
        case targetState(TargetState)
        /// TC 31: Betriebsstatus – ADS-B-Version und Positionsgenauigkeit.
        case operationalStatus(version: Int, nacp: Int?)
    }

    /// Notfallstatus aus TC 28 (DO-260B 2.2.3.2.7.8.1.1).
    enum Emergency: Int, Sendable {
        case none = 0, general, medical, minimumFuel, noCommunication, unlawfulInterference, downed, reserved

        var text: String? {
            switch self {
            case .none, .reserved: nil
            case .general: String(localized: "Notfall")
            case .medical: String(localized: "Medizinischer Notfall")
            case .minimumFuel: String(localized: "Treibstoffmangel")
            case .noCommunication: String(localized: "Funkausfall")
            case .unlawfulInterference: String(localized: "Entführung")
            case .downed: String(localized: "Abgestürzt")
            }
        }

        /// Die drei Notfall-Squawks, sonst `nil`.
        init?(squawk: Int) {
            switch squawk {
            case 7500: self = .unlawfulInterference
            case 7600: self = .noCommunication
            case 7700: self = .general
            default: return nil
            }
        }
    }

    /// Was Autopilot bzw. FMS gerade ansteuern (TC 29, Unterart 1).
    struct TargetState: Sendable, Equatable {
        /// Eingestellte Höhe in ft; `fromFMS` = vom Flugmanagementsystem statt MCP/FCU.
        var selectedAltitude: Int?
        var fromFMS = false
        /// Eingestellter Luftdruck (QNH) in hPa.
        var qnh: Double?
        var selectedHeading: Double?
        /// `nil`: Flugzeug meldet die Betriebsarten nicht.
        var modes: AutopilotModes?
    }

    struct AutopilotModes: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let autopilot = AutopilotModes(rawValue: 1)
        static let vnav = AutopilotModes(rawValue: 2)
        static let altitudeHold = AutopilotModes(rawValue: 4)
        static let approach = AutopilotModes(rawValue: 8)
        static let lnav = AutopilotModes(rawValue: 16)
        static let tcas = AutopilotModes(rawValue: 32)

        var text: String {
            var parts: [String] = []
            if contains(.autopilot) { parts.append(String(localized: "Autopilot")) }
            if contains(.lnav) { parts.append("LNAV") }
            if contains(.vnav) { parts.append("VNAV") }
            if contains(.altitudeHold) { parts.append(String(localized: "Höhe halten")) }
            if contains(.approach) { parts.append(String(localized: "Anflug")) }
            return parts.isEmpty ? String(localized: "von Hand") : parts.joined(separator: ", ")
        }
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
/// dauert 0,5 µs = 1 Abtastwert. Ausgegeben werden DF17/18 mit gültiger CRC-24
/// und Mode S ohne ADS-B (siehe unten).
///
/// Mode S ohne ADS-B (seit 03.11.2026; ein Hubschrauber flog ungesehen über):
/// Viele Hubschrauber, Polizei- und Militärmaschinen haben einen Transponder
/// ohne Extended Squitter. Er sendet etwa einmal je Sekunde einen
/// Erfassungs-Squitter (DF11, Prüfteil mit Interrogator-Kennung 0) und
/// beantwortet Radarabfragen (DF4/20 Höhe, DF5/21 Squawk). Wie dump1090:
/// - DF11 mit Rest 0 zählt erst beim zweiten Mal binnen 60 s (Zufallstreffer
///   aus Rauschen wiederholen sich nicht); mit Rest 1…127 (Antwort an ein
///   Radar) nur für schon bestätigte Adressen.
/// - DF4/5/20/21 tragen die Adresse im Prüfteil (Rest = Adresse). Sie zählen
///   nur für Adressen, die fehlerfrei per DF17/18 oder bestätigtem DF11
///   gehört wurden, und verlängern diese Bestätigung nicht.
/// - Keine Ein-Bit-Korrektur, und die DF17-Korrektur bleibt auf DF17/18-Adressen
///   beschränkt – am ADS-B-Pfad ändert sich nichts.
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
    static let maximumKnownAddresses = 4000
    /// Per DF11 bestätigte Adressen (Mode S ohne ADS-B) → letzter Squitter.
    private var squitterAddresses: [UInt32: Date] = [:]
    /// Einmal gehörte DF11-Adressen, die auf die Bestätigung warten.
    private var pendingSquitters: [UInt32: Date] = [:]
    static let squitterConfirmSeconds: TimeInterval = 60
    /// Zahl der gemerkten Adressen (für Tests der Obergrenze).
    var knownAddressCount: Int { knownAddresses.count }
    private(set) var framesSeen = 0
    private(set) var framesValid = 0
    /// Davon per Ein-Bit-Korrektur gerettet.
    private(set) var framesCorrected = 0
    /// Davon erst mit Phasenkorrektur gültig.
    private(set) var framesPhaseCorrected = 0
    /// Davon Mode S ohne ADS-B (DF4/5/11/20/21).
    private(set) var framesModeS = 0

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
        // Harte Obergrenze: Mit gefälschten DF17-Rahmen (CRC-24 ist trivial)
        // und zufälliger Kennung wüchse die Tabelle sonst auch innerhalb des
        // Zeitfensters unbegrenzt (Review 01.11.2026).
        DevicePruning.prune(&knownAddresses, limit: Self.maximumKnownAddresses,
                            maxAge: Self.knownAddressSeconds, now: now) { $0 }
        DevicePruning.prune(&squitterAddresses, limit: Self.maximumKnownAddresses,
                            maxAge: Self.knownAddressSeconds, now: now) { $0 }
        DevicePruning.prune(&pendingSquitters, limit: Self.maximumKnownAddresses,
                            maxAge: Self.squitterConfirmSeconds, now: now) { $0 }
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
    /// DF17/18/20/21 mit 112 Bits, DF4/5/11 mit 56, sonst nur die ersten fünf.
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
                switch df {
                case 17, 18, 20, 21: bits = 112
                case 4, 5, 11: bits = 56
                default: break
                }
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
        } else if let message = acceptModeS(plainBits, df: plainDF, now: now) {
            return message
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
            } else if let message = acceptModeS(phaseBits, df: df, now: now) {
                framesPhaseCorrected += 1
                return message
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

    /// Mode S ohne ADS-B (Regeln oben am Typ); `nil` für alles andere.
    private func acceptModeS(_ bits: UnsafeMutablePointer<UInt8>, df: Int, now: Date) -> ADSBMessage? {
        let count: Int
        switch df {
        case 4, 5, 11: count = 7
        case 20, 21: count = 14
        default: return nil
        }
        let syndrome = Self.crc24(bits, count: count)
        let icao: UInt32
        if df == 11 {
            guard syndrome < 0x80 else { return nil }
            icao = UInt32(bits[1]) << 16 | UInt32(bits[2]) << 8 | UInt32(bits[3])
            if syndrome == 0 {
                if isConfirmed(icao, now: now) {
                    squitterAddresses[icao] = now
                } else if let first = pendingSquitters[icao], now.timeIntervalSince(first) < Self.squitterConfirmSeconds {
                    pendingSquitters[icao] = nil
                    squitterAddresses[icao] = now
                } else {
                    pendingSquitters[icao] = now
                    return nil
                }
            }
        } else {
            icao = syndrome
        }
        guard isConfirmed(icao, now: now) else { return nil }
        framesModeS += 1
        return Self.decodeModeS(Array(UnsafeBufferPointer(start: bits, count: count)), icao: icao, now: now)
    }

    /// Fehlerfrei per DF17/18 oder bestätigtem DF11 gehört (letzte 5 min).
    private func isConfirmed(_ icao: UInt32, now: Date) -> Bool {
        if let heard = knownAddresses[icao], now.timeIntervalSince(heard) < Self.knownAddressSeconds { return true }
        if let heard = squitterAddresses[icao], now.timeIntervalSince(heard) < Self.knownAddressSeconds { return true }
        return false
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
        case 5...8:
            let movement = Int(me[0] & 7) << 4 | Int(me[1] >> 4)
            let trackValid = (me[1] >> 3) & 1 == 1
            let track = Double(Int(me[1] & 7) << 4 | Int(me[2] >> 4)) * 360 / 128
            content = .surfacePosition(
                groundSpeed: surfaceSpeed(movement), track: trackValid ? track : nil,
                oddFormat: (me[2] >> 2) & 1 == 1,
                latCPR: Int(me[2] & 3) << 15 | Int(me[3]) << 7 | Int(me[4]) >> 1,
                lonCPR: Int(me[4] & 1) << 16 | Int(me[5]) << 8 | Int(me[6]))
        case 28 where me[0] & 7 == 1:
            let squawk = squawkDigits(id13: Int(me[1] & 0x1F) << 8 | Int(me[2]))
            content = .emergency(ADSBMessage.Emergency(rawValue: Int(me[1] >> 5)) ?? .reserved, squawk: squawk)
        case 29 where (me[0] >> 1) & 3 == 1:
            content = .targetState(targetState(me))
        case 31:
            let version = Int(me[5] >> 5)
            // NACp steht erst ab Version 1 an dieser Stelle.
            content = .operationalStatus(version: version, nacp: version >= 1 ? Int(me[5] & 0x0F) : nil)
        default:
            content = .other(typeCode: tc)
        }
        return ADSBMessage(icao: icao, downlinkFormat: df, typeCode: tc, content: content, raw: bytes, date: now)
    }

    /// Rollgeschwindigkeit aus dem Bewegungsfeld (DO-260B 2.2.3.2.4.2), in kn.
    static func surfaceSpeed(_ m: Int) -> Double? {
        switch m {
        case 1: 0
        case 2...8: 0.125 * Double(m - 1)
        case 9...12: 1 + 0.25 * Double(m - 9)
        case 13...38: 2 + 0.5 * Double(m - 13)
        case 39...93: 15 + Double(m - 39)
        case 94...108: 70 + 2 * Double(m - 94)
        case 109...123: 100 + 5 * Double(m - 109)
        case 124: 175
        default: nil
        }
    }

    /// TC 29 Unterart 1 (wie pyModeS `adsb.selected_altitude` u. a.): ME-Bits
    /// 9 Quelle, 10–20 Höhe ((n − 1) · 32 ft), 21–29 QNH (800 + (n − 1) · 0,8 hPa),
    /// 30 Kurs gültig, 31–39 Kurs (· 180/256°), 47 Betriebsarten gültig,
    /// 48 Autopilot, 49 VNAV, 50 Höhe halten, 52 Anflug, 53 TCAS, 54 LNAV.
    static func targetState(_ me: [UInt8]) -> ADSBMessage.TargetState {
        func bit(_ n: Int) -> Bool { me[(n - 1) >> 3] & (0x80 >> UInt8((n - 1) & 7)) != 0 }
        func field(_ first: Int, _ count: Int) -> Int {
            (first..<(first + count)).reduce(0) { $0 << 1 | (bit($1) ? 1 : 0) }
        }
        var state = ADSBMessage.TargetState()
        let altitude = field(10, 11), qnh = field(21, 9)
        if altitude > 0 { state.selectedAltitude = (altitude - 1) * 32 }
        state.fromFMS = bit(9)
        if qnh > 0 { state.qnh = 800 + Double(qnh - 1) * 0.8 }
        if bit(30) { state.selectedHeading = Double(field(31, 9)) * 180 / 256 }
        if bit(47) {
            var modes: ADSBMessage.AutopilotModes = []
            if bit(48) { modes.insert(.autopilot) }
            if bit(49) { modes.insert(.vnav) }
            if bit(50) { modes.insert(.altitudeHold) }
            if bit(52) { modes.insert(.approach) }
            if bit(53) { modes.insert(.tcas) }
            if bit(54) { modes.insert(.lnav) }
            state.modes = modes
        }
        return state
    }

    /// 13-Bit-Kennungsfeld (C1 A1 C2 A2 C4 A4 X B1 D1 B2 D2 B4 D4) → Squawk als
    /// vierstellige Dezimalzahl (7700 = „7700“); 0 heißt „kein Code“ → `nil`.
    static func squawkDigits(id13: Int) -> Int? {
        let modeA = modeAOrder(id13)
        guard modeA != 0 else { return nil }
        return (modeA >> 12 & 7) * 1000 + (modeA >> 8 & 7) * 100 + (modeA >> 4 & 7) * 10 + (modeA & 7)
    }

    /// Mode-S-Rahmen ohne ADS-B (Prüfung in `acceptModeS`); `icao` aus dem
    /// Rahmen (DF11) bzw. dem Prüfteil (DF4/5/20/21).
    static func decodeModeS(_ bytes: [UInt8], icao: UInt32, now: Date = Date()) -> ADSBMessage? {
        guard bytes.count == 7 || bytes.count == 14 else { return nil }
        let df = Int(bytes[0] >> 3)
        // DF4/20: Höhe, DF5/21: Kennung – beide im 13-Bit-Feld der Bits 20–32.
        let field13 = Int(bytes[2] & 0x1F) << 8 | Int(bytes[3])
        let altitude: Int?, squawk: Int?
        switch df {
        case 4, 20: (altitude, squawk) = (altitude13(field13), nil)
        case 5, 21: (altitude, squawk) = (nil, squawkDigits(id13: field13))
        case 11: (altitude, squawk) = (nil, nil)
        default: return nil
        }
        let mb = bytes.count == 14 ? Array(bytes[4..<11]) : nil
        return ADSBMessage(icao: icao, downlinkFormat: df, typeCode: 0,
                           content: .surveillance(altitude: altitude, squawk: squawk, mb: mb), raw: bytes, date: now)
    }

    /// 13-Bit-Höhencode der Antworten (AC-Feld mit M-Bit): M = 1 heißt Meter –
    /// kommt praktisch nicht vor, dann keine Höhe. Sonst ohne M-Bit wie im
    /// 12-Bit-Feld der Positionsmeldung.
    static func altitude13(_ ac13: Int) -> Int? {
        guard ac13 & 0x40 == 0 else { return nil }
        return altitude((ac13 & 0x1F80) >> 1 | (ac13 & 0x3F))
    }

    private static let charset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######")

    static func callsign(_ me: [UInt8]) -> String {
        callsign(me, strict: false) ?? ""
    }

    /// Rufzeichen aus 8 × 6 Bit. `strict`: `nil`, sobald ein ungültiges Zeichen
    /// („#“) vorkommt – für Comm-B BDS 2,0, wo erst das die Kennung bestätigt.
    static func callsign(_ me: [UInt8], strict: Bool) -> String? {
        var bits: UInt64 = 0
        for k in 1...6 { bits = bits << 8 | UInt64(me[k]) }
        var text = ""
        for k in 0..<8 {
            let index = Int((bits >> UInt64(42 - 6 * k)) & 0x3F)
            let char = charset[index]
            if char == "#" {
                if strict { return nil }
                continue
            }
            text.append(char)
        }
        return text.trimmingCharacters(in: .whitespaces)
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
    /// ADS-B-Kategorie aus der Kennungsmeldung: TC << 3 | CA (CA ≠ 0).
    var emitter: Int?
    var altitude: Int?
    var groundSpeed: Double?
    var track: Double?
    var verticalRate: Int?
    /// Meldet Bodenpositionen (TC 5–8) – rollt oder steht am Flughafen.
    var onGround = false
    /// Transpondercode (Mode A), vierstellig dezimal geschrieben – erst, wenn
    /// derselbe Code zweimal kam (ein Notfall-Squawk löst eine Mitteilung aus).
    var squawk: Int?
    var pendingSquawk: Int?
    /// Notfallstatus aus TC 28 (`nil` = nie gemeldet; `.none` = gemeldet, kein Notfall).
    var emergencyState: ADSBMessage.Emergency?
    var targetState: ADSBMessage.TargetState?
    /// Comm-B (Mode-S EHS): was die Radarantworten über das Flugzeug verraten.
    var commB = CommB.State()
    var adsbVersion: Int?
    /// Positionsgenauigkeit NACp (0–11; 9 ≈ besser als 30 m).
    var nacp: Int?
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
    var squawkText: String? { squawk.map { String(format: "%04d", $0) } }

    /// Gemeldeter Notfall, sonst einer der Notfall-Squawks 7500/7600/7700.
    var emergency: ADSBMessage.Emergency? {
        if let emergencyState, emergencyState.text != nil { return emergencyState }
        return squawk.flatMap(ADSBMessage.Emergency.init(squawk:))
    }
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
    /// Obergrenze der Tabelle nach Anzahl (wie AIS/APRS): Gefälschte Rahmen mit
    /// zufälliger Kennung ließen sie sonst unbegrenzt wachsen, und das Kopieren,
    /// Sortieren und Abbilden alle 500 ms fräße Speicher und Main Actor.
    static let maximumAircraft = 2000
    /// Punkte je Flugspur (≥ 50 m Abstand): 1000 ≈ 50 km, gut 3 min Reiseflug.
    /// Vorher 200 (≈ 40 s) – zu kurz, um den Kurs zu erkennen (Wunsch 02.11.2026).
    static let trailLimit = 1000
    /// Ohne Meldung so lange bleibt ein Flugzeug in der Tabelle wählbar (3 h).
    static let keepSeconds: TimeInterval = 3 * 3600

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
        case let .identification(callsign, category):
            if !callsign.isEmpty { plane.callsign = callsign }
            if category != 0 { plane.emitter = message.typeCode << 3 | category }
        case let .surfacePosition(speed, track, odd, lat, lon):
            plane.onGround = true
            plane.altitude = nil
            if let speed { plane.groundSpeed = speed }
            if let track { plane.track = track }
            plane.verticalRate = nil
            if let position = surfacePosition(of: plane, cpr: (lat, lon), odd: odd, at: message.date) {
                plane.latitude = position.lat
                plane.longitude = position.lon
                plane.positionDate = message.date
                // Am Boden schon ab 20 m Abstand ein Spurpunkt (Rollwege sind kurz).
                let moved = plane.trail.last.map {
                    GeoMath.distanceKm(lat1: $0.lat, lon1: $0.lon, lat2: position.lat, lon2: position.lon) > 0.02
                } ?? true
                if moved {
                    plane.trail.append((position.lat, position.lon))
                    if plane.trail.count > Self.trailLimit { plane.trail.removeFirst(plane.trail.count - Self.trailLimit) }
                }
            }
        case let .airbornePosition(altitude, odd, lat, lon):
            plane.onGround = false
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
                if plane.trail.count > Self.trailLimit { plane.trail.removeFirst(plane.trail.count - Self.trailLimit) }
            }
        case let .velocity(speed, track, vr):
            plane.groundSpeed = speed
            plane.track = track
            plane.verticalRate = vr
        case let .surveillance(altitude, squawk, mb):
            if let altitude { plane.altitude = altitude }
            if let squawk { Self.take(squawk: squawk, into: &plane) }
            if let mb, let register = CommB.infer(mb, plane: plane) { register.apply(to: &plane, at: message.date) }
        case let .emergency(state, squawk):
            plane.emergencyState = state
            if let squawk { Self.take(squawk: squawk, into: &plane) }
        case let .targetState(state):
            plane.targetState = state
        case let .operationalStatus(version, nacp):
            plane.adsbVersion = version
            if let nacp { plane.nacp = nacp }
        case .other:
            break
        }
        aircraft[message.icao] = plane
        if aircraft.count > Self.maximumAircraft {
            DevicePruning.prune(&aircraft, limit: Self.maximumAircraft, maxAge: Self.keepSeconds, now: message.date) { $0.lastSeen }
        }
    }

    /// Ein neuer Code gilt erst beim zweiten Mal – ein einzelner verfälschter
    /// Rahmen soll keinen Notfall-Squawk vortäuschen.
    private static func take(squawk: Int, into plane: inout Aircraft) {
        if squawk == plane.squawk || squawk == plane.pendingSquawk {
            plane.squawk = squawk
            plane.pendingSquawk = nil
        } else {
            plane.pendingSquawk = squawk
        }
    }

    /// Bodenposition: Die CPR-Zonen sind viermal kleiner (90° statt 360°), eine
    /// einzelne Meldung ist nur bis ≈ 80 km um den Bezug eindeutig – Bezug ist die
    /// letzte Position (jünger als 60 s), sonst der eigene Standort.
    private func surfacePosition(of plane: Aircraft, cpr: (Int, Int), odd: Bool, at date: Date) -> (lat: Double, lon: Double)? {
        let recent = plane.positionDate.map { date.timeIntervalSince($0) < 60 } ?? false
        let reference: (lat: Double, lon: Double)
        if recent, let lat = plane.latitude, let lon = plane.longitude { reference = (lat, lon) }
        else if let receiver { reference = receiver }
        else { return nil }
        guard let position = Self.localPosition(cpr: cpr, odd: odd, reference: reference, surface: true) else { return nil }
        let distance = GeoMath.distanceKm(lat1: reference.lat, lon1: reference.lon, lat2: position.lat, lon2: position.lon)
        return distance <= (recent ? 5 : 80) ? position : nil
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
    /// `surface`: Bodenmeldung – Zonen über 90° statt 360°.
    static func localPosition(cpr: (Int, Int), odd: Bool, reference: (lat: Double, lon: Double),
                              surface: Bool = false) -> (lat: Double, lon: Double)? {
        let scale = 131072.0
        let i = odd ? 1.0 : 0.0
        let span = surface ? 90.0 : 360.0
        let dLat = span / (60 - i)
        let latCPR = Double(cpr.0) / scale, lonCPR = Double(cpr.1) / scale
        let j = floor(reference.lat / dLat) + floor(0.5 + mod(reference.lat, dLat) / dLat - latCPR)
        let lat = dLat * (j + latCPR)
        guard abs(lat) <= 90 else { return nil }
        let dLon = span / Double(max(nl(lat) - Int(i), 1))
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
        // Wie dump1090: Breiten außerhalb ±90° sind Datenmüll (für 90…270 wäre
        // `nl` beider Werte 1 und die Prüfung darunter griffe nicht).
        guard (-90...90).contains(rlat0), (-90...90).contains(rlat1), nl(rlat0) == nl(rlat1) else { return nil }
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
