import Foundation

/// 77-Bit-Nachrichten von FT8 (WSJT-X 2.x, „77-bit“-Format): Packen und Entpacken.
///
/// Aufbau (Bit 0 zuerst, MSB-first): die letzten drei Bits sind `i3`, bei
/// `i3 = 0` davor drei Bits `n3`.
/// - `i3 = 1/2`: Standardnachricht `c28 r1 c28 r1 R1 g15` – zwei Rufzeichen
///   (oder CQ/DE/QRZ), Locator, Rapport oder RRR/RR73/73; r1 = „/R“ bzw. „/P“
/// - `i3 = 4`: Nicht-Standard-Rufzeichen `h12 c58 h1 r2 c1`
/// - `i3 = 5`: EU-VHF-Contest `h12 h22 R1 r3 s11 g25`
/// - `i3 = 0, n3 = 0`: freier Text (13 Zeichen aus 42), `n3 = 1`: DXpedition,
///   `n3 = 5`: Telemetrie (71 Bit hexadezimal)
/// - `i3 = 0, n3 = 3/4` (ARRL Field Day) und `i3 = 3` (RTTY Roundup) brauchen
///   US-Sektionstabellen – nur die Rufzeichen werden entpackt.
struct FT8Message: Sendable, Equatable {
    enum Kind: String, Sendable {
        case standard = "Standard"
        case nonstandard = "Sonderrufzeichen"
        case freeText = "Freitext"
        case telemetry = "Telemetrie"
        case dxpedition = "DXpedition"
        case euVHF = "EU-VHF-Contest"
        case fieldDay = "ARRL Field Day"
        case rttyRoundup = "RTTY Roundup"
    }

    var kind: Kind
    var text: String
    /// Angerufene Station (oder „CQ …“, „QRZ“, „DE“).
    var to: String?
    /// Sendende Station.
    var from: String?
    /// Locator der sendenden Station (4- oder 6-stellig), falls enthalten.
    var grid: String?
    /// Rapport („-12“, „R+05“, „RR73“ …) oder Zusatz.
    var report: String?

    var isCQ: Bool { to?.hasPrefix("CQ") ?? false }

    static let ntokens: UInt32 = 2_063_592
    static let max22: UInt32 = 4_194_304
    static let maxGrid4: UInt32 = 32_400

    // MARK: - Zeichentabellen

    static let full = Array(" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?")
    static let alnumSpace = Array(" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let alnum = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let numeric = Array("0123456789")
    static let lettersSpace = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let alnumSpaceSlash = Array(" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ/")

    // MARK: - Entpacken

    /// 77 Bits (0/1) → Nachricht. `nil` bei unbekanntem Typ oder unplausiblem Inhalt.
    static func unpack(_ bits: [UInt8], hashes: FT8CallHashes?) -> FT8Message? {
        guard bits.count >= 77 else { return nil }
        let r = FT8BitReader(bits)
        let i3 = r.value(74, 3)
        switch i3 {
        case 1, 2:
            return unpackStandard(r, i3: i3, hashes: hashes)
        case 4:
            return unpackNonstandard(r, hashes: hashes)
        case 5:
            return unpackEUVHF(r, hashes: hashes)
        case 3:
            // RTTY Roundup: t1 c28 c28 R1 r3 s13 – nur die Rufzeichen.
            guard let a = unpack28(UInt32(r.value(1, 28)), ip: 0, i3: 3, hashes: hashes),
                  let b = unpack28(UInt32(r.value(29, 28)), ip: 0, i3: 3, hashes: hashes) else { return nil }
            return FT8Message(kind: .rttyRoundup, text: "\(a) \(b) (RTTY Roundup)", to: a, from: b)
        case 0:
            let n3 = r.value(71, 3)
            switch n3 {
            case 0:
                let text = unpackFreeText(bits)
                guard !text.isEmpty else { return nil }
                return FT8Message(kind: .freeText, text: text)
            case 1:
                return unpackDXpedition(r, hashes: hashes)
            case 3, 4:
                guard let a = unpack28(UInt32(r.value(0, 28)), ip: 0, i3: 0, hashes: hashes),
                      let b = unpack28(UInt32(r.value(28, 28)), ip: 0, i3: 0, hashes: hashes) else { return nil }
                let transmitters = r.value(57, 4) + 1 + (n3 == 4 ? 16 : 0)
                let cls = Character(UnicodeScalar(UInt8(65 + r.value(61, 3))))
                return FT8Message(kind: .fieldDay, text: "\(a) \(b) \(r.value(56, 1) == 1 ? "R " : "")\(transmitters)\(cls) (Field Day)",
                                  to: a, from: b)
            case 5:
                var hex = ""
                // Rechtsbündig als 18 Hex-Ziffern (72 Bit, erstes Bit 0), führende Nullen weg.
                var padded: [UInt8] = [0]
                padded.append(contentsOf: bits[0..<71])
                for i in stride(from: 0, to: 72, by: 4) {
                    let v = Int(padded[i]) << 3 | Int(padded[i + 1]) << 2 | Int(padded[i + 2]) << 1 | Int(padded[i + 3])
                    hex.append(String(v, radix: 16, uppercase: true))
                }
                while hex.count > 1, hex.hasPrefix("0") { hex.removeFirst() }
                return FT8Message(kind: .telemetry, text: hex)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func unpackStandard(_ r: FT8BitReader, i3: Int, hashes: FT8CallHashes?) -> FT8Message? {
        let n28a = UInt32(r.value(0, 28)), ipa = r.value(28, 1)
        let n28b = UInt32(r.value(29, 28)), ipb = r.value(57, 1)
        let ir = r.value(58, 1)
        let igrid = UInt32(r.value(59, 15))
        guard let a = unpack28(n28a, ip: ipa, i3: i3, hashes: hashes),
              let b = unpack28(n28b, ip: ipb, i3: i3, hashes: hashes) else { return nil }
        // Ein Rufzeichen an zweiter Stelle muss eines sein – kein CQ/DE/QRZ.
        guard n28b >= ntokens else { return nil }
        var grid: String?
        var extra = ""
        if igrid <= maxGrid4 {
            var n = Int(igrid)
            let d4 = n % 10; n /= 10
            let d3 = n % 10; n /= 10
            let l2 = n % 18; n /= 18
            let l1 = n % 18
            let g = String([Character(UnicodeScalar(UInt8(65 + l1))), Character(UnicodeScalar(UInt8(65 + l2))),
                            Character(String(d3)), Character(String(d4))])
            // „RR73“ ist als Locator RR73 kodierbar, gemeint ist aber das Kürzel.
            if g == "RR73" { extra = "RR73" } else {
                grid = g
                extra = (ir == 1 ? "R " : "") + g
            }
        } else {
            let irpt = Int(igrid - maxGrid4)
            switch irpt {
            case 1: extra = ""
            case 2: extra = "RRR"
            case 3: extra = "RR73"
            case 4: extra = "73"
            default:
                var dd = irpt - 35
                // Rapporte −50 … +49 dB; Werte außerhalb sind Fehlkodierungen.
                guard (-50...49).contains(dd) else { return nil }
                let sign = dd >= 0 ? "+" : "-"
                dd = abs(dd)
                extra = (ir == 1 ? "R" : "") + sign + String(format: "%02d", dd)
            }
        }
        let text = [a, b, extra].filter { !$0.isEmpty }.joined(separator: " ")
        return FT8Message(kind: .standard, text: text, to: a, from: b, grid: grid, report: grid == nil && !extra.isEmpty ? extra : nil)
    }

    private static func unpackNonstandard(_ r: FT8BitReader, hashes: FT8CallHashes?) -> FT8Message? {
        let n12 = UInt32(r.value(0, 12))
        var n58 = UInt64(0)
        for i in 0..<58 { n58 = n58 << 1 | UInt64(r.bits[12 + i]) }
        let iflip = r.value(70, 1)
        let nrpt = r.value(71, 2)
        let icq = r.value(73, 1)
        var c11 = [Character](repeating: " ", count: 11)
        var n = n58
        for i in stride(from: 10, through: 0, by: -1) {
            c11[i] = alnumSpaceSlash[Int(n % 38)]
            n /= 38
        }
        let decoded = String(c11).trimmingCharacters(in: .whitespaces)
        guard decoded.count >= 3 else { return nil }
        hashes?.save(decoded)
        let hashed = hashes?.lookup12(n12).map { "<\($0)>" } ?? "<...>"
        let call1 = iflip == 1 ? decoded : hashed
        let call2 = iflip == 1 ? hashed : decoded
        if icq == 1 {
            return FT8Message(kind: .nonstandard, text: "CQ \(call2)", to: "CQ", from: call2)
        }
        let extra = ["", "RRR", "RR73", "73"][nrpt]
        let text = [call1, call2, extra].filter { !$0.isEmpty }.joined(separator: " ")
        return FT8Message(kind: .nonstandard, text: text, to: call1, from: call2, report: extra.isEmpty ? nil : extra)
    }

    private static func unpackDXpedition(_ r: FT8BitReader, hashes: FT8CallHashes?) -> FT8Message? {
        // c28 c28 h10 r5: "K1ABC RR73; W9XYZ <KH1/KH7Z> -08"
        guard let a = unpack28(UInt32(r.value(0, 28)), ip: 0, i3: 0, hashes: hashes),
              let b = unpack28(UInt32(r.value(28, 28)), ip: 0, i3: 0, hashes: hashes) else { return nil }
        let n10 = UInt32(r.value(56, 10))
        let n5 = r.value(66, 5)
        let report = 2 * n5 - 30
        let dx = hashes?.lookup10(n10).map { "<\($0)>" } ?? "<...>"
        let rpt = (report >= 0 ? "+" : "-") + String(format: "%02d", abs(report))
        return FT8Message(kind: .dxpedition, text: "\(a) RR73; \(b) \(dx) \(rpt)", to: b, from: dx, report: rpt)
    }

    private static func unpackEUVHF(_ r: FT8BitReader, hashes: FT8CallHashes?) -> FT8Message? {
        // h12 h22 R1 r3 s11 g25: "<PA3XYZ> <G4ABC/P> R 590003 IO91NP"
        let n12 = UInt32(r.value(0, 12))
        let n22 = UInt32(r.value(12, 22))
        let ir = r.value(34, 1)
        let irpt = r.value(35, 3)
        let serial = r.value(38, 11)
        var n = r.value(49, 25)
        let span = 18 * 10 * 10 * 24 * 24
        guard n < 18 * span else { return nil }
        let j1 = n / span; n -= j1 * span
        let j2 = n / (10 * 10 * 24 * 24); n -= j2 * (10 * 10 * 24 * 24)
        let j3 = n / (10 * 24 * 24); n -= j3 * (10 * 24 * 24)
        let j4 = n / (24 * 24); n -= j4 * (24 * 24)
        let j5 = n / 24
        let j6 = n % 24
        let grid6 = String([Character(UnicodeScalar(UInt8(65 + j1))), Character(UnicodeScalar(UInt8(65 + j2))),
                            Character(String(j3)), Character(String(j4)),
                            Character(UnicodeScalar(UInt8(65 + j5))), Character(UnicodeScalar(UInt8(65 + j6)))])
        let a = hashes?.lookup12(n12).map { "<\($0)>" } ?? "<...>"
        let b = hashes?.lookup22(n22).map { "<\($0)>" } ?? "<...>"
        let rst = "\(52 + irpt)" + String(format: "%04d", serial)
        let text = "\(a) \(b) \(ir == 1 ? "R " : "")\(rst) \(grid6)"
        return FT8Message(kind: .euVHF, text: text, to: a, from: b, grid: grid6, report: rst)
    }

    static func unpackFreeText(_ bits: [UInt8]) -> String {
        // 71 Bit als Zahl zur Basis 42, 13 Zeichen.
        var limbs = [UInt32](repeating: 0, count: 9)   // 72 Bit, rechtsbündig
        var padded: [UInt8] = [0]
        padded.append(contentsOf: bits[0..<71])
        for i in 0..<9 {
            var v: UInt32 = 0
            for j in 0..<8 { v = v << 1 | UInt32(padded[i * 8 + j]) }
            limbs[i] = v
        }
        var chars = [Character](repeating: " ", count: 13)
        for idx in stride(from: 12, through: 0, by: -1) {
            var rem: UInt32 = 0
            for i in 0..<9 {
                let cur = rem << 8 | limbs[i]
                limbs[i] = cur / 42
                rem = cur % 42
            }
            chars[idx] = full[Int(rem)]
        }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// 28-Bit-Feld → Rufzeichen oder Kürzel; speichert Rufzeichen in der Hash-Tabelle.
    static func unpack28(_ n28: UInt32, ip: Int, i3: Int, hashes: FT8CallHashes?) -> String? {
        if n28 < ntokens {
            if n28 == 0 { return "DE" }
            if n28 == 1 { return "QRZ" }
            if n28 == 2 { return "CQ" }
            if n28 <= 1002 { return "CQ " + String(format: "%03d", n28 - 3) }
            if n28 <= 532_443 {
                var n = n28 - 1003
                var a = [Character](repeating: " ", count: 4)
                for i in stride(from: 3, through: 0, by: -1) {
                    a[i] = lettersSpace[Int(n % 27)]
                    n /= 27
                }
                return "CQ " + String(a).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        let n = n28 - ntokens
        if n < max22 {
            return hashes?.lookup22(n).map { "<\($0)>" } ?? "<...>"
        }
        var m = n - max22
        var c = [Character](repeating: " ", count: 6)
        c[5] = lettersSpace[Int(m % 27)]; m /= 27
        c[4] = lettersSpace[Int(m % 27)]; m /= 27
        c[3] = lettersSpace[Int(m % 27)]; m /= 27
        c[2] = numeric[Int(m % 10)]; m /= 10
        c[1] = alnum[Int(m % 36)]; m /= 36
        guard m < 37 else { return nil }
        c[0] = alnumSpace[Int(m)]
        let raw = String(c)
        var call: String
        if raw.hasPrefix("3D0"), c[3] != " " {
            call = "3DA0" + String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if c[0] == "Q", c[1].isLetter {
            call = "3X" + String(raw.dropFirst(1)).trimmingCharacters(in: .whitespaces)
        } else {
            call = raw.trimmingCharacters(in: .whitespaces)
        }
        // Lücken mitten im Rufzeichen kommen nur bei Fehldekodierungen vor.
        guard call.count >= 3, !call.contains(" ") else { return nil }
        if ip != 0 {
            if i3 == 1 { call += "/R" } else if i3 == 2 { call += "/P" } else { return nil }
        }
        hashes?.save(call)
        return call
    }

    // MARK: - Packen (für Tests und Modulator)

    /// Nachrichtentext → 77 Bits. Unterstützt Standardnachrichten (auch mit
    /// /P, /R, CQ nnn/CQ abcd), Sonderrufzeichen (`CQ PJ4/K1ABC`,
    /// `<W9XYZ> PJ4/K1ABC RR73`), Telemetrie (nur Hex) und freien Text.
    static func pack(_ text: String, hashes: FT8CallHashes? = nil) -> [UInt8]? {
        let t = text.uppercased().split(separator: " ").map(String.init)
        guard !t.isEmpty else { return nil }
        if let bits = packStandard(t, hashes: hashes) { return bits }
        if let bits = packNonstandard(t, hashes: hashes) { return bits }
        return packFreeText(text.uppercased())
    }

    private static func packStandard(_ tokens: [String], hashes: FT8CallHashes?) -> [UInt8]? {
        var t = tokens
        // „CQ DX K1ABC FN42“ → erstes Feld „CQ DX“.
        if t.count >= 3, t[0] == "CQ", pack28("CQ " + t[1], hashes: nil) != nil,
           t.count == 4 || packBasecall(t[1]) == nil {
            t = ["CQ " + t[1]] + Array(t[2...])
        }
        guard (2...4).contains(t.count) else { return nil }
        var extra = ""
        var ir = 0
        if t.count == 4 {
            guard t[2] == "R" else { return nil }
            ir = 1
            extra = t[3]
        } else if t.count == 3 {
            extra = t[2]
        }
        guard let (n28a, ipa) = pack28(t[0], hashes: hashes),
              let (n28b, ipb) = pack28(t[1], hashes: hashes) else { return nil }
        // Zweites Rufzeichen muss ein Standardrufzeichen sein.
        guard n28b >= ntokens + max22 else { return nil }
        var igrid: UInt32
        if extra.isEmpty { igrid = maxGrid4 + 1 }
        else if extra == "RRR" { igrid = maxGrid4 + 2 }
        else if extra == "RR73" { igrid = maxGrid4 + 3 }
        else if extra == "73" { igrid = maxGrid4 + 4 }
        else if Self.isGrid4(extra) {
            let c = Array(extra.utf8)
            igrid = (UInt32(c[0] - 65) * 18 + UInt32(c[1] - 65)) * 100 + UInt32(c[2] - 48) * 10 + UInt32(c[3] - 48)
        } else {
            var s = extra
            if s.hasPrefix("R") { ir = 1; s.removeFirst() }
            guard let dd = Int(s), (-50...49).contains(dd) else { return nil }
            igrid = maxGrid4 + UInt32(35 + dd)
        }
        let i3: UInt64 = (t[0].hasSuffix("/P") || t[1].hasSuffix("/P")) ? 2 : 1
        var w = FT8BitWriter()
        w.put(UInt64(n28a), 28); w.put(UInt64(ipa), 1)
        w.put(UInt64(n28b), 28); w.put(UInt64(ipb), 1)
        w.put(UInt64(ir), 1); w.put(UInt64(igrid), 15); w.put(i3, 3)
        return w.bits
    }

    private static func packNonstandard(_ tokens: [String], hashes: FT8CallHashes?) -> [UInt8]? {
        // CQ <call> | <hashed> <call> [RRR|RR73|73] | <call> <hashed> [...]
        var icq = 0, nrpt = 0, iflip = 0
        var full: String, hashed: String
        if tokens.count == 2, tokens[0] == "CQ" {
            icq = 1
            full = tokens[1]
            hashed = tokens[1]
        } else if tokens.count == 2 || tokens.count == 3 {
            if tokens.count == 3 {
                guard let i = ["RRR", "RR73", "73"].firstIndex(of: tokens[2]) else { return nil }
                nrpt = i + 1
            }
            if tokens[0].hasPrefix("<") {
                hashed = String(tokens[0].dropFirst().dropLast()); full = tokens[1]; iflip = 0
            } else if tokens[1].hasPrefix("<") {
                hashed = String(tokens[1].dropFirst().dropLast()); full = tokens[0]; iflip = 1
            } else if packBasecall(tokens[1]) == nil {
                hashed = tokens[0]; full = tokens[1]; iflip = 0
            } else if packBasecall(tokens[0]) == nil {
                hashed = tokens[1]; full = tokens[0]; iflip = 1
            } else { return nil }
        } else { return nil }
        guard full.count <= 11, let n58 = pack58(full) else { return nil }
        hashes?.save(full)
        let n12 = FT8CallHashes.hash(hashed, bits: 12)
        var w = FT8BitWriter()
        w.put(UInt64(n12 ?? 0), 12)
        w.put(n58, 58)
        w.put(UInt64(iflip), 1); w.put(UInt64(nrpt), 2); w.put(UInt64(icq), 1); w.put(4, 3)
        return w.bits
    }

    static func packFreeText(_ text: String) -> [UInt8]? {
        let chars = Array(text)
        guard chars.count <= 13 else { return nil }
        let padded = [Character](repeating: " ", count: 13 - chars.count) + chars
        var limbs = [UInt32](repeating: 0, count: 9)
        for ch in padded {
            guard let j = full.firstIndex(of: ch) else { return nil }
            // limbs = limbs * 42 + j
            var carry = UInt32(j)
            for i in stride(from: 8, through: 0, by: -1) {
                let v = limbs[i] * 42 + carry
                limbs[i] = v & 0xFF
                carry = v >> 8
            }
        }
        var w = FT8BitWriter()
        // 72 Bit rechtsbündig → die oberen 71 Bit verwenden (erstes Bit ist 0).
        var all: [UInt8] = []
        for limb in limbs { for b in stride(from: 7, through: 0, by: -1) { all.append(UInt8((limb >> UInt32(b)) & 1)) } }
        w.bits = Array(all[1...])
        w.put(0, 3); w.put(0, 3)
        return w.bits
    }

    static func telemetryBits(hex: String) -> [UInt8]? {
        guard hex.count <= 18, let _ = UInt64(hex.suffix(16), radix: 16) else { return nil }
        let padded = String(repeating: "0", count: 18 - hex.count) + hex
        var all: [UInt8] = []
        for ch in padded {
            guard let v = ch.hexDigitValue else { return nil }
            for b in stride(from: 3, through: 0, by: -1) { all.append(UInt8((v >> b) & 1)) }
        }
        guard all[0] == 0 else { return nil }   // nur 71 Bit
        var bits = Array(all[1...])
        bits += [1, 0, 1, 0, 0, 0]   // n3 = 5, i3 = 0
        return bits
    }

    static func isGrid4(_ s: String) -> Bool {
        let c = Array(s.utf8)
        return c.count == 4 && (65...82).contains(c[0]) && (65...82).contains(c[1])
            && (48...57).contains(c[2]) && (48...57).contains(c[3])
    }

    static func packBasecall(_ call: String) -> UInt32? {
        let c = Array(call)
        let n = c.count
        guard n > 2 else { return nil }
        var c6 = [Character](repeating: " ", count: 6)
        if call.hasPrefix("3DA0"), n > 4, n <= 7 {
            c6[0] = "3"; c6[1] = "D"; c6[2] = "0"
            for i in 4..<n { c6[i - 1] = c[i] }
        } else if call.hasPrefix("3X"), c[2].isLetter, n <= 7 {
            c6[0] = "Q"
            for i in 2..<n { c6[i - 1] = c[i] }
        } else if c[2].isNumber, n <= 6 {
            for i in 0..<n { c6[i] = c[i] }
        } else if c[1].isNumber, n <= 5 {
            for i in 0..<n { c6[i + 1] = c[i] }
        } else {
            return nil
        }
        guard let i0 = alnumSpace.firstIndex(of: c6[0]), let i1 = alnum.firstIndex(of: c6[1]),
              let i2 = numeric.firstIndex(of: c6[2]), let i3 = lettersSpace.firstIndex(of: c6[3]),
              let i4 = lettersSpace.firstIndex(of: c6[4]), let i5 = lettersSpace.firstIndex(of: c6[5]) else { return nil }
        var v = UInt32(i0)
        v = v * 36 + UInt32(i1)
        v = v * 10 + UInt32(i2)
        v = v * 27 + UInt32(i3)
        v = v * 27 + UInt32(i4)
        v = v * 27 + UInt32(i5)
        return v
    }

    static func pack28(_ call: String, hashes: FT8CallHashes?) -> (UInt32, Int)? {
        if call == "DE" { return (0, 0) }
        if call == "QRZ" { return (1, 0) }
        if call == "CQ" { return (2, 0) }
        if call.hasPrefix("CQ "), call.count < 8 {
            let mod = Array(call.dropFirst(3))
            if mod.count == 3, mod.allSatisfy(\.isNumber), let v = Int(String(mod)) { return (UInt32(3 + v), 0) }
            if mod.count <= 4, mod.allSatisfy({ $0.isLetter && $0.isASCII }) {
                var m: UInt32 = 0
                for ch in mod { m = 27 * m + UInt32(ch.asciiValue! - 64) }
                return (3 + 1000 + m, 0)
            }
            return nil
        }
        var ip = 0
        var base = call
        if call.hasSuffix("/P") || call.hasSuffix("/R") {
            ip = 1
            base = String(call.dropLast(2))
        }
        if let n = packBasecall(base) {
            hashes?.save(call)
            return (ntokens + max22 + n, ip)
        }
        if (3...11).contains(call.count), let n22 = FT8CallHashes.hash(call, bits: 22) {
            hashes?.save(call)
            return (ntokens + n22, 0)
        }
        return nil
    }

    static func pack58(_ call: String) -> UInt64? {
        var n: UInt64 = 0
        for ch in call {
            guard let j = alnumSpaceSlash.firstIndex(of: ch) else { return nil }
            n = n * 38 + UInt64(j)
        }
        return n
    }
}

/// Rufzeichen-Hashes (22, 12, 10 Bit) aus allen bisher gesehenen Rufzeichen.
/// Sonderrufzeichen (z. B. „PJ4/K1ABC“) erscheinen in Folgenachrichten nur
/// als Hash; WSJT-X zeigt sie dann in spitzen Klammern.
final class FT8CallHashes: @unchecked Sendable {
    private let lock = NSLock()
    private var by22: [UInt32: String] = [:]
    private var by12: [UInt32: String] = [:]
    private var by10: [UInt32: String] = [:]
    /// 22-Bit-Hashes in Einfügereihenfolge – die ältesten fallen zuerst heraus.
    private var order: [UInt32] = []
    /// Obergrenze: Rufzeichen kommen frei wählbar aus der Luft, die Tabellen
    /// sollen in langen Sitzungen nicht unbegrenzt wachsen.
    let capacity: Int

    init(capacity: Int = 20_000) { self.capacity = max(1, capacity) }

    var count: Int { lock.withLock { by22.count } }

    /// WSJT-X `ihashcall`: 11 Zeichen zur Basis 38, mal 47055833459 (mod 2⁶⁴), oberste Bits.
    static func hash(_ call: String, bits: Int) -> UInt32? {
        var n: UInt64 = 0
        var count = 0
        for ch in call.prefix(11) {
            guard let j = FT8Message.alnumSpaceSlash.firstIndex(of: ch) else { return nil }
            n = n &* 38 &+ UInt64(j)
            count += 1
        }
        while count < 11 { n = n &* 38; count += 1 }
        let h = (n &* 47_055_833_459) >> UInt64(64 - bits)
        return UInt32(h & ((1 << UInt64(bits)) - 1))
    }

    func save(_ call: String) {
        let call = call.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard call.count >= 3, let h22 = Self.hash(call, bits: 22) else { return }
        lock.withLock {
            if by22.updateValue(call, forKey: h22) == nil { order.append(h22) }
            by12[h22 >> 10] = call
            by10[h22 >> 12] = call
            guard by22.count > capacity else { return }
            // Älteste 10 % auf einmal entfernen (selten, deshalb kein Ringpuffer nötig).
            let drop = max(1, capacity / 10)
            for old in order.prefix(drop) {
                guard let oldCall = by22.removeValue(forKey: old) else { continue }
                if by12[old >> 10] == oldCall { by12[old >> 10] = nil }
                if by10[old >> 12] == oldCall { by10[old >> 12] = nil }
            }
            order.removeFirst(min(drop, order.count))
        }
    }

    func lookup22(_ h: UInt32) -> String? { lock.withLock { by22[h] } }
    func lookup12(_ h: UInt32) -> String? { lock.withLock { by12[h] } }
    func lookup10(_ h: UInt32) -> String? { lock.withLock { by10[h] } }

    func clear() {
        lock.withLock { by22 = [:]; by12 = [:]; by10 = [:]; order = [] }
    }
}

/// Liest Bitfelder (MSB zuerst) aus einem 0/1-Array.
struct FT8BitReader {
    let bits: [UInt8]
    init(_ bits: [UInt8]) { self.bits = bits }
    func value(_ start: Int, _ count: Int) -> Int {
        var v = 0
        for i in start..<(start + count) { v = v << 1 | Int(bits[i]) }
        return v
    }
}

struct FT8BitWriter {
    var bits: [UInt8] = []
    mutating func put(_ value: UInt64, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((value >> UInt64(i)) & 1)) }
    }
}
