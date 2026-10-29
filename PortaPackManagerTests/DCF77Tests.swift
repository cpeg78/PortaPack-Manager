import Foundation
import Testing
@testable import PortaPackManager

@Suite("DCF77 (Funkuhr)")
struct DCF77Tests {
    static let sample: DCF77Code.Time = {
        var t = DCF77Code.Time()
        t.minute = 42; t.hour = 2; t.day = 25; t.weekday = 7; t.month = 10; t.year = 26
        t.cest = true; t.cet = false; t.civil = 0x1A5B
        return t
    }()

    @Test("Kodieren und Dekodieren sind Umkehrungen; Paritäten stimmen")
    func roundtrip() throws {
        let bits = DCF77Code.encode(Self.sample)
        #expect(bits.count == 59)
        #expect(bits[0] == 0 && bits[20] == 1)
        let decoded = try DCF77Code.decode(bits).get()
        #expect(decoded == Self.sample)
        #expect(decoded.date != nil)
        // 02:42 MESZ am 25.10.2026 = 00:42 UTC
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(cal.component(.hour, from: decoded.date!) == 0)
        #expect(cal.component(.minute, from: decoded.date!) == 42)
    }

    @Test("Ein gekipptes Bit fällt an der Parität auf")
    func parity() {
        var bits = DCF77Code.encode(Self.sample)
        bits[22] ^= 1
        #expect(DCF77Code.decode(bits) == .failure(.minuteParity))
        bits[22] ^= 1; bits[31] ^= 1
        #expect(DCF77Code.decode(bits) == .failure(.hourParity))
        bits[31] ^= 1; bits[50] ^= 1
        #expect(DCF77Code.decode(bits) == .failure(.dateParity))
    }

    /// Hüllkurve (100 S/s) für eine Folge von Minuten, Träger 0,5, Absenkung auf 15 %.
    static func envelope(minutes: [DCF77Code.Time], noise: Float = 0.02) -> [Float] {
        var out: [Float] = []
        var rng = SystemRandomNumberGenerator()
        for time in minutes {
            let bits = DCF77Code.encode(time)
            for second in 0..<60 {
                let low = second == 59 ? 0 : (bits[second] == 1 ? 20 : 10)
                for k in 0..<100 {
                    let level: Float = k < low ? 0.075 : 0.5
                    out.append(level + Float.random(in: -noise...noise, using: &rng))
                }
            }
        }
        return out
    }

    @Test("Aus der Hüllkurve: Sekundentakt, Bits, Minute und Uhrvergleich")
    func decodeEnvelope() throws {
        var second = Self.sample
        second.minute = 43
        var third = Self.sample
        third.minute = 44
        // Mitten in einer Minute einsteigen (Sekunde 17), dann drei ganze Minuten.
        let signal = Array(Self.envelope(minutes: [Self.sample, second, third]).dropFirst(1700))
        let decoder = DCF77Decoder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fed = 0
        for chunk in stride(from: 0, to: signal.count, by: 37) {
            let part = Array(signal[chunk..<min(chunk + 37, signal.count)])
            fed += part.count
            decoder.feed(part, endDate: start.addingTimeInterval(Double(fed - 1) / 100), delay: 0)
        }
        #expect(decoder.locked)
        #expect(decoder.contrast > 0.3)
        // Die erste (angeschnittene) Minute zählt nicht als Fehler, danach zwei volle.
        #expect(decoder.minutesFailed == 0)
        #expect(decoder.minutesDecoded == 2)
        #expect(decoder.time == third)
        // Letzte 60 Sekunden: 59 Bits + Marke.
        let last = decoder.seconds.suffix(60)
        #expect(last.last?.kind == .marker)
        let kinds = last.dropLast().map { $0.kind == .one ? UInt8(1) : 0 }
        #expect(kinds == DCF77Code.encode(third))
        // Uhrvergleich: Sekunde 0 der Minute 02:44 lag bei Probe (1700 + 2·6000 + 6000 − 1700)… = start + 60 + 60 + 43 s.
        let offset = try #require(decoder.clockOffset)
        let expected = start.addingTimeInterval(43 + 120).timeIntervalSince(third.date!)
        #expect(abs(offset - expected) < 0.03)
    }

    @Test("Schaltsekunde: Minute mit 60 Bits wird angenommen, ohne Ankündigung verworfen")
    func leapSecondCode() throws {
        var t = Self.sample
        t.minute = 0; t.hour = 2; t.leapSecondAnnounced = true
        let bits = DCF77Code.encode(t) + [0]
        #expect(try DCF77Code.decode(bits).get() == t)
        // Ohne Ankündigung (Bit 19 und vorige Minute) ist eine 60-Bit-Minute ein Fehler.
        t.leapSecondAnnounced = false
        let unannounced = DCF77Code.encode(t) + [0]
        #expect(DCF77Code.decode(unannounced) == .failure(.length))
        #expect(try DCF77Code.decode(unannounced, leapAnnounced: true).get() == t)
        // Eingefügte Sekunde muss eine 0 sein; Schaltsekunde nur vor der vollen Stunde.
        t.leapSecondAnnounced = true
        #expect(DCF77Code.decode(DCF77Code.encode(t) + [1]) == .failure(.length))
        t.minute = 30
        #expect(DCF77Code.decode(DCF77Code.encode(t) + [0]) == .failure(.length))
    }

    @Test("Schaltsekunde aus der Hüllkurve: 61 Sekunden lange Minute, danach geht es normal weiter")
    func leapSecondEnvelope() throws {
        // 01:58 → 01:59 (Ankündigung) → Schaltminute (Zeit 02:00, Sekunde 59 = 0, Marke in 60) → 02:01.
        var minutes: [DCF77Code.Time] = []
        for (hour, minute, announced) in [(1, 58, true), (1, 59, true), (2, 0, true), (2, 1, false), (2, 2, false)] {
            var t = Self.sample
            t.hour = hour; t.minute = minute; t.leapSecondAnnounced = announced
            minutes.append(t)
        }
        var out: [Float] = []
        var rng = SystemRandomNumberGenerator()
        for (m, time) in minutes.enumerated() {
            var lows = DCF77Code.encode(time).map { $0 == 1 ? 20 : 10 }
            if m == 2 { lows.append(10) }    // eingefügte Sekunde 59: Bit 0
            lows.append(0)                    // Minutenmarke
            for low in lows {
                for k in 0..<100 { out.append((k < low ? 0.075 : 0.5) + Float.random(in: -0.02...0.02, using: &rng)) }
            }
        }
        let decoder = DCF77Decoder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fed = 0
        for chunk in stride(from: 0, to: out.count, by: 41) {
            let part = Array(out[chunk..<min(chunk + 41, out.count)])
            fed += part.count
            decoder.feed(part, endDate: start.addingTimeInterval(Double(fed - 1) / 100), delay: 0)
        }
        // Vorher: „Minutenmarke fehlt“ bzw. „Minute mit 60 statt 59 Sekunden“.
        #expect(decoder.minutesFailed == 0, "\(decoder.lastError ?? "")")
        #expect(decoder.leapSeconds == 1)
        #expect(decoder.time == minutes[4])
        #expect(decoder.minutesDecoded >= 3)
        // Uhrvergleich: 02:02 beginnt nach der fünften Marke, also nach 5 Minuten + 1 Schaltsekunde.
        let offset = try #require(decoder.clockOffset)
        let expected = start.addingTimeInterval(5 * 60 + 1).timeIntervalSince(minutes[4].date!)
        #expect(abs(offset - expected) < 0.03)
    }

    @Test("Bricht die Modulation ab, zählen die Sekunden ohne Absenkung nicht als Minutenmarken")
    func lostModulation() {
        // Zwei Minuten sauber, danach 40 s Träger ohne Absenkungen (Störung überdeckt sie).
        var signal = Self.envelope(minutes: [Self.sample, Self.sample])
        var rng = SystemRandomNumberGenerator()
        signal += (0..<4000).map { _ in Float(0.5) + Float.random(in: -0.02...0.02, using: &rng) }
        let decoder = DCF77Decoder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fed = 0
        for chunk in stride(from: 0, to: signal.count, by: 50) {
            let part = Array(signal[chunk..<min(chunk + 50, signal.count)])
            fed += part.count
            decoder.feed(part, endDate: start.addingTimeInterval(Double(fed - 1) / 100), delay: 0)
        }
        // Früher: jede Sekunde ohne Absenkung beendete eine „Minute mit 0 statt 59 Sekunden“.
        #expect(decoder.minutesFailed <= 1)
        let markers = decoder.seconds.suffix(30).filter { $0.kind == .marker }
        #expect(markers.isEmpty)
    }

    @Test("Ohne Modulation rastet nichts ein")
    func noLock() {
        let decoder = DCF77Decoder()
        var rng = SystemRandomNumberGenerator()
        let flat = (0..<1500).map { _ in Float(0.3) + Float.random(in: -0.05...0.05, using: &rng) }
        decoder.feed(flat, endDate: Date(), delay: 0)
        #expect(!decoder.locked)
        #expect(decoder.seconds.isEmpty)
    }

    /// IQ bei 2 MS/s: Träger 200 kHz unter der Mitte (= 77,5 kHz bei LO 277,5 kHz) plus
    /// `offsetHz`, mit Absenkungen auf 15 % zu den angegebenen Zeiten.
    static func iq(seconds: Double, offsetHz: Double, drops: [(start: Double, length: Double)], amplitude: Float = 40) -> Data {
        let rate = DCF77Demodulator.inputRate
        let count = Int(seconds * rate)
        var data = Data(count: count * 2)
        let w = 2 * Double.pi * (-DCF77Demodulator.offset + offsetHz) / rate
        let cr = cos(w), ci = sin(w)
        var pr = 1.0, pi = 0.0
        var rng = SystemRandomNumberGenerator()
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<count {
                let t = Double(n) / rate
                var a = amplitude
                for d in drops where t >= d.start && t < d.start + d.length { a *= 0.15 }
                let i = Float(pr) * a + Float.random(in: -3...3, using: &rng)
                let q = Float(pi) * a + Float.random(in: -3...3, using: &rng)
                p[2 * n] = Int8(max(-127, min(127, i.rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, q.rounded())))
                let nr = pr * cr - pi * ci
                pi = pr * ci + pi * cr
                pr = nr
            }
        }
        return data
    }

    @Test("IQ-Vordergrund: Hüllkurve zeigt die Absenkungen, Trägerablage wird gemessen")
    func frontEnd() {
        let demod = DCF77Demodulator()
        let data = Self.iq(seconds: 3.2, offsetHz: 2.5, drops: [(1.0, 0.1), (2.0, 0.2)])
        var envelope: [Float] = []
        let block = 262_144
        var start = 0
        while start < data.count {
            envelope += demod.process(data.subdata(in: start..<min(start + block, data.count)))
            start += block
        }
        // 3,2 s → ≈ 320 Werte abzüglich Filtereinschwingen.
        #expect(envelope.count > 300)
        let high = envelope[50...90].reduce(0, +) / 41
        #expect(high > 0.2)
        // Laufzeit der Filter in Hüllkurvenwerten.
        let delay = Int((DCF77Demodulator.groupDelay * DCF77Demodulator.envelopeRate).rounded())
        let missing = Int(3.2 * 100) - envelope.count
        func lowRun(from ms: Int) -> Int {
            let i0 = ms / 10 - missing + delay
            var n = 0
            var j = i0 - 3
            while j < i0 + 6, envelope[j] >= 0.55 * high { j += 1 }
            guard j < i0 + 6 else { return 0 }
            while envelope[j + n] < 0.55 * high { n += 1 }
            return n * 10
        }
        let first = lowRun(from: 1000), secondRun = lowRun(from: 2000)
        #expect((60...150).contains(first), "100-ms-Absenkung gemessen als \(first) ms")
        #expect((150...280).contains(secondRun), "200-ms-Absenkung gemessen als \(secondRun) ms")
        #expect(abs(demod.carrierOffsetHz - 2.5) < 1.0, "Ablage \(demod.carrierOffsetHz) Hz")
        #expect(demod.snrDB > 20)
    }
}
