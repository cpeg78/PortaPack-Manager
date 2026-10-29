import Foundation
import Testing
@testable import PortaPackManager

@Suite("RDS, Stereo und Trägerablage")
struct RDSTests {
    // MARK: - Gruppen bauen

    /// 26-Bit-Block: 16 Datenbits und Prüfwort mit Offset (0 = A … 4 = D, 3 = C').
    private func block(_ data: UInt16, offset: Int) -> [UInt8] {
        let word = (UInt32(data) << 10) | RDSDecoder.checkword(data, offset: offset)
        return (0..<26).reversed().map { UInt8((word >> UInt32($0)) & 1) }
    }

    private func group(pi: UInt16, type: Int, b low: UInt16, c: UInt16, d: UInt16, pty: Int = 10, tp: Bool = true) -> [UInt8] {
        let b = UInt16(type << 12) | (tp ? 0x0400 : 0) | UInt16(pty << 5) | low
        return block(pi, offset: 0) + block(b, offset: 1) + block(c, offset: 2) + block(d, offset: 4)
    }

    private func psGroups(_ name: String, pi: UInt16) -> [[UInt8]] {
        let bytes = Array(name.utf8)
        return (0..<4).map { segment in
            group(pi: pi, type: 0, b: UInt16(segment) | 0x08, c: 0xE0CD,
                  d: UInt16(bytes[segment * 2]) << 8 | UInt16(bytes[segment * 2 + 1]))
        }
    }

    private func radioTextGroups(_ bytes: [UInt8], pi: UInt16) -> [[UInt8]] {
        let padded = bytes + Array(repeating: 0x20, count: (4 - bytes.count % 4) % 4)
        return stride(from: 0, to: padded.count, by: 4).map { start in
            group(pi: pi, type: 2, b: UInt16(start / 4),
                  c: UInt16(padded[start]) << 8 | UInt16(padded[start + 1]),
                  d: UInt16(padded[start + 2]) << 8 | UInt16(padded[start + 3]))
        }
    }

    private func clockGroup(_ date: Date, offsetHalfHours: Int, pi: UInt16) -> [UInt8] {
        let seconds = Int(date.timeIntervalSince1970)
        let mjd = 40_587 + seconds / 86_400
        let hour = (seconds % 86_400) / 3600, minute = (seconds % 3600) / 60
        let b = UInt16((mjd >> 15) & 0x03)
        let c = UInt16((mjd & 0x7FFF) << 1) | UInt16(hour >> 4)
        let d = UInt16((hour & 0x0F) << 12) | UInt16(minute << 6) | UInt16(offsetHalfHours & 0x1F)
        return group(pi: pi, type: 4, b: b, c: c, d: d)
    }

    /// Differentielle Kodierung, wie sie der Sender vor der Biphase-Formung macht.
    private func differential(_ bits: [UInt8]) -> [UInt8] {
        var previous: UInt8 = 0
        return bits.map { bit in
            previous ^= bit
            return previous
        }
    }

    private let pi: UInt16 = 0xD3C2
    private let clock = Date(timeIntervalSince1970: 1_792_585_440)   // 2026-10-20 12:24 UTC

    private func programme() -> [UInt8] {
        let text: [UInt8] = Array("Wetter: sonnig".utf8) + [0x0D]
        var bits: [UInt8] = []
        for _ in 0..<3 {
            for g in psGroups("HR3 TEST", pi: pi) + radioTextGroups(text, pi: pi) + [clockGroup(clock, offsetHalfHours: 4, pi: pi)] {
                bits += g
            }
        }
        return bits
    }

    // MARK: - Bitebene

    @Test("Prüfwort ergibt als Syndrom genau das Offsetwort")
    func syndrome() {
        for offset in 0..<5 {
            let word = (UInt32(0xD3C2) << 10) | RDSDecoder.checkword(0xD3C2, offset: offset)
            #expect(RDSDecoder.syndrome(word) == RDSDecoder.offsets[offset])
        }
        // Ein gekipptes Bit fällt auf.
        let word = (UInt32(0xD3C2) << 10) | RDSDecoder.checkword(0xD3C2, offset: 0)
        #expect(RDSDecoder.syndrome(word ^ 0x400) != RDSDecoder.offsets[0])
    }

    @Test("Bündelfehler: Syndrome bis 5 Bit eindeutig, Korrektur bis 2 Bit in jedem Block")
    func burstCorrection() throws {
        // Eigenschaft des Codes (IEC 62106, Anhang B): alle Bündel ≤ 5 Bit haben verschiedene Syndrome.
        let table = RDSDecoder.burstTable(maxLength: 5)
        #expect(table.count == 26 + 25 + 24 * 2 + 23 * 4 + 22 * 8)
        for (offsetIndex, slot, versionB) in [(0, 0, false), (1, 1, false), (2, 2, false), (3, 2, true), (4, 3, false)] {
            let word = (UInt32(0x1234) << 10) | RDSDecoder.checkword(0x1234, offset: offsetIndex)
            for shift in 0..<26 {
                #expect(RDSDecoder.correct(word ^ (1 << UInt32(shift)), slot: slot, versionB: versionB) == word,
                        "Offset \(offsetIndex), Bit \(shift)")
                if shift < 25 {
                    #expect(RDSDecoder.correct(word ^ (3 << UInt32(shift)), slot: slot, versionB: versionB) == word,
                            "Offset \(offsetIndex), Bits \(shift)–\(shift + 1)")
                }
            }
            // Vier Bit verstreut ist kein Zweierbündel mehr.
            #expect(RDSDecoder.correct(word ^ 0b101_0000_0101, slot: slot, versionB: versionB) != word)
        }
        // Block C ohne bekannten Block B: nie eine falsche, höchstens keine Korrektur.
        for offsetIndex in [2, 3] {
            let word = (UInt32(0xBEEF) << 10) | RDSDecoder.checkword(0xBEEF, offset: offsetIndex)
            for shift in 0..<26 {
                let fixed = RDSDecoder.correct(word ^ (1 << UInt32(shift)), slot: 2)
                #expect(fixed == nil || fixed == word)
            }
        }
    }

    @Test("Bitfehler 1 %: Bündelkorrektur rettet die meisten Blöcke, Inhalt bleibt richtig")
    func decoderWithBitErrors() {
        var bits: [UInt8] = []
        for _ in 0..<8 { bits += programme() }
        var sent = differential(bits)
        var rng = SondeSignal.Random(state: 77)
        var flipped = 0
        for i in 26..<sent.count where rng.unit() < 0.01 { sent[i] ^= 1; flipped += 1 }
        var decoder = RDSDecoder()
        for bit in sent { decoder.push(bit) }
        let info = decoder.info
        let withoutCorrection = info.blocksGood - info.blocksCorrected
        let total = info.blocksGood + info.blocksBad
        // Gemessen (Startwert 77): ohne Korrektur ≈ 77 % gute Blöcke, mit ≈ 97 %.
        #expect(Double(withoutCorrection) / Double(total) < 0.85, "ohne: \(withoutCorrection)/\(total)")
        #expect(Double(info.blocksGood) / Double(total) > 0.93, "mit: \(info.blocksGood)/\(total), \(flipped) Fehler")
        #expect(info.programServiceText == "HR3 TEST")
        #expect(info.radioTextString == "Wetter: sonnig")
        #expect(info.pi == pi)
    }

    @Test("Dekoder liest Sendername, Radiotext, Programmart und Uhrzeit")
    func decoder() {
        var decoder = RDSDecoder()
        // Zufälliger Vorlauf, dann das Programm.
        let noise: [UInt8] = (0..<37).map { UInt8(($0 * 7 + 3) % 5 % 2) }
        for bit in differential(noise + programme()) { decoder.push(bit) }
        #expect(decoder.synced)
        #expect(decoder.info.pi == pi)
        #expect(decoder.info.programServiceText == "HR3 TEST")
        #expect(decoder.info.radioTextString == "Wetter: sonnig")
        #expect(decoder.info.programTypeName == "Pop")
        #expect(decoder.info.trafficProgram)
        #expect(decoder.info.clock == clock)
        #expect(decoder.info.localOffsetMinutes == 120)
        // 0xE0 = „ein AF folgt“, 0xCD = Füllwert – beides keine Frequenz.
        #expect(decoder.info.alternativeFrequencies.isEmpty)
        #expect(decoder.info.blocksBad == 0)
    }

    @Test("Zeichensatz: Umlaute nach IEC 62106")
    func characters() {
        #expect(RDSDecoder.character(0x91) == "ä")
        #expect(RDSDecoder.character(0x97) == "ö")
        #expect(RDSDecoder.character(0x99) == "ü")
        #expect(RDSDecoder.character(0x8D) == "ß")
        #expect(RDSDecoder.character(0xD1) == "Ä")
        #expect(RDSDecoder.character(0xD7) == "Ö")
        #expect(RDSDecoder.character(0xD9) == "Ü")
        #expect(RDSDecoder.character(0x41) == "A")
    }

    // MARK: - Ende zu Ende über FM

    /// UKW-Signal bei 2,4 MS/s auf dem Empfangsversatz (+ `carrierOffset`):
    /// Summe/Differenz, Pilot sin(ωt), L−R auf sin(2ωt), RDS auf 57 kHz.
    private func fmSignal(seconds: Double, left: Double?, right: Double?, rdsBits: [UInt8]?,
                          carrierOffset: Double = 0, pilot: Bool = true) -> Data {
        let rate = RadioDemodulator.inputRate
        let n = Int(seconds * rate)
        var data = Data(count: n * 2)
        let chips: [Double] = rdsBits.map { bits in differential(bits).flatMap { $0 == 1 ? [1.0, -1.0] : [-1.0, 1.0] } } ?? []
        let chipRate = 2 * RDSDemodulator.bitRate
        var phase = 0.0
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<n {
                let t = Double(k) / rate
                let l = left.map { sin(2 * .pi * $0 * t) } ?? 0
                let r = right.map { sin(2 * .pi * $0 * t) } ?? 0
                let pilotPhase = 2 * .pi * 19_000 * t
                var hz = 30_000 * (l + r) / 2 + 30_000 * (l - r) / 2 * sin(2 * pilotPhase)
                if pilot { hz += 7_000 * sin(pilotPhase) }
                if !chips.isEmpty {
                    let chip = chips[Int(t * chipRate) % chips.count]
                    hz += 3_000 * chip * sin(3 * pilotPhase)
                }
                phase += 2 * .pi * (RadioDemodulator.offset + carrierOffset + hz) / rate
                p[2 * k] = Int8((80 * cos(phase)).rounded())
                p[2 * k + 1] = Int8((80 * sin(phase)).rounded())
            }
        }
        return data
    }

    private func run(_ demod: RadioDemodulator, _ iq: Data) -> (left: [Float], right: [Float]) {
        var left: [Float] = [], right: [Float] = []
        let block = 262_144
        var offset = 0
        while offset < iq.count {
            let out = demod.process(iq.subdata(in: offset..<min(offset + block, iq.count)))
            left += out.left
            right += out.right
            offset += block
        }
        return (left, right)
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
    }

    @Test("RDS kommt über den ganzen Empfangsweg an")
    func endToEnd() {
        let demod = RadioDemodulator()
        demod.mode = .wfm
        let bits = programme()
        let seconds = Double(bits.count) / RDSDemodulator.bitRate
        _ = run(demod, fmSignal(seconds: seconds, left: 1000, right: 400, rdsBits: bits))
        let info = demod.rds.info
        #expect(demod.rds.decoder.synced)
        #expect(info.pi == pi)
        #expect(info.programServiceText == "HR3 TEST")
        #expect(info.radioTextString == "Wetter: sonnig")
        #expect(info.blockQuality > 0.95)
    }

    @Test("Stereo trennt die Kanäle, ohne Pilot bleibt es mono")
    func stereo() {
        let demod = RadioDemodulator()
        demod.mode = .wfm
        demod.volume = 1
        let out = run(demod, fmSignal(seconds: 1, left: 1000, right: nil, rdsBits: nil))
        #expect(demod.pilotLocked)
        let settled = out.left.count / 2
        let l = rms(out.left[settled...]), r = rms(out.right[settled...])
        #expect(l > 0.1)
        #expect(r < l / 10, "Übersprechen zu hoch: L \(l), R \(r)")

        let mono = RadioDemodulator()
        mono.mode = .wfm
        mono.volume = 1
        let monoOut = run(mono, fmSignal(seconds: 0.5, left: 1000, right: nil, rdsBits: nil, pilot: false))
        #expect(!mono.pilotLocked)
        #expect(monoOut.left == monoOut.right)
    }

    @Test("Trägerablage wird in Hz gemessen")
    func carrierOffset() {
        let demod = RadioDemodulator()
        demod.mode = .wfm
        _ = run(demod, fmSignal(seconds: 1, left: 800, right: 300, rdsBits: nil, carrierOffset: 1_234))
        #expect(abs(demod.carrierOffsetHz - 1_234) < 15)
        #expect(abs(demod.carrierOffsetSeconds - 1) < 0.01)
    }

    @Test("Quarzkorrektur rechnet die Sollfrequenz um")
    func correction() {
        let saved = HackRFDevice.frequencyCorrectionPPM
        defer { HackRFDevice.frequencyCorrectionPPM = saved }
        HackRFDevice.frequencyCorrectionPPM = 10
        #expect(abs(HackRFDevice.corrected(100_000_000) - 99_999_000.01) < 0.1)
        HackRFDevice.frequencyCorrectionPPM = 0
        #expect(HackRFDevice.corrected(100_000_000) == 100_000_000)
    }
}

@Suite("RDS-Sendernamen")
struct StationNameTests {
    @Test("Nur vollständige Namen werden übernommen")
    func complete() {
        var info = RDSInfo()
        #expect(StationNames.complete(info) == nil)
        info.programService = Array("SWR3    ").map { Optional($0) }
        #expect(StationNames.complete(info) == "SWR3")
        info.programService[6] = nil
        #expect(StationNames.complete(info) == nil)
        info.programService = Array("        ").map { Optional($0) }
        #expect(StationNames.complete(info) == nil)
    }

    @Test("Frequenzschlüssel auf 10 kHz, unempfindlich gegen Rundung")
    func key() {
        #expect(StationNames.key(103.6) == 10360)
        #expect(StationNames.key(103.60000001) == StationNames.key(103.6))
        #expect(StationNames.key(87.55) == 8755)
    }
}
