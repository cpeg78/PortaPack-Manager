import Foundation

/// Comm-B-Register in Radarantworten (DF20/21, Mode-S „Enhanced Surveillance“,
/// in Europa Pflicht): 56 Bit ohne Kennung, welches Register es ist – die
/// Abfrage des Radars hören wir nicht. Wie pyModeS (`bds.infer`): Ein Register
/// gilt nur, wenn alle Status- und Reservebits und Wertebereiche passen.
/// Passen BDS 5,0 und 6,0 zugleich, entscheidet der Abgleich mit dem ADS-B-
/// Kurs bzw. -Tempo; bleibt es mehrdeutig, wird die Antwort verworfen.
enum CommB: Equatable {
    /// BDS 2,0: Rufzeichen (auch von Flugzeugen ohne ADS-B).
    case identification(String)
    /// BDS 4,0: eingestellte Höhe (MCP/FCU bzw. FMS) und QNH.
    case verticalIntention(mcpAltitude: Int?, fmsAltitude: Int?, qnh: Double?)
    /// BDS 5,0: Querneigung, wahrer Kurs, Grundgeschwindigkeit, wahre Fahrt.
    case trackAndTurn(roll: Double?, track: Double?, groundSpeed: Double?, trueAirspeed: Double?)
    /// BDS 6,0: Steuerkurs (magnetisch), angezeigte Fahrt, Mach, Steigrate.
    case headingAndSpeed(heading: Double?, indicatedAirspeed: Double?, mach: Double?, verticalRate: Int?)

    /// Was je Flugzeug bekannt ist, mit Zeitpunkt der letzten Meldung.
    struct State: Sendable, Equatable {
        var mcpAltitude: Int?
        var fmsAltitude: Int?
        var qnh: Double?
        var roll: Double?
        var trueAirspeed: Double?
        var trueTrack: Double?
        var groundSpeed: Double?
        var heading: Double?
        var indicatedAirspeed: Double?
        var mach: Double?
        /// Wind (kn) und Richtung, aus der er kommt (°) – aus Luft- und Bodenvektor.
        var windSpeed: Double?
        var windFrom: Double?
        var trackDate: Date?
        var headingDate: Date?
    }

    // MARK: Bits

    private struct Bits {
        let mb: [UInt8]
        func bit(_ n: Int) -> Bool { mb[(n - 1) >> 3] & (0x80 >> UInt8((n - 1) & 7)) != 0 }
        func field(_ first: Int, _ count: Int) -> Int { (first..<(first + count)).reduce(0) { $0 << 1 | (bit($1) ? 1 : 0) } }
        /// Wert mit Vorzeichenbit davor (Zweierkomplement über `count + 1` Bit).
        func signed(_ signBit: Int, _ count: Int) -> Int {
            let value = field(signBit + 1, count)
            return bit(signBit) ? value - (1 << count) : value
        }
        /// Feld mit Statusbit: Ist der Status aus, muss das Feld 0 sein.
        func statusOK(_ status: Int, _ first: Int, _ count: Int) -> Bool { bit(status) || field(first, count) == 0 }
    }

    // MARK: Register einzeln

    static func identification(_ mb: [UInt8]) -> String? {
        guard mb.count == 7, mb[0] == 0x20 else { return nil }
        // Streng wie pyModeS `is20`: nur A–Z, 0–9 und Leerzeichen – `callsign()`
        // entfernt „#“ selbst, die Prüfung danach griff nie (Review 05.11.2026).
        guard let text = ADSBDemodulator.callsign(mb, strict: true), !text.isEmpty else { return nil }
        return text
    }

    static func verticalIntention(_ mb: [UInt8]) -> CommB? {
        let b = Bits(mb: mb)
        guard b.statusOK(1, 2, 12), b.statusOK(14, 15, 12), b.statusOK(27, 28, 12),
              b.field(40, 8) == 0, b.field(52, 2) == 0, b.statusOK(48, 49, 3), b.statusOK(54, 55, 2) else { return nil }
        let mcp = b.bit(1) ? b.field(2, 12) * 16 : nil
        let fms = b.bit(14) ? b.field(15, 12) * 16 : nil
        let qnh = b.bit(27) ? Double(b.field(28, 12)) * 0.1 + 800 : nil
        guard mcp != nil || fms != nil || qnh != nil else { return nil }
        if let mcp, mcp > 45_000 { return nil }
        if let fms, fms > 45_000 { return nil }
        if let qnh, !(900...1100).contains(qnh) { return nil }
        return .verticalIntention(mcpAltitude: mcp, fmsAltitude: fms, qnh: qnh)
    }

    static func trackAndTurn(_ mb: [UInt8]) -> CommB? {
        let b = Bits(mb: mb)
        guard b.statusOK(1, 2, 10), b.statusOK(12, 13, 11), b.statusOK(24, 25, 10), b.statusOK(35, 36, 10),
              b.statusOK(46, 47, 10) else { return nil }
        let roll = b.bit(1) ? Double(b.signed(2, 9)) * 45 / 256 : nil
        var track = b.bit(12) ? Double(b.signed(13, 10)) * 90 / 512 : nil
        if let t = track, t < 0 { track = t + 360 }
        let gs = b.bit(24) ? Double(b.field(25, 10)) * 2 : nil
        let tas = b.bit(46) ? Double(b.field(47, 10)) * 2 : nil
        guard roll != nil || track != nil || gs != nil || tas != nil else { return nil }
        if let roll, abs(roll) > 50 { return nil }
        if let gs, gs > 600 { return nil }
        if let tas, tas > 500 { return nil }
        if let gs, let tas, abs(gs - tas) > 200 { return nil }
        return .trackAndTurn(roll: roll, track: track, groundSpeed: gs, trueAirspeed: tas)
    }

    static func headingAndSpeed(_ mb: [UInt8]) -> CommB? {
        let b = Bits(mb: mb)
        guard b.statusOK(1, 2, 11), b.statusOK(13, 14, 10), b.statusOK(24, 25, 10), b.statusOK(35, 36, 10),
              b.statusOK(46, 47, 10) else { return nil }
        var heading = b.bit(1) ? Double(b.signed(2, 10)) * 90 / 512 : nil
        if let h = heading, h < 0 { heading = h + 360 }
        let ias = b.bit(13) ? Double(b.field(14, 10)) : nil
        let mach = b.bit(24) ? Double(b.field(25, 10)) * 2.048 / 512 : nil
        let baroRate = b.bit(35) ? b.signed(36, 9) * 32 : nil
        let inertialRate = b.bit(46) ? b.signed(47, 9) * 32 : nil
        guard heading != nil || ias != nil || mach != nil else { return nil }
        if let ias, ias > 500 || ias < 10 { return nil }
        if let mach, mach > 1 { return nil }
        // Beide Steigraten prüfen (pyModeS `is60`), nicht nur die erste vorhandene (Review 05.11.2026).
        if let baroRate, abs(baroRate) > 6000 { return nil }
        if let inertialRate, abs(inertialRate) > 6000 { return nil }
        // Fahrt und Mach müssen grob zueinander passen (Mach ≈ IAS/600 … IAS/250).
        if let ias, let mach, mach > 0, !(ias / 700...ias / 200).contains(mach) { return nil }
        return .headingAndSpeed(heading: heading, indicatedAirspeed: ias, mach: mach, verticalRate: baroRate ?? inertialRate)
    }

    // MARK: Zuordnung

    /// Welches Register die Antwort trägt; `nil`, wenn keines oder mehrere passen.
    static func infer(_ mb: [UInt8], plane: Aircraft) -> CommB? {
        guard mb.count == 7, mb.contains(where: { $0 != 0 }) else { return nil }
        if let callsign = identification(mb) { return .identification(callsign) }
        var candidates = [verticalIntention(mb), trackAndTurn(mb), headingAndSpeed(mb)].compactMap { $0 }
        if candidates.count > 1 { candidates = candidates.filter { fits($0, plane: plane) } }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Passt ein Register zu dem, was ADS-B über das Flugzeug sagt?
    private static func fits(_ register: CommB, plane: Aircraft) -> Bool {
        func close(_ a: Double, _ b: Double, _ limit: Double) -> Bool {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d) <= limit
        }
        switch register {
        case let .trackAndTurn(_, track, gs, _):
            guard let referenceTrack = plane.track, let referenceSpeed = plane.groundSpeed else { return false }
            return track.map { close($0, referenceTrack, 20) } ?? false && gs.map { abs($0 - referenceSpeed) <= 30 } ?? false
        case let .headingAndSpeed(heading, _, _, _):
            // Steuerkurs (magnetisch) weicht durch Wind und Missweisung vom Kurs ab.
            guard let referenceTrack = plane.track, let heading else { return false }
            return close(heading, referenceTrack, 35)
        case let .verticalIntention(mcp, fms, _):
            guard let altitude = plane.altitude, let selected = mcp ?? fms else { return false }
            return abs(selected - altitude) < 20_000
        case .identification:
            return true
        }
    }

    // MARK: Übernehmen

    func apply(to plane: inout Aircraft, at date: Date) {
        var s = plane.commB
        switch self {
        case let .identification(callsign):
            if plane.callsign == nil { plane.callsign = callsign }
        case let .verticalIntention(mcp, fms, qnh):
            s.mcpAltitude = mcp ?? s.mcpAltitude
            s.fmsAltitude = fms ?? s.fmsAltitude
            s.qnh = qnh ?? s.qnh
        case let .trackAndTurn(roll, track, gs, tas):
            s.roll = roll ?? s.roll
            s.trueTrack = track ?? s.trueTrack
            s.groundSpeed = gs ?? s.groundSpeed
            s.trueAirspeed = tas ?? s.trueAirspeed
            s.trackDate = date
        case let .headingAndSpeed(heading, ias, mach, _):
            s.heading = heading ?? s.heading
            s.indicatedAirspeed = ias ?? s.indicatedAirspeed
            s.mach = mach ?? s.mach
            s.headingDate = date
        }
        (s.windSpeed, s.windFrom) = Self.wind(s, plane: plane, at: date) ?? (s.windSpeed, s.windFrom)
        plane.commB = s
    }

    /// Wind = Bodenvektor − Luftvektor. Luft: wahre Fahrt (5,0) und Steuerkurs
    /// (6,0, magnetisch – ohne Missweisung, in Mitteleuropa ≈ 3–5° Ost, also grob);
    /// Boden: ADS-B, sonst 5,0. Beide nicht älter als 30 s.
    static func wind(_ s: State, plane: Aircraft, at date: Date) -> (speed: Double, from: Double)? {
        guard let tas = s.trueAirspeed, let heading = s.heading,
              let trackDate = s.trackDate, let headingDate = s.headingDate,
              date.timeIntervalSince(trackDate) < 30, date.timeIntervalSince(headingDate) < 30,
              let gs = plane.groundSpeed ?? s.groundSpeed, let track = plane.track ?? s.trueTrack else { return nil }
        let rad = Double.pi / 180
        let groundE = gs * sin(track * rad), groundN = gs * cos(track * rad)
        let airE = tas * sin(heading * rad), airN = tas * cos(heading * rad)
        let windE = groundE - airE, windN = groundN - airN
        let speed = (windE * windE + windN * windN).squareRoot()
        guard speed < 250 else { return nil }
        var from = atan2(-windE, -windN) / rad
        if from < 0 { from += 360 }
        return (speed, from)
    }
}
