import Accelerate
import Foundation

/// P1-Symbol (9.8): Suche, S1/S2 und ganzzahlige Frequenzablage.
enum T2P1 {
    /// Aktive Träger k_P1 (Tabelle 68).
    static let carriers: [Int] = [
        44, 45, 47, 51, 54, 59, 62, 64, 65, 66, 70, 75, 78, 80, 81, 82, 84, 85, 87, 88, 89, 90, 94, 96, 97, 98, 102,
        107, 110, 112, 113, 114, 116, 117, 119, 120, 121, 122, 124, 125, 127, 131, 132, 133, 135, 136, 137, 138, 142,
        144, 145, 146, 148, 149, 151, 152, 153, 154, 158, 160, 161, 162, 166, 171, 172, 173, 175, 179, 182, 187, 190,
        192, 193, 194, 198, 203, 206, 208, 209, 210, 212, 213, 215, 216, 217, 218, 222, 224, 225, 226, 230, 235, 238,
        240, 241, 242, 244, 245, 247, 248, 249, 250, 252, 253, 255, 259, 260, 261, 263, 264, 265, 266, 270, 272, 273,
        274, 276, 277, 279, 280, 281, 282, 286, 288, 289, 290, 294, 299, 300, 301, 303, 307, 310, 315, 318, 320, 321,
        322, 326, 331, 334, 336, 337, 338, 340, 341, 343, 344, 345, 346, 350, 352, 353, 354, 358, 363, 364, 365, 367,
        371, 374, 379, 382, 384, 385, 386, 390, 395, 396, 397, 399, 403, 406, 411, 412, 413, 415, 419, 420, 421, 423,
        424, 425, 426, 428, 429, 431, 435, 438, 443, 446, 448, 449, 450, 454, 459, 462, 464, 465, 466, 468, 469, 471,
        472, 473, 474, 478, 480, 481, 482, 486, 491, 494, 496, 497, 498, 500, 501, 503, 504, 505, 506, 508, 509, 511,
        515, 516, 517, 519, 520, 521, 522, 526, 528, 529, 530, 532, 533, 535, 536, 537, 538, 542, 544, 545, 546, 550,
        555, 558, 560, 561, 562, 564, 565, 567, 568, 569, 570, 572, 573, 575, 579, 580, 581, 583, 584, 585, 586, 588,
        589, 591, 595, 598, 603, 604, 605, 607, 611, 612, 613, 615, 616, 617, 618, 622, 624, 625, 626, 628, 629, 631,
        632, 633, 634, 636, 637, 639, 643, 644, 645, 647, 648, 649, 650, 654, 656, 657, 658, 660, 661, 663, 664, 665,
        666, 670, 672, 673, 674, 678, 683, 684, 689, 692, 696, 698, 699, 701, 702, 703, 704, 706, 707, 708, 712, 714,
        715, 717, 718, 719, 720, 722, 723, 725, 726, 727, 729, 733, 734, 735, 736, 738, 739, 740, 744, 746, 747, 748,
        753, 756, 760, 762, 763, 765, 766, 767, 768, 770, 771, 772, 776, 778, 779, 780, 785, 788, 792, 794, 795, 796,
        801, 805, 806, 807, 809,
    ]
    static let s1: [String] = ["124721741D482E7B", "47127421481D7B2E", "217412472E7B1D48", "742147127B2E481D",
                               "1D482E7B12472174", "481D7B2E47127421", "2E7B1D4821741247", "7B2E481D74214712"]
    static let s2: [String] = [
        "121D4748212E747B1D1248472E217B7412E247B721D174841DED48B82EDE7B8B",
        "4748121D747B212E48471D127B742E2147B712E2748421D148B81DED7B8B2EDE",
        "212E747B121D47482E217B741D12484721D1748412E247B72EDE7B8B1DED48B8",
        "747B212E4748121D7B742E2148471D12748421D147B712E27B8B2EDE48B81DED",
        "1D1248472E217B74121D4748212E747B1DED48B82EDE7B8B12E247B721D17484",
        "48471D127B742E214748121D747B212E48B81DED7B8B2EDE47B712E2748421D1",
        "2E217B741D124847212E747B121D47482EDE7B8B1DED48B821D1748412E247B7",
        "7B742E2148471D12747B212E4748121D7B8B2EDE48B81DED748421D147B712E2",
        "12E247B721D174841DED48B82EDE7B8B121D4748212E747B1D1248472E217B74",
        "47B712E2748421D148B81DED7B8B2EDE4748121D747B212E48471D127B742E21",
        "21D1748412E247B72EDE7B8B1DED48B8212E747B121D47482E217B741D124847",
        "748421D147B712E27B8B2EDE48B81DED747B212E4748121D7B742E2148471D12",
        "1DED48B82EDE7B8B12E247B721D174841D1248472E217B74121D4748212E747B",
        "48B81DED7B8B2EDE47B712E2748421D148471D127B742E214748121D747B212E",
        "2EDE7B8B1DED48B821D1748412E247B72E217B741D124847212E747B121D4748",
        "7B8B2EDE48B81DED748421D147B712E27B742E2148471D12747B212E4748121D",
    ]

    /// Differenzielle Muster (Produkt benachbarter Trägerwerte) für S1/S2.
    static let patterns: [(s1: Int, s2: Int, diff: [Float])] = {
        func bits(_ hex: String) -> [Int] {
            hex.flatMap { ch -> [Int] in
                let v = Int(String(ch), radix: 16)!
                return (0..<4).map { (v >> (3 - $0)) & 1 }
            }
        }
        // Verwürfelung: PRBS 1 + x¹⁴ + x¹⁵, Start 100111001000110.
        var register = [1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0]
        var scrambler = [Float]()
        for _ in 0..<384 {
            let bit = register[13] ^ register[14]
            scrambler.append(bit == 0 ? 1 : -1)
            register.removeLast()
            register.insert(bit, at: 0)
        }
        var out: [(Int, Int, [Float])] = []
        for a in 0..<8 {
            for b in 0..<16 {
                let sequence = bits(s1[a]) + bits(s2[b]) + bits(s1[a])
                var value: Float = 1
                var modulated = [Float]()
                for bit in sequence {
                    if bit == 1 { value = -value }
                    modulated.append(value)
                }
                let scrambled = zip(modulated, scrambler).map(*)
                out.append((a, b, (1..<384).map { scrambled[$0] * scrambled[$0 - 1] }))
            }
        }
        return out
    }()

    private static let phasorRe: [Float] = (0..<1024).map { cos(-2 * Float.pi * Float($0) / 1024) }
    private static let phasorIm: [Float] = (0..<1024).map { sin(-2 * Float.pi * Float($0) / 1024) }

    struct Detection {
        var position: Int
        var metric: Float
    }

    /// Sucht P1-Kandidaten: Korrelation der frequenzverschobenen Teile C und B
    /// mit dem Hauptteil A. `positions` = gültige Startindizes.
    static func search(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, absoluteStart: Int) -> [Detection] {
        let length = count - 2048
        guard length > 0 else { return [] }
        // y·e^{-j2πn/1024} mit n absolut (die Phase muss nur innerhalb des Fensters stimmen).
        var shiftedRe = [Float](repeating: 0, count: count)
        var shiftedIm = shiftedRe
        for n in 0..<count {
            let index = (absoluteStart + n) & 1023
            let c = phasorRe[index], s = phasorIm[index]
            shiftedRe[n] = re[n] * c - im[n] * s
            shiftedIm[n] = re[n] * s + im[n] * c
        }
        // C ↔ A: yr[n]·conj(y[n+542]); B ↔ A: yr[n+1566]·conj(y[n+1084]).
        var cRe = 0.0, cIm = 0.0, bRe = 0.0, bIm = 0.0, power = 0.0
        func cTerm(_ n: Int) -> (Double, Double) {
            (Double(shiftedRe[n] * re[n + 542] + shiftedIm[n] * im[n + 542]),
             Double(shiftedIm[n] * re[n + 542] - shiftedRe[n] * im[n + 542]))
        }
        func bTerm(_ n: Int) -> (Double, Double) {
            let a = n + 1566, z = n + 1084
            return (Double(shiftedRe[a] * re[z] + shiftedIm[a] * im[z]), Double(shiftedIm[a] * re[z] - shiftedRe[a] * im[z]))
        }
        func energy(_ n: Int) -> Double { Double(re[n] * re[n] + im[n] * im[n]) }
        for n in 0..<542 { let t = cTerm(n); cRe += t.0; cIm += t.1 }
        for n in 0..<482 { let t = bTerm(n); bRe += t.0; bIm += t.1 }
        for n in 0..<2048 { power += energy(n) }
        var metric = [Float](repeating: 0, count: length)
        for n in 0..<length {
            metric[n] = Float((sqrt(cRe * cRe + cIm * cIm) + sqrt(bRe * bRe + bIm * bIm)) / max(power, 1e-9))
            guard n + 1 < length else { break }
            let c0 = cTerm(n), c1 = cTerm(n + 542)
            cRe += c1.0 - c0.0; cIm += c1.1 - c0.1
            let b0 = bTerm(n), b1 = bTerm(n + 482)
            bRe += b1.0 - b0.0; bIm += b1.1 - b0.1
            power += energy(n + 2048) - energy(n)
        }
        // Spitzen über 0,15 (theoretisch höchstens 0,5), mindestens 4096 Abtastwerte auseinander.
        var found: [Detection] = []
        var n = 0
        while n < length {
            if metric[n] > 0.15 {
                var best = n
                let end = min(length, n + 4096)
                for m in n..<end where metric[m] > metric[best] { best = m }
                found.append(Detection(position: best, metric: metric[best]))
                n = end
            } else {
                n += 1
            }
        }
        return found
    }

    /// S1, S2 und die ganzzahlige Ablage in 1K-Trägern aus dem Teil A.
    static func decode(re: UnsafePointer<Float>, im: UnsafePointer<Float>, at start: Int, fft: T2FFT) -> (s1: Int, s2: Int, shift: Int, quality: Float)? {
        var buffer = (0..<1024).map { re[start + 542 + $0] }
        var bufferIm = (0..<1024).map { im[start + 542 + $0] }
        fft.forward(&buffer, &bufferIm)
        func bin(_ k: Int) -> Int { (k - 426 + 1024 * 4) % 1024 }
        var bestShift = 0
        var bestEnergy: Float = -1
        for shift in -40...40 {
            var energy: Float = 0
            for k in carriers {
                let b = bin(k + shift)
                energy += buffer[b] * buffer[b] + bufferIm[b] * bufferIm[b]
            }
            if energy > bestEnergy { bestEnergy = energy; bestShift = shift }
        }
        var diffRe = [Float](repeating: 0, count: 383)
        for i in 1..<384 {
            let a = bin(carriers[i] + bestShift), b = bin(carriers[i - 1] + bestShift)
            diffRe[i - 1] = buffer[a] * buffer[b] + bufferIm[a] * bufferIm[b]
        }
        var best = (s1: 0, s2: 0, score: -Float.infinity), second = -Float.infinity
        for p in patterns {
            var score: Float = 0
            vDSP_dotpr(diffRe, 1, p.diff, 1, &score, 383)
            if score > best.score { second = best.score; best = (p.s1, p.s2, score) } else if score > second { second = score }
        }
        guard best.score > 0 else { return nil }
        return (best.s1, best.s2, bestShift, second > 0 ? best.score / second : 10)
    }
}

/// Komplexe FFT fester Größe (vDSP, Radix 2).
final class T2FFT: @unchecked Sendable {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ re: inout [Float], _ im: inout [Float]) { run(&re, &im, FFTDirection(kFFTDirection_Forward)) }
    func inverse(_ re: inout [Float], _ im: inout [Float]) { run(&re, &im, FFTDirection(kFFTDirection_Inverse)) }

    private func run(_ re: inout [Float], _ im: inout [Float], _ direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, direction)
            }
        }
    }
}
