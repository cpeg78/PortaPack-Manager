import AVFoundation
import Foundation
import Testing
@testable import PortaPackManager

@Suite("Fernzugriff")
struct RemoteTests {
    @Test("AAC-Stream: ADTS-Rahmen lückenlos, wieder dekodierbar, Ton erhalten")
    func aacRoundtrip() throws {
        let encoder = try #require(AACStreamEncoder())
        let collected = Collector()
        encoder.onData = { collected.append($0) }
        // 2 s Sinus 1 kHz links, 500 Hz rechts, in ungeraden Stücken
        let total = 96_000
        var n = 0
        while n < total {
            let count = min(777, total - n)
            let l = (0..<count).map { Float(0.4 * sin(2 * .pi * 1000 * Double(n + $0) / 48_000)) }
            let r = (0..<count).map { Float(0.4 * sin(2 * .pi * 500 * Double(n + $0) / 48_000)) }
            encoder.push(left: l, right: r)
            n += count
        }
        encoder.flush()
        let data = collected.data
        // Rahmen über die Längenfelder durchlaufen
        var offset = 0, frames = 0
        let bytes = [UInt8](data)
        while offset + 7 <= bytes.count {
            #expect(bytes[offset] == 0xFF && bytes[offset + 1] & 0xF6 == 0xF0)
            let length = (Int(bytes[offset + 3] & 3) << 11) | (Int(bytes[offset + 4]) << 3) | (Int(bytes[offset + 5]) >> 5)
            #expect(length > 7)
            offset += length
            frames += 1
        }
        #expect(offset == bytes.count)
        #expect(frames >= 90 && frames <= 94)   // 96 000 / 1024 ≈ 93,75, Kodierer hält bis zu 2 zurück

        // Mit AVAudioFile zurücklesen und die Frequenzen prüfen
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-test-\(UUID()).aac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        #expect(buffer.frameLength > 80_000)
        func power(_ channel: Int, _ hz: Double) -> Double {
            let x = buffer.floatChannelData![channel]
            var re = 0.0, im = 0.0
            for i in 10_000..<58_000 {
                let phase = 2 * Double.pi * hz * Double(i) / 48_000
                re += Double(x[i]) * cos(phase); im += Double(x[i]) * sin(phase)
            }
            return (re * re + im * im) / 48_000 / 48_000
        }
        #expect(power(0, 1000) > 100 * power(0, 500))
        #expect(power(1, 500) > 100 * power(1, 1000))
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.withLock { buffer.append(d) } }
        var data: Data { lock.withLock { buffer } }
    }
}
