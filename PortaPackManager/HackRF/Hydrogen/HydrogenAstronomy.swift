import Foundation
import simd

/// Koordinaten und Geschwindigkeiten für die 21-cm-Linie.
///
/// Genauigkeit: Sternzeit IAU-82 (wie SGP4), Präzession IAU-1976, ohne
/// Nutation und Aberration (< 0,01°). Erdbahn aus der Sonnenlänge des
/// Astronomical Almanac mit Exzentrizität (≈ 0,05 km/s), Erddrehung auf
/// Meereshöhe, Sonnenbewegung gegen das LSR nach dem Standardwert
/// (20 km/s Richtung α = 18ʰ03ᵐ50,29ˢ, δ = +30°00′16,8″, J2000).
/// Für Schüsseln mit einigen Grad Keulenbreite ist das weit genauer als nötig.
enum HydrogenAstronomy {
    /// Ruhefrequenz der Wasserstofflinie (Hz).
    static let restFrequencyHz = 1_420_405_751.768
    static let speedOfLight = 299_792.458   // km/s
    static let rad = Double.pi / 180

    // MARK: Doppler (Radiodefinition)

    /// Radialgeschwindigkeit (km/s, positiv = entfernt sich) zu einer beobachteten Frequenz.
    static func velocity(frequencyHz f: Double) -> Double {
        speedOfLight * (restFrequencyHz - f) / restFrequencyHz
    }

    static func frequency(velocity v: Double) -> Double {
        restFrequencyHz * (1 - v / speedOfLight)
    }

    // MARK: Koordinaten

    /// Rektaszension/Deklination in Grad.
    struct Equatorial: Equatable, Sendable {
        var ra: Double
        var dec: Double
    }

    /// Galaktische Länge/Breite in Grad.
    struct Galactic: Equatable, Sendable {
        var l: Double
        var b: Double
    }

    struct Horizontal: Equatable, Sendable {
        var azimuth: Double     // von Nord über Ost
        var elevation: Double
    }

    static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }

    /// Örtliche Sternzeit (rad).
    static func localSiderealTime(_ date: Date, longitude: Double) -> Double {
        var lst = SGP4.gmst(julianDay: julianDay(date)) + longitude * rad
        lst = lst.truncatingRemainder(dividingBy: 2 * .pi)
        return lst < 0 ? lst + 2 * .pi : lst
    }

    static func vector(_ e: Equatorial) -> SIMD3<Double> {
        SIMD3(cos(e.dec * rad) * cos(e.ra * rad), cos(e.dec * rad) * sin(e.ra * rad), sin(e.dec * rad))
    }

    static func equatorial(_ v: SIMD3<Double>) -> Equatorial {
        var ra = atan2(v.y, v.x) / rad
        if ra < 0 { ra += 360 }
        return Equatorial(ra: ra, dec: asin(max(-1, min(1, v.z / simd_length(v)))) / rad)
    }

    /// Azimut/Höhe → Äquatorkoordinaten des Datums.
    static func equatorialOfDate(_ h: Horizontal, latitude: Double, longitude: Double, date: Date) -> Equatorial {
        let a = h.azimuth * rad, el = h.elevation * rad, phi = latitude * rad
        let sinDec = sin(phi) * sin(el) + cos(phi) * cos(el) * cos(a)
        let dec = asin(max(-1, min(1, sinDec)))
        let hourAngle = atan2(-sin(a) * cos(el), cos(phi) * sin(el) - sin(phi) * cos(el) * cos(a))
        var ra = (localSiderealTime(date, longitude: longitude) - hourAngle) / rad
        ra = ra.truncatingRemainder(dividingBy: 360)
        if ra < 0 { ra += 360 }
        return Equatorial(ra: ra, dec: dec / rad)
    }

    /// Äquatorkoordinaten des Datums → Azimut/Höhe.
    static func horizontal(_ e: Equatorial, latitude: Double, longitude: Double, date: Date) -> Horizontal {
        let hourAngle = localSiderealTime(date, longitude: longitude) - e.ra * rad
        let dec = e.dec * rad, phi = latitude * rad
        let el = asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(hourAngle))
        var az = atan2(-cos(dec) * sin(hourAngle), sin(dec) * cos(phi) - cos(dec) * cos(hourAngle) * sin(phi)) / rad
        if az < 0 { az += 360 }
        return Horizontal(azimuth: az, elevation: el / rad)
    }

    /// Präzessionsmatrix J2000 → Datum (IAU 1976: ζ, z, θ).
    static func precessionMatrix(_ date: Date) -> simd_double3x3 {
        let t = (julianDay(date) - 2_451_545) / 36_525
        let arcsec = rad / 3600
        let zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) * arcsec
        let z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) * arcsec
        let theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) * arcsec
        func r3(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(cos(a), sin(a), 0), SIMD3(-sin(a), cos(a), 0), SIMD3(0, 0, 1)])
        }
        func r2(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(cos(a), 0, -sin(a)), SIMD3(0, 1, 0), SIMD3(sin(a), 0, cos(a))])
        }
        return r3(-z) * r2(theta) * r3(-zeta)
    }

    static func toJ2000(_ e: Equatorial, date: Date) -> Equatorial {
        equatorial(precessionMatrix(date).transpose * vector(e))
    }

    static func fromJ2000(_ e: Equatorial, date: Date) -> Equatorial {
        equatorial(precessionMatrix(date) * vector(e))
    }

    /// Äquator J2000 → galaktisch (Matrix nach Hipparcos/ESA 1997).
    static let galacticMatrix = simd_double3x3(rows: [
        SIMD3(-0.0548755604162154, -0.8734370902348850, -0.4838350155487132),
        SIMD3(0.4941094278755837, -0.4448296299600112, 0.7469822444972189),
        SIMD3(-0.8676661490190047, -0.1980763734312015, 0.4559837761750669),
    ])

    static func galactic(_ e: Equatorial) -> Galactic {
        let g = galacticMatrix * vector(e)
        var l = atan2(g.y, g.x) / rad
        if l < 0 { l += 360 }
        return Galactic(l: l, b: asin(max(-1, min(1, g.z))) / rad)
    }

    static func equatorialJ2000(_ g: Galactic) -> Equatorial {
        let v = SIMD3(cos(g.b * rad) * cos(g.l * rad), cos(g.b * rad) * sin(g.l * rad), sin(g.b * rad))
        return equatorial(galacticMatrix.transpose * v)
    }

    // MARK: Ruhesystem (LSR)

    struct LSRCorrection: Equatable, Sendable {
        var rotation: Double
        var orbit: Double
        var solar: Double
        /// Zu addieren: v_LSR = v_topozentrisch + total.
        var total: Double { rotation + orbit + solar }
    }

    /// Sonnenbewegung gegen das LSR: 20 km/s Richtung Apex (J2000).
    static let solarApex = Equatorial(ra: (18 + 3.0 / 60 + 50.29 / 3600) * 15, dec: 30 + 0.0 / 60 + 16.8 / 3600)
    static let solarSpeed = 20.0

    /// Geschwindigkeit der Erde (Bahn) in Äquatorkoordinaten des Datums (km/s).
    static func earthOrbitalVelocity(_ date: Date) -> SIMD3<Double> {
        let n = julianDay(date) - 2_451_545
        let l = (280.460 + 0.9856474 * n) * rad
        let g = (357.528 + 0.9856003 * n) * rad
        let lambda = l + (1.915 * sin(g) + 0.020 * sin(2 * g)) * rad      // Sonnenlänge
        let e = 0.016709 - 0.000000001151 * n
        let perihelion = (102.937 + 0.0000470935 * n) * rad              // Länge des Perihels der Erde
        let v = 29.7859 / (1 - e * e).squareRoot()
        // Erde bei λ+180°: v = V·(sin λ − e·sin ϖ, −cos λ + e·cos ϖ) in der Ekliptik.
        let x = v * (sin(lambda) - e * sin(perihelion))
        let y = v * (-cos(lambda) + e * cos(perihelion))
        let eps = (23.439 - 0.0000004 * n) * rad
        return SIMD3(x, y * cos(eps), y * sin(eps))
    }

    /// Korrektur topozentrisch → LSR für eine Richtung (J2000) an einem Ort.
    static func lsrCorrection(j2000 e: Equatorial, date: Date, latitude: Double, longitude: Double) -> LSRCorrection {
        let ofDate = fromJ2000(e, date: date)
        let n = vector(ofDate)
        let hourAngle = localSiderealTime(date, longitude: longitude) - ofDate.ra * rad
        let rotation = -0.46510 * cos(latitude * rad) * cos(ofDate.dec * rad) * sin(hourAngle)
        let orbit = simd_dot(earthOrbitalVelocity(date), n)
        let solar = solarSpeed * simd_dot(vector(solarApex), vector(e))
        return LSRCorrection(rotation: rotation, orbit: orbit, solar: solar)
    }

    /// Alles zu einer Ausrichtung auf einmal.
    struct Pointing: Equatable, Sendable {
        var j2000: Equatorial
        var galactic: Galactic
        var lsr: LSRCorrection
    }

    static func pointing(_ h: Horizontal, latitude: Double, longitude: Double, date: Date) -> Pointing {
        let ofDate = equatorialOfDate(h, latitude: latitude, longitude: longitude, date: date)
        let j2000 = toJ2000(ofDate, date: date)
        return Pointing(j2000: j2000, galactic: galactic(j2000),
                        lsr: lsrCorrection(j2000: j2000, date: date, latitude: latitude, longitude: longitude))
    }

    /// Höchster Punkt der galaktischen Ebene (b = 0) gerade jetzt – Hilfe beim Ausrichten.
    static func highestGalacticPlanePoint(latitude: Double, longitude: Double, date: Date) -> (l: Double, horizontal: Horizontal) {
        var best: (l: Double, horizontal: Horizontal) = (0, Horizontal(azimuth: 0, elevation: -90))
        for l in stride(from: 0.0, to: 360, by: 2) {
            let e = fromJ2000(equatorialJ2000(Galactic(l: l, b: 0)), date: date)
            let h = horizontal(e, latitude: latitude, longitude: longitude, date: date)
            if h.elevation > best.horizontal.elevation { best = (l, h) }
        }
        return best
    }

    /// Wo steht ein Punkt (l, b) jetzt?
    static func horizontal(_ g: Galactic, latitude: Double, longitude: Double, date: Date) -> Horizontal {
        horizontal(fromJ2000(equatorialJ2000(g), date: date), latitude: latitude, longitude: longitude, date: date)
    }
}
