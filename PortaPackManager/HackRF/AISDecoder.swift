import Foundation

// MARK: - GMSK 9600

/// Demoduliert AIS (GMSK 9600 Bd, ±2,4 kHz Hub) aus dem FM-Diskriminator
/// bei 48 kHz (5 Werte je Bit): Gleichanteil (Frequenzablage) entfernen,
/// Bittakt rückgewinnen, NRZI, HDLC mit CRC.
///
/// Weil 5 Werte je Bit knapp sind, laufen zwei Entscheider mit leicht
/// unterschiedlicher Taktträgheit parallel; doppelte Rahmen werden verworfen.
final class GMSKDemodulator: @unchecked Sendable {
    static let sampleRate = FMChannelizer.outputRate
    static let baud = 9600.0

    private var slicers: [Slicer]
    private var dcWindow: [Float]
    private var dcIndex = 0
    private var dcSum: Float = 0
    private var counter = 0
    private var recent: [(frame: [UInt8], sample: Int)] = []

    private struct Slicer {
        var clock: BitClock
        var nrzi = NRZIDecoder()
        var deframer = HDLCDeframer(minimumBytes: 20, maximumBytes: 140)
    }

    init() {
        dcWindow = [Float](repeating: 0, count: 120)   // ≈ 24 Bit
        slicers = [0.6, 0.8].map { Slicer(clock: BitClock(bitRate: Self.baud, sampleRate: Self.sampleRate, inertia: $0)) }
    }

    func process(_ samples: [Float]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for x in samples {
            counter += 1
            // Gleitender Mittelwert als Schwelle: gleicht Frequenzablagen aus.
            dcSum += x - dcWindow[dcIndex]
            dcWindow[dcIndex] = x
            dcIndex = (dcIndex + 1) % dcWindow.count
            let v = x - dcSum / Float(dcWindow.count)
            for index in slicers.indices {
                guard let value = slicers[index].clock.push(v) else { continue }
                let bit = slicers[index].nrzi.decode(value > 0 ? 1 : 0)
                guard let frame = slicers[index].deframer.push(bit) else { continue }
                recent.removeAll { counter - $0.sample > 4800 }
                if !recent.contains(where: { $0.frame == frame }) {
                    recent.append((frame, counter))
                    frames.append(frame)
                }
            }
        }
        if counter > 1 << 30 { counter = 0; recent = [] }
        return frames
    }
}

// MARK: - Nachrichten

/// Bitleser für AIS-Nutzdaten (höchstwertiges Bit zuerst).
struct AISBits {
    let bits: [UInt8]

    /// Aus HDLC-Bytes (dort mit dem niederwertigen Bit zuerst gesendet):
    /// Die Nachrichtenbits stehen je Byte vom höchstwertigen Bit an.
    init(frameBytes: [UInt8]) {
        bits = frameBytes.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 } }
    }

    init(bits: [UInt8]) { self.bits = bits }

    /// Aus der 6-Bit-Panzerung einer NMEA-Zeile.
    init?(armored payload: String, fillBits: Int = 0) {
        var out: [UInt8] = []
        for c in payload.utf8 {
            var v = Int(c) - 48
            if v > 40 { v -= 8 }
            guard (0..<64).contains(v) else { return nil }
            for k in (0..<6).reversed() { out.append(UInt8((v >> k) & 1)) }
        }
        if fillBits > 0, fillBits <= out.count { out.removeLast(fillBits) }
        bits = out
    }

    var count: Int { bits.count }

    func unsigned(_ start: Int, _ length: Int) -> Int? {
        guard start + length <= bits.count else { return nil }
        var v = 0
        for k in start..<start + length { v = v << 1 | Int(bits[k]) }
        return v
    }

    func signed(_ start: Int, _ length: Int) -> Int? {
        guard let v = unsigned(start, length) else { return nil }
        return v & (1 << (length - 1)) != 0 ? v - (1 << length) : v
    }

    /// 6-Bit-Text; „@“ und Leerzeichen am Ende entfallen.
    func text(_ start: Int, _ length: Int) -> String? {
        let available = min(length, bits.count - start)
        guard available >= 6 else { return nil }
        var chars: [UInt8] = []
        for k in 0..<(available / 6) {
            guard let v = unsigned(start + 6 * k, 6) else { break }
            chars.append(UInt8(v < 32 ? v + 64 : v))
        }
        var s = String(decoding: chars, as: UTF8.self)
        while let last = s.last, last == "@" || last == " " { s.removeLast() }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? nil : s
    }

    /// 6-Bit-Panzerung für NMEA und Anzahl der Füllbits.
    var armored: (payload: String, fill: Int) {
        let fill = (6 - bits.count % 6) % 6
        let padded = bits + [UInt8](repeating: 0, count: fill)
        var chars: [UInt8] = []
        for k in stride(from: 0, to: padded.count, by: 6) {
            var v = 0
            for b in padded[k..<k + 6] { v = v << 1 | Int(b) }
            chars.append(UInt8(v < 40 ? v + 48 : v + 56))
        }
        return (String(decoding: chars, as: UTF8.self), fill)
    }
}

/// Ausgewertete AIS-Nachricht (nur die Felder, die die Anzeige braucht).
struct AISMessage: Sendable, Equatable {
    var type: Int
    var mmsi: Int
    var status: Int?
    var speedKnots: Double?
    var courseDegrees: Double?
    var heading: Int?
    var rateOfTurn: Double?
    var latitude: Double?
    var longitude: Double?
    var name: String?
    var callsign: String?
    var shipType: Int?
    var destination: String?
    var imo: Int?
    var lengthMeters: Int?
    var beamMeters: Int?
    var draughtMeters: Double?
    var eta: AISETA?
    var aidType: Int?
    var isBaseStation = false

    static func decode(_ bits: AISBits) -> AISMessage? {
        guard let type = bits.unsigned(0, 6), let mmsi = bits.unsigned(8, 30), bits.count >= 38 else { return nil }
        var m = AISMessage(type: type, mmsi: mmsi)
        switch type {
        case 1, 2, 3:
            guard bits.count >= 168 else { return nil }
            m.status = bits.unsigned(38, 4)
            if let rot = bits.signed(42, 8), rot != -128 {
                let v = Double(rot) / 4.733
                m.rateOfTurn = (v < 0 ? -1 : 1) * v * v
            }
            m.speedKnots = speed(bits.unsigned(50, 10))
            (m.longitude, m.latitude) = position(lon: bits.signed(61, 28), lat: bits.signed(89, 27))
            m.courseDegrees = course(bits.unsigned(116, 12))
            m.heading = heading(bits.unsigned(128, 9))
        case 4, 11:
            guard bits.count >= 168 else { return nil }
            m.isBaseStation = type == 4
            (m.longitude, m.latitude) = position(lon: bits.signed(79, 28), lat: bits.signed(107, 27))
        case 5:
            guard bits.count >= 420 else { return nil }
            m.imo = bits.unsigned(40, 30).flatMap { $0 == 0 ? nil : $0 }
            m.callsign = bits.text(70, 42)
            m.name = bits.text(112, 120)
            m.shipType = bits.unsigned(232, 8)
            (m.lengthMeters, m.beamMeters) = dimensions(bits, at: 240)
            m.eta = AISETA(month: bits.unsigned(274, 4) ?? 0, day: bits.unsigned(278, 5) ?? 0,
                           hour: bits.unsigned(283, 5) ?? 24, minute: bits.unsigned(288, 6) ?? 60)
            m.draughtMeters = bits.unsigned(294, 8).flatMap { $0 == 0 ? nil : Double($0) / 10 }
            m.destination = bits.text(302, 120)
        case 18, 19:
            guard bits.count >= 168 else { return nil }
            m.speedKnots = speed(bits.unsigned(46, 10))
            (m.longitude, m.latitude) = position(lon: bits.signed(57, 28), lat: bits.signed(85, 27))
            m.courseDegrees = course(bits.unsigned(112, 12))
            m.heading = heading(bits.unsigned(124, 9))
            if type == 19, bits.count >= 312 {
                m.name = bits.text(143, 120)
                m.shipType = bits.unsigned(263, 8)
                (m.lengthMeters, m.beamMeters) = dimensions(bits, at: 271)
            }
        case 21:
            guard bits.count >= 272 else { return nil }
            m.aidType = bits.unsigned(38, 5)
            var name = bits.text(43, 120) ?? ""
            if bits.count > 272, let ext = bits.text(272, min(88, (bits.count - 272) / 6 * 6)) { name += ext }
            m.name = name.isEmpty ? nil : name
            (m.longitude, m.latitude) = position(lon: bits.signed(164, 28), lat: bits.signed(192, 27))
            (m.lengthMeters, m.beamMeters) = dimensions(bits, at: 219)
        case 24:
            guard let part = bits.unsigned(38, 2) else { return nil }
            if part == 0 {
                m.name = bits.text(40, 120)
            } else if part == 1, bits.count >= 162 {
                m.shipType = bits.unsigned(40, 8)
                m.callsign = bits.text(90, 42)
                (m.lengthMeters, m.beamMeters) = dimensions(bits, at: 132)
            }
        default:
            break
        }
        return m
    }

    private static func speed(_ raw: Int?) -> Double? {
        guard let raw, raw < 1023 else { return nil }
        return Double(raw) / 10
    }

    private static func course(_ raw: Int?) -> Double? {
        guard let raw, raw < 3600 else { return nil }
        return Double(raw) / 10
    }

    private static func heading(_ raw: Int?) -> Int? {
        guard let raw, raw < 360 else { return nil }
        return raw
    }

    /// Länge/Breite in 1/10000 Minuten; 181°/91° heißt „nicht verfügbar“.
    private static func position(lon: Int?, lat: Int?) -> (Double?, Double?) {
        guard let lon, let lat else { return (nil, nil) }
        let x = Double(lon) / 600_000, y = Double(lat) / 600_000
        guard abs(x) <= 180, abs(y) <= 90, !(x == 0 && y == 0) else { return (nil, nil) }
        return (x, y)
    }

    /// Abmessungen ab Bug/Heck/Backbord/Steuerbord (9+9+6+6 Bit).
    private static func dimensions(_ bits: AISBits, at start: Int) -> (Int?, Int?) {
        guard let bow = bits.unsigned(start, 9), let stern = bits.unsigned(start + 9, 9),
              let port = bits.unsigned(start + 18, 6), let starboard = bits.unsigned(start + 24, 6) else { return (nil, nil) }
        let length = bow + stern, beam = port + starboard
        return (length == 0 ? nil : length, beam == 0 ? nil : beam)
    }

    // MARK: Klartext

    static func statusText(_ status: Int?) -> String? {
        guard let status else { return nil }
        let names = [String(localized: "unter Maschine"), String(localized: "vor Anker"), String(localized: "manövrierunfähig"),
                     String(localized: "manövrierbehindert"), String(localized: "tiefgangbehindert"), String(localized: "festgemacht"),
                     String(localized: "auf Grund"), String(localized: "beim Fischen"), String(localized: "unter Segel")]
        return status < names.count ? names[status] : nil
    }

    static func shipTypeText(_ type: Int?) -> String? {
        guard let type, type > 0 else { return nil }
        switch type {
        case 30: return String(localized: "Fischerei")
        case 31, 32: return String(localized: "Schlepper")
        case 33: return String(localized: "Baggerarbeiten")
        case 35: return String(localized: "Militär")
        case 36: return String(localized: "Segelboot")
        case 37: return String(localized: "Sportboot")
        case 40...49: return String(localized: "Schnellfahrzeug")
        case 50: return String(localized: "Lotse")
        case 51: return String(localized: "Seenotrettung")
        case 52: return String(localized: "Schlepper")
        case 53: return String(localized: "Hafenversorger")
        case 55: return String(localized: "Behörde")
        case 58: return String(localized: "Krankentransport")
        case 60...69: return String(localized: "Passagierschiff")
        case 70...79: return String(localized: "Frachter")
        case 80...89: return String(localized: "Tanker")
        default: return String(localized: "Sonstiges (\(type))")
        }
    }
}

// MARK: - NMEA

enum AISNMEA {
    /// `!AIVDM`-Zeilen für einen Rahmen; über 60 Zeichen Nutzlast wird geteilt.
    static func sentences(for bits: AISBits, channel: String, sequence: Int) -> [String] {
        let (payload, fill) = bits.armored
        let chunks = stride(from: 0, to: payload.count, by: 60).map { start -> String in
            let a = payload.index(payload.startIndex, offsetBy: start)
            let b = payload.index(a, offsetBy: min(60, payload.count - start))
            return String(payload[a..<b])
        }
        return chunks.enumerated().map { index, chunk in
            let seq = chunks.count > 1 ? String(sequence % 10) : ""
            let body = "AIVDM,\(chunks.count),\(index + 1),\(seq),\(channel),\(chunk),\(index == chunks.count - 1 ? fill : 0)"
            return "!\(body)*" + String(format: "%02X", checksum(body))
        }
    }

    static func checksum(_ body: String) -> UInt8 {
        body.utf8.reduce(0, ^)
    }

    /// Fügt eine oder mehrere `!AIVDM`-Zeilen zu Nutzbits zusammen (prüft die Prüfsumme).
    static func bits(from lines: [String]) -> AISBits? {
        var payload = ""
        var fill = 0
        for line in lines {
            guard line.hasPrefix("!"), let star = line.lastIndex(of: "*") else { return nil }
            let body = String(line[line.index(after: line.startIndex)..<star])
            guard let sum = UInt8(line[line.index(after: star)...].prefix(2), radix: 16), sum == checksum(body) else { return nil }
            let fields = body.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { return nil }
            payload += fields[5]
            fill = Int(fields[6]) ?? 0
        }
        return AISBits(armored: payload, fillBits: fill)
    }
}

// MARK: - Schiffsliste

struct AISVessel: Identifiable, Sendable, Equatable {
    struct Point: Sendable, Equatable { var lat: Double; var lon: Double }

    var mmsi: Int
    var name: String?
    var callsign: String?
    var shipType: Int?
    var destination: String?
    var status: Int?
    var speedKnots: Double?
    var courseDegrees: Double?
    var heading: Int?
    var latitude: Double?
    var longitude: Double?
    var lengthMeters: Int?
    var beamMeters: Int?
    var imo: Int?
    var draughtMeters: Double?
    var eta: AISETA?
    var isBaseStation = false
    var isAidToNavigation = false
    var trail: [Point] = []
    var messages = 0
    var lastSeen = Date()
    var lastChannel = ""

    var id: Int { mmsi }

    /// Kurs zum Zeichnen: Steuerkurs, sonst Kurs über Grund.
    var displayHeading: Double? { heading.map(Double.init) ?? courseDegrees }
}

struct AISTracker {
    private(set) var vessels: [Int: AISVessel] = [:]

    mutating func ingest(_ m: AISMessage, channel: String, at date: Date = Date()) {
        var v = vessels[m.mmsi] ?? AISVessel(mmsi: m.mmsi)
        v.messages += 1
        v.lastSeen = date
        v.lastChannel = channel
        if let name = m.name { v.name = name }
        if let callsign = m.callsign { v.callsign = callsign }
        if let shipType = m.shipType { v.shipType = shipType }
        if let destination = m.destination { v.destination = destination }
        if let length = m.lengthMeters { v.lengthMeters = length }
        if let beam = m.beamMeters { v.beamMeters = beam }
        if let imo = m.imo { v.imo = imo }
        if m.type == 5 {
            v.draughtMeters = m.draughtMeters
            v.eta = m.eta
        }
        if m.isBaseStation { v.isBaseStation = true }
        if m.type == 21 { v.isAidToNavigation = true }
        if [1, 2, 3, 18, 19].contains(m.type) {
            v.status = m.status ?? v.status
            v.speedKnots = m.speedKnots
            v.courseDegrees = m.courseDegrees
            v.heading = m.heading
        }
        if let lat = m.latitude, let lon = m.longitude {
            v.latitude = lat
            v.longitude = lon
            if let last = v.trail.last {
                if GeoMath.distanceKm(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon) > 0.01 {
                    v.trail.append(.init(lat: lat, lon: lon))
                }
            } else {
                v.trail.append(.init(lat: lat, lon: lon))
            }
            if v.trail.count > 500 { v.trail.removeFirst(v.trail.count - 500) }
        }
        vessels[m.mmsi] = v
        DevicePruning.prune(&vessels, limit: Self.maxVessels, maxAge: 3600, now: date) { $0.lastSeen }
    }

    /// MMSI sind frei wählbar – Obergrenze gegen gefälschte Kennungen.
    static let maxVessels = 2000

    var sorted: [AISVessel] { vessels.values.sorted { $0.lastSeen > $1.lastSeen } }
}

/// Voraussichtliche Ankunft aus Meldung 5 (UTC, ohne Jahr). Nicht verfügbar:
/// Monat/Tag 0, Stunde 24, Minute 60 – ist alles leer, gibt es keine ETA.
struct AISETA: Sendable, Equatable {
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int

    init?(month: Int, day: Int, hour: Int, minute: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// „24.10. 14:30 UTC“ bzw. „24.10.“ ohne Uhrzeit.
    var text: String {
        let date = String(format: "%02d.%02d.", day, month)
        guard hour < 24, minute < 60 else { return date }
        return date + String(format: " %02d:%02d UTC", hour, minute)
    }
}
