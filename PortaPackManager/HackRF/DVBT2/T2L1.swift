import Foundation

/// L1-pre-Signalling (7.2.2).
struct T2L1Pre: Sendable, Equatable {
    var type = 0
    var extendedCarriers = false
    var s1 = 0
    var s2 = 0
    var repetition = false
    var guardInterval = 0
    var papr = 0
    var l1Modulation = 0
    var l1CodeRate = 0
    var l1FECType = 0
    var l1PostSize = 0
    var l1PostInfoSize = 0
    var pilotPattern = 0
    var txIDAvailability = 0
    var cellID = 0
    var networkID = 0
    var systemID = 0
    var t2Frames = 0
    var dataSymbols = 0
    var regenFlag = 0
    var postExtension = false
    var rfCount = 0
    var currentRF = 0
    var version = 0
    var postScrambled = false
    var baseLite = false

    init() {}

    init(bits: [UInt8]) {
        var r = T2BitReader(bits)
        type = r.read(8); extendedCarriers = r.flag(); s1 = r.read(3); s2 = r.read(4)
        repetition = r.flag(); guardInterval = r.read(3); papr = r.read(4)
        l1Modulation = r.read(4); l1CodeRate = r.read(2); l1FECType = r.read(2)
        l1PostSize = r.read(18); l1PostInfoSize = r.read(18); pilotPattern = r.read(4)
        txIDAvailability = r.read(8); cellID = r.read(16); networkID = r.read(16)
        systemID = r.read(16); t2Frames = r.read(8); dataSymbols = r.read(12)
        regenFlag = r.read(3); postExtension = r.flag(); rfCount = r.read(3)
        currentRF = r.read(3); version = r.read(4); postScrambled = r.flag(); baseLite = r.flag()
    }

    /// Tone Reservation in Datensymbolen?
    var toneReservation: Bool { papr == 2 || papr == 3 }
}

/// Ein PLP aus dem konfigurierbaren und dynamischen L1-post (7.2.3).
struct T2PLP: Sendable, Equatable, Identifiable {
    var id = 0
    var type = 0                 // 0 gemeinsam, 1 Typ 1, 2 Typ 2
    var payloadType = 0          // 3 = TS
    var firstFrame = 0
    var groupID = 0
    var codeRate = 0
    var modulation = 0
    var rotation = false
    var fecType = 0              // 0 = 16K, 1 = 64K
    var blocksMax = 0
    var frameInterval = 1
    var timeInterleavingLength = 0
    var timeInterleavingType = 0
    var inBandA = false
    var inBandB = false
    var mode = 0                 // 1 NM, 2 HEM
    var staticFlag = false
    var staticPadding = false
    // dynamisch
    var start = 0
    var blocks = 0

    var fec: T2FEC? {
        guard let rate = T2CodeRate(rawValue: codeRate), fecType <= 1 else { return nil }
        return T2FEC(normal: fecType == 1, rate: rate)
    }
    var constellation: T2Modulation? { T2Modulation(rawValue: modulation) }
}

/// L1-post (konfigurierbarer und dynamischer Teil).
struct T2L1Post: Sendable, Equatable {
    var subSlicesPerFrame = 1
    var frequencies: [Int] = []
    var plps: [T2PLP] = []
    var auxiliaryStreams = 0
    var frameIndex = 0
    var subSliceInterval = 0
    var type2Start = 0
    var changeCounter = 0

    init() {}

    init?(bits: [UInt8], pre: T2L1Pre) {
        var r = T2BitReader(bits)
        subSlicesPerFrame = r.read(15)
        let plpCount = r.read(8)
        auxiliaryStreams = r.read(4)
        _ = r.read(8)
        for _ in 0..<pre.rfCount {
            _ = r.read(3)
            frequencies.append(r.read(32))
        }
        if pre.s2 & 1 == 1 { _ = r.read(4 + 22 + 8) }
        for _ in 0..<plpCount {
            var p = T2PLP()
            p.id = r.read(8); p.type = r.read(3); p.payloadType = r.read(5)
            _ = r.read(1 + 3)
            p.firstFrame = r.read(8); p.groupID = r.read(8)
            p.codeRate = r.read(3); p.modulation = r.read(3); p.rotation = r.flag()
            p.fecType = r.read(2); p.blocksMax = r.read(10); p.frameInterval = r.read(8)
            p.timeInterleavingLength = r.read(8); p.timeInterleavingType = r.read(1)
            p.inBandA = r.flag(); p.inBandB = r.flag(); _ = r.read(11)
            p.mode = r.read(2); p.staticFlag = r.flag(); p.staticPadding = r.flag()
            plps.append(p)
        }
        _ = r.read(2 + 30)
        for _ in 0..<auxiliaryStreams { _ = r.read(4 + 28) }
        // dynamisch
        frameIndex = r.read(8); subSliceInterval = r.read(22); type2Start = r.read(22)
        changeCounter = r.read(8); _ = r.read(3 + 8)
        for i in 0..<plpCount {
            let id = r.read(8)
            let start = r.read(22), blocks = r.read(10)
            _ = r.read(8)
            if plps[i].id == id {
                plps[i].start = start
                plps[i].blocks = blocks
            }
        }
        guard !r.overrun else { return nil }
    }
}

struct T2BitReader {
    private let bits: [UInt8]
    private(set) var position = 0
    private(set) var overrun = false

    init(_ bits: [UInt8]) { self.bits = bits }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            value <<= 1
            if position < bits.count { value |= Int(bits[position]) } else { overrun = true }
            position += 1
        }
        return value
    }

    mutating func flag() -> Bool { read(1) == 1 }
}

// MARK: - CRC

enum T2CRC {
    /// CRC-32 (Anhang F): Polynom 0x04C11DB7, Start mit Einsen, MSB zuerst.
    /// Über Daten samt angehängter CRC ergibt sich 0.
    static func crc32Valid(_ bits: ArraySlice<UInt8>) -> Bool {
        var crc: UInt32 = 0xFFFF_FFFF
        for bit in bits {
            let top = (crc >> 31) & 1
            crc <<= 1
            if top ^ UInt32(bit) == 1 { crc ^= 0x04C1_1DB7 }
        }
        return crc == 0
    }

    /// CRC-8 des BBHEADER (Polynom x⁸+x⁷+x⁶+x⁴+x²+1, Start 0).
    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            for i in (0..<8).reversed() {
                let bit = (byte >> UInt8(i)) & 1
                let top = crc >> 7
                crc <<= 1
                if top ^ bit == 1 { crc ^= 0xD5 }
            }
        }
        return crc
    }
}

// MARK: - Dekodierung

/// Liest L1-pre und L1-post aus den entzerrten Zellen der P2-Symbole.
enum T2L1Decoder {
    static let preCells = 1840

    /// `cells[l]` und `weights[l]`: Datenzellen (nach Frequenz-Deinterleaving)
    /// und |H|²/N0 je P2-Symbol l.
    static func decodePre(re: [[Float]], im: [[Float]], weights: [[Float]]) -> T2L1Pre? {
        let np2 = re.count
        let needed = np2 > 0 ? (preCells + np2 - 1) / np2 : 0
        guard np2 > 0, weights.count >= np2,
              (0..<np2).allSatisfy({ re[$0].count >= needed && weights[$0].count >= needed }) else { return nil }
        // Zickzack: Zelle p des L1-pre liegt in Symbol p mod NP2, Index p / NP2.
        var llr = [Float](repeating: 0, count: preCells)
        for p in 0..<preCells {
            let l = p % np2, index = p / np2
            llr[p] = 4 * re[l][index] * weights[l][index]
        }
        let fec = T2FEC(normal: false, rate: .r1_4)
        guard let info = decodeBlock(llr, ksig: 200, fec: fec, npost: preCells,
                                     shortening: [7, 3, 6, 5, 2, 4, 1, 8, 0],
                                     puncturing: [27, 13, 29, 32, 5, 0, 11, 21, 33, 20, 25, 28, 18, 35, 8, 3, 9, 31,
                                                  22, 24, 7, 14, 17, 4, 2, 26, 16, 34, 19, 10, 12, 23, 1, 6, 30, 15],
                                     scrambled: false),
              T2CRC.crc32Valid(info[...]) else { return nil }
        return T2L1Pre(bits: info)
    }

    static func decodePost(re: [[Float]], im: [[Float]], weights: [[Float]], pre: T2L1Pre) -> T2L1Post? {
        let np2 = re.count
        guard np2 > 0, im.count >= np2, weights.count >= np2 else { return nil }
        let eta = [1, 2, 4, 6][max(0, min(3, pre.l1Modulation))]
        let postCells = pre.l1PostSize
        let start = preCells / np2
        var cr = [Float](repeating: 0, count: postCells), ci = cr, cw = cr
        for p in 0..<postCells {
            let l = p % np2, index = start + p / np2
            guard index < re[l].count, index < im[l].count, index < weights[l].count else { return nil }
            cr[p] = re[l][index]; ci[p] = im[l][index]; cw[p] = weights[l][index]
        }
        let kExPad = pre.l1PostInfoSize + 32
        let blocks = (kExPad + 7031) / 7032
        let kPost = (kExPad + blocks - 1) / blocks * blocks
        let ksig = kPost / blocks
        let cellsPerBlock = postCells / blocks
        let npost = cellsPerBlock * eta
        let shortening: [Int]
        let puncturing: [Int]
        switch eta {
        case 4:
            shortening = [18, 17, 16, 15, 14, 13, 12, 11, 4, 10, 9, 8, 7, 3, 2, 1, 6, 5, 19, 0]
            puncturing = [6, 4, 13, 9, 18, 8, 15, 20, 5, 17, 2, 22, 24, 7, 12, 1, 16, 23, 14, 0, 21, 10, 19, 11, 3]
        case 6:
            shortening = [18, 17, 16, 4, 15, 14, 13, 12, 3, 11, 10, 9, 2, 8, 7, 1, 6, 5, 19, 0]
            puncturing = [6, 15, 13, 10, 3, 17, 21, 8, 5, 19, 2, 23, 16, 24, 7, 18, 1, 12, 20, 0, 4, 14, 9, 11, 22]
        default:
            shortening = [18, 17, 16, 15, 14, 13, 12, 11, 4, 10, 9, 8, 3, 2, 7, 6, 5, 1, 19, 0]
            puncturing = [6, 4, 18, 9, 13, 8, 15, 20, 5, 17, 2, 24, 10, 22, 12, 3, 16, 23, 1, 14, 0, 21, 19, 7, 11]
        }
        let fec = T2FEC(normal: false, rate: .r1_2)
        var info: [UInt8] = []
        for b in 0..<blocks {
            let range = (b * cellsPerBlock)..<((b + 1) * cellsPerBlock)
            let bits = postLLR(re: Array(cr[range]), im: Array(ci[range]), weights: Array(cw[range]), eta: eta)
            guard let part = decodeBlock(bits, ksig: ksig, fec: fec, npost: npost, shortening: shortening,
                                         puncturing: puncturing, scrambled: pre.postScrambled) else { return nil }
            info += part
        }
        let payload = info.prefix(kExPad)
        guard T2CRC.crc32Valid(payload) else { return nil }
        return T2L1Post(bits: Array(payload.prefix(pre.l1PostInfoSize)), pre: pre)
    }

    /// Zellen → LLR in Kodewort-Übertragungsreihenfolge (vor Bitverschachtelung).
    private static func postLLR(re: [Float], im: [Float], weights: [Float], eta: Int) -> [Float] {
        let count = re.count
        if eta == 1 { return (0..<count).map { 4 * re[$0] * weights[$0] } }
        // Zellen → Bits je Zelle (y0 … y_η-1), wie bei den Daten.
        let modulation: T2Modulation = eta == 2 ? .qpsk : (eta == 4 ? .qam16 : .qam64)
        let norm = T2BitMapper.norm(modulation)
        let scale = norm.squareRoot()
        var cellBits = [Float](repeating: 0, count: count * eta)
        for q in 0..<count {
            let w = 4 * weights[q] / norm
            var x = re[q] * scale, y = im[q] * scale
            let perAxis = eta / 2
            var half = Float(1 << perAxis) / 2
            cellBits[q * eta] = x * w
            cellBits[q * eta + 1] = y * w
            for i in 1..<max(1, perAxis) {
                x = abs(x) - half; y = abs(y) - half
                cellBits[q * eta + 2 * i] = x * w
                cellBits[q * eta + 2 * i + 1] = y * w
                half /= 2
            }
        }
        if eta == 2 { return cellBits }
        // Demultiplexer (Tabelle 13a) rückwärts, dann Blockverschachtelung (Spalten schreiben, Zeilen lesen).
        let demux = eta == 4 ? [7, 1, 4, 2, 5, 3, 6, 0] : [11, 7, 3, 10, 6, 2, 9, 5, 1, 8, 4, 0]
        let substreams = demux.count
        let n = count * eta
        var v = [Float](repeating: 0, count: n)
        for d in 0..<(n / substreams) {
            for index in 0..<substreams {
                let e = demux[index]
                let cell = 2 * d + (e < eta ? 0 : 1)
                v[d * substreams + index] = cellBits[cell * eta + e % eta]
            }
        }
        let nc = substreams, nr = n / nc
        var out = [Float](repeating: 0, count: n)
        for j in 0..<n {
            let r = j / nc, c = j % nc
            out[c * nr + r] = v[j]
        }
        return out
    }

    /// Verkürzten und punktierten 16K-Block dekodieren (7.3.2): LLR der
    /// übertragenen Bits → Infobits (`ksig`), oder nil.
    private static func decodeBlock(_ received: [Float], ksig: Int, fec: T2FEC, npost: Int,
                                    shortening: [Int], puncturing: [Int], scrambled: Bool) -> [UInt8]? {
        let kbch = fec.kbch, kldpc = fec.kldpc, n = fec.nldpc
        let groups = kldpc / 360
        // BCH-Infopositionen je Gruppe; die letzte Gruppe hat nur 360 − (Kldpc − Kbch) Bits.
        func groupSize(_ g: Int) -> Int { g == groups - 1 ? 360 - (kldpc - kbch) : 360 }
        // Größen stammen aus dem L1-pre (nur CRC-gesichert, also fälschbar):
        // alle Tabellen- und Feldzugriffe vorher prüfen.
        guard ksig > 0, ksig <= kbch, received.count >= ksig + (kldpc - kbch) else { return nil }
        var padded = [Bool](repeating: false, count: kbch)
        let npad = ksig < 360 ? groups - 1 : (kbch - ksig) / 360
        let extra = npad == groups - 1 ? 360 - ksig : kbch - ksig - 360 * npad
        guard npad >= 0, npad + (extra > 0 ? 1 : 0) <= shortening.count,
              shortening.allSatisfy({ (0..<groups).contains($0) }) else { return nil }
        for i in 0..<npad {
            let g = shortening[i]
            for j in 0..<groupSize(g) { padded[g * 360 + j] = true }
        }
        if extra > 0 {
            let g = shortening[npad]
            let size = groupSize(g)
            for j in max(0, size - extra)..<size { padded[g * 360 + j] = true }
        }
        let infoPositions = (0..<kbch).filter { !padded[$0] }
        guard infoPositions.count == ksig else { return nil }
        // Punktierung: Gruppen P_j = {p_k : k mod Q = j}.
        let q = fec.q
        let parityCount = n - kldpc
        let npunc = ksig + (kldpc - kbch) + parityCount - npost
        guard npunc >= 0, npunc <= parityCount, (npunc + 359) / 360 <= puncturing.count,
              puncturing.allSatisfy({ (0..<q).contains($0) }), 360 * q <= parityCount else { return nil }
        var punctured = [Bool](repeating: false, count: parityCount)
        let fullGroups = npunc / 360
        for i in 0..<fullGroups { for c in 0..<360 { punctured[c * q + puncturing[i]] = true } }
        if npunc % 360 > 0 { for c in 0..<(npunc % 360) { punctured[c * q + puncturing[fullGroups]] = true } }

        var llr = [Float](repeating: 0, count: n)
        for i in 0..<kbch where padded[i] { llr[i] = 40 }
        var cursor = 0
        for position in infoPositions { llr[position] = received[cursor]; cursor += 1 }
        for i in kbch..<kldpc { llr[i] = received[cursor]; cursor += 1 }
        for i in 0..<parityCount where !punctured[i] {
            guard cursor < received.count else { return nil }
            llr[kldpc + i] = received[cursor]
            cursor += 1
        }
        let code = T2LDPCCode.code(fec)
        let (bits, _) = T2LDPCSumProduct.decode(llr.map { max(-30, min(30, $0)) }, code: code)
        var info = infoPositions.map { bits[$0] }
        if scrambled {
            let prbs = T2Reference.scramblingSequence(ksig)
            for i in 0..<ksig { info[i] ^= prbs[i] }
        }
        return info
    }
}
