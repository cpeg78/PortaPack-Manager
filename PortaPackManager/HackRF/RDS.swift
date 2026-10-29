import Accelerate
import Foundation

/// Was ein UKW-Sender per RDS überträgt (IEC 62106).
struct RDSInfo: Sendable, Equatable {
    var pi: UInt16?
    /// Sendername (8 Zeichen); `nil` an Stellen, die noch fehlen.
    var programService: [Character?] = Array(repeating: nil, count: 8)
    var radioText: [Character?] = Array(repeating: nil, count: 64)
    var programType: Int?
    var trafficProgram = false
    var trafficAnnouncement = false
    var music = true
    /// Uhrzeit des Senders (UTC) und Ortszeitversatz in Minuten.
    var clock: Date?
    var localOffsetMinutes: Int?
    var alternativeFrequencies: Set<Double> = []
    var groups = 0
    var blocksGood = 0
    var blocksBad = 0
    /// Davon per Bündelkorrektur gerettet (zählt auch in `blocksGood`).
    var blocksCorrected = 0

    var programServiceText: String {
        String(programService.map { $0 ?? " " }).trimmingCharacters(in: .whitespaces)
    }

    var radioTextString: String {
        String(radioText.prefix { $0 != "\r" }.map { $0 ?? " " }).trimmingCharacters(in: .whitespaces)
    }

    var programTypeName: String? {
        programType.flatMap { RDSInfo.programTypeNames.indices.contains($0) ? RDSInfo.programTypeNames[$0] : nil }
    }

    /// Anteil fehlerfreier Blöcke seit dem letzten Zurücksetzen.
    var blockQuality: Double {
        let total = blocksGood + blocksBad
        return total == 0 ? 0 : Double(blocksGood) / Double(total)
    }

    /// Programmarten nach RDS (Europa).
    static let programTypeNames = [
        String(localized: "Keine Angabe"), String(localized: "Nachrichten"), String(localized: "Aktuelles"),
        String(localized: "Information"), String(localized: "Sport"), String(localized: "Bildung"),
        String(localized: "Hörspiel"), String(localized: "Kultur"), String(localized: "Wissenschaft"),
        String(localized: "Unterhaltung"), String(localized: "Pop"), String(localized: "Rock"),
        String(localized: "Unterhaltungsmusik"), String(localized: "Leichte Klassik"), String(localized: "Ernste Klassik"),
        String(localized: "Sonstige Musik"), String(localized: "Wetter"), String(localized: "Wirtschaft"),
        String(localized: "Kinder"), String(localized: "Soziales"), String(localized: "Religion"),
        String(localized: "Hörertelefon"), String(localized: "Reise"), String(localized: "Freizeit"),
        String(localized: "Jazz"), String(localized: "Country"), String(localized: "Landesmusik"),
        String(localized: "Oldies"), String(localized: "Folk"), String(localized: "Dokumentation"),
        String(localized: "Alarmtest"), String(localized: "Alarm"),
    ]
}

// MARK: - Bits → Blöcke → Gruppen

/// Synchronisiert auf 26-Bit-Blöcke, prüft die Prüfwörter und wertet die
/// Gruppen 0A/0B (Sendername, AF), 2A/2B (Radiotext) und 4A (Uhrzeit) aus.
/// Erwartet die Bits nach der Biphase-Entscheidung, aber noch differentiell
/// kodiert – die Differenzdekodierung passiert hier.
struct RDSDecoder: Sendable {
    /// Erzeugerpolynom x¹⁰ + x⁸ + x⁷ + x⁵ + x⁴ + x³ + 1.
    static let generator: UInt32 = 0x5B9
    /// Offsetwörter A, B, C, C', D.
    static let offsets: [UInt32] = [0x0FC, 0x198, 0x168, 0x350, 0x1B4]

    private(set) var info = RDSInfo()
    private(set) var synced = false
    /// Bits seit dem letzten gültigen Block – für den Halbbit-Schlupf.
    private(set) var bitsWithoutBlock = 0

    private var previousBit: UInt8 = 0
    private var register: UInt32 = 0
    private var bitCount = 0
    /// Offset-Index des nächsten erwarteten Blocks (0 = A, 1 = B, 2 = C/C', 3 = D).
    private var expected = 0
    private var bitsInBlock = 0
    private var lastMatch: (position: Int, slot: Int)?
    private var recentErrors: [Bool] = []
    private var group: [UInt16?] = [nil, nil, nil, nil]
    private var radioTextFlag: Bool?

    /// Rest der Polynomdivision eines 26-Bit-Worts – bei fehlerfreiem Block das Offsetwort.
    static func syndrome(_ word: UInt32) -> UInt32 {
        var value = word & 0x3FF_FFFF
        for bit in stride(from: 25, through: 10, by: -1) where value & (1 << bit) != 0 {
            value ^= generator << (bit - 10)
        }
        return value
    }

    /// Prüfwort für 16 Datenbits mit Offset (für Tests und Gegenproben).
    static func checkword(_ data: UInt16, offset: Int) -> UInt32 {
        syndrome(UInt32(data) << 10) ^ offsets[offset]
    }

    /// Längste Fehlerbündel, die im synchronisierten Zustand korrigiert werden.
    /// Der Code (26,16) erkennt Bündel bis 5 Bit sicher und kann sie korrigieren
    /// (IEC 62106, Anhang B) – aber je mehr Syndrome als „korrigierbar“ gelten,
    /// desto öfter wird ein zerstörter Block falsch „repariert“. Simulation
    /// (Kanalbitfehler, Differenzdekodierung macht daraus Zweierbündel), p = 1 %:
    /// ohne Korrektur 76 % gute Blöcke; ≤ 2 Bit 97 % bei 0,3 % falschen; ≤ 5 Bit
    /// 97,6 % bei 1,1 % falschen. Daher wie redsea höchstens 2 Bit.
    static let maxBurstLength = 2

    /// Fehlerbündel je Syndrom (Syndrom = Rest des Fehlermusters, ohne Offset),
    /// für alle Bündel bis `maxLength` Bit an allen 26 Lagen. Bis 5 Bit sind alle
    /// Syndrome verschieden (Bündelkorrektur-Eigenschaft des Codes).
    static func burstTable(maxLength: Int) -> [UInt32: UInt32] {
        var table: [UInt32: UInt32] = [:]
        for length in 1...maxLength {
            let inner = length >= 2 ? 1 << (length - 2) : 1
            for middle in 0..<inner {
                let pattern: UInt32 = length == 1 ? 1 : (1 << UInt32(length - 1)) | (UInt32(middle) << 1) | 1
                for shift in 0...(26 - length) {
                    let error = pattern << UInt32(shift)
                    table[syndrome(error)] = error
                }
            }
        }
        return table
    }

    private static let bursts = burstTable(maxLength: maxBurstLength)

    /// Korrigiert ein Bündel im Block, wenn das Syndrom zu einem passt.
    /// Liefert das korrigierte Wort oder nil. Block C: `versionB` (aus Block B)
    /// wählt zwischen C und C'; ist B unbekannt, gilt nur eine eindeutige
    /// Korrektur – C und C' unterscheiden sich um 0x238, ein Bündel zum einen
    /// Offset kann wie ein anderes zum zweiten aussehen.
    static func correct(_ word: UInt32, slot: Int, versionB: Bool? = nil) -> UInt32? {
        let remainder = syndrome(word)
        let candidates: [UInt32]
        switch (slot, versionB) {
        case (2, false?): candidates = [offsets[2]]
        case (2, true?): candidates = [offsets[3]]
        case (2, nil): candidates = [offsets[2], offsets[3]]
        default: candidates = [offsets[slot == 3 ? 4 : slot]]
        }
        let fixes = candidates.compactMap { bursts[remainder ^ $0].map { word ^ $0 } }
        return fixes.count == 1 ? fixes[0] : nil
    }

    /// Slot (0…3) zu einem Syndrom; C' zählt als Slot 2.
    private static func slot(forSyndrome syndrome: UInt32) -> Int? {
        switch syndrome {
        case offsets[0]: 0
        case offsets[1]: 1
        case offsets[2], offsets[3]: 2
        case offsets[4]: 3
        default: nil
        }
    }

    mutating func reset() {
        self = RDSDecoder()
    }

    /// Statistik zurücksetzen (bei Senderwechsel bleibt nichts Altes stehen).
    mutating func clearInfo() {
        info = RDSInfo()
        radioTextFlag = nil
    }

    mutating func push(_ rawBit: UInt8) {
        let bit = rawBit ^ previousBit
        previousBit = rawBit
        register = ((register << 1) | UInt32(bit)) & 0x3FF_FFFF
        bitCount += 1
        bitsWithoutBlock += 1

        if !synced {
            guard bitCount >= 26, let slot = Self.slot(forSyndrome: Self.syndrome(register)) else { return }
            if let last = lastMatch, bitCount - last.position == 26, (last.slot + 1) % 4 == slot {
                synced = true
                expected = (slot + 1) % 4
                bitsInBlock = 0
                recentErrors = []
                group = [nil, nil, nil, nil]
                accept(slot: slot)
            }
            lastMatch = (bitCount, slot)
            return
        }

        bitsInBlock += 1
        guard bitsInBlock == 26 else { return }
        bitsInBlock = 0
        let slot = expected
        let syndrome = Self.syndrome(register)
        var good = Self.slot(forSyndrome: syndrome) == slot
        if !good, let fixed = Self.correct(register, slot: slot, versionB: group[1].map { $0 & 0x0800 != 0 }) {
            // Nur im synchronisierten Zustand: die Blocklage ist bekannt, sonst
            // fände die Suche überall „korrigierbare“ Blöcke.
            register = fixed
            good = true
            info.blocksCorrected += 1
        }
        recentErrors.append(!good)
        if recentErrors.count > 50 { recentErrors.removeFirst() }
        if good {
            info.blocksGood += 1
            accept(slot: slot)
        } else {
            info.blocksBad += 1
            group[slot] = nil
        }
        if slot == 3 { finishGroup() }
        expected = (slot + 1) % 4
        // Mehr als ein Drittel kaputt → Synchronisation verloren.
        if recentErrors.count >= 30, recentErrors.filter({ $0 }).count > recentErrors.count / 3 {
            synced = false
            lastMatch = nil
        }
    }

    private mutating func accept(slot: Int) {
        bitsWithoutBlock = 0
        if slot == 0 { group = [nil, nil, nil, nil] }
        group[slot] = UInt16(register >> 10)
    }

    private mutating func finishGroup() {
        defer { group = [nil, nil, nil, nil] }
        guard let b = group[1] else { return }
        let a = group[0]
        if let a { info.pi = a }
        info.groups += 1
        let type = Int(b >> 12)
        let versionB = b & 0x0800 != 0
        info.trafficProgram = b & 0x0400 != 0
        info.programType = Int((b >> 5) & 0x1F)
        let c = group[2], d = group[3]

        switch (type, versionB) {
        case (0, _):
            info.trafficAnnouncement = b & 0x10 != 0
            info.music = b & 0x08 != 0
            if let d {
                let index = Int(b & 0x03) * 2
                info.programService[index] = Self.character(UInt8(d >> 8))
                info.programService[index + 1] = Self.character(UInt8(d & 0xFF))
            }
            if !versionB, let c {
                for code in [UInt8(c >> 8), UInt8(c & 0xFF)] where (1...204).contains(code) {
                    info.alternativeFrequencies.insert(87.5 + Double(code) * 0.1)
                }
            }
        case (2, _):
            let flag = b & 0x10 != 0
            if let previous = radioTextFlag, previous != flag {
                info.radioText = Array(repeating: nil, count: 64)
            }
            radioTextFlag = flag
            let segment = Int(b & 0x0F)
            if versionB {
                if let d {
                    let index = segment * 2
                    info.radioText[index] = Self.character(UInt8(d >> 8))
                    info.radioText[index + 1] = Self.character(UInt8(d & 0xFF))
                }
            } else {
                let index = segment * 4
                if let c {
                    info.radioText[index] = Self.character(UInt8(c >> 8))
                    info.radioText[index + 1] = Self.character(UInt8(c & 0xFF))
                }
                if let d {
                    info.radioText[index + 2] = Self.character(UInt8(d >> 8))
                    info.radioText[index + 3] = Self.character(UInt8(d & 0xFF))
                }
            }
        case (4, false):
            guard let c, let d else { return }
            let mjd = (Int(b & 0x03) << 15) | Int(c >> 1)
            let hour = (Int(c & 0x01) << 4) | Int(d >> 12)
            let minute = Int((d >> 6) & 0x3F)
            let offset = Int(d & 0x1F) * 30 * (d & 0x20 != 0 ? -1 : 1)
            guard hour < 24, minute < 60, mjd > 40_000 else { return }
            // MJD 40587 = 1970-01-01
            let seconds = Double(mjd - 40_587) * 86_400 + Double(hour * 3600 + minute * 60)
            info.clock = Date(timeIntervalSince1970: seconds)
            info.localOffsetMinutes = offset
        default:
            break
        }
    }

    /// RDS-Zeichensatz (IEC 62106, Tabelle E.1): ASCII plus Akzentzeichen.
    static func character(_ code: UInt8) -> Character {
        switch code {
        case 0x0D: return "\r"
        case 0x20...0x7D: return Character(UnicodeScalar(code))
        case 0x80...0xFF:
            return latinTable[Int(code) - 0x80]
        default:
            return " "
        }
    }

    /// Zeilen 0x80–0xFF; 0xFF ist unbelegt.
    private static let latinTable: [Character] = Array(
        "áàéèíìóòúùÑÇŞß¡Ĳ" +
        "âäêëîïôöûüñçşğıĳ" +
        "ªα©‰Ğěňőπ€£$←↑→↓" +
        "º¹²³±İńűµ¿÷°¼½¾§" +
        "ÁÀÉÈÍÌÓÒÚÙŘČŠŽĐĿ" +
        "ÂÄÊËÎÏÔÖÛÜřčšžđŀ" +
        "ÃÅÆŒŷÝÕØÞŊŔĆŚŹŦð" +
        "ãåæœŵýõøþŋŕćśźŧ ")
}

// MARK: - MPX → Bits

/// Holt die RDS-Bits aus dem MPX-Signal (240 kHz, Diskriminatorausgabe):
/// 57-kHz-Hilfsträger heruntermischen, Tiefpass ÷20 auf 12 kHz,
/// Costas-Schleife für die Trägerphase, Biphase-Matched-Filter und
/// Früh-spät-Taktregelung auf 1187,5 Bit/s.
final class RDSDemodulator: @unchecked Sendable {
    static let inputRate = 240_000.0
    static let bitRate = 1187.5
    static let decimation = 20
    static let rate = inputRate / Double(decimation)          // 12 kHz
    static let samplesPerBit = rate / bitRate                  // ≈ 10,1

    private(set) var decoder = RDSDecoder()

    private let filter: [Float]
    private let mixRe: [Float]
    private let mixIm: [Float]
    private var mixIndex = 0
    private var histRe: [Float] = []
    private var histIm: [Float] = []

    // Costas-Schleife
    private var phase: Float = 0
    private var frequency: Float = 0
    private var power: Float = 1e-6

    // Integrierte Basisbandwerte (Präfixsumme) für das Matched-Filter.
    private var cumulative: [Double] = [0]
    private var cumulativeStart = 0          // absoluter Index von cumulative[0]
    private var running = 0.0
    private var nextSample = 0.0             // absolute Abtastzeit des nächsten Bits
    private var level: Double = 0

    init() {
        filter = RadioDemodulator.lowpass(taps: 151, cutoff: 2_400, rate: Self.inputRate)
        // 57 kHz bei 240 kHz: 57/240 = 19/80 → Periode 80 Abtastwerte.
        mixRe = (0..<80).map { Float(cos(-2 * Double.pi * 57_000 * Double($0) / Self.inputRate)) }
        mixIm = (0..<80).map { Float(sin(-2 * Double.pi * 57_000 * Double($0) / Self.inputRate)) }
        nextSample = Self.samplesPerBit
    }

    func reset() {
        decoder.reset()
        histRe = []; histIm = []
        phase = 0; frequency = 0; power = 1e-6
        cumulative = [0]; cumulativeStart = 0; running = 0
        nextSample = Self.samplesPerBit
        level = 0
    }

    /// Senderwechsel: Anzeige leeren, Synchronisation neu suchen.
    func retuned() {
        reset()
    }

    var info: RDSInfo { decoder.info }

    func process(_ mpx: [Float]) {
        guard !mpx.isEmpty else { return }
        var re = [Float](repeating: 0, count: mpx.count)
        var im = [Float](repeating: 0, count: mpx.count)
        var k = mixIndex
        for n in mpx.indices {
            re[n] = mpx[n] * mixRe[k]
            im[n] = mpx[n] * mixIm[k]
            k += 1
            if k == 80 { k = 0 }
        }
        mixIndex = k
        let (bRe, bIm) = RadioDemodulator.decimateComplex(re, im, history: &histRe, &histIm, filter: filter, factor: Self.decimation)

        // Costas-Schleife (BPSK): Fehler = I·Q, normiert auf die Leistung.
        var real = [Double](repeating: 0, count: bRe.count)
        for n in bRe.indices {
            let c = cosf(phase), s = sinf(phase)
            let i = bRe[n] * c + bIm[n] * s
            let q = bIm[n] * c - bRe[n] * s
            power += 0.002 * (i * i + q * q - power)
            let error = max(-1, min(1, i * q / max(power, 1e-12)))
            frequency += 0.0001 * error
            frequency = max(-0.05, min(0.05, frequency))
            phase += frequency + 0.02 * error
            if phase > .pi { phase -= 2 * .pi } else if phase < -.pi { phase += 2 * .pi }
            real[n] = Double(i)
        }
        integrateAndSlice(real)
    }

    private func integrateAndSlice(_ samples: [Double]) {
        for value in samples {
            running += value
            cumulative.append(running)
        }
        let period = Self.samplesPerBit
        let half = period / 2
        let quarter = period / 4
        let end = Double(cumulativeStart + cumulative.count - 1)
        while nextSample + quarter < end {
            let center = matched(at: nextSample, half: half)
            let early = matched(at: nextSample - quarter, half: half)
            let late = matched(at: nextSample + quarter, half: half)
            level += 0.01 * (abs(center) - level)
            decoder.push(center > 0 ? 1 : 0)
            // Früh-spät: zum größeren Betrag hin nachführen.
            let error = (abs(late) - abs(early)) / max(abs(late) + abs(early), 1e-12)
            nextSample += period + 0.1 * error * quarter
            // Kein gültiger Block seit langem → vermutlich auf der falschen Bithälfte.
            if decoder.bitsWithoutBlock > 0, decoder.bitsWithoutBlock % 400 == 0 {
                nextSample += half
            }
        }
        // Nicht mehr benötigte Vergangenheit abschneiden.
        let keepFrom = Int(nextSample - period * 2) - cumulativeStart
        if keepFrom > 4096 {
            cumulative.removeFirst(keepFrom)
            cumulativeStart += keepFrom
        }
    }

    /// Biphase-Matched-Filter: erste Bithälfte positiv, zweite negativ, Ende bei `t`.
    private func matched(at t: Double, half: Double) -> Double {
        let a = integral(t - 2 * half), b = integral(t - half), c = integral(t)
        return (b - a) - (c - b)
    }

    /// Präfixsumme an einer gebrochenen Stelle (linear interpoliert).
    private func integral(_ t: Double) -> Double {
        let x = t - Double(cumulativeStart)
        let i = Int(x.rounded(.down))
        guard i >= 0 else { return cumulative.first ?? 0 }
        guard i + 1 < cumulative.count else { return cumulative.last ?? 0 }
        let f = x - Double(i)
        return cumulative[i] * (1 - f) + cumulative[i + 1] * f
    }
}
