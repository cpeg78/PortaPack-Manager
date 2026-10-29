import Foundation

/// SystemInformationBlockType1 (36.331), soweit für die Anzeige nötig.
struct LTESIB1: Sendable, Equatable {
    struct PLMN: Sendable, Hashable {
        var mcc: String
        var mnc: String

        var text: String { "\(mcc)-\(mnc)" }
        var operatorName: String? { LTEOperator.name(mcc: mcc, mnc: mnc) }
    }

    var plmns: [PLMN]
    var tac: Int
    /// 28 Bit: eNB-Kennung (20 Bit) und Zellnummer (8 Bit).
    var cellIdentity: Int
    var cellBarred: Bool
    var intraFreqReselectionAllowed: Bool
    var qRxLevMinDBm: Int
    var pMax: Int?
    var freqBandIndicator: Int

    var enbID: Int { cellIdentity >> 8 }
    var localCellID: Int { cellIdentity & 0xFF }
    var operatorName: String? { plmns.lazy.compactMap(\.operatorName).first }

    /// Liest eine BCCH-DL-SCH-Nachricht (UPER) mit SIB1.
    static func parse(_ bits: [UInt8]) -> LTESIB1? {
        var reader = UPERReader(bits: bits)
        do {
            // BCCH-DL-SCH-MessageType: c1 (0), darin systemInformationBlockType1 (1)
            guard try reader.bit() == 0, try reader.bit() == 1 else { return nil }
            let hasPMax = try reader.bit() == 1
            _ = try reader.bit() // tdd-Config
            _ = try reader.bit() // nonCriticalExtension
            // cellAccessRelatedInfo
            let hasCSG = try reader.bit() == 1
            let count = try reader.value(3) + 1
            var plmns: [PLMN] = []
            var lastMCC = ""
            for _ in 0..<count {
                let hasMCC = try reader.bit() == 1
                if hasMCC { lastMCC = try (0..<3).map { _ in String(try reader.value(4)) }.joined() }
                let mncLength = try reader.bit() == 1 ? 3 : 2
                let mnc = try (0..<mncLength).map { _ in String(try reader.value(4)) }.joined()
                _ = try reader.bit() // cellReservedForOperatorUse
                guard !lastMCC.isEmpty else { return nil }
                plmns.append(PLMN(mcc: lastMCC, mnc: mnc))
            }
            let tac = try reader.value(16)
            let cellIdentity = try reader.value(28)
            let barred = try reader.bit() == 0
            let intraAllowed = try reader.bit() == 0
            _ = try reader.bit() // csg-Indication
            if hasCSG { _ = try reader.value(27) }
            // cellSelectionInfo
            let hasOffset = try reader.bit() == 1
            let qRxLevMin = (try reader.value(6) - 70) * 2
            if hasOffset { _ = try reader.value(3) }
            let pMax = hasPMax ? try reader.value(6) - 30 : nil
            let band = try reader.value(6) + 1
            return LTESIB1(plmns: plmns, tac: tac, cellIdentity: cellIdentity, cellBarred: barred,
                           intraFreqReselectionAllowed: intraAllowed, qRxLevMinDBm: qRxLevMin, pMax: pMax,
                           freqBandIndicator: band)
        } catch {
            return nil
        }
    }

    /// Sendeseite (Prüfsender): vollständige Nachricht mit einer SI-Planung.
    func encode() -> [UInt8] {
        var w = UPERWriter()
        w.put(0, 1)
        w.put(1, 1)
        w.put(pMax == nil ? 0 : 1, 1)
        w.put(0, 1)
        w.put(0, 1)
        w.put(0, 1) // kein csg-Identity
        w.put(plmns.count - 1, 3)
        var lastMCC = ""
        for plmn in plmns {
            if plmn.mcc == lastMCC {
                w.put(0, 1)
            } else {
                w.put(1, 1)
                for ch in plmn.mcc { w.put(Int(String(ch)) ?? 0, 4) }
                lastMCC = plmn.mcc
            }
            w.put(plmn.mnc.count == 3 ? 1 : 0, 1)
            for ch in plmn.mnc { w.put(Int(String(ch)) ?? 0, 4) }
            w.put(1, 1)
        }
        w.put(tac, 16)
        w.put(cellIdentity, 28)
        w.put(cellBarred ? 0 : 1, 1)
        w.put(intraFreqReselectionAllowed ? 0 : 1, 1)
        w.put(0, 1)
        w.put(0, 1)
        w.put(qRxLevMinDBm / 2 + 70, 6)
        if let pMax { w.put(pMax + 30, 6) }
        w.put(freqBandIndicator - 1, 6)
        // schedulingInfoList: eine SI-Nachricht (rf16) mit SIB3
        w.put(0, 5)
        w.put(1, 3)
        w.put(1, 5)
        w.put(0, 1)
        w.put(0, 4)
        w.put(4, 3) // si-WindowLength ms15
        w.put(7, 5) // systemInfoValueTag
        return w.bits
    }
}

struct UPERReader {
    struct End: Error {}
    let bits: [UInt8]
    var position = 0

    mutating func bit() throws -> UInt8 {
        guard position < bits.count else { throw End() }
        defer { position += 1 }
        return bits[position]
    }

    mutating func value(_ n: Int) throws -> Int {
        var v = 0
        for _ in 0..<n { v = (v << 1) | Int(try bit()) }
        return v
    }
}

struct UPERWriter {
    var bits: [UInt8] = []

    mutating func put(_ value: Int, _ n: Int) {
        for i in (0..<n).reversed() { bits.append(UInt8((value >> i) & 1)) }
    }
}

/// Liest SIB1 aus einer auf die Zelle zentrierten 19,2-MS/s-Aufnahme.
enum LTESIB1Decoder {
    struct Outcome: Sendable {
        var sib1: LTESIB1?
        var dci: LTEDCI?
        /// Ausgewertete SIB1-Übertragungen (Teilrahmen 5 gerader Rahmen).
        var transmissions = 0
        var cfi: Int?
        var note: String
        var measurement: LTEMeasurement?
    }

    static let numerology = LTENumerology(fftSize: 1280, extendedCP: false)

    /// `carrierHz`: Trägerfrequenz – aus Ablage/Träger folgt die Taktabweichung
    /// des HackRF (gleicher Quarz für Mischer und Wandler), die Rahmenlänge
    /// wird danach nachgeführt.
    static func decode(re inRe: [Float], im inIm: [Float], pci: Int, mib: LTEMIB, extendedCP: Bool, tdd: Bool,
                       cfoGuessHz: Double, carrierHz: Double = 0) -> Outcome {
        guard !extendedCP else { return Outcome(note: String(localized: "Netzbetreiber lesen geht nur bei normalem Schutzintervall.")) }
        guard !tdd else { return Outcome(note: String(localized: "Netzbetreiber lesen geht nur bei FDD-Zellen.")) }
        // Wiederfinden auf 1,92 MS/s
        let narrow = LTEFrontEnd.channel(re: inRe, im: inIm, offsetHz: 0)
        let hypotheses = [cfoGuessHz - 5000, cfoGuessHz, cfoGuessHz + 5000]
        guard let hit = LTECellSearch.search(re: narrow.re, im: narrow.im, cfoHypotheses: hypotheses, only: pci, maxCells: 1)
            .first(where: { $0.pci == pci }) else {
            return Outcome(note: String(localized: "Zelle in der Aufnahme nicht wiedergefunden."))
        }
        var re = inRe, im = inIm
        LTEFrontEnd.shift(&re, &im, hz: hit.cfoHz, rate: LTEFrontEnd.captureRate)
        // Filterverzögerung des Dezimierers: (161 − 1)/2 Werte.
        var frameStart = hit.frameStart * LTEFrontEnd.decimation + 80
        frameStart = refineTiming(re: re, im: im, nid2: pci % 3, frameStart: frameStart)

        let frameScale = carrierHz > 0 ? 1 - hit.cfoHz / carrierHz : 1
        let layout = LTECellLayout(pci: pci, extendedCP: false, nRB: mib.nRB)
        var firstSFN: Int?
        var measurement: LTEMeasurement?
        if let full = LTEMIBDecoder.decode(re: re, im: im, frameStart: frameStart, layout: layout, numerology: numerology, knownPorts: mib.ports,
                                              frameScale: frameScale) {
            firstSFN = full.firstFrameSFN
            measurement = full.measurement
        } else {
            var r = narrow.re, q = narrow.im
            LTEFrontEnd.shift(&r, &q, hz: hit.cfoHz, rate: LTEFrontEnd.searchRate)
            let small = LTECellLayout(pci: pci, extendedCP: false, nRB: 6)
            firstSFN = LTEMIBDecoder.decode(re: r, im: q, frameStart: hit.frameStart, layout: small,
                                            numerology: LTECellSearch.numerologyNormal, knownPorts: mib.ports)?.firstFrameSFN
        }
        guard let firstSFN else { return Outcome(note: String(localized: "Rahmennummer (MIB) in der Aufnahme nicht lesbar.")) }

        let demod = LTEDemodulator(numerology: numerology, layout: layout)
        var outcome = Outcome(note: "", measurement: measurement)
        var buffers: [Int: [Float]] = [:]
        var frame = 0
        while true {
            let start = frameStart + Int((Double(frame * numerology.frameLength + 5 * numerology.subframeLength) * frameScale).rounded())
            guard start + numerology.subframeLength <= re.count else { break }
            defer { frame += 1 }
            let sfn = (firstSFN + frame) % 1024
            guard sfn % 2 == 0, let grid = demod.subframe(re: re, im: im, start: start, subframe: 5) else { continue }
            let estimate = LTEChannelEstimator.estimate(grid, ports: mib.ports)
            let (cfi, _) = LTEPCFICH.decode(grid: grid, estimate: estimate, ports: mib.ports)
            var found: (LTEDCI, LTEControlLayout)?
            for tryCFI in [cfi] + [1, 2, 3].filter({ $0 != cfi }) {
                let control = LTEControlLayout(layout: layout, ports: mib.ports, cfi: tryCFI,
                                               phichExtended: mib.phichExtended, phichResource: mib.phichResource)
                if let dci = LTEPDCCH.searchSI(grid: grid, estimate: estimate, control: control) {
                    found = (dci, control)
                    break
                }
            }
            guard let (dci, control) = found,
                  let prbs = LTEAllocation.prbs(for: dci, nRB: mib.nRB),
                  let tbs = LTEAllocation.transportBlockSize(dci),
                  let block = LTEPDSCH.BlockLayout(tbs: tbs) else { continue }
            outcome.dci = dci
            outcome.cfi = control.cfi
            outcome.transmissions += 1
            let elements = LTEPDSCH.resourceElements(layout: layout, ports: mib.ports, controlSymbols: control.controlSymbols,
                                                     prbs: prbs, subframe: 5)
            let llr = LTEPDSCH.softBits(grid: grid, estimate: estimate, ports: mib.ports, elements: elements, rnti: LTEDCI.siRNTI)
            let rv = dci.rv ?? LTEAllocation.sib1RV(sfn: sfn)
            // Einzeln versuchen, dann mit den früheren Übertragungen gleicher Größe kombiniert.
            var single = [Float](repeating: 0, count: 3 * block.d)
            LTERateMatching.accumulateTurbo(llr, length: block.d, rv: rv, filler: block.filler, into: &single)
            var combined = buffers[tbs] ?? [Float](repeating: 0, count: 3 * block.d)
            for i in 0..<combined.count { combined[i] += single[i] }
            buffers[tbs] = combined
            for buffer in [single, combined] {
                if let tb = LTEPDSCH.decode(buffer: buffer, layout: block), let sib1 = LTESIB1.parse(tb) {
                    outcome.sib1 = sib1
                    outcome.note = outcome.transmissions == 1
                        ? String(localized: "SIB1 gelesen (1 Übertragung).")
                        : String(localized: "SIB1 gelesen (\(outcome.transmissions) Übertragungen).")
                    return outcome
                }
            }
        }
        outcome.note = outcome.transmissions == 0
            ? String(localized: "Keine SIB1-Zuteilung (PDCCH, SI-RNTI) gefunden.")
            : String(localized: "SIB1-Zuteilung gefunden, aber der Datenblock ließ sich nicht fehlerfrei dekodieren.")
        return outcome
    }

    /// Feinzeitlage über den PSS bei voller Rate (±20 Werte um die Schätzung).
    static func refineTiming(re: [Float], im: [Float], nid2: Int, frameStart: Int) -> Int {
        let template = LTECellSearch.pssTemplate(nid2, size: numerology.fftSize)
        let n = numerology.fftSize
        let pssOffset = numerology.usefulStart(numerology.symbolsPerSlot - 1)
        var scores = [Float](repeating: 0, count: 41)
        var position = frameStart + pssOffset
        var used = 0
        while position + n + 20 < re.count, used < 8 {
            if position - 20 >= 0 {
                for d in -20...20 {
                    var acc = LTEC.zero
                    let s = position + d
                    for i in Swift.stride(from: 0, to: n, by: 1) {
                        acc += LTEC(re[s + i], im[s + i]) * LTEC(template.re[i], -template.im[i])
                    }
                    scores[d + 20] += acc.norm
                }
                used += 1
            }
            position += numerology.frameLength / 2
        }
        guard used > 0, let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return frameStart }
        return frameStart + best - 20
    }
}
