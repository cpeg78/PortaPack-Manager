import Foundation
import Testing
@testable import PortaPackManager

/// Quarzdrift-Nachführung für FT8/WSPR (`FT8DriftTracker`, `FT8FrequencyShifter`).
@Suite("FT8-Quarzdrift")
struct FT8DriftTests {
    /// Geschlossener Kreis wie in `FT8Model`: Die gemessene Frequenz enthält die
    /// Restablage δ(t) − c(t); zurückgegeben wird die Rohfrequenz (gemessen + c).
    /// Liefert die größte Restablage |δ − c| ab Minute `settle` und den Tracker.
    private static func closedLoop(minutes: Double, stations: Int, drift: (Double) -> Double, noise: Double = 0.3,
                                   jumpAt: Double? = nil, quiet: Range<Double>? = nil, settle: Double = 3, seed: UInt64 = 7)
        -> (worst: Double, worstOpen: Double, tracker: FT8DriftTracker, finalResidual: Double) {
        var rng = FT8Noise(seed: seed)
        var tracker = FT8DriftTracker()
        var correction = FT8FrequencyCorrection.none
        let audio = (0..<stations).map { 300 + Double($0) * 2400 / Double(max(stations, 1)) + 17 }
        let start = 1_000_000.0
        var worst = 0.0, worstOpen = 0.0, finalResidual = 0.0
        for cycle in 0..<Int(minutes * 4) {
            let middle = start + Double(cycle) * 15 + 0.5 + 6.32
            var observations: [FT8DriftTracker.Observation] = []
            let silent = quiet?.contains(Double(cycle) / 4) ?? false
            for s in 0..<stations where s % 2 == cycle % 2 && rng.uniform() < 0.8 && !silent {
                var f = audio[s]
                // Eine Station verstellt ihre Sendefrequenz (Bedienung), das darf nicht als Drift gelten.
                if let jumpAt, s == 0, Double(cycle) / 4 >= jumpAt { f += 140 }
                let dt = 0.1 * rng.gaussian()
                let t = middle + dt
                let measured = f + drift(t - start) - correction.value(at: t) + noise * rng.gaussian()
                observations.append(.init(key: "S\(s)", time: t, frequency: measured + correction.value(at: t)))
            }
            tracker.add(observations, at: middle)
            correction = tracker.correction
            let t = middle
            // Bezug ist die erste Auswertung (Mitte der Aussendung 6,82 s nach Beginn).
            let residual = abs(drift(t - start) - drift(6.82) - correction.value(at: t))
            // Nach einer Pause zählt erst der zweite Zyklus danach (beide Paritäten).
            let afterQuiet = quiet.map { Double(cycle) / 4 >= $0.lowerBound && Double(cycle) / 4 < $0.upperBound + 0.5 } ?? false
            if Double(cycle) / 4 >= settle && !afterQuiet {
                worst = max(worst, residual)
                worstOpen = max(worstOpen, abs(drift(t - start) - drift(0)))
            }
            finalResidual = residual
        }
        return (worst, worstOpen, tracker, finalResidual)
    }

    @Test("Lineare Drift 10 Hz/min über 30 min: Restablage bleibt unter 1,5 Hz (ohne Nachführung 300 Hz)")
    func linearDrift() throws {
        let r = Self.closedLoop(minutes: 30, stations: 10, drift: { 10.0 / 60 * $0 })
        print("Lineare Drift 30 min: Rest höchstens \(r.worst) Hz, ohne Nachführung \(r.worstOpen) Hz, Drift \((r.tracker.rate ?? 0) * 60) Hz/min")
        #expect(r.worst < 1.5)
        #expect(r.worstOpen > 290)
        let rate = try #require(r.tracker.rate)
        #expect(abs(rate * 60 - 10) < 0.3)
        // Abweichung seit Start: gezählt ab der ersten Messung (6,8 s nach Beginn).
        #expect(abs(r.tracker.offset - 10.0 / 60 * (Double(119) * 15)) < 2)
    }

    @Test("Aufwärmen (exponentiell, 400 Hz, τ = 6 min): Restablage klein, Drift klingt ab")
    func warmUp() throws {
        let r = Self.closedLoop(minutes: 30, stations: 8, drift: { 400 * (1 - exp(-$0 / 360)) })
        print("Aufwärmen: Rest höchstens \(r.worst) Hz ab Minute 3, ohne Nachführung \(r.worstOpen) Hz, am Ende \(r.finalResidual) Hz")
        // Anfangs 67 Hz/min; Rest bis zu ≈ 3 Hz nach ausgefallenen Zyklen (Fortschreibung).
        #expect(r.worst < 4.5)
        #expect(r.finalResidual < 2.5)
        let rate = try #require(r.tracker.rate)
        // Nach 30 min: 400/360·e^(−5) ≈ 0,0075 Hz/s ≈ 0,45 Hz/min.
        #expect(abs(rate * 60 - 0.45) < 0.5)
    }

    @Test("Station verstellt ihre Frequenz: kein Sprung in der Schätzung")
    func stationJump() {
        let r = Self.closedLoop(minutes: 20, stations: 8, drift: { 6.0 / 60 * $0 }, jumpAt: 10)
        #expect(r.worst < 1.5, "Rest \(r.worst) Hz")
    }

    @Test("Stille Viertelstunde: danach stimmt die Abweichung sofort wieder (Paare über die Pause)")
    func quietBand() {
        let r = Self.closedLoop(minutes: 30, stations: 8, drift: { 10.0 / 60 * $0 }, quiet: 8..<20)
        print("Pause 12 min: Rest höchstens \(r.worst) Hz außerhalb der Pause")
        #expect(r.worst < 3)
    }

    @Test("Zu wenige Stationen: nichts wird nachgeführt")
    func tooFewStations() {
        // Zwei Stationen, die sauber driften – zu wenig für eine Schätzung.
        var tracker = FT8DriftTracker()
        for cycle in 0..<40 {
            let t = Double(cycle) * 15
            tracker.add([.init(key: "A", time: t, frequency: 1000 + t), .init(key: "B", time: t, frequency: 1500 + t)], at: t)
        }
        #expect(tracker.rate == nil)
        #expect(tracker.correction.value(at: 10_000) == 0)
        #expect(tracker.estimates == 0)
    }

    @Test("Verschieber: Frequenz wandert um genau −hz, Phase stetig über Blockgrenzen")
    func shifter() {
        var shifter = FT8FrequencyShifter()
        let n = 12_000
        var phase = 0.0
        var x = FT8Signal(count: n)
        for i in 0..<n { x.re[i] = Float(cos(phase)); x.im[i] = Float(sin(phase)); phase += 2 * .pi * 1000.3 / 12_000 }
        var blocks: [FT8Signal] = []
        var i = 0
        while i < n {
            let len = min(613, n - i)
            var b = FT8Signal(re: Array(x.re[i..<i + len]), im: Array(x.im[i..<i + len]))
            shifter.apply(&b, hz: 7.3)
            blocks.append(b)
            i += len
        }
        let re = blocks.flatMap(\.re), im = blocks.flatMap(\.im)
        // Erwartet: 993 Hz – Phasendifferenz je Abtastwert überall gleich.
        var worst = 0.0
        for k in 1..<n {
            let d = atan2(Double(im[k] * re[k - 1] - re[k] * im[k - 1]), Double(re[k] * re[k - 1] + im[k] * im[k - 1]))
            worst = max(worst, abs(d - 2 * .pi * 993.0 / 12_000))
        }
        #expect(worst < 1e-3)
    }

    /// Ende-zu-Ende: FT8-Zyklen mit linearer HackRF-Drift `rate` Hz/s (auch
    /// innerhalb jeder Aussendung), echter Dekoder, Verschieber im Empfangsweg.
    /// Liefert dekodierte Zyklen×Stationen und die größte Frequenzabweichung
    /// der Dekodierungen vom Sollwert in den letzten Zyklen.
    static func endToEnd(rate: Double, snr: Double, cycles: Int, tracking: Bool)
        -> (decoded: Int, sent: Int, lateDecoded: Int, lateSent: Int, worstLateError: Double) {
        let stations: [(text: String, call: String, frequency: Double)] = [
            ("CQ DL1ABC JO62", "DL1ABC", 520), ("CQ G4ABC IO91", "G4ABC", 1110), ("CQ OK1ABC JO70", "OK1ABC", 1730),
            ("CQ PA3ABC JO22", "PA3ABC", 2350),
            ("CQ DK2XY JO31", "DK2XY", 760), ("CQ F5XYZ JN18", "F5XYZ", 1390), ("CQ SP3XY JO82", "SP3XY", 1990),
            ("CQ ON4XY JO20", "ON4XY", 2590),
        ]
        var tracker = FT8DriftTracker()
        var correction = FT8FrequencyCorrection.none
        var decoded = 0, sent = 0, lateDecoded = 0, lateSent = 0, worst = 0.0
        var options = FT8Decoder.Options()
        options.minFrequency = 100
        options.maxFrequency = 3100
        for cycle in 0..<cycles {
            let slot = Double(cycle) * 15
            let middle = slot + FT8Decoder.nominalStart + 6.32
            let active = stations.enumerated().filter { $0.offset / 4 == cycle % 2 }.map(\.element)
            // HackRF-Ablage zur Mitte der Aussendung, Drift innerhalb der Aussendung.
            let offset = rate * middle
            var x = FT8TestSignals.slot(active.map { ($0.text, $0.frequency + offset, snr, 0.5) },
                                        seed: 4000 + UInt64(cycle), drift: rate)
            if tracking {
                var shifter = FT8FrequencyShifter()
                var i = 0
                while i < x.count {
                    let len = min(655, x.count - i)
                    var block = FT8Signal(re: Array(x.re[i..<i + len]), im: Array(x.im[i..<i + len]))
                    shifter.apply(&block, hz: correction.value(at: slot + Double(i) / 12_000))
                    x.re.replaceSubrange(i..<i + len, with: block.re)
                    x.im.replaceSubrange(i..<i + len, with: block.im)
                    i += len
                }
            }
            let results = FT8Decoder(options: options).decode(x, hashes: FT8CallHashes())
            var observations: [FT8DriftTracker.Observation] = []
            for s in active {
                sent += 1
                if cycle >= cycles / 2 { lateSent += 1 }
                guard let d = results.first(where: { $0.message.from == s.call }) else { continue }
                decoded += 1
                let t = middle + d.dt
                let applied = tracking ? correction.value(at: t) : 0
                if cycle >= cycles / 2 {
                    lateDecoded += 1
                    // Sollwert: Station + Ablage zur Mitte − Nachführung.
                    worst = max(worst, abs(d.frequency - (s.frequency + offset - applied)))
                }
                observations.append(.init(key: s.call, time: t, frequency: d.frequency + applied))
            }
            tracker.add(observations, at: middle)
            correction = tracker.correction
        }
        return (decoded, sent, lateDecoded, lateSent, worst)
    }

    @Test("Ende-zu-Ende: starke Aufwärmdrift 1,5 Hz/s – mit Nachführung dekodiert die zweite Hälfte alles")
    func endToEndDrift() {
        let before = Self.endToEnd(rate: 1.5, snr: -18, cycles: 10, tracking: false)
        let after = Self.endToEnd(rate: 1.5, snr: -18, cycles: 10, tracking: true)
        print("FT8 Ende-zu-Ende 1,5 Hz/s, −18 dB: ohne \(before.decoded)/\(before.sent) (2. Hälfte \(before.lateDecoded)/\(before.lateSent)), "
              + "mit \(after.decoded)/\(after.sent) (2. Hälfte \(after.lateDecoded)/\(after.lateSent), Frequenzfehler ≤ \(after.worstLateError) Hz)")
        #expect(after.lateDecoded == after.lateSent)
        #expect(after.decoded > before.decoded)
        #expect(after.worstLateError < 2)
    }

    @Test("Ende-zu-Ende ohne Drift: Nachführung ändert nichts")
    func endToEndNoDrift() {
        let before = Self.endToEnd(rate: 0, snr: -19, cycles: 4, tracking: false)
        let after = Self.endToEnd(rate: 0, snr: -19, cycles: 4, tracking: true)
        #expect(after.decoded >= before.decoded)
        #expect(after.worstLateError < 1)
    }
}
