import Foundation

// Betriebsarten von DVB-T2 (ETSI EN 302 755) – nur das T2-Base-Profil, SISO.

/// FFT-Größe; der Rohwert ist die Größe in K.
enum T2FFTSize: Int, Sendable, CaseIterable {
    case k1 = 1, k2 = 2, k4 = 4, k8 = 8, k16 = 16, k32 = 32

    var size: Int { rawValue * 1024 }
    var log2: Int { Int(Foundation.log2(Double(size))) }
    var name: String { "\(rawValue)K" }

    /// Höchster Trägerindex im normalen Trägermodus (Tabelle 66).
    var kmaxNormal: Int { [1: 852, 2: 1704, 4: 3408, 8: 6816, 16: 13632, 32: 27264][rawValue]! }
    /// Zusätzliche Träger je Seite im erweiterten Modus.
    var kext: Int { [8: 48, 16: 144, 32: 288][rawValue] ?? 0 }
    /// Anzahl der P2-Symbole (Tabelle 51).
    var p2Symbols: Int { [1: 16, 2: 8, 4: 4, 8: 2, 16: 1, 32: 1][rawValue]! }
    /// CP-Gruppen und Modulo für die Continual Pilots (Tabelle 61).
    var cpGroups: Int { [1: 1, 2: 2, 4: 3, 8: 4, 16: 5, 32: 6][rawValue]! }
    var cpModulo: Int? { [1: 1632, 2: 1632, 4: 3264, 8: 6528, 16: 13056][rawValue] }
    /// Amplitude der Continual Pilots (Tabelle 62).
    var continualPilotAmplitude: Float {
        switch self {
        case .k1, .k2: 4 / 3
        case .k4: 4 * Float(2).squareRoot() / 3
        default: 8 / 3
        }
    }

    /// P1-Feld S2 (obere 3 Bit) → FFT-Größe (Tabelle 19, T2-Base).
    static func from(s2: Int) -> T2FFTSize? {
        switch s2 >> 1 {
        case 0: .k2
        case 1, 6: .k8
        case 2: .k4
        case 3: .k1
        case 4: .k16
        case 5, 7: .k32
        default: nil
        }
    }
}

/// Schutzintervall; Rohwert wie im L1-pre-Feld GUARD_INTERVAL.
enum T2GuardInterval: Int, Sendable, CaseIterable {
    case g1_32 = 0, g1_16 = 1, g1_8 = 2, g1_4 = 3, g1_128 = 4, g19_128 = 5, g19_256 = 6

    var fraction: (num: Int, den: Int) {
        switch self {
        case .g1_32: (1, 32)
        case .g1_16: (1, 16)
        case .g1_8: (1, 8)
        case .g1_4: (1, 4)
        case .g1_128: (1, 128)
        case .g19_128: (19, 128)
        case .g19_256: (19, 256)
        }
    }

    func samples(_ fft: T2FFTSize) -> Int { fft.size * fraction.num / fraction.den }
    var name: String { "\(fraction.num)/\(fraction.den)" }
}

/// Streupilotmuster PP1…PP8; Rohwert wie im L1-pre-Feld PILOT_PATTERN.
enum T2PilotPattern: Int, Sendable, CaseIterable {
    case pp1 = 0, pp2, pp3, pp4, pp5, pp6, pp7, pp8

    var number: Int { rawValue + 1 }
    var name: String { "PP\(number)" }
    /// Trägerabstand der pilottragenden Träger und Symbolperiode (Tabelle 57).
    var dx: Int { [3, 6, 6, 12, 12, 24, 24, 6][rawValue] }
    var dy: Int { [4, 2, 4, 2, 4, 2, 4, 16][rawValue] }
    /// Amplitude der Streupiloten (Tabelle 60).
    var amplitude: Float {
        switch self {
        case .pp1, .pp2: 4 / 3
        case .pp3, .pp4: 7 / 4
        default: 7 / 3
        }
    }

    /// Gibt es ein Abschlusssymbol? (Tabelle 64 – gleichbedeutend mit
    /// Dx·Dy ≥ 1/Schutzintervall, nie bei PP8.)
    func usesFrameClosing(_ gi: T2GuardInterval) -> Bool {
        guard self != .pp8 else { return false }
        return dx * dy * gi.fraction.num >= gi.fraction.den
    }

    /// Aktive Zellen im Abschlusssymbol C_FC (Tabelle 50, ohne Tone Reservation).
    func activeFrameClosingCells(_ fft: T2FFTSize, extended: Bool) -> Int? {
        let normal: [Int: [Int?]] = [
            1: [402, 654, 490, 707, 544, nil, nil, nil],
            2: [804, 1309, 980, 1415, 1088, nil, 1396, nil],
            4: [1609, 2619, 1961, 2831, 2177, nil, 2792, nil],
            8: [3218, 5238, 3922, 5662, 4354, nil, 5585, nil],
            16: [6437, 10476, 7845, 11324, 8709, 11801, 11170, nil],
            32: [nil, 20952, nil, 22649, nil, 23603, nil, nil],
        ]
        let ext: [Int: [Int?]] = [
            8: [3264, 5312, 3978, 5742, 4416, nil, 5664, nil],
            16: [6573, 10697, 8011, 11563, 8893, 12051, 11406, nil],
            32: [nil, 21395, nil, 23127, nil, 24102, nil, nil],
        ]
        return (extended ? ext : normal)[fft.rawValue]?[rawValue] ?? nil
    }
}

/// Modulation; Rohwert wie PLP_MOD (L1_MOD zählt ab BPSK, siehe `l1Post`).
enum T2Modulation: Int, Sendable {
    case qpsk = 0, qam16, qam64, qam256

    var bitsPerCell: Int { [2, 4, 6, 8][rawValue] }
    var name: String { ["QPSK", "16-QAM", "64-QAM", "256-QAM"][rawValue] }
    /// Drehwinkel bei PLP_ROTATION (Tabelle 16).
    var rotation: Double {
        switch self {
        case .qpsk: 29.0
        case .qam16: 16.8
        case .qam64: 8.6
        case .qam256: atan(1.0 / 16) * 180 / .pi
        }
    }
}

/// Coderate; die Rohwerte entsprechen PLP_COD (T2-Base), 1/4 kommt nur bei L1-pre vor.
enum T2CodeRate: Int, Sendable {
    case r1_2 = 0, r3_5, r2_3, r3_4, r4_5, r5_6
    case r1_3 = 6, r2_5 = 7, r1_4 = 8

    var name: String {
        switch self {
        case .r1_2: "1/2"
        case .r3_5: "3/5"
        case .r2_3: "2/3"
        case .r3_4: "3/4"
        case .r4_5: "4/5"
        case .r5_6: "5/6"
        case .r1_3: "1/3"
        case .r2_5: "2/5"
        case .r1_4: "1/4"
        }
    }
}

/// Eine FEC-Konfiguration: LDPC-Länge und Coderate (Tabellen 6 und 8).
struct T2FEC: Sendable, Hashable {
    var normal: Bool          // 64 800 statt 16 200
    var rate: T2CodeRate

    var nldpc: Int { normal ? 64_800 : 16_200 }
    var kldpc: Int {
        if normal {
            return [T2CodeRate.r1_2: 32_400, .r3_5: 38_880, .r2_3: 43_200, .r3_4: 48_600, .r4_5: 51_840, .r5_6: 54_000][rate]!
        }
        return [T2CodeRate.r1_4: 3240, .r1_2: 7200, .r3_5: 9720, .r2_3: 10_800, .r3_4: 11_880,
                .r4_5: 12_600, .r5_6: 13_320, .r1_3: 5400, .r2_5: 6480][rate]!
    }
    /// BCH-Paritätsbits: t = 12 bzw. 10 (normal) und immer 12 (kurz).
    var bchParity: Int {
        guard normal else { return 168 }
        return rate == .r2_3 || rate == .r5_6 ? 160 : 192
    }
    var kbch: Int { kldpc - bchParity }
    var q: Int { (nldpc - kldpc) / 360 }
}
