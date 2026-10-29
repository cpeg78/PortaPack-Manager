import Foundation

/// Ressourcenelementgruppe (36.211 6.2.4): vier nutzbare REs eines Symbols.
struct LTEREG: Sendable, Hashable {
    var symbol: Int
    var k0: Int
    var k: [Int]
}

/// Steuerbereich: PCFICH, PHICH und die Verschachtelung des PDCCH.
struct LTEControlLayout: Sendable {
    let layout: LTECellLayout
    let ports: Int
    let cfi: Int
    /// Steuersymbole (CFI, bei ≤ 10 RB eins mehr).
    let controlSymbols: Int
    let pcfich: [LTEREG]
    let phich: [LTEREG]
    /// Quadrupel m (natürliche Reihenfolge, CCE n = 9n…9n+8) → REG.
    let pdcch: [LTEREG]

    var cceCount: Int { pdcch.count / 9 }

    init(layout: LTECellLayout, ports: Int, cfi: Int, phichExtended: Bool, phichResource: LTEMIB.PHICHResource) {
        self.layout = layout
        self.ports = ports
        self.cfi = cfi
        let symbols = layout.nRB <= 10 ? cfi + 1 : cfi
        controlSymbols = symbols
        let all = Self.regs(layout: layout, ports: ports, symbols: max(symbols, phichExtended ? 3 : 1))
        let pcfich = Self.pcfichREGs(layout: layout, in: all)
        self.pcfich = pcfich
        let phich = Self.phichREGs(layout: layout, all: all, pcfich: pcfich, extended: phichExtended, resource: phichResource)
        self.phich = phich
        let used = Set(pcfich).union(phich)
        let free = all.filter { $0.symbol < symbols && !used.contains($0) }
        pdcch = Self.interleave(free, pci: layout.pci)
    }

    /// Alle REGs der ersten `symbols` Symbole, sortiert nach (k0, Symbol).
    static func regs(layout: LTECellLayout, ports: Int, symbols: Int) -> [LTEREG] {
        let vo = layout.pci % 3
        var out: [LTEREG] = []
        for l in 0..<symbols {
            // Symbole mit CRS: 0 immer (Ports 0/1 angenommen), 1 bei vier Ports, 3 bei erweitertem CP.
            let withReference = l == 0 || (l == 1 && ports == 4) || (l == 3 && layout.extendedCP)
            for prb in 0..<layout.nRB {
                let base = 12 * prb
                if withReference {
                    for r in 0..<2 {
                        let k0 = base + 6 * r
                        let k = (0..<6).filter { $0 % 3 != vo }.map { k0 + $0 }
                        out.append(LTEREG(symbol: l, k0: k0, k: k))
                    }
                } else {
                    for r in 0..<3 {
                        let k0 = base + 4 * r
                        out.append(LTEREG(symbol: l, k0: k0, k: Array(k0..<(k0 + 4))))
                    }
                }
            }
        }
        return out.sorted { ($0.k0, $0.symbol) < ($1.k0, $1.symbol) }
    }

    static func pcfichREGs(layout: LTECellLayout, in all: [LTEREG]) -> [LTEREG] {
        let kBar = 6 * (layout.pci % (2 * layout.nRB))
        return (0..<4).compactMap { i in
            let k = (kBar + (i * layout.nRB / 2) * 6) % layout.nsc
            return all.first { $0.symbol == 0 && $0.k0 == k }
        }
    }

    static func phichREGs(layout: LTECellLayout, all: [LTEREG], pcfich: [LTEREG], extended: Bool,
                          resource: LTEMIB.PHICHResource) -> [LTEREG] {
        let used = Set(pcfich)
        let perSymbol = (0..<3).map { l in all.filter { $0.symbol == l && !used.contains($0) }.sorted { $0.k0 < $1.k0 } }
        let units = Int((resource.ng * Double(layout.nRB) / 8).rounded(.up))
        var out: [LTEREG] = []
        let n0 = perSymbol[0].count
        guard n0 > 0 else { return [] }
        for m in 0..<units {
            for i in 0..<3 {
                let l = extended ? i : 0
                let nl = perSymbol[l].count
                guard nl > 0 else { continue }
                let index = (layout.pci * nl / n0 + m + i * nl / 3) % nl
                out.append(perSymbol[l][index])
            }
        }
        return out
    }

    /// Quadrupel-Verschachtelung (Teilblock-Verschachteler, 32 Spalten) und
    /// zyklische Verschiebung um die Zellkennung (36.211 6.8.5).
    static func interleave(_ regs: [LTEREG], pci: Int) -> [LTEREG] {
        let m = regs.count
        guard m > 0 else { return [] }
        let rows = (m - 1) / 32 + 1
        let dummy = 32 * rows - m
        var out = regs
        var k = 0
        for j in 0..<32 {
            for i in 0..<rows {
                let position = i * 32 + LTERateMatching.permutation[j]
                guard position >= dummy else { continue }
                let natural = position - dummy
                let kp = ((k - pci) % m + m) % m
                out[natural] = regs[kp]
                k += 1
            }
        }
        return out
    }

    /// Weiche Bits der Quadrupel `regs` (Sendediversität je REG).
    static func softBits(_ regs: [LTEREG], grid: LTESubframeGrid, estimate: LTEChannelEstimate, ports: Int) -> [Float] {
        var r: [LTEC] = []
        var h = [[LTEC]](repeating: [], count: max(ports, 1))
        r.reserveCapacity(4 * regs.count)
        for reg in regs {
            for k in reg.k {
                r.append(grid.symbols[reg.symbol][k])
                for p in 0..<max(ports, 1) { h[p].append(estimate.h[p][reg.symbol][k]) }
            }
        }
        let (x, g) = LTETransmitDiversity.decode(r, h: h, ports: ports)
        return LTEQPSK.llr(x, gains: g, noise: estimate.noise)
    }
}

/// Physikalischer Kanal für das Steuerformat (36.211 6.7).
enum LTEPCFICH {
    /// Kodewörter für CFI 1…3 (36.212 Tabelle 5.3.4-1).
    static func codeword(_ cfi: Int) -> [UInt8] {
        let pattern: [UInt8] = [[0, 1, 1], [1, 0, 1], [1, 1, 0]][cfi - 1]
        return (0..<32).map { pattern[$0 % 3] }
    }

    static func scramblingInit(pci: Int, subframe: Int) -> UInt32 {
        UInt32((subframe + 1) * (2 * pci + 1) * 512 + pci)
    }

    /// Liefert CFI 1…3 und die Sicherheit (Abstand zum Zweitbesten, normiert).
    static func decode(grid: LTESubframeGrid, estimate: LTEChannelEstimate, ports: Int) -> (cfi: Int, confidence: Double) {
        let layout = grid.layout
        let all = LTEControlLayout.regs(layout: layout, ports: ports, symbols: 1)
        let regs = LTEControlLayout.pcfichREGs(layout: layout, in: all)
        var llr = LTEControlLayout.softBits(regs, grid: grid, estimate: estimate, ports: ports)
        LTESequence.descramble(&llr, cInit: scramblingInit(pci: layout.pci, subframe: grid.subframe))
        let scores = (1...3).map { cfi -> Double in
            zip(codeword(cfi), llr).reduce(0.0) { $0 + Double($1.0 == 0 ? $1.1 : -$1.1) }
        }
        let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        let sorted = scores.sorted(by: >)
        let total = llr.reduce(0.0) { $0 + Double(abs($1)) }
        return (best + 1, total > 0 ? (sorted[0] - sorted[1]) / total : 0)
    }
}

/// Abwärts-Steuerinformation für Systeminformation (SI-RNTI, Formate 1A/1C).
struct LTEDCI: Sendable, Equatable {
    enum Format: String, Sendable { case f1A = "1A", f1C = "1C" }

    var format: Format
    var distributed: Bool
    /// Lücke N_gap,2 statt N_gap,1 (nur ab 50 RB).
    var gap2: Bool
    var riv: Int
    var mcs: Int
    /// Redundanzversion aus dem DCI (nur 1A).
    var rv: Int?
    /// Spalte N_PRB^1A der TBS-Tabelle (2 oder 3, nur 1A).
    var nPRB1A: Int
    var cceStart = 0
    var aggregation = 4

    static let siRNTI: UInt32 = 0xFFFF

    static func rivBits(_ n: Int) -> Int {
        let x = n * (n + 1) / 2
        var bits = 0
        while (1 << bits) < x { bits += 1 }
        return bits
    }

    private static let ambiguous: Set<Int> = [12, 14, 16, 20, 24, 26, 32, 40, 44, 56]

    /// Größe von Format 1A (gleich Format 0) im gemeinsamen Suchraum, FDD.
    static func size1A(nRB: Int) -> Int {
        let n = 15 + rivBits(nRB)
        return ambiguous.contains(n) ? n + 1 : n
    }

    static func size1C(nRB: Int) -> Int {
        let step = LTEAllocation.rbStep(nRB)
        let vrb = LTEAllocation.vrbCount(nRB: nRB, gap2: false) / step
        return (nRB >= 50 ? 1 : 0) + rivBits(vrb) + 5
    }

    /// Liest die Felder (36.212 5.3.3.1.3/5.3.3.1.4) für SI-RNTI.
    static func parse(_ bits: [UInt8], format: Format, nRB: Int) -> LTEDCI? {
        var position = 0
        func take(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                v = (v << 1) | Int(bits[position])
                position += 1
            }
            return v
        }
        switch format {
        case .f1A:
            guard bits.count >= size1A(nRB: nRB), take(1) == 1 else { return nil }
            let distributed = take(1) == 1
            let riv = take(rivBits(nRB))
            let mcs = take(5)
            _ = take(3) // HARQ-Prozess (reserviert)
            let ndi = take(1)
            let rv = take(2)
            _ = take(1) // TPC-MSB reserviert
            let column = take(1) == 1 ? 3 : 2
            let gap2 = distributed && nRB >= 50 && ndi == 1
            return LTEDCI(format: .f1A, distributed: distributed, gap2: gap2, riv: riv, mcs: mcs, rv: rv, nPRB1A: column)
        case .f1C:
            guard bits.count >= size1C(nRB: nRB) else { return nil }
            let gap2 = nRB >= 50 ? take(1) == 1 : false
            // Feldbreite immer aus N_VRB mit N_gap,1 (36.212 5.3.3.1.4).
            let vrb = LTEAllocation.vrbCount(nRB: nRB, gap2: false) / LTEAllocation.rbStep(nRB)
            let riv = take(rivBits(vrb))
            let mcs = take(5)
            return LTEDCI(format: .f1C, distributed: true, gap2: gap2, riv: riv, mcs: mcs, rv: nil, nPRB1A: 2)
        }
    }

    /// Sendeseite (Prüfsender): Bits des DCI.
    func bits(nRB: Int) -> [UInt8] {
        var out: [UInt8] = []
        func put(_ value: Int, _ n: Int) {
            for i in (0..<n).reversed() { out.append(UInt8((value >> i) & 1)) }
        }
        switch format {
        case .f1A:
            put(1, 1)
            put(distributed ? 1 : 0, 1)
            put(riv, Self.rivBits(nRB))
            put(mcs, 5)
            put(0, 3)
            put(distributed && nRB >= 50 && gap2 ? 1 : 0, 1)
            put(rv ?? 0, 2)
            put(0, 1)
            put(nPRB1A == 3 ? 1 : 0, 1)
            while out.count < Self.size1A(nRB: nRB) { out.append(0) }
        case .f1C:
            if nRB >= 50 { put(gap2 ? 1 : 0, 1) }
            let vrb = LTEAllocation.vrbCount(nRB: nRB, gap2: false) / LTEAllocation.rbStep(nRB)
            put(riv, Self.rivBits(vrb))
            put(mcs, 5)
        }
        return out
    }
}

enum LTEPDCCH {
    static func scramblingInit(pci: Int, subframe: Int) -> UInt32 { UInt32(subframe * 512 + pci) }

    /// Kandidaten des gemeinsamen Suchraums: (erstes CCE, Aggregation).
    static func commonCandidates(cceCount: Int) -> [(start: Int, aggregation: Int)] {
        var out: [(Int, Int)] = []
        for (level, count) in [(4, 4), (8, 2)] {
            let slots = cceCount / level
            guard slots > 0 else { continue }
            for m in 0..<count {
                let start = level * (m % slots)
                if !out.contains(where: { $0.0 == start && $0.1 == level }) { out.append((start, level)) }
            }
        }
        return out
    }

    /// Blinddekodierung SI-RNTI im gemeinsamen Suchraum.
    static func searchSI(grid: LTESubframeGrid, estimate: LTEChannelEstimate, control: LTEControlLayout) -> LTEDCI? {
        let nRB = control.layout.nRB
        var llr = LTEControlLayout.softBits(control.pdcch, grid: grid, estimate: estimate, ports: control.ports)
        LTESequence.descramble(&llr, cInit: scramblingInit(pci: control.layout.pci, subframe: grid.subframe))
        for candidate in commonCandidates(cceCount: control.cceCount) {
            let from = 72 * candidate.start, to = 72 * (candidate.start + candidate.aggregation)
            guard to <= llr.count else { continue }
            let soft = Array(llr[from..<to])
            for format in [LTEDCI.Format.f1A, .f1C] {
                let size = format == .f1A ? LTEDCI.size1A(nRB: nRB) : LTEDCI.size1C(nRB: nRB)
                let d = LTERateMatching.convolutionalDematch(soft, k: size + 16)
                let bits = LTEConvolutional.decode(d)
                guard LTECRC.check(bits, poly: LTECRC.crc16, length: 16, mask: LTEDCI.siRNTI),
                      var dci = LTEDCI.parse(Array(bits[0..<size]), format: format, nRB: nRB) else { continue }
                // Zuteilung muss passen, sonst war es ein Zufallstreffer der CRC.
                guard LTEAllocation.prbs(for: dci, nRB: nRB) != nil, LTEAllocation.transportBlockSize(dci) != nil else { continue }
                dci.cceStart = candidate.start
                dci.aggregation = candidate.aggregation
                return dci
            }
        }
        return nil
    }
}
