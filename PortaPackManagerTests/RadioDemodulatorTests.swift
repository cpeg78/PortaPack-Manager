import Foundation
import Testing
@testable import PortaPackManager

@Suite("Radio-Demodulator")
struct RadioDemodulatorTests {
    /// Erzeugt int8-IQ bei 2,4 MS/s: Träger beim Empfangsversatz, moduliert mit `tone` Hz.
    private func signal(seconds: Double, tone: Double, fm deviation: Double?, amDepth: Double = 0.5) -> Data {
        let rate = RadioDemodulator.inputRate
        let n = Int(seconds * rate)
        var data = Data(count: n * 2)
        var phase = 0.0
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<n {
                let t = Double(k) / rate
                let m = sin(2 * .pi * tone * t)
                var amplitude = 60.0
                if let deviation {
                    phase += 2 * .pi * (RadioDemodulator.offset + deviation * m) / rate
                } else {
                    phase += 2 * .pi * RadioDemodulator.offset / rate
                    amplitude *= 1 + amDepth * m
                }
                p[2 * k] = Int8(max(-127, min(127, (amplitude * cos(phase)).rounded())))
                p[2 * k + 1] = Int8(max(-127, min(127, (amplitude * sin(phase)).rounded())))
            }
        }
        return data
    }

    /// Bestimmt die dominante Frequenz über Nulldurchgänge (nach Einschwingen).
    private func dominantFrequency(_ audio: [Float]) -> Double {
        let settled = Array(audio.dropFirst(audio.count / 4))
        let mean = settled.reduce(0, +) / Float(settled.count)
        var crossings = 0
        for k in 1..<settled.count where (settled[k - 1] - mean) < 0 && (settled[k] - mean) >= 0 { crossings += 1 }
        return Double(crossings) / (Double(settled.count) / RadioDemodulator.audioRate)
    }

    private func run(_ demod: RadioDemodulator, _ iq: Data) -> [Float] {
        var audio: [Float] = []
        let block = 262_144
        var offset = 0
        while offset < iq.count {
            audio += demod.process(iq.subdata(in: offset..<min(offset + block, iq.count))).left
            offset += block
        }
        return audio
    }

    @Test("UKW: 1-kHz-Ton kommt als 1 kHz bei 48 kHz heraus")
    func wfm() {
        let demod = RadioDemodulator()
        demod.mode = .wfm
        demod.volume = 1
        let audio = run(demod, signal(seconds: 0.5, tone: 1000, fm: 50_000))
        #expect(abs(Double(audio.count) - 0.5 * RadioDemodulator.audioRate) < 200)
        #expect(abs(dominantFrequency(audio) - 1000) < 20)
        #expect((audio.map { abs($0) }.max() ?? 0) > 0.1)
    }

    /// Unmodulierter Träger `offset` Hz neben der Wunschfrequenz, mit ±0,5 LSB
    /// Zittern (sonst lägen die Quantisierungs-Nebenlinien zufällig im Kanal).
    private func carrier(seconds: Double, offset: Double, amplitude: Double = 100) -> Data {
        let rate = RadioDemodulator.inputRate
        let n = Int(seconds * rate)
        var data = Data(count: n * 2)
        var rng = SondeSignal.Random(state: 5)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<n {
                let phase = 2 * .pi * (RadioDemodulator.offset + offset) * Double(k) / rate
                p[2 * k] = Int8((amplitude * cos(phase) + rng.unit() - 0.5).rounded())
                p[2 * k + 1] = Int8((amplitude * sin(phase) + rng.unit() - 0.5).rounded())
            }
        }
        return data
    }

    /// Leistung im Sprachkanal (dBFS) nach dem Einschwingen.
    private func channelLevel(_ mode: RadioMode, offset: Double) -> Float {
        let demod = RadioDemodulator()
        demod.mode = mode
        _ = run(demod, carrier(seconds: 0.25, offset: offset))
        return demod.channelDB
    }

    @Test("Nachbarkanäle: NFM ±12,5/25 kHz und AM ±8,33/10 kHz mindestens 50 dB gedämpft")
    func adjacentChannelRejection() {
        // Vorher (Kanalfilter mit 95 Abgriffen bei 240 kHz, nachgerechnet): NFM bei 12,5 kHz
        // −32 dB, AM bei 8,33 kHz −22 dB, bei 10 kHz −38 dB.
        var lines: [String] = []
        let nfm = channelLevel(.nfm, offset: 0)
        #expect(nfm > -5)
        for offset in [12_500.0, -12_500, 25_000, -25_000] {
            let rejection = nfm - channelLevel(.nfm, offset: offset)
            lines.append(String(format: "NFM %+.0f Hz: %.1f dB", offset, rejection))
            #expect(rejection >= 50, "NFM \(offset) Hz: \(rejection) dB")
        }
        let am = channelLevel(.am, offset: 0)
        #expect(am > -5)
        for offset in [25_000.0 / 3, -25_000.0 / 3, 9_000, 10_000, -10_000] {
            let rejection = am - channelLevel(.am, offset: offset)
            lines.append(String(format: "AM %+.0f Hz: %.1f dB", offset, rejection))
            #expect(rejection >= 50, "AM \(offset) Hz: \(rejection) dB")
        }
        print(lines.joined(separator: "\n"))
        // Im Durchlass bleibt der Pegel: Träger 3 kHz (AM) bzw. 6 kHz (NFM) daneben höchstens 1 dB leiser.
        #expect(abs(am - channelLevel(.am, offset: 3_000)) < 1)
        #expect(abs(nfm - channelLevel(.nfm, offset: 6_000)) < 1)
    }

    @Test("NFM: 800-Hz-Ton")
    func nfm() {
        let demod = RadioDemodulator()
        demod.mode = .nfm
        demod.volume = 1
        let audio = run(demod, signal(seconds: 0.5, tone: 800, fm: 3_000))
        #expect(abs(dominantFrequency(audio) - 800) < 20)
    }

    @Test("AM: 600-Hz-Ton")
    func am() {
        let demod = RadioDemodulator()
        demod.mode = .am
        demod.volume = 1
        let audio = run(demod, signal(seconds: 0.5, tone: 600, fm: nil))
        #expect(abs(dominantFrequency(audio) - 600) < 20)
    }

    /// Rauschen (gleichverteilt ±`level`, fester Startwert) addieren bzw. erzeugen.
    private func noise(_ base: Data?, seconds: Double, level: Int) -> Data {
        let n = base.map { $0.count / 2 } ?? Int(seconds * RadioDemodulator.inputRate)
        var out = base ?? Data(count: n * 2)
        var state: UInt32 = 12345
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<(n * 2) {
                state = state &* 1_664_525 &+ 1_013_904_223
                let r = Int(state >> 16) % (2 * level + 1) - level
                p[k] = Int8(max(-127, min(127, Int(p[k]) + r)))
            }
        }
        return out
    }

    @Test("Rauschsperre: stumm im Rauschen, offen beim AM-Spruch, danach wieder stumm")
    func squelch() {
        let demod = RadioDemodulator()
        demod.mode = .am
        demod.volume = 1
        demod.squelchDB = 8
        let rate = RadioDemodulator.audioRate
        let quiet1 = run(demod, noise(nil, seconds: 1, level: 6))
        let speech = run(demod, noise(signal(seconds: 0.6, tone: 600, fm: nil), seconds: 0, level: 6))
        let quiet2 = run(demod, noise(nil, seconds: 1, level: 6))
        let rms = { (x: ArraySlice<Float>) in (x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count))).squareRoot() }
        #expect(rms(quiet1.dropFirst(Int(0.1 * rate))[...]) < 0.001)
        #expect(rms(speech.dropFirst(Int(0.1 * rate))[...]) > 0.05)
        #expect(abs(dominantFrequency(speech) - 600) < 20)
        #expect(rms(quiet2.dropFirst(Int(0.6 * rate))[...]) < 0.001)

        demod.squelchDB = 0
        let open = run(demod, noise(nil, seconds: 0.5, level: 6))
        #expect(rms(open.dropFirst(Int(0.1 * rate))[...]) > 0.01)
    }
}
