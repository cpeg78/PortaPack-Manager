import Foundation

// Digitaler Selektivruf (DSC) nach ITU-R M.493 auf UKW-Kanal 70 (156,525 MHz).
//
// Aufbau einer Aussendung (UKW):
// - FM mit Unterträger: 1200 Bd, 1300 Hz = Y = 1, 2100 Hz = B = 0.
// - 20 Bit Punktmuster (BYBY…), dann die Phasierungsfolge: abwechselnd
//   DX (Zeichen 125) und RX (Zeichen 111, 110 … 104).
// - Jedes Zeichen 10 Bit: 7 Informationsbits (niederwertigstes zuerst),
//   dann die Anzahl der B-Bits (Nullen) darin als 3 Bit (höchstwertiges zuerst).
// - Zeitdiversität: jedes Nachrichtenzeichen geht zweimal hinaus, in der
//   DX-Position und vier Zeichen später noch einmal in der RX-Position.
// - Am Ende: EOS (117, 122 oder 127), Prüfzeichen ECC (XOR aller Zeichen vom
//   Formatkennzeichen – nur einmal gezählt – bis EOS), in DX noch zweimal EOS.

// MARK: - Zeichencode

enum DSCSymbol {
    static let dx: UInt8 = 125
    /// RX-Phasierungszeichen in Sendereihenfolge (RX7 … RX0).
    static let rx: [UInt8] = [111, 110, 109, 108, 107, 106, 105, 104]
    static let endOfSequence: Set<UInt8> = [117, 122, 127]

    /// Die 10 Bits eines Zeichens in Sendereihenfolge.
    static func bits(_ value: UInt8) -> [UInt8] {
        var bits: [UInt8] = []
        var zeros = 0
        for i in 0..<7 {
            let bit = (value >> i) & 1
            bits.append(bit)
            if bit == 0 { zeros += 1 }
        }
        for i in (0..<3).reversed() { bits.append(UInt8((zeros >> i) & 1)) }
        return bits
    }

    /// 10-Bit-Wort (erstes gesendetes Bit = höchstwertiges) → Zeichenwert, −1 bei Prüffehler.
    static let table: [Int16] = {
        var table = [Int16](repeating: -1, count: 1024)
        for value in 0..<128 {
            table[word(bits(UInt8(value)))] = Int16(value)
        }
        return table
    }()

    static func word(_ bits: [UInt8]) -> Int {
        bits.reduce(0) { $0 << 1 | Int($1 & 1) }
    }

    /// Die sieben Informationsbits eines (auch fehlerhaften) Worts.
    static func information(of word: Int) -> UInt8 {
        var value: UInt8 = 0
        for i in 0..<7 where (word >> (9 - i)) & 1 == 1 { value |= 1 << i }
        return value
    }

    /// Prüfzeichen über die Nachricht (Formatkennzeichen einmal, bis EOS einschließlich).
    static func ecc(_ message: some Sequence<UInt8>) -> UInt8 {
        message.reduce(0) { $0 ^ $1 } & 0x7F
    }

    /// Vollständige Zeichenfolge einer Aussendung: Phasierung, DX/RX verschränkt.
    /// `message`: Formatkennzeichen (zweimal) … EOS, ohne ECC.
    static func transmission(message: [UInt8]) -> [UInt8] {
        let ecc = Self.ecc(message.dropFirst())
        let full = message + [ecc]
        let dxStream = [UInt8](repeating: dx, count: 6) + full + [full[full.count - 2], full[full.count - 2]]
        let rxStream = rx + full
        var out: [UInt8] = []
        for k in 0..<dxStream.count {
            out.append(dxStream[k])
            if k < rxStream.count { out.append(rxStream[k]) }
        }
        return out
    }
}

// MARK: - Rahmen aus Bits (Phasierung, Diversität, ECC)

/// Ein gefundener Ruf: Zeichen vom Formatkennzeichen bis ECC.
struct DSCFrame: Sendable, Equatable {
    var symbols: [UInt8]
    /// Zeichen, die erst über die zweite Kopie oder das Prüfzeichen stimmten.
    var corrected: Int
}

/// Sucht in einem Bitstrom die Phasierungsfolge und setzt aus DX- und
/// RX-Kopien die Nachricht zusammen. Phasierung gilt nach ITU-R M.493 als
/// erreicht, wenn drei Phasierungszeichen an passender Stelle stehen, mindestens
/// eins davon RX (DX allein legt die Lage nicht fest).
struct DSCFrameAssembler {
    static let maxMessageSymbols = 48
    /// Letzter Phasierungsplatz (RX 104).
    private static let phasingSlots = 16
    private static let window = 10   // Zeichen im Suchfenster

    private var register = 0
    private var bitCount = 0
    /// Wort je Bitposition (Ring über `window` Zeichen).
    private var ring = [Int](repeating: 0, count: 10 * DSCFrameAssembler.window)
    private var collecting = false
    /// Platznummer des Zeichens, das bei `nextBit` endet.
    private var nextSlot = 0
    private var bitsToNext = 0
    /// Wort je Platz (ab 12 = erstes DX-Nachrichtenzeichen).
    private var slots: [Int] = []

    init() {}

    mutating func reset() {
        self = DSCFrameAssembler()
    }

    /// Nimmt ein Bit (0/1); liefert einen Rahmen, sobald einer vollständig ist.
    mutating func push(_ bit: UInt8) -> DSCFrame? {
        register = (register << 1 | Int(bit & 1)) & 0x3FF
        ring[bitCount % ring.count] = register
        bitCount += 1
        if collecting {
            bitsToNext -= 1
            guard bitsToNext == 0 else { return nil }
            bitsToNext = 10
            if nextSlot >= 12 { slots.append(register) }
            nextSlot += 1
            if let frame = assemble() {
                collecting = false
                return frame
            }
            if nextSlot > 12 + 2 * (Self.maxMessageSymbols + 6) { collecting = false }
            return nil
        }
        guard bitCount >= 30 else { return nil }
        searchPhasing()
        return nil
    }

    private static func expected(slot: Int) -> UInt8? {
        if slot % 2 == 1 {
            let k = (slot - 1) / 2
            return k < 8 ? DSCSymbol.rx[k] : nil
        }
        return slot / 2 <= 5 ? DSCSymbol.dx : nil
    }

    private mutating func searchPhasing() {
        let available = min(bitCount / 10, Self.window)
        var values: [Int16] = []   // values[0] = jüngstes Zeichen
        for n in 0..<available {
            values.append(DSCSymbol.table[ring[(bitCount - 1 - 10 * n) % ring.count]])
        }
        var best: (slot: Int, score: Int)?
        for last in 2..<Self.phasingSlots {
            var matches = 0, rxMatches = 0
            for n in 0..<available {
                let slot = last - n
                guard slot >= 0 else { break }
                guard let want = Self.expected(slot: slot) else { continue }
                if values[n] == Int16(want) {
                    matches += 1
                    if slot % 2 == 1 { rxMatches += 1 }
                }
            }
            if matches >= 3, rxMatches >= 1, matches > (best?.score ?? 0) { best = (last, matches) }
        }
        guard let best else { return }
        collecting = true
        nextSlot = best.slot + 1
        bitsToNext = 10
        slots = []
        // Liegt der Fund schon im Nachrichtenteil (12, 14), dessen Wörter übernehmen.
        if best.slot >= 12 {
            for slot in 12...best.slot {
                let n = best.slot - slot
                slots.append(ring[(bitCount - 1 - 10 * n) % ring.count])
            }
        }
    }

    private func word(at slot: Int) -> Int? {
        let index = slot - 12
        return index >= 0 && index < slots.count ? slots[index] : nil
    }

    /// Ein Nachrichtenzeichen aus seinen beiden Kopien.
    private struct Merged {
        var value: Int16          // −1 = unbekannt
        var words: [Int]          // empfangene Wörter (für die Prüfung einer ECC-Korrektur)
        var candidates: [UInt8]   // gültige, aber widersprüchliche Werte
        var repaired: Bool
    }

    private func merged(_ j: Int) -> Merged? {
        guard let dx = word(at: 2 * j + 12) else { return nil }
        let rx = word(at: 2 * j + 17)
        let a = DSCSymbol.table[dx], b = rx.map { DSCSymbol.table[$0] } ?? -1
        let words = [dx] + (rx.map { [$0] } ?? [])
        if a >= 0, b >= 0 {
            return a == b ? Merged(value: a, words: words, candidates: [], repaired: false)
                : Merged(value: -1, words: words, candidates: [UInt8(a), UInt8(b)], repaired: true)
        }
        if a >= 0 { return Merged(value: a, words: words, candidates: [], repaired: rx != nil) }
        if b >= 0 { return Merged(value: b, words: words, candidates: [], repaired: true) }
        return Merged(value: -1, words: words, candidates: [], repaired: true)
    }

    private func assemble() -> DSCFrame? {
        var message: [Merged] = []
        var j = 0
        while let m = merged(j) { message.append(m); j += 1 }
        guard message.count >= 6 else { return nil }
        // EOS suchen; braucht ECC in beiden Kopien (RX-Platz von j+1 = 2j+19).
        for e in 4..<(message.count - 1) {
            guard word(at: 2 * e + 19) != nil else { break }
            var eos = message[e]
            if eos.value < 0 {
                // EOS geht in DX dreimal hinaus (e, e+2, e+3).
                let later = [2 * e + 16, 2 * e + 18].compactMap { word(at: $0) }.map { DSCSymbol.table[$0] }
                if later.count == 2, later[0] == later[1], later[0] >= 0, DSCSymbol.endOfSequence.contains(UInt8(later[0])) {
                    eos.value = later[0]
                }
            }
            guard eos.value >= 0, DSCSymbol.endOfSequence.contains(UInt8(eos.value)) else { continue }
            var parts = Array(message[0...(e + 1)])
            parts[e] = eos
            if let frame = Self.resolve(parts) { return frame }
        }
        return nil
    }

    /// Prüft das ECC und repariert höchstens ein unbekanntes Zeichen darüber –
    /// aber nur, wenn der errechnete Wert zu einer empfangenen Kopie passt
    /// (widersprüchlicher Wert oder höchstens ein Bit Abstand).
    private static func resolve(_ parts: [Merged]) -> DSCFrame? {
        var parts = parts
        // Formatkennzeichen steht zweimal – eine gute Kopie genügt.
        if parts[1].value < 0, parts[0].value >= 0 { parts[1].value = parts[0].value }
        if parts[0].value < 0 { parts[0].value = parts[1].value }
        guard parts[0].value == parts[1].value else { return nil }
        let unknown = (1..<parts.count).filter { parts[$0].value < 0 }
        if unknown.count > 1 { return nil }
        if let u = unknown.first {
            var needed: UInt8 = 0
            for i in 1..<parts.count where i != u { needed ^= UInt8(parts[i].value) }
            let p = parts[u]
            let plausible = p.candidates.contains(needed) || p.words.contains { word in
                (DSCSymbol.information(of: word) ^ needed).nonzeroBitCount <= 1
            }
            guard plausible else { return nil }
            parts[u].value = Int16(needed)
            if u == 1, parts[0].value < 0 { parts[0].value = Int16(needed) }
        } else {
            var check: UInt8 = 0
            for i in 1..<parts.count { check ^= UInt8(parts[i].value) }
            guard check == 0 else { return nil }
        }
        return DSCFrame(symbols: parts.map { UInt8($0.value) }, corrected: parts.filter(\.repaired).count)
    }
}

// MARK: - Demodulator (AFSK 1300/2100 Hz aus dem FM-Diskriminator)

/// Zwei gleitende Quadraturkorrelatoren über je eine Bitdauer (wie
/// `AFSKDemodulator`), mehrere Entscheider mit verschieden gewichtetem
/// B-Ton (Vorverzerrung des Senders hebt 2100 Hz an). Jeder Entscheider
/// prüft beide Polaritäten – Geräte vertauschen gelegentlich die Töne.
final class DSCDemodulator: @unchecked Sendable {
    static let sampleRate = FMChannelizer.outputRate
    static let baud = 1200.0
    static let yTone = 1300.0     // Y = 1
    static let bTone = 2100.0     // B = 0
    static let bGains: [Float] = [0.5, 0.8, 1.25, 2.0]

    private let window = Int(sampleRate / baud)
    private let yStep = 2 * Double.pi * yTone / sampleRate
    private let bStep = 2 * Double.pi * bTone / sampleRate
    private var yPhase = 0.0, bPhase = 0.0
    private var ring: [(Float, Float, Float, Float)]
    private var ringIndex = 0
    private var sums: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var sinceRecalc = 0
    private var sampleCounter = 0
    private var slicers: [Slicer]
    private var recent: [(symbols: [UInt8], sample: Int)] = []

    private struct Slicer {
        var gain: Float
        // Träge Taktnachführung: mit 0,75 (wie APRS) rutschte der Takt im Rauschen
        // um ein Bit, und der Rest des Rufs war verloren (σ 0,25: 25/45 statt 45/45).
        // 20 Punktbits plus Phasierung reichen trotzdem zum Einrasten.
        var clock = BitClock(bitRate: DSCDemodulator.baud, sampleRate: DSCDemodulator.sampleRate, inertia: 0.9)
        var normal = DSCFrameAssembler()
        var inverted = DSCFrameAssembler()
    }

    init() {
        ring = Array(repeating: (0, 0, 0, 0), count: window)
        slicers = Self.bGains.map { Slicer(gain: $0) }
    }

    func reset() {
        ring = Array(repeating: (0, 0, 0, 0), count: window)
        sums = (0, 0, 0, 0)
        slicers = Self.bGains.map { Slicer(gain: $0) }
        recent = []
    }

    /// Diskriminatorwerte (48 kHz) → neu gefundene Rahmen.
    func process(_ samples: [Float]) -> [DSCFrame] {
        var frames: [DSCFrame] = []
        for x in samples {
            sampleCounter += 1
            let yr = x * Float(cos(yPhase)), yi = x * Float(sin(yPhase))
            let br = x * Float(cos(bPhase)), bi = x * Float(sin(bPhase))
            yPhase += yStep
            bPhase += bStep
            if yPhase > 2 * .pi { yPhase -= 2 * .pi }
            if bPhase > 2 * .pi { bPhase -= 2 * .pi }
            let old = ring[ringIndex]
            ring[ringIndex] = (yr, yi, br, bi)
            ringIndex = (ringIndex + 1) % window
            sums.0 += yr - old.0
            sums.1 += yi - old.1
            sums.2 += br - old.2
            sums.3 += bi - old.3
            sinceRecalc += 1
            if sinceRecalc >= 4096 {
                sinceRecalc = 0
                sums = ring.reduce((0, 0, 0, 0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2, $0.3 + $1.3) }
            }
            let y = (sums.0 * sums.0 + sums.1 * sums.1).squareRoot()
            let b = (sums.2 * sums.2 + sums.3 * sums.3).squareRoot()
            for index in slicers.indices {
                guard let value = slicers[index].clock.push(y - slicers[index].gain * b) else { continue }
                let bit: UInt8 = value > 0 ? 1 : 0
                if let frame = slicers[index].normal.push(bit) { accept(frame, into: &frames) }
                if let frame = slicers[index].inverted.push(bit ^ 1) { accept(frame, into: &frames) }
            }
        }
        return frames
    }

    /// Denselben Ruf liefern meist mehrere Entscheider – nur einmal weitergeben.
    private func accept(_ frame: DSCFrame, into frames: inout [DSCFrame]) {
        let horizon = Int(Self.sampleRate)
        recent.removeAll { sampleCounter - $0.sample > horizon }
        guard !recent.contains(where: { $0.symbols == frame.symbols }) else { return }
        recent.append((frame.symbols, sampleCounter))
        frames.append(frame)
    }
}

// MARK: - Auswertung

enum DSCFormat: UInt8, Sendable, CaseIterable {
    case area = 102, distress = 112, group = 114, allShips = 116, individual = 120, automatic = 123

    var title: String {
        switch self {
        case .area: String(localized: "Gebiet")
        case .distress: String(localized: "Notruf")
        case .group: String(localized: "Gruppe")
        case .allShips: String(localized: "Alle Schiffe")
        case .individual: String(localized: "Einzelruf")
        case .automatic: String(localized: "Einzelruf (automatisch)")
        }
    }
}

enum DSCCategory: UInt8, Sendable {
    case routine = 100, safety = 108, urgency = 110, distress = 112

    var title: String {
        switch self {
        case .routine: String(localized: "Routine")
        case .safety: String(localized: "Sicherheit")
        case .urgency: String(localized: "Dringlichkeit")
        case .distress: String(localized: "Notfall")
        }
    }
}

struct DSCPosition: Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    var text: String {
        func dm(_ value: Double, _ pos: String, _ neg: String, width: Int) -> String {
            let a = abs(value)
            let deg = Int(a), min = Int(((a - Double(deg)) * 60).rounded())
            return String(format: "%0\(width)d° %02d′ %@", deg, min, value < 0 ? neg : pos)
        }
        return dm(latitude, "N", "S", width: 2) + "  " + dm(longitude, "O", "W", width: 3)
    }
}

/// Rechteck eines Gebietsrufs: Bezugspunkt = Nordwestecke, Ausdehnung nach
/// Süden und Osten (ITU-R M.493, Anhang 1).
struct DSCArea: Sendable, Equatable {
    var north: Double
    var west: Double
    var heightDegrees: Int
    var widthDegrees: Int

    var south: Double { north - Double(heightDegrees) }
    var east: Double { west + Double(widthDegrees) }
    var text: String {
        String(format: String(localized: "%.0f°%@ %.0f°%@, %d° nach Süden × %d° nach Osten"),
               abs(north), north < 0 ? "S" : "N", abs(west), west < 0 ? "W" : "O", heightDegrees, widthDegrees)
    }
}

struct DSCCall: Sendable, Equatable {
    var format: DSCFormat
    var category: DSCCategory?
    /// Absender (MMSI).
    var sender: Int
    /// Empfänger bei Einzel- und Gruppenruf.
    var address: Int?
    var area: DSCArea?
    var firstCommand: UInt8?
    var secondCommand: UInt8?
    /// Schiff in Not bei Bestätigung und Relais (bei Notruf = Absender).
    var distressID: Int?
    var nature: UInt8?
    var position: DSCPosition?
    var positionUnknown = false
    /// UTC-Zeit der Position (Stunde, Minute).
    var hour: Int?
    var minute: Int?
    /// Folgekommunikation (Telebefehl 100 = Sprechfunk FM, 109 = SSB …).
    var subsequent: UInt8?
    var frequency: String?
    var endOfSequence: UInt8
    var symbols: [UInt8]

    // MARK: Einordnung

    var isDistressAcknowledgement: Bool { firstCommand == 110 && category == .distress }
    var isDistressRelay: Bool { firstCommand == 112 && category == .distress }
    /// Alles, was einen Seenotfall betrifft.
    var concernsDistress: Bool { format == .distress || category == .distress }
    var isTest: Bool { firstCommand == 118 }

    /// Kurzbezeichnung für die Liste.
    var kindText: String {
        if format == .distress { return String(localized: "Notruf") }
        if isDistressAcknowledgement { return String(localized: "Notruf-Bestätigung") }
        if isDistressRelay { return String(localized: "Notruf-Relais") }
        if isTest { return String(localized: "Testruf") }
        return category?.title ?? format.title
    }

    var acknowledgementText: String? {
        switch endOfSequence {
        case 117: String(localized: "Quittung erbeten")
        case 122: String(localized: "Quittung")
        default: nil
        }
    }

    var natureText: String? { nature.flatMap(Self.natureText) }

    var timeText: String? {
        guard let hour, let minute else { return nil }
        return String(format: "%02d:%02d UTC", hour, minute)
    }

    static func natureText(_ code: UInt8) -> String? {
        switch code {
        case 100: String(localized: "Feuer, Explosion")
        case 101: String(localized: "Wassereinbruch")
        case 102: String(localized: "Kollision")
        case 103: String(localized: "Grundberührung")
        case 104: String(localized: "Schlagseite, Kentergefahr")
        case 105: String(localized: "Sinken")
        case 106: String(localized: "Manövrierunfähig, treibend")
        case 107: String(localized: "Nicht näher bezeichnet")
        case 108: String(localized: "Schiff wird verlassen")
        case 109: String(localized: "Piraterie, bewaffneter Überfall")
        case 110: String(localized: "Mensch über Bord")
        case 112: String(localized: "Seenotfunkbake (EPIRB)")
        default: nil
        }
    }

    static func firstCommandText(_ code: UInt8) -> String? {
        switch code {
        case 100: String(localized: "Sprechfunk (FM)")
        case 101: String(localized: "Sprechfunk (FM, duplex)")
        case 103: String(localized: "Abfrage")
        case 104: String(localized: "Kann nicht folgen")
        case 105: String(localized: "Ende des Rufs")
        case 106: String(localized: "Daten")
        case 109: String(localized: "Sprechfunk (SSB)")
        case 110: String(localized: "Notruf-Bestätigung")
        case 112: String(localized: "Notruf-Relais")
        case 113: String(localized: "Funkfernschreiben (FEC)")
        case 115: String(localized: "Funkfernschreiben (ARQ)")
        case 118: String(localized: "Test")
        case 121: String(localized: "Positionsabfrage/-meldung")
        case 126: String(localized: "keine Angabe")
        default: nil
        }
    }

    static func secondCommandText(_ code: UInt8) -> String? {
        switch code {
        case 100: String(localized: "kein Grund")
        case 101: String(localized: "Überlastung")
        case 102: String(localized: "besetzt")
        case 103: String(localized: "Warteschlange")
        case 104: String(localized: "Station gesperrt")
        case 105: String(localized: "kein Funker")
        case 106: String(localized: "Funker vorübergehend abwesend")
        case 107: String(localized: "Gerät ausgeschaltet")
        case 108: String(localized: "Kanal nicht nutzbar")
        case 109: String(localized: "Betriebsart nicht nutzbar")
        case 110: String(localized: "Neutrale Schiffe und Luftfahrzeuge (bewaffneter Konflikt)")
        case 111: String(localized: "Sanitätstransport")
        case 112: String(localized: "öffentliche Fernsprechstelle")
        case 113: String(localized: "Fax/Daten")
        case 126: String(localized: "keine Angabe")
        default: nil
        }
    }

    // MARK: Zerlegen

    /// Zeichen vom Formatkennzeichen (zweimal) bis ECC. `nil`, wenn das
    /// Prüfzeichen nicht stimmt oder der Aufbau nicht passt.
    static func parse(_ s: [UInt8]) -> DSCCall? {
        guard s.count >= 6, s.count <= DSCFrameAssembler.maxMessageSymbols + 2,
              s.allSatisfy({ $0 < 128 }), s[0] == s[1],
              let format = DSCFormat(rawValue: s[0]) else { return nil }
        let eos = s.count - 2
        guard DSCSymbol.endOfSequence.contains(s[eos]), DSCSymbol.ecc(s[1...eos]) == s[eos + 1] else { return nil }
        var call = DSCCall(format: format, sender: 0, endOfSequence: s[eos], symbols: s)
        let body = Array(s[2..<eos])
        var i = 0
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard i + n <= body.count else { return nil }
            defer { i += n }
            return body[i..<(i + n)]
        }
        func mmsi() -> Int?? { take(5).map(Self.mmsi) }
        /// Notfalldaten: Art, Position, Zeit, Folgekommunikation.
        func distressDetails() -> Bool {
            guard let nature = take(1), let position = take(5), let time = take(2), let next = take(1) else { return false }
            call.nature = nature.first
            (call.position, call.positionUnknown) = Self.position(position)
            (call.hour, call.minute) = Self.time(time)
            call.subsequent = next.first
            return true
        }
        /// Telebefehle und Rest (Kanal/Frequenz oder Position).
        func commands() -> Bool {
            guard let first = take(1)?.first else { return false }
            call.firstCommand = first
            if first == 110 || first == 112, call.category == .distress {
                guard let id = mmsi(), let id else { return false }
                call.distressID = id
                return distressDetails()
            }
            guard let second = take(1)?.first else { return false }
            call.secondCommand = second
            let rest = body[i...]
            i = body.count
            if first == 121, rest.count >= 5 {
                (call.position, call.positionUnknown) = Self.position(rest.prefix(5))
                if rest.count >= 7 { (call.hour, call.minute) = Self.time(rest.dropFirst(5).prefix(2)) }
            } else if rest.count >= 3 {
                call.frequency = Self.frequency(rest.prefix(3))
                if rest.count >= 6, let rx = Self.frequency(rest.dropFirst(3).prefix(3)), rx != call.frequency {
                    call.frequency = [call.frequency, rx].compactMap { $0 }.joined(separator: " / ")
                }
            }
            return true
        }
        switch format {
        case .distress:
            guard let id = mmsi(), let id else { return nil }
            call.sender = id
            call.distressID = id
            call.category = .distress
            guard distressDetails() else { return nil }
        case .allShips:
            guard let cat = take(1)?.first, let category = DSCCategory(rawValue: cat),
                  let id = mmsi(), let id else { return nil }
            call.category = category
            call.sender = id
            guard commands() else { return nil }
        case .individual, .automatic, .group, .area:
            if format == .area {
                guard let area = take(5).flatMap(Self.area) else { return nil }
                call.area = area
            } else {
                guard let to = mmsi(), let to else { return nil }
                call.address = to
            }
            guard let cat = take(1)?.first, let category = DSCCategory(rawValue: cat),
                  let id = mmsi(), let id else { return nil }
            call.category = category
            call.sender = id
            guard commands() else { return nil }
        }
        guard i == body.count else { return nil }
        return call
    }

    /// Zehn Ziffern aus fünf Zeichen (00–99); `nil` bei anderen Werten.
    static func digits(_ symbols: some Collection<UInt8>) -> [Int]? {
        var digits: [Int] = []
        for s in symbols {
            guard s < 100 else { return nil }
            digits += [Int(s) / 10, Int(s) % 10]
        }
        return digits
    }

    /// MMSI: neun Ziffern, die zehnte ist 0.
    static func mmsi(_ symbols: some Collection<UInt8>) -> Int? {
        guard let d = digits(symbols), d.count == 10 else { return nil }
        return d.prefix(9).reduce(0) { $0 * 10 + $1 }
    }

    static func position(_ symbols: some Collection<UInt8>) -> (DSCPosition?, Bool) {
        guard symbols.count == 5 else { return (nil, false) }
        if symbols.allSatisfy({ $0 == 99 }) { return (nil, true) }
        guard let d = digits(symbols), d[0] <= 3 else { return (nil, false) }
        let latDeg = d[1] * 10 + d[2], latMin = d[3] * 10 + d[4]
        let lonDeg = d[5] * 100 + d[6] * 10 + d[7], lonMin = d[8] * 10 + d[9]
        guard latDeg <= 90, lonDeg <= 180, latMin < 60, lonMin < 60 else { return (nil, false) }
        var lat = Double(latDeg) + Double(latMin) / 60, lon = Double(lonDeg) + Double(lonMin) / 60
        // Quadrant: 0 = NO, 1 = NW, 2 = SO, 3 = SW.
        if d[0] >= 2 { lat = -lat }
        if d[0] == 1 || d[0] == 3 { lon = -lon }
        return (DSCPosition(latitude: lat, longitude: lon), false)
    }

    static func time(_ symbols: some Collection<UInt8>) -> (Int?, Int?) {
        guard symbols.count == 2 else { return (nil, nil) }
        let h = Int(symbols.first!), m = Int(symbols.dropFirst().first!)
        guard h < 24, m < 60 else { return (nil, nil) }   // 88 88 = unbekannt
        return (h, m)
    }

    static func area(_ symbols: some Collection<UInt8>) -> DSCArea? {
        guard let d = digits(symbols), d.count == 10, d[0] <= 3 else { return nil }
        let lat = d[1] * 10 + d[2], lon = d[3] * 100 + d[4] * 10 + d[5]
        guard lat <= 90, lon <= 180 else { return nil }
        let north = d[0] >= 2 ? -Double(lat) : Double(lat)
        let west = (d[0] == 1 || d[0] == 3) ? -Double(lon) : Double(lon)
        return DSCArea(north: north, west: west, heightDegrees: d[6] * 10 + d[7], widthDegrees: d[8] * 10 + d[9])
    }

    /// Kanal bzw. Frequenz aus drei Zeichen (sechs Ziffern).
    static func frequency(_ symbols: some Collection<UInt8>) -> String? {
        guard symbols.count == 3 else { return nil }
        if symbols.allSatisfy({ $0 == 126 }) { return nil }
        guard let d = digits(symbols) else { return nil }
        switch d[0] {
        case 9:
            let channel = d[2...5].reduce(0) { $0 * 10 + $1 }
            return String(localized: "Kanal \(channel)")
        case 0...2:
            let hundredHz = d.reduce(0) { $0 * 10 + $1 }
            return String(format: "%.1f kHz", Double(hundredHz) / 10).replacingOccurrences(of: ".", with: ",")
        case 3:
            let number = d[1...5].map(String.init).joined()
            return String(localized: "HF-Kanal \(number)")
        default:
            return nil
        }
    }

    /// Klartext der Folgekommunikation („Sprechfunk (FM)“).
    var subsequentText: String? { subsequent.flatMap(Self.firstCommandText) }
}

// MARK: - Seefunkkennungen (MMSI)

enum MaritimeIdentity {
    enum Kind: Sendable, Equatable {
        case ship, coastStation, group, sarAircraft, handheld, craft, aidToNavigation, sart, manOverboard, epirb, unknown
        var title: String? {
            switch self {
            case .ship: nil
            case .coastStation: String(localized: "Küstenfunkstelle")
            case .group: String(localized: "Gruppe")
            case .sarAircraft: String(localized: "SAR-Luftfahrzeug")
            case .handheld: String(localized: "Handfunkgerät")
            case .craft: String(localized: "Beiboot")
            case .aidToNavigation: String(localized: "Seezeichen")
            case .sart: "AIS-SART"
            case .manOverboard: String(localized: "MOB-Sender")
            case .epirb: "EPIRB"
            case .unknown: nil
            }
        }
    }

    /// Art der Kennung und Ländercode (MID).
    static func classify(_ mmsi: Int) -> (kind: Kind, mid: Int?) {
        let text = String(format: "%09d", mmsi)
        let d = Array(text).compactMap { $0.wholeNumberValue }
        guard d.count == 9 else { return (.unknown, nil) }
        func mid(_ at: Int) -> Int { d[at] * 100 + d[at + 1] * 10 + d[at + 2] }
        if text.hasPrefix("970") { return (.sart, nil) }
        if text.hasPrefix("972") { return (.manOverboard, nil) }
        if text.hasPrefix("974") { return (.epirb, nil) }
        if text.hasPrefix("111") { return (.sarAircraft, mid(3)) }
        if text.hasPrefix("00") { return (.coastStation, mid(2)) }
        if text.hasPrefix("0") { return (.group, mid(1)) }
        if text.hasPrefix("98") { return (.craft, mid(2)) }
        if text.hasPrefix("99") { return (.aidToNavigation, mid(2)) }
        if text.hasPrefix("8") { return (.handheld, mid(1)) }
        if (2...7).contains(d[0]) { return (.ship, mid(0)) }
        return (.unknown, nil)
    }

    static func country(_ mmsi: Int) -> String? {
        classify(mmsi).mid.flatMap { countries[$0] }
    }

    /// Bekannte Küstenfunkstellen (Auswahl).
    static let stations: [Int: String] = [
        2_111_240: "Bremen Rescue (MRCC)",
    ]

    /// Länder nach Maritime Identification Digits (ITU, Auswahl der vergebenen MID).
    static let countries: [Int: String] = {
        var map: [Int: String] = [
            201: "Albanien", 202: "Andorra", 203: "Österreich", 204: "Portugal (Azoren)", 205: "Belgien",
            206: "Belarus", 207: "Bulgarien", 208: "Vatikanstadt", 209: "Zypern", 210: "Zypern", 211: "Deutschland",
            212: "Zypern", 213: "Georgien", 214: "Moldau", 215: "Malta", 216: "Armenien", 218: "Deutschland",
            219: "Dänemark", 220: "Dänemark", 224: "Spanien", 225: "Spanien", 226: "Frankreich", 227: "Frankreich",
            228: "Frankreich", 229: "Malta", 230: "Finnland", 231: "Färöer", 232: "Vereinigtes Königreich",
            233: "Vereinigtes Königreich", 234: "Vereinigtes Königreich", 235: "Vereinigtes Königreich",
            236: "Gibraltar", 237: "Griechenland", 238: "Kroatien", 239: "Griechenland", 240: "Griechenland",
            241: "Griechenland", 242: "Marokko", 243: "Ungarn", 244: "Niederlande", 245: "Niederlande",
            246: "Niederlande", 247: "Italien", 248: "Malta", 249: "Malta", 250: "Irland", 251: "Island",
            252: "Liechtenstein", 253: "Luxemburg", 254: "Monaco", 255: "Portugal (Madeira)", 256: "Malta",
            257: "Norwegen", 258: "Norwegen", 259: "Norwegen", 261: "Polen", 262: "Montenegro", 263: "Portugal",
            264: "Rumänien", 265: "Schweden", 266: "Schweden", 267: "Slowakei", 268: "San Marino", 269: "Schweiz",
            270: "Tschechien", 271: "Türkei", 272: "Ukraine", 273: "Russland", 274: "Nordmazedonien",
            275: "Lettland", 276: "Estland", 277: "Litauen", 278: "Slowenien", 279: "Serbien",
            301: "Anguilla", 303: "USA (Alaska)", 304: "Antigua und Barbuda", 305: "Antigua und Barbuda",
            306: "Curaçao, Sint Maarten, Bonaire", 307: "Aruba", 308: "Bahamas", 309: "Bahamas", 310: "Bermuda",
            311: "Bahamas", 312: "Belize", 314: "Barbados", 316: "Kanada", 319: "Kaimaninseln", 321: "Costa Rica",
            323: "Kuba", 325: "Dominica", 327: "Dominikanische Republik", 329: "Guadeloupe", 330: "Grenada",
            331: "Grönland", 332: "Guatemala", 334: "Honduras", 336: "Haiti", 338: "USA", 339: "Jamaika",
            341: "St. Kitts und Nevis", 343: "St. Lucia", 345: "Mexiko", 347: "Martinique", 348: "Montserrat",
            350: "Nicaragua", 358: "Puerto Rico", 359: "El Salvador", 361: "St. Pierre und Miquelon",
            362: "Trinidad und Tobago", 364: "Turks- und Caicosinseln", 375: "St. Vincent und die Grenadinen",
            376: "St. Vincent und die Grenadinen", 377: "St. Vincent und die Grenadinen",
            378: "Britische Jungferninseln", 379: "Amerikanische Jungferninseln",
            401: "Afghanistan", 403: "Saudi-Arabien", 405: "Bangladesch", 408: "Bahrain", 410: "Bhutan",
            412: "China", 413: "China", 414: "China", 416: "Taiwan", 417: "Sri Lanka", 419: "Indien", 422: "Iran",
            423: "Aserbaidschan", 425: "Irak", 428: "Israel", 431: "Japan", 432: "Japan", 434: "Turkmenistan",
            436: "Kasachstan", 437: "Usbekistan", 438: "Jordanien", 440: "Südkorea", 441: "Südkorea",
            443: "Palästina", 445: "Nordkorea", 447: "Kuwait", 450: "Libanon", 451: "Kirgisistan", 453: "Macau",
            455: "Malediven", 457: "Mongolei", 459: "Nepal", 461: "Oman", 463: "Pakistan", 466: "Katar",
            468: "Syrien", 470: "Vereinigte Arabische Emirate", 471: "Vereinigte Arabische Emirate",
            472: "Tadschikistan", 473: "Jemen", 475: "Jemen", 477: "Hongkong", 478: "Bosnien und Herzegowina",
            501: "Frankreich (Adélieland)", 503: "Australien", 506: "Myanmar", 508: "Brunei", 510: "Mikronesien",
            511: "Palau", 512: "Neuseeland", 514: "Kambodscha", 515: "Kambodscha", 516: "Weihnachtsinsel",
            518: "Cookinseln", 520: "Fidschi", 523: "Kokosinseln", 525: "Indonesien", 529: "Kiribati", 531: "Laos",
            533: "Malaysia", 536: "Nördliche Marianen", 538: "Marshallinseln", 540: "Neukaledonien", 542: "Niue",
            544: "Nauru", 546: "Französisch-Polynesien", 548: "Philippinen", 550: "Osttimor",
            553: "Papua-Neuguinea", 555: "Pitcairninseln", 557: "Salomonen", 559: "Amerikanisch-Samoa",
            561: "Samoa", 563: "Singapur", 564: "Singapur", 565: "Singapur", 566: "Singapur", 567: "Thailand",
            570: "Tonga", 572: "Tuvalu", 574: "Vietnam", 576: "Vanuatu", 577: "Vanuatu", 578: "Wallis und Futuna",
            601: "Südafrika", 603: "Angola", 605: "Algerien", 607: "Frankreich (St. Paul, Amsterdam)",
            608: "Ascension", 609: "Burundi", 610: "Benin", 611: "Botswana", 612: "Zentralafrikanische Republik",
            613: "Kamerun", 615: "Kongo", 616: "Komoren", 617: "Kap Verde", 618: "Frankreich (Crozetinseln)",
            619: "Elfenbeinküste", 620: "Komoren", 621: "Dschibuti", 622: "Ägypten", 624: "Äthiopien",
            625: "Eritrea", 626: "Gabun", 627: "Ghana", 629: "Gambia", 630: "Guinea-Bissau",
            631: "Äquatorialguinea", 632: "Guinea", 633: "Burkina Faso", 634: "Kenia",
            635: "Frankreich (Kerguelen)", 636: "Liberia", 637: "Liberia", 638: "Südsudan", 642: "Libyen",
            644: "Lesotho", 645: "Mauritius", 647: "Madagaskar", 649: "Mali", 650: "Mosambik",
            654: "Mauretanien", 655: "Malawi", 656: "Niger", 657: "Nigeria", 659: "Namibia", 660: "Réunion",
            661: "Ruanda", 662: "Sudan", 663: "Senegal", 664: "Seychellen", 665: "St. Helena", 666: "Somalia",
            667: "Sierra Leone", 668: "São Tomé und Príncipe", 669: "Eswatini", 670: "Tschad", 671: "Togo",
            672: "Tunesien", 674: "Tansania", 675: "Uganda", 676: "DR Kongo", 677: "Tansania", 678: "Sambia",
            679: "Simbabwe",
            701: "Argentinien", 710: "Brasilien", 720: "Bolivien", 725: "Chile", 730: "Kolumbien",
            735: "Ecuador", 740: "Falklandinseln", 745: "Französisch-Guayana", 750: "Guyana", 755: "Paraguay",
            760: "Peru", 765: "Suriname", 770: "Uruguay", 775: "Venezuela",
        ]
        for mid in [351, 352, 353, 354, 355, 356, 357, 370, 371, 372, 373, 374] { map[mid] = "Panama" }
        for mid in 366...369 { map[mid] = "USA" }
        return map
    }()
}

// MARK: - Liste der Rufe

/// Ein Eintrag der Rufliste; gleiche Rufe binnen 10 Minuten zählen als Wiederholung
/// (Notrufe wiederholt das Gerät von selbst alle 3,5–4,5 Minuten).
struct DSCLogEntry: Identifiable, Sendable, Equatable {
    let id: Int
    var call: DSCCall
    var first: Date
    var last: Date
    var repeats = 1
    var corrected = 0
}

struct DSCCallLog: Sendable {
    static let maxEntries = 500
    static let repeatWindow: TimeInterval = 600

    private(set) var entries: [DSCLogEntry] = []   // neueste zuerst
    private var nextID = 1

    /// Nimmt einen Ruf auf; `true`, wenn er neu (keine Wiederholung) ist.
    @discardableResult
    mutating func ingest(_ call: DSCCall, corrected: Int = 0, at date: Date = Date()) -> Bool {
        if let index = entries.firstIndex(where: { $0.call.symbols == call.symbols && date.timeIntervalSince($0.last) < Self.repeatWindow }) {
            entries[index].last = date
            entries[index].repeats += 1
            entries[index].corrected = max(entries[index].corrected, corrected)
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return false
        }
        entries.insert(DSCLogEntry(id: nextID, call: call, first: date, last: date, corrected: corrected), at: 0)
        nextID += 1
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        return true
    }
}
