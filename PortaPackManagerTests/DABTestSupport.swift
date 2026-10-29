import Accelerate
import Foundation
@testable import PortaPackManager

/// Ein kleiner DAB-Sender für Tests: baut FIBs, kodiert FIC und MSC wie im
/// Standard und erzeugt daraus OFDM-Rahmen (2,048 MS/s).
enum DABTestTransmitter {
    /// Deterministischer Zufall.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func bit() -> UInt8 { UInt8(next() & 1) }
        mutating func gaussian() -> Float {
            let u1 = max(Float(next() % 1_000_000) / 1_000_000, 1e-7)
            let u2 = Float(next() % 1_000_000) / 1_000_000
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    // MARK: - FIBs

    static func fig(type: Int, _ body: [UInt8]) -> [UInt8] {
        [UInt8(type << 5 | body.count)] + body
    }

    static func label(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(16))
        return bytes + [UInt8](repeating: 0x20, count: 16 - bytes.count)
    }

    /// FIB aus FIGs, mit Endmarke/Polster und CRC (32 Bytes).
    static func fib(_ figs: [[UInt8]]) -> [UInt8] {
        var data = figs.flatMap { $0 }
        precondition(data.count <= 30)
        if data.count < 30 { data.append(0xFF) }
        while data.count < 30 { data.append(0x00) }
        let crc = DABCRC.ccitt(data)
        return data + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
    }

    /// Ein Beispiel-Ensemble: „Test-Mux“ mit einem DAB+-Dienst „Radio Eins“
    /// in Unterkanal 3 (EEP 3-A, 48 kbit/s = 36 CU ab CU 0).
    static func exampleFIBs() -> [[UInt8]] {
        let ensembleInfo = fig(type: 0, [0x00, 0x10, 0x01, 0x00, 0x00])                // 0/0 EId 0x1001
        let subchannel = fig(type: 0, [0x01, 3 << 2 | 0, 0x00, 0x80 | 2 << 2, 36])   // 0/1 long form
        let service = fig(type: 0, [0x02, 0xD3, 0x10, 0x01, 63, 3 << 2 | 0x02])       // 0/2 SId 0xD310 → SubCh 3, DAB+
        let ensembleLabel = fig(type: 1, [0x00, 0x10, 0x01] + label("Test-Mux") + [0xFF, 0x00])
        let serviceLabel = fig(type: 1, [0x01, 0xD3, 0x10] + label("Radio Eins") + [0xFF, 0x00])
        return [
            fib([ensembleInfo, subchannel, service]),
            fib([ensembleLabel]),
            fib([serviceLabel]),
        ]
    }

    /// FIC eines Rahmens: 12 FIBs → 4 Blöcke zu 2304 Bits (gesendet).
    static func ficBits(_ fibs: [[UInt8]]) -> [UInt8] {
        let prbs = DABTables.prbs(count: 768)
        var out: [UInt8] = []
        for block in 0..<4 {
            var bits: [UInt8] = []
            for f in 0..<3 { bits += DABBits.unpack(fibs[(block * 3 + f) % fibs.count]) }
            for i in 0..<768 { bits[i] ^= prbs[i] }
            out += DABPuncturing.fic.puncture(DABConvolutionalCode.encode(bits))
        }
        return out
    }

    // MARK: - OFDM

    /// Erzeugt Rahmen aus je 75 · 3072 gesendeten Bits (FIC + MSC).
    static func frames(_ bitsPerFrame: [[UInt8]], frequencyOffset: Double = 0, noise: Float = 0,
                       seed: UInt64 = 1) -> (re: [Float], im: [Float]) {
        let n = DABMode.fftSize
        let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        defer { vDSP_DFT_DestroySetup(setup) }
        var random = Random(state: seed)
        var re: [Float] = [], im: [Float] = []
        let interleaver = DABTables.frequencyInterleaver
        let amplitude: Float = 1 / Float(n) * 40

        func emit(_ specRe: [Float], _ specIm: [Float]) {
            var tRe = [Float](repeating: 0, count: n), tIm = [Float](repeating: 0, count: n)
            vDSP_DFT_Execute(setup, specRe, specIm, &tRe, &tIm)
            re += tRe[(n - DABMode.guardLength)...].map { $0 * amplitude } + tRe.map { $0 * amplitude }
            im += tIm[(n - DABMode.guardLength)...].map { $0 * amplitude } + tIm.map { $0 * amplitude }
        }

        for bits in bitsPerFrame {
            re += [Float](repeating: 0, count: DABMode.nullLength)
            im += [Float](repeating: 0, count: DABMode.nullLength)
            var phaseRe = DABTables.prsReference.re
            var phaseIm = DABTables.prsReference.im
            emit(phaseRe, phaseIm)
            for l in 0..<(DABMode.symbolsPerFrame - 1) {
                for k in 0..<DABMode.carriers {
                    let p0 = bits[l * DABMode.bitsPerSymbol + k]
                    let p1 = bits[l * DABMode.bitsPerSymbol + DABMode.carriers + k]
                    let yRe: Float = (p0 == 0 ? 1 : -1) / Float(2).squareRoot()
                    let yIm: Float = (p1 == 0 ? 1 : -1) / Float(2).squareRoot()
                    let bin = interleaver[k]
                    let a = phaseRe[bin], b = phaseIm[bin]
                    phaseRe[bin] = a * yRe - b * yIm
                    phaseIm[bin] = a * yIm + b * yRe
                }
                emit(phaseRe, phaseIm)
            }
        }
        // Frequenzablage und Rauschen
        let step = 2 * Double.pi * frequencyOffset / Double(DABMode.sampleRate)
        for k in re.indices {
            let phase = step * Double(k)
            let c = Float(cos(phase)), s = Float(sin(phase))
            let a = re[k], b = im[k]
            re[k] = a * c - b * s + noise * random.gaussian()
            im[k] = a * s + b * c + noise * random.gaussian()
        }
        return (re, im)
    }

    /// Gibt Abtastwerte stückweise in den Demodulator.
    static func demodulate(_ signal: (re: [Float], im: [Float]), with demodulator: DABOFDMDemodulator,
                           chunk: Int = 65_536) -> [DABOFDMDemodulator.Frame] {
        var frames: [DABOFDMDemodulator.Frame] = []
        var start = 0
        while start < signal.re.count {
            let end = min(start + chunk, signal.re.count)
            frames += demodulator.process(re: Array(signal.re[start..<end]), im: Array(signal.im[start..<end]))
            start = end
        }
        return frames
    }
}
