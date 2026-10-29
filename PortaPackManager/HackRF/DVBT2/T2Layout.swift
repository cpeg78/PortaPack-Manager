import Foundation

/// Trägerbelegung eines T2-Signals: welche Träger Piloten sind, welche Daten
/// tragen und in welcher Reihenfolge (Abschnitte 8.5, 9.2–9.4).
struct T2Layout: Sendable {
    let fft: T2FFTSize
    let guardInterval: T2GuardInterval
    let pattern: T2PilotPattern
    let extended: Bool
    let toneReservation: Bool
    let dataSymbols: Int

    let kmax: Int
    /// Datenträger (aufsteigend) im P2-Symbol.
    let p2Carriers: [Int]
    /// Pilotträger im P2-Symbol (nur die mit k mod 3 = 0, für die Kanalschätzung).
    let p2Pilots: [Int]
    /// Datenträger je Datensymbol, nach Symbolklasse (siehe `dataCarriers(symbol:)`).
    private let normalCarriers: [[Int]]
    let frameClosingCarriers: [Int]
    /// Gibt es ein Abschlusssymbol, und wie viele seiner Zellen sind moduliert?
    let frameClosing: Bool
    let frameClosingActive: Int
    /// Continual Pilots eines normalen Datensymbols.
    let continualPilots: [Int]

    init?(fft: T2FFTSize, guardInterval: T2GuardInterval, pattern: T2PilotPattern,
          extended: Bool, toneReservation: Bool, dataSymbols: Int) {
        // NUM_DATA_SYMBOLS kommt aus dem L1-pre: unter 3 Datensymbolen greift die
        // Phasenkorrektur auf Symbol −1 zu, und die Norm erlaubt höchstens 250 ms
        // je Rahmen – sonst fordert ein gefälschtes L1-pre mehrere GB Puffer an.
        let maxFrameSamples = Int(Self.maxFrameDuration * T2FrontEnd.outputRate)
        guard dataSymbols >= 3,
              2048 + (fft.p2Symbols + dataSymbols) * (fft.size + guardInterval.samples(fft)) <= maxFrameSamples
        else { return nil }
        self.fft = fft
        self.guardInterval = guardInterval
        self.pattern = pattern
        self.extended = extended && fft.kext > 0
        self.toneReservation = toneReservation
        self.dataSymbols = dataSymbols
        let kext = self.extended ? fft.kext : 0
        let kmax = fft.kmaxNormal + 2 * kext
        self.kmax = kmax

        // P2: Piloten bei k mod 3 = 0 (32K: mod 6), im erweiterten Modus auch die Ränder.
        let p2Step = fft == .k32 ? 6 : 3
        var p2Mask = [Bool](repeating: false, count: kmax + 1)
        for k in stride(from: 0, through: kmax, by: p2Step) { p2Mask[k] = true }
        if kext > 0 {
            for k in 0..<kext { p2Mask[k] = true; p2Mask[kmax - k] = true }
        }
        p2Pilots = Array(stride(from: 0, through: kmax, by: p2Step))
        let p2Reserved = Set(T2Tables.p2ReservedCarriers(fftK: fft.rawValue).map { $0 + kext })
        p2Carriers = (0...kmax).filter { !p2Mask[$0] && !p2Reserved.contains($0) }

        // Continual Pilots: Gruppen CP1…CPn, k = k32 mod Kmod, dazu die Erweiterung.
        var cps = Set<Int>()
        let groups = T2Tables.continualPilotGroups(pattern: pattern.number)
        for group in groups.prefix(fft.cpGroups) {
            for k in group { cps.insert(fft.cpModulo.map { k % $0 } ?? k) }
        }
        if self.extended {
            cps.formUnion(T2Tables.extendedContinualPilots(pattern: pattern.number, fftK: fft.rawValue))
        }
        continualPilots = cps.filter { $0 <= kmax }.sorted()

        // Datensymbole: Streupiloten wandern mit l mod Dy, Tone Reservation mit Dx·(l mod Dy).
        let reserved = T2Tables.dataReservedCarriers(fftK: fft.rawValue)
        var classes: [[Int]] = []
        for phase in 0..<pattern.dy {
            var mask = [Bool](repeating: false, count: kmax + 1)
            let step = pattern.dx * pattern.dy
            for k in 0...kmax where ((k - kext) % step + step) % step == pattern.dx * phase {
                mask[k] = true
            }
            for k in continualPilots { mask[k] = true }
            mask[0] = true
            mask[kmax] = true
            if toneReservation {
                for i in reserved {
                    let k = i + pattern.dx * phase + kext
                    if k <= kmax { mask[k] = true }
                }
            }
            classes.append((0...kmax).filter { !mask[$0] })
        }
        normalCarriers = classes

        frameClosing = pattern.usesFrameClosing(guardInterval)
        var fcMask = [Bool](repeating: false, count: kmax + 1)
        for k in stride(from: 0, through: kmax, by: pattern.dx) { fcMask[k] = true }
        fcMask[0] = true
        fcMask[kmax] = true
        if toneReservation { for k in p2Reserved where k <= kmax { fcMask[k] = true } }
        frameClosingCarriers = (0...kmax).filter { !fcMask[$0] }
        let tr = toneReservation ? T2Tables.dataReservedCarriers(fftK: fft.rawValue).count : 0
        if frameClosing {
            guard let active = pattern.activeFrameClosingCells(fft, extended: self.extended) else { return nil }
            frameClosingActive = active - tr
        } else {
            frameClosingActive = 0
        }
    }

    /// Höchste Rahmendauer laut EN 302 755 (T_F ≤ 250 ms).
    static let maxFrameDuration = 0.25

    var symbolsPerFrame: Int { fft.p2Symbols + dataSymbols }
    var symbolSamples: Int { fft.size + guardInterval.samples(fft) }
    /// Abstand zweier P1-Anfänge (ohne FEF).
    var frameSamples: Int { 2048 + symbolsPerFrame * symbolSamples }
    var cellsPerSymbol: Int { normalCarriers[0].count }

    /// Symbolindex l (P2 = 0 …) → Art des Symbols.
    func isFrameClosing(_ l: Int) -> Bool { frameClosing && l == symbolsPerFrame - 1 }

    func dataCarriers(symbol l: Int) -> [Int] {
        if l < fft.p2Symbols { return p2Carriers }
        if isFrameClosing(l) { return frameClosingCarriers }
        return normalCarriers[l % pattern.dy]
    }

    /// Streupiloten eines Datensymbols (inklusive Rand), bzw. die FC-Piloten.
    func scatteredPilots(symbol l: Int) -> [Int] {
        let kext = extended ? fft.kext : 0
        if isFrameClosing(l) { return Array(stride(from: 0, through: kmax, by: pattern.dx)) + (kmax % pattern.dx == 0 ? [] : [kmax]) }
        let step = pattern.dx * pattern.dy
        let offset = ((pattern.dx * (l % pattern.dy) + kext) % step + step) % step
        var list = Array(stride(from: offset, through: kmax, by: step))
        if list.first != 0 { list.insert(0, at: 0) }
        if list.last != kmax { list.append(kmax) }
        return list
    }

    /// Zellen, die das PLP-Adressschema (8.3.6.2) je Symbol zählt.
    func activeCells(symbol l: Int, l1Cells: Int) -> Int {
        if l < fft.p2Symbols { return p2Carriers.count - l1Cells / fft.p2Symbols }
        if isFrameClosing(l) { return frameClosingActive }
        return cellsPerSymbol
    }
}

// MARK: - Bezugsfolgen (9.2.2)

enum T2Reference {
    /// Symbolfolge w_k: PRBS x¹¹ + x² + 1, Register mit Einsen geladen.
    static let prbs: [UInt8] = {
        var register = [UInt8](repeating: 1, count: 11)
        var out = [UInt8](repeating: 0, count: 32_768 + 600)
        for i in 0..<out.count {
            out[i] = register[10]
            let bit = register[10] ^ register[8]
            register.removeLast()
            register.insert(bit, at: 0)
        }
        return out
    }()

    /// Rahmenfolge pn_l (Tabelle 56).
    static let frameSequence: [UInt8] = {
        let hex = "4DC2AF7BD8C3C9A1E76C9A090AF1C3114F07FCA2808E9462E9AD7B712D6F4AC8A59BB069CC50BF1149927E6B"
            + "B1C9FC8C18BB949B30CD09DDD749E704F57B41DEC7E7B176E12C5657432B51B0B812DF0E14887E24D80C97F09"
            + "374AD76270E58FE1774B2781D8D3821E393F2EA0FFD4D24DE20C05D0BA1703D10E52D61E013D837AA62D007CC"
            + "2FD76D23A3E125BDE8A9A7C02A98B70251C556F6341EBDECB801AAD5D9FB8CBEA80BB619096527A8C475B3D8"
            + "DB28AF8543A00EC3480DFF1E2CDA9F985B523B879007AA5D0CE58D21B18631006617F6F769EB947F924EA5161E"
            + "C2C0488B63ED7993BA8EF4E552FA32FC3F1BDB19923902BCBBE5DDABB824126E08459CA6CFA0267E5294A98C6"
            + "32569791E60EF659AEE9518CDF08D87833690C1B79183ED127E53360CD86514859A28B5494F51AA4882419A25A2"
            + "D01A5F47AA27301E79A5370CCB3E197F"
        return hex.flatMap { ch -> [UInt8] in
            let v = Int(String(ch), radix: 16)!
            return (0..<4).map { UInt8((v >> (3 - $0)) & 1) }
        }
    }()

    /// Pilotvorzeichen (+1/−1) für Träger k in Symbol l.
    @inline(__always)
    static func sign(symbol l: Int, carrier k: Int, layout: T2Layout) -> Float {
        let offset = layout.extended ? 0 : layout.fft.kext
        return (prbs[k + offset] ^ frameSequence[l]) == 0 ? 1 : -1
    }

    /// BB-Verwürfelung (5.2.4) und Dummy-Zellen: PRBS 1 + x¹⁴ + x¹⁵, Start 100101010000000.
    static func scramblingSequence(_ count: Int) -> [UInt8] {
        var register: [UInt8] = [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0]
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let bit = register[13] ^ register[14]
            out[i] = bit
            register.removeLast()
            register.insert(bit, at: 0)
        }
        return out
    }
}

// MARK: - Interleaver-Adressen

enum T2Interleavers {
    /// Frequenz-Interleaver (8.5): Permutation H0/H1 (bzw. H bei 32K) für `count` Datenzellen.
    static func frequency(_ fft: T2FFTSize, count: Int, odd: Bool) -> [Int32] {
        let nr = fft.log2
        let taps: [Int]
        let permutation: [Int]   // R'-Bit (höchstes zuerst) → R-Bit
        switch fft {
        case .k1: taps = [0, 4]; permutation = odd ? [3, 2, 5, 0, 1, 4, 7, 8, 6] : [4, 3, 2, 1, 0, 5, 6, 7, 8]
        case .k2: taps = [0, 3]; permutation = odd ? [3, 2, 7, 0, 1, 5, 8, 4, 9, 6] : [0, 7, 5, 1, 8, 2, 6, 9, 3, 4]
        case .k4: taps = [0, 2]; permutation = odd ? [6, 2, 7, 10, 8, 0, 3, 4, 1, 9, 5] : [7, 10, 5, 8, 1, 2, 4, 9, 0, 3, 6]
        case .k8: taps = [0, 1, 4, 6]; permutation = odd ? [8, 10, 7, 6, 0, 5, 2, 1, 3, 9, 4, 11] : [5, 11, 3, 0, 10, 8, 6, 9, 2, 4, 1, 7]
        case .k16: taps = [0, 1, 4, 5, 9, 11]; permutation = odd ? [7, 9, 5, 3, 11, 1, 4, 0, 2, 12, 10, 8, 6] : [8, 4, 3, 2, 0, 11, 1, 5, 12, 10, 6, 7, 9]
        case .k32: taps = [0, 1, 2, 12]; permutation = [6, 5, 0, 10, 8, 1, 11, 12, 2, 9, 4, 3, 13, 7]
        }
        let bits = nr - 1
        var h = [Int32]()
        h.reserveCapacity(count)
        var r = 0
        for i in 0..<(1 << nr) {
            if i < 2 { r = 0 } else if i == 2 { r = 1 } else {
                var bit = 0
                for t in taps { bit ^= (r >> t) & 1 }
                r = (r >> 1) | (bit << (bits - 1))
            }
            var value = 0
            for (index, target) in permutation.enumerated() where (r >> (bits - 1 - index)) & 1 == 1 {
                value |= 1 << target
            }
            value += (i & 1) << bits
            if value < count { h.append(Int32(value)) }
        }
        // 32K: gerade Symbole verwenden die Umkehrung (a_H(p) = x_p).
        if fft == .k32 && !odd {
            var inverse = [Int32](repeating: 0, count: count)
            for (p, value) in h.enumerated() { inverse[Int(value)] = Int32(p) }
            return inverse
        }
        return h
    }

    /// Grundpermutation L0(q) des Zell-Interleavers (6.4).
    static func cellBase(cells: Int) -> [Int32] {
        let nd = Int(ceil(log2(Double(cells))))
        let taps: [Int] = [11: [0, 3], 12: [0, 2], 13: [0, 1, 4, 6], 14: [0, 1, 4, 5, 9, 11], 15: [0, 1, 2, 12]][nd]!
        var out = [Int32]()
        out.reserveCapacity(cells)
        var s = 0
        for i in 0..<(1 << nd) {
            if i < 2 { s = 0 } else if i == 2 { s = 1 } else {
                var bit = 0
                for t in taps { bit ^= (s >> t) & 1 }
                s = (s >> 1) | (bit << (nd - 2))
            }
            let value = s | ((i & 1) << (nd - 1))
            if value < cells { out.append(Int32(value)) }
        }
        return out
    }

    /// Verschiebungen P(r) für die FEC-Blöcke eines TI-Blocks.
    static func cellShifts(cells: Int, blocks: Int) -> [Int] {
        let nd = Int(ceil(log2(Double(cells))))
        var out: [Int] = []
        var k = 0
        for _ in 0..<blocks {
            var p = cells
            while p >= cells {
                var reversed = 0
                for j in 0..<nd where (k >> j) & 1 == 1 { reversed |= 1 << (nd - 1 - j) }
                p = reversed
                k += 1
            }
            out.append(p)
        }
        return out
    }
}
