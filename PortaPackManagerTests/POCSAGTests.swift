import Foundation
import Testing
@testable import PortaPackManager

@Suite("POCSAG")
struct POCSAGTests {
    /// Bitfolge → 2-FSK ±4,5 kHz (1 = untere Frequenz) als IQ bei 2,4 MS/s.
    private func fskIQ(_ bits: [UInt8], bitRate: Int, offset: Double = 0, inverted: Bool = false,
                       noise: Double = 3, amplitude: Double = 40, seed: UInt64 = 1) -> Data {
        let rate = FMChannelizer.inputRate
        let samplesPerBit = rate / Double(bitRate)
        var freq = [Double](repeating: offset, count: Int(rate * 0.05))
        var clock = 0.0
        for bit in bits {
            clock += samplesPerBit
            let count = Int(clock.rounded())
            clock -= Double(count)
            let low = (bit == 1) != inverted
            freq += [Double](repeating: offset + (low ? -4_500 : 4_500), count: count)
        }
        freq += [Double](repeating: offset, count: Int(rate * 0.05))
        return TestSignals.iq(carriers: [freq], amplitude: amplitude, noise: noise, seed: seed)
    }

    private func decode(_ iq: Data) -> [PagerMessage] {
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 9_000)
        let demod = POCSAGDemodulator()
        var out: [PagerMessage] = []
        for block in TestSignals.blocks(iq) { out += demod.process(front.process(block)[0]) }
        return out + demod.flush()
    }

    private let pages: [POCSAGEncoder.Page] = [
        .init(ric: 2504, function: 3, bits: POCSAG.alphaBits("Gr}~e aus K|ln: DAPNET-Test 73")),
        .init(ric: 8, function: 0, bits: POCSAG.numericBits("0172-123456")),
        .init(ric: 1_234_567, function: 1, bits: []),
        .init(ric: 200_005, function: 3, bits: POCSAG.alphaBits(String(repeating: "Lange Nachricht ueber mehrere Stapel. ", count: 4))),
    ]

    @Test("Leer- und Sync-Wort sind gültige BCH-Kodewörter mit gerader Parität")
    func constants() {
        for word in [POCSAG.idle, POCSAG.sync] {
            #expect(POCSAG.syndrome(word) == 0)
            #expect(word.nonzeroBitCount % 2 == 0)
            #expect(POCSAG.encode(word >> 11) == word)
        }
    }

    @Test("BCH korrigiert ein und zwei Bitfehler und erkennt drei")
    func correction() {
        var rng = TestSignals.Noise(state: 7)
        for _ in 0..<300 {
            let cw = POCSAG.encode(UInt32(rng.next() * 2_097_152))
            let i = Int(rng.next() * 32), j = (i + 1 + Int(rng.next() * 31)) % 32
            #expect(POCSAG.correct(cw ^ 1 << UInt32(i))?.codeword == cw)
            #expect(POCSAG.correct(cw ^ 1 << UInt32(i) ^ 1 << UInt32(j))?.codeword == cw)
            #expect(POCSAG.correct(cw ^ 1 << UInt32(i) ^ 1 << UInt32(j))?.errors == 2)
            // Mit Parität Mindestabstand 6: drei Fehler werden immer erkannt.
            let k = (j + 1 + Int(rng.next() * 30)) % 32
            if k != i {
                #expect(POCSAG.correct(cw ^ 1 << UInt32(i) ^ 1 << UInt32(j) ^ 1 << UInt32(k)) == nil)
            }
        }
    }

    @Test("Text und Ziffern: Rundreise, deutscher Zeichensatz")
    func charsets() {
        #expect(POCSAG.alphaText(POCSAG.alphaBits("Hallo Welt")) == "Hallo Welt")
        #expect(POCSAG.german("Gr}~e aus K|ln") == "Grüße aus Köln")
        #expect(POCSAG.numericText(POCSAG.numericBits("0172-123456")) == "0172-123456")
        // Bitreihenfolge: „A“ = 0x41 → LSB zuerst 1000001.
        #expect(POCSAG.alphaBits("A") == [1, 0, 0, 0, 0, 0, 1])
    }

    @Test("Framer: Adresse, Rahmenlage, Funktion und mehrere Stapel")
    func framer() {
        var framer = POCSAGFramer(bitRate: 1200)
        var out: [PagerMessage] = []
        for bit in POCSAGEncoder.transmission(pages) + [UInt8](repeating: 0, count: 64) {
            if let m = framer.push(bit) { out.append(m) }
        }
        if let m = framer.flush() { out.append(m) }
        check(out)
    }

    private func check(_ out: [PagerMessage], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(out.map(\.ric) == pages.map(\.ric), sourceLocation: sourceLocation)
        guard out.count == pages.count else { return }
        #expect(out[0].kind == .alpha, sourceLocation: sourceLocation)
        #expect(out[0].text(german: true) == "Grüße aus Köln: DAPNET-Test 73", sourceLocation: sourceLocation)
        #expect(out[1].kind == .numeric, sourceLocation: sourceLocation)
        #expect(out[1].text(german: true) == "0172-123456", sourceLocation: sourceLocation)
        #expect(out[2].kind == .tone && out[2].functionLetter == "B", sourceLocation: sourceLocation)
        #expect(out[3].text(german: false) == String(repeating: "Lange Nachricht ueber mehrere Stapel. ", count: 4),
                sourceLocation: sourceLocation)
        #expect(out.allSatisfy { !$0.incomplete }, sourceLocation: sourceLocation)
    }

    @Test("Ende zu Ende über FM-IQ bei allen drei Bitraten", arguments: POCSAG.bitRates)
    func endToEnd(bitRate: Int) {
        let out = decode(fskIQ(POCSAGEncoder.transmission(pages), bitRate: bitRate))
        #expect(out.allSatisfy { $0.bitRate == bitRate })
        check(out)
    }

    @Test("Frequenzablage 3 kHz und invertierte Lage")
    func offsetAndInversion() {
        check(decode(fskIQ(POCSAGEncoder.transmission(pages), bitRate: 1200, offset: 3_000)))
        check(decode(fskIQ(POCSAGEncoder.transmission(pages), bitRate: 1200, offset: -2_000, inverted: true)))
    }

    /// C/N0 ≈ 42,7 dB-Hz (Amplitude 4, σ 32): knapp über der Schwelle für 512 Bd.
    /// Gemessen: vollständig bis 42,7 (512 Bd), 46,8 (1200 Bd) bzw. ≈ 47 dB-Hz
    /// (2400 Bd) – die FM-Schwelle des 18-kHz-Kanals, nicht die Bitrate, begrenzt.
    @Test("Verrauscht: Bitfehler werden korrigiert")
    func noisy() {
        let out = decode(fskIQ(POCSAGEncoder.transmission(pages), bitRate: 512, noise: 32, amplitude: 4, seed: 5))
        check(out)
        #expect(out.reduce(0) { $0 + $1.correctedBits } > 0)
    }

    @Test("Reines Rauschen ergibt keine Nachrichten")
    func noiseOnly() {
        let samples = Int(FMChannelizer.inputRate * 5)
        let iq = TestSignals.iq(carriers: [[Double](repeating: 0, count: samples)], amplitude: 0, noise: 30, seed: 11)
        #expect(decode(iq).isEmpty)
    }
}
