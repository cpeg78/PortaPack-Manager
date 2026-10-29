import Foundation

/// Satellitenbahn und -uhr aus der Ephemeride (IS-GPS-200, Tabelle 20-IV;
/// Rechenweg wie RTKLIB `eph2pos`/`eph2clk`).
extension GPSEphemeris {
    /// Zeitdifferenz mit Wochenwechsel (IS-GPS-200: |tk| ≤ 302 400 s).
    static func timeDiff(_ t: Double, _ ref: Double) -> Double {
        var d = t - ref
        if d > 302_400 { d -= GPSConst.weekSeconds } else if d < -302_400 { d += GPSConst.weekSeconds }
        return d
    }

    /// Exzentrische Anomalie zur GPS-Zeit `t` (Sekunde der Woche).
    func eccentricAnomaly(at t: Double) -> Double {
        let a = sqrtA * sqrtA
        let tk = Self.timeDiff(t, toe)
        let n = (GPSConst.mu / (a * a * a)).squareRoot() + deltaN
        let m = m0 + n * tk
        var ecc = m
        for _ in 0..<30 {
            let next = ecc - (ecc - e * sin(ecc) - m) / (1 - e * cos(ecc))
            if abs(next - ecc) < 1e-13 { ecc = next; break }
            ecc = next
        }
        return ecc
    }

    /// Position im ECEF-System (WGS-84) zur GPS-Zeit `t` – der Sendezeit, also
    /// im Erdsystem dieses Augenblicks (Sagnac-Drehung macht der Löser).
    func position(at t: Double) -> SIMD3<Double> {
        let a = sqrtA * sqrtA
        let tk = Self.timeDiff(t, toe)
        let ecc = eccentricAnomaly(at: t)
        let sinE = sin(ecc), cosE = cos(ecc)
        let nu = atan2((1 - e * e).squareRoot() * sinE, cosE - e)
        let phi = nu + omega
        let sin2 = sin(2 * phi), cos2 = cos(2 * phi)
        let u = phi + cus * sin2 + cuc * cos2
        let r = a * (1 - e * cosE) + crs * sin2 + crc * cos2
        let inc = i0 + idot * tk + cis * sin2 + cic * cos2
        let x = r * cos(u), y = r * sin(u)
        let node = omega0 + (omegaDot - GPSConst.omegaE) * tk - GPSConst.omegaE * toe
        let sinO = sin(node), cosO = cos(node), cosI = cos(inc)
        return SIMD3(x * cosO - y * cosI * sinO,
                     x * sinO + y * cosI * cosO,
                     y * sin(inc))
    }

    /// Geschwindigkeit (ECEF, m/s) per zentraler Differenz – genügt für den
    /// Doppler-Ansatz der Empfängergeschwindigkeit.
    func velocity(at t: Double) -> SIMD3<Double> {
        (position(at: t + 0.5) - position(at: t - 0.5))
    }

    /// Uhrfehler des Satelliten für L1 C/A (s) zur GPS-Zeit `t`:
    /// af0 + af1·Δt + af2·Δt² + relativistische Korrektur − TGD.
    func clockBias(at t: Double) -> Double {
        let dt = Self.timeDiff(t, toc)
        let rel = GPSConst.relativisticF * e * sqrtA * sin(eccentricAnomaly(at: t))
        return af0 + af1 * dt + af2 * dt * dt + rel - tgd
    }

    /// Uhrfehler zur Sendezeit in Satellitenzeit (`tsv`): IS-GPS-200 rechnet
    /// mit t = tsv − Δtsv, darum einmal nachiterieren.
    func clockBias(satelliteTime tsv: Double) -> Double {
        var dt = clockBias(at: tsv)
        dt = clockBias(at: tsv - dt)
        return dt
    }

    /// Uhrdrift (s/s), für die Geschwindigkeitslösung.
    func clockDrift(at t: Double) -> Double {
        af1 + 2 * af2 * Self.timeDiff(t, toc)
    }
}

/// Koordinatenumrechnungen und Ausbreitungsmodelle.
enum GPSGeo {
    static let a = 6_378_137.0
    static let f = 1 / 298.257223563
    static var e2: Double { f * (2 - f) }

    /// ECEF → (Breite, Länge in Radiant, Höhe über Ellipsoid in m) – wie RTKLIB `ecef2pos`.
    static func geodetic(_ r: SIMD3<Double>) -> (lat: Double, lon: Double, height: Double) {
        let r2 = r.x * r.x + r.y * r.y
        var z = r.z, zk = 0.0, v = a
        var iterations = 0
        while abs(z - zk) >= 1e-4 && iterations < 20 {
            zk = z
            let sinp = z / (r2 + z * z).squareRoot()
            v = a / (1 - e2 * sinp * sinp).squareRoot()
            z = r.z + v * e2 * sinp
            iterations += 1
        }
        let lat = r2 > 1e-12 ? atan(z / r2.squareRoot()) : (r.z > 0 ? .pi / 2 : -.pi / 2)
        let lon = r2 > 1e-12 ? atan2(r.y, r.x) : 0
        return (lat, lon, (r2 + z * z).squareRoot() - v)
    }

    /// (Breite, Länge in Radiant, Höhe) → ECEF.
    static func ecef(lat: Double, lon: Double, height: Double) -> SIMD3<Double> {
        let sinp = sin(lat), cosp = cos(lat)
        let v = a / (1 - e2 * sinp * sinp).squareRoot()
        return SIMD3((v + height) * cosp * cos(lon), (v + height) * cosp * sin(lon), (v * (1 - e2) + height) * sinp)
    }

    /// Zeilen der Drehmatrix ECEF → ENU (Ost, Nord, Oben).
    static func enuBasis(lat: Double, lon: Double) -> (e: SIMD3<Double>, n: SIMD3<Double>, u: SIMD3<Double>) {
        let sp = sin(lat), cp = cos(lat), sl = sin(lon), cl = cos(lon)
        return (SIMD3(-sl, cl, 0), SIMD3(-sp * cl, -sp * sl, cp), SIMD3(cp * cl, cp * sl, sp))
    }

    /// Azimut und Elevation (Radiant) eines Punkts `sat` vom Ort `rx` aus.
    static func azimuthElevation(rx: SIMD3<Double>, sat: SIMD3<Double>) -> (az: Double, el: Double) {
        let g = geodetic(rx)
        let b = enuBasis(lat: g.lat, lon: g.lon)
        let d = sat - rx
        let len = (d * d).sum().squareRoot()
        guard len > 0 else { return (0, .pi / 2) }
        let u = d / len
        let e = (b.e * u).sum(), n = (b.n * u).sum(), up = (b.u * u).sum()
        var az = atan2(e, n)
        if az < 0 { az += 2 * .pi }
        return (az, asin(max(-1, min(1, up))))
    }

    /// Troposphäre nach Saastamoinen mit Normatmosphäre (RTKLIB `tropmodel`, Feuchte 0,7).
    static func troposphere(lat: Double, height: Double, elevation: Double) -> Double {
        guard height > -100, height < 10_000, elevation > 0 else { return 0 }
        let hgt = max(height, 0)
        let pres = 1013.25 * pow(1 - 2.2557e-5 * hgt, 5.2568)
        let temp = 15.0 - 6.5e-3 * hgt + 273.16
        let e = 6.108 * 0.7 * exp((17.15 * temp - 4684) / (temp - 38.45))
        let z = .pi / 2 - elevation
        let trph = 0.0022768 * pres / (1 - 0.00266 * cos(2 * lat) - 0.00028 * hgt / 1e3) / cos(z)
        let trpw = 0.002277 * (1255 / temp + 0.05) * e / cos(z)
        return trph + trpw
    }

    /// Ionosphäre nach Klobuchar (IS-GPS-200 20.3.3.5.2.5; RTKLIB `ionmodel`), in Metern auf L1.
    static func klobuchar(_ ion: GPSIonoUTC, lat: Double, lon: Double, az: Double, el: Double, tow: Double) -> Double {
        guard el > 0 else { return 0 }
        let sc = GPSConst.pi
        let psi = 0.0137 / (el / sc + 0.11) - 0.022
        var phi = lat / sc + psi * cos(az)
        phi = max(-0.416, min(0.416, phi))
        let lam = lon / sc + psi * sin(az) / cos(phi * sc)
        phi += 0.064 * cos((lam - 1.617) * sc)
        var tt = 43_200 * lam + tow
        tt -= floor(tt / 86_400) * 86_400
        let f = 1 + 16 * pow(0.53 - el / sc, 3)
        var amp = ion.alpha[0] + phi * (ion.alpha[1] + phi * (ion.alpha[2] + phi * ion.alpha[3]))
        var per = ion.beta[0] + phi * (ion.beta[1] + phi * (ion.beta[2] + phi * ion.beta[3]))
        amp = max(amp, 0)
        per = max(per, 72_000)
        let x = 2 * sc * (tt - 50_400) / per
        let delay = abs(x) < 1.57 ? 5e-9 + amp * (1 + x * x * (-0.5 + x * x / 24)) : 5e-9
        return GPSConst.c * f * delay
    }

    /// Sagnac: Satellitenposition zur Sendezeit ins Erdsystem des Empfangs
    /// drehen (Erde dreht sich während der Laufzeit τ um ΩE·τ).
    static func rotateEarth(_ p: SIMD3<Double>, travelTime: Double) -> SIMD3<Double> {
        let w = GPSConst.omegaE * travelTime
        return SIMD3(cos(w) * p.x + sin(w) * p.y, -sin(w) * p.x + cos(w) * p.y, p.z)
    }
}

/// GPS-Zeit in Datum umrechnen.
enum GPSTime {
    /// 6. Januar 1980, 00:00:00 UTC.
    static let epoch = Date(timeIntervalSince1970: 315_964_800)

    /// Volle Wochennummer aus der 10-Bit-Zahl, nächstliegend zu `reference`.
    static func fullWeek(_ week10: Int, near reference: Date = Date()) -> Int {
        let refWeek = Int(reference.timeIntervalSince(epoch) / GPSConst.weekSeconds)
        var best = week10
        while best + 1024 <= refWeek + 512 { best += 1024 }
        return best
    }

    /// UTC-Zeitpunkt zu GPS-Woche und Sekunde (Schaltsekunden abgezogen).
    static func utc(week: Int, tow: Double, leapSeconds: Int) -> Date {
        epoch.addingTimeInterval(Double(week) * GPSConst.weekSeconds + tow - Double(leapSeconds))
    }
}
