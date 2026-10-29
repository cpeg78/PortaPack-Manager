import Accelerate
import Foundation

/// Schneidet aus dem HackRF-Strom (2,4 MS/s) einen SSB-Kanal heraus und
/// liefert komplexes Basisband mit 12 kHz, die Skalenfrequenz bei 0 Hz.
///
/// Kette: Mischen um `offset` (Oszillatortabelle mit exakter Periode) →
/// Tiefpass 25 kHz, ÷10 → Tiefpass 6,5 kHz, ÷10 → komplexer Bandpass
/// −2,5 … +5,5 kHz (oberes Seitenband samt Reserve für Quarzablagen), ÷2.
/// Negative Frequenzen (unteres Seitenband) werden unterdrückt; die Dekoder
/// arbeiten direkt auf dem komplexen Signal.
final class FT8Channelizer: @unchecked Sendable {
    static let inputRate = 2_400_000.0
    static let outputRate = 12_000.0

    /// Kanal (Skalenfrequenz) relativ zur HackRF-Mittenfrequenz, ganze Hz.
    let offset: Int
    private let oscRe: [Float]
    private let oscIm: [Float]
    private var oscIndex = 0
    private let stage1: FT8Decimator
    private let stage2: FT8Decimator
    private let stage3: FT8Decimator

    init(offset: Int) {
        self.offset = offset
        let fs = Int(Self.inputRate)
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let period = fs / gcd(fs, abs(offset) == 0 ? fs : abs(offset))
        oscRe = (0..<period).map { Float(cos(-2 * Double.pi * Double(offset) * Double($0) / Self.inputRate)) }
        oscIm = (0..<period).map { Float(sin(-2 * Double.pi * Double(offset) * Double($0) / Self.inputRate)) }
        stage1 = FT8Decimator(factor: 10, tapsRe: FT8Decimator.lowpass(taps: 95, cutoff: 25_000, rate: 2_400_000))
        stage2 = FT8Decimator(factor: 10, tapsRe: FT8Decimator.lowpass(taps: 127, cutoff: 6_500, rate: 240_000))
        let bp = FT8Decimator.bandpass(taps: 127, center: 1_500, halfWidth: 4_000, rate: 24_000)
        stage3 = FT8Decimator(factor: 2, tapsRe: bp.re, tapsIm: bp.im)
    }

    func reset() {
        oscIndex = 0
        stage1.reset(); stage2.reset(); stage3.reset()
    }

    /// Bereits in Float gewandelte IQ-Werte (±1) → 12-kHz-Basisband.
    func process(re: [Float], im: [Float]) -> FT8Signal {
        let n = re.count
        var mr = [Float](repeating: 0, count: n), mi = [Float](repeating: 0, count: n)
        let period = oscRe.count
        var k = oscIndex
        oscRe.withUnsafeBufferPointer { cr in
            oscIm.withUnsafeBufferPointer { ci in
                for i in 0..<n {
                    let c = cr[k], s = ci[k], a = re[i], b = im[i]
                    mr[i] = a * c - b * s
                    mi[i] = a * s + b * c
                    k += 1
                    if k == period { k = 0 }
                }
            }
        }
        oscIndex = k
        let a = stage1.process(mr, mi)
        let b = stage2.process(a.re, a.im)
        let c = stage3.process(b.re, b.im)
        return FT8Signal(re: c.re, im: c.im)
    }

    /// int8-IQ-Block → Float (±1), getrennt nach I und Q.
    static func convert(_ iq: Data) -> (re: [Float], im: [Float]) {
        let n = iq.count / 2
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for i in 0..<n {
                re[i] = Float(p[2 * i]) / 128
                im[i] = Float(p[2 * i + 1]) / 128
            }
        }
        return (re, im)
    }
}

/// Ringpuffer für das 12-kHz-Basisband mit Zeitbezug zur Mac-Uhr.
///
/// Jeder Block bekommt seine Ankunftszeit; daraus folgt die Uhrzeit des
/// Abtastwerts 0. Verzögerungen (USB, Warteschlange) machen Blöcke nur
/// später, nie früher – deshalb gilt das Minimum der letzten 20 s. Fehlen
/// Blöcke (Rückstau, verworfen), springt der Wert dauerhaft nach oben; nach
/// drei Blöcken über 0,25 s wird neu verankert.
struct FT8SampleBuffer: Sendable {
    let maxSeconds: Double
    private(set) var re: [Float] = []
    private(set) var im: [Float] = []
    /// Absoluter Index des ersten gespeicherten Abtastwerts.
    private(set) var firstIndex = 0
    /// Anzahl aller bisher erzeugten Abtastwerte.
    private(set) var produced = 0
    private var offsets: [(arrival: Double, offset: Double)] = []
    private var jumps = 0
    /// Uhrzeit (Unix-Sekunden) des Abtastwerts mit Index 0.
    private(set) var anchor: Double?

    init(maxSeconds: Double) { self.maxSeconds = maxSeconds }

    mutating func reset() {
        re = []; im = []; firstIndex = 0; produced = 0; offsets = []; jumps = 0; anchor = nil
    }

    mutating func append(_ x: FT8Signal, arrival: Double, rate: Double = 12_000) {
        guard x.count > 0 else { return }
        re.append(contentsOf: x.re)
        im.append(contentsOf: x.im)
        produced += x.count
        let offset = arrival - Double(produced) / rate
        if let a = anchor, offset - a > 0.25 {
            jumps += 1
            if jumps >= 3 {
                // Lücke im Strom: neu verankern.
                offsets = []
                jumps = 0
            }
        } else {
            jumps = 0
        }
        offsets.append((arrival, offset))
        offsets.removeAll { arrival - $0.arrival > 20 }
        anchor = offsets.map(\.offset).min()
        let maxCount = Int(maxSeconds * rate)
        if re.count > maxCount + Int(5 * rate) {
            let drop = re.count - maxCount
            re.removeFirst(drop)
            im.removeFirst(drop)
            firstIndex += drop
        }
    }

    /// Ausschnitt ab Uhrzeit `start` (Unix-Sekunden) über `count` Abtastwerte;
    /// fehlende Werte sind 0. Liefert auch, ab welcher Uhrzeit Daten vorliegen.
    func extract(from start: Double, count: Int, rate: Double = 12_000) -> (signal: FT8Signal, dataStart: Double, dataEnd: Double)? {
        guard let anchor, !re.isEmpty else { return nil }
        let startIndex = Int(((start - anchor) * rate).rounded())
        var out = FT8Signal(count: count)
        let lo = max(startIndex, firstIndex), hi = min(startIndex + count, firstIndex + re.count)
        if lo < hi {
            for i in lo..<hi {
                out.re[i - startIndex] = re[i - firstIndex]
                out.im[i - startIndex] = im[i - firstIndex]
            }
        }
        let dataStart = anchor + Double(firstIndex) / rate
        let dataEnd = anchor + Double(firstIndex + re.count) / rate
        return (out, dataStart, dataEnd)
    }
}
