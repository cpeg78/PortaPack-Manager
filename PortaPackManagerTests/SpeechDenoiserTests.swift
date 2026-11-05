import Foundation
import Testing
@testable import PortaPackManager

@Suite("Flugfunk: Rauschminderung")
struct SpeechDenoiserTests {
    /// Gleichverteiltes Rauschen aus einem festen Startwert (reproduzierbar).
    private func noise(_ count: Int, amplitude: Float, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
    }

    /// 6 s: abwechselnd 0,5 s „Sprache“ (Ton 800 Hz) und 0,5 s Pause, darüber Rauschen.
    private func signal() -> (mixed: [Float], tone: [Float]) {
        let rate: Float = 16_000, count = 6 * 16_000
        let tone = (0..<count).map { n -> Float in
            let inBurst = (n / 8000) % 2 == 0
            return inBurst ? 0.3 * sinf(2 * .pi * 800 * Float(n) / rate) : 0
        }
        return (zip(tone, noise(count, amplitude: 0.15)).map(+), tone)
    }

    /// In Stücken wie im Empfänger (16-kHz-Blöcke zu 240 Werten).
    private func run(_ input: [Float], _ level: NoiseReduction) -> [Float] {
        var denoiser = SpeechDenoiser(floorDB: level.floorDB ?? 0)
        return stride(from: 0, to: input.count, by: 240).flatMap { start in
            denoiser.process(Array(input[start..<min(start + 240, input.count)]))
        }
    }

    @Test("Rauschen in Pausen deutlich leiser, Ton bleibt; gleich viele Werte heraus")
    func reducesNoise() {
        let (mixed, _) = signal()
        let out = run(mixed, .strong)
        #expect(out.count == mixed.count)
        // Letzte Pause (5,5–6 s) bzw. letzter Ton (4,5–5 s) nach dem Einlernen; 16 ms Latenz.
        let delay = SpeechDenoiser.frameLength
        let pauseIn = rms(mixed[(5 * 16_000 + 8000 + 800)..<(6 * 16_000 - 800)])
        let pauseOut = rms(out[(5 * 16_000 + 8000 + 800 + delay)..<(6 * 16_000 - 800)])
        let toneIn = rms(mixed[(4 * 16_000 + 800)..<(4 * 16_000 + 8000 - 800)])
        let toneOut = rms(out[(4 * 16_000 + 800 + delay)..<(4 * 16_000 + 8000 - 800 + delay)])
        let pauseDB = 20 * log10(pauseOut / pauseIn), toneDB = 20 * log10(toneOut / toneIn)
        #expect(pauseDB < -10, "Pause nur \(pauseDB) dB")
        #expect(toneDB > -3, "Ton \(toneDB) dB")
        // Mittel nimmt weniger weg als stark.
        let medium = run(mixed, .medium)
        let mediumPause = rms(medium[(5 * 16_000 + 8000 + 800 + delay)..<(6 * 16_000 - 800)])
        #expect(mediumPause > pauseOut)
    }

    @Test("Brummen unter dem Sprachband wird gedämpft")
    func removesHum() {
        let hum = (0..<(3 * 16_000)).map { n in 0.3 * sinf(2 * .pi * 100 * Float(n) / 16_000) }
        let out = run(hum, .medium)
        let db = 20 * log10(rms(out[(2 * 16_000)...]) / rms(hum[(2 * 16_000)...]))
        #expect(db < -10, "Brummen nur \(db) dB")
    }
}
