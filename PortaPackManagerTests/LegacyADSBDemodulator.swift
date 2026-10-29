import Foundation
@testable import PortaPackManager

// Unveränderte Kopie der Präambelsuche und Bitentscheidung des ADS-B-Demodulators
// vor der CPU-Optimierung (Stand f80a38a, 29.10.2026) – nur als Referenz für den
// Vergleichstest „der neue findet alles, was der alte fand“ und den Benchmark
// (`ADSBSpeedTests`). Nicht weiterentwickeln.

final class LegacyADSBDemodulator {
    private var magnitude: [UInt16] = []
    private var carry: [UInt16] = []        // Rest des letzten Blocks (Nachrichten über Blockgrenzen)
    private(set) var framesSeen = 0
    private(set) var framesValid = 0

    static let sampleRate: UInt32 = 2_000_000
    static let frequency: UInt64 = 1_090_000_000
    private static let longFrameSamples = (8 + 112) * 2

    /// Betragstabelle: |I + jQ| für alle 256×256 Kombinationen.
    private static let magnitudeTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 65536)
        for i in 0..<256 {
            for q in 0..<256 {
                let fi = Double(Int8(bitPattern: UInt8(i))), fq = Double(Int8(bitPattern: UInt8(q)))
                table[i << 8 | q] = UInt16(min(65535, (fi * fi + fq * fq).squareRoot() * 360))
            }
        }
        return table
    }()

    func process(_ iq: Data, now: Date = Date()) -> [ADSBMessage] {
        let count = iq.count / 2
        magnitude.removeAll(keepingCapacity: true)
        magnitude.append(contentsOf: carry)
        magnitude.reserveCapacity(carry.count + count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let table = Self.magnitudeTable
            for n in 0..<count {
                magnitude.append(table[Int(bytes[2 * n]) << 8 | Int(bytes[2 * n + 1])])
            }
        }
        var results: [ADSBMessage] = []
        let limit = magnitude.count - Self.longFrameSamples
        var j = 0
        magnitude.withUnsafeBufferPointer { m in
            while j < limit {
                if let (bytes, length) = detect(m, at: j) {
                    framesSeen += 1
                    if var message = ADSBDemodulator.decode(bytes, now: now) {
                        framesValid += 1
                        let pulses = Int(m[j]) + Int(m[j + 2]) + Int(m[j + 7]) + Int(m[j + 9])
                        message.signal = min(1, Double(pulses) / (4 * 128 * 360))
                        results.append(message)
                        j += length * 2 + 16
                        continue
                    }
                }
                j += 1
            }
        }
        carry = Array(magnitude.suffix(Self.longFrameSamples))
        return results
    }

    /// Prüft die Präambel bei `j` und liefert die Rohbytes (14 oder 7).
    private func detect(_ m: UnsafeBufferPointer<UInt16>, at j: Int) -> ([UInt8], Int)? {
        // Präambel: Impulse bei 0, 2, 7, 9 (je 0,5 µs).
        guard m[j] > m[j + 1], m[j + 1] < m[j + 2], m[j + 2] > m[j + 3], m[j + 3] < m[j],
              m[j + 4] < m[j], m[j + 5] < m[j], m[j + 6] < m[j],
              m[j + 7] > m[j + 8], m[j + 8] < m[j + 9], m[j + 9] > m[j + 6] else { return nil }
        let high = (Int(m[j]) + Int(m[j + 2]) + Int(m[j + 7]) + Int(m[j + 9])) / 6
        guard Int(m[j + 4]) < high, Int(m[j + 5]) < high else { return nil }
        for k in 11...14 where Int(m[j + k]) >= high { return nil }

        var bytes = [UInt8](repeating: 0, count: 14)
        var bits = 112
        var i = 0
        while i < bits {
            let a = m[j + 16 + 2 * i], b = m[j + 16 + 2 * i + 1]
            if a > b { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
            if i == 4 {
                // Nach den ersten 5 Bits steht das Downlink-Format fest.
                let df = Int(bytes[0] >> 3)
                bits = df >= 16 ? 112 : 56
            }
            i += 1
        }
        return (Array(bytes.prefix(bits / 8)), bits)
    }
}
