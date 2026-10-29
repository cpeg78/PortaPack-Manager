import Foundation
import Testing
@testable import PortaPackManager

@Suite("Wasserstofflinie")
struct HydrogenTests {
    typealias Astro = HydrogenAstronomy

    private struct LCG {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(1e-12, uniform()), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    private static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).truncatingRemainder(dividingBy: 360)
        return abs(d > 180 ? d - 360 : d < -180 ? d + 360 : d)
    }

    // MARK: Koordinaten

    @Test("Galaktisches Zentrum (Sgr A*) liegt bei l ≈ 0, b ≈ 0")
    func galacticCenter() {
        let g = Astro.galactic(.init(ra: 266.41683, dec: -29.00781))   // Sgr A*, J2000
        #expect(angleDiff(g.l, 0) < 0.1, "l = \(g.l)")
        #expect(abs(g.b) < 0.1, "b = \(g.b)")
        let pole = Astro.galactic(.init(ra: 192.85948, dec: 27.12825))
        #expect(abs(pole.b - 90) < 0.001)
        // Cygnus A: l = 76,19°, b = +5,76°
        let cyg = Astro.galactic(.init(ra: 299.86815, dec: 40.73392))
        #expect(angleDiff(cyg.l, 76.19) < 0.05 && abs(cyg.b - 5.76) < 0.05, "\(cyg)")
        let back = Astro.equatorialJ2000(.init(l: 30, b: -2))
        let again = Astro.galactic(back)
        #expect(angleDiff(again.l, 30) < 1e-9 && abs(again.b + 2) < 1e-9)
    }

    @Test("Sternzeit zur Epoche J2000.0 und Präzession")
    func siderealAndPrecession() {
        let j2000 = Date(timeIntervalSince1970: (2_451_545.0 - 2_440_587.5) * 86_400)
        #expect(angleDiff(Astro.localSiderealTime(j2000, longitude: 0) / Astro.rad, 280.46062) < 0.001)
        // Rund 26 Jahre Präzession: ≈ 50″/Jahr in Länge, am Frühlingspunkt ≈ 0,36° in α.
        let date = Self.date("2026-01-01T00:00:00Z")
        let p = Astro.fromJ2000(.init(ra: 0, dec: 0), date: date)
        #expect(abs(p.ra - 0.334) < 0.01, "α = \(p.ra)")
        #expect(abs(p.dec - 0.145) < 0.01, "δ = \(p.dec)")
        let back = Astro.toJ2000(p, date: date)
        #expect(angleDiff(back.ra, 0) < 1e-9 && abs(back.dec) < 1e-9)
    }

    @Test("Azimut/Elevation → galaktische Koordinaten (Zentrum über dem Horizont)")
    func pointingToGalacticCenter() {
        let date = Self.date("2026-07-15T21:30:00Z")
        let lat = 48.0, lon = 11.0
        let h = Astro.horizontal(Astro.Galactic(l: 0, b: 0), latitude: lat, longitude: lon, date: date)
        // Mitte Juli um 23:30 MESZ steht das Zentrum tief im Süden.
        #expect(h.elevation > 5 && h.elevation < 20, "El = \(h.elevation)")
        #expect(abs(h.azimuth - 180) < 25, "Az = \(h.azimuth)")
        let p = Astro.pointing(h, latitude: lat, longitude: lon, date: date)
        #expect(angleDiff(p.galactic.l, 0) < 0.01, "l = \(p.galactic.l)")
        #expect(abs(p.galactic.b) < 0.01, "b = \(p.galactic.b)")
        // Zenit = Deklination gleich Breite.
        let zenith = Astro.equatorialOfDate(.init(azimuth: 0, elevation: 90), latitude: lat, longitude: lon, date: date)
        #expect(abs(zenith.dec - lat) < 1e-6)
        #expect(angleDiff(zenith.ra, Astro.localSiderealTime(date, longitude: lon) / Astro.rad) < 1e-6)
    }

    @Test("LSR-Korrektur: Sonnenbewegung, Erdbahn, Erddrehung")
    func lsrComponents() {
        let date = Self.date("2026-03-20T14:46:00Z")   // Frühlingsanfang: Sonne bei λ = 0
        // Sonnenapex: +20 km/s, Gegenrichtung −20 km/s.
        let apex = Astro.lsrCorrection(j2000: Astro.solarApex, date: date, latitude: 0, longitude: 0)
        #expect(abs(apex.solar - 20) < 1e-9)
        let anti = Astro.lsrCorrection(j2000: .init(ra: Astro.solarApex.ra - 180, dec: -Astro.solarApex.dec), date: date, latitude: 0, longitude: 0)
        #expect(abs(anti.solar + 20) < 1e-9)
        // Erdbahn zum Frühlingsanfang Richtung λ = 270° (α = 18h, δ = −23,44°), ≈ 29,8 km/s.
        let apexOrbit = Astro.lsrCorrection(j2000: .init(ra: 270, dec: -23.44), date: date, latitude: 0, longitude: 0)
        #expect(apexOrbit.orbit > 29.5 && apexOrbit.orbit < 30.4, "\(apexOrbit.orbit)")
        let pole = Astro.lsrCorrection(j2000: .init(ra: 270, dec: 66.56), date: date, latitude: 0, longitude: 0)
        #expect(abs(pole.orbit) < 0.3, "Ekliptikpol: \(pole.orbit)")
        let speed = simd_length(Astro.earthOrbitalVelocity(date))
        #expect(speed > 29.2 && speed < 30.4)
        // Erddrehung: im Meridian 0; am Osthorizont am Äquator bewegen wir uns mit
        // 0,465 km/s auf die Quelle zu – die Korrektur ist +0,465 km/s.
        let lat = 0.0, lon = 0.0
        let east = Astro.equatorialOfDate(.init(azimuth: 90, elevation: 0), latitude: lat, longitude: lon, date: date)
        let rotEast = Astro.lsrCorrection(j2000: Astro.toJ2000(east, date: date), date: date, latitude: lat, longitude: lon).rotation
        #expect(abs(rotEast - 0.4651) < 0.002, "Ost: \(rotEast)")
        let south = Astro.equatorialOfDate(.init(azimuth: 180, elevation: 40), latitude: lat, longitude: lon, date: date)
        let rotSouth = Astro.lsrCorrection(j2000: Astro.toJ2000(south, date: date), date: date, latitude: lat, longitude: lon).rotation
        #expect(abs(rotSouth) < 1e-6)
    }

    @Test("Doppler: Radiodefinition hin und zurück")
    func doppler() {
        #expect(Astro.velocity(frequencyHz: Astro.restFrequencyHz) == 0)
        let f = Astro.frequency(velocity: 100)
        #expect(abs(Astro.restFrequencyHz - f - 473_796.4) < 0.1)   // 100 km/s ≈ 473,8 kHz
        #expect(abs(Astro.velocity(frequencyHz: f) - 100) < 1e-9)
    }

    // MARK: Spektren

    /// Empfängerfrequenzgang über dem Basisband (Welligkeit ±30 %, Neigung).
    private func ripple(_ bbHz: Double) -> Double {
        1 + 0.3 * sin(2 * .pi * bbHz / 700_000 + 0.4) + 0.1 * bbHz / 2_000_000
    }

    /// Linie: Gauß, Höhe relativ zu T_sys, Breite in km/s, bei v_LSR.
    private func line(_ rfHz: Double, vLSR: Double, lsr: Double, height: Double, sigmaKmS: Double) -> Double {
        let vTopo = vLSR - lsr
        let f0 = Astro.frequency(velocity: vTopo)
        let sigmaHz = sigmaKmS / Astro.speedOfLight * Astro.restFrequencyHz
        return height * exp(-0.5 * pow((rfHz - f0) / sigmaHz, 2))
    }

    private func powerSpectrum(lo: Double, fftSize n: Int, rng: inout LCG, noise: Double, vLSR: Double, lsr: Double) -> [Double] {
        let bin = HydrogenModel.sampleRate / Double(n)
        return (0..<n).map { k in
            let bb = Double(k - n / 2) * bin
            let sky = 1 + line(lo + bb, vLSR: vLSR, lsr: lsr, height: 0.02, sigmaKmS: 12)
                + line(lo + bb, vLSR: vLSR - 55, lsr: lsr, height: 0.008, sigmaKmS: 8)
            return ripple(bb) * sky * (1 + noise * rng.gaussian())
        }
    }

    @Test("Frequenzumschaltung: Linie in Rauschen mit Welligkeit an der richtigen Geschwindigkeit")
    func frequencySwitchingRecoversLine() throws {
        let n = 4096
        let (loA, loB) = HydrogenProcessing.localOscillators(centerHz: Astro.restFrequencyHz, offsetHz: 1_000_000,
                                                             sampleRate: HydrogenModel.sampleRate, fftSize: n)
        #expect(abs((loB - loA) - 2_000_000) < HydrogenModel.sampleRate / Double(n))
        var rng = LCG(state: 2026)
        let lsr = 12.3, vTrue = 40.0
        let a = powerSpectrum(lo: loA, fftSize: n, rng: &rng, noise: 0.002, vLSR: vTrue, lsr: lsr)
        let b = powerSpectrum(lo: loB, fftSize: n, rng: &rng, noise: 0.002, vLSR: vTrue, lsr: lsr)
        let spectrum = HydrogenProcessing.fold(a: a, b: b, loA: loA, loB: loB, sampleRate: HydrogenModel.sampleRate)
        // Gültig etwa Mitte ± 1 MHz.
        let span = Double(spectrum.count) * spectrum.stepHz
        #expect(span > 1.8e6 && span < 2.2e6, "Breite \(span)")
        let curve = HydrogenProcessing.curve(spectrum, lsrCorrection: lsr, smoothingKHz: 5, baselineOrder: 1, excludeKmS: 120)
        let peak = try #require(curve.peak())
        // Das Maximum einer 12 km/s breiten Linie wandert im Rauschen um ±1 km/s,
        // der Schwerpunkt über der halben Höhe deutlich weniger.
        #expect(abs(peak.velocity - vTrue) < 2, "Maximum bei \(peak.velocity) km/s")
        let centroid = try #require(curve.centroid())
        #expect(abs(centroid - vTrue) < 0.6, "Schwerpunkt bei \(centroid) km/s")
        #expect(abs(peak.value - 0.02) < 0.002, "Höhe \(peak.value)")
        // Welligkeit (±30 %) ist weg: außerhalb der Linien nur noch Rauschen.
        let noise = try #require(curve.noise(exclude: -120...120))
        #expect(noise < 0.0015, "Rest \(noise)")
        // Zweite, schwächere Komponente bei −15 km/s sichtbar.
        let i = try #require(curve.velocity.indices.min { abs(curve.velocity[$0] + 15) < abs(curve.velocity[$1] + 15) })
        #expect(curve.values[i] > 0.006)
    }

    @Test("Referenzmessung: (S − R)/R entfernt den Frequenzgang")
    func referenceRecoversLine() throws {
        let n = 4096
        let lo = Astro.restFrequencyHz - 1_000_000
        var rng = LCG(state: 7)
        let lsr = -8.0, vTrue = -25.0
        let s = powerSpectrum(lo: lo, fftSize: n, rng: &rng, noise: 0.002, vLSR: vTrue, lsr: lsr)
        // Referenz: kalter Himmel – derselbe Frequenzgang, keine Linie.
        let bin = HydrogenModel.sampleRate / Double(n)
        let r = (0..<n).map { k in ripple(Double(k - n / 2) * bin) * (1 + 0.002 * rng.gaussian()) }
        let spectrum = HydrogenProcessing.referenceRatio(signal: s, reference: r, lo: lo, sampleRate: HydrogenModel.sampleRate)
        let curve = HydrogenProcessing.curve(spectrum, lsrCorrection: lsr, smoothingKHz: 5, baselineOrder: 1, excludeKmS: 120)
        let centroid = try #require(curve.centroid())
        #expect(abs(centroid - vTrue) < 0.6, "Schwerpunkt bei \(centroid) km/s")
    }

    @Test("Grundlinie: Polynom außerhalb des Linienbereichs abgezogen")
    func baseline() {
        let x = (0..<400).map { Double($0) - 200 }   // km/s
        let values = x.map { 0.01 + 0.00002 * $0 + 0.000_000_1 * $0 * $0 + (abs($0) < 20 ? 0.005 : 0) }
        let flat = HydrogenProcessing.subtractBaseline(values, x: x, exclude: -60...60, order: 2)
        #expect(abs(flat[0]) < 1e-9 && abs(flat[399]) < 1e-9)
        #expect(abs(flat[200] - 0.005) < 1e-9)
        let smoothed = HydrogenProcessing.smooth([1, 2, 3, .nan, 5], width: 3)
        #expect(smoothed[1] == 2 && smoothed[2] == 2.5 && smoothed[3].isNaN && smoothed[4] == 5)
    }

    @Test("FFT-Weg: Ton über der Mitte landet im oberen Basisband")
    func accumulatorFrequencySign() throws {
        let n = 4096
        let acc = HydrogenAccumulator(fftSize: n)
        acc.setPhase(.a)
        let toneHz = 500_000.0
        var iq = Data(count: 2 * n * 4)
        iq.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: Int8.self)
            for k in 0..<(n * 4) {
                let phase = 2 * Double.pi * toneHz * Double(k) / HydrogenModel.sampleRate
                b[2 * k] = Int8((50 * cos(phase)).rounded())
                b[2 * k + 1] = Int8((50 * sin(phase)).rounded())
            }
        }
        acc.process(iq)
        let snap = acc.snapshot()
        #expect(snap.countA == 4 && snap.countB == 0)
        let best = try #require(snap.a.indices.max { snap.a[$0] < snap.a[$1] })
        let expected = n / 2 + Int((toneHz / (HydrogenModel.sampleRate / Double(n))).rounded())
        #expect(abs(best - expected) <= 1)
        // Fortsetzen: Summen zurückschreiben ergibt dieselben Mittelwerte.
        let other = HydrogenAccumulator(fftSize: n)
        other.restore(a: snap.a, countA: snap.countA, b: [], countB: 0)
        let again = other.snapshot()
        #expect(again.countA == 4)
        #expect(zip(again.a, snap.a).allSatisfy { abs($0 - $1) <= 1e-12 * max(1, abs($1)) })
    }
}

import simd
