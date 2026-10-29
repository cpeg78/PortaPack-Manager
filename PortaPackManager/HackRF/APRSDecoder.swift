import Foundation

// MARK: - AFSK 1200 (Bell 202)

/// Demoduliert AFSK 1200 Bd (Mark 1200 Hz, Space 2200 Hz) aus dem
/// FM-Diskriminatorsignal bei 48 kHz und liefert geprüfte AX.25-Rahmen.
///
/// Zwei gleitende Quadraturkorrelatoren über je eine Bitdauer messen die
/// Leistung beider Töne. Weil Sender und Empfänger die Töne unterschiedlich
/// betonen („Twist“), laufen mehrere Entscheider mit verschieden
/// gewichtetem Space-Ton parallel – wie die Mehrfach-Slicer in direwolf.
/// Doppelt dekodierte Rahmen werden verworfen.
final class AFSKDemodulator: @unchecked Sendable {
    static let sampleRate = FMChannelizer.outputRate
    static let baud = 1200.0
    static let spaceGains: [Float] = [0.5, 0.7, 1.0, 1.4, 2.0]

    private let window = Int(sampleRate / baud)   // 40 Werte = 1 Bit
    private let markStep = 2 * Double.pi * 1200 / sampleRate
    private let spaceStep = 2 * Double.pi * 2200 / sampleRate
    private var markPhase = 0.0, spacePhase = 0.0
    private var ring: [(Float, Float, Float, Float)]
    private var ringIndex = 0
    private var sums: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var slicers: [Slicer]
    private var sampleCounter = 0
    private var recent: [(frame: [UInt8], sample: Int)] = []
    private var sinceRecalc = 0

    private struct Slicer {
        var gain: Float
        var clock = BitClock(bitRate: AFSKDemodulator.baud, sampleRate: AFSKDemodulator.sampleRate, inertia: 0.75)
        var nrzi = NRZIDecoder()
        var deframer = HDLCDeframer(minimumBytes: 15, maximumBytes: 330)
    }

    init() {
        ring = Array(repeating: (0, 0, 0, 0), count: window)
        slicers = Self.spaceGains.map { Slicer(gain: $0) }
    }

    func reset() {
        ring = Array(repeating: (0, 0, 0, 0), count: window)
        sums = (0, 0, 0, 0)
        slicers = Self.spaceGains.map { Slicer(gain: $0) }
        recent = []
    }

    /// Verarbeitet Diskriminatorwerte und liefert neu dekodierte Rahmen (ohne FCS).
    func process(_ samples: [Float]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for x in samples {
            sampleCounter += 1
            let mr = x * Float(cos(markPhase)), mi = x * Float(sin(markPhase))
            let sr = x * Float(cos(spacePhase)), si = x * Float(sin(spacePhase))
            markPhase += markStep
            spacePhase += spaceStep
            if markPhase > 2 * .pi { markPhase -= 2 * .pi }
            if spacePhase > 2 * .pi { spacePhase -= 2 * .pi }
            let old = ring[ringIndex]
            ring[ringIndex] = (mr, mi, sr, si)
            ringIndex = (ringIndex + 1) % window
            sums.0 += mr - old.0
            sums.1 += mi - old.1
            sums.2 += sr - old.2
            sums.3 += si - old.3
            sinceRecalc += 1
            if sinceRecalc >= 4096 {
                // Rundungsfehler der gleitenden Summen gelegentlich bereinigen.
                sinceRecalc = 0
                sums = ring.reduce((0, 0, 0, 0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2, $0.3 + $1.3) }
            }
            let mark = (sums.0 * sums.0 + sums.1 * sums.1).squareRoot()
            let space = (sums.2 * sums.2 + sums.3 * sums.3).squareRoot()
            for index in slicers.indices {
                let d = mark - slicers[index].gain * space
                guard let value = slicers[index].clock.push(d) else { continue }
                let bit = slicers[index].nrzi.decode(value > 0 ? 1 : 0)
                if let frame = slicers[index].deframer.push(bit) { accept(frame, into: &frames) }
            }
        }
        return frames
    }

    /// Nimmt einen Rahmen nur auf, wenn ihn kein anderer Entscheider kurz zuvor geliefert hat.
    private func accept(_ frame: [UInt8], into frames: inout [[UInt8]]) {
        let horizon = Int(Self.sampleRate / 2)
        recent.removeAll { sampleCounter - $0.sample > horizon }
        guard !recent.contains(where: { $0.frame == frame }) else { return }
        recent.append((frame, sampleCounter))
        frames.append(frame)
    }
}

// MARK: - AX.25

struct AX25Address: Sendable, Equatable, Hashable {
    var call: String
    var ssid: Int
    /// H-Bit: Digipeater hat das Paket bereits wiederholt.
    var repeated = false

    var description: String { ssid == 0 ? call : "\(call)-\(ssid)" }

    /// Aus „CALL-7“ oder „CALL“.
    init(_ text: String, repeated: Bool = false) {
        let parts = text.split(separator: "-", maxSplits: 1)
        call = String(parts.first ?? "").uppercased()
        ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        self.repeated = repeated
    }

    init(call: String, ssid: Int, repeated: Bool = false) {
        self.call = call
        self.ssid = ssid
        self.repeated = repeated
    }

    func encoded(last: Bool) -> [UInt8] {
        let padded = Array((call + "      ").utf8.prefix(6))
        var bytes = padded.map { $0 << 1 }
        bytes.append(0x60 | UInt8(ssid & 0x0F) << 1 | (repeated ? 0x80 : 0) | (last ? 1 : 0))
        return bytes
    }
}

/// UI-Rahmen nach AX.25 2.2 (APRS nutzt nur diese).
struct AX25Frame: Sendable, Equatable {
    var destination: AX25Address
    var source: AX25Address
    var digipeaters: [AX25Address] = []
    var control: UInt8 = 0x03
    var pid: UInt8 = 0xF0
    var info: [UInt8]

    static func parse(_ bytes: [UInt8]) -> AX25Frame? {
        var addresses: [AX25Address] = []
        var index = 0
        while index + 7 <= bytes.count {
            let chunk = bytes[index..<index + 7]
            let chars = chunk.prefix(6).map { $0 >> 1 }
            guard chars.allSatisfy({ $0 == 0x20 || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { return nil }
            let call = String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let ssidByte = chunk.last!
            addresses.append(AX25Address(call: call, ssid: Int((ssidByte >> 1) & 0x0F), repeated: ssidByte & 0x80 != 0))
            index += 7
            if ssidByte & 1 != 0 { break }
            if addresses.count > 10 { return nil }
        }
        guard addresses.count >= 2, index + 2 <= bytes.count, !addresses[1].call.isEmpty else { return nil }
        let control = bytes[index]
        guard control & 0xEF == 0x03 else { return nil }   // nur UI-Rahmen
        return AX25Frame(destination: addresses[0], source: addresses[1], digipeaters: Array(addresses.dropFirst(2)),
                         control: control, pid: bytes[index + 1], info: Array(bytes[(index + 2)...]))
    }

    func encoded() -> [UInt8] {
        var out = destination.encoded(last: false)
        out += source.encoded(last: digipeaters.isEmpty)
        for (n, digi) in digipeaters.enumerated() { out += digi.encoded(last: n == digipeaters.count - 1) }
        out += [control, pid]
        out += info
        return out
    }

    /// Pfad in TNC2-Schreibweise, z. B. „WIDE1-1*,WIDE2-1“.
    var path: String {
        digipeaters.map { $0.description + ($0.repeated ? "*" : "") }.joined(separator: ",")
    }

    var infoText: String { String(decoding: info.map { $0 < 0x20 || $0 > 0x7E ? 0x2E : $0 }, as: UTF8.self) }

    /// TNC2-Monitorzeile „QUELLE>ZIEL,PFAD:Info“.
    var tnc2: String {
        "\(source.description)>\(destination.description)\(digipeaters.isEmpty ? "" : "," + path):\(infoText)"
    }
}

// MARK: - APRS

/// Ausgewertetes APRS-Paket.
struct APRSPacket: Sendable, Equatable {
    enum Kind: String, Sendable {
        case position = "Position"
        case micE = "Mic-E"
        case object = "Objekt"
        case item = "Item"
        case status = "Status"
        case message = "Nachricht"
        case weather = "Wetter"
        case telemetry = "Telemetrie"
        case other = "Sonstiges"

        /// Anzeigename (übersetzt).
        var title: String {
            switch self {
            case .position: String(localized: "Position")
            case .micE: "Mic-E"
            case .object: String(localized: "Objekt")
            case .item: String(localized: "Item")
            case .status: String(localized: "Status")
            case .message: String(localized: "Nachricht")
            case .weather: String(localized: "Wetter")
            case .telemetry: String(localized: "Telemetrie")
            case .other: String(localized: "Sonstiges")
            }
        }
    }

    var source: String
    var destination: String
    var path: String
    var kind: Kind = .other
    var latitude: Double?
    var longitude: Double?
    var symbolTable: Character = "/"
    var symbolCode: Character = "/"
    var courseDegrees: Double?
    var speedKnots: Double?
    var altitudeMeters: Double?
    var comment = ""
    /// Name bei Objekten/Items; `nil` sonst.
    var objectName: String?
    var objectKilled = false
    var micEMessage: String?
    var weather: String?
    var raw: String

    /// Kennung für die Stationsliste: Objektname oder Absender.
    var stationID: String { objectName ?? source }

    init(source: String, destination: String, path: String, raw: String) {
        self.source = source
        self.destination = destination
        self.path = path
        self.raw = raw
    }

    static func parse(_ frame: AX25Frame) -> APRSPacket {
        var packet = APRSPacket(source: frame.source.description, destination: frame.destination.description,
                                path: frame.path, raw: frame.tnc2)
        packet.decode(info: frame.info, destinationCall: frame.destination.call)
        return packet
    }

    /// Paket aus einer TNC2-Zeile (für Drittanbieter-Pakete und Tests).
    static func parse(tnc2 line: String) -> APRSPacket? {
        guard let colon = line.firstIndex(of: ":"), let gt = line.firstIndex(of: ">"), gt < colon else { return nil }
        let source = String(line[..<gt])
        let route = line[line.index(after: gt)..<colon].split(separator: ",").map(String.init)
        guard let destination = route.first else { return nil }
        var packet = APRSPacket(source: source, destination: destination,
                                path: route.dropFirst().joined(separator: ","), raw: line)
        let info = Array(line[line.index(after: colon)...].utf8)
        packet.decode(info: info, destinationCall: AX25Address(destination).call)
        return packet
    }

    private mutating func decode(info: [UInt8], destinationCall: String) {
        guard let type = info.first else { return }
        let text = Array(info)
        switch type {
        case UInt8(ascii: "!"), UInt8(ascii: "="):
            kind = .position
            decodePosition(text, at: 1)
        case UInt8(ascii: "/"), UInt8(ascii: "@"):
            kind = .position
            decodePosition(text, at: 8)    // 7 Zeichen Zeitstempel
        case UInt8(ascii: "`"), UInt8(ascii: "'"), 0x1C, 0x1D:
            kind = .micE
            decodeMicE(text, destination: destinationCall)
        case UInt8(ascii: ";"):
            kind = .object
            guard text.count >= 18 else { return }
            objectName = Self.string(text[1..<10]).trimmingCharacters(in: .whitespaces)
            objectKilled = text[10] == UInt8(ascii: "_")
            decodePosition(text, at: 18)
        case UInt8(ascii: ")"):
            kind = .item
            let body = text.dropFirst()
            guard let end = body.prefix(10).firstIndex(where: { $0 == UInt8(ascii: "!") || $0 == UInt8(ascii: "_") }) else { return }
            objectName = Self.string(text[1..<end])
            objectKilled = text[end] == UInt8(ascii: "_")
            decodePosition(text, at: end + 1)
        case UInt8(ascii: ">"):
            kind = .status
            comment = Self.string(text.dropFirst())
        case UInt8(ascii: ":"):
            kind = .message
            if text.count > 11, text[10] == UInt8(ascii: ":") {
                let to = Self.string(text[1..<10]).trimmingCharacters(in: .whitespaces)
                let body = Self.string(text[11...])
                comment = String(localized: "an \(to): \(body)")
                if to.hasPrefix("BLN") { kind = .other; comment = String(localized: "Bulletin \(to): \(body)") }
            } else {
                comment = Self.string(text.dropFirst())
            }
        case UInt8(ascii: "_"):
            kind = .weather
            weather = Self.weatherSummary(Self.string(text.dropFirst(9)))
        case UInt8(ascii: "T"):
            kind = .telemetry
            comment = Self.string(text.dropFirst())
        case UInt8(ascii: "}"):
            // Drittanbieter-Paket: inneres Paket auswerten, Pfad behalten.
            if let inner = APRSPacket.parse(tnc2: Self.string(text.dropFirst())) {
                let outerPath = path
                self = inner
                path = outerPath.isEmpty ? String(localized: "über Gateway") : outerPath
            }
        default:
            // Position ohne Kennzeichen an erster Stelle (bis 40 Zeichen weiter) – selten, nicht ausgewertet.
            comment = Self.string(text)
        }
        if symbolCode == "_", let weatherText = weather ?? Self.weatherSummary(comment) {
            kind = kind == .position ? .weather : kind
            weather = weatherText
        }
    }

    // MARK: Positionsformate

    private mutating func decodePosition(_ text: [UInt8], at start: Int) {
        guard start < text.count else { return }
        let first = text[start]
        if (0x30...0x39).contains(first) || first == 0x20 {
            decodeUncompressed(text, at: start)
        } else if text.count >= start + 13 {
            decodeCompressed(text, at: start)
        }
    }

    private mutating func decodeUncompressed(_ text: [UInt8], at start: Int) {
        guard text.count >= start + 19 else { return }
        // Positionsunschärfe (Leerzeichen statt Ziffern) als 0 lesen.
        func digits(_ range: Range<Int>) -> String {
            Self.string(text[range]).replacingOccurrences(of: " ", with: "0")
        }
        let latText = digits(start..<start + 7)
        let ns = text[start + 7]
        let lonText = digits(start + 9..<start + 17)
        let ew = text[start + 17]
        guard let latDeg = Double(latText.prefix(2)), let latMin = Double(latText.dropFirst(2)),
              let lonDeg = Double(lonText.prefix(3)), let lonMin = Double(lonText.dropFirst(3)),
              [UInt8(ascii: "N"), UInt8(ascii: "S")].contains(ns),
              [UInt8(ascii: "E"), UInt8(ascii: "W")].contains(ew) else { return }
        var lat = latDeg + latMin / 60
        var lon = lonDeg + lonMin / 60
        if ns == UInt8(ascii: "S") { lat = -lat }
        if ew == UInt8(ascii: "W") { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return }
        latitude = lat
        longitude = lon
        symbolTable = Character(Unicode.Scalar(text[start + 8]))
        symbolCode = Character(Unicode.Scalar(text[start + 18]))
        var rest = Self.string(text[(start + 19)...])
        // Datenerweiterung „Kurs/Tempo“ (ddd/ddd).
        if rest.count >= 7 {
            let ext = Array(rest.prefix(7))
            if ext[3] == "/", let course = Double(String(ext[0..<3])), let speed = Double(String(ext[4..<7])) {
                if course > 0 { courseDegrees = course.truncatingRemainder(dividingBy: 360) }
                speedKnots = speed
                rest.removeFirst(7)
            } else if rest.hasPrefix("PHG") || rest.hasPrefix("RNG") || rest.hasPrefix("DFS") {
                rest.removeFirst(7)
            }
        }
        comment = extractAltitude(from: rest)
        if symbolCode == "_" { weather = Self.weatherSummary(comment) }
    }

    private mutating func decodeCompressed(_ text: [UInt8], at start: Int) {
        let table = text[start]
        guard table == UInt8(ascii: "/") || table == UInt8(ascii: "\\") || (0x41...0x5A).contains(table) || (0x61...0x6A).contains(table),
              let y = Self.base91(text[start + 1..<start + 5]), let x = Self.base91(text[start + 5..<start + 9]) else { return }
        latitude = 90 - Double(y) / 380_926
        longitude = -180 + Double(x) / 190_463
        symbolTable = Character(Unicode.Scalar(table))
        symbolCode = Character(Unicode.Scalar(text[start + 9]))
        let c = Int(text[start + 10]) - 33, s = Int(text[start + 11]) - 33, t = Int(text[start + 12]) - 33
        if text[start + 10] != 0x20, c >= 0, s >= 0 {
            if t >= 0, (t >> 3) & 3 == 2 {
                altitudeMeters = pow(1.002, Double(c * 91 + s)) * 0.3048
            } else if c <= 89 {
                courseDegrees = c == 0 ? nil : Double(c * 4)
                speedKnots = pow(1.08, Double(s)) - 1
            }
        }
        comment = extractAltitude(from: Self.string(text[(start + 13)...]))
    }

    /// Mic-E: Breite, Nachrichtenbits und Richtungen stecken im Zielrufzeichen.
    private mutating func decodeMicE(_ text: [UInt8], destination: String) {
        let dest = Array(destination.utf8)
        guard dest.count >= 6, text.count >= 9 else { return }
        func digit(_ c: UInt8) -> Int? {
            switch c {
            case 0x30...0x39: Int(c - 0x30)
            case 0x41...0x4A: Int(c - 0x41)
            case 0x50...0x59: Int(c - 0x50)
            case 0x4B, 0x4C, 0x5A: 0          // Unschärfe
            default: nil
            }
        }
        let northOrWest: (UInt8) -> Bool = { (0x50...0x5A).contains($0) }
        let digits = dest.prefix(6).compactMap(digit)
        guard digits.count == 6 else { return }
        var lat = Double(digits[0] * 10 + digits[1]) + (Double(digits[2] * 10 + digits[3]) + Double(digits[4] * 10 + digits[5]) / 100) / 60
        if !northOrWest(dest[3]) { lat = -lat }

        var degrees = Int(text[1]) - 28
        if northOrWest(dest[4]) { degrees += 100 }
        if (180...189).contains(degrees) { degrees -= 80 } else if (190...199).contains(degrees) { degrees -= 190 }
        var minutes = Int(text[2]) - 28
        if minutes >= 60 { minutes -= 60 }
        let hundredths = Int(text[3]) - 28
        var lon = Double(degrees) + (Double(minutes) + Double(hundredths) / 100) / 60
        if northOrWest(dest[5]) { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180, minutes >= 0, hundredths >= 0 else { return }
        latitude = lat
        longitude = lon

        let sp = Int(text[4]) - 28, dc = Int(text[5]) - 28, se = Int(text[6]) - 28
        var speed = sp * 10 + dc / 10
        var course = (dc % 10) * 100 + se
        if speed >= 800 { speed -= 800 }
        if course >= 400 { course -= 400 }
        speedKnots = Double(speed)
        if course > 0 && course <= 360 { courseDegrees = Double(course % 360) }
        symbolCode = Character(Unicode.Scalar(text[7]))
        symbolTable = Character(Unicode.Scalar(text[8]))

        // Nachrichtencode aus den ersten drei Zeichen.
        let bits = dest.prefix(3).map { (0x50...0x5A).contains($0) || (0x41...0x4B).contains($0) ? 1 : 0 }
        let custom = dest.prefix(3).contains { (0x41...0x4B).contains($0) }
        let code = bits[0] << 2 | bits[1] << 1 | bits[2]
        let names = [String(localized: "Notfall"), String(localized: "Priorität"), String(localized: "Sonder"),
                     String(localized: "Zugesagt"), String(localized: "Rückkehr"), String(localized: "Im Dienst"),
                     String(localized: "Unterwegs"), String(localized: "Außer Dienst")]
        micEMessage = custom ? (code == 0 ? String(localized: "Notfall") : String(localized: "Eigene Meldung \(7 - code)")) : names[code]

        var rest = Array(text.dropFirst(9))
        // Höhe: drei Base-91-Zeichen und „}“, Meter über −10 km.
        if let brace = rest.firstIndex(of: UInt8(ascii: "}")), brace >= 3, brace <= 4,
           let value = Self.base91(rest[(brace - 3)..<brace]) {
            altitudeMeters = Double(value - 10_000)
            rest.removeSubrange(0...brace)
        }
        // Gerätekennungen von Kenwood (> ]) am Anfang weglassen.
        if let first = rest.first, first == UInt8(ascii: ">") || first == UInt8(ascii: "]") { rest.removeFirst() }
        comment = extractAltitude(from: Self.string(rest))
    }

    /// Holt „/A=dddddd“ (Fuß) aus dem Kommentar.
    private mutating func extractAltitude(from text: String) -> String {
        guard let range = text.range(of: "/A=") else { return text.trimmingCharacters(in: .whitespaces) }
        let digits = text[range.upperBound...].prefix(6)
        if digits.count == 6, let feet = Double(digits) {
            altitudeMeters = feet * 0.3048
            var rest = text
            rest.removeSubrange(range.lowerBound..<text.index(range.upperBound, offsetBy: 6))
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Wetter

    /// Kurzfassung der APRS-Wetterangaben (Wind ddd/sss, t, h, b, r, g).
    static func weatherSummary(_ text: String) -> String? {
        var parts: [String] = []
        let chars = Array(text)
        var i = 0
        if chars.count >= 7, chars[3] == "/", let dir = Int(String(chars[0..<3])), let speed = Int(String(chars[4..<7])) {
            parts.append(String(format: String(localized: "Wind %.0f km/h aus %d°"), Double(speed) * 1.609, dir))
            i = 7
        } else if chars.count >= 8, chars[0] == "c", chars[4] == "s",
                  let dir = Int(String(chars[1..<4])), let speed = Int(String(chars[5..<8])) {
            parts.append(String(format: String(localized: "Wind %.0f km/h aus %d°"), Double(speed) * 1.609, dir))
            i = 8
        }
        func value(_ length: Int) -> Int? {
            guard i + 1 + length <= chars.count else { return nil }
            return Int(String(chars[(i + 1)..<(i + 1 + length)]).trimmingCharacters(in: .whitespaces))
        }
        var found = !parts.isEmpty
        while i < chars.count {
            switch chars[i] {
            case "g": if let v = value(3) { parts.append(String(format: String(localized: "Böen %.0f km/h"), Double(v) * 1.609)) }; i += 4
            case "t": if let v = value(3) { parts.append(String(format: "%.1f °C", (Double(v) - 32) * 5 / 9)) }; i += 4; found = true
            case "r", "p", "P": i += 4
            case "h": if let v = value(2) { parts.append("\(v == 0 ? 100 : v) %") }; i += 3; found = true
            case "b": if let v = value(5) { parts.append(String(format: "%.1f hPa", Double(v) / 10)) }; i += 6; found = true
            case "L", "l": i += 4
            default: i = chars.count
            }
        }
        return found ? parts.joined(separator: ", ") : nil
    }

    // MARK: Hilfen

    static func base91<C: Collection>(_ chars: C) -> Int? where C.Element == UInt8 {
        var value = 0
        for c in chars {
            guard c >= 33, c <= 124 else { return nil }
            value = value * 91 + Int(c - 33)
        }
        return value
    }

    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes.map { $0 < 0x20 || $0 > 0x7E ? 0x20 : $0 }, as: UTF8.self)
    }

    /// SF-Symbol zum APRS-Symbol (Haupttabelle „/“; Rest grob zugeordnet).
    var systemImage: String {
        switch symbolCode {
        case ">", "j": "car.fill"
        case "k", "u": "box.truck.fill"
        case "v", "R": "bus.fill"
        case "U": "bus.fill"
        case "-", "y": "house.fill"
        case "_": "cloud.sun.fill"
        case "#", "r", "&", "`": "antenna.radiowaves.left.and.right"
        case "[": "figure.walk"
        case "b", "<": "bicycle"
        case "Y": "sailboat.fill"
        case "s": "ferry.fill"
        case "O": "balloon.fill"
        case "^", "'": "airplane"
        case "a": "cross.case.fill"
        case "f": "flame.fill"
        default: "mappin.circle.fill"
        }
    }
}

/// Station (oder Objekt) mit letzter Position und Spur.
struct APRSStation: Identifiable, Sendable, Equatable {
    struct Point: Sendable, Equatable { var lat: Double; var lon: Double }

    var id: String
    var last: APRSPacket
    var latitude: Double?
    var longitude: Double?
    var trail: [Point] = []
    var packets = 0
    var lastHeard = Date()
}

/// Sammelt Pakete zu Stationen.
struct APRSStationTracker {
    private(set) var stations: [String: APRSStation] = [:]

    mutating func ingest(_ packet: APRSPacket, at date: Date = Date()) {
        let id = packet.stationID
        var station = stations[id] ?? APRSStation(id: id, last: packet)
        station.last = packet
        station.packets += 1
        station.lastHeard = date
        if let lat = packet.latitude, let lon = packet.longitude {
            station.latitude = lat
            station.longitude = lon
            if let previous = station.trail.last {
                if GeoMath.distanceKm(lat1: previous.lat, lon1: previous.lon, lat2: lat, lon2: lon) > 0.01 {
                    station.trail.append(.init(lat: lat, lon: lon))
                }
            } else {
                station.trail.append(.init(lat: lat, lon: lon))
            }
            if station.trail.count > 500 { station.trail.removeFirst(station.trail.count - 500) }
        }
        stations[id] = station
        // Rufzeichen sind frei wählbar – Tabelle begrenzen.
        DevicePruning.prune(&stations, limit: 2000, maxAge: 3600, now: date) { $0.lastHeard }
    }

    var sorted: [APRSStation] { stations.values.sorted { $0.lastHeard > $1.lastHeard } }
}
