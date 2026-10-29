import Foundation
import Testing
@testable import PortaPackManager

/// Rechenaufwand des Zigbee-Demodulators: die optimierte Präambelsuche muss
/// genau dieselben Rahmen finden wie die alte (`LegacyZigbeeDemodulator`) und
/// deutlich schneller sein. Laufzeit aussagekräftig nur mit
/// `-configuration Release ENABLE_TESTABILITY=YES`.
@Suite("Zigbee-Rechenaufwand")
struct ZigbeeSpeedTests {
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

    /// Rohdaten wie vom HackRF (Int8-IQ, Kanal 2 MHz über der Mitte): Rauschen,
    /// breitbandige Störblöcke (WLAN-ähnlich), FSK-Blöcke (Bluetooth-ähnlich,
    /// 1 Mbit/s, ±250 kHz) und Zigbee-Rahmen mit zufälliger Länge, Ablage,
    /// Stärke, I/Q-Lage; einige mit kaputter FCS. `gap`: Abstand der Rahmen.
    /// Liefert die Daten und die Zahl der gültigen Rahmen.
    static func capture(samples: Int, seed: UInt64, gap: ClosedRange<Int> = 500...12_000) -> (data: Data, frames: Int) {
        var rng = Random(state: seed)
        var re = [Float](repeating: 0, count: samples), im = [Float](repeating: 0, count: samples)
        for n in 0..<samples {
            re[n] = Float(0.03 * rng.gaussian()); im[n] = Float(0.03 * rng.gaussian())
        }
        // Störblöcke: ≈ 15 % der Zeit breitbandig laut.
        var position = 0
        while position < samples {
            position += rng.int(5_000...40_000)
            guard position < samples else { break }
            let length = rng.int(1_000...8_000)
            for n in position..<min(samples, position + length) {
                re[n] += Float(0.12 * rng.gaussian()); im[n] += Float(0.12 * rng.gaussian())
            }
            position += length
        }
        // FSK-Blöcke: 8 Werte je Bit, Phase läuft mit ±250 kHz.
        position = 0
        while position < samples {
            position += rng.int(20_000...80_000)
            guard position < samples else { break }
            let length = rng.int(2_000...6_000)
            let center = (rng.next() - 0.5) * 1_200_000
            var phase = 0.0
            var bit = 1.0
            for k in 0..<min(length, samples - position) {
                if k % 8 == 0 { bit = rng.next() < 0.5 ? -1 : 1 }
                phase += 2 * Double.pi * (center + 250_000 * bit) / ZigbeeDemodulator.inputRate
                re[position + k] += Float(0.2 * cos(phase)); im[position + k] += Float(0.2 * sin(phase))
            }
            position += length
        }
        var valid = 0
        position = 2_000
        while true {
            let payload = (0..<rng.int(3...100)).map { _ in UInt8(rng.int(0...255)) }
            var psdu = IEEE802154.withFCS(payload)
            let broken = rng.next() < 0.1
            if broken { psdu[psdu.count / 2] ^= 0x10 }
            let (sr, si) = IEEE802154.modulate(symbols: IEEE802154.symbols(psdu: psdu), samplesPerChip: 4)
            guard position + sr.count + 1_000 < samples else { break }
            let amplitude = Float(0.15 + 0.4 * rng.next())
            let offsetHz = (rng.next() - 0.5) * 160_000
            let invert = rng.next() < 0.3
            for k in 0..<sr.count {
                let n = position + k
                let phase = 2 * Double.pi * offsetHz * Double(n) / ZigbeeDemodulator.inputRate
                let c = Float(cos(phase)), s = Float(sin(phase))
                let q = invert ? -si[k] : si[k]
                re[n] += amplitude * (sr[k] * c - q * s)
                im[n] += amplitude * (sr[k] * s + q * c)
            }
            if !broken { valid += 1 }
            position += sr.count + rng.int(gap)
        }
        // Um +2 MHz verschieben (der Demodulator mischt mit e^(−jπn/2) zurück)
        // und wie der HackRF als Int8 ablegen.
        var data = Data(count: samples * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<samples {
                let (i, q): (Float, Float) = switch n & 3 {
                case 0: (re[n], im[n])
                case 1: (-im[n], re[n])
                case 2: (-re[n], -im[n])
                default: (im[n], -re[n])
                }
                p[2 * n] = Int8(max(-127, min(127, (i * 127).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (q * 127).rounded())))
            }
        }
        return (data, valid)
    }

    /// USB-Blöcke wie vom HackRF (262 144 Bytes).
    private static func blocks(_ data: Data, size: Int = 262_144) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min(data.count, $0 + size)) }
    }

    private struct Run {
        var frames: [ZigbeeRadioFrame] = []
        var crcErrors = 0
        var noiseDB = 0.0
        var seconds = 0.0
    }

    private static func runNew(_ blocks: [Data]) -> Run {
        let demod = ZigbeeDemodulator()
        var run = Run()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for block in blocks { run.frames += demod.process(block, channel: 15) }
        }
        run.crcErrors = demod.crcErrors
        run.noiseDB = demod.noiseDB
        run.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return run
    }

    private static func runLegacy(_ blocks: [Data]) -> Run {
        let demod = LegacyZigbeeDemodulator()
        var run = Run()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for block in blocks { run.frames += demod.process(block, channel: 15) }
        }
        run.crcErrors = demod.crcErrors
        run.noiseDB = demod.noiseDB
        run.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return run
    }

    /// Gleich bis aufs Bit: Inhalt, Pegel, Ablage (nur die Uhrzeit nicht).
    private static func same(_ a: [ZigbeeRadioFrame], _ b: [ZigbeeRadioFrame]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.mpdu == $1.mpdu && $0.rssiDB == $1.rssiDB && $0.offsetKHz == $1.offsetKHz && $0.channel == $1.channel
        }
    }

    @Test("Alte und neue Präambelsuche finden dieselben Rahmen", arguments: [UInt64(1), 7, 23])
    func sameFrames(seed: UInt64) {
        let (data, valid) = Self.capture(samples: 1_500_000, seed: seed)
        // Auch ungerade Blockgrößen: Rahmen über Blockgrenzen (`needMore`).
        for size in [262_144, 50_002] {
            let blocks = Self.blocks(data, size: size)
            let old = Self.runLegacy(blocks), new = Self.runNew(blocks)
            #expect(Self.same(old.frames, new.frames), "Blockgröße \(size): \(old.frames.count) alt, \(new.frames.count) neu")
            #expect(old.crcErrors == new.crcErrors)
            #expect(old.noiseDB == new.noiseDB)
            // Sinnprüfung: fast alle gültigen Rahmen werden gefunden.
            #expect(new.frames.count >= valid / 2, "\(new.frames.count) von \(valid) Rahmen")
        }
    }

    @Test("Vorprüfung: fest verdrahtete Stellen entsprechen der Chipfolge von Symbol 0")
    func boundTerms() {
        #expect(ZigbeeDemodulator.boundTerms.map(\.offset) == ZigbeeDemodulator.wiredBoundTerms.map(\.offset))
        #expect(ZigbeeDemodulator.boundTerms.map(\.weight) == ZigbeeDemodulator.wiredBoundTerms.map(\.weight))
    }

    @Test("Auswahl des unteren Zehntels wie nach dem Sortieren")
    func selection() {
        var rng = Random(state: 3)
        for size in [1, 2, 7, 100, 2048] {
            var values = (0..<size).map { _ in Float(rng.int(0...50)) }      // mit Doppelten
            let expected = values.sorted()[size / 10]
            #expect(ZigbeeDemodulator.select(&values, size / 10) == expected)
        }
    }

    @Test("Ruhiger Kanal und Vollaussteuerung: gleiche Ergebnisse")
    func extremes() {
        let silent = [Data(count: 262_144), Data(count: 262_144)]
        #expect(Self.runNew(silent).frames.isEmpty && Self.runLegacy(silent).frames.isEmpty)
        var rng = Random(state: 99)
        let loud = (0..<3).map { _ in Data((0..<262_144).map { _ in UInt8(truncatingIfNeeded: rng.int(0...255)) }) }
        let old = Self.runLegacy(loud), new = Self.runNew(loud)
        #expect(Self.same(old.frames, new.frames) && old.crcErrors == new.crcErrors)
    }

    /// Benchmark: 0,5 s Rohdaten (4 Mio. Werte). Mit Release gemessen am
    /// 28.10.2026 – Werte im Protokoll des Testlaufs und in
    /// `Docs/Erfahrungen/Zigbee-Thread.md`.
    @Test("Benchmark: neue Präambelsuche mindestens dreimal so schnell")
    func benchmark() {
        // Etwa 40 Rahmen je Sekunde (live: ≈ 25/s auf einem belebten Kanal).
        let (data, _) = Self.capture(samples: 4_000_000, seed: 5, gap: 100_000...300_000)
        let blocks = Self.blocks(data)
        // Je zweimal, der schnellere Lauf zählt (Aufwärmen, Störungen durch Parallelläufe).
        let old = [Self.runLegacy(blocks), Self.runLegacy(blocks)].min { $0.seconds < $1.seconds }!
        let new = [Self.runNew(blocks), Self.runNew(blocks)].min { $0.seconds < $1.seconds }!
        let speedup = old.seconds / max(new.seconds, 1e-9)
        print(String(format: "Zigbee-Benchmark: alt %.3f s, neu %.3f s für 0,5 s Signal – Faktor %.1f (%d Rahmen)",
                     old.seconds, new.seconds, speedup, new.frames.count))
        #expect(Self.same(old.frames, new.frames))
        #if !DEBUG
        // Nur optimiert aussagekräftig; Debug-Builds messen vor allem Grenzprüfungen.
        #expect(speedup >= 3, "Faktor \(speedup)")
        #endif
    }
}
