import Foundation
import Testing
@testable import PortaPackManager

@Suite("LTE: Kanalkodierung")
struct LTECodingTests {
    static func bits(of text: String) -> [UInt8] {
        text.utf8.flatMap { byte in (0..<8).reversed().map { UInt8((byte >> $0) & 1) } }
    }

    @Test("CRC-16 entspricht dem XMODEM-Prüfwert (0x1021, Start 0)")
    func crc16() {
        #expect(LTECRC.compute(Self.bits(of: "123456789"), poly: LTECRC.crc16, length: 16) == 0x31C3)
    }

    @Test("CRC-24A und Masken: Anhängen, Prüfen, gekipptes Bit fällt auf")
    func crc24() {
        var rng = LTESimRNG(seed: 3)
        let payload = (0..<200).map { _ in rng.bit() }
        let block = LTECRC.attach(payload, poly: LTECRC.crc24A, length: 24)
        #expect(LTECRC.check(block, poly: LTECRC.crc24A, length: 24))
        var broken = block
        broken[17] ^= 1
        #expect(!LTECRC.check(broken, poly: LTECRC.crc24A, length: 24))
        let masked = LTECRC.attach(Array(payload[0..<24]), poly: LTECRC.crc16, length: 16, mask: 0x5555)
        #expect(LTECRC.check(masked, poly: LTECRC.crc16, length: 16, mask: 0x5555))
        #expect(!LTECRC.check(masked, poly: LTECRC.crc16, length: 16, mask: 0xFFFF))
    }

    @Test("Tail-biting-Faltungscode: Viterbi dekodiert mit Ratenanpassung und Rauschen", arguments: [40, 43, 57])
    func viterbi(k: Int) {
        var rng = LTESimRNG(seed: UInt64(k))
        let c = (0..<k).map { _ in rng.bit() }
        // Ohne Rauschen exakt
        let d = LTEConvolutional.encode(c)
        let clean = d.map { $0.map { Float($0 == 0 ? 4 : -4) } }
        #expect(LTEConvolutional.decode(clean) == c)
        // E = 576 Bit (z. B. PDCCH mit 8 CCE ist 576) bei Es/N0 = −2 dB
        let e = 576
        let coded = LTERateMatching.convolutionalEncode(c, count: e)
        let sigma = Float(pow(10, 2.0 / 20))
        let llr = coded.map { b -> Float in
            let y = Float(b == 0 ? 1 : -1) + sigma * rng.gaussian()
            return 2 * y / (sigma * sigma)
        }
        #expect(LTEConvolutional.decode(LTERateMatching.convolutionalDematch(llr, k: k)) == c)
    }

    @Test("QPP-Verschachteler ist für alle 188 Blockgrößen eine Permutation")
    func qpp() {
        #expect(LTETurbo.blockSizes.count == 188)
        #expect(LTETurbo.f1.count == 188 && LTETurbo.f2.count == 188)
        for k in LTETurbo.blockSizes {
            let pi = LTETurbo.interleaver(k: k)!
            #expect(Set(pi).count == k, "K = \(k)")
        }
        #expect(LTETurbo.interleaver(k: 40)!.prefix(4) == [0, 13, 6, 19])
    }

    @Test("Turbo-Code: Kodieren, Ratenanpassung (alle RV) und Dekodieren mit Rauschen", arguments: [40, 344, 1088])
    func turbo(tbsPlusCRC: Int) {
        var rng = LTESimRNG(seed: UInt64(tbsPlusCRC))
        let tbs = tbsPlusCRC - 24
        let tb = (0..<tbs).map { _ in rng.bit() }
        let block = LTEPDSCH.BlockLayout(tbs: tbs)!
        #expect(block.filler == 0)
        // Rate ≈ 1/2 je Übertragung
        let e = 2 * tbsPlusCRC
        func transmit(rv: Int, esN0: Double) -> [Float] {
            let sigma = Float(pow(10, -esN0 / 20))
            let coded = LTEPDSCH.encode(tb, count: e, rv: rv)!
            let llr = coded.map { b -> Float in
                let y = Float(b == 0 ? 1 : -1) + sigma * rng.gaussian()
                return 2 * y / (sigma * sigma)
            }
            var buffer = [Float](repeating: 0, count: 3 * block.d)
            LTERateMatching.accumulateTurbo(llr, length: block.d, rv: rv, filler: block.filler, into: &buffer)
            return buffer
        }
        // Eine Übertragung bei Es/N0 = 3 dB, jede RV für sich
        for rv in 0..<4 {
            #expect(LTEPDSCH.decode(buffer: transmit(rv: rv, esN0: 3), layout: block) == tb, "RV \(rv)")
        }
        // Vier Übertragungen bei −3 dB kombiniert (zusammen +3 dB, mehr Parität)
        var combined = [Float](repeating: 0, count: 3 * block.d)
        for rv in [0, 2, 3, 1] {
            let b = transmit(rv: rv, esN0: -3)
            for i in combined.indices { combined[i] += b[i] }
        }
        #expect(LTEPDSCH.decode(buffer: combined, layout: block) == tb)
    }

    @Test("Turbo-Code mit Füllbits (K größer als Block + CRC)")
    func turboFiller() {
        var rng = LTESimRNG(seed: 11)
        let tbs = 50 // 74 Bit → K = 80, 6 Füllbits
        let tb = (0..<tbs).map { _ in rng.bit() }
        let block = LTEPDSCH.BlockLayout(tbs: tbs)!
        #expect(block.k == 80 && block.filler == 6)
        let coded = LTEPDSCH.encode(tb, count: 240, rv: 0)!
        let llr = coded.map { Float($0 == 0 ? 3 : -3) }
        var buffer = [Float](repeating: 0, count: 3 * block.d)
        LTERateMatching.accumulateTurbo(llr, length: block.d, rv: 0, filler: block.filler, into: &buffer)
        #expect(LTEPDSCH.decode(buffer: buffer, layout: block) == tb)
    }
}

@Suite("LTE: Tabellen und Felder")
struct LTEFieldTests {
    @Test("EARFCN und Frequenz der deutschen Bänder")
    func earfcn() {
        #expect(LTEBand.locate(mhz: 806)?.earfcn == 6300)
        #expect(LTEBand.locate(mhz: 806)?.band.number == 20)
        #expect(LTEBand.locate(mhz: 1815)?.earfcn == 1300)
        #expect(LTEBand.locate(mhz: 2140)?.earfcn == 300)
        #expect(LTEBand.locate(mhz: 2650)?.earfcn == 3050)
        #expect(LTEBand.locate(mhz: 950.9)?.earfcn == 3709)
        #expect(LTEBand.band(number: 3)?.frequencyMHz(earfcn: 1801) == 1865.1)
        #expect(LTEBand.locate(mhz: 600) == nil)
    }

    @Test("PSS/SSS: 504 Zellkennungen eindeutig, Teilrahmen 0/5 unterscheidbar")
    func syncSequences() {
        var seen = Set<[Float]>()
        for nid2 in 0..<3 {
            for nid1 in 0..<168 {
                seen.insert(LTECellSearch.sss(nid1: nid1, nid2: nid2, subframe5: false))
                seen.insert(LTECellSearch.sss(nid1: nid1, nid2: nid2, subframe5: true))
            }
        }
        #expect(seen.count == 1008)
        let pss = LTECellSearch.pss(0)
        #expect(pss.allSatisfy { abs($0.norm - 1) < 1e-4 })
        // Zeitbereichs-Vorlage hat Energie 1; Folge 1 und 2 sind zueinander konjugiert (u = 29/34, 29 + 34 = 63).
        let t = LTECellSearch.pssTemplate(1, size: 128)
        #expect(abs(zip(t.re, t.im).reduce(Float(0)) { $0 + $1.0 * $1.0 + $1.1 * $1.1 } - 1) < 1e-4)
        #expect(zip(LTECellSearch.pss(1), LTECellSearch.pss(2)).allSatisfy { ($0.0 - $0.1.conj).norm < 1e-6 })
    }

    @Test("MIB: Bits hin und zurück")
    func mib() {
        let mib = LTEMIB(nRB: 50, phichExtended: true, phichResource: .half, sfn: 0x2B7, ports: 2)
        let parsed = LTEMIB.parse(mib.bits(), ports: 2, segment: 0x2B7 % 4)
        #expect(parsed == mib)
    }

    @Test("DCI-Größen für SI-RNTI je Bandbreite (1A und 1C)")
    func dciSizes() {
        #expect([6, 15, 25, 50, 75, 100].map { LTEDCI.size1A(nRB: $0) } == [21, 22, 25, 27, 27, 28])
        #expect([6, 15, 25, 50, 75, 100].map { LTEDCI.size1C(nRB: $0) } == [8, 10, 12, 13, 14, 15])
        let dci = LTEDCI(format: .f1A, distributed: true, gap2: false, riv: 77, mcs: 9, rv: 2, nPRB1A: 3)
        #expect(LTEDCI.parse(dci.bits(nRB: 25), format: .f1A, nRB: 25) == dci)
        let c = LTEDCI(format: .f1C, distributed: true, gap2: true, riv: 5, mcs: 12, rv: nil, nPRB1A: 2)
        #expect(LTEDCI.parse(c.bits(nRB: 100), format: .f1C, nRB: 100) == c)
    }

    @Test("Verteilte VRB-Zuordnung: je Slot eindeutig, im Band", arguments: [6, 15, 25, 50, 75, 100])
    func distributed(nRB: Int) {
        for gap2 in nRB >= 50 ? [false, true] : [false] {
            let count = LTEAllocation.vrbCount(nRB: nRB, gap2: gap2)
            let map = (0..<count).map { LTEAllocation.distributedPRB($0, nRB: nRB, gap2: gap2) }
            #expect(Set(map.map(\.slot0)).count == count)
            #expect(Set(map.map(\.slot1)).count == count)
            #expect(map.allSatisfy { $0.slot0 < nRB && $0.slot1 < nRB })
        }
        // RIV hin und zurück
        for start in 0..<nRB {
            for length in 1...(nRB - start) {
                let riv = LTEAllocation.encodeRIV(start: start, length: length, n: nRB)
                let back = LTEAllocation.decodeRIV(riv, n: nRB, limit: nRB)
                #expect(back.start == start && back.length == length)
            }
        }
    }

    @Test("Steuerbereich: PCFICH, PHICH und PDCCH teilen sich keine REG", arguments: [6, 25, 100])
    func controlRegions(nRB: Int) {
        for ports in [1, 2, 4] {
            let layout = LTECellLayout(pci: 301, extendedCP: false, nRB: nRB)
            let c = LTEControlLayout(layout: layout, ports: ports, cfi: 2, phichExtended: false, phichResource: .one)
            #expect(c.pcfich.count == 4)
            #expect(c.phich.count == 3 * Int((Double(nRB) / 8).rounded(.up)))
            let all = c.pcfich + c.phich + c.pdcch
            #expect(Set(all).count == all.count)
            #expect(c.pdcch.allSatisfy { $0.symbol < c.controlSymbols })
        }
    }

    @Test("SIB1 (UPER): hin und zurück, Netzbetreiber nach MCC/MNC")
    func sib1() {
        let sib1 = LTESIB1(plmns: [.init(mcc: "262", mnc: "01"), .init(mcc: "262", mnc: "023")], tac: 0xB1A7, cellIdentity: 0x1A2B3C4,
                           cellBarred: false, intraFreqReselectionAllowed: true, qRxLevMinDBm: -124, pMax: 23, freqBandIndicator: 20)
        let parsed = LTESIB1.parse(sib1.encode())
        #expect(parsed == sib1)
        #expect(parsed?.enbID == 0x1A2B3 && parsed?.localCellID == 0xC4)
        #expect(parsed?.operatorName == "Telekom")
        #expect(LTEOperator.name(mcc: "262", mnc: "02") == "Vodafone")
        #expect(LTEOperator.name(mcc: "262", mnc: "03")?.hasPrefix("O2") == true)
        #expect(LTEOperator.name(mcc: "262", mnc: "23") == "1&1")
    }
}

@Suite("LTE: Empfang (Prüfsender)")
struct LTEReceiverTests {
    struct NarrowCase: Sendable, CustomStringConvertible {
        var pci: Int
        var ports: Int
        var extendedCP: Bool
        var tdd: Bool
        var snrDB: Double
        var cfoHz: Double
        var description: String { "PCI \(pci), \(ports) Ports\(extendedCP ? ", erw. CP" : "")\(tdd ? ", TDD" : ""), \(snrDB) dB, \(Int(cfoHz)) Hz" }
    }

    static let narrowCases: [NarrowCase] = [
        .init(pci: 0, ports: 1, extendedCP: false, tdd: false, snrDB: 20, cfoHz: 0),
        .init(pci: 302, ports: 2, extendedCP: false, tdd: false, snrDB: 0, cfoHz: 17_300),
        .init(pci: 477, ports: 4, extendedCP: false, tdd: false, snrDB: 2, cfoHz: -23_800),
        .init(pci: 131, ports: 2, extendedCP: true, tdd: false, snrDB: 5, cfoHz: 4_100),
        .init(pci: 88, ports: 1, extendedCP: false, tdd: true, snrDB: 5, cfoHz: -9_000),
    ]

    @Test("Zellsuche bei 1,92 MS/s: PCI, CP, FDD/TDD und MIB mit Rauschen und Ablage", arguments: narrowCases)
    func narrow(_ c: NarrowCase) throws {
        let cell = LTETestCell(pci: c.pci, nRB: 6, ports: c.ports, extendedCP: c.extendedCP, tdd: c.tdd,
                               phichExtended: c.ports == 4, phichResource: .half, mibRB: 50)
        let tx = LTETransmitter.generate(cell, fftSize: 128, frames: 5, firstSFN: 517)
        // Ablage kommt vom HackRF-Quarz: derselbe Fehler streckt die Abtastrate.
        let rx = LTETransmitter.channel(tx, fftSize: 128, snrDB: c.snrDB, cfoHz: c.cfoHz, delay: 7_321, clockPPM: -c.cfoHz / 806)
        let findings = LTEScanner.analyzeNarrow(re: rx.re, im: rx.im, carrierMHz: 806,
                                                hypotheses: LTEScanner.cfoHypotheses(ppm: nil, carrierMHz: 806))
        let found = try #require(findings.first { $0.sync.pci == c.pci })
        #expect(found.sync.extendedCP == c.extendedCP)
        #expect(found.sync.tdd == c.tdd)
        #expect(abs(found.sync.cfoHz - c.cfoHz) < 150)
        // Taktabweichung verschiebt die Spitze über die Aufnahme um bis zu ±2 Werte.
        #expect(abs(found.sync.frameStart - 7_321) <= 3)
        #expect(found.mib.nRB == 50)
        #expect(found.mib.ports == c.ports)
        #expect(found.mib.phichResource == .half)
        #expect(found.mib.phichExtended == (c.ports == 4))
        #expect((517...521).contains(found.mib.sfn))
        let measurement = try #require(found.measurement)
        #expect(abs(measurement.sinrDB - c.snrDB) < 4, "SINR \(measurement.sinrDB)")
    }

    @Test("Beobachten: Messwerte einer bekannten Zelle auch unter der MIB-Schwelle")
    func observeMeasurement() throws {
        let cell = LTETestCell(pci: 222, nRB: 6, ports: 2, mibRB: 25)
        let tx = LTETransmitter.generate(cell, fftSize: 128, frames: 3, firstSFN: 0)
        for snr in [12.0, -3.0] {
            let rx = LTETransmitter.channel(tx, fftSize: 128, snrDB: snr, cfoHz: 1_200, delay: 2_000)
            let result = try #require(LTEScanner.measure(re: rx.re, im: rx.im, hypotheses: [-3000, 1000, 5000], pci: 222))
            #expect(abs(result.measurement.sinrDB - snr) < 3, "SNR \(snr): \(result.measurement.sinrDB)")
            #expect(abs(result.hit.cfoHz - 1_200) < 200)
        }
    }

    @Test("Ohne Signal keine Zelle (nur Rauschen)")
    func noiseOnly() {
        var rng = LTESimRNG(seed: 99)
        let n = 19_200 * 4
        let re = (0..<n).map { _ in rng.gaussian() }, im = (0..<n).map { _ in rng.gaussian() }
        let findings = LTEScanner.analyzeNarrow(re: re, im: im, carrierMHz: 1815,
                                                hypotheses: LTEScanner.cfoHypotheses(ppm: nil, carrierMHz: 1815))
        #expect(findings.isEmpty)
    }

    @Test("Breitband-Suchlauf: zwei Zellen in einer 19,2-MS/s-Aufnahme, Spektrum → Kandidaten → MIB")
    func wideband() throws {
        let rate = LTEFrontEnd.captureRate
        let a = LTETestCell(pci: 214, nRB: 25, ports: 2)
        let b = LTETestCell(pci: 37, nRB: 15, ports: 1)
        let tunedMHz = 1830.0
        // Zelle A bei 1826,5 MHz (−3,5 MHz), Zelle B bei 1834,8 MHz (+4,8 MHz); HackRF 3 ppm daneben.
        let ppm = 3.0
        let txA = LTETransmitter.shifted(LTETransmitter.generate(a, fftSize: 1280, frames: 4, firstSFN: 100, seed: 2),
                                         hz: -3.5e6 + ppm * 1826.5, rate: rate)
        let txB = LTETransmitter.shifted(LTETransmitter.generate(b, fftSize: 1280, frames: 4, firstSFN: 900, seed: 3),
                                         hz: 4.8e6 + ppm * 1834.8, rate: rate)
        let mixed = LTETransmitter.add(txA, txB, gain: 0.5)
        let rx = LTETransmitter.channel(mixed, fftSize: 1280, snrDB: 15, cfoHz: 0, delay: 33_333)
        let data = LTETransmitter.quantize(rx)
        let iq = LTEFrontEnd.convert(data)
        let points = LTEScanner.spectrumPoints(re: iq.re, im: iq.im, tunedMHz: tunedMHz)
        let segments = LTEScanner.segments(points)
        #expect(segments.count >= 2)
        let band = LTEBand.band(number: 3)
        var findings: [LTECellFinding] = []
        for segment in segments {
            let candidates = LTEScanner.candidates(for: segment, band: band)
            findings += LTEScanner.analyze(re: iq.re, im: iq.im, tunedMHz: tunedMHz, candidates: candidates, ppm: nil)
        }
        let foundA = try #require(findings.first { $0.sync.pci == 214 })
        let foundB = try #require(findings.first { $0.sync.pci == 37 })
        #expect(abs(foundA.carrierMHz - 1826.5) < 0.01)
        #expect(abs(foundB.carrierMHz - 1834.8) < 0.01)
        #expect(foundA.mib.nRB == 25 && foundA.mib.ports == 2)
        #expect(foundB.mib.nRB == 15 && foundB.mib.ports == 1)
        #expect(abs(foundA.sync.cfoHz / 1826.5 - ppm) < 0.2)
        // Herausnehmen der gefundenen Zellen lässt nichts Breites übrig.
        for segment in segments {
            #expect(LTEScanner.remaining(segment, after: findings).allSatisfy { $0.widthMHz < 1.5 })
        }
    }

    struct SIBCase: Sendable, CustomStringConvertible {
        var nRB: Int
        var ports: Int
        var format: LTEDCI.Format
        var distributed: Bool
        var cfi: Int
        var aggregation: Int
        var snrDB: Double
        var description: String { "\(nRB) RB, \(ports) Ports, DCI \(format.rawValue)\(distributed ? " verteilt" : ""), CFI \(cfi), \(snrDB) dB" }
    }

    static let sibCases: [SIBCase] = [
        .init(nRB: 25, ports: 2, format: .f1A, distributed: false, cfi: 2, aggregation: 4, snrDB: 8),
        .init(nRB: 50, ports: 1, format: .f1C, distributed: true, cfi: 1, aggregation: 8, snrDB: 8),
        .init(nRB: 15, ports: 4, format: .f1A, distributed: true, cfi: 3, aggregation: 4, snrDB: 10),
        .init(nRB: 6, ports: 2, format: .f1A, distributed: false, cfi: 2, aggregation: 4, snrDB: 10),
        .init(nRB: 100, ports: 2, format: .f1A, distributed: false, cfi: 1, aggregation: 8, snrDB: 8),
    ]

    @Test("SIB1: PCFICH → PDCCH (SI-RNTI) → PDSCH → Turbo → Netzbetreiber, TAC, Zellkennung", arguments: sibCases)
    func sib1(_ c: SIBCase) throws {
        let sib1 = LTESIB1(plmns: [.init(mcc: "262", mnc: "02")], tac: 0x4C2E, cellIdentity: 0x2F1A0_1B,
                           cellBarred: false, intraFreqReselectionAllowed: true, qRxLevMinDBm: -128, pMax: nil, freqBandIndicator: 20)
        var cell = LTETestCell(pci: 389, nRB: c.nRB, ports: c.ports, phichResource: .one, sib1: sib1)
        cell.cfi = c.cfi
        cell.aggregation = c.aggregation
        cell.dci = LTEDCI(format: c.format, distributed: c.distributed, gap2: false, riv: 0, mcs: c.format == .f1C ? 9 : 6,
                          rv: nil, nPRB1A: 3)
        if c.format == .f1C {
            cell.sib1Start = 2 * LTEAllocation.rbStep(c.nRB)
            cell.sib1Length = 2 * LTEAllocation.rbStep(c.nRB)
        } else {
            cell.sib1Start = min(2, c.nRB - 4)
            cell.sib1Length = 4
        }
        let frames = 6
        let tx = LTETransmitter.generate(cell, fftSize: 1280, frames: frames, firstSFN: 64, seed: 5)
        // HackRF-Quarz 3,56 ppm daneben (bei 806 MHz −2870 Hz), Echo nach 1,2 µs.
        let ppm = 3.56
        let cfo = -ppm * 806
        let rx = LTETransmitter.channel(tx, fftSize: 1280, snrDB: c.snrDB, cfoHz: cfo, delay: 54_321,
                                        echo: (delay: 23, gain: LTEC(0.3, -0.2)), clockPPM: ppm)
        let iq = LTEFrontEnd.convert(LTETransmitter.quantize(rx))
        let mib = LTEMIB(nRB: c.nRB, phichExtended: false, phichResource: .one, sfn: 0, ports: c.ports)
        let outcome = LTESIB1Decoder.decode(re: iq.re, im: iq.im, pci: 389, mib: mib, extendedCP: false, tdd: false,
                                            cfoGuessHz: cfo, carrierHz: 806e6)
        let decoded = try #require(outcome.sib1, "\(outcome.note)")
        #expect(decoded == sib1)
        #expect(decoded.operatorName == "Vodafone")
        #expect(outcome.dci?.format == c.format)
        #expect(outcome.cfi == c.cfi)
    }

    @Test("SIB1 wird nicht erfunden: Zelle ohne SIB1-Übertragung")
    func noSIB1() {
        let cell = LTETestCell(pci: 12, nRB: 25, ports: 1)
        let tx = LTETransmitter.generate(cell, fftSize: 1280, frames: 6, firstSFN: 0, seed: 8)
        let rx = LTETransmitter.channel(tx, fftSize: 1280, snrDB: 15, cfoHz: 0, delay: 1_000)
        let mib = LTEMIB(nRB: 25, phichExtended: false, phichResource: .one, sfn: 0, ports: 1)
        let outcome = LTESIB1Decoder.decode(re: rx.re, im: rx.im, pci: 12, mib: mib, extendedCP: false, tdd: false, cfoGuessHz: 0)
        #expect(outcome.sib1 == nil)
        #expect(!outcome.note.isEmpty)
    }
}
