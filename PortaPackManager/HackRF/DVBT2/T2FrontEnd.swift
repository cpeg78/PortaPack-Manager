import Accelerate
import Foundation

/// Eingangsstufe: Der HackRF läuft mit 2 × 64/7 MHz und ist ein Viertel der
/// Abtastrate über die Kanalmitte gestimmt – so liegen DC-Spitze und
/// IQ-Spiegel außerhalb des Kanals. Hier: um fs/4 zurückmischen,
/// tiefpassfiltern (±4,2 MHz) und auf 64/7 MS/s halbieren.
final class T2FrontEnd {
    static let inputRate = 2 * 64_000_000.0 / 7
    static let outputRate = 64_000_000.0 / 7
    /// Abstand der HackRF-Mitte von der Kanalmitte.
    static let tuningOffset = inputRate / 4

    private let taps: [Float]
    private var phase = 0
    private var historyRe: [Float]
    private var historyIm: [Float]

    init() {
        let count = 63
        let cutoff = 4.2e6 / Self.inputRate
        var taps = [Float](repeating: 0, count: count)
        let middle = Double(count - 1) / 2
        for i in 0..<count {
            let x = Double(i) - middle
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(count - 1))
            taps[i] = Float(sinc * window)
        }
        let sum = taps.reduce(0, +)
        self.taps = taps.map { $0 / sum }
        historyRe = [Float](repeating: 0, count: count - 1)
        historyIm = historyRe
    }

    func reset() {
        phase = 0
        for i in historyRe.indices { historyRe[i] = 0; historyIm[i] = 0 }
    }

    /// int8-IQ (I, Q, I, Q …) → komplexe Abtastwerte mit halber Rate.
    func process(_ block: Data, re outRe: inout [Float], im outIm: inout [Float]) {
        let pairs = block.count / 2
        guard pairs > 0 else { return }
        let history = taps.count - 1
        var re = [Float](repeating: 0, count: history + pairs)
        var im = re
        for i in 0..<history { re[i] = historyRe[i]; im[i] = historyIm[i] }
        block.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int8.self)
            // Mischen mit e^{+jπn/2}: (1, j, −1, −j)
            for n in 0..<pairs {
                let i = Float(p[2 * n]), q = Float(p[2 * n + 1])
                let o = history + n
                switch (phase + n) & 3 {
                case 0: re[o] = i; im[o] = q
                case 1: re[o] = -q; im[o] = i
                case 2: re[o] = -i; im[o] = -q
                default: re[o] = q; im[o] = -i
                }
            }
        }
        phase = (phase + pairs) & 3
        // Ausgangswerte bei jeder zweiten Position, durchgehend über Blockgrenzen.
        let outputs = (pairs - (consumedOffset)) / 2 + ((pairs - consumedOffset) % 2 > 0 ? 1 : 0)
        let start = consumedOffset
        var yr = [Float](repeating: 0, count: max(0, outputs))
        var yi = yr
        if outputs > 0 {
            re.withUnsafeBufferPointer { r in
                im.withUnsafeBufferPointer { m in
                    vDSP_desamp(r.baseAddress! + start, 2, taps, &yr, vDSP_Length(outputs), vDSP_Length(taps.count))
                    vDSP_desamp(m.baseAddress! + start, 2, taps, &yi, vDSP_Length(outputs), vDSP_Length(taps.count))
                }
            }
            outRe.append(contentsOf: yr)
            outIm.append(contentsOf: yi)
        }
        consumedOffset = start + 2 * outputs - pairs
        historyRe = Array(re[(re.count - history)...])
        historyIm = Array(im[(im.count - history)...])
    }

    private var consumedOffset = 0
}
