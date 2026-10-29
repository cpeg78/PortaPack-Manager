import Accelerate
import Foundation

/// Komplexe DFT fester Länge (vDSP, Länge f·2ⁿ mit f ∈ {1, 3, 5, 15}).
final class FT8DFT: @unchecked Sendable {
    let length: Int
    private let setup: vDSP_DFT_Setup

    init(length: Int, inverse: Bool = false) {
        self.length = length
        guard let s = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), inverse ? .INVERSE : .FORWARD) else {
            fatalError("DFT-Länge \(length) wird von vDSP nicht unterstützt")
        }
        setup = s
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func run(_ inRe: [Float], _ inIm: [Float], _ outRe: inout [Float], _ outIm: inout [Float]) {
        precondition(inRe.count == length && inIm.count == length)
        if outRe.count != length { outRe = [Float](repeating: 0, count: length) }
        if outIm.count != length { outIm = [Float](repeating: 0, count: length) }
        vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
    }
}

/// Komplexes Signal als getrennte Real-/Imaginärteile.
struct FT8Signal: Sendable {
    var re: [Float]
    var im: [Float]
    var count: Int { re.count }

    init(re: [Float], im: [Float]) { self.re = re; self.im = im }
    init(count: Int) { re = [Float](repeating: 0, count: count); im = [Float](repeating: 0, count: count) }

    /// Ausschnitt, außerhalb mit Nullen aufgefüllt.
    func slice(from start: Int, count n: Int) -> FT8Signal {
        var out = FT8Signal(count: n)
        let lo = max(0, start), hi = min(count, start + n)
        if lo < hi {
            for i in lo..<hi { out.re[i - start] = re[i]; out.im[i - start] = im[i] }
        }
        return out
    }

    /// Nimmt eine lineare Drift von `rate` Hz/s heraus (Phase −π·rate·(t − center)²),
    /// die Frequenz bei `center` (Sekunden ab Index 0) bleibt.
    func dechirped(rate: Double, center: Double, sampleRate: Double) -> FT8Signal {
        var out = FT8Signal(count: count)
        for k in 0..<count {
            let t = Double(k) / sampleRate - center
            let phi = -Double.pi * rate * t * t
            let c = Float(cos(phi)), s = Float(sin(phi))
            out.re[k] = re[k] * c - im[k] * s
            out.im[k] = re[k] * s + im[k] * c
        }
        return out
    }

    /// Mischt um `−frequency` Hz (Frequenz nach 0 verschieben).
    func shifted(by frequency: Double, sampleRate: Double, startPhase: Double = 0) -> FT8Signal {
        var out = FT8Signal(count: count)
        let w = -2 * Double.pi * frequency / sampleRate
        // Oszillator in Blöcken neu angesetzt, damit sich Rundungsfehler nicht aufsummieren.
        var i = 0
        while i < count {
            let end = min(count, i + 4096)
            let p0 = startPhase + w * Double(i)
            var c = Float(cos(p0)), s = Float(sin(p0))
            let dc = Float(cos(w)), ds = Float(sin(w))
            for k in i..<end {
                let a = re[k], b = im[k]
                out.re[k] = a * c - b * s
                out.im[k] = a * s + b * c
                let nc = c * dc - s * ds
                s = c * ds + s * dc
                c = nc
            }
            i = end
        }
        return out
    }
}

/// FIR-Dezimierer für komplexe Daten mit reellen oder komplexen Koeffizienten
/// (Korrelationsform wie `vDSP_desamp`), blockweise mit Gedächtnis.
final class FT8Decimator: @unchecked Sendable {
    let factor: Int
    private let tapsRe: [Float]
    private let tapsIm: [Float]?
    private var histRe: [Float] = []
    private var histIm: [Float] = []

    init(factor: Int, tapsRe: [Float], tapsIm: [Float]? = nil) {
        self.factor = factor
        self.tapsRe = tapsRe
        self.tapsIm = tapsIm
    }

    func reset() { histRe = []; histIm = [] }

    func process(_ re: [Float], _ im: [Float]) -> (re: [Float], im: [Float]) {
        histRe.append(contentsOf: re)
        histIm.append(contentsOf: im)
        let taps = tapsRe.count
        guard histRe.count >= taps else { return ([], []) }
        let outCount = (histRe.count - taps) / factor + 1
        var aRe = [Float](repeating: 0, count: outCount), aIm = [Float](repeating: 0, count: outCount)
        vDSP_desamp(histRe, vDSP_Stride(factor), tapsRe, &aRe, vDSP_Length(outCount), vDSP_Length(taps))
        vDSP_desamp(histIm, vDSP_Stride(factor), tapsRe, &aIm, vDSP_Length(outCount), vDSP_Length(taps))
        if let tapsIm {
            // (x + jy)(h + jg) = (xh − yg) + j(xg + yh)
            var bRe = [Float](repeating: 0, count: outCount), bIm = [Float](repeating: 0, count: outCount)
            vDSP_desamp(histIm, vDSP_Stride(factor), tapsIm, &bRe, vDSP_Length(outCount), vDSP_Length(taps))
            vDSP_desamp(histRe, vDSP_Stride(factor), tapsIm, &bIm, vDSP_Length(outCount), vDSP_Length(taps))
            var cRe = [Float](repeating: 0, count: outCount), cIm = [Float](repeating: 0, count: outCount)
            vDSP_vsub(bRe, 1, aRe, 1, &cRe, 1, vDSP_Length(outCount))
            vDSP_vadd(aIm, 1, bIm, 1, &cIm, 1, vDSP_Length(outCount))
            aRe = cRe
            aIm = cIm
        }
        let consumed = outCount * factor
        histRe.removeFirst(consumed)
        histIm.removeFirst(consumed)
        return (aRe, aIm)
    }

    /// Gefensterter Sinc-Tiefpass (Blackman), Verstärkung 1.
    static func lowpass(taps: Int, cutoff: Double, rate: Double) -> [Float] {
        RadioDemodulator.lowpass(taps: taps, cutoff: cutoff, rate: rate)
    }

    /// Komplexer Bandpass in Korrelationsform: Tiefpass um `center` verschoben.
    static func bandpass(taps: Int, center: Double, halfWidth: Double, rate: Double) -> (re: [Float], im: [Float]) {
        let h = lowpass(taps: taps, cutoff: halfWidth, rate: rate)
        let w = -2 * Double.pi * center / rate
        return (h.enumerated().map { Float(Double($1) * cos(w * Double($0))) },
                h.enumerated().map { Float(Double($1) * sin(w * Double($0))) })
    }
}

/// FT8Locator-Locator ↔ Koordinaten.
enum FT8Locator {
    /// Mitte des Feldes (4 oder 6 Stellen), `nil` bei ungültigem Locator.
    static func coordinate(_ locator: String) -> (lat: Double, lon: Double)? {
        let c = Array(locator.uppercased().utf8)
        guard c.count == 4 || c.count == 6,
              (65...82).contains(c[0]), (65...82).contains(c[1]),
              (48...57).contains(c[2]), (48...57).contains(c[3]) else { return nil }
        var lon = Double(c[0] - 65) * 20 - 180 + Double(c[2] - 48) * 2
        var lat = Double(c[1] - 65) * 10 - 90 + Double(c[3] - 48)
        if c.count == 6 {
            guard (65...88).contains(c[4]), (65...88).contains(c[5]) else { return nil }
            lon += Double(c[4] - 65) * (2.0 / 24) + 1.0 / 24
            lat += Double(c[5] - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }

    /// Koordinaten → 6-stelliger Locator.
    static func locator(lat: Double, lon: Double) -> String {
        let x = min(max(lon + 180, 0), 359.9999)
        let y = min(max(lat + 90, 0), 179.9999)
        let a = Int(x / 20), b = Int(y / 10)
        let c = Int((x - Double(a) * 20) / 2), d = Int(y - Double(b) * 10)
        let e = Int((x - Double(a) * 20 - Double(c) * 2) * 12)
        let f = Int((y - Double(b) * 10 - Double(d)) * 24)
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWX")
        return String([letters[a], letters[b]]) + "\(c)\(d)" + String([letters[e], letters[f]]).lowercased()
    }
}
