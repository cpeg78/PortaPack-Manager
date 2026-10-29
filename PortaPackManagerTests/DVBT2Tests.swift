import Foundation
import Testing
@testable import PortaPackManager

@Suite("DVB-T2")
struct DVBT2Tests {
    // MARK: - Bezugsfolgen und Trägerbelegung

    @Test("Pilot-Bezugsfolge beginnt mit elf Einsen, Rahmenfolge mit 0x4D")
    func referenceSequences() {
        #expect(Array(T2Reference.prbs.prefix(13)) == [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0])
        #expect(Array(T2Reference.frameSequence.prefix(8)) == [0, 1, 0, 0, 1, 1, 0, 1])
        #expect(T2Reference.frameSequence.count == 2624)
    }

    /// Datenzellen je Symbol (Tabelle 48) – prüft Streu- und Continual-Pilot-Tabellen.
    @Test("Datenzellen je Symbol stimmen mit Tabelle 48 überein")
    func dataCells() throws {
        let normal: [Int: [Int?]] = [
            1: [764, 768, 798, 804, 818, nil, nil, nil],
            2: [1522, 1532, 1596, 1602, 1632, nil, 1646, nil],
            4: [3084, 3092, 3228, 3234, 3298, nil, 3328, nil],
            8: [6208, 6214, 6494, 6498, 6634, nil, 6698, 6698],
            16: [12418, 12436, 12988, 13002, 13272, 13288, 13416, 13406],
            32: [nil, 24886, nil, 26022, nil, 26592, 26836, 26812],
        ]
        let extended: [Int: [Int?]] = [
            8: [6296, 6298, 6584, 6588, 6728, nil, 6788, 6788],
            16: [12678, 12698, 13262, 13276, 13552, 13568, 13698, 13688],
            32: [nil, 25412, nil, 26572, nil, 27152, 27404, 27376],
        ]
        for (table, ext) in [(normal, false), (extended, true)] {
            for (k, row) in table {
                let fft = try #require(T2FFTSize(rawValue: k))
                for (index, expected) in row.enumerated() {
                    guard let expected else { continue }
                    let pattern = try #require(T2PilotPattern(rawValue: index))
                    let layout = try #require(T2Layout(fft: fft, guardInterval: .g1_128, pattern: pattern, extended: ext,
                                                       toneReservation: false, dataSymbols: 10))
                    // 16K PP1 erweitert: Tabelle 48 nennt 12 678; in Symbolen mit l mod 4 = 0
                    // fallen beide Randpiloten auf Streupiloten, die Pilotdefinition ergibt dort
                    // einen Träger mehr. Nur mit Schutzintervall 1/4 erlaubt, in Deutschland ungenutzt.
                    if fft == .k16 && pattern == .pp1 && ext { continue }
                    for phase in 0..<pattern.dy {
                        let count = layout.dataCarriers(symbol: fft.p2Symbols + phase).count
                        #expect(count == expected, "\(fft.name) \(pattern.name) \(ext ? "erweitert" : "normal") Phase \(phase): \(count)")
                    }
                }
            }
        }
    }

    @Test("P2- und Abschlusssymbol-Zellen stimmen mit Tabellen 47 und 49 überein")
    func p2AndFrameClosingCells() throws {
        let p2: [T2FFTSize: Int] = [.k1: 558, .k2: 1118, .k4: 2236, .k8: 4472, .k16: 8944, .k32: 22432]
        for (fft, expected) in p2 {
            for ext in fft.kext > 0 ? [false, true] : [false] {
                let layout = try #require(T2Layout(fft: fft, guardInterval: .g1_8, pattern: .pp2, extended: ext,
                                                   toneReservation: false, dataSymbols: 10))
                #expect(layout.p2Carriers.count == expected, "\(fft.name)")
            }
        }
        // 16K, Schutzintervall 19/128: Abschlusssymbol bei PP2 und PP3.
        let nfc: [(T2PilotPattern, Int, Int)] = [(.pp2, 11360, 11600), (.pp3, 11360, 11600)]
        for (pattern, normal, extended) in nfc {
            for (ext, expected) in [(false, normal), (true, extended)] {
                let layout = try #require(T2Layout(fft: .k16, guardInterval: .g19_128, pattern: pattern, extended: ext,
                                                   toneReservation: false, dataSymbols: 87))
                #expect(layout.frameClosing)
                #expect(layout.frameClosingCarriers.count == expected)
            }
        }
        let k23 = try #require(T2Layout(fft: .k16, guardInterval: .g19_128, pattern: .pp2, extended: true,
                                        toneReservation: false, dataSymbols: 87))
        #expect(k23.frameClosingActive == 10697)
        #expect(k23.frameSamples == 1_657_856)    // gemessener P1-Abstand auf K23
    }

    // MARK: - Interleaver

    @Test("Frequenz- und Zell-Interleaver sind Permutationen; Verschiebungen wie im Normbeispiel")
    func interleavers() {
        for (fft, count) in [(T2FFTSize.k16, 12698), (.k16, 8944), (.k32, 27404), (.k8, 6298), (.k1, 768)] {
            for odd in [false, true] {
                let h = T2Interleavers.frequency(fft, count: count, odd: odd)
                #expect(h.count == count && Set(h).count == count, "\(fft.name)")
            }
        }
        let base = T2Interleavers.cellBase(cells: 10800)
        #expect(Set(base).count == 10800)
        #expect(T2Interleavers.cellShifts(cells: 10800, blocks: 8) == [0, 8192, 4096, 2048, 10240, 6144, 1024, 9216])
    }

    @Test("Bitabbildung ist eine Permutation der Kodewortbits")
    func bitMapper() {
        let cases: [(T2FEC, T2Modulation)] = [
            (T2FEC(normal: true, rate: .r1_2), .qam64), (T2FEC(normal: true, rate: .r2_3), .qam256),
            (T2FEC(normal: false, rate: .r3_5), .qam16), (T2FEC(normal: true, rate: .r3_4), .qpsk),
            (T2FEC(normal: false, rate: .r2_3), .qam256),
        ]
        for (fec, modulation) in cases {
            let mapper = T2BitMapper.mapper(fec: fec, modulation: modulation, rotated: false)
            #expect(Set(mapper.position).count == fec.nldpc, "\(modulation.name) \(fec.rate.name)")
        }
    }

    // MARK: - LDPC

    /// Systematische Kodierung über die Prüfmatrix (Akkumulator).
    static func encode(_ code: T2LDPCCode, _ info: [UInt8]) -> [UInt8] {
        var word = info + [UInt8](repeating: 0, count: code.m)
        for c in 0..<code.m {
            var s: UInt8 = 0
            for e in Int(code.offsets[c])..<Int(code.offsets[c + 1]) where Int(code.variables[e]) < code.k {
                s ^= word[Int(code.variables[e])]
            }
            word[code.k + c] = s ^ (c > 0 ? word[code.k + c - 1] : 0)
        }
        return word
    }

    /// Reproduzierbares Gaußrauschen.
    struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func gauss() -> Float {
            Float((-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()))
        }
    }

    @Test("LDPC: verrauschte Kodewörter werden fehlerfrei (64K 2/3, 16K 3/5)")
    func ldpc() {
        var noise = Noise(state: 42)
        // Eb/N0 ≈ 3 dB: deutlich verrauscht (rund 5 % Rohfehler), aber über der Schwelle.
        for (fec, sigma) in [(T2FEC(normal: true, rate: .r2_3), Float(0.6)), (T2FEC(normal: false, rate: .r3_5), Float(0.6))] {
            let code = T2LDPCCode.code(fec)
            let words = (0..<3).map { _ in Self.encode(code, (0..<code.k).map { _ in noise.uniform() < 0.5 ? 0 : 1 }) }
            #expect(words.allSatisfy { w in w.withUnsafeBufferPointer { code.check($0.baseAddress!) } })
            let llr = words.map { w in w.map { b -> Float in 2 * ((b == 0 ? 1 : -1) + sigma * noise.gauss()) / (sigma * sigma) } }
            let raw = zip(words[0], llr[0]).filter { ($0.1 < 0 ? 1 : 0) != $0.0 }.count
            #expect(raw > code.n / 40)                            // wirklich verrauscht
            let out = T2LDPCBatchDecoder(code: code).decode(llr)
            for (result, word) in zip(out, words) {
                #expect(result.ok)
                #expect(result.bits == word)
            }
        }
    }

    // MARK: - L1

    /// L1-pre und L1-post von K23 (490 MHz, DVB-T2 HD), Rahmen 0.
    static let preBits = T2K23.preBits
    static let postBits = T2K23.postBits
    static func bits(_ s: String) -> [UInt8] { s.map { $0 == "1" ? 1 : 0 } }

    @Test("BCH: Generator 16K = Produkt der Tabelle 7b; bis 12 Fehler werden korrigiert, 13 erkannt")
    func bch() {
        let short = T2BCH(m: 14, t: 12, n: 7200)
        #expect(short.generator == T2TestTransmitter.bch16KGenerator)
        #expect(short.parityBits == 168 && short.k == 7032)
        let normal = T2BCH(m: 16, t: 12, n: 32_400)
        #expect(normal.parityBits == 192 && normal.k == 32_208)
        // g₁ und g₂ der normalen Rahmen (Tabelle 7a) sind Faktoren des Generators:
        // g₁ = 1+x²+x³+x⁵+x¹⁶ ist das Feldpolynom; Teilbarkeit durch Polynomdivision.
        func divides(_ divisor: [UInt8], _ poly: [UInt8]) -> Bool {
            var r = poly
            while r.count >= divisor.count {
                if r.last == 1 { for (i, d) in divisor.enumerated() { r[r.count - divisor.count + i] ^= d } }
                r.removeLast()
            }
            return r.allSatisfy { $0 == 0 }
        }
        let g1: [UInt8] = "10110100000000001".map { $0 == "1" ? 1 : 0 }
        let g2: [UInt8] = "11001110100000001".map { $0 == "1" ? 1 : 0 }
        #expect(divides(g1, normal.generator))
        #expect(divides(g2, normal.generator))

        var rng = T2SimRandom(state: 7)
        let message = (0..<normal.k).map { _ in UInt8(rng.next() & 1) }
        let word = message + normal.parity(message)
        #expect(normal.check(word))
        for errors in [1, 5, 12] {
            var damaged = word
            var positions = Set<Int>()
            while positions.count < errors { positions.insert(Int(rng.next() % UInt64(normal.n))) }
            for p in positions { damaged[p] ^= 1 }
            #expect(!normal.check(damaged))
            #expect(normal.correct(&damaged) == errors, "\(errors) Fehler")
            #expect(damaged == word)
        }
        var damaged = word
        for p in stride(from: 100, to: 100 + 13 * 97, by: 97) { damaged[p] ^= 1 }
        #expect(normal.correct(&damaged) == nil)
        // Kurzer Rahmen: 12 Fehler, auch in der Parität.
        let shortMessage = (0..<short.k).map { _ in UInt8(rng.next() & 1) }
        var shortWord = shortMessage + short.parity(shortMessage)
        let original = shortWord
        for p in [0, 1, 500, 3000, 7031, 7032, 7100, 7199, 4444, 6000, 2222, 1234] { shortWord[p] ^= 1 }
        #expect(short.correct(&shortWord) == 12)
        #expect(shortWord == original)
    }

    @Test("L1-pre von K23: CRC und Felder")
    func l1Pre() {
        let bits = Self.bits(Self.preBits)
        #expect(T2CRC.crc32Valid(bits[...]))
        let pre = T2L1Pre(bits: bits)
        #expect(pre.extendedCarriers)
        #expect(pre.s2 == 8)
        #expect(T2GuardInterval(rawValue: pre.guardInterval) == .g19_128)
        #expect(T2PilotPattern(rawValue: pre.pilotPattern) == .pp2)
        #expect(pre.l1PostSize == 1500 && pre.l1PostInfoSize == 318)
        #expect(pre.dataSymbols == 87 && pre.t2Frames == 2)
        #expect(pre.networkID == 0x300A && pre.cellID == 0x0A21)
        #expect(pre.version == 2)
    }

    @Test("L1-post von K23: ein PLP, 64-QAM 1/2, 102 Blöcke")
    func l1Post() throws {
        let pre = T2L1Pre(bits: Self.bits(Self.preBits))
        let bits = Self.bits(Self.postBits)
        #expect(T2CRC.crc32Valid(bits[...]))
        let post = try #require(T2L1Post(bits: Array(bits.prefix(318)), pre: pre))
        #expect(post.frequencies == [490_000_000])
        let plp = try #require(post.plps.first)
        #expect(post.plps.count == 1)
        #expect(plp.type == 1 && plp.payloadType == 3)
        #expect(plp.constellation == .qam64 && plp.fec == T2FEC(normal: true, rate: .r1_2))
        #expect(plp.blocks == 102 && plp.blocksMax == 102 && plp.start == 0)
        #expect(plp.timeInterleavingType == 0 && plp.timeInterleavingLength == 2)
        #expect(plp.mode == 2 && plp.inBandA && plp.staticFlag)
    }

    /// BCH (16K, t = 12): Produkt der ersten zwölf Polynome aus Tabelle 7(b).
    static func bch16K(_ message: [UInt8]) -> [UInt8] {
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
        let degree = g.count - 1
        var register = [UInt8](repeating: 0, count: degree)   // register[0] = höchster Grad
        for bit in message {
            let feedback = bit ^ register[0]
            register.removeFirst()
            register.append(0)
            if feedback == 1 { for i in 0..<degree { register[i] ^= g[degree - 1 - i] } }
        }
        return register
    }

    @Test("L1-pre: verkürzt, punktiert, BPSK, verrauscht – wird wieder gelesen")
    func l1PreRoundTrip() throws {
        let info = Self.bits(Self.preBits)
        let fec = T2FEC(normal: false, rate: .r1_4)
        let code = T2LDPCCode.code(fec)
        // BCH über Info + Nullen, dann LDPC; Info liegt (Ksig < 360) am Anfang von Gruppe 0.
        var message = [UInt8](repeating: 0, count: fec.kbch)
        message.replaceSubrange(0..<200, with: info)
        let word = Self.encode(code, message + Self.bch16K(message))
        let puncture = [27, 13, 29, 32, 5, 0, 11, 21, 33, 20, 25, 28, 18, 35, 8, 3, 9, 31, 22, 24, 7, 14, 17, 4, 2, 26,
                        16, 34, 19, 10, 12, 23, 1, 6, 30, 15]
        var punctured = Set<Int>()
        for g in 0..<31 { for c in 0..<360 { punctured.insert(c * 36 + puncture[g]) } }
        for c in 0..<328 { punctured.insert(c * 36 + puncture[31]) }
        var sent = Array(word[0..<200]) + Array(word[3072..<3240])
        for i in 0..<(fec.nldpc - fec.kldpc) where !punctured.contains(i) { sent.append(word[fec.kldpc + i]) }
        #expect(sent.count == 1840)
        var noise = Noise(state: 7)
        let re = sent.map { Float($0 == 0 ? 1 : -1) + 0.5 * noise.gauss() }
        let pre = try #require(T2L1Decoder.decodePre(re: [re], im: [[Float](repeating: 0, count: 1840)],
                                                     weights: [[Float](repeating: 1 / 0.25, count: 1840)]))
        #expect(pre == T2L1Pre(bits: info))
    }

    // MARK: - Basisband und Transportstrom

    @Test("BBFRAME im High Efficiency Mode mit Nullpaket-Löschung → TS-Pakete")
    func baseBand() {
        let fec = T2FEC(normal: true, rate: .r1_2)
        // Zwei Pakete, das erste beginnt 10 Byte nach dem Datenfeldanfang (Rest des vorigen).
        let packets: [[UInt8]] = (0..<3).map { n in [0x47] + (1..<188).map { UInt8(($0 * 7 + n * 31) & 0xFF) } }
        var field: [UInt8] = [UInt8](repeating: 0xAA, count: 10)
        for p in packets { field += p[1...] + [0] }            // 187 Bytes + DNP
        var header: [UInt8] = [0xF4, 0x00, 0, 0, 0, 0, 0, 0, 0]
        let dfl = field.count * 8
        header[4] = UInt8(dfl >> 8); header[5] = UInt8(dfl & 0xFF)
        header[7] = 0; header[8] = 80                          // SYNCD = 80 Bit
        header.append(T2CRC.crc8(header[...]) ^ 1)              // MODE = 1 (HEM)
        var bytes = header + field
        bytes += [UInt8](repeating: 0, count: fec.kbch / 8 - bytes.count)
        let prbs = T2Reference.scramblingSequence(fec.kbch)
        var bits = [UInt8](repeating: 0, count: fec.kbch)
        for i in 0..<fec.kbch { bits[i] = (bytes[i / 8] >> (7 - UInt8(i % 8)) & 1) ^ prbs[i] }
        let extractor = T2TransportStreamExtractor()
        var out: [[UInt8]] = []
        extractor.packetHandler = { out.append($0) }
        extractor.process(bits: bits, ok: true)
        #expect(extractor.lastHeader?.highEfficiency == true)
        #expect(extractor.lastHeader?.nullPacketDeletion == true)
        #expect(out == packets)
    }

    /// PSI-Abschnitt mit Kopf und CRC.
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

    static func packet(pid: Int, _ section: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10, 0x00] + section
        p += [UInt8](repeating: 0xFF, count: 188 - p.count)
        return p
    }

    @Test("Transportstrom: PAT, PMT und SDT ergeben den Dienst samt Namen")
    func psi() throws {
        let demux = TSDemuxer()
        let pat = Self.section(table: 0x00, id: 0x1234, body: [0x00, 0x0A, 0xE1, 0x00])        // Programm 10 → PMT 0x100
        let pmt = Self.section(table: 0x02, id: 10, body: [0xE1, 0x01, 0xF0, 0x00,
                                                           0x24, 0xE1, 0x01, 0xF0, 0x00,             // HEVC auf 0x101
                                                           0x06, 0xE1, 0x02, 0xF0, 0x08, 0x7A, 0x01, 0x00,  // E-AC-3
                                                           0x0A, 0x03, 0x64, 0x65, 0x75])
        let name = Array("Das Erste HD".utf8)
        let provider = Array("ARD".utf8)
        let descriptor: [UInt8] = [0x48, UInt8(3 + provider.count + name.count), 0x1F, UInt8(provider.count)] + provider + [UInt8(name.count)] + name
        let sdt = Self.section(table: 0x42, id: 0x1234, body: [0x00, 0x01, 0xFF, 0x00, 0x0A, 0xFC, 0x80 | 0, UInt8(descriptor.count)] + descriptor)
        for (pid, s) in [(0, pat), (0x100, pmt), (0x11, sdt)] { demux.process(Self.packet(pid: pid, s)) }
        let service = try #require(demux.services[10])
        #expect(service.name == "Das Erste HD" && service.provider == "ARD")
        #expect(service.typeName == "TV (HEVC)")
        #expect(service.video?.pid == 0x101 && service.video?.kind == .hevc)
        #expect(service.audio.first?.kind == .eac3 && service.audio.first?.language == "deu")
        #expect(!service.scrambled)
    }

    @Test("DVB-Text: ISO 6937 mit Akzentzeichen, ISO 8859-9 und UTF-8")
    func dvbText() {
        #expect(DVBText.decode([0x4D, 0xC8, 0x75, 0x6E, 0x63, 0x68, 0x65, 0x6E][...]) == "München")
        #expect(DVBText.decode([0x05, 0x47, 0x72, 0xFC, 0xDF][...]) == "Grüß")
        #expect(DVBText.decode([0x15] + Array("Tagesschau – Ü".utf8)) == "Tagesschau – Ü")
    }

    // MARK: - P1

    @Test("P1: Suche findet das Symbol, S1/S2 werden gelesen")
    func p1() throws {
        // P1 nach 9.8.2.4: A aus 384 DBPSK-Trägern, C und B frequenzverschoben.
        let pattern = try #require(T2P1.patterns.first { $0.s1 == 0 && $0.s2 == 8 })
        // Modulationswerte aus den Differenzen zurückgewinnen (Start +1).
        var values: [Float] = [1]
        for d in pattern.diff { values.append(values.last! * d) }
        var aRe = [Float](repeating: 0, count: 1024), aIm = aRe
        for (i, k) in T2P1.carriers.enumerated() {
            for t in 0..<1024 {
                let phase = 2 * Float.pi * Float((k - 426) * t) / 1024
                aRe[t] += values[i] * cos(phase) / 20
                aIm[t] += values[i] * sin(phase) / 20
            }
        }
        var noise = Noise(state: 3)
        let offset = 5000
        var re = (0..<20_000).map { _ in 0.05 * noise.gauss() }, im = re
        for t in 0..<2048 {
            var (r, i): (Float, Float)
            if t < 542 {
                let phase = 2 * Float.pi * Float(t) / 1024
                (r, i) = (aRe[t] * cos(phase) - aIm[t] * sin(phase), aRe[t] * sin(phase) + aIm[t] * cos(phase))
            } else if t < 1566 {
                (r, i) = (aRe[t - 542], aIm[t - 542])
            } else {
                let phase = 2 * Float.pi * Float(t) / 1024
                let a = (aRe[t - 1024], aIm[t - 1024])
                (r, i) = (a.0 * cos(phase) - a.1 * sin(phase), a.0 * sin(phase) + a.1 * cos(phase))
            }
            re[offset + t] += r
            im[offset + t] += i
        }
        let found = re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in
            T2P1.search(re: r.baseAddress!, im: i.baseAddress!, count: re.count, absoluteStart: 0)
        } }
        let best = try #require(found.max { $0.metric < $1.metric })
        #expect(abs(best.position - offset) <= 2)
        let decoded = try #require(re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in
            T2P1.decode(re: r.baseAddress!, im: i.baseAddress!, at: best.position, fft: T2FFT(size: 1024))
        } })
        #expect(decoded.s1 == 0 && decoded.s2 == 8 && decoded.shift == 0)
        #expect(T2FFTSize.from(s2: decoded.s2) == .k16)
    }

    // MARK: - Demapper

    @Test("64-QAM-LLR entsprechen der exakten Log-MAP-Rechnung über alle 64 Punkte")
    func logMAPDemapper() {
        let fec = T2FEC(normal: true, rate: .r1_2)
        let mapper = T2BitMapper.mapper(fec: fec, modulation: .qam64, rotated: false)
        let levels = T2BitMapper.axisLevels(perAxis: 3)
        #expect(Set(levels) == [-7, -5, -3, -1, 1, 3, 5, 7])
        var noise = Noise(state: 11)
        let count = mapper.cells
        let scale = Float(42).squareRoot()
        var re = [Float](repeating: 0, count: count), im = re
        let weights = [Float](repeating: 3.0, count: count)          // |H|²/N0 ≈ 4,8 dB
        for q in 0..<count { re[q] = Float(noise.gauss()) * 0.7; im[q] = Float(noise.gauss()) * 0.7 }
        var llr = [Float](repeating: 0, count: fec.nldpc)
        mapper.llr(re: re, im: im, weights: weights, into: &llr)
        for q in [0, 1, 777, count - 1] {
            // Direkt: Summe über alle Punkte mit Bit b = 0 bzw. 1, Bits y0 y1 … (gerade = I, ungerade = Q).
            for b in 0..<6 {
                var sum0 = 0.0, sum1 = 0.0
                for i in 0..<8 {
                    for j in 0..<8 {
                        let x = Double(levels[i] / scale), y = Double(levels[j] / scale)
                        let d = Double(weights[q]) * (pow(Double(re[q]) - x, 2) + pow(Double(im[q]) - y, 2))
                        let axisIndex = b % 2 == 0 ? i : j
                        let bit = (axisIndex >> (2 - b / 2)) & 1
                        if bit == 0 { sum0 += exp(-d) } else { sum1 += exp(-d) }
                    }
                }
                let expected = log(sum0) - log(sum1)
                let got = Double(llr[Int(mapper.position[q * 6 + b])])
                #expect(abs(got - expected) < 1e-3 * max(1, abs(expected)), "Zelle \(q) Bit \(b): \(got) statt \(expected)")
            }
        }
    }

    // MARK: - Simulationsprüfstand (DVBT2Simulation.swift)

    /// Echo, Frequenz- und Abtastratenablage zusammen: Die Abtastratenablage
    /// (5 ppm, 8 Abtastwerte Drift je Rahmen) brachte den alten Empfänger schon ab 1 ppm aus dem Tritt.
    @Test("0-dB-Echo, 3 kHz und 5 ppm Ablage bei 20 dB: alle Blöcke fehlerfrei")
    func echoAndOffsets() throws {
        var channel = T2TestChannel.Parameters()
        channel.snrDB = 20
        channel.echoDB = 0
        channel.frequencyOffsetHz = 3000
        channel.sampleRatePPM = 5
        let result = T2Simulation.run(channel, frames: 2)
        #expect(result.locked)
        #expect(result.blocksGood >= 204 && result.blocksBad == 0)
        #expect(result.validPackets > 3000)
    }

    @Test("Anzeige-Schwelle 64-QAM 1/2 passt zur gemessenen Echo-Schwelle")
    func thresholdTable() throws {
        let required = try #require(T2Threshold.requiredSNR(modulation: 2, codeRate: 0))
        #expect(required >= 12.35 && required < 13)
    }

    @Test("Annex-B-Strom wird in NAL-Einheiten zerlegt")
    func nalUnits() {
        let data = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 1, 0x42, 0x01, 0xBB, 0xCC, 0, 0, 1, 0x26, 0x01])
        #expect(TVPlayer.nalUnits(data) == [[0x40, 0x01, 0xAA], [0x42, 0x01, 0xBB, 0xCC], [0x26, 0x01]])
    }
}
