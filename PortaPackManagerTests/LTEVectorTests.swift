import Foundation
import Testing
@testable import PortaPackManager

private let vectorFolder = ProcessInfo.processInfo.environment["LTE_VECTORS"].map { URL(fileURLWithPath: $0) }

/// Gegenprobe mit echten Aufnahmen fremder Herkunft (unabhängig vom eigenen
/// Prüfsender): die Testsignale aus srsRAN (`lib/src/phy/phch/test/`,
/// komplexe Float32-Werte bei 1,92 MS/s). Nicht im Repo – Aufruf mit
/// `TEST_RUNNER_LTE_VECTORS=<ordner> xcodebuild test -only-testing:PortaPackManagerTests/LTEVectorTests …`
///
/// - `signal.1.92M.dat`: PCI 150, 2 Ports, MIB-Nutzlast laut srsRAN
///   011010000001110000000000 (50 RB, PHICH normal/1, SFN 28 + 0).
/// - `signal.1.92M.amar.dat`: PCI 1, 6 RB, 1 Port, CFI 3, SI-RNTI.
@Suite("LTE: Fremdaufnahmen", .enabled(if: vectorFolder != nil))
struct LTEVectorTests {
    private func load(_ name: String) throws -> (re: [Float], im: [Float]) {
        let data = try Data(contentsOf: vectorFolder!.appending(path: name))
        let count = data.count / 8
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                re[i] = f[2 * i]
                im[i] = f[2 * i + 1]
            }
        }
        return (re, im)
    }

    @Test("srsRAN signal.1.92M.dat: SSS → PCI 150, MIB mit zwei Ports")
    func mib() throws {
        let s = try load("signal.1.92M.dat")
        let num = LTECellSearch.numerologyNormal
        // PSS im letzten Symbol von Slot 0 (Rahmen beginnt bei 0)
        let hit = try #require(LTECellSearch.detectSSS(re: s.re, im: s.im, nid2: 0, tau: num.usefulStart(6)))
        #expect(hit.pci == 150)
        #expect(hit.frameStart == 0)
        #expect(!hit.extendedCP && !hit.tdd)
        let layout = LTECellLayout(pci: 150, extendedCP: false, nRB: 6)
        let result = try #require(LTEMIBDecoder.decode(re: s.re, im: s.im, frameStart: 0, layout: layout, numerology: num))
        let expected: [UInt8] = [0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(result.mib.bits() == expected)
        #expect(result.mib.ports == 2)
        #expect(result.mib.nRB == 50)
        #expect(result.mib.sfn == 28)
        print("MIB:", result.mib, result.measurement as Any)
    }

    @Test("srsRAN signal.1.92M.amar.dat: PCFICH, PDCCH (SI-RNTI), PDSCH mit CRC")
    func systemInformation() throws {
        let s = try load("signal.1.92M.amar.dat")
        let num = LTECellSearch.numerologyNormal
        let layout = LTECellLayout(pci: 1, extendedCP: false, nRB: 6)
        let demod = LTEDemodulator(numerology: num, layout: layout)
        var decodedBlocks = 0
        var dciCount = 0
        var sib1Found: LTESIB1?
        for sf in 0..<10 {
            guard let grid = demod.subframe(re: s.re, im: s.im, start: sf * num.subframeLength, subframe: sf) else { continue }
            let estimate = LTEChannelEstimator.estimate(grid, ports: 1)
            let (cfi, confidence) = LTEPCFICH.decode(grid: grid, estimate: estimate, ports: 1)
            let control = LTEControlLayout(layout: layout, ports: 1, cfi: cfi, phichExtended: false, phichResource: .one)
            guard let dci = LTEPDCCH.searchSI(grid: grid, estimate: estimate, control: control) else {
                print("Teilrahmen \(sf): CFI \(cfi) (\(confidence)), kein SI-DCI")
                continue
            }
            dciCount += 1
            #expect(cfi == 3)
            let prbs = try #require(LTEAllocation.prbs(for: dci, nRB: 6))
            let tbs = try #require(LTEAllocation.transportBlockSize(dci))
            let block = try #require(LTEPDSCH.BlockLayout(tbs: tbs))
            let elements = LTEPDSCH.resourceElements(layout: layout, ports: 1, controlSymbols: control.controlSymbols, prbs: prbs, subframe: sf)
            let llr = LTEPDSCH.softBits(grid: grid, estimate: estimate, ports: 1, elements: elements, rnti: LTEDCI.siRNTI)
            var buffer = [Float](repeating: 0, count: 3 * block.d)
            LTERateMatching.accumulateTurbo(llr, length: block.d, rv: dci.rv ?? 0, filler: block.filler, into: &buffer)
            let tb = LTEPDSCH.decode(buffer: buffer, layout: block)
            if let tb { decodedBlocks += 1 }
            let hex = tb.map { bits in stride(from: 0, to: bits.count - 7, by: 8).map { i in
                String(format: "%02X", bits[i..<(i + 8)].reduce(0) { ($0 << 1) | Int($1) }) }.joined() } ?? "–"
            print("Teilrahmen \(sf): CFI \(cfi), DCI \(dci), PRB \(prbs.slot0), TBS \(tbs), CRC \(tb != nil ? "gut" : "falsch"), \(hex)")
            if let tb, let sib1 = LTESIB1.parse(tb) {
                print("SIB1:", sib1)
                sib1Found = sib1
            }
        }
        // Amarisoft-Testnetz: MCC 001, MNC 01, TAC 1, Band 7
        let sib1 = try #require(sib1Found)
        #expect(sib1.plmns == [.init(mcc: "001", mnc: "01")])
        #expect(sib1.tac == 1)
        #expect(sib1.cellIdentity == 0x1A2D401) // eNB 107220, Zelle 1
        #expect(sib1.freqBandIndicator == 7)
        #expect(dciCount > 0)
        #expect(decodedBlocks == dciCount)
    }
}
