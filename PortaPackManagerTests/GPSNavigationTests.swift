import Testing
@testable import PortaPackManager

@Suite("GPS-Navigationsnachricht")
struct GPSNavigationTests {

    /// Testvektoren aus `computeChecksum` von gps-sdr-sim (eigenständige
    /// Implementierung): Eingang D29*, D30*, d1…d24; Ausgang D1…D30.
    static let vectors: [(source: UInt32, sent: UInt32)] = [
        (0x22C0_0000, 0x22C0_0012),
        (0x62C4_8D00, 0x1D3B_72DD),
        (0x848D_1580, 0x048D_15A8),
        (0xEAF3_7BC0, 0x150C_8419),
    ]

    @Test("Wortparität trifft die Testvektoren")
    func paritaetTestvektoren() {
        for v in Self.vectors {
            let d29 = v.source >> 31, d30 = (v.source >> 30) & 1
            let data = (v.source >> 6) & 0xFF_FFFF
            #expect(GPSParity.encode(data: data, prevD29: d29, prevD30: d30) == v.sent)
            #expect(GPSParity.decode(v.source & 0xC000_0000 | v.sent) == data)
            // Ein gekipptes Bit muss auffallen.
            for bit in 0..<30 {
                #expect(GPSParity.decode(v.source & 0xC000_0000 | (v.sent ^ (1 << UInt32(bit)))) == nil)
            }
        }
    }

    /// Masken gegen die Gleichungen aus IS-GPS-200, Tabelle 20-XIV.
    @Test("Paritätsmasken entsprechen IS-GPS-200 Tabelle 20-XIV")
    func paritaetsGleichungen() {
        let equations: [(star: Int, bits: [Int])] = [
            (29, [1, 2, 3, 5, 6, 10, 11, 12, 13, 14, 17, 18, 20, 23]),
            (30, [2, 3, 4, 6, 7, 11, 12, 13, 14, 15, 18, 19, 21, 24]),
            (29, [1, 3, 4, 5, 7, 8, 12, 13, 14, 15, 16, 19, 20, 22]),
            (30, [2, 4, 5, 6, 8, 9, 13, 14, 15, 16, 17, 20, 21, 23]),
            (30, [1, 3, 5, 6, 7, 9, 10, 14, 15, 16, 17, 18, 21, 22, 24]),
            (29, [3, 5, 6, 8, 9, 10, 11, 13, 15, 19, 22, 23, 24]),
        ]
        for (mask, eq) in zip(GPSParity.masks, equations) {
            var expected: UInt32 = eq.star == 29 ? 1 << 31 : 1 << 30
            for d in eq.bits { expected |= 1 << UInt32(30 - d) }
            #expect(mask == expected)
        }
    }

    @Test("Wort 2/10: t-Bits erzwingen D29 = D30 = 0")
    func nullEnde() {
        for d29: UInt32 in 0...1 {
            for d30: UInt32 in 0...1 {
                let w = GPSParity.encodeZeroTail(data: 0x5A_5A50, prevD29: d29, prevD30: d30)
                #expect(w & 3 == 0)
                #expect(GPSParity.decode(d29 << 31 | d30 << 30 | w) != nil)
            }
        }
    }

    @Test("Ephemeride übersteht Kodieren und Dekodieren")
    func ephemerideRundreise() {
        let eph = GPSTestConstellation.ephemeris(prn: 7, toe: 345_600, week: 2440)
        let s = (1...3).map { GPSSubframe(words: GPSNavBuilder.subframe(id: $0, towCount: 57_600, eph: eph)) }
        let back = GPSEphemeris(prn: 7, sf1: s[0], sf2: s[1], sf3: s[2])
        #expect(back == eph)
        #expect(s[0].towCount == 57_600)
        #expect(s[1].id == 2)
        // Abweichende IODE (Ephemeridenwechsel) wird abgelehnt.
        var other = eph
        other.iode = 99; other.iodc = 99
        let s3 = GPSSubframe(words: GPSNavBuilder.subframe(id: 3, towCount: 1, eph: other))
        #expect(GPSEphemeris(prn: 7, sf1: s[0], sf2: s[1], sf3: s3) == nil)
    }

    @Test("Ionosphäre und Schaltsekunden aus Subframe 4, Seite 18")
    func ionosphaere() {
        // Werte aus brdc0010.22n (ION ALPHA/BETA, 18 Schaltsekunden).
        let ion = GPSIonoUTC(alpha: [0.1211e-7, -0.7451e-8, -0.5960e-7, 0.1192e-6],
                             beta: [0.1167e6, -0.2458e6, -0.6554e5, 0.1114e7], leapSeconds: 18)
        let eph = GPSTestConstellation.ephemeris(prn: 1, toe: 0, week: 0)
        let sf = GPSSubframe(words: GPSNavBuilder.subframe(id: 4, towCount: 3, eph: eph, iono: ion))
        let back = GPSIonoUTC(sf4: sf)
        #expect(back != nil)
        #expect(back?.leapSeconds == 18)
        for k in 0..<4 {
            #expect(abs(back!.alpha[k] - ion.alpha[k]) < 1e-9)
            #expect(abs(back!.beta[k] - ion.beta[k]) / ion.beta[k].magnitude < 0.02)
        }
    }

    @Test("Rahmensynchronisation – auch bei invertiertem Bitstrom")
    func rahmenSync() {
        let eph = GPSTestConstellation.ephemeris(prn: 3, toe: 0, week: 0)
        let frames = (0..<6).map { k in
            GPSNavBuilder.subframe(id: k % 5 + 1, towCount: 1000 + k, eph: eph)
        }
        let bits = GPSNavBuilder.encode(frames)
        for invert in [false, true] {
            var decoder = GPSNavDecoder()
            var timings: [(Double, Int)] = []
            var subframes: [GPSSubframe] = []
            // Ab Bit 137 einsteigen: mitten im ersten Subframe.
            for (i, b) in bits.enumerated() where i >= 137 {
                for e in decoder.push(bit: (b == 1) != invert, epoch: i * 20) {
                    switch e {
                    case .timing(let tow, let epoch): timings.append((tow, epoch))
                    case .subframe(let sf): subframes.append(sf)
                    }
                }
            }
            #expect(subframes.map(\.id) == [2, 3, 4, 5, 1])
            // Wörter 3–9 unverändert (in Wort 2 und 10 setzt der Sender die t-Bits).
            #expect(subframes.first?.words[2..<9] == frames[1][2..<9])
            // Subframe k beginnt bei Bit 300·k zur Zeit (1000 + k − 1)·6.
            #expect(timings.first.map { $0.0 } == Double(1000) * 6)
            #expect(timings.first.map { $0.1 } == 300 * 20)
        }
    }
}
