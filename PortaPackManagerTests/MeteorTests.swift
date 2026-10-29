import Foundation
import Testing
@testable import PortaPackManager

@Suite("METEOR LRPT")
struct MeteorTests {
    typealias F = MeteorSignalFactory

    // MARK: Kodierung

    @Test("CCSDS-Pseudozufallsfolge beginnt mit FF 48 0E C0 9A")
    func randomizer() {
        #expect(Array(MeteorRandomizer.sequence.prefix(8)) == [0xFF, 0x48, 0x0E, 0xC0, 0x9A, 0x0D, 0x70, 0xBC])
    }

    @Test("Faltungscode erzeugt das bekannte kodierte Synchronwort")
    func encodedSyncWord() {
        // SatDump korreliert (mit invertierten Werten) auf 0xFCA2B63DB00D9794.
        let coded = MeteorConvolutionalCode.encode(F.bits([0x1A, 0xCF, 0xFC, 0x1D]))
        var value: UInt64 = 0
        for bit in coded { value = value << 1 | UInt64(bit) }
        #expect(~value == 0xFCA2_B63D_B00D_9794)
    }

    @Test("Reed-Solomon: Codewort hat keine Syndrome, 16 Fehler werden korrigiert")
    func reedSolomon() {
        var random = F.Random(state: 7)
        let data = (0..<223).map { _ in random.byte() }
        let word = MeteorReedSolomon.encode(data)
        var copy = word
        #expect(MeteorReedSolomon.decode(&copy) == 0)
        var damaged = word
        var positions = Set<Int>()
        while positions.count < 16 { positions.insert(Int(random.next() % 255)) }
        for p in positions { damaged[p] ^= random.byte() | 1 }
        #expect(MeteorReedSolomon.decode(&damaged) == 16)
        #expect(damaged == word)
        // 17 Fehler sind zu viel – das Codewort darf nicht als gültig durchgehen.
        var broken = word
        positions.removeAll()
        while positions.count < 17 { positions.insert(Int(random.next() % 255)) }
        for p in positions { broken[p] ^= random.byte() | 1 }
        let result = MeteorReedSolomon.decode(&broken)
        #expect(result == nil || broken != word)
    }

    @Test("Reed-Solomon verschachtelt mit Tiefe 4")
    func interleaved() {
        var random = F.Random(state: 11)
        let data = (0..<892).map { _ in random.byte() }
        var block = MeteorReedSolomon.encodeInterleaved(data)
        for i in stride(from: 0, to: 1020, by: 17) { block[i] ^= 0x5A }     // 60 Fehler, 15 je Codewort
        let results = MeteorReedSolomon.decodeInterleaved(&block)
        #expect(results.allSatisfy { $0 != nil })
        #expect(Array(block[0..<892]) == data)
    }

    @Test("Viterbi dekodiert verrauschte weiche Werte fehlerfrei")
    func viterbi() {
        var random = F.Random(state: 3)
        let bits = (0..<4000).map { _ in UInt8(random.next() & 1) }
        let soft = F.soft(MeteorConvolutionalCode.encode(bits), noise: 30, random: &random)
        let viterbi = MeteorViterbi()
        var out: [UInt8] = []
        // In Stücken, wie im Betrieb.
        for start in stride(from: 0, to: soft.count, by: 1000) {
            let chunk = Array(soft[start..<min(start + 1000, soft.count)])
            out += chunk.withUnsafeBufferPointer { viterbi.decode($0, flush: start + 1000 >= soft.count) }
        }
        #expect(out == bits)
        #expect(MeteorViterbi.bitErrorRate(Array(soft.prefix(2048))) < 0.12)
    }

    @Test("Rahmen werden unter allen Phasenlagen gefunden", arguments: [false, true])
    func frameSync(differential: Bool) {
        var random = F.Random(state: differential ? 21 : 22)
        let vcdus = (0..<6).map { _ in (0..<892).map { _ in random.byte() } }
        let coded = F.codedBits(vcdus.map(F.cadu), differential: differential)
        for hypothesis in MeteorPhaseHypothesis.all {
            var soft = F.soft(coded, noise: 25, random: &random)
            // Kanalseitig verdrehen: Umkehrung der Hypothese anwenden.
            var i = 0
            while i + 1 < soft.count {
                var a = soft[i], b = soft[i + 1]
                if hypothesis.rotate90 { (a, b) = (-b, a) }
                if hypothesis.swapIQ { swap(&a, &b) }
                soft[i] = a; soft[i + 1] = b
                i += 2
            }
            if hypothesis.shift { soft.insert(17, at: 0) }
            // 180° obendrauf: invertierte Daten.
            if hypothesis.shift && hypothesis.rotate90 { soft = soft.map { $0 == -128 ? 127 : -$0 } }
            let decoder = MeteorFrameDecoder()
            var found: [[UInt8]] = []
            for start in stride(from: 0, to: soft.count, by: 5000) {
                found += decoder.process(Array(soft[start..<min(start + 5000, soft.count)]))
            }
            // Der letzte Rahmen steckt noch in der Viterbi-Verzögerung.
            #expect(found.count >= 4, "Hypothese \(hypothesis)")
            #expect(found.allSatisfy { vcdus.contains($0) })
            #expect(decoder.statistics.differential == differential)
        }
    }

    // MARK: Pakete und Bild

    @Test("JPEG-Rundweg: selbst kodierter Streifen wird zurückgewonnen")
    func jpegRoundTrip() throws {
        var strip = [UInt8](repeating: 0, count: 8 * MeteorJPEG.segmentWidth)
        for r in 0..<8 {
            for c in 0..<MeteorJPEG.segmentWidth { strip[r * MeteorJPEG.segmentWidth + c] = F.pixel(channel: 1, row: r, column: c) }
        }
        let payload = F.segmentPayload(pixels: strip, mcuNumber: 28, quality: 90)
        let segment = try #require(MeteorJPEG.decodeSegment(payload))
        #expect(segment.mcuNumber == 28)
        #expect(segment.decodedMCUs == 14)
        let worst = zip(segment.pixels, strip).map { abs(Int($0) - Int($1)) }.max() ?? 255
        #expect(worst <= 12)
    }

    @Test("Ein abgeschnittenes Paket liefert nur die vollständigen MCUs")
    func jpegTruncated() throws {
        let strip = [UInt8](repeating: 100, count: 8 * MeteorJPEG.segmentWidth)
        let payload = F.segmentPayload(pixels: strip, mcuNumber: 0)
        let segment = try #require(MeteorJPEG.decodeSegment(Array(payload.prefix(16))))
        #expect(segment.decodedMCUs < 14)
        #expect(segment.pixels.last == 0)
    }

    @Test("Pakete über VCDU-Grenzen, Neuaufsetzen nach einer Lücke")
    func packetDemux() {
        var random = F.Random(state: 5)
        let packets = (0..<30).map { n in
            MeteorPacketDemux.packet(apid: 64 + n % 3, sequence: n, payload: (0..<(100 + Int(random.next() % 900))).map { _ in random.byte() })
        }
        let frames = MeteorPacketDemux.pack(packets)
        let demux = MeteorPacketDemux()
        let all = frames.flatMap { demux.process($0) }
        #expect(all.count == packets.count)
        #expect(all.map(\.sequence) == Array(0..<30))
        #expect(all[7].payload == Array(packets[7][6...]))

        let gap = MeteorPacketDemux()
        var withGap: [MeteorPacket] = []
        for (i, f) in frames.enumerated() where i != 5 { withGap += gap.process(f) }
        #expect(gap.lostFrames == 1)
        #expect(withGap.count < packets.count)
        #expect(withGap.allSatisfy { p in packets.contains { $0 == MeteorPacketDemux.packet(apid: p.apid, sequence: p.sequence, payload: p.payload) } })
    }

    @Test("Bild aus drei Kanälen, fehlendes Paket bleibt schwarz")
    func imageAssembly() throws {
        let raw = F.imagePackets(apids: [64, 65, 67], groups: 3, startSequence: 16_370)   // mit Zählerüberlauf
        var assembler = MeteorImageAssembler()
        for (n, bytes) in raw.enumerated() where n != 50 {        // Gruppe 1, Kanal 64, Stück 7 fehlt
            let apid = Int(bytes[0] & 7) << 8 | Int(bytes[1])
            let sequence = Int(bytes[2] & 0x3F) << 8 | Int(bytes[3])
            assembler.add(MeteorPacket(apid: apid, sequence: sequence, payload: Array(bytes[6...])))
        }
        #expect(assembler.channelNumbers == [1, 2, 4])
        #expect(assembler.period == 43)
        let image = try #require(assembler.grayImage(channel: 4))
        #expect(image.width == 1568)
        #expect(image.height == 24)
        // Stichprobe in Kanal 4, Zeile 13, Spalte 500.
        let expected = Int(F.pixel(channel: 4, row: 13, column: 500))
        #expect(abs(Int(image.pixels[13 * 1568 + 500]) - expected) <= 12)
        let first = try #require(assembler.grayImage(channel: 1))
        let missing = 8 * 1568 + 7 * 112 + 50
        #expect(first.pixels[missing] == 0)
        #expect(first.pixels[missing - 112] != 0)
        #expect(MeteorComposite.rgb124.render(assembler) != nil)
        #expect(MeteorComposite.rgb221.available(in: assembler.channelNumbers))
        #expect(!MeteorComposite.rgb321.available(in: assembler.channelNumbers))
    }

    // MARK: Demodulator und ganze Kette

    @Test("Ganze Kette: OQPSK mit Frequenzablage und Rauschen ergibt das Bild",
          arguments: [MeteorSignal.oqpsk72, .qpsk72])
    func fullChain(signal: MeteorSignal) throws {
        var random = F.Random(state: signal == .oqpsk72 ? 99 : 98)
        let packets = F.imagePackets(apids: [64, 65, 66], groups: 2)
        let vcdus = MeteorPacketDemux.pack(packets)
        // Vorlauf mit Füll-VCDUs, damit Takt, Träger und Viterbi einrasten.
        var filler = [UInt8](repeating: 0, count: 892)
        filler[1] = 63
        let all = [[UInt8]](repeating: filler, count: 8) + vcdus + [[UInt8]](repeating: filler, count: 3)
        let coded = F.codedBits(all.map(F.cadu), differential: signal == .oqpsk72)
        let rate = 288_000.0
        let (re, im) = F.baseband(coded, samplesPerSymbol: 4, oqpsk: signal == .oqpsk72, frequency: 1_800,
                                  sampleRate: rate, phase: 1.1, snr: 12, delay: 3, random: &random)
        let receiver = MeteorReceiver(inputRate: rate, offset: 0, signal: signal)
        let demodulator = MeteorDemodulator(inputRate: rate, offset: 0, modulation: signal.modulation)
        for start in stride(from: 0, to: re.count, by: 20_000) {
            let end = min(start + 20_000, re.count)
            receiver.processSoft(demodulator.process(re: Array(re[start..<end]), im: Array(im[start..<end])))
        }
        let snapshot = receiver.snapshot
        #expect(demodulator.locked)
        #expect(abs(demodulator.frequencyOffset - 1_800) < 100)
        #expect(snapshot.frame.framesOK >= vcdus.count)
        let image = receiver.currentImage
        #expect(image.channelNumbers == [1, 2, 3])
        let gray = try #require(image.grayImage(channel: 2))
        #expect(gray.height == 16)
        let expected = Int(F.pixel(channel: 2, row: 9, column: 1000))
        #expect(abs(Int(gray.pixels[9 * 1568 + 1000]) - expected) <= 12)
    }

    @Test("Mischen und Dezimieren: Kanal 400 kHz neben der Mitte bei 2,88 MS/s")
    func mixAndDecimate() {
        var random = F.Random(state: 1234)
        var bits: [UInt8] = []
        for _ in 0..<12 { bits += (0..<892).map { _ in random.byte() } }
        let vcdus = stride(from: 0, to: bits.count, by: 892).map { Array(bits[$0..<($0 + 892)]) }
        let coded = F.codedBits(vcdus.map(F.cadu), differential: true)
        let rate = 2_880_000.0
        let (re, im) = F.baseband(coded, samplesPerSymbol: 40, oqpsk: true, frequency: 400_000 - 2_500,
                                  sampleRate: rate, phase: 0.3, snr: 14, delay: 17, random: &random)
        let receiver = MeteorReceiver(inputRate: rate, offset: 400_000, signal: .oqpsk72)
        let demodulator = MeteorDemodulator(inputRate: rate, offset: 400_000, modulation: .oqpsk)
        #expect(demodulator.decimation == 10)
        for start in stride(from: 0, to: re.count, by: 262_144) {
            let end = min(start + 262_144, re.count)
            receiver.processSoft(demodulator.process(re: Array(re[start..<end]), im: Array(im[start..<end])))
        }
        #expect(abs(demodulator.frequencyOffset + 2_500) < 100)
        #expect(receiver.snapshot.frame.framesOK >= 8)
    }

    @Test("Rechenzeit: eine Sekunde HackRF-Daten (2,88 MS/s)")
    func throughput() {
        var random = F.Random(state: 77)
        let block = Data((0..<524_288).map { _ in UInt8(truncatingIfNeeded: Int(random.gaussian() * 20)) })
        let receiver = MeteorReceiver(offset: 400_000, signal: .oqpsk72)
        let start = Date()
        for _ in 0..<11 { receiver.process(block) }      // ≈ 2,9 M Abtastwerte
        let seconds = Date().timeIntervalSince(start)
        let demodulator = MeteorDemodulator(inputRate: 2_880_000, offset: 400_000)
        let demodStart = Date()
        for _ in 0..<11 { _ = demodulator.process(block) }
        print(String(format: "METEOR: 1 s Signal in %.2f s verarbeitet (davon Demodulator %.2f s)",
                     seconds, Date().timeIntervalSince(demodStart)))
        #expect(receiver.snapshot.symbols > 60_000)
    }

    // MARK: Echte Aufnahmen (optional)

    /// Ordner mit Proben: `TEST_RUNNER_METEOR_SAMPLES=<pfad> xcodebuild test …`.
    /// Herkunft (nicht einchecken):
    /// - `iwallplace_m2-3_2026-02-14.cadu`: github.com/iwallplace/meteor-m2-3-lrpt-capture, `data/meteor_m2-x_lrpt.cadu`
    /// - `jmfriedt_extrait.s`: github.com/jmfriedt/meteor-m2, `extrait.s`
    /// - `yam2d_2018_07_22.s`: github.com/DancingVixen/YAM2D, `2018_07_22_LRPT_21-57-39.s`
    /// - `lartech_meteor_m2_72k.wav`: github.com/lar-tech/satellite-decoder, `data/meteor_m2_72k.wav`
    static var samples: URL? {
        ProcessInfo.processInfo.environment["METEOR_SAMPLES"].map { URL(fileURLWithPath: $0) }
    }

    @Test("Echte CADUs von METEOR-M2-3: RS-Prüfung ohne Dual-Basis und Bild",
          .enabled(if: MeteorTests.samples != nil))
    func realCADU() throws {
        let url = try #require(Self.samples?.appendingPathComponent("iwallplace_m2-3_2026-02-14.cadu"))
        let data = try [UInt8](Data(contentsOf: url))
        let receiver = MeteorReceiver(offset: 0, signal: .oqpsk72)
        var valid = 0, frames = 0
        for start in stride(from: 0, to: data.count - 1023, by: 1024) {
            var block = Array(data[(start + 4)..<(start + 1024)])
            frames += 1
            // SatDump schreibt die Rahmen entwürfelt und korrigiert: Parität muss stimmen.
            let results = MeteorReedSolomon.decodeInterleaved(&block)
            if results.allSatisfy({ $0 == 0 }) { valid += 1 }
            receiver.processVCDU(Array(block[0..<892]))
        }
        print("M2-3: \(valid) von \(frames) Rahmen mit Syndrom null")
        #expect(valid * 10 >= frames * 9)
        let image = receiver.currentImage
        print("M2-3: \(frames) Rahmen, Kanäle \(image.channelNumbers), \(image.lineCount) Zeilen, Pakete \(receiver.snapshot.packets)")
        #expect(image.lineCount > 100)
        for composite in MeteorComposite.allCases where composite.available(in: image.channelNumbers) {
            if let cg = composite.render(image) {
                try MeteorPNG.write(cg, to: url.deletingLastPathComponent().appendingPathComponent("m2-3_\(composite.rawValue).png"))
            }
        }
    }

    @Test("Echte M2-3-Rahmen neu moduliert (OQPSK, NRZ-M, 2,88 MS/s, Doppler)", .enabled(if: MeteorTests.samples != nil))
    func realCADURemodulated() throws {
        let url = try #require(Self.samples?.appendingPathComponent("iwallplace_m2-3_2026-02-14.cadu"))
        let data = try [UInt8](Data(contentsOf: url))
        // 60 Rahmen ab Rahmen 100 (dort ohne Lücken).
        let vcdus = (100..<160).map { n -> [UInt8] in
            var block = Array(data[(n * 1024 + 4)..<(n * 1024 + 1024)])
            _ = MeteorReedSolomon.decodeInterleaved(&block)
            return Array(block[0..<892])
        }
        var random = F.Random(state: 4711)
        let coded = F.codedBits(vcdus.map(F.cadu), differential: true)
        let rate = 2_880_000.0
        let (re, im) = F.baseband(coded, samplesPerSymbol: 40, oqpsk: true, frequency: -400_000 + 3_200,
                                  sampleRate: rate, phase: 2.0, snr: 11, delay: 29, random: &random)
        let receiver = MeteorReceiver(inputRate: rate, offset: -400_000, signal: .oqpsk72)
        let reference = MeteorReceiver(offset: 0, signal: .oqpsk72)
        for v in vcdus { reference.processVCDU(v) }
        let demodulator = MeteorDemodulator(inputRate: rate, offset: -400_000, modulation: .oqpsk)
        for start in stride(from: 0, to: re.count, by: 262_144) {
            let end = min(start + 262_144, re.count)
            receiver.processSoft(demodulator.process(re: Array(re[start..<end]), im: Array(im[start..<end])))
        }
        let s = receiver.snapshot
        print("M2-3 neu moduliert: Rahmen ok \(s.frame.framesOK) von \(vcdus.count), Ablage \(demodulator.frequencyOffset) Hz, Pakete \(s.packets) (Referenz \(reference.snapshot.packets))")
        #expect(s.frame.framesOK >= vcdus.count - 5)      // Einrasten am Anfang, Viterbi-Verzögerung am Ende
        #expect(s.frame.differential == true)
    }

    @Test("Echtes Basisband der alten METEOR-M2 (WAV, 187,5 kS/s, QPSK)", .enabled(if: MeteorTests.samples != nil))
    func realBaseband() throws {
        let url = try #require(Self.samples?.appendingPathComponent("lartech_meteor_m2_72k.wav"))
        let data = try Data(contentsOf: url)
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let receiver = MeteorReceiver(offset: 0, signal: .qpsk72)
        let demodulator = MeteorDemodulator(inputRate: 187_500, offset: 0, modulation: .qpsk)
        let chunk = 65_536
        var lockedAt: Int?
        for start in stride(from: 0, to: samples.count / 2, by: chunk) {
            let end = min(start + chunk, samples.count / 2)
            let re = (start..<end).map { Float(samples[2 * $0]) / 32768 }
            let im = (start..<end).map { Float(samples[2 * $0 + 1]) / 32768 }
            receiver.processSoft(demodulator.process(re: re, im: im))
            if lockedAt == nil, demodulator.locked { lockedAt = start }
            if start % (chunk * 15) == 0 {
                let s = receiver.snapshot
                print(String(format: "WAV t=%.1f s: Träger %@ %.2f, Ablage %.0f Hz, Pegel %.1f dB, Viterbi %@ BER %.3f, ok %d, Fehler %d",
                             Double(start) / 187_500, demodulator.locked ? "ja" : "nein", demodulator.lockQuality,
                             demodulator.frequencyOffset, demodulator.levelDB, s.frame.viterbiLocked ? "ja" : "nein",
                             s.frame.bitErrorRate, s.frame.framesOK, s.frame.framesFailed))
            }
        }
        let s = receiver.snapshot
        print("WAV: gerastet ab \(lockedAt ?? -1), Ablage \(demodulator.frequencyOffset) Hz, Rahmen ok \(s.frame.framesOK), Fehler \(s.frame.framesFailed), korrigiert \(s.frame.rsCorrectedBytes), BER \(s.frame.bitErrorRate), Zeilen \(s.lines), Kanäle \(s.segments)")
        #expect(s.frame.framesOK > 100)
        let image = receiver.currentImage
        if let composite = MeteorComposite.allCases.first(where: { $0.available(in: image.channelNumbers) }),
           let cg = composite.render(image) {
            try MeteorPNG.write(cg, to: url.deletingLastPathComponent().appendingPathComponent("lartech.png"))
        }
    }

    @Test("Echte weiche Symbole der alten METEOR-M2 (QPSK)", .enabled(if: MeteorTests.samples != nil),
          arguments: ["yam2d_2018_07_22.s", "jmfriedt_extrait.s"])
    func realSoft(file: String) throws {
        let url = try #require(Self.samples?.appendingPathComponent(file))
        let data = try Data(contentsOf: url)
        let soft = data.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
        let receiver = MeteorReceiver(offset: 0, signal: .qpsk72)
        for start in stride(from: 0, to: soft.count, by: 65_536) {
            receiver.processSoft(Array(soft[start..<min(start + 65_536, soft.count)]))
        }
        let s = receiver.snapshot
        print("\(file): Rahmen ok \(s.frame.framesOK), Fehler \(s.frame.framesFailed), korrigiert \(s.frame.rsCorrectedBytes) Bytes, BER \(s.frame.bitErrorRate), \(s.frame.hypothesis), NRZ-M \(String(describing: s.frame.differential)), Zeilen \(s.lines), Kanäle \(s.segments)")
        #expect(s.frame.framesOK > 100)
        let image = receiver.currentImage
        if let composite = MeteorComposite.allCases.first(where: { $0.available(in: image.channelNumbers) }),
           let cg = composite.render(image) {
            try MeteorPNG.write(cg, to: url.deletingLastPathComponent().appendingPathComponent(file + ".png"))
        }
    }
}
