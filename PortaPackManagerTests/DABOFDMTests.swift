import Foundation
import Testing
@testable import PortaPackManager

@Suite("DAB: OFDM")
struct DABOFDMTests {
    private func randomFrames(_ count: Int, seed: UInt64) -> [[UInt8]] {
        var random = DABTestTransmitter.Random(state: seed)
        return (0..<count).map { _ in (0..<(75 * DABMode.bitsPerSymbol)).map { _ in random.bit() } }
    }

    private func bitErrors(_ frame: DABOFDMDemodulator.Frame, _ bits: [UInt8]) -> Int {
        let soft = frame.fic + frame.msc
        var errors = 0
        for i in 0..<soft.count where (soft[i] < 0 ? 1 : 0) != bits[i] { errors += 1 }
        return errors
    }

    @Test("Synchronisiert und demoduliert ohne Störung", arguments: [0.0, 3_300.0, -12_700.0])
    func clean(offset: Double) {
        let frames = randomFrames(6, seed: 7)
        let signal = DABTestTransmitter.frames(frames, frequencyOffset: offset)
        let demodulator = DABOFDMDemodulator()
        // Etwas Vorlauf, damit der Rahmenanfang nicht am Pufferanfang liegt.
        let lead = 12_345
        let padded = ([Float](repeating: 0.01, count: lead) + signal.re, [Float](repeating: 0, count: lead) + signal.im)
        let out = DABTestTransmitter.demodulate(padded, with: demodulator)
        #expect(demodulator.state == .locked)
        #expect(!out.isEmpty)
        #expect(abs(demodulator.frequencyOffset - offset) < 20)
        // Die zuletzt demodulierten Rahmen gehören zu den letzten gesendeten.
        guard let last = out.last else { return }
        let errorsLast = (0..<frames.count).map { bitErrors(last, frames[$0]) }.min() ?? .max
        #expect(errorsLast == 0)
    }

    @Test("Mit Rauschen bleiben nur wenige Bitfehler")
    func noisy() {
        let frames = randomFrames(6, seed: 9)
        let signal = DABTestTransmitter.frames(frames, frequencyOffset: 1_234, noise: 0.15, seed: 3)
        let demodulator = DABOFDMDemodulator()
        let out = DABTestTransmitter.demodulate(signal, with: demodulator)
        guard let last = out.last else { Issue.record("kein Rahmen"); return }
        let errors = (0..<frames.count).map { bitErrors(last, frames[$0]) }.min() ?? .max
        #expect(Double(errors) / Double(75 * DABMode.bitsPerSymbol) < 0.02)
        #expect(demodulator.snr > 5)
    }

    @Test("FIC vom Sender bis zum Ensemblenamen")
    func ficEndToEnd() {
        let fibs = DABTestTransmitter.exampleFIBs()
        let fic = DABTestTransmitter.ficBits(fibs)
        var random = DABTestTransmitter.Random(state: 5)
        let frames = (0..<8).map { _ in fic + (0..<(72 * DABMode.bitsPerSymbol)).map { _ in random.bit() } }
        let signal = DABTestTransmitter.frames(frames, frequencyOffset: -2_150, noise: 0.25, seed: 11)
        let demodulator = DABOFDMDemodulator()
        let decoder = DABFICDecoder()
        var ensemble = DABEnsemble()
        for frame in DABTestTransmitter.demodulate(signal, with: demodulator) {
            for fib in decoder.decode(frame.fic) { ensemble.process(fib: fib) }
        }
        #expect(decoder.fibsTotal > 0)
        #expect(decoder.fibsGood == decoder.fibsTotal)
        #expect(ensemble.label == "Test-Mux")
        #expect(ensemble.audioServices.map(\.label) == ["Radio Eins"])
    }

    @Test("Eingangsstufe: Nutzband bleibt, Nachbarkanal faltet nicht hinein")
    func frontEnd() {
        func level(_ toneHz: Double) -> Float {
            let rate = Double(DABFrontEnd.inputRate)
            let n = 262_144
            var iq = Data(count: 2 * n)
            iq.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Int8.self)
                for k in 0..<n {
                    let phase = 2 * Double.pi * toneHz * Double(k) / rate
                    p[2 * k] = Int8((100 * cos(phase)).rounded())
                    p[2 * k + 1] = Int8((100 * sin(phase)).rounded())
                }
            }
            let frontEnd = DABFrontEnd()
            let (re, im) = frontEnd.process(iq)
            #expect(re.count == n / 4)
            let tail = re.indices.dropFirst(1000)
            let power = tail.reduce(Float(0)) { $0 + re[$1] * re[$1] + im[$1] * im[$1] } / Float(tail.count)
            return 10 * log10(power)
        }
        let wanted = level(300_000)
        let neighbour = level(1_500_000)
        #expect(wanted > -3)
        #expect(wanted - neighbour > 50)
    }
}
