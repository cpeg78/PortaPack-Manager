import Accelerate
import Foundation
#if canImport(PortaPackManager)
@testable import PortaPackManager
#endif

// Simulationsprüfstand für den DVB-T2-Empfänger: ein T2-Sender, der komplette
// Rahmen wie auf K23 erzeugt (P1, P2 mit L1-pre/-post, Daten-PLP 64-QAM 1/2
// mit 64K-LDPC, Zell- und Zeit-Interleaving, Streu-/Continual-/Randpiloten,
// erweiterter Trägermodus, Schutzintervall 19/128, Abschlusssymbol), dazu ein
// Kanal mit Echo, Frequenz- und Abtastratenablage und Gaußrauschen. Ausgabe
// wie vom HackRF: int8-IQ mit 2·64/7 MS/s, Kanal bei −fs/4.
//
// Die Datei wird sowohl im Testziel als auch im Messwerkzeug
// `Tools/t2-sweep.sh` (mit swiftc -O, ohne App-Modul) übersetzt.
//
// Vereinfachungen: gedrehte Konstellationen und Tone Reservation werden
// nicht erzeugt. Die BCH-Parität ist seit 25.10.2026 echt (`T2BCH`) – der
// Empfänger prüft und korrigiert sie.

/// Reproduzierbarer Zufall (LCG, obere Bits).
struct T2SimRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }

    mutating func gauss() -> Float {
        Float((-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()))
    }

    mutating func bit() -> UInt8 { UInt8(next() >> 63) }
}

/// L1-Signalisierung von K23 (490 MHz, Rahmen 0), live mitgeschnitten.
enum T2K23 {
    static let preBits = "00000000100010000101000000000000000000010111011100000000000100111110000100000000000010100010000100110000000010100001111111111111000000100000010101110000001000001000111101110000100100000000110111001101"
    static let postBits = "00000000000000100000001000000000000000000111010011010011001110100000000000000000100011000000000000000000000000100010001100110000000010000001001011111111111101000111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000111111110000000000000000000000000000000001100110111111111111111111011010011010001011001101000010"
    static func bits(_ s: String) -> [UInt8] { s.map { $0 == "1" ? 1 : 0 } }
}

// MARK: - Sender

final class T2TestTransmitter {
    static let oversampling = 2
    /// PID der erzeugten Transportstrom-Pakete; Nutzdaten aus dem Paketzähler.
    static let pid = 0x100

    let pre: T2L1Pre
    let layout: T2Layout
    let plp: T2PLP
    let fec: T2FEC
    let modulation: T2Modulation
    private let postInfo: [UInt8]
    private let frameIndexBit: Int
    private let code: T2LDPCCode
    private let bch: T2BCH
    private let mapper: T2BitMapper
    private let infoOffsets: [Int32]
    private let infoVariables: [Int32]
    private let levels: [Float]
    private var random: T2SimRandom
    private(set) var frameIndex = 0
    /// Bytes des laufenden TS-Pakets, die schon gesendet sind (0…186).
    private var packetPhase = 0
    private var packetCounter = 0
    private var pendingPacket: [UInt8] = []
    /// Erzeugte BBFRAMEs und TS-Pakete.
    private(set) var bbFramesSent = 0
    private(set) var packetsSent = 0

    private let n2: Int
    private let fft2: T2FFT
    private let p1: (re: [Float], im: [Float])
    private let carrierScale: Float

    init(seed: UInt64 = 1) {
        pre = T2L1Pre(bits: T2K23.bits(T2K23.preBits))
        let postBits = T2K23.bits(T2K23.postBits)
        postInfo = Array(postBits.prefix(pre.l1PostInfoSize))
        let post = T2L1Post(bits: postInfo, pre: pre)!
        plp = post.plps[0]
        fec = plp.fec!
        modulation = plp.constellation!
        precondition(!plp.rotation && !pre.toneReservation, "Nicht nachgebildet")
        let size = T2FFTSize.from(s2: pre.s2)!
        layout = T2Layout(fft: size, guardInterval: T2GuardInterval(rawValue: pre.guardInterval)!,
                          pattern: T2PilotPattern(rawValue: pre.pilotPattern)!, extended: pre.extendedCarriers,
                          toneReservation: pre.toneReservation, dataSymbols: pre.dataSymbols)!
        // Lage von FRAME_IDX im L1-post (Beginn des dynamischen Teils).
        var bit = 15 + 8 + 4 + 8 + pre.rfCount * 35 + (pre.s2 & 1 == 1 ? 34 : 0)
        bit += post.plps.count * 89 + 32 + post.auxiliaryStreams * 32
        frameIndexBit = bit
        code = T2LDPCCode.code(fec)
        bch = T2BCH(fec: fec)
        mapper = T2BitMapper.mapper(fec: fec, modulation: modulation, rotated: false)
        // Prüfungen nur über Infobits (für die Akkumulator-Kodierung).
        var offsets: [Int32] = [0], variables: [Int32] = []
        for c in 0..<code.m {
            for e in Int(code.offsets[c])..<Int(code.offsets[c + 1]) where Int(code.variables[e]) < code.k {
                variables.append(code.variables[e])
            }
            offsets.append(Int32(variables.count))
        }
        infoOffsets = offsets
        infoVariables = variables
        levels = Self.levels(perAxis: modulation.bitsPerCell / 2)
        random = T2SimRandom(state: seed)

        n2 = size.size * Self.oversampling
        fft2 = T2FFT(size: n2)
        carrierScale = 1 / Float(layout.kmax + 1).squareRoot()
        p1 = Self.makeP1(s2: pre.s2)
    }

    /// Abtastwerte je Rahmen bei doppelter Rate.
    var frameSamples: Int { layout.frameSamples * Self.oversampling }
    static var sampleRate: Double { Double(oversampling) * 64_000_000 / 7 }
    /// Anteil der belegten Bandbreite an der Abtastrate (für die Rauschleistung im Kanal).
    var occupiedFraction: Double { Double(layout.kmax + 1) / Double(n2) }

    /// Gray-PAM-Stufen je Bitmuster einer Achse (Bit 0 = höchstwertig): erstes Bit
    /// = Vorzeichen, dann |x| − L/2, ||x| − L/2| − L/4 … (Tabelle 15 der Norm).
    static func levels(perAxis: Int) -> [Float] {
        let count = 1 << perAxis
        var table = [Float](repeating: 0, count: count)
        for l in 0..<count {
            let x = Float(2 * l - count + 1)
            var index = x < 0 ? 1 : 0
            var t = x
            var half = Float(count) / 2
            for _ in 1..<perAxis {
                t = abs(t) - half
                index = index << 1 | (t < 0 ? 1 : 0)
                half /= 2
            }
            table[index] = x
        }
        return table
    }

    // MARK: Rahmen

    /// Ein kompletter T2-Rahmen (P1 + P2 + Datensymbole) bei 2·64/7 MS/s,
    /// mittlere Leistung der Datensymbole ≈ 1.
    func frame() -> (re: [Float], im: [Float]) {
        let size = layout.fft
        let np2 = size.p2Symbols
        let lf = layout.symbolsPerFrame

        // PLP-Zellen dieses Rahmens.
        let plpCells = makePLPCells(blocks: plp.blocks)
        // L1.
        let preCells = encodeL1Pre()
        let postCells = encodeL1Post()

        var outRe = [Float](repeating: 0, count: frameSamples)
        var outIm = outRe
        outRe.replaceSubrange(0..<p1.re.count, with: p1.re)
        outIm.replaceSubrange(0..<p1.im.count, with: p1.im)

        var cursor = 0          // Position im PLP-Zellstrom
        func nextCell() -> (Float, Float) {
            if cursor < plpCells.re.count {
                defer { cursor += 1 }
                return (plpCells.re[cursor], plpCells.im[cursor])
            }
            cursor += 1
            return (random.bit() == 0 ? 1 : -1, 0)       // Dummy-Zelle
        }

        let kmax = layout.kmax
        let kext = layout.extended ? size.kext : 0
        var specRe = [Float](repeating: 0, count: kmax + 1), specIm = specRe
        let l1Cells = T2L1Decoder.preCells + pre.l1PostSize
        for l in 0..<lf {
            for k in 0...kmax { specRe[k] = 0; specIm[k] = 0 }
            let carriers = layout.dataCarriers(symbol: l)
            var cellRe = [Float](repeating: 0, count: carriers.count), cellIm = cellRe
            if l < np2 {
                // P2-Piloten (k mod 3 = 0, im erweiterten Modus auch die Ränder).
                let step = size == .k32 ? 6 : 3
                let ap2: Float = size == .k32 ? Float(37).squareRoot() / 5 : Float(31).squareRoot() / 5
                for k in 0...kmax where k % step == 0 || (kext > 0 && (k < kext || k > kmax - kext)) {
                    specRe[k] = ap2 * T2Reference.sign(symbol: l, carrier: k, layout: layout)
                }
                // L1-pre und -post im Zickzack, dann PLP.
                for p in 0..<T2L1Decoder.preCells where p % np2 == l {
                    cellRe[p / np2] = preCells.re[p]; cellIm[p / np2] = preCells.im[p]
                }
                for p in 0..<pre.l1PostSize where p % np2 == l {
                    let index = T2L1Decoder.preCells / np2 + p / np2
                    cellRe[index] = postCells.re[p]; cellIm[index] = postCells.im[p]
                }
                for i in (l1Cells / np2)..<carriers.count { (cellRe[i], cellIm[i]) = nextCell() }
            } else {
                let asp = layout.pattern.amplitude
                let scattered = layout.scatteredPilots(symbol: l)
                if !layout.isFrameClosing(l) {
                    let acp = size.continualPilotAmplitude
                    for k in layout.continualPilots {
                        specRe[k] = acp * T2Reference.sign(symbol: l, carrier: k, layout: layout)
                    }
                }
                for k in scattered { specRe[k] = asp * T2Reference.sign(symbol: l, carrier: k, layout: layout) }
                let active = layout.isFrameClosing(l) ? layout.frameClosingActive : carriers.count
                for i in 0..<active { (cellRe[i], cellIm[i]) = nextCell() }
            }
            // Frequenz-Interleaver: Träger p trägt Zelle H(p).
            let h = frequencyInterleaver(count: carriers.count, odd: l % 2 == 1)
            for (p, k) in carriers.enumerated() {
                specRe[k] = cellRe[Int(h[p])]
                specIm[k] = cellIm[Int(h[p])]
            }
            // OFDM mit doppelter Rate: Träger k auf Bin k − kmax/2.
            var xr = [Float](repeating: 0, count: n2), xi = xr
            for k in 0...kmax {
                let bin = ((k - kmax / 2) % n2 + n2) % n2
                xr[bin] = specRe[k] * carrierScale
                xi[bin] = specIm[k] * carrierScale
            }
            fft2.inverse(&xr, &xi)
            let g2 = layout.guardInterval.samples(size) * Self.oversampling
            let start = 2048 * Self.oversampling + l * (n2 + g2)
            for t in 0..<g2 {
                outRe[start + t] = xr[n2 - g2 + t]; outIm[start + t] = xi[n2 - g2 + t]
            }
            for t in 0..<n2 {
                outRe[start + g2 + t] = xr[t]; outIm[start + g2 + t] = xi[t]
            }
        }
        frameIndex = (frameIndex + 1) % max(1, pre.t2Frames)
        return (outRe, outIm)
    }

    private var interleavers: [String: [Int32]] = [:]
    private func frequencyInterleaver(count: Int, odd: Bool) -> [Int32] {
        let key = "\(count)-\(odd)"
        if let h = interleavers[key] { return h }
        let h = T2Interleavers.frequency(layout.fft, count: count, odd: odd)
        interleavers[key] = h
        return h
    }

    /// P1 (9.8) bei doppelter Rate: Teil A aus 384 DBPSK-Trägern, C und B um einen 1K-Träger verschoben.
    private static func makeP1(s2: Int) -> (re: [Float], im: [Float]) {
        let pattern = T2P1.patterns.first { $0.s1 == 0 && $0.s2 == s2 }!
        var values: [Float] = [1]
        for d in pattern.diff { values.append(values.last! * d) }
        let n = 1024 * oversampling
        var aRe = [Float](repeating: 0, count: n), aIm = aRe
        for (i, k) in T2P1.carriers.enumerated() { aRe[((k - 426) % n + n) % n] = values[i] }
        T2FFT(size: n).inverse(&aRe, &aIm)
        let scale = 1 / Float(T2P1.carriers.count).squareRoot()
        var re = [Float](repeating: 0, count: 2 * n), im = re
        let c = 542 * oversampling, a = 1024 * oversampling
        for t in 0..<(2 * n) {
            let phase = 2 * Double.pi * Double(t) / Double(n)
            let (r, i): (Float, Float)
            if t < c {
                let (cr, ci) = (Float(cos(phase)), Float(sin(phase)))
                (r, i) = (aRe[t] * cr - aIm[t] * ci, aRe[t] * ci + aIm[t] * cr)
            } else if t < c + a {
                (r, i) = (aRe[t - c], aIm[t - c])
            } else {
                let (cr, ci) = (Float(cos(phase)), Float(sin(phase)))
                let s = t - n
                (r, i) = (aRe[s] * cr - aIm[s] * ci, aRe[s] * ci + aIm[s] * cr)
            }
            re[t] = r * scale; im[t] = i * scale
        }
        return (re, im)
    }

    // MARK: Daten-PLP

    /// BBFRAME (K_bch Bits, verwürfelt): BBHEADER im HEM, Datenfeld aus TS-Paketen ohne Sync-Byte.
    private func bbFrame() -> [UInt8] {
        let kbch = fec.kbch
        let dflBytes = (kbch - 80) / 8
        var field: [UInt8] = []
        field.reserveCapacity(dflBytes)
        let syncd = packetPhase == 0 ? 0 : (187 - packetPhase) * 8
        while field.count < dflBytes {
            if pendingPacket.isEmpty { pendingPacket = makePacket() }
            let take = min(dflBytes - field.count, pendingPacket.count)
            field += pendingPacket[0..<take]
            pendingPacket.removeFirst(take)
        }
        packetPhase = pendingPacket.isEmpty ? 0 : 187 - pendingPacket.count
        let dfl = dflBytes * 8
        var header: [UInt8] = [0xF0, 0x00, 0, 0, UInt8(dfl >> 8), UInt8(dfl & 0xFF), 0, UInt8(syncd >> 8), UInt8(syncd & 0xFF)]
        header.append(T2CRC.crc8(header[...]) ^ 1)          // MODE = 1 (HEM)
        let bytes = header + field
        let prbs = T2Reference.scramblingSequence(kbch)
        var bits = [UInt8](repeating: 0, count: kbch)
        for i in 0..<min(kbch, bytes.count * 8) { bits[i] = (bytes[i / 8] >> (7 - UInt8(i % 8))) & 1 }
        for i in 0..<kbch { bits[i] ^= prbs[i] }
        bbFramesSent += 1
        return bits
    }

    /// Dienst im erzeugten Transportstrom (PAT, PMT und SDT alle 40 Pakete).
    static let serviceName = "Prüfbild HD"
    static let serviceProvider = "Prüfstand"
    static let programNumber = 42
    private var psiCounter = 0
    private var psiContinuity: [Int: UInt8] = [:]

    /// PSI-Abschnitt mit Kopf und CRC-32/MPEG-2.
    static func section(table: UInt8, id: Int, body: [UInt8]) -> [UInt8] {
        let length = 5 + body.count + 4
        var s: [UInt8] = [table, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF), UInt8(id >> 8), UInt8(id & 0xFF), 0xC1, 0, 0] + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in s {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        s += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        return s
    }

    private func psiPacket(_ kind: Int) -> [UInt8] {
        let program = Self.programNumber
        let (pid, section): (Int, [UInt8])
        switch kind {
        case 0:
            pid = 0
            section = Self.section(table: 0x00, id: 0x1234, body: [UInt8(program >> 8), UInt8(program & 0xFF), 0xE1, 0x01])
        case 1:
            pid = 0x101
            section = Self.section(table: 0x02, id: program, body: [0xE1, 0x00, 0xF0, 0x00,
                                                                    0x24, 0xE1, 0x00, 0xF0, 0x00])   // HEVC auf 0x100
        default:
            pid = 0x11
            let name = Array(Self.serviceName.utf8), provider = Array(Self.serviceProvider.utf8)
            // Zeichensatz-Kennung 0x15 = UTF-8.
            let descriptor: [UInt8] = [0x48, UInt8(5 + provider.count + name.count), 0x1F, UInt8(provider.count + 1), 0x15]
                + provider + [UInt8(name.count + 1), 0x15] + name
            section = Self.section(table: 0x42, id: 0x1234, body: [0x00, 0x01, 0xFF, UInt8(program >> 8), UInt8(program & 0xFF),
                                                                   0xFC, 0x80, UInt8(descriptor.count)] + descriptor)
        }
        let cc = psiContinuity[pid, default: 0]
        psiContinuity[pid] = (cc + 1) & 0x0F
        var packet: [UInt8] = [0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | cc, 0x00] + section
        packet += [UInt8](repeating: 0xFF, count: 187 - packet.count)
        return packet
    }

    /// TS-Paket ohne Sync-Byte (187 Bytes); Nutzdaten aus dem Zähler ableitbar.
    private func makePacket() -> [UInt8] {
        psiCounter += 1
        if psiCounter % 40 < 3 {
            packetsSent += 1
            return psiPacket(psiCounter % 40)
        }
        let counter = packetCounter
        packetCounter += 1
        packetsSent += 1
        var p: [UInt8] = [UInt8(Self.pid >> 8), UInt8(Self.pid & 0xFF), 0x10 | UInt8(counter & 0x0F)]
        p += (0..<184).map { UInt8((counter &* 7 &+ $0 &* 13) & 0xFF) }
        return p
    }

    /// Erwartete Nutzdaten eines empfangenen Pakets (für Prüfungen).
    static func isValidPacket(_ packet: [UInt8]) -> Bool {
        guard packet.count == 188, packet[0] == 0x47, Int(packet[1]) << 8 | Int(packet[2]) == pid else { return false }
        // Zähler nur bis auf Vielfache von 256 bekannt – die Nutzdaten müssen zu einem der Kandidaten passen.
        let base = Int(packet[4])
        for counter in stride(from: 0, to: 256, by: 1) where UInt8((counter &* 7) & 0xFF) == UInt8(base) {
            if (0..<184).allSatisfy({ packet[4 + $0] == UInt8((counter &* 7 &+ $0 &* 13) & 0xFF) }) { return true }
        }
        return false
    }

    /// Kodewort (N_ldpc Bits): BBFRAME + BCH-Parität + LDPC-Parität (Akkumulator).
    func encode(_ info: [UInt8]) -> [UInt8] {
        var word = [UInt8](repeating: 0, count: code.n)
        word.replaceSubrange(0..<info.count, with: info)
        word.replaceSubrange(info.count..<(info.count + bch.parityBits), with: bch.parity(info))
        var parity: UInt8 = 0
        for c in 0..<code.m {
            var s: UInt8 = 0
            for e in Int(infoOffsets[c])..<Int(infoOffsets[c + 1]) { s ^= word[Int(infoVariables[e])] }
            parity ^= s
            word[code.k + c] = parity
        }
        return word
    }

    /// Zellen eines FEC-Blocks (Bitverschachtelung, Demultiplexer, Gray-QAM).
    func cells(_ word: [UInt8]) -> (re: [Float], im: [Float]) {
        let eta = modulation.bitsPerCell, perAxis = eta / 2
        let count = fec.nldpc / eta
        let scale = 1 / T2BitMapper.norm(modulation).squareRoot()
        var re = [Float](repeating: 0, count: count), im = re
        for q in 0..<count {
            var i = 0, qq = 0
            for b in 0..<perAxis {
                i = i << 1 | Int(word[Int(mapper.position[q * eta + 2 * b])])
                qq = qq << 1 | Int(word[Int(mapper.position[q * eta + 2 * b + 1])])
            }
            re[q] = levels[i] * scale
            im[q] = levels[qq] * scale
        }
        return (re, im)
    }

    /// PLP-Zellen eines Interleaving-Frames: Zell-Interleaver je FEC-Block, Zeit-Interleaver je TI-Block
    /// (genaue Umkehrung von `T2PLPDecoder`).
    private func makePLPCells(blocks: Int) -> (re: [Float], im: [Float]) {
        let ncells = fec.nldpc / modulation.bitsPerCell
        let nti = plp.timeInterleavingType == 1 ? 1 : max(1, plp.timeInterleavingLength)
        var sizes: [Int] = []
        for s in 0..<nti { sizes.append(blocks / nti + (s >= nti - blocks % nti ? 1 : 0)) }
        if plp.timeInterleavingLength == 0 { sizes = [blocks] }
        let base = T2Interleavers.cellBase(cells: ncells)
        var outRe = [Float](repeating: 0, count: blocks * ncells), outIm = outRe
        var offset = 0
        for size in sizes where size > 0 {
            let total = size * ncells
            var dRe = [Float](repeating: 0, count: total), dIm = dRe
            let shifts = T2Interleavers.cellShifts(cells: ncells, blocks: size)
            for r in 0..<size {
                let c = cells(encode(bbFrame()))
                let shift = plp.timeInterleavingLength == 0 ? 0 : shifts[r]
                for q in 0..<ncells {
                    let to = r * ncells + (Int(base[q]) + shift) % ncells
                    dRe[to] = c.re[q]; dIm[to] = c.im[q]
                }
            }
            if plp.timeInterleavingLength == 0 {
                for i in 0..<total { outRe[offset + i] = dRe[i]; outIm[offset + i] = dIm[i] }
            } else {
                let nr = ncells / 5, nc = 5 * size
                for r in 0..<nr {
                    for c in 0..<nc {
                        outRe[offset + r * nc + c] = dRe[c * nr + r]
                        outIm[offset + r * nc + c] = dIm[c * nr + r]
                    }
                }
            }
            offset += total
        }
        return (outRe, outIm)
    }

    // MARK: L1

    private func encodeL1Pre() -> (re: [Float], im: [Float]) {
        let bits = encodeL1Block(T2K23.bits(T2K23.preBits), fec: T2FEC(normal: false, rate: .r1_4), npost: T2L1Decoder.preCells,
                                 shortening: [7, 3, 6, 5, 2, 4, 1, 8, 0],
                                 puncturing: [27, 13, 29, 32, 5, 0, 11, 21, 33, 20, 25, 28, 18, 35, 8, 3, 9, 31,
                                              22, 24, 7, 14, 17, 4, 2, 26, 16, 34, 19, 10, 12, 23, 1, 6, 30, 15])
        return (bits.map { $0 == 0 ? 1 : -1 }, [Float](repeating: 0, count: bits.count))
    }

    private func encodeL1Post() -> (re: [Float], im: [Float]) {
        precondition(pre.l1Modulation == 0, "Nur BPSK-L1-post nachgebildet")
        var info = postInfo
        for b in 0..<8 { info[frameIndexBit + b] = UInt8((frameIndex >> (7 - b)) & 1) }
        info += Self.crc32(info)
        if pre.postScrambled {
            let prbs = T2Reference.scramblingSequence(info.count)
            for i in info.indices { info[i] ^= prbs[i] }
        }
        precondition(info.count <= 7032, "Nur ein L1-post-Block nachgebildet")
        let bits = encodeL1Block(info, fec: T2FEC(normal: false, rate: .r1_2), npost: pre.l1PostSize,
                                 shortening: [18, 17, 16, 15, 14, 13, 12, 11, 4, 10, 9, 8, 3, 2, 7, 6, 5, 1, 19, 0],
                                 puncturing: [6, 4, 18, 9, 13, 8, 15, 20, 5, 17, 2, 24, 10, 22, 12, 3, 16, 23, 1, 14, 0, 21, 19, 7, 11])
        return (bits.map { $0 == 0 ? 1 : -1 }, [Float](repeating: 0, count: bits.count))
    }

    /// CRC-32 (Anhang F) als 32 Bit, MSB zuerst.
    static func crc32(_ bits: [UInt8]) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for bit in bits {
            let top = (crc >> 31) & 1
            crc <<= 1
            if top ^ UInt32(bit) == 1 { crc ^= 0x04C1_1DB7 }
        }
        return (0..<32).map { UInt8((crc >> (31 - UInt32($0))) & 1) }
    }

    /// Verkürzter, punktierter 16K-Block (7.3.2): Infobits → gesendete Bits
    /// (Info, BCH-Parität, nicht punktierte LDPC-Parität).
    private func encodeL1Block(_ info: [UInt8], fec: T2FEC, npost: Int, shortening: [Int], puncturing: [Int]) -> [UInt8] {
        let ksig = info.count
        let kbch = fec.kbch, kldpc = fec.kldpc, n = fec.nldpc
        let groups = kldpc / 360
        func groupSize(_ g: Int) -> Int { g == groups - 1 ? 360 - (kldpc - kbch) : 360 }
        var padded = [Bool](repeating: false, count: kbch)
        let npad = ksig < 360 ? groups - 1 : (kbch - ksig) / 360
        for i in 0..<npad {
            let g = shortening[i]
            for j in 0..<groupSize(g) { padded[g * 360 + j] = true }
        }
        let extra = npad == groups - 1 ? 360 - ksig : kbch - ksig - 360 * npad
        if extra > 0 {
            let g = shortening[npad]
            let size = groupSize(g)
            for j in max(0, size - extra)..<size { padded[g * 360 + j] = true }
        }
        let infoPositions = (0..<kbch).filter { !padded[$0] }
        precondition(infoPositions.count == ksig)
        var message = [UInt8](repeating: 0, count: kbch)
        for (i, position) in infoPositions.enumerated() { message[position] = info[i] }
        let l1Code = T2LDPCCode.code(fec)
        var word = message + T2BCH(fec: fec).parity(message)
        word += [UInt8](repeating: 0, count: n - kldpc)
        var parity: UInt8 = 0
        for c in 0..<l1Code.m {
            var s: UInt8 = 0
            for e in Int(l1Code.offsets[c])..<Int(l1Code.offsets[c + 1]) where Int(l1Code.variables[e]) < kldpc {
                s ^= word[Int(l1Code.variables[e])]
            }
            parity ^= s
            word[kldpc + c] = parity
        }
        let q = fec.q
        let parityCount = n - kldpc
        let npunc = ksig + (kldpc - kbch) + parityCount - npost
        var punctured = [Bool](repeating: false, count: parityCount)
        let fullGroups = npunc / 360
        for i in 0..<fullGroups { for c in 0..<360 { punctured[c * q + puncturing[i]] = true } }
        if npunc % 360 > 0 { for c in 0..<(npunc % 360) { punctured[c * q + puncturing[fullGroups]] = true } }
        var sent = infoPositions.map { word[$0] } + Array(word[kbch..<kldpc])
        for i in 0..<parityCount where !punctured[i] { sent.append(word[kldpc + i]) }
        precondition(sent.count == npost)
        return sent
    }

    /// BCH (16K, t = 12): Produkt der ersten zwölf Polynome aus Tabelle 7(b).
    static let bch16KGenerator: [UInt8] = {
        let polys = ["110101000000001", "100000101001001", "111000100110001", "100010011010101", "101010101101011",
                     "100100011100011", "101001110011011", "100001001111001", "111100000110001", "100100100101101",
                     "100010000001101", "111101111010011"]
        var g: [UInt8] = [1]
        for p in polys {
            let q = p.map { UInt8($0 == "1" ? 1 : 0) }
            var r = [UInt8](repeating: 0, count: g.count + q.count - 1)
            for (i, a) in g.enumerated() where a == 1 { for (j, b) in q.enumerated() { r[i + j] ^= b } }
            g = r
        }
        return g
    }()

    static func bch16K(_ message: [UInt8]) -> [UInt8] {
        let g = bch16KGenerator
        let degree = g.count - 1
        var register = [UInt8](repeating: 0, count: degree)
        for bit in message {
            let feedback = bit ^ register[0]
            register.removeFirst()
            register.append(0)
            if feedback == 1 { for i in 0..<degree { register[i] ^= g[degree - 1 - i] } }
        }
        return register
    }
}

// MARK: - Kanal

/// Übertragungskanal bei 2·64/7 MS/s: Zweiwege-Echo, Frequenzablage,
/// Abtastratenablage (Fensterung-Sinc-Interpolation), Gaußrauschen, dann
/// Verschiebung auf −fs/4 und Quantisierung auf int8 wie beim HackRF.
final class T2TestChannel {
    struct Parameters: Sendable {
        /// Störabstand im belegten Band (C/N), nil = rauschfrei.
        var snrDB: Double? = nil
        /// Echo relativ zum Hauptpfad (dB) und seine Verzögerung (µs).
        var echoDB: Double? = nil
        var echoMicroseconds = 5.0
        var echoPhase = 1.0
        var frequencyOffsetHz = 0.0
        /// Abtastratenablage des Empfängers (ppm); positiv: er tastet langsamer ab (Ausgangswert m
        /// liegt bei Eingangszeit m·(1 + ε)).
        var sampleRatePPM = 0.0
        /// Nachbarkanal (ein zweites T2-Signal) relativ zum Nutzsignal (dB) und sein Abstand (MHz).
        var adjacentDB: Double? = nil
        var adjacentMHz = 8.0
        /// Störträger (CW) relativ zur Signalleistung (dBc) und seine Ablage von der Kanalmitte (Hz).
        var toneDBc: Double? = nil
        var toneOffsetHz = 1_234_567.0
        var seed: UInt64 = 99
    }

    let parameters: Parameters
    private let occupiedFraction: Double
    private var random: T2SimRandom
    private var echoHistoryRe: [Float] = []
    private var echoHistoryIm: [Float] = []
    private var cfoPhase = 0.0
    private var mixIndex = 0
    // Abtastratenablage
    private var resampleRe: [Float] = []
    private var resampleIm: [Float] = []
    private var resampleTime = 0.0          // Zeit des nächsten Ausgangswerts relativ zu resampleRe[0]
    private static let halfTaps = 12
    private static let phases = 512
    private let polyphase: [Float]
    /// Feste Leistung für die Rauschberechnung (Signal nach Echo); beim ersten Aufruf gemessen.
    private var signalPower: Double?

    init(_ parameters: Parameters, occupiedFraction: Double) {
        self.parameters = parameters
        self.occupiedFraction = occupiedFraction
        random = T2SimRandom(state: parameters.seed)
        let taps = 2 * Self.halfTaps
        var table = [Float](repeating: 0, count: Self.phases * taps)
        for p in 0..<Self.phases {
            let mu = Double(p) / Double(Self.phases)
            for j in 0..<taps {
                let x = Double(j - Self.halfTaps + 1) - mu
                let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                let w = x / Double(Self.halfTaps)
                let window = abs(w) >= 1 ? 0 : 0.42 + 0.5 * cos(.pi * w) + 0.08 * cos(2 * .pi * w)
                table[p * taps + j] = Float(sinc * window)
            }
        }
        polyphase = table
    }

    /// Legt die Bezugsleistung für Rauschen und Pegel fest: mittlere Leistung
    /// eines gesendeten Rahmens, mit dem Echo (unkorreliert) addiert.
    func calibrate(re: [Float], im: [Float]) {
        var p = 0.0
        for n in 0..<re.count { p += Double(re[n] * re[n] + im[n] * im[n]) }
        p /= Double(max(1, re.count))
        if let echoDB = parameters.echoDB { p *= 1 + pow(10, echoDB / 10) }
        signalPower = p
    }

    private var adjacent: T2TestTransmitter?
    private var adjacentRe: [Float] = []
    private var adjacentIm: [Float] = []
    private var adjacentPhase = 0.0
    private var tonePhase = 0.0

    /// Nachbarkanal dazumischen (unabhängiger Sender, eigene Rahmenlage).
    private func addAdjacent(re: inout [Float], im: inout [Float]) {
        guard let db = parameters.adjacentDB else { return }
        if adjacent == nil {
            adjacent = T2TestTransmitter(seed: parameters.seed &+ 12345)
            // Andere Rahmenlage als das Nutzsignal.
            let f = adjacent!.frame()
            adjacentRe = Array(f.re[700_001...]); adjacentIm = Array(f.im[700_001...])
        }
        while adjacentRe.count < re.count {
            let f = adjacent!.frame()
            adjacentRe += f.re; adjacentIm += f.im
        }
        let gain = Float(pow(10, db / 20))
        let step = 2 * Double.pi * parameters.adjacentMHz * 1e6 / T2TestTransmitter.sampleRate
        for n in 0..<re.count {
            let c = Float(cos(adjacentPhase)) * gain, s = Float(sin(adjacentPhase)) * gain
            re[n] += adjacentRe[n] * c - adjacentIm[n] * s
            im[n] += adjacentRe[n] * s + adjacentIm[n] * c
            adjacentPhase += step
            if adjacentPhase > .pi { adjacentPhase -= 2 * .pi } else if adjacentPhase < -.pi { adjacentPhase += 2 * .pi }
        }
        adjacentRe.removeFirst(re.count); adjacentIm.removeFirst(re.count)
    }

    /// Ein Signalstück durch den Kanal; Ergebnis als HackRF-int8-Daten.
    func process(re inRe: [Float], im inIm: [Float]) -> Data {
        var re = inRe, im = inIm
        let fs = T2TestTransmitter.sampleRate
        // Echo.
        if let echoDB = parameters.echoDB {
            let delay = Int((parameters.echoMicroseconds * 1e-6 * fs).rounded())
            let gain = Float(pow(10, echoDB / 20))
            let gr = gain * Float(cos(parameters.echoPhase)), gi = gain * Float(sin(parameters.echoPhase))
            if echoHistoryRe.count != delay {
                echoHistoryRe = [Float](repeating: 0, count: delay); echoHistoryIm = echoHistoryRe
            }
            let extendedRe = echoHistoryRe + inRe, extendedIm = echoHistoryIm + inIm
            for n in 0..<re.count {
                let dr = extendedRe[n], di = extendedIm[n]
                re[n] += gr * dr - gi * di
                im[n] += gr * di + gi * dr
            }
            echoHistoryRe = Array(extendedRe.suffix(delay)); echoHistoryIm = Array(extendedIm.suffix(delay))
        }
        // Frequenzablage.
        if parameters.frequencyOffsetHz != 0 {
            let step = 2 * Double.pi * parameters.frequencyOffsetHz / fs
            for n in 0..<re.count {
                let c = Float(cos(cfoPhase)), s = Float(sin(cfoPhase))
                let r = re[n], i = im[n]
                re[n] = r * c - i * s; im[n] = r * s + i * c
                cfoPhase += step
                if cfoPhase > .pi { cfoPhase -= 2 * .pi } else if cfoPhase < -.pi { cfoPhase += 2 * .pi }
            }
        }
        addAdjacent(re: &re, im: &im)
        if let dbc = parameters.toneDBc {
            let amplitude = Float(((signalPower ?? 1) * pow(10, dbc / 10)).squareRoot())
            let step = 2 * Double.pi * parameters.toneOffsetHz / fs
            for n in 0..<re.count {
                re[n] += amplitude * Float(cos(tonePhase)); im[n] += amplitude * Float(sin(tonePhase))
                tonePhase += step
                if tonePhase > .pi { tonePhase -= 2 * .pi }
            }
        }
        // Abtastratenablage: Ausgangswert m liegt bei Eingangszeit m·(1 + ε).
        if parameters.sampleRatePPM != 0 {
            resampleRe += re; resampleIm += im
            let ratio = 1 + parameters.sampleRatePPM * 1e-6
            let taps = 2 * Self.halfTaps
            var outRe: [Float] = [], outIm: [Float] = []
            outRe.reserveCapacity(re.count + 16); outIm.reserveCapacity(re.count + 16)
            polyphase.withUnsafeBufferPointer { table in
                while true {
                    let base = Int(resampleTime.rounded(.down))
                    guard base + Self.halfTaps < resampleRe.count else { break }
                    let mu = resampleTime - Double(base)
                    let phase = min(Self.phases - 1, Int((mu * Double(Self.phases)).rounded()))
                    var r: Float = 0, i: Float = 0
                    let first = base - Self.halfTaps + 1
                    for j in 0..<taps {
                        let index = first + j
                        guard index >= 0 else { continue }
                        let w = table[phase * taps + j]
                        r += w * resampleRe[index]; i += w * resampleIm[index]
                    }
                    outRe.append(r); outIm.append(i)
                    resampleTime += ratio
                }
            }
            let drop = max(0, Int(resampleTime.rounded(.down)) - Self.halfTaps)
            if drop > 0 {
                resampleRe.removeFirst(drop); resampleIm.removeFirst(drop)
                resampleTime -= Double(drop)
            }
            re = outRe; im = outIm
        }
        // Rauschen: C/N im belegten Band.
        let power = signalPower ?? 1
        var noiseSigma: Float = 0
        if let snr = parameters.snrDB {
            let total = power / (pow(10, snr / 10) * occupiedFraction)
            noiseSigma = Float((total / 2).squareRoot())
        }
        // Pegel wie beim HackRF: Effektivwert je Komponente ≈ 20 Stufen.
        let adjacentPower = parameters.adjacentDB.map { power * pow(10, $0 / 10) } ?? 0
        let rms = ((power + adjacentPower + Double(2 * noiseSigma * noiseSigma)) / 2).squareRoot()
        let gain = Float(20 / rms)
        var data = Data(count: re.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int8.self)
            for n in 0..<re.count {
                var r = re[n], i = im[n]
                if noiseSigma > 0 { r += noiseSigma * random.gauss(); i += noiseSigma * random.gauss() }
                // Mischen mit e^{−jπn/2}: Kanal liegt danach bei −fs/4.
                let (a, b): (Float, Float)
                switch mixIndex & 3 {
                case 0: (a, b) = (r, i)
                case 1: (a, b) = (i, -r)
                case 2: (a, b) = (-r, -i)
                default: (a, b) = (-i, r)
                }
                mixIndex += 1
                out[2 * n] = Int8(max(-127, min(127, (a * gain).rounded())))
                out[2 * n + 1] = Int8(max(-127, min(127, (b * gain).rounded())))
            }
        }
        return data
    }

    /// Nur Rauschen (Vorlauf vor dem ersten Rahmen).
    func silence(samples: Int) -> Data {
        process(re: [Float](repeating: 0, count: samples), im: [Float](repeating: 0, count: samples))
    }
}

// MARK: - Messung

/// Sendet `frames` Rahmen durch den Kanal in einen frischen Empfänger und
/// zählt, was ankommt.
struct T2SimulationResult: Sendable {
    var locked = false
    var blocksGood = 0
    var blocksBad = 0
    var bbFramesGood = 0
    var packets = 0
    var validPackets = 0
    var estimatedSNR = 0.0
    var frames = 0
    var seconds = 0.0
    /// Rechenzeit nur im Empfänger.
    var receiverSeconds = 0.0
    var ldpcIterations = 0

    var blockRate: Double { blocksGood + blocksBad == 0 ? 0 : Double(blocksGood) / Double(blocksGood + blocksBad) }
}

enum T2Simulation {
    static func run(_ parameters: T2TestChannel.Parameters, frames: Int, seed: UInt64 = 1,
                    configure: (T2Receiver) -> Void = { _ in }) -> T2SimulationResult {
        let transmitter = T2TestTransmitter(seed: seed)
        let channel = T2TestChannel(parameters, occupiedFraction: transmitter.occupiedFraction)
        let receiver = T2Receiver()
        configure(receiver)
        final class Counter: @unchecked Sendable { var packets = 0; var valid = 0 }
        let counter = Counter()
        receiver.packetHandler = { packet in
            counter.packets += 1
            if T2TestTransmitter.isValidPacket(packet) { counter.valid += 1 }
        }
        let started = Date()
        var receiverTime = 0.0
        var pending = transmitter.frame()
        channel.calibrate(re: pending.re, im: pending.im)
        var stream = channel.silence(samples: 150_000)
        func feed(_ data: inout Data, all: Bool) {
            let block = 262_144
            var offset = data.startIndex
            while data.endIndex - offset >= block || (all && offset < data.endIndex) {
                let end = min(data.endIndex, offset + block)
                let chunk = data.subdata(in: offset..<end)
                let t = Date()
                receiver.process(chunk)
                receiverTime += Date().timeIntervalSince(t)
                offset = end
            }
            data = data.subdata(in: offset..<data.endIndex)
        }
        // Ein Rahmen mehr, damit der letzte gezählte vollständig im Puffer liegt.
        for index in 0..<(frames + 1) {
            stream += channel.process(re: pending.re, im: pending.im)
            feed(&stream, all: false)
            if index < frames { pending = transmitter.frame() }
        }
        stream += channel.silence(samples: 20_000)
        feed(&stream, all: true)
        let status = receiver.currentStatus()
        var result = T2SimulationResult()
        result.locked = status.locked
        result.blocksGood = status.blocksGood
        result.blocksBad = status.blocksBad
        result.bbFramesGood = status.bbFramesGood
        result.packets = counter.packets
        result.validPackets = counter.valid
        result.estimatedSNR = status.snr
        result.frames = status.frames
        result.ldpcIterations = status.ldpcIterations
        result.seconds = Date().timeIntervalSince(started)
        result.receiverSeconds = receiverTime
        return result
    }
}
