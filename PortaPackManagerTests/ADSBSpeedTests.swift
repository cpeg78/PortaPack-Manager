import Foundation
import Testing
@testable import PortaPackManager

/// ADS-B-Demodulator nach der Überarbeitung (Review L3, 29.10.2026): findet
/// alles, was der alte fand (`LegacyADSBDemodulator`), dazu Rahmen mit einem
/// gekippten Bit und mit ungünstiger Abtastphase – ohne Phantome – und ist
/// schneller. Laufzeit aussagekräftig nur mit `-configuration Release ENABLE_TESTABILITY=YES`.
@Suite("ADS-B-Demodulator: Fehlerkorrektur, Phase, Rechenaufwand")
struct ADSBSpeedTests {
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() * Double(range.count)) }
    }

    private static func bytes(_ hex: String) -> [UInt8] { [UInt8](Data(hexString: hex)!) }

    /// DF17-Rahmen mit gültiger Prüfsumme.
    private static func frame(icao: UInt32, me: [UInt8], df: UInt8 = 17) -> [UInt8] {
        var b: [UInt8] = [df << 3 | 5, UInt8(icao >> 16 & 0xFF), UInt8(icao >> 8 & 0xFF), UInt8(icao & 0xFF)] + me + [0, 0, 0]
        let crc = ADSBDemodulator.crc24(b)
        b[11] = UInt8(crc >> 16 & 0xFF); b[12] = UInt8(crc >> 8 & 0xFF); b[13] = UInt8(crc & 0xFF)
        return b
    }

    private static func flipped(_ bytes: [UInt8], _ bits: Int...) -> [UInt8] {
        var b = bytes
        for bit in bits { b[bit >> 3] ^= 0x80 >> UInt8(bit & 7) }
        return b
    }

    /// Halbbits: Präambel (Impulse 0, 2, 7, 9) + PPM-Daten.
    private static func halfBits(_ raw: [UInt8]) -> [Double] {
        var half = [Double](repeating: 0, count: 16)
        for k in [0, 2, 7, 9] { half[k] = 1 }
        for i in 0..<(raw.count * 8) {
            let one = raw[i / 8] & (0x80 >> UInt8(i % 8)) != 0
            half += one ? [1, 0] : [0, 1]
        }
        return half
    }

    /// Schreibt einen Rahmen in die Hüllkurve ab `start`, Abtastphase `phase`
    /// (0 = mittig, 0,5 = genau zwischen zwei Halbbits).
    private static func place(_ raw: [UInt8], in envelope: inout [Double], at start: Int, phase: Double, amplitude: Double) {
        let half = halfBits(raw)
        for n in 0..<half.count {
            let next = n + 1 < half.count ? half[n + 1] : 0
            envelope[start + n] += amplitude * ((1 - phase) * half[n] + phase * next)
        }
    }

    /// Hüllkurve → IQ (Int8) mit zufälliger Trägerphase und Rauschen.
    private static func iq(_ envelope: [Double], noise: Double, rng: inout Random) -> Data {
        var out = [UInt8](repeating: 0, count: envelope.count * 2)
        let theta = rng.next() * 2 * .pi
        for n in envelope.indices {
            let i = envelope[n] * cos(theta) + noise * rng.gaussian()
            let q = envelope[n] * sin(theta) + noise * rng.gaussian()
            out[2 * n] = UInt8(bitPattern: Int8(max(-127, min(127, i.rounded()))))
            out[2 * n + 1] = UInt8(bitPattern: Int8(max(-127, min(127, q.rounded()))))
        }
        return Data(out)
    }

    private static func blocks(_ data: Data, size: Int = 262_144) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min(data.count, $0 + size)) }
    }

    // MARK: Ein-Bit-Fehlerkorrektur

    @Test("Ein gekipptes Bit wird an jeder Stelle (außer DF) korrigiert")
    func singleBit() throws {
        let raw = Self.bytes("8D4840D6202CC371C32CE0576098")
        #expect(ADSBDemodulator.correctSingleBit(raw) == nil)        // schon gültig
        for bit in 5..<112 {
            let fixed = try #require(ADSBDemodulator.correctSingleBit(Self.flipped(raw, bit)), "Bit \(bit)")
            #expect(fixed.bytes == raw && fixed.bit == bit)
        }
        // Im DF-Feld nicht – sonst würde aus einem anderen Format ein DF17.
        for bit in 0..<5 { #expect(ADSBDemodulator.correctSingleBit(Self.flipped(raw, bit)) == nil) }
    }

    @Test("Zwei gekippte Bits werden nie „korrigiert“")
    func twoBits() {
        let raw = Self.bytes("8D40621D58C382D690C8AC2863A7")
        var corrected = 0
        for a in 5..<112 {
            for b in (a + 1)..<112 where ADSBDemodulator.correctSingleBit(Self.flipped(raw, a, b)) != nil { corrected += 1 }
        }
        #expect(corrected == 0)
    }

    @Test("Demodulator: korrigiert nur Adressen, die schon fehlerfrei gehört wurden")
    func correctionNeedsKnownAddress() throws {
        let raw = Self.bytes("8D4840D6202CC371C32CE0576098")
        let broken = Self.flipped(raw, 60)
        func signal(_ frames: [[UInt8]]) -> Data {
            var envelope = [Double](repeating: 0, count: 400 + frames.count * 400)
            for (k, f) in frames.enumerated() { Self.place(f, in: &envelope, at: 100 + 400 * k, phase: 0, amplitude: 60) }
            var rng = Random(state: 1)
            return Self.iq(envelope, noise: 0, rng: &rng)
        }
        // Unbekannte Adresse: kein Rahmen.
        let alone = ADSBDemodulator()
        #expect(alone.process(signal([broken])).isEmpty)
        // Erst fehlerfrei, dann mit Fehler: beide, der zweite repariert.
        let demod = ADSBDemodulator()
        let messages = demod.process(signal([raw, broken]))
        #expect(messages.map(\.rawHex) == ["8D4840D6202CC371C32CE0576098", "8D4840D6202CC371C32CE0576098"])
        #expect(demod.framesCorrected == 1)
    }

    // MARK: Höhe

    /// Unabhängiger Gillham-Kodierer: 500-ft-Stufe als Gray-Code auf D2 D4 A1 A2 A4
    /// B1 B2 B4, 100-ft-Stufe als Fünferzyklus auf C1 C2 C4 (rückwärts bei
    /// ungerader 500-ft-Stufe). Liefert das 12-Bit-AC-Feld mit Q = 0.
    private static func gillhamAC12(feet: Int) -> Int {
        let n = (feet + 1200) / 100                // 100-ft-Stufen ab −1200 ft
        let five = n / 5
        var one = n % 5 + 1
        if five & 1 == 1 { one = 6 - one }
        let gray = five ^ (five >> 1)
        // Gray-Bits, höchstwertiges zuerst: D2 D4 A1 A2 A4 B1 B2 B4.
        let bit = { (k: Int) in (gray >> (7 - k)) & 1 == 1 }
        let (d2, d4, a1, a2, a4, b1, b2, b4) = (bit(0), bit(1), bit(2), bit(3), bit(4), bit(5), bit(6), bit(7))
        // C1 C2 C4 für 1…5: 001, 011, 010, 110, 100.
        let c: (Bool, Bool, Bool) = [(false, false, true), (false, true, true), (false, true, false),
                                     (true, true, false), (true, false, false)][one - 1]
        // AC-Feld: C1 A1 C2 A2 C4 A4 B1 Q B2 D2 B4 D4 (Q = 0).
        let fields = [c.0, a1, c.1, a2, c.2, a4, b1, false, b2, d2, b4, d4]
        return fields.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
    }

    @Test("Höhe mit Q = 0 (Gillham, 100-ft-Schritte)")
    func gillham() {
        for feet in stride(from: -1200, through: 126_700, by: 100) {
            let ac12 = Self.gillhamAC12(feet: feet)
            #expect(ADSBDemodulator.altitude(ac12) == feet, "\(feet) ft")
        }
        // Q = 1 unverändert: 38 000 ft aus dem Lehrbuchbeispiel (AC = 0xC38).
        #expect(ADSBDemodulator.altitude(0xC38) == 38000)
        #expect(ADSBDemodulator.altitude(0) == nil)
        // Ungültig: C-Bits alle 0.
        #expect(ADSBDemodulator.gillhamHundreds(modeA: 0x1000) == nil)
    }

    // MARK: Alt gegen neu

    private struct Run {
        var messages: [ADSBMessage] = []
        var seconds = 0.0
    }

    private static func runLegacy(_ blocks: [Data]) -> Run {
        let demod = LegacyADSBDemodulator()
        var run = Run()
        let elapsed = ContinuousClock().measure {
            for block in blocks { run.messages += demod.process(block, now: Date(timeIntervalSince1970: 0)) }
        }
        run.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return run
    }

    private static func runNew(_ blocks: [Data]) -> Run {
        let demod = ADSBDemodulator()
        var run = Run()
        let elapsed = ContinuousClock().measure {
            for block in blocks { run.messages += demod.process(block, now: Date(timeIntervalSince1970: 0)) }
        }
        run.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return run
    }

    /// Rauschen mit Rahmen von 30 Flugzeugen: zufällige Abtastphase und Stärke,
    /// ein Teil mit einem gekippten Bit. Liefert die Daten und alle gesendeten Rahmen.
    private static func capture(samples: Int, seed: UInt64, gap: ClosedRange<Int>) -> (data: Data, sent: Set<String>) {
        var rng = Random(state: seed)
        var envelope = [Double](repeating: 0, count: samples)
        let planes = (0..<30).map { _ in UInt32(rng.int(0x100000...0xFFFFFF)) }
        var sent = Set<String>()
        var position = 1000
        while position + 400 < samples {
            let raw = frame(icao: planes[rng.int(0...29)], me: (0..<7).map { _ in UInt8(rng.int(0...255)) })
            sent.insert(raw.map { String(format: "%02X", $0) }.joined())
            // Jeder fünfte Rahmen mit einem gekippten Bit hinter dem DF-Feld.
            let onAir = rng.int(0...4) == 0 ? flipped(raw, rng.int(5...111)) : raw
            place(onAir, in: &envelope, at: position, phase: rng.next(), amplitude: Double(rng.int(15...100)))
            position += rng.int(gap)
        }
        return (iq(envelope, noise: 3, rng: &rng), sent)
    }

    @Test("Neu findet alles, was alt fand, und mehr – ohne Phantome", arguments: [UInt64(3), 11])
    func superset(seed: UInt64) {
        let (data, sent) = Self.capture(samples: 2_000_000, seed: seed, gap: 2_000...6_000)
        for size in [262_144, 50_002] {
            let blocks = Self.blocks(data, size: size)
            let old = Self.runLegacy(blocks).messages.map(\.rawHex)
            let new = Self.runNew(blocks).messages.map(\.rawHex)
            #expect(Set(new).isSuperset(of: Set(old)))
            #expect(new.count >= old.count)
            #expect(Set(new).isSubset(of: sent), "Phantome: \(Set(new).subtracting(sent))")
            print("ADS-B-Erkennung (Block \(size)): alt \(old.count), neu \(new.count) Rahmen")
        }
    }

    @Test("Phasenkorrektur rettet Rahmen zwischen zwei Abtastwerten")
    func phase() {
        // Abtastphase 0,35: der alte Entscheider verliert einen Teil der Rahmen.
        var rng = Random(state: 9)
        var envelope = [Double](repeating: 0, count: 200_000)
        var position = 500
        var frames = 0
        while position + 400 < envelope.count {
            let raw = Self.frame(icao: 0x4840D6, me: (0..<7).map { _ in UInt8(rng.int(0...255)) })
            Self.place(raw, in: &envelope, at: position, phase: 0.35 + 0.1 * rng.next(), amplitude: 50)
            position += 1000
            frames += 1
        }
        let data = Self.iq(envelope, noise: 4, rng: &rng)
        let old = Self.runLegacy([data]).messages.count, new = Self.runNew([data]).messages.count
        print("ADS-B-Phase 0,35–0,45: \(frames) gesendet, alt \(old), neu \(new)")
        #expect(new >= old)
    }

    /// Benchmark: 2 s Rohdaten (4 Mio. Werte, 16 MB), etwa 400 Rahmen je Sekunde.
    @Test("Benchmark: neuer Demodulator schneller als der alte")
    func benchmark() {
        let (data, _) = Self.capture(samples: 4_000_000, seed: 5, gap: 3_000...7_000)
        let blocks = Self.blocks(data)
        let old = [Self.runLegacy(blocks), Self.runLegacy(blocks)].min { $0.seconds < $1.seconds }!
        let new = [Self.runNew(blocks), Self.runNew(blocks)].min { $0.seconds < $1.seconds }!
        let speedup = old.seconds / max(new.seconds, 1e-9)
        print(String(format: "ADS-B-Benchmark: alt %.1f ms, neu %.1f ms für 2 s Signal – Faktor %.1f (alt %d, neu %d Rahmen)",
                     old.seconds * 1000, new.seconds * 1000, speedup, old.messages.count, new.messages.count))
        #expect(new.messages.count >= old.messages.count)
        #if !DEBUG
        #expect(speedup >= 1.5, "Faktor \(speedup)")
        #endif
    }
}
