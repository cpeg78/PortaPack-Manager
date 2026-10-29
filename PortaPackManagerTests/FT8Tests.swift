import Foundation
import Testing
@testable import PortaPackManager

/// Reproduzierbares Rauschen (xorshift64*, Box-Muller).
struct FT8Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func uniform() -> Double {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

enum FT8TestSignals {
    /// Komplexes Rauschen (σ = 1 je Komponente) plus FT8-Signale mit
    /// gegebenem SNR in 2500 Hz. `start` in Sekunden ab Zyklusbeginn.
    static func slot(_ signals: [(text: String, frequency: Double, snr: Double, start: Double)], seed: UInt64 = 1,
                     noise: Bool = true, drift: Double = 0) -> FT8Signal {
        var x = FT8Signal(count: FT8Decoder.slotSamples)
        if noise {
            var rng = FT8Noise(seed: seed)
            for i in 0..<x.count { x.re[i] = Float(rng.gaussian()); x.im[i] = Float(rng.gaussian()) }
        }
        // Rauschleistung (komplex, 2σ²) über 12 kHz → in 2500 Hz: 2 · 2500/12000.
        let noiseIn2500 = 2.0 * 2500 / 12_000
        for (i, s) in signals.enumerated() {
            let bits = FT8Message.pack(s.text)!
            let tones = FT8Codec.tones(message: bits)
            var w = FT8Codec.waveform(tones: tones, frequency: s.frequency, phase: Double(i) * 1.3)
            if drift != 0 {
                // Lineare Drift `drift` Hz/s, Sollfrequenz in der Mitte der Aussendung.
                let mid = Double(w.re.count) / 2
                for k in 0..<w.re.count {
                    let t = (Double(k) - mid) / 12_000
                    let phi = Float(Double.pi * drift * t * t)
                    let c = cos(phi), sn = sin(phi)
                    let r = w.re[k], m = w.im[k]
                    w.re[k] = r * c - m * sn
                    w.im[k] = r * sn + m * c
                }
            }
            let amp = Float((pow(10, s.snr / 10) * noiseIn2500).squareRoot())
            let offset = Int(s.start * 12_000)
            for k in 0..<w.re.count where offset + k < x.count && offset + k >= 0 {
                x.re[offset + k] += amp * w.re[k]
                x.im[offset + k] += amp * w.im[k]
            }
        }
        return x
    }
}

@Suite("FT8")
struct FT8Tests {
    private func bitsString(_ b: [UInt8]) -> String { b.map(String.init).joined() }

    // Referenzwerte: unabhängig mit einer wörtlichen Nachbildung von ft8_lib
    // (Packen, CRC, Generatormatrix) berechnet; die Töne für „CQ K1ABC FN42“
    // stimmen mit der Ausgabe von WSJT-X `ft8code` überein.
    static let vectors: [(text: String, bits: String, tones: String)] = [
        ("CQ K1ABC FN42",
         "00000000000000000000000000100000010011011110111100011010100010100001100110001",
         "3140652000000001005476704606021533433140652736011047517007334745455133543140652"),
        ("K1ABC W9XYZ EN37",
         "00001001101111011110001101010000011000010100100111011100000010000101011001001",
         "3140652032247523504061147005134325373140652464557561564770300376175462233140652"),
        ("W9XYZ K1ABC -11",
         "00001100001010010011101110000000010011011110111100011010100111111010101000001",
         "3140652020355725005476704617463024063140652536316515751700077044377507213140652"),
        ("K1ABC W9XYZ R-09",
         "00001001101111011110001101010000011000010100100111011100001111111010101010001",
         "3140652032247523504061147027463527033140652323406130213743267634453040613140652"),
        ("K1ABC W9XYZ RR73",
         "00001001101111011110001101010000011000010100100111011100000111111010010011001",
         "3140652032247523504061147017455422543140652656077704107145041657342273103140652"),
        ("TNX BOB 73 GL",
         "01100011111011011100111011100010101001001010111000000111111101010000000000000",
         "3140652207447147063336401773500017703140652646427306546072440503670130533140652"),
    ]

    @Test("Normvektoren: Nachricht → 77 Bit → Töne")
    func normVectors() throws {
        for v in Self.vectors {
            let bits = try #require(FT8Message.pack(v.text), "\(v.text)")
            #expect(bitsString(bits) == v.bits, "\(v.text)")
            let tones = FT8Codec.tones(message: bits)
            #expect(tones.map(String.init).joined() == v.tones, "\(v.text)")
        }
    }

    @Test("CQ K1ABC FN42: Felder einzeln wie in der Protokollbeschreibung")
    func fieldsOfCQ() throws {
        let bits = try #require(FT8Message.pack("CQ K1ABC FN42"))
        let r = FT8BitReader(bits)
        #expect(r.value(0, 28) == 2)                                   // CQ
        #expect(r.value(29, 28) == 2_063_592 + 4_194_304 + 3_957_069)  // K1ABC
        #expect(r.value(59, 15) == 10_342)                             // FN42
        #expect(r.value(74, 3) == 1)
    }

    @Test("Codewörter erfüllen alle 83 Paritätsprüfungen (Generator- und Prüfmatrix passen)")
    func parityChecks() {
        var rng = FT8Noise(seed: 7)
        for _ in 0..<50 {
            let bits = (0..<77).map { _ in UInt8(rng.uniform() < 0.5 ? 0 : 1) }
            let cw = FT8Codec.encode(FT8Codec.addCRC(bits))
            #expect(cw.count == 174)
            #expect(FT8Codec.parityErrors(cw) == 0)
            #expect(FT8Codec.checkCRC(cw))
        }
    }

    @Test("Entpacken: Standard, CQ DX, /P, Rapporte, Freitext, Telemetrie")
    func unpackRoundTrip() throws {
        let texts = ["CQ K1ABC FN42", "CQ DX DL1ABC JO62", "CQ 145 DL1ABC JO62", "K1ABC W9XYZ EN37", "W9XYZ K1ABC -11",
                     "K1ABC W9XYZ R-09", "K1ABC W9XYZ RRR", "K1ABC W9XYZ RR73", "K1ABC W9XYZ 73",
                     "DL1ABC/P OE3XYZ JN88", "DL1ABC OE3XYZ/R +05", "TNX BOB 73 GL", "QRZ DL1ABC JO62", "DE DL1ABC"]
        for text in texts {
            let bits = try #require(FT8Message.pack(text), "\(text)")
            let msg = try #require(FT8Message.unpack(bits, hashes: FT8CallHashes()), "\(text)")
            #expect(msg.text == text)
        }
        let cq = try #require(FT8Message.unpack(FT8Message.pack("CQ DL1ABC JO62")!, hashes: nil))
        #expect(cq.isCQ && cq.from == "DL1ABC" && cq.grid == "JO62")
        let tele = try #require(FT8Message.telemetryBits(hex: "123456789ABCDEF012"))
        #expect(FT8Message.unpack(tele, hashes: nil)?.text == "123456789ABCDEF012")
        #expect(FT8Message.unpack(tele, hashes: nil)?.kind == .telemetry)
    }

    @Test("Rufzeichen-Hashes: Sonderrufzeichen erscheint nach dem ersten Empfang im Klartext")
    func callHashes() throws {
        let hashes = FT8CallHashes()
        let unknown = try #require(FT8Message.unpack(FT8Message.pack("W9XYZ <PJ4/K1ABC> RR73")!, hashes: hashes))
        #expect(unknown.text == "W9XYZ <...> RR73")
        let cq = try #require(FT8Message.unpack(FT8Message.pack("CQ PJ4/K1ABC")!, hashes: hashes))
        #expect(cq.text == "CQ PJ4/K1ABC")
        #expect(cq.kind == .nonstandard)
        let again = try #require(FT8Message.unpack(FT8Message.pack("W9XYZ <PJ4/K1ABC> RR73")!, hashes: hashes))
        #expect(again.text == "W9XYZ <PJ4/K1ABC> RR73")
        // 22-Bit-Hash in einer Standardnachricht.
        let std = try #require(FT8Message.unpack(FT8Message.pack("PJ4/K1ABC W9XYZ -07")!, hashes: hashes))
        #expect(std.text == "<PJ4/K1ABC> W9XYZ -07")
        #expect(FT8CallHashes.hash("K1ABC", bits: 22)! >> 10 == FT8CallHashes.hash("K1ABC", bits: 12)!)
    }

    @Test("Belief Propagation korrigiert verrauschte weiche Bits, OSD schafft schwerere Fälle")
    func ldpcDecoding() throws {
        let bits = FT8Message.pack("CQ DL1ABC JO62")!
        let cw = FT8Codec.encode(FT8Codec.addCRC(bits))
        var rng = FT8Noise(seed: 3)
        // σ = 0,7: rund 8 % der harten Entscheidungen falsch.
        let llr = cw.map { b -> Float in
            let x = (b == 1 ? 1.0 : -1.0) + 0.7 * rng.gaussian()
            return Float(2 * x / 0.49)
        }
        let hard = zip(llr, cw).filter { ($0 > 0 ? 1 : 0) != $1 }.count
        #expect(hard > 5)
        #expect(FT8Codec.beliefPropagation(llr) == cw)
        #expect(FT8Codec.osd(llr) == cw)
    }

    @Test("Modulator → Dekoder bei −10 dB: Nachricht, Frequenz, Δt und SNR stimmen")
    func decodeSingle() throws {
        let x = FT8TestSignals.slot([("CQ DL1ABC JO62", 1234.0, -10, 0.7)], seed: 11)
        let decoder = FT8Decoder()
        let results = decoder.decode(x, hashes: FT8CallHashes())
        let d = try #require(results.first { $0.message.text == "CQ DL1ABC JO62" })
        #expect(abs(d.frequency - 1234) < 1)
        #expect(abs(d.dt - 0.2) < 0.05)
        #expect(abs(d.snr - -10) < 2.5, "SNR \(d.snr)")
        #expect(results.count == 1)
    }

    @Test("Modulator → Dekoder bei −18 dB SNR (2500 Hz)")
    func decodeWeak() throws {
        let x = FT8TestSignals.slot([("K1ABC W9XYZ EN37", 1500.0, -18, 0.5)], seed: 5)
        let results = FT8Decoder().decode(x, hashes: FT8CallHashes())
        #expect(results.contains { $0.message.text == "K1ABC W9XYZ EN37" })
        #expect(results.allSatisfy { $0.message.text == "K1ABC W9XYZ EN37" }, "Fehldekodierung: \(results.map(\.message.text))")
    }

    /// Anteil dekodierter Zyklen bei Drift `drift` Hz/s (Aufwärmdrift des HackRF ohne TCXO).
    static func driftRate(_ drift: Double, snr: Double, seeds: Range<UInt64>) -> Int {
        seeds.filter { seed in
            let x = FT8TestSignals.slot([("K1ABC W9XYZ EN37", 1000 + Double(seed % 10) * 137, snr, 0.5)], seed: seed, drift: drift)
            return FT8Decoder().decode(x, hashes: FT8CallHashes()).contains { $0.message.text == "K1ABC W9XYZ EN37" }
        }.count
    }

    @Test("Drift: lineare Frequenzdrift (Aufwärmdrift ohne TCXO) wird nachgeführt")
    func drift() {
        // Gemessen 29.10.2026 (8 Zyklen je Wert, −12/−18 dB): vorher 0,5 Hz/s 8/8 bzw. 3/8,
        // 0,8 Hz/s 1/8 bzw. 0/8, ab 1 Hz/s nichts; nachher 0,8 Hz/s 8/8 bzw. 8/8,
        // 1,5 Hz/s 8/8 bzw. 5/8. 40 Rauschzyklen ohne Fehldekodierung.
        #expect(Self.driftRate(0.8, snr: -12, seeds: 100..<104) == 4)
        #expect(Self.driftRate(0.5, snr: -18, seeds: 200..<204) >= 3)
        #expect(Self.driftRate(1.5, snr: -12, seeds: 100..<102) == 2)
        var falseDecodes: [String] = []
        for seed in UInt64(300)..<UInt64(308) {
            falseDecodes += FT8Decoder().decode(FT8TestSignals.slot([], seed: seed), hashes: FT8CallHashes()).map(\.message.text)
        }
        #expect(falseDecodes.isEmpty, "\(falseDecodes)")
    }

    @Test("Reines Rauschen ergibt keine Dekodierung")
    func noiseOnly() {
        for seed in UInt64(20)..<UInt64(23) {
            let x = FT8TestSignals.slot([], seed: seed)
            #expect(FT8Decoder().decode(x, hashes: FT8CallHashes()).isEmpty)
        }
    }

    @Test("Zwei überlappende Signale werden beide dekodiert (Abziehen im zweiten Durchgang)")
    func overlapping() throws {
        // 15 Hz auseinander – die Tonraster überlappen sich weitgehend.
        let x = FT8TestSignals.slot([("CQ DL1ABC JO62", 1000.0, -6, 0.5), ("W9XYZ K1ABC -11", 1015.0, -12, 0.6),
                                     ("K1ABC W9XYZ RR73", 2200.0, -15, 0.4)], seed: 9)
        let results = FT8Decoder().decode(x, hashes: FT8CallHashes())
        let texts = Set(results.map(\.message.text))
        #expect(texts.contains("CQ DL1ABC JO62"))
        #expect(texts.contains("W9XYZ K1ABC -11"))
        #expect(texts.contains("K1ABC W9XYZ RR73"))
        #expect(results.count == 3, "\(texts)")
    }

    @Test("FT8Locator-Locator ↔ Koordinaten")
    func maidenhead() throws {
        let fn42 = try #require(FT8Locator.coordinate("FN42"))
        #expect(abs(fn42.lat - 42.5) < 1e-9 && abs(fn42.lon - -71) < 1e-9)
        let jo62 = try #require(FT8Locator.coordinate("JO62qm"))
        #expect(abs(jo62.lat - 52.52) < 0.05 && abs(jo62.lon - 13.375) < 0.05)
        #expect(FT8Locator.locator(lat: 52.52, lon: 13.40) == "JO62qm")
        #expect(FT8Locator.coordinate("ZZ99") == nil)
    }
}

@Suite("FT8-Empfangsweg")
struct FT8ChainTests {
    /// HackRF-Rohdaten (int8, 2,4 MS/s): FT8 im oberen Seitenband bei +1500 Hz
    /// und ein zweites FT8-Signal im unteren Seitenband (−1500 Hz) – das darf
    /// nicht erscheinen.
    private func hackRFBlocks(offset: Int) -> [Data] {
        let fs = 2_400_000.0
        let usb = FT8Codec.phaseSteps(tones: FT8Codec.tones(message: FT8Message.pack("CQ DL1ABC JO62")!))
        let lsb = FT8Codec.phaseSteps(tones: FT8Codec.tones(message: FT8Message.pack("CQ OE3XYZ JN88")!))
        let start = Int(0.5 * fs)
        let total = Int(14.0 * fs)
        var rng = FT8Noise(seed: 2)
        var bytes = [Int8](repeating: 0, count: 2 * total)
        var p1 = 0.0, p2 = 0.0
        let w1 = 2 * Double.pi * (Double(offset) + 1500) / fs
        let w2 = 2 * Double.pi * (Double(offset) - 1500 - 50) / fs
        for n in 0..<total {
            var i = 6 * rng.gaussian(), q = 6 * rng.gaussian()
            let k = (n - start) / 200
            if n >= start, k < usb.count {
                p1 += w1 + usb[k] / 200
                p2 += w2 + lsb[k] / 200
                i += 30 * cos(p1) + 30 * cos(p2)
                q += 30 * sin(p1) + 30 * sin(p2)
            }
            bytes[2 * n] = Int8(max(-127, min(127, i.rounded())))
            bytes[2 * n + 1] = Int8(max(-127, min(127, q.rounded())))
        }
        let blockBytes = 262_144
        return stride(from: 0, to: bytes.count, by: blockBytes).map { o in
            bytes[o..<min(o + blockBytes, bytes.count)].withUnsafeBytes { Data($0) }
        }
    }

    @Test("HackRF-Rohdaten → SSB-Kanal → Zeitpuffer → FT8-Dekoder, unteres Seitenband unterdrückt")
    func chain() throws {
        let channel = FT8Channelizer(offset: 240_000)
        var buffer = FT8SampleBuffer(maxSeconds: 35)
        let t0 = 1_700_000_000.0   // ganzzahliges Vielfaches von 15 s ⇒ Zyklusbeginn
        var produced = 0.0
        for block in hackRFBlocks(offset: 240_000) {
            let (re, im) = FT8Channelizer.convert(block)
            produced += Double(re.count) / 2_400_000
            buffer.append(channel.process(re: re, im: im), arrival: t0 + produced + 0.03)
        }
        let extracted = try #require(buffer.extract(from: t0, count: FT8Decoder.slotSamples))
        #expect(abs(extracted.dataStart - t0) < 0.1)
        let results = FT8Decoder().decode(extracted.signal, hashes: FT8CallHashes())
        #expect(results.map(\.message.text) == ["CQ DL1ABC JO62"])
        let d = try #require(results.first)
        #expect(abs(d.frequency - 1500) < 1)
        // Verzögerung durch USB-Ankunft (30 ms) und Filter: Δt nahe 0.
        #expect(abs(d.dt) < 0.1, "Δt \(d.dt)")
    }

    @Test("Zeitpuffer verankert neu, wenn Blöcke fehlen")
    func bufferGap() {
        var buffer = FT8SampleBuffer(maxSeconds: 10)
        let chunk = FT8Signal(count: 600)   // 50 ms
        var t = 100.0
        for _ in 0..<40 { t += 0.05; buffer.append(chunk, arrival: t) }
        #expect(abs((buffer.anchor ?? 0) - 100) < 1e-6)
        t += 1.0   // eine Sekunde Daten verloren
        for _ in 0..<5 { t += 0.05; buffer.append(chunk, arrival: t) }
        #expect(abs((buffer.anchor ?? 0) - 101) < 1e-6)
    }

    @Test("Uhrenhinweis aus der Δt-Statistik")
    func clockVerdict() {
        #expect(FT8Model.clockVerdict(median: 0.2, count: 12).ok)
        let late = FT8Model.clockVerdict(median: 1.4, count: 12)
        #expect(!late.ok)
        #expect(late.text.contains("1.4 s vor"))
        #expect(FT8Model.clockVerdict(median: -0.9, count: 8).text.contains("nach"))
    }
}

@Suite("WSPR")
struct WSPRTests {
    static let k1abc = "330020001020131222100323133220200032012322002232110233210221321222033030301210212032132003323032203020201023021112330231212221332000010320132222202332323320031222"

    @Test("Normvektor K1ABC FN42 37: Packen, Faltungscode, Verschachtelung, Sync")
    func normVector() throws {
        #expect(WSPRCodec.packCall("K1ABC") == 259_047_992)
        let data = try #require(WSPRCodec.pack(call: "K1ABC", grid: "FN42", power: 37))
        let symbols = WSPRCodec.channelSymbols(data)
        #expect(symbols.map(String.init).joined() == Self.k1abc)
        #expect(zip(symbols, WSPRCodec.sync).allSatisfy { $0 & 1 == Int($1) })
    }

    @Test("Fano-Dekoder und Entpacken (Typ 1)")
    func fano() throws {
        let data = try #require(WSPRCodec.pack(call: "DL1ABC", grid: "JO62", power: 23))
        let channel = WSPRCodec.channelSymbols(data)
        var rng = FT8Noise(seed: 4)
        // Weiche Symbole mit Rauschen (Datenbit = Symbol >> 1).
        let soft = channel.map { s -> UInt8 in
            let v = (s >> 1 == 1 ? 40.0 : -40.0) + 45 * rng.gaussian()
            return UInt8(max(0, min(255, 128 + v)))
        }
        let decoded = try #require(WSPRCodec.fano(WSPRCodec.deinterleave(soft)))
        #expect(Array(decoded.prefix(7)) == Array(data.prefix(7)))
        let msg = try #require(WSPRCodec.unpack(decoded, hashes: nil))
        #expect(msg.text == "DL1ABC JO62 23")
        #expect(msg.kind == .type1)
    }

    @Test("Typ 2 und Typ 3 mit Hash-Tabelle")
    func types2and3() throws {
        let hashes = WSPRCallHashes()
        let t2 = try #require(WSPRCodec.unpack(WSPRCodec.packType2(call: "PJ4/K1ABC", power: 37)!, hashes: hashes))
        #expect(t2.text == "PJ4/K1ABC 37")
        #expect(t2.kind == .type2)
        let t2b = try #require(WSPRCodec.unpack(WSPRCodec.packType2(call: "DL1ABC/P", power: 30)!, hashes: hashes))
        #expect(t2b.text == "DL1ABC/P 30")
        let t3 = try #require(WSPRCodec.unpack(WSPRCodec.packType3(call: "PJ4/K1ABC", grid6: "FK52UD", power: 37)!, hashes: hashes))
        #expect(t3.text == "<PJ4/K1ABC> FK52UD 37")
        #expect(t3.kind == .type3)
    }

    private func cycle(_ signals: [(call: String, grid: String, power: Int, freq: Double, snr: Double, start: Double)],
                       seed: UInt64) -> FT8Signal {
        let n = 114 * 12_000
        var x = FT8Signal(count: n)
        var rng = FT8Noise(seed: seed)
        for i in 0..<n { x.re[i] = Float(rng.gaussian()); x.im[i] = Float(rng.gaussian()) }
        let noiseIn2500 = 2.0 * 2500 / 12_000
        for s in signals {
            let symbols = WSPRCodec.channelSymbols(WSPRCodec.pack(call: s.call, grid: s.grid, power: s.power)!)
            let w = WSPRCodec.waveform(symbols: symbols, frequency: s.freq)
            let amp = Float((pow(10, s.snr / 10) * noiseIn2500).squareRoot())
            let offset = Int(s.start * 12_000)
            for k in 0..<w.re.count where offset + k < n {
                x.re[offset + k] += amp * w.re[k]
                x.im[offset + k] += amp * w.im[k]
            }
        }
        return x
    }

    @Test("Modulator → Dekoder bei −24 dB: zwei Stationen im selben Zyklus")
    func decodeCycle() throws {
        let x = cycle([("K1ABC", "FN42", 37, 1480.0, -24, 1.0), ("DL1ABC", "JO62", 23, 1561.3, -20, 1.5)], seed: 8)
        let results = WSPRDecoder().decode(x, centers: [1500], hashes: WSPRCallHashes())
        let k = try #require(results.first { $0.message.text == "K1ABC FN42 37" })
        #expect(abs(k.frequency - 1480) < 1)
        #expect(abs(k.dt - 0) < 0.3)
        let d = try #require(results.first { $0.message.text == "DL1ABC JO62 23" })
        #expect(abs(d.frequency - 1561.3) < 1)
        #expect(abs(d.dt - 0.5) < 0.3)
        #expect(results.count == 2, "\(results.map(\.message.text))")
    }

    @Test("Signal außerhalb ±150 Hz wird über ein weiteres Teilband gefunden")
    func subBands() throws {
        let x = cycle([("K1ABC", "FN42", 37, 1820.0, -20, 1.0)], seed: 12)
        #expect(WSPRDecoder().decode(x, centers: [1500], hashes: WSPRCallHashes()).isEmpty)
        let results = WSPRDecoder().decode(x, centers: [1500, 1800], hashes: WSPRCallHashes())
        #expect(results.map(\.message.text) == ["K1ABC FN42 37"])
    }
}
