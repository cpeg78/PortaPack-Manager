import Foundation

/// Ein PLP: Zellen eines Interleaving-Frames → Zeit- und Zell-Deinterleaving
/// → LLR → LDPC → BBFRAMEs → Transportstrom.
final class T2PLPDecoder: @unchecked Sendable {
    let plp: T2PLP
    let fec: T2FEC
    let modulation: T2Modulation
    let extractor = T2TransportStreamExtractor()
    private let mapper: T2BitMapper
    private let code: T2LDPCCode
    private let bch: T2BCH
    private var decoders: [T2LDPCBatchDecoder] = []
    private let decoderLock = NSLock()

    /// Zellen des laufenden Interleaving-Frames (bei P_I > 1 über mehrere T2-Rahmen).
    private var re: [Float] = []
    private var im: [Float] = []
    private var weight: [Float] = []
    private var framesCollected = 0

    private(set) var blocksGood = 0
    private(set) var blocksBad = 0
    /// Vom BCH korrigierte Bits und dadurch gerettete Blöcke (LDPC nicht konvergiert).
    private(set) var bchCorrectedBits = 0
    private(set) var bchRescuedBlocks = 0
    /// LDPC-Syndrom erfüllt, aber BCH nicht korrigierbar (falsches Kodewort).
    private(set) var ldpcFalseBlocks = 0
    private(set) var lastIterations = 0
    private var lastFrameFailed = false
    /// Höchstzahl der LDPC-Iterationen (Prüfwerkzeuge setzen sie hoch).
    nonisolated(unsafe) static var maxIterations = 50
    /// Nur für Prüfwerkzeuge: harte BBHEADER-Bits jedes Blocks (auch ungültiger).
    var headerProbe: (([UInt8]) -> Void)?

    var cellsPerBlock: Int { fec.nldpc / modulation.bitsPerCell }
    /// T2-Rahmen je Interleaving-Frame und TI-Blöcke je Interleaving-Frame (6.5).
    var framesPerIF: Int { plp.timeInterleavingType == 1 ? max(1, plp.timeInterleavingLength) : 1 }
    var tiBlocks: Int { plp.timeInterleavingType == 1 ? 1 : max(1, plp.timeInterleavingLength) }

    init?(plp: T2PLP) {
        guard let fec = plp.fec, let modulation = plp.constellation else { return nil }
        self.plp = plp
        self.fec = fec
        self.modulation = modulation
        mapper = T2BitMapper.mapper(fec: fec, modulation: modulation, rotated: plp.rotation)
        code = T2LDPCCode.code(fec)
        bch = T2BCH(fec: fec)
    }

    func reset() {
        re = []; im = []; weight = []
        framesCollected = 0
        extractor.reset()
    }

    /// Zellen dieses PLP aus einem T2-Rahmen. `blocks` = PLP_NUM_BLOCKS des IF.
    func add(re cellsRe: ArraySlice<Float>, im cellsIm: ArraySlice<Float>, weight cellsWeight: ArraySlice<Float>,
             blocks: Int, positionInIF: Int) {
        if positionInIF == 0 {
            re = []; im = []; weight = []
            framesCollected = 0
        } else if framesCollected != positionInIF {
            // Rahmen verpasst – dieses IF ist unvollständig.
            framesCollected = -1
        }
        guard framesCollected >= 0 else { return }
        re += cellsRe; im += cellsIm; weight += cellsWeight
        framesCollected += 1
        if framesCollected == framesPerIF {
            decodeInterleavingFrame(blocks: blocks)
            framesCollected = -1
        }
    }

    private func decodeInterleavingFrame(blocks: Int) {
        let ncells = cellsPerBlock
        guard blocks > 0, re.count >= blocks * ncells else { return }
        // TI-Blöcke: die kleineren zuerst (6.5.2).
        let nti = tiBlocks
        var sizes: [Int] = []
        for s in 0..<nti { sizes.append(blocks / nti + (s >= nti - blocks % nti ? 1 : 0)) }
        if plp.timeInterleavingLength == 0 { sizes = [blocks] }

        var blockCells: [(re: [Float], im: [Float], w: [Float])] = []
        blockCells.reserveCapacity(blocks)
        let base = T2Interleavers.cellBase(cells: ncells)
        var offset = 0
        for size in sizes where size > 0 {
            let total = size * ncells
            var dRe = [Float](repeating: 0, count: total), dIm = dRe, dW = dRe
            if plp.timeInterleavingLength == 0 {
                for i in 0..<total { dRe[i] = re[offset + i]; dIm[i] = im[offset + i]; dW[i] = weight[offset + i] }
            } else {
                // Zeilen gelesen: Empfangsindex r·Nc + c ↔ Speicherindex c·Nr + r.
                let nr = ncells / 5, nc = 5 * size
                for r in 0..<nr {
                    for c in 0..<nc {
                        let from = offset + r * nc + c, to = c * nr + r
                        dRe[to] = re[from]; dIm[to] = im[from]; dW[to] = weight[from]
                    }
                }
            }
            let shifts = T2Interleavers.cellShifts(cells: ncells, blocks: size)
            for r in 0..<size {
                var gRe = [Float](repeating: 0, count: ncells), gIm = gRe, gW = gRe
                let shift = plp.timeInterleavingLength == 0 ? 0 : shifts[r]
                for q in 0..<ncells {
                    let from = r * ncells + (Int(base[q]) + shift) % ncells
                    gRe[q] = dRe[from]; gIm[q] = dIm[from]; gW[q] = dW[from]
                }
                blockCells.append((gRe, gIm, gW))
            }
            offset += total
        }

        // LLR und LDPC in Achtergruppen, parallel. Kam im letzten Interleaving-Frame
        // kein Block durch, nur eine Gruppe als Probe – spart bei zu schwachem
        // Signal fast die ganze Rechenzeit.
        let groups = lastFrameFailed ? 1 : (blockCells.count + 7) / 8
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var groups: [[(bits: [UInt8], ok: Bool, corrected: Int, rescued: Bool, falseWord: Bool)]]
            var iterations = 0
            init(_ count: Int) { groups = .init(repeating: [], count: count) }
        }
        let box = Results(groups)
        let cellsByBlock = blockCells
        DispatchQueue.concurrentPerform(iterations: groups) { g in
            let decoder = takeDecoder()
            defer { returnDecoder(decoder) }
            var llrs: [[Float]] = []
            for b in (g * 8)..<min(cellsByBlock.count, g * 8 + 8) {
                var llr = [Float](repeating: 0, count: fec.nldpc)
                let cells = cellsByBlock[b]
                cells.re.withUnsafeBufferPointer { r in
                    cells.im.withUnsafeBufferPointer { i in
                        cells.w.withUnsafeBufferPointer { w in
                            llr.withUnsafeMutableBufferPointer { out in
                                mapper.llr(re: r.baseAddress!, im: i.baseAddress!, weights: w.baseAddress!, into: out.baseAddress!)
                            }
                        }
                    }
                }
                llrs.append(llr)
            }
            let out = decoder.decode(llrs, maxIterations: T2PLPDecoder.maxIterations)
            // Äußerer BCH: repariert Restfehler, entlarvt falsche LDPC-Wörter.
            let checked = out.map { result -> (bits: [UInt8], ok: Bool, corrected: Int, rescued: Bool, falseWord: Bool) in
                var bits = result.bits
                if let fixed = bch.correct(&bits) { return (bits, true, fixed, !result.ok, false) }
                return (bits, false, 0, false, result.ok)
            }
            box.lock.withLock {
                box.groups[g] = checked
                box.iterations = decoder.iterations
            }
        }
        lastIterations = box.iterations
        let results = box.groups
        if let probe = headerProbe {
            let prbs = T2Reference.scramblingSequence(80)
            for group in results { for result in group { probe((0..<80).map { result.bits[$0] ^ prbs[$0] }) } }
        }
        var good = 0
        for group in results {
            for result in group {
                if result.ok { blocksGood += 1; good += 1 } else { blocksBad += 1 }
                bchCorrectedBits += result.corrected
                if result.rescued { bchRescuedBlocks += 1 }
                if result.falseWord { ldpcFalseBlocks += 1 }
                extractor.process(bits: Array(result.bits[0..<fec.kbch]), ok: result.ok)
            }
        }
        lastFrameFailed = good == 0
        if lastFrameFailed { extractor.reset() }
    }

    private func takeDecoder() -> T2LDPCBatchDecoder {
        decoderLock.withLock {
            if let d = decoders.popLast() { return d }
            return T2LDPCBatchDecoder(code: code)
        }
    }

    private func returnDecoder(_ decoder: T2LDPCBatchDecoder) {
        decoderLock.withLock { decoders.append(decoder) }
    }
}
