import Accelerate
import Foundation
@testable import PortaPackManager

/// Der Sondenkanal bis 28.10.2026 (Kanalfilter 8 kHz bei 400 kS/s, Mittel
/// über 5 Werte, Taktnachführung 0,3) – nur als Vergleich für
/// `SondeTests.bitErrorRate`, damit „vorher/nachher“ im Test nachprüfbar bleibt.
final class LegacySondeChannel {
    private let stage1: [Float]
    private let stage2: [Float]
    private let factor1: Int
    private var h1Re: [Float] = [], h1Im: [Float] = []
    private var h2Re: [Float] = [], h2Im: [Float] = []
    private var lastRe: Float = 1, lastIm: Float = 0
    private var dc: Float = 0
    private var smooth: [Float] = []

    init(inputRate: Double) {
        factor1 = Int(inputRate / 400_000)
        stage1 = RadioDemodulator.lowpass(taps: 159, cutoff: 25_000, rate: inputRate)
        stage2 = RadioDemodulator.lowpass(taps: 79, cutoff: 8_000, rate: 400_000)
    }

    /// Mischen entfällt: das Testsignal liegt schon bei 0 Hz (plus Ablage).
    func demodulate(re: [Float], im: [Float]) -> [Float] {
        let (aRe, aIm) = RadioDemodulator.decimateComplex(re, im, history: &h1Re, &h1Im, filter: stage1, factor: factor1)
        let (bRe, bIm) = RadioDemodulator.decimateComplex(aRe, aIm, history: &h2Re, &h2Im, filter: stage2, factor: 8)
        var fm = [Float](repeating: 0, count: bRe.count)
        var pr = lastRe, pi = lastIm
        for i in fm.indices {
            let r = bRe[i], m = bIm[i]
            let v = atan2f(m * pr - r * pi, r * pr + m * pi)
            pr = r; pi = m
            dc += 0.002 * (v - dc)
            fm[i] = v - dc
        }
        lastRe = pr; lastIm = pi
        let input = smooth + fm
        var filtered = [Float](repeating: 0, count: fm.count)
        for i in fm.indices {
            var sum: Float = 0
            for j in 0..<5 {
                let index = i + smooth.count - j
                if index >= 0 { sum += input[index] }
            }
            filtered[i] = sum / 5
        }
        smooth = Array(input.suffix(4))
        return filtered
    }

    /// Alte Bitentscheidung: wie `SondeSlicer`, aber Nachführung 0,3.
    static func slice(_ samples: [Float], samplesPerSymbol: Double) -> [UInt8] {
        var phase = 0.0, last: Float = 0
        var bits: [UInt8] = []
        let step = 1 / samplesPerSymbol
        for v in samples {
            let previous = last
            last = v
            if (previous < 0) != (v < 0), previous != v {
                let fraction = Double(previous / (previous - v))
                var error = phase + fraction * step
                error -= error.rounded()
                phase -= 0.3 * error
                if phase < 0 { phase += 1 }
            }
            let before = phase
            phase += step
            if before < 0.5, phase >= 0.5 { bits.append(v > 0 ? 1 : 0) }
            if phase >= 1 { phase -= 1 }
        }
        return bits
    }
}
