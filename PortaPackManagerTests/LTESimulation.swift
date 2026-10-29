import Foundation
@testable import PortaPackManager

/// Prüfsender für den LTE-Empfänger: erzeugt einen Abwärtsstrecken-Rahmen nach
/// 36.211/36.212 (PSS, SSS, CRS, PBCH mit MIB, PCFICH, PHICH-Füllung, PDCCH mit
/// DCI 1A/1C für SI-RNTI, PDSCH mit turbokodiertem SIB1, Füllverkehr) und den
/// Kanal (Ports mit eigener Dämpfung/Phase, Echo, Frequenzablage, Rauschen,
/// 8-Bit-Wandler).
struct LTESimRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Float {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }

    mutating func bit() -> UInt8 { UInt8(next() & 1) }
}

struct LTETestCell {
    var pci: Int
    var nRB: Int
    var ports: Int = 1
    var extendedCP = false
    var tdd = false
    var phichExtended = false
    var phichResource: LTEMIB.PHICHResource = .one
    /// Bandbreite laut MIB (darf vom erzeugten Ausschnitt abweichen, z. B. 6-RB-Sicht).
    var mibRB: Int?
    var sib1: LTESIB1?
    var dci = LTEDCI(format: .f1A, distributed: false, gap2: false, riv: 0, mcs: 5, rv: nil, nPRB1A: 3)
    /// SIB1-PRBs (lokalisiert: Start/Länge, für 1A).
    var sib1Start = 2
    var sib1Length = 4
    var cfi = 2
    var aggregation = 4
    var load = true
}

enum LTETransmitter {
    /// Erzeugt `frames` Rahmen ab `firstSFN` bei `fftSize`·15 kHz; Ports mit `portGains` überlagert.
    static func generate(_ cell: LTETestCell, fftSize: Int, frames: Int, firstSFN: Int, seed: UInt64 = 1,
                         portGains: [LTEC] = [LTEC(1, 0), LTEC(0.45, 0.6), LTEC(-0.5, 0.4), LTEC(0.3, -0.7)]) -> (re: [Float], im: [Float]) {
        var rng = LTESimRNG(seed: seed)
        let num = LTENumerology(fftSize: fftSize, extendedCP: cell.extendedCP)
        let layout = LTECellLayout(pci: cell.pci, extendedCP: cell.extendedCP, nRB: cell.nRB)
        let nsc = layout.nsc
        let n = layout.symbolsPerSlot
        let nSym = 2 * n
        let mib = LTEMIB(nRB: cell.mibRB ?? cell.nRB, phichExtended: cell.phichExtended, phichResource: cell.phichResource,
                         sfn: 0, ports: cell.ports)
        let fft = LTEFFT(size: fftSize)
        var outRe: [Float] = [], outIm: [Float] = []
        outRe.reserveCapacity(frames * num.frameLength)
        outIm.reserveCapacity(frames * num.frameLength)
        let qpskA = LTEQPSK.amplitude
        func randomSymbol() -> LTEC {
            LTEC(rng.bit() == 0 ? qpskA : -qpskA, rng.bit() == 0 ? qpskA : -qpskA)
        }

        for f in 0..<frames {
            let sfn = (firstSFN + f) % 1024
            var frameMIB = mib
            frameMIB.sfn = sfn
            let pbchBits = LTEPBCH.encode(frameMIB, pci: cell.pci, extendedCP: cell.extendedCP)
            for sf in 0..<10 {
                var grid = [[[LTEC]]](repeating: [[LTEC]](repeating: [LTEC](repeating: .zero, count: nsc), count: nSym), count: cell.ports)
                var used = [[Bool]](repeating: [Bool](repeating: false, count: nsc), count: nSym)
                func place(_ res: [(symbol: Int, k: Int)], _ symbols: [LTEC]) {
                    let y = LTETransmitDiversity.encode(symbols, ports: cell.ports)
                    for (i, re) in res.enumerated() where i < symbols.count {
                        for p in 0..<cell.ports { grid[p][re.symbol][re.k] = y[p][i] }
                        used[re.symbol][re.k] = true
                    }
                }
                // CRS (Plätze aller vorhandenen Ports sind auf den anderen Ports leer)
                for p in 0..<cell.ports {
                    for symbol in LTECRS.symbols(port: p, extendedCP: cell.extendedCP) {
                        let l = symbol % n, ns = 2 * sf + symbol / n
                        let ref = LTECRS.sequence(pci: cell.pci, ns: ns, l: l, extendedCP: cell.extendedCP, nRB: cell.nRB)
                        let off = LTECRS.offset(port: p, l: l, ns: ns, vShift: layout.vShift)
                        for m in 0..<(2 * cell.nRB) {
                            grid[p][symbol][6 * m + off] = ref[m]
                            used[symbol][6 * m + off] = true
                        }
                    }
                }
                // PSS/SSS
                let pssSymbol: Int?, sssSymbol: Int?
                if cell.tdd {
                    pssSymbol = (sf == 1 || sf == 6) ? 2 : nil
                    sssSymbol = (sf == 0 || sf == 5) ? nSym - 1 : nil
                } else {
                    pssSymbol = (sf == 0 || sf == 5) ? n - 1 : nil
                    sssSymbol = (sf == 0 || sf == 5) ? n - 2 : nil
                }
                if let s = pssSymbol {
                    let d = LTECellSearch.pss(cell.pci % 3)
                    for i in 0..<62 { grid[0][s][nsc / 2 - 31 + i] = d[i] }
                    for k in (nsc / 2 - 36)..<(nsc / 2 + 36) { used[s][k] = true }
                }
                if let s = sssSymbol {
                    let d = LTECellSearch.sss(nid1: cell.pci / 3, nid2: cell.pci % 3, subframe5: sf == 5)
                    for i in 0..<62 { grid[0][s][nsc / 2 - 31 + i] = LTEC(d[i], 0) }
                    for k in (nsc / 2 - 36)..<(nsc / 2 + 36) { used[s][k] = true }
                }
                // PBCH
                if sf == 0 {
                    let res = LTEPBCH.resourceElements(layout: layout)
                    let per = LTEPBCH.bitsPerFrame(extendedCP: cell.extendedCP)
                    let seg = sfn % 4
                    let symbols = LTEQPSK.modulate(Array(pbchBits[(seg * per)..<((seg + 1) * per)]))
                    place(res, symbols)
                    for l in 0..<4 { for k in (nsc / 2 - 36)..<(nsc / 2 + 36) { used[n + l][k] = true } }
                }
                // Steuerbereich und SIB1 (nur bei voller Bandbreite)
                var controlSymbols = 0
                if cell.mibRB == nil || cell.mibRB == cell.nRB {
                    let control = LTEControlLayout(layout: layout, ports: cell.ports, cfi: cell.cfi,
                                                   phichExtended: cell.phichExtended, phichResource: cell.phichResource)
                    controlSymbols = control.controlSymbols
                    // PCFICH
                    let cw = LTESequence.scramble(LTEPCFICH.codeword(cell.cfi), cInit: LTEPCFICH.scramblingInit(pci: cell.pci, subframe: sf))
                    let pcfichSymbols = LTEQPSK.modulate(cw)
                    for (i, reg) in control.pcfich.enumerated() {
                        place(reg.k.map { (reg.symbol, $0) }, Array(pcfichSymbols[(4 * i)..<(4 * i + 4)]))
                    }
                    // PHICH: Füllung
                    for reg in control.phich { place(reg.k.map { (reg.symbol, $0) }, (0..<4).map { _ in randomSymbol() }) }
                    // PDCCH
                    let sib1Subframe = sf == 5 && sfn % 2 == 0 && cell.sib1 != nil && !cell.tdd
                    var bits = (0..<(8 * control.pdcch.count)).map { _ in rng.bit() }
                    var pdschDCI: LTEDCI?
                    if sib1Subframe {
                        var dci = cell.dci
                        if dci.format == .f1A {
                            dci.riv = LTEAllocation.encodeRIV(start: cell.sib1Start, length: cell.sib1Length, n: cell.nRB)
                            dci.rv = LTEAllocation.sib1RV(sfn: sfn)
                        } else {
                            let step = LTEAllocation.rbStep(cell.nRB)
                            let vrb = LTEAllocation.vrbCount(nRB: cell.nRB, gap2: dci.gap2) / step
                            dci.riv = LTEAllocation.encodeRIV(start: cell.sib1Start / step, length: cell.sib1Length / step, n: vrb)
                        }
                        let size = dci.format == .f1A ? LTEDCI.size1A(nRB: cell.nRB) : LTEDCI.size1C(nRB: cell.nRB)
                        var payload = dci.bits(nRB: cell.nRB)
                        payload = Array(payload.prefix(size))
                        let withCRC = LTECRC.attach(payload, poly: LTECRC.crc16, length: 16, mask: LTEDCI.siRNTI)
                        let coded = LTERateMatching.convolutionalEncode(withCRC, count: 72 * cell.aggregation)
                        for (i, b) in coded.enumerated() { bits[i] = b }
                        pdschDCI = dci
                    }
                    let scrambled = LTESequence.scramble(bits, cInit: LTEPDCCH.scramblingInit(pci: cell.pci, subframe: sf))
                    let pdcchSymbols = LTEQPSK.modulate(scrambled)
                    for (m, reg) in control.pdcch.enumerated() {
                        place(reg.k.map { (reg.symbol, $0) }, Array(pdcchSymbols[(4 * m)..<(4 * m + 4)]))
                    }
                    // Übrige Steuer-REs (REG-Reste ohne Zuordnung) leer lassen, aber belegt markieren.
                    for l in 0..<controlSymbols { for k in 0..<nsc { used[l][k] = true } }
                    // PDSCH mit SIB1
                    if let dci = pdschDCI, let sib1 = cell.sib1, let prbs = LTEAllocation.prbs(for: dci, nRB: cell.nRB),
                       let tbs = LTEAllocation.transportBlockSize(dci) {
                        var tb = sib1.encode()
                        precondition(tb.count <= tbs, "SIB1 passt nicht in den Transportblock")
                        tb += [UInt8](repeating: 0, count: tbs - tb.count)
                        let res = LTEPDSCH.resourceElements(layout: layout, ports: cell.ports, controlSymbols: controlSymbols, prbs: prbs, subframe: sf)
                        let usable = cell.ports == 4 ? res.count / 4 * 4 : cell.ports == 2 ? res.count / 2 * 2 : res.count
                        let rv = dci.rv ?? LTEAllocation.sib1RV(sfn: sfn)
                        let coded = LTEPDSCH.encode(tb, count: 2 * usable, rv: rv)!
                        let cInit = LTEPDSCH.scramblingInit(rnti: LTEDCI.siRNTI, subframe: sf, pci: cell.pci)
                        let symbols = LTEQPSK.modulate(LTESequence.scramble(coded, cInit: cInit))
                        place(Array(res[0..<usable]), symbols)
                    }
                }
                // Füllverkehr
                if cell.load {
                    let scale = Float(1 / Double(cell.ports).squareRoot())
                    for symbol in controlSymbols..<nSym {
                        for k in 0..<nsc where !used[symbol][k] {
                            if LTECRS.isReference(symbol: symbol, k: k, ports: cell.ports, layout: layout) { continue }
                            for p in 0..<cell.ports { grid[p][symbol][k] = scale * randomSymbol() }
                        }
                    }
                }
                // OFDM
                var sfRe = [Float](repeating: 0, count: num.subframeLength)
                var sfIm = [Float](repeating: 0, count: num.subframeLength)
                for p in 0..<cell.ports {
                    let g = portGains[p]
                    for symbol in 0..<nSym {
                        var binsRe = [Float](repeating: 0, count: fftSize), binsIm = [Float](repeating: 0, count: fftSize)
                        for k in 0..<nsc {
                            let v = g * grid[p][symbol][k]
                            let bin = num.bin(k, nsc: nsc)
                            binsRe[bin] = v.re
                            binsIm[bin] = v.im
                        }
                        let t = fft.inverse(binsRe, binsIm)
                        let useful = num.usefulStart(symbol)
                        let cp = num.cpLength(symbol % n)
                        for i in 0..<fftSize {
                            sfRe[useful + i] += t.re[i]
                            sfIm[useful + i] += t.im[i]
                        }
                        for i in 0..<cp {
                            sfRe[useful - cp + i] += t.re[fftSize - cp + i]
                            sfIm[useful - cp + i] += t.im[fftSize - cp + i]
                        }
                    }
                }
                outRe += sfRe
                outIm += sfIm
            }
        }
        return (outRe, outIm)
    }

    /// Kanal: Vorlauf (Rauschen), Echo, Frequenzablage, Rauschen je RE (Bezug: RE-Leistung 1 bei `fftSize`).
    /// `clockPPM`: Taktabweichung des Empfängers (Wandler läuft um ε schneller →
    /// mehr Abtastwerte je Rahmen); die passende Frequenzablage gibt `cfoHz` an.
    static func channel(_ input: (re: [Float], im: [Float]), fftSize: Int, snrDB: Double, cfoHz: Double, delay: Int,
                        echo: (delay: Int, gain: LTEC)? = nil, clockPPM: Double? = nil, seed: UInt64 = 7) -> (re: [Float], im: [Float]) {
        var rng = LTESimRNG(seed: seed)
        let rate = Double(fftSize) * 15_000
        let signal = clockPPM.map { resample(input, ppm: $0) } ?? input
        let count = signal.re.count + delay
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        for i in 0..<signal.re.count {
            re[delay + i] = signal.re[i]
            im[delay + i] = signal.im[i]
        }
        if let echo {
            let r0 = re, i0 = im
            for i in echo.delay..<count {
                let v = echo.gain * LTEC(r0[i - echo.delay], i0[i - echo.delay])
                re[i] += v.re
                im[i] += v.im
            }
        }
        LTEFrontEnd.shift(&re, &im, hz: -cfoHz, rate: rate)
        let sigma = Float((Double(fftSize) / pow(10, snrDB / 10) / 2).squareRoot())
        for i in 0..<count {
            re[i] += sigma * rng.gaussian()
            im[i] += sigma * rng.gaussian()
        }
        return (re, im)
    }

    /// Gefensterte Sinc-Interpolation (32 Stützstellen): Empfangswert n liegt bei Sendezeit n/(1+ε).
    static func resample(_ s: (re: [Float], im: [Float]), ppm: Double) -> (re: [Float], im: [Float]) {
        let ratio = 1 / (1 + ppm * 1e-6)
        let count = Int(Double(s.re.count - 40) / ratio)
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        let half = 16
        for n in 0..<count {
            let t = Double(n) * ratio
            let base = Int(t)
            let frac = t - Double(base)
            var accRe: Float = 0, accIm: Float = 0
            for k in (-half + 1)...half {
                let index = base + k
                guard index >= 0, index < s.re.count else { continue }
                let u = Double(k) - frac
                let sinc = abs(u) < 1e-9 ? 1 : sin(.pi * u) / (.pi * u)
                let w = 0.42 + 0.5 * cos(.pi * u / Double(half)) + 0.08 * cos(2 * .pi * u / Double(half))
                let h = Float(sinc * w)
                accRe += h * s.re[index]
                accIm += h * s.im[index]
            }
            re[n] = accRe
            im[n] = accIm
        }
        return (re, im)
    }

    /// 8-Bit-Wandler: auf `rmsDBFS` aussteuern, runden, begrenzen.
    static func quantize(_ signal: (re: [Float], im: [Float]), rmsDBFS: Double = -18) -> Data {
        let n = signal.re.count
        var power = 0.0
        for i in 0..<n { power += Double(signal.re[i] * signal.re[i] + signal.im[i] * signal.im[i]) }
        let rms = (power / Double(max(n, 1)) / 2).squareRoot()
        let scale = Float(pow(10, rmsDBFS / 20) * 128 / max(rms, 1e-12))
        var bytes = [Int8](repeating: 0, count: 2 * n)
        for i in 0..<n {
            bytes[2 * i] = Int8(max(-127, min(127, (signal.re[i] * scale).rounded())))
            bytes[2 * i + 1] = Int8(max(-127, min(127, (signal.im[i] * scale).rounded())))
        }
        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func add(_ a: (re: [Float], im: [Float]), _ b: (re: [Float], im: [Float]), gain: Float = 1) -> (re: [Float], im: [Float]) {
        let n = min(a.re.count, b.re.count)
        return ((0..<n).map { a.re[$0] + gain * b.re[$0] }, (0..<n).map { a.im[$0] + gain * b.im[$0] })
    }

    /// Verschiebt um +hz (Träger liegt dann bei +hz).
    static func shifted(_ s: (re: [Float], im: [Float]), hz: Double, rate: Double) -> (re: [Float], im: [Float]) {
        var re = s.re, im = s.im
        LTEFrontEnd.shift(&re, &im, hz: -hz, rate: rate)
        return (re, im)
    }
}
