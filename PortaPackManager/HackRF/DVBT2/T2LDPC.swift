import Foundation

/// Prüfmatrix eines DVB-T2-LDPC-Codes, aufgebaut aus den Akkumulator-Tabellen
/// (6.1.2): Infobit m der Gruppe g (j = m mod 360) wirkt auf die Prüfungen
/// (x + j·Q) mod (N−K); Paritätsbit i auf Prüfung i und i+1 (Akkumulator).
final class T2LDPCCode: @unchecked Sendable {
    let fec: T2FEC
    let n: Int
    let k: Int
    let m: Int
    /// Variablen je Prüfung (CSR): `variables[offsets[c]..<offsets[c+1]]`.
    let offsets: [Int32]
    let variables: [Int32]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [T2FEC: T2LDPCCode] = [:]

    static func code(_ fec: T2FEC) -> T2LDPCCode {
        lock.withLock {
            if let code = cache[fec] { return code }
            let code = T2LDPCCode(fec)
            cache[fec] = code
            return code
        }
    }

    private init(_ fec: T2FEC) {
        self.fec = fec
        n = fec.nldpc
        k = fec.kldpc
        m = n - k
        let q = fec.q
        let table = T2Tables.ldpcTable(normal: fec.normal, rate: fec.rate)
        var perCheck = [[Int32]](repeating: [], count: m)
        var position = 0
        var group = 0
        while position < table.count {
            let count = Int(table[position])
            let addresses = table[(position + 1)...(position + count)].map(Int.init)
            for j in 0..<360 {
                let bit = Int32(group * 360 + j)
                for x in addresses { perCheck[(x + j * q) % m].append(bit) }
            }
            position += count + 1
            group += 1
        }
        for i in 0..<m {
            if i > 0 { perCheck[i].append(Int32(k + i - 1)) }
            perCheck[i].append(Int32(k + i))
        }
        var offsets = [Int32](repeating: 0, count: m + 1)
        var variables = [Int32]()
        variables.reserveCapacity(perCheck.reduce(0) { $0 + $1.count })
        for (i, list) in perCheck.enumerated() {
            variables.append(contentsOf: list)
            offsets[i + 1] = Int32(variables.count)
        }
        self.offsets = offsets
        self.variables = variables
    }

    var edges: Int { variables.count }

    /// Gilt das Syndrom (alle Prüfungen erfüllt)?
    func check(_ bits: UnsafePointer<UInt8>) -> Bool {
        offsets.withUnsafeBufferPointer { off in
            variables.withUnsafeBufferPointer { vars in
                for c in 0..<m {
                    var parity: UInt8 = 0
                    for e in Int(off[c])..<Int(off[c + 1]) { parity ^= bits[Int(vars[e])] }
                    if parity != 0 { return false }
                }
                return true
            }
        }
    }
}

// MARK: - Daten: geschichtetes Sum-Product (stückweise linear), acht Kodewörter parallel

/// Dekodiert bis zu acht Kodewörter gleichzeitig (eine NEON-Spur je Wort,
/// Kern in `T2LDPCKernel.c`). LLR-Konvention: positiv = Bit 0.
final class T2LDPCBatchDecoder {
    let code: T2LDPCCode
    private var totals: [Int16]
    private var messages: [Int16]
    private let maxDegree: Int
    /// Höchstbetrag von Kanal-LLR und Prüfnachrichten (int16-Stufen), so dass
    /// keine A-posteriori-Summe sättigt.
    let limit: Int16
    /// Iterationen des letzten Laufs.
    private(set) var iterations = 0

    init(code: T2LDPCCode) {
        self.code = code
        totals = [Int16](repeating: 0, count: code.n * 8)
        messages = [Int16](repeating: 0, count: code.edges * 8)
        var maxDegree = 0
        for c in 0..<code.m { maxDegree = max(maxDegree, Int(code.offsets[c + 1] - code.offsets[c])) }
        self.maxDegree = maxDegree
        var variableDegree = [Int](repeating: 0, count: code.n)
        for v in code.variables { variableDegree[Int(v)] += 1 }
        let dv = variableDegree.max() ?? 1
        limit = Int16(min(2000, 32_000 / (dv + 1)))
    }

    /// Quantisierung: Stufen je LLR-Einheit. Die Kanal-LLR müssen kalibriert
    /// sein (echte Log-Likelihood-Verhältnisse) – die Korrektur des Sum-Product
    /// rechnet in absoluten LLR-Einheiten.
    static let scale: Float = 16

    /// `llr[w]`: Kanal-LLR von Kodewort w (Länge n), positiv = Bit 0.
    /// Ergebnis: harte Bits je Wort und ob alle Prüfungen erfüllt sind.
    func decode(_ llr: [[Float]], maxIterations: Int = 50) -> [(bits: [UInt8], ok: Bool)] {
        let words = llr.count
        precondition(words <= 8)
        let n = code.n
        let limit = Float(self.limit)    // 2000 = 125 LLR-Einheiten
        let scale = Self.scale
        totals.withUnsafeMutableBufferPointer { t in
            for i in 0..<t.count { t[i] = 0 }
            for w in 0..<words {
                llr[w].withUnsafeBufferPointer { l in
                    for v in 0..<n { t[8 * v + w] = Int16(max(-limit, min(limit, (l[v] * scale).rounded()))) }
                }
            }
        }
        messages.withUnsafeMutableBufferPointer { m in
            for i in 0..<m.count { m[i] = 0 }
        }
        var done = [UInt8](repeating: 0, count: 8)
        for w in words..<8 { done[w] = 1 }
        iterations = Int(totals.withUnsafeMutableBufferPointer { t in
            messages.withUnsafeMutableBufferPointer { m in
                code.offsets.withUnsafeBufferPointer { off in
                    code.variables.withUnsafeBufferPointer { vars in
                        done.withUnsafeMutableBufferPointer { d in
                            t2_ldpc_decode8(t.baseAddress!, m.baseAddress!, off.baseAddress!, vars.baseAddress!,
                                            Int32(code.m), Int32(maxDegree), Int32(maxIterations),
                                            Int16((0.625 * scale).rounded()), self.limit, d.baseAddress!)
                        }
                    }
                }
            }
        })
        return (0..<words).map { w in
            var bits = [UInt8](repeating: 0, count: n)
            for v in 0..<n where totals[8 * v + w] < 0 { bits[v] = 1 }
            return (bits, done[w] == 1)
        }
    }
}

// MARK: - L1: Sum-Product (stark punktierte, verkürzte Codes)

enum T2LDPCSumProduct {
    /// Fließkomma-Sum-Product mit Abbruch bei erfülltem Syndrom.
    static func decode(_ llr: [Float], code: T2LDPCCode, maxIterations: Int = 100) -> (bits: [UInt8], ok: Bool) {
        let n = code.n
        let edges = code.edges
        var messages = [Float](repeating: 0, count: edges)
        var totals = llr
        var bits = [UInt8](repeating: 0, count: n)
        var t = [Float](repeating: 0, count: 64)
        for _ in 0..<maxIterations {
            for v in 0..<n { bits[v] = totals[v] < 0 ? 1 : 0 }
            if bits.withUnsafeBufferPointer({ code.check($0.baseAddress!) }) { return (bits, true) }
            var next = llr
            for c in 0..<code.m {
                let start = Int(code.offsets[c]), end = Int(code.offsets[c + 1])
                if end - start > t.count { t = [Float](repeating: 0, count: end - start) }
                var logSum: Float = 0
                var negatives = 0
                var zero = -1
                for e in start..<end {
                    let x = max(-30, min(30, totals[Int(code.variables[e])] - messages[e]))
                    let value = tanhf(x / 2)
                    t[e - start] = value
                    let magnitude = abs(value)
                    if magnitude < 1e-12 { zero = zero < 0 ? e : -2; continue }
                    logSum += logf(magnitude)
                    if value < 0 { negatives += 1 }
                }
                for e in start..<end {
                    let value = t[e - start]
                    var product: Float
                    if zero == -2 { product = 0 }
                    else if zero >= 0 { product = e == zero ? expf(logSum) : 0 }
                    else { product = expf(logSum - logf(abs(value))) }
                    var neg = negatives
                    if value < 0 && abs(value) >= 1e-12 { neg -= 1 }
                    if neg & 1 == 1 { product = -product }
                    product = max(-0.999_999, min(0.999_999, product))
                    let out = 2 * atanhf(product)
                    messages[e] = out
                    next[Int(code.variables[e])] += out
                }
            }
            totals = next
        }
        for v in 0..<n { bits[v] = totals[v] < 0 ? 1 : 0 }
        return (bits, bits.withUnsafeBufferPointer { code.check($0.baseAddress!) })
    }
}
