import Foundation

/// Master Information Block (36.331 MasterInformationBlock, 24 Bit).
struct LTEMIB: Sendable, Equatable {
    enum PHICHResource: Int, Sendable, CaseIterable {
        case oneSixth = 0, half, one, two

        var ng: Double { [1.0 / 6, 0.5, 1, 2][rawValue] }
        var text: String { ["1/6", "1/2", "1", "2"][rawValue] }
    }

    static let bandwidths = [6, 15, 25, 50, 75, 100]

    var nRB: Int
    var phichExtended: Bool
    var phichResource: PHICHResource
    /// Vollständige Rahmennummer (10 Bit) des Rahmens, in dem dekodiert wurde.
    var sfn: Int
    /// Zahl der Sendeantennen-Ports (aus der CRC-Maske).
    var ports: Int

    var bandwidthMHz: Double { [6: 1.4, 15: 3, 25: 5, 50: 10, 75: 15, 100: 20][nRB] ?? Double(nRB) * 0.2 }

    /// Die 24 Bit (SFN-Bits 9…2, Rest frei).
    func bits() -> [UInt8] {
        var out: [UInt8] = []
        let bw = Self.bandwidths.firstIndex(of: nRB) ?? 0
        for i in (0..<3).reversed() { out.append(UInt8((bw >> i) & 1)) }
        out.append(phichExtended ? 1 : 0)
        for i in (0..<2).reversed() { out.append(UInt8((phichResource.rawValue >> i) & 1)) }
        let high = (sfn >> 2) & 0xFF
        for i in (0..<8).reversed() { out.append(UInt8((high >> i) & 1)) }
        out += [UInt8](repeating: 0, count: 10)
        return out
    }

    static func parse(_ bits: [UInt8], ports: Int, segment: Int) -> LTEMIB? {
        guard bits.count >= 24 else { return nil }
        func value(_ range: Range<Int>) -> Int { range.reduce(0) { ($0 << 1) | Int(bits[$1]) } }
        let bw = value(0..<3)
        guard bw < bandwidths.count, let resource = PHICHResource(rawValue: value(4..<6)) else { return nil }
        return LTEMIB(nRB: bandwidths[bw], phichExtended: bits[3] == 1, phichResource: resource,
                      sfn: (value(6..<14) << 2) | segment, ports: ports)
    }

    /// CRC-Maske je Portzahl (36.212 Tabelle 5.3.1.1-1).
    static func antennaMask(ports: Int) -> UInt32 {
        switch ports {
        case 2: 0xFFFF
        case 4: 0x5555
        default: 0
        }
    }
}

/// Messwerte einer Zelle aus den CRS (Mittel über die ausgewerteten Teilrahmen).
struct LTEMeasurement: Sendable, Equatable {
    /// RSRP je RE, dBFS (bezogen auf Vollaussteuerung des Wandlers).
    var rsrpDBFS: Double
    var rsrqDB: Double
    var sinrDB: Double

    static func average(_ estimates: [LTEChannelEstimate]) -> LTEMeasurement? {
        guard !estimates.isEmpty else { return nil }
        let n = Float(estimates.count)
        let rsrp = estimates.reduce(Float(0)) { $0 + $1.rsrp } / n
        let noise = estimates.reduce(Float(0)) { $0 + $1.noise } / n
        let rssi = estimates.reduce(Float(0)) { $0 + $1.rssiPerRE } / n
        return LTEMeasurement(rsrpDBFS: 10 * log10(Double(max(rsrp, 1e-15))),
                              rsrqDB: 10 * log10(Double(max(rsrp, 1e-15)) / Double(max(12 * rssi, 1e-15))),
                              sinrDB: 10 * log10(Double(max(rsrp, 1e-15)) / Double(max(noise, 1e-15))))
    }
}

/// Physikalischer Rundsendekanal (36.211 6.6, 36.212 5.3.1).
enum LTEPBCH {
    static func bitsPerFrame(extendedCP: Bool) -> Int { extendedCP ? 432 : 480 }

    /// REs des PBCH in Teilrahmen 0 in Abbildungsreihenfolge (k zuerst, dann l).
    /// k bezieht sich auf das Raster von `layout` (mittlere 72 Unterträger).
    static func resourceElements(layout: LTECellLayout) -> [(symbol: Int, k: Int)] {
        let n = layout.symbolsPerSlot
        let k0 = layout.nsc / 2 - 36
        var out: [(Int, Int)] = []
        for l in 0..<4 {
            // Für 4 Ports reservierte CRS-Plätze bleiben frei, gleich wie viele Ports es gibt.
            let reserved = l == 0 || l == 1 || (layout.extendedCP && l == 3)
            for kp in 0..<72 {
                let k = k0 + kp
                if reserved, k % 3 == layout.vShift % 3 { continue }
                out.append((n + l, k))
            }
        }
        return out
    }

    /// Weiche Bits des PBCH eines Rahmens unter der Annahme `ports`.
    static func softBits(grid: LTESubframeGrid, estimate: LTEChannelEstimate, ports: Int) -> [Float] {
        let res = resourceElements(layout: grid.layout)
        let r = res.map { grid.symbols[$0.symbol][$0.k] }
        let h = (0..<max(ports, 1)).map { p in res.map { estimate.h[p][$0.symbol][$0.k] } }
        let (x, gains) = LTETransmitDiversity.decode(r, h: h, ports: ports)
        return LTEQPSK.llr(x, gains: gains, noise: estimate.noise)
    }

    /// Kombiniert Rahmen derselben 40-ms-Periode und dekodiert.
    /// `segments`: weiche Bits je Rahmen und deren Lage (SFN mod 4).
    static func decode(_ segments: [(llr: [Float], segment: Int)], pci: Int, ports: Int, extendedCP: Bool) -> [UInt8]? {
        let perFrame = bitsPerFrame(extendedCP: extendedCP)
        let e = 4 * perFrame
        let c = LTESequence.gold(UInt32(pci), count: e)
        var full = [Float](repeating: 0, count: e)
        for (llr, segment) in segments {
            for i in 0..<min(perFrame, llr.count) {
                let position = segment * perFrame + i
                full[position] += c[position] == 1 ? -llr[i] : llr[i]
            }
        }
        let d = LTERateMatching.convolutionalDematch(full, k: 40)
        let bits = LTEConvolutional.decode(d)
        guard LTECRC.check(bits, poly: LTECRC.crc16, length: 16, mask: LTEMIB.antennaMask(ports: ports)) else { return nil }
        return Array(bits[0..<24])
    }

    /// Sendeseite: kodierte und verwürfelte Bits aller vier Rahmen (für den Prüfsender).
    static func encode(_ mib: LTEMIB, pci: Int, extendedCP: Bool) -> [UInt8] {
        let e = 4 * bitsPerFrame(extendedCP: extendedCP)
        let withCRC = LTECRC.attach(mib.bits(), poly: LTECRC.crc16, length: 16, mask: LTEMIB.antennaMask(ports: mib.ports))
        let coded = LTERateMatching.convolutionalEncode(withCRC, count: e)
        return LTESequence.scramble(coded, cInit: UInt32(pci))
    }
}

/// Ergebnis der MIB-Auswertung über eine Aufnahme.
struct LTEMIBResult: Sendable {
    var mib: LTEMIB
    /// Rahmennummer des ersten vollständigen Rahmens der Aufnahme.
    var firstFrameSFN: Int
    var measurement: LTEMeasurement?
    var framesUsed: Int
}

enum LTEMIBDecoder {
    /// Dekodiert das MIB aus allen vollständigen Rahmen ab `frameStart`
    /// (Abtastwert eines Rahmenbeginns). `layout.nRB` bestimmt den
    /// betrachteten Ausschnitt (6 bei 1,92 MS/s).
    static func decode(re: [Float], im: [Float], frameStart: Int, layout: LTECellLayout,
                       numerology: LTENumerology, knownPorts: Int? = nil, frameScale: Double = 1) -> LTEMIBResult? {
        let demod = LTEDemodulator(numerology: numerology, layout: layout)
        var grids: [(index: Int, grid: LTESubframeGrid, estimate: LTEChannelEstimate)] = []
        var index = 0
        while true {
            let start = frameStart + Int((Double(index * numerology.frameLength) * frameScale).rounded())
            guard start + numerology.subframeLength <= re.count else { break }
            if start >= 0, let grid = demod.subframe(re: re, im: im, start: start, subframe: 0) {
                grids.append((index, grid, LTEChannelEstimator.estimate(grid)))
            }
            index += 1
        }
        guard !grids.isEmpty else { return nil }
        let measurement = LTEMeasurement.average(grids.map(\.estimate))
        let portOptions = knownPorts.map { [$0] } ?? [1, 2, 4]
        var soft: [Int: [[Float]]] = [:]
        for ports in portOptions {
            soft[ports] = grids.map { LTEPBCH.softBits(grid: $0.grid, estimate: $0.estimate, ports: ports) }
        }
        func result(_ bits: [UInt8], ports: Int, segment: Int, frame: Int) -> LTEMIBResult? {
            guard let mib = LTEMIB.parse(bits, ports: ports, segment: segment) else { return nil }
            let first = ((mib.sfn - frame) % 1024 + 1024) % 1024
            return LTEMIBResult(mib: mib, firstFrameSFN: first, measurement: measurement, framesUsed: grids.count)
        }
        // Einzelne Rahmen
        for (j, entry) in grids.enumerated() {
            for ports in portOptions {
                guard let llr = soft[ports]?[j] else { continue }
                for segment in 0..<4 {
                    if let bits = LTEPBCH.decode([(llr, segment)], pci: layout.pci, ports: ports, extendedCP: layout.extendedCP),
                       let r = result(bits, ports: ports, segment: segment, frame: entry.index) {
                        return r
                    }
                }
            }
        }
        // Kombination innerhalb einer 40-ms-Periode
        guard grids.count > 1 else { return nil }
        for ports in portOptions {
            guard let all = soft[ports] else { continue }
            for first in 0..<4 {
                var groups: [Int: [(llr: [Float], segment: Int, frame: Int)]] = [:]
                for (j, entry) in grids.enumerated() {
                    let position = first + entry.index
                    groups[position / 4, default: []].append((all[j], position % 4, entry.index))
                }
                for group in groups.values.sorted(by: { $0.count > $1.count }) where group.count > 1 {
                    if let bits = LTEPBCH.decode(group.map { ($0.llr, $0.segment) }, pci: layout.pci, ports: ports, extendedCP: layout.extendedCP),
                       let r = result(bits, ports: ports, segment: group[0].segment, frame: group[0].frame) {
                        return r
                    }
                }
            }
        }
        return nil
    }
}
