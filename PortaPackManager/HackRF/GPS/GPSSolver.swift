import Foundation

/// Messung eines Satelliten zu einer gemeinsamen Empfangsepoche.
struct GPSObservation: Sendable {
    let prn: Int
    /// Sendezeit laut Satellitenuhr (Sekunde der Woche).
    let transmitTime: Double
    /// Gemessene Trägerfrequenz (Doppler plus Empfänger-Quarzablage), Hz.
    var dopplerHz: Double = 0
    var cn0: Double = 0
}

/// Lage eines Satelliten in der Lösung.
struct GPSSatelliteGeometry: Sendable, Equatable {
    let prn: Int
    let azimuth: Double      // Grad
    let elevation: Double    // Grad
    let residual: Double     // m
}

/// Positions-, Geschwindigkeits- und Zeitlösung (PVT).
struct GPSSolution: Sendable, Equatable {
    var ecef: SIMD3<Double>
    var latitude: Double     // Grad
    var longitude: Double    // Grad
    var height: Double       // m über WGS-84-Ellipsoid
    /// Empfangszeit in GPS-Zeit (Sekunde der Woche), Uhrfehler herausgerechnet.
    var gpsTime: Double
    var clockBias: Double    // m (Empfängeruhr gegen die angenommene Empfangszeit)
    var velocityENU: SIMD3<Double>?    // m/s
    var clockDrift: Double?  // m/s
    var gdop: Double, pdop: Double, hdop: Double, vdop: Double, tdop: Double
    /// Mittlerer Restfehler der Pseudodistanzen (m), 0 bei genau 4 Satelliten.
    var rmsResidual: Double
    var satellites: [GPSSatelliteGeometry]

    var speed: Double? { velocityENU.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() } }
    /// Grobe horizontale Genauigkeit (1σ): HDOP · max(Restfehler, 3 m).
    var horizontalAccuracy: Double { hdop * max(rmsResidual, 3) }
    var verticalAccuracy: Double { vdop * max(rmsResidual, 3) }
}

/// Kleinste-Quadrate-Löser für Position und Uhrfehler (wie SoftGNSS `leastSquarePos`
/// bzw. RTKLIB `estpos`, ungewichtet).
enum GPSSolver {
    /// - Parameters:
    ///   - receiveTime: angenommene Empfangszeit (Sekunde der Woche); ihr Fehler
    ///     landet im Uhrfehler. Typisch: späteste Sendezeit + 75 ms.
    static func solve(_ observations: [GPSObservation], ephemerides: [Int: GPSEphemeris],
                      iono: GPSIonoUTC? = nil, receiveTime: Double,
                      initial: SIMD3<Double>? = nil, troposphere: Bool = true) -> GPSSolution? {
        struct Sat {
            let obs: GPSObservation
            let pos: SIMD3<Double>
            let vel: SIMD3<Double>
            let pseudorange: Double   // um die Satellitenuhr korrigiert
            let clockDrift: Double
        }
        var sats: [Sat] = []
        for o in observations {
            guard let eph = ephemerides[o.prn], eph.health == 0 else { continue }
            let dts = eph.clockBias(satelliteTime: o.transmitTime)
            let t = o.transmitTime - dts
            let rho = GPSConst.c * GPSEphemeris.timeDiff(receiveTime, o.transmitTime)
            sats.append(Sat(obs: o, pos: eph.position(at: t), vel: eph.velocity(at: t),
                            pseudorange: rho + GPSConst.c * dts, clockDrift: eph.clockDrift(at: t)))
        }
        guard sats.count >= 4 else { return nil }

        var x = initial ?? .zero
        var b = 0.0
        var rows: [[Double]] = []
        var residuals: [Double] = []
        var geometry: [GPSSatelliteGeometry] = []
        var converged = false
        for _ in 0..<12 {
            rows.removeAll(); residuals.removeAll(); geometry.removeAll()
            let plausible = (x * x).sum().squareRoot() > 6.0e6
            let g = GPSGeo.geodetic(x)
            for s in sats {
                var p = s.pos
                if plausible || (x * x).sum() > 0 {
                    let d = p - x
                    p = GPSGeo.rotateEarth(p, travelTime: (d * d).sum().squareRoot() / GPSConst.c)
                }
                let d = p - x
                let range = (d * d).sum().squareRoot()
                var corr = 0.0
                var az = 0.0, el = Double.pi / 2
                if plausible {
                    (az, el) = GPSGeo.azimuthElevation(rx: x, sat: p)
                    if troposphere { corr += GPSGeo.troposphere(lat: g.lat, height: g.height, elevation: el) }
                    if let iono {
                        corr += GPSGeo.klobuchar(iono, lat: g.lat, lon: g.lon, az: az, el: el,
                                                 tow: receiveTime - b / GPSConst.c)
                    }
                }
                let u = d / range
                rows.append([-u.x, -u.y, -u.z, 1])
                let res = s.pseudorange - corr - (range + b)
                residuals.append(res)
                geometry.append(GPSSatelliteGeometry(prn: s.obs.prn, azimuth: az * 180 / .pi,
                                                     elevation: el * 180 / .pi, residual: res))
            }
            guard let dx = leastSquares(rows, residuals) else { return nil }
            x += SIMD3(dx[0], dx[1], dx[2])
            b += dx[3]
            if (dx[0] * dx[0] + dx[1] * dx[1] + dx[2] * dx[2]).squareRoot() < 1e-4 { converged = true; break }
        }
        guard converged, let q = normalInverse(rows) else { return nil }
        let geo = GPSGeo.geodetic(x)
        guard geo.height > -1000, geo.height < 100_000 else { return nil }

        // DOP: Kovarianz ins lokale System drehen.
        let basis = GPSGeo.enuBasis(lat: geo.lat, lon: geo.lon)
        func qProject(_ a: SIMD3<Double>) -> Double {
            var sum = 0.0
            for i in 0..<3 { for j in 0..<3 { sum += a[i] * q[i][j] * a[j] } }
            return sum
        }
        let qe = qProject(basis.e), qn = qProject(basis.n), qu = qProject(basis.u)
        let tdop = q[3][3].squareRoot()
        let pdop = (q[0][0] + q[1][1] + q[2][2]).squareRoot()
        let n = Double(residuals.count)
        let rms = n > 4 ? ((residuals.map { $0 * $0 }.reduce(0, +)) / (n - 4)).squareRoot() : 0

        // Geschwindigkeit aus Doppler: −λ·f = (v_sat − v_rx)·u + c·(ḋt_rx − ḋt_sv).
        var velocity: SIMD3<Double>?
        var drift: Double?
        if sats.allSatisfy({ $0.obs.dopplerHz != 0 }) {
            var vrows: [[Double]] = []
            var vres: [Double] = []
            for s in sats {
                let p = GPSGeo.rotateEarth(s.pos, travelTime: ((s.pos - x) * (s.pos - x)).sum().squareRoot() / GPSConst.c)
                let d = p - x
                let u = d / (d * d).sum().squareRoot()
                let rate = -GPSConst.wavelength * s.obs.dopplerHz
                vrows.append([-u.x, -u.y, -u.z, 1])
                vres.append(rate - (s.vel * u).sum() + GPSConst.c * s.clockDrift)
            }
            if let v = leastSquares(vrows, vres) {
                let ve = SIMD3(v[0], v[1], v[2])
                velocity = SIMD3((basis.e * ve).sum(), (basis.n * ve).sum(), (basis.u * ve).sum())
                drift = v[3]
            }
        }

        return GPSSolution(ecef: x, latitude: geo.lat * 180 / .pi, longitude: geo.lon * 180 / .pi,
                           height: geo.height, gpsTime: receiveTime - b / GPSConst.c, clockBias: b,
                           velocityENU: velocity, clockDrift: drift,
                           gdop: (pdop * pdop + tdop * tdop).squareRoot(), pdop: pdop,
                           hdop: (qe + qn).squareRoot(), vdop: qu.squareRoot(), tdop: tdop,
                           rmsResidual: rms, satellites: geometry)
    }

    /// Lösung von (HᵀH)·x = Hᵀ·y für 4 Unbekannte.
    static func leastSquares(_ h: [[Double]], _ y: [Double]) -> [Double]? {
        guard let q = normalInverse(h) else { return nil }
        var hty = [Double](repeating: 0, count: 4)
        for (row, v) in zip(h, y) { for j in 0..<4 { hty[j] += row[j] * v } }
        return (0..<4).map { i in (0..<4).reduce(0) { $0 + q[i][$1] * hty[$1] } }
    }

    /// (HᵀH)⁻¹ per Gauß-Jordan; nil bei singulärer Geometrie.
    static func normalInverse(_ h: [[Double]]) -> [[Double]]? {
        var m = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 4)
        for row in h { for i in 0..<4 { for j in 0..<4 { m[i][j] += row[i] * row[j] } } }
        for i in 0..<4 { m[i][4 + i] = 1 }
        for col in 0..<4 {
            var pivot = col
            for r in col..<4 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            let p = m[col][col]
            for j in 0..<8 { m[col][j] /= p }
            for r in 0..<4 where r != col {
                let f = m[r][col]
                if f != 0 { for j in 0..<8 { m[r][j] -= f * m[col][j] } }
            }
        }
        return m.map { Array($0[4..<8]) }
    }
}
