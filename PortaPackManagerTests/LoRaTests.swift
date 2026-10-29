import Foundation
import Testing
@testable import PortaPackManager

/// Synthetischer LoRa-Sender nach gr-lora_sdr (`modulate_impl.cc`,
/// `build_upchirp`): Präambel aus Up-Chirps, zwei Sync-Symbole
/// (Nibble × 8), 2,25 Down-Chirps, Nutzsymbole. Die Chirps werden zeitstetig
/// berechnet, damit sich Zeitversatz, Frequenz- und Taktablage beliebig
/// einstellen lassen.
struct LoRaTestTransmitter {
    var parameters: LoRaParameters
    var preambleLength = 16

    private enum Segment {
        case up(Int)
        case down
    }

    /// Chirp-Phase (rad) an der Chip-Stelle `x` eines Up-Chirps mit Wert `id`.
    private func upPhase(_ x: Double, id: Int) -> Double {
        let n = Double(parameters.symbolSamples)
        let fold = n - Double(id)
        let offset = x < fold ? Double(id) / n - 0.5 : Double(id) / n - 1.5
        return 2 * .pi * (x * x / (2 * n) + offset * x)
    }

    private func segments(_ symbols: [Int]) -> [(Segment, Double)] {
        let (s1, s2) = parameters.syncSymbols
        var list: [(Segment, Double)] = Array(repeating: (.up(0), 1), count: preambleLength)
        list += [(.up(s1), 1), (.up(s2), 1), (.down, 1), (.down, 1), (.down, 0.25)]
        list += symbols.map { (.up($0), 1) }
        return list
    }

    /// Komplexes Basisband, Kanal bei `centerHz` relativ zur Abtastmitte.
    /// `startDelay` in Abtastwerten (auch gebrochen), `cfoHz` verschiebt
    /// Träger und – wie bei einem gemeinsamen Quarz – den Chiptakt.
    func waveform(symbols: [Int], sampleRate: Double, centerHz: Double = 0, cfoHz: Double = 0,
                  carrierHz: Double = 869_525_000, startDelay: Double = 0, tail: Int = 0,
                  amplitude: Double = 1) -> (re: [Double], im: [Double]) {
        let n = Double(parameters.symbolSamples)
        let chipRate = parameters.bandwidth * (1 + cfoHz / carrierHz)
        let list = segments(symbols)
        var starts: [Double] = []
        var total = 0.0
        for (_, length) in list {
            starts.append(total)
            total += length * n
        }
        let count = Int((startDelay + total / chipRate * sampleRate).rounded(.up)) + tail
        var re = [Double](repeating: 0, count: count), im = [Double](repeating: 0, count: count)
        var segment = 0
        for m in 0..<count {
            let t = (Double(m) - startDelay) / sampleRate
            guard t >= 0 else { continue }
            let chip = t * chipRate
            guard chip < total else { continue }
            while segment + 1 < list.count, chip >= starts[segment + 1] { segment += 1 }
            let x = chip - starts[segment]
            let phase: Double
            switch list[segment].0 {
            case .up(let id): phase = upPhase(x, id: id)
            case .down: phase = -upPhase(x, id: 0)
            }
            let total = phase + 2 * .pi * (centerHz + cfoHz) * t
            re[m] = amplitude * cos(total)
            im[m] = amplitude * sin(total)
        }
        return (re, im)
    }
}

/// Reproduzierbares Gaußrauschen (SplitMix64 + Box-Muller).
struct TestNoise {
    var state: UInt64

    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func gaussian() -> Double {
        (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

@Suite("LoRa")
struct LoRaTests {
    // MARK: - Kodierung

    @Test("Whitening-Folge entspricht der Tabelle aus gr-lora_sdr")
    func whiteningTabelle() {
        let table: [UInt8] = [0xFF, 0xFE, 0xFC, 0xF8, 0xF0, 0xE1, 0xC2, 0x85, 0x0B, 0x17, 0x2F, 0x5E, 0xBC, 0x78, 0xF1, 0xE3,
                              0xC6, 0x8D, 0x1A, 0x34, 0x68, 0xD0, 0xA0, 0x40, 0x80, 0x01, 0x02, 0x04, 0x08, 0x11, 0x23, 0x47,
                              0x8E, 0x1C, 0x38, 0x71, 0xE2, 0xC4, 0x89, 0x12, 0x25, 0x4B, 0x97, 0x2E, 0x5C, 0xB8, 0x70, 0xE0,
                              0xC0, 0x81, 0x03, 0x06, 0x0C, 0x19, 0x32, 0x64, 0xC9, 0x92, 0x24, 0x49, 0x93, 0x26, 0x4D, 0x9B]
        #expect(Array(LoRaCoding.whiteningSequence.prefix(table.count)) == table)
    }

    @Test("Hamming 4/7 und 4/8 korrigieren jeden Einzelbitfehler", arguments: [3, 4])
    func hammingKorrektur(codingRate: Int) {
        for nibble in UInt8(0)..<16 {
            let word = LoRaCoding.hammingEncode(nibble, codingRate: codingRate)
            #expect(LoRaCoding.hammingDecode(word, codingRate: codingRate) == (nibble, false))
            for bit in 0..<(4 + codingRate) {
                let damaged = word ^ (1 << UInt8(bit))
                let (decoded, corrected) = LoRaCoding.hammingDecode(damaged, codingRate: codingRate)
                #expect(decoded == nibble)
                #expect(corrected)
            }
        }
    }

    @Test("Hamming 4/5 und 4/6 liefern die Datenbits", arguments: [1, 2])
    func hammingErkennung(codingRate: Int) {
        for nibble in UInt8(0)..<16 {
            let word = LoRaCoding.hammingEncode(nibble, codingRate: codingRate)
            #expect(LoRaCoding.hammingDecode(word, codingRate: codingRate) == (nibble, false))
        }
        // Paritätsbit gekippt: erkannt, Daten unverändert.
        let word = LoRaCoding.hammingEncode(0b1011, codingRate: codingRate)
        #expect(LoRaCoding.hammingDecode(word ^ 1, codingRate: codingRate) == (0b1011, true))
    }

    @Test("Interleaver und Gray-Abbildung lassen sich umkehren")
    func interleaverUmkehrbar() {
        var noise = TestNoise(state: 7)
        for sf in [7, 9, 11, 12] {
            for (reduced, cr) in [(true, 4), (false, 1), (false, 4), (true, 2)] {
                let rows = reduced ? sf - 2 : sf
                let words = (0..<rows).map { _ in UInt8(Int(noise.uniform() * 256) & ((1 << (4 + cr)) - 1)) }
                let values = LoRaCoding.interleave(words, cwLength: 4 + cr, sf: sf, reduced: reduced)
                let bins = values.map { LoRaCoding.symbolForValue($0, sf: sf) }
                #expect(bins.allSatisfy { (0..<(1 << sf)).contains($0) })
                let back = bins.map { LoRaCoding.valueForSymbol($0, sf: sf, reduced: reduced) }
                #expect(LoRaCoding.deinterleave(back, cwLength: 4 + cr, rows: rows) == words)
            }
        }
    }

    @Test("Kopf-Prüfsumme erkennt Fehler")
    func kopfPruefsumme() {
        let nibbles = LoRaCoding.headerNibbles(length: 42, codingRate: 1, hasCRC: true)
        #expect(LoRaCoding.parseHeader(nibbles) == LoRaCoding.Header(length: 42, codingRate: 1, hasCRC: true))
        for k in 0..<3 {
            var damaged = nibbles
            damaged[k] ^= 0x04
            #expect(LoRaCoding.parseHeader(damaged) == nil)
        }
    }

    @Test("Symbolzahl passt zur Semtech-Formel")
    func symbolZahl() {
        // 8 + max(ceil((8PL − 4SF + 28 + 16CRC − 20IH) / (4(SF − 2DE))) · (CR + 4), 0)
        for (sf, length, cr, ldro) in [(11, 40, 1, false), (7, 10, 1, false), (12, 60, 4, true), (9, 255, 2, false)] {
            let numerator = Double(8 * length - 4 * sf + 28 + 16)
            let denominator = Double(4 * (sf - (ldro ? 2 : 0)))
            let expected = 8 + max(Int((numerator / denominator).rounded(.up)) * (cr + 4), 0)
            #expect(LoRaCoding.symbolCount(length: length, codingRate: cr, hasCRC: true, sf: sf, lowDataRate: ldro) == expected)
            #expect(LoRaCoding.encode([UInt8](repeating: 0x55, count: length), sf: sf, codingRate: cr,
                                      lowDataRate: ldro).count == expected)
        }
    }

    @Test("Low-Data-Rate-Optimierung nur ab 16 ms Symbolzeit")
    func lowDataRate() {
        #expect(!MeshtasticPreset.longFast.parameters.lowDataRate)       // SF11/250 kHz: 8,2 ms
        #expect(MeshtasticPreset.longModerate.parameters.lowDataRate)    // SF11/125 kHz: 16,4 ms
        #expect(MeshtasticPreset.longSlow.parameters.lowDataRate)        // SF12/125 kHz: 32,8 ms
        #expect(!MeshtasticPreset.shortFast.parameters.lowDataRate)
    }

    // MARK: - Demodulation

    /// Moduliert direkt mit 4 × Bandbreite (ohne Vorstufe) und demoduliert.
    private func roundTrip(_ preset: MeshtasticPreset, payload: [UInt8], cfoHz: Double, delay: Double,
                           snrDB: Double? = nil, seed: UInt64 = 1) -> [LoRaFrame] {
        let parameters = preset.parameters
        let symbols = LoRaCoding.encode(payload, sf: parameters.spreadingFactor, codingRate: preset.codingRateDenominator - 4,
                                        lowDataRate: parameters.lowDataRate)
        let tx = LoRaTestTransmitter(parameters: parameters)
        let os = LoRaDemodulator.oversampling
        let n = parameters.symbolSamples * os
        var (re, im) = tx.waveform(symbols: symbols, sampleRate: parameters.bandwidth * Double(os), cfoHz: cfoHz,
                                   startDelay: Double(3 * n) + delay, tail: 3 * n)
        if let snrDB {
            var noise = TestNoise(state: seed)
            let sigma = (pow(10, -snrDB / 10) / 2).squareRoot()
            for k in re.indices {
                re[k] += sigma * noise.gaussian()
                im[k] += sigma * noise.gaussian()
            }
        }
        let demod = LoRaDemodulator(parameters: parameters, centerFrequency: 869_525_000)
        // In Stücken einspeisen wie vom Empfangsthread.
        var frames: [LoRaFrame] = []
        let chunk = 10_000
        var start = 0
        while start < re.count {
            let end = min(start + chunk, re.count)
            frames += demod.process(re: re[start..<end].map(Float.init), im: im[start..<end].map(Float.init))
            start = end
        }
        return frames
    }

    @Test("LongFast mit Frequenz- und Zeitversatz", arguments: [(0.0, 0.0), (15_000.0, 0.37), (-22_000.0, 811.6), (3_100.0, 1500.2)])
    func longFastVersatz(cfoHz: Double, delay: Double) {
        let payload = Array("Hallo LoRa, das ist ein Test mit etwas Länge!".utf8)
        let frames = roundTrip(.longFast, payload: payload, cfoHz: cfoHz, delay: delay)
        #expect(frames.count == 1)
        #expect(frames.first?.payload == payload)
        #expect(frames.first?.crcValid == true)
        if let offset = frames.first?.frequencyOffsetHz {
            #expect(abs(offset - cfoHz) < 300)
        }
    }

    @Test("Alle EU-868-Voreinstellungen", arguments: MeshtasticRegion.eu868.presets)
    func voreinstellungen(preset: MeshtasticPreset) {
        let payload: [UInt8] = (0..<37).map { UInt8(($0 * 37 + 11) & 0xFF) }
        let frames = roundTrip(preset, payload: payload, cfoHz: 9_000, delay: 123.4)
        #expect(frames.count == 1)
        #expect(frames.first?.payload == payload)
        #expect(frames.first?.crcValid == true)
    }

    @Test("LongFast bei −10 dB Störabstand")
    func longFastRauschen() {
        let payload = Array("Schwaches Signal".utf8)
        let frames = roundTrip(.longFast, payload: payload, cfoHz: 7_000, delay: 55.5, snrDB: -10, seed: 99)
        #expect(frames.count == 1)
        #expect(frames.first?.payload == payload)
        #expect(frames.first?.crcValid == true)
        if let snr = frames.first?.snrDB { #expect(abs(snr + 10) < 3) }
    }

    @Test("Nur Rauschen ergibt keine Rahmen")
    func nurRauschen() {
        let parameters = MeshtasticPreset.longFast.parameters
        var noise = TestNoise(state: 5)
        let count = 200 * parameters.symbolSamples * LoRaDemodulator.oversampling
        let re = (0..<count).map { _ in Float(noise.gaussian()) }
        let im = (0..<count).map { _ in Float(noise.gaussian()) }
        let demod = LoRaDemodulator(parameters: parameters, centerFrequency: 869_525_000)
        #expect(demod.process(re: re, im: im).isEmpty)
    }

    @Test("Ganzer Empfangsweg ab HackRF-Abtastwerten mit Taktablage")
    func hackRFKette() {
        let preset = MeshtasticPreset.longFast
        let parameters = preset.parameters
        let first = Array("Erstes Paket".utf8)
        let second: [UInt8] = (0..<60).map { UInt8($0 * 7 & 0xFF) }
        let tx = LoRaTestTransmitter(parameters: parameters)
        let rate = LoRaDemodulator.inputRate
        // +20 kHz bei 869,525 MHz = 23 ppm: über 60 Symbole läuft der Takt
        // um mehrere Abtastwerte weg – ohne Nachführung bricht das Paket.
        let cfo = 20_000.0
        var re: [Double] = [], im: [Double] = []
        for (payload, delay) in [(first, 31_234.5), (second, 20_000.25)] {
            let symbols = LoRaCoding.encode(payload, sf: parameters.spreadingFactor, codingRate: 1)
            let wave = tx.waveform(symbols: symbols, sampleRate: rate, centerHz: LoRaDemodulator.offset, cfoHz: cfo,
                                   startDelay: delay, tail: 10_000, amplitude: 10)
            re += wave.re
            im += wave.im
        }
        // Rauschen: Störabstand im Kanal (250 von 2000 kHz) etwa 0 dB.
        var noise = TestNoise(state: 42)
        var data = Data(count: re.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in re.indices {
                p[2 * k] = Int8(max(-127, min(127, (re[k] + 20 * noise.gaussian()).rounded())))
                p[2 * k + 1] = Int8(max(-127, min(127, (im[k] + 20 * noise.gaussian()).rounded())))
            }
        }
        let demod = LoRaDemodulator(parameters: parameters, centerFrequency: 869_525_000)
        var frames: [LoRaFrame] = []
        var offset = 0
        let block = 262_144
        while offset < data.count {
            frames += demod.process(data.subdata(in: offset..<min(offset + block, data.count)))
            offset += block
        }
        #expect(frames.map(\.payload) == [first, second])
        #expect(frames.allSatisfy { $0.crcValid == true })
        #expect(frames.allSatisfy { abs($0.frequencyOffsetHz - cfo) < 300 })
    }
}
