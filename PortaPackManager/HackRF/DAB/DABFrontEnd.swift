import Accelerate
import Foundation

/// Eingangsstufe: Der HackRF tastet mit 8,192 MS/s ab, weil er unter 8 MS/s
/// stark faltet (Nachbarkanäle im Abstand von 1,712 MHz fielen sonst ins
/// Nutzband). Hier: int8 → Float, Gleichanteil entfernen, Tiefpass
/// (Durchlass ±0,77 MHz, Sperrbereich ab 1,28 MHz) und ÷4 auf 2,048 MS/s.
final class DABFrontEnd: @unchecked Sendable {
    static let inputRate: UInt32 = 8_192_000
    static let decimation = 4

    private let filter = RadioDemodulator.lowpass(taps: 95, cutoff: 1_020_000, rate: Double(DABFrontEnd.inputRate))
    private var historyRe: [Float] = []
    private var historyIm: [Float] = []
    private var dcRe: Float = 0
    private var dcIm: Float = 0

    func reset() {
        historyRe = []
        historyIm = []
        dcRe = 0
        dcIm = 0
    }

    /// Liefert die dezimierten Abtastwerte (Real- und Imaginärteil).
    func process(_ iq: Data) -> (re: [Float], im: [Float]) {
        let count = iq.count / 2
        guard count > 0 else { return ([], []) }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var sumI: Float = 0, sumQ: Float = 0
            for n in 0..<count {
                let i = Float(p[2 * n]), q = Float(p[2 * n + 1])
                re[n] = i; im[n] = q
                sumI += i; sumQ += q
            }
            // Gleichanteil (HackRF-Mittenspitze) langsam nachführen.
            dcRe += 0.2 * (sumI / Float(count) - dcRe)
            dcIm += 0.2 * (sumQ / Float(count) - dcIm)
        }
        vDSP.add(-dcRe, re, result: &re)
        vDSP.add(-dcIm, im, result: &im)
        vDSP.multiply(1 / 128, re, result: &re)
        vDSP.multiply(1 / 128, im, result: &im)
        let (outRe, outIm) = RadioDemodulator.decimateComplex(re, im, history: &historyRe, &historyIm,
                                                             filter: filter, factor: Self.decimation)
        return (outRe, outIm)
    }
}
