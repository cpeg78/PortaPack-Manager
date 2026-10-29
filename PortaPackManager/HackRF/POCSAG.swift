import Foundation

// MARK: - Kodierung

/// POCSAG (ITU-R M.584): Kodewörter zu 32 Bit, höchstwertiges Bit zuerst
/// gesendet. Bit 31 unterscheidet Adresse (0) und Nachricht (1), Bits 30–11
/// tragen die Daten, Bits 10–1 die BCH(31,21)-Prüfung, Bit 0 die gerade
/// Parität über alle 32 Bit. Ein Stapel („Batch“) = Sync-Wort + 8 Rahmen zu
/// je 2 Kodewörtern; ein Empfänger mit RIC r hört nur in Rahmen r mod 8.
enum POCSAG {
    static let sync: UInt32 = 0x7CD2_15D8
    static let idle: UInt32 = 0x7A89_C197
    /// Generatorpolynom x¹⁰+x⁹+x⁸+x⁶+x⁵+x³+1.
    static let generator: UInt32 = 0x769
    static let bitRates = [512, 1200, 2400]
    /// Ziffernnachrichten: BCD, Werte 10–15 wie in multimon-ng.
    static let numericDigits = Array("0123456789*U -)(")

    /// BCH-Rest der oberen 31 Bit (Kodewort ohne Paritätsbit).
    static func syndrome(_ codeword: UInt32) -> UInt32 {
        var r = codeword >> 1
        for bit in stride(from: 30, through: 10, by: -1) where r & (1 << bit) != 0 {
            r ^= generator << (bit - 10)
        }
        return r
    }

    /// Fehlermuster (bezogen auf die oberen 31 Bit) je Syndrom, bis zwei Fehler.
    private static let corrections: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 1024)
        for i in 0..<31 {
            table[Int(syndrome(UInt32(1) << (i + 1)))] = 1 << i
            for j in 0..<i {
                table[Int(syndrome(UInt32(1) << (i + 1) | UInt32(1) << (j + 1)))] = 1 << i | 1 << j
            }
        }
        return table
    }()

    /// Korrigiert bis zu zwei Bitfehler; `nil`, wenn das Wort nicht zu retten ist.
    static func correct(_ word: UInt32) -> (codeword: UInt32, errors: Int)? {
        var cw = word
        var errors = 0
        let s = syndrome(cw)
        if s != 0 {
            let pattern = corrections[Int(s)]
            guard pattern != 0 else { return nil }
            cw ^= pattern << 1
            errors = pattern.nonzeroBitCount
        }
        if cw.nonzeroBitCount & 1 != 0 {
            // Paritätsfehler: nur glaubhaft, wenn höchstens ein weiterer Fehler vorlag.
            guard errors < 2 else { return nil }
            cw ^= 1
            errors += 1
        }
        return (cw, errors)
    }

    /// Ergänzt 21 Datenbits (Bit 31–11) um BCH-Prüfung und Parität.
    static func encode(_ upper21: UInt32) -> UInt32 {
        var cw = (upper21 & 0x1F_FFFF) << 11
        cw |= syndrome(cw) << 1
        if cw.nonzeroBitCount & 1 != 0 { cw |= 1 }
        return cw
    }

    static func addressCodeword(ric: UInt32, function: UInt8) -> UInt32 {
        encode((ric >> 3) << 2 | UInt32(function & 3))
    }

    static func messageCodeword(_ data20: UInt32) -> UInt32 {
        encode(1 << 20 | (data20 & 0xF_FFFF))
    }

    /// Text → Datenbits: 7-Bit-Zeichen, niederwertiges Bit zuerst.
    static func alphaBits(_ text: String) -> [UInt8] {
        text.unicodeScalars.flatMap { scalar -> [UInt8] in
            let value = UInt8(truncatingIfNeeded: scalar.value) & 0x7F
            return (0..<7).map { (value >> $0) & 1 }
        }
    }

    /// Ziffern → Datenbits: 4 Bit je Ziffer, niederwertiges Bit zuerst,
    /// mit Leerzeichen auf volle Kodewörter (5 Ziffern) aufgefüllt.
    static func numericBits(_ digits: String) -> [UInt8] {
        let padded = digits + String(repeating: " ", count: (5 - digits.count % 5) % 5)
        return padded.flatMap { char -> [UInt8] in
            let value = UInt8(numericDigits.firstIndex(of: char) ?? 12)
            return (0..<4).map { (value >> $0) & 1 }
        }
    }

    static func alphaText(_ bits: [UInt8]) -> String {
        var scalars: [UInt8] = []
        var index = 0
        while index + 7 <= bits.count {
            var value: UInt8 = 0
            for k in 0..<7 { value |= bits[index + k] << k }
            scalars.append(value)
            index += 7
        }
        // Füllzeichen und Endkennungen (NUL, ETX, EOT) am Ende entfernen.
        while let last = scalars.last, last == 0 || last == 3 || last == 4 { scalars.removeLast() }
        return String(scalars.map { value -> Character in
            switch value {
            case 0x0A, 0x0D: "\n"
            case 0x20...0x7E: Character(Unicode.Scalar(value))
            default: "·"
            }
        })
    }

    static func numericText(_ bits: [UInt8]) -> String {
        var out = ""
        var index = 0
        while index + 4 <= bits.count {
            var value = 0
            for k in 0..<4 { value |= Int(bits[index + k]) << k }
            out.append(numericDigits[value])
            index += 4
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// Anteil plausibler Textzeichen – entscheidet bei Funktion 1/2, ob Text vorliegt.
    static func looksLikeText(_ bits: [UInt8]) -> Bool {
        let text = alphaText(bits)
        guard !text.isEmpty else { return false }
        let printable = text.filter { $0 != "·" }.count
        return Double(printable) / Double(text.count) >= 0.9
    }

    /// Deutscher Zeichensatz nach DIN 66003 (ISO 646-DE), wie ihn Skyper- und
    /// DAPNET-Pager anzeigen: [\]{|}~ → ÄÖÜäöüß.
    static func german(_ text: String) -> String {
        String(text.map { char -> Character in
            switch char {
            case "[": "Ä"
            case "\\": "Ö"
            case "]": "Ü"
            case "{": "ä"
            case "|": "ö"
            case "}": "ü"
            case "~": "ß"
            case "@": "§"
            default: char
            }
        })
    }
}

/// Eine vollständig empfangene Pager-Nachricht.
struct PagerMessage: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case alpha = "Text"
        case numeric = "Ziffern"
        case tone = "Nur Ton"

        /// Anzeigename (übersetzt).
        var title: String {
            switch self {
            case .alpha: String(localized: "Text")
            case .numeric: String(localized: "Ziffern")
            case .tone: String(localized: "Nur Ton")
            }
        }
    }

    var id = UUID()
    var date = Date()
    var ric: UInt32
    /// Funktionsbits 0–3, auf Pagern meist als A–D angezeigt.
    var function: UInt8
    var bitRate: Int
    var bits: [UInt8]
    /// Korrigierte Bitfehler über alle Kodewörter.
    var correctedBits: Int
    /// Ein Kodewort war nicht zu korrigieren; der Rest fehlt.
    var incomplete: Bool
    /// Korrigierte Bits im Adresswort. Zwei heißt: möglicherweise ein
    /// zerstörtes Wort, das zufällig als Adresse durchging.
    var addressErrors = 0

    var uncertain: Bool { addressErrors >= 2 }

    var functionLetter: String { ["A", "B", "C", "D"][Int(function & 3)] }

    var kind: Kind {
        if bits.isEmpty { return .tone }
        switch function {
        case 0: return .numeric
        case 3: return .alpha
        default: return POCSAG.looksLikeText(bits) ? .alpha : .numeric
        }
    }

    func text(german: Bool) -> String {
        switch kind {
        case .tone: ""
        case .numeric: POCSAG.numericText(bits)
        case .alpha: german ? POCSAG.german(POCSAG.alphaText(bits)) : POCSAG.alphaText(bits)
        }
    }

    /// Gleicher Inhalt an denselben Empfänger (Wiederholung, anderer Sender).
    func sameContent(as other: PagerMessage) -> Bool {
        ric == other.ric && function == other.function && bits == other.bits
    }
}

// MARK: - Rahmenbildung

/// Sucht Sync-Wörter im Bitstrom und setzt Adressen und Nachrichten zusammen.
///
/// Zur Erstsynchronisation genügt ein fehlerfreies Sync-Wort oder eines mit
/// bis zu zwei Fehlern direkt nach der Präambel (1010…). Ein Zufallstreffer
/// wäre teuer: Die BCH-Korrektur nimmt rund ein Viertel aller Zufallswörter
/// als gültig an. Danach wird jedes folgende Sync-Wort mit bis zu drei
/// Fehlern akzeptiert. Invertierte Polarität erkennt das invertierte Sync-Wort.
struct POCSAGFramer {
    let bitRate: Int

    private var register: UInt64 = 0
    private var locked = false
    private var inverted = false
    private var word: UInt32 = 0
    private var bitCount = 0
    private var codewordIndex = 0
    private var current: PagerMessage?
    /// Längste Nachricht in Kodewörtern (rund 1100 Zeichen), dann abbrechen.
    private let maximumCodewords = 400
    private var messageCodewords = 0

    init(bitRate: Int) {
        self.bitRate = bitRate
    }

    var isLocked: Bool { locked }

    mutating func push(_ bit: UInt8) -> PagerMessage? {
        register = register << 1 | UInt64(bit & 1)
        guard locked else {
            let candidate = UInt32(truncatingIfNeeded: register)
            let before = UInt32(truncatingIfNeeded: register >> 32)
            let preamble = min((before ^ 0xAAAA_AAAA).nonzeroBitCount, (before ^ 0x5555_5555).nonzeroBitCount) <= 4
            let normal = (candidate ^ POCSAG.sync).nonzeroBitCount
            let invert = (candidate ^ ~POCSAG.sync).nonzeroBitCount
            if normal == 0 || (normal <= 2 && preamble) {
                lock(inverted: false)
            } else if invert == 0 || (invert <= 2 && preamble) {
                lock(inverted: true)
            }
            return nil
        }
        word = word << 1 | UInt32((inverted ? bit ^ 1 : bit) & 1)
        bitCount += 1
        guard bitCount == 32 else { return nil }
        bitCount = 0
        if codewordIndex == 16 {
            if (word ^ POCSAG.sync).nonzeroBitCount <= 3 {
                codewordIndex = 0
                return nil
            }
            locked = false
            return finish(incomplete: false)
        }
        let frame = UInt32(codewordIndex / 2)
        codewordIndex += 1
        return handle(word, frame: frame)
    }

    /// Schließt eine offene Nachricht ab (z. B. am Ende einer Aufnahme).
    mutating func flush() -> PagerMessage? {
        finish(incomplete: false)
    }

    private mutating func lock(inverted: Bool) {
        locked = true
        self.inverted = inverted
        bitCount = 0
        codewordIndex = 0
        word = 0
    }

    private mutating func handle(_ raw: UInt32, frame: UInt32) -> PagerMessage? {
        guard let (cw, errors) = POCSAG.correct(raw) else {
            return finish(incomplete: true)
        }
        if cw == POCSAG.idle { return finish(incomplete: false) }
        if cw & 0x8000_0000 == 0 {
            // Mit Paritätsbit ist der Mindestabstand 6: Falsch korrigierte Wörter
            // haben mindestens vier Fehler, kommen also aus Fehlerbündeln mitten
            // in einer Nachricht. Eine Adresse dort, die zwei Korrekturen
            // brauchte, gilt deshalb als zerstörtes Nachrichtenwort.
            if errors >= 2, current != nil, messageCodewords > 0 {
                return finish(incomplete: true)
            }
            let done = finish(incomplete: false)
            current = PagerMessage(ric: (cw >> 13) << 3 | frame, function: UInt8((cw >> 11) & 3),
                                   bitRate: bitRate, bits: [], correctedBits: errors, incomplete: false,
                                   addressErrors: errors)
            messageCodewords = 0
            return done
        }
        guard current != nil else { return nil }   // Fortsetzung ohne Adresse
        for k in stride(from: 30, through: 11, by: -1) {
            current!.bits.append(UInt8((cw >> UInt32(k)) & 1))
        }
        current!.correctedBits += errors
        messageCodewords += 1
        return messageCodewords >= maximumCodewords ? finish(incomplete: true) : nil
    }

    private mutating func finish(incomplete: Bool) -> PagerMessage? {
        guard var message = current else { return nil }
        current = nil
        // Nur-Ton-Ruf an eine Adresse mit zwei Korrekturen: bei vielen
        // Bitfehlern fast immer ein Zufallswort (gemessen im Rauschtest).
        if message.bits.isEmpty, message.uncertain { return nil }
        message.incomplete = incomplete
        message.date = Date()
        return message
    }
}

// MARK: - Demodulation

/// 2-FSK (±4,5 kHz) aus dem FM-Diskriminator bei 48 kHz, alle drei
/// Bitraten parallel. Je Rate: gleitender Mittelwert über eine Bitdauer
/// (signalangepasstes Filter für NRZ), Gleichanteil (Frequenzablage von
/// Sender und Quarz) über rund 32 Bit nachgeführt, Bittakt wie bei APRS.
/// Logisch 1 = untere Frequenz; die umgekehrte Lage erkennt der Framer.
final class POCSAGDemodulator: @unchecked Sendable {
    static let sampleRate = FMChannelizer.outputRate

    private struct Slicer {
        var length: Int
        var ring: [Float]
        var index = 0
        var sum: Float = 0
        var sinceRecalc = 0
        var dc: Float = 0
        let dcRate: Float
        var clock: BitClock
        var framer: POCSAGFramer

        init(bitRate: Int) {
            let samplesPerBit = POCSAGDemodulator.sampleRate / Double(bitRate)
            length = max(1, Int(samplesPerBit.rounded()))
            ring = [Float](repeating: 0, count: length)
            dcRate = Float(1 / (samplesPerBit * 32))
            clock = BitClock(bitRate: Double(bitRate), sampleRate: POCSAGDemodulator.sampleRate, inertia: 0.75)
            framer = POCSAGFramer(bitRate: bitRate)
        }
    }

    private var slicers: [Slicer]

    init(bitRates: [Int] = POCSAG.bitRates) {
        slicers = bitRates.map(Slicer.init)
    }

    func reset() {
        slicers = slicers.map { Slicer(bitRate: $0.framer.bitRate) }
    }

    /// Bitraten mit derzeit erkannter Synchronisation.
    var lockedRates: [Int] { slicers.filter(\.framer.isLocked).map(\.framer.bitRate) }

    func process(_ samples: [Float]) -> [PagerMessage] {
        var messages: [PagerMessage] = []
        for n in slicers.indices {
            var s = slicers[n]
            for x in samples {
                s.sum += x - s.ring[s.index]
                s.ring[s.index] = x
                s.index += 1
                if s.index == s.length { s.index = 0 }
                s.sinceRecalc += 1
                if s.sinceRecalc >= 8192 {
                    s.sinceRecalc = 0
                    s.sum = s.ring.reduce(0, +)
                }
                let y = s.sum / Float(s.length)
                s.dc += s.dcRate * (y - s.dc)
                guard let value = s.clock.push(y - s.dc) else { continue }
                // Untere Frequenz (negativer Diskriminator) = logisch 1.
                if let message = s.framer.push(value < 0 ? 1 : 0) { messages.append(message) }
            }
            slicers[n] = s
        }
        return messages
    }

    /// Gibt noch offene Nachrichten aus (Ende einer Aufnahme).
    func flush() -> [PagerMessage] {
        slicers.indices.compactMap { slicers[$0].framer.flush() }
    }
}

// MARK: - Sender (für Tests)

enum POCSAGEncoder {
    struct Page {
        var ric: UInt32
        var function: UInt8
        var bits: [UInt8]
    }

    /// Bitfolge einer Aussendung: 576 Bit Präambel, dann Stapel mit Sync-Wort.
    static func transmission(_ pages: [Page], preambleBits: Int = 576) -> [UInt8] {
        var codewords: [UInt32] = []
        for page in pages {
            let frame = Int(page.ric & 7)
            // Bis zum Rahmen des Empfängers mit Leerwörtern auffüllen.
            while (codewords.count % 16) != frame * 2 { codewords.append(POCSAG.idle) }
            codewords.append(POCSAG.addressCodeword(ric: page.ric, function: page.function))
            var bits = page.bits
            while bits.count % 20 != 0 { bits.append(0) }
            for start in stride(from: 0, to: bits.count, by: 20) {
                var data: UInt32 = 0
                for k in 0..<20 { data = data << 1 | UInt32(bits[start + k]) }
                codewords.append(POCSAG.messageCodeword(data))
            }
            codewords.append(POCSAG.idle)
        }
        while codewords.count % 16 != 0 { codewords.append(POCSAG.idle) }
        var out = (0..<preambleBits).map { UInt8(($0 + 1) & 1) }
        for (n, cw) in codewords.enumerated() {
            if n % 16 == 0 { out += bits(POCSAG.sync) }
            out += bits(cw)
        }
        return out
    }

    private static func bits(_ word: UInt32) -> [UInt8] {
        (0..<32).map { UInt8((word >> UInt32(31 - $0)) & 1) }
    }
}
