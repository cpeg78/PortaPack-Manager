import Foundation
import Testing
@testable import PortaPackManager

@Suite("Signaloptimierung")
struct GainOptimizerTests {
    typealias Preset = GainProfile.Preset

    /// Simulierter Empfänger: Pegel = Antennenpegel + LNA + VGA (+14 mit
    /// Vorverstärker); Übersteuerung, wenn der Mittelwert −12 dBFS übersteigt
    /// (Scheitelfaktor) oder die HF-Stufe über `rfLimit` dB Verstärkung bekommt.
    struct Receiver {
        var antenna: Double
        var rfLimit = 100.0
        func levels(_ p: Preset) -> HackRFDevice.InputLevels {
            let rf = p.lna + (p.amplifier ? 14 : 0)
            let rms = min(0, antenna + rf + p.vga)
            let clipped = rms > -12 || rf > rfLimit ? 0.02 : 0
            return .init(rmsDBFS: rms, peakDBFS: rms + 10, clipped: clipped)
        }
    }

    private func run(_ receiver: Receiver, start: Preset, external: Bool) -> (Preset, Int) {
        var search = GainSearch(start: start, externalAmplifier: external)
        var levels = receiver.levels(search.current)
        while search.next(after: levels) != nil { levels = receiver.levels(search.current) }
        return (search.current, search.steps)
    }

    @Test("Zu starkes Signal: erst Vorverstärker aus, dann LNA runter, bis im Zielbereich")
    func strong() {
        let receiver = Receiver(antenna: -40)
        let (p, steps) = run(receiver, start: .init(lna: 32, vga: 30, amplifier: true), external: false)
        let l = receiver.levels(p)
        #expect(GainSearch.rmsRange.contains(l.rmsDBFS) && l.clipped == 0)
        #expect(!p.amplifier)
        #expect(steps < GainSearch.maxSteps)
    }

    @Test("Schwaches Signal: LNA hoch, dann VGA; Vorverstärker nur ohne externen")
    func weak() {
        let receiver = Receiver(antenna: -110)
        let (alone, _) = run(receiver, start: .init(lna: 16, vga: 20, amplifier: false), external: false)
        #expect(alone.lna == 40)
        #expect(alone.amplifier || GainSearch.rmsRange.contains(receiver.levels(alone).rmsDBFS))
        let (external, _) = run(receiver, start: .init(lna: 16, vga: 20, amplifier: true), external: true)
        #expect(!external.amplifier)
    }

    @Test("HF-Übersteuerung bei hoher LNA: kein Pendeln, LNA bleibt unter der Grenze")
    func noOscillation() {
        let receiver = Receiver(antenna: -95, rfLimit: 24)
        let (p, steps) = run(receiver, start: .init(lna: 40, vga: 20, amplifier: false), external: true)
        #expect(p.lna <= 24)
        #expect(receiver.levels(p).clipped == 0)
        #expect(steps < GainSearch.maxSteps)
    }

    @Test("Kandidaten und Auswahl: Gleichstand → geringere Verstärkung")
    func choice() {
        let base = Preset(lna: 24, vga: 20, amplifier: false)
        let candidates = GainSearch.candidates(around: base)
        #expect(candidates.first == base && candidates.count == 5)
        #expect(candidates.allSatisfy { (0...40).contains($0.lna) && (0...62).contains($0.vga) })
        let results: [(preset: Preset, score: Double)] = [
            (base, 100), (.init(lna: 32, vga: 12, amplifier: false), 104), (.init(lna: 16, vga: 28, amplifier: false), 60),
        ]
        #expect(GainSearch.best(results) == base)   // 104 nur 4 % besser, aber mehr Verstärkung
        #expect(GainSearch.best([(base, 50), (.init(lna: 32, vga: 12, amplifier: false), 80)])?.lna == 32)
    }

    @Test("Gütezahlen: Blockanteil im Fenster, Zähler-Neustart, Gleichstand je Art")
    func scores() {
        // DVB-T2: Anteil fehlerfreier Blöcke im Fenster, nicht seit Start.
        #expect(GainOptimizer.score(before: .ratio(good: 100, bad: 100), after: .ratio(good: 180, bad: 120)) == 80)
        // Zähler nach Neueinrasten zurückgesetzt: ab null zählen.
        #expect(GainOptimizer.score(before: .ratio(good: 500, bad: 10), after: .ratio(good: 9, bad: 1)) == 90)
        #expect(GainOptimizer.score(before: .count(40), after: .count(5)) == 5)
        // Zu wenige Blöcke: kein Urteil.
        #expect(GainOptimizer.score(before: .ratio(good: 0, bad: 0), after: .ratio(good: 2, bad: 1)) == nil)
        // Störabstand: 0,5 dB entscheiden, 10 % (≈ 1 dB) wären viel zu grob.
        let low = Preset(lna: 24, vga: 20, amplifier: false), high = Preset(lna: 32, vga: 20, amplifier: false)
        let tolerance = GainOptimizer.tolerance(.value(10.7), top: 11.2)
        #expect(GainSearch.best([(low, 10.7), (high, 11.2)], tolerance: tolerance) == high)
        #expect(GainSearch.best([(low, 79), (high, 81)], tolerance: GainOptimizer.tolerance(.ratio(good: 0, bad: 0), top: 81)) == low)
    }
}
