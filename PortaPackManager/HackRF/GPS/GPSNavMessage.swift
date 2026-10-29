import Foundation

/// Konstanten nach IS-GPS-200 (Werte wie RTKLIB `rtklib.h`/`ephemeris.c`).
enum GPSConst {
    static let c = 299_792_458.0                 // Lichtgeschwindigkeit, m/s
    static let l1 = 1_575_420_000.0               // Hz
    static let chipRate = 1_023_000.0             // Chips/s
    static let mu = 3.986005e14                   // m³/s², WGS-84 nach IS-GPS-200
    static let omegaE = 7.2921151467e-5           // Erddrehrate, rad/s
    static let pi = 3.1415926535898               // GPS-π für Halbkreise
    static let relativisticF = -4.442807633e-10   // s/√m
    static let weekSeconds = 604_800.0
    static var wavelength: Double { c / l1 }
}

/// Wortparität der Navigationsnachricht (IS-GPS-200, 20.3.5.2, Tabelle 20-XIV).
///
/// Darstellung wie RTKLIB `decode_word`: Bit 31 = D29*, Bit 30 = D30* (die
/// beiden letzten Bits des Vorgängerworts), Bits 29…0 = D1…D30. Ist D30*
/// gesetzt, sind die 24 Datenbits invertiert gesendet. Daraus folgt auch,
/// dass ein komplett invertierter Bitstrom (180°-Mehrdeutigkeit des Costas-
/// Loops) dieselben Daten liefert – die Polarität klärt sich von selbst.
enum GPSParity {
    /// Je Paritätsbit D25…D30 die Maske über D29*, D30*, d1…d24.
    static let masks: [UInt32] = [0xBB1F_3480, 0x5D8F_9A40, 0xAEC7_CD00, 0x5763_E680, 0x6BB1_F340, 0x8B7A_89C0]

    /// Prüft ein Wort; liefert die 24 Datenbits d1…d24 (d1 = höchstes Bit) oder nil.
    static func decode(_ word: UInt32) -> UInt32? {
        var w = word
        if w & 0x4000_0000 != 0 { w ^= 0x3FFF_FFC0 }
        if parity(w) != w & 0x3F { return nil }
        return (w >> 6) & 0xFF_FFFF
    }

    /// Sechs Paritätsbits zu (D29*, D30*, d1…d24) – Eingabe wie `decode` nach dem Rückdrehen.
    private static func parity(_ w: UInt32) -> UInt32 {
        var p: UInt32 = 0
        for m in masks {
            p = p << 1 | UInt32((w & m).nonzeroBitCount & 1)
        }
        return p
    }

    /// Sendewort (30 Bits, D1…D30) zu 24 Datenbits und den beiden Vorgängerbits.
    static func encode(data: UInt32, prevD29: UInt32, prevD30: UInt32) -> UInt32 {
        let d = data & 0xFF_FFFF
        let p = parity(prevD29 << 31 | prevD30 << 30 | d << 6)
        let sent = prevD30 == 1 ? d ^ 0xFF_FFFF : d
        return sent << 6 | p
    }

    /// Wie `encode`, wählt aber die Bits d23/d24 („t“) so, dass D29 = D30 = 0
    /// (Pflicht für Wort 2 und 10, damit das nächste Wort nicht invertiert ist).
    static func encodeZeroTail(data: UInt32, prevD29: UInt32, prevD30: UInt32) -> UInt32 {
        for t: UInt32 in 0..<4 {
            let w = encode(data: (data & 0xFF_FFFC) | t, prevD29: prevD29, prevD30: prevD30)
            if w & 3 == 0 { return w }
        }
        return encode(data: data, prevD29: prevD29, prevD30: prevD30)
    }
}

/// Ein dekodierter Subframe: 10 Wörter à 24 Datenbits (ohne Parität).
struct GPSSubframe: Sendable, Equatable {
    /// d1…d24 je Wort, Wort 1 (TLM) zuerst.
    let words: [UInt32]

    var id: Int { Int(bitsU(43, 3)) }
    /// Abgeschnittener Z-Zähler: Beginn des **nächsten** Subframes in 6-s-Schritten.
    var towCount: Int { Int(bitsU(24, 17)) }

    /// Vorzeichenlose Bits ab Position `pos` (0-basiert über die 240 Datenbits,
    /// wie RTKLIB `getbitu` auf der paritätsfreien Darstellung).
    func bitsU(_ pos: Int, _ len: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in pos..<(pos + len) {
            let word = words[i / 24]
            let bit = (word >> UInt32(23 - i % 24)) & 1
            v = v << 1 | UInt64(bit)
        }
        return v
    }

    /// Zweierkomplement-Bits (RTKLIB `getbits`).
    func bitsS(_ pos: Int, _ len: Int) -> Int64 {
        let u = bitsU(pos, len)
        if u & (1 << UInt64(len - 1)) != 0 { return Int64(bitPattern: u) - (1 << Int64(len)) }
        return Int64(u)
    }
}

/// Satelliten-Ephemeride aus den Subframes 1–3 (Winkel in Radiant).
struct GPSEphemeris: Sendable, Equatable, Codable {
    var prn: Int
    var weekNumber: Int          // 10-Bit-Wochennummer, wie gesendet
    var uraIndex: Int
    var health: Int
    var iodc: Int
    var iode: Int
    var tgd: Double
    var toc: Double
    var af0: Double, af1: Double, af2: Double
    var crs: Double, deltaN: Double, m0: Double
    var cuc: Double, e: Double, cus: Double, sqrtA: Double, toe: Double
    var cic: Double, omega0: Double, cis: Double, i0: Double, crc: Double
    var omega: Double, omegaDot: Double, idot: Double

    /// Liest die Ephemeride wie RTKLIB `decode_subfrm1/2/3`. nil, wenn IODE/IODC
    /// der drei Subframes nicht zusammenpassen (Ephemeridenwechsel dazwischen).
    init?(prn: Int, sf1: GPSSubframe, sf2: GPSSubframe, sf3: GPSSubframe) {
        let p2 = { (n: Int) in pow(2.0, Double(n)) }
        let sc = GPSConst.pi
        self.prn = prn
        weekNumber = Int(sf1.bitsU(48, 10))
        uraIndex = Int(sf1.bitsU(60, 4))
        health = Int(sf1.bitsU(64, 6))
        let iodcHigh = Int(sf1.bitsU(70, 2))
        let tgdRaw = sf1.bitsS(160, 8)
        tgd = tgdRaw == -128 ? 0 : Double(tgdRaw) * p2(-31)
        iodc = iodcHigh << 8 | Int(sf1.bitsU(168, 8))
        toc = Double(sf1.bitsU(176, 16)) * 16
        af2 = Double(sf1.bitsS(192, 8)) * p2(-55)
        af1 = Double(sf1.bitsS(200, 16)) * p2(-43)
        af0 = Double(sf1.bitsS(216, 22)) * p2(-31)

        iode = Int(sf2.bitsU(48, 8))
        crs = Double(sf2.bitsS(56, 16)) * p2(-5)
        deltaN = Double(sf2.bitsS(72, 16)) * p2(-43) * sc
        m0 = Double(sf2.bitsS(88, 32)) * p2(-31) * sc
        cuc = Double(sf2.bitsS(120, 16)) * p2(-29)
        e = Double(sf2.bitsU(136, 32)) * p2(-33)
        cus = Double(sf2.bitsS(168, 16)) * p2(-29)
        sqrtA = Double(sf2.bitsU(184, 32)) * p2(-19)
        toe = Double(sf2.bitsU(216, 16)) * 16

        cic = Double(sf3.bitsS(48, 16)) * p2(-29)
        omega0 = Double(sf3.bitsS(64, 32)) * p2(-31) * sc
        cis = Double(sf3.bitsS(96, 16)) * p2(-29)
        i0 = Double(sf3.bitsS(112, 32)) * p2(-31) * sc
        crc = Double(sf3.bitsS(144, 16)) * p2(-5)
        omega = Double(sf3.bitsS(160, 32)) * p2(-31) * sc
        omegaDot = Double(sf3.bitsS(192, 24)) * p2(-43) * sc
        let iode3 = Int(sf3.bitsU(216, 8))
        idot = Double(sf3.bitsS(224, 14)) * p2(-43) * sc

        guard sf1.id == 1, sf2.id == 2, sf3.id == 3, iode3 == iode, iode == iodc & 0xFF else { return nil }
    }

    /// Für Tests und den Signalgenerator: alle Felder direkt.
    init(prn: Int, weekNumber: Int, uraIndex: Int = 0, health: Int = 0, iodc: Int, iode: Int,
         tgd: Double, toc: Double, af0: Double, af1: Double, af2: Double,
         crs: Double, deltaN: Double, m0: Double, cuc: Double, e: Double, cus: Double,
         sqrtA: Double, toe: Double, cic: Double, omega0: Double, cis: Double, i0: Double,
         crc: Double, omega: Double, omegaDot: Double, idot: Double) {
        self.prn = prn; self.weekNumber = weekNumber; self.uraIndex = uraIndex; self.health = health
        self.iodc = iodc; self.iode = iode; self.tgd = tgd; self.toc = toc
        self.af0 = af0; self.af1 = af1; self.af2 = af2
        self.crs = crs; self.deltaN = deltaN; self.m0 = m0; self.cuc = cuc; self.e = e
        self.cus = cus; self.sqrtA = sqrtA; self.toe = toe; self.cic = cic; self.omega0 = omega0
        self.cis = cis; self.i0 = i0; self.crc = crc; self.omega = omega
        self.omegaDot = omegaDot; self.idot = idot
    }
}

/// Ionosphären- (Klobuchar) und UTC-Parameter aus Subframe 4, Seite 18.
struct GPSIonoUTC: Sendable, Equatable {
    var alpha: [Double]
    var beta: [Double]
    var a0: Double, a1: Double
    var tot: Double, wnt: Int
    var leapSeconds: Int

    /// nil, wenn der Subframe nicht Seite 18 (SV-ID 56) ist.
    init?(sf4: GPSSubframe) {
        guard sf4.id == 4, sf4.bitsU(48, 2) == 1, sf4.bitsU(50, 6) == 56 else { return nil }
        let p2 = { (n: Int) in pow(2.0, Double(n)) }
        alpha = [Double(sf4.bitsS(56, 8)) * p2(-30), Double(sf4.bitsS(64, 8)) * p2(-27),
                 Double(sf4.bitsS(72, 8)) * p2(-24), Double(sf4.bitsS(80, 8)) * p2(-24)]
        beta = [Double(sf4.bitsS(88, 8)) * p2(11), Double(sf4.bitsS(96, 8)) * p2(14),
                Double(sf4.bitsS(104, 8)) * p2(16), Double(sf4.bitsS(112, 8)) * p2(16)]
        a1 = Double(sf4.bitsS(120, 24)) * p2(-50)
        a0 = Double(sf4.bitsS(144, 32)) * p2(-30)
        tot = Double(sf4.bitsU(176, 8)) * p2(12)
        wnt = Int(sf4.bitsU(184, 8))
        leapSeconds = Int(sf4.bitsS(192, 8))
    }

    init(alpha: [Double], beta: [Double], leapSeconds: Int = 18) {
        self.alpha = alpha; self.beta = beta
        a0 = 0; a1 = 0; tot = 0; wnt = 0
        self.leapSeconds = leapSeconds
    }
}

/// Rahmensynchronisation und Subframe-Dekodierung aus dem 50-bit/s-Bitstrom
/// eines Kanals.
struct GPSNavDecoder {
    enum Event: Equatable {
        /// Sendezeit (Sekunde der Woche) des Beginns des Subframes, der mit
        /// der Codeperiode `epoch` beginnt.
        case timing(towStart: Double, epoch: Int)
        case subframe(GPSSubframe)
    }

    static let preamble: UInt32 = 0x8B

    private var bits: [UInt32] = []      // 0/1, wie empfangen (Polarität offen)
    private var epochs: [Int] = []
    private var base = 0                  // absoluter Index von bits[0]
    private var syncStart: Int?           // absoluter Index des laufenden Subframes
    private var failures = 0

    var isSynchronized: Bool { syncStart != nil }

    mutating func reset() {
        bits.removeAll(); epochs.removeAll(); base = 0; syncStart = nil; failures = 0
    }

    /// Nimmt ein Bit (Beginn in Codeperiode `epoch`) entgegen.
    mutating func push(bit: Bool, epoch: Int) -> [Event] {
        bits.append(bit ? 1 : 0)
        epochs.append(epoch)
        var events: [Event] = []
        let count = base + bits.count

        if let start = syncStart {
            if count >= start + 300 {
                if let sf = decodeSubframe(at: start) {
                    events.append(.timing(towStart: Self.subframeStart(sf.towCount), epoch: epochOf(start)))
                    events.append(.subframe(sf))
                    failures = 0
                } else {
                    failures += 1
                }
                syncStart = failures >= 2 ? nil : start + 300
            }
        } else if count >= 62 {
            // Kandidat: Präambel 60 Bit vor dem Ende (TLM + HOW vollständig).
            let k = count - 60
            if let how = checkHeader(at: k) {
                syncStart = k
                failures = 0
                events.append(.timing(towStart: Self.subframeStart(Int((how >> 7) & 0x1FFFF)), epoch: epochOf(k)))
            }
        }

        // Puffer kurz halten (reicht für einen Subframe plus Vorlauf).
        if bits.count > 700 {
            let drop = bits.count - 400
            bits.removeFirst(drop); epochs.removeFirst(drop); base += drop
        }
        return events
    }

    /// Sekunde der Woche zu Beginn eines Subframes, dessen HOW `towCount` trägt.
    static func subframeStart(_ towCount: Int) -> Double {
        var t = Double(towCount) * 6 - 6
        if t < 0 { t += GPSConst.weekSeconds }
        return t
    }

    private func bit(_ abs: Int) -> UInt32 { bits[abs - base] }
    private func epochOf(_ abs: Int) -> Int { epochs[abs - base] }

    /// 30-Bit-Wort ab `abs` samt D29*/D30* davor, im Format von `GPSParity.decode`.
    private func rawWord(at abs: Int) -> UInt32? {
        guard abs - 2 >= base, abs + 30 <= base + bits.count else { return nil }
        var w: UInt32 = 0
        for i in (abs - 2)..<(abs + 30) { w = w << 1 | bit(i) }
        return w
    }

    /// Präambel und Parität von TLM und HOW; liefert die HOW-Daten.
    private func checkHeader(at k: Int) -> UInt32? {
        var raw: UInt32 = 0
        for i in k..<(k + 8) { raw = raw << 1 | bit(i) }
        guard raw == Self.preamble || raw == (~Self.preamble & 0xFF) else { return nil }
        guard let w1 = rawWord(at: k).flatMap(GPSParity.decode),
              let w2 = rawWord(at: k + 30).flatMap(GPSParity.decode),
              w1 >> 16 == Self.preamble else { return nil }
        let id = (w2 >> 2) & 7
        guard (1...5).contains(id), (w2 >> 7) & 0x1FFFF < 100_800 else { return nil }
        return w2
    }

    private func decodeSubframe(at k: Int) -> GPSSubframe? {
        guard checkHeader(at: k) != nil else { return nil }
        var words: [UInt32] = []
        for n in 0..<10 {
            guard let raw = rawWord(at: k + 30 * n), let d = GPSParity.decode(raw) else { return nil }
            words.append(d)
        }
        return GPSSubframe(words: words)
    }
}
