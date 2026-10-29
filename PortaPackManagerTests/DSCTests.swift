import Foundation
import Testing
@testable import PortaPackManager

/// DSC-Modulator für die Tests: Zeichen → Bits (Punktmuster, Phasierung,
/// DX/RX) → AFSK 1300/2100 Hz als FM-Diskriminatorsignal (48 kHz) bzw. als
/// FM-IQ-Signal (2,4 MS/s, 240 kHz über der Abstimmfrequenz wie am Gerät).
enum DSCTestModulator {
    /// Nachricht ohne ECC → Bitfolge der ganzen Aussendung.
    static func bits(message: [UInt8], dots: Int = 20) -> [UInt8] {
        let symbols = DSCSymbol.transmission(message: message)
        return (0..<dots).map { UInt8(($0 + 1) % 2) } + symbols.flatMap(DSCSymbol.bits)
    }

    /// Zeichenfolge mit einzelnen verfälschten Bits: (Platz, Bit) – Platz wie in `transmission`.
    static func bits(message: [UInt8], flips: [(slot: Int, bit: Int)], dots: Int = 20) -> [UInt8] {
        var b = bits(message: message, dots: dots)
        for flip in flips { b[dots + flip.slot * 10 + flip.bit] ^= 1 }
        return b
    }

    /// Diskriminatorwerte: Ton je Bit (Y = 1 = 1300 Hz, B = 0 = 2100 Hz), stetige
    /// Phase. `emphasis` hebt 2100 Hz an wie die Vorverzerrung des Senders.
    static func discriminator(_ bits: [UInt8], amplitude: Float = 0.3, emphasis: Float = 1.6,
                              noise: Float = 0, lead: Int = 2000, seed: UInt64 = 1) -> [Float] {
        let rate = DSCDemodulator.sampleRate, spb = rate / DSCDemodulator.baud
        var rng = SplitMix(seed: seed)
        var out = [Float](repeating: 0, count: lead)
        var phase = 0.0
        let total = Int((Double(bits.count) * spb).rounded())
        for n in 0..<total {
            let bit = bits[min(Int(Double(n) / spb), bits.count - 1)]
            let f = bit == 1 ? DSCDemodulator.yTone : DSCDemodulator.bTone
            phase += 2 * .pi * f / rate
            out.append(amplitude * (bit == 1 ? 1 : emphasis) * Float(sin(phase)))
        }
        out += [Float](repeating: 0, count: lead)
        if noise > 0 { for i in out.indices { out[i] += noise * rng.gaussian() } }
        return out
    }

    /// FM-modulierte IQ-Werte (int8) für die ganze Kette über `FMChannelizer`.
    static func iq(_ bits: [UInt8], deviation: Double = 3000, noise: Double = 0) -> Data {
        let audio = discriminator(bits, amplitude: 1, emphasis: 1, lead: 4000)
        let inRate = FMChannelizer.inputRate, factor = Int(inRate / DSCDemodulator.sampleRate)
        var rng = SplitMix(seed: 9)
        var bytes = [UInt8]()
        bytes.reserveCapacity(audio.count * factor * 2)
        var phase = 0.0
        for a in audio {
            for _ in 0..<factor {
                phase += 2 * .pi * (FMChannelizer.offset + deviation * Double(a)) / inRate
                if phase > .pi { phase -= 2 * .pi }
                let i = 90 * cos(phase) + noise * Double(rng.gaussian())
                let q = 90 * sin(phase) + noise * Double(rng.gaussian())
                bytes.append(UInt8(bitPattern: Int8(max(-127, min(127, i.rounded())))))
                bytes.append(UInt8(bitPattern: Int8(max(-127, min(127, q.rounded())))))
            }
        }
        return Data(bytes)
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func gaussian() -> Float {
            let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-12), u2 = Double(next() >> 11) / Double(1 << 53)
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
    }
}

/// Baut Nachrichten nach ITU-R M.493 (ohne ECC).
enum DSCTestMessages {
    static func mmsi(_ id: Int) -> [UInt8] {
        let digits = Array(String(format: "%09d", id) + "0").map { UInt8($0.wholeNumberValue!) }
        return stride(from: 0, to: 10, by: 2).map { digits[$0] * 10 + digits[$0 + 1] }
    }

    /// Position aus Quadrant und Grad/Minuten.
    static func position(quadrant: UInt8, latDeg: Int, latMin: Int, lonDeg: Int, lonMin: Int) -> [UInt8] {
        let digits = [Int(quadrant), latDeg / 10, latDeg % 10, latMin / 10, latMin % 10,
                      lonDeg / 100, lonDeg / 10 % 10, lonDeg % 10, lonMin / 10, lonMin % 10]
        return stride(from: 0, to: 10, by: 2).map { UInt8(digits[$0] * 10 + digits[$0 + 1]) }
    }

    static let ship = 211_234_560
    static let other = 244_123_450
    static let coast = 2_111_240
    /// 53° 52′ N, 9° 03′ O (Elbmündung).
    static let elbe = position(quadrant: 0, latDeg: 53, latMin: 52, lonDeg: 9, lonMin: 3)

    static var distress: [UInt8] {
        [112, 112] + mmsi(ship) + [101] + elbe + [14, 35] + [100] + [127]
    }
    static var allShipsUrgency: [UInt8] {
        [116, 116, 110] + mmsi(coast) + [100, 126] + [90, 00, 16] + [127]
    }
    static var distressAcknowledgement: [UInt8] {
        [116, 116, 112] + mmsi(coast) + [110] + mmsi(ship) + [101] + elbe + [14, 35] + [100] + [127]
    }
    static var distressRelayIndividual: [UInt8] {
        [120, 120] + mmsi(coast) + [112] + mmsi(other) + [112] + mmsi(ship) + [110] + position(quadrant: 0, latDeg: 54, latMin: 10, lonDeg: 7, lonMin: 50) + [88, 88] + [100] + [117]
    }
    static var group: [UInt8] {
        [114, 114] + mmsi(21_100_000) + [108] + mmsi(coast) + [100, 126] + [90, 00, 22] + [127]
    }
    static var area: [UInt8] {
        // Nordwestecke 56° N, 6° O, 3° nach Süden, 4° nach Osten.
        [102, 102, 5, 60, 6, 3, 4] + [110] + mmsi(coast) + [109, 126] + [90, 00, 67] + [127]
    }
    static var individualRoutine: [UInt8] {
        [120, 120] + mmsi(other) + [100] + mmsi(ship) + [100, 126] + [90, 00, 72] + [117]
    }
    static var individualAcknowledgement: [UInt8] {
        [120, 120] + mmsi(ship) + [100] + mmsi(other) + [100, 126] + [90, 00, 72] + [122]
    }
    static var test: [UInt8] {
        [120, 120] + mmsi(coast) + [108] + mmsi(ship) + [118, 126] + [126, 126, 126] + [117]
    }
    static var all: [(String, [UInt8])] {
        [("Notruf", distress), ("Alle Schiffe", allShipsUrgency), ("Bestätigung", distressAcknowledgement),
         ("Relais", distressRelayIndividual), ("Gruppe", group), ("Gebiet", area),
         ("Einzelruf", individualRoutine), ("Quittung", individualAcknowledgement), ("Test", test)]
    }
}

@Suite("DSC")
struct DSCTests {
    private func decode(_ samples: [Float]) -> [DSCFrame] {
        let demod = DSCDemodulator()
        var frames: [DSCFrame] = []
        for chunk in stride(from: 0, to: samples.count, by: 4096) {
            frames += demod.process(Array(samples[chunk..<min(chunk + 4096, samples.count)]))
        }
        return frames
    }

    private func full(_ message: [UInt8]) -> [UInt8] {
        message + [DSCSymbol.ecc(message.dropFirst())]
    }

    // MARK: Zeichencode

    @Test("Normzeichen: Prüfbits zählen die B-Bits (Nullen)")
    func symbolTable() {
        #expect(DSCSymbol.bits(0) == [0, 0, 0, 0, 0, 0, 0, 1, 1, 1])
        #expect(DSCSymbol.bits(127) == [1, 1, 1, 1, 1, 1, 1, 0, 0, 0])
        // 125 = 1111101₂ → niederwertigstes Bit zuerst, eine Null.
        #expect(DSCSymbol.bits(125) == [1, 0, 1, 1, 1, 1, 1, 0, 0, 1])
        // 108 = 1101100₂ → 0,0,1,1,0,1,1, drei Nullen.
        #expect(DSCSymbol.bits(108) == [0, 0, 1, 1, 0, 1, 1, 0, 1, 1])
        for value in 0..<128 {
            let word = DSCSymbol.word(DSCSymbol.bits(UInt8(value)))
            #expect(DSCSymbol.table[word] == Int16(value))
            #expect(DSCSymbol.information(of: word) == UInt8(value))
            // Jeder Einzelbitfehler fällt auf.
            for bit in 0..<10 { #expect(DSCSymbol.table[word ^ (1 << bit)] == -1) }
        }
        #expect(DSCSymbol.table.filter { $0 >= 0 }.count == 128)
    }

    @Test("Aussendung: Phasierung, RX-Kopie vier Zeichen später, ECC, EOS dreimal in DX")
    func transmissionLayout() {
        let message = DSCTestMessages.distress
        let t = DSCSymbol.transmission(message: message)
        #expect(Array(t.prefix(12)) == [125, 111, 125, 110, 125, 109, 125, 108, 125, 107, 125, 106])
        #expect(t[13] == 105 && t[15] == 104)
        for (j, value) in message.enumerated() {
            #expect(t[2 * j + 12] == value)          // DX
            #expect(t[2 * j + 17] == value)          // RX, vier Zeichen dazwischen
        }
        let ecc = DSCSymbol.ecc(message.dropFirst())
        #expect(t.last == ecc)
        let eos = message.last!
        #expect(t.filter { $0 == eos }.count == 4)  // DX dreimal, RX einmal
        // ECC = XOR vom (einmal gezählten) Formatkennzeichen bis EOS.
        #expect(ecc == message.dropFirst().reduce(0, ^))
    }

    // MARK: Auswertung

    @Test("Notruf: Absender, Land, Art, Position, Zeit, Folgekommunikation")
    func parseDistress() throws {
        let call = try #require(DSCCall.parse(full(DSCTestMessages.distress)))
        #expect(call.format == .distress && call.concernsDistress)
        #expect(call.sender == DSCTestMessages.ship)
        #expect(MaritimeIdentity.country(call.sender) == "Deutschland")
        #expect(call.natureText == "Wassereinbruch")
        let p = try #require(call.position)
        #expect(abs(p.latitude - (53 + 52.0 / 60)) < 1e-9 && abs(p.longitude - (9 + 3.0 / 60)) < 1e-9)
        #expect(call.timeText == "14:35 UTC")
        #expect(call.subsequentText == "Sprechfunk (FM)")
        #expect(call.kindText == "Notruf")
    }

    @Test("Quadranten der Position und unbekannte Position/Zeit")
    func quadrants() {
        let sw = DSCCall.position(DSCTestMessages.position(quadrant: 3, latDeg: 33, latMin: 30, lonDeg: 70, lonMin: 15)).0
        #expect(sw?.latitude == -33.5 && sw?.longitude == -70.25)
        let nw = DSCCall.position(DSCTestMessages.position(quadrant: 1, latDeg: 40, latMin: 0, lonDeg: 74, lonMin: 0)).0
        #expect(nw?.latitude == 40 && nw?.longitude == -74)
        let unknown = DSCCall.position([99, 99, 99, 99, 99] as [UInt8])
        #expect(unknown.0 == nil && unknown.1)
        #expect(DSCCall.time([88, 88] as [UInt8]).0 == nil)
    }

    @Test("Alle Formate: Felder werden richtig zugeordnet")
    func parseFormats() throws {
        let urgency = try #require(DSCCall.parse(full(DSCTestMessages.allShipsUrgency)))
        #expect(urgency.format == .allShips && urgency.category == .urgency && urgency.frequency == "Kanal 16")
        #expect(MaritimeIdentity.classify(urgency.sender).kind == .coastStation)

        let ack = try #require(DSCCall.parse(full(DSCTestMessages.distressAcknowledgement)))
        #expect(ack.isDistressAcknowledgement && ack.distressID == DSCTestMessages.ship && ack.natureText == "Wassereinbruch")
        #expect(ack.kindText == "Notruf-Bestätigung")

        let relay = try #require(DSCCall.parse(full(DSCTestMessages.distressRelayIndividual)))
        #expect(relay.isDistressRelay && relay.address == DSCTestMessages.coast && relay.sender == DSCTestMessages.other)
        #expect(relay.distressID == DSCTestMessages.ship && relay.natureText == "Mensch über Bord")
        #expect(relay.timeText == nil && relay.acknowledgementText == "Quittung erbeten")
        #expect(MaritimeIdentity.country(relay.sender) == "Niederlande")

        let group = try #require(DSCCall.parse(full(DSCTestMessages.group)))
        #expect(group.format == .group && group.category == .safety && group.frequency == "Kanal 22")
        #expect(MaritimeIdentity.classify(group.address!).kind == .group)

        let area = try #require(DSCCall.parse(full(DSCTestMessages.area)))
        #expect(area.area == DSCArea(north: 56, west: 6, heightDegrees: 3, widthDegrees: 4))
        #expect(DSCCall.firstCommandText(area.firstCommand!) == "Sprechfunk (SSB)")

        let routine = try #require(DSCCall.parse(full(DSCTestMessages.individualRoutine)))
        #expect(routine.format == .individual && routine.category == .routine && routine.frequency == "Kanal 72")
        let reply = try #require(DSCCall.parse(full(DSCTestMessages.individualAcknowledgement)))
        #expect(reply.acknowledgementText == "Quittung")

        let test = try #require(DSCCall.parse(full(DSCTestMessages.test)))
        #expect(test.isTest && test.frequency == nil && !test.concernsDistress)
    }

    @Test("Falsches Prüfzeichen oder unbekanntes Format wird verworfen")
    func rejects() {
        var bad = full(DSCTestMessages.distress)
        bad[bad.count - 1] ^= 1
        #expect(DSCCall.parse(bad) == nil)
        var unknownFormat = DSCTestMessages.distress
        unknownFormat[0] = 113; unknownFormat[1] = 113
        #expect(DSCCall.parse(full(unknownFormat)) == nil)
        #expect(DSCCall.parse([]) == nil)
    }

    @Test("Seefunkkennungen: Schiff, Küstenfunkstelle, Gruppe, SART, Land aus MID")
    func identities() {
        #expect(MaritimeIdentity.classify(211_234_560) == (.ship, 211))
        #expect(MaritimeIdentity.classify(2_111_240) == (.coastStation, 211))
        #expect(MaritimeIdentity.classify(21_100_000) == (.group, 211))
        #expect(MaritimeIdentity.classify(111_211_001) == (.sarAircraft, 211))
        #expect(MaritimeIdentity.classify(970_123_456).kind == .sart)
        #expect(MaritimeIdentity.classify(974_123_456).kind == .epirb)
        #expect(MaritimeIdentity.country(353_000_000) == "Panama")
        #expect(MaritimeIdentity.country(367_000_000) == "USA")
        #expect(MaritimeIdentity.country(2_111_240) == "Deutschland")
    }

    // MARK: Demodulator und Rahmen

    @Test("Jeder Format-Typ kommt durch Modulator und Dekoder zurück", arguments: DSCTestMessages.all.map(\.0))
    func roundTrip(name: String) throws {
        let message = try #require(DSCTestMessages.all.first { $0.0 == name }?.1)
        let frames = decode(DSCTestModulator.discriminator(DSCTestModulator.bits(message: message)))
        #expect(frames.count == 1)
        let frame = try #require(frames.first)
        #expect(frame.symbols == full(message))
        #expect(frame.corrected == 0)
        #expect(DSCCall.parse(frame.symbols) != nil)
    }

    @Test("Bitfehler in je einer Kopie: Zeitdiversität korrigiert")
    func diversity() throws {
        let message = DSCTestMessages.distress
        // DX-Kopie von Zeichen 2, 5, 9 und RX-Kopie von 3, 12 und des EOS verfälschen.
        let eos = message.count - 1
        let flips: [(Int, Int)] = [(2 * 2 + 12, 3), (2 * 5 + 12, 0), (2 * 9 + 12, 9),
                                   (2 * 3 + 17, 4), (2 * 12 + 17, 6), (2 * eos + 17, 1)]
        let bits = DSCTestModulator.bits(message: message, flips: flips)
        let frame = try #require(decode(DSCTestModulator.discriminator(bits)).first)
        #expect(frame.symbols == full(message))
        #expect(frame.corrected == 6)
    }

    @Test("Beide Kopien eines Zeichens kaputt: Prüfzeichen repariert, zwei solche nicht")
    func eccRepair() throws {
        let message = DSCTestMessages.allShipsUrgency
        let j = 4
        let one = DSCTestModulator.bits(message: message, flips: [(2 * j + 12, 2), (2 * j + 17, 5)])
        let frame = try #require(decode(DSCTestModulator.discriminator(one)).first)
        #expect(frame.symbols == full(message))

        let two = DSCTestModulator.bits(message: message, flips: [(2 * j + 12, 2), (2 * j + 17, 5),
                                                                   (2 * 6 + 12, 1), (2 * 6 + 17, 1)])
        #expect(decode(DSCTestModulator.discriminator(two)).isEmpty)
    }

    @Test("Phasierung mit gestörten Zeichen und vertauschten Tönen")
    func phasingAndPolarity() throws {
        let message = DSCTestMessages.group
        // Drei Phasierungszeichen gestört – der Rest reicht.
        let bits = DSCTestModulator.bits(message: message, flips: [(0, 1), (1, 1), (3, 7)])
        #expect(try #require(decode(DSCTestModulator.discriminator(bits)).first).symbols == full(message))
        // Töne vertauscht (Y/B invertiert).
        let inverted = DSCTestModulator.bits(message: message).map { $0 ^ 1 }
        #expect(try #require(decode(DSCTestModulator.discriminator(inverted)).first).symbols == full(message))
    }

    /// Rauschen σ = 0,25 je Wert bei Tonamplitude 0,3 (Knick der Kurve: ab 0,3 gehen einzelne Rufe verloren).
    @Test("Rauschen: Rufe kommen bei mäßigem Störabstand durch", arguments: [1, 2, 3] as [UInt64])
    func noise(seed: UInt64) throws {
        for (_, message) in DSCTestMessages.all {
            let samples = DSCTestModulator.discriminator(DSCTestModulator.bits(message: message), noise: 0.25, seed: seed)
            let frame = try #require(decode(samples).first)
            #expect(frame.symbols == full(message))
        }
    }

    @Test("Frequenzablage (Gleichanteil im Diskriminator) stört nicht")
    func frequencyOffset() throws {
        // 1,5 kHz Ablage ≈ 0,2 rad je Wert bei 48 kHz – halb so viel wie der Hub.
        for (_, message) in DSCTestMessages.all {
            let samples = DSCTestModulator.discriminator(DSCTestModulator.bits(message: message), noise: 0.1).map { $0 + 0.2 }
            #expect(try #require(decode(samples).first).symbols == full(message))
        }
    }

    @Test("Ganze Kette: FM-IQ über FMChannelizer bis zum Ruf")
    func fullChain() throws {
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 8_000)
        let demod = DSCDemodulator()
        let iq = DSCTestModulator.iq(DSCTestModulator.bits(message: DSCTestMessages.distress), noise: 8)
        var frames: [DSCFrame] = []
        let block = 262_144
        for start in stride(from: 0, to: iq.count, by: block) {
            frames += demod.process(front.process(iq.subdata(in: start..<min(start + block, iq.count)))[0])
        }
        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(DSCCall.parse(frame.symbols)?.natureText == "Wassereinbruch")
    }

    @Test("Zwei Rufe hintereinander werden beide erkannt")
    func backToBack() {
        let bits = DSCTestModulator.bits(message: DSCTestMessages.distress) + [UInt8](repeating: 0, count: 37)
            + DSCTestModulator.bits(message: DSCTestMessages.individualRoutine)
        var assembler = DSCFrameAssembler()
        let frames = bits.compactMap { assembler.push($0) }
        #expect(frames.map(\.symbols) == [full(DSCTestMessages.distress), full(DSCTestMessages.individualRoutine)])
    }

    @Test("Rufliste fasst Wiederholungen binnen 10 Minuten zusammen")
    func callLog() throws {
        var log = DSCCallLog()
        let call = try #require(DSCCall.parse(full(DSCTestMessages.distress)))
        let t = Date(timeIntervalSince1970: 1_000_000)
        let first = log.ingest(call, at: t)
        let repeated = log.ingest(call, at: t.addingTimeInterval(240))
        #expect(first && !repeated)
        #expect(log.entries.count == 1 && log.entries[0].repeats == 2)
        let later = log.ingest(call, at: t.addingTimeInterval(240 + 601))
        #expect(later)
        #expect(log.entries.count == 2)
    }
}
