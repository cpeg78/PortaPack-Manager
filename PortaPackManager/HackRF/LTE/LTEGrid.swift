import Accelerate
import Foundation

/// Bekannte Eigenschaften einer Zelle, soweit für das Raster nötig.
struct LTECellLayout: Sendable, Hashable {
    var pci: Int
    var extendedCP: Bool
    /// Ressourcenblöcke des betrachteten Ausschnitts (6 = Mitte, sonst ganze Bandbreite).
    var nRB: Int

    var vShift: Int { pci % 6 }
    var nsc: Int { 12 * nRB }
    var symbolsPerSlot: Int { extendedCP ? 6 : 7 }
    var symbolsPerSubframe: Int { 2 * symbolsPerSlot }
}

/// OFDM-Raster eines Teilrahmens: `symbols[l][k]`, k aufsteigend in der Frequenz.
struct LTESubframeGrid: Sendable {
    var layout: LTECellLayout
    /// Teilrahmennummer 0…9 (für Folgen, die vom Slot abhängen).
    var subframe: Int
    var symbols: [[LTEC]]
}

/// Schneidet Teilrahmen aus dem Zeitsignal und transformiert sie.
final class LTEDemodulator: @unchecked Sendable {
    let numerology: LTENumerology
    let layout: LTECellLayout
    private let fft: LTEFFT
    private var outRe: [Float]
    private var outIm: [Float]

    init(numerology: LTENumerology, layout: LTECellLayout) {
        self.numerology = numerology
        self.layout = layout
        fft = LTEFFT(size: numerology.fftSize)
        outRe = [Float](repeating: 0, count: numerology.fftSize)
        outIm = [Float](repeating: 0, count: numerology.fftSize)
    }

    /// `start`: Abtastwert des Teilrahmenbeginns. Das FFT-Fenster beginnt eine
    /// halbe CP-Länge früher (Schutz vor Zeitfehlern), die Phasenrampe wird
    /// zurückgedreht. Werte = Amplitude je Unterträger (FFT / N).
    func subframe(re: [Float], im: [Float], start: Int, subframe: Int, symbolCount: Int? = nil) -> LTESubframeGrid? {
        let n = numerology.fftSize
        let count = symbolCount ?? numerology.symbolsPerSubframe
        guard start >= 0, start + numerology.subframeLength <= re.count else { return nil }
        let nsc = layout.nsc
        var symbols: [[LTEC]] = []
        symbols.reserveCapacity(count)
        let scale = 1 / Float(n)
        for l in 0..<count {
            let advance = numerology.cpLength(l % numerology.symbolsPerSlot) / 2
            let s = start + numerology.usefulStart(l) - advance
            re.withUnsafeBufferPointer { rp in
                im.withUnsafeBufferPointer { ip in
                    fft.forward(re: rp.baseAddress! + s, im: ip.baseAddress! + s, outRe: &outRe, outIm: &outIm)
                }
            }
            var row = [LTEC](repeating: .zero, count: nsc)
            for k in 0..<nsc {
                let m = LTENumerology.frequencyIndex(k, nsc: nsc)
                let bin = (m + n) % n
                let rot = LTEC.cis(2 * .pi * Double(m * advance) / Double(n))
                row[k] = scale * (LTEC(outRe[bin], outIm[bin]) * rot)
            }
            symbols.append(row)
        }
        return LTESubframeGrid(layout: layout, subframe: subframe, symbols: symbols)
    }
}

/// Zellspezifische Referenzsignale (36.211 6.10.1).
enum LTECRS {
    /// Symbole (im Teilrahmen) mit Pilot des Ports.
    static func symbols(port: Int, extendedCP: Bool) -> [Int] {
        let n = extendedCP ? 6 : 7
        return port < 2 ? [0, n - 3, n, 2 * n - 3] : [1, n + 1]
    }

    /// Versatz (k mod 6) des Ports im Symbol `l` (im Slot) von Slot `ns`.
    static func offset(port: Int, l: Int, ns: Int, vShift: Int) -> Int {
        let v: Int
        switch port {
        case 0: v = l == 0 ? 0 : 3
        case 1: v = l == 0 ? 3 : 0
        case 2: v = 3 * (ns % 2)
        default: v = 3 + 3 * (ns % 2)
        }
        return (v + vShift) % 6
    }

    /// r(m′) für die 2·nRB Piloten des Ausschnitts (m′ = m + 110 − nRB).
    static func sequence(pci: Int, ns: Int, l: Int, extendedCP: Bool, nRB: Int) -> [LTEC] {
        let cInit = UInt32(1024 * (7 * (ns + 1) + l + 1) * (2 * pci + 1) + 2 * pci + (extendedCP ? 0 : 1))
        let c = LTESequence.gold(cInit, count: 4 * lteMaxRB)
        let a = LTEQPSK.amplitude
        return (0..<(2 * nRB)).map { m in
            let mp = m + lteMaxRB - nRB
            return LTEC(c[2 * mp] == 0 ? a : -a, c[2 * mp + 1] == 0 ? a : -a)
        }
    }

    /// Ist (Symbol im Teilrahmen, k) ein Pilot eines der ersten `ports` Ports?
    static func isReference(symbol: Int, k: Int, ports: Int, layout: LTECellLayout) -> Bool {
        let n = layout.symbolsPerSlot
        let l = symbol % n, ns = symbol / n
        for p in 0..<ports {
            let hit = p < 2 ? (l == 0 || l == n - 3) : l == 1
            if hit, k % 6 == offset(port: p, l: l, ns: ns, vShift: layout.vShift) { return true }
        }
        return false
    }
}

let lteMaxRB = 110

/// Kanalschätzung aus den CRS und Messwerte.
struct LTEChannelEstimate: Sendable {
    /// h[port][symbol][k]
    var h: [[[LTEC]]]
    /// Rauschleistung je Unterträger (σ²).
    var noise: Float
    /// Mittlere Leistung der Port-0-Piloten abzüglich Rauschen (je RE).
    var rsrp: Float
    /// Mittlere Leistung je RE in den Symbolen mit Port-0-Piloten.
    var rssiPerRE: Float
    /// Mittlere Pilotleistung je Port (zur Portzahl-Schätzung).
    var portPower: [Float]

    var sinrDB: Double { 10 * log10(Double(max(rsrp, 1e-15)) / Double(max(noise, 1e-15))) }
    var rsrpDBFS: Double { 10 * log10(Double(max(rsrp, 1e-15))) }
    /// RSRQ = RSRP / (RSSI je RB) · Bezug auf 1 RB → RSRP / (12 · RE-Leistung).
    var rsrqDB: Double { 10 * log10(Double(max(rsrp, 1e-15)) / Double(max(12 * rssiPerRE, 1e-15))) }
}

enum LTEChannelEstimator {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [LTEC]] = [:]

    private static func pilots(pci: Int, ns: Int, l: Int, extendedCP: Bool, nRB: Int) -> [LTEC] {
        let key = "\(pci)-\(ns)-\(l)-\(extendedCP)-\(nRB)"
        if let hit = cacheLock.withLock({ cache[key] }) { return hit }
        let value = LTECRS.sequence(pci: pci, ns: ns, l: l, extendedCP: extendedCP, nRB: nRB)
        cacheLock.withLock {
            if cache.count > 4000 { cache.removeAll() }
            cache[key] = value
        }
        return value
    }

    /// Schätzt den Kanal aller vier Ports (fehlende Ports liefern Rauschen).
    static func estimate(_ grid: LTESubframeGrid, ports: Int = 4) -> LTEChannelEstimate {
        let layout = grid.layout
        let nsc = layout.nsc
        let nSym = grid.symbols.count
        let n = layout.symbolsPerSlot
        var h: [[[LTEC]]] = []
        var residual: Float = 0, residualCount = 0
        var rsrpAcc: Float = 0, rsrpCount = 0
        var portPower: [Float] = []
        for p in 0..<ports {
            var pilotSymbols: [Int] = []
            var pilotRows: [[LTEC]] = []
            var powerAcc: Float = 0, powerCount = 0
            for symbol in LTECRS.symbols(port: p, extendedCP: layout.extendedCP) where symbol < nSym {
                let l = symbol % n, slot = symbol / n
                let ns = 2 * grid.subframe + slot
                let ref = pilots(pci: layout.pci, ns: ns, l: l, extendedCP: layout.extendedCP, nRB: layout.nRB)
                let off = LTECRS.offset(port: p, l: l, ns: ns, vShift: layout.vShift)
                let count = 2 * layout.nRB
                var raw = [LTEC](repeating: .zero, count: count)
                for m in 0..<count {
                    let k = 6 * m + off
                    // |r|² = 1
                    raw[m] = grid.symbols[symbol][k] * ref[m].conj
                    powerAcc += raw[m].norm
                    powerCount += 1
                }
                // Glätten über drei Piloten
                var smooth = raw
                for m in 0..<count {
                    if m > 0, m < count - 1 {
                        smooth[m] = 0.25 * raw[m - 1] + 0.5 * raw[m] + 0.25 * raw[m + 1]
                    }
                }
                if p == 0 {
                    for m in 1..<(count - 1) {
                        residual += (raw[m] - smooth[m]).norm
                        residualCount += 1
                    }
                }
                // Auf alle Unterträger verteilen (linear zwischen Piloten)
                var row = [LTEC](repeating: .zero, count: nsc)
                for k in 0..<nsc {
                    let x = Double(k - off) / 6
                    if x <= 0 {
                        row[k] = smooth[0]
                    } else if x >= Double(count - 1) {
                        row[k] = smooth[count - 1]
                    } else {
                        let i = Int(x)
                        let w = Float(x - Double(i))
                        row[k] = (1 - w) * smooth[i] + w * smooth[i + 1]
                    }
                }
                pilotSymbols.append(symbol)
                pilotRows.append(row)
            }
            portPower.append(powerCount > 0 ? powerAcc / Float(powerCount) : 0)
            if p == 0 {
                rsrpAcc = powerAcc
                rsrpCount = powerCount
            }
            // Zeitlich interpolieren
            var perSymbol: [[LTEC]] = []
            for t in 0..<nSym {
                guard !pilotSymbols.isEmpty else {
                    perSymbol.append([LTEC](repeating: .zero, count: nsc))
                    continue
                }
                if let exact = pilotSymbols.firstIndex(of: t) {
                    perSymbol.append(pilotRows[exact])
                    continue
                }
                let before = pilotSymbols.lastIndex { $0 < t }
                let after = pilotSymbols.firstIndex { $0 > t }
                switch (before, after) {
                case let (b?, a?):
                    let w = Float(t - pilotSymbols[b]) / Float(pilotSymbols[a] - pilotSymbols[b])
                    perSymbol.append((0..<nsc).map { (1 - w) * pilotRows[b][$0] + w * pilotRows[a][$0] })
                case let (b?, nil):
                    perSymbol.append(pilotRows[b])
                case let (nil, a?):
                    perSymbol.append(pilotRows[a])
                default:
                    perSymbol.append([LTEC](repeating: .zero, count: nsc))
                }
            }
            h.append(perSymbol)
        }
        // Rest nach Glättung: e = n·(1 − ½) − ¼(n₋ + n₊) → Var = 0,375 σ²
        let noise = residualCount > 0 ? residual / Float(residualCount) / 0.375 : 1e-9
        var rssi: Float = 0, rssiCount = 0
        for symbol in LTECRS.symbols(port: 0, extendedCP: layout.extendedCP) where symbol < nSym {
            for v in grid.symbols[symbol] { rssi += v.norm }
            rssiCount += nsc
        }
        let rsrp = max(rsrpCount > 0 ? rsrpAcc / Float(rsrpCount) - noise : 0, 1e-15)
        return LTEChannelEstimate(h: h, noise: max(noise, 1e-15), rsrp: rsrp,
                                  rssiPerRE: rssiCount > 0 ? rssi / Float(rssiCount) : 0, portPower: portPower)
    }
}

/// Sendediversität (36.211 6.3.4.3): Entzerrung von SFBC (2 Ports) und
/// SFBC+FSTD (4 Ports).
enum LTETransmitDiversity {
    /// `r`: empfangene Werte in Abbildungsreihenfolge, `h[p][i]` Kanal je Port
    /// und RE. Liefert Symbole in Schichtreihenfolge und je Symbol die
    /// wirksame Leistungsverstärkung (für die LLR).
    static func decode(_ r: [LTEC], h: [[LTEC]], ports: Int) -> (symbols: [LTEC], gains: [Float]) {
        let count = r.count
        var x = [LTEC](repeating: .zero, count: count)
        var g = [Float](repeating: 0, count: count)
        switch ports {
        case 1:
            for i in 0..<count {
                let hh = h[0][i]
                let p = max(hh.norm, 1e-15)
                x[i] = (1 / p) * (r[i] * hh.conj)
                g[i] = p
            }
        case 2:
            var i = 0
            while i + 1 < count {
                pair(r, h, i, 0, 1, &x, &g)
                i += 2
            }
        default:
            var i = 0
            while i + 3 < count {
                pair(r, h, i, 0, 2, &x, &g)
                pair(r, h, i + 2, 1, 3, &x, &g)
                i += 4
            }
        }
        return (x, g)
    }

    private static func pair(_ r: [LTEC], _ h: [[LTEC]], _ i: Int, _ pa: Int, _ pb: Int, _ x: inout [LTEC], _ g: inout [Float]) {
        let h0 = 0.5 * (h[pa][i] + h[pa][i + 1])
        let h1 = 0.5 * (h[pb][i] + h[pb][i + 1])
        let gain = max(h0.norm + h1.norm, 1e-15)
        let r0 = r[i], r1 = r[i + 1]
        let s = Float(2.0.squareRoot()) / gain
        x[i] = s * (h0.conj * r0 + h1 * r1.conj)
        x[i + 1] = s * (h0.conj * r1 - h1 * r0.conj)
        g[i] = gain / 2
        g[i + 1] = gain / 2
    }

    /// Sendeseite (für den Prüfsender): Symbole → Werte je Port und RE.
    static func encode(_ d: [LTEC], ports: Int) -> [[LTEC]] {
        let count = d.count
        var y = [[LTEC]](repeating: [LTEC](repeating: .zero, count: count), count: ports)
        let s = Float(1 / 2.0.squareRoot())
        switch ports {
        case 1:
            y[0] = d
        case 2:
            var i = 0
            while i + 1 < count {
                y[0][i] = s * d[i]
                y[1][i] = s * -(d[i + 1].conj)
                y[0][i + 1] = s * d[i + 1]
                y[1][i + 1] = s * d[i].conj
                i += 2
            }
        default:
            var i = 0
            while i + 3 < count {
                y[0][i] = s * d[i]
                y[2][i] = s * -(d[i + 1].conj)
                y[0][i + 1] = s * d[i + 1]
                y[2][i + 1] = s * d[i].conj
                y[1][i + 2] = s * d[i + 2]
                y[3][i + 2] = s * -(d[i + 3].conj)
                y[1][i + 3] = s * d[i + 3]
                y[3][i + 3] = s * d[i + 2].conj
                i += 4
            }
        }
        return y
    }
}
