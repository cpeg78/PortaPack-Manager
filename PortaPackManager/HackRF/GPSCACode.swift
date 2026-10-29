import Foundation

/// Erzeugt die GPS-L1-C/A-Gold-Codes (PRN 1–32).
///
/// Jeder Satellit sendet einen eigenen 1023-Chip-Code mit 1,023 Mchip/s, der
/// sich jede Millisekunde wiederholt. Der Code entsteht aus zwei
/// 10-Bit-Schieberegistern (G1, G2) nach IS-GPS-200; die Satelliten
/// unterscheiden sich nur in der Anzapfung von G2.
enum GPSCACode {
    static let prnCount = 32
    static let chips = 1023

    /// Anzapfpaare von G2 je PRN (1-basierte Registerstellen), IS-GPS-200 Tab. 3-Ia.
    private static let g2Taps: [(Int, Int)] = [
        (2, 6), (3, 7), (4, 8), (5, 9), (1, 9), (2, 10), (1, 8), (2, 9),
        (3, 10), (2, 3), (3, 4), (5, 6), (6, 7), (7, 8), (8, 9), (9, 10),
        (1, 4), (2, 5), (3, 6), (4, 7), (5, 8), (6, 9), (1, 3), (4, 6),
        (5, 7), (6, 8), (7, 9), (8, 10), (1, 6), (2, 7), (3, 8), (4, 9),
    ]

    /// Die ersten 10 Chips je PRN als Oktalwert – Prüfwerte aus IS-GPS-200.
    static let firstTenChipsOctal: [Int] = [
        0o1440, 0o1620, 0o1710, 0o1744, 0o1133, 0o1455, 0o1131, 0o1454,
        0o1626, 0o1504, 0o1642, 0o1750, 0o1764, 0o1772, 0o1775, 0o1776,
        0o1156, 0o1467, 0o1633, 0o1715, 0o1746, 0o1763, 0o1063, 0o1706,
        0o1743, 0o1761, 0o1770, 0o1774, 0o1127, 0o1453, 0o1625, 0o1712,
    ]

    /// Der C/A-Code eines Satelliten als 1023 Chips, 0 oder 1.
    /// `prn` ist 1-basiert (1…32).
    static func code(prn: Int) -> [Int] {
        precondition((1...prnCount).contains(prn), "PRN 1…32")
        let (tapA, tapB) = g2Taps[prn - 1]
        var g1 = [Int](repeating: 1, count: 11)   // Index 1…10 genutzt
        var g2 = [Int](repeating: 1, count: 11)
        var out = [Int](repeating: 0, count: chips)
        for i in 0..<chips {
            out[i] = g1[10] ^ (g2[tapA] ^ g2[tapB])
            let fb1 = g1[3] ^ g1[10]
            let fb2 = g2[2] ^ g2[3] ^ g2[6] ^ g2[8] ^ g2[9] ^ g2[10]
            for k in stride(from: 10, to: 1, by: -1) {
                g1[k] = g1[k - 1]
                g2[k] = g2[k - 1]
            }
            g1[1] = fb1
            g2[1] = fb2
        }
        return out
    }

    /// Codes als ±1, einmal erzeugt (für die Kreuzkorrelationsprüfung).
    private static let bipolar: [[Float]] = (1...prnCount).map { code(prn: $0).map { $0 == 0 ? 1 : -1 } }

    /// Betrag der Kreuzkorrelation (0…1) zwischen dem Signal von `strong` und der
    /// Replik von `weak`, wenn die Replik um `offsetChips` gegen den Code des
    /// starken Satelliten versetzt ist und `dopplerHz` Trägerablage dazwischen
    /// liegt – über eine Codeperiode, halbe Chips; das Maximum über ±½ Chip
    /// fängt die Ungenauigkeit der Akquisition ab.
    static func crossCorrelation(_ strong: Int, _ weak: Int, offsetChips: Double, dopplerHz: Double) -> Double {
        let a = bipolar[strong - 1], b = bipolar[weak - 1]
        let n = 2 * chips
        let step = 2 * Double.pi * dopplerHz / (Double(n) * 1000)
        let dc = cos(step), ds = sin(step)
        var best = 0.0
        for shift in -1...1 {
            var off = (Int((2 * offsetChips).rounded()) + shift) % n
            if off < 0 { off += n }
            var re = 0.0, im = 0.0
            var c = 1.0, s = 0.0
            for m in 0..<n {
                var k = m + off
                if k >= n { k -= n }
                let v = Double(a[m >> 1] * b[k >> 1])
                re += v * c; im += v * s
                let nc = c * dc - s * ds
                s = s * dc + c * ds
                c = nc
            }
            best = max(best, (re * re + im * im).squareRoot() / Double(n))
        }
        return best
    }

    /// Der Code als ±1-Folge, auf `samples` Abtastwerte gestreckt (eine
    /// Codeperiode = 1 ms). Chip 0 → +1, Chip 1 → −1.
    static func sampled(prn: Int, samples: Int) -> [Float] {
        let c = code(prn: prn)
        var out = [Float](repeating: 0, count: samples)
        for n in 0..<samples {
            let chip = (n * chips) / samples
            out[n] = c[chip] == 0 ? 1 : -1
        }
        return out
    }
}
