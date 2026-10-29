import Accelerate
import Foundation

/// Polyphasen-Filterbank (gewichtetes Überlappen und Falten, „WOLA“): zerlegt
/// einen breiten Ausschnitt (8 oder 16 MS/s) auf einmal in `bins` gleich breite
/// Kanäle. Bei 8 MS/s und 960 Kanälen ist jeder Kanal genau 25/3 kHz breit –
/// das Flugfunkraster. Jeder Kanal liefert komplexe Werte mit 16 kHz
/// (Vorschub `hop` = 500 bzw. 1000 Abtastwerte, also zweifach überabgetastet:
/// der Sprachkanal ±3 kHz faltet nicht).
///
/// Ablauf je Ausgaberahmen: die letzten `taps` = K·N Eingangswerte mit dem
/// Prototyp-Tiefpass gewichten, in N Fächer falten (aufsummieren), N-Punkt-DFT.
/// Kanal m entspricht dann einem Bandpass um m·fs/N. Die Phasendrehung durch
/// den Vorschub fällt bei AM (Betrag) nicht ins Gewicht und wird nicht korrigiert.
///
/// Prototyp: Kaiser-gefensterter Sinc, Grenze eine halbe Kanalbreite (4,17 kHz),
/// K = 12 → Übergang ≈ 2,5 kHz breit, Sperrdämpfung ≈ 60 dB. Durchlass bis
/// ≈ 2,9 kHz, Nachbarkanal (8,33 kHz) gedämpft.
final class AirbandChannelizer: @unchecked Sendable {
    let sampleRate: Double
    let bins: Int
    let hop: Int
    let taps: Int
    /// Ausgaberate je Kanal in Hz.
    var outputRate: Double { sampleRate / Double(hop) }

    private let prototype: [Float]
    private let dft: vDSP_DFT_Setup
    private var bufferRe: [Float] = []
    private var bufferIm: [Float] = []
    private var weighted: [Float]
    private var weightedIm: [Float]
    private var foldRe: [Float]
    private var foldIm: [Float]
    private var outRe: [Float]
    private var outIm: [Float]
    private var magnitudes: [Float]

    /// Ergebnis eines Blocks.
    struct Output {
        /// Zahl der Ausgaberahmen in diesem Block.
        var frames: Int
        /// Summe |X|² je Kanal (Index 0…N−1, FFT-Reihenfolge) über alle Rahmen.
        var powerSum: [Float]
        /// Komplexe Werte der ausgewählten Kanäle, je Kanal ein Feld.
        var selectedRe: [[Float]]
        var selectedIm: [[Float]]
    }

    /// `bins` muss 2^n, 3·2^n, 5·2^n oder 15·2^n sein (vDSP-DFT).
    init(sampleRate: Double = 8_000_000, bins: Int = 960, hop: Int = 500, overlap: Int = 12, beta: Double = 5.65) {
        self.sampleRate = sampleRate
        self.bins = bins
        self.hop = hop
        taps = overlap * bins
        prototype = Self.kaiserLowpass(taps: overlap * bins, cutoff: 0.5 / Double(bins), beta: beta)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(bins), .FORWARD) else {
            fatalError("DFT-Länge \(bins) wird von vDSP nicht unterstützt")
        }
        dft = setup
        weighted = [Float](repeating: 0, count: taps)
        weightedIm = [Float](repeating: 0, count: taps)
        foldRe = [Float](repeating: 0, count: bins)
        foldIm = [Float](repeating: 0, count: bins)
        outRe = [Float](repeating: 0, count: bins)
        outIm = [Float](repeating: 0, count: bins)
        magnitudes = [Float](repeating: 0, count: bins)
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

    func reset() {
        bufferRe = []
        bufferIm = []
    }

    /// Kanal (FFT-Index) einer Frequenzablage in ganzen Kanälen (negativ = unterhalb der Mitte).
    func binIndex(offset: Int) -> Int { ((offset % bins) + bins) % bins }

    /// Kaiser-gefensterter Sinc-Tiefpass, Summe 1 (Gleichanteil-Verstärkung 1).
    static func kaiserLowpass(taps: Int, cutoff: Double, beta: Double) -> [Float] {
        let m = Double(taps - 1)
        let i0Beta = besselI0(beta)
        var h = (0..<taps).map { n -> Double in
            let x = Double(n) - m / 2
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let r = 2 * Double(n) / m - 1
            return sinc * besselI0(beta * (1 - r * r).squareRoot()) / i0Beta
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map(Float.init)
    }

    /// Modifizierte Besselfunktion erster Art, Ordnung 0 (Reihe).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2
        for k in 1..<40 {
            term *= (half / Double(k)) * (half / Double(k))
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }

    /// Wandelt int8-IQ in Float und zieht den Gleichanteil des Blocks ab
    /// (DC-Spitze des HackRF in der Mitte des Ausschnitts).
    static func convert(_ iq: Data) -> (re: [Float], im: [Float]) {
        let count = iq.count / 2
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        guard count > 0 else { return (re, im) }
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            re.withUnsafeMutableBufferPointer { r in
                vDSP_vflt8(p.baseAddress!, 2, r.baseAddress!, 1, vDSP_Length(count))
            }
            im.withUnsafeMutableBufferPointer { i in
                vDSP_vflt8(p.baseAddress! + 1, 2, i.baseAddress!, 1, vDSP_Length(count))
            }
        }
        let meanRe = vDSP.mean(re), meanIm = vDSP.mean(im)
        re = vDSP.add(-meanRe, re)
        im = vDSP.add(-meanIm, im)
        re = vDSP.multiply(Float(1.0 / 128), re)
        im = vDSP.multiply(Float(1.0 / 128), im)
        return (re, im)
    }

    /// Verarbeitet neue Eingangswerte. `select`: FFT-Indizes der Kanäle, deren
    /// komplexe Werte gebraucht werden (Kanalliste); von allen übrigen nur die Leistung.
    func process(re: [Float], im: [Float], select: [Int]) -> Output {
        bufferRe.append(contentsOf: re)
        bufferIm.append(contentsOf: im)
        var power = [Float](repeating: 0, count: bins)
        var selRe = [[Float]](repeating: [], count: select.count)
        var selIm = [[Float]](repeating: [], count: select.count)
        var position = 0
        var frames = 0
        let n = bins
        bufferRe.withUnsafeBufferPointer { bRe in
            bufferIm.withUnsafeBufferPointer { bIm in
                while position + taps <= bRe.count {
                    // Gewichten
                    vDSP_vmul(bRe.baseAddress! + position, 1, prototype, 1, &weighted, 1, vDSP_Length(taps))
                    vDSP_vmul(bIm.baseAddress! + position, 1, prototype, 1, &weightedIm, 1, vDSP_Length(taps))
                    // Falten
                    weighted.withUnsafeBufferPointer { w in
                        foldRe.withUnsafeMutableBufferPointer { f in
                            memcpy(f.baseAddress!, w.baseAddress!, n * MemoryLayout<Float>.size)
                            var k = n
                            while k < taps {
                                vDSP_vadd(f.baseAddress!, 1, w.baseAddress! + k, 1, f.baseAddress!, 1, vDSP_Length(n))
                                k += n
                            }
                        }
                    }
                    weightedIm.withUnsafeBufferPointer { w in
                        foldIm.withUnsafeMutableBufferPointer { f in
                            memcpy(f.baseAddress!, w.baseAddress!, n * MemoryLayout<Float>.size)
                            var k = n
                            while k < taps {
                                vDSP_vadd(f.baseAddress!, 1, w.baseAddress! + k, 1, f.baseAddress!, 1, vDSP_Length(n))
                                k += n
                            }
                        }
                    }
                    vDSP_DFT_Execute(dft, foldRe, foldIm, &outRe, &outIm)
                    // Leistung aller Kanäle
                    outRe.withUnsafeMutableBufferPointer { r in
                        outIm.withUnsafeMutableBufferPointer { i in
                            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                            vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n))
                        }
                    }
                    vDSP_vadd(power, 1, magnitudes, 1, &power, 1, vDSP_Length(n))
                    for (k, index) in select.enumerated() {
                        selRe[k].append(outRe[index])
                        selIm[k].append(outIm[index])
                    }
                    frames += 1
                    position += hop
                }
            }
        }
        if position > 0 {
            bufferRe.removeFirst(position)
            bufferIm.removeFirst(position)
        }
        return Output(frames: frames, powerSum: power, selectedRe: selRe, selectedIm: selIm)
    }
}
