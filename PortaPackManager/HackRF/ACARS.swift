import Foundation

/// CRC-16 von ACARS wie in acarsdec: CCITT-Polynom reflektiert (0x8408),
/// Startwert 0, kein Endwert (CRC-16/KERMIT). Gerechnet über alle Zeichen
/// nach SOH bis einschließlich ETX/ETB – mit Paritätsbit; die beiden
/// Prüfbytes folgen mit dem niederwertigen Byte zuerst, dann ist der Rest 0.
enum ACARSCRC {
    private static let table: [UInt16] = (0..<256).map { n -> UInt16 in
        var crc = UInt16(n)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        return crc
    }

    static func checksum<S: Sequence>(_ bytes: S, initial: UInt16 = 0) -> UInt16 where S.Element == UInt8 {
        var crc = initial
        for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)] }
        return crc
    }
}

/// Eine ACARS-Nachricht (ARINC 618), Felder wie acarsdec sie ausgibt.
struct ACARSMessage: Identifiable, Sendable, Equatable {
    var id = 0
    var date = Date()
    var frequencyMHz: Double = 0
    var levelDB: Double = 0
    /// Korrigierte Paritätsfehler.
    var corrected = 0
    var mode: Character
    /// Kennzeichen, ohne die führenden Punkte.
    var registration: String
    /// Quittung: Block-ID der bestätigten Nachricht oder „!“ für NAK.
    var acknowledge: Character
    var label: String
    var blockID: Character?
    var messageNumber: String?
    var flight: String?
    var text: String
    /// Endet mit ETB: weitere Blöcke folgen.
    var continued: Bool
    /// ICAO-Adresse des Flugzeugs (nur über VDL2 bekannt).
    var icao: UInt32?
    /// Zahl der zusammengesetzten Blöcke (mehrteilige Nachricht).
    var blocks = 1
    /// Schon gedeutete Felder (CPDLC/CM aus dem ATN) – die Deutung übernimmt sie.
    var details: [[String]] = []

    /// Nachrichtennummer ohne den Folgebuchstaben (D34A, D34B → D34).
    var messageNumberBase: String? { messageNumber.map { String($0.prefix(3)) } }
    /// Folgebuchstabe der Nachrichtennummer (A, B, …).
    var messageSequence: Character? { messageNumber.flatMap { $0.count == 4 ? $0.last : nil } }
    var interpretation: ACARSInterpretation { ACARSInterpreter.interpret(self) }

    /// Blöcke mit Ziffer als Block-ID kommen vom Flugzeug (downlink).
    var isDownlink: Bool { blockID.map { $0.isASCII && $0.isNumber } ?? false }

    var labelMeaning: String? { Self.labelNames[label] }

    /// Häufige Labels (ARINC 620, kleine Auswahl).
    static let labelNames: [String: String] = [
        "_d": String(localized: "keine Nachricht (Quittung)"), "SQ": String(localized: "Squitter der Bodenstation"), "Q0": String(localized: "Verbindungstest"),
        "H1": String(localized: "Nachricht an/von Bordrechner"), "5Z": String(localized: "Airline-Mitteilung"), "B6": "ADS-C",
        "RA": String(localized: "Freitext an Cockpit/Drucker"), "C1": String(localized: "Freitext an Cockpit/Drucker"),
        "SA": String(localized: "Datenlink-Statusmeldung (Media Advisory)"), "QA": String(localized: "OOOI: Gate verlassen (OUT)"),
        "QB": String(localized: "OOOI: abgehoben (OFF)"), "QC": String(localized: "OOOI: gelandet (ON)"), "QD": String(localized: "OOOI: am Gate (IN)"),
        "QE": String(localized: "OOOI: OUT mit Kraftstoff"), "QF": String(localized: "OOOI: OFF mit Kraftstoff"), "Q1": String(localized: "ETA-Meldung"), "Q2": String(localized: "ETA-Meldung"),
        "10": String(localized: "Positionsmeldung/Anforderung"), "15": String(localized: "Positionsmeldung"), "16": String(localized: "Positionsmeldung"), "20": String(localized: "Positionsmeldung"),
        "21": String(localized: "Positionsmeldung"), "22": String(localized: "Positionsmeldung"), "23": String(localized: "Positionsmeldung"), "2Z": String(localized: "Freitext an die Airline"),
        "30": String(localized: "Wetter/ATIS"), "33": String(localized: "Flugplan"), "3Z": String(localized: "Zeitmeldung"), "4A": String(localized: "Freitext"), "4M": String(localized: "Wartungsmeldung"),
        "51": String(localized: "Wetter (METAR/TAF)"), "52": String(localized: "Wetter"), "54": String(localized: "Wetter"), "80": String(localized: "Airline-Meldung"), "81": String(localized: "Airline-Meldung"),
        "82": String(localized: "Airline-Meldung"), "83": String(localized: "Airline-Meldung (Flugplan/ETA)"), "84": String(localized: "Airline-Meldung"), "85": String(localized: "Airline-Meldung"),
        "86": String(localized: "Airline-Meldung"), "87": String(localized: "Airline-Meldung"), "88": String(localized: "Airline-Meldung"), "89": String(localized: "Airline-Meldung"),
        "8D": String(localized: "Flugdaten"), "8E": String(localized: "Flugdaten"), "A6": String(localized: "ATS: ADS-C/CPDLC (Uplink)"), "AA": String(localized: "ATS: ADS-C/CPDLC (Uplink)"),
        "BA": String(localized: "ATS: CPDLC (binär)"), "H2": String(localized: "Wartungsrechner"), "MA": String(localized: "MIAM-Nachricht"),
        "C2": String(localized: "Drucker"), "C3": String(localized: "Drucker"), "1L": String(localized: "Airline-Meldung"), "XID": String(localized: "VDL2-Verbindungsaufbau (Position)"), "ATN": String(localized: "ATN-Datenverkehr (X.25: CM/CPDLC)"),
        "CPDLC": String(localized: "Lotsen-Datenfunk (CPDLC über ATN)"), "CM": String(localized: "ATN-Kontextverwaltung (Anmeldung)"),
    ]

    /// Unterkennung bei Label H1 („#M1B“ → M1) und ihre Bedeutung.
    var sublabel: String? {
        guard label == "H1" else { return nil }
        if isDownlink, text.count >= 4, text.first == "#", text[text.index(text.startIndex, offsetBy: 3)] == "B" {
            return String(text.dropFirst().prefix(2))
        }
        if !isDownlink, text.hasPrefix("- #"), text.count >= 5 { return String(text.dropFirst(3).prefix(2)) }
        return nil
    }
    static let sublabelNames: [String: String] = [
        "M1": String(localized: "Flugmanagement (FMS)"), "MD": String(localized: "Flugmanagement (FMS)"), "DF": String(localized: "Flugdatenerfassung (ACMS)"),
        "CF": String(localized: "Zentraler Wartungsrechner (CMC)"), "T1": String(localized: "Wartung/Technik"), "T2": String(localized: "Wartung/Technik"),
        "EI": String(localized: "Triebwerksdaten"), "S1": String(localized: "Satcom"), "PS": String(localized: "Kabine/Passagierdienst"), "H1": String(localized: "Hersteller"),
    ]
}

/// Bitstrom → Blöcke, Zustandsfolge wie `decodeAcars` in acarsdec: Zwei
/// SYN suchen (auch invertiert – dann dreht die MSK-Stufe ihre Polarität),
/// SOH, Zeichen bis ETX/ETB, zwei CRC-Bytes. Bits kommen mit dem
/// niederwertigen zuerst.
enum ACARSFrame {
    static let syn: UInt8 = 0x16
    static let soh: UInt8 = 0x01
    static let stx: UInt8 = 0x02
    static let etx: UInt8 = 0x83   // 0x03 mit Paritätsbit
    static let etb: UInt8 = 0x97   // 0x17 mit Paritätsbit
    static let del: UInt8 = 0x7F

    /// 7 Bit + ungerade Parität im obersten Bit.
    static func withParity(_ char: UInt8) -> UInt8 {
        let c = char & 0x7F
        return c.nonzeroBitCount % 2 == 0 ? c | 0x80 : c
    }

    static func parityOK(_ byte: UInt8) -> Bool { byte.nonzeroBitCount % 2 == 1 }

    /// Prüft einen Block (Zeichen nach SOH bis ETX/ETB samt Parität und
    /// die zwei CRC-Bytes). Bis zu zwei Paritätsfehler werden über die CRC
    /// korrigiert (je ein Bit im betroffenen Zeichen).
    static func validate(_ block: [UInt8], crc: [UInt8]) -> (text: [UInt8], corrected: Int)? {
        guard block.count >= 13, crc.count == 2 else { return nil }
        var txt = block
        // Zeichen 12 ist STX oder ETX – acarsdec erzwingt eines von beiden.
        txt[12] &= (etx | stx)
        txt[12] |= (etx & stx)
        let errors = txt.indices.filter { !parityOK(txt[$0]) }
        guard errors.count <= 2 else { return nil }
        func ok(_ candidate: [UInt8]) -> Bool { ACARSCRC.checksum(candidate + crc) == 0 }
        if errors.isEmpty {
            return ok(txt) ? (txt.map { $0 & 0x7F }, 0) : nil
        }
        // Jede Kombination aus einem gekippten Bit je fehlerhaftem Zeichen.
        let combinations = Int(pow(8.0, Double(errors.count)))
        for combination in 0..<combinations {
            var candidate = txt
            var rest = combination
            for index in errors {
                candidate[index] ^= 1 << UInt8(rest % 8)
                rest /= 8
            }
            if ok(candidate) { return (candidate.map { $0 & 0x7F }, errors.count) }
        }
        return nil
    }

    /// Zerlegt den geprüften Block (ohne Parität) in die Felder.
    static func parse(_ txt: [UInt8]) -> ACARSMessage? {
        guard txt.count >= 13 else { return nil }
        func char(_ byte: UInt8) -> Character { Character(Unicode.Scalar(byte)) }
        let registration = String(txt[1...7].filter { $0 != 0x2E }.map(char))   // ohne „.“
        let ack = txt[8] == 0x15 ? "!" : char(txt[8])
        let label = String([char(txt[9]), txt[10] == 0x7F ? "d" : char(txt[10])])
        let blockID: Character? = txt[11] == 0 ? nil : char(txt[11])
        let start = txt[12]
        let end = txt[txt.count - 1]
        var message = ACARSMessage(mode: char(txt[0]), registration: registration.trimmingCharacters(in: .whitespaces),
                                   acknowledge: ack, label: label, blockID: blockID, text: "", continued: end == 0x17)
        guard start != 0x03 else { return message }   // kein Text
        var k = 13
        let last = txt.count - 1
        // Bei 13 Zeichen ist k > last – ohne die Bedingung entstünde ein
        // umgekehrter Bereich (Funkrahmen aus der Luft – sonst Absturz).
        if message.isDownlink, k < last {
            let number = txt[k..<min(k + 4, last)]
            k += number.count
            let flight = txt[k..<min(k + 6, last)]
            k += flight.count
            message.messageNumber = String(number.map(char))
            message.flight = String(flight.map(char)).trimmingCharacters(in: .whitespaces)
        }
        if k < last {
            message.text = String(txt[k..<last].map { byte -> Character in
                switch byte {
                case 0x0A, 0x0D: return "\n"
                case 0x20...0x7E: return char(byte)
                default: return "·"
                }
            })
        }
        return message
    }
}

/// MSK-Demodulator und Blocksuche eines Kanals – eine Übertragung von
/// `demodMSK` aus acarsdec (msk.c): Hüllkurve mit 12,5 kHz, VCO auf
/// 1800 Hz (Mitte zwischen 1200 und 2400 Hz), Bittakt aus derselben Phase
/// (1800/2400 = 3/4 Umlauf je Bit), Matched Filter als halbe Kosinuswelle
/// über zwei Bit, Entscheidung abwechselnd auf Real- und Imaginärteil, PLL
/// auf den Quadraturfehler. Bei MSK ist die Entscheidung bereits das
/// Datenbit: 2400 Hz heißt „wie das vorige Bit“, 1200 Hz „Wechsel“.
final class ACARSChannelDecoder {
    static let sampleRate = 12_500.0
    private static let filterLength = Int(sampleRate) / 1200 + 1      // 11
    private static let oversampling = 12
    private static let matched: [Float] = {
        let count = filterLength * oversampling + 1
        return (0..<count).map { i in
            max(0, Float(cos(2 * Double.pi * 600 / sampleRate / Double(oversampling) * Double(i - (count - 1) / 2))))
        }
    }()
    private static let pllGain = 38e-4
    private static let pllCoefficient = 0.52

    private enum State { case waitSYN, syn2, soh, text, crc1, crc2, end }

    private var phase = 0.0
    private var clock = 0.0
    private var frequencyError = 0.0
    private var symbolIndex = 0
    private var bufferRe: [Float]
    private var bufferIm: [Float]
    private var bufferIndex = 0

    private var outBits: UInt8 = 0
    private var bitsNeeded = 8
    private var state = State.waitSYN
    private var block: [UInt8] = []
    private var crc: [UInt8] = []
    private var levelSum = 0.0
    private var levelCount = 0

    /// Fertige Blöcke: Zeichen, CRC-Bytes und mittlerer Pegel.
    private(set) var blocks: [(text: [UInt8], crc: [UInt8], levelDB: Double)] = []

    init() {
        bufferRe = [Float](repeating: 0, count: Self.filterLength)
        bufferIm = [Float](repeating: 0, count: Self.filterLength)
    }

    /// Verarbeitet Hüllkurvenwerte (12,5 kHz, ohne Gleichanteil); liefert fertige Blöcke.
    func process(_ samples: [Float]) -> [(text: [UInt8], crc: [UInt8], levelDB: Double)] {
        blocks.removeAll(keepingCapacity: true)
        let n = Self.filterLength
        let threeHalfPi = 3 * Double.pi / 2
        Self.matched.withUnsafeBufferPointer { h in
            for x in samples {
                let step = 1800 / Self.sampleRate * 2 * .pi + frequencyError
                phase += step
                if phase >= 2 * .pi { phase -= 2 * .pi }
                bufferRe[bufferIndex] = x * Float(cos(phase))
                bufferIm[bufferIndex] = -x * Float(sin(phase))
                bufferIndex = (bufferIndex + 1) % n

                clock += step
                guard clock >= threeHalfPi - step / 2 else { continue }
                clock -= threeHalfPi
                var o = Int(Double(Self.oversampling) * (clock / step + 0.5))
                if o > Self.oversampling { o = Self.oversampling }
                if o < 0 { o = 0 }
                var re: Float = 0, im: Float = 0
                var index = bufferIndex
                for _ in 0..<n {
                    re += h[o] * bufferRe[index]
                    im += h[o] * bufferIm[index]
                    o += Self.oversampling
                    index += 1
                    if index == n { index = 0 }
                }
                let level = (re * re + im * im).squareRoot()
                re /= level + 1e-8
                im /= level + 1e-8
                levelSum += Double(level * level) / 4
                levelCount += 1

                let value: Float, error: Float
                if symbolIndex & 1 != 0 {
                    value = im
                    error = value >= 0 ? -re : re
                } else {
                    value = re
                    error = value >= 0 ? im : -im
                }
                putBit(symbolIndex & 2 != 0 ? -value : value)
                symbolIndex += 1
                frequencyError = Self.pllCoefficient * frequencyError + (1 - Self.pllCoefficient) * Self.pllGain * Double(error)
            }
        }
        return blocks
    }

    private func putBit(_ value: Float) {
        outBits >>= 1
        if value > 0 { outBits |= 0x80 }
        bitsNeeded -= 1
        if bitsNeeded <= 0 { decodeByte(outBits) }
    }

    private func reset() {
        state = .waitSYN
        frequencyError = 0
        bitsNeeded = 1
    }

    private func decodeByte(_ r: UInt8) {
        switch state {
        case .waitSYN:
            if r == ACARSFrame.syn {
                state = .syn2
                bitsNeeded = 8
            } else if r == ~ACARSFrame.syn {
                symbolIndex ^= 2   // Polarität drehen
                state = .syn2
                bitsNeeded = 8
            } else {
                bitsNeeded = 1
            }
        case .syn2:
            if r == ACARSFrame.syn {
                state = .soh
                bitsNeeded = 8
            } else if r == ~ACARSFrame.syn {
                symbolIndex ^= 2
                bitsNeeded = 8
            } else {
                reset()
            }
        case .soh:
            if r == ACARSFrame.soh {
                state = .text
                block.removeAll(keepingCapacity: true)
                crc.removeAll()
                levelSum = 0
                levelCount = 0
                bitsNeeded = 8
            } else {
                reset()
            }
        case .text:
            block.append(r)
            if block.count(where: { !ACARSFrame.parityOK($0) }) > 4 {
                reset()
                return
            }
            if r == ACARSFrame.etx || r == ACARSFrame.etb {
                state = .crc1
                bitsNeeded = 8
                return
            }
            if block.count > 240 {
                reset()
                return
            }
            bitsNeeded = 8
        case .crc1:
            crc = [r]
            state = .crc2
            bitsNeeded = 8
        case .crc2:
            crc.append(r)
            let level = levelCount > 0 ? 10 * log10(max(levelSum / Double(levelCount), 1e-12)) : -100
            blocks.append((block, crc, level))
            state = .end
            bitsNeeded = 8
        case .end:
            reset()
            bitsNeeded = 8
        }
    }
}

/// AM-Kanalisierung für ACARS: 2 MS/s vom HackRF, je Kanal mischen (die
/// Kanäle liegen auf dem 12,5-kHz-Raster, die Mitte ebenfalls – der
/// Oszillator wiederholt sich dann nach 160 Abtastwerten), dann FIR ÷8,
/// ÷4, ÷5 auf 12,5 kHz, Hüllkurve, Gleichanteil abziehen.
final class ACARSChannelizer {
    static let inputRate = 2_000_000.0
    static let outputRate = 12_500.0
    private static let period = 160   // inputRate / 12,5 kHz

    let channelOffsets: [Double]
    /// Trägerleistung je Kanal in dBFS.
    private(set) var channelPowerDB: [Float]

    private let filter1: [Float]
    private let filter2: [Float]
    private let filter3: [Float]
    private var states: [State]

    private struct State {
        var oscRe: [Float]
        var oscIm: [Float]
        var oscIndex = 0
        var h1Re: [Float] = [], h1Im: [Float] = []
        var h2Re: [Float] = [], h2Im: [Float] = []
        var h3Re: [Float] = [], h3Im: [Float] = []
        var mean: Float = 0
    }

    init(channelOffsets: [Double]) {
        self.channelOffsets = channelOffsets
        channelPowerDB = channelOffsets.map { _ in -100 }
        filter1 = RadioDemodulator.lowpass(taps: 63, cutoff: 40_000, rate: Self.inputRate)
        filter2 = RadioDemodulator.lowpass(taps: 63, cutoff: 12_000, rate: Self.inputRate / 8)
        filter3 = RadioDemodulator.lowpass(taps: 127, cutoff: 5_000, rate: Self.inputRate / 32)
        states = channelOffsets.map { offset in
            State(oscRe: (0..<Self.period).map { Float(cos(-2 * Double.pi * offset * Double($0) / Self.inputRate)) },
                  oscIm: (0..<Self.period).map { Float(sin(-2 * Double.pi * offset * Double($0) / Self.inputRate)) })
        }
    }

    /// IQ-Block (int8, 2 MS/s) → Hüllkurve je Kanal (12,5 kHz, mittelwertfrei).
    func process(_ iq: Data) -> [[Float]] {
        let count = iq.count / 2
        guard count > 0 else { return channelOffsets.map { _ in [] } }
        var inRe = [Float](repeating: 0, count: count)
        var inIm = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<count {
                inRe[n] = Float(p[2 * n]) / 128
                inIm[n] = Float(p[2 * n + 1]) / 128
            }
        }
        var outputs: [[Float]] = []
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        for index in states.indices {
            var s = states[index]
            s.oscRe.withUnsafeBufferPointer { c in
                s.oscIm.withUnsafeBufferPointer { d in
                    var k = s.oscIndex
                    for n in 0..<count {
                        let i = inRe[n], q = inIm[n]
                        re[n] = i * c[k] - q * d[k]
                        im[n] = i * d[k] + q * c[k]
                        k += 1
                        if k == Self.period { k = 0 }
                    }
                    s.oscIndex = k
                }
            }
            let (aRe, aIm) = RadioDemodulator.decimateComplex(re, im, history: &s.h1Re, &s.h1Im, filter: filter1, factor: 8)
            let (bRe, bIm) = RadioDemodulator.decimateComplex(aRe, aIm, history: &s.h2Re, &s.h2Im, filter: filter2, factor: 4)
            let (cRe, cIm) = RadioDemodulator.decimateComplex(bRe, bIm, history: &s.h3Re, &s.h3Im, filter: filter3, factor: 5)
            var envelope = [Float](repeating: 0, count: cRe.count)
            var power: Float = 0
            for n in cRe.indices {
                let p = cRe[n] * cRe[n] + cIm[n] * cIm[n]
                power += p
                let a = p.squareRoot()
                // Gleichanteil (Träger) mit einem langsamen Mittelwert abziehen.
                s.mean += (a - s.mean) * 0.01
                envelope[n] = a - s.mean
            }
            if !cRe.isEmpty { channelPowerDB[index] = 10 * log10(max(power / Float(cRe.count), 1e-12)) }
            states[index] = s
            outputs.append(envelope)
        }
        return outputs
    }
}

/// Kanalwahl und Mittenfrequenz für ein HackRF-Fenster von 2 MS/s.
enum ACARSPlan {
    /// Europäische Kanäle; die ersten drei sind die üblichen.
    static let europeanMHz = [131.525, 131.725, 131.825, 129.125, 130.025, 130.425, 130.450, 131.550]
    static let defaultMHz = [131.525, 131.725, 131.825]
    /// Nutzbare Breite je Seite (Basisbandfilter 1,75 MHz).
    static let usableHz = 800_000.0
    /// Abstand zur Gleichspannungsspitze.
    static let dcGapHz = 50_000.0
    static let gridHz = 12_500.0

    struct Result: Equatable {
        var centerHz: Double
        var active: [Double]      // MHz
        var outside: [Double]     // MHz, passen nicht ins Fenster
    }

    static func plan(_ selectedMHz: [Double]) -> Result? {
        let selected = Array(Set(selectedMHz.map { ($0 * 1000).rounded() / 1000 })).sorted()
        guard !selected.isEmpty else { return nil }
        // Größte Gruppe, die in 2 · usableHz passt.
        var best: [Double] = []
        for (i, low) in selected.enumerated() {
            let group = selected[i...].filter { ($0 - low) * 1e6 <= 2 * usableHz }
            if group.count > best.count { best = Array(group) }
        }
        let low = best.first! * 1e6, high = best.last! * 1e6
        let middle = ((low + high) / 2 / gridHz).rounded() * gridHz
        // Von der Mitte aus abwechselnd nach außen, bis kein Kanal auf der DC-Spitze liegt.
        for step in 0..<200 {
            let delta = Double((step + 1) / 2) * gridHz * (step % 2 == 0 ? 1 : -1)
            let center = middle + delta
            let fits = best.allSatisfy { abs($0 * 1e6 - center) <= usableHz && abs($0 * 1e6 - center) >= dcGapHz }
            if fits {
                return Result(centerHz: center, active: best, outside: selected.filter { !best.contains($0) })
            }
        }
        return nil
    }
}

/// Alle Kanäle eines Fensters: Kanalisierung, Demodulation, Prüfung.
final class ACARSReceiver {
    let plan: ACARSPlan.Result
    let channelizer: ACARSChannelizer
    private let decoders: [ACARSChannelDecoder]
    private(set) var blocksSeen = 0
    private(set) var crcErrors = 0

    init(plan: ACARSPlan.Result) {
        self.plan = plan
        channelizer = ACARSChannelizer(channelOffsets: plan.active.map { $0 * 1e6 - plan.centerHz })
        decoders = plan.active.map { _ in ACARSChannelDecoder() }
    }

    func process(_ iq: Data) -> [ACARSMessage] {
        let envelopes = channelizer.process(iq)
        var messages: [ACARSMessage] = []
        for (index, envelope) in envelopes.enumerated() {
            for block in decoders[index].process(envelope) {
                blocksSeen += 1
                guard let (text, corrected) = ACARSFrame.validate(block.text, crc: block.crc),
                      var message = ACARSFrame.parse(text) else {
                    crcErrors += 1
                    continue
                }
                message.frequencyMHz = plan.active[index]
                message.levelDB = block.levelDB
                message.corrected = corrected
                messages.append(message)
            }
        }
        return messages
    }
}

/// Erzeugt ACARS-Signale – für die Tests.
enum ACARSEncoder {
    /// Zeichen nach SOH bis ETX (mit Parität).
    static func block(mode: Character = "2", registration: String, acknowledge: UInt8 = 0x15, label: String,
                      blockID: Character, messageNumber: String = "", flight: String = "", text: String,
                      end: UInt8 = ACARSFrame.etx) -> [UInt8] {
        var reg = Array(registration.utf8)
        if reg.count < 7 { reg = Array(repeating: 0x2E, count: 7 - reg.count) + reg }   // mit „.“ auffüllen
        var chars: [UInt8] = [mode.asciiValue!] + reg.prefix(7) + [acknowledge] + Array(label.utf8.prefix(2)) + [blockID.asciiValue!]
        let body = Array(messageNumber.utf8) + Array(flight.utf8) + Array(text.utf8)
        chars += body.isEmpty ? [] : [ACARSFrame.stx]
        let withParity = chars.map(ACARSFrame.withParity) + (body.isEmpty ? [] : body.map(ACARSFrame.withParity)) + [end]
        return withParity
    }

    /// Komplette Übertragung als Bytes: Vorlauf, „+*“, SYN SYN SOH, Block, CRC, DEL.
    static func transmission(_ block: [UInt8], preKeyBytes: Int = 16) -> [UInt8] {
        let crc = ACARSCRC.checksum(block)
        return Array(repeating: 0xFF, count: preKeyBytes)
            + ["+", "*"].map { ACARSFrame.withParity(Character($0).asciiValue!) }
            + [ACARSFrame.syn, ACARSFrame.syn, ACARSFrame.soh] + block
            + [UInt8(crc & 0xFF), UInt8(crc >> 8), ACARSFrame.del]
    }

    /// Bits mit dem niederwertigen zuerst.
    static func bits(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { byte in (0..<8).map { (byte >> UInt8($0)) & 1 } }
    }

    /// MSK-Ton (phasenstetig): 2400 Hz, wenn das Bit dem vorigen gleicht,
    /// sonst 1200 Hz; 2400 Bit/s. Die Phase wird je Abtastwert exakt aus
    /// Bitbeginn und Frequenz berechnet – bei 12,5 kHz (5,2 Werte je Bit)
    /// summiert ein schrittweise weitergezählter Oszillator sonst Fehler auf,
    /// an denen die Demodulation scheitert.
    static func audio(_ bits: [UInt8], sampleRate: Double) -> [Float] {
        let bitRate = 2400.0
        var frequencies: [Double] = []
        var startPhases: [Double] = []
        var previous: UInt8 = 1
        var phase = 0.0
        for bit in bits {
            let f = bit == previous ? 2400.0 : 1200.0
            previous = bit
            frequencies.append(f)
            startPhases.append(phase)
            phase = (phase + 2 * .pi * f / bitRate).truncatingRemainder(dividingBy: 2 * .pi)
        }
        let count = Int(Double(bits.count) / bitRate * sampleRate)
        return (0..<count).map { n in
            let t = Double(n) / sampleRate
            let k = min(Int(t * bitRate), bits.count - 1)
            return Float(sin(startPhases[k] + 2 * .pi * frequencies[k] * (t - Double(k) / bitRate)))
        }
    }
}
