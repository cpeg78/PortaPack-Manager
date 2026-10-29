import Foundation

/// Ressourcenzuteilung Typ 2 und Transportblockgröße (36.211 6.2.3, 36.213 7.1.6/7.1.7).
enum LTEAllocation {
    /// RBG-Größe P (36.213 Tabelle 7.1.6.1-1).
    static func rbgSize(_ nRB: Int) -> Int { nRB <= 10 ? 1 : nRB <= 26 ? 2 : nRB <= 63 ? 3 : 4 }

    /// N_step für Format 1C (36.213 Tabelle 7.1.6.3-1).
    static func rbStep(_ nRB: Int) -> Int { nRB < 50 ? 2 : 4 }

    /// N_gap (36.211 Tabelle 6.2.3.2-1).
    static func gap(nRB: Int, gap2: Bool) -> Int {
        switch nRB {
        case ...10: (nRB + 1) / 2
        case 11: 4
        case 12...19: 8
        case 20...26: 12
        case 27...44: 18
        case 45...49: 27
        case 50...63: gap2 ? 9 : 27
        case 64...79: gap2 ? 16 : 32
        default: gap2 ? 16 : 48
        }
    }

    /// N_VRB^DL für verteilte Zuteilung.
    static func vrbCount(nRB: Int, gap2: Bool) -> Int {
        let g = gap(nRB: nRB, gap2: gap2 && nRB >= 50)
        return gap2 && nRB >= 50 ? (nRB / (2 * g)) * 2 * g : 2 * min(g, nRB - g)
    }

    /// RIV → (Start, Länge); `n` ist die Bezugsgröße, `limit` die Höchstzahl VRBs.
    static func decodeRIV(_ riv: Int, n: Int, limit: Int) -> (start: Int, length: Int) {
        var length = riv / n + 1
        var start = riv % n
        if length > limit - start {
            length = n - riv / n + 1
            start = n - riv % n - 1
        }
        return (start, length)
    }

    static func encodeRIV(start: Int, length: Int, n: Int) -> Int {
        (length - 1) <= n / 2 ? n * (length - 1) + start : n * (n - length + 1) + (n - 1 - start)
    }

    /// VRB → PRB für verteilte Zuteilung (36.211 6.2.3.2), je Slot.
    static func distributedPRB(_ vrb: Int, nRB: Int, gap2: Bool) -> (slot0: Int, slot1: Int) {
        let g2 = gap2 && nRB >= 50
        let nGap = gap(nRB: nRB, gap2: g2)
        let tildeN = g2 ? 2 * nGap : vrbCount(nRB: nRB, gap2: false)
        let p = rbgSize(nRB)
        let rows = Int((Double(tildeN) / Double(4 * p)).rounded(.up)) * p
        let nulls = 4 * rows - tildeN
        let tilde = vrb % tildeN
        let block = tildeN * (vrb / tildeN)
        let prime = 2 * rows * (tilde % 2) + tilde / 2 + block
        let second = rows * (tilde % 4) + tilde / 4 + block
        let even: Int
        if nulls != 0, tilde >= tildeN - nulls, tilde % 2 == 1 {
            even = prime - rows
        } else if nulls != 0, tilde >= tildeN - nulls, tilde % 2 == 0 {
            even = prime - rows + nulls / 2
        } else if nulls != 0, tilde < tildeN - nulls, tilde % 4 >= 2 {
            even = second - nulls / 2
        } else {
            even = second
        }
        let odd = (even + tildeN / 2) % tildeN + block
        func place(_ x: Int) -> Int { x < tildeN / 2 ? x : x + nGap - tildeN / 2 }
        return (place(even), place(odd))
    }

    /// Zugeteilte PRBs je Slot (aufsteigend) oder `nil`, wenn die Zuteilung nicht passt.
    static func prbs(for dci: LTEDCI, nRB: Int) -> (slot0: [Int], slot1: [Int])? {
        var start: Int, length: Int
        switch dci.format {
        case .f1A:
            let limit = dci.distributed ? vrbCount(nRB: nRB, gap2: dci.gap2) : nRB
            guard dci.riv < nRB * (nRB + 1) / 2 else { return nil }
            (start, length) = decodeRIV(dci.riv, n: nRB, limit: limit)
            guard start >= 0, length >= 1, start + length <= limit else { return nil }
        case .f1C:
            let step = rbStep(nRB)
            let vrb = vrbCount(nRB: nRB, gap2: dci.gap2) / step
            guard vrb > 0, dci.riv < vrb * (vrb + 1) / 2 else { return nil }
            (start, length) = decodeRIV(dci.riv, n: vrb, limit: vrb)
            guard start >= 0, length >= 1, start + length <= vrb else { return nil }
            start *= step
            length *= step
        }
        if !dci.distributed {
            let list = Array(start..<(start + length))
            guard list.allSatisfy({ $0 < nRB }) else { return nil }
            return (list, list)
        }
        var s0: [Int] = [], s1: [Int] = []
        for v in start..<(start + length) {
            let (a, b) = distributedPRB(v, nRB: nRB, gap2: dci.gap2)
            guard a < nRB, b < nRB, a >= 0, b >= 0 else { return nil }
            s0.append(a)
            s1.append(b)
        }
        return (s0.sorted(), s1.sorted())
    }

    /// TBS-Tabelle 7.1.7.2.1-1, Spalten N_PRB = 2 und 3, I_TBS 0…26.
    static let tbsColumn2 = [32, 56, 72, 104, 120, 144, 176, 224, 256, 296, 328, 376, 440, 488, 552, 600, 632, 696, 776,
                             840, 904, 1000, 1064, 1128, 1192, 1256, 1480]
    static let tbsColumn3 = [56, 88, 144, 176, 208, 224, 256, 328, 392, 456, 504, 584, 680, 744, 840, 904, 968, 1064,
                             1160, 1288, 1384, 1480, 1608, 1736, 1800, 1864, 2216]
    /// Format 1C (Tabelle 7.1.7.2.3-1).
    static let tbs1C = [40, 56, 72, 120, 136, 144, 176, 208, 224, 256, 280, 296, 328, 336, 392, 488, 552, 600, 632, 696,
                        776, 840, 904, 1000, 1064, 1128, 1224, 1288, 1384, 1480, 1608, 1736]

    static func transportBlockSize(_ dci: LTEDCI) -> Int? {
        switch dci.format {
        case .f1A:
            guard dci.mcs < tbsColumn2.count else { return nil }
            return dci.nPRB1A == 3 ? tbsColumn3[dci.mcs] : tbsColumn2[dci.mcs]
        case .f1C:
            return dci.mcs < tbs1C.count ? tbs1C[dci.mcs] : nil
        }
    }

    /// Redundanzversion für SIB1 bei Format 1C (36.321 5.3.1): k = (SFN/2) mod 4.
    static func sib1RV(sfn: Int) -> Int {
        let k = (sfn / 2) % 4
        return Int((1.5 * Double(k)).rounded(.up)) % 4
    }
}

/// Gemeinsamer Abwärtskanal: REs, Verwürfelung, Transportblock.
enum LTEPDSCH {
    /// REs eines Teilrahmens in Abbildungsreihenfolge (k über die PRBs, dann l; FDD).
    static func resourceElements(layout: LTECellLayout, ports: Int, controlSymbols: Int, prbs: (slot0: [Int], slot1: [Int]),
                                 subframe: Int) -> [(symbol: Int, k: Int)] {
        let n = layout.symbolsPerSlot
        let center = layout.nsc / 2
        var out: [(Int, Int)] = []
        for symbol in controlSymbols..<(2 * n) {
            let slot = symbol / n, l = symbol % n
            let list = slot == 0 ? prbs.slot0 : prbs.slot1
            // PSS/SSS (Teilrahmen 0/5, Slot 0, letzte zwei Symbole) und PBCH (Teilrahmen 0, Slot 1, l 0…3)
            let syncSymbol = (subframe == 0 || subframe == 5) && slot == 0 && l >= n - 2
            let pbchSymbol = subframe == 0 && slot == 1 && l < 4
            for prb in list {
                for k in (12 * prb)..<(12 * prb + 12) {
                    if (syncSymbol || pbchSymbol), k >= center - 36, k < center + 36 { continue }
                    if LTECRS.isReference(symbol: symbol, k: k, ports: ports, layout: layout) { continue }
                    out.append((symbol, k))
                }
            }
        }
        return out
    }

    static func scramblingInit(rnti: UInt32, subframe: Int, pci: Int) -> UInt32 {
        (rnti << 14) + UInt32(subframe * 512 + pci)
    }

    /// Weiche, entwürfelte Bits des PDSCH.
    static func softBits(grid: LTESubframeGrid, estimate: LTEChannelEstimate, ports: Int,
                         elements: [(symbol: Int, k: Int)], rnti: UInt32) -> [Float] {
        let usable = ports == 4 ? elements.count / 4 * 4 : ports == 2 ? elements.count / 2 * 2 : elements.count
        let res = Array(elements[0..<usable])
        let r = res.map { grid.symbols[$0.symbol][$0.k] }
        let h = (0..<max(ports, 1)).map { p in res.map { estimate.h[p][$0.symbol][$0.k] } }
        let (x, g) = LTETransmitDiversity.decode(r, h: h, ports: ports)
        var llr = LTEQPSK.llr(x, gains: g, noise: estimate.noise)
        LTESequence.descramble(&llr, cInit: scramblingInit(rnti: rnti, subframe: grid.subframe, pci: grid.layout.pci))
        return llr
    }

    /// Kodierparameter eines Transportblocks mit einem Kodeblock (≤ 6120 Bit).
    struct BlockLayout: Sendable, Equatable {
        var tbs: Int
        var k: Int
        var filler: Int
        var d: Int { k + 4 }

        init?(tbs: Int) {
            guard let k = LTETurbo.blockSize(for: tbs + 24), tbs + 24 <= 6144 else { return nil }
            self.tbs = tbs
            self.k = k
            filler = k - tbs - 24
        }
    }

    /// Versucht den Transportblock aus dem (kombinierten) Puffer zu dekodieren.
    static func decode(buffer: [Float], layout: BlockLayout) -> [UInt8]? {
        let d = layout.d
        var streams = (0..<3).map { Array(buffer[($0 * d)..<($0 * d + d)]) }
        for i in 0..<layout.filler {
            streams[0][i] = 30
            streams[1][i] = 30
        }
        guard let bits = LTETurbo.decode(streams, k: layout.k, accept: { bits in
            LTECRC.check(Array(bits[layout.filler...]), poly: LTECRC.crc24A, length: 24)
        }) else { return nil }
        return Array(bits[layout.filler..<(layout.filler + layout.tbs)])
    }

    /// Sendeseite (Prüfsender): Transportblock → kodierte Bits für `count` Plätze.
    static func encode(_ tb: [UInt8], count: Int, rv: Int) -> [UInt8]? {
        guard let block = BlockLayout(tbs: tb.count) else { return nil }
        let c = [UInt8](repeating: 0, count: block.filler) + LTECRC.attach(tb, poly: LTECRC.crc24A, length: 24)
        let d = LTETurbo.encode(c)
        return LTERateMatching.turboEncode(d, count: count, rv: rv, filler: block.filler)
    }
}
