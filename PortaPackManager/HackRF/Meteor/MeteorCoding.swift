import Foundation

// Kanalkodierung von METEOR-M LRPT: Faltungscode k=7 r=1/2, Synchronwort
// 0x1ACFFC1D, CCSDS-Verwürfelung, Reed-Solomon (255,223) mit Tiefe 4.
// Nachgeschlagen in SatDump (`module_meteor_lrpt_decoder.cpp`,
// `reedsolomon.cpp`, `viterbi_1_2.cpp`) und meteor_decode (dbdexter).

/// Faltungscode nach CCSDS: Polynome 171/133 oktal (0x79/0x5B mit dem neuen
/// Bit oben; in libfec-Schreibweise 0x4F/0x6D), G1 zuerst, G2 *nicht*
/// invertiert. Weiche Werte: positiv = „0“, negativ = „1“.
enum MeteorConvolutionalCode {
    static let g1 = 0x79
    static let g2 = 0x5B

    /// Ausgabepaar (G1 << 1 | G2) für ein 7-Bit-Register (neues Bit in Bit 6).
    @inline(__always)
    static func symbol(register: Int) -> Int {
        ((register & g1).nonzeroBitCount & 1) << 1 | ((register & g2).nonzeroBitCount & 1)
    }

    /// Kodiert Bits (0/1) zu Codebits (G1, G2, G1, G2, …). `state` sind die
    /// letzten sechs Eingangsbits (neuestes in Bit 5).
    static func encode(_ bits: [UInt8], state: inout Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bits.count * 2)
        for bit in bits {
            let register = Int(bit & 1) << 6 | state
            let symbol = Self.symbol(register: register)
            out.append(UInt8(symbol >> 1))
            out.append(UInt8(symbol & 1))
            state = register >> 1
        }
        return out
    }

    static func encode(_ bits: [UInt8]) -> [UInt8] {
        var state = 0
        return encode(bits, state: &state)
    }
}

/// Viterbi-Dekoder für einen endlosen Strom: Pfadmetriken laufen über
/// Aufrufe hinweg weiter, ausgegeben wird mit `depth` Schritten Verzögerung.
final class MeteorViterbi {
    static let depth = 128

    /// Ausgabesymbol der beiden Vorgänger je Folgezustand (Register = n<<1 | x).
    private static let symbols: [(UInt8, UInt8)] = (0..<64).map { n in
        (UInt8(MeteorConvolutionalCode.symbol(register: n << 1)),
         UInt8(MeteorConvolutionalCode.symbol(register: n << 1 | 1)))
    }

    private var metric = [Int32](repeating: 0, count: 64)
    private var next = [Int32](repeating: 0, count: 64)
    private var decisions: [UInt64] = []
    private var stepsSinceNormalize = 0

    func reset() {
        metric = [Int32](repeating: 0, count: 64)
        decisions.removeAll(keepingCapacity: true)
        stepsSinceNormalize = 0
    }

    /// Verarbeitet weiche Paare (G1, G2) und liefert die bereits sicheren Bits.
    /// `flush` gibt auch die letzten `depth` Bits aus (Blockende).
    func decode(_ soft: UnsafeBufferPointer<Int8>, flush: Bool = false) -> [UInt8] {
        let steps = soft.count / 2
        // Lokale Kopien und rohe Zeiger: Zugriffe auf Klassen-Arrays kosten
        // sonst je Zugriff Exklusivitäts- und Grenzprüfungen (zehnfach langsamer).
        var current = metric
        var following = next
        var fresh = [UInt64](repeating: 0, count: steps)
        var sinceNormalize = stepsSinceNormalize
        Self.symbols.withUnsafeBufferPointer { sym in
            fresh.withUnsafeMutableBufferPointer { out in
                current.withUnsafeMutableBufferPointer { m0Buffer in
                    following.withUnsafeMutableBufferPointer { m1Buffer in
                        var cur = m0Buffer.baseAddress!, nxt = m1Buffer.baseAddress!
                        var branch: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
                        for t in 0..<steps {
                            let a = Int32(soft[2 * t]), b = Int32(soft[2 * t + 1])
                            branch = (a + b, a - b, -a + b, -a - b)    // erwartet 00, 01, 10, 11
                            var word: UInt64 = 0
                            for n in 0..<64 {
                                let p0 = (n << 1) & 63
                                let s = sym[n]
                                let b0: Int32, b1: Int32
                                switch s.0 { case 0: b0 = branch.0; case 1: b0 = branch.1; case 2: b0 = branch.2; default: b0 = branch.3 }
                                switch s.1 { case 0: b1 = branch.0; case 1: b1 = branch.1; case 2: b1 = branch.2; default: b1 = branch.3 }
                                let m0 = cur[p0] &+ b0
                                let m1 = cur[p0 | 1] &+ b1
                                if m1 > m0 {
                                    nxt[n] = m1
                                    word |= 1 << UInt64(n)
                                } else {
                                    nxt[n] = m0
                                }
                            }
                            out[t] = word
                            swap(&cur, &nxt)
                            sinceNormalize += 1
                            if sinceNormalize >= 256 {
                                var top = cur[0]
                                for i in 1..<64 where cur[i] > top { top = cur[i] }
                                for i in 0..<64 { cur[i] -= top }
                                sinceNormalize = 0
                            }
                        }
                        // Ergebnis liegt in `cur`; nach `current` zurückschreiben.
                        if cur != m0Buffer.baseAddress! {
                            for i in 0..<64 { m0Buffer[i] = cur[i] }
                        }
                    }
                }
            }
        }
        metric = current
        next = following
        stepsSinceNormalize = sinceNormalize
        decisions.append(contentsOf: fresh)
        let keep = flush ? 0 : Self.depth
        guard decisions.count > keep else { return [] }
        var best = 0
        for n in 1..<64 where metric[n] > metric[best] { best = n }
        let total = decisions.count
        let emit = total - keep
        var out = [UInt8](repeating: 0, count: emit)
        var state = best
        for t in stride(from: total - 1, through: 0, by: -1) {
            if t < emit { out[t] = UInt8(state >> 5) }
            let x = Int(decisions[t] >> UInt64(state) & 1)
            state = ((state << 1) | x) & 63
        }
        decisions.removeFirst(emit)
        return out
    }

    /// Dekodiert einen Block neu (Metriken bei null) und kodiert das Ergebnis
    /// zurück: Anteil der abweichenden harten Entscheidungen – unter 0,12
    /// heißt „richtige Phase gefunden“.
    static func bitErrorRate(_ soft: [Int8]) -> Double {
        let viterbi = MeteorViterbi()
        let bits = soft.withUnsafeBufferPointer { viterbi.decode($0, flush: true) }
        var state = 0
        let coded = MeteorConvolutionalCode.encode(bits, state: &state)
        // Anfang und Ende sind unsicher (Startzustand, fehlende Zukunft).
        let skip = 40
        guard coded.count > 4 * skip else { return 1 }
        var errors = 0, total = 0
        for i in (2 * skip)..<(coded.count - 2 * skip) where soft[i] != 0 {
            let hard: UInt8 = soft[i] < 0 ? 1 : 0
            if hard != coded[i] { errors += 1 }
            total += 1
        }
        return total > 0 ? Double(errors) / Double(total) : 1
    }
}

/// Mehrdeutigkeiten der (O)QPSK-Demodulation: Phase 0/90°, I/Q vertauscht,
/// Paarbildung um ein Codebit versetzt. 180° und 270° ergeben dieselben
/// Codewörter mit invertierten Daten (beide Polynome haben ungerades
/// Gewicht) – das klärt das Synchronwort bzw. NRZ-M danach.
struct MeteorPhaseHypothesis: Equatable, Sendable {
    var swapIQ: Bool
    var rotate90: Bool
    var shift: Bool

    static let all: [MeteorPhaseHypothesis] = [false, true].flatMap { swap in
        [false, true].flatMap { rot in [false, true].map { MeteorPhaseHypothesis(swapIQ: swap, rotate90: rot, shift: $0) } }
    }

    /// Wendet Tausch und Drehung auf Paare an (wie SatDump `rotate_soft`).
    func apply(_ soft: inout [Int8]) {
        var i = 0
        while i + 1 < soft.count {
            var a = soft[i] == -128 ? -127 : soft[i]
            var b = soft[i + 1] == -128 ? -127 : soft[i + 1]
            if swapIQ { swap(&a, &b) }
            if rotate90 { (a, b) = (b, -a) }
            soft[i] = a
            soft[i + 1] = b
            i += 2
        }
    }
}

/// CCSDS-Pseudozufallsfolge (h(x) = x⁸+x⁷+x⁵+x³+1, Start 0xFF), Periode 255.
enum MeteorRandomizer {
    static let sequence: [UInt8] = {
        var state: UInt8 = 0xFF
        var out = [UInt8](repeating: 0, count: 255)
        for i in 0..<255 {
            var byte: UInt8 = 0
            for _ in 0..<8 {
                let newBit = (state >> 7 ^ state >> 5 ^ state >> 3 ^ state) & 1
                byte = byte << 1 | (state & 1)
                state = state >> 1 | newBit << 7
            }
            out[i] = byte
        }
        return out
    }()

    /// Ver-/Entwürfeln (gleiche Operation) der 1020 Bytes nach dem Synchronwort.
    static func apply(_ data: inout [UInt8]) {
        for i in data.indices { data[i] ^= sequence[i % 255] }
    }
}

/// Reed-Solomon (255,223) nach CCSDS: Feldpolynom 0x187, erste Nullstelle
/// 112, Nullstellenabstand 11 – aber in **konventioneller** Darstellung,
/// ohne Dual-Basis-Umrechnung (SatDump `decode_interlaved(…, false, 4, …)`,
/// meteor_decode ebenso; mit Dual-Basis schlägt jede Prüfung fehl).
/// Byte 0 ist der Koeffizient von x²⁵⁴.
enum MeteorReedSolomon {
    static let n = 255, k = 223, parity = 32
    static let firstRoot = 112, rootSkip = 11

    static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 512)
        var x = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x187 }
        }
        for i in 255..<512 { table[i] = table[i - 255] }
        return table
    }()

    static let log: [Int] = {
        var table = [Int](repeating: 0, count: 256)
        for i in 0..<255 { table[Int(exp[i])] = i }
        return table
    }()

    @inline(__always) static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        (a == 0 || b == 0) ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }

    @inline(__always) static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        (a == 0 || b == 0) ? 0 : exp[(log[Int(a)] - log[Int(b)] + 255) % 255]
    }

    /// α hoch e (e beliebig, auch negativ).
    @inline(__always) static func alpha(_ e: Int) -> UInt8 { exp[((e % 255) + 255) % 255] }

    /// Generatorpolynom, höchster Koeffizient zuerst (33 Werte, g[0] = 1).
    static let generator: [UInt8] = {
        var g: [UInt8] = [1]
        for j in 0..<32 {
            let root = alpha(rootSkip * (firstRoot + j))
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (i, c) in g.enumerated() {
                next[i] ^= c
                next[i + 1] ^= mul(c, root)
            }
            g = next
        }
        return g
    }()

    /// Systematisch: 223 Datenbytes → 255 Bytes (Daten + 32 Parität).
    static func encode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == k)
        var remainder = [UInt8](repeating: 0, count: parity)
        for byte in data {
            let feedback = byte ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            if feedback != 0 {
                for i in 0..<parity { remainder[i] ^= mul(feedback, generator[i + 1]) }
            }
        }
        return data + remainder
    }

    /// Korrigiert ein Codewort an Ort und Stelle. Ergebnis: Zahl der
    /// korrigierten Bytes oder `nil`, wenn nicht korrigierbar.
    static func decode(_ word: inout [UInt8]) -> Int? {
        precondition(word.count == n)
        var syndromes = [UInt8](repeating: 0, count: parity)
        var any = false
        for j in 0..<parity {
            let root = alpha(rootSkip * (firstRoot + j))
            var s: UInt8 = 0
            for byte in word { s = mul(s, root) ^ byte }
            syndromes[j] = s
            if s != 0 { any = true }
        }
        guard any else { return 0 }

        // Berlekamp-Massey: Fehlerortungspolynom Λ (Λ[0] = 1, aufsteigend).
        var lambda = [UInt8](repeating: 0, count: parity + 1)
        var previous = [UInt8](repeating: 0, count: parity + 1)
        lambda[0] = 1; previous[0] = 1
        var degree = 0, shift = 1
        var lastDelta: UInt8 = 1
        for r in 0..<parity {
            var delta = syndromes[r]
            if degree > 0 {
                for i in 1...degree { delta ^= mul(lambda[i], syndromes[r - i]) }
            }
            if delta == 0 {
                shift += 1
                continue
            }
            let factor = div(delta, lastDelta)
            let saved = lambda
            if shift <= parity {
                for i in shift...parity where previous[i - shift] != 0 {
                    lambda[i] ^= mul(factor, previous[i - shift])
                }
            }
            if 2 * degree <= r {
                degree = r + 1 - degree
                previous = saved
                lastDelta = delta
                shift = 1
            } else {
                shift += 1
            }
        }
        guard degree <= parity / 2 else { return nil }

        // Chien-Suche: Byte i ist Grad p = 254 − i, Fehlerort X = β^p mit β = α¹¹.
        var positions: [Int] = []
        var locators: [Int] = []          // log_α von X
        for p in 0..<n {
            let xLog = (rootSkip * p) % 255
            var sum: UInt8 = 0
            for i in 0...degree where lambda[i] != 0 {
                sum ^= mul(lambda[i], alpha(-xLog * i))
            }
            if sum == 0 {
                positions.append(n - 1 - p)
                locators.append(xLog)
            }
        }
        guard positions.count == degree else { return nil }

        // Forney: e = X^(1−b) · Ω(X⁻¹) / Λ'(X⁻¹), Ω = S·Λ mod x^32.
        var omega = [UInt8](repeating: 0, count: parity)
        for i in 0..<parity {
            var v: UInt8 = 0
            for j in 0...min(i, degree) { v ^= mul(lambda[j], syndromes[i - j]) }
            omega[i] = v
        }
        for (index, xLog) in zip(positions, locators) {
            let inverse = -xLog
            var num: UInt8 = 0
            for i in 0..<parity where omega[i] != 0 { num ^= mul(omega[i], alpha(inverse * i)) }
            var den: UInt8 = 0
            // Ableitung in Charakteristik 2: nur ungerade Potenzen.
            var i = 1
            while i <= degree {
                if lambda[i] != 0 { den ^= mul(lambda[i], alpha(inverse * (i - 1))) }
                i += 2
            }
            guard den != 0 else { return nil }
            let magnitude = mul(div(num, den), alpha(xLog * (1 - firstRoot)))
            word[index] ^= magnitude
        }
        return degree
    }

    /// 1020 verschachtelte Bytes (Tiefe 4): Codewort i = Bytes i, i+4, ….
    /// Ergebnis je Codewort: korrigierte Bytes oder `nil`.
    static func decodeInterleaved(_ block: inout [UInt8]) -> [Int?] {
        precondition(block.count == 4 * n)
        var results: [Int?] = []
        for lane in 0..<4 {
            var word = (0..<n).map { block[$0 * 4 + lane] }
            let result = decode(&word)
            if result != nil {
                for j in 0..<n { block[j * 4 + lane] = word[j] }
            }
            results.append(result)
        }
        return results
    }

    /// Gegenstück für Tests: 892 Datenbytes → 1020 verschachtelte Bytes.
    static func encodeInterleaved(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == 4 * k)
        var block = [UInt8](repeating: 0, count: 4 * n)
        for lane in 0..<4 {
            let word = encode((0..<k).map { data[$0 * 4 + lane] })
            for j in 0..<n { block[j * 4 + lane] = word[j] }
        }
        return block
    }
}

/// Sucht das Synchronwort im Bitstrom und schneidet 1024-Byte-CADUs heraus.
/// Läuft wahlweise auf NRZ-M-dekodierten Bits (METEOR-M2-3/2-4).
final class MeteorDeframer {
    static let syncWord: UInt32 = 0x1ACF_FC1D
    static let frameBytes = 1024

    let differential: Bool
    private var shiftRegister: UInt32 = 0
    private var lastBit: UInt8 = 0
    private var collecting = false
    private var inverted = false
    private var frame: [UInt8] = []
    private var bitIndex = 0
    private var byte: UInt8 = 0
    /// Nach einem Rahmen das nächste Synchronwort an fester Stelle prüfen.
    private var checkingSync = false
    private var syncBits = 0
    private var misses = 0
    private(set) var locked = false

    init(differential: Bool) {
        self.differential = differential
    }

    func reset() {
        shiftRegister = 0
        collecting = false
        checkingSync = false
        locked = false
        misses = 0
    }

    /// Liefert vollständige CADUs (Synchronwort + 1020 Bytes, Bits schon
    /// zurückinvertiert, aber noch verwürfelt).
    func process(_ bits: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for raw in bits {
            var bit = raw & 1
            if differential {
                let decoded = bit ^ lastBit
                lastBit = bit
                bit = decoded
            }
            shiftRegister = shiftRegister << 1 | UInt32(bit)
            if collecting {
                byte = byte << 1 | (bit ^ (inverted ? 1 : 0))
                bitIndex += 1
                if bitIndex & 7 == 0 {
                    frame.append(byte)
                    byte = 0
                    if frame.count == Self.frameBytes {
                        frames.append(frame)
                        collecting = false
                        checkingSync = true
                        syncBits = 0
                    }
                }
            } else if checkingSync {
                syncBits += 1
                if syncBits == 32 {
                    checkingSync = false
                    let target = inverted ? ~Self.syncWord : Self.syncWord
                    if (shiftRegister ^ target).nonzeroBitCount <= 8 {
                        misses = 0
                        startFrame()
                    } else {
                        misses += 1
                        if misses <= 2 {
                            startFrame()      // Schwungrad: Lage beibehalten
                        } else {
                            locked = false
                        }
                    }
                }
            } else {
                if (shiftRegister ^ Self.syncWord).nonzeroBitCount <= 3 {
                    inverted = false
                    misses = 0
                    startFrame()
                } else if (shiftRegister ^ ~Self.syncWord).nonzeroBitCount <= 3 {
                    inverted = true
                    misses = 0
                    startFrame()
                }
            }
        }
        return frames
    }

    private func startFrame() {
        frame = [0x1A, 0xCF, 0xFC, 0x1D]
        frame.reserveCapacity(Self.frameBytes)
        bitIndex = 0
        byte = 0
        collecting = true
        locked = true
    }
}

/// Weiche Symbole → geprüfte VCDUs (892 Bytes). Sucht zuerst die Phase per
/// Viterbi-Probedekodierung (wie SatDump `Viterbi1_2`), dekodiert dann
/// laufend und deframt parallel mit und ohne NRZ-M.
final class MeteorFrameDecoder {
    struct Statistics: Sendable, Equatable {
        var viterbiLocked = false
        var bitErrorRate = 1.0
        var hypothesis: String = "–"
        var framesFound = 0
        var rsCorrectedBytes = 0
        var framesOK = 0
        var framesFailed = 0
        var differential: Bool?
    }

    static let testLength = 2048            // weiche Werte je Probe
    static let lockThreshold = 0.12
    static let loseThreshold = 0.2
    static let checkInterval = 16_384

    private(set) var statistics = Statistics()
    private var pending: [Int8] = []
    /// Letzte Rohwerte (vor Drehung) für die laufende Phasenprüfung.
    private var recent: [Int8] = []
    /// Gewählte Drehung/Vertauschung; die Paarlage ist durch Verwerfen eines
    /// Wertes schon ausgeglichen (`shift` ist hier immer `false`).
    private var hypothesis: MeteorPhaseHypothesis?
    private var dropNext = false
    private let viterbi = MeteorViterbi()
    private let plain = MeteorDeframer(differential: false)
    private let nrzm = MeteorDeframer(differential: true)
    private var sinceCheck = 0
    private var badChecks = 0

    func reset() {
        pending.removeAll()
        recent.removeAll()
        hypothesis = nil
        dropNext = false
        viterbi.reset()
        plain.reset()
        nrzm.reset()
        statistics = Statistics()
    }

    /// Nimmt weiche Werte (I, Q, I, Q …) und gibt geprüfte VCDUs zurück.
    func process(_ soft: [Int8]) -> [[UInt8]] {
        pending.append(contentsOf: soft)
        if dropNext, !pending.isEmpty {
            pending.removeFirst()
            dropNext = false
        }
        var output: [[UInt8]] = []
        if hypothesis == nil {
            while hypothesis == nil, pending.count >= Self.testLength + 2 {
                let probe = Array(pending.prefix(Self.testLength + 2))
                if let (found, _) = bestHypothesis(probe, below: Self.lockThreshold) {
                    adopt(found)
                } else {
                    pending.removeFirst(min(pending.count, 2 * Self.testLength))   // ≈ 28 ms weiter, spart Rechenzeit ohne Signal
                }
            }
            guard hypothesis != nil else { return output }
        }
        let usable = pending.count & ~1
        guard usable >= 2 else { return output }
        let raw = Array(pending[0..<usable])
        pending.removeFirst(usable)
        var chunk = raw
        hypothesis!.apply(&chunk)
        let bits = chunk.withUnsafeBufferPointer { viterbi.decode($0) }
        for frame in plain.process(bits) { if let v = check(frame, differential: false) { output.append(v) } }
        for frame in nrzm.process(bits) { if let v = check(frame, differential: true) { output.append(v) } }

        recent.append(contentsOf: raw)
        if recent.count > Self.testLength + 2 { recent.removeFirst(recent.count - Self.testLength - 2) }
        sinceCheck += raw.count
        if sinceCheck >= Self.checkInterval, recent.count == Self.testLength + 2 {
            sinceCheck = 0
            if recheck() {
                // Umgeschaltet: Rest des alten Pfads ausgeben, dann neu beginnen.
                let tail = [Int8]().withUnsafeBufferPointer { viterbi.decode($0, flush: true) }
                viterbi.reset()
                for frame in plain.process(tail) { if let v = check(frame, differential: false) { output.append(v) } }
                for frame in nrzm.process(tail) { if let v = check(frame, differential: true) { output.append(v) } }
            }
        }
        return output
    }

    /// Laufende Prüfung: Passt die Phase noch? Ein Phasensprung der
    /// Costas-Schleife (90°) macht eine andere Hypothese besser – dann
    /// umschalten. Wichtig: Eine falsche Lage kann bei sauberem Signal noch
    /// ≈ 13 % BER zeigen (gemessen an einer echten Aufnahme), daher immer
    /// gegen alle Hypothesen vergleichen statt nur gegen eine Schwelle.
    /// Ergebnis `true`, wenn auf eine andere Hypothese umgeschaltet wurde.
    private func recheck() -> Bool {
        guard let current = hypothesis else { return false }
        var aligned = Array(recent.prefix(Self.testLength))
        current.apply(&aligned)
        let currentBER = MeteorViterbi.bitErrorRate(aligned)
        statistics.bitErrorRate = currentBER
        if let (better, ber) = bestHypothesis(recent, below: Self.lockThreshold),
           ber < currentBER * 0.5, better != current {
            adopt(better, keepDeframers: true)
            statistics.bitErrorRate = ber
            return true
        }
        if currentBER > Self.loseThreshold {
            badChecks += 1
            if badChecks >= 4 { unlock() }
        } else {
            badChecks = 0
        }
        return false
    }

    /// Beste Hypothese für die Rohwerte (Paare ab Index 0), wenn ihre BER
    /// unter `limit` liegt.
    private func bestHypothesis(_ raw: [Int8], below limit: Double) -> (MeteorPhaseHypothesis, Double)? {
        var best: (MeteorPhaseHypothesis, Double)?
        for candidate in MeteorPhaseHypothesis.all {
            let start = candidate.shift ? 1 : 0
            guard raw.count >= start + Self.testLength else { continue }
            var test = Array(raw[start..<(start + Self.testLength)])
            candidate.apply(&test)
            let ber = MeteorViterbi.bitErrorRate(test)
            if best == nil || ber < best!.1 { best = (candidate, ber) }
        }
        if let best { statistics.bitErrorRate = best.1 }
        guard let best, best.1 < limit else { return nil }
        return best
    }

    /// Übernimmt eine Hypothese. Bei Versatz wird ein Wert verworfen: beim
    /// Einrasten vorn in `pending`, beim Umschalten der nächste ankommende.
    private func adopt(_ found: MeteorPhaseHypothesis, keepDeframers: Bool = false) {
        if found.shift {
            if keepDeframers { dropNext = true } else { pending.removeFirst() }
        }
        var stored = found
        stored.shift = false
        hypothesis = stored
        if !keepDeframers { viterbi.reset() }
        recent.removeAll()
        if !keepDeframers {
            plain.reset()
            nrzm.reset()
        }
        sinceCheck = 0
        badChecks = 0
        statistics.viterbiLocked = true
        statistics.hypothesis = (found.rotate90 ? "90°" : "0°") + (found.swapIQ ? String(localized: ", I/Q getauscht") : "")
    }

    private func unlock() {
        hypothesis = nil
        statistics.viterbiLocked = false
        statistics.hypothesis = "–"
        viterbi.reset()
        plain.reset()
        nrzm.reset()
        recent.removeAll()
        badChecks = 0
    }

    /// Entwürfeln und RS-Prüfung. Ergebnis: 892 Bytes VCDU.
    private func check(_ cadu: [UInt8], differential: Bool) -> [UInt8]? {
        statistics.framesFound += 1
        var block = Array(cadu[4...])
        MeteorRandomizer.apply(&block)
        let results = MeteorReedSolomon.decodeInterleaved(&block)
        guard results.allSatisfy({ $0 != nil }) else {
            // Fehlversuche des jeweils anderen Zweigs (mit/ohne NRZ-M) nicht zählen.
            if statistics.differential == nil || statistics.differential == differential {
                statistics.framesFailed += 1
            }
            return nil
        }
        statistics.framesOK += 1
        statistics.rsCorrectedBytes += results.reduce(0) { $0 + ($1 ?? 0) }
        statistics.differential = differential
        return Array(block[0..<892])
    }
}
