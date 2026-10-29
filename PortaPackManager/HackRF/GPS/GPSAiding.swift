import Foundation

/// Almanach eines Satelliten (Subframe 5 Seiten 1–24, Subframe 4 Seiten
/// 2–5 und 7–10; IS-GPS-200 Tabelle 20-VI). Grobe Bahn, wochenlang brauchbar
/// – genug, um Sichtbarkeit und Doppler auf wenige Hz vorherzusagen.
struct GPSAlmanac: Sendable, Equatable, Codable {
    var prn: Int
    var health: Int
    var e: Double
    /// Bezugszeit als absolute GPS-Sekunden (Woche · 604 800 + toa).
    var toaAbsolute: Double
    var i0: Double                 // rad
    var omegaDot: Double           // rad/s
    var sqrtA: Double
    var omega0: Double, omega: Double, m0: Double   // rad
    var af0: Double, af1: Double

    /// Liest eine Almanachseite. `nearAbsolute`: ungefähre GPS-Zeit beim Empfang
    /// (absolute Sekunden) – legt die Woche der 8-Bit-Bezugszeit fest.
    init?(page sf: GPSSubframe, nearAbsolute: Double) {
        guard sf.bitsU(48, 2) == 1 else { return nil }
        let sv = Int(sf.bitsU(50, 6))
        switch sf.id {
        case 5 where (1...24).contains(sv), 4 where (25...32).contains(sv): break
        default: return nil
        }
        let p2 = { (n: Int) in pow(2.0, Double(n)) }
        let sc = GPSConst.pi
        prn = sv
        e = Double(sf.bitsU(56, 16)) * p2(-21)
        let toa = Double(sf.bitsU(72, 8)) * p2(12)
        i0 = (0.3 + Double(sf.bitsS(80, 16)) * p2(-19)) * sc
        omegaDot = Double(sf.bitsS(96, 16)) * p2(-38) * sc
        health = Int(sf.bitsU(112, 8))
        sqrtA = Double(sf.bitsU(120, 24)) * p2(-11)
        omega0 = Double(sf.bitsS(144, 24)) * p2(-23) * sc
        omega = Double(sf.bitsS(168, 24)) * p2(-23) * sc
        m0 = Double(sf.bitsS(192, 24)) * p2(-23) * sc
        let af0Raw = Int64(sf.bitsU(216, 8)) << 3 | Int64(sf.bitsU(235, 3))
        af0 = Double(af0Raw >= 1024 ? af0Raw - 2048 : af0Raw) * p2(-20)
        af1 = Double(sf.bitsS(224, 11)) * p2(-38)
        guard sqrtA > 5000, sqrtA < 5400, e < 0.05 else { return nil }   // Platzhalterseiten
        let week = ((nearAbsolute - toa) / GPSConst.weekSeconds).rounded()
        toaAbsolute = week * GPSConst.weekSeconds + toa
    }

    /// ECEF-Position zur absoluten GPS-Zeit `t` (Kepler ohne Störterme).
    func position(atAbsolute t: Double) -> SIMD3<Double> {
        let a = sqrtA * sqrtA
        let tk = t - toaAbsolute
        let n = (GPSConst.mu / (a * a * a)).squareRoot()
        let m = m0 + n * tk
        var ecc = m
        for _ in 0..<20 { ecc = m + e * sin(ecc) }
        let nu = atan2((1 - e * e).squareRoot() * sin(ecc), cos(ecc) - e)
        let u = nu + omega
        let r = a * (1 - e * cos(ecc))
        let toa = toaAbsolute.truncatingRemainder(dividingBy: GPSConst.weekSeconds)
        let node = omega0 + (omegaDot - GPSConst.omegaE) * tk - GPSConst.omegaE * toa
        let x = r * cos(u), y = r * sin(u)
        return SIMD3(x * cos(node) - y * cos(i0) * sin(node),
                     x * sin(node) + y * cos(i0) * cos(node),
                     y * sin(i0))
    }
}

/// Hilfsdaten für den nächsten Start (Warm-/Heißstart): Bahnen, letzte
/// Position, Quarzablage. Liegt als JSON in Application Support
/// (`GPS-Hilfsdaten.json`), nicht in den UserDefaults.
struct GPSAidingData: Sendable, Equatable, Codable {
    struct StoredEphemeris: Sendable, Equatable, Codable {
        var ephemeris: GPSEphemeris
        /// Volle GPS-Woche der Bezugszeit toe.
        var week: Int
        var toeAbsolute: Double { Double(week) * GPSConst.weekSeconds + ephemeris.toe }
    }

    var ephemerides: [StoredEphemeris] = []
    var almanac: [GPSAlmanac] = []
    /// Letzte Position (ECEF, m) und wann sie galt.
    var position: [Double]?
    var positionDate: Date?
    /// Trägerablage durch den Quarz des Empfängers (Hz bei L1), gemittelt.
    var clockOffsetHz: Double?
    var savedAt = Date()

    static let fileName = "GPS-Hilfsdaten.json"

    var ecef: SIMD3<Double>? {
        guard let p = position, p.count == 3 else { return nil }
        return SIMD3(p[0], p[1], p[2])
    }

    var isEmpty: Bool { ephemerides.isEmpty && almanac.isEmpty && position == nil && clockOffsetHz == nil }

    static func load(from url: URL) -> GPSAidingData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GPSAidingData.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Führt neue Daten mit älteren zusammen: je PRN die jüngste Bahn.
    func merged(over older: GPSAidingData) -> GPSAidingData {
        var out = self
        var eph = Dictionary(older.ephemerides.map { ($0.ephemeris.prn, $0) }, uniquingKeysWith: { a, _ in a })
        for e in ephemerides where (eph[e.ephemeris.prn]?.toeAbsolute ?? -.infinity) <= e.toeAbsolute { eph[e.ephemeris.prn] = e }
        out.ephemerides = eph.values.sorted { $0.ephemeris.prn < $1.ephemeris.prn }
        var alm = Dictionary(older.almanac.map { ($0.prn, $0) }, uniquingKeysWith: { a, _ in a })
        for a in almanac where (alm[a.prn]?.toaAbsolute ?? -.infinity) <= a.toaAbsolute { alm[a.prn] = a }
        out.almanac = alm.values.sorted { $0.prn < $1.prn }
        if out.position == nil { out.position = older.position; out.positionDate = older.positionDate }
        if out.clockOffsetHz == nil { out.clockOffsetHz = older.clockOffsetHz }
        return out
    }
}

/// Vorhersage: welche Satelliten über dem Horizont stehen und mit welchem
/// Doppler (ohne Quarzablage des Empfängers) – aus Ephemeride (bis 3 Tage
/// alt) oder Almanach.
enum GPSPredictor {
    struct Prediction: Sendable, Equatable {
        let prn: Int
        let elevation: Double      // Grad
        let dopplerHz: Double
    }

    /// Absolute GPS-Sekunden zu einem UTC-Zeitpunkt.
    static func gpsSeconds(_ date: Date, leapSeconds: Int = 18) -> Double {
        date.timeIntervalSince(GPSTime.epoch) + Double(leapSeconds)
    }

    /// Alle Satelliten mit Bahn, deren Höhe über `minElevation` (Grad) liegt.
    static func predict(at t: Double, rx: SIMD3<Double>, aiding: GPSAidingData,
                        minElevation: Double = -5) -> [Prediction] {
        var out: [Prediction] = []
        let eph = Dictionary(aiding.ephemerides.map { ($0.ephemeris.prn, $0) }, uniquingKeysWith: { a, _ in a })
        let alm = Dictionary(aiding.almanac.map { ($0.prn, $0) }, uniquingKeysWith: { a, _ in a })
        for prn in Set(eph.keys).union(alm.keys) {
            let position: (Double) -> SIMD3<Double>
            if let e = eph[prn], abs(t - e.toeAbsolute) < 3 * 86_400 {
                let tow = t - (t / GPSConst.weekSeconds).rounded(.down) * GPSConst.weekSeconds
                position = { e.ephemeris.position(at: tow + ($0 - t)) }
            } else if let a = alm[prn], a.health == 0 {   // ungesund gemeldete auslassen
                position = { a.position(atAbsolute: $0) }
            } else { continue }
            let p = position(t)
            let el = GPSGeo.azimuthElevation(rx: rx, sat: p).el * 180 / .pi
            guard el >= minElevation else { continue }
            let v = (position(t + 0.5) - position(t - 0.5))
            let los = p - rx
            let rangeRate = (v * los).sum() / (los * los).sum().squareRoot()
            out.append(Prediction(prn: prn, elevation: el, dopplerHz: -rangeRate / GPSConst.wavelength))
        }
        return out.sorted { $0.elevation > $1.elevation }
    }
}
