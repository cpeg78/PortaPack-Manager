import Foundation

/// Zwei-Zeilen-Bahnelemente (TLE) eines Satelliten.
struct TLE: Sendable, Equatable {
    let name: String
    let catalogNumber: Int
    /// Epoche als julianisches Datum (UTC).
    let epochJD: Double
    let bstar: Double
    let inclination: Double      // rad
    let raan: Double             // rad
    let eccentricity: Double
    let argumentOfPerigee: Double // rad
    let meanAnomaly: Double      // rad
    /// Mittlere Bewegung in rad/min (Kozai).
    let meanMotion: Double
    let line1: String
    let line2: String

    var epoch: Date { Date(timeIntervalSince1970: (epochJD - 2_440_587.5) * 86_400) }

    init?(name: String, line1: String, line2: String) {
        let l1 = Array(line1), l2 = Array(line2)
        guard l1.count >= 69, l2.count >= 69, l1[0] == "1", l2[0] == "2" else { return nil }
        func field(_ chars: [Character], _ from: Int, _ to: Int) -> String {
            String(chars[from..<to]).trimmingCharacters(in: .whitespaces)
        }
        /// „ 14498-4“ → 0.14498e-4 (angenommene Dezimalstelle vorn).
        func exponential(_ text: String) -> Double? {
            var t = text.replacingOccurrences(of: " ", with: "")
            guard !t.isEmpty else { return 0 }
            var sign = 1.0
            if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
            guard let split = t.lastIndex(where: { $0 == "-" || $0 == "+" }), split != t.startIndex,
                  let mantissa = Double("0." + t[..<split]), let exponent = Int(t[split...]) else { return nil }
            return sign * mantissa * pow(10, Double(exponent))
        }
        guard let number = Int(field(l1, 2, 7)),
              let year = Int(field(l1, 18, 20)), let day = Double(field(l1, 20, 32)),
              let bstar = exponential(field(l1, 53, 61)),
              let incl = Double(field(l2, 8, 16)), let raan = Double(field(l2, 17, 25)),
              let ecc = Double("0." + field(l2, 26, 33)), let argp = Double(field(l2, 34, 42)),
              let mo = Double(field(l2, 43, 51)), let n = Double(field(l2, 52, 63)) else { return nil }
        let fullYear = year < 57 ? 2000 + year : 1900 + year
        self.name = name.trimmingCharacters(in: .whitespaces)
        catalogNumber = number
        epochJD = Self.julianDay(year: fullYear, month: 1, day: 1) - 1 + day
        self.bstar = bstar
        let rad = Double.pi / 180
        inclination = incl * rad
        self.raan = raan * rad
        eccentricity = ecc
        argumentOfPerigee = argp * rad
        meanAnomaly = mo * rad
        meanMotion = n * 2 * .pi / 1440
        self.line1 = line1
        self.line2 = line2
    }

    /// Liest Dreizeiler (Name, Zeile 1, Zeile 2) wie von CelesTrak; Zweizeiler ohne Namen gehen auch.
    static func parse(_ text: String) -> [TLE] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result: [TLE] = []
        var i = 0
        while i < lines.count {
            if i + 1 < lines.count, lines[i].hasPrefix("1 "), let tle = TLE(name: "", line1: lines[i], line2: lines[i + 1]) {
                result.append(tle); i += 2
            } else if i + 2 < lines.count, let tle = TLE(name: lines[i], line1: lines[i + 1], line2: lines[i + 2]) {
                result.append(tle); i += 3
            } else {
                i += 1
            }
        }
        return result
    }

    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        // Vallado `jday` für 00:00 UTC.
        367.0 * Double(year) - floor(7 * (Double(year) + floor(Double(month + 9) / 12)) * 0.25)
            + floor(275 * Double(month) / 9) + Double(day) + 1_721_013.5
    }

    static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }
}

/// SGP4 nach Vallado („Revisiting Spacetrack Report #3“, 2006), nur der
/// erdnahe Zweig (Umlauf < 225 min – alle Wettersatelliten im LEO), WGS-72.
/// Ergebnis im TEME-System in km bzw. km/s.
struct SGP4: Sendable {
    // WGS-72
    static let mu = 398_600.8
    static let earthRadius = 6378.135
    static let xke = 60 / (earthRadius * earthRadius * earthRadius / mu).squareRoot()
    static let j2 = 0.001082616
    static let j3 = -0.00000253881
    static let j4 = -0.00000165597
    static let j3oj2 = j3 / j2

    enum Failure: Error { case deepSpace, decayed }

    let tle: TLE
    private let no, ecco, inclo, argpo, nodeo, mo, bstar: Double
    private let isimp: Bool
    private let con41, x1mth2, x7thm1, cc1, cc4, cc5, d2, d3, d4, delmo, eta, sinmao: Double
    private let argpdot, mdot, nodedot, nodecf, omgcof, xmcof, t2cof, t3cof, t4cof, t5cof, xlcof, aycof: Double

    init(_ tle: TLE) throws {
        self.tle = tle
        ecco = tle.eccentricity; inclo = tle.inclination; argpo = tle.argumentOfPerigee
        nodeo = tle.raan; mo = tle.meanAnomaly; bstar = tle.bstar
        let xke = Self.xke, j2 = Self.j2, j4 = Self.j4, j3oj2 = Self.j3oj2, r = Self.earthRadius
        let x2o3 = 2.0 / 3.0

        // initl
        let eccsq = ecco * ecco, omeosq = 1 - eccsq, rteosq = omeosq.squareRoot()
        let cosio = cos(inclo), cosio2 = cosio * cosio
        let ak = pow(xke / tle.meanMotion, x2o3)
        let d1 = 0.75 * j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        let no = tle.meanMotion / (1 + del)
        self.no = no
        let ao = pow(xke / no, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecco)
        guard 2 * .pi / no < 225 else { throw Failure.deepSpace }
        guard rp >= 1 else { throw Failure.decayed }

        // sgp4init
        let ss = 78 / r + 1
        let qzms2t = pow((120 - 78) / r, 4)
        isimp = rp < 220 / r + 1
        var sfour = ss, qzms24 = qzms2t
        let perige = (rp - 1) * r
        if perige < 156 {
            sfour = perige < 98 ? 20 : perige - 78
            qzms24 = pow((120 - sfour) / r, 4)
            sfour = sfour / r + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta, eeta = ecco * eta
        let psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * no * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
            + 0.375 * j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        cc1 = bstar * cc2
        let cc3 = ecco > 1e-4 ? -2 * coef * tsi * j3oj2 * no * sinio / ecco : 0
        x1mth2 = 1 - cosio2
        cc4 = 2 * no * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + ecco * (0.5 + 2 * etasq)
            - j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
                + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argpo)))
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * no
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * no
        mdot = no + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4)
            + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = ecco > 1e-4 ? -x2o3 * coef * bstar / eeta : 0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        xlcof = abs(cosio + 1) > 1.5e-12
            ? -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio)
            : -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        aycof = -0.5 * j3oj2 * sinio
        delmo = pow(1 + eta * cos(mo), 3)
        sinmao = sin(mo)
        x7thm1 = 7 * cosio2 - 1
        if !isimp {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        } else {
            d2 = 0; d3 = 0; d4 = 0; t3cof = 0; t4cof = 0; t5cof = 0
        }
    }

    /// Position (km) und Geschwindigkeit (km/s) im TEME-System, `minutes` nach der Epoche.
    func propagate(minutes t: Double) throws -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
        let xke = Self.xke, j2 = Self.j2, twoPi = 2 * Double.pi
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf, mm = xmdf
        let t2 = t * t
        let nodem0 = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2
        if !isimp {
            let delomg = omgcof * t
            let delm = xmcof * (pow(1 + eta * cos(xmdf), 3) - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t, t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe += bstar * cc5 * (sin(mm) - sinmao)
            templ += t3cof * t3 + t4 * (t4cof + t * t5cof)
        }
        let am = pow(xke / no, 2.0 / 3.0) * tempa * tempa
        let nm = xke / pow(am, 1.5)
        var em = ecco - tempe
        guard em < 1, em >= -0.001, am >= 0.95 else { throw Failure.decayed }
        if em < 1e-6 { em = 1e-6 }
        mm += no * templ
        var xlm = mm + argpm + nodem0
        let nodem = nodem0.truncatingRemainder(dividingBy: twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twoPi)

        let sinip = sin(inclo), cosip = cos(inclo)
        let axnl = em * cos(argpm)
        var temp = 1 / (am * (1 - em * em))
        let aynl = em * sin(argpm) + temp * aycof
        let xl = mm + argpm + nodem + temp * xlcof * axnl

        // Kepler-Gleichung
        let u = (xl - nodem).truncatingRemainder(dividingBy: twoPi)
        var eo1 = u, tem5 = 9999.0, ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12 && ktr <= 10 {
            sineo1 = sin(eo1); coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        guard pl >= 0 else { throw Failure.decayed }
        let rl = am * (1 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1 - el2).squareRoot()
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su -= 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosip * sin2u
        let xinc = inclo + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / xke
        guard mrt >= 1 else { throw Failure.decayed }

        let sinsu = sin(su), cossu = cos(su), snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi, xmy = cnod * cosi
        let uvec = SIMD3(xmx * sinsu + cnod * cossu, xmy * sinsu + snod * cossu, sini * sinsu)
        let vvec = SIMD3(xmx * cossu - cnod * sinsu, xmy * cossu - snod * sinsu, sini * cossu)
        let vkmpersec = Self.earthRadius * xke / 60
        return (mrt * uvec * Self.earthRadius, (mvt * uvec + rvdot * vvec) * vkmpersec)
    }

    func propagate(to date: Date) throws -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
        try propagate(minutes: (TLE.julianDay(date) - tle.epochJD) * 1440)
    }

    /// Greenwich-Sternzeit (rad) nach IAU-82, wie Vallado `gstime`.
    static func gmst(julianDay jd: Double) -> Double {
        let t = (jd - 2_451_545) / 36_525
        var temp = -6.2e-6 * t * t * t + 0.093104 * t * t + (876_600 * 3600 + 8_640_184.812866) * t + 67_310.54841
        temp = (temp * .pi / 180 / 240).truncatingRemainder(dividingBy: 2 * .pi)
        return temp < 0 ? temp + 2 * .pi : temp
    }
}

/// Beobachtungsort und Blickwinkel zu einem Satelliten.
struct GroundStation: Sendable, Equatable {
    var latitude: Double   // Grad
    var longitude: Double  // Grad
    var altitudeKm: Double = 0

    /// Erdfeste Position (WGS-84) in km.
    var ecef: SIMD3<Double> {
        let a = 6378.137, f = 1 / 298.257223563, e2 = f * (2 - f)
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        let n = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
        return SIMD3((n + altitudeKm) * cos(lat) * cos(lon),
                     (n + altitudeKm) * cos(lat) * sin(lon),
                     (n * (1 - e2) + altitudeKm) * sin(lat))
    }

    /// Höhe über dem Horizont und Azimut (Grad) einer TEME-Position.
    func lookAngles(teme: SIMD3<Double>, date: Date) -> (elevation: Double, azimuth: Double, rangeKm: Double) {
        let g = SGP4.gmst(julianDay: TLE.julianDay(date))
        let x = teme.x * cos(g) + teme.y * sin(g)
        let y = -teme.x * sin(g) + teme.y * cos(g)
        let d = SIMD3(x, y, teme.z) - ecef
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        let east = -sin(lon) * d.x + cos(lon) * d.y
        let north = -sin(lat) * cos(lon) * d.x - sin(lat) * sin(lon) * d.y + cos(lat) * d.z
        let up = cos(lat) * cos(lon) * d.x + cos(lat) * sin(lon) * d.y + sin(lat) * d.z
        let range = (d * d).sum().squareRoot()
        var azimuth = atan2(east, north) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        return (asin(up / range) * 180 / .pi, azimuth, range)
    }

    /// Sonnenhöhe in Grad (Näherung nach dem Astronomical Almanac, ±0,1°).
    func sunElevation(at date: Date) -> Double {
        let n = TLE.julianDay(date) - 2_451_545
        let rad = Double.pi / 180
        let l = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let lambda = (l + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let epsilon = (23.439 - 0.0000004 * n) * rad
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let dec = asin(sin(epsilon) * sin(lambda))
        let hourAngle = SGP4.gmst(julianDay: TLE.julianDay(date)) + longitude * rad - ra
        let lat = latitude * rad
        return asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hourAngle)) / rad
    }
}
