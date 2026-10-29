import Accelerate
import Foundation

// Grundbausteine des LTE-Empfängers (3GPP TS 36.211/36.212/36.213):
// komplexe Zahl, OFDM-Raster, FFT, Gold-Folge, Bänder und Netzbetreiber.
//
// Gelesen werden ausschließlich die öffentlichen Rundsendekanäle einer
// Basisstation (Synchronisation, MIB, SIB1) – keine Nutzerdaten.

/// Komplexe Zahl (Float).
struct LTEC: Sendable, Equatable {
    var re: Float
    var im: Float

    init(_ re: Float, _ im: Float) {
        self.re = re
        self.im = im
    }

    static let zero = LTEC(0, 0)
    var conj: LTEC { LTEC(re, -im) }
    /// |z|²
    var norm: Float { re * re + im * im }
    var phase: Double { atan2(Double(im), Double(re)) }

    static func + (a: LTEC, b: LTEC) -> LTEC { LTEC(a.re + b.re, a.im + b.im) }
    static func - (a: LTEC, b: LTEC) -> LTEC { LTEC(a.re - b.re, a.im - b.im) }
    static func * (a: LTEC, b: LTEC) -> LTEC { LTEC(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Float, b: LTEC) -> LTEC { LTEC(a * b.re, a * b.im) }
    static prefix func - (a: LTEC) -> LTEC { LTEC(-a.re, -a.im) }
    static func += (a: inout LTEC, b: LTEC) { a = a + b }
    static func cis(_ phase: Double) -> LTEC { LTEC(Float(cos(phase)), Float(sin(phase))) }
}

/// Zeitraster eines LTE-Signals bei `fftSize`·15 kHz Abtastrate.
struct LTENumerology: Sendable, Hashable {
    var fftSize: Int
    var extendedCP: Bool

    var sampleRate: Double { Double(fftSize) * 15_000 }
    var symbolsPerSlot: Int { extendedCP ? 6 : 7 }
    var symbolsPerSubframe: Int { 2 * symbolsPerSlot }
    /// 0,5 ms
    var slotLength: Int { fftSize * 15 / 2 }
    /// 1 ms
    var subframeLength: Int { fftSize * 15 }
    /// 10 ms
    var frameLength: Int { fftSize * 150 }

    /// Länge des zyklischen Präfixes von Symbol `l` im Slot (normal: 160/144 bei 2048).
    func cpLength(_ l: Int) -> Int {
        extendedCP ? fftSize / 4 : (l == 0 ? fftSize * 5 / 64 : fftSize * 9 / 128)
    }

    /// Beginn des Nutzteils von Symbol `symbol` (0..<symbolsPerSubframe) ab Teilrahmenbeginn.
    func usefulStart(_ symbol: Int) -> Int {
        let slot = symbol / symbolsPerSlot, l = symbol % symbolsPerSlot
        var position = slot * slotLength
        for i in 0..<l { position += cpLength(i) + fftSize }
        return position + cpLength(l)
    }

    /// FFT-Platz des Unterträgers `k` (0..<nsc, aufsteigende Frequenz, DC ausgelassen).
    func bin(_ k: Int, nsc: Int) -> Int {
        let m = k - nsc / 2
        return m < 0 ? fftSize + m : m + 1
    }

    /// Vorzeichenbehaftete Frequenzzahl des Unterträgers `k` (ohne DC).
    static func frequencyIndex(_ k: Int, nsc: Int) -> Int {
        let m = k - nsc / 2
        return m < 0 ? m : m + 1
    }
}

/// Diskrete Fourier-Transformation (vDSP) fester Länge.
final class LTEFFT: @unchecked Sendable {
    let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup

    init(size: Int) {
        self.size = size
        forwardSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        inverseSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE)!
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// Unnormierte Vorwärtstransformation von `size` Werten ab `offset`.
    func forward(re: UnsafePointer<Float>, im: UnsafePointer<Float>, outRe: inout [Float], outIm: inout [Float]) {
        vDSP_DFT_Execute(forwardSetup, re, im, &outRe, &outIm)
    }

    func forward(_ re: [Float], _ im: [Float]) -> (re: [Float], im: [Float]) {
        var outRe = [Float](repeating: 0, count: size), outIm = [Float](repeating: 0, count: size)
        vDSP_DFT_Execute(forwardSetup, re, im, &outRe, &outIm)
        return (outRe, outIm)
    }

    /// Unnormierte Rücktransformation (Summe ohne 1/N).
    func inverse(_ re: [Float], _ im: [Float]) -> (re: [Float], im: [Float]) {
        var outRe = [Float](repeating: 0, count: size), outIm = [Float](repeating: 0, count: size)
        vDSP_DFT_Execute(inverseSetup, re, im, &outRe, &outIm)
        return (outRe, outIm)
    }
}

/// Pseudozufallsfolge c(n) (36.211 7.2): zwei m-Folgen der Länge 31, Versatz 1600.
enum LTESequence {
    static func gold(_ cInit: UInt32, count: Int) -> [UInt8] {
        let nc = 1600
        let total = count + nc + 31
        var x1 = [UInt8](repeating: 0, count: total)
        var x2 = [UInt8](repeating: 0, count: total)
        x1[0] = 1
        for i in 0..<31 { x2[i] = UInt8((cInit >> UInt32(i)) & 1) }
        for n in 0..<(total - 31) {
            x1[n + 31] = x1[n + 3] ^ x1[n]
            x2[n + 31] = x2[n + 3] ^ x2[n + 2] ^ x2[n + 1] ^ x2[n]
        }
        var out = [UInt8](repeating: 0, count: count)
        for n in 0..<count { out[n] = x1[n + nc] ^ x2[n + nc] }
        return out
    }

    /// Weiche Werte entwürfeln: Bit 1 der Folge dreht das Vorzeichen.
    static func descramble(_ llr: inout [Float], cInit: UInt32, offset: Int = 0) {
        let c = gold(cInit, count: offset + llr.count)
        for i in 0..<llr.count where c[offset + i] == 1 { llr[i] = -llr[i] }
    }

    static func scramble(_ bits: [UInt8], cInit: UInt32, offset: Int = 0) -> [UInt8] {
        let c = gold(cInit, count: offset + bits.count)
        return bits.enumerated().map { $0.element ^ c[offset + $0.offset] }
    }
}

/// QPSK nach 36.211 7.1.2 (Bit 0 → +1/√2).
enum LTEQPSK {
    static let amplitude = Float(1 / 2.0.squareRoot())

    static func modulate(_ bits: [UInt8]) -> [LTEC] {
        stride(from: 0, to: bits.count - 1, by: 2).map {
            LTEC(bits[$0] == 0 ? amplitude : -amplitude, bits[$0 + 1] == 0 ? amplitude : -amplitude)
        }
    }

    /// Weiche Bits (positiv = 0) aus entzerrten Symbolen und deren Störabstand je Symbol.
    static func llr(_ symbols: [LTEC], gains: [Float], noise: Float) -> [Float] {
        let n = max(noise, 1e-12)
        var out = [Float](repeating: 0, count: 2 * symbols.count)
        for (i, s) in symbols.enumerated() {
            let c = 2 * Float(2.0.squareRoot()) * gains[i] / n
            out[2 * i] = max(-30, min(30, c * s.re))
            out[2 * i + 1] = max(-30, min(30, c * s.im))
        }
        return out
    }
}

// MARK: - Bänder und Netzbetreiber

/// LTE-Band (FDD-Abwärtsstrecke) mit EARFCN-Zuordnung (36.101 Tabelle 5.7.3-1).
struct LTEBand: Sendable, Hashable, Identifiable {
    var number: Int
    var name: String
    var lowMHz: Double
    var highMHz: Double
    var earfcnOffset: Int

    var id: Int { number }

    func earfcn(forMHz mhz: Double) -> Int { earfcnOffset + Int(((mhz - lowMHz) * 10).rounded()) }
    func frequencyMHz(earfcn: Int) -> Double { lowMHz + Double(earfcn - earfcnOffset) / 10 }
    func contains(earfcn: Int) -> Bool {
        earfcn >= earfcnOffset && earfcn < earfcnOffset + Int(((highMHz - lowMHz) * 10).rounded())
    }

    /// In Deutschland genutzte Bänder.
    static let germany: [LTEBand] = [
        LTEBand(number: 28, name: "700 MHz", lowMHz: 758, highMHz: 803, earfcnOffset: 9210),
        LTEBand(number: 20, name: "800 MHz", lowMHz: 791, highMHz: 821, earfcnOffset: 6150),
        LTEBand(number: 8, name: "900 MHz", lowMHz: 925, highMHz: 960, earfcnOffset: 3450),
        LTEBand(number: 3, name: "1800 MHz", lowMHz: 1805, highMHz: 1880, earfcnOffset: 1200),
        LTEBand(number: 1, name: "2100 MHz", lowMHz: 2110, highMHz: 2170, earfcnOffset: 0),
        LTEBand(number: 7, name: "2600 MHz", lowMHz: 2620, highMHz: 2690, earfcnOffset: 2750),
    ]

    static func band(number: Int) -> LTEBand? { germany.first { $0.number == number } }

    /// Band und EARFCN zu einer Mittenfrequenz (auf 100 kHz gerundet); B28 nur, wo B20 nicht passt.
    static func locate(mhz: Double) -> (band: LTEBand, earfcn: Int)? {
        let candidates = germany.filter { mhz >= $0.lowMHz && mhz < $0.highMHz }
        guard let band = candidates.first(where: { $0.number != 28 }) ?? candidates.first else { return nil }
        return (band, band.earfcn(forMHz: mhz))
    }
}

/// Netzbetreiber nach MCC/MNC.
enum LTEOperator {
    static func name(mcc: String, mnc: String) -> String? {
        switch (mcc, mnc) {
        case ("262", "01"), ("262", "06"): "Telekom"
        case ("262", "02"), ("262", "04"), ("262", "09"): "Vodafone"
        case ("262", "03"), ("262", "05"), ("262", "07"), ("262", "08"), ("262", "11"), ("262", "77"): "O2 (Telefónica)"
        case ("262", "23"): "1&1"
        case ("232", "01"): "A1 (Österreich)"
        case ("232", "03"): "Magenta (Österreich)"
        case ("232", "10"): "Drei (Österreich)"
        case ("228", "01"): "Swisscom"
        case ("228", "02"): "Sunrise"
        case ("228", "03"): "Salt"
        case ("204", "04"): "Vodafone NL"
        case ("204", "08"): "KPN"
        case ("204", "16"): "Odido (NL)"
        case ("208", "01"): "Orange (Frankreich)"
        case ("230", "01"): "T-Mobile CZ"
        default: nil
        }
    }
}
