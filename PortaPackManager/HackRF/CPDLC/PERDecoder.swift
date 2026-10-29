import Foundation

// Schemagesteuerter Dekoder für ASN.1 Unaligned PER (X.691), wie ihn CPDLC,
// CM und die ULCS-Schichten des ATN (ICAO Doc 9880) und FANS-1/A (ARINC 622)
// verwenden. Das Schema liegt als JSON in den Ressourcen (CPDLC-ATN.json,
// CPDLC-FANS.json) und wurde aus den asn1c-Tabellen von dumpvdl2/libacars
// abgeleitet (Typart, Wertebereiche, Felder, Erweiterbarkeit) – der Dekoder
// selbst ist eigenständig geschrieben.

/// Ein Typ des Schemas.
struct ASN1Type: Decodable {
    struct Constraint: Decodable {
        struct Range: Decodable {
            var flags: [String]
            var bits: Int
            var lb: Int
            var ub: Int
            var constrained: Bool { flags.contains("APC_CONSTRAINED") || flags.contains("APC_SEMI_CONSTRAINED") }
            var semi: Bool { flags.contains("APC_SEMI_CONSTRAINED") }
            var extensible: Bool { flags.contains("APC_EXTENSIBLE") }
        }
        var value: Range?
        var size: Range?
    }
    struct Member: Decodable {
        var name: String
        var type: String
        var optional: Bool
        var `default`: Bool
    }
    var kind: String
    var members: [Member]?
    var element: String?
    var constraint: Constraint?
    var values: [[JSONValue]]?
    var alphabet: [Int]?
    var extBefore: Int?
    var extAfter: Int?
    var extStart: Int?
    var target: String?

    /// Namen der ENUMERATED-Werte (Wert → Name).
    var enumNames: [Int: String] {
        var names: [Int: String] = [:]
        for pair in values ?? [] where pair.count == 2 {
            if case .number(let v) = pair[0], case .string(let n) = pair[1] { names[Int(v)] = n }
        }
        return names
    }
}

enum JSONValue: Decodable {
    case number(Double), string(String), other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .other }
    }
}

/// Dekodierter Wert.
indirect enum ASN1Value: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case enumerated(String)
    case string(String)
    case octets([UInt8])
    case bits([UInt8], count: Int)
    case oid([UInt8])
    case open([UInt8])
    case sequence([(String, ASN1Value)])
    case choice(String, ASN1Value)
    case list([ASN1Value])

    static func == (a: ASN1Value, b: ASN1Value) -> Bool { "\(a)" == "\(b)" }

    /// Feld einer SEQUENCE / Alternative einer CHOICE nach Namen.
    subscript(name: String) -> ASN1Value? {
        switch self {
        case .sequence(let members): return members.first { $0.0 == name }?.1
        case .choice(let chosen, let value): return chosen == name ? value : nil
        default: return nil
        }
    }
    var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}

/// Schema aus den Ressourcen; je Familie (ATN, FANS) einmal geladen.
final class ASN1Schema: @unchecked Sendable {
    let types: [String: ASN1Type]
    private init(types: [String: ASN1Type]) { self.types = types }

    nonisolated(unsafe) private static var cache: [String: ASN1Schema] = [:]
    private static let lock = NSLock()

    static func named(_ name: String) -> ASN1Schema? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let url = Bundle(for: ASN1Schema.self).url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let types = try? JSONDecoder().decode([String: ASN1Type].self, from: data) else { return nil }
        let schema = ASN1Schema(types: types)
        cache[name] = schema
        return schema
    }
    static var atn: ASN1Schema? { named("CPDLC-ATN") }
    static var fans: ASN1Schema? { named("CPDLC-FANS") }

    /// Alias-Ketten auflösen.
    func resolve(_ name: String) -> (name: String, type: ASN1Type)? {
        var current = name.replacingOccurrences(of: "-", with: "_")
        for _ in 0..<10 {
            guard let t = types[current] else { return nil }
            if t.kind == "alias", let target = t.target { current = target; continue }
            return (current, t)
        }
        return nil
    }
}

struct PERError: Error, CustomStringConvertible {
    var description: String
}

/// Liest Bits MSB-zuerst.
struct PERBitReader {
    let bytes: [UInt8]
    let bitCount: Int
    var position = 0

    init(bytes: [UInt8], bitCount: Int? = nil) {
        self.bytes = bytes
        self.bitCount = min(bitCount ?? bytes.count * 8, bytes.count * 8)
    }
    var remaining: Int { bitCount - position }

    mutating func bit() throws -> Int {
        guard position < bitCount else { throw PERError(description: "Bits erschöpft") }
        let b = Int(bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return b
    }
    mutating func bits(_ n: Int) throws -> Int {
        guard n >= 0, n <= 62 else { throw PERError(description: "Feld zu breit (\(n) Bit)") }
        var v = 0
        for _ in 0..<n { v = v << 1 | (try bit()) }
        return v
    }
    mutating func bitArray(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining else { throw PERError(description: "Bitfolge zu lang") }
        var out = [UInt8](repeating: 0, count: (n + 7) / 8)
        for i in 0..<n where try bit() == 1 { out[i >> 3] |= 0x80 >> UInt8(i & 7) }
        return out
    }
    mutating func octets(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining / 8 else { throw PERError(description: "Oktette zu lang (\(n))") }
        return try (0..<n).map { _ in UInt8(try bits(8)) }
    }

    /// Längenbestimmung (X.691 10.9): < 128 ein Oktett, < 16384 zwei, sonst Fragmente (nicht unterstützt).
    mutating func lengthDeterminant() throws -> Int {
        if try bit() == 0 { return try bits(7) }
        if try bit() == 0 { return try bits(14) }
        throw PERError(description: "fragmentierte Länge")
    }
    /// „Normally small“ nichtnegative Zahl (10.6). Mehr als 4 Oktette ergeben
    /// keinen sinnvollen Index – sonst liefe `v << 8` über und der Index würde
    /// negativ (Funkrahmen aus der Luft – sonst Absturz).
    mutating func normallySmall() throws -> Int {
        if try bit() == 0 { return try bits(6) }
        let n = try lengthDeterminant()
        guard n <= 4 else { throw PERError(description: "Normally-small mit \(n) Oktetten") }
        var v = 0
        for _ in 0..<n { v = v << 8 | (try bits(8)) }
        return v
    }
    /// „Normally small“ Länge (für Erweiterungs-Bitfelder): 1 … 64 direkt.
    mutating func normallySmallLength() throws -> Int {
        if try bit() == 0 { return try bits(6) + 1 }
        return try lengthDeterminant()
    }
    /// Beschränkte ganze Zahl im Bereich lb…ub mit `bits` Bit.
    mutating func constrained(_ r: ASN1Type.Constraint.Range) throws -> Int {
        if r.ub == r.lb { return r.lb }
        // Ohne Bitzahl aus dem Schema nur bei echtem Bereich rechnen – ub < lb
        // (semi-beschränkt, „1..MAX“) ergäbe log2(≤ 0) = −∞ und Int() stürzte ab.
        guard r.bits > 0 || r.ub > r.lb else { throw PERError(description: "Wertebereich \(r.lb)…\(r.ub)") }
        let bits = r.bits > 0 ? r.bits : max(1, Int((log2(Double(r.ub) - Double(r.lb) + 1)).rounded(.up)))
        let (sum, overflow) = r.lb.addingReportingOverflow(try self.bits(bits))
        guard !overflow else { throw PERError(description: "Ganzzahl übergelaufen") }
        return sum
    }
    /// Unbeschränkte ganze Zahl: Länge in Oktetten, Zweierkomplement.
    mutating func unconstrainedInt() throws -> Int {
        let n = try lengthDeterminant()
        guard n > 0, n <= 8 else { throw PERError(description: "Ganzzahl mit \(n) Oktetten") }
        var v = 0
        for _ in 0..<n { v = v << 8 | (try bits(8)) }
        if v & (1 << (8 * n - 1)) != 0 { v -= 1 << (8 * n) }
        return v
    }
}

/// Der Dekoder: wandert durch das Schema.
struct PERDecoder {
    let schema: ASN1Schema
    /// Tiefe gegen Endlosrekursion bei fehlerhaften Schemata.
    private var depth = 0

    init(schema: ASN1Schema) { self.schema = schema }

    func decode(_ typeName: String, bytes: [UInt8], bitCount: Int? = nil) throws -> ASN1Value {
        var reader = PERBitReader(bytes: bytes, bitCount: bitCount)
        var decoder = self
        return try decoder.decode(typeName, &reader)
    }

    mutating func decode(_ typeName: String, _ r: inout PERBitReader) throws -> ASN1Value {
        guard let (name, type) = schema.resolve(typeName) else { throw PERError(description: "Typ \(typeName) unbekannt") }
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw PERError(description: "zu tief") }
        switch type.kind {
        case "null": return .null
        case "boolean": return .bool(try r.bit() == 1)
        case "integer": return .int(try integer(type, &r))
        case "enumerated": return try enumerated(type, &r)
        case "string": return .string(try string(type, &r))
        case "octets": return .octets(try octets(type, &r))
        case "bits": return try bitString(type, &r)
        case "oid": return .oid(try r.octets(try r.lengthDeterminant()))
        case "any": return .open(try r.octets(try r.lengthDeterminant()))
        case "sequence": return try sequence(type, name, &r)
        case "choice": return try choice(type, name, &r)
        case "sequenceOf": return try sequenceOf(type, &r)
        default: throw PERError(description: "Typart \(type.kind) (\(name))")
        }
    }

    private func integer(_ type: ASN1Type, _ r: inout PERBitReader) throws -> Int {
        guard let v = type.constraint?.value, v.constrained else { return try r.unconstrainedInt() }
        if v.extensible, try r.bit() == 1 { return try r.unconstrainedInt() }
        if v.semi {
            // Oktettzahl und Summe kommen aus der Luft – begrenzen statt überlaufen.
            let n = try r.lengthDeterminant()
            guard n <= 8 else { throw PERError(description: "Ganzzahl mit \(n) Oktetten") }
            var value = 0
            for _ in 0..<n { value = value << 8 | (try r.bits(8)) }
            let (sum, overflow) = v.lb.addingReportingOverflow(value)
            guard !overflow else { throw PERError(description: "Ganzzahl übergelaufen") }
            return sum
        }
        return try r.constrained(v)
    }

    private func enumerated(_ type: ASN1Type, _ r: inout PERBitReader) throws -> ASN1Value {
        let names = type.enumNames
        guard let v = type.constraint?.value else {
            let index = try r.normallySmall()
            return .enumerated(names[index] ?? "#\(index)")
        }
        if v.extensible, try r.bit() == 1 {
            let index = try r.normallySmall()
            return .enumerated("erweitert#\(index)")
        }
        let index = try r.constrained(v)
        return .enumerated(names[index] ?? "#\(index)")
    }

    private func count(_ size: ASN1Type.Constraint.Range?, _ r: inout PERBitReader) throws -> Int {
        // SIZE(n..MAX) ist semi-beschränkt: allgemeine Längenbestimmung (X.691 11.9.4.2).
        guard let size, size.constrained, !size.semi else { return try r.lengthDeterminant() }
        if size.extensible, try r.bit() == 1 { return try r.lengthDeterminant() }
        return try r.constrained(size)
    }

    private func string(_ type: ASN1Type, _ r: inout PERBitReader) throws -> String {
        let n = try count(type.constraint?.size, &r)
        guard n >= 0, n <= 4096 else { throw PERError(description: "Zeichenkette zu lang") }
        let value = type.constraint?.value
        let bits = value.map { $0.bits > 0 ? $0.bits : 8 } ?? 8
        var scalars: [Character] = []
        for _ in 0..<n {
            let code = try r.bits(bits)
            let char: Int
            if let alphabet = type.alphabet, code < alphabet.count { char = alphabet[code] }
            else if let value, value.constrained, value.ub - value.lb + 1 <= (1 << bits) { char = value.lb + code }
            else { char = code }
            scalars.append(Character(Unicode.Scalar(UInt8(clamping: char))))
        }
        return String(scalars)
    }

    private func octets(_ type: ASN1Type, _ r: inout PERBitReader) throws -> [UInt8] {
        let n = try count(type.constraint?.size, &r)
        return try r.octets(n)
    }

    private func bitString(_ type: ASN1Type, _ r: inout PERBitReader) throws -> ASN1Value {
        let n = try count(type.constraint?.size, &r)
        return .bits(try r.bitArray(n), count: n)
    }

    private mutating func sequence(_ type: ASN1Type, _ name: String, _ r: inout PERBitReader) throws -> ASN1Value {
        let members = type.members ?? []
        let extensible = (type.extBefore ?? -1) >= 0
        let rootEnd = extensible ? min(members.count, (type.extBefore ?? -1) + 1) : members.count
        let extended = extensible ? (try r.bit() == 1) : false
        // Anwesenheitsbits der optionalen Wurzelfelder.
        var present: [Bool] = []
        for m in members[0..<rootEnd] { present.append(m.optional ? (try r.bit() == 1) : true) }
        var out: [(String, ASN1Value)] = []
        for (i, m) in members[0..<rootEnd].enumerated() where present[i] {
            out.append((m.name, try decode(m.type, &r)))
        }
        if extended {
            let n = try r.normallySmallLength()
            var flags: [Bool] = []
            for _ in 0..<n { flags.append(try r.bit() == 1) }
            for (k, flag) in flags.enumerated() where flag {
                let length = try r.lengthDeterminant()
                let data = try r.octets(length)
                let index = rootEnd + k
                if index < members.count {
                    var sub = PERBitReader(bytes: data)
                    if let value = try? decode(members[index].type, &sub) { out.append((members[index].name, value)); continue }
                }
                out.append(("erweiterung\(k)", .open(data)))
            }
        }
        return .sequence(out)
    }

    private mutating func choice(_ type: ASN1Type, _ name: String, _ r: inout PERBitReader) throws -> ASN1Value {
        let members = type.members ?? []
        let extStart = type.extStart ?? -1
        let extensible = extStart >= 0
        let rootCount = extensible ? min(extStart, members.count) : members.count
        if extensible, try r.bit() == 1 {
            let (index, overflow) = rootCount.addingReportingOverflow(try r.normallySmall())
            guard !overflow, index >= 0 else { throw PERError(description: "CHOICE-Erweiterung in \(name)") }
            let length = try r.lengthDeterminant()
            let data = try r.octets(length)
            if index < members.count {
                var sub = PERBitReader(bytes: data)
                if let value = try? decode(members[index].type, &sub) { return .choice(members[index].name, value) }
            }
            return .choice("erweiterung#\(index)", .open(data))
        }
        let bits = type.constraint?.value?.bits ?? max(1, Int((log2(Double(max(rootCount, 1)))).rounded(.up)))
        let index = rootCount <= 1 ? 0 : try r.bits(bits)
        guard index >= 0, index < members.count else { throw PERError(description: "CHOICE-Index \(index) in \(name)") }
        return .choice(members[index].name, try decode(members[index].type, &r))
    }

    private mutating func sequenceOf(_ type: ASN1Type, _ r: inout PERBitReader) throws -> ASN1Value {
        let n = try count(type.constraint?.size, &r)
        guard n >= 0, n <= 10_000, let element = type.element else { throw PERError(description: "SEQUENCE OF") }
        var items: [ASN1Value] = []
        for _ in 0..<n { items.append(try decode(element, &r)) }
        return .list(items)
    }
}
