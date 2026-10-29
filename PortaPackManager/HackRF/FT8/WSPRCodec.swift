import Foundation

/// WSPR-Nachricht (Typ 1: Rufzeichen, Locator, Leistung; Typ 2: zusammengesetztes
/// Rufzeichen und Leistung; Typ 3: Hash des Rufzeichens, 6-stelliger Locator).
struct WSPRMessage: Sendable, Equatable {
    enum Kind: String, Sendable { case type1 = "Typ 1", type2 = "Typ 2", type3 = "Typ 3" }
    var kind: Kind
    var callsign: String
    var grid: String?
    var powerDBm: Int
    var text: String {
        [callsign, grid ?? "", String(powerDBm)].filter { !$0.isEmpty }.joined(separator: " ")
    }
    var powerWatts: Double { pow(10, Double(powerDBm - 30) / 10) }
}

/// Kanalkodierung von WSPR: 50 Bit Nutzdaten + 31 Nullbits, Faltungscode
/// K = 32, r = 1/2 (Layland-Lushbaugh, Polynome 0xF2D05351/0xE4613C47),
/// Verschachtelung per Bitumkehr, 4-FSK mit Sync-Vektor (Symbol = 2·Datenbit + Sync).
enum WSPRCodec {
    static let sync: [UInt8] = [
        1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1,
        0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1,
        0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1,
        0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0,
        0, 0,
    ]
    static let poly1: UInt32 = 0xF2D0_5351
    static let poly2: UInt32 = 0xE461_3C47
    static let symbolCount = 162
    /// Symboldauer 8192/12000 s, Tonabstand 12000/8192 Hz.
    static let toneSpacing = 12_000.0 / 8192
    static let symbolSamples12k = 8192

    // MARK: - Packen

    static func callCode(_ ch: Character) -> Int? {
        if let d = ch.wholeNumberValue, ch.isASCII { return d }
        if ch == " " { return 36 }
        if let a = ch.asciiValue, (65...90).contains(a) { return Int(a) - 55 }
        return nil
    }

    static func packCall(_ call: String) -> UInt32? {
        let c = Array(call.uppercased())
        guard (1...6).contains(c.count) else { return nil }
        var c6 = [Character](repeating: " ", count: 6)
        if c.count > 2, c[2].isNumber {
            for i in 0..<c.count { c6[i] = c[i] }
        } else if c.count > 1, c[1].isNumber, c.count <= 5 {
            for i in 0..<c.count { c6[i + 1] = c[i] }
        } else { return nil }
        guard let v0 = callCode(c6[0]), let v1 = callCode(c6[1]), let v2 = callCode(c6[2]), v2 < 10,
              let v3 = callCode(c6[3]), let v4 = callCode(c6[4]), let v5 = callCode(c6[5]),
              v1 < 36, [v3, v4, v5].allSatisfy({ $0 >= 10 }) else { return nil }
        var n = UInt32(v0)
        n = n * 36 + UInt32(v1)
        n = n * 10 + UInt32(v2)
        n = n * 27 + UInt32(v3 - 10)
        n = n * 27 + UInt32(v4 - 10)
        n = n * 27 + UInt32(v5 - 10)
        return n
    }

    /// Typ-1-Nachricht „K1ABC FN42 37“ → 50 Bits (als 11 Bytes inkl. Nullschwanz).
    static func pack(call: String, grid: String, power: Int) -> [UInt8]? {
        guard let n = packCall(call), FT8Message.isGrid4(grid.uppercased()), (0...60).contains(power) else { return nil }
        let g = Array(grid.uppercased().utf8).map { Int($0) }
        let m0 = (179 - 10 * (g[0] - 65) - (g[2] - 48)) * 180 + 10 * (g[1] - 65) + (g[3] - 48)
        let m = UInt32(m0 * 128 + power + 64)
        return packBytes(n: n, m: m)
    }

    /// Typ-2-Nachricht „PJ4/K1ABC 37“ (Präfix 1–3 Zeichen oder Suffix 1–2 Zeichen).
    static func packType2(call: String, power: Int) -> [UInt8]? {
        let p = power + [0, -1, 1, 0, -1, 2, 1, 0, -1, 1][max(0, min(60, power)) % 10]
        let parts = call.uppercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        var n: UInt32, mPrefix: Int, nadd: Int
        if parts[1].count == 1 {
            guard let base = packCall(parts[0]), let ch = parts[1].first else { return nil }
            n = base; nadd = 1
            var v = 38
            if let d = ch.wholeNumberValue { v = d } else if let a = ch.asciiValue, (65...90).contains(a) { v = Int(a) - 65 + 10 }
            mPrefix = 60000 - 32768 + v
        } else if parts[1].count == 2, let d = Int(parts[1]) {
            guard let base = packCall(parts[0]) else { return nil }
            n = base; nadd = 1
            mPrefix = 60000 + 26 + d
        } else {
            guard let base = packCall(parts[1]), (1...3).contains(parts[0].count) else { return nil }
            n = base
            var m = parts[0].count == 1 ? 37 * 36 + 36 : parts[0].count == 2 ? 36 : 0
            for ch in parts[0] {
                var v = 36
                if let d = ch.wholeNumberValue { v = d } else if let a = ch.asciiValue, (65...90).contains(a) { v = Int(a) - 65 + 10 }
                m = 37 * m + v
            }
            nadd = 0
            if m > 32768 { m -= 32768; nadd = 1 }
            mPrefix = m
        }
        let ntype = p + 1 + nadd
        return packBytes(n: n, m: UInt32(128 * mPrefix + ntype + 64))
    }

    /// Typ-3-Nachricht „<PJ4/K1ABC> FK52UD 37“.
    static func packType3(call: String, grid6: String, power: Int) -> [UInt8]? {
        let g = Array(grid6.uppercased())
        guard g.count == 6 else { return nil }
        let p = power + [0, -1, 1, 0, -1, 2, 1, 0, -1, 1][max(0, min(60, power)) % 10]
        let ntype = -(p + 1)
        let ihash = Int(nhash(call.uppercased()))
        let rotated = String(g[1...5]) + String(g[0])
        guard let n = packCall(rotated) else { return nil }
        return packBytes(n: n, m: UInt32(128 * ihash + ntype + 64))
    }

    private static func packBytes(n: UInt32, m: UInt32) -> [UInt8] {
        [UInt8((n >> 20) & 0xFF), UInt8((n >> 12) & 0xFF), UInt8((n >> 4) & 0xFF),
         UInt8(((n & 0x0F) << 4) | ((m >> 18) & 0x0F)), UInt8((m >> 10) & 0xFF), UInt8((m >> 2) & 0xFF),
         UInt8((m & 0x03) << 6), 0, 0, 0, 0]
    }

    // MARK: - Kodieren

    @inline(__always) static func parity(_ x: UInt32) -> UInt8 { UInt8(x.nonzeroBitCount & 1) }

    /// 11 Bytes → 176 Codebits (nur 162 werden gesendet).
    static func convolve(_ data: [UInt8]) -> [UInt8] {
        var state: UInt32 = 0
        var out: [UInt8] = []
        out.reserveCapacity(176)
        for byte in data {
            for i in stride(from: 7, through: 0, by: -1) {
                state = (state << 1) | UInt32((byte >> UInt8(i)) & 1)
                out.append(parity(state & poly1))
                out.append(parity(state & poly2))
            }
        }
        return out
    }

    static func bitReverse8(_ i: Int) -> Int {
        var r = 0
        for b in 0..<8 where (i >> b) & 1 == 1 { r |= 1 << (7 - b) }
        return r
    }

    /// Reihenfolge der Verschachtelung: Codebit p landet auf Kanalposition `order[p]`.
    static let order: [Int] = {
        var o: [Int] = []
        var i = 0
        while o.count < 162 {
            let j = bitReverse8(i)
            if j < 162 { o.append(j) }
            i += 1
        }
        return o
    }()

    static func interleave(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 162)
        for p in 0..<162 { out[order[p]] = bits[p] }
        return out
    }

    static func deinterleave(_ symbols: [UInt8]) -> [UInt8] {
        (0..<162).map { symbols[order[$0]] }
    }

    /// 11 Datenbytes → 162 Kanalsymbole (0…3).
    static func channelSymbols(_ data: [UInt8]) -> [Int] {
        let inter = interleave(Array(convolve(data).prefix(162)))
        return (0..<162).map { 2 * Int(inter[$0]) + Int(sync[$0]) }
    }

    // MARK: - Fano-Dekoder (nach Phil Karn KA9Q, wie in WSJT-X)

    /// Weiche, entschachtelte Symbole (0…255, 128 = unsicher) → 11 Datenbytes.
    static func fano(_ symbols: [UInt8], delta: Int32 = 60, maxCyclesPerBit: Int = 10_000) -> [UInt8]? {
        let nbits = 81
        var metrics = [(Int32, Int32, Int32, Int32)](repeating: (0, 0, 0, 0), count: nbits)
        let m0 = WSPRTables.metric0
        for i in 0..<nbits {
            let a = Int(symbols[2 * i]), b = Int(symbols[2 * i + 1])
            let a0 = m0[a], a1 = m0[255 - a], b0 = m0[b], b1 = m0[255 - b]
            metrics[i] = (a0 + b0, a0 + b1, a1 + b0, a1 + b1)
        }
        func metric(_ i: Int, _ sym: Int) -> Int32 {
            switch sym {
            case 0: return metrics[i].0
            case 1: return metrics[i].1
            case 2: return metrics[i].2
            default: return metrics[i].3
            }
        }
        func encodeSym(_ state: UInt32) -> Int {
            Int(parity(state & poly1)) << 1 | Int(parity(state & poly2))
        }
        var encstate = [UInt32](repeating: 0, count: nbits + 1)
        var gamma = [Int32](repeating: 0, count: nbits + 1)
        var tm = [(Int32, Int32)](repeating: (0, 0), count: nbits)
        var branch = [Int](repeating: 0, count: nbits)
        let tail = nbits - 31

        func prepare(_ np: Int) {
            let lsym = encodeSym(encstate[np])
            if np >= tail {
                tm[np] = (metric(np, lsym), 0)
            } else {
                let a = metric(np, lsym), b = metric(np, 3 ^ lsym)
                if a > b { tm[np] = (a, b) } else { tm[np] = (b, a); encstate[np] += 1 }
            }
            branch[np] = 0
        }

        var np = 0
        encstate[0] = 0
        prepare(0)
        gamma[0] = 0
        var t: Int32 = 0
        let maxCycles = maxCyclesPerBit * nbits
        var done = false
        for _ in 0..<maxCycles {
            let ngamma = gamma[np] + (branch[np] == 0 ? tm[np].0 : tm[np].1)
            if ngamma >= t {
                if gamma[np] < t + delta {
                    while ngamma >= t + delta { t += delta }
                }
                gamma[np + 1] = ngamma
                encstate[np + 1] = encstate[np] << 1
                np += 1
                if np == nbits { done = true; break }
                prepare(np)
                continue
            }
            while true {
                if np == 0 || gamma[np - 1] < t {
                    t -= delta
                    if branch[np] != 0 {
                        branch[np] = 0
                        encstate[np] ^= 1
                    }
                    break
                }
                np -= 1
                if np < tail && branch[np] != 1 {
                    branch[np] += 1
                    encstate[np] ^= 1
                    break
                }
            }
        }
        guard done else { return nil }
        // Datenbytes aus dem Encoderzustand an jeder 8. Stelle.
        var data = [UInt8](repeating: 0, count: 11)
        for i in 0..<10 { data[i] = UInt8(encstate[8 * i + 7] & 0xFF) }
        _ = data[10]
        return data
    }

    // MARK: - Entpacken

    static let callChars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ ")

    static func unpackCall(_ ncall: Int) -> String? {
        guard ncall < 262_177_560 else { return nil }
        var n = ncall
        var tmp = [Character](repeating: " ", count: 6)
        tmp[5] = callChars[n % 27 + 10]; n /= 27
        tmp[4] = callChars[n % 27 + 10]; n /= 27
        tmp[3] = callChars[n % 27 + 10]; n /= 27
        tmp[2] = callChars[n % 10]; n /= 10
        tmp[1] = callChars[n % 36]; n /= 36
        guard n < 37 else { return nil }
        tmp[0] = callChars[n]
        return String(tmp).trimmingCharacters(in: .whitespaces)
    }

    static func unpackGrid(_ ngrid: Int) -> String? {
        let g = ngrid >> 7
        guard g < 32400 else { return nil }
        let dlat = (g % 180) - 90
        var dlong = (g / 180) * 2 - 180 + 2
        if dlong < -180 { dlong += 360 }
        if dlong > 180 { dlong += 360 }
        let nlong = Int(60.0 * (180.0 - Double(dlong)) / 5.0)
        var n1 = nlong / 240
        var n2 = (nlong - 240 * n1) / 24
        let c0 = callChars[10 + n1], c2 = callChars[n2]
        let nlat = Int(60.0 * Double(dlat + 90) / 2.5)
        n1 = nlat / 240
        n2 = (nlat - 240 * n1) / 24
        let c1 = callChars[10 + n1], c3 = callChars[n2]
        return String([c0, c1, c2, c3])
    }

    static func unpackPrefix(_ nprefix: Int, call: String) -> String? {
        if nprefix < 60000 {
            var n = nprefix
            var pfx = [Character](repeating: " ", count: 3)
            for i in stride(from: 2, through: 0, by: -1) {
                let nc = n % 37
                pfx[i] = nc <= 9 ? Character(String(nc)) : nc <= 35 ? callChars[nc] : " "
                n /= 37
            }
            let p = String(pfx).trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            return "\(p)/\(call)"
        }
        let nc = nprefix - 60000
        if (0...9).contains(nc) { return "\(call)/\(nc)" }
        if (10...35).contains(nc) { return "\(call)/\(callChars[nc])" }
        if (36...125).contains(nc) { return "\(call)/\((nc - 26) / 10)\((nc - 26) % 10)" }
        return nil
    }

    /// 11 Datenbytes → Nachricht; aktualisiert die Hash-Tabelle.
    static func unpack(_ data: [UInt8], hashes: WSPRCallHashes?) -> WSPRMessage? {
        let n1 = Int(data[0]) << 20 | Int(data[1]) << 12 | Int(data[2]) << 4 | Int(data[3] >> 4)
        let n2 = Int(data[3] & 0x0F) << 18 | Int(data[4]) << 10 | Int(data[5]) << 2 | Int(data[6] >> 6)
        guard let callsign = unpackCall(n1) else { return nil }
        let ntype = (n2 & 127) - 64
        if (0...62).contains(ntype) {
            let nu = ntype % 10
            if nu == 0 || nu == 3 || nu == 7 {
                guard let grid = unpackGrid(n2), callsign.count >= 3 else { return nil }
                hashes?.save(callsign)
                return WSPRMessage(kind: .type1, callsign: callsign, grid: grid, powerDBm: ntype)
            }
            var nadd = nu
            if nu > 3 { nadd = nu - 3 }
            if nu > 7 { nadd = nu - 7 }
            let n3 = n2 / 128 + 32768 * (nadd - 1)
            guard let full = unpackPrefix(n3, call: callsign) else { return nil }
            let dbm = ntype - nadd
            let nu2 = dbm % 10
            guard nu2 == 0 || nu2 == 3 || nu2 == 7 else { return nil }
            hashes?.save(full)
            return WSPRMessage(kind: .type2, callsign: full, grid: nil, powerDBm: dbm)
        }
        if ntype < 0 {
            guard ntype != -64 else { return nil }
            let dbm = -(ntype + 1)
            // Der 6-stellige Locator steckt rotiert im Rufzeichenfeld.
            var tmp = [Character](repeating: " ", count: 6)
            var n = n1
            tmp[5] = callChars[n % 27 + 10]; n /= 27
            tmp[4] = callChars[n % 27 + 10]; n /= 27
            tmp[3] = callChars[n % 27 + 10]; n /= 27
            tmp[2] = callChars[n % 10]; n /= 10
            tmp[1] = callChars[n % 36]; n /= 36
            guard n < 37 else { return nil }
            tmp[0] = callChars[n]
            let grid6 = String([tmp[5]] + tmp[0..<5])
            let g = Array(grid6)
            let nu = dbm % 10
            guard nu == 0 || nu == 3 || nu == 7, g[0].isLetter, g[1].isLetter, g[2].isNumber, g[3].isNumber,
                  grid6 != "A000AA" else { return nil }
            let ihash = (n2 - ntype - 64) / 128
            let name = hashes?.lookup(UInt32(ihash)).map { "<\($0)>" } ?? "<...>"
            let trimmed = grid6.trimmingCharacters(in: .whitespaces)
            return WSPRMessage(kind: .type3, callsign: name, grid: trimmed, powerDBm: dbm)
        }
        return nil
    }

    // MARK: - Hash (Bob Jenkins lookup3 `hashlittle`, 15 Bit, Startwert 146)

    static func nhash(_ text: String, initval: UInt32 = 146) -> UInt32 {
        let k = Array(text.utf8)
        var length = k.count
        var a = 0xDEAD_BEEF &+ UInt32(length) &+ initval
        var b = a, c = a
        @inline(__always) func rot(_ x: UInt32, _ r: UInt32) -> UInt32 { (x << r) | (x >> (32 - r)) }
        var o = 0
        while length > 12 {
            a &+= UInt32(k[o]) | UInt32(k[o + 1]) << 8 | UInt32(k[o + 2]) << 16 | UInt32(k[o + 3]) << 24
            b &+= UInt32(k[o + 4]) | UInt32(k[o + 5]) << 8 | UInt32(k[o + 6]) << 16 | UInt32(k[o + 7]) << 24
            c &+= UInt32(k[o + 8]) | UInt32(k[o + 9]) << 8 | UInt32(k[o + 10]) << 16 | UInt32(k[o + 11]) << 24
            a &-= c; a ^= rot(c, 4); c &+= b
            b &-= a; b ^= rot(a, 6); a &+= c
            c &-= b; c ^= rot(b, 8); b &+= a
            a &-= c; a ^= rot(c, 16); c &+= b
            b &-= a; b ^= rot(a, 19); a &+= c
            c &-= b; c ^= rot(b, 4); b &+= a
            length -= 12
            o += 12
        }
        if length == 0 { return c & 32767 }
        func byte(_ i: Int) -> UInt32 { i < length ? UInt32(k[o + i]) : 0 }
        c &+= byte(8) | byte(9) << 8 | byte(10) << 16 | byte(11) << 24
        b &+= byte(4) | byte(5) << 8 | byte(6) << 16 | byte(7) << 24
        a &+= byte(0) | byte(1) << 8 | byte(2) << 16 | byte(3) << 24
        c ^= b; c &-= rot(b, 14)
        a ^= c; a &-= rot(c, 11)
        b ^= a; b &-= rot(a, 25)
        c ^= b; c &-= rot(b, 16)
        a ^= c; a &-= rot(c, 4)
        b ^= a; b &-= rot(a, 14)
        c ^= b; c &-= rot(b, 24)
        return c & 32767
    }

    // MARK: - Modulator (für Tests)

    /// Kontinuierliche 4-FSK bei 12 kHz; `frequency` ist die Mitte zwischen
    /// Ton 1 und 2 (wie WSJT-X sie meldet).
    static func waveform(symbols: [Int], frequency: Double, sampleRate: Double = 12_000) -> (re: [Float], im: [Float]) {
        let nsps = Int(sampleRate * 8192 / 12_000)
        var re: [Float] = [], im: [Float] = []
        re.reserveCapacity(symbols.count * nsps)
        im.reserveCapacity(symbols.count * nsps)
        var phi = 0.0
        for s in symbols {
            let f = frequency + (Double(s) - 1.5) * toneSpacing
            let dphi = 2 * Double.pi * f / sampleRate
            for _ in 0..<nsps {
                re.append(Float(cos(phi)))
                im.append(Float(sin(phi)))
                phi = (phi + dphi).truncatingRemainder(dividingBy: 2 * .pi)
            }
        }
        return (re, im)
    }
}

/// 15-Bit-Hashes der WSPR-Rufzeichen (für Typ-3-Nachrichten).
final class WSPRCallHashes: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [UInt32: String] = [:]
    func save(_ call: String) { lock.withLock { table[WSPRCodec.nhash(call)] = call } }
    func lookup(_ h: UInt32) -> String? { lock.withLock { table[h] } }
    func clear() { lock.withLock { table = [:] } }
}
